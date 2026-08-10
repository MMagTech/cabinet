// tvOS's own bridging header, trimmed from RommApp/RommApp/Native/RommApp-Bridging-Header.h.
//
// Only LibretroFrontend.h is pulled in, for the LibretroCoreID enum that
// NativeCore.swift's `coreID` property returns (NativeCore.swift is shared
// with tvOS since KeptGameStore depends on it). The Objective-C++
// implementation behind that header (LibretroFrontend.mm) and the twelve
// per-core static libraries are iOS-only in this pass, so nothing here
// actually needs to resolve at link time. Archive.h is left out entirely:
// its one caller, NativeLauncher's archive extraction path, is guarded
// #if os(iOS) for the same reason.
#import "../RommApp/Native/Libretro/LibretroFrontend.h"
