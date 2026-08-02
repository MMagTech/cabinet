#!/bin/bash
# Screenshot the booted simulator, upright.
#
#   tools/shot.sh [output.png]
#
# The simulator always writes portrait pixels regardless of how the device is
# oriented, so a landscape screen arrives rotated a quarter turn. Reading it
# that way means doing coordinate arithmetic by hand and misjudging layouts,
# which is exactly how several landscape screens got shipped wrong. This
# rotates it back first.
set -e

OUT="${1:-/tmp/sim-shot.png}"
UDID="${SIM_UDID:-booted}"

xcrun simctl io "$UDID" screenshot "$OUT" >/dev/null 2>&1

W=$(sips -g pixelWidth "$OUT" | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$OUT" | awk '/pixelHeight/{print $2}')

# Taller than wide means the device is in landscape and the image needs
# turning. A genuinely portrait screen is left alone.
if [ "$H" -gt "$W" ] && [ -n "${LANDSCAPE:-1}" ]; then
    sips -r 90 "$OUT" >/dev/null 2>&1
fi

sips -Z "${MAXDIM:-1100}" "$OUT" >/dev/null 2>&1
echo "$OUT"
sips -g pixelWidth -g pixelHeight "$OUT" | tail -2
