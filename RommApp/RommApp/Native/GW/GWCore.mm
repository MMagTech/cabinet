#import "GWCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
//
// Serialize is wired but honest: this core's retro_serialize returns
// false and its serialize_size is zero, so save states DO NOT exist for
// Game & Watch. The launch screen and pause menu hide the slots for
// this platform rather than offering buttons that cannot work. The
// memory API is real: a small key/value SRAM carrying per-game settings
// and scores, which rides the normal save sync.
extern "C" {
    unsigned gw_retro_api_version(void);
    void gw_retro_get_system_info(struct retro_system_info *);
    void gw_retro_set_environment(retro_environment_t);
    void gw_retro_set_video_refresh(retro_video_refresh_t);
    void gw_retro_set_audio_sample(retro_audio_sample_t);
    void gw_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void gw_retro_set_input_poll(retro_input_poll_t);
    void gw_retro_set_input_state(retro_input_state_t);
    void gw_retro_set_controller_port_device(unsigned, unsigned);
    void gw_retro_init(void);
    void gw_retro_deinit(void);
    bool gw_retro_load_game(const struct retro_game_info *);
    void gw_retro_unload_game(void);
    void gw_retro_run(void);
    void gw_retro_reset(void);
    void gw_retro_get_system_av_info(struct retro_system_av_info *);
    size_t gw_retro_serialize_size(void);
    bool gw_retro_serialize(void *, size_t);
    bool gw_retro_unserialize(const void *, size_t);
    void *gw_retro_get_memory_data(unsigned);
    size_t gw_retro_get_memory_size(unsigned);
}

const LibretroCoreAPI *GWCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = gw_retro_api_version,
        .get_system_info = gw_retro_get_system_info,
        .set_environment = gw_retro_set_environment,
        .set_video_refresh = gw_retro_set_video_refresh,
        .set_audio_sample = gw_retro_set_audio_sample,
        .set_audio_sample_batch = gw_retro_set_audio_sample_batch,
        .set_input_poll = gw_retro_set_input_poll,
        .set_input_state = gw_retro_set_input_state,
        .set_controller_port_device = gw_retro_set_controller_port_device,
        .init = gw_retro_init,
        .deinit = gw_retro_deinit,
        .load_game = gw_retro_load_game,
        .unload_game = gw_retro_unload_game,
        .run = gw_retro_run,
        .reset = gw_retro_reset,
        .get_system_av_info = gw_retro_get_system_av_info,
        .serialize_size = gw_retro_serialize_size,
        .serialize = gw_retro_serialize,
        .unserialize = gw_retro_unserialize,
        .get_memory_data = gw_retro_get_memory_data,
        .get_memory_size = gw_retro_get_memory_size,
    };
    return &api;
}
