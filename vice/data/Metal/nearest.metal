#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float4 position [[position]];
    float2 uv;
};

vertex Vertex vice_vertex(uint index [[vertex_id]], constant float4 *vertices [[buffer(0)]])
{
    return {float4(vertices[index].xy, 0, 1), vertices[index].zw};
}

fragment float4 vice_nearest(Vertex in [[stage_in]], texture2d<float> image [[texture(0)]])
{
    constexpr sampler nearest(coord::normalized, address::clamp_to_edge, filter::nearest);
    return image.sample(nearest, in.uv);
}
