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
