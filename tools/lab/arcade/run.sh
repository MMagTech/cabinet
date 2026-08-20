#!/bin/sh
# Regenerates the arcade layout JSONs from the player's own generator.
# Only needed when ArcadeLayout.swift's geometry changes; the files it
# writes are the ones the app and the LayoutEditor both read, so running
# this DISCARDS any hand tuning done in the editor. Check git diff after.
set -e
cd "$(dirname "$0")/../../.."
SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
OUT=/tmp/cabinet-arcade-dump
xcrun swiftc -sdk "$SDK" -target arm64-apple-ios17.0-simulator \
  RommApp/RommApp/Controls/ControlLayout.swift \
  RommApp/RommApp/Controls/ControllerBindings.swift \
  RommApp/RommApp/Controls/ArcadeProfiles.swift \
  RommApp/RommApp/Controls/ArcadeLayout.swift \
  RommApp/LayoutEditor/EditableLayout.swift \
  tools/lab/arcade/main.swift \
  -o "$OUT"
BOOTED=$(xcrun simctl list devices booted | grep -o '[A-F0-9-]\{36\}' | head -1)
[ -n "$BOOTED" ] || { echo "boot an iPhone simulator first"; exit 1; }
xcrun simctl spawn "$BOOTED" "$OUT" "$PWD/RommApp/RommApp/Resources/ControlLayouts"
