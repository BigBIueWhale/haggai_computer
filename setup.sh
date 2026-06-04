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
# step actually took effect, fails LOUD (with diagnostics) at the first unexpected
# state, and never silently falls back. It REFUSES to run if the container already
# exists, so a re-run can never wipe Haggai's persistent writable layer (his
# installed packages, /tmp, /etc, everything). Use ./teardown.sh to reset.
#
# HARD INVARIANT (learned the hard way): a *foreground* `docker compose exec` against
# this container can wedge indefinitely — the in-container command finishes but the
# exec client never returns, and `timeout` cannot tear it down. So this script runs
# NO foreground exec anywhere. It sets both passwords with DETACHED (`-d`) execs and
# verifies the results from the HOST side of the ./home bind mount.
# =============================================================================
set -euo pipefail

# ---- constants (specific, not configurable) --------------------------------
CONTAINER=haggai_computer
SERVICE=haggai_computer
HOST_PORT=21128
CONTAINER_PORT=21118
MIN_PW_LEN=12
HEALTH_TIMEOUT=300        # seconds to wait for the container to become healthy
PW_TIMEOUT=420            # seconds to keep trying to set the RustDesk password
PW_REFIRE=20              # seconds between (re)fires of the detached password setter
POLL_SLEEP=3              # seconds between host-side read-back polls
LINUX_PW_TIMEOUT=60       # seconds to wait for the detached Linux-password setter

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RD_TOML="$SCRIPT_DIR/home/.config/rustdesk/RustDesk.toml"  # bind-mounted; host-readable (uid 1000)
LINUX_MARK="$SCRIPT_DIR/home/.haggai_linux_pw_ok"          # transient success marker (host-polled)
LINUX_LOG="$SCRIPT_DIR/home/.haggai_linux_pw.log"          # transient diagnostics (never the password)
GPU_MARK="$SCRIPT_DIR/home/.haggai_gpu_ok"                 # transient: --dev GPU verification marker
HOSTDOCKER_MARK="$SCRIPT_DIR/home/.haggai_hostdocker_ok"   # transient: --dev host-Docker verification marker

log()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup]\033[0m %s\n' "$*" >&2; }
die()  { trap - ERR; printf '\033[1;31m[setup] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

# Remove the transient host-side provisioning artifacts on ANY exit.
cleanup() { rm -f "$LINUX_MARK" "$LINUX_LOG" "$GPU_MARK" "$HOSTDOCKER_MARK" 2>/dev/null || true; }
trap cleanup EXIT

# Safety net for an UNGUARDED failure (set -e): name the line and the recovery path.
on_err() {
  local rc=$?
  printf '\033[1;31m[setup] FATAL:\033[0m unexpected error (exit %s) near line %s.\n' \
    "$rc" "${BASH_LINENO[0]:-?}" >&2
  printf '[setup] The deployment may be half-provisioned. Run ./teardown.sh and retry.\n' >&2
}
trap on_err ERR

print_help() {
  cat <<EOF
Usage: ./setup.sh [options] <password>

  <password>        REQUIRED. Used for BOTH RustDesk access AND the 'user' sudo
                    login inside the container. >= ${MIN_PW_LEN} characters; no
                    control characters (newline/tab/etc.).

Options (OPTIONAL and OFF by default — Haggai's deployment uses NONE of this):
  --dev             Turn this locked-down streaming desktop into a host-coupled DEV
                    workstation. ONE switch, both halves, no sub-options:
                      * host NVIDIA GPU for CUDA / compute (nvidia-container-toolkit).
                        Graphics stay on the CPU, so 0 VRAM is spent on the desktop.
                      * the HOST's Docker: bakes in the Docker CLI + the docker-guard
                        wrapper and bind-mounts /var/run/docker.sock, so 'docker'
                        inside drives the host daemon (NOT Docker-in-Docker). The
                        wrapper refuses the patterns that would publish a service to
                        the public internet on this DMZ box, and prints the working
                        one ('docker haggai-help' inside shows it).
                    WARNING: the docker socket is ROOT-EQUIVALENT on the host. Use
                    --dev ONLY on a single-user box you fully trust; NEVER for Haggai's
                    DMZ desktop. Requires the NVIDIA driver + nvidia-container-toolkit
                    already installed on THIS host.
  -h, --help        Show this help and exit.

Builds the image, starts the container, and provisions the password. Refuses to run
if the container already exists (run ./teardown.sh first to reset).
EOF
}
usage() { print_help >&2; exit 2; }

# ---- container-state helpers (host-side only; never exec, so they can't wedge) ----
container_status() { docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true; }
assert_container_running() {
  local s; s="$(container_status)"
  [ "$s" = running ] || {
    docker compose logs --tail=120 2>/dev/null || true
    die "container '$CONTAINER' is '${s:-absent}' (expected 'running') mid-provisioning — see logs above."
  }
}

# ---- argument parsing (flags in any order; exactly one positional: the password) --
DEV=0
POSITIONAL=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --dev)     DEV=1; shift ;;
    --)        shift; while [ "$#" -gt 0 ]; do POSITIONAL+=("$1"); shift; done ;;
    -*)        die "unknown option: $1  (run ./setup.sh --help)" ;;
    *)         POSITIONAL+=("$1"); shift ;;
  esac
done
[ "${#POSITIONAL[@]}" -eq 1 ] || usage
PASSWORD="${POSITIONAL[0]}"
[ -n "$PASSWORD" ]                   || die "password must not be empty"
[ "${#PASSWORD}" -ge "$MIN_PW_LEN" ] || die "password too short: need >= ${MIN_PW_LEN} characters, got ${#PASSWORD}"
case "$PASSWORD" in
  *[[:cntrl:]]*) die "password must not contain control characters (newline, tab, etc.)" ;;
esac

# ---- host preconditions ----------------------------------------------------
command -v docker  >/dev/null 2>&1 || die "docker not found on PATH"
command -v timeout >/dev/null 2>&1 || die "coreutils 'timeout' not found on PATH"
command -v ss      >/dev/null 2>&1 || die "iproute2 'ss' not found on PATH (needed for the final listener check)"
docker info >/dev/null 2>&1 \
  || die "cannot talk to the Docker daemon (is it running, and are you in the 'docker' group?)"
docker compose version >/dev/null 2>&1 \
  || die "the Docker Compose v2 plugin is required (the 'docker compose' subcommand)"
[ -f "$SCRIPT_DIR/docker-compose.yml" ] || die "docker-compose.yml not found next to setup.sh"
[ -f "$SCRIPT_DIR/Dockerfile" ]         || die "Dockerfile not found next to setup.sh"

cd "$SCRIPT_DIR"

# ---- optional dev mode: assemble COMPOSE_FILE + check ALL preconditions ----------
# Default (no --dev) => COMPOSE_FILE is exactly docker-compose.yml, identical to
# before. --dev appends the single override (compose merges them) and is gated by
# fail-loud precondition checks for BOTH halves — host GPU and host Docker — in the
# spirit of the personal_server install scripts (refuse on a missing prerequisite,
# never silently degrade).
COMPOSE_FILES="docker-compose.yml"
if [ "$DEV" -eq 1 ]; then
  [ -f docker-compose.dev.yml ] || die "--dev: docker-compose.dev.yml is missing"
  # half 1 — host GPU prerequisites
  command -v nvidia-smi >/dev/null 2>&1 \
    || die "--dev: 'nvidia-smi' not found — install the NVIDIA driver on this host first"
  nvidia-smi -L >/dev/null 2>&1 \
    || die "--dev: 'nvidia-smi -L' failed — the NVIDIA driver is not working"
  docker info 2>/dev/null | grep -qiE 'Runtimes:.*nvidia|nvidia\.com/gpu' \
    || die "--dev: Docker has no NVIDIA runtime/CDI — install nvidia-container-toolkit and run 'sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker'"
  # half 2 — host Docker socket
  [ -S /var/run/docker.sock ] \
    || die "--dev: /var/run/docker.sock not found — is the host Docker daemon running?"
  COMPOSE_FILES="$COMPOSE_FILES:docker-compose.dev.yml"
  warn "Mode: --dev — host-coupled dev workstation. The container will get the host GPU"
  warn "      (compute only; graphics stay on the CPU) AND ROOT-EQUIVALENT control of this"
  warn "      host's Docker (bind-mounting /var/run/docker.sock). Only ever do this on a box"
  warn "      you fully trust; NEVER for a DMZ desktop like Haggai's."
fi
export COMPOSE_FILE="$COMPOSE_FILES"

# ---- refuse if already deployed (protects the persistent writable layer) ---
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  die "container '$CONTAINER' already exists. Refusing to rebuild — that would discard
       Haggai's installed packages and system changes. Run ./teardown.sh first if you
       really intend to reset, then re-run ./setup.sh."
fi

# the persistent, isolated home must exist on the host before the bind-mount
install -d "$SCRIPT_DIR/home"
# clear any transient artifacts a previous interrupted run may have left behind
rm -f "$LINUX_MARK" "$LINUX_LOG"

# ---- build -----------------------------------------------------------------
log "Building the image. This is intentionally large (full toolchain + RustDesk +"
log "desktop); the FIRST build downloads/compiles a lot and can take a long while."
docker compose build || die "image build failed (see output above)"

# ---- launch ----------------------------------------------------------------
log "Starting the container..."
docker compose up -d || die "'docker compose up -d' failed (see output above)"

# ---- wait until healthy (RustDesk Direct-IP listener is up on :21118) -------
# Fail FAST on an exited/dead container instead of waiting out the whole timeout.
log "Waiting for the RustDesk listener to come up (container health)..."
start=$SECONDS
while :; do
  info="$(docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || true)"
  cstatus="${info%%|*}"; hstatus="${info##*|}"
  [ -n "$cstatus" ] || { docker compose logs --tail=120 || true; die "container '$CONTAINER' disappeared"; }
  case "$cstatus" in
    running) ;;
    *) docker compose logs --tail=120 || true; die "container is '$cstatus' (not running) — see logs above" ;;
  esac
  case "$hstatus" in
    healthy)   break ;;
    unhealthy) docker compose logs --tail=120 || true; die "container became unhealthy — see logs above" ;;
    *)         ;;   # starting / none → keep waiting
  esac
  if [ $(( SECONDS - start )) -ge "$HEALTH_TIMEOUT" ]; then
    docker compose logs --tail=120 || true
    die "timed out after ${HEALTH_TIMEOUT}s waiting for 'healthy' (status: ${cstatus}/${hstatus})"
  fi
  sleep 3
done
log "Container is healthy."

# ---- verify the optional modes actually took effect (detached exec -> host marker) ---
# Same no-foreground-exec rule as the passwords: a detached exec writes a marker into
# the bind-mounted home, then we poll it from the host.
if [ "$DEV" -eq 1 ]; then
  log "Verifying GPU passthrough (nvidia-smi inside the container)..."
  rm -f "$GPU_MARK"
  # Detached EXISTENCE-marker: the in-container pipe decides and we only `touch` the
  # marker on success. Detached execs reliably create a file but do NOT reliably
  # capture a command's stdout to a bind-mounted file, so we never depend on content.
  docker compose exec -d -u 0 "$SERVICE" \
    bash -c 'nvidia-smi -L 2>/dev/null | grep -qi "GPU [0-9]" && : > /home/user/.haggai_gpu_ok' \
    >/dev/null 2>&1 || true
  gpu_ok=0; gdl=$(( SECONDS + 30 ))
  while [ "$SECONDS" -lt "$gdl" ]; do [ -f "$GPU_MARK" ] && { gpu_ok=1; break; }; sleep 1; done
  rm -f "$GPU_MARK"
  [ "$gpu_ok" -eq 1 ] \
    || die "--dev (GPU): nvidia-smi could not see a GPU inside the container. Check the host's nvidia-container-toolkit, then ./teardown.sh and retry."
  log "  GPU verified — nvidia-smi sees the host GPU inside (CUDA/compute available)."
fi
if [ "$DEV" -eq 1 ]; then
  log "Verifying host-Docker access (daemon reachable + 'user' in the socket group)..."
  rm -f "$HOSTDOCKER_MARK"
  # Same existence-marker pattern: only touch the marker if BOTH the host daemon is
  # reachable AND 'user' is in the socket's group.
  docker compose exec -d -u 0 "$SERVICE" bash -c '
    docker version --format "{{.Server.Version}}" >/dev/null 2>&1 || exit 0
    g="$(getent group "$(stat -c %g /var/run/docker.sock)" | head -1 | cut -d: -f1)"
    id -nG user | tr " " "\n" | grep -qx "$g" || exit 0
    : > /home/user/.haggai_hostdocker_ok' >/dev/null 2>&1 || true
  hd_ok=0; hdl=$(( SECONDS + 30 ))
  while [ "$SECONDS" -lt "$hdl" ]; do [ -f "$HOSTDOCKER_MARK" ] && { hd_ok=1; break; }; sleep 1; done
  rm -f "$HOSTDOCKER_MARK"
  [ "$hd_ok" -eq 1 ] \
    || die "--dev (host Docker): the container could not reach the host Docker daemon, or 'user' lacks socket access. Run ./teardown.sh and retry."
  log "  host Docker reachable from the container, and 'user' can use it without sudo."
fi

# ---- set the RustDesk permanent password -----------------------------------
# How `rustdesk --password` works here (verified against the 1.4.7 source AND by
# inspecting a live container):
#   * run as root (-u 0) with the binary "installed" (under /usr) so core_main
#     enables the UserMainIpcScope guard for this management command;
#   * 1.4.7 IPC sockets are uid-scoped (/tmp/<App>-<uid>/ipc). Root scans /proc for
#     the running `--server` (reading /proc/<pid>/exe across uids needs
#     CAP_SYS_PTRACE — added in compose), takes its uid (1000), and connects to
#     /tmp/RustDesk-1000/ipc (reached via the default DAC_OVERRIDE capability);
#   * the server (uid 1000) then persists the encrypted password into RustDesk.toml.
# THE GOTCHA + THE RULE: `rustdesk --password` sets the password over IPC then leaves
# a process holding its stdio open and never returns; and (worse) a FOREGROUND
# `docker compose exec` here can wedge for that same reason even running a trivial
# grep, with `timeout` unable to kill it. So: NO foreground exec. The set runs
# DETACHED (`-d`); the read-back does not exec at all — ./home is bind-mounted, so we
# grep $RD_TOML directly on the host (host is uid 1000, the file's owner). We re-fire
# on an interval (never killing an in-flight attempt) and check container liveness
# each poll so a dead container fails fast instead of waiting out the timeout.
# DISPLAY is set because the binary may touch the UI; the password rides an inherited
# env var, expanded INSIDE the container (single-quoted bash -c) so it never reaches
# host argv.
log "Setting the RustDesk permanent password..."
export RD_PASSWORD="$PASSWORD"

# If ./home carried a RustDesk password over from a previous deployment (a
# `./teardown.sh` WITHOUT --purge keeps ./home), clear just that one line — keeping
# Haggai's persistent device id/keys — so a non-empty password below unambiguously
# means THIS run's detached setter wrote it, not a leftover (no false positive).
if [ -f "$RD_TOML" ] && grep -Eq "^password = '.+'" "$RD_TOML" 2>/dev/null; then
  log "  (clearing a carried-over RustDesk password so the new one is verifiable)"
  tmp="$(mktemp "${RD_TOML}.XXXXXX")" || die "could not create a temp file next to RustDesk.toml"
  { grep -v '^password = ' "$RD_TOML" > "$tmp" && cat "$tmp" > "$RD_TOML"; } \
    || { rm -f "$tmp"; die "failed to clear the carried-over RustDesk password in $RD_TOML"; }
  rm -f "$tmp"
  ! grep -Eq "^password = '.+'" "$RD_TOML" 2>/dev/null \
    || die "carried-over RustDesk password still present after clearing — aborting"
fi

rd_ok=0
pw_deadline=$(( SECONDS + PW_TIMEOUT ))
last_fire=$(( SECONDS - PW_REFIRE ))      # make the first iteration fire immediately
while [ "$SECONDS" -lt "$pw_deadline" ]; do
  assert_container_running
  if [ $(( SECONDS - last_fire )) -ge "$PW_REFIRE" ]; then
    docker compose exec -d -u 0 -e RD_PASSWORD -e DISPLAY=:99 "$SERVICE" \
      bash -c 'rustdesk --password "$RD_PASSWORD"' >/dev/null 2>&1 || true
    last_fire=$SECONDS
  fi
  sleep "$POLL_SLEEP"
  # Read back on the HOST side of the bind mount — no docker exec, so it can't wedge.
  if grep -Eq "^password = '.+'" "$RD_TOML" 2>/dev/null; then
    rd_ok=1
    break
  fi
done
if [ "$rd_ok" -ne 1 ]; then
  if [ -f "$RD_TOML" ]; then
    warn "RustDesk.toml exists but shows no password — --server is up but is not accepting --password."
  else
    warn "RustDesk.toml was never created — the --server did not initialise its config."
  fi
  docker compose logs --tail=120 2>/dev/null || true
  die "RustDesk password not persisted within ${PW_TIMEOUT}s (diagnostics above). Run ./teardown.sh and retry."
fi
# Clean up the detached client(s) — DETACHED (pkill excludes its own pid), so it
# returns at once and killing the stuck Flutter process can't wedge the host.
docker compose exec -d -u 0 "$SERVICE" pkill -f 'rustdesk --password' >/dev/null 2>&1 || true
log "RustDesk permanent password set and verified."

# ---- set the 'user' Linux / sudo password to the SAME value ----------------
# /etc/shadow is in the container's writable layer (NOT bind-mounted), so this must
# run inside the container — but, per the no-foreground-exec rule, DETACHED. ONE
# detached exec sets the password, self-verifies (passwd -S => P), records a
# diagnostics line (never the password) to $LINUX_LOG, and only on success writes the
# $LINUX_MARK marker. We poll the marker on the HOST, checking liveness each second.
log "Setting the 'user' Linux/sudo password (same value)..."
docker compose exec -d -u 0 -e RD_PASSWORD "$SERVICE" bash -c '
  { printf "user:%s\n" "$RD_PASSWORD" | chpasswd ; } 2>/home/user/.haggai_linux_pw.log
  crc=$?
  st="$(passwd -S user 2>>/home/user/.haggai_linux_pw.log | awk "{print \$2}")"
  echo "chpasswd_rc=$crc passwd_status=$st" >>/home/user/.haggai_linux_pw.log
  [ "$crc" = 0 ] && [ "$st" = P ] && : >/home/user/.haggai_linux_pw_ok
' >/dev/null 2>&1 || true
lin_ok=0
lin_deadline=$(( SECONDS + LINUX_PW_TIMEOUT ))
while [ "$SECONDS" -lt "$lin_deadline" ]; do
  [ -f "$LINUX_MARK" ] && { lin_ok=1; break; }
  assert_container_running
  sleep 1
done
unset RD_PASSWORD
if [ "$lin_ok" -ne 1 ]; then
  [ -f "$LINUX_LOG" ] && { warn "in-container diagnostics:"; sed 's/^/    /' "$LINUX_LOG" >&2 || true; }
  docker compose logs --tail=60 2>/dev/null || true
  die "Linux/sudo password not confirmed within ${LINUX_PW_TIMEOUT}s (diagnostics above). Run ./teardown.sh and retry."
fi
log "Linux/sudo password set and verified."

# ---- final end-state assertions (all host-side) ----------------------------
assert_container_running
hfinal="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER" 2>/dev/null || true)"
[ "$hfinal" = healthy ] || die "container is no longer healthy at the end of provisioning (status: ${hfinal:-unknown})"
grep -Eq "^password = '.+'" "$RD_TOML" 2>/dev/null || die "final check: RustDesk password missing from RustDesk.toml"
ss -ltn 2>/dev/null | awk -v port="$HOST_PORT" '$4 ~ ":"port"$" {found=1} END {exit found?0:1}' \
  || die "final check: host port ${HOST_PORT}/tcp is not listening (port publishing failed?)"
log "Final checks passed: running + healthy, RustDesk password present, ${HOST_PORT}/tcp listening."

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

# Dev-mode notes (printed only when --dev was given).
if [ "$DEV" -eq 1 ]; then
  cat <<EOF
  Dev mode (--dev) is ON:
     * host NVIDIA GPU available inside for CUDA/compute (graphics stay on the CPU, 0 VRAM).
     * 'docker' inside the desktop drives the HOST's Docker (root-equivalent; NOT DinD). It
       is the docker-guard wrapper: it REFUSES publishing a service to the internet on this
       DMZ box and shows the pattern that works. Run 'docker haggai-help' inside for the
       networking model + a private vLLM recipe (use --network container:${CONTAINER}, not -p).
============================================================================
EOF
fi
