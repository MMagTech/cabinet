#!/bin/sh
# Builds the headless bench harness against the app's own libretro.h, so the
# environment constants it answers are exactly the ones the app answers.
set -e
cd "$(dirname "$0")/../../.."
cc -O2 -Wall -Wextra -I RommApp/RommApp/Native/Libretro \
   -o tools/lab/bench/libretro_bench tools/lab/bench/libretro_bench.c
echo "Wrote tools/lab/bench/libretro_bench"
