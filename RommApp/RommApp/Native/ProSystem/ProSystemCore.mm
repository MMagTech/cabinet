#import "ProSystemCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
extern "C" {
    unsigned a78_retro_api_version(void);
    void a78_retro_get_system_info(struct retro_system_info *);
    void a78_retro_set_environment(retro_environment_t);
    void a78_retro_set_video_refresh(retro_video_refresh_t);
    void a78_retro_set_audio_sample(retro_audio_sample_t);
    void a78_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void a78_retro_set_input_poll(retro_input_poll_t);
    void a78_retro_set_input_state(retro_input_state_t);
    void a78_retro_set_controller_port_device(unsigned, unsigned);
    void a78_retro_init(void);
    void a78_retro_deinit(void);
    bool a78_retro_load_game(const struct retro_game_info *);
    void a78_retro_unload_game(void);
    void a78_retro_run(void);
    void a78_retro_reset(void);
    void a78_retro_get_system_av_info(struct retro_system_av_info *);
    size_t a78_retro_serialize_size(void);
    bool a78_retro_serialize(void *, size_t);
    bool a78_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *ProSystemCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = a78_retro_api_version,
        .get_system_info = a78_retro_get_system_info,
        .set_environment = a78_retro_set_environment,
        .set_video_refresh = a78_retro_set_video_refresh,
        .set_audio_sample = a78_retro_set_audio_sample,
        .set_audio_sample_batch = a78_retro_set_audio_sample_batch,
        .set_input_poll = a78_retro_set_input_poll,
        .set_input_state = a78_retro_set_input_state,
        .set_controller_port_device = a78_retro_set_controller_port_device,
        .init = a78_retro_init,
        .deinit = a78_retro_deinit,
        .load_game = a78_retro_load_game,
        .unload_game = a78_retro_unload_game,
        .run = a78_retro_run,
        .reset = a78_retro_reset,
        .get_system_av_info = a78_retro_get_system_av_info,
        .serialize_size = a78_retro_serialize_size,
        .serialize = a78_retro_serialize,
        .unserialize = a78_retro_unserialize,
    };
    return &api;
}
