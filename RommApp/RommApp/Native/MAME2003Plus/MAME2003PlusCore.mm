#import "MAME2003PlusCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
extern "C" {
    unsigned m2003p_retro_api_version(void);
    void m2003p_retro_get_system_info(struct retro_system_info *);
    void m2003p_retro_set_environment(retro_environment_t);
    void m2003p_retro_set_video_refresh(retro_video_refresh_t);
    void m2003p_retro_set_audio_sample(retro_audio_sample_t);
    void m2003p_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void m2003p_retro_set_input_poll(retro_input_poll_t);
    void m2003p_retro_set_input_state(retro_input_state_t);
    void m2003p_retro_set_controller_port_device(unsigned, unsigned);
    void m2003p_retro_init(void);
    void m2003p_retro_deinit(void);
    bool m2003p_retro_load_game(const struct retro_game_info *);
    void m2003p_retro_unload_game(void);
    void m2003p_retro_run(void);
    void m2003p_retro_reset(void);
    void m2003p_retro_get_system_av_info(struct retro_system_av_info *);
    size_t m2003p_retro_serialize_size(void);
    bool m2003p_retro_serialize(void *, size_t);
    bool m2003p_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *MAME2003PlusCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = m2003p_retro_api_version,
        .get_system_info = m2003p_retro_get_system_info,
        .set_environment = m2003p_retro_set_environment,
        .set_video_refresh = m2003p_retro_set_video_refresh,
        .set_audio_sample = m2003p_retro_set_audio_sample,
        .set_audio_sample_batch = m2003p_retro_set_audio_sample_batch,
        .set_input_poll = m2003p_retro_set_input_poll,
        .set_input_state = m2003p_retro_set_input_state,
        .set_controller_port_device = m2003p_retro_set_controller_port_device,
        .init = m2003p_retro_init,
        .deinit = m2003p_retro_deinit,
        .load_game = m2003p_retro_load_game,
        .unload_game = m2003p_retro_unload_game,
        .run = m2003p_retro_run,
        .reset = m2003p_retro_reset,
        .get_system_av_info = m2003p_retro_get_system_av_info,
        .serialize_size = m2003p_retro_serialize_size,
        .serialize = m2003p_retro_serialize,
        .unserialize = m2003p_retro_unserialize,
    };
    return &api;
}
