# PixlAudio lyrics view: build spec (Apple Music style)

**Target tree:** `C:/Users/Hoa/Downloads/Code Projects/PixelPlayer-master/beta2-release`.

**Base package:** `app/src/main/java/com/theveloper/pixelplay/`. Paths below are relative to it unless they start with `app/`.

**Verified in the live tree before writing:**
- `LyricsSheet.kt` is 2,485 lines. The public `LyricsSheet(...)` is at `:234`.
- `SyncedLyricsList` is at `:1304`, `LyricLineRow` at `:1520` and `LyricWordSpan` at `:1791`.
- `rememberSmoothPosition` is at `:2265` and `synthesizeWordsForLine` at `:2241`.
- The keep-screen-on `DisposableEffect` appears twice, at `:395` and `:418`.
- The mount point is `FullPlayerContent.kt:979`.
- Two blur preferences already exist: `animatedLyricsBlurEnabledFlow` and `animatedLyricsBlurStrengthFlow` in `data/preferences/UserPreferencesRepository.kt:1262-1270`.
- Library versions: Compose BOM 2026.06.00, Kotlin 2.4.0, `io.github.kyant0:backdrop` 2.0.0, Coil 2.7.0.
- The lyric sync offset is additive: `position + lyricsSyncOffset` (`LyricsSheet.kt:718`).

---

## 0. Licences and fonts (read first)

**Nothing below may be copied as code. Constants and techniques only, re-implemented from scratch in Kotlin.**

| Source | Licence | Rule |
|---|---|---|
| AMLL (`amll-dev/applemusic-like-lyrics` and forks: spicy-lyrics, AMLL-DroidMate, …) | AGPL-3.0 | Numbers and ideas only. Do not copy or translate its TS, CSS or GLSL line by line, and do not port its shader files. |
| music.apple.com JS and CSS (MusicKit components, `scene~*.js`) | Apple proprietary | Constants only. |
| aadishv/html-music, the Priva28 gist, beautiful-lyrics, HuangRunHua | No licence | Constants only. |
| accompanist-lyrics-ui / -core, amlv, Pear-Wall | Apache-2.0 | May be reused. Add an entry to `THIRD_PARTY_NOTICES.md` if any code is taken. |
| pixi-filters (twist, Kawase, adjustment maths) | MIT | The formulas are textbook. Write our own AGSL. |
| pushkine spring | MIT | Not needed. Use Compose's `FloatSpringSpec` (§3.1). |

**UI naming:** never use "Apple" or "Apple Music" in any UI string, resource name or setting. Call the feature something like "Karaoke lyrics".

**Font:** **never bundle SF Pro or SF Pro Rounded.** Apple's licence restricts them to Apple platforms.
- Use the bundled `app/src/main/res/font/gflex_variable.ttf` (Google Sans Flex 3.007, OFL-1.1) with these settings:
  - `FontVariation.weight(700)`
  - `FontVariation.Setting("ROND", 0f)`. Not the app's `GoogleSansRounded`, which uses `ROND=100`. Apple lyrics use plain SF Pro, not Rounded.
  - `FontVariation.width(100f)`
  - `FontVariation.opticalSizing(34.sp)`, i.e. opsz = the rendered size.
- Declare this as a new `FontFamily` `LyricsDisplayFamily` in `ui/theme/Type.kt`.
- Keep the existing `isCoveredByAppFont` fallback (`LyricsSheet.kt:2218`) for scripts Google Sans Flex does not cover, such as CJK. When it triggers, switch only the font family, never the size.

---

## 1. Visual constants

**Units:**
- `em` means the current line font size. At the default 34 sp, 1 em = 34 sp.
- "CSS px" in the sources ≈ dp.
- Every blur value in the sources is a Gaussian σ.
- Android `RenderEffect.createBlurEffect` and `setShadowLayer` take a *radius*, and Skia converts it with `σ = 0.57735·r + 0.5`. So always convert:

```kotlin
// σ in dp (CSS filter:blur value) → Android/Compose blur radius in px
fun sigmaDpToRadiusPx(sigmaDp: Float, density: Float): Float =
    ((sigmaDp * density - 0.5f) / 0.57735f).coerceAtLeast(0f)
// CSS text-shadow blur B (dp) has σ = B/2
fun cssShadowBlurToRadiusPx(blurDp: Float, density: Float) = sigmaDpToRadiusPx(blurDp / 2f, density)
```

(The old code passed dp straight to `Modifier.blur`, which treats it as a radius, so its blurs were about 42% weaker than the numbers suggested.)

### 1.1 Typography and layout

| Item | Value | Source |
|---|---|---|
| Main line | 34 sp, weight 700, line height 1.2059 (≈41 sp), `LineHeightStyle(Center, Trim.None)`, letter spacing −0.01 em | Apple mobile CSS 34 px / 1.2059 / 700; tracking is my judgement for Google Sans Flex |
| User size setting | Multiply the 34 sp by the existing lyrics text-size preference (`lyricsTextStyle.fontSize / default`). Keep other ratios relative to it. | — |
| Text motion | `TextMotion.Animated`, because lines scale | — |
| Line breaking | `LineBreak.Heading`: balanced on API 33+, falls back to simple below | Replaces AMLL's balanced-wrap DP |
| Line box padding | top and bottom 15 dp, so ≈30 dp between lines; start 24 dp; end 44 dp | Apple: 31 px gap, 45 px right margin; AMLL 0.4 em ×2 ≈ 27 dp |
| Duet songs (any line with `voiceRole == "duet"`) | Lead lines: end padding = 15% of view width. Duet lines: start padding = 15%, right-aligned text, pivot on the right. | AMLL 15%; Apple 75% width |
| Background-vocal line | 0.65 em (22 sp), same weight | Apple 22/34 |
| Translation | 0.54 em, weight 600, directly under its line, 4 dp gap | Apple |
| Pronunciation / romanization | 0.64 em, weight 600 | Apple |
| Plain (unsynced) lyrics | 20 sp, weight 500, white at 0.85, normal scroll, no blur or scale | Apple `--lyrics-static-*` |
| Anchor | The **top** of the active line sits at `0.25 × viewportHeight`. The viewport is the lyrics area between the header and bottom controls. The anchor must be at least header height + 16 dp. | Apple mobile offsetRatio 0.25 = AMLL full player top at 25% |
| Scroll limits | Top: the first line cannot go below the anchor. Bottom: stops when the end of the content reaches 50% of the viewport. | AMLL |
| Edge fade | Top: alpha 0 → 1 over the first 10% of the viewport. Bottom: 1 → 0 over the last 12% (the glass controls sit there). | AMLL vertical layout (top only), extended for the controls |
| First show / song change | Every line starts at `y = 2 × viewportHeight` and cascades up (§3.3) | AMLL |

### 1.2 Colour and alpha

All text is pure white. Brightness comes only from alpha.

| State | Alpha | Source |
|---|---|---|
| Inactive line (past or future) | **0.20** | Apple 0.175 / AMLL 0.2 |
| Active line, line-synced only (no word data) | **1.0** | — |
| Active line, word-synced, word not yet sung | **0.35** | Apple mobile |
| Active line, word-synced, word sung | **1.0** | Apple mobile |
| Background vocal: unsung / sung | 0.175 / 0.35 | Apple |
| Translation | 0.45 when active, 0.20 when inactive | Apple 0.45 |
| Pronunciation | Same as the parent line's current unsung/inactive alpha | — |
| Press highlight on a line | Rounded rect, radius 0.25 em, white at 0.07 | AMLL `#fff1` |

**Activeness.** Each line has an activeness value `a ∈ [0,1]` that blends between the inactive and active alphas:
- It rises 0 → 1 with `tween(300, easing = CubicBezierEasing(0f, 0f, 0.58f, 1f))` (ease-out).
- It falls 1 → 0 with `tween(450, easing = same)`.
- Formula: `unsungAlpha = lerp(0.20, 0.35, a)` and `sungAlpha = lerp(0.20, 1.0, a)`.
- When a line deactivates, its sung words fade back to 0.20. Past lines stay visible and dimmed, as on iOS. The web player hides past lines; do not copy that.

**Blend mode.** The whole lyrics layer composites onto the background with `BlendMode.Plus`, Compose's equivalent of Apple's `plus-lighter`.

**Bright-artwork exception** (Apple uses normal blending on white art): if the mean luma of the graded background tile (§5) is above 0.6:
- use `BlendMode.SrcOver`,
- set inactive alpha to 0.50,
- add a black scrim at 0.35 over the background.

**Increased contrast:** on API 34+, when `UiModeManager.contrast ≥ 0.5`:
- use `SrcOver`,
- set inactive alpha to 0.55,
- turn off the word gradient (a word is either unsung at 0.6 or sung at 1.0),
- turn off blur.

### 1.3 Depth effect (inactive lines)

**Scale:**
- 1.00 for active lines. 0.97 for inactive lines, **only while playing**. When paused, all lines are 1.00.
- Pivot: `TransformOrigin(0f, 0.5f)`. For duet or RTL lines, `(1f, 0.5f)`.
- Spring as in §3.1 "scale".

**Blur:** σ in dp, then convert with `sigmaDpToRadiusPx`.
- Distance:
  - lines above the active line: `d = activeIdx − i + 1`
  - lines below it: `d = i − lastHotIdx`
- `σ = min(5, (1 + d) × 0.8) × blurStrengthPref`. That gives 1.6, 2.4, 3.2, 4.0, then 4.8 dp going down. The line just above the active one gets 2.4.
- Blur is 0 in these cases:
  - hot lines,
  - while the user is dragging or flinging (§4),
  - when `animatedLyricsBlurEnabled == false`,
  - on API < 31.
- Transition: `tween(400)`. Write the radius to state in 0.25 px steps so layers are not re-rasterised every frame.
- **API 30 fallback (no RenderEffect):** no blur. Use an alpha falloff instead: `inactiveAlpha × (1 − 0.06·min(d,4))`, i.e. 0.20 → 0.152.
  - Optional experiment, only if it looks right on the API 30 AVD: draw inactive lines with `color = Transparent, shadow = Shadow(White.copy(alpha), Offset.Zero, blurRadius)` so the text shadow acts as blurred text. Ship it only after checking it renders.

### 1.4 Word highlight (karaoke fill), word-synced lines

**Soft-edge width:** `fade = 0.5 × lineHeightPx`. This is AMLL's iPad value. Apple web uses 20% of each syllable's width instead; we use the height-based value so the edge is the same width on every syllable.

**Sweep:**
- For syllable *s* with box `[L, R]`, progress is `p = clamp((t − start)/(end − start))`, and it moves linearly.
- Edge centre: `xc = lerp(L − fade/2, R + fade/2, p)`.
- Fill: `sungAlpha` left of `xc − fade/2`, `unsungAlpha` right of `xc + fade/2`, a linear ramp in between.
- Syllables fully before the current time draw solid `sungAlpha`. Syllables after it draw solid `unsungAlpha`.

**Lift:**
- Each syllable moves up by `0.05 em × easeOut(clamp((t − start) / max(1000, dur)))`, with easing `CubicBezierEasing(0f, 0f, 0.58f, 1f)`.
- Background-vocal syllables lift 0.10 em.
- The drawn lift is multiplied by the line's activeness `a`, so words settle back down as the line deactivates. That is the "reverse" effect.

**Emphasis ("glow")** on long words:
- **Which words qualify:**
  - Merge syllables with `startsNewWord == false` into one word, then test the whole word.
  - It qualifies if its duration is ≥ 1000 ms **and** its trimmed length is 2–7 grapheme characters. CJK only needs the duration test.
  - **The duration must be explicit:** a `LyricsDoc` syllable duration, or `SyncedWord.endTime != null`. Words whose end is inferred (enhanced LRC) never emphasise, because the inferred end includes pauses.
  - Split the word into graphemes with `BreakIterator.getCharacterInstance()`. N is the grapheme count.
- **Timing and strength:**
  - `du = max(1000, wordDur)`. Grapheme *i* starts at `wordStart + (du / 2.5 / N) × i`, and `x = clamp((t − charStart) / du)`.
  - `f(v) = if (v > 1) sqrt(v) else v³`.
  - `amount = min(1.2, f(du/2000) × 0.6)` and `glow = min(0.8, f(du/3000) × 0.5)`.
  - For the **last word of the line**: amount ×1.6, glow ×1.5, du ×1.2.
- **Curve:**
  - `easeA = CubicBezierEasing(0.2f, 0.4f, 0.58f, 1f)` and `easeB = CubicBezierEasing(0.3f, 0f, 0.58f, 1f)`.
  - `e = if (x < .5) easeA(x*2) else 1 − easeB((x − .5)*2)`.
  - Scale about the grapheme centre: `1 + e × 0.1 × amount`.
  - Horizontal push: `−e × 0.03 × amount × (N/2 − i)` em, so the letters spread out from the middle.
  - Vertical: `−e × 0.025 × amount` em.
  - Glow is a text shadow: white at alpha `e × glow`, CSS blur `min(0.3, glow × 0.3)` em, converted with `cssShadowBlurToRadiusPx`. At 34 sp the maximum CSS blur is 10.2 dp.
- **Extra hop:** up by `sin(π·x′) × 0.05 em`, with `x′ = clamp((t − (charStart − 400)) / (du × 1.4))`. This is added on top of the normal lift.
- **Reference values** for checking the curve:

| Word length | Peak scale | Glow alpha |
|---|---|---|
| 1 s | ≈ 1.0075 | ≈ 0.02 |
| 2 s | 1.06 | 0.15 |
| 3 s | ≈ 1.07 | 0.5 |

### 1.5 Line-synced-only songs (no word data)

These must still look good, and must not fake a word fill. **Stop using `synthesizeWordsForLine`** (`LyricsSheet.kt:2241`) in the new renderer.

What they get:
- the cascade scroll (§3.3),
- scale 0.97 → 1.0,
- depth blur,
- the activeness fade 0.20 → 1.0 (300 ms),
- interlude dots,
- tap-to-seek.

That is exactly what Apple shows for line-timed lyrics. Users can upgrade a song to word timing through the tap-sync editor (§8).

### 1.6 Interlude dots

**When they appear:**
- When `nextLeadStart − prevEnd ≥ 9000 ms` (Apple's web code; AMLL uses 7000). An intro counts if the first line starts at ≥ 9000 ms, with `prevEnd = 0`.
- `prevEnd` is the maximum end of all earlier lines.
- For lines without an explicit end: `estimatedEnd = start + clamp(wordCount × 450 + 800, 1500, 6000)` ms.
- An empty-text LRC line counts as the explicit end of the previous line.

**Layout:**
- A pseudo-row in the line list: 3 dots, each 0.3 em across (≈10 dp), 0.15 em apart (≈5 dp).
- Margins of 0.4 em above and below, aligned to the line start. Right-aligned if the next line is a duet line.
- The row's height is multiplied by an `expand ∈ [0,1]` factor that is read in **placement**, so lines below slide rather than re-measure.

**Timeline**, with `g0` = gap start and `g1` = next line start:
- **Expand:** from `g0` over 300 ms with `EaseInOut`. Row height 0 → full, group scale 0.1 → 1, alpha 0 → 1.
- **Fill:** dot *k* (0..2) goes from alpha 0.3 to 1.0 linearly over `[g0 + k·(g1−g0)/3, g0 + (k+1)·(g1−g0)/3]`.
- **Breathing:** until `g1 − 1500`, group scale = `1 + 0.2 × sin²(π · ((t − g0) mod 5000) / 5000)`.
- **Final pulse:** from `g1 − 1500` until `g1 − 300`, scale = `1.1 + 0.3 × sin²(π · (t − (g1 − 1500)) / 1000)`, which pulses between 1.1 and 1.4.
- **Collapse:** from `g1 − 300` to `g1`, scale → 0.1, alpha → 0, height → 0, all `EaseInOut`.
- **Short gaps:** if `g1 − g0 < 3000`, skip the breathing: fill all dots, expand, then collapse.
- **After a seek:** jumping into a gap recomputes everything from `t`. Dots never animate from a stale state.

### 1.7 Background vocals and duets

**Grouping background vocals:**
- A `voiceRole == "background"` line belongs to the lead line whose `[start − 1000, end]` window contains its start.
- If it starts before the lead line, it goes above the lead line; otherwise below.

**Background vocals while inactive:**
- Collapsed: height 0, alpha 0, scale 0.75.
- They take no space and are never blurred, because they are invisible.

**When the group turns hot:**
- The collapsed height grows with spring §3.1 "bg".
- Alpha 0 → 1 over 300 ms.
- Scale 0.8 → 1.0.
- Vertical slide: `translationY = (1 − progress) × −0.8 × bgHeight`, or `+0.8 × bgHeight` when the vocal sits above the lead line.

**Duets:** right-aligned, with right pivot and padding per §1.1. If the next line after an interlude is a duet line, the dots are right-aligned too.

---

## 2. Background (animated artwork)

This follows Apple's web LyricsScene: 4 copies of the art, twisted, blurred and over-saturated. **No blur runs per frame.** Blur and colour work happen once per track on tiny bitmaps.

### 2.1 Baking, once per track

**Where it runs:** `ArtworkSpriteBaker`, on `Dispatchers.Default`, cached in an `LruCache<String, SpriteSet>(4)` keyed by the art URI.

1. **Decode the art.** Use Coil at 96×96 with `allowHardware(false)`.

2. **Screen metrics.** Let `W, H` be the view size in px, `M = max(W, H)` and `S = min(W, H)`. Screen blur `σs = 0.09 × S` (start here; tune on device).

3. **Sprites:**

| Sprite | On-screen size | Tile mode | Padding |
|---|---|---|---|
| 0 | `hypot(W, H)`, covers the screen at any rotation | `MIRROR` | none |
| 1 | `0.80·M` | `CLAMP` | transparent, see below |
| 2 | `0.50·M` | `CLAMP` | transparent |
| 3 | `0.25·M` | `CLAMP` | transparent |

4. **Per-sprite blur.** For sprite *k* with on-screen size `Sk`:
   - `σtex = σs / Sk × 96`
   - `pad = ceil(3 σtex)` texels for sprites 1–3, 0 for sprite 0
   - The texture is `(96 + 2·pad)²`: the art centred on transparent, then Gaussian-blurred (3-pass box blur is fine) in premultiplied alpha.
   - Cost: well under 2 ms in total. Keep the bitmaps `ARGB_8888` and immutable.

5. **Brightness check.** Compute the mean luma of the graded result (§2.3) on the 96 px art. This drives §1.2's bright-art exception.

6. **No art:** reuse the existing `PlayerFlowingGradient(colorScheme)` from `PlayerAmbientEffects.kt`, not the sprites.

### 2.2 Motion, per frame

Rates are Apple's per-33 ms increments × 30, in rad/s:

| Sprite | Rotation | Centre |
|---|---|---|
| 0 | +0.09 | screen centre |
| 1 | −0.24 | `(W/2.5, H/2.5)` |
| 2 | −0.18 | orbits `(W/2, H/2)` at radius `0.25W`, angle `θ2 × 0.75` |
| 3 | +0.12 | orbits `(W/2 + 0.05W, H/2)` at radius `0.25W`, angle `θ3 × 0.75` |

- **Initial angles:** random per track.
- **Reduced motion** (`Settings.Global.ANIMATOR_DURATION_SCALE == 0`): 0.03 rad/s for every sprite, and no orbit.
- **Frame rate:** 30 fps. The background lives in its own `graphicsLayer` and is invalidated only when ≥ 33 ms have passed since its last draw. Lyric animation must never invalidate it.
- **Stop** when the lyrics sheet is not visible (`AnimatedVisibility` gone, or `ON_STOP`), or power-save is on. Keep animating while paused, as Apple does.
- **Track change:** crossfade the old and new sprite sets over 1,700 ms, linear (Apple: alpha +0.02 per 33 ms tick). Draw both sets only during the fade.

### 2.3 Compositing, by API tier

**Tier B, API 33+ (default where available).** Draw one full-screen `ShaderBrush(RuntimeShader)` with our own AGSL:

**Inputs:**
- `uniform shader s0..s3`: each sprite is a `BitmapShader` whose local matrix = the sprite's transform (scale, rotate about its centre, translate).
- Uniforms `size`, `twistAngle = −3.25`, `twistRadius = 1.0 × S` (scaled from Apple's 900 px; tune by eye) and `fade` (the crossfade).

**Per pixel:**
1. **Twist.** `d = p − size/2`. If `|d| < R`, rotate `d` by `twistAngle × ((R − |d|)/R)²`, then set `q = size/2 + d`.
2. **Composite.** `col = s0.eval(q)`, then `col = sk + col × (1 − sk.a)` for k = 1..3.
3. **Grade** in gamma-encoded sRGB, float, clamping only at the end:
   - saturation: `rgb = mix(dot(rgb, (0.2125, 0.7154, 0.0721)), rgb, 2.75)`
   - contrast: `rgb = (rgb − 0.5) × 1.9 + 0.5`
   - brightness: `rgb *= 0.7`
   - `rgb = clamp(rgb, 0, 1)`
4. **Overlays:** black at 50% (`rgb *= 0.5`), then white at 5% (`rgb = rgb × 0.95 + 0.05`).
5. **Dither:** add `(ign(p) − 0.5)/255`, where `ign(p) = fract(52.9829189 × fract(dot(p, float2(0.06711056, 0.00583715))))`. This is interleaved-gradient noise, a public-domain technique.

**Crossfade:** draw the outgoing set with the same shader at `1 − fade`.

**Cost:** one full-screen pass with 4 bilinear fetches per pixel at 30 fps. Trivial.

**Optional, API 31+ only:** a `RenderEffect` blur of σ ≈ 1.5% of W on the background layer, to soften twist creases. Leave it off by default.

**Tier A, API 30–32:**
- In `drawWithCache` / `onDrawBehind` on the background layer:
  1. `canvas.saveLayer(bounds, Paint().apply { colorFilter = ColorMatrixColorFilter(GRADE) })`
  2. Draw sprites 0–3 as rects filled with `BitmapShader` plus local matrix, `FilterQuality.Low`.
  3. `restore()`
  4. Draw a black rect at 0.5, then a white rect at 0.05.
  5. Overlay a 64×64 noise tile at 3% alpha (`TileMode.REPEAT`, generated once).
- No twist on this tier.
- `GRADE` is saturation 2.75 → contrast 1.9 → brightness 0.7 collapsed into one matrix (sRGB 0–255, clamped by the filter). Computed for this spec:

```
R' =  3.16291R − 1.66509G − 0.16781B − 80.325
G' = −0.49459R + 1.99241G − 0.16781B − 80.325
B' = −0.49459R − 1.66509G + 3.48969B − 80.325
```

(Each row sums to 1.33 = 1.9 × 0.7. The offset is −0.315 × 255. Do **not** fold the black and white overlays into this matrix: the clamp has to happen between them.)

- **First frame, before baking finishes:** fill with `colorScheme.surfaceContainerLowest` darkened ×0.5, then crossfade to the sprites.

---

## 3. Motion engine

### 3.1 Spring conversion

The web springs are `m·x″ + c·x′ + k·x = 0`. Compose `spring()` assumes unit mass, so:
- `stiffness = k / m`
- `dampingRatio ζ = c / (2·√(k·m))`

AMLL line springs use m = 0.9.

| Use | Web (m, k, c) | Compose `spring(dampingRatio, stiffness)` |
|---|---|---|
| Normal playback, line Y | 0.9, k = 170…220, c = 2.2√k | ζ = 1.1/√0.9 = **1.1595**, stiffness = k/0.9 = **188.9…244.4** |
| Seek, interlude, first or last line, snap-back | 0.9, 90, 15 | ζ = 15/(2√81) = **0.8333**, stiffness = **100** |
| Song ended | 0.9, 140, 22 | ζ = 22/(2√126) = **0.980**, stiffness = **155.6** |
| Line scale | 2, 100, 25 | ζ = 25/(2√200) = **0.884**, stiffness = **50** |
| Background-vocal expand and slide | — | ζ = **0.9**, stiffness = **150** (my choice) |

**Normal-playback stiffness:**
- `gap = clamp(line[i].start − line[i−1].start, 100, 800)`
- `ratio = (1 − (gap − 100)/700)^0.2`
- `kWeb = 170 + 50·ratio`, so `stiffness = kWeb / 0.9`
- Lines that come quickly get a stiffer, faster spring.

**Evaluating springs:**
- Use `FloatSpringSpec(dampingRatio, stiffness, visibilityThreshold = 0.5f)` with `getValueFromNanos` / `getVelocityFromNanos`. This is the exact closed form, in public `animation-core`.
- **Retargeting:** take the current value and velocity, then restart toward the new target.
- **Do not** use one `Animatable` per line. Everything runs in the single frame loop in §3.4.

### 3.2 Which line is active

**Lead-in:**
- A line becomes **hot** at `start − 250 ms` (Apple), for scrolling, activeness and scale.
- The word fill always uses the exact times.

**Offset:**
- Lyrics time `t = playerPosition + lyricsSyncOffset`.

**Hot set and scroll target:**
- The hot set is every line with `start − 250 ≤ t < end`.
- End per line:
  - the explicit end if there is one;
  - otherwise the next lead line's start;
  - the last line: `start + max(4000, estimated)`.
- Several lines can be hot at once (overlaps, background vocals).
- The **scroll target** is the lowest-index hot lead line. If none is hot, it is the last line with `start ≤ t`, or line 0.

**Lookup:**
- Binary search over the pre-sorted start times, run in the frame loop.
- Never use `derivedStateOf` over the position in composition. This replaces `resolveCurrentLineIndex` (`LyricsSheet.kt:2373`).

### 3.3 Cascade (stagger)

**When:** the scroll target changes during normal playback.

**Targets:**
- `targetY[i] = anchorY − prefix[target] + prefix[i] + userOffset`.
- `prefix` is the sum of each preceding row's current effective height: measured height × expand factor for interlude and background rows.

**Delays:**
1. Start with `delay = 0` and `step = 50 ms`.
2. Walk the lines in index order. For each line whose current bottom is ≥ 0 (visible or below the viewport), give it `delay`, then `delay += step`.
3. From the target index onwards, also do `step /= 1.05` after each line.
4. Lines above the viewport get delay 0.

**Skipping invisible lines:** a line whose current **and** target positions are both outside `[−300 dp, H + 300 dp]` snaps with no spring.

**When the stagger is off:** delays are all 0 on seeks (|Δt| > 1000 ms from the prediction), resizes, lyrics rebuilds and the start of a user scroll.

**Delay implementation:** a pending `(target, startAtNanos, spec)` per line, applied by the frame loop.

### 3.4 Frame loop and clock

**`LyricsClock`:**
- `nowMs` is a `mutableLongStateOf`.
- Each frame it sets it from `positionProvider()` + offset.
- **Monotonic guard:** while playing, reject backward steps smaller than 80 ms. `MediaController` extrapolation can jitter backward when a session update arrives.
- A jump larger than 1000 ms counts as a seek.

**`LyricsEngine`** is one `LaunchedEffect`:
- `while (isActive) withFrameNanos { clock.tick(); engine.step(it) }`
- Per step:
  - update the hot set;
  - evaluate the springs and tweens;
  - **write per-line snapshot state only when a value changes**:
    - `y`, epsilon 0.25 px
    - `scale`, epsilon 0.0005
    - `blurPx`, 0.25 px steps
    - `activeness`, epsilon 0.002
    - `hot` (Boolean)
    - `expand`, interlude and background rows only
- **Suspends** when paused and every spring and tween is at rest. It wakes on play or pause, seek, lyrics change, size change or touch, via `snapshotFlow`.

---

## 4. Interaction

**Tap a line:**
- Calls `onSeekTo(line.startMs − lyricsSyncOffset)` (existing callback).
- Leaves user-scroll mode immediately.
- Uses the slow spring and no stagger. The dots restart from `t`.
- Press feedback per §1.2.

**Drag:**
- Starts after `viewConfiguration.touchSlop`.
- While dragging:
  - `userOffset += dy`, applied directly in placement with no spring;
  - all blur goes to 0 (250 ms linear);
  - the scale springs keep running.

**Fling:**
- If the release speed is below 100 px/s, there is no coasting.
- Otherwise use `exponentialDecay(frictionMultiplier = 0.733f, absVelocityThreshold = 50f)`. That matches the source's ×0.95 every 16.67 ms: λ = 3.08 /s = 4.2 × 0.733.
- Clamp per §1.1 and stop at the clamp.

**Snap-back to auto-follow:** whichever of these comes first:
- AMLL rule: ≥ 500 ms since the scroll ended, **and** the scroll target changes, **and** the new target is currently inside the viewport.
- Apple rule: 4,500 ms after the scroll ended.
- A seek.

**How the snap-back animates:**
1. Fold `userOffset` into each line's current spring value.
2. Set `userOffset = 0`.
3. Retarget with the slow spring (ζ 0.833, stiffness 100), no stagger.
4. Blur returns over 400 ms.

**Accessibility:**
- Each line node gets `semantics { text = …; onClick(label = "Play from here") }`.
- The container gets `scrollBy` / `scrollToIndex` semantics.
- Reduced motion:
  - springs snap and the stagger is 0;
  - no emphasis and no lift;
  - activeness still fades;
  - the background follows §2.2.

---

## 5. Performance contract

| Phase | Reads | Changes |
|---|---|---|
| **Composition** | The `PreparedLyrics` list (keyed), preferences, API tier, bright-art flag | Only on song change, lyrics edit, or a preference or size change. **Zero recompositions per frame during playback, and zero at line boundaries.** |
| **Measure** | Line text and width | Once per song, width or font size. Per-line `TextLayoutResult` is cached in the node. |
| **Placement** (parent `Layout`) | Every line's `y` state, every row's `expand` state | Re-runs while springs move. Cheap: ~100 `placeWithLayer` calls. |
| **Layer block** (`placeWithLayer { }`, per line) | That line's `scale`, `blurPx`, `alpha` (the API 30 falloff) | Only that line's RenderNode properties update. A translation-only change never re-rasterises a blurred layer. |
| **Draw** (per line node) | `hot`, `activeness`; **`clock.nowMs` only when `hot`** | Only hot lines (normally 1–2) redraw every frame. |

**Rules:**

1. **Custom `Layout`, not `LazyColumn` or Snapper.**
   - Positions come from per-line springs with staggered delays, not from a scroll offset.
   - The cascade needs every row height (prefix sums).
   - Compose every line. A typical song has 40–120, and measuring once costs about 20–40 ms at song load. Accept that, or prepare the next song's model early.
   - Keep the `Layout` inside `graphicsLayer { compositingStrategy = Offscreen; blendMode = Plus (or SrcOver) }`.
   - Draw the edge-fade mask in `drawWithContent { drawContent(); drawRect(fadeBrush, blendMode = DstIn) }` on that same layer.
   - This is one full-screen offscreen pass, and the only one.

2. **Each line is a single `Modifier.Node`** (`LyricLineNode : LayoutModifierNode, DrawModifierNode, SemanticsModifierNode`) on an empty `Layout`.
   - Do not use `Text` / `BasicText` composables. Measure with a shared `TextMeasurer(fontFamilyResolver, density, layoutDirection, cacheSize = 0)`.
   - **Inactive, or line-only:** one `drawText(layout, color = White.copy(alpha))`.
   - **Hot, word-synced:** from the full-line layout, cache each syllable's box: `getBoundingBox(first).left..getBoundingBox(last).right`, plus `getLineTop` / `getLineBottom` of its visual row. Handle RTL by taking min/max.
   - Lazily (the first time the line turns hot), measure one small single-line `TextLayoutResult` per syllable, and per grapheme for emphasis words.
   - Per frame, for each syllable: `translate(0, −lift) { drawText(sylLayout, brush/color, topLeft = box.topLeft) }`.
   - **The active syllable's brush** is a cached `ShaderBrush` wrapping one `LinearGradient(0 → fade, [sung, unsung])` shader. Per frame, only its local matrix is updated to `translate(xc − fade/2)`. No allocation per frame.
   - Solid sung and unsung syllables use `color =`.
   - Emphasis graphemes use `withTransform { scale; translate }` plus `drawText(..., shadow = Shadow(White.copy(e·glow), Offset.Zero, r))`.

3. **Blur on API 31+:**
   - `renderEffect = BlurEffect(r, r, TileMode.Decal)`, `clip = false`.
   - The line box's 15 dp vertical and 24/44 dp horizontal padding contains the halo, because a layer's output is bounded by the node.
   - Cache `BlurEffect` instances by quantised radius.
   - **Budget:** about 8 visible blurred lines × roughly 1344×180 px layers, re-rasterised only when their content changes. Inactive lines don't redraw.
   - Scale also forces no re-raster; it is a node property.
   - **Never use `Modifier.blur`.** It clips, and on API 30 it is silently ignored.

4. **Remove from `LyricsSheet.kt`:**
   - `rememberSmoothPosition` (`:2265`). It assumes 1× speed and would run ahead at 0.75× in the editor.
   - Every `positionProvider()` read in item scope.
   - `animateColorAsState` and the per-word `animate*AsState` calls.
   - The four-`Text` glow stack and the infinite wobble.
   - The `LyricSparkles` infinite transition.
   - The duplicate keep-screen-on `DisposableEffect` (keep the one at `:395`, delete the one at `:418`).

5. **Frame-accurate position:**
   - Add `fun framePositionMs(): Long` to `PlaybackStateHolder`: `activeLocalPlayer().currentPosition` passed through the same `resolveUiPosition` / paused-seek override logic (`:253-276`).
   - Expose it through `PlayerViewModel` as `currentPositionForLyrics()`.
   - It must be called on the main thread. The `MediaController` lives there, and the session is in-process on the main looper.
   - It is speed-aware (Media3 extrapolates using elapsed time × speed), and ExoPlayer already subtracts AudioTrack latency.
   - Do **not** raise the 250 ms polling rate. The renderer no longer depends on it.

6. **Background:** its own layer and its own 30 fps invalidation (§2.2). It is never read by lyric state.

7. **Acceptance:**
   - Layout Inspector shows 0 recompositions per second during steady playback.
   - `adb shell dumpsys gfxinfo com.theveloper.pixelplay framestats` over 60 s of a word-synced song: 90th-percentile frame < 8 ms at 120 Hz on the Pixel 10 Pro XL AVD, and no janky frames on a line change.
   - Check again on a real device before claiming any GPU numbers; the emulator GPU is not representative.

---

## 6. Data preparation

### 6.1 Prepared model

**New file `presentation/lyrics/model/PreparedLyrics.kt`** holds immutable, `@Immutable` types:

```kotlin
data class PreparedLyrics(val lines: PersistentList<PreparedLine>, val rows: PersistentList<Row>,
    val hasWordTiming: Boolean, val hasDuet: Boolean, val startsSorted: LongArray)
data class PreparedLine(val index: Int, val startMs: Long, val endMs: Long, val endIsExplicit: Boolean,
    val text: String, val role: VoiceRole /*LEAD, BACKGROUND, DUET*/, val groupLeadIndex: Int,
    val bgAbove: Boolean, val syllables: PersistentList<PreparedSyllable>?, val translation: String?,
    val romanization: String?)
data class PreparedSyllable(val charStart: Int, val charEnd: Int, val startMs: Long, val endMs: Long,
    val endIsExplicit: Boolean, val wordIndex: Int, val emphasis: Boolean)
sealed interface Row { data class Line(val lineIndex: Int): Row
    data class Interlude(val startMs: Long, val endMs: Long, val alignEnd: Boolean): Row }
```

**Rules:**
- Add these types to `app/compose_stability.conf`.
- **Built by `LyricsStateHolder`** (the existing `@Singleton`) on `Dispatchers.Default` whenever the lyrics change. It exposes `preparedLyrics: StateFlow<PreparedLyrics?>`.
- **Source preference:** `Lyrics.document` (a `LyricsDoc`: syllables, durations, voices, ends) is used when present. Otherwise `Lyrics.synced`, with `SyncedWord.startsNewWord` for word grouping.
- **Syllable ends:**
  - explicit if `LyricsDoc` duration or `SyncedWord.endTime` is set;
  - otherwise the next syllable's start;
  - the last syllable: `min(lineEnd, start + 1200)`, with `endIsExplicit = false`.
- **Line ends:** use the existing `resolveLineEndTimeMs` logic (`LyricsSheet.kt:2098`). Move it into this builder along with `sanitizeLyricLineText` / `sanitizeSyncedWords` / `clusterSyncedWords`.
- **Character ranges:** tokens keep their original whitespace, so `charStart` / `charEnd` index into `text` exactly.

### 6.2 TTML (phase 2, but plan for it)

`utils/TtmlLyricsParser.kt` currently converts TTML to enhanced LRC, dropping `<span end>`, `ttm:agent` (duets) and `ttm:role="x-bg"`.

Change it to build a `LyricsDoc` directly:
- `agent` other than the first vocalist → voice role `duet`
- `x-bg` → `background`
- span `begin` / `end` → syllable start and duration

Return that doc so `LyricsUtils.parseLyrics` keeps it. Until then, background-vocal and duet rendering only lights up for NetEase YRC / Musixmatch richsync (already `LyricsDoc`) and user syncs.

---

## 7. Files: change, add, delete

**Add** under `presentation/lyrics/`:

| File | Contents |
|---|---|
| `LyricsView.kt` | Public `@Composable fun KaraokeLyricsView(prepared, clock, engine, isPlaying, onSeekLine, modifier)`: the custom `Layout`, Plus/offscreen layer, edge mask, gestures |
| `LyricLineNode.kt` | Measure, draw and semantics node (§5.2) |
| `LyricsEngine.kt` | Springs, cascade, hot set, user scroll, snap-back, per-line state (§3–4) |
| `LyricsClock.kt` | Frame clock, monotonic guard, seek detection |
| `EmphasisMath.kt` | Emphasis formulas and easings (§1.4), unit-tested |
| `InterludeDots.kt` | Draw logic for the interlude row (§1.6) |
| `background/LyricsArtworkBackground.kt` | Composable: tier selection, 30 fps layer, crossfade |
| `background/ArtworkSpriteBaker.kt` | Decode, blur, pad, luma, `LruCache` |
| `background/LyricsBackgroundShader.kt` | Our own AGSL source as a `const val` string (API 33+) |
| `model/PreparedLyrics.kt` and `model/PreparedLyricsBuilder.kt` | §6 |

**Change:**

- **`presentation/components/LyricsSheet.kt`:**
  - Keep the public `LyricsSheet(...)` signature so `FullPlayerContent.kt:979` keeps compiling.
  - Add one parameter, `positionProvider: () -> Long = { playbackPositionFlow.value }`.
  - Replace `SyncedLyricsList` / `LyricLineRow` / `LyricWordSpan` (`:1304-1943`) with `KaraokeLyricsView`.
  - Replace the Scaffold's flat `containerColor` (`:699`) and the gradient fades (`:893-916`) with `LyricsArtworkBackground` behind a transparent Scaffold.
  - Restyle `PlainLyricsLine` (`:1946`) per §1.1.
  - Delete the now-unused helpers: `rememberSmoothPosition`, `rememberSweepBrush`, `LyricSparkles`, `computeSweepProgress`, `resolveHighlightedWordIndex`, `calculateHighlightMetrics`, `highlightSnapOffsetPx`, `resolveCurrentLineIndex`, `synthesizeWordsForLine`. Keep any that tests reference until those tests are moved.
  - Remove the duplicate keep-screen-on effect (`:418-439`).
  - Collect the DataStore flows once through the ViewModel or a state holder, not ad hoc (`:340-388`).
  - Keep search, import, translate, the sync-offset controls, `LyricsMoreBottomSheet` and immersive mode unchanged.
- **`presentation/components/player/FullPlayerContent.kt:979`:** pass `positionProvider = playerViewModel::currentPositionForLyrics`.
- **`presentation/viewmodel/PlaybackStateHolder.kt`:** add `framePositionMs()` (§5.5).
- **`presentation/viewmodel/PlayerViewModel.kt`:** add the facade `currentPositionForLyrics()` only. No new state fields.
- **`presentation/viewmodel/LyricsStateHolder.kt`:** add `preparedLyrics`.
- **`ui/theme/Type.kt`:** add `LyricsDisplayFamily` (§0).
- **`app/compose_stability.conf`:** add the prepared-model types.
- **`THIRD_PARTY_NOTICES.md`:** only if accompanist code is actually used.

**Delete:** `presentation/components/LyricsDocViewer.kt` (it has no callers).

**Do not touch** `PlayerAmbientEffects.kt`. It is the now-playing ambient background. Only `PlayerFlowingGradient` is reused, as the no-art fallback.

**Unit tests** (`app/src/test/...`), none of which needs a device:
- the prepared-lyrics builder: end inference, grouping, interlude detection including the intro and empty-LRC-line cases, emphasis only on explicit ends;
- cascade delays;
- the spring conversion table;
- emphasis reference values (1 s → 1.0075, 2 s → 1.06, 3 s → about 1.07);
- the `GRADE` matrix against the three-step reference on random colours.

---

## 8. Hooks for the tap-to-sync editor (separate spec)

- `KaraokeLyricsView` takes a `PreparedLyrics`, so the editor can preview a live, in-progress sync by rebuilding the model from its token list. Rebuilding is cheap; prepare off-thread.
- The editor saves a `LyricsDoc` (`LyricsDocCodec.encode`, `metadata.source = "user"`) through `LyricsRepository.updateLyrics`. That gives explicit syllable durations, so user-synced songs get the emphasis glow automatically.
- The same `LyricsClock` / `framePositionMs()` is speed-aware. While the editor is open:
  - allow 0.75× speed,
  - turn off audio offload,
  - turn off crossfade.

---

## 9. Liquid Glass controls over the lyrics

- **What the glass samples:** the lyrics screen's background layer and lyrics layer are recorded as the backdrop, using `rememberPageBackdrop()` and `Modifier.pageBackdrop(...)` from `ui/glass/PageBackdrop.kt`. The glass header and bottom controls are **siblings outside** that recorded subtree, so the glass bends the lyrics and the art.
- **Material:** Apple's HIG rule is the clear glass variant over media. When the art is bright (§2.1 luma > 0.6), add a dark dimming layer of **35%** under the glass. Glyphs stay bold white. Tint only the play/pause button.
- **Scroll edge:** lyrics dissolve under the glass through the edge fade in §1.1. The bottom fade must start above the top of the control cluster.
- **Appearing and disappearing** (immersive auto-hide): animate the backdrop lens and refraction strength 0 → 1 over 250 ms instead of fading alpha, following the HIG's "materialise by lensing, not fading".