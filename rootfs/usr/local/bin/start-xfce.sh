#!/bin/bash
# start-xfce.sh — the XFCE desktop session, under a fresh D-Bus session bus.
# Waits for Xvfb (:99) to accept connections first, and fails loud if it never
# does (rather than silently starting a broken session). startxfce4 blocks until
# the session ends, so supervisord supervises it directly.
set -euo pipefail
export DISPLAY=:99

for _ in $(seq 1 150); do
  if xdpyinfo -display :99 >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
xdpyinfo -display :99 >/dev/null 2>&1 \
  || { echo "start-xfce: X server :99 never became ready" >&2; exit 1; }

# Headless RustDesk desktop: the framebuffer must NEVER blank. The X server's
# screen-saver is already disabled at the server level (start-xvfb.sh's `-s 0`), but
# XFCE's session startup resets the saver to the X default (600s) ONCE during init.
# So, from a background loop, re-assert "off" across the first ~40s: our last write
# lands after that one-time reset, after which it stays off (verified by observation)
# — and the saver could not fire until 600s of inactivity regardless. `xset` needs
# only DISPLAY (already exported), so this needs no session bus. Best-effort: the
# desktop must come up whether or not these succeed.
( for _ in $(seq 1 10); do xset s off s noblank 2>/dev/null || true; sleep 4; done ) &
exec dbus-launch --exit-with-session startxfce4
