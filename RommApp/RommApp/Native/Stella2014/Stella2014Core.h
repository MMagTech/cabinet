#include "LibretroCoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// Stella 2014's entry points as a table for the shared frontend. The
// core's archive is a single merged object whose only exported symbols
// are these a26_retro_* forwarders; the real retro_* definitions inside
// it are private, so they cannot collide with any other core's. Built
// by tools/build-core.sh.
const LibretroCoreAPI *Stella2014CoreAPI(void);

#ifdef __cplusplus
}
#endif
