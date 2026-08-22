#import "VecxCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
// No get_memory_data/get_memory_size here on purpose: vecx exposes only
// RETRO_MEMORY_SYSTEM_RAM, and no Vectrex cartridge had battery saves.
extern "C" {
    unsigned vcx_retro_api_version(void);
    void vcx_retro_get_system_info(struct retro_system_info *);
    void vcx_retro_set_environment(retro_environment_t);
    void vcx_retro_set_video_refresh(retro_video_refresh_t);
    void vcx_retro_set_audio_sample(retro_audio_sample_t);
    void vcx_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void vcx_retro_set_input_poll(retro_input_poll_t);
    void vcx_retro_set_input_state(retro_input_state_t);
    void vcx_retro_set_controller_port_device(unsigned, unsigned);
    void vcx_retro_init(void);
    void vcx_retro_deinit(void);
    bool vcx_retro_load_game(const struct retro_game_info *);
    void vcx_retro_unload_game(void);
    void vcx_retro_run(void);
    void vcx_retro_reset(void);
    void vcx_retro_get_system_av_info(struct retro_system_av_info *);
    size_t vcx_retro_serialize_size(void);
    bool vcx_retro_serialize(void *, size_t);
    bool vcx_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *VecxCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = vcx_retro_api_version,
        .get_system_info = vcx_retro_get_system_info,
        .set_environment = vcx_retro_set_environment,
        .set_video_refresh = vcx_retro_set_video_refresh,
        .set_audio_sample = vcx_retro_set_audio_sample,
        .set_audio_sample_batch = vcx_retro_set_audio_sample_batch,
        .set_input_poll = vcx_retro_set_input_poll,
        .set_input_state = vcx_retro_set_input_state,
        .set_controller_port_device = vcx_retro_set_controller_port_device,
        .init = vcx_retro_init,
        .deinit = vcx_retro_deinit,
        .load_game = vcx_retro_load_game,
        .unload_game = vcx_retro_unload_game,
        .run = vcx_retro_run,
        .reset = vcx_retro_reset,
        .get_system_av_info = vcx_retro_get_system_av_info,
        .serialize_size = vcx_retro_serialize_size,
        .serialize = vcx_retro_serialize,
        .unserialize = vcx_retro_unserialize,
    };
    return &api;
}
