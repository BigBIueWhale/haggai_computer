#!/bin/bash
# start-kde.sh — KDE Plasma 5 on the Xvfb X11 display, under a fresh D-Bus
# session bus. Plasma stays on X11 because the hardened RustDesk build captures
# X11 directly and deliberately has no Wayland/portal path.
set -euo pipefail
export DISPLAY=:99
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=KDE
export KDE_FULL_SESSION=true
export KDE_SESSION_VERSION=5
export QT_QPA_PLATFORM=xcb
export GDK_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1

for _ in $(seq 1 150); do
  if xdpyinfo -display :99 >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
xdpyinfo -display :99 >/dev/null 2>&1 \
  || { echo "start-kde: X server :99 never became ready" >&2; exit 1; }

# Plasma and some apps may reapply X11 idle settings while the session starts.
# Reassert no blanking throughout initialization so remote users never return to
# a black framebuffer. KDE's own lock/power settings are also seeded off.
( for _ in $(seq 1 15); do xset s off s noblank -dpms 2>/dev/null || true; sleep 4; done ) &

exec dbus-run-session -- startplasma-x11
