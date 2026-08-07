#import "SaturnCore.h"

// The prefixed libretro API, resolved from libbeetle_saturn_ios.a at
// link time. See tools/build-beetle-saturn.sh for where the prefix
// comes from.
extern "C" {
    unsigned bsat_retro_api_version(void);
    void bsat_retro_get_system_info(struct retro_system_info *);
    void bsat_retro_set_environment(retro_environment_t);
    void bsat_retro_set_video_refresh(retro_video_refresh_t);
    void bsat_retro_set_audio_sample(retro_audio_sample_t);
    void bsat_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void bsat_retro_set_input_poll(retro_input_poll_t);
    void bsat_retro_set_input_state(retro_input_state_t);
    void bsat_retro_init(void);
    void bsat_retro_deinit(void);
    bool bsat_retro_load_game(const struct retro_game_info *);
    void bsat_retro_unload_game(void);
    void bsat_retro_run(void);
    void bsat_retro_reset(void);
    void bsat_retro_get_system_av_info(struct retro_system_av_info *);
    size_t bsat_retro_serialize_size(void);
    bool bsat_retro_serialize(void *, size_t);
    bool bsat_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *BeetleSaturnCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = bsat_retro_api_version,
        .get_system_info = bsat_retro_get_system_info,
        .set_environment = bsat_retro_set_environment,
        .set_video_refresh = bsat_retro_set_video_refresh,
        .set_audio_sample = bsat_retro_set_audio_sample,
        .set_audio_sample_batch = bsat_retro_set_audio_sample_batch,
        .set_input_poll = bsat_retro_set_input_poll,
        .set_input_state = bsat_retro_set_input_state,
        .init = bsat_retro_init,
        .deinit = bsat_retro_deinit,
        .load_game = bsat_retro_load_game,
        .unload_game = bsat_retro_unload_game,
        .run = bsat_retro_run,
        .reset = bsat_retro_reset,
        .get_system_av_info = bsat_retro_get_system_av_info,
        .serialize_size = bsat_retro_serialize_size,
        .serialize = bsat_retro_serialize,
        .unserialize = bsat_retro_unserialize,
    };
    return &api;
}
