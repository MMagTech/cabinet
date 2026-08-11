#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut libretro_vertex(const device VertexIn *vertices [[buffer(0)]], uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.texCoord = vertices[vid].texCoord;
    return out;
}

// Sharp (none), the default: a plain nearest-sampled passthrough with no
// filter, matching what the native player has always rendered.
fragment float4 libretro_fragment(VertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                sampler samp [[sampler(0)]]) {
    return tex.sample(samp, in.texCoord);
}

// Decodes a raw RGB565 frame straight from the GPU instead of the CPU
// scalar loop updateTexture used to run per pixel: NativePlayerRenderer
// uploads the packed 16-bit samples untouched into an r16Uint texture,
// and this runs as a blit pass into the real bgra8Unorm target so every
// existing shader downstream keeps sampling a normal float texture like
// before. Bit layout is libretro's own RETRO_PIXEL_FORMAT_RGB565: bits
// 15-11 red, 10-5 green, 4-0 blue.
fragment float4 shader_rgb565_unpack_fragment(VertexOut in [[stage_in]],
                                               texture2d<uint> tex [[texture(0)]],
                                               sampler samp [[sampler(0)]]) {
    uint2 size = uint2(tex.get_width(), tex.get_height());
    uint2 coord = uint2(in.texCoord * float2(size));
    coord = min(coord, size - 1);
    uint packed = tex.read(coord).r;
    float r = float((packed >> 11) & 0x1F) / 31.0;
    float g = float((packed >> 5) & 0x3F) / 63.0;
    float b = float(packed & 0x1F) / 31.0;
    return float4(r, g, b, 1.0);
}

// Every shader below this line takes the source texture's pixel size (in
// texels) as a second fragment buffer, needed to step to neighbouring
// texels for edge and scanline work. NativePlayerRenderer supplies it.

// SABR's character is edge-aware sharpening rather than smoothing: an
// unsharp mask whose strength backs off near a detected edge so it
// sharpens flat regions without ringing across sprite outlines.
fragment float4 shader_sabr_fragment(VertexOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      sampler samp [[sampler(0)]],
                                      constant float2 &texelSize [[buffer(1)]]) {
    float4 center = tex.sample(samp, in.texCoord);
    float4 n = tex.sample(samp, in.texCoord + float2(0, -texelSize.y));
    float4 s = tex.sample(samp, in.texCoord + float2(0, texelSize.y));
    float4 e = tex.sample(samp, in.texCoord + float2(texelSize.x, 0));
    float4 w = tex.sample(samp, in.texCoord + float2(-texelSize.x, 0));

    float4 blur = (n + s + e + w) * 0.25;
    float edge = distance(n.rgb, s.rgb) + distance(e.rgb, w.rgb);
    float amount = 0.6 / (1.0 + edge * 4.0);
    return clamp(center + (center - blur) * amount, 0.0, 1.0);
}

// Shared scanline term: darkens rows between texels along the vertical
// axis, the trait every CRT variant below builds on.
static float scanlineFactor(float2 uv, float2 texelSize, float strength) {
    float line = fract(uv.y / texelSize.y);
    float beam = 1.0 - strength + strength * sin(line * M_PI_F);
    return beam;
}

// crt-aperture: a fine RGB aperture-grille mask over crisp scanlines,
// the sharpest and least softened of the CRT set.
fragment float4 shader_crt_aperture_fragment(VertexOut in [[stage_in]],
                                              texture2d<float> tex [[texture(0)]],
                                              sampler samp [[sampler(0)]],
                                              constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    float scan = scanlineFactor(in.texCoord, texelSize, 0.35);
    float column = fract(in.texCoord.x / (texelSize.x / 3.0));
    float3 mask = float3(1.0);
    if (column < 0.333) mask = float3(1.15, 0.85, 0.85);
    else if (column < 0.667) mask = float3(0.85, 1.15, 0.85);
    else mask = float3(0.85, 0.85, 1.15);
    return float4(color.rgb * scan * mask, color.a);
}

// crt-easymode: gentle scanlines, a soft vignette, no visible mask, the
// mildest of the set and closest to a plain screen with rounded edges.
fragment float4 shader_crt_easymode_fragment(VertexOut in [[stage_in]],
                                              texture2d<float> tex [[texture(0)]],
                                              sampler samp [[sampler(0)]],
                                              constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    float scan = scanlineFactor(in.texCoord, texelSize, 0.18);
    float2 centered = in.texCoord - 0.5;
    float vignette = 1.0 - dot(centered, centered) * 0.35;
    return float4(color.rgb * scan * vignette, color.a);
}

// crt-mattias: thin, dark scanlines with the in-between rows left bright,
// a higher-contrast scanline than easymode without geom's curvature.
fragment float4 shader_crt_mattias_fragment(VertexOut in [[stage_in]],
                                             texture2d<float> tex [[texture(0)]],
                                             sampler samp [[sampler(0)]],
                                             constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    float line = fract(in.texCoord.y / texelSize.y);
    float scan = line < 0.15 ? 0.4 : 1.0;
    return float4(color.rgb * scan, color.a);
}

// crt-beam: models a Gaussian electron-beam intensity profile per
// scanline instead of a hard on/off stripe, a softer falloff than
// mattias with no colour mask.
fragment float4 shader_crt_beam_fragment(VertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          sampler samp [[sampler(0)]],
                                          constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    float line = fract(in.texCoord.y / texelSize.y) - 0.5;
    float beam = exp(-line * line * 8.0);
    float intensity = mix(0.55, 1.15, beam);
    return float4(color.rgb * intensity, color.a);
}

// crt-caligari: a soft, slightly desaturated scanline look, the gentlest
// and blurriest of the set, closer to a well worn CRT than a sharp one.
fragment float4 shader_crt_caligari_fragment(VertexOut in [[stage_in]],
                                              texture2d<float> tex [[texture(0)]],
                                              sampler samp [[sampler(0)]],
                                              constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    float4 below = tex.sample(samp, in.texCoord + float2(0, texelSize.y));
    float4 blended = mix(color, below, 0.3);
    float scan = scanlineFactor(in.texCoord, texelSize, 0.22);
    float gray = dot(blended.rgb, float3(0.299, 0.587, 0.114));
    float3 desaturated = mix(blended.rgb, float3(gray), 0.08);
    return float4(desaturated * scan, blended.a);
}

// crt-geom: bows the image outward like a curved CRT tube instead of
// coloring/scanlining a flat rectangle, the one shader in this list that
// reshapes the screen's geometry rather than its color. Distorts texture
// coordinates with the same x-bends-by-y^2/y-bends-by-x^2 barrel
// curvature libretro/slang-shaders' crt-geom.slang uses, then clips to a
// rounded rectangle and darkens the corners, so the visible image reads
// as a convex tube face rather than a flat panel. An earlier six-shader
// pass on this list dropped a multi-pass crt-geom.slang port as looking
// bad on device; this is a different, single-pass geometry-only effect
// built from scratch, not that same shader revisited.
fragment float4 shader_crt_geom_fragment(VertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          sampler samp [[sampler(0)]],
                                          constant float2 &texelSize [[buffer(1)]]) {
    float2 c = in.texCoord * 2.0 - 1.0;
    const float curvature = 6.0;
    float2 offset = c.yx / curvature;
    c += c * offset * offset;
    float2 uv = c * 0.5 + 0.5;

    // Rounded-rect clip in the same centered space: anything outside the
    // rounded box, corners included, is the tube's bezel, not the
    // picture. dist is the signed distance to that rounded boundary
    // (negative inside), reused below to fade brightness in before the
    // hard cutoff instead of ending in a flat, shadowless edge.
    const float cornerRadius = 0.08;
    float2 boxHalf = float2(1.0 - cornerRadius);
    float2 q = abs(c) - boxHalf;
    float dist = length(max(q, 0.0)) - cornerRadius;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || dist > 0.02) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float4 color = tex.sample(samp, uv);
    float scan = scanlineFactor(uv, texelSize, 0.35);
    // Corner/edge shadow: ramps from full brightness well inside the
    // rounded rect down to 45% right at its boundary, so the darkening
    // actually reads as a shadow cast by the tube's bezel rather than a
    // uniform tint or an invisible one-pixel edge. Layered under a mild
    // whole-screen vignette for the rest of the curvature.
    float edgeShadow = 1.0 - smoothstep(-0.16, 0.02, dist);
    float vignette = mix(0.45, 1.0, edgeShadow) * (1.0 - dot(c, c) * 0.12);
    return float4(color.rgb * scan * vignette, color.a);
}

// lcd: the generic handheld screen look for GBA/Game Gear/NGPC, none of
// which were ever displayed on a CRT. Reimplements the real math (not a
// copy) of libretro/slang-shaders' lcd3x.slang, itself explicitly public
// domain (Author: Gigaherz), using its own shipped defaults
// (brighten_scanlines 16.0, brighten_lcd 4.0): a soft sine-based scanline
// darkening plus a per-channel horizontal subpixel-fringe term, phase
// offset 2/3 of a cycle per channel to fake an RGB stripe mask without
// sampling neighbouring texels.
fragment float4 shader_lcd_fragment(VertexOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler samp [[sampler(0)]],
                                     constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    const float brightenScanlines = 16.0;
    const float brightenLCD = 4.0;
    float2 omega = (2.0 * M_PI_F) / texelSize;
    float2 angle = in.texCoord * omega;
    float yFactor = (brightenScanlines + sin(angle.y)) / (brightenScanlines + 1.0);
    float3 offsets = M_PI_F * float3(0.5, 0.5 - 2.0 / 3.0, 0.5 - 4.0 / 3.0);
    float3 xFactors = (brightenLCD + sin(angle.x + offsets)) / (brightenLCD + 1.0);
    float3 shaped = yFactor * xFactors * color.rgb;
    return float4(shaped, color.a);
}

// gameboy: a two-axis dot-matrix grid (both x and y, unlike lcd's
// scanline-only pattern), a touch of extra contrast, and a faint warm-
// green tint evoking the original DMG/GBC reflective screen. The real
// community dot-matrix shader (libretro/slang-shaders handheld/shaders/
// gameboy) is a five-pass pipeline with border art and previous-frame
// ghosting; this frontend has no multi-pass or prior-frame support, so
// this is a single-pass approximation of the same idea, not a port of
// its exact math. Colorization/recoloring is deliberately left alone
// here: Gambatte's own gambatte_gb_colorization core option already
// owns "what colors a mono Game Boy cart gets," this shader only shapes
// the screen, never repaints the palette.
fragment float4 shader_gameboy_fragment(VertexOut in [[stage_in]],
                                         texture2d<float> tex [[texture(0)]],
                                         sampler samp [[sampler(0)]],
                                         constant float2 &texelSize [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texCoord);
    float2 cell = fract(in.texCoord / texelSize);
    float2 dist = abs(cell - 0.5) * 2.0;
    float grid = 1.0 - max(dist.x, dist.y) * 0.22;
    float3 shaped = color.rgb * grid;
    float3 contrasted = (shaped - 0.5) * 1.08 + 0.5;
    float3 tinted = mix(contrasted, contrasted * float3(0.92, 1.02, 0.9), 0.18);
    return float4(clamp(tinted, 0.0, 1.0), color.a);
}
