// dclab: the Mac Dreamcast lab's go/no-go spike. Boots the macOS Flycast
// libretro core headless with a CGL offscreen context and reports whether
// frames and audio arrive. Success = the lab is viable.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <GLES3/gl3.h>
static void *eglLib, *glesLib;
static EGLDisplay eglDpy; static EGLContext eglCtx; static EGLSurface eglSurf;
#include "libretro.h"

static GLuint fbo, colorTex, depthRb;
static unsigned fboW = 640, fboH = 480;
static uint64_t frames, dupes, audioFrames;
static struct retro_hw_render_callback hw;

static uintptr_t get_fb(void) { return fbo; }
static retro_proc_address_t get_proc(const char *sym) {
    void *p = dlsym(glesLib, sym);
    if (!p) p = (void *)eglGetProcAddress(sym);
    return (retro_proc_address_t)p;
}
#include <stdarg.h>
static void log_cb(enum retro_log_level level, const char *fmt, ...) {
    if (level < RETRO_LOG_INFO) return;
    va_list ap; va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
}

static const char *SYSDIR = NULL, *SAVEDIR = NULL;

static bool env_cb(unsigned cmd, void *data) {
    static int seen[256];
    unsigned base = cmd & 0xFF;
    if (base < 256 && !seen[base]++) printf("  env cmd %u%s\n", base, (cmd & 0x10000) ? " (exp)" : "");
    switch (cmd) {
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: *(const char **)data = SYSDIR; return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:   *(const char **)data = SAVEDIR; return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
        ((struct retro_log_callback *)data)->log = log_cb; return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        struct retro_variable *v = (struct retro_variable *)data;
        printf("  GET_VARIABLE %s\n", v->key);
        /* Generic override: CAB_OPT_<key>=<value> in the environment
         * answers any core option, e.g. CAB_OPT_reicast_sh4clock=400. */
        {
            char envkey[128];
            snprintf(envkey, sizeof(envkey), "CAB_OPT_%s", v->key);
            const char *ov = getenv(envkey);
            if (ov != NULL) { v->value = ov; return true; }
        }
        if (!strcmp(v->key, "reicast_hle_bios")) { v->value = "enabled"; return true; }
        if (!strcmp(v->key, "reicast_threaded_rendering")) { v->value = "enabled"; return true; }
        v->value = NULL; return false;
    }
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
        *(unsigned *)data = RETRO_HW_CONTEXT_OPENGLES3;
        return true;
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        struct retro_hw_render_callback *h = (struct retro_hw_render_callback *)data;
        if (h->context_type != RETRO_HW_CONTEXT_OPENGLES2
            && h->context_type != RETRO_HW_CONTEXT_OPENGLES3
            && h->context_type != RETRO_HW_CONTEXT_OPENGLES_VERSION) {
            printf("  SET_HW_RENDER rejected (context_type=%u)\n", h->context_type);
            return false;
        }
        h->get_current_framebuffer = get_fb;
        h->get_proc_address = get_proc;
        hw = *h;
        printf("  SET_HW_RENDER accepted (context_type=%u)\n", h->context_type);
        return true;
    }
    default: return false;
    }
}

static void video_cb(const void *data, unsigned w, unsigned h, size_t pitch) {
    (void)pitch;
    if (data == NULL) { dupes++; return; }
    frames++;
    if (frames <= 3 || frames % 300 == 0)
        printf("  frame %llu (%ux%u)%s\n", frames, w, h,
               data == RETRO_HW_FRAME_BUFFER_VALID ? " [hw]" : "");
}
static void audio_sample_cb(int16_t l, int16_t r) { (void)l; (void)r; audioFrames++; }
static size_t audio_batch_cb(const int16_t *d, size_t n) { (void)d; audioFrames += n; return n; }
static void input_poll_cb(void) {}
static int16_t input_state_cb(unsigned port, unsigned dev, unsigned idx, unsigned id) {
    (void)port; (void)dev; (void)idx; (void)id; return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);  // survive crashes
    if (argc < 4) { fprintf(stderr, "usage: dclab core.dylib rom sysdir\n"); return 2; }
    SYSDIR = argv[3]; SAVEDIR = argv[3];

    // ANGLE: GLES3 on Metal via EGL, offscreen pbuffer, no window.
    eglLib  = dlopen(getenv("ANGLE_EGL"),  RTLD_NOW | RTLD_GLOBAL);
    glesLib = dlopen(getenv("ANGLE_GLES"), RTLD_NOW | RTLD_GLOBAL);
    if (!eglLib || !glesLib) { fprintf(stderr, "ANGLE dylibs not loaded: %s\n", dlerror()); return 1; }

    eglDpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major, minor;
    if (!eglInitialize(eglDpy, &major, &minor)) { fprintf(stderr, "eglInitialize failed\n"); return 1; }
    printf("EGL %d.%d via %s\n", major, minor, eglQueryString(eglDpy, EGL_VENDOR));

    EGLint cfgAttrs[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8,
                          EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
                          EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE };
    EGLConfig cfg; EGLint nCfg;
    if (!eglChooseConfig(eglDpy, cfgAttrs, &cfg, 1, &nCfg) || nCfg < 1) { fprintf(stderr, "no EGL config\n"); return 1; }
    EGLint pbAttrs[] = { EGL_WIDTH, (EGLint)fboW, EGL_HEIGHT, (EGLint)fboH, EGL_NONE };
    eglSurf = eglCreatePbufferSurface(eglDpy, cfg, pbAttrs);
    EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    eglCtx = eglCreateContext(eglDpy, cfg, EGL_NO_CONTEXT, ctxAttrs);
    if (eglCtx == EGL_NO_CONTEXT) { fprintf(stderr, "no EGL context\n"); return 1; }
    eglMakeCurrent(eglDpy, eglSurf, eglSurf, eglCtx);
    printf("GL context: %s / %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));

    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glGenTextures(1, &colorTex);
    glBindTexture(GL_TEXTURE_2D, colorTex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, fboW, fboH, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, colorTex, 0);
    glGenRenderbuffers(1, &depthRb);
    glBindRenderbuffer(GL_RENDERBUFFER, depthRb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, fboW, fboH);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthRb);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, depthRb);
    printf("FBO status: 0x%x (0x8cd5 = complete)\n", glCheckFramebufferStatus(GL_FRAMEBUFFER));
    printf("GL error after harness setup: 0x%x\n", glGetError());

    void *core = dlopen(argv[1], RTLD_NOW);
    if (!core) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    #define SYM(name) __typeof__(name) *name##_p = dlsym(core, #name)
    SYM(retro_set_environment); SYM(retro_init); SYM(retro_set_video_refresh);
    SYM(retro_set_audio_sample); SYM(retro_set_audio_sample_batch);
    SYM(retro_set_input_poll); SYM(retro_set_input_state);
    SYM(retro_load_game); SYM(retro_run); SYM(retro_unload_game); SYM(retro_deinit);

    retro_set_environment_p(env_cb);
    retro_init_p();
    retro_set_video_refresh_p(video_cb);
    retro_set_audio_sample_p(audio_sample_cb);
    retro_set_audio_sample_batch_p(audio_batch_cb);
    retro_set_input_poll_p(input_poll_cb);
    retro_set_input_state_p(input_state_cb);

    struct retro_game_info info = {0};
    info.path = argv[2];
    printf("loading %s ...\n", argv[2]);
    if (!retro_load_game_p(&info)) { fprintf(stderr, "retro_load_game FAILED\n"); return 1; }
    if (hw.context_reset) hw.context_reset();
    printf("GL error after context_reset: 0x%x\n", glGetError());

    printf("running 600 frames...\n");
    uint64_t t0 = mach_absolute_time();
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double rbTotalMs = 0; int rbSamples = 0;
    static uint8_t rbBuf[640*480*4];
    int totalFrames = argc > 4 ? atoi(argv[4]) : 600;
    for (int i = 0; i < totalFrames; i++) {
        if (i < 5 || i % 60 == 0) printf("  run %d (frames so far %llu)\n", i, (unsigned long long)frames);
        retro_run_p();
        // The readback benchmark: the exact operation the Cabinet
        // frontend performs per frame, measured here under ANGLE.
        if (i >= 100 && i < 400) {
            glBindFramebuffer(GL_FRAMEBUFFER, fbo);
            glPixelStorei(GL_PACK_ALIGNMENT, 1);
            uint64_t r0 = mach_absolute_time();
            glReadPixels(0, 0, fboW, fboH, GL_RGBA, GL_UNSIGNED_BYTE, rbBuf);
            uint64_t r1 = mach_absolute_time();
            rbTotalMs += (double)(r1 - r0) * tb.numer / tb.denom / 1e6;
            rbSamples++;
        }
    }
    uint64_t t1 = mach_absolute_time();
    double wallMs = (double)(t1 - t0) * tb.numer / tb.denom / 1e6;
    printf("WALL: %.0fms for %d frames (%.2fx realtime at 60fps)\n", wallMs, totalFrames, totalFrames / 60.0 * 1000.0 / wallMs);
    printf("READBACK under ANGLE: mean %.3fms over %d frames (device floor on Apple GLES: 4.4ms)\n",
           rbSamples ? rbTotalMs / rbSamples : 0, rbSamples);

    printf("RESULT: frames=%llu dupes=%llu audio_frames=%llu\n", frames, dupes, audioFrames);
    printf(frames > 60 && audioFrames > 44100 ? "GO: lab is viable\n" : "NO-GO: core ran but produced too little\n");
    retro_unload_game_p();
    return frames > 60 ? 0 : 1;
}
