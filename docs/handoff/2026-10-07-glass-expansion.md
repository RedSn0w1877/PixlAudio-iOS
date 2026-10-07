# More Liquid Glass (2026-10-07, branch `wt/glass`)

Hoa asked for more Liquid Glass, starting with the queue. He picked options A + B of the glass-expansion plan, plus
glass pills on the floating bars and a glass Stats header. The lyrics page and the full player's top bar belong to
other groups and are untouched. Design notes: `docs/design.md` › Glass expansion.

## What changed

- **See-through tall sheets.** `PresentationDetent.tallGlass` is one `.fraction(0.92)` detent, defined in
  `DesignSystem/Components/SheetScaffold.swift`. It replaces `[.large]` for:
  - the queue;
  - the song sheet (`AppSheet.songInfo`, and the one the queue opens);
  - the AI Daily Mix sheet (`aiPlaylist`);
  - Taizo's chat (`taisChat`).
- **Queue** (`Features/Queue/QueueSheet.swift`):
  - The toolbar circles are separate interactive glass, with no backing capsule.
  - The toolbar and the open menu share one `GlassEffectContainer`. The ⋯ circle morphs into "Save as playlist"
    (shared `glassEffectID`), while Locate and Clear materialise.
  - The menu animates with a spring through `withAnimation`; the root's implicit ease-out is gone.
  - The modal VoiceOver semantics sit on the pills.
- **Floating bars:** the primary buttons are their own glass pills, and the bars' backing glass is gone. This covers
  Save as playlist (which now has a summary capsule and a Save pill), Edit song (Cancel and Save), the Library tab
  order (a Reset circle and the Done pill) and genre Quick Fill (the Select all · Clear pair, a status capsule and
  Next).
- **Listening Stats:** the collapsing header is Settings' glass bar.
- **Decision-10 fixes:**
  - the full player's loading chip and format pill are clear glass;
  - the genre page's artist header is glass, and its album play button a glass circle;
  - the playlist editor's collage and Pick Image tiles are glass.
- **Performance containers:** the sleep timer's surfaces, and the Save as playlist fields.
- **Demo ids:** `queue.saveAsPlaylist` and `genre.quickFill` (`App/Demo/UITestLaunchRouter.swift`).
- **Tests:**
  - `PlayerScreenshotTests`: `testQueueMenuDark`, `testSaveQueueLight`, `testSaveQueueDark`;
  - `LibraryScreenshotTests`: `testGenreQuickFillLight`, `testGenreQuickFillGenreStepDark`;
  - `GlassAccessibilityTests/testQueueControlsKeepButtonTraits`;
  - `MenuRecordingTests/testQueueMenuMorph` (opt-in filming).
- **Docs:** `api-notes.md` (`PresentationDetent.fraction`, `glassEffectTransition` / `.materialize`, the shared
  `glassEffectID`, non-interactive `Glass.clear`), `design.md`, `performance.md` and `parity.md` (a new glass row and
  the queue row's divergences).

## Verified, and how

- No Mac here, so nothing was compiled for iOS. Every changed Swift file passes `swiftc -parse` (Linux Swift 6.4),
  and `ci/check-forbidden.sh` passes.
- API signatures were checked against the plan's developer.apple.com notes:
  - `glassEffectTransition(_:)` and `GlassEffectTransition.materialize` (iOS 26.0);
  - `glassEffectID(_:in:)` (iOS 26.0);
  - `PresentationDetent.fraction(_:)` (iOS 16).
- Every other API was already used in the app. No iOS 27 API, so `Compat27.swift` is untouched.
- `LaunchConfigurationTests.testEveryDemoScreenRoutes` rules hold for the two new ids (each has one destination;
  the genre id's ready element is `screen.genreDetail`).

## Next step (CI)

Push and run the screenshot classes:
`[shots:PlayerScreenshotTests,LibraryScreenshotTests,HomeStatsScreenshotTests,GlassAccessibilityTests,ScreenshotTests/testNowPlayingDark,SpotifyConnectScreenshotTests/testNowPlayingChipLight,AIScreenshotTests,TaisScreenshotTests/testSongSheetLight]`.
Then look at:

- `queue-light` / `-dark`: the sheet should be inset and see-through over the player. If it's opaque, change
  `tallGlass` to 0.85. Also check that the toolbar and undo bar clear the bottom edge.
- `queueMenu-light` / `-dark`: the pills over the scrim, with no toolbar under them.
- `saveQueue-*`, `editSong-*`, `libraryReorderTabs-dark`, `genre.quickFill-*`: the separate glass shapes. The
  Quick Fill status text may truncate as it did before.
- `stats-scrolled-light`: the glass bar under the circles and the range pills.
- `playerExpanded*` / `nowPlaying*`: the format pill's contrast. The loading chip only shows while a song prepares.
- `genreDetail-*`, `playlistEditor-*`, `playerSongInfo-*` / `songInfo-*` (tall glass), `aiPlaylist-*`, the
  `taisChat*` shots (legibility of the see-through chat, and `taisChat-typing-dark` with the keyboard up).

To film the morph, add `[record:MenuRecordingTests]` to a commit message.

## Waiting on Hoa's phone

1. **The ⋯ morph.** Does the circle flow into "Save as playlist" and back? It shares one `glassEffectID` across an
   if / else, which Apple doesn't show. If it looks wrong, use the fallback in `design.md` › Glass expansion.
2. **VoiceOver on the open menu:** is it modal, and does escape close the menu rather than the whole queue?
3. **The 92 % sheets:** legibility over bright album art, and Taizo's chat over Home.
4. **The idle cost** of the full player rendering under the see-through queue.
