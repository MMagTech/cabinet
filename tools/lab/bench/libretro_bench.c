// Headless libretro harness, for measuring a core option's cost and proving
// it changed the picture, without an iPhone in the loop.
//
// This is deliberately a copy of what LibretroFrontend.mm answers, not a
// generic frontend: the whole point is that a core sees the same environment
// here as it sees inside Cabinet, including the things Cabinet does NOT
// answer (SET_VARIABLES, SET_CORE_OPTIONS*), because those silences are
// exactly what leaves a core on its own compiled-in defaults. A harness that
// answered them would measure a core Cabinet never runs.
//
// Build: tools/lab/bench/build.sh
// Usage: libretro_bench <core.dylib> <rom> [-o key=value]... [-f frames]
//                       [-s systemdir] [-d dumpdir] [-c csv]
//
// Reports per-frame retro_run wall time, audio frames produced, geometry,
// and a hash per frame so two runs can be compared for "did the output
// actually change" without a human looking at anything.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <time.h>
#include "libretro.h"

#define MAX_OPTS 128
#define MAX_FRAMES 200000

static struct { char key[128]; char value[128]; } g_opts[MAX_OPTS];
static int g_opt_count = 0;
static char g_system_dir[1024] = ".";
static char g_save_dir[1024] = ".";
static char g_dump_dir[1024] = "";

static enum retro_pixel_format g_pixfmt = RETRO_PIXEL_FORMAT_0RGB1555;
static double g_fps = 60.0, g_sample_rate = 44100.0;
static unsigned g_rotation = 0;
static uint64_t g_audio_frames = 0;
static unsigned g_last_w = 0, g_last_h = 0;
static uint64_t g_frame_hash = 0;
// The frame hash is taken inside video_cb, which the core calls from
// inside retro_run, so hashing lands inside the stopwatch that is
// supposed to be timing emulation. Left alone it charges the core for
// the harness's own work, and because the cost scales with the frame
// size it does not cancel out of an A/B that changes geometry: it moves
// the answer in the same direction as the thing being measured. So the
// hash times itself here and the run loop subtracts it.
static double g_hash_ms_frame = 0.0;
static double g_hash_ms[MAX_FRAMES];
static uint64_t g_dupe_frames = 0;
// Audio gets its own running hash: an option that only changes sound (an FM
// chip model, a resampler) leaves every video hash identical, so a video-only
// comparison would report "no effect" for exactly the changes this pass cares
// most about.
static uint64_t g_audio_hash = 1469598103934665603ULL;
static int g_frame_index = 0;
static int g_dump_at[8]; static int g_dump_count = 0;

// Scripted input. A benchmark that never presses a button measures title
// screens, which is exactly the "whole-session means lie" trap: a core sitting
// on a logo draws almost nothing and reports a cost no real scene has. These
// let a run walk itself into an attract demo or past a start prompt.
#define MAX_PRESSES 32
static struct { int frame, id, hold; } g_press[MAX_PRESSES];
static int g_mouse_dx = 0;
static int g_mouse_from = 0;
static int g_press_count = 0;
static int g_warmup = 0;

// Per-frame records.
static double g_run_ms[MAX_FRAMES];
static uint64_t g_hash[MAX_FRAMES];
static unsigned g_w[MAX_FRAMES], g_h[MAX_FRAMES];
static int g_recorded = 0;

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}

// FNV-1a over the visible pixels only, row by row, so a stride change
// that leaves the picture identical does not read as a different picture.
static uint64_t hash_frame(const void *data, unsigned width, unsigned height, size_t pitch) {
    uint64_t h = 1469598103934665603ULL;
    size_t bpp = (g_pixfmt == RETRO_PIXEL_FORMAT_XRGB8888) ? 4 : 2;
    const uint8_t *p = (const uint8_t *)data;
    for (unsigned y = 0; y < height; y++) {
        const uint8_t *row = p + (size_t)y * pitch;
        for (size_t i = 0; i < (size_t)width * bpp; i++) {
            h ^= row[i];
            h *= 1099511628211ULL;
        }
    }
    return h;
}

static void dump_ppm(const char *path, const void *data, unsigned width, unsigned height, size_t pitch) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%u %u\n255\n", width, height);
    for (unsigned y = 0; y < height; y++) {
        const uint8_t *row = (const uint8_t *)data + (size_t)y * pitch;
        for (unsigned x = 0; x < width; x++) {
            uint8_t r, g, b;
            if (g_pixfmt == RETRO_PIXEL_FORMAT_XRGB8888) {
                uint32_t px = ((const uint32_t *)row)[x];
                r = (px >> 16) & 0xff; g = (px >> 8) & 0xff; b = px & 0xff;
            } else if (g_pixfmt == RETRO_PIXEL_FORMAT_RGB565) {
                uint16_t px = ((const uint16_t *)row)[x];
                r = ((px >> 11) & 0x1f) << 3; g = ((px >> 5) & 0x3f) << 2; b = (px & 0x1f) << 3;
            } else {
                uint16_t px = ((const uint16_t *)row)[x];
                r = ((px >> 10) & 0x1f) << 3; g = ((px >> 5) & 0x1f) << 3; b = (px & 0x1f) << 3;
            }
            fputc(r, f); fputc(g, f); fputc(b, f);
        }
    }
    fclose(f);
}

// Panel mode: ask the core itself what this game reads, rather than
// inferring it from a listxml generation that may not match the binary.
// Off by default and answered nowhere else, so an ordinary bench run
// still mirrors LibretroFrontend.mm case for case.
// MAME 2003-Plus works out the whole panel for itself when it loads a
// game: which analog mechanism the cabinet had, how many buttons, how
// many players, how many directions the stick allowed. It keeps that in
// the exported "options" struct as content_flags, and reading it is the
// difference between asking the machine and guessing from a listxml.
//
// The offset is the three mame_file pointers that precede the array in
// struct GameOptions (src/mame.h). Hardcoded rather than shared, because
// the alternative is compiling the lab against core internals; the
// sanity check below is what keeps a silent layout change from turning
// into silent nonsense.
#define CONTENT_FLAGS_OFFSET 24
enum {
    CF_VECTOR = 4, CF_DIAL = 5, CF_TRACKBALL = 6, CF_LIGHTGUN = 7,
    CF_PADDLE = 8, CF_AD_STICK = 9, CF_HAS_PEDAL = 12, CF_HAS_PEDAL2 = 13,
    CF_ALTERNATING = 14, CF_ROTATE_JOY_45 = 16, CF_PLAYER_COUNT = 17,
    CF_CTRL_COUNT = 18, CF_DUAL_JOYSTICK = 19, CF_BUTTON_COUNT = 20,
    CF_LIGHTGUN_COUNT = 21, CF_JOY_DIRECTIONS = 22, CF_COUNT = 25
};

static int g_panel = 0;

struct desc_row { unsigned port, device, index, id; char text[128]; };
#define MAX_DESCS 256
static struct desc_row g_descs[MAX_DESCS];
static int g_desc_count = 0;

static const char *device_name(unsigned d) {
    switch (d & RETRO_DEVICE_MASK) {
    case RETRO_DEVICE_JOYPAD:   return "joypad";
    case RETRO_DEVICE_MOUSE:    return "mouse";
    case RETRO_DEVICE_KEYBOARD: return "keyboard";
    case RETRO_DEVICE_LIGHTGUN: return "lightgun";
    case RETRO_DEVICE_ANALOG:   return "analog";
    case RETRO_DEVICE_POINTER:  return "pointer";
    default:                    return "none";
    }
}

static void log_cb(enum retro_log_level level, const char *fmt, ...) {
    (void)level; (void)fmt;
}

/* Rumble observation, lab only. The app fires a haptic here; this only
 * counts, so a run can answer "did the core ask for the motor at all"
 * with no device and nobody's hand involved. g_rumble_on counts
 * off-to-on edges, the same edge the app turns into one haptic, so it
 * reads as "times the motor was kicked" rather than "times the core
 * mentioned it". Added 2026-08-24 to A/B whether an unanswered rumble
 * option silently disables a core's rumble. */
static int g_rumble_asked = 0;
static long g_rumble_calls = 0, g_rumble_on = 0;
static int g_rumble_was_on[8][2];
static bool rumble_cb(unsigned port, enum retro_rumble_effect effect, uint16_t strength) {
    if (port >= 8 || effect > RETRO_RUMBLE_WEAK) return false;
    g_rumble_calls++;
    int on = strength > 0;
    if (on && !g_rumble_was_on[port][effect]) g_rumble_on++;
    g_rumble_was_on[port][effect] = on;
    return true;
}

// Mirrors LibretroFrontend.mm's environmentCallback case for case. Anything
// it does not answer is not answered here either.
static bool env_cb(unsigned cmd, void *data) {
    switch (cmd) {
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
        const struct retro_system_av_info *info = (const struct retro_system_av_info *)data;
        if (!info) return false;
        if (info->timing.fps > 0) g_fps = info->timing.fps;
        return true;
    }
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        *(const char **)data = g_system_dir; return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        *(const char **)data = g_save_dir; return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        g_pixfmt = *(const enum retro_pixel_format *)data;
        if (getenv("BENCH_TRACE_VARS")) fprintf(stderr, "[fmt] core set pixel format %d\n", (int)g_pixfmt);
        return true;
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
        return true;
    case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE: {
        struct retro_rumble_interface *ri = (struct retro_rumble_interface *)data;
        if (!ri) return false;
        ri->set_rumble_state = rumble_cb;
        g_rumble_asked = 1;
        return true;
    }
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
        *(bool *)data = true; return true;
    case RETRO_ENVIRONMENT_SET_ROTATION:
        g_rotation = *(const unsigned *)data; return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
        ((struct retro_log_callback *)data)->log = log_cb; return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        struct retro_variable *var = (struct retro_variable *)data;
        if (!var || !var->key) return false;
        for (int i = 0; i < g_opt_count; i++) {
            if (!strcmp(g_opts[i].key, var->key)) {
                var->value = g_opts[i].value;
                if (getenv("BENCH_TRACE_VARS")) fprintf(stderr, "[var] %s -> %s\n", var->key, var->value);
                return true;
            }
        }
        if (getenv("BENCH_TRACE_VARS")) fprintf(stderr, "[var] %s -> (unanswered)\n", var->key);
        var->value = NULL;
        return false;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        *(bool *)data = false; return true;
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS: {
        // The app does not answer this, so neither does a normal run.
        if (!g_panel) return false;
        const struct retro_input_descriptor *d =
            (const struct retro_input_descriptor *)data;
        if (!d) return false;
        // The core republishes the whole set on every port assignment,
        // so keep the latest rather than appending four copies of it.
        g_desc_count = 0;
        for (; d->description && g_desc_count < MAX_DESCS; d++) {
            struct desc_row *row = &g_descs[g_desc_count++];
            row->port = d->port; row->device = d->device;
            row->index = d->index; row->id = d->id;
            snprintf(row->text, sizeof(row->text), "%s", d->description);
        }
        return true;
    }
    default:
        return false;
    }
}

static void video_cb(const void *data, unsigned width, unsigned height, size_t pitch) {
    g_last_w = width; g_last_h = height;
    if (!data) { g_dupe_frames++; return; }  // dupe, same as last frame
    double hash_t0 = now_ms();
    g_frame_hash = hash_frame(data, width, height, pitch);
    g_hash_ms_frame += now_ms() - hash_t0;
    if (g_dump_dir[0]) {
        for (int i = 0; i < g_dump_count; i++) {
            // Latching, not exact-match: a 30fps game reports a dupe on half
            // its frames, and a dump asked for on one of those would silently
            // never be written. Arm at the requested frame, fire on the next
            // frame that actually carries pixels.
            if (g_dump_at[i] >= 0 && g_frame_index >= g_dump_at[i]) {
                char path[1200];
                snprintf(path, sizeof(path), "%s/frame-%06d.ppm", g_dump_dir, g_dump_at[i]);
                dump_ppm(path, data, width, height, pitch);
                g_dump_at[i] = -1;
            }
        }
    }
}

static inline void mix_audio_hash(int16_t v) {
    g_audio_hash ^= (uint64_t)(uint16_t)v;
    g_audio_hash *= 1099511628211ULL;
}

static void audio_sample_cb(int16_t l, int16_t r) {
    mix_audio_hash(l); mix_audio_hash(r);
    g_audio_frames++;
}
static size_t audio_batch_cb(const int16_t *data, size_t frames) {
    if (data) {
        for (size_t i = 0; i < frames * 2; i++) mix_audio_hash(data[i]);
    }
    g_audio_frames += frames;
    return frames;
}
static void input_poll_cb(void) {}
static int16_t input_state_cb(unsigned port, unsigned device, unsigned index, unsigned id) {
    (void)index;
    // A steady mouse drift, for asking whether a declared dial does
    // anything. Several drivers declare analog ports their game never
    // reads (the Taito F3 board declares dials once for forty games),
    // and no amount of reading data files settles that. Turning the
    // knob and watching the screen does.
    if (g_mouse_dx && device == RETRO_DEVICE_MOUSE && g_frame_index >= g_mouse_from) {
        if (id == RETRO_DEVICE_ID_MOUSE_X) return (int16_t)g_mouse_dx;
        if (id == RETRO_DEVICE_ID_MOUSE_Y) return 0;
    }
    if (port != 0 || device != RETRO_DEVICE_JOYPAD) return 0;
    for (int i = 0; i < g_press_count; i++) {
        if ((int)id == g_press[i].id &&
            g_frame_index >= g_press[i].frame &&
            g_frame_index < g_press[i].frame + g_press[i].hold) {
            return 1;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <core.dylib> <rom> [-o key=value] [-f frames] [-s sysdir] [-d dumpdir] [-c out.csv] [-P] [-M dx,fromframe]\n", argv[0]);
        return 2;
    }
    const char *core_path = argv[1];
    const char *rom_path = argv[2];
    int frames = 1800;
    const char *csv_path = NULL;

    for (int i = 3; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) {
            char *eq = strchr(argv[++i], '=');
            if (eq && g_opt_count < MAX_OPTS) {
                size_t klen = (size_t)(eq - argv[i]);
                if (klen >= sizeof(g_opts[0].key)) klen = sizeof(g_opts[0].key) - 1;
                memcpy(g_opts[g_opt_count].key, argv[i], klen);
                g_opts[g_opt_count].key[klen] = 0;
                snprintf(g_opts[g_opt_count].value, sizeof(g_opts[0].value), "%s", eq + 1);
                g_opt_count++;
            }
        } else if (!strcmp(argv[i], "-f") && i + 1 < argc) {
            frames = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "-s") && i + 1 < argc) {
            snprintf(g_system_dir, sizeof(g_system_dir), "%s", argv[++i]);
            snprintf(g_save_dir, sizeof(g_save_dir), "%s", argv[i]);
        } else if (!strcmp(argv[i], "-d") && i + 1 < argc) {
            snprintf(g_dump_dir, sizeof(g_dump_dir), "%s", argv[++i]);
        } else if (!strcmp(argv[i], "-c") && i + 1 < argc) {
            csv_path = argv[++i];
        } else if (!strcmp(argv[i], "-M") && i + 1 < argc) {
            sscanf(argv[++i], "%d,%d", &g_mouse_dx, &g_mouse_from);
        } else if (!strcmp(argv[i], "-P")) {
            g_panel = 1;
        } else if (!strcmp(argv[i], "-w") && i + 1 < argc) {
            g_warmup = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "-i") && i + 1 < argc && g_press_count < MAX_PRESSES) {
            // frame,retropad_id,hold_frames
            int fr = 0, bid = 0, hold = 1;
            if (sscanf(argv[++i], "%d,%d,%d", &fr, &bid, &hold) >= 2) {
                g_press[g_press_count].frame = fr;
                g_press[g_press_count].id = bid;
                g_press[g_press_count].hold = hold;
                g_press_count++;
            }
        } else if (!strcmp(argv[i], "--dump-at") && i + 1 < argc) {
            char *tok = strtok(argv[++i], ",");
            while (tok && g_dump_count < 8) { g_dump_at[g_dump_count++] = atoi(tok); tok = strtok(NULL, ","); }
        }
    }
    if (frames > MAX_FRAMES) frames = MAX_FRAMES;

    void *lib = dlopen(core_path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }

    // Typedefs first: a function-pointer type written inline carries a
    // comma, which a macro would split into two arguments.
    typedef void (*set_env_fn)(retro_environment_t);
    typedef void (*set_video_fn)(retro_video_refresh_t);
    typedef void (*set_audio_fn)(retro_audio_sample_t);
    typedef void (*set_audio_batch_fn)(retro_audio_sample_batch_t);
    typedef void (*set_poll_fn)(retro_input_poll_t);
    typedef void (*set_input_fn)(retro_input_state_t);
    typedef void (*void_fn)(void);
    typedef bool (*load_fn)(const struct retro_game_info *);
    typedef void (*av_fn)(struct retro_system_av_info *);

    #define SYM(t, n) t n = (t)dlsym(lib, #n); if (!n) { fprintf(stderr, "missing %s\n", #n); return 1; }
    SYM(set_env_fn, retro_set_environment)
    SYM(set_video_fn, retro_set_video_refresh)
    SYM(set_audio_fn, retro_set_audio_sample)
    SYM(set_audio_batch_fn, retro_set_audio_sample_batch)
    SYM(set_poll_fn, retro_set_input_poll)
    SYM(set_input_fn, retro_set_input_state)
    SYM(void_fn, retro_init)
    SYM(void_fn, retro_deinit)
    SYM(load_fn, retro_load_game)
    SYM(void_fn, retro_unload_game)
    SYM(void_fn, retro_run)
    SYM(av_fn, retro_get_system_av_info)
    typedef void (*port_fn)(unsigned, unsigned);
    port_fn retro_set_controller_port_device = (port_fn)dlsym(lib, "retro_set_controller_port_device");
    #undef SYM

    retro_set_environment(env_cb);
    retro_set_video_refresh(video_cb);
    retro_set_audio_sample(audio_sample_cb);
    retro_set_audio_sample_batch(audio_batch_cb);
    retro_set_input_poll(input_poll_cb);
    retro_set_input_state(input_state_cb);
    retro_init();

    // Read the whole ROM into memory: every core here is a "needs full data"
    // core except the CD ones, which take a path instead. Passing both is
    // what RetroArch does for a core with need_fullpath unset.
    struct retro_game_info info = {0};
    info.path = rom_path;
    FILE *f = fopen(rom_path, "rb");
    if (f) {
        fseek(f, 0, SEEK_END);
        long sz = ftell(f);
        fseek(f, 0, SEEK_SET);
        // Skip the read for anything CD sized; those cores want the path.
        if (sz > 0 && sz < 64L * 1024 * 1024) {
            void *buf = malloc((size_t)sz);
            if (buf && fread(buf, 1, (size_t)sz, f) == (size_t)sz) {
                info.data = buf; info.size = (size_t)sz;
            }
        }
        fclose(f);
    }

    if (!retro_load_game(&info)) {
        fprintf(stderr, "LOAD_FAILED\n");
        return 3;
    }

    // Assign a port device, exactly as NativeLauncher does after every
    // load. This is not optional politeness: MAME 2003-Plus builds its
    // whole OSD-code to MAME-input mapping in response, so a frontend
    // that skips it gets a core that reads no input at all. The bench
    // skipped it, which meant -i input scripting silently did nothing on
    // this core: Arkanoid sat on its title screen reading CREDIT 0 while
    // the harness pressed coin, and every run looked identical because
    // every run was the same untouched attract loop. Panel mode assigns
    // all four ports because the description covers every connected one.
    if (retro_set_controller_port_device) {
        unsigned ports = g_panel ? 4 : 2;
        for (unsigned port = 0; port < ports; port++) {
            retro_set_controller_port_device(port, RETRO_DEVICE_JOYPAD);
        }
    }

    struct retro_system_av_info av = {0};
    retro_get_system_av_info(&av);
    if (av.timing.fps > 0) g_fps = av.timing.fps;
    if (av.timing.sample_rate > 0) g_sample_rate = av.timing.sample_rate;

    // Warmup frames run but are not measured and not hashed into the totals:
    // boot logos and first-load allocation are not the workload.
    double t_all = 0;
    for (int i = 0; i < frames; i++) {
        if (i == g_warmup) { t_all = now_ms(); g_audio_frames = 0; }
        g_frame_index = i;
        g_hash_ms_frame = 0.0;
        double t0 = now_ms();
        retro_run();
        // Emulation only: the harness's own hashing ran inside this
        // window, via the core's call to video_cb, and comes back out.
        double dt = now_ms() - t0 - g_hash_ms_frame;
        if (dt < 0) dt = 0;
        if (i >= g_warmup && g_recorded < MAX_FRAMES) {
            g_run_ms[g_recorded] = dt;
            g_hash_ms[g_recorded] = g_hash_ms_frame;
            g_hash[g_recorded] = g_frame_hash;
            g_w[g_recorded] = g_last_w;
            g_h[g_recorded] = g_last_h;
            g_recorded++;
        }
    }
    double wall = now_ms() - t_all;
    int measured_frames = frames - g_warmup;
    if (measured_frames < 1) measured_frames = 1;

    if (csv_path) {
        FILE *c = fopen(csv_path, "w");
        if (c) {
            fprintf(c, "frame,run_ms,width,height,hash\n");
            for (int i = 0; i < g_recorded; i++)
                fprintf(c, "%d,%.4f,%u,%u,%llu\n", i, g_run_ms[i], g_w[i], g_h[i],
                        (unsigned long long)g_hash[i]);
            fclose(c);
        }
    }

    // Sorted copy for percentiles.
    for (int i = 1; i < g_recorded; i++) {
        double v = g_run_ms[i]; int j = i - 1;
        while (j >= 0 && g_run_ms[j] > v) { g_run_ms[j + 1] = g_run_ms[j]; j--; }
        g_run_ms[j + 1] = v;
    }
    double median = g_recorded ? g_run_ms[g_recorded / 2] : 0;
    double p95 = g_recorded ? g_run_ms[(int)(g_recorded * 0.95)] : 0;
    double p99 = g_recorded ? g_run_ms[(int)(g_recorded * 0.99)] : 0;
    double mean = 0;
    for (int i = 0; i < g_recorded; i++) mean += g_run_ms[i];
    mean = g_recorded ? mean / g_recorded : 0;

    // One combined hash over every frame, so two runs compare in one number.
    uint64_t total = 1469598103934665603ULL;
    for (int i = 0; i < g_recorded; i++) {
        total ^= g_hash[i];
        total *= 1099511628211ULL;
    }

    double emulated_ms = measured_frames * 1000.0 / (g_fps > 0 ? g_fps : 60.0);
    double audio_expected = emulated_ms / 1000.0 * g_sample_rate;

    // Panel mode reports what the core asked for and stops. One line per
    // control the game actually reads, straight from the binary that will
    // run it, which is the only source that cannot disagree with itself.
    if (g_panel) {
        const int *cf = NULL;
        void *opts = dlsym(lib, "options");
        if (opts) cf = (const int *)((const char *)opts + CONTENT_FLAGS_OFFSET);
        // A wrong offset reads neighbouring memory and would look like
        // data. Player and button counts have known bounds, so check them
        // rather than trust the struct has not moved.
        if (cf && (cf[CF_PLAYER_COUNT] < 0 || cf[CF_PLAYER_COUNT] > 8 ||
                   cf[CF_BUTTON_COUNT] < 0 || cf[CF_BUTTON_COUNT] > 16)) {
            fprintf(stderr, "content_flags look wrong, refusing to report them\n");
            cf = NULL;
        }
        printf("PANEL\t%s\trotation=%u\twidth=%u\theight=%u\tdescs=%d\n",
               rom_path, g_rotation, g_last_w, g_last_h, g_desc_count);
        if (cf) {
            printf("FLAGS\t%s\tplayers=%d\tctrls=%d\tbuttons=%d\tdirections=%d"
                   "\tdial=%d\ttrackball=%d\tlightgun=%d\tguns=%d\tpaddle=%d\tadstick=%d"
                   "\tpedal=%d\tpedal2=%d\tdualjoy=%d\talternating=%d\trotate45=%d\tvector=%d\n",
                   rom_path, cf[CF_PLAYER_COUNT], cf[CF_CTRL_COUNT], cf[CF_BUTTON_COUNT],
                   cf[CF_JOY_DIRECTIONS], cf[CF_DIAL], cf[CF_TRACKBALL], cf[CF_LIGHTGUN],
                   cf[CF_LIGHTGUN_COUNT], cf[CF_PADDLE], cf[CF_AD_STICK], cf[CF_HAS_PEDAL],
                   cf[CF_HAS_PEDAL2], cf[CF_DUAL_JOYSTICK], cf[CF_ALTERNATING],
                   cf[CF_ROTATE_JOY_45], cf[CF_VECTOR]);
        }
        for (int i = 0; i < g_desc_count; i++) {
            printf("DESC\t%s\t%u\t%s\t%u\t%u\t%s\n", rom_path,
                   g_descs[i].port, device_name(g_descs[i].device),
                   g_descs[i].index, g_descs[i].id, g_descs[i].text);
        }
        fflush(stdout);
        retro_unload_game();
        retro_deinit();
        return 0;
    }

    printf("{\n");
    printf("  \"core\": \"%s\",\n", core_path);
    printf("  \"rom\": \"%s\",\n", rom_path);
    printf("  \"frames\": %d,\n", measured_frames);
    printf("  \"warmup\": %d,\n", g_warmup);
    printf("  \"fps_declared\": %.4f,\n", g_fps);
    printf("  \"sample_rate\": %.1f,\n", g_sample_rate);
    printf("  \"wall_ms\": %.2f,\n", wall);
    printf("  \"run_ms_mean\": %.4f,\n", mean);
    printf("  \"run_ms_median\": %.4f,\n", median);
    // What the harness itself cost, excluded from run_ms above. Reported
    // rather than hidden: it is the size of the error every number this
    // tool produced before 2026-08-20 carried, and it scales with the
    // frame, so it is the first thing to look at when an old result and a
    // new one disagree.
    {
        double hash_total = 0;
        for (int i = 0; i < g_recorded; i++) hash_total += g_hash_ms[i];
        printf("  \"hash_ms_mean_excluded\": %.4f,\n",
               g_recorded ? hash_total / g_recorded : 0.0);
    }
    printf("  \"run_ms_p95\": %.4f,\n", p95);
    printf("  \"run_ms_p99\": %.4f,\n", p99);
    printf("  \"realtime_ratio\": %.3f,\n", emulated_ms / wall);
    printf("  \"audio_frames\": %llu,\n", (unsigned long long)g_audio_frames);
    printf("  \"audio_expected\": %.0f,\n", audio_expected);
    printf("  \"audio_ratio\": %.4f,\n", audio_expected > 0 ? g_audio_frames / audio_expected : 0);
    printf("  \"dupe_frames\": %llu,\n", (unsigned long long)g_dupe_frames);
    printf("  \"width\": %u,\n", g_last_w);
    printf("  \"height\": %u,\n", g_last_h);
    printf("  \"rotation\": %u,\n", g_rotation);
    printf("  \"pixel_format\": %d,\n", (int)g_pixfmt);
    printf("  \"rumble_interface_requested\": %d,\n", g_rumble_asked);
    printf("  \"rumble_edges\": %ld,\n", g_rumble_on);
    printf("  \"rumble_calls\": %ld,\n", g_rumble_calls);
    printf("  \"output_hash\": \"%llu\",\n", (unsigned long long)total);
    printf("  \"audio_hash\": \"%llu\"\n", (unsigned long long)g_audio_hash);
    printf("}\n");

    retro_unload_game();
    retro_deinit();
    return 0;
}
