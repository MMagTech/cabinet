#!/bin/sh
# Measure one candidate option against the shipping defaults on device.
# Usage: tools/bench/wave2.sh <romId> <coreName> <label> "<key=value;key=value>" [seconds]
set -e
DEVICE=${CABINET_BENCH_DEVICE:-4B536CB7-E086-5C97-AA3F-6C38C6395301}
BUNDLE=com.mmagtech.CabinetDev
ROM=$1; CORE=$2; LABEL=$3; OPTS=$4; SECS=${5:-40}
OUT=/tmp/cabinet-wave2
mkdir -p "$OUT"
xcrun devicectl device process launch --terminate-existing --console --device "$DEVICE" \
  "$BUNDLE" -- -cabinetBench "$ROM" -cabinetBenchSeconds "$SECS" -cabinetBenchOption "$OPTS" \
  > "$OUT/$LABEL.log" 2>&1 || true
# See device_bench.sh: a failed launch leaves the previous run's trace on
# the device, and copying it produces a convincing no-change result.
if ! grep -q "exit code 0" "$OUT/$LABEL.log"; then
  echo "FAILED $LABEL: $(grep -o 'NSLocalizedFailureReason = [^;]*' "$OUT/$LABEL.log" | head -1)" >&2
  exit 1
fi
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" --source "Library/Caches/frame-trace-$CORE.csv" \
  --destination "$OUT/$LABEL.csv" >/dev/null 2>&1
echo "$OUT/$LABEL.csv"
