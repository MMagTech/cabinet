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
// Build: tools/bench/build.sh
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

static void log_cb(enum retro_log_level level, const char *fmt, ...) {
    (void)level; (void)fmt;
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
        fprintf(stderr, "usage: %s <core.dylib> <rom> [-o key=value] [-f frames] [-s sysdir] [-d dumpdir] [-c out.csv]\n", argv[0]);
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
    printf("  \"output_hash\": \"%llu\",\n", (unsigned long long)total);
    printf("  \"audio_hash\": \"%llu\"\n", (unsigned long long)g_audio_hash);
    printf("}\n");

    retro_unload_game();
    retro_deinit();
    return 0;
}
