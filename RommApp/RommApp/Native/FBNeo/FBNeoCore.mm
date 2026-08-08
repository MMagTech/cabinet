#import "FBNeoCore.h"

// The unprefixed libretro API, resolved from libfbneo_libretro_ios.a at
// link time.
extern "C" {
    unsigned retro_api_version(void);
    void retro_get_system_info(struct retro_system_info *);
    void retro_set_environment(retro_environment_t);
    void retro_set_video_refresh(retro_video_refresh_t);
    void retro_set_audio_sample(retro_audio_sample_t);
    void retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void retro_set_input_poll(retro_input_poll_t);
    void retro_set_input_state(retro_input_state_t);
    void retro_set_controller_port_device(unsigned, unsigned);
    void retro_init(void);
    void retro_deinit(void);
    bool retro_load_game(const struct retro_game_info *);
    void retro_unload_game(void);
    void retro_run(void);
    void retro_reset(void);
    void retro_get_system_av_info(struct retro_system_av_info *);
    size_t retro_serialize_size(void);
    bool retro_serialize(void *, size_t);
    bool retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *FBNeoCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = retro_api_version,
        .get_system_info = retro_get_system_info,
        .set_environment = retro_set_environment,
        .set_video_refresh = retro_set_video_refresh,
        .set_audio_sample = retro_set_audio_sample,
        .set_audio_sample_batch = retro_set_audio_sample_batch,
        .set_input_poll = retro_set_input_poll,
        .set_input_state = retro_set_input_state,
        .set_controller_port_device = retro_set_controller_port_device,
        .init = retro_init,
        .deinit = retro_deinit,
        .load_game = retro_load_game,
        .unload_game = retro_unload_game,
        .run = retro_run,
        .reset = retro_reset,
        .get_system_av_info = retro_get_system_av_info,
        .serialize_size = retro_serialize_size,
        .serialize = retro_serialize,
        .unserialize = retro_unserialize,
    };
    return &api;
}
