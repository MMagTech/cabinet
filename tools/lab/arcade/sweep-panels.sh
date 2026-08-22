#!/bin/sh
# Ask the core what every game in a romset actually reads.
#
# Cabinet's arcade panels were inferred for a long time: from a modern
# MAME listxml, then from that core's own generation, then corrected by
# hand when someone played a game and found the panel wrong. All three
# are guesses about a binary that is sitting right here and can be asked
# directly. MAME 2003-Plus publishes retro_input_descriptors per game,
# naming every control the driver reads, and it will do that for all
# 4,892 sets in about as long as it takes to make coffee.
#
# Usage: sweep-panels.sh <romdir> <core.dylib> <out.tsv> [jobs]
#
# Output is one DESC line per control, tab separated, which
# panels_from_sweep.py folds into the panel map. Games that fail to load
# are recorded rather than dropped: a set this core cannot run is a fact
# worth keeping, not a gap to be silent about.
set -e
ROMS=${1:?romdir}
CORE=${2:?core dylib}
OUT=${3:?output tsv}
JOBS=${4:-8}
HERE=$(cd "$(dirname "$0")" && pwd)
BENCH="$HERE/../bench/libretro_bench"
[ -x "$BENCH" ] || sh "$HERE/../bench/build.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Each worker gets its own system directory: the core writes nvram and
# config on unload, and eight processes sharing one directory is a race
# that would show up later as an unexplained difference between runs.
export BENCH CORE WORK ROMS

ls "$ROMS"/*.zip | wc -l | sed 's/^/sets to ask: /'
# Paths go through the environment rather than being interpolated into
# the -I{} template: expanded inline they overran the argument limit and
# xargs refused the whole run.
ls "$ROMS"/*.zip | xargs -P "$JOBS" -I{} sh -c '
    rom="$1"
    name=$(basename "$rom" .zip)
    sys="$WORK/sys.$$"
    mkdir -p "$sys"
    if out=$("$BENCH" "$CORE" "$rom" -P -f 2 -s "$sys" 2>/dev/null); then
        printf "%s\n" "$out" | sed "s|\t.*/roms/|\t|g"
    else
        printf "FAILED\t%s.zip\n" "$name"
    fi
' _ {} > "$OUT"
echo "wrote $OUT"
