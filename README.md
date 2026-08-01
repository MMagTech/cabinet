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

Pre-release. Nothing works yet.

## Tools

`tools/mame_profiles.py` builds the arcade control profile map from MAME's
listxml. See the docstring for usage.

## Licence

MIT. Note that bundling EmulatorJS for offline play (Phase 2) would bring
GPLv3 into scope, so revisit before doing that.
