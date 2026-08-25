#!/bin/sh
# Regenerates the analog arcade panel layouts (dial, trackball, rotary,
# light gun, pedals) from the player's own generator, one file per panel
# shape that a real cabinet in the data actually has.
#
# Refuses to write if two cabinets resolve to the same file but need
# different panels. Running this DISCARDS hand tuning in those files, so
# check git diff after.
set -e
cd "$(dirname "$0")/../../.."
SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
OUT=/tmp/cabinet-arcade-panels
RES=RommApp/RommApp/Resources
xcrun swiftc -sdk "$SDK" -target arm64-apple-ios17.0-simulator \
  RommApp/RommApp/Controls/ControlLayout.swift \
  RommApp/RommApp/Controls/ControllerBindings.swift \
  RommApp/RommApp/Controls/ArcadeProfiles.swift \
  RommApp/RommApp/Controls/AnalogControls.swift \
  RommApp/RommApp/Controls/ArcadeLayout.swift \
  RommApp/LayoutEditor/EditableLayout.swift \
  tools/lab/arcade/panels/main.swift \
  -o "$OUT"
BOOTED=$(xcrun simctl list devices booted | grep -o '[A-F0-9-]\{36\}' | head -1)
[ -n "$BOOTED" ] || { echo "boot an iPhone simulator first"; exit 1; }
xcrun simctl spawn "$BOOTED" "$OUT" \
  "$PWD/$RES/ControlLayouts" \
  "$PWD/$RES/ArcadeProfiles/profiles.json" \
  "$PWD/$RES/ArcadeProfiles/arcade-panels.json" \
  "$PWD/$RES/analog-controls.json"
