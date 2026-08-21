#!/bin/sh
# Checks the bundled arcade layouts still match ArcadeLayout's generator.
# Run after regenerating them, and after any edit to ArcadeLayout.swift.
# A tuned file SHOULD eventually differ (that is the point of editing it);
# this exists so an ACCIDENTAL difference is never silent.
set -e
cd "$(dirname "$0")/../../.."
SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
OUT=/tmp/cabinet-arcade-verify
# Swift only allows top level code in a file called main.swift, and this
# station's entry point cannot be called that in the repository without
# colliding with the generator's own main.swift next to it. Staged under
# the required name instead of renaming either file.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp tools/lab/arcade/verify-main.swift "$STAGE/main.swift"
xcrun swiftc -sdk "$SDK" -target arm64-apple-ios17.0-simulator \
  RommApp/RommApp/Controls/ControlLayout.swift \
  RommApp/RommApp/Controls/ControllerBindings.swift \
  RommApp/RommApp/Controls/ArcadeProfiles.swift \
  RommApp/RommApp/Controls/AnalogControls.swift \
  RommApp/RommApp/Controls/ArcadeLayout.swift \
  "$STAGE/main.swift" \
  -o "$OUT"
BOOTED=$(xcrun simctl list devices booted | grep -o '[A-F0-9-]\{36\}' | head -1)
[ -n "$BOOTED" ] || { echo "boot an iPhone simulator first"; exit 1; }
xcrun simctl spawn "$BOOTED" "$OUT" "$PWD/RommApp/RommApp/Resources/ControlLayouts"
