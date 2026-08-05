# romm-ios

An iOS client for a self-hosted [RomM](https://github.com/rommapp/romm) instance.

## Why

RomM's web player works, but Safari on iPhone has no Fullscreen API for
arbitrary elements, which is why RomM ships an iOS pseudo-fullscreen shim. A
native app has no browser chrome to hide, so fullscreen is simply the default
state. It also gets proper touch controls, physical controller support, and
one-tap resume.

## Architecture

Native SwiftUI shell, `WKWebView` player running EmulatorJS.

The app never emulates natively. WKWebView's WebContent process carries the
dynamic code signing entitlement, so WASM cores get a real JIT; the same cores
compiled into the app process would be interpreter-only.

See [docs/scope-v0.1.md](docs/scope-v0.1.md) for the full design.

## Status

Pre-release. Under active development, not yet feature complete.

## Requirements

- Xcode 16 or later
- iOS 17+ device or simulator
- A running RomM instance to connect to (see [romm.app](https://romm.app))

## Building

1. Clone the repo and open `RommApp/RommApp.xcodeproj` in Xcode.
2. Select the `RommApp` target, then in Signing & Capabilities switch the team
   to your own Apple ID or developer account. The project ships with the
   maintainer's team ID, which won't work for anyone else.
3. Build and run on a simulator, or on a physical device if you want a real
   dynamic-code-signing JIT (the simulator doesn't need the entitlement).
4. On first launch, enter your RomM server URL and complete the device
   authorization flow. No credentials are stored in the app; auth is handled
   entirely by RomM's own device flow.

## Tools

`tools/mame_profiles.py` builds the arcade control profile map from MAME's
listxml. See the docstring for usage.

## Licence

MIT. Note that bundling EmulatorJS for offline play (Phase 2) would bring
GPLv3 into scope, so revisit before doing that.
