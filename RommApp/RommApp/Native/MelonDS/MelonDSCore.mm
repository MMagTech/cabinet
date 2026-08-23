#import "MelonDSCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
// No memory API: this fork answers RETRO_MEMORY_SAVE_RAM with NULL and
// manages the cartridge save itself, writing <save dir>/<game>.sav
// through its own NDSCart_SRAMManager, so in-game saves ride the
// segaCD/ngpc file path, not SAVE_RAM.
extern "C" {
    unsigned mds_retro_api_version(void);
    void mds_retro_get_system_info(struct retro_system_info *);
    void mds_retro_set_environment(retro_environment_t);
    void mds_retro_set_video_refresh(retro_video_refresh_t);
    void mds_retro_set_audio_sample(retro_audio_sample_t);
    void mds_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void mds_retro_set_input_poll(retro_input_poll_t);
    void mds_retro_set_input_state(retro_input_state_t);
    void mds_retro_set_controller_port_device(unsigned, unsigned);
    void mds_retro_init(void);
    void mds_retro_deinit(void);
    bool mds_retro_load_game(const struct retro_game_info *);
    void mds_retro_unload_game(void);
    void mds_retro_run(void);
    void mds_retro_reset(void);
    void mds_retro_get_system_av_info(struct retro_system_av_info *);
    size_t mds_retro_serialize_size(void);
    bool mds_retro_serialize(void *, size_t);
    bool mds_retro_unserialize(const void *, size_t);
}

const LibretroCoreAPI *MelonDSCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = mds_retro_api_version,
        .get_system_info = mds_retro_get_system_info,
        .set_environment = mds_retro_set_environment,
        .set_video_refresh = mds_retro_set_video_refresh,
        .set_audio_sample = mds_retro_set_audio_sample,
        .set_audio_sample_batch = mds_retro_set_audio_sample_batch,
        .set_input_poll = mds_retro_set_input_poll,
        .set_input_state = mds_retro_set_input_state,
        .set_controller_port_device = mds_retro_set_controller_port_device,
        .init = mds_retro_init,
        .deinit = mds_retro_deinit,
        .load_game = mds_retro_load_game,
        .unload_game = mds_retro_unload_game,
        .run = mds_retro_run,
        .reset = mds_retro_reset,
        .get_system_av_info = mds_retro_get_system_av_info,
        .serialize_size = mds_retro_serialize_size,
        .serialize = mds_retro_serialize,
        .unserialize = mds_retro_unserialize,
    };
    return &api;
}
