#!/bin/bash
# start-xvfb.sh — the virtual X11 display (:99) the whole desktop renders into.
# Pure software framebuffer; this container never touches the NVIDIA GPU.
# 1920x1080x24, with RANDR/RENDER/GLX so KDE and apps are happy. No TCP listener.
#
# `-s 0` disables the X screen-saver at the SERVER level. Verified empirically that
# for Xvfb this means "timeout 0 = never blank" (not the "blank immediately" myth).
# This is a headless desktop streamed by RustDesk, so a blanked framebuffer would
# only ever show a remote user a black screen after the idle timeout. Setting it on
# the server command line makes "no blanking" the default from the first frame —
# race-free, with nothing to re-enable later. (Xvfb exposes no DPMS extension, so
# there is no DPMS-based blanking to disable.)
set -euo pipefail
exec Xvfb :99 \
  -screen 0 1920x1080x24 \
  -ac \
  -s 0 \
  +extension RANDR \
  +extension RENDER \
  +extension GLX \
  -nolisten tcp
