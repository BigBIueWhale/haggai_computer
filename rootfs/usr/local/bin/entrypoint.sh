#!/bin/bash
# =============================================================================
# entrypoint.sh — container PID-1 work (runs as root), then hand off to
# supervisord. Idempotent and seed-if-absent ONLY: safe to run on every
# (re)start, never clobbers Haggai's edits or his installed packages. This is
# why a reboot/restart never resets state.
# =============================================================================
set -euo pipefail

USER_UID=1000
USER_GID=1000
USER_HOME=/home/user
RUNTIME_DIR="/run/user/${USER_UID}"
SKEL=/etc/haggai/skel

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

# Strict sanity: the image must actually contain what we are about to run.
[ -x /usr/share/rustdesk/rustdesk ] || die "rustdesk binary missing from image"
command -v supervisord >/dev/null 2>&1 || die "supervisord missing from image"
[ -f /etc/supervisor/haggai.conf ]   || die "supervisor config missing from image"
[ -f "$SKEL/rustdesk/RustDesk2.toml" ] || die "RustDesk skel config missing from image"
[ -f "$SKEL/codex/config.toml" ]       || die "Codex skel config missing from image"

# 1) Per-user XDG runtime dir (D-Bus session, PulseAudio, RustDesk IPC socket).
install -d -m 0700 -o "$USER_UID" -g "$USER_GID" "$RUNTIME_DIR"

# 1b) X11/ICE socket dirs. Xvfb runs as the unprivileged user and cannot create
#     /tmp/.X11-unix itself (it logs "euid != 0, ... will not be created" and falls
#     back to the abstract socket only). Pre-create them sticky + world-writable, as
#     root, so the standard filesystem X sockets exist. (/tmp is the container's
#     writable layer, so this is re-asserted, idempotently, on every (re)start.)
install -d -m 1777 /tmp/.X11-unix /tmp/.ICE-unix

# 1c) Optional host-Docker mode: when the host's Docker socket is bind-mounted in (the
#     `./setup.sh --host-docker` deployment), grant `user` access to it by matching
#     its group — create a group with the socket's gid if the image has none, then add
#     `user`. supervisord's setuid/initgroups gives the desktop session that group, so
#     `docker` works without sudo inside. Entirely SKIPPED when the socket isn't
#     mounted, i.e. Haggai's default deployment — so his image/runtime is unchanged.
if [ -S /var/run/docker.sock ]; then
  sock_gid="$(stat -c %g /var/run/docker.sock)"
  getent group "$sock_gid" >/dev/null 2>&1 || groupadd -g "$sock_gid" hostdocker
  sock_grp="$(getent group "$sock_gid" | head -1 | cut -d: -f1)"
  usermod -aG "$sock_grp" user
  log "host Docker socket present — added 'user' to group '$sock_grp' (gid $sock_gid)"
fi

# 2) Ensure the (bind-mounted) home itself is owned by the user. Non-recursive on
#    purpose: never rewrite ownership/perms of Haggai's own files underneath.
install -d -o "$USER_UID" -g "$USER_GID" "$USER_HOME"
chown "$USER_UID:$USER_GID" "$USER_HOME"

# 3) Config dirs the seeds/programs need, owned by the user.
for d in .config .config/rustdesk .codex; do
  install -d -m 0700 -o "$USER_UID" -g "$USER_GID" "$USER_HOME/$d"
done

# Seed a file into the home only if it is absent (so edits persist), user-owned.
seed() {  # seed <src> <dest>   (dest's directory must already exist)
  local src=$1 dest=$2
  if [ ! -e "$dest" ]; then
    install -o "$USER_UID" -g "$USER_GID" -m 0644 "$src" "$dest"
    log "seeded $dest"
  fi
}

# 4) Shell dotfiles — the home is a fresh bind-mount, so /etc/skel never populated it.
for f in .bashrc .profile .bash_logout; do
  [ -e "/etc/skel/$f" ] && seed "/etc/skel/$f" "$USER_HOME/$f"
done

# 5) RustDesk options (direct-server / full access / software codec) and the
#    Codex in-container sandbox config. Seeded once; Haggai owns them thereafter.
seed "$SKEL/rustdesk/RustDesk2.toml" "$USER_HOME/.config/rustdesk/RustDesk2.toml"
seed "$SKEL/codex/config.toml"       "$USER_HOME/.codex/config.toml"

# 6) Hand off. supervisord becomes the long-running process and manages the stack.
log "starting supervisord"
exec supervisord -c /etc/supervisor/haggai.conf
