#include "LibretroCoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// Opera's entry points as a table for the shared frontend. The core's
// archive is a single merged object whose only exported symbols are
// these opr_retro_* forwarders; the real retro_* definitions inside it
// are private, so they cannot collide with any other core's. Built by
// tools/build-core.sh. Requires a 3DO BIOS staged by NativeLauncher and
// named through the forced opera_bios option.
const LibretroCoreAPI *OperaCoreAPI(void);

#ifdef __cplusplus
}
#endif
