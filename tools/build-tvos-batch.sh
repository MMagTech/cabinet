#!/bin/sh
# Overnight batch: rebuild the tvOS-confirmed cores one at a time, deleting
# each core's cloned source immediately after a successful build so disk
# usage never holds more than one core's checkout at once. mGBA, FBNeo, and
# Beetle Saturn are deliberately excluded: mGBA's CMake build has no
# confirmed tvOS support (unlike the other eight, whose upstream Makefiles
# already have a real tvos-arm64 case), and FBNeo/Saturn use their own
# non-generic build scripts that have not been checked for tvOS support yet.
set -e
cd "$(dirname "$0")/.."

CORES="gambatte genesis_plus_gx beetle_pce_fast snes9x fceumm beetle_ngp prosystem picodrive"
LOG=/tmp/tvos-core-batch.log
: > "$LOG"

for core in $CORES; do
    echo "=== $core ===" | tee -a "$LOG"
    if ./tools/build-core.sh "$core" tvos >> "$LOG" 2>&1; then
        echo "$core: OK" | tee -a "$LOG"
    else
        echo "$core: FAILED, see $LOG" | tee -a "$LOG"
    fi
    rm -rf "spikes/cores/${core}-tvos"
done

echo "=== batch done ===" | tee -a "$LOG"
ls -la RommApp/RommApp/Native/*/lib*_tvos.a 2>&1 | tee -a "$LOG"
