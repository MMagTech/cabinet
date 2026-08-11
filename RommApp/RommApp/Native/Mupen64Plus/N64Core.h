#include "LibretroCoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// mupen64plus-libretro-nx's entry points as a table for the shared
// frontend, n64_retro_* forwarders from the merged, symbol-scoped
// archive. Built by tools/build-n64.sh: upstream's own real ios-arm64
// platform target (WITH_DYNAREC empty, no dynamic recompiler, the same
// no-JIT exception Saturn/PS1/Flycast already proved out), GLES3 forced
// on for GLideN64's hardware-render path, which is also this core's
// default RDP plugin already. See LibretroFrontend.h's
// LibretroCoreIDMupen64Plus comment.
const LibretroCoreAPI *N64CoreAPI(void);

#ifdef __cplusplus
}
#endif
