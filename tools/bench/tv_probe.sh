#!/bin/sh
# One option-override run against the Apple TV. Mirrors wave2.sh.
set -e
DEVICE=${CABINET_TV_DEVICE:-539DFD4E-FAAB-56D5-A39D-34D941DA2754}
BUNDLE=com.mmagtech.CabinetDev.tv
ROM=$1; CORE=$2; LABEL=$3; OPTS=$4; SECS=${5:-40}
OUT=/tmp/cabinet-tv2; mkdir -p "$OUT"
xcrun devicectl device process launch --terminate-existing --console --device "$DEVICE" \
  "$BUNDLE" -- -cabinetBench "$ROM" -cabinetBenchSeconds "$SECS" -cabinetBenchOption "$OPTS" \
  > "$OUT/$LABEL.log" 2>&1 || true
if ! grep -q "exit code 0" "$OUT/$LABEL.log"; then
  echo "FAILED $LABEL: $(grep -o 'NSLocalizedFailureReason = [^;]*' "$OUT/$LABEL.log" | head -1)" >&2; exit 1
fi
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" --source "Library/Caches/frame-trace-$CORE.csv" \
  --destination "$OUT/$LABEL.csv" >/dev/null 2>&1
echo "$OUT/$LABEL.csv"
