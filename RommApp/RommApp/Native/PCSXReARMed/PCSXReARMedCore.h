#include "LibretroCoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// PCSX ReARMed's entry points as a table for the shared frontend. The
// core's archive is a single merged object whose only exported symbols
// are these psx_retro_* forwarders; the real retro_* definitions
// inside it are private, so they cannot collide with any other core's.
// Built by tools/build-core.sh with platform=ios-arm64, which the
// core's own Makefile forces to DYNAREC=0, a pure interpreter build.
// This is a go/no-go, not a batch-confidence core like the other ten:
// verify real device speed per title before trusting it generally.
const LibretroCoreAPI *PCSXReARMedCoreAPI(void);

#ifdef __cplusplus
}
#endif
