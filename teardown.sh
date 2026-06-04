#!/usr/bin/env bash
# =============================================================================
# teardown.sh — the explicit, destructive reset for Haggai's container.
#
#   ./teardown.sh            Stop + remove the container (and its writable layer).
#                            Haggai's `sudo apt install` packages and any system
#                            changes are DISCARDED. His files under ./home are
#                            KEPT, and the built image is kept (fast re-setup).
#
#   ./teardown.sh --purge    All of the above, PLUS permanently delete ./home
#                            (ALL of Haggai's files). Irreversible. Requires
#                            typing DELETE to confirm.
#
# Normal reboots/restarts do NOT need this — the container is persistent and comes
# back on its own (see README "Persistence"). This is only for a deliberate reset.
# =============================================================================
set -euo pipefail

CONTAINER=haggai_computer
BASE_IMAGE=ubuntu:24.04
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$SCRIPT_DIR/home"

log()  { printf '\033[1;32m[teardown]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[teardown]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[teardown] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

PURGE=0
case "${1:-}" in
  "")        PURGE=0 ;;
  --purge)   PURGE=1 ;;
  *)
    cat >&2 <<EOF
Usage: ./teardown.sh [--purge]

  (no args)   Stop + remove the container. Discards Haggai's installed packages /
              system changes, but KEEPS ./home and the built image.
  --purge     Also permanently delete ./home (ALL of Haggai's files). Irreversible;
              requires typing DELETE.
EOF
    exit 2 ;;
esac

command -v docker >/dev/null 2>&1            || die "docker not found on PATH"
docker compose version >/dev/null 2>&1       || die "the Docker Compose v2 plugin is required"
[ -f "$SCRIPT_DIR/docker-compose.yml" ]      || die "docker-compose.yml not found next to teardown.sh"
cd "$SCRIPT_DIR"

if [ "$PURGE" -eq 1 ]; then
  warn "PURGE will remove the container AND permanently delete every file under"
  warn "    $HOME_DIR"
  warn "This cannot be undone."
  printf 'Type exactly DELETE to proceed: '
  read -r reply
  [ "$reply" = "DELETE" ] || die "not confirmed (you typed '${reply}') — nothing was changed"
fi

# Remove the container (+ compose network). Idempotent: a no-op if already gone.
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  warn "Removing the container — its writable layer (Haggai's apt installs, /tmp,"
  warn "    /etc changes, etc.) will be discarded. ./home is NOT touched here."
fi
log "docker compose down ..."
docker compose down --remove-orphans

if [ "$PURGE" -eq 1 ]; then
  if [ -d "$HOME_DIR" ]; then
    # Delete as root inside a throwaway container so that any root-owned files
    # Haggai created via `sudo` are also removed. The ./home directory itself is
    # preserved (it is the bind-mount target for the next ./setup.sh).
    log "Deleting all contents of ./home (as root, to catch root-owned files)..."
    docker run --rm -v "$HOME_DIR":/purge "$BASE_IMAGE" find /purge -mindepth 1 -delete
  fi
  log "Purge complete. ./home is empty. Re-create with: ./setup.sh <password>"
  log "(The built image was kept for a fast rebuild. To reclaim its disk space:"
  log "   docker image rm haggai_computer:1.4.7 )"
else
  log "Done. The container is gone; ./home and the image are intact."
  log "Re-deploy with: ./setup.sh <password>"
fi
