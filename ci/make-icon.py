#!/usr/bin/env python3
"""Generates the placeholder app icon (1024x1024, opaque sRGB PNG).

A diagonal violet→indigo→blue gradient with a soft highlight and a centred white waveform glyph.
Build-time only (needs Pillow); the PNG is committed at App/Assets.xcassets/AppIcon.appiconset/AppIcon.png.
Usage: python ci/make-icon.py [output.png]
"""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SS = 2  # supersampling factor for smooth edges
OUT = sys.argv[1] if len(sys.argv) > 1 else "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

STOPS = [(0.0, (124, 92, 255)), (0.55, (84, 70, 230)), (1.0, (40, 120, 255))]


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient_color(t):
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        if t <= t1:
            return lerp(c0, c1, (t - t0) / (t1 - t0))
    return STOPS[-1][1]


def main():
    n = SIZE
    # Diagonal gradient: build a 1-D ramp and rotate it, cheap and smooth.
    ramp = Image.new("RGB", (n * 2, 1))
    ramp.putdata([gradient_color(x / (n * 2 - 1)) for x in range(n * 2)])
    ramp = ramp.resize((n * 2, n * 2))
    bg = ramp.rotate(-45, resample=Image.BICUBIC).crop((n // 2, n // 2, n // 2 + n, n // 2 + n))

    # Soft top-left highlight.
    glow = Image.new("L", (n, n), 0)
    ImageDraw.Draw(glow).ellipse((-n * 0.25, -n * 0.35, n * 0.75, n * 0.55), fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(n * 0.12))
    bg = Image.composite(Image.new("RGB", (n, n), (255, 255, 255)), bg, glow)

    # Waveform glyph: 9 rounded bars, symmetric envelope.
    big = n * SS
    mask = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(mask)
    heights = [0.20, 0.36, 0.58, 0.80, 0.96, 0.80, 0.58, 0.36, 0.20]
    bar_w = big * 0.052
    gap = big * 0.034
    total = len(heights) * bar_w + (len(heights) - 1) * gap
    x = (big - total) / 2
    max_h = big * 0.46
    for h in heights:
        bh = max_h * h
        y0 = (big - bh) / 2
        d.rounded_rectangle((x, y0, x + bar_w, y0 + bh), radius=bar_w / 2, fill=255)
        x += bar_w + gap
    mask = mask.resize((n, n), Image.LANCZOS)

    shadow = mask.filter(ImageFilter.GaussianBlur(n * 0.02))
    bg = Image.composite(Image.new("RGB", (n, n), (30, 20, 90)), bg, shadow.point(lambda v: v * 0.35))
    bg = Image.composite(Image.new("RGB", (n, n), (255, 255, 255)), bg, mask)

    bg.convert("RGB").save(OUT, "PNG", optimize=True)
    print(f"wrote {OUT} ({n}x{n})")


if __name__ == "__main__":
    main()
