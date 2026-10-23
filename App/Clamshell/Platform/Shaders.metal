// SPDX-License-Identifier: GPL-3.0-or-later

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Full-screen quad from the vertex index; no vertex buffer needed.
vertex VertexOut screenVertex(uint vid [[vertex_id]]) {
    float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VertexOut out;
    out.position = float4(corners[vid], 0, 1);
    out.uv = float2((corners[vid].x + 1) * 0.5, 1 - (corners[vid].y + 1) * 0.5);
    return out;
}

// Sharp bilinear: nearest-neighbour inside each source pixel, a one-output-pixel
// linear blend at the edges. Crisp at any scale, without the shimmer of plain
// nearest-neighbour at non-integer scales.
// sizes = (source width, source height, target width, target height)
fragment float4 screenFragmentSharpBilinear(VertexOut in [[stage_in]],
                                            texture2d<float> source [[texture(0)]],
                                            sampler linearSampler [[sampler(0)]],
                                            constant float4 &sizes [[buffer(0)]]) {
    float2 sourceSize = sizes.xy;
    float2 scale = max(floor(sizes.zw / sourceSize), float2(1));
    float2 texel = in.uv * sourceSize;
    float2 centerDistance = fract(texel) - 0.5;
    float2 region = 0.5 - 0.5 / scale;
    float2 f = (centerDistance - clamp(centerDistance, -region, region)) * scale + 0.5;
    return source.sample(linearSampler, (floor(texel) + f) / sourceSize);
}
