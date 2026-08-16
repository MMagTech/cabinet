#import "GenesisPlusGXCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
extern "C" {
    unsigned gpgx_retro_api_version(void);
    void gpgx_retro_get_system_info(struct retro_system_info *);
    void gpgx_retro_set_environment(retro_environment_t);
    void gpgx_retro_set_video_refresh(retro_video_refresh_t);
    void gpgx_retro_set_audio_sample(retro_audio_sample_t);
    void gpgx_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void gpgx_retro_set_input_poll(retro_input_poll_t);
    void gpgx_retro_set_input_state(retro_input_state_t);
    void gpgx_retro_set_controller_port_device(unsigned, unsigned);
    void gpgx_retro_init(void);
    void gpgx_retro_deinit(void);
    bool gpgx_retro_load_game(const struct retro_game_info *);
    void gpgx_retro_unload_game(void);
    void gpgx_retro_run(void);
    void gpgx_retro_reset(void);
    void gpgx_retro_get_system_av_info(struct retro_system_av_info *);
    size_t gpgx_retro_serialize_size(void);
    bool gpgx_retro_serialize(void *, size_t);
    bool gpgx_retro_unserialize(const void *, size_t);
    void *gpgx_retro_get_memory_data(unsigned);
    size_t gpgx_retro_get_memory_size(unsigned);
}

const LibretroCoreAPI *GenesisPlusGXCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = gpgx_retro_api_version,
        .get_system_info = gpgx_retro_get_system_info,
        .set_environment = gpgx_retro_set_environment,
        .set_video_refresh = gpgx_retro_set_video_refresh,
        .set_audio_sample = gpgx_retro_set_audio_sample,
        .set_audio_sample_batch = gpgx_retro_set_audio_sample_batch,
        .set_input_poll = gpgx_retro_set_input_poll,
        .set_input_state = gpgx_retro_set_input_state,
        .set_controller_port_device = gpgx_retro_set_controller_port_device,
        .init = gpgx_retro_init,
        .deinit = gpgx_retro_deinit,
        .load_game = gpgx_retro_load_game,
        .unload_game = gpgx_retro_unload_game,
        .run = gpgx_retro_run,
        .reset = gpgx_retro_reset,
        .get_system_av_info = gpgx_retro_get_system_av_info,
        .serialize_size = gpgx_retro_serialize_size,
        .serialize = gpgx_retro_serialize,
        .unserialize = gpgx_retro_unserialize,
        // Cartridge save RAM for Genesis, Master System and Game Gear.
        // The reported size is the fixed 64KB maximum at load time and is
        // trimmed to the bytes actually written once the game is running,
        // so a captured save is usually smaller than the size reported at
        // the next boot; the frontend's restore copies the smaller length
        // for exactly this reason. Never-written save RAM reports zero.
        // Sega CD's internal backup RAM is NOT this region, the core
        // writes that to its own .brm file instead, handled separately.
        .get_memory_data = gpgx_retro_get_memory_data,
        .get_memory_size = gpgx_retro_get_memory_size,
    };
    return &api;
}
