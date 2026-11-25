# Lyrics duet rundown (iOS), 2026-11-25 — branch `lyrics-duet` (from `everything`)

Owner's report: on duet songs (two singers, end-side lines) "it changes fonts" and "some lines aren't fully on the
left or right".

## What changed

- **Background vocals follow their line.** `PreparedLyrics.sideRole(of:)` (PixlCore) returns `.duet` for a
  background vocal grouped under a duet line in a duet song, else the line's own role. `KaraokeLyricsView` places a
  row by that side role (start / end padding, content width, text / frame / stack alignment, scale pivot,
  `startAligned` of the renderer) and still sizes it by `line.role` (background stays 0.65 em, half vertical
  padding). Before, every background vocal sat flush left with the lead lines' 15 % end inset, even when it answered
  a right-hand duet line. Orphan background vocals and non-duet songs are unchanged. Android's `LyricsRenderStyle`
  still places all background vocals on the start side; the Android agent of this batch may port the same rule.
- Test: `LyricsRenderMathTests.backgroundVocalsFollowTheirDuetLineToTheEndSide`.
- New screenshots (checked in CI run 45650078282: the echo sits flush right under its duet line): `lyricsDuetEcho` (39 000, the echo of the duet line "Follow the river…") and
  `lyricsDuetEmphasis` (47 600, emphasis on "higher" at the end of an end-aligned duet line).
- Unrelated build fix: `RingCodeDiagnosticsView.swift` imports `PixlModel` (`currentTimeMillis`); `everything`
  did not build without it.

## Checked, no change needed

- Font: every main and background line uses one `.system(size:weight: .heavy)` font (`KaraokeRowStyle.font`);
  duet lines take the same path as lead lines; nothing role-dependent but the 0.65 em background size. No font
  switch found in the iOS renderer (see "Open" below).
- Duet geometry: lead lines 24 pt start / max(44, 15 %) end, duet lines max(24, 15 %) start / 24 pt end, wrapped
  lines aligned by `multilineTextAlignment` inside a frame aligned to the same side; interlude dots before a duet
  line are right-aligned at 24 pt.

## Open (not fixed)

- RTL lines (Hebrew, Arabic) with the start alignment pivot on the right (`pivotX`) but their frame is aligned
  `.leading` (left); Android's `TextAlign.Start` puts them on the right. Unverified on device.
- End-aligned lines get no horizontal `displayPadding` in `KaraokeTextRenderer` (it shifted them ~20 pt). The
  `lyricsDuetEmphasis` shot (CI run 45650078282) shows the scale and glow on "higher" are not visibly cut; a very
  strong glow could still be trimmed at the right edge.
- Background grouping is by time window (Android §1.7), not by TTML paragraph: where a lead and a duet line overlap,
  an echo joins the line that started last.
- "Changes fonts" could not be reproduced from code; if it still shows, it is most likely the system font fallback
  for scripts SF Pro lacks (e.g. Hangul in a mixed line), or the emphasis scale on long held words (explicit-end
  TTML, which is also where duet roles come from).
