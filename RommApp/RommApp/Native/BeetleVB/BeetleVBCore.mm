#import "BeetleVBCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
// No memory API: the Virtual Boy's few battery-backed carts are not
// exposed through RETRO_MEMORY_SAVE_RAM by this core.
extern "C" {
    unsigned vb_retro_api_version(void);
    void vb_retro_get_system_info(struct retro_system_info *);
    void vb_retro_set_environment(retro_environment_t);
    void vb_retro_set_video_refresh(retro_video_refresh_t);
    void vb_retro_set_audio_sample(retro_audio_sample_t);
    void vb_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void vb_retro_set_input_poll(retro_input_poll_t);
    void vb_retro_set_input_state(retro_input_state_t);
    void vb_retro_set_controller_port_device(unsigned, unsigned);
    void vb_retro_init(void);
    void vb_retro_deinit(void);
    bool vb_retro_load_game(const struct retro_game_info *);
    void vb_retro_unload_game(void);
    void vb_retro_run(void);
    void vb_retro_reset(void);
    void vb_retro_get_system_av_info(struct retro_system_av_info *);
    size_t vb_retro_serialize_size(void);
    bool vb_retro_serialize(void *, size_t);
    bool vb_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *BeetleVBCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = vb_retro_api_version,
        .get_system_info = vb_retro_get_system_info,
        .set_environment = vb_retro_set_environment,
        .set_video_refresh = vb_retro_set_video_refresh,
        .set_audio_sample = vb_retro_set_audio_sample,
        .set_audio_sample_batch = vb_retro_set_audio_sample_batch,
        .set_input_poll = vb_retro_set_input_poll,
        .set_input_state = vb_retro_set_input_state,
        .set_controller_port_device = vb_retro_set_controller_port_device,
        .init = vb_retro_init,
        .deinit = vb_retro_deinit,
        .load_game = vb_retro_load_game,
        .unload_game = vb_retro_unload_game,
        .run = vb_retro_run,
        .reset = vb_retro_reset,
        .get_system_av_info = vb_retro_get_system_av_info,
        .serialize_size = vb_retro_serialize_size,
        .serialize = vb_retro_serialize,
        .unserialize = vb_retro_unserialize,
    };
    return &api;
}
