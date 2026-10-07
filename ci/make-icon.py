#!/usr/bin/env python3
"""Renders the PixlAudio logo from one geometry: the iOS app icon (light, dark, tinted), the in-app marks and
the brand PNG for the READMEs.

The logo is concept C, "Glyph" (owner decision, 2026-10-07): the Android launcher icon's monochrome silhouette
(the play triangle with the lens cut out and the note inside) as a white frosted-glass glyph on a vivid
sky-to-violet gradient. The two other concepts stay selectable for comparison:
  A  Prism          lavender tile, sky-to-indigo glass play triangle, light-blue lens, navy note
  B  Midnight Lens  deep indigo tile, translucent glass triangle, glowing core disc
  C  Glyph          the silhouette as frosted white glass on a sky-to-violet gradient (the logo, default)
Shapes are 4x supersampled masks on a 1024 grid. Rounded corners are tangent arcs, the same construction as
SwiftUI's Path.addArc(tangent1End:tangent2End:radius:). The one-colour glyph is also traced into a vector path
(marching squares, then Douglas-Peucker), so the SVG and the Android vector drawables match the icon exactly.

Build-time only (Pillow; no numpy). Paths are relative to the repo root, wherever it runs from.
Usage: python ci/make-icon.py [--concept A|B|C] [--root DIR] [--preview PNG] [--compare PNG] [--variants DIR]
  (no flags)      writes every committed asset below
  --concept       A, B or C (default C): the app icon and BrandMark
  --root DIR      write the committed assets under DIR instead of the repo root
  --preview PNG   contact sheet: light, dark and tinted at Home Screen sizes, BrandMark, the launch screen and
                  the About glyph (preview only; don't commit it)
  --compare PNG   the three concepts side by side
  --variants DIR  loose 1024 PNGs (AppIcon, -dark, -tinted, BrandMark) for review
  --write         also write the committed assets when --preview, --compare or --variants is given
Committed assets:
  App/Assets.xcassets/AppIcon.appiconset/   AppIcon.png (Any, opaque RGB), AppIcon-Dark.png (transparent background),
                                            AppIcon-Tinted.png (opaque grayscale RGB), Contents.json
  App/Assets.xcassets/BrandMark.imageset/   the icon tile (continuous corners) at 120 pt @2x/@3x, light and dark;
                                            also the launch-screen image (project.yml UILaunchScreen)
  App/Assets.xcassets/BrandGlyph.imageset/  BrandGlyph.svg: the glyph as a template vector (takes foregroundStyle)
  docs/brand/pixlaudio-icon.png             512 px tile with transparent corners, for the README
Other tools import this file as a module: the Android launcher icon (tools/make-launcher-icon.py in the Android
repo) uses background(), foreground(), glyph_contours(), glyph_path(), glyph_box(), masked() and squircle().
"""
import argparse
import json
import math
import os
from functools import lru_cache

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

SIZE = 1024
N = SIZE
SS = 4  # supersampling factor for shape masks
GRID = 256  # gradients are evaluated per pixel on this grid (per 1024 px), then upscaled bicubic (they are smooth)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_CONCEPT = "C"

SHADOW_DARK = "#05041A"  # shadows in the dark foreground: a coloured one would glow on black
TOWARD_LIGHT = (-0.6, -0.8)  # unit vector toward the key light: above, slightly left
AWAY = (0.6, 0.8)

# ---------- shared geometry (1024 grid) ----------
# Fitted to the Android icon's outline (RMS error about 2 px). Play triangle: sharp vertices top-left,
# left pinch (reflex, gives the Android glyph's concave left edge), bottom-left, right tip; one
# tangent-arc radius per vertex. The top-left and bottom-left vertices sit on the canvas edge; only
# their arcs are drawn. Resulting bounding box (224,163)-(834,861).
TRI_PTS = [(157, 0), (264, 512), (157, 1024), (951, 512)]
TRI_R = [144, 200, 144, 140]
DISC_C, DISC_R = (506, 514), 164  # lens disc
HEAD_C, HEAD_R = (506, 514), 79  # note head, concentric with the disc as on Android
# Stem and flag as one rounded polygon; the two bottom corners hide inside the head. (585,350) is reflex.
# The flag straddles the triangle's top edge, as on Android.
NOTE_PTS = [(538, 514), (538, 266), (676, 303), (676, 375), (585, 350), (585, 514)]
NOTE_R = [0, 22, 22, 22, 10, 0]
HALO = 22  # gap between the note and the triangle in the monochrome silhouette
FILLET = 12  # rounding of the silhouette's cut corners, like Android's monochrome

# Concept C palette.
C_BACKGROUND = [(0, "#7CCBFF"), (0.45, "#6F8EFF"), (0.8, "#6C4FF5"), (1, "#5634D2")]  # (180,0) -> (844,1024)
DARK_TILE = [(0, "#24214F"), (1, "#100F2B")]  # in-app dark tile under the dark foreground (BrandMark, dark)

# In-app glyph box: the glyph's height is this share of its square box, centred on the canvas centre (so it keeps
# the icon's optical offset). The same margins as Android's pixelplay_base_monochrome (glyph 77 % x 88.5 %), so
# Android's sizes (28 dp in a 48 dp circle in About) port 1:1.
GLYPH_FILL = 0.885
TRACE_TOLERANCE = 0.2  # Douglas-Peucker tolerance of the traced glyph, in grid px


# ---------- geometry ----------
def _unit(x, y):
    length = math.hypot(x, y)
    return x / length, y / length


def _corner(pts, radii, i):
    """Tangent arc rounding vertex i (convex or reflex): (tangent point in, tangent point out, centre).

    For neighbours A, B: u1 = unit(A-P), u2 = unit(B-P), theta = acos(u1.u2), tangent distance
    t = r/tan(theta/2), centre = P + unit(u1+u2) * r/sin(theta/2).
    """
    (ax, ay), (px, py), (bx, by) = pts[i - 1], pts[i], pts[(i + 1) % len(pts)]
    r = radii[i]
    u1 = _unit(ax - px, ay - py)
    u2 = _unit(bx - px, by - py)
    theta = math.acos(max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1])))
    t = r / math.tan(theta / 2)
    assert t < math.hypot(ax - px, ay - py) and t < math.hypot(bx - px, by - py), (pts[i], r)
    bis = _unit(u1[0] + u2[0], u1[1] + u2[1])
    d = r / math.sin(theta / 2)
    return (px + u1[0] * t, py + u1[1] * t), (px + u2[0] * t, py + u2[1] * t), (px + bis[0] * d, py + bis[1] * d)


def corner_centre(pts, radii, i):
    return _corner(pts, radii, i)[2]


def rounded_outline(pts, radii):
    """Closed outline with each vertex replaced by its tangent arc (the shorter sweep)."""
    out = []
    for i, r in enumerate(radii):
        if r <= 0:
            out.append(pts[i])
            continue
        (x1, y1), (x2, y2), (cx, cy) = _corner(pts, radii, i)
        a1 = math.atan2(y1 - cy, x1 - cx)
        da = (math.atan2(y2 - cy, x2 - cx) - a1 + math.pi) % (2 * math.pi) - math.pi
        steps = max(8, int(abs(da) * r * 2))
        out.extend((cx + r * math.cos(a1 + da * k / steps), cy + r * math.sin(a1 + da * k / steps))
                   for k in range(steps + 1))
    return out


def hull_of_circles(*circles):
    """Convex hull (monotone chain) of sampled circles: two circles plus their external tangents."""
    pts = sorted({(round(cx + r * math.cos(k * math.pi / 360), 3), round(cy + r * math.sin(k * math.pi / 360), 3))
                  for (cx, cy), r in circles for k in range(720)})

    def chain(seq):
        out = []
        for p in seq:
            while len(out) >= 2 and ((out[-1][0] - out[-2][0]) * (p[1] - out[-2][1]) -
                                     (out[-1][1] - out[-2][1]) * (p[0] - out[-2][0])) <= 0:
                out.pop()
            out.append(p)
        return out[:-1]
    return chain(pts) + chain(reversed(pts))


def offset_polygon(pts, radii, d):
    """Exact inset (d > 0) or outset (d < 0): edges move by d, convex radii shrink by d, reflex ones grow."""
    n = len(pts)
    sgn = 1 if sum(pts[i][0] * pts[(i + 1) % n][1] - pts[(i + 1) % n][0] * pts[i][1] for i in range(n)) > 0 else -1
    lines = []
    for i in range(n):
        (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % n]
        ex, ey = _unit(x1 - x0, y1 - y0)
        lines.append(((x0 - ey * sgn * d, y0 + ex * sgn * d), (ex, ey)))  # moved along the inward normal
    new_pts, new_r = [], []
    for i in range(n):
        (p, e), (q, f) = lines[i - 1], lines[i]
        den = e[0] * f[1] - e[1] * f[0]
        s = ((q[0] - p[0]) * f[1] - (q[1] - p[1]) * f[0]) / den
        new_pts.append((p[0] + e[0] * s, p[1] + e[1] * s))
        new_r.append(max(radii[i] - d, 0) if den * sgn > 0 else max(radii[i] + d, 0))
    return new_pts, new_r


# ---------- masks ("L" images; drawn at SS x and box-reduced, so edges are anti-aliased) ----------
def _blank_ss():
    return Image.new("L", (N * SS, N * SS), 0)


def _poly_ss(pts, radii, grow=0):
    if grow:
        pts, radii = offset_polygon(pts, radii, -grow)
    m = _blank_ss()
    ImageDraw.Draw(m).polygon([(x * SS, y * SS) for x, y in rounded_outline(pts, radii)], fill=255)
    return m


def _circle_ss(c, r):
    m = _blank_ss()
    ImageDraw.Draw(m).ellipse(((c[0] - r) * SS, (c[1] - r) * SS, (c[0] + r) * SS, (c[1] + r) * SS), fill=255)
    return m


def _note_ss(grow=0):
    return ImageChops.lighter(_circle_ss(HEAD_C, HEAD_R + grow), _poly_ss(NOTE_PTS, NOTE_R, grow))


def _smooth_ss(m, radius):
    """Blur-and-threshold at supersampled scale: rounds sharp cusps left by boolean cuts."""
    return m.filter(ImageFilter.GaussianBlur(radius * SS)).point(lambda v: 255 if v >= 128 else 0)


@lru_cache(maxsize=None)
def shape(name):
    if name == "tri":
        return _poly_ss(TRI_PTS, TRI_R).reduce(SS)
    if name == "disc":
        return _circle_ss(DISC_C, DISC_R).reduce(SS)
    if name == "note":
        return _note_ss().reduce(SS)
    if name == "glyph":
        # Android monochrome topology: triangle - (disc | note halo), plus the note. Like Android's, the cut
        # runs straight from the flag's end into the disc (hull of the flag-corner halo and the disc), and
        # opens straight up beside the stem, so no slivers of triangle are left between them.
        cut = ImageChops.lighter(_circle_ss(DISC_C, DISC_R), _note_ss(HALO))
        extra = _blank_ss()
        flag = corner_centre(NOTE_PTS, NOTE_R, 3)
        hull = hull_of_circles((flag, NOTE_R[3] + HALO), (DISC_C, DISC_R))
        ImageDraw.Draw(extra).polygon([(x * SS, y * SS) for x, y in hull], fill=255)
        stem_x, stem_top = NOTE_PTS[1][0] - HALO, corner_centre(NOTE_PTS, NOTE_R, 1)
        ImageDraw.Draw(extra).rectangle((stem_x * SS, 0, stem_top[0] * SS, stem_top[1] * SS), fill=255)
        cut = ImageChops.lighter(cut, extra)
        body = _smooth_ss(ImageChops.subtract(_poly_ss(TRI_PTS, TRI_R), cut), FILLET)
        return ImageChops.lighter(body, _note_ss()).reduce(SS)
    raise KeyError(name)


def circle(cx, cy, r, extent=N):
    """Disc mask on an extent x extent canvas centred on the 1024 grid (extent > N: Android's 108 dp layer)."""
    o = (extent - N) / 2
    m = Image.new("L", (extent, extent), 0)
    ImageDraw.Draw(m).ellipse((cx + o - r, cy + o - r, cx + o + r, cy + o + r), fill=255)
    return m


def blur(m, s):
    return m.filter(ImageFilter.GaussianBlur(s)) if s else m


def shift(m, dx, dy):
    """Translate with sub-pixel precision; uncovered pixels are 0 (no wrap-around)."""
    return m.transform(m.size, Image.AFFINE, (1, 0, -dx, 0, 1, -dy), resample=Image.BILINEAR)


def mul(a, *more):
    for b in more:
        a = ImageChops.multiply(a, b)
    return a


def gain(m, g):
    return m.point([min(255, round(v * g)) for v in range(256)])


def facing(m, width, toward=TOWARD_LIGHT):
    """Band inside m along the edges whose outward normal points toward `toward` (a crescent)."""
    return ImageChops.subtract(m, shift(m, -toward[0] * width, -toward[1] * width))


def edge(m, s):
    """1 on the inside of the boundary, fading inward over about 2*s px."""
    return mul(m, gain(ImageChops.invert(blur(m, s)), 2))


# ---------- colour ----------
def hexrgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _lut(stops):
    cols = [(t, hexrgb(c)) for t, c in stops]
    lut = []
    for k in range(1024):
        t = k / 1023
        for (t0, c0), (t1, c1) in zip(cols, cols[1:]):
            if t <= t1:
                f = 0.0 if t1 == t0 else max(0.0, (t - t0) / (t1 - t0))
                lut.append(tuple(round(c0[i] + (c1[i] - c0[i]) * f) for i in range(3)))
                break
        else:
            lut.append(cols[-1][1])
    return lut


def _gradient(field, stops, extent=N):
    """field(x, y) -> 0..1 in grid coordinates, over an extent x extent px square centred on the grid."""
    lut = _lut(stops)
    grid = GRID * extent // N
    o = (extent - N) / 2
    step = extent / grid
    img = Image.new("RGB", (grid, grid))
    img.putdata([lut[int(max(0.0, min(1.0, field((i + 0.5) * step - o, (j + 0.5) * step - o))) * 1023 + 0.5)]
                 for j in range(grid) for i in range(grid)])
    return img.resize((extent, extent), Image.BICUBIC)


def linear(stops, p0, p1, extent=N):
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    l2 = dx * dx + dy * dy
    return _gradient(lambda x, y: ((x - p0[0]) * dx + (y - p0[1]) * dy) / l2, stops, extent)


def radial(stops, c, r):
    return _gradient(lambda x, y: math.hypot(x - c[0], y - c[1]) / r, stops)


def paint(base, fill, mask, opacity=1.0):
    """Composite `fill` (hex colour or RGB image) over `base` (RGBA) through `mask` at `opacity`."""
    if isinstance(fill, str):
        fill = Image.new("RGB", base.size, hexrgb(fill))
    alpha = mask if opacity >= 1 else gain(mask, opacity)
    return Image.alpha_composite(base, Image.merge("RGBA", (*fill.convert("RGB").split(), alpha)))


def transparent(size=N):
    return Image.new("RGBA", (size, size), (0, 0, 0, 0))


# ---------- concept A: Prism ----------
def concept_a(dark=False):
    tri, disc, note = shape("tri"), shape("disc"), shape("note")
    if dark:
        img = transparent()
    else:
        img = linear([(0, "#F5F7FF"), (0.5, "#DFE3FF"), (1, "#C7BBFF")], (0, 0), (N, N)).convert("RGBA")
        img = paint(img, "#FFFFFF", blur(circle(300, 230, 470), 120), 0.55)
    img = paint(img, SHADOW_DARK if dark else "#3B2FC9", blur(shift(tri, 0, 34), 40), 0.50 if dark else 0.30)  # ambient
    img = paint(img, SHADOW_DARK if dark else "#2A2290", blur(shift(tri, 0, 8), 8), 0.30 if dark else 0.16)  # contact
    stops = ([(0, "#7CC2FF"), (0.42, "#5F8DFF"), (0.75, "#5B5BF0"), (1, "#5A3FE0")] if dark else
             [(0, "#93D3FF"), (0.42, "#72A6FF"), (0.75, "#6A6BFF"), (1, "#6C4FF5")])
    img = paint(img, linear(stops, (204, 76), (760, 948)), tri)
    img = paint(img, "#3A2FC4", mul(blur(facing(tri, 26, AWAY), 18), tri), 0.30)  # glass thickness
    img = paint(img, "#FFFFFF", mul(tri, blur(circle(330, 250, 330), 90)), 0.22)  # sheen
    caustic = mul(blur(facing(tri, 22, AWAY), 3), ImageChops.invert(blur(facing(tri, 9, AWAY), 2)), tri)
    img = paint(img, "#D6DEFF", caustic, 0.30)  # light focused inside the far edge
    img = paint(img, "#FFFFFF", mul(blur(facing(tri, 10), 2), tri), 0.95)  # specular rim
    img = paint(img, "#FFFFFF", mul(blur(facing(tri, 4, AWAY), 1), tri), 0.40)  # back rim, crisp far edge
    img = paint(img, "#FFFFFF", edge(tri, 1.2), 0.22)  # fresnel line all round
    img = paint(img, "#2E3AA8", mul(blur(shift(disc, 6, 22), 26), tri), 0.40)  # lens shadow
    cx, cy = DISC_C
    lens = radial([(0, "#EAF6FF"), (0.55, "#ACDDFF"), (1, "#5FAFFF")], (cx - 58, cy - 64), DISC_R * 1.5)
    img = paint(img, lens, disc)
    img = paint(img, "#FFFFFF", mul(blur(facing(disc, 8), 1.5), disc), 0.9)
    img = paint(img, "#2F6FD8", mul(blur(facing(disc, 8, AWAY), 1.5), disc), 0.45)
    img = paint(img, "#0B2766", blur(shift(note, 4, 12), 10), 0.35)
    img = paint(img, linear([(0, "#2B62BE"), (1, "#14357A")], (0, NOTE_PTS[1][1]), (0, HEAD_C[1] + HEAD_R)), note)
    img = paint(img, "#FFFFFF", mul(note, blur(circle(HEAD_C[0] - 24, HEAD_C[1] - 28, 40), 18)), 0.14)
    img = paint(img, "#9FC3FF", mul(blur(facing(note, 5), 1.2), note), 0.5)
    return img


# ---------- concept B: Midnight Lens ----------
def concept_b(dark=False):
    tri, disc, note = shape("tri"), shape("disc"), shape("note")
    if dark:
        img = transparent()
    else:
        img = radial([(0, "#33309E"), (0.55, "#1D1A66"), (1, "#0D0C33")], (400, 330), 900).convert("RGBA")
        img = paint(img, "#6C4FF5", blur(circle(620, 640, 380), 160), 0.45)
    img = paint(img, "#05041A", blur(shift(tri, 0, 30), 40), 0.5)
    body = linear([(0, "#5CC6FF"), (0.5, "#5A78FF"), (1, "#7446FF")], (204, 76), (760, 948))
    img = paint(img, body, tri, 0.66)  # translucent glass
    img = paint(img, "#8AD6FF", edge(tri, 16), 0.28)  # thick glass refracts more light at its edges
    img = paint(img, "#FFFFFF", mul(tri, blur(circle(330, 260, 300), 100)), 0.10)
    rim = linear([(0, "#C8F0FF"), (0.5, "#8FB4FF"), (1, "#B9A2FF")], (248, 150), (884, 874))
    img = paint(img, rim, edge(tri, 2.5), 0.95)
    img = paint(img, "#FFFFFF", mul(blur(facing(tri, 10), 2), tri), 0.80)  # specular rim
    img = paint(img, "#D9CCFF", mul(blur(facing(tri, 5, AWAY), 1.5), tri), 0.50)
    img = paint(img, "#7FC4FF", blur(circle(*DISC_C, DISC_R + 30), 40), 0.55)  # glow
    cx, cy = DISC_C
    core = radial([(0, "#F4FBFF"), (0.4, "#B8E0FF"), (0.8, "#6FA6FF"), (1, "#5A86FF")], (cx - 66, cy - 74), DISC_R * 1.75)
    img = paint(img, core, disc)
    img = paint(img, "#FFFFFF", mul(blur(facing(disc, 8), 1.5), disc), 0.85)
    img = paint(img, "#3B5BD8", mul(blur(facing(disc, 8, AWAY), 1.5), disc), 0.50)
    img = paint(img, "#050A2A", blur(shift(note, 3, 10), 9), 0.35)
    img = paint(img, linear([(0, "#1B2F7A"), (1, "#0E1A4A")], (0, NOTE_PTS[1][1]), (0, HEAD_C[1] + HEAD_R)), note)
    img = paint(img, "#6C8FE8", mul(blur(facing(note, 5), 1.2), note), 0.5)
    return img


# ---------- concept C: Glyph (the logo) ----------
# Split into layers for Android's adaptive icon: background() is the gradient tile, foreground() everything on
# top of it (the recessed well, the glyph's shadows, the glyph). Alpha "over" is associative, so the composite
# equals painting everything onto one canvas.
def background(extent=N):
    """Concept C's tile on an extent x extent px canvas centred on the 1024 grid (extent 1536 = Android's 108 dp
    layer, whose central 72 dp are the 1024 icon)."""
    img = linear(C_BACKGROUND, (180, 0), (844, N), extent).convert("RGBA")
    return paint(img, "#FFFFFF", blur(circle(260, 180, 420, extent), 140), 0.30)


def foreground(dark=False):
    """Concept C's glyph layer on a transparent 1024 canvas: frosted white for the light icon (a little of the
    blurred tile shows through), the sky-to-violet glyph without the well for the dark appearance."""
    g = shape("glyph")
    img = transparent()
    if not dark:  # a soft recessed well behind the lens hole, so the white note stands out
        img = paint(img, "#2A1F9A", blur(circle(*DISC_C, DISC_R - 10), 36), 0.32)
    img = paint(img, SHADOW_DARK if dark else "#22158A", blur(shift(g, 0, 22), 26), 0.40 if dark else 0.30)  # ambient
    img = paint(img, SHADOW_DARK if dark else "#22158A", blur(shift(g, 0, 6), 6), 0.30 if dark else 0.22)  # contact
    fill = (linear([(0, "#A9DAFF"), (0.5, "#7C9BFF"), (1, "#7B5CFF")], (204, 76), (760, 948)) if dark else
            linear([(0, "#FFFFFF"), (1, "#E2E7FF")], (204, 76), (760, 948)))
    img = paint(img, fill, g)
    if not dark:
        img = paint(img, background().filter(ImageFilter.GaussianBlur(20)), g, 0.10)  # frosted
    img = paint(img, "#5A4FD8" if dark else "#6F6FE0", mul(blur(facing(g, 16, AWAY), 10), g), 0.30)  # thickness
    img = paint(img, "#C4CCFF" if dark else "#A9B2FF", mul(blur(facing(g, 3, AWAY), 0.8), g), 0.6)  # far edge
    img = paint(img, "#FFFFFF", mul(blur(facing(g, 7), 1), g), 0.9)  # specular rim
    return img


def concept_c(dark=False):
    return foreground(True) if dark else Image.alpha_composite(background(), foreground())


CONCEPTS = {
    "A": ("Prism", "the Android icon, in glass", concept_a),
    "B": ("Midnight Lens", "deep indigo, glowing core", concept_b),
    "C": ("Glyph", "white glass silhouette", concept_c),
}


@lru_cache(maxsize=None)
def render(concept, dark=False):
    return CONCEPTS[concept][2](dark)


# ---------- the glyph as a vector ----------
def _march(mask):
    """Marching squares at half coverage over the anti-aliased mask: closed loops in pixel coordinates."""
    w, h = mask.size
    v = mask.tobytes()
    cand = ImageChops.multiply(mask.filter(ImageFilter.MaxFilter(3)).point(lambda p: 255 if p > 127 else 0),
                               mask.filter(ImageFilter.MinFilter(3)).point(lambda p: 255 if p <= 127 else 0))
    pts, adj = {}, {}

    def point(e):
        if e not in pts:
            kind, i, j = e
            a, b = (j * w + i, j * w + i + 1) if kind == "h" else (j * w + i, (j + 1) * w + i)
            t = (127.5 - v[a]) / (v[b] - v[a])
            pts[e] = (i + 0.5 + t, j + 0.5) if kind == "h" else (i + 0.5, j + 0.5 + t)
        return e

    for k, flag in enumerate(cand.tobytes()):
        i, j = k % w, k // w
        if not flag or i >= w - 1 or j >= h - 1:
            continue
        tl, tr, bl, br = v[k], v[k + 1], v[k + w], v[k + w + 1]
        case = (tl > 127) | (tr > 127) << 1 | (br > 127) << 2 | (bl > 127) << 3
        if case in (0, 15):
            continue
        top, right, bottom, left = ("h", i, j), ("v", i + 1, j), ("h", i, j + 1), ("v", i, j)
        crossed = [e for e, a, b in ((top, tl, tr), (right, tr, br), (bottom, br, bl), (left, bl, tl))
                   if (a > 127) != (b > 127)]
        if len(crossed) == 2:
            pairs = [crossed]
        elif (case == 5) == ((tl + tr + br + bl) / 4 > 127.5):  # saddle: cut off the top-right / bottom-left corners
            pairs = [(top, right), (bottom, left)]
        else:
            pairs = [(left, top), (right, bottom)]
        for a, b in pairs:
            adj.setdefault(point(a), []).append(point(b))
            adj.setdefault(b, []).append(a)
    loops, seen = [], set()
    for start in adj:
        if start in seen:
            continue
        loop, prev, cur = [], None, start
        while True:
            seen.add(cur)
            loop.append(pts[cur])
            nxt = adj[cur][0] if adj[cur][0] != prev else adj[cur][1]
            prev, cur = cur, nxt
            if cur == start:
                break
        loops.append(loop)
    return loops


def _douglas_peucker(pts, tol):
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        s, e = stack.pop()
        (x0, y0), (x1, y1) = pts[s], pts[e]
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy) or 1e-9
        best, at = -1.0, -1
        for k in range(s + 1, e):
            d = abs((pts[k][0] - x0) * dy - (pts[k][1] - y0) * dx) / length
            if d > best:
                best, at = d, k
        if best > tol:
            keep[at] = True
            stack += [(s, at), (at, e)]
    return [p for p, k in zip(pts, keep) if k]


def _area(loop):
    return sum(x0 * y1 - x1 * y0 for (x0, y0), (x1, y1) in zip(loop, loop[1:] + loop[:1])) / 2


def _inside(p, loop):
    x, y, c = p[0], p[1], False
    for (x0, y0), (x1, y1) in zip(loop, loop[1:] + loop[:1]):
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            c = not c
    return c


@lru_cache(maxsize=None)
def glyph_contours():
    """The glyph's outline on the 1024 grid: closed polygons (tolerance 0.2 px). Outer loops run clockwise on
    screen, holes counter-clockwise, so the default non-zero fill rule (SVG, Android pathData) fills it right."""
    out = []
    for loop in _march(shape("glyph")):
        far = max(range(len(loop)), key=lambda k: (loop[k][0] - loop[0][0]) ** 2 + (loop[k][1] - loop[0][1]) ** 2)
        simple = (_douglas_peucker(loop[:far + 1], TRACE_TOLERANCE)[:-1] +
                  _douglas_peucker(loop[far:] + loop[:1], TRACE_TOLERANCE)[:-1])
        out.append(simple)
    result = []
    for loop in out:
        depth = sum(_inside(loop[0], other) for other in out if other is not loop)
        clockwise = _area(loop) > 0  # y points down
        result.append(tuple(loop if clockwise == (depth % 2 == 0) else loop[::-1]))
    return tuple(sorted(result, key=lambda lp: -abs(_area(list(lp)))))


def glyph_bounds():
    xs = [x for loop in glyph_contours() for x, _ in loop]
    ys = [y for loop in glyph_contours() for _, y in loop]
    return min(xs), min(ys), max(xs), max(ys)


def glyph_box():
    """(x, y, side) of the in-app glyph's square box on the grid: centred on the canvas, glyph height = GLYPH_FILL."""
    _, y0, _, y1 = glyph_bounds()
    side = (y1 - y0) / GLYPH_FILL
    return N / 2 - side / 2, N / 2 - side / 2, side


def _num(v, decimals):
    s = f"{v:.{decimals}f}".rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


def glyph_path(scale=1.0, dx=0.0, dy=0.0, decimals=2):
    """Path data (M/L/Z only: valid SVG and Android pathData) of the glyph, each point mapped to p * scale + d."""
    return "".join("M" + "L".join(f"{_num(x * scale + dx, decimals)} {_num(y * scale + dy, decimals)}"
                                  for x, y in loop) + "Z" for loop in glyph_contours())


def glyph_svg(points=28, view=1000):
    """The in-app glyph as SVG: glyph_box() mapped onto a view x view viewBox, `points` pt intrinsic size."""
    bx, by, side = glyph_box()
    k = view / side
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{points}" height="{points}" '
            f'viewBox="0 0 {view} {view}">\n<path d="{glyph_path(k, -bx * k, -by * k, 1)}" fill="#000000"/>\n</svg>\n')


def rasterize(loops, size, scale, dx=0.0, dy=0.0):
    """Anti-aliased mask (size x size) of polygons mapped by p * scale + d, non-zero winding via even-odd of
    nested loops (they never cross)."""
    m = Image.new("L", (size * SS, size * SS), 0)
    for loop in loops:  # outer loops first (largest area), holes punched after their outer
        poly = [((x * scale + dx) * SS, (y * scale + dy) * SS) for x, y in loop]
        ImageDraw.Draw(m).polygon(poly, fill=255 if _area(list(loop)) > 0 else 0)
    return m.reduce(SS)


# ---------- variants ----------
def squircle(size):
    """iOS-like continuous-corner mask (superellipse, n = 5), for previews and the in-app tile only."""
    big, n = size * SS, 5.0
    pts = []
    for k in range(720):
        a = 2 * math.pi * k / 720
        c, s = math.cos(a), math.sin(a)
        pts.append((big / 2 * (1 + math.copysign(abs(c) ** (2 / n), c)),
                    big / 2 * (1 + math.copysign(abs(s) ** (2 / n), s))))
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m.reduce(SS)


def masked(icon, size):
    tile = icon.convert("RGBA")
    tile.putalpha(mul(tile.getchannel("A"), squircle(tile.width)))
    return tile if size == tile.width else tile.resize((size, size), Image.LANCZOS)


def tinted(foreground_img):
    """iOS tinted appearance: luminance of the dark foreground on black, stretched to near-white, RGB."""
    lum = Image.alpha_composite(Image.new("RGBA", (N, N), (0, 0, 0, 255)), foreground_img).convert("L")
    hist, acc, hi = lum.histogram(), 0, 255
    for v in range(255, -1, -1):
        acc += hist[v]
        if acc >= N * N * 0.005:
            hi = v
            break
    lum = lum.point([min(255, round(v * 245 / max(hi, 1))) for v in range(256)])
    return Image.merge("RGB", (lum, lum, lum))


def dark_tile(foreground_img):
    """Simulates the system's dark icon background under a transparent dark-appearance foreground."""
    bg = linear([(0, "#2E2E33"), (1, "#121214")], (0, 0), (0, N)).convert("RGBA")
    return Image.alpha_composite(bg, foreground_img)


def brand_tile(concept, dark=False):
    """The in-app full-colour mark at 1024: the icon masked to the squircle; dark = dark foreground on DARK_TILE."""
    icon = render(concept)
    if dark:
        icon = Image.alpha_composite(linear(DARK_TILE, (0, 0), (0, N)).convert("RGBA"), render(concept, True))
    return masked(icon, N)


def write_variants(concept, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    light, dark = render(concept), render(concept, dark=True)
    files = {
        "AppIcon.png": light.convert("RGB"),
        "AppIcon-dark.png": dark,
        "AppIcon-tinted.png": tinted(dark),
        "BrandMark.png": masked(light, N),
    }
    for name, img in files.items():
        img.save(os.path.join(out_dir, name), "PNG", optimize=True)
        print(f"wrote {os.path.join(out_dir, name)} ({img.width}x{img.height} {img.mode})")


# ---------- committed assets ----------
LUMINOSITY_DARK = [{"appearance": "luminosity", "value": "dark"}]
LUMINOSITY_TINTED = [{"appearance": "luminosity", "value": "tinted"}]
BRAND_MARK_POINTS = 120  # BrandMark size: the launch-screen image; smaller in-app uses scale it down


def _contents(images, properties=None):
    doc = {"images": images, "info": {"author": "xcode", "version": 1}}
    if properties:
        doc["properties"] = properties
    return json.dumps(doc, indent=2, sort_keys=True, separators=(",", " : ")) + "\n"


def _save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG", optimize=True)
    print(f"wrote {os.path.relpath(path)} ({img.width}x{img.height} {img.mode})")


def _write_text(text, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"wrote {os.path.relpath(path)}")


def write_assets(concept, root):
    catalog = os.path.join(root, "App", "Assets.xcassets")
    light, dark = render(concept), render(concept, dark=True)

    icons = os.path.join(catalog, "AppIcon.appiconset")
    _save(light.convert("RGB"), os.path.join(icons, "AppIcon.png"))  # Any: opaque
    _save(dark, os.path.join(icons, "AppIcon-Dark.png"))  # Dark: transparent background, the system fills it
    _save(tinted(dark), os.path.join(icons, "AppIcon-Tinted.png"))  # Tinted: opaque grayscale (R = G = B)
    single = {"idiom": "universal", "platform": "ios", "size": "1024x1024"}
    _write_text(_contents([
        dict(single, filename="AppIcon.png"),
        dict(single, filename="AppIcon-Dark.png", appearances=LUMINOSITY_DARK),
        dict(single, filename="AppIcon-Tinted.png", appearances=LUMINOSITY_TINTED),
    ]), os.path.join(icons, "Contents.json"))

    mark = os.path.join(catalog, "BrandMark.imageset")
    images = []
    for dark_mark in (False, True):
        tile = brand_tile(concept, dark_mark)
        for scale in (2, 3):
            name = f"BrandMark{'-Dark' if dark_mark else ''}@{scale}x.png"
            _save(tile.resize((BRAND_MARK_POINTS * scale,) * 2, Image.LANCZOS), os.path.join(mark, name))
            entry = {"filename": name, "idiom": "universal", "scale": f"{scale}x"}
            images.append(dict(entry, appearances=LUMINOSITY_DARK) if dark_mark else entry)
    _write_text(_contents(images), os.path.join(mark, "Contents.json"))

    glyph = os.path.join(catalog, "BrandGlyph.imageset")
    _write_text(glyph_svg(), os.path.join(glyph, "BrandGlyph.svg"))
    _write_text(_contents([{"filename": "BrandGlyph.svg", "idiom": "universal"}],
                          {"preserves-vector-representation": True, "template-rendering-intent": "template"}),
                os.path.join(glyph, "Contents.json"))

    _save(masked(light, 512), os.path.join(root, "docs", "brand", "pixlaudio-icon.png"))


# ---------- preview contact sheets ----------
def _font(size, bold=False):
    for path in (f"/usr/share/fonts/truetype/dejavu/DejaVuSans{'-Bold' if bold else ''}.ttf",
                 f"/System/Library/Fonts/Supplemental/Arial{' Bold' if bold else ''}.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size)


def _wallpaper(w, h, dark):
    small = Image.new("RGBA", (w // 4, h // 4))
    if dark:
        base, blobs = ("#141631", "#07070F"), [("#2B2F7A", 0.2, 0.3, 0.5), ("#4A1F5E", 0.85, 0.8, 0.45), ("#0F4A5A", 0.6, 0.1, 0.3)]
    else:
        base, blobs = ("#FBEFE6", "#E6EEFF"), [("#FFD6C2", 0.15, 0.85, 0.45), ("#CFF2E6", 0.8, 0.2, 0.4), ("#E4D9FF", 0.6, 0.9, 0.35)]
    a, b = hexrgb(base[0]), hexrgb(base[1])
    for y in range(small.height):
        t = y / max(1, small.height - 1)
        ImageDraw.Draw(small).line((0, y, small.width, y), fill=tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3)))
    for col, cx, cy, r in blobs:
        m = Image.new("L", small.size, 0)
        rr = r * small.width
        ImageDraw.Draw(m).ellipse((cx * small.width - rr, cy * small.height - rr, cx * small.width + rr, cy * small.height + rr), fill=200)
        small = Image.composite(Image.new("RGBA", small.size, hexrgb(col) + (255,)), small, m.filter(ImageFilter.GaussianBlur(rr * 0.6)))
    return small.resize((w, h), Image.BICUBIC)


def _drop_icon(sheet, icon, x, y, shadow=0.28):
    a = icon.getchannel("A")
    pad = max(8, icon.width // 6)
    sh = Image.new("L", (icon.width + 2 * pad, icon.height + 2 * pad), 0)
    sh.paste(a, (pad, pad))
    sh = sh.filter(ImageFilter.GaussianBlur(icon.width / 30)).point(lambda v: round(v * shadow))
    shadow_img = Image.new("RGBA", sh.size, (10, 10, 40, 0))
    shadow_img.putalpha(sh)
    sheet.alpha_composite(shadow_img, (x - pad, y - pad + max(1, icon.width // 40)))
    sheet.alpha_composite(icon, (x, y))


def write_compare(path):
    col_w, gap, big = 500, 44, 420
    width, height = 3 * col_w + 4 * gap, 1180
    sheet = Image.new("RGBA", (width, height), hexrgb("#F2F2F6") + (255,))
    d = ImageDraw.Draw(sheet)
    d.text((gap, 34), "PixlAudio logo concepts", font=_font(34, True), fill=hexrgb("#16161D"))
    d.text((gap, 82), "1024 master scaled down, then 120 px and 60 px on light and dark wallpapers. "
           "The rounded mask is for preview only; the real iOS icon is square.", font=_font(17), fill=hexrgb("#6B6B76"))
    cap = _font(14)
    for k, (key, (name, tagline, _)) in enumerate(CONCEPTS.items()):
        x0 = gap + k * (col_w + gap)
        light, dark = render(key), render(key, dark=True)
        d.ellipse((x0, 140, x0 + 44, 184), fill=hexrgb("#16161D"))
        d.text((x0 + 22, 162), key, font=_font(24, True), fill=(255, 255, 255), anchor="mm")
        d.text((x0 + 58, 138), name, font=_font(28, True), fill=hexrgb("#16161D"))
        d.text((x0 + 58, 172), tagline, font=_font(16), fill=hexrgb("#6B6B76"))
        _drop_icon(sheet, masked(light, big), x0 + (col_w - big) // 2, 214)
        for row, dark_wall in enumerate((False, True)):
            py = 676 + row * 238
            panel = _wallpaper(col_w, 216, dark_wall)
            pm = Image.new("L", panel.size, 0)
            ImageDraw.Draw(pm).rounded_rectangle((0, 0, col_w - 1, 215), radius=26, fill=255)
            sheet.paste(panel, (x0, py), pm)
            items = [("Default 120", light, 120), ("60", light, 60)]
            if dark_wall:
                items += [("Dark 120", dark_tile(dark), 120), ("60", dark_tile(dark), 60)]
            total = sum(s for _, _, s in items) + 34 * (len(items) - 1)
            ix = x0 + (col_w - total) // 2
            for label, icon, s in items:
                iy = py + 30 + (120 - s) // 2
                _drop_icon(sheet, masked(icon, s), ix, iy, 0.35)
                ImageDraw.Draw(sheet).text((ix + s // 2, py + 176), label, font=cap, anchor="mm",
                                           fill=(235, 235, 245) if dark_wall else hexrgb("#4A4A55"))
                ix += s + 34
    sheet.convert("RGB").save(path, "PNG", optimize=True)
    print(f"wrote {path} ({width}x{height})")


def _tint_simulation(gray, tint="#F5B94A"):
    """Roughly what iOS does with the tinted icon: the grayscale drives a tint colour over a dark tinted tile."""
    lum = gray.convert("L")
    bg = Image.new("RGB", gray.size, tuple(round(c * 0.16) for c in hexrgb(tint)))
    return Image.composite(Image.new("RGB", gray.size, hexrgb(tint)), bg, lum).convert("RGBA")


def _glyph_in_circle(px, circle_hex, glyph_hex, glyph_px):
    """Android/iOS About: the glyph box (glyph_px) centred in a px circle, from the traced vector."""
    _, _, side = glyph_box()
    bx, by, _ = glyph_box()
    k = glyph_px / side
    off = (px - glyph_px) / 2
    m = rasterize(glyph_contours(), px, k, off - bx * k, off - by * k)
    img = transparent(px)
    disc = Image.new("L", (px * SS, px * SS), 0)
    ImageDraw.Draw(disc).ellipse((0, 0, px * SS - 1, px * SS - 1), fill=255)
    img = paint(img, circle_hex, disc.reduce(SS))
    return paint(img, glyph_hex, m)


def write_preview(concept, path):
    width, height, gap = 1480, 1500, 40
    sheet = Image.new("RGBA", (width, height), hexrgb("#F2F2F6") + (255,))
    d = ImageDraw.Draw(sheet)
    ink, sub, cap = hexrgb("#16161D"), hexrgb("#6B6B76"), _font(15)
    name = CONCEPTS[concept][0]
    d.text((gap, 30), f"PixlAudio logo: concept {concept} “{name}”", font=_font(32, True), fill=ink)
    d.text((gap, 74), "iOS 26+ single-size icon: Any (opaque), Dark (transparent background; the system's dark tile "
           "simulated), Tinted (grayscale; an amber tint simulated). Squircle masks are previews.", font=_font(16), fill=sub)
    light, dark = render(concept), render(concept, dark=True)
    gray = tinted(dark)
    variants = [("Any (light)", light), ("Dark", dark_tile(dark)), ("Tinted", _tint_simulation(gray)),
                ("Tinted file (grayscale)", gray.convert("RGBA"))]
    big = 300
    for k, (label, icon) in enumerate(variants):
        x = gap + k * (big + 50)
        _drop_icon(sheet, masked(icon, big), x, 120)
        d.text((x + big // 2, 440), label, font=cap, anchor="mm", fill=ink)

    sizes = [180, 120, 87, 60, 40]
    for row, dark_wall in enumerate((False, True)):
        py = 480 + row * 250
        panel = _wallpaper(width - 2 * gap, 230, dark_wall)
        pm = Image.new("L", panel.size, 0)
        ImageDraw.Draw(pm).rounded_rectangle((0, 0, panel.width - 1, panel.height - 1), radius=26, fill=255)
        sheet.paste(panel, (gap, py), pm)
        icon = dark_tile(dark) if dark_wall else light
        ix = gap + 30
        for s in sizes:
            _drop_icon(sheet, masked(icon, s), ix, py + 20 + (180 - s) // 2, 0.35)
            d.text((ix + s // 2, py + 212), f"{s} px", font=cap, anchor="mm",
                   fill=(235, 235, 245) if dark_wall else hexrgb("#4A4A55"))
            ix += s + 30
        tint_icon = _tint_simulation(gray)
        for s in sizes[1:3]:
            _drop_icon(sheet, masked(tint_icon, s), ix, py + 20 + (180 - s) // 2, 0.35)
            ix += s + 30
        d.text((ix - 120, py + 212), "tinted", font=cap, anchor="mm",
               fill=(235, 235, 245) if dark_wall else hexrgb("#4A4A55"))

    py = 1000
    d.text((gap, py), "In-app", font=_font(22, True), fill=ink)
    x = gap
    for dark_mode in (False, True):  # the About circle, from the traced vector, at 1x and 3x
        circle_hex, glyph_hex = ("#473F77", "#E5DEFF") if dark_mode else ("#E5DEFF", "#473F77")
        bg = Image.new("RGBA", (220, 220), hexrgb("#141318" if dark_mode else "#FDF8FF") + (255,))
        bg.alpha_composite(_glyph_in_circle(144, circle_hex, glyph_hex, 84), (38, 20))
        bg.alpha_composite(_glyph_in_circle(48, circle_hex, glyph_hex, 28), (86, 168))
        sheet.alpha_composite(bg, (x, py + 40))
        d.text((x + 110, py + 276), f"About glyph {'dark' if dark_mode else 'light'} (3x, 1x)", font=cap, anchor="mm", fill=ink)
        x += 250
    for dark_mode in (False, True):  # launch screen: BrandMark (120 pt) on the launch background, phone at 1/2 pt
        phone = Image.new("RGBA", (197, 426), hexrgb("#141318" if dark_mode else "#FDF8FF") + (255,))
        tile = brand_tile(concept, dark_mode).resize((60, 60), Image.LANCZOS)
        phone.alpha_composite(tile, ((197 - 60) // 2, (426 - 60) // 2))
        pm = Image.new("L", phone.size, 0)
        ImageDraw.Draw(pm).rounded_rectangle((0, 0, 196, 425), radius=28, fill=255)
        sheet.paste(phone, (x, py + 40), pm)
        d.rounded_rectangle((x, py + 40, x + 196, py + 465), radius=28, outline=hexrgb("#C9C9D2"), width=2)
        d.text((x + 98, py + 480), f"Launch {'dark' if dark_mode else 'light'}", font=cap, anchor="mm", fill=ink)
        x += 230
    for dark_mode in (False, True):
        tile = brand_tile(concept, dark_mode).resize((180, 180), Image.LANCZOS)
        _drop_icon(sheet, tile, x, py + 60)
        d.text((x + 90, py + 276), f"BrandMark {'dark' if dark_mode else 'light'}", font=cap, anchor="mm", fill=ink)
        x += 210
    sheet.convert("RGB").save(path, "PNG", optimize=True)
    print(f"wrote {path} ({width}x{height})")


def trace_error():
    """Largest and mean difference between the traced vector, rasterized, and the glyph mask (0..255)."""
    diff = ImageChops.difference(rasterize(glyph_contours(), N, 1.0), shape("glyph"))
    hist = diff.histogram()
    return max(v for v in range(256) if hist[v]), sum(v * c for v, c in enumerate(hist)) / (N * N)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--concept", default=DEFAULT_CONCEPT, choices=sorted(CONCEPTS), type=str.upper)
    ap.add_argument("--root", default=ROOT, help="write the committed assets under this directory")
    ap.add_argument("--preview", metavar="OUT.png", help="contact sheet of the selected concept")
    ap.add_argument("--compare", metavar="OUT.png", help="contact sheet of all three concepts")
    ap.add_argument("--variants", metavar="DIR", help="write loose 1024 PNGs for review")
    ap.add_argument("--write", action="store_true", help="also write the committed assets")
    args = ap.parse_args()
    if args.preview:
        write_preview(args.concept, args.preview)
    if args.compare:
        write_compare(args.compare)
    if args.variants:
        write_variants(args.concept, args.variants)
    if args.write or not (args.preview or args.compare or args.variants):
        write_assets(args.concept, args.root)
        worst, mean = trace_error()
        print(f"glyph: {sum(len(lp) for lp in glyph_contours())} points in {len(glyph_contours())} loops; "
              f"trace vs mask: max {worst}/255, mean {mean:.3f}/255")


if __name__ == "__main__":
    main()
