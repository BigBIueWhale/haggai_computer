#!/bin/bash
# start-rustdesk.sh — the RustDesk listener (--server) that binds the Direct-IP
# port 21118 (TCP) inside the container, captures the X11 desktop on :99, and (per
# incoming connection) spawns the GUI `--cm` connection-manager onto :99 — which
# is why the Xvfb display is mandatory, not just for screen capture.
#
# HOME=/home/user so the server reads its options from
# ~/.config/rustdesk/RustDesk2.toml and persists the permanent password into
# ~/.config/rustdesk/RustDesk.toml as `user`. XDG_RUNTIME_DIR is the user session
# dir. (On 1.4.7 the IPC socket is uid-scoped: this server owns
# /tmp/<App>-1000/ipc, and setup.sh's root `rustdesk --password` finds it by
# scanning /proc for THIS --server.) Waits for the X server first; fails loud if
# it never appears.
set -euo pipefail
export DISPLAY=:99
export HOME=/home/user
export XDG_RUNTIME_DIR=/run/user/1000

for _ in $(seq 1 150); do
  if xdpyinfo -display :99 >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
xdpyinfo -display :99 >/dev/null 2>&1 \
  || { echo "start-rustdesk: X server :99 never became ready" >&2; exit 1; }

exec /usr/share/rustdesk/rustdesk --server
