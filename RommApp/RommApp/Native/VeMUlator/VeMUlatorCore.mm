#import "VeMUlatorCore.h"

// The prefixed libretro API, resolved from the core's static archive at
// link time. See tools/build-core.sh for where the prefix comes from.
//
// Serialize is wired but honest, the same shape as Game & Watch: this
// core's retro_serialize returns false and its serialize_size is zero,
// so save states DO NOT exist for the VMU player. Nothing is lost: the
// card file IS the persistence, written through in real time by the
// core itself (enable_flash_write). The memory API is stubbed to NULL
// in the core for the same reason, the card file is the save.
//
// One warning that must outlive everyone's memory of why: NEVER map
// anything to RETRO_DEVICE_ID_JOYPAD_START. The core's own processInput
// deliberately comments MODE out ("Clicking MODE without a BIOS causes
// hang", main.cpp) because the HLE boot has no BIOS menu to return to.
// Cabinet's MENU pill is frontend-side for exactly this reason.
extern "C" {
    unsigned vmu_retro_api_version(void);
    void vmu_retro_get_system_info(struct retro_system_info *);
    void vmu_retro_set_environment(retro_environment_t);
    void vmu_retro_set_video_refresh(retro_video_refresh_t);
    void vmu_retro_set_audio_sample(retro_audio_sample_t);
    void vmu_retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void vmu_retro_set_input_poll(retro_input_poll_t);
    void vmu_retro_set_input_state(retro_input_state_t);
    void vmu_retro_set_controller_port_device(unsigned, unsigned);
    void vmu_retro_init(void);
    void vmu_retro_deinit(void);
    bool vmu_retro_load_game(const struct retro_game_info *);
    void vmu_retro_unload_game(void);
    void vmu_retro_run(void);
    void vmu_retro_reset(void);
    void vmu_retro_get_system_av_info(struct retro_system_av_info *);
    size_t vmu_retro_serialize_size(void);
    bool vmu_retro_serialize(void *, size_t);
    bool vmu_retro_unserialize(const void *, size_t);
    void *vmu_retro_get_memory_data(unsigned);
    size_t vmu_retro_get_memory_size(unsigned);
}

const LibretroCoreAPI *VeMUlatorCoreAPI(void) {
    static const LibretroCoreAPI api = {
        .api_version = vmu_retro_api_version,
        .get_system_info = vmu_retro_get_system_info,
        .set_environment = vmu_retro_set_environment,
        .set_video_refresh = vmu_retro_set_video_refresh,
        .set_audio_sample = vmu_retro_set_audio_sample,
        .set_audio_sample_batch = vmu_retro_set_audio_sample_batch,
        .set_input_poll = vmu_retro_set_input_poll,
        .set_input_state = vmu_retro_set_input_state,
        .set_controller_port_device = vmu_retro_set_controller_port_device,
        .init = vmu_retro_init,
        .deinit = vmu_retro_deinit,
        .load_game = vmu_retro_load_game,
        .unload_game = vmu_retro_unload_game,
        .run = vmu_retro_run,
        .reset = vmu_retro_reset,
        .get_system_av_info = vmu_retro_get_system_av_info,
        .serialize_size = vmu_retro_serialize_size,
        .serialize = vmu_retro_serialize,
        .unserialize = vmu_retro_unserialize,
        .get_memory_data = vmu_retro_get_memory_data,
        .get_memory_size = vmu_retro_get_memory_size,
    };
    return &api;
}
