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

## Round 2: Android parity (Android `lyrics-duet` bdd22f6 / a43f146, its handoff items 1-6)

- **Background vocals keep their singer's side from the TTML (Android 2 + 3).** In a duet song
  `TtmlDocumentParser` files each background vocal under `LyricsVoiceIds.leadBackground` /
  `.duetBackground` (PixlModel, role `background`) by the `<p>` it was nested in. `PreparedLyricsBuilder` reads
  that as an owner hint: grouping prefers a line of that side and falls back to the old time-only rule.
  `PreparedLine.duetEnd` (new, default false) is true for duet lines, background vocals grouped under one, and
  orphan vocals nested in one; `PreparedLyrics.sideRole(of:)` and the interlude `alignEnd` now key on it. Solo songs
  keep plain `background` ids; cached docs without the new ids behave exactly as before.
- **Undeclared agents (Android 4).** iOS already resolved undeclared agents in order of appearance (first singer
  lead, others duet); now an undeclared `v1000`+ id (the catalogs' group id) sings with the lead
  (`Builder.isGroupAgentId`). iOS still picks the lead as the first singer to *appear*, not the first declared
  person (Android); same result on catalog files, which declare v1 first.
- **Physical duet sides (Android 5).** `LyricsRenderMetrics.pivotX` in duets is 0 / 1 by side only (an RTL
  singer-1 line used to pivot right). `KaraokeRowContainer` forces `.leftToRight` layout direction on duet rows so a
  right-to-left device language cannot mirror the paddings / alignments; RTL lines in duets get the start display
  padding like LTR ones. Solo songs unchanged (still `.leading` / `.trailing`).
- **Short lines flush to their side (Android 1): no bug on iOS.** The row's VStack hugs its text and is placed by
  `.frame(width: contentWidth, alignment: side)`, so a one-row line sits at the trailing edge; translation and
  romanisation follow the stack alignment. Nothing like Compose's shrink-to-intrinsic measurement.
- **Font coverage (Android 6): not applicable.** iOS has no whole-song font fallback; every line uses
  `.system(size:weight:)` (SF Pro, per-glyph system fallback only).
- Tests: `DuetLyricsTests` (Android `DuetLyricsTest` end to end, plus an orphan-in-duet case) and
  `LyricsRenderMathTests.goldenAlignmentTable` (Android's table).

### Still open

- Solo songs with RTL text: Android places them by `TextAlign.Start/End` (RTL start = right, end pivot = left);
  iOS keeps `.leading` frames (left in an LTR app) with a right pivot for start. Not touched (out of scope).
- Wrapped RTL lines in a duet under the forced LTR direction: lines should align left (singer 1) / right
  (singer 2); not checked on a device.
