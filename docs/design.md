# Design — a port of PixlAudio, with Liquid Glass in place of Material

**The port rule (owner decision 10, 2026-09-30 — overrides everything older):** every iOS screen reproduces the
Android PixlAudio screen — layout, structure, order, sizes, spacing, corner radii, content, behaviour and
album-art colour theming. **Only the Material elements change**, into Apple's real Liquid Glass. SF Pro (the system
font) at PixlAudio's sizes and weights. Owner: *"I want the layouts and design to look exactly like PixlAudio.
nothing change. but the material elements are replaced with liquid glass… that's why I'm calling it a port not a
remake."* Reviewers compare every screen side by side with Android: *same layout as PixlAudio, glass instead of
Material, nothing else changed.*

Sources of truth, in order: the Compose code under the Android repo's `presentation/**` and `ui/theme/**` (exact dp
and sp: 1 dp = 1 pt, 1 sp = 1 pt), then the screenshots in [`design-refs/`](design-refs/) (real Android PixlAudio,
Beta 2: `pp_*.png`; current Library › Songs: `owner-library-songs-2026-09-30.png`).

## Material → Liquid Glass mapping

| PixlAudio (Material 3) | iOS port | Design system |
|---|---|---|
| Pill / chip / quick-action button, Beta chip, Shuffle pill | Glass capsule (`glassEffect` in `Capsule`, interactive); tinted when Android filled it | `GlassPillButton` |
| Tabs / segmented buttons / filter chips (Library tabs) | Row of glass capsules; the selected one is tinted glass that glides (`glassEffectID` in a `GlassEffectContainer`) | `GlassPillRow` |
| `FilledIconButton` / `FilledTonalIconButton` / icon buttons | Glass circle, interactive | `GlassCircleButton` |
| FAB / big circular play button | `.glassProminent` / strongly tinted glass circle (the one primary action) | `GlassCircleButton(tint:)` |
| `Card`, `Surface`, greeting card, mix cards, settings groups | Rounded glass panel, same radius; Android's fill colour becomes the glass tint | `GlassCard` |
| Song list item (`EnhancedSongListItem`) | Glass rounded card, same geometry; playing = capsule + brighter `primaryContainer` glass | `SongCard` |
| `TopAppBar` with large title + actions | Same title in SF Pro + glass action circles | `LargeHeader` |
| Section title + subtitle (+ refresh button) | Same text styles, optional glass circle | `SectionHeader` |
| Bottom `NavigationBar` (custom compact bar, 3 icons) | **Owner change 2026-10-01/02:** the iOS tab bar — floating interactive-glass capsule (symbol + label, icons only in compact mode) whose selection is the system liquid lens (accent-tinted pill at rest; clear, swelling, magnifying lens under the finger) | `GlassNavBar` + `LiquidTabBar` |
| Mini player (player sheet, collapsed) | Glass bar tinted with the album's `primaryContainer`, same layout | `MiniPlayerBar` |
| `ModalBottomSheet` | System sheet (glass by itself) + PixlAudio's sheet layout inside | `SheetScaffold` + `.pixlSheet()` |
| Ripple, state layers | Glass `.interactive()` highlight; `PressScaleButtonStyle` for fills sitting on glass | `GlassStyle.swift` |
| Tonal elevation, shadows | None (glass depth) | — |
| Material shapes (cookie / squircle morphs), Material motion | Rounded/continuous shapes, interruptible springs | `PixlMotion` |
| Material You dynamic colour (wallpaper) | PixlAudio's brand scheme (`ArtworkTheme.brandPair`, from `0xFF6C4FF5`) — iOS has no wallpaper colours | `ThemeColors.brand` |
| Album-art colour scheme (`ColorSchemeProcessor`) | Same algorithm, ported bit-exact (`PixlLibrary/ArtworkTheme`) | `ThemeStore`, `ColorExtractor` |

Forbidden in `App/` (CI, `ci/check-forbidden.sh`): Material / Compose names as identifiers (`Ripple…`,
`FloatingActionButton`, `FAB…`, `…TonalElevation`, `MaterialTheme`, `Material3`, `Material…` types) and fake glass
(`.ultraThinMaterial`, `.thinMaterial`, `.regularMaterial`, `.thickMaterial`, `.ultraThickMaterial`, `.bar`,
`UIBlurEffect`, `UIVisualEffectView`). Palette role names (`primaryContainer`, …) are PixlAudio's and fine.

## Colour

- `ThemeColors` (`DesignSystem/Theme.swift`) exposes all 48 PixlAudio palette roles as `Color`
  (`theme.onPrimaryContainer`), backed by PixlLibrary's `ColorRoles`. Two environment values:
  - `\.appTheme` — the app chrome (Android's `MaterialTheme.colorScheme` outside the player): the **accent
    scheme** (Settings › Appearance › Accent Color, iOS-only; PixlAudio's violet `brandPair` by default), or the
    album scheme when *player theme = Global*;
  - `\.playerTheme` — the current song's album scheme (Android `LocalMaterialTheme` in the player / mini player);
    equals `appTheme` when nothing plays or album theming is off (Player Theme "Accent Color", stored `dynamic`).
- The accent (owner request 2026-10-07, see § Accent colour): a picked colour becomes
  `ArtworkTheme.accentPair(seed:)` — TonalSpot's surfaces, secondary, tertiary and role tones with the primary at
  the pick's own chroma (≥ 36), so the primary family is vivid in light mode and pastel (tone 80) in dark mode, and
  surfaces / icons take a faint cast of its hue as with the violet. Album schemes are unchanged. Never hard-code the
  violet: read `theme.primary` & co.
- `ThemeStore` follows the current song (`.task(id:)` in the shell) and `player_theme_preference_v2`,
  `album_art_palette_style_v1`, `album_art_color_accuracy_v1`; `ColorExtractor` decodes the art at 128 px and runs
  the ported seed selection + scheme generation off the main thread, cached in memory and `ArtworkThemeRecord`
  (key `<artwork>|<style>|accuracy_<n>|algo_v7`, like Android).
- Where Android **filled** a surface with a role, the port **tints glass** with it, at the strength in `GlassTint`:
  `prominent` 0.85 (primary action / selected item), `container` 0.62 (album-coloured panels: mini player, playing
  song, mix cards), `surface` 0.28 (neutral panels), `bar` 0.6 (the bottom bar, which content scrolls under). Text keeps Android's `on…` role.
- Light and dark as Android: schemes come in pairs; `app_theme_mode` forces one. Lyrics and the player background
  follow their own rules (always dark lyrics).

## Type

`PixlTextStyle` (`DesignSystem/Typography.swift`) mirrors `ui/theme/Type.kt` in SF Pro: same size, weight, line
height and tracking; apply with `.pixlFont(.bodyLarge)` / `.pixlFont(.bodyLarge, weight: .semibold)` /
`.pixlFont(.custom(size: 15, weight: .semibold, tracking: -0.2))`. Names match the Compose roles so calls port 1:1.
Text scales with Dynamic Type (like sp), capped at 1.6× to keep fixed bars intact.

| Role | pt | weight | line | tracking |
|---|---|---|---|---|
| displayLarge / Medium / Small | 48 / 36 / 30 | bold / bold / regular | 56 / 44 / 38 | 0 |
| headlineLarge / Medium / Small | 32 / 28 / 24 | semibold | 40 / 36 / 32 | 0 |
| titleLarge / Medium / Small | 22 / 18 / 14 | regular / medium / medium | 28 / 24 / 20 | 0 / 0.15 / 0.1 |
| bodyLarge / Medium / Small | 16 / 14 / 12 | regular | 24 / 20 / 16 | 0.5 / 0.25 / 0.4 |
| labelLarge / Medium / Small | 16 / 14 / 11 | medium | 20 / 16 / 16 | 0.1 / 0.5 / 0.5 |

Icons: a Material 24 dp icon ≈ an SF Symbol at 20 pt.

## Spacing, radii, geometry

`Tokens` (`DesignSystem/Tokens.swift`) holds the values used across screens, each naming its Compose source:
spacing, `Shapes` radii (8/16/24) plus card 28, mix card 32, content panel 34, quick action 20; the shell geometry;
mini player, song card, top bar and tab-row metrics. Add screen-specific values next to the screen, with the
Compose file they come from.

## Glass usage

- Real Liquid Glass only: `glassEffect(_:in:)`, `Glass.regular` / `.clear`, `.tint`, `.interactive`,
  `GlassEffectContainer`, `glassEffectID`, `glassEffectUnion`, `.buttonStyle(.glass / .glassProminent)`.
  `pixlGlass(in:tint:interactive:)` is the house helper.
- One variant per context: `.regular` everywhere; `.clear` only over media (player/lyrics backgrounds) with ~35 %
  dimming when the art is bright (`relativeLuminance > 0.6`).
- No glass on glass inside one element: a control sitting on a glass card/bar is a fill with `PressScaleButtonStyle`
  (mini-player transport, the song card's ⋮), or joins the card with `glassEffectUnion`. Exception by owner
  request: the tab bar's accent glass selection pill.
- Clusters of separate glass shapes share a `GlassEffectContainer` whose `spacing` is **smaller than the gap**
  between them, so they render together but never blend at rest.
- Sheets use the system presentation; never override `presentationBackground`.
- Accessibility: standard glass adapts to Reduce Transparency / Increase Contrast / Reduce Motion; every icon-only
  button has an accessibility label; 44 pt targets where Android had 48 dp.

## Performance with glass

Rows and cards are glass here, so: lazy stacks (`LazyVStack` / `LazyVGrid`), **one** glass layer per row and no
container per row, art decoded off the main thread at display size (`ArtworkView` → `ArtworkPipeline`, memory hit
on the first frame), no per-frame state in rows (playing indicator = system symbol effect), no sorting/formatting
in `body`. Playback position is never observable (`PlaybackStore.positionMs()` on demand).

Transitions (tab switches, pushes, sheets, the player sheet) have their own rules — what was slow on the first
install and what prevents it now: [`docs/performance.md`](performance.md).

## Shell (stage 4)

PixlAudio's layout (Android `MainActivity.MainUI`, default nav style, compact bar), `Shell/RootView.swift`:

- Content: the selected tab's `NavigationStack`, full screen. All three stacks stay alive (scroll state kept).
- Bottom, inset 16 pt from the sides and sitting on the home-indicator safe area: the **mini player** (64 pt
  capsule, 32 pt corners, glass tinted with the album's `primaryContainer`) floating **8 pt** above the **tab bar**.
- Tab bar (owner change 2026-10-01: "just an ios liquid navbar just with the accent color as the gliding glass
  pill"): a floating `.regular` glass capsule, 62 pt (54 pt in compact mode), Home, Search, Library evenly spread —
  19 pt semibold symbol over a 10 pt semibold label (`.primary`), symbols only (21 pt) in compact mode. Behind the
  selected tab, inset 4 pt, a capsule pill of glass tinted with the accent (`primary` at `GlassTint.prominent`); the
  selected symbol is filled and `onPrimary`. The pill glides to a tapped tab (`PixlMotion.selection`); press and drag
  along the bar and it follows the finger (interactive spring), swells 1.12× while held, lights the tab under the
  finger with a selection haptic, and settles on the nearest tab on release. Reduce Motion: no swell, short ease.
  Re-tapping the selected tab pops it to its root. Android's NavBar Style (default / full width) setting is gone;
  compact mode remains. Not the system `TabView` bar: its selection platter can't take the accent colour and the
  player sheet expands from the mini player slot above the bar.
- **2026-10-02 (owner: "the pill doesnt go clear or expand, and it doesnt refract text underneath. use like a demo
  thing online"):** the bar is now built on the system's liquid lens, following the open-source FabBar (MIT,
  github.com/ryanashcraft/FabBar). Outside UITabBar, only UISegmentedControl has that lens, so `LiquidTabBar` puts a
  segmented control in a capsule of interactive `UIGlassEffect` (2 pt padding).
  - **Glyphs:** the segments' labels and background images are hidden. PixlAudio's glyphs (18 pt semibold symbol over
    a 10 pt semibold label; 21 pt symbol alone in compact mode) are drawn inside each segment view, so the lens
    magnifies them.
  - **Pill and lens colour:** `selectedSegmentTintColor` is the accent (`primary` at `GlassTint.prominent`), the
    resting pill. A filled, accent-tinted copy of each glyph is masked to the lens' presentation frame by a display
    link that pauses after three still frames. That copy is `onPrimary` at rest and `primary` while the finger is
    down, when the lens is clear.
  - **Touch:** the lens moves on touch down and the selection changes on touch up; a re-tap pops the tab to its root.
  - **Fragility:** segments and lens are found by class name (`UISegment`, `_UILiquidLensView`). If iOS changes
    that hierarchy, the glyphs aren't injected and the control falls back to its own segment titles.
- **2026-10-03 (owner: "an auto compact version that removes the labels and shrinks the distance between the icons
  and makes it smaller and … a bit shorter as well when the user scrolls"):** scrolling a tab root down 36 pt
  minimizes the bar. The labels cross-fade out (21 pt symbols alone) and the capsule narrows to 58 pt per tab and
  lowers to 48 pt, centred, on a UIKit spring (0.5 s, bounce 0.2). The mini player follows it down. Scrolling 36 pt back
  up, coming within 24 pt of the top, switching tabs, pushing or popping restores it. The minimized bar
  stays fully interactive (lens and all). Reduce Motion: the shape changes without the spring.
  (`MinimizesTabBarOnScroll`, `Router.isTabBarMinimized`, `LiquidLensBarView.setShape`.)
- **Song picker LOCAL / CLOUD (2026-10-03, owner: "the same liquid magnifying mechanism as the main home screen"):**
  `LiquidSegmentedPicker` puts the same lens in a 56 pt glass capsule, with inline glyphs (16 pt symbol beside a 14 pt
  bold label) in `onSurface`, and the accent pill with `onPrimary` glyphs.
- **Sheet tab capsules on the lens (2026-10-03, owner: "the navbar here isn't Liquid Glass sliding implemented"):**
  the song options OPTIONS / INFO, devices CONTROLS / DEVICES and song picker LOCAL / CLOUD capsules are one
  `LiquidTabCapsule` (56 pt, accent pill, `onSurface` glyphs, filled symbol inside the lens, selection haptic).
- **Full player chrome (2026-10-03, owner: "make the 2 buttons at the top like liquid transparent buttons and the …
  shuffle repeat etc buttons … be liquidified"):**
  - The collapse, output, queue, lyrics and AI DJ buttons are clear glass with `onPrimary` at
    `GlassTint.playerChrome` (0.14), down from 70–80 %, which read as solid.
  - The toggle row lost its cream capsule. Each segment is its own interactive clear-glass shape in one
    `GlassEffectContainer`: off is lightly tinted with an 18 pt corner radius; on is filled with its fixed role and becomes a pill.
- The bars float over the tabs as an overlay (no layout space, docs/performance.md); content scrolls under the
  see-through glass, and every tab root and route reserves the bars' room inside its own stack
  (`BottomBarsClearance`: tab bar + mini player + 8 pt on a root, the mini player + 8 pt on a pushed screen, as
  Android pads by `bottomBarHeight + MiniPlayerHeight`), so the last rows scroll up above the bars. Android's bottom
  gradients behind its bar (Home, Search) are gone.
- The bar shows only at a tab's root — every pushed screen hides it (Android `routesWithHiddenNavigationBar`); the
  mini player then sits alone with 32 pt corners.
- The mini player is the collapsed player sheet (stage 8): tap or drag it up to expand (see Stage 8 notes).
- Root screens draw their own PixlAudio headers (system navigation bar hidden); pushed placeholders use the
  system bar for now — stages replacing them with PixlAudio's top bars must keep the back swipe working.

## Screen map (Android → iOS)

| Android screen / sheet | iOS route / presentation | View (file) | Stage |
|---|---|---|---|
| Home | tab `.home` root | `HomeView` (Features/Home/HomeView.swift) | 7b |
| Daily Mix / Your Mix / Recently Played / Stats | `.dailyMix` `.yourMix` `.recentlyPlayed` `.stats` | `DailyMixView` `YourMixView` (Features/Mixes), `RecentlyPlayedView` (Features/Home), `StatsView` (Features/Stats) | 7b |
| Beta info / Changelog / Jobs sheets | `AppSheet.betaInfo/.changelog/.jobs` | `HomeInfoSheet` (Features/Home) | 7b |
| Search | tab `.search` root | `SearchView` (Features/Search) | 7c |
| Library (tabs, action row, songs/albums/artists/playlists/folders/liked) | tab `.library` root | `LibraryView` (Features/Library) | 7a |
| Folder explorer | `.folderExplorer(path:)` | `FolderExplorerView` (Features/Library) | 7a |
| Album / Artist / Genre / Playlist detail | `.albumDetail` `.artistDetail` `.genreDetail` `.playlistDetail` | Features/Detail/*View.swift | 7a |
| Create / edit playlist | `.playlistEditor(playlistId:)` | `PlaylistEditorView` (Features/Playlists) | 7a |
| Settings + categories | `.settings`, `.settingsCategory(_:)` | `SettingsView`, `SettingsCategoryView` (Features/Settings) | 7d |
| Palette style, Experimental, Artist settings, Device capabilities, About, Licences, Easter egg, Quick fill | `.paletteStyle` … `.quickFill` | Features/Settings/*View.swift | 7d |
| Delimiters / word delimiters | `.delimiterConfig`, `.wordDelimiterConfig` | Features/Delimiters | 7d |
| Equalizer | `.equalizer` | `EqualizerView` (Features/Equalizer) | 7d |
| Transitions | `.editTransition(playlistId:)` | `EditTransitionView` (Features/Transitions) | 7d |
| Diagnostics (iOS only) | `.diagnostics` | `DiagnosticsView` (Features/Developer) | done |
| Player sheet (expanded) | `AppCover.nowPlaying` | `NowPlayingView` (Features/NowPlaying) | 8 |
| Queue / Song info / Sleep timer | `AppSheet.queue/.songInfo/.sleepTimer` | `QueueSheet`, `SongInfoSheet`, `SleepTimerSheet` | 8 |
| Karaoke lyrics / lyrics options | `AppCover.lyrics`, `AppSheet.lyricsOptions` | `LyricsView`, `LyricsOptionsSheet` (Features/Lyrics) | 9 |
| Lyrics sync editor | `AppCover.lyricsSync(songId:)` | `LyricsSyncEditorView` (Features/LyricsSync) | 10 |
| YouTube login (+ device-code dialog, cookie paste) | `.youTubeLogin` | `YouTubeLoginView` (Features/YouTube) | 11 |
| Playback test ("Test playback" / "Deep probe", Android: Spotify dashboard cards) | `.playbackDiagnostics` | `PlaybackDiagnosticsView` (Features/YouTube) | 11 |
| Offline download card (song sheet) | inside `SongOptionsSheet` | `OfflineDownloadCard` (Features/YouTube) | 11 |
| Spotify dashboard / browse | `.spotifyDashboard`, `.spotifyBrowse(query:)` | Features/Spotify | 12 |
| Accounts | `.accounts` | `AccountsView` (Features/Accounts) | 12 (Spotify card), 11 (YouTube links) |
| AI playlist sheet (Daily Mix sparkle button) | `AppSheet.aiPlaylist` | `AiPlaylistSheet` (Features/AI) | 13 |
| AI Playlist Lab (Library › Create playlist › With AI) | `AppCover.aiPlaylistLab` | `AiPlaylistLabView` (Features/AI) | 13 |
| TAIS DJ chat (Experimental › TAIS DJ; player's Taizo button) | `AppSheet.taisChat` | `TaisChatSheet` (Features/AI) | 13 |
| Setup | `AppCover.setup` | `SetupView` (Features/Onboarding) | 15 |
| TAIS Studio "Remaster Song" card (Experimental, song sheet), on-device models panel (iOS only) | inside `ExperimentalSettingsView` / `SongOptionsSheet` | `TaisStudioProgressCard`, `OnDeviceModelsPanel` (Features/Tais) | 14 |
| Lyrics screen instrumental card + floating instrumental toggle | inside `LyricsView` | `InstrumentalRenderAction`, `InstrumentalLyricsToggle` (Features/Tais) | 14 |
| Backup export / restore | `AppCover.backupExport`, `.backupImport` | `BackupExportCover`, `BackupImportCover` (Features/Backup) | 15 |
| Plus / license debug, nav-bar corner radius | — (dropped: everything unlocked; Material-only setting) | — | — |

Stage 7d notes: settings rows are glass shapes inside a group clipped to 24 pt (the Compose `clip` on the
group), 2 pt apart (`Features/Settings/Components/SettingsRows.swift`); every settings screen uses
`SettingsScaffold` (Android `CollapsibleCommonTopBar`). Dropped as Material-only or Android-only, each noted in
its view: album-art palette style, nav-bar corner radius, smooth corners, the visual-style switch, the Plus card and
licence debug tools, battery optimisation, Chromecast autoplay, Hi-Fi float output, offload-ready formats and the
ExoPlayer tile. TAIS tools in Experimental are UI shells until the TAIS stages.

Dropped settings (final review, 2026-10-03), because iOS can't honour them:
- Playback › "Keep playing after closing": iOS ends the app — and its playback — when it is swiped away from the app
  switcher, so neither choice could be kept; background audio plays on otherwise. The key stays for backups.
- AI › Music intelligence › "Discover beyond my library": on Android it adds online catalog songs to Home's
  discovery shelves; the iOS Home has no catalog source. The key stays for backups.
- Appearance › App Language shows only when the app has more than one localisation (English only for now).
Kept as on Android although unused there too: the Home collage pattern and auto-rotate rows; the Experimental
full-player loading steps. "Auto-scan .lrc files" stays as it is (sidecar lyrics are always read at play time, as
on Android).

## Seams — who owns what

Shared files (stage 4; change only with a reason, in a small commit, and say so in the stage report):
`Core/Routes.swift` (all routes), `Shell/*` (router, root, destinations), `DesignSystem/*`, `Stores/*`,
`Persistence/SchemaV1.swift`, `AppEnvironment.swift`, `Demo/UITestLaunchRouter.swift`.

Parallel stages **own and replace** only these:

- **Stage 5 (playback):** `App/Playback/**` — a `PlaybackEngine` implementation (dual-deck AVPlayer), audio session,
  Now Playing; one line in `AppEnvironment.init` swaps `DemoPlaybackEngine` for it on non-UI-test launches.
- **Stage 6 (library import):** `App/Library/**` — a `LibraryImporting` implementation writing through
  `PersistenceActor` (add queries in `extension PersistenceActor` files there), `ArtworkPipeline.embeddedArtworkLoader`;
  one line in `AppEnvironment.init` passes the importer to `LibraryStore`.
- **Stage 7a:** `Features/Library/**`, `Features/Detail/**`, `Features/Playlists/**`.
- **Stage 7b:** `Features/Home/**`, `Features/Mixes/**`, `Features/Stats/**` (Home, mixes, recently played, stats, home
  sheets). `HomeStore` (in `AppEnvironment.home`) owns `ListeningHistoryStore` — the `playback_history.json` events
  behind Recently Played, Stats, the greeting and the recommendations. Stage 5's `ListeningStatsTracker` reports each finished
  listening span there through `PlaybackServices.recordHistory`, wired in `AppEnvironment` (Android
  `PlaybackStatsRepository.recordPlayback`); stage 15's backup restore calls `importEvents(_:)`.
- **Stage 7c:** `Features/Search/**` and `LibrarySearchProvider` (on `SearchIndex`; `SearchModel` re-indexes it on
  every library snapshot).
- **Stage 7d:** `Features/Settings/**`, `Features/Delimiters/**`, `Features/Equalizer/**`, `Features/Transitions/**`;
  extends the category objects in `Stores/SettingsStore.swift` (append keys to `PreferenceKeys`).
- **Stage 8:** `Features/NowPlaying/**`, `Features/Queue/**`, `Features/SongInfo/**`.
- **Stage 9:** `Features/Lyrics/**`, drives `LyricsStore`. **Stage 10:** `Features/LyricsSync/**`.
- **Stages 11 / 12 / 15:** `Features/YouTube/**`, `Features/Spotify/**`, `Features/Accounts/**` +
  `Features/Onboarding/**`; they update `AccountsStore`.
- **Stage 13 (AI):** `Services/AI/**`, `Features/AI/**`; `env.ai` (`AIService`, built on first use) holds the
  orchestrator, the AI playlist state (`AIPlaylistController`) and the DJ chat (`TaisChatModel`). Lyric translation is
  the `LyricsTranslating` seam (`Core/LyricsTranslating.swift`, `env.ai.lyricsTranslator`) for stage 9's lyrics
  options. The DJ's catalogue fallback uses the Search seam's Spotify / YouTube Music providers (stages 11/12).

Rules for stages: keep each placeholder view's **type name and initialiser** (the router calls them); build from
the design-system components (extend them rather than forking); put new tokens next to their screen; add a
`-screen` id per new screen state only through `DemoScreen` (one line each); every Apple API used for the first time
goes into `docs/api-notes.md`.

## Screenshot ids (UI tests)

`-uiTest -screen <id> -appearance light|dark [-song n] [-paused] [-noSong]`. Every `AppRoute`, `AppSheet` and
`AppCover` has an id (`DemoScreen`, App/Demo/UITestLaunchRouter.swift; e.g. `albumDetail`,
`settingsCategory.appearance`, `queue`, `nowPlaying`), plus `home`, `search`, `searchResults`, `library`,
`miniPlayer` (library with a vivid song: album-tinted mini player) and `miniPlayerAlone` (pushed screen: bar
hidden). The ready element of each is `screen.<id>`. Stage 4 shots: home, library, miniPlayer, miniPlayerAlone in
light + dark; search, settings, nowPlaying, diagnostics.

`-accent RRGGBB` (UI tests only) starts any screen with that accent colour (Settings › Appearance › Accent Color);
shots taken with it carry a suffix (`settingsCategory.appearance-dark-accentRed`, `home-dark-accentGreen`). Accent
swatches are `settings.accent.<preset id>` / `settings.accent.custom`, the row `settings.accentColor`.

Stage 7a ids (Library tab on screen, ready `screen.library` plus the page/sheet id): `libraryPlaylists`,
`libraryAlbums` (grid), `libraryAlbumsList`, `libraryArtists`, `libraryFolders`, `libraryLiked`, `librarySelection`
(three songs selected), `librarySort`, `libraryReorderTabs`, `libraryMultiSelection`, `libraryCreatePlaylist`,
`libraryAddToPlaylist`; `songOptionsInfo` (the ⋮ sheet on its Info page); `playlistEdit` (editor on the first demo
playlist, Icon tab with a star), `playlistAddSongs`, `playlistOptions`, `playlistReorder` (reorder + remove modes),
`genreSort`. Shots: `UITests/LibraryScreenshotTests` (CI runs every `PixlAudioUITests` class).

## Stage 7a notes (Library, details, playlists)

- Library state lives in the screen: `LibraryModel` (sorted lists, recomputed off the main thread for large
  libraries), `LibraryPreferences` (Android keys: `library_tabs_order`, `*_sort_option`, `last_storage_filter`,
  `is_folders_playlist_view`, `playlist_song_order_modes`), `OrderedSelection` (multi-selection in selection order).
- Edits go through `LibraryEditor` (`env.libraryEditor`): the snapshot updates at once, then `PersistenceActor`
  writes and the launch cache is refreshed.
- Every song ⋮ opens `AppSheet.songInfo`, whose body is the ported `SongOptionsSheet` (Android `SongInfoBottomSheet`);
  other stages can present it the same way.
- Queue insertions (`playNext`, `addToQueue`) re-set the queue through the `PlaybackEngine` seam at the current
  position until stage 5 adds native inserts.

Stage 7c adds `-searchFilter all|songs|albums|artists|playlists`
(with `-screen search -searchQuery <q>`) and the shots searchEmpty, searchTyping, searchAll, searchSongs, searchAlbums,
searchArtists, searchPlaylists, searchNoResults (light + dark; `UITests/SearchScreenshotTests.swift`).

## Integration notes (run 3: stages 5, 6, 7a–7d merged)

How the stages meet now that they share one `main`:

- **Queue inserts:** `PlaybackStore.playNext` / `addToQueue` call the engine's native inserts (stage 5) and start
  playback when nothing is loaded; stage 7a's re-set-the-queue fallbacks were removed. `DemoPlaybackEngine` implements
  the inserts too, so UI tests see the queue change.
- **Listening history:** one owner of `playback_history.json` — Home's `ListeningHistoryStore`. The engine's sessions
  reach it through `PlaybackServices.recordHistory` (its own `PlaybackHistoryStore` is only the fallback when nothing is
  wired). The store reads the file before its first write, so a session recorded at launch never truncates history.
- **Equalizer and transitions:** `PlaybackServices.applySettings` uses stage 7d's `EqualizerPreferences.engineSettings`
  (saved custom presets, loudness) and the observed `globalTransitionSettingsJSON`; saving a playlist rule calls
  `PlaybackServices.reloadTransitionRules()`.
- **Music folders:** Settings › Music Management adds and removes folders through `LocalLibraryImporter` (unique
  display names, security scope kept open). Library paths are `/<root display name>/<relative path>` with the
  Documents root named `PixlAudio` (`FolderRoot.documentsDisplayName`), so `blocked_directories` entries written by
  the folder screen match the scanner's paths.
- **Pill row accessory:** `GlassPillRow(accessory:)` is the one trailing action capsule (Library's Edit tab, the
  equalizer's Edit presets).
- **CI:** the shots job runs every `PixlAudioUITests` class (111 screenshots, ~42 min; timeout 90 min).
  `ci/export-shots.sh` keeps `.png` on ids containing a dot and strips Xcode's `_<n>_<UUID>` suffix wherever it
  lands (`settingsCategory.about-dark.png`).

### Visual review (run 3, `int-stage07` shots vs `docs/design-refs`)
Same layout, order and geometry as PixlAudio on Home, Library (all tabs), details, Search, Settings and its
categories, sheets; glass in place of Material; text legible in light and dark. Known differences, not bugs:
- **Type weight:** the Android screenshots render Google Sans Flex (rounded) much heavier than SF Pro at the same
  Type.kt weights, so iOS titles, tab labels and card text read lighter. Matching them would mean an optical weight
  bump in `Typography.swift` — an owner decision (decision 3 says "SF Pro at PixlAudio's sizes and weights").
- **Surface strength:** Material's solid containers (the orange "Comfort zone" mix card, the Play tile, the stats
  card) are tinted glass, so they read paler and see-through; list content shows through the mini player and the
  bottom bar while scrolling.
- **Demo data:** the screenshots use the generated demo library (placeholder art, a lavender seed), not real covers.
- **Now Playing** is still the stage-4 placeholder (stage 8).

## Stage 8 notes (player sheet, full player, queue, timer, song editor, devices)

- **One card, mini ↔ full** (Android `UnifiedPlayerSheetV2`): the shell keeps a `MiniPlayerSlot` where the mini player
  sits and draws `PlayerSheetHost` as a sibling above everything. The card interpolates from the slot (16 pt insets,
  64 pt, 32 / 10 pt corners) to the screen (no corners) with the expansion fraction in `PlayerSheetController`
  (`env.playerSheet`). `PlayerSheetMorph` is `Animatable`, so the springs (Android's expressive spatial spec to expand;
  stiffness 200 with fraction-dependent damping to collapse, plus the 0.97 squash) drive every derived value; the layers
  read the fraction from `\.playerSheetMetrics` in tiny fade modifiers, so neither a drag nor a spring re-renders the
  full player. Collapsed, the card is the album-tinted glass mini player; the glass fades out over the first 25 % and
  `primaryContainer` fades in (Android's glass mode).
- **Gestures:** drag the mini player up / the full player down (axis-locked, follows the finger, Android's 5 pt / 55 pt/s
  release rules), tap the mini player, the collapse circle, VoiceOver escape, or swipe in from the leading edge
  (predictive back). An upward flick on the expanded player opens the queue.
- **`AppCover.nowPlaying` is a request** the sheet consumes (the shell's cover binding skips it): every existing
  `router.present(AppCover.nowPlaying)` still opens the player. Lyrics (`AppCover.lyrics`) and the sync editor open
  above the expanded player and return to it.
- **Full player** (`NowPlayingView`, Android `FullPlayerContent`): top bar, carousel (`carousel_style` peek styles),
  title/artist (+ artist picker for several credits), lyrics and AI DJ circles, `PlayerSeekBar` (≤ 4 Hz from
  `PlaybackStore.clock`), `AnimatedPlaybackControls` (weighted glass pills), `PlayerToggleRow`, the
  `player_ambient_style` background. Controls are clear glass tinted with the album roles (`playerGlass`).
- **Sheets:** `AppSheet.queue` (large; see-through `tallGlass` since 2026-10-07), `.sleepTimer`, `.devices`, `.artistPicker(songId:)`, `.taisChat` (stage 13's
  TAIS DJ chat, from the sparkles circle); `AppCover.editSong(songId:)`. The queue presents the song sheet, the timer and Save as
  playlist itself. The song sheet's edit button (`SongOptionsSheet(onEdit:)`) opens `EditSongSheet`.
- **Shared-file changes (all additive):** `Shell/RootView.swift` (slot + host, cover binding), `Core/Routes.swift`
  and `Shell/RouteDestinations.swift` (new cases, queue/timer detents), `AppEnvironment.swift` (`playerSheet`,
  `sleepTimer`), `DesignSystem/Components/MiniPlayerBar.swift` (`drawsGlass`), `Demo/*` (screen ids, demo engine queue
  edits, one featured credit on "Slow Burn"), `Features/Library/SongOptionsSheet.swift` (`onEdit`),
  `Library/TagOverrides.swift` (`artworkUri`), `Library/TagWriteBack.swift` + `LocalLibraryImporter.editTags`
  (`TagWriteExtras`: composer, lyrics, ReplayGain, cover).

Stage 8 screenshot ids (`UITests/PlayerScreenshotTests`): `miniPlayer` (collapsed), `nowPlaying` (expanded; `-paused`
for pp_full), `queue`, `sleepTimer`, `songInfo`, `editSong`, `artistPicker` (song 16, two credits), `devices` —
the player's sheets open over the expanded player. Gesture tests: drag up from the mini player, collapse circle.

## Stage 9 notes (karaoke lyrics, lyrics services)

Port of Android `presentation/lyrics/**` + `components/LyricsSheet.kt` (`AppCover.lyrics` → `LyricsView`). Files:
`Features/Lyrics/` (screen, chrome, karaoke view, renderer, driver, background, More sheet, fetch dialog, demo content)
and `Services/Lyrics*.swift` + `Services/CJKRomanization.swift`.

- **Engine and driver:** PixlLyrics' ported `LyricsEngine` is stepped by `LyricsDriver`'s `CADisplayLink` (60–120 Hz)
  with `t = player position + sync offset`; only changed per-row values are written into `LyricRowState`s (y, scale,
  σ, alpha, activeness, hot, expand, culled). Hot rows (normally one or two) also read `LyricsHotClock.nowMs`, so a
  tick re-renders just those. The link pauses while playback is paused and the engine is at rest (a 150 ms poll
  notices outside seeks meanwhile). Signpost interval `LyricsEngine.step` (target < 0.5 ms).
- **Rows:** one `ZStack` of every row placed by `.offset(y:)` from the engine (no scroll view), `.scaleEffect` about
  the engine's pivot, `.blur(radius: σ)`, opacity = depth × presence (0 when culled). Heights come from
  `onGeometryChange` once per song / width. Word fill: each syllable (or emphasis grapheme) is a `Text` run tagged
  with `KaraokePieceAttribute`; `KaraokeTextRenderer` draws sung / unsung runs at their alphas, the active one through
  a destination-in ramp half a line height wide, with lift × activeness and the emphasis scale/spread/hop/glow.
  The whole layer is one compositing group blended `.plusLighter` (normal over bright art / increased contrast) and
  masked by the 10 %/12 % edge fade (top below the header + 48 pt, bottom above the controls + 96 pt).
  Only start-aligned lines give the renderer horizontal `displayPadding`: with it, trailing (duet) text drew ~20 pt
  towards the end and ran off the screen.
- **Background:** `ArtworkSpriteBaker` (actor, LRU 4) bakes the four blurred sprites from the 96 px art into one 2×2
  atlas; `LyricsScene.metal` (twist, composite, grade, overlays, dither) fills the screen from a
  `TimelineView(.animation(minimumInterval: 1/30, paused:))`; 1.7 s crossfade; paused when hidden, in Low Power Mode
  or with a frozen UI-test clock. CI downloads the Metal toolchain when a runner lacks it (`ci/select-xcode.sh`).
- **Chrome:** Android's Material-mode cluster, each Material element as glass over the scrim: track pill (clear glass
  tinted `onPrimaryFixedVariant`, spinning 54 pt art, playing bars), play/pause (78 pt, squircle ↔ circle,
  `tertiaryFixedDim` tinted glass), seek-bar pill (50 pt, wavy track), back · Synced · Static · more (40 pt circles,
  50 pt segments: capsule when active, 8 pt corners when not), sync-offset capsule (fills inside, no glass on glass),
  immersive "show controls" disc, sync chip. Over bright art the clear glass takes a 35 % black tint.
- **Always dark, palette included:** the lyrics screen and the sync editor apply `alwaysDarkTheme(_:)` (Theme.swift),
  which forces `.dark` *and* re-resolves `appTheme` / `playerTheme` for dark. `preferredColorScheme(.dark)` alone left
  the palette the shell resolved for the system scheme, so with the phone in light mode the More sheet (and the fetch
  dialog) drew light-scheme roles — near-black `onSurface` rows, cream fills — on the dark system sheet (fixed
  2026-10-03; shots `lyricsMoreSheet.lightApp`, `lyricsMoreSheet.lightAppBottom`, `lyricsFetchDialog.lightApp`). The
  shuffle / repeat / favourite row at the sheet's end is the sheet's own (Android `BottomToggleRow`), not the screen's.
- **Sheets:** the More sheet is a system sheet with PixlAudio's groups as fills (inside glass); the fetch dialog is a
  centred glass card (32 pt) over a dim backdrop. Save Lyrics exports `.lrc` with `fileExporter`; import goes through
  `LyricsImportSecurity`.
- **Services:** `LyricsService` (actor): memory → stored row (`LyricsRecord.docJSON` holds Android's raw lyrics
  content) → JSON cache (`Application Support/lyrics/<id>.json`, Android `LyricsData`) → the song's scanned text, then
  the sources in the user's order (embedded tags incl. SYLT, AMLL + NetEase + LRCLIB in parallel, sidecar `.lrc`).
  `LyricsController` (main actor, `env.lyricsController`) drives `LyricsStore`, builds `PreparedLyrics` off the main
  thread, keeps per-song offsets (`lyrics_sync_offsets_json`) and runs the fetch dialog. UI tests never touch the
  network: the current song gets `LyricsDemoContent`.

Screenshot ids (`UITests/LyricsScreenshotTests`, `-screen lyrics` + `-lyricsDemo words|duet|lines|plain|none`,
`-lyricsFreezeMs <ms>`, `-lyricsBrightArt`, `-lyricsHighContrast`, `-lyricsImmersive`): lyricsWordFill (42 300),
lyricsEmphasis (47 600), lyricsInterlude (61 000), lyricsDuet, lyricsBrightArt, lyricsHighContrast, lyricsLineSynced,
lyricsPlain, lyricsNone, lyricsImmersive, lyricsLight, lyricsMoreSheet, lyricsFetchDialog, lyricsOptions,
lyricsCascade.f0…f7 (first-show cascade frames, live clock).

## Stage 10 notes (lyrics sync editor)

Port of Android `presentation/lyrics/sync/**` + `LyricsSyncEditorStateHolder` (`AppCover.lyricsSync` →
`LyricsSyncEditorView`), on PixlLyrics' `LyricsTapSync` / `LyricsExport` / `LyricsSyncDraftStore`.

- **Session** (`LyricsSyncSession`, created by the cover, closed on dismiss): phases Loading → Resume / Words / Intro /
  Manage → Tap (and Fix a line) → Preview, Android's dialogs as system alerts, notices as a glass pill. While open it
  pauses, suspends crossfades (`DualDeckEngine.suspendTransitions(owner: "lyrics_sync")`) and opens an exact-timing
  session (`beginExactTimingSession`: no hand-over; at the end of the song the engine pauses on it → "The song ended
  before the last N words"); `close()` restores the rate and both. Drafts autosave 1 s after a change to
  `Application Support/lyrics_sync_drafts` (Android's files), are flushed on close / background / song change and
  deleted after Save. Save stores `LyricsDocCodec.encode(doc)` with source `"user"` through `LyricsService.save`
  (user-synced lyrics win over every fetcher), learns the reaction offset from the nudge, and returns to the lyrics
  screen with Android's toast. Reaction offsets: Settings › Lyrics (100 ms speaker / 180 ms Bluetooth, chosen by the
  route at open).
- **Tap pad:** a UIKit touch surface under the SwiftUI pad stamps on touch *down* with `UITouch.timestamp` (latency
  removed from the player position); a hold ≥ 350 ms marks the word's end; extra fingers are taps; scale 0.97 + glow +
  `sensoryFeedback(.impact(weight: .light))` (the haptics setting). Speeds 1 / 0.75 / 0.5 use the engine's
  pitch-preserving rate.
- **Word marks** (Android's latest): the word being sung has a white 1.5 pt box with a spring pop (1.06 → 1, damping
  0.6 / stiffness 900); tapped words fill with the accent from the first to the last letter in 260 ms (right to left
  for RTL words, `TextScripts.isRtlWord`); the next word white; later words 40 %. Music breaks (> 5 s to the next
  anchor) swap the context for a countdown ring that reads the position per frame only while shown.
- **Glass:** Android's Liquid Glass palette as clear glass over the artwork — chips / ✕ / secondary buttons white 12 %,
  the pad white 16 % (36 pt corners), the preview panel black 32 % (32 pt corners), the accent (album `primary` when
  luminous enough, else `inversePrimary`) at `GlassTint.prominent` for Start / Save / the selected speed / the intro
  icons; 35 % black over bright art. Buttons inside the panel are fills. Preview uses the real `KaraokeLyricsView` with
  its own `LyricsDriver` on the editor's clock and the lyrics screen's appearance preferences.
- **Entry points:** the lyrics More sheet's first row, the empty-state button and the sync chip
  (`LyricsSyncEditorView.open(…, fromLyrics: true)` — the editor returns to the lyrics screen); Edit song's "Change the
  words" (`.words`) and "Fix timing" (`.fixTiming`), which start the song paused if another one is playing.
- **Shared-file changes (additive):** `Playback/DualDeckEngine.swift` (exact-timing session), `Stores/PlaybackStore.swift`
  (explicit `resume()` / `pause()`), `Services/LyricsController.swift` (`lyricsService`, shared with stage 14), `Features/Lyrics/LyricsView.swift`
  and `Features/SongInfo/EditSongSheet.swift` (open through `LyricsSyncEditorView.open`).

Screenshot ids (`UITests/LyricsSyncScreenshotTests`, `-screen lyricsSync -syncStep <step>`; ready `screen.lyricsSync`):
syncIntro, syncWords, syncResume, syncManage, syncTap, syncTapReady, syncTapBreak, syncTapNotice, syncTapEnded,
syncFixLine, syncPreview, syncPreviewFixLine, syncTapLight, syncSpeedMenu, syncLiveIntro / syncLiveTapped (a live run
on the demo engine).

## Stage 11 notes (YouTube playback)

- **Services** live in `App/Services/YouTube/` and are built once as `AppEnvironment.youtube` (`YouTubeServices`; a demo
  variant without any network object in UI tests). `InnerTubeService` resolves a video id: the remote client table
  (`remote/config.json`, fetched ≤ every 6 h, parsed by PixlNet's `RemoteClientConfig` which keeps the no-cookie and host
  invariants) drives PixlNet's `ChainedYouTubeStreamResolver` — VISIONOS first with a fresh visitorData and no cookie, the
  other pre-signed clients, the deciphered ones (JavaScriptCore, base.js cached per player version) — then Piped. AAC only.
- **Streaming:** songs whose item URL is `pixlstream://<videoId>` (YouTube Music `yt:` songs; stage 12 can point matched
  Spotify songs there too) are served by `YouTubeResourceLoader`, registered with `StreamingResourceLoaderRegistry`. It answers
  from `StreamCache` (sparse file + `ByteRangeSet`, `Library/Caches/YouTube/streams`, 1 GB LRU) and fetches gaps with
  `StreamFetcher` (ranged GETs, the client's User-Agent only, 403 → re-resolve; since 2026-10-07 a 128 KiB first GET and
  growing fetches, Android's retry rules — see "Streaming speed" below). The resolver (`StreamingPlayableURLResolver`,
  wrapping the engine's default) plays downloaded files first, then fully cached files. `YouTubePrefetcher` (fed by
  `PlaybackServices.onUpcomingChanged` / `onPlayStateChanged`) prepares the next streamed songs while music plays and
  caches the next one's first MiB 30 s before the end.
- **PoToken:** `PoTokenGenerator` runs `po_token.html` (copied from the Android assets) in a 1×1 `WKWebView` with
  `callAsyncJavaScript`; PixlNet asks for a token only for the signed-in WEB_REMIX fallback (VISIONOS needs none).
- **Sign-in:** the web page (Android's flow) with two glass-capsule fallbacks under it — the device-code flow (Android's
  `YouTubeSignInDialog`, as a sheet; the token authenticates TVHTML5 through `GoogleBearerHTTPClient`) and a pasted cookie.
  Signed in, the screen shows Android's `YouTubeAccountCard` (from the Spotify dashboard) + "Test playback". Until the
  Accounts screen (stage 15) exists, Settings › Developer Options has rows for both screens.
- **Downloads:** `DownloadManager` (background `URLSession`; foreground ranged fallback; complete cache files are copied),
  files in `Application Support/Downloads/<videoId>.m4a`. UI: `OfflineDownloadCard` in the song sheet, the playlist sheet's
  "Download all songs". Song rows (`SongCard`) show Android's `SongAvailabilityBadge` (downloaded / downloading / failed)
  from `DownloadBadges`, injected at the root — kind only, so progress ticks never re-render the lists.
- **Screenshot ids:** `youTubeLogin`, `youTubeLoginCode`, `youTubeLoginCookie`, `youTubeLoginSignedIn`, `playbackDiagnostics`
  (all steps green), `playbackDiagnosticsFailed` (audio step red), `playbackDiagnosticsTimings` (the Stream start
  timings card, 2026-10-07) — `UITests/YouTubeScreenshotTests`, light + dark.

## Stage 12 notes (Spotify)

- **Screens:** `AccountsView` (Android `AccountsScreen`, on `SettingsScaffold`), `SpotifyDashboardView` and
  `SpotifyBrowseView` (Android `SpotifyDashboardScreen` / `SpotifyBrowseScreen`, on `SpotifyScaffold` — the plain
  64 pt `TopAppBar` with the glass back circle, glass filling in once content scrolls under it). Cards are glass in
  Android's radii (30/28/24/20/16) tinted with their `surfaceContainer*` role (`GlassTint.surface`) or
  `errorContainer`/`secondaryContainer` (`GlassTint.container`); tiles, chips and buttons sitting on a card are fills
  (`SpotifyFilledButton`, `SpotifyOutlinedButton`); standalone buttons (Browse, Add whole album) are green glass
  capsules. Spotify green `0xFF1DB954` and YouTube red stay as on Android.
- **Seams:** `SpotifyService` (in `AppEnvironment.spotify`) owns the state and updates `AccountsStore.spotify`.
  YouTube goes through `SpotifyYouTubeBridge` (search for the matcher, the URL for a matched video, a stream
  resolution for "Test playback"); `PixlNetYouTubeBridge` works alone (anonymous InnerTube, pre-signed client chain);
  since the wave-A merge the app passes stage 11's `InnerTubeSpotifyBridge` instead. `SpotifyPlayableURLResolver` wraps the engine's resolver (keep it outermost): a
  `spotify://<id>` song plays its matched video as a `yt:<videoId>` song (`pixlstream://<videoId>`) through the inner
  resolver, else a direct pre-signed URL. Search's Spotify section is `SpotifyCatalogSearchProvider`.
- **Data:** the Spotify tables are `SpotifySongRecord` / `SpotifyPlaylistRecord` (SchemaV1, unchanged);
  `PersistenceActor` implements PixlNet's `SpotifyLibraryStore` and writes the unified rows (`sp:<id>` songs, albums /
  artists in Android's negative id bands, `spotify_playlist:<id>` playlists with source `SPOTIFY`) after every sync
  flush; local rescans never touch them.
- **Background:** `.backgroundTask(.appRefresh("io.github.redsn0w1877.pixlaudio.spotify-sync"))` in `PixlAudioApp`:
  a resumable sync slice when the last complete sync is > 12 h old, then a matching slice (~22 s in all).

Stage 12 screenshot ids (signed out on the plain ids; demo data, no network): `accounts`, `accounts.signedIn`,
`spotifyDashboard`, `spotifyDashboard.signedIn`, `spotifyDashboard.tested` (with a playback test report),
`spotifyBrowse` (home: top artists and songs), `spotifyBrowse.results` (query "Luma"), `spotifyBrowse.artist`,
`spotifyBrowse.album`. Shots: `UITests/SpotifyScreenshotTests`.

## Stage 13 notes (AI)

- Providers: Gemini and every OpenAI-compatible provider through PixlNet's `AiOrchestrator` (provider chain,
  cooldowns, 30-minute cache in `AICacheRecord`, model recovery, usage in `AIUsageRecord`); settings come from the
  Android keys in UserDefaults and the Keychain (`AISettingsBridge`). Ollama / custom base URLs may be plain HTTP on the
  LAN. The on-device provider is the system language model (`OnDeviceAiClient`), availability-gated, with guided
  generation for playlist ids.
- AI playlist sheet: Android's layout; the badge, size card, prompt field, error / success cards and the morphing
  generate button are tinted glass; the min / max fields inside the size card are fills. A generated mix replaces
  today's Daily Mix (`HomeStore.setDailyMix`), starts playing and opens the player once the sheet has gone.
- AI Playlist Lab: Android's full-screen dialog as a cover; cards are glass, chips / segments / fields inside them are
  fills; Generate saves an AI playlist (`LibraryEditor.createPlaylist(isAiGenerated:)`) and closes.
- TAIS DJ chat: bubbles in Android's shapes as glass (user = `primary`, Taizo = `surfaceContainerHigh`, errors =
  `errorContainer`), suggestion chips as glass capsules, the bulk buttons and song rows inside a bubble as fills. Taizo's
  avatar keeps Android's `primary → tertiary` gradient (a mark, not a Material surface). Online (catalogue) results
  import through `SearchProviding.importAndPlay` on tap. The sheet uses the large detent: Android caps the column at 620 dp, but the system's
  partial-height sheet floats with clearer glass, and the Home content behind made the chat hard to read.
  (2026-10-07: Hoa asked for the see-through glass after all; it now uses `tallGlass`, see Glass expansion.)
- **Taizo redesign (owner request 2026-10-03, "make taizo up much better and more beautiful"; the port rule is relaxed
  for this sheet only).** Empty: `TaizoOrb` — a 3×3 `MeshGradient` of the theme's fixed roles (same in light and dark)
  with a specular highlight, rim and glow, drifting at ≤ 24 fps (paused off screen / sheet gone / background / Reduce
  Motion / UI tests) — over a time-of-day greeting, a one-line subtitle and the suggestion chips: glass capsules with a
  faint mood tint and a mood-coloured symbol disc, centred in `AIFlowLayout`, led by the listener's top artist and genre
  from Home's stats overview when known. Conversation: the orb flies into the header (`matchedGeometryEffect`; one
  identity) and stirs while a prompt is in flight ("Thinking…"); bubbles grow in from their corner; a media answer is
  `TaizoQueueCard` (cover mosaic on a fanned stack, mix name from the prompt, count · duration, Play / Add to Queue fills,
  the songs, "Show all" past five). The composer is one glass capsule in a bottom `safeAreaBar` with the send button
  inside it as a fill (accent with text, dimmed and disabled when empty) — a glass button inside the glass capsule would
  be glass on glass. Shots: `taisChat`, `taisChat-typing`, `taisChat-conversation`, `taisChat-queueCard`.
- UI tests use the scripted provider (`DemoAiClient`): playlist prompts get every other candidate id, Taizo gets a
  fixed intro and answer, a prompt containing `#demo-error` fails like a rejected key.

Stage 13 ids: `aiPlaylist` (sheet over Home), `taisChat` (empty), `taisChatConversation` (a scripted genre request
and question; ready `screen.taisChat`), `aiPlaylistLab` (cover). Shots: `UITests/AIScreenshotTests`.

### On-device AI by default (2026-10-07, local AI phase 1; owner decisions, a departure from Android)

- **Default and fallback.** The on-device model (Foundation Models) is the default assistant for every AI feature.
  Cloud providers are optional and off by default; an on-device selection never falls back to a cloud provider
  (`AISettingsBridge.providerChain` → the orchestrator's new `providerChain`). Key-less Gemini users move to on-device
  once at launch (`ai_provider_migrated_v1`) and again after a restore.
- **Settings › AI features:** an "Assistant" group with the on-device model row (in use / not on this iPhone / turned
  off / downloading / language; a checkmark when it is the assistant; always "ready" in UI tests), then "Cloud
  assistants (optional)": a "Use a cloud assistant" switch (off by default) that reveals the cloud provider picker
  (Android's order, no "(Free)" label), Save on usage, sign-in, model and base URL. Advanced shows only Temperature
  on-device (the on-device paths size their own prompts and answers); the whole Android block for a cloud assistant.
  Rows stay settings glass rows; nothing new is glass on glass.
- **On-device paths** (`App/Services/AI`): `OnDeviceAI` (the sessions, serialised per feature, prewarmed when the AI
  sheets open), `OnDevicePlaylistCurator` + `OnDeviceCuration` (numbered pool without ids, dynamic schema, budget
  ladder; Lab requests over 40 songs are planned, filled from the library, the first 40 ordered), Taizo's chat with
  memory and the `searchLibrary` tool (`LibraryLookup`), `OnDeviceLyricsTranslator` (behind `AILyricsTranslator`; the
  lyrics UI is unchanged), Home's AI greeting (`HomeAIGreeter`). Pure parts live in files without Foundation Models
  (`OnDevicePrompts`, `OnDeviceCuration`, `OnDeviceLyricsTranslation`) so AppTests cover them; `OnDeviceModel`
  maps every error (iOS 27's types through `Compat27`). None of it runs in UI tests (CI simulators have no model).
- **Taizo:** an on-device media answer shows its queue card at once; the intro line fills in when the model has
  written it (`TaisChatModel.setIntro`). UI tests keep the synchronous scripted intro.
- **Home greeting card:** Android's AI headline (once a day, cached in `home_greeting_text` / `home_greeting_date`)
  replaces the local one with the existing crossfade; expanding the card asks for the AI insight, with a small
  spinner while it is written (the chevron is disabled meanwhile, as on Android) and the local insight as fallback.
- **Library › Create playlist › With AI:** while the selected on-device model can't answer, the card says why
  ("Needs on-device AI · Turned off in system settings.", `cpu` symbol) and the button reads "Open AI settings".

Ids: `settingsCategory.ai.cloud` (AI features with the cloud assistant switched on; ready
`screen.settingsCategory.ai`), `libraryCreatePlaylist.onDeviceOff` (the creation sheet with the on-device model
turned off; ready `sheet.createPlaylist`). Shots: `SettingsScreenshotTests.testAICategoryCloudLight/Dark`,
`testAICategoryAdvancedOnDeviceLight`, `LibraryScreenshotTests.testLibraryCreatePlaylistOnDeviceOffDark`; the existing
`settingsCategory.ai` shots now show the on-device default.

## Stage 15 notes (backup, setup, updates, localisation)

- **Backup** (`App/Services/Backup`, `Features/Backup`): `env.backup` (`BackupService`) exports, inspects and restores on
  PixlBackup. Settings › Backup & Restore opens one root cover per flow (`AppCover.backupExport` / `.backupImport`,
  so the flows never hang off Settings' lazy list): export = `BackupSectionPicker` → progress →
  `fileExporter`; restore = `BackupImportPicker` → `BackupRestorePlanView` (Android `BackupModuleSelectionDialog`) →
  progress (`BackupTransferProgressView`, Android's dialog as a glass card over a scrim) → `BackupImportReportView`.
  The report is iOS's addition: per module what was restored and how many entries matched no song — Android backups
  describe songs only inside playlists, so favourites / plays / history / lyrics / rules of other songs can't be
  matched, and the report says so. Settings go to `UserDefaults` under the Android keys (typed by Android's declared
  key types on export), API keys to the Keychain; `SettingsStore.reload(from:)` refreshes the observable stores.
- **Setup** (`Features/Onboarding`): Android `SetupScreen` page by page — `SetupPermissionPage` (Android
  `PermissionPageLayout`), `SetupIconCollage` (glass tiles in one container; the star tile is a circle),
  `SetupBottomBar` (glass bar, 80 pt next button turning and changing shape per page), `WelcomeArt` (the Android vector
  drawable's paths filled with palette roles). Order: welcome, music library, music folders, backup, theme, library
  layout, Spotify, finish. `AppEnvironment.start()` presents it while `initial_setup_done` is false.
- **Updates**: `env.updates` (`UpdateNotifier`) checks GitHub at most every 12 h; `RootView` shows the banner.
- **Localisation — English only for now (owner decision 12):** `App/Resources/Localizable.xcstrings` holds only the
  English source strings (the 11 Android locales stage 15 converted were stripped when it merged; `project.yml`
  declares no other regions). `tools/localization/android_strings_to_xcstrings.py <android res>` regenerates the
  English catalog; adding `--with-translations` brings Android's 11 locales back in one step when languages return.
  New strings: English only, `String(localized: "<android key>", defaultValue: "<English>")` (Android's key when
  Android has the string).
- Screenshot ids: `setup`, `setupPermission`, `setupFolders`, `setupBackup`, `setupTheme`, `setupLibraryLayout`,
  `setupSpotify`, `setupFinish` (ready `screen.setup`); `backupRestorePlan` (ready `screen.backupRestorePlan`) and
  `backupImportReport` (ready `screen.backupReport`), both on the `backupImport` cover. Class:
  `UITests/BackupOnboardingScreenshotTests`.

## Stage 14 notes (on-device ML: lyric sync, instrumentals)

- **Models** (`App/Services/ML/`): `.github/workflows/ml-convert.yml` (manual, macOS runner, build-time Python only)
  converts facebook/wav2vec2-base-960h from PyTorch to a Core ML ML Program — fp16 weights with fp32 reductions
  ("mixed"), fixed 10 s input — and gates it against PyTorch (frame agreement ≥ 97 %, identical greedy transcript, CTC
  word starts within one frame); it also converts UVR-MDX-NET-Voc_FT (ONNX → onnx2torch → Core ML fp16) gated against
  ONNX Runtime (instrumental SNR ≥ 30 dB). Both passed and are assets of the prerelease `models-v1` (tars of the
  `.mlpackage`s + `models-v1.json` + reports). `ModelCatalog` pins each tar's size and SHA-256 — re-running the
  workflow never replaces an asset unless `replace` is ticked, and then the catalog must change too.
  `ModelManager` downloads on demand (background `URLSession`, whole-percent progress), verifies, extracts with
  PixlFoundation's `UstarExtractor`, `MLModel.compileModel`s, and stores `Application Support/Models/<id>/` (excluded
  from backups). Both models run `.cpuOnly` (what the gate measured; works in the background).
- **TAIS Studio** (`TaisStudio`, `env.tais.studio`): one serial job lane, like Android's shared engine lane — lyric
  sync (`TaisStudioWorker`: catalogs first, user sync kept unless "Replace", then `Wav2Vec2Aligner` →
  `TaisLyricsAlignment.assemble` → a `LyricsDoc` with source `tais` saved through `LyricsService`), the on-device
  instrumental (`StemSeparatorWorker` → `MdxStemSeparator`), the BS-RoFormer render (`BsRoformerRenderWorker` → PixlNet's
  Gradio / direct-POST clients; also the instrumental job's fallback when the model can't be had). Streamed songs are
  downloaded first (`DownloadManager`). A run is a `BGContinuedProcessingTask` (iOS 26): it keeps going in the
  background with the system's progress Live Activity, which can cancel it; every row can cancel too.
- **Instrumental switch** (`InstrumentalController`, `env.tais.instrumental`; `DualDeckEngine+Instrumental.swift`): the
  render is loaded on the idle deck 0.5 s ahead of the playhead, prerolled, started on the host clock at that exact
  media time (`Deck.start(rate:at:atHostTime:)`), both taps run a 700 ms linear crossfade, the decks swap — same queue
  entry, so Now Playing, the queue and the lyrics don't change. A new song starts with its own audio. Magic
  Instrumentalize (Experimental slider) drives the tap's mid/side reducer (`PlaybackServices.applySettings`).
- **UI** (`App/Features/Tais/`): `TaisStudioProgressCard` (Android's, a 10 pt `surfaceContainer` glass panel; bars,
  buttons and dividers are fills) in Experimental (with the BS-RoFormer row) and in the song sheet above the offline
  card; `OnDeviceModelsPanel` (iOS only, under it in Experimental): each model's state, size, Download / Cancel /
  Remove, and the rendered instrumentals' size with Delete; the lyrics screen's `InstrumentalRenderAction` (no lyrics:
  Render → Rendering… → Play instrumental → Play original, on the 28 pt clear-glass card) and Android's
  `FloatingInstrumentalToggle` (44 pt clear-glass circle growing to a 172 pt "Instrumental" pill) above the controls.
- **Shared-file changes (additive):** `AppEnvironment` (`tais`, started after YouTube), `Playback/Deck.swift`
  (`makeItem(for:overrideURL:)`, `start(rate:at:atHostTime:)`), `Playback/PlaybackServices.swift` (vocal attenuation),
  `Services/LyricsController.swift` (`lyricsService`), `Features/Lyrics/LyricsStaticContent.swift` + `LyricsView.swift`
  (the real card and the toggle), `Features/Settings/ExperimentalSettingsView.swift` (the shell panel replaced),
  `Features/Library/SongOptionsSheet.swift` (the card), `Demo/UITestLaunchRouter.swift` + `Demo/TaisDemo.swift`,
  `project.yml` (`BGTaskSchedulerPermittedIdentifiers` += `io.github.redsn0w1877.pixlaudio.tais-studio`).

Stage 14 screenshot ids (`UITests/TaisScreenshotTests`; demo states, no network or Core ML): `tais.studio`
(Experimental scrolled to Remaster Song: lyric sync running, instrumental ready, BS-RoFormer failed), `tais.models`
(the models panel with wav2vec2 downloading), `tais.songSheet` (the song sheet's card mid-render),
`tais.instrumental`, `tais.instrumentalRendering`, `tais.instrumentalActive` (the lyrics screen with `-lyricsDemo none`).

## Integration notes (wave A: stages 8, 9, 11, 12, 13, 15 merged — tag `stage-13`)

How the stages meet on `main`:

- **Player ↔ lyrics ↔ AI DJ:** the full player's lyrics circle presents `AppCover.lyrics` (stage 9's `LyricsView`,
  above the expanded player, which it returns to); the sparkles circle presents `AppSheet.taisChat` (stage 13's DJ
  chat). Stage 8's `AIDJSheet` placeholder and its `AppSheet.aiDJ` route are gone.
- **Lyrics ↔ AI translation:** the lyrics More sheet has Android's "Translate via AI" (after Save Lyrics):
  `LyricsController.translateViaAI` sends the song's scanned lyrics, else the LRC of what the screen shows, through
  `env.ai.lyricsTranslator` in the device language, and imports a valid reply like a file (each translation pairs with
  its line by timestamp; the toast is Android's message). Stage 9's on-device translation stays below it, renamed "Translate on device" (character-bubble icon) so the two rows read apart.
- **Lyrics ↔ sync editor:** "Sync the words yourself" / the sync chip present `AppCover.lyricsSync(songId:)` — stage
  10's editor (see Stage 10 notes).
- **Spotify ↔ YouTube:** `AppEnvironment` builds `SpotifyService` after `YouTubeServices` and passes
  `InnerTubeSpotifyBridge` (App/Services/Spotify): the matcher searches through stage 11's InnerTube session, matched
  videos resolve through stage 11's `StreamingPlayableURLResolver` (download → complete cache file →
  `pixlstream://`), and "Test playback" reports the same chain the player uses (remote client table, JavaScriptCore
  cipher, Piped). Resolver order, inner to outer: the engine's file resolver → stage 11's streaming resolver →
  `SpotifyPlayableURLResolver`.
- **Launch order** (`AppEnvironment.start()`): first-run setup cover → playback → YouTube (account state, downloads,
  cache trim) → Spotify attach → library load → queue restore → auto refresh → backup pending-playlist retry →
  Spotify start (match counters, pending matches, BG refresh) → the update check.
- **Opening files:** `.onOpenURL` → `AppEnvironment.open(_:)`: a `.pxpl` (or the Android app's legacy `.json.gz`)
  opened from Files / the share sheet is inspected and opens the restore flow (`AppCover.backupImport` starting at the
  module dialog); ignored while the first-run setup is showing (it has its own restore page).
- **English only** (decision 12): see Stage 15 notes › Localisation.

### Visual review (wave A, `int-wave-a` shots vs `docs/design-refs` + Compose)
208 shots, light + dark. Same layout as PixlAudio on the full player (pp_full: top bar with collapse circle, output
and queue buttons; cover; title/artist with the lyrics and AI DJ circles; seek bar with the quality pill; weighted
prev / play / next; shuffle / repeat / favourite row), the mini player (pp_player), the lyrics screen (pp_lyr: track
pill, play square + seek capsule, back · Synced · Static · more), the song sheet (pp_sheet: Play / ♥ / share,
Add to queue / Next, Playlist / Delete, OPTIONS · INFO bar), queue, timer, devices, editor, AI sheets, Spotify,
YouTube, backup and setup screens. Glass in place of Material; text legible in light and dark; coloured blocks keep
the light tint (decision 11). Fixed in review:
- Sleep timer: the disabled "Cancel timer" kept full red glass with a 38 % label (unreadable in dark) — now Android's
  disabled button (faint `onSurface` container, 38 % label), red only while a timer runs.
- Player top bar: the queue button uses `music.note.list` (Android `rounded_queue_music_24`), not a bullet list.
- Lyrics More sheet: the two translate rows read apart ("Translate via AI" / "Translate on device").
Known differences, not bugs: the song sheet has no Remaster card (instrumental / word sync arrive with stage 14) and
no "Set as sound" (iOS apps can't set ringtones), so the large sheet shows empty space below the buttons; the devices
hero's `MPVolumeView` is empty in the Simulator; screenshots use the demo library's placeholder art.
Final check on `main` 3a376e8 (CI run 36934265005, all classes, 208 shots green), re-reviewed side by side: player,
queue, timer, lyrics, Spotify, AI, setup, backup, YouTube and devices screens all match the review above. Left for
their owners: Settings › Library › Music folders (stage 7d) drew its "Excluded Directories" title under the `+`
button (fixed in the final review: the title is centred between the buttons); `ci/export-shots.sh` names the backup probe's text attachment `public.plain-text.txt.png` (it is text, not
an image).

## Integration notes (Integrate B: stages 10 and 14 merged — tag `stage-15`)

- **Lyrics ↔ sync editor:** the lyrics More sheet's first row, the empty-state button and the line-synced chip open
  stage 10's editor (`LyricsSyncEditorView.open(…, fromLyrics: true)`, which returns to the lyrics screen); Edit song's
  "Change the words" / "Fix timing" open it at the words / fix-timing entries. The placeholder is gone.
- **Sync editor ↔ instrumental:** `LyricsSyncPlayer` suspends stage 14's `InstrumentalController` for the session
  (owner `lyrics_sync`, Android `InstrumentalCrossfadeController.suspend`): an instrumental that was playing switches back
  to the song's own audio so the person hears the vocals they are timing, and returns when the editor closes. Crossfades
  and the hand-over stay suspended through the engine's exact-timing session as before.
- **One lyrics service accessor:** both stages had added one (`syncService`, `lyricsService`) to `LyricsController`;
  they are now the single `lyricsService`, used by the editor (stored lyrics, Save as source `user`, Find lyrics online)
  and TAIS Studio (catalog check, Save as source `tais`, "Replace" for a user sync). A TAIS save reloads the lyrics
  screen when it shows that song.
- **Song sheet:** the Remaster Song card (stage 14) now fills the space wave A's review noted under the buttons.
- **Playlist:** "Sync lyrics for all songs" / "Instrumentalize all" and `PlaylistLyricSyncCard` run on TAIS Studio's lane.


### Visual review (Integrate B, `main` 1d22211, CI run 37008732905: 235 shots, every class green)
Compared side by side with the Compose code (`presentation/lyrics/sync/**`, `components/tais/**`) and `pp_card` /
`pp_sheet`. Same layout as PixlAudio, glass in place of Material, legible in light and dark, coloured blocks keep the
light tint (decision 11):
- **Sync editor** (syncIntro … syncLiveTapped): `SyncCardScreen`'s top bar (✕ circle, title, speed pill), centred
  30 pt title / 16 pt body, the three numbered step rows with 44 pt accent circles, the Normal / Slower / Slowest
  capsules, Start + "Got it" at the bottom; the tap screen's progress line, context lines, boxed sung word, NEXT word,
  36 pt pad and Undo / Pause / Back 5 s; the preview's karaoke view under the 32 pt panel (Earlier · offset · Later, Fix a
  line, Keep tapping, share, Save); the words screen's title, body and field (Android repeats the body as the field's
  placeholder too); manage; the system glass alerts and speed menu (documented deviations). Light appearance stays dark,
  as Android's editor does.
- **TAIS** (tais.*): Remaster Song card in the song sheet matches `pp_card` (sparkles, title, description, Render
  Instrumental, divider, Sync / resync lyrics; progress bar + Cancel while running) and fills the space wave A noted
  under the buttons; Experimental's card with the BS-RoFormer row, the models panel; the lyrics screen's instrumental
  card and floating Instrumental pill.
Nothing needed fixing. Known differences, not bugs: no Offline card under Remaster on the demo song (it is a local file;
Android shows it for streamable songs), no "Set as sound" (iOS can't set ringtones).

## Small menus (owner change 2026-10-02)

Hoa asked for "the exploding liquid menus that pop out from [the button's] original position", meaning the system's
own menu morph, checked against a recording of Messages' Edit menu:
- the glass swells and bursts into a lens-like blob, with the menu inside it magnified and blurred;
- the blob settles into the panel, and the text shrinks and sharpens (about 0.3 s).

Hoa wants it "on things that don't need the entire screen like small menus, filter songs, etc" — not on full-screen
surfaces such as the queue. So small menus are SwiftUI `Menu`s, and the system draws the morph:
- `GlassCircleMenu`: Apple's `.glass` / `.glassProminent` button style in a circle. Used by the playlist's Sort Songs
  and ⋯ options.
- `ShapedGlassMenu`: a `Menu` on PixlAudio's own glass shape. Used by Library › Sort by (a segment of the action row)
  and the genre page's Sort & Play.
- Content: `SortMenuSections` (Sort by and Order as inline pickers) and `LibrarySortMenuContent` (plus View / Playlist
  View / Cloud Only), the playlist options (edit, transition, export, batch actions, delete), and Sort & Play
  (Shuffle, Quick Fill, Sort By).
- The queue keeps its own menu. The Android sort and options sheets stay, for UI-test launch states. (2026-10-07:
  the queue's ⋯ circle now liquid-morphs into its menu's pills, see Glass expansion; still not a system `Menu`.)
- `[record:Class]` in a commit message films that UI test class on CI (`MenuRecordingTests` opens these menus slowly),
  so the morph can be compared frame by frame with the reference recording.

## Glass expansion (owner change 2026-10-07)

Hoa asked for more Liquid Glass, starting with the queue, which read as "not glass": the sheet turned opaque at full
height, its toolbar circles were opaque fills on a glass capsule, and the ⋯ menu slid in on its own. These are the
plan's options A + B plus the floating-bar pills (owner decisions). The lyrics page and the full player's top bar
belong to other work and are untouched.

- **See-through tall sheets.** `PresentationDetent.tallGlass` (`SheetScaffold.swift`) is one `.fraction(0.92)`
  detent. iOS 26 draws a partial-detent sheet as inset Liquid Glass and turns a `.large` one opaque. The queue, the
  song sheet (from any row, and from the queue), the AI Daily Mix sheet and Taizo's chat use it, so the player or the
  page shows around and through them. `presentationBackground` is never touched. Trade-offs:
  - one detent, so there is no dragging to full height (dragging down still dismisses);
  - lower contrast over bright art;
  - the player keeps rendering beneath (the ambient styles at their 30 Hz);
  - Taizo's chat had moved to `.large` in stage 13 because the floating glass over Home was hard to read, so check
    it in the shots;
  - Apple documents no threshold for the glass look, so CI shots must confirm that 0.92 still renders inset and
    translucent (0.85 otherwise).
- **Queue toolbar.** Shuffle, repeat and the timer are each their own interactive glass circle: `primary` at
  prominent when on, a hint of `surfaceContainer` when off, the symbol replaced with a content transition. There is no
  backing capsule: Android puts glass circles on a glass capsule, which iOS can't stack (the same call as
  `PlayerToggleRow`). The capsule's padding stays, so nothing moves.
- **Queue ⋯ menu morph.** The toolbar and the open menu share one `GlassEffectContainer(spacing: 8)`. It never
  leaves the tree; only its content switches between the toolbar and the pills.
  - The ⋯ circle and "Save as playlist" carry the same `glassEffectID`, so the circle morphs into that pill and back.
  - The toolbar circles and Locate / Clear use `glassEffectTransition(.materialize)`: they fade rather than being
    pulled into the Save pill, which overlaps the toolbar's area.
  - The toolbar leaves while the menu is open, because overlapping shapes in one container would blend. The undo
    bar stays outside the container for the same reason.
  - It runs on `PixlMotion.selection` through `withAnimation`. The root no longer carries an implicit animation on
    `isMenuExpanded`, which would flatten the spring.
  - Android's 0.55 scrim and the gradient stay.
  - VoiceOver: `.isModal`, the escape action and `queue.menu` sit on the pills' VStack, which exists only while the
    menu is open. On a wrapper around the container they would trap VoiceOver in the closed toolbar and swallow the
    escape that dismisses the sheet.
  - Fallback if the shared-id morph looks wrong on the phone: put the toolbar back outside, give the pills their own
    container under the scrim and restore the slide-in (`.move(edge: .bottom)`). Never keep the pills and a visible
    toolbar in one container.
- **Floating bars: the primary button is its own glass pill.** This covers Save as playlist, Edit song, the Library
  tab order and genre Quick Fill. A glass button can't sit on a glass bar, so each bar's backing glass is gone and its
  controls are separate glass shapes in one container, with spacing below their gaps:
  - Save as playlist: the summary capsule (`secondaryContainer`) and Save (`primary`), both 56 pt.
  - Edit song: Cancel (`secondaryContainer` at container) and Save (`primary` at prominent), where the capsule held
    them.
  - Tab order: Reset becomes a glass circle beside Done (`primaryContainer` at prominent).
  - Quick Fill: the Select all · Clear pair, a status capsule (`surfaceContainerHighest`) and Next / Quick Fill
    (`primary`). On the genre step the pair leaves and the status capsule takes its room; Android keeps its panel and
    hides the pair.
- **Listening Stats header.** It uses the `SettingsScaffold` glass bar (`surfaceContainerHigh` at `GlassTint.bar`,
  fading in over the first half of the collapse) instead of the solid band. The circles and the pill row sit on it,
  as Settings' back circle does.
- **Missed decision-10 conversions (parity).**
  - Full player: the loading chip becomes clear glass inside the lyrics / AI circles' container, and the format pill
    under the seek bar becomes clear glass (both Material Surfaces on Android).
  - Genre page: the artist group header becomes glass (a Surface), and the album play button a glass circle (an
    IconButton).
- **Also glass.**
  - The playlist editor's collage placeholder and Pick Image tile, tinted at `GlassTint.container`: the flat page
    gives them nothing to refract.
  - For performance only: the sleep timer's surfaces and the Save as playlist fields now share a container each.
- **Left alone on purpose.**
  - The queue's swipe-to-remove reveal: glass there would add a second glass layer to a lazy row, mid-gesture.
  - The row ⋮ fills, and the content panels behind glass rows.
  - The playlist editor's top bar: nothing scrolls under it.
  - The devices sheet's tiles: their tap target is a UIKit route picker, untested inside a container.
- **Screenshot ids.**
  - `queue.saveAsPlaylist`: the queue opens Save as playlist after 0.7 s; ready `sheet.saveQueue`.
  - `genre.quickFill`: the genre page opens Quick Fill; ready `screen.quickFill.genre`.
- **Tests.**
  - `PlayerScreenshotTests`: `testQueueMenuDark`, `testSaveQueueLight` / `Dark`.
  - `LibraryScreenshotTests`: `testGenreQuickFillLight`, `testGenreQuickFillGenreStepDark`.
  - `GlassAccessibilityTests/testQueueControlsKeepButtonTraits`.
  - `MenuRecordingTests/testQueueMenuMorph`, filmed with `[record:MenuRecordingTests]`.

## Spotify Connect output (2026-10-03, branch `spotify-connect`; shared spec with Android)

Hoa wants to "beam music" to Spotify Connect speakers (an Echo Show) instead of Bluetooth. The device streams from
Spotify; PixlAudio sends what to play through the Web API's Player endpoints and stays the remote. Facts and limits:
docs/api-notes.md › Spotify Connect output.

- **Where:** the devices sheet's DEVICES page, below the AirPlay rows — header "Spotify Connect" + a refresh glass
  circle (as the route-picker circle), then one `DeviceRow` per device (the sheet's own glass capsule rows, now a
  shared view: SF Symbol for `type`, status badge "Playing here" / "Active in Spotify" / "Available" /
  "Can't be controlled"). Pull to refresh; the list is fetched again whenever the sheet opens. Empty: the sheet's
  empty card with "Devices appear when they're online and signed in to your Spotify. For an Echo, link Spotify in the
  Alexa app." Hidden while Spotify isn't linked; a pre-Connect login shows only "Reconnect Spotify to use Connect".
  While a device plays, "Stop playing on <device>" heads the list and the CONTROLS hero shows the device (icon, name,
  "Spotify Connect • Playing") with its volume slider when `supports_volume` (else a note) instead of the phone's.
- **Chip:** the full player's output pill shows the device's symbol and name, like AirPlay's route name (VoiceOver: "Playing on <device>"; long press: Stop
  playing on <device>); the mini player's artist line becomes "Playing on <device>" with a small speaker icon.
- **Toasts:** Connect has its own `LibraryToast` instance, shown by `RootView` above the bars and inside the devices
  sheet (skipped songs once per resolution pass, takeovers, errors).
- **Seam:** `RemotePlaybackOutput` (`App/Core`). While attached, `PlaybackStore` sends play / pause / next / previous /
  seek / pick-an-entry / repeat there and reports queue edits; the engine stays paused with its queue (no teardown);
  `isPlaying`, `positionMs()` and `PlaybackClock` read the remote. `remoteMoved(toQueueIndex:)` moves the local model
  when the device advances (loaded paused); `resumeLocally` hands back at the device's song and position.
  `NowPlayingController.remote` routes the lock-screen commands and publishes the device's position/rate.
- **Order and windows:** PixlAudio's queue is the order. Up to 100 URIs from the current entry per `play`; the next
  window is sent when the device reaches the window's last entry, or (after background resolution found more) at the
  next track change so nothing jumps mid-song. Shuffle reorders PixlAudio's queue and re-sends (Spotify's shuffle is
  set off); repeat-one is Spotify's `track`; repeat-all wraps in PixlAudio. Picking another song or editing/reordering
  the queue re-sends `play` from the current entry at the current position — except when the device's remaining list
  is unchanged or only grew at the end ("Add to queue"), which just re-indexes.
- **Performance:** networking, JSON and search in PixlNet actors; the main actor runs the reducer only. Polling exists
  only during a session (1 s foreground, 5 s background, Retry-After honoured); the reducer interpolates progress and
  reports "no change" when a poll matches, so nothing observable is written; the device list assigns only on change.
- **Screenshot ids** (`UITests/SpotifyConnectScreenshotTests`, demo devices, no network): `devices.spotifyConnect`,
  `devices.spotifyPlaying`, `devices.spotifyReconnect`, `devices.spotifyEmpty` (the sheet opens on DEVICES),
  `nowPlaying.spotifyConnect`, `miniPlayer.spotifyConnect`.

## Streaming speed (2026-10-07, branch `wt/stream`; iOS first, Android later)

Hoa asked for streamed songs (YouTube Music, Spotify matched to YouTube) to start faster on tap and on skip. Plan:
`plans/streaming-speed.json` (R-numbers below); owner decisions: measure first, then R2, R3, R4, R5a, R7, R11; R8
behind a remote flag that defaults off; R5b and the client order unchanged. Divergences: docs/parity.md › iOS-first
divergences.

- **Measure (R12).** `PlaybackStartTimings` (App/Playback, no YouTube code: the streaming layer reports by the item
  URL's text `pixlstream://<videoId>`) keeps the last 8 starts: tap → URL (Spotify matched, file or stream chosen) →
  audio track loaded → item built → first `.playing`, plus the resolution (time, client, attempt detail, whether the
  URL carries `n`, remote-config wait), the loader's requests (content-info / to-end) and cancellations, the network
  fetches (first chunk time and size) and the first `respond(with:)`, all within the start's first 10 s. One `Mutex`;
  never touched by the processing tap. Signposts: category "Streaming". **Where Hoa reads it:** Settings › Developer ›
  Test playback › "Stream start timings" (a `DeepProbeCard` under its own title, Copy / Close; a snapshot per tap) and
  the deep probe's "Last start" and "Overlapping clients" lines; the newest start also shows in Settings › Developer ›
  Diagnostics › "Last Song Start" (a plain `Form` section, read when the screen appears; shot `diagnostics`). A skip into a prepared song reads "(skip into the
  prepared song)"; a prefetched resolution "done before the tap (prefetch)".
- **First fetch (R2).** PixlNet `StreamChunkPolicy`: AVFoundation's first loading request (content info + bytes 0–1)
  is answered by a GET of the first 128 KiB, so the next request starts from disk; each loading request's network
  fetches then grow 128 KiB → 512 KiB → 2 MiB (cache hits don't advance the ramp; cache reads up to 2 MiB). Prefetch
  and downloads use 2 MiB fetches.
- **Prepare ahead (R3).** `YouTubePrefetcher` v2, one task re-planned on queue / track / play-state changes, cancelled on
  pause: 1.5 s after playback starts, the next songs in skip order (2 on Wi-Fi or Ethernet, 1 on cellular or a
  metered path, none in Low Data Mode — `NetworkConditionsMonitor`, an `NWPathMonitor` started the first time music
  plays) go through the engine's full resolver (Spotify songs are matched on the way) and get their URL resolved;
  once the current song has played 3 s, their first 512 KiB are cached with `allowsConstrainedNetworkAccess = false`;
  30 s before the end the next song's first MiB as before. Off the main actor (`@concurrent`). In Low Data Mode only
  the near-end top-up runs (it was there before, and the gapless hand-over needs those bytes seconds later anyway).
- **Client table (R4).** Resolution never awaits `remote/config.json`; a due refresh starts in the background at
  utility priority, and the saved file's modification date gates the six-hour refresh across relaunches.
- **Retries (R5a).** PixlNet `StreamRetryPolicy` (Android oct3 `CloudStreamProxy.fetch`): four attempts; the first
  401/403/404/410 resolves again with the same client (an IP change), later ones move past it, never once bytes of the
  file are cached (another client may serve another itag → `formatChanged` → skip); 429/5xx wait 250 ms × attempt.
- **HTTP/3 (R6).** `assumesHTTP3Capable` on `*.googlevideo.com` range requests (QUIC racing; TCP fallback).
- **Skip into the prepared song (R7).** `DualDeckEngine.jump` takes over `preparedIncoming` when it is exactly the
  target (crossfade on: from ~1.5 s into the song; gapless: the last ~4.5 s): the incoming deck is captured before the
  swap, the scheduled hand-over cancelled, a crossfade's zero-gain ramp cleared, the transition reported as manual.
- **Overlapping clients (R8, off).** `ChainedYouTubeStreamResolver` hedging (next client after 1.5 s or at once on a
  failure, 8 s per client, first URL wins) runs only when `remote/config.json` sets `innertube.hedge.enabled` — turn
  it on there (no release needed) if the timings show slow or failing VISIONOS. Android's sequential chain is the
  default and its parity tests are unchanged.
- **Matching (R11).** `TrackMatcher.findMatchFanOut` for on-demand matches (play time and R3's pre-matching): after
  the first song search, the rest at once, folded in `findMatch`'s order — same video. The background
  `SpotifyMatchRunner` keeps `findMatch`.
- **Left out:** R9 (cipher / JavaScriptCore warm-up — only if the timings show `n` on VISIONOS URLs), R10 (delegate
  streaming — only if first-byte latency remains), R5b (persisted URLs, owner: not now).


## Accent colour (owner request 2026-10-07; iOS-only, no Android counterpart)

Hoa asked for an app-wide accent: presets plus a custom colour, applied to every tint and Liquid Glass tint, saved
and backed up, updating live. Decisions (DECISIONS.md › Accent colour): option A "seed chroma, vivid"; the player
keeps album colours; the unused Player Theme "System Dynamic" option is renamed "Accent Color"; the default stays
today's soft violet; presets Blue, Indigo, Purple, Pink, Red, Orange, Yellow, Green, Mint, Graphite (grey), Custom.

- **Where:** Settings › Appearance › Global Theme, right after App Theme: `AccentColorRow` — `ThemeSelectorRow`'s
  layout (24 pt `paintpalette` icon in `secondary`, `titleMedium` title, `bodyMedium` description, 16 pt padding,
  `settingsRowGlass()`), with two rows of six 44 pt cells where the value capsule was: PixlAudio (the default), the
  ten presets, then Custom. Six cells fit the narrowest text column (375 pt phone: 271 pt); wider phones spread them.
- **Swatches** are plain 32 pt circle fills on the row's glass (no glass on glass) with `PressScaleButtonStyle`;
  selected = a 42 pt `onSurface` ring (2.5 pt) and a 13 pt bold check, white on the swatch unless that falls below
  3:1, then black. A swatch shows the *named* colour (its seed), not the scheme tone: the dark-mode tones are
  pastel and nearly equal for Red / Pink and Blue / Indigo, and the light tones turn Yellow and Orange into olive
  and brown, so the seeds are what tells the choices apart. The app itself shows the scheme's tone.
- **Custom** is the system `ColorPicker` (`supportsOpacity: false`), its well ringed while a custom colour is the
  accent. The picker reports every drag step; the row commits 180 ms after the last one, never the value it was
  seeded with (opening the page never saves the violet's seed over the default `""`).
- **Scheme:** `ArtworkTheme.accentPair(seed:)` (PixlLibrary): TonalSpot palettes and role tones with the primary
  palette at max(36, seed chroma). Light primaries: Red #BD0E12, Blue #005DB8, Green #006E28, Yellow #705D00 (the
  same numbers as Google's reference utilities); dark ones stay pastel (Red #FFB4AA, Blue #AAC7FF). Contrast comes
  from the fixed role tones: ≥ 4.5:1 for `onPrimary` on `primary`, `primary` on the background and
  `onPrimaryContainer` on `primaryContainer`, for every preset and a sweep of custom picks (`AccentPairTests`).
  Near-grey picks (Graphite) are pure greys at the exact role tones (#5E5E5E / #C6C6C6), error stays red.
- **Applied:** `ThemeStore.accentPair` (memoised per stored value; reading it observes the setting) replaces the brand
  pair in `colors(for:)`, so `appTheme`, the shell's `.tint`, the tab bar pill, sheet tab capsules, selected pills,
  the playing song card, toggles, sliders, captions, icons (secondary) and row glass (surfaceContainer) all follow.
  Sheets and covers re-apply `.tint` (they used to fall back to the static `AccentColor` asset), `alwaysDarkTheme`
  tints with the dark tone, and the windows' `tintColor` follows the accent (`WindowTint`) for UIKit alerts,
  dialogs and menus. The accent snaps (no animation: the root `.animation` is keyed to album colours only, so the
  three tab stacks never cross-fade a re-theme).
- **Player:** Album Art (default) keeps album colours in the mini and full player and the lyrics; with no artwork
  or nothing playing, the player takes the accent. "Accent Color" (stored `dynamic`, Android's "System Dynamic")
  puts the accent on the player too. Album / artist pages with art keep their art colours (`ArtworkThemed`).
- **Storage:** `accent_color_v1` in `UserDefaults`, a `"#RRGGBB"` string (`""` = violet; an Int would flip sign as an
  Android `int`). Backed up in the global-settings module through PixlBackup's `AndroidPreferenceCatalog.iosOnly`;
  restored live (`SettingsReload`). A backup without the key (older iOS, Android) restores cleanly and resets the
  accent to the violet, like any setting a backup doesn't carry.
- **Not done (follow-ups):** Increase Contrast could build the pair with `contrastLevel` 0.5 / 1.0 (the static asset
  has a high-contrast variant, the accent scheme doesn't yet); the launch screen and anything UIKit draws before
  the first frame still use the static `AccentColor` asset.
