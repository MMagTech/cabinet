#include "LibretroCoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// Flycast's entry points as a table for the shared frontend, dc_retro_*
// forwarders from the merged, symbol-scoped archive. Built by
// tools/build-flycast.sh: interpreter-only (TARGET_NO_REC), no dynarec,
// the same no-JIT exception Saturn and PS1 already proved out, and
// requires the frontend's GLES hardware-render path since this core has
// no software renderer at all. Debug-menu spike only; see
// LibretroFrontend.h's LibretroCoreIDFlycast comment.
const LibretroCoreAPI *FlycastCoreAPI(void);

#ifdef __cplusplus
}
#endif
