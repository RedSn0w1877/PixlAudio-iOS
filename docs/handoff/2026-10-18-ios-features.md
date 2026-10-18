# Four iOS features: Find in playlist, Blocked artists, Gestures, Music Haptics (2026-10-18)

Branch `ios-features-pick`, one PR. The owner picked these from a list of ideas gathered from another iOS Spotify mod; they
are written from scratch from the descriptions (no code copied). Nothing here could be run on a device: CI compiles and
tests it; the feel of the haptics and the gestures needs the phone (see the end).

The settings live in **Settings > Behavior** (the app has no "Player" category; Behavior already holds the player
gestures and haptics): a Gestures row, a Blocked artists row (with the count) and, below Haptic feedback, a Music Haptics
section.

## 1. Find in playlist

- **What it does.** On a playlist page, pull the song list down past its top (or More options > Find in playlist, or
  VoiceOver's "Find in playlist" action on the list) and a glass search field slides in above the header, with the keyboard.
  It filters the page live on title, artist (every credited artist) and album, ignoring case and diacritics ("deja vu"
  finds "Déjà Vu"), every word must match, the page's order is kept. "No matches" shows its own state. Tapping a result plays
  within the filtered list. Cancel clears and hides it; with nothing typed, scrolling the list up also hides it (with a query
  it stays until Cancel so the results stay reachable). Reorder / Remove modes close it.
- **Cheap on large playlists.** `SongFilterIndex` (PixlLibrary) folds each song's strings once per list (built off the main
  actor with `@concurrent`, warmed when the field opens); each keystroke waits 80 ms and then does a substring scan, also off
  the main actor (`ListFindModel`). 20,000 songs are tested.
- **Code.** `Packages/PixlCore/Sources/PixlLibrary/SongFilterIndex.swift` (+ `SearchFolding` in `BlockedArtists.swift`),
  `App/Features/Find/ListFindModel.swift`, `ListFindField.swift`, `App/Features/Detail/PlaylistDetailView.swift`
  (`find`, `scrolled(to:)`, `songList(_:)`).
- **Not done.** Liked Songs and album pages: they are not the same list view (Liked is the Library's songs page, which has
  pull-to-refresh on the same gesture; albums use the collapsing header). The model and field are reusable for them.

## 2. Blocked artists

- **What it does.** A song with a blocked artist among its credits is never played by itself: skipped on next / previous /
  auto-advance / crossfade (`PlaybackQueue` asks `BlockedNavigation`), left out of shuffles (`playShuffled`, and the queue skips
  them under shuffle), a list that would start on a blocked song starts on the next one that is not blocked (nothing plays and
  `lastError` says so when all are), and out of Home (Daily Mix, Your Mix, shelves, Recently played, the "made for you"
  mixes: `HomeStore` recomputes from a snapshot without them, and an AI-curated Daily Mix is filtered too). In playlists, albums,
  the Library songs / Liked pages and artist pages they stay visible, **dimmed with a "Blocked" badge**; tapping one asks
  **Play anyway** (a dialog at the shell). Blocking the artist of the song that is playing moves playback on.
- **Entry points.** The artist page's `...` menu (Block artist / Unblock artist), a song's options sheet (one "Block <artist>" /
  "Unblock <artist>" tile per credited artist, up to three), Settings > Behavior > Blocked artists (count on the row; the
  page has search, an Unblock button per artist, Unblock all with a confirmation, an empty state).
- **Matching.** `BlockedArtistMatcher` (PixlLibrary, 12 tests): id first, then the normalised name (case, diacritics, spacing)
  for artists the YouTube / Spotify matcher created with other ids.
- **Persistence.** One JSON string in `UserDefaults` under `blocked_artists_json` (like `HiddenSongs`), **not SwiftData**: a
  new model needs a `SchemaV2` and a migration stage that cannot be tried without a phone, and a failed migration would lose
  the whole library. It is an iOS-only portable key (`AndroidPreferenceCatalog.iosOnly`), so a settings backup carries it and a
  restore re-reads it (`BlockedArtistsStore.reloadFromDefaults`). Moving it into SwiftData later is a small change: the store
  is the only reader and writer.
- **Not filtered.** Explicit search results and the Spotify browse pages still show a blocked artist's songs (the person
  asked for them; `App/Features/Search` was off limits on this branch anyway); tapping one there plays it as before.
- **Spotify Connect.** While the queue plays on a Connect device the device steps through its own window of the queue
  (`SpotifyConnectController` maps window slots to queue indexes), so blocked songs in that window still play there. The
  on-phone engine, Home, shuffles and `play` honour the list.
- **Code.** `BlockedArtists.swift` (PixlCore), `App/Features/BlockedArtists/` (store, view, badge), `PlaybackQueue.swift`,
  `PlaybackStore.swift` (`setBlocklist`, `play(... allowsBlockedStart:)`), `DualDeckEngine.setBlocklist`, `HomeStore`,
  `SongCard` / `PlaylistSongRow` (dim + badge), `RootView` (dialog), `AppEnvironment.wireBlockedArtists`.

## 3. Gestures

Settings > Behavior > Gestures: a switch per gesture, all on by default. Each horizontal gesture decides once, at its first
movement, whether the drag is clearly sideways (`GesturePolicy.intent`: past 10 pt and at least 1.7x more horizontal than
vertical); only then does it follow the finger or act. They attach with `simultaneousGesture`, so scrolling and the sheet's
vertical drag are never blocked. With VoiceOver on they are off and the same actions are `accessibilityActions`.

| Where | Gesture | Setting |
|---|---|---|
| Full player artwork | swipe left / right = next / previous (the existing snapping carousel; the switch locks it; a glass "Next" / "Previous" hint and the settle haptic follow) | Swipe to skip |
| | double-tap = like / unlike with a heart burst and a haptic | Double-tap to like |
| | long press = add to playlist / share / go to the artist (context menu) | Press and hold for actions |
| Mini player | swipe left / right = next / previous (the bar follows the finger and springs back, haptic) | Swipe to skip |
| | swipe up = open the player (the sheet's existing drag; the switch stops it beginning) | Swipe up to open |
| | long press = the same quick-actions menu | Press and hold for actions |
| Song rows (Library songs / Liked, playlists, albums, artist pages) | swipe right = Play next, left = Add to queue (row follows on a rubber band, the action shows behind it, toast + haptic) | Swipe songs to queue |

`App/Features/Queue` was not touched: queue rows keep their own swipe and reorder. Code: `App/Features/Gestures/`,
`AlbumCarousel.swift`, `NowPlayingView.swift`, `PlayerSheetHost.swift`.

## 4. Music Haptics

- **Settings > Behavior > Music Haptics** (hidden on devices without a Taptic Engine: iPad, Simulator): master switch (off by
  default), Strength 20-200 % (100 default), Follows: Everything (taps on kicks and snares plus a soft rumble under the bass),
  Beat (taps only), Bass (kick taps + rumble), and a status line **On / Off / Not available** with the reason when
  something blocks it.
- **Analysis.** `MusicHapticAnalyzer` (PixlAudioCore): a value type of scalars, so `process` allocates nothing and takes no
  lock. Two-pole filters split the mono mix into bass (<160 Hz), mid (to 2.5 kHz, band-passed) and high; per-sample envelopes
  feed 512-frame blocks; levels are shares of a decaying broadband peak, so a click cannot pass for a kick; onsets are the
  positive rise of a band's level over the previous block (spectral flux over three bands): bass rise = kick, mid + high rise =
  snare / hi-hat, one per 80 ms; the smoothed bass level drives the rumble. Tested on synthetic click trains (snare-like),
  60 Hz bursts (kicks, a rumble), silence, a steady tone, 44.1 / 48 kHz, chunk-size independence and interleaved input.
- **Render path.** `TapContext.runHapticAnalysis` (ProcessingTap.swift) runs after the chain while `HapticSignalBus.isActive`
  is set (one relaxed atomic load per buffer otherwise) and publishes onsets and the bass level through atomics.
- **CoreHaptics.** `HapticEnginePlayer` (own serial queue, haptics-only engine): a 20 ms timer reads the bus, maps onsets with
  `MusicHapticsMapper` (kicks round and softer, snares crisp; intensity x strength), limits to 25 taps/s
  (`HapticRateLimiter`), and sets the intensity of one looping continuous event for the rumble. Taps and rumble changes are
  scheduled `AVAudioSession.outputLatency` ahead so they land with the sound. The engine and timer exist only while running.
- **When it runs** (`MusicHapticsPolicy`, tested): switch on, device supports haptics, playing, app in front, and none of: Low
  Power Mode, thermal serious or critical, safe mode, a phone call (`CXCallObserver`), the music playing elsewhere (AirPlay or
  Spotify Connect). Pause, background and route changes stop it; start / stop / failures go to `DiagnosticsLog`
  (category `haptics`). Speaker, wired, AirPods and other Bluetooth output are fine.
- **Code.** `Packages/PixlCore/Sources/PixlAudioCore/MusicHapticAnalyzer.swift`, `MusicHapticsPolicy.swift`;
  `App/Playback/MusicHaptics/`, `TapParameters.swift` (`AudioEffectsParameters.haptics`), `ProcessingTap.swift`.

## Backup

`blocked_artists_json`, the seven `gesture_*` switches and `music_haptics_{enabled,strength,mode}` are iOS-only portable keys
(`AndroidPreferenceCatalog.iosOnly`, typed in `SettingsBackup.androidTypes`), so Settings > Backup carries and restores them
(PixlBackup `IosFeatureKeysTests`, app `IosFeaturesTests`).

## Tests and screenshots

PixlCore: `BlockedArtistsTests`, `SongFilterIndexTests`, `MusicHapticAnalyzerTests`, `MusicHapticsPolicyTests`,
`GesturePolicyTests`, `IosFeatureKeysTests`. App: `AppTests/IosFeaturesTests` (queue skipping, store, Play anyway, settings,
backup keys, the find model). UI: `UITests/FeaturesScreenshotTests` (`[shots:FeaturesScreenshotTests]`): `playlistFind`,
`playlistFindEmpty`, `playlistBlocked`, `blockedArtists`, `blockedArtistsEmpty`, `gestureSettings`, `settingsBehavior` with
Music Haptics, tapping a result, Play anyway, blocked-artist search / Unblock, swipe a row, swipe the mini player,
double-tap the artwork. In UI tests the haptics rows show (the Simulator pretends it has haptics); the engine never starts.

## Plain phone checks

1. Open a playlist, pull the list down: the field appears with the keyboard. Type part of a title, an artist, an album: the
   list narrows in the same order; an accent-less query finds accented names; nonsense says "No matches". Tap a result: it
   plays and Next walks the filtered list. Cancel brings everything back. Try a playlist of a few thousand songs: typing stays
   smooth.
2. Artist page > `...` > Block artist. Play a shuffled library: that artist never comes up; Next skips them; their songs are
   dimmed with "Blocked" in playlists; tap one: "Play anyway". Settings > Behavior > Blocked artists shows the count, search,
   Unblock, Unblock all. Back up and restore: the list comes back.
3. Gestures page: toggle each switch and check the gesture follows it. Swipe the artwork, double-tap it (heart), hold it
   (menu), swipe and hold the mini player, drag it up, swipe song rows (Library, a playlist, an album). Scroll lists with
   a diagonal thumb: they must still scroll. Turn VoiceOver on: no swipes, but "Next song" etc. in the actions rotor.
4. Music Haptics: switch on, play something with a clear beat on the speaker: taps on kicks and snares, rumble on bass lines.
   Try the three Follows modes and the strength slider. It must stop on pause, when the app goes to the background, in Low
   Power Mode (status says so), on AirPlay / Spotify Connect, and during a call.

## Could not verify without a device

- **The feel of the haptics**: the thresholds (onset 0.16, refractory 80 ms, rumble gain 0.5) were tuned on synthetic
  signals only; real music, the latency compensation (`outputLatency`, large on Bluetooth) and CoreHaptics' behaviour while
  the music plays have not been felt. If it is too busy or too sparse, `MusicHapticAnalyzer.onsetThreshold` and
  `MusicHapticsMapper` are the two places.
- CoreHaptics engine restarts after a system stop, and that a haptics-only engine leaves the music's audio session alone.
- That the double-tap gesture does not delay the album-opening single tap noticeably (it waits for the second tap only while
  Double-tap to like is on).
- The pull-to-reveal threshold (-72 pt) and that it never triggers by accident while scrolling back to the top.
- VoiceOver: the swipe-to-queue actions sit on the row's wrapper; if VoiceOver does not offer them on a song card, move the
  `accessibilityActions` into `SongCard`.
