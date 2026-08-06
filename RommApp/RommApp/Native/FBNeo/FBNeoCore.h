#include "LibretroCoreAPI.h"

#ifdef __cplusplus
extern "C" {
#endif

// FBNeo's entry points as a table for the shared frontend. FBNeo is the
// core that links under the standard retro_* names; see LibretroCoreAPI.h
// for how later cores avoid colliding with it.
const LibretroCoreAPI *FBNeoCoreAPI(void);

#ifdef __cplusplus
}
#endif
