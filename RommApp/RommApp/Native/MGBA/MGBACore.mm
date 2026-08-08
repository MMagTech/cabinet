#import "MGBACore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
extern "C" {
    unsigned gba_retro_api_version(void);
    void gba_retro_get_system_info(struct retro_system_info *);
    void gba_retro_set_environment(retro_environment_t);
    void gba_retro_set_video_refresh(retro_video_refresh_t);
    void gba_retro_set_audio_sample(retro_audio_sample_t);
    void gba_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void gba_retro_set_input_poll(retro_input_poll_t);
    void gba_retro_set_input_state(retro_input_state_t);
    void gba_retro_set_controller_port_device(unsigned, unsigned);
    void gba_retro_init(void);
    void gba_retro_deinit(void);
    bool gba_retro_load_game(const struct retro_game_info *);
    void gba_retro_unload_game(void);
    void gba_retro_run(void);
    void gba_retro_reset(void);
    void gba_retro_get_system_av_info(struct retro_system_av_info *);
    size_t gba_retro_serialize_size(void);
    bool gba_retro_serialize(void *, size_t);
    bool gba_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *MGBACoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = gba_retro_api_version,
        .get_system_info = gba_retro_get_system_info,
        .set_environment = gba_retro_set_environment,
        .set_video_refresh = gba_retro_set_video_refresh,
        .set_audio_sample = gba_retro_set_audio_sample,
        .set_audio_sample_batch = gba_retro_set_audio_sample_batch,
        .set_input_poll = gba_retro_set_input_poll,
        .set_input_state = gba_retro_set_input_state,
        .set_controller_port_device = gba_retro_set_controller_port_device,
        .init = gba_retro_init,
        .deinit = gba_retro_deinit,
        .load_game = gba_retro_load_game,
        .unload_game = gba_retro_unload_game,
        .run = gba_retro_run,
        .reset = gba_retro_reset,
        .get_system_av_info = gba_retro_get_system_av_info,
        .serialize_size = gba_retro_serialize_size,
        .serialize = gba_retro_serialize,
        .unserialize = gba_retro_unserialize,
    };
    return &api;
}
