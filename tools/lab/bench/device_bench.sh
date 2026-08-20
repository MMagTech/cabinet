#!/bin/sh
# One measured run of one kept game on the iPhone, start to numbers.
#
# Usage: tools/lab/bench/device_bench.sh <romId> <coreName> <seconds> [stock] 
#   stock: pass "stock" to run with the pre-2026-08-17 core options, for A/B.
#
# Needs the DEBUG build installed; see NativeBenchHarness for the contract.
set -e
DEVICE=${CABINET_BENCH_DEVICE:-4B536CB7-E086-5C97-AA3F-6C38C6395301}
BUNDLE=com.mmagtech.CabinetDev
ROM=$1; CORE=$2; SECS=${3:-30}; MODE=${4:-tuned}; LABEL=${5:-$CORE}
OUT=${CABINET_BENCH_OUT:-/tmp/cabinet-bench}
mkdir -p "$OUT"

ARGS="-cabinetBench $ROM -cabinetBenchSeconds $SECS"
[ "$MODE" = stock ] && ARGS="$ARGS -cabinetBenchStockOptions 1"

xcrun devicectl device process launch --terminate-existing --console --device "$DEVICE" \
  "$BUNDLE" -- $ARGS > "$OUT/$LABEL-$MODE.log" 2>&1 || true

# A run that never started must never look like a run that did. The trace
# file for a core persists on the device between runs, so a failed launch
# followed by a copy hands back the PREVIOUS run's numbers with nothing to
# distinguish them. That is not hypothetical: on 2026-08-17 the iPhone
# auto-locked partway through a batch, every later launch failed with
# "the device was not, or could not be, unlocked", and every one of them
# copied a stale trace that compared as a clean no-change result.
if ! grep -q "exit code 0" "$OUT/$LABEL-$MODE.log"; then
  echo "FAILED $LABEL $MODE: $(grep -o 'NSLocalizedFailureReason = [^;]*' "$OUT/$LABEL-$MODE.log" | head -1)" >&2
  exit 1
fi

xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" --source "Library/Caches/frame-trace-$CORE.csv" \
  --destination "$OUT/$LABEL-$MODE.csv" >/dev/null 2>&1

echo "$OUT/$LABEL-$MODE.csv"
