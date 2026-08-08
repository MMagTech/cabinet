#include "LibretroCoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// PicoDrive's entry points as a table for the shared frontend. The
// core's archive is a single merged object whose only exported symbols
// are these pico_retro_* forwarders; the real retro_* definitions
// inside it are private, so they cannot collide with any other core's.
// Built by tools/build-core.sh. Genesis Plus GX handles every other
// Sega platform this app supports; PicoDrive exists only because
// upstream Genesis Plus GX has never added Sega 32X emulation.
const LibretroCoreAPI *PicoDriveCoreAPI(void);

#ifdef __cplusplus
}
#endif
