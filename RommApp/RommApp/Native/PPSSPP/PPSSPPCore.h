#include "LibretroCoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// PPSSPP's entry points as a table for the shared frontend, psp_retro_*
// forwarders from the merged, symbol-scoped archive. Built by
// tools/build-ppsspp.sh: the CPU core is forced to the IR interpreter
// at runtime (ppsspp_cpu_core, NativeCoreOptions), no dynarec, the
// same no-JIT constraint every native core here runs under, and it
// requires the frontend's GLES hardware-render path the way Flycast
// does; the software renderer exists but is far too slow for real
// games on device. Apple TV go/no-go spike; see LibretroFrontend.h's
// LibretroCoreIDPPSSPP comment.
const LibretroCoreAPI *PPSSPPCoreAPI(void);

#ifdef __cplusplus
}
#endif
