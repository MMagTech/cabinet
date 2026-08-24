#import "PPSSPPCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-ppsspp.sh for where the prefix comes from.
// No memory API: PSP games save to memory-stick directories under the
// frontend's save directory (g_Config.memStickDirectory), whole folders
// of files per game, not RETRO_MEMORY_SAVE_RAM. Syncing those is its
// own future feature; nothing rides the SAVE_RAM path.
extern "C" {
    unsigned psp_retro_api_version(void);
    void psp_retro_get_system_info(struct retro_system_info *);
    void psp_retro_set_environment(retro_environment_t);
    void psp_retro_set_video_refresh(retro_video_refresh_t);
    void psp_retro_set_audio_sample(retro_audio_sample_t);
    void psp_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void psp_retro_set_input_poll(retro_input_poll_t);
    void psp_retro_set_input_state(retro_input_state_t);
    void psp_retro_set_controller_port_device(unsigned, unsigned);
    void psp_retro_init(void);
    void psp_retro_deinit(void);
    bool psp_retro_load_game(const struct retro_game_info *);
    void psp_retro_unload_game(void);
    void psp_retro_run(void);
    void psp_retro_reset(void);
    void psp_retro_get_system_av_info(struct retro_system_av_info *);
    size_t psp_retro_serialize_size(void);
    bool psp_retro_serialize(void *, size_t);
    bool psp_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *PPSSPPCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = psp_retro_api_version,
        .get_system_info = psp_retro_get_system_info,
        .set_environment = psp_retro_set_environment,
        .set_video_refresh = psp_retro_set_video_refresh,
        .set_audio_sample = psp_retro_set_audio_sample,
        .set_audio_sample_batch = psp_retro_set_audio_sample_batch,
        .set_input_poll = psp_retro_set_input_poll,
        .set_input_state = psp_retro_set_input_state,
        .set_controller_port_device = psp_retro_set_controller_port_device,
        .init = psp_retro_init,
        .deinit = psp_retro_deinit,
        .load_game = psp_retro_load_game,
        .unload_game = psp_retro_unload_game,
        .run = psp_retro_run,
        .reset = psp_retro_reset,
        .get_system_av_info = psp_retro_get_system_av_info,
        .serialize_size = psp_retro_serialize_size,
        .serialize = psp_retro_serialize,
        .unserialize = psp_retro_unserialize,
    };
    return &api;
}
