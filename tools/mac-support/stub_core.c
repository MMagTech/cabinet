// Link placeholder for a core whose real Mac build is not ready yet.
//
// The Mac target links every core the frontend's table references, and
// the GL trio (Flycast, Mupen64Plus, PPSSPP) cannot be built for the
// Mac until ANGLE-for-Mac exists: their code compiles against GLES and
// resolves it at runtime through the hardware-render interface, which
// this target cannot host yet. Rather than holding the whole Mac build
// hostage to that, each pending core links as this stub, compiled with
// its prefix: every entry point is present, loading a game reports
// failure, and nothing else can be reached because the app lists the
// platform as unsupported on the Mac until the real core lands.
//
// Built by tools/build-mac-core-stub.sh. Delete a core's stub the day
// its real Mac library exists; the archive name is identical.
#include <string.h>
#include "libretro.h"

#define GLUE2(a, b) a##b
#define GLUE(a, b) GLUE2(a, b)
#define P(name) GLUE(CORE_PREFIX, name)

void P(_retro_set_environment)(retro_environment_t cb) { (void)cb; }
void P(_retro_set_video_refresh)(retro_video_refresh_t cb) { (void)cb; }
void P(_retro_set_audio_sample)(retro_audio_sample_t cb) { (void)cb; }
void P(_retro_set_audio_sample_batch)(retro_audio_sample_batch_t cb) { (void)cb; }
void P(_retro_set_input_poll)(retro_input_poll_t cb) { (void)cb; }
void P(_retro_set_input_state)(retro_input_state_t cb) { (void)cb; }

void P(_retro_init)(void) {}
void P(_retro_deinit)(void) {}

unsigned P(_retro_api_version)(void) { return RETRO_API_VERSION; }

void P(_retro_get_system_info)(struct retro_system_info *info)
{
    memset(info, 0, sizeof(*info));
    info->library_name = "pending on the Mac";
    info->library_version = "0";
    info->valid_extensions = "";
}

void P(_retro_get_system_av_info)(struct retro_system_av_info *info)
{
    memset(info, 0, sizeof(*info));
    info->geometry.base_width = 320;
    info->geometry.base_height = 240;
    info->geometry.max_width = 320;
    info->geometry.max_height = 240;
    info->timing.fps = 60.0;
    info->timing.sample_rate = 44100.0;
}

void P(_retro_set_controller_port_device)(unsigned port, unsigned device)
{
    (void)port; (void)device;
}

void P(_retro_reset)(void) {}
void P(_retro_run)(void) {}

size_t P(_retro_serialize_size)(void) { return 0; }
bool P(_retro_serialize)(void *data, size_t size) { (void)data; (void)size; return false; }
bool P(_retro_unserialize)(const void *data, size_t size) { (void)data; (void)size; return false; }

void P(_retro_cheat_reset)(void) {}
void P(_retro_cheat_set)(unsigned index, bool enabled, const char *code)
{
    (void)index; (void)enabled; (void)code;
}

bool P(_retro_load_game)(const struct retro_game_info *game)
{
    (void)game;
    return false;
}

bool P(_retro_load_game_special)(unsigned game_type, const struct retro_game_info *info, size_t num_info)
{
    (void)game_type; (void)info; (void)num_info;
    return false;
}

void P(_retro_unload_game)(void) {}

unsigned P(_retro_get_region)(void) { return RETRO_REGION_NTSC; }

void *P(_retro_get_memory_data)(unsigned id) { (void)id; return 0; }
size_t P(_retro_get_memory_size)(unsigned id) { (void)id; return 0; }
