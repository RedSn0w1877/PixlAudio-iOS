# Ring code pictures shared by Android and iOS

`scenes.jsonl`: one scene per line, what to draw. `id`, `bucket`, `random` are the code; every other key is an integer:
`width`/`height` (360 default), `cx`/`cy` (centre, default half the size), `half` (plate half-width in pixels, 130),
`rotDeg`, `tiltDeg`, `axisDeg`, `blurMilli`, `noiseMilli` (sigma times 1000), `noiseSeed`, `contrastMilli` (1000),
`clutter`, `art` (0 texture, 1 dark, 2 light, 3 stripes, 4 orange texture), `artSeed`, `marker` (0 hides the start dot),
`supersample` (2), `dotLuma`/`plateLuma`/`markerLuma`, `smudgeSlot` + `smudgePercent` + `smudgeLuma`, and `glare` as
`[cx, cy, rx, ry, angleDeg, gain]`. Degrees become radians as `deg * (pi / 180)`. The numbers are the parameters of Android's
`RenderParams` and of the Swift one of the same name.

`kotlin/*.pgm`: the scenes drawn by Android's committed `RingCodeRenderer` (commit 4f0aaed of branch everything), grayscale
binary PGM (P5), luma only, no hue map. They were made by compiling the committed ring sources with `kotlinc` and running
`render`, not by Gradle. The same harness read them back with Android's committed `RingScanner`: 12 / 12.

The Swift renderer wrote the same 12 pictures byte for byte (checked with `cmp` on Windows when these files were made), so
the Kotlin scanner reads what Swift renders as well. `RingCrossPlatformTests` keeps the Swift side honest on every run.
Android can add the same check: read `scenes.jsonl`, render, compare with these files or scan them.
