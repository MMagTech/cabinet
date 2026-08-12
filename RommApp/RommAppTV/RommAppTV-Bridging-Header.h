// tvOS's own bridging header, the sibling of
// RommApp/RommApp/Native/RommApp-Bridging-Header.h.
//
// LibretroFrontend.h carries the LibretroCoreID enum NativeCore.swift's
// `coreID` property returns, and the frontend interface TVPlayerView
// drives. Archive.h carries archive_extract_first_file, which
// NativeLauncher needs for every cartridge platform RomM serves zipped
// (most of them): both now build for tvOS, so both belong here.
#import "../RommApp/Native/Libretro/LibretroFrontend.h"
#import "../RommApp/Native/Archive/Archive.h"
