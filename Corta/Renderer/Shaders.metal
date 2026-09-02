#include <metal_stdlib>
using namespace metal;

// Layout must match `QuadInstance` / `QuadUniforms` in QuadInstance.swift
// exactly. Metal's default struct layout (each member aligned to its own
// natural alignment, `float2` = 8, `float4` = 16) is what Swift's
// `SIMD2<Float>` / `SIMD4<Float>` produce too, so no explicit `packed_*` or
// manual padding is needed — but a member added on one side without the
// other silently misaligns the rest of the struct.
struct QuadInstance {
    float2 origin;  // top-left, pixels, relative to the target rect's origin
    float2 size;    // width, height, pixels
    float4 color;   // straight-alpha, sRGB-encoded (see the colour-space
                     // note in QuadRenderer.swift)
    float4 uvRect;  // atlas UV (x, y, w, h), normalised; zero for solid quads
};

struct QuadUniforms {
    float2 rectOrigin;    // target rect's origin, pixels, within the drawable
    float2 rectSize;      // target rect's size, pixels (unused by the vertex
                           // math itself; kept for future clipping math)
    float2 drawableSize;  // full drawable size, pixels
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

// A triangle strip over the unit square, offset and scaled per instance.
constant float2 kUnitQuad[4] = {
    float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1)
};

vertex VertexOut quad_vertex(uint vertexID [[vertex_id]],
                              uint instanceID [[instance_id]],
                              constant QuadInstance *instances [[buffer(0)]],
                              constant QuadUniforms &uniforms [[buffer(1)]]) {
    QuadInstance inst = instances[instanceID];
    float2 corner = kUnitQuad[vertexID];
    float2 pixel = uniforms.rectOrigin + inst.origin + corner * inst.size;

    // Pixel space has (0,0) at the drawable's top-left, y increasing down.
    // Metal NDC has (0,0) at the centre, y increasing up — hence the flip.
    float2 ndc = (pixel / uniforms.drawableSize) * 2.0 - 1.0;
    ndc.y = -ndc.y;

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = inst.color;
    out.uv = inst.uvRect.xy + corner * inst.uvRect.zw;
    return out;
}

fragment float4 quad_fragment_solid(VertexOut in [[stage_in]]) {
    return in.color;
}

fragment float4 quad_fragment_glyph(VertexOut in [[stage_in]],
                                     texture2d<float> atlas [[texture(0)]],
                                     sampler atlasSampler [[sampler(0)]]) {
    // The atlas is `r8Unorm` coverage; `.r` is the glyph's alpha.
    float coverage = atlas.sample(atlasSampler, in.uv).r;
    return float4(in.color.rgb, in.color.a * coverage);
}

// The color-atlas variant: texels are premultiplied bgra (Apple Color Emoji
// bitmaps), so the sample is the fragment colour verbatim and the instance
// colour — a tint for coverage glyphs — does not apply. The pipeline's
// blend state is premultiplied-over (`sourceRGB = one`), matching the
// texels.
fragment float4 quad_fragment_color(VertexOut in [[stage_in]],
                                     texture2d<float> atlas [[texture(0)]],
                                     sampler atlasSampler [[sampler(0)]]) {
    return atlas.sample(atlasSampler, in.uv);
}
