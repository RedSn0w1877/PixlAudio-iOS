// The animated artwork behind the karaoke lyrics: our own shader, written from the maths in the lyrics spec §2.3
// (the same steps as Android's AGSL `LyricsBackgroundShader` and PixlLyrics' CPU reference `LyricsBackgroundGrade`):
// twist → composite the four pre-blurred sprites (premultiplied, back to front) → grade (saturation 2.75, contrast
// 1.9, brightness 0.7, clamped at the end) → black 50 % / white 5 % / bright-art scrim → interleaved-gradient dither.
// The twist is the textbook "rotate by angle·((R − |d|)/R)²" swirl; interleaved-gradient noise is public domain.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

constant float3 kLuma = float3(0.2125, 0.7154, 0.0721);

// Samples sprite k of the 2×2 atlas. `xf` = (s·cosθ, s·sinθ, centreX, centreY) maps a screen point to sprite texels
// (texture centred on the origin). Sprite 0 mirrors at its edges (Android MIRROR); sprites 1–3 clamp onto their
// transparent padding (Android CLAMP).
static float4 sampleSprite(texture2d<half> atlas, float4 xf, float2 q, float2 cellOrigin, float spriteSize,
                           bool mirrorEdges, float2 atlasSize) {
    float2 d = q - xf.zw;
    float2 t = float2(xf.x * d.x + xf.y * d.y, xf.x * d.y - xf.y * d.x);
    float2 p = t + spriteSize * 0.5;
    if (mirrorEdges) {
        float period = 2.0 * spriteSize;
        p = p - period * floor(p / period);
        p = select(p, period - p, p > spriteSize);
    }
    p = clamp(p, float2(0.5), float2(spriteSize - 0.5));
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    return float4(atlas.sample(linearSampler, (cellOrigin + p) / atlasSize));
}

[[ stitchable ]] half4 lyricsScene(float2 position, texture2d<half> atlas, float2 size, float4 xf0, float4 xf1,
                                   float4 xf2, float4 xf3, float4 spriteSizes, float cell, float twistAngle,
                                   float twistRadius, float alpha, float scrim) {
    // 1. Twist around the centre.
    float2 c = size * 0.5;
    float2 d = position - c;
    float dist = length(d);
    if (dist < twistRadius) {
        float k = (twistRadius - dist) / twistRadius;
        float a = twistAngle * k * k;
        float cs = cos(a);
        float sn = sin(a);
        d = float2(d.x * cs - d.y * sn, d.x * sn + d.y * cs);
    }
    float2 q = c + d;

    // 2. Composite the sprites, premultiplied, back to front.
    float2 atlasSize = float2(2.0 * cell);
    float4 col = sampleSprite(atlas, xf0, q, float2(0.0, 0.0), spriteSizes.x, true, atlasSize);
    float4 s1 = sampleSprite(atlas, xf1, q, float2(cell, 0.0), spriteSizes.y, false, atlasSize);
    col = s1 + col * (1.0 - s1.a);
    float4 s2 = sampleSprite(atlas, xf2, q, float2(0.0, cell), spriteSizes.z, false, atlasSize);
    col = s2 + col * (1.0 - s2.a);
    float4 s3 = sampleSprite(atlas, xf3, q, float2(cell, cell), spriteSizes.w, false, atlasSize);
    col = s3 + col * (1.0 - s3.a);
    float3 rgb = col.rgb / max(col.a, 0.0001);

    // 3. Grade in float, clamp only at the end.
    float luma = dot(rgb, kLuma);
    rgb = mix(float3(luma), rgb, 2.75);
    rgb = (rgb - 0.5) * 1.9 + 0.5;
    rgb *= 0.7;
    rgb = clamp(rgb, 0.0, 1.0);

    // 4. Overlays: black at 50 %, white at 5 %, then the bright-art scrim.
    rgb *= 0.5;
    rgb = rgb * 0.95 + 0.05;
    rgb *= 1.0 - scrim;

    // 5. Dither: interleaved-gradient noise, ±0.5/255.
    float ign = fract(52.9829189 * fract(dot(position, float2(0.06711056, 0.00583715))));
    rgb += (ign - 0.5) / 255.0;

    return half4(half3(rgb * alpha), half(alpha));
}
