#include "LibretroCoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// Beetle Saturn's entry points as a table for the shared frontend. The
// core's archive is a single merged object whose only exported symbols
// are these bsat_retro_* forwarders; the real retro_* definitions inside
// it are private, so they cannot collide with FBNeo's. Built by
// tools/build-beetle-saturn.sh.
const LibretroCoreAPI *BeetleSaturnCoreAPI(void);

#ifdef __cplusplus
}
#endif
