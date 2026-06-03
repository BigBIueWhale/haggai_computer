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
IMAGE=haggai_computer:1.4.6
SERVICE=haggai_computer
HOST_PORT=21128
MIN_PW_LEN=12
HEALTH_TIMEOUT=300        # seconds to wait for the container to become healthy
IPC_ATTEMPTS=20           # rustdesk --password tries (waits out IPC readiness)
IPC_SLEEP=3               # seconds between tries
EXEC_TIMEOUT=30           # hard cap on each rustdesk exec (guards against a hang)

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
# How `rustdesk --password` works here (verified against the 1.4.6 source):
#   * it must run as root (-u 0) and the binary must be "installed" (under /usr);
#   * it reaches the running --server over a FIXED IPC socket /tmp/<AppName>/ipc
#     (hbb_common config.rs `ipc_path`) — NOT a HOME/XDG-derived path, so we do
#     NOT set those. The server (running as `user`) then persists the encrypted
#     permanent password into /home/user/.config/rustdesk/RustDesk.toml AS `user`.
#   * we leave HOME at root's default (/root) so the client's own harmless local
#     config write (ipc.rs:1162) never lands in — or root-owns — the user's home.
# DISPLAY is set in case the Flutter binary spins up the UI before handling the
# flag. The password is passed via an inherited env var, expanded INSIDE the
# container (single-quoted bash -c), so it never appears in the host process list.
log "Setting the RustDesk permanent password (IPC to the running server)..."
export RD_PASSWORD="$PASSWORD"
rd_ok=0
rd_out=""
for _ in $(seq 1 "$IPC_ATTEMPTS"); do
  rd_out="$(timeout "$EXEC_TIMEOUT" docker compose exec -T -u 0 \
              -e RD_PASSWORD \
              -e DISPLAY=:99 \
              "$SERVICE" \
              bash -c 'rustdesk --password "$RD_PASSWORD"' 2>&1 || true)"
  if printf '%s' "$rd_out" | grep -q 'Done!'; then
    rd_ok=1
    break
  fi
  sleep "$IPC_SLEEP"
done
unset RD_PASSWORD
if [ "$rd_ok" -ne 1 ]; then
  printf '%s\n' "$rd_out" >&2
  die "RustDesk did not accept the permanent password (expected 'Done!'). Output above."
fi

# read-back assertion: the server actually persisted an (encrypted) permanent
# password into the user's RustDesk.toml. The short retry absorbs the async IPC
# write (the '--password' client may print 'Done!' just before the server stores).
rb_ok=0
for _ in $(seq 1 10); do
  if docker compose exec -T -u 0 "$SERVICE" \
       bash -c "grep -Eq \"^password = '.+'\" /home/user/.config/rustdesk/RustDesk.toml" 2>/dev/null; then
    rb_ok=1
    break
  fi
  sleep 1
done
[ "$rb_ok" -eq 1 ] || die "RustDesk password read-back failed — no password persisted in RustDesk.toml"
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
