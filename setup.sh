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
#     authoritative success signal.
# THE CRITICAL GOTCHA: `rustdesk --password` sets the password over IPC almost
# immediately, but the 1.4.7 Flutter binary then leaves a process holding its stdio
# open and never returns. Worse, a *foreground* `docker compose exec` against this
# container can wedge for that same reason even when the command it runs is trivial
# (even a grep), and `timeout` cannot rescue it — a SIGTERM to the compose client
# does not tear down the in-container exec session (observed: `timeout 30` calls
# still alive after minutes). So the rule here is absolute: NO foreground
# `docker compose exec`, ever.
#   * The password set runs DETACHED (`-d`, returns immediately).
#   * The read-back does NOT exec at all: ./home is bind-mounted to /home/user, so
#     RustDesk.toml is the host file $RD_TOML below — we grep it directly on the host
#     (host runs as uid 1000, the same uid that owns the file).
#   * We (re)fire on an interval rather than every poll, and never kill an in-flight
#     attempt, so a slow first try is given time instead of being cut off.
# DISPLAY is set because the binary may touch the UI; the password is passed via an
# inherited env var, expanded INSIDE the container (single-quoted bash -c) so it
# never reaches host argv. (A clean ./home — `./teardown.sh --purge` before
# re-deploying — makes a non-empty password unambiguously mean THIS run set it.)
RD_TOML="$SCRIPT_DIR/home/.config/rustdesk/RustDesk.toml"   # bind-mounted; host-readable
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
  # Read back on the HOST side of the bind mount — no docker exec, so it can't wedge.
  if grep -Eq "^password = '.+'" "$RD_TOML" 2>/dev/null; then
    rd_ok=1
    break
  fi
done
[ "$rd_ok" -eq 1 ] \
  || die "RustDesk password was not persisted to RustDesk.toml within ${PW_TIMEOUT}s (is --server up?)."
# Clean up the detached client(s) — DETACHED (pkill excludes its own pid), so it
# returns at once and killing the stuck Flutter process can't wedge the host.
docker compose exec -d -u 0 "$SERVICE" pkill -f 'rustdesk --password' >/dev/null 2>&1 || true
log "RustDesk permanent password set and verified."

# ---- set the 'user' Linux / sudo password to the SAME value ----------------
# /etc/shadow lives in the container's writable layer (NOT bind-mounted), so this
# must run inside the container — but, per the no-foreground-exec rule above, it runs
# DETACHED. ONE detached exec sets the password and self-verifies (passwd -S => P),
# and only on success writes a marker into the bind-mounted home, which we then poll
# from the HOST. The password rides the already-exported env var (never host argv);
# chpasswd reads it from stdin inside the container.
MARK="$SCRIPT_DIR/home/.haggai_linux_pw_ok"
rm -f "$MARK"
log "Setting the 'user' Linux/sudo password (same value)..."
docker compose exec -d -u 0 -e RD_PASSWORD "$SERVICE" bash -c '
  printf "user:%s\n" "$RD_PASSWORD" | chpasswd \
    && [ "$(passwd -S user | awk "{print \$2}")" = P ] \
    && : > /home/user/.haggai_linux_pw_ok
' >/dev/null 2>&1 || true
lin_ok=0
lin_deadline=$(( SECONDS + EXEC_TIMEOUT ))
while [ "$SECONDS" -lt "$lin_deadline" ]; do
  [ -f "$MARK" ] && { lin_ok=1; break; }
  sleep 1
done
rm -f "$MARK"
unset RD_PASSWORD
[ "$lin_ok" -eq 1 ] \
  || die "Linux/sudo password for 'user' was not set/verified within ${EXEC_TIMEOUT}s."
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
