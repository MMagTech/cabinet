#include "LibretroCoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// melonDS's entry points as a table for the shared frontend. The core's
// archive is a single merged object whose only exported symbols are
// these mds_retro_* forwarders; the real retro_* definitions inside it
// are private, so they cannot collide with any other core's. Built by
// tools/build-core.sh.
const LibretroCoreAPI *MelonDSCoreAPI(void);

#ifdef __cplusplus
}
#endif
