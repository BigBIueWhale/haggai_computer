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

exec dbus-launch --exit-with-session startxfce4
