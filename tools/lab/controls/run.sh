#!/bin/sh
# Builds the controls harness against the REAL Controls sources for the
# iOS simulator and runs it there headless. Green exit 0. Needs a booted
# simulator (any iPhone); boots the first available one if none is.
set -e
cd "$(dirname "$0")/../../.."

SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
OUT=/tmp/cabinet-controls-test
xcrun swiftc \
  -sdk "$SDK" -target arm64-apple-ios17.0-simulator \
  -D DEBUG \
  RommApp/RommApp/Controls/ControllerBindings.swift \
  RommApp/RommApp/Controls/GameControllerManager.swift \
  tools/lab/controls/FrontendStub.swift \
  tools/lab/controls/main.swift \
  -o "$OUT"

BOOTED=$(xcrun simctl list devices booted | grep -o '[A-F0-9-]\{36\}' | head -1)
if [ -z "$BOOTED" ]; then
  BOOTED=$(xcrun simctl list devices available | grep 'iPhone' | grep -o '[A-F0-9-]\{36\}' | head -1)
  xcrun simctl boot "$BOOTED"
fi
xcrun simctl spawn "$BOOTED" "$OUT"
