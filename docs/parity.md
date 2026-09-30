# Feature parity (Android → iOS)

From architecture §5. Status: **todo** · **wip** · **done** (merged, CI green) · **n/a** (not possible / not
applicable on iOS, with the reason). Update the row and the stage when you land a feature.

| Android | iOS plan | Stage | Status |
|---|---|---|---|
| Media3 service + notification | AVAudioSession + background audio; system Now Playing (Lock Screen, Dynamic Island, Control Center) | 5 | wip — background audio key + Diagnostics tone with Now Playing/remote commands (stage 0) |
| Dual-ExoPlayer crossfade 4×4 + per-playlist rules | DualDeckEngine + tap gain curves + TransitionRuleRecord | 3b, 5 | todo |
| ReplayGain, EQ/BassBoost/Virtualizer, presets | Tap chain with vDSP biquads; 10-band UI + response curve | 3b, 5, 7d | todo |
| Surround downmix, hi-res cap, offload, decoder policy | N/A (iOS handles); route/sample rate shown under Device capabilities | 15 | n/a — handled by iOS |
| Sleep timer (time/count/end of track), queue/shuffle/repeat | PixlAudioCore state machines + QueueUtils | 3a, 3b, 8 | todo |
| Audio focus / noisy | Interruption + route-change handling | 5 | todo |
| MediaStore | Folder bookmarks + Documents + MPMediaLibrary (DRM-free) | 6 | wip — bookmark persistence check in Diagnostics (stage 0) |
| Delimiters, grouping, folders, favourites, playlists, smart rules, M3U | PixlLibrary | 3a, 7a | todo |
| FTS search | In-memory SearchIndex (diacritic-folded, prefix) | 3a, 7c | wip — search tab shell with demo data (stage 0) |
| Tag editing | Overrides + m4a passthrough export + PixlTags writers | 3d, 8 | todo |
| Room v5 + history JSON | SwiftData v1 + same JSON | 4 | todo |
| Spotify (all) | PKCE via ASWebAuthenticationSession, Keychain, sync, playback via YouTube match | 3c, 12 | wip — URL scheme `pixlaudio` + Keychain round trip (stage 0) |
| YouTube (InnerTube, matcher, cipher, PoToken, Piped, downloads, diagnostics, login) | Resource loader + InnerTubeService; **NewPipe dropped** (Java) | 3c, 11 | todo |
| Local HTTP stream/cast proxy | Resource loader | 11 | todo |
| Lyrics providers/tags/cache/parsers/export/import | PixlLyrics + LyricsService (parallel TaskGroup; embedded via AVMetadata + PixlTags SYLT) | 2b, 9 | todo |
| Translation | Translation framework (on device) or AI | 9, 13 | todo |
| Romanisation | `CFStringTokenizer` Latin transcription (Japanese); `applyingTransform(.toLatin)` otherwise | 9 | todo |
| Karaoke view, tap-sync editor | SwiftUI KaraokeLyricsView + sync editor (architecture §4) | 2c, 2d, 9, 10 | todo |
| Forced alignment (wav2vec2 ONNX) | Core ML conversion on CI, downloaded on demand, CTC core ported | 14 | todo |
| Instrumental (MDX-Net) | Core ML conversion with parity gate; fallbacks cloud BS-Roformer + tap mid/side | 14 | todo |
| AI Gemini/OpenAI-compatible/Gemma | URLSession REST (keys in Keychain) / Foundation Models (availability-gated) | 3c, 13 | wip — on-device model availability shown in Diagnostics (stage 0) |
| AI playlists, daily mix, DJ, usage, cache | Ported prompt engine + intent parser; AICache/AIUsage records | 13 | todo |
| Stats, recommendations, Daily Mix | PixlLibrary + Swift Charts | 3a, 7b | todo |
| Backup/restore | PixlBackup; imports Android .pxpl | 3e, 15 | wip — `.pxpl` document type declared (stage 0) |
| Cast | AirPlay (`AVRoutePickerView`) | 8 | todo |
| Wear OS | Built-in watch Now Playing; watchOS app deferred | — | n/a — no extensions under free signing |
| Glance widgets, QS tile | Deferred; system Now Playing + App Intents shortcuts (no extension) | 15 | todo (App Intents only) |
| Android Auto | Not possible (CarPlay entitlement) | — | n/a — entitlement unavailable |
| External player intent | Document types + `onOpenURL` | 15 | wip — document types declared (stage 0) |
| Self-updater | Notify-only check against GitHub Releases | 15 | todo |
| Plus / checkout | Everything unlocked | — | n/a |
| Palette style / nav-bar radius (Material) | Removed; Appearance keeps accent source, lyrics size/blur | 7d | n/a — Material-only |
| QuickFill, easter egg, device capabilities, developer, about, localisation | Ported (String Catalog; 12 Android locales converted late) | 15 | wip — Diagnostics/developer screen (stage 0) |
| Home / Library / Search / Settings shells | Liquid Glass TabView, search tab, bottom accessory mini player, native Form | 0, 7a–7d | wip — placeholder shell (stage 0) |
