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
| Bottom `NavigationBar` (custom compact bar, 3 icons) | Custom glass bar, same layout; glass selection bubble glides between icons | `GlassNavBar` |
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
  - `\.appTheme` — the app chrome (Android's `MaterialTheme.colorScheme` outside the player): the brand scheme,
    or the album scheme when *player theme = Global*;
  - `\.playerTheme` — the current song's album scheme (Android `LocalMaterialTheme` in the player / mini player);
    equals `appTheme` when nothing plays or album theming is off.
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
  request: the bottom bar's glass selection bubble.
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

## Shell (stage 4)

PixlAudio's layout (Android `MainActivity.MainUI`, default nav style, compact bar), `Shell/RootView.swift`:

- Content: the selected tab's `NavigationStack`, full screen. All three stacks stay alive (scroll state kept).
- Bottom, inset 16 pt from the sides and sitting on the home-indicator safe area: the **mini player** (64 pt, top
  corners 32, bottom corners 10) floating **8 pt** above the **bottom bar** (64 pt, top corners 10 while the mini
  player is shown else 32, bottom corners 32). Both are glass; the mini player is tinted with the album's
  `primaryContainer`, the bar with the scheme's `surfaceContainer` (at `GlassTint.bar`).
- Bottom bar: Home, Search, Library — icons only, evenly spread (10 pt row padding), 56×32 selection bubble
  (`secondaryContainer` glass) behind the selected icon, which is `primary`, filled, 1.1×; others
  `onSurfaceVariant`. Re-tapping the selected tab pops it to its root.
- The bar shows only at a tab's root — every pushed screen hides it (Android `routesWithHiddenNavigationBar`); the
  mini player then sits alone with 32 pt corners.
- Tapping the mini player presents `AppCover.nowPlaying` (stage 8 builds the player and its drag-up gesture).
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
| YouTube login | `.youTubeLogin` | `YouTubeLoginView` (Features/YouTube) | 11 |
| Spotify dashboard / browse | `.spotifyDashboard`, `.spotifyBrowse(query:)` | Features/Spotify | 12 |
| Accounts | `.accounts` | `AccountsView` (Features/Accounts) | 15 |
| AI playlist sheet (Daily Mix sparkle button) | `AppSheet.aiPlaylist` | `AiPlaylistSheet` (Features/AI) | 13 |
| AI Playlist Lab (Library › Create playlist › With AI) | `AppCover.aiPlaylistLab` | `AiPlaylistLabView` (Features/AI) | 13 |
| TAIS DJ chat (Experimental › TAIS DJ; player's Taizo button) | `AppSheet.taisChat` | `TaisChatSheet` (Features/AI) | 13 |
| Setup | `AppCover.setup` | `SetupView` (Features/Onboarding) | 15 |
| Plus / license debug, nav-bar corner radius | — (dropped: everything unlocked; Material-only setting) | — | — |

Stage 7d notes: settings rows are glass shapes inside a group clipped to 24 pt (the Compose `clip` on the
group), 2 pt apart (`Features/Settings/Components/SettingsRows.swift`); every settings screen uses
`SettingsScaffold` (Android `CollapsibleCommonTopBar`). Dropped as Material-only or Android-only, each noted in
its view: album-art palette style, nav-bar corner radius, smooth corners, the visual-style switch, the Plus card and
licence debug tools, battery optimisation, Chromecast autoplay, Hi-Fi float output, offload-ready formats and the
ExoPlayer tile. TAIS tools in Experimental are UI shells until the TAIS stages.

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
  import through `SearchProviding.importAndPlay` on tap.
- UI tests use the scripted provider (`DemoAiClient`): playlist prompts get every other candidate id, Taizo gets a
  fixed intro and answer, a prompt containing `#demo-error` fails like a rejected key.

## Screenshot ids (UI tests)

`-uiTest -screen <id> -appearance light|dark [-song n] [-paused] [-noSong]`. Every `AppRoute`, `AppSheet` and
`AppCover` has an id (`DemoScreen`, App/Demo/UITestLaunchRouter.swift; e.g. `albumDetail`,
`settingsCategory.appearance`, `queue`, `nowPlaying`), plus `home`, `search`, `searchResults`, `library`,
`miniPlayer` (library with a vivid song: album-tinted mini player) and `miniPlayerAlone` (pushed screen: bar
hidden). The ready element of each is `screen.<id>`. Stage 4 shots: home, library, miniPlayer, miniPlayerAlone in
light + dark; search, settings, nowPlaying, diagnostics.

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

Stage 13 ids: `aiPlaylist` (sheet over Home), `taisChat` (empty), `taisChatConversation` (a scripted genre request
and question; ready `screen.taisChat`), `aiPlaylistLab` (cover). Shots: `UITests/AIScreenshotTests`.

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
