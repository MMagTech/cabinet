#import "Snes9xCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
extern "C" {
    unsigned s9x_retro_api_version(void);
    void s9x_retro_get_system_info(struct retro_system_info *);
    void s9x_retro_set_environment(retro_environment_t);
    void s9x_retro_set_video_refresh(retro_video_refresh_t);
    void s9x_retro_set_audio_sample(retro_audio_sample_t);
    void s9x_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void s9x_retro_set_input_poll(retro_input_poll_t);
    void s9x_retro_set_input_state(retro_input_state_t);
    void s9x_retro_set_controller_port_device(unsigned, unsigned);
    void s9x_retro_init(void);
    void s9x_retro_deinit(void);
    bool s9x_retro_load_game(const struct retro_game_info *);
    void s9x_retro_unload_game(void);
    void s9x_retro_run(void);
    void s9x_retro_reset(void);
    void s9x_retro_get_system_av_info(struct retro_system_av_info *);
    size_t s9x_retro_serialize_size(void);
    bool s9x_retro_serialize(void *, size_t);
    bool s9x_retro_unserialize(const void *, size_t);
    void *s9x_retro_get_memory_data(unsigned);
    size_t s9x_retro_get_memory_size(unsigned);
}

const LibretroCoreAPI *Snes9xCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = s9x_retro_api_version,
        .get_system_info = s9x_retro_get_system_info,
        .set_environment = s9x_retro_set_environment,
        .set_video_refresh = s9x_retro_set_video_refresh,
        .set_audio_sample = s9x_retro_set_audio_sample,
        .set_audio_sample_batch = s9x_retro_set_audio_sample_batch,
        .set_input_poll = s9x_retro_set_input_poll,
        .set_input_state = s9x_retro_set_input_state,
        .set_controller_port_device = s9x_retro_set_controller_port_device,
        .init = s9x_retro_init,
        .deinit = s9x_retro_deinit,
        .load_game = s9x_retro_load_game,
        .unload_game = s9x_retro_unload_game,
        .run = s9x_retro_run,
        .reset = s9x_retro_reset,
        .get_system_av_info = s9x_retro_get_system_av_info,
        .serialize_size = s9x_retro_serialize_size,
        .serialize = s9x_retro_serialize,
        .unserialize = s9x_retro_unserialize,
        // Cartridge battery SRAM. The pointer is never null even for a
        // cartridge with no battery; only the size drops to zero, so the
        // size is the signal, which the frontend's saveRAM already tests.
        .get_memory_data = s9x_retro_get_memory_data,
        .get_memory_size = s9x_retro_get_memory_size,
    };
    return &api;
}
