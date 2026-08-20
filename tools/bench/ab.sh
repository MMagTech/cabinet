#!/bin/sh
# A/B one core option against the same core+rom. Prints both runs' key numbers
# side by side so "did it change the output" and "what did it cost" are one
# command, not a spreadsheet exercise.
#
# Usage: tools/bench/ab.sh <core.dylib> <rom> <frames> [-- baseline opts] [-- variant opts]
