#import "Stella2014Core.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
// No get_memory_data/get_memory_size here on purpose: the core exposes
// only RETRO_MEMORY_SYSTEM_RAM (the 2600's 128 bytes of RIOT RAM), and
// no retail 2600 cartridge had battery saves.
extern "C" {
    unsigned a26_retro_api_version(void);
    void a26_retro_get_system_info(struct retro_system_info *);
    void a26_retro_set_environment(retro_environment_t);
    void a26_retro_set_video_refresh(retro_video_refresh_t);
    void a26_retro_set_audio_sample(retro_audio_sample_t);
    void a26_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void a26_retro_set_input_poll(retro_input_poll_t);
    void a26_retro_set_input_state(retro_input_state_t);
    void a26_retro_set_controller_port_device(unsigned, unsigned);
    void a26_retro_init(void);
    void a26_retro_deinit(void);
    bool a26_retro_load_game(const struct retro_game_info *);
    void a26_retro_unload_game(void);
    void a26_retro_run(void);
    void a26_retro_reset(void);
    void a26_retro_get_system_av_info(struct retro_system_av_info *);
    size_t a26_retro_serialize_size(void);
    bool a26_retro_serialize(void *, size_t);
    bool a26_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *Stella2014CoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = a26_retro_api_version,
        .get_system_info = a26_retro_get_system_info,
        .set_environment = a26_retro_set_environment,
        .set_video_refresh = a26_retro_set_video_refresh,
        .set_audio_sample = a26_retro_set_audio_sample,
        .set_audio_sample_batch = a26_retro_set_audio_sample_batch,
        .set_input_poll = a26_retro_set_input_poll,
        .set_input_state = a26_retro_set_input_state,
        .set_controller_port_device = a26_retro_set_controller_port_device,
        .init = a26_retro_init,
        .deinit = a26_retro_deinit,
        .load_game = a26_retro_load_game,
        .unload_game = a26_retro_unload_game,
        .run = a26_retro_run,
        .reset = a26_retro_reset,
        .get_system_av_info = a26_retro_get_system_av_info,
        .serialize_size = a26_retro_serialize_size,
        .serialize = a26_retro_serialize,
        .unserialize = a26_retro_unserialize,
    };
    return &api;
}
