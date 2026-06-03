#!/bin/bash
# start-xvfb.sh — the virtual X11 display (:99) the whole desktop renders into.
# Pure software framebuffer; this container never touches the NVIDIA GPU.
# 1920x1080x24, with RANDR/RENDER/GLX so XFCE and apps are happy. No TCP listener.
set -euo pipefail
exec Xvfb :99 \
  -screen 0 1920x1080x24 \
  -ac \
  +extension RANDR \
  +extension RENDER \
  +extension GLX \
  -nolisten tcp
