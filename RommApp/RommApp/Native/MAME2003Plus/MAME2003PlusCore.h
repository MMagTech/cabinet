#include "LibretroCoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// MAME 2003-Plus's entry points as a table for the shared frontend. The
// core's archive is a single merged object whose only exported symbols
// are these m2003p_retro_* forwarders; the real retro_* definitions
// inside it are private, so they cannot collide with FinalBurn Neo's or
// any other core's. Built by tools/build-core.sh.
//
// This is Cabinet's second arcade core, and the only one that reaches
// the boards FBNeo does not: the early-80s Atari and Midway machines
// whose controls were dials, spinners, trackballs, paddles and guns.
// Why this version rather than mame2010 is measured out in
// docs/mame-core-comparison-2026-08-21.md.
const LibretroCoreAPI *MAME2003PlusCoreAPI(void);

#ifdef __cplusplus
}
#endif
