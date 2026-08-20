#!/bin/sh
# The same sweep as sweep.sh, against the Apple TV. Separate script rather
# than a flag because the bundle id differs (.tv suffix) and because the
# rom list is not limited to kept games here: tvOS has no kept-games mirror
# at all, so every title is fetched, which the harness now supports.
SECS=${1:-40}
cd "$(dirname "$0")/../../.."
DEVICE=${CABINET_TV_DEVICE:-539DFD4E-FAAB-56D5-A39D-34D941DA2754}
BUNDLE=com.mmagtech.CabinetDev.tv
OUT=${CABINET_BENCH_OUT:-/tmp/cabinet-tv}
mkdir -p "$OUT"
set -- "383 fceumm" "234 snes9x" "246 snes9x_fzero" "12 gambatte" "52 mgba" \
       "480 genesisPlusGX" "504 genesisPlusGX_tf3" "513 beetlePCEFast" \
       "221 picoDrive" "1108 beetleNGP" "2214 prosystem" "738 fbneo" \
       "662 beetleSaturn" "322 pcsxReARMed"
for entry in "$@"; do
  set -- $entry; rom=$1; label=$2; core=$(echo "$label" | cut -d_ -f1)
  for mode in stock tuned; do
    args="-cabinetBench $rom -cabinetBenchSeconds $SECS"
    [ "$mode" = stock ] && args="$args -cabinetBenchStockOptions 1"
    xcrun devicectl device process launch --terminate-existing --console \
      --device "$DEVICE" "$BUNDLE" -- $args > "$OUT/$label-$mode.log" 2>&1 || true
    if ! grep -q "exit code 0" "$OUT/$label-$mode.log"; then
      echo "FAIL $label $mode: $(grep -o 'NSLocalizedFailureReason = [^;]*' "$OUT/$label-$mode.log" | head -1)"
      continue
    fi
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source "Library/Caches/frame-trace-$core.csv" \
      --destination "$OUT/$label-$mode.csv" >/dev/null 2>&1
    echo "ok   $label $mode"
  done
done
