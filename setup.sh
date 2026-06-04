#!/usr/bin/env bash
# =============================================================================
# setup.sh — build, launch, and provision Haggai's persistent desktop container.
#
# REQUIRES exactly one argument: the password. That one value becomes BOTH:
#   * the RustDesk remote-desktop permanent password, AND
#   * the `user` Linux login / sudo password
# inside the container.
#
# Defensive and strict, by design: it validates every precondition, asserts every
# step actually took effect, and fails loud at the first unexpected state. There
# are no silent fallbacks. It REFUSES to run if the container already exists, so a
# re-run can never wipe Haggai's persistent writable layer (his installed
# packages, /tmp, /etc, everything). Use ./teardown.sh to intentionally reset.
# =============================================================================
set -euo pipefail

# ---- constants (specific, not configurable) --------------------------------
CONTAINER=haggai_computer
IMAGE=haggai_computer:1.4.7
SERVICE=haggai_computer
HOST_PORT=21128
MIN_PW_LEN=12
HEALTH_TIMEOUT=300        # seconds to wait for the container to become healthy
PW_TIMEOUT=420            # total seconds to keep trying to set the password
PW_REFIRE=20              # seconds between (re)fires of the detached password setter
IPC_SLEEP=3               # seconds between read-back polls
EXEC_TIMEOUT=30           # hard cap on each (foreground) read-back exec

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[setup] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
Usage: ./setup.sh <password>

  <password>   REQUIRED. Used for BOTH RustDesk access AND the 'user' sudo login
               inside the container. Minimum ${MIN_PW_LEN} characters.

Builds the image, starts the container, and provisions the password. Refuses to
run if the container already exists (run ./teardown.sh first to reset).
EOF
  exit 2
}

# ---- argument validation ---------------------------------------------------
[ "$#" -eq 1 ] || usage
PASSWORD="$1"
[ -n "$PASSWORD" ]                  || die "password must not be empty"
[ "${#PASSWORD}" -ge "$MIN_PW_LEN" ] || die "password too short: need >= ${MIN_PW_LEN} characters, got ${#PASSWORD}"

# ---- host preconditions ----------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
command -v timeout >/dev/null 2>&1 || die "coreutils 'timeout' not found on PATH"
docker info >/dev/null 2>&1 \
  || die "cannot talk to the Docker daemon (is it running, and are you in the 'docker' group?)"
docker compose version >/dev/null 2>&1 \
  || die "the Docker Compose v2 plugin is required (the 'docker compose' subcommand)"
[ -f "$SCRIPT_DIR/docker-compose.yml" ] || die "docker-compose.yml not found next to setup.sh"
[ -f "$SCRIPT_DIR/Dockerfile" ]         || die "Dockerfile not found next to setup.sh"

cd "$SCRIPT_DIR"

# ---- refuse if already deployed (protects the persistent writable layer) ---
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  die "container '$CONTAINER' already exists. Refusing to rebuild — that would discard
       Haggai's installed packages and system changes. Run ./teardown.sh first if you
       really intend to reset, then re-run ./setup.sh."
fi

# the persistent, isolated home must exist on the host before the bind-mount
install -d "$SCRIPT_DIR/home"

# ---- build -----------------------------------------------------------------
log "Building the image. This is intentionally large (full toolchain + RustDesk +"
log "desktop); the FIRST build downloads/compiles a lot and can take a long while."
docker compose build

# ---- launch ----------------------------------------------------------------
log "Starting the container..."
docker compose up -d

# ---- wait until healthy (RustDesk Direct-IP listener is up on :21118) -------
log "Waiting for the RustDesk listener to come up (container health)..."
start=$SECONDS
while :; do
  status="$(docker inspect -f '{{ if .State.Health }}{{ .State.Health.Status }}{{ else }}none{{ end }}' "$CONTAINER" 2>/dev/null || echo missing)"
  case "$status" in
    healthy)   break ;;
    unhealthy) docker compose logs --tail=120 || true; die "container became unhealthy" ;;
    missing)   docker compose logs --tail=120 || true; die "container '$CONTAINER' disappeared" ;;
  esac
  if [ $(( SECONDS - start )) -ge "$HEALTH_TIMEOUT" ]; then
    docker compose logs --tail=120 || true
    die "timed out after ${HEALTH_TIMEOUT}s waiting for 'healthy' (last status: $status)"
  fi
  sleep 3
done
log "Container is healthy."

# ---- set the RustDesk permanent password -----------------------------------
# How `rustdesk --password` works here (verified against the 1.4.7 source AND by
# inspecting a live container):
#   * run as root (-u 0) with the binary "installed" (under /usr) so core_main
#     enables the UserMainIpcScope guard for this management command;
#   * 1.4.7 IPC sockets are uid-scoped (/tmp/<App>-<uid>/ipc). Root does NOT use a
#     fixed path: it scans /proc for the running `--server` (reading /proc/<pid>/exe
#     across uids needs CAP_SYS_PTRACE — added in compose), takes its uid (1000),
#     and connects to /tmp/RustDesk-1000/ipc (reached via the default DAC_OVERRIDE
#     capability — one reason cap_drop:ALL is not used);
#   * the server (uid 1000) then persists the encrypted password into
#     /home/user/.config/rustdesk/RustDesk.toml AS `user`. That file is the ONLY
#     authoritative success signal, and we read it back to confirm.
# THE CRITICAL GOTCHA: `rustdesk --password` sets the password over IPC almost
# immediately, but the 1.4.7 Flutter binary then leaves a process holding its stdio
# open and never returns. So ANY *foreground* `docker compose exec` that runs it — or
# that later kills it — inherits that open pipe and hangs waiting for EOF, and
# `timeout` cannot rescue it (a SIGTERM to the compose client does not tear down the
# in-container exec session; observed: a `timeout 30` still alive after 90 minutes).
# Therefore EVERYTHING that touches the Flutter client runs DETACHED (`-d`, which
# returns the instant it is launched): both the password set AND the cleanup kill.
# The ONLY foreground exec is the read-back — a plain grep that never touches the
# client, so it always returns fast — and that file is the authoritative success
# signal. We (re)fire on an interval rather than every poll, and never kill an
# in-flight attempt, so a slow first try is given time instead of being cut off.
# DISPLAY is set because the binary may touch the UI; the password is passed via an
# inherited env var, expanded INSIDE the container (single-quoted bash -c) so it
# never reaches host argv. (A clean ./home — `./teardown.sh --purge` before
# re-deploying — makes a non-empty password unambiguously mean THIS run set it.)
log "Setting the RustDesk permanent password..."
export RD_PASSWORD="$PASSWORD"
rd_ok=0
pw_deadline=$(( SECONDS + PW_TIMEOUT ))
last_fire=$(( SECONDS - PW_REFIRE ))      # make the first iteration fire immediately
while [ "$SECONDS" -lt "$pw_deadline" ]; do
  if [ $(( SECONDS - last_fire )) -ge "$PW_REFIRE" ]; then
    docker compose exec -d -u 0 -e RD_PASSWORD -e DISPLAY=:99 "$SERVICE" \
      bash -c 'rustdesk --password "$RD_PASSWORD"' >/dev/null 2>&1 || true
    last_fire=$SECONDS
  fi
  sleep "$IPC_SLEEP"
  if timeout "$EXEC_TIMEOUT" docker compose exec -T -u 0 "$SERVICE" \
       bash -c "grep -Eq \"^password = '.+'\" /home/user/.config/rustdesk/RustDesk.toml" 2>/dev/null; then
    rd_ok=1
    break
  fi
done
unset RD_PASSWORD
[ "$rd_ok" -eq 1 ] \
  || die "RustDesk password was not persisted to RustDesk.toml within ${PW_TIMEOUT}s (is --server up?)."
# Clean up the detached client(s) — DETACHED, so killing the stuck Flutter process
# can never wedge the host the way a foreground exec would.
docker compose exec -d -u 0 "$SERVICE" pkill -f 'rustdesk --password' >/dev/null 2>&1 || true
log "RustDesk permanent password set and verified."

# ---- set the 'user' Linux / sudo password to the SAME value ----------------
# `printf` is a bash builtin (no separate process), so the password is not in the
# host process list; chpasswd reads "user:<pw>" from stdin (not from argv).
log "Setting the 'user' Linux/sudo password (same value)..."
printf 'user:%s\n' "$PASSWORD" | docker compose exec -T -u 0 "$SERVICE" chpasswd
pw_status="$(docker compose exec -T -u 0 "$SERVICE" passwd -S user | awk '{print $2}')"
[ "$pw_status" = "P" ] || die "Linux password for 'user' did not take (passwd -S reported '$pw_status')"
log "Linux/sudo password set and verified."

# ---- done: print how to connect --------------------------------------------
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[ -n "${LAN_IP:-}" ] || LAN_IP="<this-box-LAN-ip>"

cat <<EOF

============================================================================
  haggai_computer is up, healthy, and provisioned.
============================================================================

  Connect with the RustDesk app (Android or desktop) -> "Direct IP Access":
        <YOUR-PUBLIC-IP>:${HOST_PORT}
     (on the LAN you can test with   ${LAN_IP}:${HOST_PORT} )

  Password (BOTH RustDesk access AND the 'user' sudo login): the one you set.

  Inside the desktop:
     * Codex:   run 'codex' -> "Sign in with ChatGPT" (device code shown in the
                terminal; open it on your phone), or  export OPENAI_API_KEY=...
     * GitHub:  'gh auth login' (device flow), then 'git push' works.
     * 'sudo' works with the same password; 'sudo apt install ...' PERSISTS
       across reboots (the whole container is persistent — see README).

  DMZ NOTE: port ${HOST_PORT}/tcp is now reachable from the internet. Apply the
  one-line allow-list edit in docs/SECURITY.md so verify_network_security.py
  stays green and your posture stays known.

  Lifecycle:
     ./teardown.sh                  stop + remove the container (keeps ./home)
     docker compose stop|start      pause / resume (keeps EVERYTHING)
============================================================================
EOF
