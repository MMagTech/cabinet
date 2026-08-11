#import "FlycastCore.h"

extern "C" {
    unsigned dc_retro_api_version(void);
    void dc_retro_get_system_info(struct retro_system_info *);
    void dc_retro_set_environment(retro_environment_t);
    void dc_retro_set_video_refresh(retro_video_refresh_t);
    void dc_retro_set_audio_sample(retro_audio_sample_t);
    void dc_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void dc_retro_set_input_poll(retro_input_poll_t);
    void dc_retro_set_input_state(retro_input_state_t);
    void dc_retro_set_controller_port_device(unsigned, unsigned);
    void dc_retro_init(void);
    void dc_retro_deinit(void);
    bool dc_retro_load_game(const struct retro_game_info *);
    void dc_retro_unload_game(void);
    void dc_retro_run(void);
    void dc_retro_reset(void);
    void dc_retro_get_system_av_info(struct retro_system_av_info *);
    size_t dc_retro_serialize_size(void);
    bool dc_retro_serialize(void *, size_t);
    bool dc_retro_unserialize(const void *, size_t);
    void *dc_retro_get_memory_data(unsigned);
    size_t dc_retro_get_memory_size(unsigned);
}

const LibretroCoreAPI *FlycastCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = dc_retro_api_version,
        .get_system_info = dc_retro_get_system_info,
        .set_environment = dc_retro_set_environment,
        .set_video_refresh = dc_retro_set_video_refresh,
        .set_audio_sample = dc_retro_set_audio_sample,
        .set_audio_sample_batch = dc_retro_set_audio_sample_batch,
        .set_input_poll = dc_retro_set_input_poll,
        .set_input_state = dc_retro_set_input_state,
        .set_controller_port_device = dc_retro_set_controller_port_device,
        .init = dc_retro_init,
        .deinit = dc_retro_deinit,
        .load_game = dc_retro_load_game,
        .unload_game = dc_retro_unload_game,
        .run = dc_retro_run,
        .reset = dc_retro_reset,
        .get_system_av_info = dc_retro_get_system_av_info,
        .serialize_size = dc_retro_serialize_size,
        .serialize = dc_retro_serialize,
        .unserialize = dc_retro_unserialize,
        .get_memory_data = dc_retro_get_memory_data,
        .get_memory_size = dc_retro_get_memory_size,
    };
    return &api;
}
