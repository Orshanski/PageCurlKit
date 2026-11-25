// Page curl shaders. The source is compiled at runtime, so the package ships no Metal library
// resource.
//
// The leaf is wrapped around a cone, a cylinder or a mix of the two, then turned about the spine
// and seen in perspective. Source: Hong, Card, Chen, "Deforming Pages of 3D Electronic Books"
// (2004), and Austin's page_curl::curlPage.
//
// Modes: spread (the leaf is half the screen, its axis at the spine, its back is the opposite half
// of the target snapshot) and single page (the leaf is the whole screen, its axis at the left edge,
// its back is a translucent mirror of the leaf itself, like thin paper).
let pageCurlShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct CurlUniforms {
    float theta;
    float apexY;
    float rotation;
    float conic;
    float cylinderRadius;
    float width;        // sheet width, pt
    float height;       // sheet and screen height, pt
    float eyeDistance;  // pt
    float direction;    // +1 — the leaf moves left of its edge; −1 — mirrored
    float originX;      // screen x of the leaf axis: spine (spread) or left edge
    float halfWidth;    // half the SCREEN width, pt
    float isSingle;
    float backMix;      // single: how much text shows through the back
    float paperR;       // single: paper color of the back
    float paperG;
    float paperB;
    float shadowStrength;
    float shadowShiftX;
    float shadowShiftY;
    float shadowSoftening;
    float shadowMaxWidth;
    float shadowMinimumWidth;
    float shadowTopLevel;
    float lampX;
    float lampY;
    float lampZ;
    float leafTone;
    float gutterHalfWidth;
};

// The table of PageLight.shaderTable, laid out by PageLight.
constant int toneSamples = \(PageLight.toneSamples);
constant float lowestCosine = \(PageLight.lowestCosine);
constant int gutterSamples = \(PageLight.bandSamples);
constant int gutterLeftStart = \(PageLight.leftBandStart);
constant int gutterRightStart = \(PageLight.rightBandStart);

static float lookUp(constant float *table, int start, int count, float share) {
    float f = clamp(share, 0.0, 1.0) * float(count - 1);
    int i = min(int(f), count - 2);
    return mix(table[start + i], table[start + i + 1], f - float(i));
}

static float gutterAt(
    float d, int start, constant CurlUniforms &u, constant float *table, float outside
) {
    if (u.gutterHalfWidth <= 0.0 || d >= u.gutterHalfWidth) {
        return outside;
    }
    return lookUp(table, start, gutterSamples, d / u.gutterHalfWidth);
}

static float lampTone(float3 normal, constant CurlUniforms &u, constant float *table) {
    float cosine = dot(normal, float3(u.lampX, u.lampY, u.lampZ));
    return lookUp(table, 0, toneSamples, (cosine - lowestCosine) / (u.lampZ - lowestCosine));
}

// Half a step of noise hides the steps of 8-bit output on smooth grey.
static float3 withNoise(float3 color, float2 pixel) {
    float noise = fract(sin(dot(pixel, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    return color + noise / 255.0;
}

struct LeafVaryings {
    float4 position [[position]];
    float2 faceUV;
    float2 backUV;
    float2 sheet;
    // The face's normal in screen axes, not normalized: interpolated along the triangle and
    // normalized at each point.
    float3 normal;
};

// Sheet point (x from the spine, y from the top edge) to the leaf in space: x across the screen
// away from the spine, y down, z toward the reader.
static float3 curlPoint(float x, float y, constant CurlUniforms &u) {
    // Precise functions and 2·sin²(a/2) in place of 1 − cos(a): near a flat leaf the angles are
    // tiny and the radius huge, and the fast ones give a lift of tens of points out of nothing.
    // The cone tight at the bottom is the top one with the sheet turned upside down.
    bool bottom = u.conic < 0.0;
    float yc = bottom ? u.height - y : y;
    float sinT = precise::sin(u.theta);
    float R = length(float2(x, yc - u.apexY));
    float r = R * sinT;
    float beta = precise::asin(min(x / R, 1.0)) / sinT;
    float halfBeta = precise::sin(0.5 * beta);
    float sag = 2.0 * r * halfBeta * halfBeta;
    float3 cone = float3(
        r * precise::sin(beta),
        R + u.apexY - sag * sinT,
        sag * precise::cos(u.theta)
    );
    if (bottom) {
        cone.y = u.height - cone.y;
    }

    float b = x / u.cylinderRadius;
    float halfB = precise::sin(0.5 * b);
    float3 cylinder = float3(
        u.cylinderRadius * precise::sin(b),
        y,
        2.0 * u.cylinderRadius * halfB * halfB
    );

    float3 t = mix(cylinder, cone, abs(u.conic));
    float sinR = precise::sin(u.rotation);
    float cosR = precise::cos(u.rotation);
    return float3(t.x * cosR - t.z * sinR, t.y, t.x * sinR + t.z * cosR);
}

vertex LeafVaryings leaf_vertex(
    const device float4 *vertices [[buffer(0)]],
    constant CurlUniforms &u [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    float4 v = vertices[vid];
    float3 p = curlPoint(v.x, v.y, u);

    // The eye is above the screen centre; points on the screen plane stay where they are.
    float2 screen = float2(u.originX + u.direction * p.x, p.y);
    float2 centre = float2(u.halfWidth, 0.5 * u.height);
    screen = centre + (screen - centre) * (u.eyeDistance / (u.eyeDistance - p.z));

    LeafVaryings out;
    out.position = float4(
        screen.x / u.halfWidth - 1.0,
        1.0 - 2.0 * (screen.y / u.height),
        // The flat leaf sits just above the background against z-fighting.
        clamp(p.z / (2.0 * u.width) + 0.002, 0.0, 0.999),
        1.0
    );
    out.sheet = v.xy;
    // The surface's slope from the leaf's own shape, 2 pt apart along the sheet.
    float3 alongX = curlPoint(v.x + 2.0, v.y, u) - p;
    float3 alongY = curlPoint(v.x, v.y + 2.0, u) - p;
    alongX.x *= u.direction;
    alongY.x *= u.direction;
    out.normal = normalize(cross(alongX, alongY)) * u.direction;
    // Snapshot rows are stored top-down: v=0 is the snapshot's top.
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
    return out;
}

constexpr sampler snapshotSampler(
    mag_filter::linear, min_filter::linear, mip_filter::linear,
    max_anisotropy(8), address::clamp_to_edge
);

static float4 leafColor(
    LeafVaryings in, bool isFront, constant CurlUniforms &u,
    texture2d<float> faceTex, texture2d<float> backTex
) {
    if (isFront) {
        return faceTex.sample(snapshotSampler, in.faceUV);
    }
    if (u.isSingle > 0.5) {
        // Translucent mirror: theme paper with a hint of the leaf's text.
        float4 ink = faceTex.sample(snapshotSampler, in.backUV);
        float3 paper = float3(u.paperR, u.paperG, u.paperB);
        return float4(mix(paper, ink.rgb, u.backMix), 1.0);
    }
    return backTex.sample(snapshotSampler, in.backUV);
}

static float leafTone(
    float3 faceNormal, bool isFront, constant CurlUniforms &u, constant float *gutter
) {
    if (u.leafTone <= 0.0) {
        return 1.0;
    }
    float3 normal = normalize(faceNormal);
    return lampTone(isFront ? normal : -normal, u, gutter);
}

fragment float4 leaf_fragment(
    LeafVaryings in [[stage_in]],
    bool isFront [[front_facing]],
    constant CurlUniforms &u [[buffer(1)]],
    texture2d<float> faceTex [[texture(0)]],
    texture2d<float> backTex [[texture(1)]],
    constant float *gutter [[buffer(2)]],
    constant float2 &spineBand [[buffer(3)]]
) {
    float4 c = leafColor(in, isFront, u, faceTex, backTex);
    bool hasBand = (isFront ? spineBand.x : spineBand.y) > 0.5;
    // The spine's band goes with the side of the leaf: the face starts on its own page, the back
    // lands on the other one.
    bool onLeftPage = isFront == (u.direction < 0.0);
    int start = onLeftPage ? gutterLeftStart : gutterRightStart;
    float band = hasBand ? gutterAt(in.sheet.x, start, u, gutter, 1.0) : 1.0;
    float tone = leafTone(in.normal, isFront, u, gutter) * band;
    if (tone >= 1.0) {
        return c;
    }
    return float4(withNoise(c.rgb * tone, in.position.xy), c.a);
}

// The leaf moved along the lamp's ray onto the page: red — covered, green — the leaf's height.
struct ShadowVaryings {
    float4 position [[position]];
    float height;
};

vertex ShadowVaryings shadow_vertex(
    const device float4 *vertices [[buffer(0)]],
    constant CurlUniforms &u [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    float4 v = vertices[vid];
    float3 p = curlPoint(v.x, v.y, u);
    float2 page = float2(u.originX + u.direction * p.x, p.y)
        + p.z * float2(u.shadowShiftX, u.shadowShiftY);
    ShadowVaryings out;
    out.position = float4(page.x / u.halfWidth - 1.0, 1.0 - 2.0 * (page.y / u.height), 0.0, 1.0);
    out.height = max(p.z, 0.0);
    return out;
}

fragment float2 shadow_fragment(ShadowVaryings in [[stage_in]]) {
    return float2(1.0, in.height);
}

struct BlurVaryings {
    float4 position [[position]];
    float2 uv;
};

// One triangle over the whole target.
vertex BlurVaryings fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    BlurVaryings out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

struct BlurStep {
    float2 step;
    float sigma;
};

fragment float2 blur_fragment(
    BlurVaryings in [[stage_in]],
    constant BlurStep &b [[buffer(0)]],
    texture2d<float> source [[texture(0)]]
) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    float2 sum = 0.0;
    float total = 0.0;
    for (int i = -4; i <= 4; i++) {
        float w = exp(-0.5 * float(i * i) / (b.sigma * b.sigma));
        sum += w * source.sample(smp, in.uv + float(i) * b.step).rg;
        total += w;
    }
    return sum / total;
}

struct BackgroundVaryings {
    float4 position [[position]];
    float2 uv;
};

vertex BackgroundVaryings background_vertex(
    const device float4 *vertices [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    float4 v = vertices[vid];
    BackgroundVaryings out;
    out.position = float4(v.x, v.y, 0.0, 1.0);
    out.uv = float2(v.z, v.w);
    return out;
}

constant int shadowLevelCount = \(CurlShadowLevels.count);
constant float sharpBlur = \(CurlShadowLevels.sharpBlur);
constant float firstBlur = \(CurlShadowLevels.firstBlur);
constant float growth = \(Float(CurlShadowLevels.growth));
constant int averagingLevel = \(CurlShadowLevels.averaging);

// The shadow's soft edge, by the leaf's height. The snapshot's uv is also the place on the screen.
static float shadowAt(
    float2 uv, constant CurlUniforms &u,
    array<texture2d<float>, shadowLevelCount> levels
) {
    constexpr sampler smp(filter::linear, address::clamp_to_edge);
    // The leaf's height over this place, averaged around it.
    float2 around = levels[averagingLevel].sample(smp, uv).rg;
    float height = around.g / max(around.r, 1e-4);
    float sigma = 0.5 * min(max(u.shadowSoftening * height, u.shadowMinimumWidth), u.shadowMaxWidth);
    float level = sigma < firstBlur
        ? max(sigma - sharpBlur, 0.0) / (firstBlur - sharpBlur)
        : 1.0 + log2(sigma / firstBlur) / log2(growth);
    level = clamp(level, 0.0, u.shadowTopLevel);
    int below = int(floor(level));
    int above = min(below + 1, int(u.shadowTopLevel));
    float cover = mix(
        levels[below].sample(smp, uv).r, levels[above].sample(smp, uv).r, level - float(below)
    );
    return u.shadowStrength * cover;
}

fragment float4 background_fragment(
    BackgroundVaryings in [[stage_in]],
    constant CurlUniforms &u [[buffer(1)]],
    texture2d<float> tex [[texture(0)]],
    array<texture2d<float>, shadowLevelCount> shadowLevels [[texture(1)]],
    constant float *gutter [[buffer(2)]],
    constant float &spineBand [[buffer(3)]]
) {
    float4 c = tex.sample(snapshotSampler, in.uv);
    float tone = 1.0;
    if (u.gutterHalfWidth > 0.0 && spineBand > 0.5) {
        float x = in.uv.x * 2.0 * u.halfWidth;
        int start = x < u.halfWidth ? gutterLeftStart : gutterRightStart;
        tone = gutterAt(abs(x - u.halfWidth), start, u, gutter, 1.0);
    }
    if (u.shadowStrength > 0.0) {
        // Where the spine's band and the leaf's shadow meet, the darker of the two: both are the
        // same shadow, so the spine does not jump when the leaf lifts.
        tone = min(tone, 1.0 - shadowAt(in.uv, u, shadowLevels));
    }
    if (tone >= 1.0) {
        return c;
    }
    return float4(withNoise(c.rgb * tone, in.position.xy), c.a);
}
"""
