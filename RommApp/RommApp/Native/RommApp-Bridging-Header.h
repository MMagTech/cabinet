#import "Libretro/LibretroFrontend.h"
#import "Archive.h"

// PS2 is Mac only and always will be: PCSX2 needs a recompiler, and
// only macOS grants one. The guard is what keeps this file identical
// for iOS, which never sees the header behind it.
#if TARGET_OS_MACCATALYST
#import "../../RommAppMac/PCSX2/CabinetPS2Bridge.h"
#endif
