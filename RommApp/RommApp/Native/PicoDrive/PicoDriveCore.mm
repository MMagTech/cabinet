#import "PicoDriveCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
extern "C" {
    unsigned pico_retro_api_version(void);
    void pico_retro_get_system_info(struct retro_system_info *);
    void pico_retro_set_environment(retro_environment_t);
    void pico_retro_set_video_refresh(retro_video_refresh_t);
    void pico_retro_set_audio_sample(retro_audio_sample_t);
    void pico_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void pico_retro_set_input_poll(retro_input_poll_t);
    void pico_retro_set_input_state(retro_input_state_t);
    void pico_retro_set_controller_port_device(unsigned, unsigned);
    void pico_retro_init(void);
    void pico_retro_deinit(void);
    bool pico_retro_load_game(const struct retro_game_info *);
    void pico_retro_unload_game(void);
    void pico_retro_run(void);
    void pico_retro_reset(void);
    void pico_retro_get_system_av_info(struct retro_system_av_info *);
    size_t pico_retro_serialize_size(void);
    bool pico_retro_serialize(void *, size_t);
    bool pico_retro_unserialize(const void *, size_t);
    void *pico_retro_get_memory_data(unsigned);
    size_t pico_retro_get_memory_size(unsigned);
}

const LibretroCoreAPI *PicoDriveCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = pico_retro_api_version,
        .get_system_info = pico_retro_get_system_info,
        .set_environment = pico_retro_set_environment,
        .set_video_refresh = pico_retro_set_video_refresh,
        .set_audio_sample = pico_retro_set_audio_sample,
        .set_audio_sample_batch = pico_retro_set_audio_sample_batch,
        .set_input_poll = pico_retro_set_input_poll,
        .set_input_state = pico_retro_set_input_state,
        .set_controller_port_device = pico_retro_set_controller_port_device,
        .init = pico_retro_init,
        .deinit = pico_retro_deinit,
        .load_game = pico_retro_load_game,
        .unload_game = pico_retro_unload_game,
        .run = pico_retro_run,
        .reset = pico_retro_reset,
        .get_system_av_info = pico_retro_get_system_av_info,
        .serialize_size = pico_retro_serialize_size,
        .serialize = pico_retro_serialize,
        .unserialize = pico_retro_unserialize,
        // 32X cartridge save RAM. Rare in the library, a handful of
        // titles, but the wiring is the same one call every cartridge
        // core answers. Save RAM the game never wrote reports size zero.
        .get_memory_data = pico_retro_get_memory_data,
        .get_memory_size = pico_retro_get_memory_size,
    };
    return &api;
}
