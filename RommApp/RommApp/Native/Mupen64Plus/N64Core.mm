#import "N64Core.h"

extern "C" {
    unsigned n64_retro_api_version(void);
    void n64_retro_get_system_info(struct retro_system_info *);
    void n64_retro_set_environment(retro_environment_t);
    void n64_retro_set_video_refresh(retro_video_refresh_t);
    void n64_retro_set_audio_sample(retro_audio_sample_t);
    void n64_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void n64_retro_set_input_poll(retro_input_poll_t);
    void n64_retro_set_input_state(retro_input_state_t);
    void n64_retro_set_controller_port_device(unsigned, unsigned);
    void n64_retro_init(void);
    void n64_retro_deinit(void);
    bool n64_retro_load_game(const struct retro_game_info *);
    void n64_retro_unload_game(void);
    void n64_retro_run(void);
    void n64_retro_reset(void);
    void n64_retro_get_system_av_info(struct retro_system_av_info *);
    size_t n64_retro_serialize_size(void);
    bool n64_retro_serialize(void *, size_t);
    bool n64_retro_unserialize(const void *, size_t);
    void *n64_retro_get_memory_data(unsigned);
    size_t n64_retro_get_memory_size(unsigned);
}

const LibretroCoreAPI *N64CoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = n64_retro_api_version,
        .get_system_info = n64_retro_get_system_info,
        .set_environment = n64_retro_set_environment,
        .set_video_refresh = n64_retro_set_video_refresh,
        .set_audio_sample = n64_retro_set_audio_sample,
        .set_audio_sample_batch = n64_retro_set_audio_sample_batch,
        .set_input_poll = n64_retro_set_input_poll,
        .set_input_state = n64_retro_set_input_state,
        .set_controller_port_device = n64_retro_set_controller_port_device,
        .init = n64_retro_init,
        .deinit = n64_retro_deinit,
        .load_game = n64_retro_load_game,
        .unload_game = n64_retro_unload_game,
        .run = n64_retro_run,
        .reset = n64_retro_reset,
        .get_system_av_info = n64_retro_get_system_av_info,
        .serialize_size = n64_retro_serialize_size,
        .serialize = n64_retro_serialize,
        .unserialize = n64_retro_unserialize,
        .get_memory_data = n64_retro_get_memory_data,
        .get_memory_size = n64_retro_get_memory_size,
    };
    return &api;
}
