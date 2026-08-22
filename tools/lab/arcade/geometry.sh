#!/bin/sh
# Asserts that no generated arcade panel draws one control on top of
# another, and that no analog control's hit frame swallows a button.
#
# Compiles the app's own ArcadeLayout and measures what it produces, so
# this cannot drift from what ships. Swift requires top level code to
# live in a file called main.swift, hence the copy.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-$(cd "$HERE/../../.." && pwd)}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$HERE/geometry-main.swift" "$WORK/main.swift"
swiftc -O \
    "$REPO/RommApp/RommApp/Controls/ArcadeLayout.swift" \
    "$REPO/RommApp/RommApp/Controls/ControlLayout.swift" \
    "$REPO/RommApp/RommApp/Controls/ArcadeProfiles.swift" \
    "$REPO/RommApp/RommApp/Controls/AnalogControls.swift" \
    "$REPO/RommApp/RommApp/Controls/ControllerBindings.swift" \
    "$WORK/main.swift" -o "$WORK/geometry" 2>&1 | grep -E "error:" && exit 2
# The bundled layout files have to be reachable: a tuned panel that wins
# over the generator must be measured, not skipped.
cp "$REPO"/RommApp/RommApp/Resources/ControlLayouts/*.json "$WORK/" 2>/dev/null || true
cp "$REPO"/RommApp/RommApp/Resources/ArcadeProfiles/*.json "$WORK/" 2>/dev/null || true
cp "$REPO"/RommApp/RommApp/Resources/analog-controls.json "$WORK/" 2>/dev/null || true
cd "$WORK" && ./geometry
