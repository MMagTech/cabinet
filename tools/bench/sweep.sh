#!/bin/sh
# Every eligible core, both option sets, one row of numbers each.
# Usage: tools/bench/sweep.sh [seconds]
SECS=${1:-40}
cd "$(dirname "$0")/../.."
# romId coreName  (one representative kept game per eligible core)
set -- \
  "383 fceumm" \
  "234 snes9x" \
  "12 gambatte" \
  "2814 gambatte_gbc" \
  "52 mgba" \
  "480 genesisPlusGX" \
  "701 genesisPlusGX_gg" \
  "668 genesisPlusGX_cd" \
  "513 beetlePCEFast" \
  "221 picoDrive" \
  "1108 beetleNGP" \
  "2214 prosystem" \
  "738 fbneo" \
  "662 beetleSaturn" \
  "322 pcsxReARMed"
for entry in "$@"; do
  set -- $entry
  rom=$1; label=$2
  core=$(echo "$label" | cut -d_ -f1)
  for mode in stock tuned; do
    # The label, not the core name, decides the output file: several rows
    # share one core (Genesis/Game Gear/Sega CD are all genesisPlusGX), and
    # naming by core meant the later row's copy overwrote the earlier row's
    # results before they were renamed.
    out=$(CABINET_BENCH_OUT=/tmp/cabinet-bench sh tools/bench/device_bench.sh "$rom" "$core" "$SECS" "$mode" "$label" 2>/dev/null)
    if [ -f "$out" ]; then
      echo "ok   $label $mode"
    else
      echo "MISS $label $mode"
    fi
  done
done
