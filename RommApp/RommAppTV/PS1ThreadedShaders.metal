#include <metal_stdlib>
using namespace metal;

// tvOS-only experimental shader, isolated from the shared
// LibretroShaders.metal on purpose: unpacks the core's raw RGB565 video
// frame on the GPU, in the fragment shader, instead of a CPU scalar loop
// converting every pixel by hand before upload. RetroArch's own GL/Vulkan
// drivers upload RGB565 in its native packed format for exactly this
// reason, no CPU conversion step in the hot path at all.
//
// Uses a raw r16Uint texture (not Metal's built-in .b5g6r5Unorm) on
// purpose: an earlier attempt at Metal's native 16-bit packed texture
// format rendered solid black (see NativePlayerRenderer's updateTexture
// comment, from the Genesis Plus GX bring-up), and rather than re-risk
// that same undocumented-packing uncertainty, this unpacks the bits by
// hand from a plain unsigned-integer texture, giving full control over
// exactly how each bit is interpreted.
struct ThreadedVertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct ThreadedVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex ThreadedVertexOut ps1_threaded_vertex(const device ThreadedVertexIn *vertices [[buffer(0)]], uint vid [[vertex_id]]) {
    ThreadedVertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.texCoord = vertices[vid].texCoord;
    return out;
}

fragment float4 ps1_threaded_rgb565_unpack(ThreadedVertexOut in [[stage_in]],
                                            texture2d<uint> tex [[texture(0)]],
                                            sampler samp [[sampler(0)]]) {
    uint2 size = uint2(tex.get_width(), tex.get_height());
    uint2 coord = uint2(in.texCoord * float2(size));
    coord = min(coord, size - 1);
    uint packed = tex.read(coord).r;

    // libretro's RETRO_PIXEL_FORMAT_RGB565: bits 15-11 red, 10-5 green, 4-0
    // blue, matching the same layout the CPU path already unpacked.
    float r = float((packed >> 11) & 0x1F) / 31.0;
    float g = float((packed >> 5) & 0x3F) / 63.0;
    float b = float(packed & 0x1F) / 31.0;
    return float4(r, g, b, 1.0);
}
