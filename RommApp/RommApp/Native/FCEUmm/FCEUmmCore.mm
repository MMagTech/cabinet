#import "FCEUmmCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
extern "C" {
    unsigned fcm_retro_api_version(void);
    void fcm_retro_get_system_info(struct retro_system_info *);
    void fcm_retro_set_environment(retro_environment_t);
    void fcm_retro_set_video_refresh(retro_video_refresh_t);
    void fcm_retro_set_audio_sample(retro_audio_sample_t);
    void fcm_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void fcm_retro_set_input_poll(retro_input_poll_t);
    void fcm_retro_set_input_state(retro_input_state_t);
    void fcm_retro_set_controller_port_device(unsigned, unsigned);
    void fcm_retro_init(void);
    void fcm_retro_deinit(void);
    bool fcm_retro_load_game(const struct retro_game_info *);
    void fcm_retro_unload_game(void);
    void fcm_retro_run(void);
    void fcm_retro_reset(void);
    void fcm_retro_get_system_av_info(struct retro_system_av_info *);
    size_t fcm_retro_serialize_size(void);
    bool fcm_retro_serialize(void *, size_t);
    bool fcm_retro_unserialize(const void *, size_t);
    void *fcm_retro_get_memory_data(unsigned);
    size_t fcm_retro_get_memory_size(unsigned);
}

const LibretroCoreAPI *FCEUmmCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = fcm_retro_api_version,
        .get_system_info = fcm_retro_get_system_info,
        .set_environment = fcm_retro_set_environment,
        .set_video_refresh = fcm_retro_set_video_refresh,
        .set_audio_sample = fcm_retro_set_audio_sample,
        .set_audio_sample_batch = fcm_retro_set_audio_sample_batch,
        .set_input_poll = fcm_retro_set_input_poll,
        .set_input_state = fcm_retro_set_input_state,
        .set_controller_port_device = fcm_retro_set_controller_port_device,
        .init = fcm_retro_init,
        .deinit = fcm_retro_deinit,
        .load_game = fcm_retro_load_game,
        .unload_game = fcm_retro_unload_game,
        .run = fcm_retro_run,
        .reset = fcm_retro_reset,
        .get_system_av_info = fcm_retro_get_system_av_info,
        .serialize_size = fcm_retro_serialize_size,
        .serialize = fcm_retro_serialize,
        .unserialize = fcm_retro_unserialize,
        // Cartridge battery RAM, only offered when the board actually has
        // a battery. One surprise: for Famicom Disk System games this
        // region is the entire live disk image, hundreds of kilobytes
        // rather than a few, which is correct, the disk is the save.
        .get_memory_data = fcm_retro_get_memory_data,
        .get_memory_size = fcm_retro_get_memory_size,
    };
    return &api;
}
