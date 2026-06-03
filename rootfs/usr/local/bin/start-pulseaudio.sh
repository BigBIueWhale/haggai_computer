#!/bin/bash
# start-pulseaudio.sh — headless audio so the desktop has a working sink/source
# and RustDesk can relay sound. There is no sound hardware in the container, so we
# load ONLY explicit virtual devices (-n, no udev hardware probing) for reliability.
set -euo pipefail
exec /usr/bin/pulseaudio -n \
  --exit-idle-time=-1 \
  --disallow-exit \
  --log-target=stderr \
  --load=module-native-protocol-unix \
  --load="module-null-sink sink_name=virtual_speaker sink_properties=device.description=Virtual_Speaker" \
  --load="module-null-source source_name=virtual_mic source_properties=device.description=Virtual_Mic"
