#import "PCSXReARMedCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
extern "C" {
    unsigned psx_retro_api_version(void);
    void psx_retro_get_system_info(struct retro_system_info *);
    void psx_retro_set_environment(retro_environment_t);
    void psx_retro_set_video_refresh(retro_video_refresh_t);
    void psx_retro_set_audio_sample(retro_audio_sample_t);
    void psx_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void psx_retro_set_input_poll(retro_input_poll_t);
    void psx_retro_set_input_state(retro_input_state_t);
    void psx_retro_set_controller_port_device(unsigned, unsigned);
    void psx_retro_init(void);
    void psx_retro_deinit(void);
    bool psx_retro_load_game(const struct retro_game_info *);
    void psx_retro_unload_game(void);
    void psx_retro_run(void);
    void psx_retro_reset(void);
    void psx_retro_get_system_av_info(struct retro_system_av_info *);
    size_t psx_retro_serialize_size(void);
    bool psx_retro_serialize(void *, size_t);
    bool psx_retro_unserialize(const void *, size_t);
    void *psx_retro_get_memory_data(unsigned);
    size_t psx_retro_get_memory_size(unsigned);
}

const LibretroCoreAPI *PCSXReARMedCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = psx_retro_api_version,
        .get_system_info = psx_retro_get_system_info,
        .set_environment = psx_retro_set_environment,
        .set_video_refresh = psx_retro_set_video_refresh,
        .set_audio_sample = psx_retro_set_audio_sample,
        .set_audio_sample_batch = psx_retro_set_audio_sample_batch,
        .set_input_poll = psx_retro_set_input_poll,
        .set_input_state = psx_retro_set_input_state,
        .set_controller_port_device = psx_retro_set_controller_port_device,
        .init = psx_retro_init,
        .deinit = psx_retro_deinit,
        .load_game = psx_retro_load_game,
        .unload_game = psx_retro_unload_game,
        .run = psx_retro_run,
        .reset = psx_retro_reset,
        .get_system_av_info = psx_retro_get_system_av_info,
        .serialize_size = psx_retro_serialize_size,
        .serialize = psx_retro_serialize,
        .unserialize = psx_retro_unserialize,
        // Memory card 1, exposed as standard SAVE_RAM because the core's
        // pcsx_rearmed_memcard1 option defaults to "libretro". The only
        // core wired for save RAM so far: PS1 saves have no other home,
        // while cartridge systems still cover themselves with states.
        .get_memory_data = psx_retro_get_memory_data,
        .get_memory_size = psx_retro_get_memory_size,
    };
    return &api;
}
