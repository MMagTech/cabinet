#ifndef LibretroCoreAPI_h
#define LibretroCoreAPI_h

#include "libretro.h"

#ifdef __cplusplus
extern "C" {
#endif

// One statically linked libretro core's entry points, gathered into data so
// the shared frontend can drive any core without naming its symbols. Only
// one core can link with the standard retro_* names; every additional
// core's archive gets those symbols renamed with a per-core prefix before
// linking (llvm-objcopy --redefine-syms), and its wiring file fills this
// struct with the renamed functions. The frontend never knows the
// difference, which is the point.
typedef struct {
    unsigned (*api_version)(void);
    void (*get_system_info)(struct retro_system_info *);
    void (*set_environment)(retro_environment_t);
    void (*set_video_refresh)(retro_video_refresh_t);
    void (*set_audio_sample)(retro_audio_sample_t);
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*set_input_poll)(retro_input_poll_t);
    void (*set_input_state)(retro_input_state_t);
    void (*init)(void);
    void (*deinit)(void);
    bool (*load_game)(const struct retro_game_info *game);
    void (*unload_game)(void);
    void (*run)(void);
    void (*reset)(void);
    void (*get_system_av_info)(struct retro_system_av_info *info);
    size_t (*serialize_size)(void);
    bool (*serialize)(void *data, size_t size);
    bool (*unserialize)(const void *data, size_t size);
} LibretroCoreAPI;

#ifdef __cplusplus
}
#endif

#endif /* LibretroCoreAPI_h */
