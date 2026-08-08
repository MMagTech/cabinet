#import "BeetleNGPCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
extern "C" {
    unsigned ngp_retro_api_version(void);
    void ngp_retro_get_system_info(struct retro_system_info *);
    void ngp_retro_set_environment(retro_environment_t);
    void ngp_retro_set_video_refresh(retro_video_refresh_t);
    void ngp_retro_set_audio_sample(retro_audio_sample_t);
    void ngp_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void ngp_retro_set_input_poll(retro_input_poll_t);
    void ngp_retro_set_input_state(retro_input_state_t);
    void ngp_retro_set_controller_port_device(unsigned, unsigned);
    void ngp_retro_init(void);
    void ngp_retro_deinit(void);
    bool ngp_retro_load_game(const struct retro_game_info *);
    void ngp_retro_unload_game(void);
    void ngp_retro_run(void);
    void ngp_retro_reset(void);
    void ngp_retro_get_system_av_info(struct retro_system_av_info *);
    size_t ngp_retro_serialize_size(void);
    bool ngp_retro_serialize(void *, size_t);
    bool ngp_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *BeetleNGPCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = ngp_retro_api_version,
        .get_system_info = ngp_retro_get_system_info,
        .set_environment = ngp_retro_set_environment,
        .set_video_refresh = ngp_retro_set_video_refresh,
        .set_audio_sample = ngp_retro_set_audio_sample,
        .set_audio_sample_batch = ngp_retro_set_audio_sample_batch,
        .set_input_poll = ngp_retro_set_input_poll,
        .set_input_state = ngp_retro_set_input_state,
        .set_controller_port_device = ngp_retro_set_controller_port_device,
        .init = ngp_retro_init,
        .deinit = ngp_retro_deinit,
        .load_game = ngp_retro_load_game,
        .unload_game = ngp_retro_unload_game,
        .run = ngp_retro_run,
        .reset = ngp_retro_reset,
        .get_system_av_info = ngp_retro_get_system_av_info,
        .serialize_size = ngp_retro_serialize_size,
        .serialize = ngp_retro_serialize,
        .unserialize = ngp_retro_unserialize,
    };
    return &api;
}
