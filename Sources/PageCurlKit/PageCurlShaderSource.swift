// Page curl shaders. The source is compiled at runtime, so the package ships no Metal library
// resource.
//
// The leaf has three zones: flat before the fold line, wrapped around a radius r(s) = r0 + k·s at
// the fold, and lying mirrored at height 2r past the crest. The zones are real branches, not a
// blend; the radius is clamped from below because d/r at r = 0 would give NaN.
//
// Modes: spread (the leaf is half the screen, its axis at the spine, its back is the opposite half
// of the target snapshot) and single page (the leaf is the whole screen, its axis at the left edge,
// its back is a translucent mirror of the leaf itself, like thin paper).
let pageCurlShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct CurlUniforms {
    float foldX;      // fold line at the bottom edge, sheet coordinates
    float r0;         // bend radius at the bottom edge
    float k;          // radius growth along the fold line (cone strength)
    float halfWidth;  // half the SCREEN width, pt (for NDC)
    float height;     // sheet height, pt
    float zScale;     // height above the plane -> depth
    float zEpsilon;   // lift above the background against z-fighting
    float direction;  // +1 — the leaf moves left of its edge; −1 — mirrored
    float originX;    // screen x of the leaf axis: spine (spread) or left edge
    float isSingle;   // 1 — single page, 0 — spread
    float backMix;    // single: how much text shows through the back
    float paperR;     // single: paper color of the back
    float paperG;
    float paperB;
    float shadowAmp;  // cast shadow strength (0 at the trajectory ends)
    float pad1;
};

// Light from above-and-front, like a lamp over a book. No lateral component
// on purpose: with one, forward and backward curls would be lit on different
// sides of the roll (physical, but reads as asymmetry).
constant float3 curlLight = float3(0.0, -0.28, 0.96);

struct VertexIn {
    float2 sheet [[attribute(0)]];
    float2 uv    [[attribute(1)]];
};

struct LeafVaryings {
    float4 position [[position]];
    float2 faceUV;
    float2 backUV;
    // Surface brightness from the bend (cone-normal self-shading);
    // interpolation over the fine mesh is enough.
    float shade;
};

vertex LeafVaryings leaf_vertex(
    const device float4 *vertices [[buffer(0)]],
    constant CurlUniforms &u [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    float4 v = vertices[vid];
    float x = v.x;
    float y = v.y;
    // s — along the fold line from the bottom edge, d — across, toward the
    // curl.
    float s = u.height - y;
    float d = x - u.foldX;

    float px;
    float pz;
    float shade = 1.0;
    // Flat-area lighting uses the same formula as the roll at θ=0: the zone
    // seams must meet without a visible edge.
    float flatLit = clamp(dot(float3(0.0, 0.0, 1.0), normalize(curlLight)), 0.0, 1.0);
    float flatShade = 0.72 + 0.28 * flatLit;
    if (d <= 0.0) {
        px = x;
        pz = 0.0;
        // Slight darkening of the flat part next to the fold: the rising
        // roll shades it from the light. Matches the roll start at d=0.
        shade = flatShade * (1.0 - 0.08 * exp(d / max(u.r0, 8.0)));
    } else {
        float r = max(u.r0 + u.k * s, 0.75);
        float arc = M_PI_F * r;
        if (d <= arc) {
            float theta = d / r;
            px = u.foldX + sin(theta) * r;
            pz = (1.0 - cos(theta)) * r;
            // Cone normal in screen axes: (−dir·sinθ, 0, cosθ); lit by
            // curlLight with some ambient so the turned edge is not black.
            float3 normal = float3(-u.direction * sin(theta), 0.0, cos(theta));
            float lit = clamp(dot(normal, normalize(curlLight)), 0.0, 1.0);
            shade = 0.72 + 0.28 * lit;
            // The roll's shading fades as the sheet rises — values match the
            // flat part at the boundary.
            shade *= 1.0 - 0.08 * (1.0 - smoothstep(0.0, 0.6, theta));
            // Toward the crest, blend into the settled overturn's lighting.
            shade = mix(shade, 0.97, smoothstep(2.4, M_PI_F, theta));
        } else {
            px = u.foldX - (d - arc);
            pz = 2.0 * r;
            // The settled overturn is lit evenly, slightly dimmed.
            shade = 0.97;
        }
    }
    // Normalize by flat-area lighting: the far field of the sheet is exactly
    // 1.0 (the t=0 frame matches the live spread pixel for pixel), and the
    // zone seams stay continuous under a common divisor.
    shade = min(shade / flatShade, 1.0);

    float sx = u.originX + u.direction * px;
    LeafVaryings out;
    out.position = float4(
        sx / u.halfWidth - 1.0,
        1.0 - 2.0 * (y / u.height),
        clamp(pz * u.zScale + u.zEpsilon, 0.0, 0.999),
        1.0
    );
    // The loader stores CGImage rows top-down: v=0 is the snapshot's top.
    if (u.isSingle > 0.5) {
        // The leaf is the whole snapshot; the back samples the same point:
        // the flipped geometry itself yields the mirrored look.
        out.faceUV = float2(v.z, v.w);
        out.backUV = float2(v.z, v.w);
    } else {
        // Face — the leaf's half of the current snapshot; back — the
        // opposite half of the target (lies mirrored across the spine).
        out.faceUV = float2(0.5 + u.direction * 0.5 * v.z, v.w);
        out.backUV = float2(0.5 - u.direction * 0.5 * v.z, v.w);
    }
    out.shade = shade;
    return out;
}

fragment float4 leaf_fragment(
    LeafVaryings in [[stage_in]],
    bool isFront [[front_facing]],
    constant CurlUniforms &u [[buffer(1)]],
    texture2d<float> faceTex [[texture(0)]],
    texture2d<float> backTex [[texture(1)]]
) {
    constexpr sampler smp(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    if (isFront) {
        float4 c = faceTex.sample(smp, in.faceUV);
        return float4(c.rgb * in.shade, c.a);
    }
    if (u.isSingle > 0.5) {
        // Translucent mirror: theme paper with a hint of the leaf's text.
        float4 ink = faceTex.sample(smp, in.backUV);
        float3 paper = float3(u.paperR, u.paperG, u.paperB);
        return float4(mix(paper, ink.rgb, u.backMix) * in.shade, 1.0);
    }
    float4 c = backTex.sample(smp, in.backUV);
    return float4(c.rgb * in.shade, c.a);
}

// Background under the leaf: two halves for a spread (static and opening),
// one full-screen snapshot for single mode. On top — the cast shadow: a soft
// band under the fold roll and a band ahead of the settled overturn's edge
// ("the shadow precedes the leaf"). Both analytic, no blur.
struct BackgroundVaryings {
    float4 position [[position]];
    float2 uv;
    float xNDC;
};

vertex BackgroundVaryings background_vertex(
    const device float4 *vertices [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    float4 v = vertices[vid];
    BackgroundVaryings out;
    out.position = float4(v.x, v.y, 0.0, 1.0);
    out.uv = float2(v.z, v.w);
    out.xNDC = v.x;
    return out;
}

fragment float4 background_fragment(
    BackgroundVaryings in [[stage_in]],
    constant CurlUniforms &u [[buffer(1)]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler smp(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(smp, in.uv);

    float x = (in.xNDC + 1.0) * u.halfWidth;
    float sheetW = (u.isSingle > 0.5) ? 2.0 * u.halfWidth : u.halfWidth;
    float arc = M_PI_F * u.r0;

    // The band under the fold roll.
    float c1 = u.originX + u.direction * (u.foldX + u.r0);
    float w1 = max(u.r0 * 2.2, 30.0);
    float d1 = (x - c1) / w1;
    float band1 = exp(-0.5 * d1 * d1);

    // The band ahead of the settled overturn's edge; appears once the
    // overturn exists.
    float flipped = (sheetW - u.foldX) - arc;
    float edgePx = u.foldX - flipped;
    float c2 = u.originX + u.direction * edgePx;
    float w2 = max(u.r0 * 1.2, 24.0);
    float d2 = (x - c2) / w2;
    float band2 = exp(-0.5 * d2 * d2) * smoothstep(0.0, 60.0, flipped) * 0.7;

    float shadow = min(u.shadowAmp * (band1 + band2), 0.35);
    return float4(c.rgb * (1.0 - shadow), c.a);
}
"""
