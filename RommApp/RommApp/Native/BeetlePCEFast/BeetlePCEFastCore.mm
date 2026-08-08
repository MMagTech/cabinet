#import "BeetlePCEFastCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
extern "C" {
    unsigned pce_retro_api_version(void);
    void pce_retro_get_system_info(struct retro_system_info *);
    void pce_retro_set_environment(retro_environment_t);
    void pce_retro_set_video_refresh(retro_video_refresh_t);
    void pce_retro_set_audio_sample(retro_audio_sample_t);
    void pce_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void pce_retro_set_input_poll(retro_input_poll_t);
    void pce_retro_set_input_state(retro_input_state_t);
    void pce_retro_set_controller_port_device(unsigned, unsigned);
    void pce_retro_init(void);
    void pce_retro_deinit(void);
    bool pce_retro_load_game(const struct retro_game_info *);
    void pce_retro_unload_game(void);
    void pce_retro_run(void);
    void pce_retro_reset(void);
    void pce_retro_get_system_av_info(struct retro_system_av_info *);
    size_t pce_retro_serialize_size(void);
    bool pce_retro_serialize(void *, size_t);
    bool pce_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *BeetlePCEFastCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = pce_retro_api_version,
        .get_system_info = pce_retro_get_system_info,
        .set_environment = pce_retro_set_environment,
        .set_video_refresh = pce_retro_set_video_refresh,
        .set_audio_sample = pce_retro_set_audio_sample,
        .set_audio_sample_batch = pce_retro_set_audio_sample_batch,
        .set_input_poll = pce_retro_set_input_poll,
        .set_input_state = pce_retro_set_input_state,
        .set_controller_port_device = pce_retro_set_controller_port_device,
        .init = pce_retro_init,
        .deinit = pce_retro_deinit,
        .load_game = pce_retro_load_game,
        .unload_game = pce_retro_unload_game,
        .run = pce_retro_run,
        .reset = pce_retro_reset,
        .get_system_av_info = pce_retro_get_system_av_info,
        .serialize_size = pce_retro_serialize_size,
        .serialize = pce_retro_serialize,
        .unserialize = pce_retro_unserialize,
    };
    return &api;
}
