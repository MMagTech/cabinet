#import "OperaCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
// No get_memory_data/get_memory_size here on purpose: Opera answers
// RETRO_MEMORY_SAVE_RAM with NULL. The 3DO's battery-backed NVRAM is a
// file the core itself writes into the save directory at unload
// (opera/shared/nvram.0.srm under the options this app forces), synced
// through the same file path Sega CD and Neo Geo Pocket use.
extern "C" {
    unsigned opr_retro_api_version(void);
    void opr_retro_get_system_info(struct retro_system_info *);
    void opr_retro_set_environment(retro_environment_t);
    void opr_retro_set_video_refresh(retro_video_refresh_t);
    void opr_retro_set_audio_sample(retro_audio_sample_t);
    void opr_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void opr_retro_set_input_poll(retro_input_poll_t);
    void opr_retro_set_input_state(retro_input_state_t);
    void opr_retro_set_controller_port_device(unsigned, unsigned);
    void opr_retro_init(void);
    void opr_retro_deinit(void);
    bool opr_retro_load_game(const struct retro_game_info *);
    void opr_retro_unload_game(void);
    void opr_retro_run(void);
    void opr_retro_reset(void);
    void opr_retro_get_system_av_info(struct retro_system_av_info *);
    size_t opr_retro_serialize_size(void);
    bool opr_retro_serialize(void *, size_t);
    bool opr_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *OperaCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = opr_retro_api_version,
        .get_system_info = opr_retro_get_system_info,
        .set_environment = opr_retro_set_environment,
        .set_video_refresh = opr_retro_set_video_refresh,
        .set_audio_sample = opr_retro_set_audio_sample,
        .set_audio_sample_batch = opr_retro_set_audio_sample_batch,
        .set_input_poll = opr_retro_set_input_poll,
        .set_input_state = opr_retro_set_input_state,
        .set_controller_port_device = opr_retro_set_controller_port_device,
        .init = opr_retro_init,
        .deinit = opr_retro_deinit,
        .load_game = opr_retro_load_game,
        .unload_game = opr_retro_unload_game,
        .run = opr_retro_run,
        .reset = opr_retro_reset,
        .get_system_av_info = opr_retro_get_system_av_info,
        .serialize_size = opr_retro_serialize_size,
        .serialize = opr_retro_serialize,
        .unserialize = opr_retro_unserialize,
    };
    return &api;
}
