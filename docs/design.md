# Design — Liquid Glass UI rules and screen map

Source: architecture §3 plus the owner's rules (AGENTS.md) and Apple's HIG (Materials, Tab bars, Color).
PixlAudio uses **Liquid Glass only**: system components first, custom glass rarely, **no Material design
anything**, SF Pro (system font) everywhere, no "Apple"/"Apple Music" in any string.

## Layers
- **Control layer (glass):** tab bar, toolbars, the mini-player accessory, Now Playing transport, floating
  controls, sheets, menus, search field. Use system components that are glass automatically (`TabView`,
  `NavigationStack` toolbars, `.searchable`, sheets, `Menu`, `.buttonStyle(.glass/.glassProminent)`).
- **Content layer (never glass):** lists, rows, cards, grids, artwork, text. Plain `List`/`LazyVGrid`,
  semantic fills (`.fill.tertiary`), artwork. CI forbids `glassEffect` in row/cell/card files.

## Glass rules
- Custom glass only via `glassEffect` inside one `GlassEffectContainer` per cluster; few effects on screen.
- No glass on glass (elements on glass use fills, vibrancy, transparency).
- Never mix `.regular` and `.clear`. `.clear` only over media with bold foreground; add ~35 % dimming when the
  art is bright (luma > 0.6).
- Tint only the primary action, and tint the glass, not the glyph. Monochrome bars over colourful content.
- Never override sheet/popover backgrounds (`presentationBackground`). Half sheets inset with system radii.
- `backgroundExtensionEffect()` on at most one hero view per screen.
- Accessibility: standard glass adapts to Reduce Transparency / Increase Contrast / Reduce Motion by itself;
  test custom glass with `accessibilityReduceTransparency`. SF Symbols with labels, 44 pt targets,
  Dynamic Type (lyrics have their own size). Light and dark everywhere except Now Playing and lyrics
  (always dark).

## Shell
- `TabView`: **Home**, **Library**, **Search** (`Tab(role: .search)` + `.searchable`, search field at the
  trailing end). `.tabBarMinimizeBehavior(.onScrollDown)`.
- Mini player = `.tabViewBottomAccessory(isEnabled: hasItem)`. `.expanded`: 40 pt art, title/artist,
  play/pause, next. `.inline`: 28 pt art, title, play/pause. No glass inside (the accessory is glass),
  nothing updating per second. Tapping it opens Now Playing (stage 8).
- Settings: Home toolbar button → pushed native `Form` (no custom glass). Diagnostics lives under
  Settings › Developer.

## Now Playing (stage 8)
- `.fullScreenCover` with `.navigationTransition(.zoom(sourceID: "player", in: ns))` from a
  `matchedTransitionSource` on the accessory (fallback: large sheet). Always dark.
- Background: the lyrics sprite shader in a calmer preset (shared with lyrics).
- Content layer: paging artwork carousel (prev/current/next, `.scrollTargetBehavior(.paging)`, art springs
  to 0.85 when paused), marquee title/artist, favourite, `Menu` "…", custom non-glass scrubber, `MPVolumeView`.
- Control layer: transport in one `GlassEffectContainer(spacing: 16)` — prev/next `.clear.interactive()`,
  play/pause `.clear.tint(artAccent.opacity(0.35)).interactive()` (the only tinted control); bottom cluster
  lyrics · AirPlay · queue joined with `glassEffectUnion`; 35 % dimming under glass when art luma > 0.6.
- Lyrics is a mode inside Now Playing: artwork shrinks to a header row, `KaraokeLyricsView` fills the
  middle, glass controls stay.

## Sheets, details, lists
- Sheets (queue, song info/tag edit, create/edit playlist, sleep timer, DJ chat, lyrics search):
  `.presentationDetents([.medium, .large])`, glass automatically. System menus/dialogs/alerts.
- Details (album/artist/genre/playlist/mix): hero art `.ignoresSafeArea(.top)` + `.backgroundExtensionEffect()`;
  Play `.glassProminent` tinted with the art accent, Shuffle `.glass`; plain `List` body; glass toolbar grouped
  with `ToolbarSpacer`.
- Lists: plain `List`/`LazyVGrid`, stable IDs, swipe actions (Play Next, Queue, Like), `contextMenu`,
  multi-select via `List(selection:)` + bottom-bar actions, now-playing indicator `waveform` with
  `.symbolEffect(.variableColor.iterative)`.
- Album-art colour: `ColorExtractor` (ImageIO 32×32 → PixlCore k-means), cached in `ArtworkThemeRecord`;
  used for the play tint, mix cards, header fallback gradients.
- Accent: `AccentColor` in the asset catalog (violet, with dark and high-contrast variants).

## Screen map
| Android | iOS |
|---|---|
| Setup | Onboarding cover (add folders, music library, import Android backup) |
| Home | Greeting large title, quick actions, Your Mix/Daily Mix shelves, Recently Played/Added, stats card |
| Daily/Your Mix, Recently Played | Pushed list views |
| Stats | Swift Charts, segmented day/week/month/year/all |
| Library tabs + reorder | Library category list (Playlists, Artists, Albums, Songs, Genres, Folders, Liked, Downloaded, Spotify), Edit to reorder/hide, sort `Menu` |
| Search | Search tab: `.searchable` + `.searchScopes` (Library/Spotify/YouTube Music) + suggestions/history; genre grid when empty |
| Player/queue/cast/song info/artist picker/DJ | Now Playing, queue sheet, AirPlay picker, info sheet, `Menu`, DJ sheet |
| Lyrics sheet + editor | Lyrics mode + menus; sync editor as a full-screen cover |
| Accounts, Spotify dashboard/browse, YouTube login | Settings › Accounts |
| Settings categories, EQ, transitions, delimiters, easter egg | `Form` pages; EQ with custom vertical sliders + response curve |

## Screenshot ids (UI tests)
`-uiTest -screen <id> -appearance light|dark`: `home`, `library`, `search`, `searchResults`, `miniPlayer`
(library scrolled so the tab bar minimizes and the accessory goes inline), `settings`, `diagnostics`.
