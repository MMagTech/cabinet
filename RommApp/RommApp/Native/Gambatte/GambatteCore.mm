#import "GambatteCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
extern "C" {
    unsigned gmb_retro_api_version(void);
    void gmb_retro_get_system_info(struct retro_system_info *);
    void gmb_retro_set_environment(retro_environment_t);
    void gmb_retro_set_video_refresh(retro_video_refresh_t);
    void gmb_retro_set_audio_sample(retro_audio_sample_t);
    void gmb_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void gmb_retro_set_input_poll(retro_input_poll_t);
    void gmb_retro_set_input_state(retro_input_state_t);
    void gmb_retro_set_controller_port_device(unsigned, unsigned);
    void gmb_retro_init(void);
    void gmb_retro_deinit(void);
    bool gmb_retro_load_game(const struct retro_game_info *);
    void gmb_retro_unload_game(void);
    void gmb_retro_run(void);
    void gmb_retro_reset(void);
    void gmb_retro_get_system_av_info(struct retro_system_av_info *);
    size_t gmb_retro_serialize_size(void);
    bool gmb_retro_serialize(void *, size_t);
    bool gmb_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *GambatteCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = gmb_retro_api_version,
        .get_system_info = gmb_retro_get_system_info,
        .set_environment = gmb_retro_set_environment,
        .set_video_refresh = gmb_retro_set_video_refresh,
        .set_audio_sample = gmb_retro_set_audio_sample,
        .set_audio_sample_batch = gmb_retro_set_audio_sample_batch,
        .set_input_poll = gmb_retro_set_input_poll,
        .set_input_state = gmb_retro_set_input_state,
        .set_controller_port_device = gmb_retro_set_controller_port_device,
        .init = gmb_retro_init,
        .deinit = gmb_retro_deinit,
        .load_game = gmb_retro_load_game,
        .unload_game = gmb_retro_unload_game,
        .run = gmb_retro_run,
        .reset = gmb_retro_reset,
        .get_system_av_info = gmb_retro_get_system_av_info,
        .serialize_size = gmb_retro_serialize_size,
        .serialize = gmb_retro_serialize,
        .unserialize = gmb_retro_unserialize,
    };
    return &api;
}
