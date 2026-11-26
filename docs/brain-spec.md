# PixlAudio Music Brain: specification v1.1 (reviewed)

Date: 2026-11-17. Scope: both apps (Android `PixlAudio-android-audio`, branch `new-ui`, HEAD `1305547`; iOS `PixlAudio-iOS-audio`, branch `new-ui`, HEAD `e97ab5f`). Nothing in either checkout was edited, built or run to write this.

**Evidence tags used throughout**

| Tag | Meaning |
|---|---|
| [C] | I read it in the checkout while writing this spec (file and line given). |
| [L] | Verified live on 2026-11-17 by one of the five research reports (anonymous, one US IP). I did not re-run the probe. |
| [R] | Stated in a report from its own reading of code or documentation. I did not re-check it. |
| [E] | A proposal or estimate. Untested. **Every numeric hyperparameter in this document is [E] unless tagged otherwise**; they are starting values to tune with the replay harness (section 11). |
| [S*n*] | Not verified by anyone. Must be verified in stage *n* before the dependent work starts. |

The one check I re-ran myself: `methods-probe\ekf_check.py`, the synthetic test of the learner in section 5.9. It reproduced the reported numbers (held-out log-loss 0.5927 for the online update against 0.5919 for batch MAP at 4,000 events; 0.6047 against 0.6099 at 200; uninformed 0.6931).

**Review pass (2026-11-17, a second reader).** This document was attacked from four sides (feasibility, honesty of the learning, the listener, scope) and edited in place. Every change is listed in section 16. One new tag:

| Tag | Meaning |
|---|---|
| [V] | Re-verified live by the reviewer on 2026-11-17: anonymous, one US IP, a fresh `visitorData`, the app's exact `WEB_REMIX` `1.20260707.12.00` context. Scripts: `music-brain\review-probe\reprobe.py`, `cont.py`. |

[V] covers: `visitor_id`; the songs search; **song radio on 6 seeds** (US pop, classic rock, K-pop, three Vietnamese tracks) at the exact JSON path of section 3.3 (50 rows each, seed first, 47-50 official-audio rows, 35-37 KB gzip, 0.67-1.06 s, also without any `visitorData`); body-only continuation; the Related tab; `music/get_queue`; the artist page, artist radio and the `MPAD` discography; Deezer `track/isrc:` and `artist/{id}/related`. The reviewer also re-read every code location that sections 4.2, 7.1 and 7.2 cite; where the code said something different the text below was corrected.

**Stage 1 was re-cut.** As first written it held about three passes of work per platform. It is now the loop that makes the app feel like a streaming service (autoplay, stations, one Home row, skip reactions, "Not for me") on top of the event log that every later stage needs; new music inside the mixes, new releases, the background worker and the "Don't learn" controls moved to stage 2. Section 14 has the new cut.

**Two corrections to the brief.** The main Android database is at **version 5** with four migrations, not version 1 (`data/database/PixelPlayDatabase.kt:29` [C]); CLAUDE.md is stale. `finalizeCurrentSession` is at `ListeningStatsTracker.kt:224` and the five-second gate at `:230` [C].

Android paths are relative to `app/src/main/java/com/theveloper/pixelplay/` unless they start with a module name. iOS paths are relative to the repo root.

---

## 0. Decisions

Where the two input designs (A, the learning-core lens; B, the listener-experience lens) differed, or where the code contradicted both, this is what the spec chose.

| # | Question | Choice | Why |
|---|---|---|---|
| D1 | Where the pure logic lives on Android | A new pure-JVM Gradle module `:brain` (A) | The existing golden generator needs a compiled Android tree [R]; a JVM-only module generates vectors with no Android build and cannot import Android classes by construction. Cost: one line in `settings.gradle.kts` (four modules today [C]) and one plugin alias (`org.jetbrains.kotlin.jvm`; the catalogue already pins `kotlin = "2.4.20"` [C]). |
| D2 | Where it lives on iOS | A folder `Packages/PixlCore/Sources/PixlLibrary/Brain/` (B), not a new target | `Package.swift` says every module is declared up front so parallel work never edits the manifest [C]. The brain needs nothing PixlLibrary lacks, and `PixlBackup` already depends on PixlLibrary. Purity is enforced by a source-scan test (section 10.4). |
| D3 | Identity | Both: an Int64 recording id (`rid`) with an alias table inside the engine (A); `sp:<id>` / `yt:<videoId>` strings only at the playback boundary (B) | One recording has several YouTube audio ids and radios mix them [L], so the engine must key on the recording, not on any one id. |
| D4 | How an outside track plays on Android | **Neither design as written.** No row in the main database. A `playable` table in the brain database maps a synthetic 22-character id to a video id, and `SpotifyStreamProxy` consults it when `spotify_songs` has no match (section 7.2) | A's hidden-pool row would leak into the library: the unfiltered `syncUnifiedLibrarySongsFromSpotify()` reads every distinct `spotify_songs` row regardless of playlist (`SpotifyRepository.kt:1105-1109`, called unfiltered at `:690`, `:1020`, `:1093` [C]). B's literal `yt:` id is rejected by `SpotifyStreamProxy.validateId`, which requires `^[A-Za-z0-9]{22}$` (`:96` [C]). The chosen path is [S1]: it is the first task of stage 1, with the pool row as the fallback. |
| D5 | Golden vectors | Generated by `./gradlew :brain:generateGolden` (A), copied into the iOS fixtures | Follows the existing "generated from Android, never hand-edited" rule [R] without the Android build. |
| D6 | Tag merge | Noisy-OR per genre (A) | Bounded in 0..1 and rewards agreement between sources; the two reports each proposed a different rule (weighted sum, max). All three are [E]. |
| D7 | Session vectors | **Changed from both.** Two short lists of recent track ids (liked, skipped) and a pairwise `sim` function, instead of 64-dimension float accumulators | One definition works in stage 1 (no embeddings yet) and later; no floating-point vector state in the session; easier bit-parity. |
| D8 | Swapping the pre-buffered next track after a skip | Not done (B). A skip never changes the track that starts because of it; re-scoring applies from the track after | Android queue edits must not land during a `DualPlayerEngine` transition [R]; iOS prepares the next item ahead for gapless and crossfade [R]. The methods report's swap is a stage 3 experiment. |
| D9 | Autoplay batch | Append 5 in one call when 2 or fewer tracks remain | Each Android `addMediaItems` republishes the whole queue [R], so one call; five keeps the next batch reactive (B). |
| D10 | Stage 1 Home shelves | **Changed from both.** Brain rows ("Because you listened to *X*", at most two) are appended as their own sections; the legacy planner is called exactly as today, minus its "Beyond your library" text-search shelf | Both designs fed outside tracks through the planner's `discoveries` / `releases` parameters (`HomeRecommendationPlanner.kt:38-39` [C]). The planner ranks them with the legacy scorer (`:46` [C]), which has no signal for an unheard track, so the brain's order and reasons would be lost. |
| D11 | The old engine | Untouched through stage 2 as a switchable fallback; deleted with its golden file after stage 3 passes test 6 | Keeps `RecommendationGoldenEqualityTest` and `recommendationMatchesAndroid` (`GoldenVectorTests.swift:167` [C]) green while the new engine proves itself. `MusicTasteRepository` keeps writing the legacy counters for good, because the cloud prepare-ahead rankers read them [R]. |
| D12 | Spotify priors and taste adjustments | One new formula each, for the brain only (sections 4.4, 5.11). The legacy formulas are not touched | The two apps already disagree on both [R]; the brain starts from one spec with shared vectors. Limits follow Android: 300 adjustments, 3,650 days. |
| D13 | Feature count | 51 (the methods report's 44, plus four surface and three origin features from A) | The origin features absorb the bias of migrated and imported rows and are zero at serve time. |
| D14 | Home design, feedback controls, "Your sound", promises | B | A did not specify surfaces. |
| D15 | What "learning" may be claimed | Nothing until stage 3 (B). Stages 1 and 2 say "based on what you play" | Stages 1 and 2 use fixed prior weights plus per-listener rate statistics. |
| D16 | Reason text | Keys and arguments from pure logic; strings in each app's resources (B) | iOS currently hard-codes English reasons in PixlCore [R]. |
| D17 | Paid tier | Nothing in the brain is paid. The Muselle 2 gate on Home is removed in stage 2 | Both designs agree. Plus keeps only what costs money per use (stems, spatial processing). |
| D18 | Model choice for assistant work | Unchanged: whatever `ClaudeConfig.MODEL` pins | Cost figures in section 9.4 are for the owner to decide on; the spec does not downgrade a model on its own. |

---

## 1. Principles and promises

**Principles**

1. **Candidates first.** The app cannot recommend what it cannot name. Stage 1 exists to get real related music into the queue.
2. **The event log is the only source of truth.** Affinities, embeddings, taste islands, ranker weights and bandit posteriors are a cache, rebuilt by replaying the log through one pure function. A formula change is a replay, not a migration.
3. **One decision core, two languages, identical output.** Everything that decides which music is chosen is pure logic, proven equal by shared golden vectors.
4. **Learning is measured or not claimed.** The learned ranker ships only for a listener on whom it beats the fixed prior (test 6).
5. **On the device.** History, taste and the model never leave the phone. No new server.
6. **Nothing at app start.** Home renders from the last saved plan; all computation and network are background, bounded and cached.
7. **Unknown stays unknown.** No guessed genre chips, no guessed moods.
8. **The listener outranks the model.** Taste adjustments, blocked artists and "Not for me" are hard constraints applied after scoring.
9. **The assistant talks; it does not rank.** The language model names things, explains and turns sentences into structured requests. Every track it mentions is resolved against the catalogue first.

**Promises** (shown to the listener on the "How picks work" sheet, section 8.9)

1. Nobody can pay to be in your picks.
2. Less repetition: a song is never in two mixes on the same day, and a new song you ignored three times stays away for 60 days.
3. You can see why a song was picked, and change it. Changes apply from the next track and can be undone.
4. Nothing is slipped into your playlists. Picks live only under the Autoplay line, which has an off switch.
5. It stays on your phone. Looking up songs and facts contacts public music catalogues without an account; they see an IP address and the artist or song looked up. The assistant's cloud mode sends the conversation.

---

## 2. Architecture

### 2.1 Modules

| Layer | Android | iOS | Responsibility |
|---|---|---|---|
| Pure core | `:brain` (new JVM module), package `com.theveloper.pixelplay.brain` | `Packages/PixlCore/Sources/PixlLibrary/Brain/` | Maths, hashing, text folding, identity, reward, affinity, tags, graph, embeddings, islands, session state, features, ranker, bandit, list building, Home planning, reason keys, replay, evaluation, snapshot codec. No I/O, no clock, no platform types. |
| Parsers | `data/youtube/InnerTubeMusicParsers.kt`, `data/brain/source/*Parsers.kt` | `Packages/PixlCore/Sources/PixlNet/YouTube/InnerTubeRadio.swift`, `PixlNet/Knowledge/` | Response JSON to plain row types. Fixture-tested against the saved responses in `music-brain\yt\raw` and `music-brain\probe`. |
| Store | `data/brain/store/MusicBrainDatabase.kt` (Room, `brain.db`) | `App/Services/Brain/BrainStore.swift` over `KeyedLogStore` files | Persistence only. |
| Sources | `data/brain/source/` | `App/Services/Brain/` + PixlNet clients | Network clients behind `KnowledgeSource` / `RadioSource` interfaces, one token bucket per host. |
| Orchestration | `data/brain/BrainRepository.kt`, `BrainEventRecorder.kt`, `data/worker/BrainRefreshWorker.kt` | `App/Services/Brain/BrainService.swift`, `BrainRefreshTask.swift` | Load state, call the core, save, schedule. |
| Playback | `data/service/player/AutoplayPolicy.kt`, `AutoplayController.kt` | `App/Playback/AutoplayController.swift` | Queue top-up and skip reaction. |
| UI state | `presentation/viewmodel/*StateHolder.kt` | `App/Features/**` stores | Render plans. No ranking. |

The legacy engine (`MusicRecommendationEngine`, `Muselle`, `DailyMixManager.personalizedPicks`, and `Recommendation.swift`) is not modified. One switch, `BrainSwitch.engine = legacy | brain`, is read at the call sites listed in section 13.

### 2.2 Data flow

```
 Spotify Web API  (library, likes, playlists, top lists, followed, ISRC, artist ids) --+
 Imported history (listening_history.db / imported_history.tsv) ----------------------+|
                                                                                      vv
 Player --play ends--> BrainEventRecorder --append--> play_event ----------------> Brain.onEvent
   ^                                                      |                        |         |
   |                                                      | replay                 v         v
   |                                                      +--------------->  Affinity     Session state
   |                                                                         (pos/neg)    (in memory)
   |   BrainRefreshWorker (background, budgeted)                                 |             |
   |   YouTube Music --> radio_list, graph_edge --> Graph --> embeddings, PPR    |             |
   |   Deezer / MusicBrainz / ListenBrainz / Wikidata --> track_dna, artist_dna  |             |
   |                         (tags mapped through the bundled genre atlas)       |             |
   |                                                                             v             v
   |                                        Candidate arms --> Features(51) --> Ranker (weights m, q)
   |                                                                             |
   |                                                                             v
   |                                           ListBuilder (constraints, slot plan, MMR, calibration)
   |                                                                             |
   |          +----------------+----------------+----------------+---------------+--------------+
   |          v                v                v                v                              v
   +---- Autoplay tail      Stations          Mixes         Home plan                     Taizo tools
        (queue top-up)                                    (home_plan.json)
```

### 2.3 From a play to a changed recommendation

1. A track ends, is skipped or is stopped. The platform tracker calls `BrainEventRecorder.record` with raw facts (played ms, duration, start and end reason, surface, arm, slot, session). No five-second floor.
2. The recorder resolves the track to a `rid`, appends one row to `play_event`, and hands the event to `Brain.onEvent` on a background dispatcher.
3. `Reward.grade` turns the event into a reward `r` in 0..1 and a trust weight `c`.
4. `Affinity.apply` updates the decayed counters for the track, its artists, its tags, its decade, its island, its arm and its context bucket. Cost: tens of integer operations.
5. `Session.apply` updates the in-memory session state (recent liked and skipped tracks, tag penalties, artist blocks, skip run, novelty appetite).
6. From stage 3: `Ranker.update` applies one online step to the 51 weights, using the feature vector that was computed when the track started.
7. If the engine owns upcoming tracks, `Session.patchQueue` re-scores the engine-owned tail against the pre-scored pool and returns a replacement list. It never touches a track the prefetcher has already warmed (the next one on cellular, the next two on unmetered Wi-Fi [R: `StreamPrefetchPolicy.MAX_DEPTH = 2`]). The platform applies it in one queue edit, and only when the order actually changed. Target: under 10 ms, no network.
8. At session end (30 minutes without a play), on feedback, at a daypart boundary and after the daily refresh, `HomePlanner.plan` rebuilds the Home plan in the background and saves it. Home shows the new plan on its next appearance; it never changes under the thumb.
9. From stage 2, nightly (unmetered, not low battery): the refresh worker fetches radios and facts within the budgets of section 3.7, rebuilds the graph, embeddings and (weekly) the islands, and from stage 3 runs `Ranker.dailyForget`. Stage 1 has no background job: radios are fetched on demand while music plays (section 7.1).

---

## 3. Knowledge layer

### 3.1 Identity

Today a song is a negative long on Android, `spotify_<id>` in older data, and `sp:` / `yt:` on iOS; an artist is the whole display string, so "A, B" and "A" are unrelated [R].

**Recording id (`rid`, Int64).** Minted the first time a recording is seen, as `fnv1a64(utf8(firstKey))` reinterpreted as a signed Int64; if that value is 0 or already belongs to a different recording, `fnv1a64(utf8(firstKey + "#" + n))` for n = 1, 2, ... The rid is stored in `track_alias` (a truth table) and never changes, so it does not need to be reproducible from other state.

| Key form | Source |
|---|---|
| `s:<spotifyTrackId>` | Spotify library, catalogue |
| `i:<ISRC, upper case>` | Spotify `external_ids.isrc`, Deezer |
| `y:<videoId>` | YouTube Music rows |
| `n:<fold(primaryArtistName)>\|<fold(cleanTitle)>\|<identityFlags, lower-case hex>` | every track (it is the only key of an imported play that carries names alone, and the only bridge between a Spotify library track and a YouTube radio row) |

`identityFlags = versionFlags` with the `remaster` bit cleared: a remaster is the same recording for taste, and Spotify and YouTube disagree on whether the title says so [V: the search for Fleetwood Mac "Dreams" returned "Dreams (2004 Remaster)"].

- `track_alias(key PRIMARY KEY, rid)` holds every key.
- **Resolve** (`Ids.resolve(keys, durationMs)`; the caller passes every key it has):
  1. The first of the caller's `s`, `i`, `y` keys (in that order) found in the table decides the rid.
  2. Otherwise, if the caller's `n` key is in the table, its rid is accepted when the caller has no `s` / `i` / `y` key at all (a names-only import), or either duration is unknown, or the two durations differ by at most 3,000 ms. If the durations differ by more, it is another recording under the same name (an edit, a re-recording): mint from the caller's strongest key and do **not** store the caller's `n` key.
  3. Otherwise mint from the first key the caller has, in the order `s`, `i`, `y`, `n`.
  4. Every caller key not yet in the table is stored against the chosen rid (except the `n` key in the rejected case of step 2).
- **Merge.** If step 4 finds a caller key of type `s`, `i` or `y` already stored under a *different* rid (typical: an ISRC that arrives in stage 2 joins a `y:` row and an `s:` row), the two rids are one recording. The rid chosen in step 1 survives; the other gets a row in `track_merge(rid PRIMARY KEY, into)`, with chains flattened at write time. Readers resolve through `track_merge`; events are never rewritten; the merged rid's affinity rows are folded into the survivor at the next rebuild.
- `fold`, `cleanTitle` and `versionFlags` (live, remix, acoustic, instrumental, remaster, cover, karaoke, sped-up, slowed, re-recorded) are defined in section 10.5. They use no regular expressions and no locale API. The two existing normalisers, which disagree [R], are not used by the brain.
- **Never dedupe by video id** [L]: one recording was seen under several audio ids, and radios mix them.

**Artist id (`aid`, Int64).** Same scheme over `sa:<spotifyArtistId>`, `ya:<UC...>`, `da:<deezerId>`, `mb:<mbid>`, `na:<fold(name)>`; resolve order `sa`, `ya`, `da`, `mb`, `na`; an `na` hit is always accepted. A track carries `artistIds`, primary first.

**Stage 1 joins artists by name.** The only artist keys stage 1 has are `ya:` (radio rows carry the channel id [V]) and `na:` (library tracks and imports), so a library artist and a radio artist become one `aid` through the folded name. Two different artists with the same folded name are one artist until stage 2 brings ids; accepted. The primary artist of a library track is the first entry of the library's own split artist list (Android `Song.artists.first()`, falling back to `Song.artist`; iOS the first synced artist). The brain must not split `spotify_songs.artist` itself: it is a `", "`-joined display string (`SpotifyRepository.kt:1283`, `:1292` [C]; the unified library splits it again with `CloudMusicUtils.parseArtistNames`, `:1123` [C]) and "Tyler, The Creator" would break.

**Import changes this needs (stage 2; nothing in stage 1 reads these facts).**
- Spotify: the playlist field list already asks for `artists(id,name)` and `external_ids(isrc)` (`SpotifyApiService.kt:206-208` [C]), and `spotify_songs` already stores `isrc` (`SpotifySongEntity.kt:52` [C]), but `toSpotifySongEntity` keeps only artist names (`SpotifyRepository.kt:1273-1299` [C]). Add `album(release_date,release_date_precision)` and `explicit` to the field list, and pass each track's artist ids, release date and explicit flag to a `BrainFactsSink` at the three call sites (`:303`, `:474`, `:949` [C]). The brain stores them in its own database; `spotify_songs` does not change, so there is no main-database migration.
- YouTube: `parseSearchItem` (`InnerTubeClient.kt:401` [C]) drops the artist and album `browseId` and the play count [R]. The new parsers keep them (section 3.3).
- iOS: `SpotifyAPI.playlistTrackFields` and `fetchArtistGenres`, which fetches each artist's full genre array and keeps the first [R]. Store the facts in the brain's side store, not SwiftData.

### 3.2 Track DNA

One row per rid. Integers only, so both platforms store and compare it identically.

| Field | Type | Meaning |
|---|---|---|
| `rid` | Int64 | primary key |
| `spotifyId`, `isrc`, `deezerId`, `mbRecordingId` | String? / Int64? | foreign ids |
| `ytAudioIds` | [String] | known official-audio video ids; the first one that produced a healthy radio is the preferred seed id |
| `artistIds` | [Int64] | primary first |
| `albumKey` | Int64? | `fnv1a64` of the album key (`MPREb_...`, Spotify album id, or folded name) |
| `title`, `artistDisplay` | String | for display and for reasons |
| `versionFlags` | Int32 bits | from `cleanTitle` (10.5) |
| `firstYear`, `yearSource` | Int16, Int8 | 0 = unknown |
| `durationMs` | Int32 | 0 = unknown |
| `explicit` | Int8 | -1 unknown, 0, 1 |
| `popPermille` | Int16 | 0..1000, -1 unknown |
| `tempoBpmX10`, `tempoSource`, `gainDbX10` | Int16, Int8, Int16 | 0 = unknown tempo; `gainDbX10 = -32768` unknown |
| `scriptLang` | Int8 | from the title's script ranges and the artist country; 0 unknown |
| `tags` | [(atlasId Int16, w UInt8)] | at most 12, section 3.4 |
| `moods` | [Int16] | at most 4 ids from the atlas mood whitelist |
| `energy`, `valence` | Int16 | 0..255, -1 unknown |
| `emb` | Int8[64]? | graph embedding, section 5.4 |
| `embVersion`, `confidence`, `fetchedMask`, `updatedAtMs` | Int32, UInt8, Int32, Int64 | `fetchedMask` has one bit per source tried |

`ArtistDna(aid, spotifyId, ytChannelId, deezerId, mbid, wikidataId, name, country, tags, popPermille, releaseIds[], fetchedMask, updatedAtMs)` holds the artist-level facts; `releaseIds` is the last seen set of `MPREb_` ids for the release diff (section 6.3).

### 3.3 Sources and fallback order

All requests are anonymous. YouTube Music calls use the app's existing `WEB_REMIX` context (`InnerTubeContexts.kt:182-194`, client version `1.20260707.12.00`, `hl=en`, `gl=US` at `:213-214` [C]) and the process-wide anonymous `visitorData`. Keep `hl=en`: strings localise otherwise [L].

**A. YouTube Music (InnerTube).** Base `https://music.youtube.com/youtubei/v1/`. Every body starts with the existing context object.

| Purpose | Request | Where the rows are | Cost [L] |
|---|---|---|---|
| Song radio | `POST next {"videoId":V,"playlistId":"RDAMVM"+V}` | `contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer.watchNextTabbedResultsRenderer.tabs[0].tabRenderer.content.musicQueueRenderer.content.playlistPanelRenderer.contents[].playlistPanelVideoRenderer` (50 rows, seed first) | 35-37 KB gzip, median 787 ms, p90 1178 ms |
| Radio continuation | `POST next {"continuation":T}` (body only; no query parameters needed [V]), `T` from `...playlistPanelRenderer.continuations[0].nextRadioContinuationData.continuation`; the next token is at `continuationContents.playlistPanelContinuation.continuations[0].nextRadioContinuationData.continuation` | `continuationContents.playlistPanelContinuation.contents[]`: 49 rows, **but pages repeat earlier rows**. New ids per page on three seeds [V]: 28, 11, 0, 35; 49, 49, 2, 49; 49, 49, 49, 49. Count a page by its new ids, never by its length | 33 KB, 0.3-1.0 s [V] |
| Tuning chips | read `...musicQueueRenderer.subHeaderChipCloud.chipCloudRenderer.chips[].chipCloudChipRenderer`: `.text.runs[0].text`, and `.navigationEndpoint.queueUpdateCommand.fetchContentsCommand.watchEndpoint.{playlistId, params}`; request with `POST next {"videoId":V,"playlistId":chipPlaylistId,"params":chipParams}` | 25 rows + continuation; mostly music-video ids, so rows must be re-matched to audio | as radio |
| Related tab | find the tab whose `tabRenderer.endpoint.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType == "MUSIC_PAGE_TYPE_TRACK_RELATED"`, then `POST browse {"browseId":"MPTRt_..."}` | `contents.sectionListRenderer.contents[]` carousels: "You might also like" (20 songs, no duration), "Similar artists" (10), "Other performances" (8, used as a dedupe list) | 38 KB, ~0.4 s |
| Artist page | `POST browse {"browseId":"UC..."}` | header `musicImmersiveHeaderRenderer` (or `musicVisualHeaderRenderer`): `.startRadioButton.buttonRenderer.navigationEndpoint.watchEndpoint` = `{videoId, playlistId: "RDEM...", params: "wAEB"}` [V]; sections under `contents.singleColumnBrowseResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer.contents[]`: Top songs (`musicShelfRenderer`, **5 rows** inline [V]), Albums (10), Singles & EPs (10), "Fans might also like" (10) | 37 KB, ~0.45 s [V] |
| Artist radio | `POST next {"videoId":we.videoId,"playlistId":we.playlistId,"params":we.params}` with the three values of that `watchEndpoint`, sent as they came | the song-radio path; 50 rows + continuation [V] | 37 KB, ~0.8 s [V] |
| Full discography | `POST browse {"browseId":"MPAD"+channelId}` (no params) | `...sectionListRenderer.contents[0].gridRenderer.items[].musicTwoRowItemRenderer`, newest first | 9-37 KB, ~0.3 s |
| Album tracks | `POST browse {"browseId":"MPREb_..."}`, read `microformat.microformatDataRenderer.urlCanonical` for the `OLAK5uy_...` audio playlist id, then `POST browse {"browseId":"VL"+thatId}` | `...musicPlaylistShelfRenderer.contents[].musicResponsiveListItemRenderer`. **Never take track ids from the album page itself**: anonymously they are music-video ids [L] | 20 KB + 11 KB |
| Hydrate ids | `POST music/get_queue {"videoIds":[...up to 100]}` | `queueDatas[].content.playlistPanelVideoRenderer`. One invalid id makes the whole batch a 404: bisect | 58 KB per 100, 0.4 s |
| Charts | `POST browse {"browseId":"FEmusic_charts","formData":{"selectedValues":[CC]}}` | Top artists (40) with channel ids; chart playlists hold mostly music-video ids | 19-66 KB |
| New albums | `POST browse {"browseId":"FEmusic_new_releases_albums"}` | 146 unranked releases, no dates; follows the IP, not `gl` | 69 KB |
| Moods and genres | `POST browse {"browseId":"FEmusic_moods_and_genres"}`, then `{"browseId":"FEmusic_moods_and_genres_category","params":P}` | 12 moods, 27 genres; category pages are 116-145 KB gzip | on demand only |

Fields per `playlistPanelVideoRenderer` [L]: `videoId`; `title.runs[0].text`; `longBylineText.runs[]` (artist runs carry `navigationEndpoint.browseEndpoint.browseId` with `pageType MUSIC_PAGE_TYPE_ARTIST`; the album run has `MUSIC_PAGE_TYPE_ALBUM`; a run matching `^\d{4}$` is the year); `lengthText.runs[0].text`; `thumbnail.thumbnails[]`; `badges[].musicInlineBadgeRenderer.icon.iconType == "MUSIC_EXPLICIT_BADGE"`; and the kind at `navigationEndpoint.watchEndpoint.watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig.musicVideoType` (`MUSIC_VIDEO_TYPE_ATV` official audio, `..._OMV` music video, `..._UGC`, `..._PODCAST_EPISODE`).

Parser rules (all from the YouTube report; each one is a break that happened to another client this year [R]):
1. Find renderers by name with a tree walk (`collectByKey`), never by array index. Classify runs by `pageType`, years and play counts by pattern.
2. HTTP 200 without the expected renderer means "no data". An empty radio is retried once.
3. Unwrap `playlistPanelVideoWrapperRenderer.primaryRenderer`. Skip rows with `unplayableText`. A missing `musicVideoType` is "unknown", not official audio.
4. Skip shelves without a header. Accept `singleColumnBrowseResultsRenderer` and `twoColumnBrowseResultsRenderer`.
5. Stop paging on a missing continuation token, not on a short page. Cap at 3 continuations per request chain. Merge pages by video id and then by rid; if two pages in a row add fewer than 5 new ids, stop the chain early. Do not size any pool on "49 new rows per page": one seed gave 74 new ids over four pages, another 196 [V].
6. **Junk detector**, before a radio is stored: `rows < 40`, or no row among rows 1..25 shares an artist id with the seed (all 6 re-probed seeds had exactly 5 such rows and 0-3 rows without any artist id [V]; a row without an artist id is kept but can never satisfy this test). A junk radio falls back to the Related tab, then to another audio id of the same recording, then to the artist radio. About 6% of calls needed this in a 50-seed sample, including a famous song reached through a low-traffic duplicate id [L].
7. Only `MUSIC_VIDEO_TYPE_ATV` rows are playable candidates (47-50 of 50 rows on the re-probed seeds [V]). Other rows are dropped in stage 1; from stage 2 they become candidates after the existing matcher finds an audio id.

On Android the new parsers take `kotlinx.serialization.json.JsonElement` (already a dependency, `app/build.gradle.kts:405` [C]) so they run in plain JVM unit tests; no unit test in the repo parses `org.json` today [C]. `InnerTubeClient.post` is private and returns `JSONObject?` (`:317` [C]); add a sibling that returns the body text.

**B. Open knowledge sources** (all [L] unless marked; errors and limits from the knowledge report).

| Fact | Order and call | Notes |
|---|---|---|
| Track identity | 1. `GET https://api.deezer.com/track/isrc:{ISRC}` (16/16 found). 2. On `error.code == 800` or no ISRC: `GET /search?q={folded artist} {title}`, accept the first hit whose folded title and primary artist match and whose duration is within 3 s. | Deezer errors arrive as HTTP 200 with an `error` object. Field-qualified search returns nothing today. Up to 40 sub-requests per `GET /batch?methods=[...]`, each counted against the quota. |
| Artist ids | 1. One SPARQL query per 100 Spotify artist ids at `https://query.wikidata.org/sparql` (`P1902` to `P434` MBID, `P2722` Deezer id, `P136`/`P8052` genres as MusicBrainz genre ids; the query is in the knowledge report, section 6.2). 2. `GET https://musicbrainz.org/ws/2/url?resource=https://open.spotify.com/artist/{id}&inc=artist-rels&fmt=json`. | 15/16 test artists were on Wikidata, 14 with genres. |
| Recording id, first year | `GET https://musicbrainz.org/ws/2/isrc/{ISRC}?inc=artists&fmt=json`; take the earliest `first-release-date`; reject a title with remix/live/instrumental unless ours has it. Lazy, most-played first. | 13/16 by ISRC; one ISRC resolved to a remix. About one call in three returned 503 at a polite rate. |
| Tags, in trust order | see section 3.4 | |
| Year | minimum year over MusicBrainz `first-release-date`, iTunes `releaseDate`, Spotify `album.release_date`, the YouTube byline year, Deezer `release_date`. **Never Deezer alone**: wrong era on 6 of 16. | `yearSource` records the winner. |
| Popularity | 1. Deezer `rank` / 1000 (so 0..1000). 2. YouTube play-count text ("47M plays"): `min(1000, round(1000 * log10(1+plays) / 9.7))` [E]. 3. `POST https://api.listenbrainz.org/1/popularity/recording {"recording_mbids":[...]}`: `min(1000, round(1000 * log10(1+users) / 5.3))`. | ListenBrainz scores Vietnamese pop far too low; last resort only. |
| Tempo, loudness | Deezer `bpm` when > 0 (27% of a 500-track sample; near zero for editions from 2021 on) and `gain` (498/500). Then AcousticBrainz bulk `GET https://acousticbrainz.org/api/v1/low-level?recording_ids=a;b&features=rhythm.bpm` (9/16, pre-2022). Stage 5: an on-device estimate from decoded audio. | ReccoBeats is not used: unknown provenance and terms. |
| Similar artists | 1. YouTube "Fans might also like" and Related-tab "Similar artists" (10 each). 2. `GET https://api.deezer.com/artist/{id}/related` (exactly 20, 16/16 including all three Vietnamese acts). 3. `GET https://labs.api.listenbrainz.org/similar-artists/json?artist_mbids={mbid}&algorithm=session_based_days_7500_session_300_contribution_3_threshold_10_limit_100_filter_True_skip_30` (12/16; nothing useful for Vietnamese pop). | Merge rule in section 3.6. |
| Fallback graph source | `GET https://api.deezer.com/artist/{id}/radio?limit=100` | Track-level Deezer radio does not exist (error 600). Used only when the YouTube source is switched off. |
| Energy, valence | from the atlas descriptors weighted by the tag vector, nudged by gain and tempo (section 3.5) | -1 when the tag vector is empty. |

Spotify contributes only what it still serves to a development-mode app [R, from Spotify's pages fetched 2026-11-17; nothing was called with a token]: track ids, ISRC, artist ids and names, album and release date, the listener's top lists, saved tracks, followed artists and playlists. Related artists, recommendations, audio features, batch artist lookup, artist top tracks and `popularity` are gone. Whether artist `genres` is still filled is unknown [S1: one log line on a real account]; plan for empty. The app still calls two removed or changed endpoints (`/artists/{id}/top-tracks`; `/artists/{id}/albums` with `limit=50` against a documented maximum of 10) [R]; stage 1 stops relying on both.

### 3.4 Tag vector

Per track, collect `(atlasId, trust, conf)` triples from every source that answered:

| # | Source | trust |
|---|---|---|
| 1 | MusicBrainz / ListenBrainz recording genres (`POST https://api.listenbrainz.org/1/metadata/recording/ {"recording_mbids":[...],"inc":"artist tag release"}`; entries carrying `genre_mbid`) | 1.0 |
| 2 | Primary-artist genres from MusicBrainz (`GET /ws/2/artist/{mbid}?inc=genres&fmt=json`) or Wikidata `P136` | 0.8 |
| 3 | Spotify artist `genres`, including the already-synced `taste_seeds.genres` | 0.7 |
| 4 | YouTube Music radio chip labels, for the track that was the radio's seed | 0.6 |
| 5 | Discogs styles (anonymous, 25 per minute; optional) | 0.5 |
| 6 | iTunes `primaryGenreName` (`GET https://itunes.apple.com/search?term=...&entity=song&limit=5`) | 0.4 |
| 7 | Mean vector of the artist's Deezer-related artists that have tags | 0.35 |
| 8 | Deezer album genre (`GET /album/{id}`, `genres.data[]`) | 0.3 |
| 9 | Vote of tracks sharing a user playlist or a session with it | 0.3 |
| 10 | Assistant model constrained to a shortlist of atlas ids (section 9.3) | 0.25 |

`conf` is `votes / maxVotesInThatSource` for voted sources and 1 otherwise. Sources 7, 9 and 10 run only when the result of 1-6 and 8 is weak (`max w < 0.5`). Row 4 is the cheapest fix for thin Vietnamese coverage: "V-pop", "Vietnamese Hip Hop" and "Vietnamese Indie Pop" exist only as chips [L]. Decade and mood chips ("2010s", "Chill", "Party") go to `moods` or are ignored; they are not genres.

```
per atlas id g:   w(g)   = 1 - PRODUCT over sources s of (1 - trust_s * conf_s(g))        noisy-OR
propagate:        w(parent) = max(w(parent), 0.5 * w(child)); grandparent 0.25
weight:           w(g)  *= min(2.4, 1 + 0.35 * depth(g))                                   static, from the atlas
keep the 12 largest (ties: smaller atlas id); L2-normalise; quantise  q = floor(255 * w + 0.5)
unknown:          if no source reached w >= 0.25 before propagation, tags = [] and the UI shows no genre
```
A track with no tags of its own uses its primary artist's vector at 0.7 weight. Mapping a raw string to an atlas id: by MusicBrainz genre MBID when the source gives one; otherwise `BrainText.fold`, then the atlas name-and-alias index, then the per-source tables for Deezer and iTunes. Measured hit rates [L]: Discogs 16/16, Wikidata artist genres 35/36, MusicBrainz tags 84/115 (the misses are mostly not genres), Deezer 18/27, iTunes 263/525.

### 3.5 Genre atlas (bundled asset)

`genre-atlas-v1.json.gz`, byte-identical in both apps, with a golden test on its SHA-256.

**Build recipe** (an offline script in `tools/atlas/` in the Android repo; output checked in to both repos; re-run a few times a year):
1. **Nodes.** `GET https://musicbrainz.org/ws/2/genre/all?fmt=json&limit=100&offset=0..2200` (23 requests): 2,227 genres with MBID and name [L]. CC0 [R].
2. **Spine.** MusicBrainz genre relationships and aliases. The web service does not return them (`inc` is ignored on `/ws/2/genre/{id}` [L]). Take them from the database dump, or crawl `https://musicbrainz.org/genre/{mbid}` once at 1 request per second (about 45 minutes) and parse "subgenre of", "fusion of", "influenced by", "from". Relationship coverage was checked on 35 pages only (31 had at least one relation) [L]; full coverage is [S2].
3. **Enrichment.** Wikidata by `P8052`: labels and aliases, `P571` inception, `P495` country, and `P279` / `P737` where MusicBrainz has none (2,182 of the 2,227 genres are linked; 672 have no Wikidata parent) [L]. CC0.
4. **Related edges.** Siblings plus influence edges. Optional: the top 8 of `GET https://labs.api.listenbrainz.org/tag-similarity/json?tag=...` per genre.
5. **Families.** 24 hand-picked roots (pop, rock, metal, punk, hip hop, r&b/soul, electronic, house/techno, ambient/downtempo, jazz, blues, country, folk, classical, soundtrack, latin, reggae/caribbean, african, east asian pop, south/southeast asian, middle eastern, brazilian, gospel/religious, experimental); each genre takes the nearest root along `parents`.
6. **Descriptors.** Not open data. Hand-written (assistant-drafted, human-reviewed) for about 200 anchor genres: `energy, valence, danceability, acousticness` in 0..255, `tempoLo, tempoHi`, up to 4 moods from a whitelist of about 40. Descendants inherit from the nearest described ancestor. A one-paragraph description for the same 200 (used by genre pages).
7. **Source tables.** Deezer's 28 names and the roughly 80 iTunes names that matter, mapped by hand.

Only CC0 inputs are bundled. MusicBrainz tag votes are CC BY-NC-SA [R] and are fetched at run time, never bundled.

**Record** (one JSON array, integer ids for edges):
```json
{"i":1042,"m":"<musicbrainz genre mbid>","w":"Q272167","n":"shoegaze","a":["shoegazing","shoegazer"],
 "p":[87],"inf":[311,455],"fus":[],"rel":[312,977],"fam":3,"d":2,"reg":["GB"],"era":[1987,1990],
 "x":{"e":140,"v":90,"dn":76,"ac":51,"t":[90,140],"mood":[12,31]},"desc":"..."}
```
**Size.** The Wikidata layer alone measured 266 KB JSON / 110 KB gzip with MBIDs [L]. The full atlas is estimated at 450-600 KB raw, 130-180 KB gzip [E]; descriptions add roughly 40 KB [E]. Parsed once, off the main thread, into `mbid -> id` and `foldedName -> id` maps (5,595 keys measured [L]).

Energy and valence for a track: the tag-weighted mean of its tags' descriptors; then `energy += clamp((gainDb + 9) * 4, -20, 20)` when gain is known [E]. Vietnamese sub-genre depth is thin in every source [L]; that corner of the atlas is hand-curated.

### 3.6 Similarity graph

One sparse undirected weighted graph over rids and aids. **Stage 1 persists no edges.** It builds the graph in memory, when a pool is built, from the cached `radio_list` rows of the session's seeds (about 10 lists of 50 rows) using the first row of the table below plus the track-to-artist edge; that is all `adj` in section 5.3 needs. Stage 2 adds the `graph_edge` table, the other edge types, embeddings and PageRank, and converts the radio lists stage 1 left behind into edges once.

| Edge | Weight |
|---|---|
| radio seed to the row at rank k (k = 1 for the first non-seed row) | `1 / log2(2 + k)` |
| Related-tab "You might also like", rank k | `0.8 / log2(2 + k)` |
| chip-radio row, rank k (after re-matching to audio) | `0.6 / log2(2 + k)` |
| artist to similar artist, rank k, per source: YouTube 1.0, Deezer 0.6, ListenBrainz 0.4; sum over sources, +0.2 when two or more agree, capped at 1 | `0.7 * s / log2(2 + k_best)` |
| track to its primary artist | 0.5 |
| two tracks completed back to back in the listener's own sessions | 0.3 per co-occurrence, capped at 1.5 |
| two tracks in the same user playlist | 0.2, capped at 1.0 |

Each node keeps its 64 heaviest edges (ties: smaller neighbour id). When the same pair gets edges of several types, the stored weight is the maximum.

**Seeds.** A radio is fetched for a recording through its preferred audio id.
- **Stage 1: on demand only.** A radio is fetched for (a) the tracks of the autoplay or station seed set (section 7.1) and (b) the anchors of the Home rows (section 8.1), when it is not cached or is older than 14 days. No background seeding.
- Stage 2 before islands exist, at most 24 background seeds a day: the 8 most recent distinct tracks the listener *chose* and completed in the last 14 days; the 8 top tracks by decayed engagement; 4 tracks liked or saved in the last 30 days; 4 seeded pseudo-random library tracks with non-negative affinity. At most 2 seeds per primary artist, because two seeds by one artist share 28-31 of 50 rows [L].
- Stage 2 with islands: each island's medoid and its top 10 tracks, the last 20 chosen-and-completed tracks, each newly saved track. Steady state 150-300 seeds, 14-day lifetime, so about 20 fetches a day.
- **A track the engine picked is never a background seed unless the listener liked, saved or replayed it.** Passive completions of engine picks must not choose what is fetched next; otherwise the graph drifts toward whatever the engine happened to play (section 5.12).
- A seed without a known audio id is matched first by the existing matcher; unmatched tracks are not seeds.

Target size: 5,000-15,000 track nodes [E]. A radio is cached as a set with a soft ranking: repeated calls share 46-50 of 50 ids but reshuffle the order [L; the reviewer saw 50 of 50 shared and a different order]. `radio_list` rows are replaced on refresh and otherwise kept, capped at 500 lists (least recently used out first, about 3 MB [E]).

### 3.7 Enrichment scheduler (stage 2)

**Stage 1 has no worker and no enrichment.** Its only brain traffic is on-demand YouTube Music requests while the app is in use: `next` (song or artist radio), its continuation, the Related tab as the junk fallback, and the artist page when an artist station starts. Rules for those: at most 2 in parallel; never inside the first 1.5 s of a track (the existing prefetch settle delay [R]); 8 s timeout, one retry on an empty 200; at most 60 requests per local day [E]; on cellular they are allowed (35-37 KB each, a few per hour of autoplay, against megabytes of audio). `AiDailyMixWorker` and its `music_intelligence_periodic` job stay as they are until this section ships.

`BrainRefreshWorker` (Android: unique periodic work `brain_refresh`, 24 h, unmetered network, battery not low, random initial delay up to 60 minutes; it defers while music plays, as `AiDailyMixWorker` does today [R]). iOS: a `BGProcessingTask` when the system grants one (a new task identifier must be added to `BGTaskSchedulerPermittedIdentifiers` in the app's Info.plist; the app already registers background tasks, for example `App/Services/Cloud/CloudBackground.swift` [C]), otherwise the same lanes run in the first foreground minute at `.utility` priority.

**Lanes, in priority order**

| Lane | Work | Network |
|---|---|---|
| 0 Foreground | the playing track and the next one: at most 10 calls per track (Deezer by ISRC, chips arrive with its radio) | any |
| 1 Radio seeds | section 3.6 | any (37 KB each) |
| 2 Releases | artist pages for the top 20 artists | unmetered |
| 3 DNA, most played first | identity, tags, year, popularity | unmetered |
| 4 DNA, rest of library and graph nodes shown to the listener | same | unmetered |
| 5 Refresh of expired entries | by TTL | unmetered |

**Token bucket per host** (one process-wide bucket each, shared with `SpotifyMatchWorker` for YouTube [R]):

| Host | Rate | Daily ceiling [E] | Back off on |
|---|---|---|---|
| music.youtube.com | 6 in parallel, 8 s timeout | 80 requests | empty 200 (retry once), timeout |
| api.deezer.com | 5 sub-requests per second | 600 sub-requests | `error.code == 4` ("Quota limit exceeded", HTTP 200; seen after about 50 requests in 5 s [L]) |
| musicbrainz.org | 1 per 1.1 s | 200 | 503 (about 30% of first tries [L]) |
| api.listenbrainz.org, labs | 1 per second; obey `X-RateLimit-Remaining` | 150 | 429 |
| query.wikidata.org | 1 per 6 s | 3 | 429 (seen at 2 s spacing [L]) |
| itunes.apple.com | 1 per 3.5 s | 60 | 403 |

Exponential back-off with jitter, honouring `Retry-After`. Daily data ceiling: 5 MB on cellular (lanes 0-1 only), 15 MB unmetered [E].

**Cost of a first import** of 2,000 tracks, about 600 artists and 1,200 albums [R, the knowledge report's estimate]: about 4,000 Deezer sub-requests, 6 Wikidata queries, 750 ListenBrainz calls; roughly 25 minutes of background work for genre, similarity and popularity. Under the daily ceilings above that spreads over about a week, most-played first. MusicBrainz per-recording lookups (2,000 at 1 per 1.1 s) trail behind.

**Time to live:** ids, year, tempo: never expire. Tags: 90 days. Similar artists: 30 days. Radios: 14 days. Popularity: 7 days. Artist release sets: 24 hours. Charts: 24 hours. A miss at a source: 14 days, doubling to 120.

**HTTP clients.** YouTube calls use `@YouTubeOkHttpClient`. The open-data hosts get a new `@KnowledgeOkHttpClient` whose User-Agent is `PixlAudio/<version> ( <public project URL> )`, as MusicBrainz and Wikimedia ask [R]. Neither may be the default client, which overwrites the User-Agent (CLAUDE.md). The User-Agent identifies the app, never the listener.

**Switches.** Every source sits behind an interface with a local flag and a remote flag, following `data/youtube/StreamRemoteFlags.kt` [C, the file exists] and `PixlNet/YouTube/RemoteClientConfig.swift` [C, the file exists]. With YouTube radio off, the graph falls back to Deezer artist radio and similar-artist edges.

### 3.8 Storage

**Android: Room database `MusicBrainDatabase`, file `brain.db`,** version 1, exported schema, real migrations from the first change on. Destructive fallback is acceptable only for the tables marked "cache"; `play_event`, `track_alias`, `artist_alias` and `feedback` must survive every upgrade. The main database and `listening_history.db` are not touched.

| Table | Content | Kind |
|---|---|---|
| `play_event` | section 4.1 | truth |
| `track_alias(key PK, rid)`, `track_merge(rid PK, into)`, `artist_alias(key PK, aid)` | identity (3.1) | truth |
| `affinity(family, key, posQ, negQ, lastMs, posRQ, negRQ, lastRMs)`, PK (family, key) | the decayed counters of section 5.2, one row per key; the rows an event touches (3-8) are upserted in the same transaction as the event | cache |
| `feedback(id PK, kind, targetKind, targetId, createdAtMs, undoneAtMs)` | "Don't learn from this", private-session spans (stage 2). "Not for me" is a `TasteAdjustments` mute in the existing store, not a row here | truth |
| `track_dna`, `artist_dna` | section 3.2 | cache |
| `graph_edge(src, dst, type, wQ16, rank, fetchedAt)`, PK (src, dst, type) | section 3.6 | cache |
| `radio_list(seedRid, kind, chip, fetchedAt, lastUsedAt, healthy, rowsBlob, chipsBlob)` | parsed rows, never raw JSON (a raw radio is 550-565 KB [V]); `chipsBlob` keeps the chip labels as text for stage 2's tag source 4; at most 500 lists | cache |
| `playable(synthId PK, rid, videoId, title, artistDisplay, album, durationMs, artUrl, lastUsedAt)` | how an outside track is played, section 7.2 | cache |
| `source_miss(entity, source, retryAfter)` | negative cache | cache |
| `served_list(recId PK, surface, surfaceId, builtAt, seed, modelVersion, nuQ, itemsBlob)` | the served log (stage 2): repetition budget and the join target for events | cache, 60 days (the "stays away for 60 days" rule of 6.1 needs that long) |
| `impression(recId, shelfId, slot, seenMs, at)` | from stage 3 | cache, 30 days |
| `brain_state(key PK, blob)` | the small parts of the state (versions, `salt`, `p0`, and from stage 2 islands, from stage 3 `m`, `q` and the posteriors). **Never the affinity counters**: a listener with a large import has over 10,000 keys, and rewriting that blob every few plays would be the heaviest write in the app | cache |

Plans are plain files: `files/brain/home_plan.json`, `your_sound.json` (stage 2 and 3).

**Stage 1 creates only** `play_event`, `track_alias`, `track_merge`, `artist_alias`, `affinity`, `radio_list`, `playable` and `brain_state`. Every other table arrives with the stage that first uses it, as a real Room migration. Until `track_dna` exists, the title, artist, length and flags of a track outside the library come from its `radio_list` row and, once it has played, its `playable` row.

**iOS:** the same logical tables as append-only record files under `Application Support/Brain/`, with an in-memory index and compaction when a file exceeds twice its live size (`KeyedLogStore`, pure Swift, testable on Windows; it does file I/O, so it lives in `PixlLibrary/BrainStore/`, outside the folder the purity test scans). Events are monthly segments, `events-YYYY-MM.pbl`, one canonical-JSON record per line; only the current month is ever appended to. SwiftData (`SchemaV1`) is not touched.

**Both** read and write the same canonical `brain-snapshot-v1` (section 10.3), which is also the fixture format and, from stage 3, a backup module.

---

## 4. Event log and migration of existing data

### 4.1 The record

One append-only row per play attempt, live or imported. Raw facts only: reward and trust are derived by `Reward.grade`, so their definition can change and be replayed.

| Field | Type | Meaning |
|---|---|---|
| `eventId` | Int64 | `(startedAtMs << 16) \| seq`; primary key; time-ordered. `seq` = the low 16 bits of `fnv1a64(utf8(origin + "\|" + keyAtWrite))`; if that id is taken by a different play, `seq + 1` modulo 65,536 until free. It is deterministic, so copying the same legacy row twice gives the same id. Timestamps are below 2^47, so the value is positive and replay order is plain ascending Int64 |
| `schema` | Int8 | 1 |
| `origin` | enum | `live`, `importSpotify`, `importYtm`, `migratedHistory` |
| `rid`, `primaryAid`, `otherAids` | Int64, Int64, [Int64] (at most 4) | resolved at write time. The other credited artists are stored because stage 1 has no `track_dna` to look them up in at replay, and section 5.2 gives them half credit |
| `keyAtWrite` | String | the key that was resolved, for audit and re-resolution |
| `startedAtMs` | Int64 | UTC. Imported and migrated rows carry an *end* time (`played_at`, the history `timestamp`): for them `startedAtMs = endTime - max(0, playedMs)` |
| `tzOffsetMin` | Int16? | at play time; null for imports (the home-timezone setting is used) |
| `playedMs`, `durationMs` | Int32 | audible milliseconds, **-1 when unknown** (an imported play without `ms_played`); duration 0 when unknown |
| `startReason` | enum | `tap`, `next`, `prev`, `autoAdvance`, `autoplay`, `restore`, `remote`, `unknown` |
| `endReason` | enum | `trackDone`, `next`, `prev`, `pickedOther`, `stopped`, `queueEdit`, `error`, `killed`, `unknown` |
| `flags` | Int32 bits | shuffle, repeatOne, offline, neverAudible, exploreSlot, controlSession, likedDuring, savedDuring, addedToPlaylist, seekBack, replayed, notForMe, learnExcluded |
| `surface` | enum | `homeShelf`, `dailyMix`, `yourMix`, `namedMix`, `station`, `autoplay`, `album`, `playlist`, `liked`, `artist`, `search`, `assistant`, `manualQueue`, `external`, `unknown` |
| `surfaceId` | String, 40 max | shelf id, mix id, hashed playlist id, or the station seed rid |
| `recId`, `slot` | Int64, Int16 | the list this pick was part of (in stage 1 just an id minted per autoplay batch, station batch or Home row; from stage 2 the join to `served_list`) and its position; 0 and -1 when the play was not a recommendation |
| `arm` | enum | `FAV, DEEP, BACK, RADIO, SIM, ARTIST, NEW, EDGE, ASK, NONE` |
| `sessionId`, `posInSession` | Int64, Int16 | a new session starts after 30 minutes without a play |
| `passiveRun` | Int16 | consecutive tracks with no touch |
| `route` | enum | `speaker`, `wired`, `bluetooth`, `car`, `cast`, `connect`, `unknown` |
| `retrQ`, `radioRank` | Int16, Int16 | for an engine pick: its retrieval percentile x 1000 (feature 37) and its best radio rank (feature 38) at serve time; -1 otherwise. Written from stage 1, because stage 3 trains on these plays and the radio lists they came from will be long gone |
| `pServedQ`, `modelVersion` | Int16, Int32 | predicted probability x 10,000 at serve time, for calibration; 0 before stage 3 |

About 120 bytes a row [E]; 30,000 plays a year is under 4 MB. No retention cap.

### 4.2 Recording changes

- **Android.** The tracker cannot do this alone. It is a `@Singleton` driven by `MusicService` with a song id and nothing else (`syncLocalListeningStatsFromPlayer`, `MusicService.kt:575-614`; `onTrackChanged` and `finalizeCurrentSession`, `presentation/viewmodel/ListeningStatsTracker.kt:98-263` [C]): it does not know why a session ended, how it started, or which `MediaItem` it was. Three changes:
  1. `syncLocalListeningStatsFromPlayer` builds a `PlayContext` from the `MediaItem` (the `brain.*` extras, `EXTERNAL_EXTRA_SPOTIFY_ID`, title, artist, duration, the start reason) and passes it to `onTrackChanged` / `ensureSession`, which keep it on `ActiveSession`.
  2. Every finalisation carries an end reason from the service, per the table below.
  3. `finalizeCurrentSession` (`:224` [C]) calls `BrainEventRecorder.record(session, endReason)` **before** the `listened >= MIN_SESSION_LISTEN_MS` check at `:230` [C], so sub-five-second skips are recorded.

  | Service event | `endReason` of the session that ends | `startReason` of the one that starts |
  |---|---|---|
  | `onMediaItemTransition` (`:1897` [C]), reason `AUTO` | `trackDone` | `autoplay` if the new item has a `brain.arm` extra, else `autoAdvance` |
  | reason `SEEK`, new absolute index = old + 1 / old - 1 / anything else | `next` / `prev` / `pickedOther` | the same word |
  | reason `PLAYLIST_CHANGED` | `pickedOther` when a new queue was set; `queueEdit` when the current item was removed | `tap`; `restore` while `isRestoringPlaybackSnapshot` |
  | reason `REPEAT` | `trackDone` | `autoAdvance`, flag `repeatOne` |
  | `onPlaybackStateChanged(STATE_ENDED)` (`:1831` [C]) | `trackDone` | - |
  | `onPlaybackStopped`, service teardown (`:2073`, `:3238` [C]) | `stopped` | - |
  | an unfinished session found at process start | `killed` | - |

  The absolute index is `engine.getCurrentAbsoluteIndex()`, not `player.currentMediaItemIndex`: after a crossfade the active player can hold a 200-item window of a longer queue (`DualPlayerEngine.kt:285`, `:783-800` [C]). Which reason a crossfade hand-over reports was not traced [S1]; the reward does not depend on it, because a play of 80% or more is a completion whatever the reason says (4.3).

  Surface, surface id, rec id, slot, arm, `retrQ` and `radioRank` travel in `MediaItem` extras (`brain.surface`, `brain.surfaceId`, `brain.recId`, `brain.slot`, `brain.arm`, `brain.retrQ`, `brain.radioRank`). For plays the UI starts they are set in `buildPlaybackMediaItem` (`PlaybackDispatchStateHolder.kt:1002-1019` [C]), which already carries `playlistId` that way; `queueName` and `playlistId` are known at dispatch but never reach the tracker today [R], so thread them through `showAndPlaySong` to the extras. For autoplay and station items they are set by `AutoplayController` in the service. **The queue snapshot must carry them too**: `PlaybackQueueItemSnapshot` stores only id, uri, title, artist, album, artwork and duration (`data/model/PlaybackQueueSnapshot.kt:6-14`; written at `MusicService.kt:2297-2325`, read at `:2459` [C]), so today every extra, including `playlistId`, is lost on a process restart. Add five optional fields with defaults (`brainSurface`, `brainSurfaceId`, `brainRecId`, `brainSlot`, `brainArm`) and restore them into the extras; old snapshots decode unchanged.
- **iOS.** Extend `ListeningStatsTracker.Record` (`App/Playback/ListeningStatsTracker.swift:28-37` [C]) and the `stats.onRecord` fan-out (`App/Playback/PlaybackServices.swift:174` [C]). It is a single closure [R]: add the brain as a second call inside the existing closure, do not reassign it. The 5 s floor is `minimumSessionMs` at `ListeningStatsTracker.swift:13` [C]; the brain's call goes in front of it. The play-source tag is threaded through `PlaybackStore.play(...)` onto the queue entry, and the queue snapshot keeps it.
- **Compatibility.** The existing `PlaybackEvent` (`data/stats/PlaybackStatsRepository.kt:59-65` [R]) and `playback_history.json` keep being written unchanged; their shape is part of the cross-platform backup and an iOS golden fixture [R]. The legacy counters (`feedback_v1`, `music_taste.json`) and `song_engagements` also keep being written **for library songs**: Stats, widgets and the cloud prepare-ahead rankers read them [R]. For an engine track that has no library row, the counter writes (`tasteRepository.record`, `dailyMixManager.recordPlay`, `ListeningStatsTracker.kt:249`, `:293` [C]) are skipped: those stores are capped at 5,000 songs, oldest out [R], and feed rankers that spend money in the cloud. Its `PlaybackEvent` is still written, so it shows in Recently Played through the `playable` lookup (7.2).
- **Spotify Connect and Cast.** Local listening is not recorded by the iOS tracker during Connect [R]. Those plays arrive later through the `recently-played` sync as imported plays. No change in stage 1.

### 4.3 Reward

`Reward.grade(event, context) -> (r, c)`. `context` is `(pastCompletions of this track, the session's skip streak)`. The rules for `r` are tested top to bottom and the first that matches wins:

```
1  notForMe                                                        r = 0.0
2  likedDuring | savedDuring | addedToPlaylist | replayed          r = 1.0
3  playedMs == -1  (an import with no ms_played)                   r = 0.75
4  endReason == trackDone                                          r = 1.0
5  durationMs > 0 and playedMs >= 0.8 * durationMs                 r = 1.0
6  playedMs < 10,000                                               r = 0.0
7  playedMs < 30,000                                               r = 0.1
8  durationMs > 0                                                  r = 0.3 + 0.7 * min(1, (playedMs / durationMs) / 0.8)
9  otherwise  (30 s or more heard, length unknown)                 r = 0.6
```
The 30 s and 80% lines are the ones the app already uses [R]. Rule 3 exists because the two import sources without `ms_played` only list plays that were really heard: Spotify's recently-played list, and the YouTube Music history page (the existing importer calls this outcome `UNKNOWN`, "still counts as a play", `ListeningHistoryModels.kt:50-68` [C]). Imported rows have no duration at all (`imported_plays` has no such column, `ListeningHistoryDatabase.kt:37-60` [C]), so they reach rule 4 through `outcome = completed` (the importer already applied the 80% test when it had a length) and otherwise fall to rules 6, 7 and 9. The first version of this table listed the import rule last, where it could never fire, and divided by an unknown duration.

**A skip**, wherever sections 5.5 and 7.3 say the word, is an event with `endReason` in {`next`, `pickedOther`, `queueEdit`} and `playedMs < durationMs / 2` (or under 30 s when the length is unknown). A play that ends by `stopped`, `killed`, `error`, `prev` or `unknown` is never a skip.

`c` is one base value times every factor that applies. It is at most 4.5.

| Base (exactly one) | Value |
|---|---|
| live, the listener picked it (`album`, `playlist`, `liked`, `artist`, `search`, `manualQueue`, `external`, `unknown`) | 1.0 when `r >= 0.5`; 0.6 when `r < 0.5` (skipping inside one's own playlist is often "not now") |
| live, an engine surface (`homeShelf`, mixes, `station`, `autoplay`, `assistant`) | 0.6 when `r >= 0.5` (it was put in front of them); 1.0 when `r < 0.5` (an active rejection) |
| `migratedHistory` (the app's own older plays) | 0.8 |
| imported | `0.5 * sourceWeight`; `sourceWeight` 1.0 Spotify, 0.35 YouTube Music (the existing constants [R]) |

| Factor | Value |
|---|---|
| rule 1 or 2 fired (an explicit action) | x 3 |
| `seekBack` (a backward seek of 10 s or more after 30 s of play), rule 2 not fired | x 1.5 |
| live, ended by `stopped`, `killed`, `error` or `unknown` with under 30 s heard | x 0 (the listener put the phone down; that is not evidence about the song) |
| ended by `prev` | x 0.3 |
| skip inside a streak of 3 or more skips within 60 s | x 0.3 |
| skip under 2 s directly after a skip | x 0.3 |
| skip of a track with 3 or more past completions | x 0.3 for every key except the track's own |
| completion with `passiveRun >= 6` | x 0.5; x 0.25 at `>= 12` |
| `exploreSlot` | x 1.5 |
| `neverAudible` | x 0 |
| `learnExcluded` (private session, "Don't learn from this") | x 0 |

Two things changed here on review, both to keep the engine from teaching itself. (a) A completed engine pick now counts **less** (0.6) than a completed track the listener chose (1.0); the first version had it the other way round, which let autoplay raise an artist's affinity faster than the listener's own choices could. (b) Imported plays no longer carry a `2^(-ageDays/365)` factor: "age" depended on the day the replay ran, so the same log gave different state on different days, which breaks principle 2. Ageing is done once, by the decay in section 5.2.

### 4.4 Migrating what exists

All of it runs in the background (stage 1: a one-shot job on the brain's own dispatcher the first time the brain is needed; from stage 2 inside the refresh worker), never at app start, and is idempotent (keyed by `eventId`).

1. **Imported history is read, not copied.** `ImportedPlayAdapter` reads `imported_plays` (Android, `listening_history.db`, columns at `ListeningHistoryDatabase.kt:37-60` [C]) or `imported_history.tsv` (iOS) in `played_at` order (indexed [C]) and yields `PlayEvent`s: `endReason` from `outcome` (1 completed to `trackDone`, 2 skipped to `next`, 0 and 3 to `unknown`); `playedMs` from `ms_played`, -1 when null; `durationMs` 0 unless the rid is a library track of known length; `startedAtMs = played_at - max(0, playedMs)`. The adapter resolves each row to a rid with `Ids.resolve` (keys `s:` from `spotify_track_id`, `y:` from `video_id`, `n:` from the names) *before* the pure replay sees it. `Replay` merges that stream with `play_event` by `eventId`. The source tables stay the single home of imported plays. **Scale:** 50,000 imported plays are about 10 counter updates each, once per rebuild; budget under 3 s on a phone [E], and a rebuild is needed only when the import changed (the adapter remembers the highest imported row id it has folded in), a formula version changed, or the clock rule of 5.2 fired.
2. **`playback_history.json` and `.log`** (both apps, up to 730 days [R]) are copied once into `play_event` with `origin = migratedHistory`: `playedMs` from the listened field, duration from the library when the track is still there, reasons and surface `unknown`. An imported row whose end time is within 90 s of a live or migrated row's end time for the same rid is dropped as a duplicate.
3. **Counters are not migrated** (`feedback_v1`, `music_taste.json`, `song_engagements`). They aggregate the same sessions the history file holds, and both drop everything under 5 s [R]. The first version turned their excess into synthetic rows carrying `n`, `nCompleted`, `nEarlySkip`, fields the event record of 4.1 does not have; that is cut. Favourites still enter through step 4.
4. **Facts that are not events** enter as `LibraryFacts` and become prior pseudo-counts in the affinity tables (this replaces the two diverging artist-prior formulas, for the brain only):

| Fact | Pseudo-count |
|---|---|
| Spotify Liked Songs track, in-app favourite | +2 pos on the track, +0.5 pos on its primary artist |
| Spotify top artist | `+6 * rangeWeight * (1 - 0.7 * position/listSize)` pos; `rangeWeight` 1.0 short, 0.8 medium, 0.6 long (Android's constants [R]). An artist in several ranges gets the largest of the three values, not their sum |
| Spotify top track | +3 pos on the track x the same range and rank factors, largest range only; +0.5 pos on its primary artist |
| followed artist | +2 pos |
| taste adjustment "more" / "less" | +6 pos / +6 neg on the target, scaled 1, 1.5, 2 by strength |

   Pseudo-counts do not decay and are recomputed from the facts at every rebuild, so removing a like removes its effect.
5. **Bias in old rows.** Migrated rows contain no skips under 5 s; imported rows come from another app with other defaults. Three origin features (section 5.8, indexes 48-50) absorb the offset during training and are zero at serve time.

---

## 5. Representation and the learning model

What is fitted to the listener, and what is not:

| Component | Kind | Fitted to this listener | From stage |
|---|---|---|---|
| Affinity tables | decayed rate statistics with shrinkage. This is bookkeeping, not a fitted model: it changes with every play, but nothing is optimised | yes, every play | 1 |
| Session state | short lists and counters | yes, every play, reset after 30 minutes | 1 |
| Similarity graph | borrowed crowd co-listening (YouTube Music's, the same for every listener) | no; only *which part* of it is fetched follows the listener | 1 (in memory), 2 (stored) |
| Graph embedding | unsupervised projection of the graph (FastRP) | recomputed from the listener's graph | 2 |
| Taste islands | weighted spherical k-means | weekly | 2 |
| Ranker, 51 weights | online Bayesian logistic regression | every play | 3 |
| Arm bandit, shelf bandit, novelty appetite, repeat-decay exponent | Beta posteriors; a grid fit | daily to weekly | 3 |
| Prior weights `M0`, thresholds, list constraints | constants | no | 1 |
| The assistant's language model | not trained | no | - |

### 5.1 Maths conventions

All real arithmetic is IEEE double using only `+ - * /` and `sqrt`, plus the hand-rolled `ln`, `exp`, `sigmoid`, `log2`, `powNeg` of section 10.2. `clip(x, lo, hi)` is `max(lo, min(hi, x))`. Counters are Int64 fixed point with 20 fractional bits (`Q20`), in memory as well as on disk: `toQ(x) = floor(x * 1048576 + 0.5)`, `fromQ(q) = q / 1048576.0`. Every update converts to double, computes, and converts back, so both platforms hold the same integers after every event. `toQ` clips its argument to `[0, 2^40]` first (section 10.3, rule 11).

### 5.2 Affinity

For every key `k` keep `(posQ, negQ, lastMs)` twice: half-life `H = 120` days, and a "recent" copy with `H = 21` days. Families: `track`, `artist`, `arm` and the single key `all` in stage 1; `tag` and `decade` from stage 2; `island` and `ctx` (daypart x weekday/weekend) from stages 2-3. Each family also has one total key, `sum:<family>`.

```
decay(dtMs, H)  = exp( -LN2 * dtMs / (H * 86_400_000) )                      dtMs >= 0 always
apply(k, r, c, tMs):                                                         tMs = the event's startedAtMs
    if tMs >= lastMs:   pos = fromQ(posQ) * decay(tMs - lastMs, H) ;  neg likewise ;  g = 1 ;  lastMs = tMs
    else:               pos = fromQ(posQ) ;  neg = fromQ(negQ) ;  g = decay(lastMs - tMs, H)     a late event: shrink the increment, never grow the state
    posQ = toQ( pos + g * c * r * part ) ;   negQ = toQ( neg + g * c * (1 - r) * part )
    part = 1 for track, decade, island, arm, ctx, all;
           1 for the primary artist, 0.5 for each other credited artist;
           tagWeight/255 for each of the track's tags
    the family's sum key gets the same call with the same part
read(k, nowMs): pos = fromQ(posQ) * decay(max(0, nowMs - lastMs), H) ;  neg likewise        reads never write
aff(k)   = clip( ln( (pos + prior_pos + a*p0) / (neg + prior_neg + a*(1 - p0)) ) - ln( p0 / (1 - p0) ), -3, 3 )
p0       = clip( posAll / (posAll + negAll), 0.2, 0.8 ) from the key `all` ;  0.5 while posAll + negAll < 1
a        = 2 (track), 4 (artist), 8 (tag), 4 (decade, island, arm, ctx)
share(k) = (pos + neg) / (posSum + negSum) of the family's sum key ;  0 while that total is under 1
```
`prior_pos`, `prior_neg` are the pseudo-counts of section 4.4. `aff` answers "do they finish it when it plays", `share` answers "how much of their listening is it". Because both are rates, being shown more cannot by itself raise an affinity; that is the fix for the legacy engine's summed weights [R].

**What this is bounded by.** `aff` is in -3..3 by the clip. A counter cannot exceed `4.5 * (events per day) * H / LN2`. A new listener has every `aff = 0` and `p0 = 0.5`, so the score of section 5.7 reduces to the retrieval terms (radio order). A listener with 50,000 imported plays gets the same formulas; their imports only weigh less (4.3).

**Late events and clock changes.** Events do not always arrive in time order: a Spotify recently-played sync brings plays older than the last live play, and a phone's clock can be set back. Exponential decay makes the late-event branch above exact (decaying the increment is the same as having applied it on time), so order changes only the last bits; the golden vectors feed events in ascending `eventId`. A clock set far *ahead* is the dangerous case: it would decay every counter to nothing and pin `lastMs` in the future. Two guards: `Replay.rebuild(..., nowMs)` clamps every event time to `nowMs`; and when a live `apply` sees `nowMs + 48 h < newest lastMs in the state`, the state is marked dirty and rebuilt in the background. Until that finishes, the late-event branch keeps every update finite and non-growing.

**Persistence.** The rows an event touched are upserted with the event (3.8). `brain_state` never holds the counters.

**Undo (stage 2).** "Don't learn from this" subtracts the excluded events' own contributions (`c * r` and `c * (1 - r)`, decayed to now, floored at 0) from the counters at once, flags the events, and schedules a full rebuild in the background.

### 5.3 Track vectors

- **Tag vector `g(t)`:** section 3.4. Up to 12 `(atlasId, w)` pairs, unit length before quantisation. `tagdot(a, b) = sum over shared ids of (wa/255) * (wb/255)`.
- **Graph embedding `e(t)`, Int8[64]** (stage 2). FastRP over the graph of section 3.6, with no training loop and no randomness beyond a hash:
  ```
  R[v][j] in { +sqrt(3), 0, -sqrt(3) }:  h = splitmix64(fnv1a64(nodeId) xor j);  h mod 6 == 0 -> +,  == 1 -> -,  else 0
  A~ = D^-1 A (row-normalised, neighbours in ascending id order)
  N1 = A~ R;  N2 = A~ N1;  N3 = A~ N2;   each row L2-normalised after each pass
  E  = N2 + N3;   e = round_half_up(127 * E / ||E||)  as Int8
  ```
  Recomputed in the nightly job when the graph grew by more than 5% and at least weekly; `embVersion` increments. Estimated cost for 50,000 nodes and a million edges: about 2 x 10^8 multiply-adds [E, unmeasured on a phone; S2].
- **Similarity**, used everywhere:
  ```
  sim(a, b) = 1                                             if same rid
            = (0.6 * S + 0.4 * T) / (0.6 + 0.4 * hasT)      otherwise
  S         = cos_int8(e_a, e_b)   if both have embeddings of the same embVersion,   else adj(a, b)
  T, hasT   = tagdot(a, b), 1      if both have a tag vector,                        else 0, 0
  adj(a, b) = max( 0.8 if same primary artist,
                   min(1, edgeWeight(a, b)),
                   0.5 * max over common neighbours n of min(edgeWeight(a, n), edgeWeight(b, n)) )   else 0
  ```
  `cos_int8` is an exact integer dot product divided by precomputed integer norms. The `adj` branch is what makes stage 1 work before any embedding exists.

  **Stage 1 scale.** With no tags and no embeddings `sim = adj`: 0.8 for the same primary artist; `1/log2(2+k)` between a seed and row k of its radio (0.63 at k = 1, 0.30 at k = 8, 0.18 at k = 49); at most 0.25 between two rows of one radio. So in stage 1 a threshold of 0.5 or 0.6 means "same primary artist", and 0.3 means "same artist, or among the first 8 rows of a seed's radio". The first version added a missing tag term as zero (`0.6 * adj + 0.4 * 0`), which capped stage 1 similarity at 0.48 and made the 0.5 and 0.6 thresholds of section 7 unreachable.

### 5.4 Taste islands (stage 2)

Weighted spherical k-means over the listener's top 1,500 tracks by `w_t = sum over plays of c * r * 2^(-ageDays/180)`.

```
point x_t   = concat( e_t / 127 , 0.7 * P(g_t) ), L2-normalised;  P = fixed hashed random projection of the tag vector to 32 dims
K0          = clamp( round( sqrt(n / 20) ), 3, 12 )
init        = first centre: highest w_t; each next: the point maximising sqrt(w_t) * (1 - max cos to chosen centres)
iterate     = exactly 15 rounds, ties to the lower cluster index
merge       = centroid cosine > 0.85;  dissolve clusters under 8 tracks into the nearest
store       = centroid, medoid rid, top 5 tags by weighted share, W_c = sum of w_t, 21-day weight, size
stability   = match new clusters to old greedily by descending centroid cosine, so "Daily Mix 2" stays the same island
```
Re-run weekly or after 200 qualified plays. Fewer than 60 engaged tracks: one island, and the surfaces that need several are hidden.

### 5.5 Session state

In memory; reset after 30 minutes without a play.

| Field | Update |
|---|---|
| `recentPos` (up to 5 rids, newest first) | pushed on `r >= 0.8` |
| `recentNeg` (up to 5 `(rid, h)`) | pushed on a skip with strength `h > 0`: `h = 1.0` under 10 s, `0.6` under 30 s, `0.2` under half the track, else 0 |
| `tagPen[atlasId]` (stage 2: no track has tags before) | on a skip: `+= h * w/255` for the track's top 5 tags, three times that if the previous skipped track shared its top tag; on a completion: all entries `*= 0.7` |
| `artistBlock[aid]` | 10 tracks when `h >= 0.6`; the rest of the session after a second skip of that artist; counts down per track played. **The seed artist of a station is exempt** (the listener asked for that artist): a skip there lowers the artist's share to 1 track in 6 for the next 10 tracks, a second skip to none for 10 tracks, never for the rest of the session |
| `skipRun` | +1 per skip with `h >= 0.6`; 0 on a completion |
| `lastCompleted` | rid |
| `nuSession` | starts at the surface's `nu`; `* 0.67` (floor 0.08) on a hard skip of a novel track; `* 1.25` (ceiling 0.6) on a liked novel track |
| `seed`, `seedKind` | station or autoplay seed |
| `anchors` (up to 3 rids, newest first) | the last tracks the *listener* chose in this session and heard with `r >= 0.5`, plus any engine pick they liked, saved or replayed. Engine picks that merely played through are never anchors (7.1) |

"Skip" and "completion" in this table are the definitions of section 4.3 (a completion is `r >= 0.8`). An event with `c = 0` changes nothing here except `lastCompleted` and the block countdown.

### 5.6 Repeat activation (stage 2)

Stage 1 uses only the time since the last play (features 12-16, read from `affinity.lastMs`), so it keeps no per-track play lists. From stage 2, for a track with past plays `j` (keep the last 30 plus one aggregate bucket):
```
B(t, now) = ln( sum_j c_j * powNeg( hours(now - t_j) + 1, d ) ),   d = 0.5
```
`d` is fixed at 0.5 in stages 1-2. From stage 3 it is fitted per listener from {0.3, 0.5, 0.7, 0.9, 1.2} by held-out log-loss at each weekly rebuild (the source paper fitted 0.86 at a one-week horizon [R]). Features 10 and 11 (B and its square) let the model place this listener's own point of fatigue.

### 5.7 One scorer

`Brain.score(candidates, state, session, ctx, weights) -> [(rid, z, p)]` is the only scorer for every surface. `z = sum_i w_i * x_i`; `p = sigmoid(z / sqrt(1 + 0.3927 * s))` with `s = sum_i x_i^2 / q_i` (0.3927 is pi/8). Surfaces differ only in their candidate pool, their novelty share, their constraint set, and which features are live.

**Two lanes (2026-11-26).** The score above predicts "will they finish it". Lists also need "will they pick it", so every list StationPlanner builds (autoplay, stations, mixes, Endless; home rows and First Listen are all novel and unaffected) orders its familiar lane (`inLibrary`) by a second, "choice" score: `zc = sum_i (w_i + CHOICE_SHIFT_i) * x_i` plus the same station pull and `boostLn` as `z`, `pc` from `zc` like `p`. `w` is whatever ranks the list (the prior `M0` with `logit(p0)`, the learned mean or its posterior sample), so the choice prior is `M0 + CHOICE_SHIFT` and the learner moves it with the same events, with no second model. `CHOICE_SHIFT` (`Ranker.choiceShift`): [1] -0.8, [3] +0.6, [4] -0.4, [12] +1.5, [13] +0.6, [14] +0.1, [15] -0.1, [16] -0.2, [24] +0.5, all others 0 (prior: since_last 12-16 -> 0, track_aff 0.4, artist_aff_recent 1.0, tag_aff 0.4, sess_tag_pen -0.5). The novel lane, the novelty share, skip prediction, the served `pQ`, the reward and the learner use `z` / `p` unchanged. Measured in tools/eval/RESULTS.md ("Two lanes").

### 5.8 Features and initial weights (D = 51)

All features are scaled to roughly -1..1. A feature whose input is unknown is exactly 0. "From" is the first stage in which the feature can be non-zero.

| # | Feature | Definition | M0 | SD0 | From |
|---|---|---|---|---|---|
| 0 | bias | 1 | `logit(p0)` at first rebuild | 0.5 | 1 |
| 1 | track_aff | `aff(track) / 3` | +1.2 | 0.5 | 1 |
| 2 | artist_aff | `aff(primary artist) / 3` | +1.0 | 0.5 | 1 |
| 3 | artist_aff_recent | 21-day copy `/ 3` | +0.4 | 0.5 | 1 |
| 4 | tag_aff | `sum over tags of (w/255) * aff(tag) / 3` | +0.8 | 0.5 | 2 |
| 5 | island_sim | max over islands of `sim(track, centroid)` | +1.0 | 0.5 | 2 |
| 6 | island_weight | `sqrt(W_c share)` of that island | +0.3 | 0.5 | 2 |
| 7 | decade_aff | `aff(decade) / 3` | +0.2 | 0.3 | 2 |
| 8 | liked | favourite or Spotify Liked Songs | +0.8 | 0.5 | 1 |
| 9 | in_playlists | `min(1, userPlaylistsContaining / 3)` | +0.4 | 0.5 | 2 |
| 10 | actr | `clip((B + 4) / 6, 0, 1)`; never played: 0 | +0.5 | 0.5 | 2 |
| 11 | actr_sq | feature 10 squared | -0.3 | 0.3 | 2 |
| 12-16 | since_last | one-hot: under 2 h, 24 h, 7 d, 30 d, older (never: all zero) | -1.5, -0.6, -0.1, +0.1, +0.2 | 0.5 | 1 |
| 17 | unheard_track | never played | -0.3 | 0.5 | 1 |
| 18 | unheard_artist | primary artist never played | -0.4 | 0.5 | 1 |
| 19 | novelty_dist | `1 - island_sim`, only if unheard | -0.5 | 0.5 | 2 |
| 20 | pop | `popPermille / 1000 - 0.5` | 0.0 | 0.3 | 2 |
| 21 | pop_x_mainstream | `pop * (mean pop of completed plays - 0.5) * 2` | +0.3 | 0.3 | 2 |
| 22 | sess_pos_sim | `max over j in recentPos of 0.7^j * sim(i, pos_j)` | +0.8 | 0.5 | 1 |
| 23 | sess_neg_sim | `max over j in recentNeg of h_j * 0.8^j * sim(i, neg_j)` | -1.0 | 0.5 | 1 |
| 24 | sess_tag_pen | `min(1, sum over tags of (w/255) * tagPen[tag])` | -1.0 | 0.5 | 2 |
| 25 | prev_completed | previous track's `r >= 0.8` | +0.4 | 0.3 | 1 |
| 26 | skip_run | `min(1, skipRun / 3)` | -0.4 | 0.3 | 1 |
| 27 | tempo_jump | folded tempo distance to the previous track (section 6.5) | -0.3 | 0.3 | 2 |
| 28 | loud_jump | `abs(gain difference in dB) / 10` | -0.1 | 0.3 | 2 |
| 29 | ctx_lift | context lift of the track's island now (section 5.10) | +0.5 | 0.5 | 3 |
| 30 | weekend | Saturday or Sunday | 0.0 | 0.2 | 1 |
| 31-34 | route | one-hot: speaker, wired, bluetooth, car | 0.0 | 0.2 | 1 |
| 35 | route_x_energy | route is speaker or car, times `energy/255 - 0.5` | 0.0 | 0.2 | 2 |
| 36 | arm_aff | `aff(arm) / 3` | +0.4 | 0.3 | 1 |
| 37 | retrieval | the candidate's retrieval-score percentile within its arm (section 6.1): `(number of candidates of that arm with a strictly smaller quantised score) / max(1, n - 1)`; 0 for arms without a retrieval score | +0.5 | 0.5 | 1 |
| 38 | radio_rank | `1 / log2(2 + best rank in any seed's list)` | +0.3 | 0.3 | 1 |
| 39 | fresh | first seen as a new release in the last 28 days | +0.2 | 0.3 | 2 |
| 40 | duration_dev | `abs(ln(duration / listener's median duration))`, capped at 1; 0 when either is unknown | -0.2 | 0.3 | 2 |
| 41 | explicit_mismatch | explicit track x the listener's explicit completion gap | 0.0 | 0.3 | 2 |
| 42 | passive_ctx | `passiveRun >= 6` | 0.0 | 0.2 | 1 |
| 43 | position | `ln(1 + posInSession) / 4` | 0.0 | 0.2 | 1 |
| 44-47 | surface family | one-hot: home, mix, station/autoplay, user-picked | 0.0 | 0.3 | 1 |
| 48-50 | origin | one-hot: importSpotify, importYtm, migratedHistory. **Forced to 0 at serve time** | 0.0 | 0.5 | 3 (training only) |

Indexes 0-43 and their `M0` / `SD0` are the table in section B.4.2 of `research-methods.md`, with three changes: features 22-23 use the list form of D7; feature 37 is defined for both the stage 1 retrieval score and stage 2 PageRank; feature 5 is named for islands. `M0` is hand-set and is the least defensible part of this spec: fit it once on pooled exports from consenting friends in stage 3 and ship the fitted values as a new `priorVersion`.

In stages 1 and 2 the weights are `M0`, unchanged. That is a fixed formula, and the UI does not call it learning.

**What stage 1 actually computes.** Features 0, 1, 2, 3, 8, 12-18, 22, 23, 25, 26, 36, 37 and 38. Every other entry of the vector is exactly 0 (its input does not exist yet, or its `M0` is 0). Of those, 0, 25 and 26 are the same for every candidate of one list, so they move `p` but not the order. For an unheard radio candidate the order therefore comes from five things: how much the listener likes its artist (2, 3), whether the artist is new to them (18), how close it is to what they just finished or just skipped (22, 23), and where the radio ranked it (37, 38). That is a modest re-ranking of YouTube Music's own order, and stage 1 should be described that way. With an empty state it *is* radio order.

### 5.9 The learner (stage 3)

Each weight is a Gaussian `N(m_i, 1/q_i)`. The update is the diagonal extended-Kalman linearisation of the logistic likelihood, with a soft target `y = r` and weight `c`:

```
init      m = M0 ;  q = 1 / SD0^2
predict   z = sum_i m_i x_i ;  s = sum_i x_i^2 / q_i ;  p = sigmoid( z / sqrt(1 + 0.3927 * s) )
update    p_hat = sigmoid(z) ;  h = max( p_hat * (1 - p_hat), 0.02 ) ;  denom = 1 + c * h * s
          for i ascending with x_i != 0, using the pre-update q_i and the shared s:
              m_i += clip( (x_i / q_i) * c * (r - p_hat) / denom, -0.25, +0.25 )
              q_i  = q_i / ( 1 - (x_i^2 / q_i) * c * h / denom )
daily     q_i <- q0_i + (q_i - q0_i) * 0.995 ;   m_i <- m_i + (M0_i - m_i) * 0.001
```
- The effective step for weight `i` is `1/q_i`; it shrinks as evidence accumulates and the daily forgetting keeps it above zero, so taste drift is tracked.
- The daily line runs once per elapsed local day since `lastForgetDay`, at most 30 times in one go, and never for a gap that is zero or negative (a clock set back). `q_i` only grows in an update: `(x_i^2 / q_i) * c * h / denom < 1` because `s >= x_i^2 / q_i`, so the divisor is always in (0, 1].
- The prior precision is the regulariser, pulling toward `M0`, not toward zero. With no data the model is the prior.
- `denom` shares one observation's credit across the active features, so correlated features do not double-count.
- **Status of this rule.** It was derived for the methods report, not taken from a paper. On synthetic data (12 correlated features) one pass matched a batch refit: I re-ran the check and got held-out log-loss 0.5927 against 0.5919 at 4,000 events, with AUC 0.7465 against 0.7469. **It has not been run on real listening data.** The step clip (0.25) and the `h` floor (0.02) are untested on real data [S3].
- **Timing.** `x` is computed when the track starts and held in memory with the queue entry. The update runs at finalisation on the tracker's background dispatcher: 51 multiply-adds. An event finalised after a process death updates affinities only.
- **Training on history.** `Replay` walks all events in time order: compute features from the state as of that moment, predict, record the prediction (this is the evaluation), update the ranker, then update the affinities. Session features (22-26) are rebuilt by running `Session.apply` over the same events; features 37 and 38 come from the `retrQ` and `radioRank` fields the event has carried since stage 1; the other graph-derived features are 0 for old rows, so their weights stay near the prior until live data arrives.
- **Persistence.** `m` and `q` are saved as IEEE bit patterns inside `BrainState`, debounced to every 10 events and on pause, as an atomic write.

### 5.10 Bandits, novelty and context (stage 3)

**Arms.** One discounted Beta posterior per arm and surface family (home, mix, station/autoplay):
```
on a recommender play from arm a:   alpha += c * r ;  beta += c * (1 - r)
daily:                              alpha <- a0 + (alpha - a0) * 0.98 ;  same for beta
priors (a0, b0):   FAV (7,3)  BACK (6,4)  DEEP (5,5)  ARTIST (5,5)  NEW (5,5)  RADIO (4,6)  ASK (4,6)  SIM (3,7)  EDGE (2,8)
draw:              mu = alpha/(alpha+beta) ;  sd = sqrt( alpha*beta / ((alpha+beta)^2 * (alpha+beta+1)) )
                   theta = clip( mu + sd * gaussian12(rng), 0, 1 )
```
A novel slot goes to the arm with the largest draw among arms that still have candidates. In stages 1 and 2 the same code runs with the priors frozen.

**Within an arm.** One posterior sample of the weight vector per list, `w_i = m_i + gaussian12(rng) / sqrt(q_i)`, with the generator seeded by `fnv1a64(salt, listId, localDate)`, so a mix does not reshuffle when it is reopened. Stages 1-2: `w = M0`.

**Novelty appetite `nu`** = the share of slots given to tracks the listener has never played.
```
nu0      = clip( share of qualified plays in the trailing 365 days that were the track's first play, 0.08, 0.50 );  0.25 with no history
stage 3: two discounted Beta posteriors on recommender surfaces, F (familiar plays) and N (novel plays)
         nuLong = clip( nu0 * (mean(N) / mean(F))^1.5, 0.08, 0.60 ), moving at most 0.02 per day
         +0.01 per novel track liked or saved (decaying over 30 days), capped at +0.10
surface: nu = nuLong * k;  k = 1.0 mixes, 1.2 a station from a seed, 0.8 autoplay after an album or playlist,
         0 for On Repeat and Rediscover, 1 (all novel) for First Listen and Just Dropped
switch:  Familiar / Blend / Discover multiplies nu by 0.4 / 1.0 / 2.0   (available from stage 1)
```

**Context.** 4 dayparts (05-11, 11-17, 17-22, 22-05 local) x weekday/weekend = 8 buckets `b`; keys are islands.
```
n[k][b] += c * r, decayed with H = 120 days ;  N[b] = sum_k n[k][b] ;  P(k) = sum_b n[k][b] / sum_b N[b]
lift(k | b) = clip( ln( (n[k][b] + 20 * P(k)) / (N[b] + 20) ) - ln P(k), -1.5, 1.5 )   ;  0 unless N[b] >= 50 plays
```
Imported timestamps are UTC [R]; they are bucketed with the device's current offset unless the listener sets a home timezone.

**Home shelves** are a cascade bandit: one Beta per (shelf type, daypart). Priors: Made for you (3,7), On repeat (2,8), all others (1,9), pessimistic on purpose, following the published carousel result [R]. Reward 1: a play of 30 s or more started from that shelf. Reward 0: the shelf was on screen for at least 1 s and the visit ended, or a lower shelf was used; only shelves at or above the last one seen are updated. The order is drawn once per daypart and then frozen. A shelf type unseen for 14 days gets one forced exposure.

### 5.11 Hard constraints from the listener

Applied after scoring, outside the learner, so an explicit instruction is exact and immediate.

- **Mute, block, blocked artists, "Not for me":** removed at retrieval. Never returned by any arm, never queued by autoplay.
- **Boost / reduce** (existing strengths 1.25, 1.6, 2.2; reduce is the inverse; the stacked product is clamped to 0.4..2.5 [R]): `z' = z + ln(product)`. Matching is by `aid`, `rid`, album key, or atlas id including descendants, so a genre adjustment finally matches Spotify tracks; today it matches on the empty `Song.genre` [R].
- Each adjustment also writes the pseudo-counts of section 4.4, so from stage 3 the learner agrees with the listener instead of working against them.
- Limits as on Android: 300 adjustments, 3,650 days. The existing `TasteAdjustments` stores and screens stay; the brain reads them through an adapter that resolves targets to ids.

### 5.12 Safeguards

1. Rates, not sums (5.2).
2. Each `m_i` is boxed to `M0_i +- 4 * SD0_i`. Any non-finite value resets the ranker to `M0` and schedules a replay.
3. Exploration slots are logged and up-weighted (`c x 1.5`). Arm quality is audited on exploration plays only; when the audit and the main estimate differ by more than 0.15, the audit is used.
4. PageRank scores are divided by `sqrt(weightedDegree)`, and the popularity weight has a zero-mean prior. This is the counterweight to the popularity lean of radio lists [L].
5. Passive completions, skip streaks and "not now" skips are discounted (4.3).
6. On all-novel lists (First Listen, Just Dropped) features 1, 8, 9, 10, 11 are zeroed.
7. List calibration keeps the largest island from absorbing every mix (6.5).
8. **Frozen-prior gate.** The switch is decided by prediction, not by a traffic split: at every weekly rebuild both weight vectors (learned and `M0`) predict the last 2,000 graded events prequentially, and `useLearnedWeights` turns off when the learned log-loss is not lower, on again when it is lower two weeks running; "Your sound" says which is in use. One session in ten (`splitmix64(sessionId) mod 10 == 0`, unsigned) is additionally ranked with `M0` and flagged `controlSession`, and its completion rate is *shown* next to the learned one once it has 300 plays. The first version switched the learner off from a 1-in-20 control after 500 recommender plays, which is about 25 control plays: a coin toss.
9. A candidate whose DNA `confidence` is 0 and which has no graph edge to anything the listener played cannot be served outside an exploration slot.
10. **Anchors, not echoes.** Only tracks the listener chose, or engine picks they liked, saved or replayed, may seed a radio fetch, an autoplay pool or a Home row (3.6, 5.5, 7.1, 8.1). Together with the 0.6 trust for completed engine picks (4.3) this keeps a passive listener's autoplay from walking away from their taste one radio at a time.

### 5.13 Persisted state

`BrainState = { specVersion, featureVersion, priorVersion, atlasVersion, embVersion, m[51], q[51], actrD, p0, affinity tables (two half-lives; stored as `affinity` rows, not inside the `brain_state` blob, 3.8), pseudo-count tables, islands, armPosteriors, shelfPosteriors, nuLong, nuBoost, ctxCounts, medianDurationMs, mainstreamness, lastForgetDay, salt, useLearnedWeights }`.

Everything in it is reproducible by `Replay.rebuild(events, facts, dna, graph)`. It is a cache with one exception: `salt` (a random 64-bit value created once per install, which makes seeds differ between listeners) is kept across rebuilds.

### 5.14 Versioning

| Version | Bumped when | Effect |
|---|---|---|
| `specVersion` | any change to the pure logic that alters output | new golden files; full rebuild on first launch after update, in the background |
| `featureVersion` | a feature's definition or index changes | ranker reset to `M0`, then replay |
| `priorVersion` | `M0` / `SD0` change | same |
| `atlasVersion` | the bundled atlas changes | tag vectors recomputed from stored source tags; islands re-fitted |
| `embVersion` | embeddings recomputed | session lists are unaffected (they hold rids) |
| event `schema` | a field is added to `play_event` | additive only; old rows read with defaults |

Until a rebuild finishes, the previous state keeps serving. The legacy engine is the fallback if no state exists at all.

---

## 6. Candidate generation, ranking and list construction

### 6.1 Arms

Every candidate carries the arm that produced it; the arm is logged with the play and feeds the bandit and the reason line.

| Arm | What | Rule | From |
|---|---|---|---|
| FAV | familiar favourites | library tracks with at least one completion and `since_last > 4 h`. On autoplay and stations in stage 1: only those by a seed's primary artist or present in a seed's radio list | 1 |
| DEEP | library deep cuts | in the library; never played, or not played in 90 days | 1 |
| RADIO | radio neighbours | unheard official-audio tracks from cached radio lists and Related tabs | 1 |
| ARTIST | more from artists you like | unheard tracks by artists with `aff > 0.5` and 5 or more plays. Stage 1: only such tracks found in the cached radio lists. Stage 2 adds the artist page's top songs (5 rows inline [V]) | 1 |
| NEW | new releases | section 6.3 | 2 |
| BACK | forgotten favourites | imported-history tracks with 5 or more completions, last played over a year ago, not in the library | 2 |
| SIM | similar artists | top tracks of artists adjacent to high-affinity artists, artist never played | 2 |
| EDGE | adjacent genres | tracks whose strongest tag is a sibling or neighbour of a high-affinity tag and has `share < 0.005` | 2 |
| ASK | assistant picks | tracks proposed by the assistant in a batch job and resolved to real ids (section 9) | 4 |

**Retrieval score** (feeds feature 37 as a percentile within the arm):

- Stage 1, RADIO and ARTIST: cross-seed co-occurrence, the starting formula of the YouTube report [E]:
  ```
  cooc(c) = sum over seeds s whose list contains c of  w(s) / (10 + rank_s(c))
  w(s)    = clip( 1 + aff(primary artist of s) / 3, 0.1, 2 )
  cooc   *= 1.25 if c appears under seeds by two or more different artists
  ```
- Stage 2 on: personalised PageRank per island, in deterministic power-iteration form:
  ```
  seeds S = the island's top 30 tracks by w_t ;  p0[t] = w_t / sum(w)
  repeat 4 times:  p <- 0.20 * p0 + 0.80 * (A~ transposed) p ;  truncate p to its 3,000 largest entries (ties by node id)
  ppr(t) = p[t] / sqrt(weightedDegree(t)) ;  keep unheard tracks, top 300 per island
  ```

**Filters before scoring:** drop rows that are not official audio; durations outside 60-900 s; novel candidates whose `versionFlags` include karaoke, cover, sped-up or slowed, and those flagged live, instrumental or remix unless the seed carries the same flag (this replaces "the existing unsuitable-title pattern", which is a different regular expression on each platform [R]); recordings that resolve to a library rid (for novel arms); anything excluded by section 5.11; and **anything the listener ignored three times**: a rid with 3 or more engine-served plays under 30 s in the last 60 days and none of 30 s or more stays out until 60 days after the third. In stage 1 that count is read straight from `play_event` (`arm != NONE`); from stage 2 a serve that never started playing also counts once per local day per surface, when the listener opened that surface that day (`served_list`).

### 6.2 Per surface

`nu` is the novelty share of section 5.10. "Pool" is what is scored; all pools come from local tables.

| Surface | Pool | Size | `nu` | Constraints beyond 6.4 | Seed for randomness |
|---|---|---|---|---|---|
| Autoplay (queue has 2 or fewer tracks left) | RADIO of the session's anchors (5.5); FAV and DEEP with `sim >= 0.3` to an anchor; ARTIST | batches of 5 from a pool of at least 40 | `nu0 * 0.8` after an album or playlist, `* 1.0` after a single track or a mix (`nuLong` from stage 3) | first track is the bridge (7.1) | session id, batch index |
| Station from a song | seed radio + up to 2 continuations (25-100 further tracks, not 98: pages overlap [V]) + Related tab; library tracks with `sim >= 0.3` to the seed; from stage 2, PageRank from the seed. When the pool runs under 15, re-seed from the best-received station track's radio | endless; first batch 20 | `nu0 * 1.2` (`nuLong` from stage 3) | `sim(i, seed) >= 0.25` with embeddings, `>= 0.15` without; score `z + 1.2 * (0.6 * sim(i, seed) + 0.4 * feature22)` | seed rid, local date |
| Station from an artist | artist radio (`RDEM...`), artist top songs, similar artists' top songs | same | same | at most 1 in 3 by the seed artist | same |
| Station from an album / playlist (stage 2) | up to 3 / 5 seed tracks (most played, else the first; at most 2 per artist), radios merged by `cooc` | same | same | none of the source's own tracks in the first 10 | same |
| Station from a genre or mood (stage 2) | the listener's top tracks under that atlas node; chip radios of matching seeds; EDGE within the node | same | same | tag weight for the node `> 0` | same |
| Daily Mix / Your Mix, stage 1 | unchanged: the legacy mixes, library only. (The first version grafted novel slots onto them; that needed background radio seeding, a new saved-mix format and non-library rows in both mix screens, all of which stage 2 rebuilds anyway. Moved to stage 2.) | - | - | - | - |
| Daily Mix 1..K, stage 2 | FAV + DEEP + BACK inside one island; PageRank RADIO for that island; ARTIST | 30 each, K = 3-6 | `clip(nuLong, 0.15, 0.40)` | `island_sim` of every track to this island `>= 0.2` | island id, local date |
| Your Mix, stage 2 | all islands, weighted by the current daypart lift | endless, first 60 | `0.8 * nuLong` | calibration across islands | local date |
| First Listen (weekly) | RADIO, SIM, EDGE, ARTIST; unheard only | 30 | 1 | at least 40% from never-played artists; at most 2 per artist | ISO week |
| Just Dropped | NEW | up to 30 | 1 | loved artists first, then adjacent | local date |
| On Repeat | top by decayed plays in the last 30 days | 30 | 0 | none | - |
| Rediscover | `aff(track) > 0.5`, not played in 90 days | 30 | 0 | rotates by a 30-day served penalty | ISO week |
| Daypart mix (stage 3) | the island with the largest `W_c * exp(lift)` now | 25 | 0.15 | shown only when the bucket has 50 plays | date, daypart |
| Home shelves | section 8.1 | 12 cards | per shelf | a track appears once on the page | date, daypart |

### 6.3 New releases

- **Loved artists:** the top 20 by artist affinity with a known YouTube channel id, plus followed artists. Daily: `browse UC...`; when the 10-item carousels are full, `browse MPAD<channelId>` for the whole discography. Diff the `MPREb_` ids against `ArtistDna.releaseIds`.
- **Adjacent artists** (stage 2): the 20 nearest by similar-artist edges that the listener has never played, checked weekly in rotation.
- **Guards**, because release dates are year-only everywhere on YouTube Music and re-releases are mislabelled [L]: the first fetch for an artist is a baseline and surfaces nothing; a "new" id whose folded title matches an older release by that artist is dropped; the year must be the current year (or the previous one during January).
- **Tracks:** through the audio playlist (section 3.3, "Album tracks"), never the album page.
- **Copy:** "Out this week" only when a full date is known (MusicBrainz, or ListenBrainz `GET /1/explore/fresh-releases/?days=7&sort=release_date&past=true&future=false` [L]); otherwise "New".

### 6.4 Hard list constraints

Never violated on any generated list: no recording twice; no track played in the last 4 hours; the same primary artist not within 4 slots and at most 2 per 20 (3 per 50); the same album not within 8 slots; nothing excluded by 5.11; all-novel lists contain only unheard tracks; from stage 2, a track is never in two generated mixes built on the same local day (the legacy mixes of stage 1 make no such promise).

### 6.5 Building a list

Greedy, slot by slot, in `ListBuilder.build`.

```
slot plan    slot 1: "trust opener": familiar, highest p in the list's main island (stage 1: highest p), not played today
             slot 2: familiar
             then:   a novel slot whenever novelSoFar < nu * slotIndex and the previous slot was familiar
                     (nu = 0.25 gives F F N F F F N ...; two novel in a row only when nu > 0.5)
             last:   familiar, high affinity (finite lists only)
bridge       a novel track needs sim >= 0.45 to the track before it; otherwise place first the familiar track most similar to it.
             Autoplay and stations need no bridge slot: every candidate there comes from the radio of an anchor the listener just heard.
             Mixes (stage 2) before embeddings exist: a RADIO candidate is bridged by the library seed whose radio produced it.
coherence    on stations and autoplay a familiar slot with no candidate passing the similarity floor is given to a novel candidate:
             staying on topic beats the familiar quota.
novel arm    section 5.10 (Thompson draw over arms; priors frozen before stage 3)
within slot  value(i) = lambda * z_i - (1 - lambda) * max over chosen j of sim(i, j) + kappa * calibGain(i) - flowCost(i) - servedPen(i)
             lambda = 0.75 inside one island, 0.6 across islands ;  kappa = 0.4 (0 before stage 2)
lanes        z_i and p_i above are the lane's score: the choice score zc / pc (5.7) for a familiar candidate (opener, familiar, bridge,
             closer and liked slots alike), the finish score z / p for a novel one. ListBuilder.Scored.zChoice / pChoice default to z / p.
calibGain(i) = KL(P || Q_without) - KL(P || Q_with_i)
             P(c) = W_c^0.75 normalised over islands, floor 0.03 ;  Q = island mix of the list so far, smoothed 0.99 Q + 0.01 P
flowCost(i)  = 0.15 * max(0, tempoDist(prev, i) - 0.17) + 0.05 * max(0, abs(gainPrev - gain_i) - 4) / 4 ;  unknown values cost 0
tempoDist    = min over k in {0.5, 1, 2} of abs( log2( bpm_a * k / bpm_b ) )
servedPen(i) = 0.4 * min(1, timesServedLast30Days / 3)          (generated lists only)
order key    floor(value * 2^20 + 0.5), descending ;  ties: splitmix64(rid xor seed) ascending, then rid ascending
```
Health targets held by test 5: at least 60% of the tracks a daily mix serves over 30 days are distinct; Jaccard between any two mixes of one day is 0 by the constraint above; novel share within 0.05 of `nu`.

**Reasons.** `WhyLine.pick` returns `(key, args)` from the arm and, from stage 2, the feature with the largest `w_i * x_i` among the features that have a sentence. Keys are in section 8.8.

---

## 7. Endless playback

### 7.1 Autoplay

- **Setting.** "Autoplay" in the queue (the mockup `AndroidQueue` already shows "Autoplay · Taizo picks more after this" [C]). Default on. Off when repeat-all or repeat-one is active. A sleep timer or "stop after this track" is untouched: autoplay only adds tracks, it never restarts playback that a timer stopped.
- **Trigger.** Two or fewer unplayed tracks remain after the current one. Android: `AutoplayController.onTransition`, called from `MusicService.onMediaItemTransition` (`data/service/MusicService.kt:1897` [C]) right after `enforceBlockedArtists(reason)` (`:1907` [C]). **Count with `engine.getFullQueue().size - engine.getCurrentAbsoluteIndex() - 1`, not `player.mediaItemCount`**: after a crossfade the active player can hold only a 200-item window of the queue (`DualPlayerEngine.kt:285`, `:783-800` [C]). iOS: chained onto `PlaybackServices.onUpcomingChanged` (`App/Playback/PlaybackServices.swift:26` [C]), which the prefetcher already owns (`App/Services/YouTube/YouTubeServices.swift:93` [C]); wrap the existing closure, do not replace it.
- **Never at queue end.** On iOS feeding at `queueEnded` breaks gapless and crossfade, because the next item is prepared ahead [R]. On Android the `STATE_ENDED` branch (`MusicService.kt:1831` [C]) is a backstop only (below).
- **Network.** The trigger asks the pool, never the network. The pool is refilled by radio requests that start no earlier than 1.5 s into a track, at most 2 at a time (3.7).
- **Batch.** Five tracks in one queue edit: Android `player.addMediaItems(items)` on the main thread, deferred while `engine.isTransitionRunning()` and released from `addTransitionFinishedListener` (`DualPlayerEngine.kt:745`, `:781` [C]). A re-score of the tail is one `player.replaceMediaItems(from, to, items)` call (already used at `PlaybackStateHolder.kt:1045` [C]), not a remove plus an add, because every timeline change republishes the whole queue to the media session [R].
- **Seed set.** The session's `anchors` (5.5): up to 3 tracks the listener chose and heard, plus engine picks they liked, saved or replayed. If there is none yet, the track that is playing. Tracks the engine picked and the listener merely let play are not seeds; without that rule an hour of autoplay is the radio of a radio of a radio. A single-song tap is a one-song queue today (`PlaybackDispatchStateHolder.kt:438-449` [C]); with autoplay it continues at once.
- **First appended track** is the bridge: a familiar track with `sim >= 0.6` to any of the last 3 completed tracks (in stage 1 that means the same primary artist, 5.3); if none qualifies, the best radio row of the newest anchor.
- **Ownership.** Tracks under the Autoplay divider belong to the engine. Tracks the listener queued are never reordered or removed by it. "Play next" inserts above the divider.
- **Pool.** At least 40 scored candidates held in memory by the controller, built from the radios of the anchors and refilled in the background whenever an anchor changes or the pool drops under 15. Top-up and re-scoring never wait for the network.
- **Backstop.** If the queue ends before the first radio arrived (a one-song queue skipped in its first seconds): the queue shows "Finding more like this" under the divider; when picks land within 10 s and the listener has not pressed pause, they are appended and playback resumes; after 10 s nothing happens and the queue simply ended, as today.
- **Offline, or the YouTube source switched off.** The pool is library-only: tracks by the anchors' primary artists first, then the legacy ranking's picks (`DailyMixManager.personalizedPicks` on Android, `DailyMix.personalizedPicks` on iOS), with the constraints of 6.4. The divider reads "Autoplay · from your library".
- **Cast and Spotify Connect.** Autoplay is off during remote sessions in stage 1. How the Connect resolver treats a track with no Spotify URI was not traced [S2]. The owner should know this covers listening through a Connect speaker.

### 7.2 Playing a track that is not in the library

**iOS** [R, read in code, not run; S1]. A `Song` with id `yt:<videoId>` and `contentUriString` `pixlstream://<videoId>` already goes through the resolver chain with no library row, `PlaybackStore.addToQueue` accepts any `[Song]`, and the queue snapshot restores non-library songs from its own metadata. Plays of such songs are invisible to Home and Stats today because both join on the library snapshot [R]; stage 1 adds the brain's `playable` metadata as a second lookup for Recently Played and Stats.

**Android** [S1: this is the first task of stage 1; build nothing else until one engine track plays end to end].

1. `playable` row in `brain.db`: `synthId = SpotifyRepository.youTubeMusicSyntheticId(videoId)` (the first 22 hex characters of SHA-256 of the video id, `SpotifyRepository.kt:1038-1042` [C]). Using the existing function means that if the listener later saves the track, the normal importer produces the same id.
2. In memory: `Song(id = unifiedSongId(synthId).toString(), contentUriString = "spotify://" + synthId, ...)` with title, artist, album, duration and artwork from the radio row. `MediaItemBuilder.build` already carries that metadata in the item's extras (`utils/MediaItemBuilder.kt:97-104`, `:269-290` [C]).
3. `SpotifyStreamProxy.resolveViaYouTube` (`data/spotify/SpotifyStreamProxy.kt:354-360` [C]) asks `spotifyDao.getMatchedVideoId(id)` first. Add an injected `EphemeralTrackLookup` and use `spotifyDao.getMatchedVideoId(id) ?: ephemeral.videoIdFor(id)` before the on-demand match. `resolveViaSpotiFLAC` returns null when there is no `spotify_songs` row (`:322-323` [C]), so an engine track plays from YouTube audio until it is saved.
4. The service does not drop unknown ids: `resolveMediaItemsWithTrustedArtworkGrants` passes an item through unchanged when the repository has no song for it (`data/service/TrustedMediaItemsResolution.kt:17-25` [C]).
5. **To check in the spike:** every reader that looks the current song up in the `songs` table (player screen, favourite button, lyrics, widgets, Wear, Android Auto, the Stats join), and the Cast file server. Three things the reviewer read and can already answer: (a) the queue UI copes, because `resolveSongFromMediaItem` falls back to building a `Song` from the item's own metadata (`presentation/viewmodel/MediaControllerSyncStateHolder.kt:133-144` [C]); (b) queue restore keeps the item (id, uri and display fields are saved) but drops every extra, so the snapshot change of 4.2 is required, and the `playable` row must still exist for the restored `spotify://<synthId>` uri to resolve; (c) appending while the active player holds a windowed queue is untested: a `PLAYLIST_CHANGED` timeline event makes the engine rebuild its full-queue snapshot from the player with `usesWindowedQueue = false` (`DualPlayerEngine.kt:635-640` [C]), which may cut a 200-plus queue down to the window. Reproduce with a queue of more than 200 items after a crossfade before trusting it [S1].
   **Recently Played.** An engine track's `PlaybackEvent` is written (4.2); the Recently Played and history lists resolve an id that is not in the library through `playable` (title, artist, artwork) and offer "Save". Without this a listener cannot find the song autoplay just played them. Stats joins stay library-only until stage 2.
6. **Fallback if the spike fails:** `spotify_songs` rows under `playlist_id = "brain_pool"` with no `spotify_playlists` row, plus `WHERE playlist_id != 'brain_pool'` in `SpotifyDao.getDistinctSpotifySongsList` (`data/database/SpotifyDao.kt:45-46` [C]) and a review of the seven uses of `getDistinctSpotifySongsList` / `getAllSpotifySongsList` outside the DAO [C]. A query edit does not change the Room schema, so neither path needs a main-database migration.
7. **Saving.** Like, "Add to playlist" and "Save" import the track for good through the existing `importYouTubeMusicTracks` (`SpotifyRepository.kt:997` [C]). Stage 1 narrows its two full rewrites: pass `onlySpotifyIds` to `syncUnifiedLibrarySongsFromSpotify` at `:1020` and `onlyPlaylistId = BROWSE_ID` to `mirrorPlaylistsIntoApp` (`:1213` already has the parameter [C]). The eager import inside `MusicDiscoveryRepository.augment` is retired.

`playable` rows unused for 60 days are deleted, except rows still referenced by the saved queue or by a `PlaybackEvent` of the last 60 days.

### 7.3 What a reaction does, at once

All arithmetic on the in-memory pool. The network only refills the pool.

| Signal | Session effect (section 5.5) | Visible effect |
|---|---|---|
| Skip under 10 s (`h = 1.0`) | `recentNeg`, tag penalties, artist blocked for 10 tracks, `skipRun + 1`; if novel, `nuSession * 0.67` | engine tail re-scored from the second upcoming track; blocked-artist tracks leave the tail |
| Skip at 10-30 s (`h = 0.6`) | same, weaker | same |
| Skip after 30 s, before half (`h = 0.2`) | `recentNeg`, tag penalties | tail re-scored |
| Skip of a track with 3 or more completions | session only, `h` capped at 0.3 | tail re-scored; long-term affinity nearly untouched (4.3) |
| Second skip in a row | - | the next engine pick must be familiar with `sim >= 0.5` to `lastCompleted` (stage 1: the same primary artist), highest `p` first; if there is none, the best-ranked row of the newest anchor's radio. (The first version also required `p >= 0.7`; with hand-set weights that threshold means nothing yet, so it is dropped until stage 3.) |
| Third skip in a row | re-seed: stage 1, the next anchor of the session, and if there is none the listener's highest-affinity library artist outside the skipped artists; stage 2, the next island by `W_c * exp(lift)`; in a station, back to the original seed | queue note: "Skipped three. Changing direction." |
| Completion | `recentPos`, `skipRun = 0`, tag penalties `* 0.7`, blocks count down | - |
| Like or save | as a completion, pushed twice; one track by the same artist or its nearest neighbour is scheduled within the next 5; if novel, `nuSession * 1.25` | next batch shows "Because you liked *X*" |
| Replay or seek back to the start | as a like; the track is not re-queued | same |
| "Not for me" | hard exclusion (5.11) + `h = 1.0` skip | skips now; snackbar with Undo |
| Familiar / Blend / Discover | `nu` multiplier 0.4 / 1 / 2 | tail rebuilt |

D8 applies: the track that starts because of a skip is never replaced, and neither is any track the prefetcher has warmed (2.3, step 7). In stage 1 the tag rows of this table do nothing (no track has tags yet); the artist, similarity and skip-run rows do. Tuning note: if this feels jumpy, lower `h` before touching anything else; one skip must nudge and two must turn [R].

---

## 8. Surfaces

Visual language: the approved mockups in `scratchpad\newui\project` (`Main`, `iOSHome`, `AndroidQueue`, `AndroidPlayerMenu`, `AndroidAskTaizo`, `AndroidSearch`): split-pill navigation, large expressive type, full-bleed blurred heroes. Android is Material 3 Expressive; iOS is Liquid Glass. Under the port rule the Android screen is built first and iOS reproduces it [R]. Each surface below names the stage it ships in.

**Copy rule.** No user-visible string may contain: lossless, hi-res, Dolby, Atmos, 360 Reality, Claude, Anthropic, BiniLyrics, Enhanced. The examples below comply. Until stage 3 no string says "learns" or "learning"; use "based on what you play".

### 8.1 Home

**Stage 1 (existing layout, one new kind of row).**

| Row | Content rule | Refresh | Copy |
|---|---|---|---|
| Because you listened to *X* (at most two rows, for the two newest anchors by different artists) | X = an anchor (5.5) of a session that ended in the last 7 days, read back from `play_event` (the in-memory session is gone by then): a live event on a listener-picked surface with `r >= 0.8`, or an engine pick with a liked, saved or replayed flag. Never a track that merely played through on autoplay. The row is X's cached radio, filtered (6.1) and scored (5.7): 12 cards, up to 9 novel, at most 2 per artist | built when a session ends, from radios the autoplay pool already fetched; if X's radio is not cached it is fetched after Home's first frame, and the row appears on the next visit | "Because you listened to Espresso" |
| Daily Mix, Your Mix, every other shelf | unchanged (legacy) | as today | unchanged |

The row replaces the legacy "Beyond your library" shelf and its text search; `MusicDiscoveryRepository.augment`'s eager import (the library-pollution bug [R]) is switched off in the same change. "New from artists you enjoy" stays as it is until stage 2 replaces it with section 6.3. The row is appended next to the legacy planner's output; on Android `HomeDiscoveryShelf` renders any list of sections with per-song reasons [R]. iOS: append to the shelves that `HomeStore` publishes (`App/Features/Home/HomeStore.swift:497-503` [C]) [S1: confirm `HomeSections` renders appended sections]. Tapping a card plays it with the row as the queue; autoplay continues from there. A new listener sees no brain row until their first session ends.

**Stage 2 (the full design).** The frame from `iOSHome`: date line ("Friday night"), greeting, chips `For you · Mixes · Spatial · New`.

| Slot | Row | Content | Refresh |
|---|---|---|---|
| 1 | Hero, full-bleed blurred art | one pick: a Daily Mix, First Listen on Mondays, a new release from a top-5 artist; from stage 3 also the daypart mix | at daypart boundary |
| 2 | Ask Taizo pill | a prompt built from the listener's own data: "Something like Espresso, but slower" | daily |
| 3 | Jump back in, 2 x 3 tiles | the last 6 distinct contexts played (playlist, album, mix, station), not songs | live, local |
| 4+ | Shelves, at most 7 | below | per shelf |

| Shelf | Rule | Novel share | Refresh | Stage |
|---|---|---|---|---|
| Made for you | Daily Mix 1..K, Your Mix, First Listen, Just Dropped as cards | - | daily | 2 |
| Because you listened to *X* | as stage 1 | 0.75 | session end | 1 |
| New from artists you love | section 6.3 | 1 | daily | 2 |
| On repeat | top by decayed plays, last 30 days | 0 | daily | 2 |
| Rediscover | high affinity, not played in 90 days | 0 | daily | 2 |
| Stations for you | 6 genre or mood stations from the listener's top atlas nodes, plus one adjacent | - | weekly | 2 |
| A step sideways | one adjacent genre the listener has not played; the card says so | 1 | weekly | 2 |
| More like *album* | album station for a recently completed album | 0.75 | session end | 2 |
| Popular where you are | the country chart's Top artists (40, anonymous [L]), re-ranked | 1 | daily | 2 |
| Your *Friday nights* | daypart mix; only after 50 plays in that bucket | 0.15 | daypart boundary | 3 |

**Page rules** (in `HomePlanner`): a track appears once on the page; an artist at most twice per shelf and four times per page; two all-novel shelves are never adjacent; at least one familiar shelf sits in slots 4-6; a shelf with fewer than 6 playable items is hidden, not padded. Shelf order: fixed in stage 2 (the table's order); the cascade bandit of section 5.10 from stage 3, which needs the `impression` table.

**Chips.** "Mixes": every made-for-you list as large cards. "New": Just Dropped, First Listen, new from adjacent artists. "Spatial": unchanged.

**State.** `HomePlan { planVersion, generatedAt, daypart, hero, tiles[6], shelves[{type, titleKey, titleArgs, subtitleKey, items[{songRef, rid, whyKey, whyArgs, arm, recId, slot}]}] }`, saved as `home_plan.json` (under 50 KB) and read on launch before anything else. Home never shows a spinner or an empty state: with no plan it shows Jump back in and the library rows (section 8.10).

**Platform notes.** Android: `HomePlanStateHolder` (a `@Singleton` state holder, per the repo convention) replaces the refresh in `HomeDiscoveryStateHolder`, which today reloads and ranks the whole library on every Home start [R]. New section models must be immutable collections and be added to `app/compose_stability.conf`, which does not list `data.recommendation.**` [R]. iOS: `HomeView.task(id:)` has no day component [R]; add the plan's `generatedAt` day so mixes roll over at 04:00 local.

### 8.2 Made-for-you mixes (stage 2)

| Mix | What | Size | Name and subtitle |
|---|---|---|---|
| Daily Mix 1..K | one per taste island | 30 | "Daily Mix 1" · "Soft pop & R&B · Sabrina Carpenter, Chappell Roan" |
| Your Mix | endless station across all islands | endless | "Your Mix" |
| First Listen | weekly; only music never played here | 30 | "First Listen · week of 16 Nov" |
| Just Dropped | new releases | up to 30 | "Just Dropped" |
| On Repeat | what the listener plays now | 30 | "On Repeat" |
| Rediscover | loved, then forgotten | 30 | "Rediscover" |
| Daypart mix (stage 3) | the island that fits now | 25 | "Friday Night" |

- **Names** are deterministic: an island's subtitle is its two tags with the highest lift over the listener's average, by atlas name. An assistant-written name is an optional overlay cached per island (stage 4).
- **First Listen** is built Monday 04:00 local and fixed all week; last week's stays reachable for 7 days, with liked tracks marked.
- **Refresh.** Daily mixes rebuild on the first open after 04:00 local. "Regenerate" draws a new seed and counts against the served log.
- **State.** `Mix { id, kind, islandId?, titleKey, titleArgs, subtitle, builtAt, seed, items[...as HomePlan items] }`.
- The two saved-id lists `daily_mix_song_ids` / `your_mix_song_ids` restore by id and silently drop ids that are not in the library [R]; stage 2 stores mixes as `served_list` rows instead and keeps writing the two legacy keys with the library-only subset.

### 8.3 Stations (stage 1 for song and artist; stage 2 for album, playlist, genre and mood)

- **Entry.** "Start station" in every song and artist menu in stage 1 (add to the `AndroidPlayerMenu` list), in album and playlist menus from stage 2, and "Play station" on genre pages. In stage 2 the Search "Browse" tiles (Pop, Hip-hop, Chill, Workout in `AndroidSearch` [C]) become stations; today they run a text search [R].
- **Start.** The first track plays at once: the seed itself. For an artist: the listener's most-played library track by that artist; if they have none, the `videoId` of the artist page's `startRadioButton` endpoint, which costs one `browse` (about 0.45 s [V]) before sound. One `next` call (0.67-1.06 s on 6 seeds [V]) fills the rest; 8 s timeout, one retry on empty. An artist the library knows only by name needs its channel id first: take it from any cached radio row by that artist, else from the songs search the app already has (the artist run of the first hit carries the `browseId` [L]).
- **Queue header.** "Station · Espresso" with the three-stop control Familiar / Blend / Discover.
- **Recents.** A station is a context: it appears in Jump back in (stage 2, with the new Home).
- **State.** `Station { seedRef, seedKind, title, nuSwitch, pool[], served[] }`, held by `StationStateHolder` / the iOS equivalent; the queue itself holds the tracks.

### 8.4 Queue (stage 1)

```
NOW PLAYING    Espresso · Sabrina Carpenter
Up next from Daily Mix 1 · 6 songs
  ...
Autoplay · Taizo picks more after this                [on]
  Hikari · Clovis Reyes          Fans of d4vd also play this
  E85 · Don Toliver              Because you liked Woman
  ...                                                 [Refresh picks]
```
Each engine row carries its why-line. Swipe removes it (a weak negative, `h = 0.2`); long-press offers "Not for me". State: `QueueUi { userItems[], engineItems[{songRef, whyKey, whyArgs, arm}], autoplayOn, station?, sessionNoteKey? }`. Android: the divider is a row in the existing queue list keyed off the `brain.arm` extra. iOS: `App/Features/Queue/QueueSheet.swift`.

### 8.5 Feedback controls (stage 1: Like, Not for me, Less of this artist; stage 2: the rest)

In the player menu and on long-press of any song.

| Control | Long-term effect | Shown at once |
|---|---|---|
| Like | favourite; Spotify Liked Songs count as favourites too (section 4.4) | heart fills; tail re-scores |
| Not for me | the song is muted (a `TasteAdjustments` mute); half-strength negative on its primary artist and tags | skips now. "Got it. You won't hear this in mixes again." · Undo · "Less from Doja Cat" |
| Less of this artist / genre | existing reduce levels; a second tap offers mute | matching tracks leave the engine tail now and Home at the next replan |
| More like this | boost | the next batch leans that way |
| Don't learn from this | the song, album, playlist or the last hour is flagged `learnExcluded` | "This won't shape your picks." Listed under Your sound |
| Private session | events are logged with `learnExcluded` until switched off | a "Private" pill in the player |

"More like this", the genre controls, "Don't learn from this" and Private session wait for stage 2: they need tags, `Affinity.subtract` and the `feedback` table, and until the ranker learns (stage 3) excluding a play changes very little. The `learnExcluded` flag is in the event record from stage 1 so nothing has to be migrated.

Every change lands in the existing Taste changes screen (`presentation/screens/TasteChangesScreen.kt` [C], `App/Features/Taste/TasteChangesView.swift` [C]) and can be undone there. The genre controls appear only for tracks that have a tag vector.

### 8.6 Your sound (stage 3)

Reached from Home's avatar and from Settings. One scroll under a hero tinted by the top island's artwork.

1. **Right now.** Islands as large shapes sized by share of the last 28 days: "Soft pop & R&B 41%". Tap: top artists and songs, Play station, More / Less.
2. **Genres.** Top families as bars; tap to open sub-genres along the atlas tree; tap a genre for its page.
3. **Eras.** A decade histogram. Hidden until `firstYear` is known for 60% of plays.
4. **Through the day.** Four dayparts, each with its leading island: "Mornings are quieter: mostly acoustic."
5. **Over months.** Stacked island shares per month, up to 24 months; imported history fills it on day one.
6. **New and familiar.** The Familiar / Blend / Discover switch with the measured fact: "Last week 22% of what you played was new to you."
7. **How well I know you.** "Learning from 4,212 plays. I call your skips right 68% of the time, up from 61% a month ago." The figure is the prequential accuracy of the learned ranker on rows with `r = 1` or `r <= 0.1`, next to the same figure for the frozen prior. Below 300 events, or when `useLearnedWeights` is off: "Still getting to know you" with a count, or "Your picks use the standard recipe for now."
8. **Lately.** The five largest affinity moves in 14 days: "Up: bedroom pop, HIEUTHUHAI. Down: EDM."
9. **Controls.** Taste changes, blocked artists, the "Not learning from" list, Private session, "Reset what I've learned" (events kept, exclusions and adjustments kept, state rebuilt from `M0`), "Export my data".
10. **Footer.** "All of this is worked out on your phone."

Energy and mood sections appear only when tempo and loudness cover 60% of plays; otherwise they are absent. **State.** `YourSound { islands[{id, name, share, topArtists, topTracks}], genreTree, decades?, dayparts[4], monthly[{month, shares}], novelty{switch, measured}, model{events, accNow, accBefore, accPrior}?, recentMoves, exclusions }`, computed in the background, cached as `your_sound.json`, recomputed at most once per session end.

### 8.7 Genre pages (stage 3)

Rebuild `presentation/screens/GenreDetailScreen.kt` and `App/Features/Detail/GenreDetailView.swift` (both exist [C]). Reached from Your sound, from genre chips on artist and album pages, and from Search.

- **Hero:** the name in large type over blurred art from its key artists; one line of origin, "Seoul · 1990s", from the atlas `reg` and `era`.
- **What it is:** the atlas description, for the roughly 200 described genres; other genres show facts only. No assistant call at run time.
- **Family:** "Comes from" (parents), "Branches" (children), "Close to" (related), "Shaped by" (influences). All tappable.
- **Key artists:** artists in the listener's graph with the highest tag weight for the node, then "From your library".
- **You and this genre:** first played, share of listening, top 5 tracks. Hidden if never played.
- **Actions:** Play station · More of this · Less of this.

**State.** `GenrePage { node, description?, parents, children, related, influences, keyArtists, libraryArtists, userStats?, stationSeed }`.

### 8.8 Why this song (stage 1 for arm reasons; stage 2 for feature reasons)

One line under the title when the track came from the engine, on queue rows and on shelf cards. The key comes from the arm, refined by the feature with the largest contribution, so the line is a true statement about the decision.

| Key | Line | Source |
|---|---|---|
| `radio_fans` | "Fans of d4vd also play this" | RADIO; the arg is the seed's artist |
| `because_liked` | "Because you liked Woman" | scheduled after a like |
| `because_listened` | "Because you listened to Espresso" | the Home row |
| `artist_aff` | "You play a lot of Chappell Roan" | feature 2 |
| `artist_more` | "More from Chappell Roan" | ARTIST |
| `similar_artist` | "Close to The Weeknd" | SIM |
| `new_release` | "New from Sơn Tùng M-TP" | NEW |
| `forgotten` | "You loved this in 2023" | BACK, features 10-16 |
| `on_repeat` | "On repeat this month" | FAV with a high 21-day affinity |
| `adjacent_genre` | "A step sideways from indie pop: bedroom pop" | EDGE |
| `daypart` | "Fits your Friday nights" | feature 29 |
| `explore` | "Trying something new. Tell me if it misses." | exploration slot |
| `asked` | "You asked for a late drive" | ASK, `assistant` surface |

Tapping opens a sheet (`WhyThisSongSheet`): the line; up to two supporting facts ("Bedroom pop · 2024 · you finished 9 of the last 10 like it"); the buttons of 8.5; and a "How picks work" link.

### 8.9 How picks work (stage 1)

A static sheet with the promises of section 1, the autoplay switch, and a link to Taste changes. Stage 3 adds a link to Your sound. **Stage 1 shows promises 1, 3, 4 and 5, and of promise 2 only "a new song you skipped three times stays away for 60 days".** The "never in two mixes on the same day" half is not true of the legacy mixes [R: the audit calls them near-duplicates] and appears with stage 2.

### 8.10 Onboarding and cold start (stage 2; the stage 1 engine degrades to the same fallbacks)

| Case | Minute one | Within a day |
|---|---|---|
| Spotify connected, sizeable library | Home shows Jump back in and the legacy rows from already-synced data, and a strip: "Getting to know your music · 3 of 8". Eight radios for the top artists (at most 2 seeds each) run at 6 in parallel (8 in parallel took 1.1 s in the probe [L]); the mixes and the first "Because you listened to" follow. | enrichment proceeds in the background; islands are named; First Listen is ready by the next Monday |
| Imported history available | as above, plus the import is replayed: affinities, `nu0` and (stage 3) the ranker are trained on day one; Your sound shows months of history | same |
| Thin or empty library | a picker: "Pick three artists you love." The grid is the device country's chart Top artists (40 [L]) plus search (`params` for the artists filter are in the YouTube report, section 8). Three picks give three artist radios, Your Mix and one Daily Mix. | every play teaches; shelves appear as they reach 6 items |

Setup gains one page after Spotify connect: Familiar / Blend / Discover, with an "Import your listening history" link to the existing flow. No questionnaire.

---

## 9. Ask Taizo (stage 4)

### 9.1 Role

The assistant becomes fluent in music by reading the same tables the engine reads, through tools. It is not trained or fine-tuned. It never ranks and never invents a track: it turns a sentence into a structured request and the engine fills it. Because the request is a small structure, the on-device models can produce it too [S4: check against the 4,096-token window of the iOS system model and the roughly 4k budget of the Android on-device path, both [R]].

### 9.2 Knowledge base access

No new store. The tools read `track_dna`, `artist_dna`, the atlas, the graph, the islands, the affinity tables and the context counts through `BrainRepository` / `BrainService`. Results are capped (25 rows by default) and carry ids the next tool call can use.

### 9.3 New tools

Constraints that shape the schemas:
- The existing 16 client tools are a cached prompt prefix mirrored on iOS, and strict schemas share a budget of 24 optional parameters of which 20 are used [R]. **Every parameter below is required**; "no value" is an explicit sentinel (`"any"`, `0`, `[]`), so the new tools are strict (`strict: true`, `additionalProperties: false`) without spending optional parameters.
- New tools are appended after the existing 16 in a fixed order and never reordered. That costs one cache miss on release.
- Tool choice stays automatic; the pinned model family rejects a forced tool choice (the API reference bundled with this environment), so routing is steered by the prompt (9.4).

| Tool | Parameters | Result |
|---|---|---|
| `resolve_tracks` | `items: [{title, artist}]` (max 25) | per item `{ref, title, artist, year, in_library}` or `{not_found: true}`. `ref` is `sp:<id>` or `yt:<videoId>`. Resolution: alias table, then YouTube Music songs search with the existing matcher thresholds. |
| `recommend` | `seed_refs: [ref]`, `genre_ids: [int]`, `year_from: int`, `year_to: int`, `energy: "any"\|"lower"\|"higher"`, `novelty: "any"\|"familiar"\|"new"`, `count: int` (1-50) | ranked `[{ref, title, artist, year, why_key, why_args}]` from the engine (stations pool + arms), filtered |
| `build_mix` | `title: string`, `seed_refs`, `genre_ids`, `mood_ids: [int]`, `year_from`, `year_to`, `energy`, `tempo: "any"\|"slow"\|"mid"\|"fast"`, `novelty_share_pct: int` (0-100), `length: int` (10-60), `exclude_artist_refs: [string]` | `{mix_id, title, tracks: [...]}`; shown as the card in `AndroidAskTaizo` ("Late drive · 30 songs · Play · Save"). Arm `ASK`, surface `assistant`. |
| `start_station` | `seed_ref: string`, `seed_kind: "song"\|"artist"\|"album"\|"playlist"\|"genre"`, `mode: "familiar"\|"blend"\|"discover"` | `{started: true, first_track}` |
| `steer_session` | `change: "more_artist"\|"less_artist"\|"more_genre"\|"less_genre"\|"energy_up"\|"energy_down"\|"more_familiar"\|"more_new"`, `target: string` (ref, genre id, or `""`), `scope: "session"\|"always"` | `{applied, tail_changed: int}`. `scope = "always"` writes a taste adjustment or the novelty switch and goes through the existing confirmation rules. |
| `explain_track` | `ref: string` | `{arm, why_key, why_args, top_factors: [{name, direction}], facts: {genres, year, plays, completion_rate}}`. Factor names come from a fixed list; no raw weights. |
| `explain_taste` | `scope: "summary"\|"islands"\|"genres"\|"dayparts"\|"recent_moves"\|"model"` | the matching part of the Your sound state, including what is unknown |
| `lookup_genre` | `query: string` | `{id, name, description, parents, children, related, influences, region, era, descriptors}` or the 5 nearest names |
| `similar_artists` | `artist: string`, `count: int`, `only_unplayed: bool` | `[{name, ref, score, sources}]` from the graph |
| `new_releases` | `scope: "my_artists"\|"adjacent"\|"country"`, `count: int` | `[{title, artist, type, year, ref}]` |

`play_songs` and its siblings today import a catalogue track into the library to play it [R]; in stage 4 they play engine refs through the `playable` path instead.

**What the listener gets**
- **A mix from a sentence.** "Make me something like Espresso but slower for a late drive" becomes one `build_mix` call. The chips under the card (Less Sabrina · More R&B · Shorter) are deltas on the stored request, applied on the device with no model call.
- **An explanation.** "Why do I keep getting trap?" is answered from `explain_taste` with real numbers and ends with a one-tap "Less trap".
- **Steering.** "Slow it down" calls `steer_session`.
- **Set notes.** A text line in the queue and under the player title, at most one per five tracks, from templates on the device: "Three from your V-pop side, then something new from HIEUTHUHAI." No voice, no per-track model call.
- **A weekly note** on First Listen: two or three sentences, one cloud call a week over evidence rows, with a template fallback.

### 9.4 Prompt additions and batch jobs

Appended to the system prompt after the existing tool guidance (wording to be mirrored on iOS):

```
Music picks come from the listener's own engine, not from memory.
- Never name a track, album or artist as a recommendation unless a tool returned it in this conversation.
  If you think of a song yourself, pass it to resolve_tracks first and drop anything not found.
- To recommend, call recommend or build_mix with structured filters. Do not rank or reorder what they return.
- Genre and mood filters are ids. Get them from lookup_genre; do not guess ids.
- To explain a pick or the listener's taste, call explain_track or explain_taste and report only what they return.
  If a field is listed as unknown, say it is unknown.
- Numbers about the listener come only from tool results.
```
The listener's taste digest stays after the cache breakpoint, as today.

**Batch jobs** (background, cached forever by `(model id, prompt version, input hash)`; all optional and behind the existing monthly budget):

| Job | Shape | Estimated cost, from the methods report [R, token counts good to about 2x] |
|---|---|---|
| Constrained genre and mood tags for tracks no source knows (tag source 10) | 50 tracks per call; structured output whose tag field is an enum of 30 shortlisted atlas ids per track (region and family priors), plus a confidence | about $0.035 per 1,000 tracks on the small model tier, about $0.70 on the model the app pins today |
| Island names and one-line descriptions | one call for all islands, weekly | under one cent |
| ASK-arm suggestions | per island per week: "20 artists this listener likely does not know", then `resolve_tracks`; the bandit shrinks the arm if they are skipped | about one cent a week on the pinned model |
| Weekly note | one call over evidence rows | about one cent |

Which model tier runs these is the owner's call (D18). The built-in key is extractable from the app and the cap is client-side [R]; that is the reason nothing in ranking or autoplay calls a model.

---

## 10. Shared pure-logic contract

### 10.1 Functions both platforms implement identically

Kotlin in `:brain` is normative; Swift in `PixlLibrary/Brain/` is a line-by-line transliteration with the same file names.

| File | Functions |
|---|---|
| `BrainMath` | `ln`, `exp`, `sigmoid`, `log2`, `powNeg(x, d)`, `toQ`, `fromQ` |
| `BrainHash` | `fnv1a64(bytes)`, `splitmix64(state)`, `uniform(state)`, `gaussian12(state)` |
| `BrainText` | `fold(s)`, `cleanTitle(s) -> (title, versionFlags)` |
| `Ids` | `mint(key)`, `resolve(keys)`, `merge(a, b)` |
| `PlayEvent`, `Snapshot` | canonical encode / decode |
| `Reward` | `grade(event, ctx) -> (r, c)` |
| `Affinity` | `touch`, `apply`, `subtract`, `aff`, `share` |
| `Tags` | `merge(sourceTags, atlas) -> [TagW]`, `tagdot` |
| `GenreAtlas` | `load(bytes)`, `idFor(mbid \| name)`, `ancestors`, `descriptors` |
| `Graph`, `FastRp`, `Ppr` | `addList`, `topEdges`, `embed`, `run` |
| `Similarity` | `sim(a, b)` |
| `Islands` | `fit(points)`, `match(old, new)` |
| `Session` | `apply(state, event)`, `patchQueue(state, tail, pool)` |
| `Features` | `compute(candidate, state, session, ctx) -> Double[51]` |
| `Ranker` | `predict`, `update`, `dailyForget`, `sampleWeights` |
| `Bandit`, `Novelty`, `Context` | `draw`, `update`, `lift` |
| `Retrieval` | arm pools, `cooc` |
| `ListBuilder` | `build(request, scored) -> [Pick]` |
| `HomePlanner`, `MixPlanner`, `StationPlanner` | `plan(...)` |
| `WhyLine` | `pick(pick) -> (key, args)` |
| `YourSoundBuilder` | `build(state, events) -> YourSound` |
| `Replay`, `Eval` | `rebuild(events, facts, dna, graph) -> BrainState`, `run(...) -> EvalReport` |

The core receives plain values. It never sees `Song`, Room entities, SwiftData models, a clock or a locale.

**Stage 1 implements** `BrainMath`, `BrainHash`, `BrainText`, `Ids`, `PlayEvent`, `Reward`, `Affinity` (without `subtract`), `Graph` (in-memory, radio edges only), `Similarity` (the `adj` branch), `Session`, `Features` (the stage 1 list of 5.8), `Ranker.predict`, `Retrieval` (`cooc`), `ListBuilder` (constraints of 6.4, the slot plan, `lambda`; no calibration, flow or served penalty), `StationPlanner` (which also plans autoplay batches and the Home row), `WhyLine` (arm keys) and `Replay` (affinities only). The rest of the table is stage 2 or 3.

**iOS module boundary.** `PixlNet` and `PixlLibrary` are siblings; neither imports the other (`Packages/PixlCore/Package.swift:8-17` [C]). The parsers live in `PixlNet` and the brain in `PixlLibrary`, so the row types they share (`RadioRow`, `RadioList`, `ArtistRef`) go in `PixlModel/BrainRows.swift`, which both already import.

### 10.2 Hand-rolled maths

`exp`, `ln` and `pow` are not guaranteed bit-identical between `java.lang.Math` and Apple's or Linux's libm; `+ - * /` and `sqrt` are [R]. So:

```
ln(x), x > 0:   split x = m * 2^e using the IEEE bit pattern, with m in [sqrt(2)/2, sqrt(2))
                s = (m - 1) / (m + 1) ;  t = s * s
                ln(x) = e * LN2 + 2 * s * (1 + t*(1/3 + t*(1/5 + t*(1/7 + t*(1/9 + t*(1/11 + t*(1/13 + t*(1/15 + t*(1/17 + t/19)))))))))
exp(x):         x clipped to [-700, 700] ;  k = floor(x * INV_LN2 + 0.5) ;  r = (x - k * LN2_HI) - k * LN2_LO
                exp(r) by a degree-13 Taylor polynomial in Horner form ;  result = poly * 2^k, with 2^k built from exponent bits
sigmoid(x):     x >= 0 ?  1 / (1 + exp(-x))  :  exp(x) / (1 + exp(x))
log2(x):        ln(x) * INV_LN2
powNeg(x, d):   exp(-d * ln(x))
constants:      given as 64-bit patterns in the source, never as decimal literals
domain:         ln of a value that is not finite or not > 0 returns -700 ;  exp, sigmoid of a non-finite value return 0 ;  nothing here can produce NaN
```
The expression order in the Kotlin source is the definition. `math.jsonl` pins the output bits; an implementation that differs in the last bit fails. No fused multiply-add: Kotlin on the JVM and ART does not contract `a*b+c`; Swift must not call `addingProduct` [R; the golden test is the proof, not this sentence].

### 10.3 Determinism rules

1. Real arithmetic uses only `+ - * /`, `sqrt` and the functions of 10.2.
2. Sums run in a fixed order: dense arrays by index; map keys sorted by Int64 id first. Never accumulate while iterating a hash map.
3. Embeddings are Int8 with exact integer dot products. Persisted counters are Q20 Int64.
4. Order by a quantised key: `floor(score * 2^20 + 0.5)` descending, then `splitmix64(rid xor seed)` ascending, then `rid` ascending. A total order makes sort stability irrelevant.
5. Randomness is SplitMix64 only (`state += 0x9E3779B97F4A7C15`; `z = (z xor (z >>> 30)) * 0xBF58476D1CE4E5B9`; `z = (z xor (z >>> 27)) * 0x94D049BB133111EB`; `z xor (z >>> 31)`; uniform `= (z >>> 11) * 2^-53`), seeded from FNV-1a 64 over UTF-8 bytes of stable ids. `String.hashCode`, `java.util.Random` and Swift `hashValue` are banned; the legacy engine uses the first two [R], which is one reason it is not extended.
6. Text keys go through `BrainText.fold` (section 10.5): a shipped code-point table with ASCII lower-casing, an explicit diacritics table including Vietnamese, `đ` to `d`, punctuation to space. No locale or ICU APIs.
7. Time enters as `nowMs` and `tzOffsetMin`. Local day and daypart come from integer arithmetic.
8. Output of the assistant enters only as stored data keyed by `(model id, prompt version, input hash)`.
9. Parity means "same snapshot and same request give the same bytes". Two devices have different graphs and so different picks.
10. **Hashes are unsigned 64-bit.** Kotlin: `ULong`, or `Long` with `ushr`, `java.lang.Long.remainderUnsigned` and `compareUnsigned`; never `%` or `<` on a hash held in a signed `Long` (the remainder of a negative value is negative, so `h mod 6` and `mod 10` would differ from Swift's `UInt64`). Swift: `UInt64` with the wrapping operators `&+` and `&*`; plain `+` and `*` trap on overflow. A hash becomes an id by reinterpreting the bits as Int64. Tie-break comparisons on `splitmix64(...)` are unsigned.
11. **Double to integer.** Before every conversion the value is checked finite and clipped to `[-2^52, 2^52]`. Kotlin's `toLong()` saturates and turns NaN into 0; Swift's `Int64(_:)` traps. `floor` and `sqrt` from the platform are allowed (both are exact); nothing else from a maths library is.
12. **Integer division.** Local day, week and daypart use an explicit `floorDiv` / `floorMod` helper, because `/` and `%` truncate toward zero in both languages and times before 1970 or negative offsets would land in the wrong bucket. `localDay = floorDiv(ms + tzOffsetMin * 60_000, 86_400_000)`; the "day" of a daily list starts at 04:00 local: `floorDiv(ms + tzOffsetMin * 60_000 - 14_400_000, 86_400_000)`.
13. **Strings are never compared or ordered as strings.** Swift's `==` and `<` work on canonical equivalence and Kotlin's on UTF-16 units, so they disagree on unnormalised text. The core handles text only as Unicode scalar values (Kotlin `codePoints()`, Swift `unicodeScalars`) on the way into `fold`, and afterwards as UTF-8 bytes or their `fnv1a64`. Lists are ordered by ids, never by names.
14. `uniform(state)` advances the SplitMix64 state once. `gaussian12(state) = (sum of 12 successive uniforms) - 6`.
15. Shipped tables (`fold-v1`, `title-rules-v1`) are compiled in as generated source in both languages, produced by the `generateGolden` task from the reviewed `.tsv` files. Nothing in the core opens a resource at run time (that avoids depending on Java-resource packaging in the APK, and PixlCore targets declare no resources).
16. No regular expressions in the core: `java.util.regex` and Swift `Regex` differ in Unicode classes and case folding.

### 10.4 Golden vectors

- **Generated** by `./gradlew :brain:generateGolden` (a JVM-only task; no Android build) into `brain/src/test/resources/brain-golden/`, with `MANIFEST.sha256` and `SPEC_VERSION`. `BrainGoldenTest` asserts that regeneration equals the checked-in files.
- **Copied** to `Packages/PixlCore/Tests/PixlLibraryTests/Fixtures/brain/` (the test target already copies `Fixtures` [C]). `brainMatchesAndroid` in `GoldenVectorTests.swift` asserts equality and the manifest hash, next to the existing `recommendationMatchesAndroid` (`:167` [C]). The fixtures' own rule holds: regenerate, never hand-edit [R].
- **Format.** JSON Lines, one case per line: `{"fn": <case kind>, "in": {...}, "out": {...}}`, the shape the existing fixtures use [R]. Doubles are 16-hex-digit bit patterns; Int64 values are decimal strings; arrays are in canonical order.

| File | Covers | Stage |
|---|---|---|
| `math.jsonl` | 2,000 inputs each for `ln`, `exp`, `sigmoid`, `log2`, `powNeg` | 1 |
| `hash.jsonl`, `fold.jsonl`, `title.jsonl` | FNV, SplitMix64, `gaussian12`; 1,000 names including Vietnamese, Korean and Japanese; 300 titles | 1 |
| `ids.jsonl` | key sequences to rids: the four steps of `resolve`, the duration rejection, merges, a forced hash collision | 1 |
| `reward.jsonl` | 300 events to `(r, c)` | 1 |
| `affinity.jsonl` | counter traces with decay, late events, a clock jump, pseudo-counts (subtraction added in stage 2) | 1 |
| `session.jsonl` | skip and completion sequences to queue patches | 1 |
| `retrieval.jsonl`, `lists.jsonl` | snapshot + request to ordered rids, quantised scores and reason keys, per surface | 1, extended each stage |
| `tags.jsonl` | source tags to merged vectors through the atlas | 2 |
| `fastrp.jsonl`, `ppr.jsonl`, `islands.jsonl` | a 200-node graph to embeddings, PageRank lists, islands and matching | 2 |
| `homeplan.jsonl` | snapshot to plan | 2 |
| `ekf.jsonl` | 1,000 updates to `m`, `q` bit patterns; daily forgetting; Thompson samples | 3 |
| `replay.jsonl` | three synthetic listeners of 5,000 events each to the final state hash and the evaluation report | 3 |

- **Parser fixtures** are separate: saved responses (from `music-brain\yt\raw` and `music-brain\probe`, trimmed) with the expected parsed rows as JSON, used by both platforms' parser tests. Parsers are not part of the bit-parity contract, but both must produce the same rows from the same file.
- **Purity test.** One test per repo scans the brain sources and fails on a banned import or call (`kotlin.math.ln/exp/pow`, `java.util.Random`, `hashCode()`, `Foundation` `log/exp/pow`, `hashValue`, `Date()`, `Locale`).
- The synthetic comparison of the learner against a batch refit (`methods-probe\ekf_check.py`) becomes a unit test in `:brain`.

### 10.5 Text rules

**`BrainText.fold(s)`**, one pass over Unicode scalar values:
1. Map each scalar through `fold-v1`:
   - ASCII `A-Z` to `a-z`; ASCII letters and digits unchanged; every other ASCII character to a space.
   - Combining marks U+0300..U+036F: deleted (this is what folds decomposed Vietnamese).
   - Every precomposed Latin letter in U+00C0..U+024F and U+1E00..U+1EFF to its base ASCII letter or letters, both cases (`đ`, `Đ` to `d`; `ß` to `ss`; `æ` to `ae`; `ø` to `o`; `ł` to `l`). The table lists each one explicitly; about 700 rows.
   - Greek and Cyrillic capitals to their small letters (explicit rows).
   - General punctuation U+2000..U+206F, CJK punctuation U+3000..U+303F: a space. Full-width ASCII U+FF01..U+FF5E: its ASCII counterpart, then the ASCII rule.
   - A lone surrogate (Kotlin only) and U+FFFD: a space.
   - Everything else (Hangul, kana, CJK, Thai, ...) unchanged.
2. Collapse runs of spaces to one; trim.

Not handled: Hangul that arrives as decomposed jamo [S1: check one Korean title from each source].

**`BrainText.cleanTitle(raw) -> (title, versionFlags)`**:
1. Cut `raw` into segments before folding: each `( ... )` and `[ ... ]` group (also the full-width forms), and the text after the last `" - "` (hyphen, en dash or em dash with a space on both sides). What is left is the head.
2. Fold each segment into tokens and test it against `title-rules-v1`, first match wins:
   - **flag rules** (the segment is dropped and the flag set) when it contains the token sequence: live: `live`, `concert`, `unplugged`; remix: `remix`, `rmx`, `bootleg`, `mashup`, `rework`, `flip`; acoustic: `acoustic`, `stripped`, `piano version`; instrumental: `instrumental`, `inst`; remaster: `remaster`, `remastered`; cover: `cover`, `tribute`; karaoke: `karaoke`, `backing track`; sped-up: `sped up`, `speed up`, `nightcore`; slowed: `slowed`, `reverb`; re-recorded: `re recorded`, `rerecorded`, or the tokens `s version` (as in "Taylor's Version", "John's Version" [V: seen in a radio]).
   - **neutral rules** (dropped, no flag) when the segment starts with `feat`, `ft`, `featuring`, `with`, `prod`, `from`, or equals one of `radio edit`, `single version`, `album version`, `original mix`, `original version`, `explicit`, `clean`, `mono`, `stereo`, `bonus track`, `deluxe`, `deluxe edition`.
   - otherwise the segment stays in the title ("(Part 2)", "(Interlude)").
3. `title = fold(head + kept segments)`. If that is empty, `title = fold(raw)`.

The lists above are the starting content of `title-rules-v1.tsv` (`flag <tab> token sequence`); `title.jsonl` pins 300 real titles, at least 60 of them Vietnamese, Korean or Japanese. Stage 1 must not ship before the rules are run over the titles of one real library and the output is read by a person [S1].

---

## 11. Evaluation harness (stage 2 for tests 1-5 and 7; stage 3 for test 6)

`Eval.run(events, facts, dna, graph, config) -> EvalReport` is pure and is driven three ways: unit tests on three synthetic listeners; a desktop JVM test over a local, git-ignored export; and on the device from Developer mode ("Measure my recommendations"), in the background, never uploading.

**Protocol.** Prequential replay (predict, record, then update), plus a hold-out of the last 8 weeks (the last 15% of events when history is short). Nothing after the cut may influence state before it. Confidence intervals by resampling sessions.

| # | Test | Target [E] |
|---|---|---|
| 1 | Skip prediction on held-out plays (`r = 1` against `r <= 0.1`) | AUC at least 0.05 above the legacy engine's score used as a predictor, and above the artist-rate baseline; calibration error at most 0.05 over 10 bins |
| 2 | Relistening: which known tracks get a completed play in the next 7 days | Recall@50 at least 1.2 x repeat-activation alone |
| 3 | Session continuation from the first 3 tracks of a held-out session | hit@50 at least 2 x a popularity baseline |
| 4 | Discovery: 200 unheard tracks at time T; a hit is a track later completed twice, or an artist later replayed, within 8 weeks | at least 2 x random from the same arms. An upper bound only: radios fetched today know the future, so candidates released after T are dropped and the number is reported as optimistic |
| 5 | List health over 30 simulated daily builds | distinct-track ratio at least 0.60; no artist above 10% of a list; novel share within 0.05 of `nu`; calibration KL at most 0.15; no track in two mixes of one day |
| 6 | Learned weights against the frozen prior | log-loss better by at least 1% with an interval excluding 0, at 2,000 or more events. Otherwise that listener keeps the prior |
| 7 | Kotlin / Swift parity | byte-identical golden files |

Expect single-listener AUC around 0.62-0.75 [E, the methods report's expectation]; beating the baselines and being calibrated matters more than the absolute number. The harness cannot measure reaction speed or sequencing feel; a small friends panel with the learned-versus-control comparison covers that.

---

## 12. Performance, privacy, failure modes

### 12.1 Budgets

Every figure is a target to measure on a mid-range phone, not a measurement.

| Moment | Budget |
|---|---|
| App start | read `home_plan.json` (under 50 KB) and render. No ranking, no network, no brain state load before the first frame |
| Brain state load | lazy, on a background dispatcher, on first need (autoplay pool, replan); under 150 ms for affinities and islands; embeddings are memory-mapped or read per pool |
| Home replan | background, one thread (Android keeps `Dispatchers.Default.limitedParallelism(1)` [R]; iOS `.utility`), under 150 ms for a 5,000-song library plus 2,000 candidates. Triggers: daypart boundary, session end, feedback, daily refresh. Not on every Home start |
| Score 2,000 candidates | under 30 ms |
| Skip reaction | under 10 ms to re-score a 50-track tail, off the main thread; one queue edit (`replaceMediaItems`), skipped when the order did not change |
| Autoplay top-up | under 30 ms from the in-memory pool |
| Event write | one transaction per track change, off main: the event row plus the 3-8 affinity rows it touched. No blob of the whole state is ever rewritten per play |
| Radio response | 550-565 KB of JSON per radio (35-37 KB on the wire [V]): parsed off the main thread, rows extracted, the tree dropped at once; never stored raw |
| Replay | 100,000 events in under 10 s, background only |
| Memory | DNA, graph and Int8[64] embeddings for 10,000 tracks under 8 MB |
| Network | stage 1: on-demand radios only, about 2 per 10 autoplayed tracks plus one per station start, 35-37 KB each, at most 60 a day. From stage 2: section 3.7; cellular only for lanes 0-1 under a 5 MB daily cap |
| Background | stage 1: none (no worker, no alarm, no BG task). From stage 2: one daily job |

Rules carried over from the repos: batch queue edits; no work competing with the first bytes of the current track (prefetch waits 1.5 s [R]); new instrumentation goes through `PerformanceMetrics` and records primitives only [R]; iOS waits 1.5 s after a play before recomputing Home [R].

### 12.2 Privacy

- Events, taste, model and plans exist only on the device (and in the listener's own backup from stage 3).
- Outbound requests carry an artist id, a track id or an ISRC, an app-identifying User-Agent and nothing about the listener. No account, no cookie, no install id. The anonymous YouTube `visitorData` is per process, as today.
- Not sent anywhere: play history, skip data, affinities, the Your sound picture.
- The optional shared catalogue cache (stage 5) would hold public artist-level facts keyed by Spotify artist id, and nothing else.
- The assistant's cloud mode sends the conversation and tool results, as today; tool results are capped and contain taste summaries, not raw history.

### 12.3 Failure modes and offline behaviour

| Failure | Behaviour |
|---|---|
| Offline | Home from the saved plan; mixes from the saved lists; autoplay and stations from library tracks and cached pool tracks; no spinners. Enrichment waits |
| YouTube radio returns nothing, junk, or a new layout | junk detector and fallbacks (3.3); the previous cache is kept; three failed days flip the local flag off until the next app update or remote flag |
| YouTube source switched off | graph from Deezer artist radio and similar-artist edges; stations become artist-based; reasons use `artist_more` / `similar_artist` |
| Deezer quota, MusicBrainz 503, Wikidata 429 | back off per host; the track stays partly known; `source_miss` prevents hammering |
| Deezer or MusicBrainz tag source switched off for terms reasons | tags from Wikidata, Spotify, chips, iTunes and the atlas only |
| No tags for a track | `tags = []`; features 4 and 24 are 0; no genre chip |
| No embeddings yet | `sim` uses the `adj` branch |
| No brain state (first launch, reset, failed rebuild, a rebuild in progress) | the legacy engine serves Home and mixes; autoplay and stations use radio order with the hard constraints (5.8: the score reduces to it) |
| The device clock was wrong | 5.2: events are clamped to now at rebuild; a backward jump of more than 48 h triggers one |
| Non-finite ranker weight | reset to `M0`, schedule a replay (5.12) |
| Learned weights not ahead of the prior | `useLearnedWeights = false` for that listener; said plainly in Your sound |
| Process death mid-session | events are already appended; session state restarts empty; the queue snapshot restores engine items with their `brain.*` fields **once the snapshot change of 4.2 is made** (today it restores no extras at all [C]); the divider is drawn from those fields |
| An engine track fails to resolve audio | skip it silently, mark the audio id bad for 30 minutes (the existing exclusion), pick the next pool track; no reward is recorded (`endReason = error`) |
| Spotify removes another endpoint | only identity and library sync depend on Spotify; candidates, tags and similarity do not |

---

## 13. Files

### 13.1 Android

**Add**

| Path | Content | Stage |
|---|---|---|
| `settings.gradle.kts`: `include(":brain")`; `gradle/libs.versions.toml`: plugin alias `org.jetbrains.kotlin.jvm`; `brain/build.gradle.kts` (Kotlin JVM, stdlib only, JUnit 5, `generateGolden` task); `app/build.gradle.kts`: `implementation(project(":brain"))` | the module | 1 |
| `brain/src/main/kotlin/com/theveloper/pixelplay/brain/`: `BrainMath.kt`, `BrainHash.kt`, `BrainText.kt`, `Ids.kt`, `PlayEvent.kt`, `Reward.kt`, `Affinity.kt`, `Graph.kt`, `Similarity.kt`, `Session.kt`, `Features.kt`, `Ranker.kt`, `Bandit.kt`, `Retrieval.kt`, `ListBuilder.kt`, `MixPlanner.kt`, `StationPlanner.kt`, `WhyLine.kt`, `Snapshot.kt`, `Replay.kt` | core, stage 1 subset | 1 |
| same folder: `GenreAtlas.kt`, `Tags.kt`, `TrackDna.kt`, `FastRp.kt`, `Ppr.kt`, `Islands.kt`, `HomePlanner.kt`, `Eval.kt` | | 2 |
| same folder: `Novelty.kt`, `Context.kt`, `YourSoundBuilder.kt`; learner parts of `Ranker.kt`, `Bandit.kt` | | 3 |
| `brain/tables/fold-v1.tsv`, `title-rules-v1.tsv` (the reviewed sources) and the generated `brain/src/main/kotlin/.../FoldTable.kt`, `TitleRules.kt` (stage 1; rule 15 of 10.3); `app/src/main/assets/genre-atlas-v1.json.gz`, whose bytes the app passes to `GenreAtlas.load` (stage 2) | shipped tables | 1, 2 |
| `brain/src/test/...`: unit tests, `BrainGoldenTest.kt`, `PurityTest.kt`, `brain-golden/*.jsonl` | | 1+ |
| `data/brain/BrainRepository.kt`, `BrainEventRecorder.kt`, `BrainSwitch.kt`, `ImportedPlayAdapter.kt`, `LegacyMigration.kt` (the `playback_history` copy only), `TasteConstraintAdapter.kt` | orchestration | 1 |
| `data/brain/BrainFactsSink.kt` | Spotify artist ids, release dates, explicit | 2 |
| `data/brain/store/MusicBrainDatabase.kt` (+ DAOs, entities; the stage 1 tables of 3.8) | storage | 1 |
| `data/brain/store/PlanCache.kt` | saved plans | 2 |
| `data/brain/source/RadioSource.kt`, `YouTubeRadioSource.kt`, `EphemeralTrackLookup.kt`, `HostBudget.kt` (stage 1: the YouTube bucket only) | sources | 1 |
| `data/brain/source/KnowledgeSource.kt`, `DeezerSource.kt`, `MusicBrainzSource.kt`, `ListenBrainzSource.kt`, `WikidataSource.kt`, `ITunesSource.kt`, `DeezerRadioSource.kt`; `di/` qualifier `@KnowledgeOkHttpClient` | | 2 |
| `data/youtube/InnerTubeMusicParsers.kt`, `InnerTubeMusicModels.kt` | row parsers | 1 |
| `data/service/player/AutoplayPolicy.kt`, `AutoplayController.kt` | | 1 |
| `data/worker/BrainRefreshWorker.kt` | | 2 |
| `presentation/viewmodel/BrainSessionStateHolder.kt`, `StationStateHolder.kt` | | 1 |
| `presentation/viewmodel/HomePlanStateHolder.kt` | | 2 |
| `presentation/viewmodel/YourSoundViewModel.kt` | | 3 |
| `presentation/components/WhyThisSongSheet.kt`, `HowPicksWorkSheet.kt`, `AutoplayDivider.kt` | | 1 |
| `presentation/components/NoveltySwitch.kt` | Familiar / Blend / Discover | 1 (first on the cut list) |
| `presentation/screens/FirstListenScreen.kt`, `ArtistPickerScreen.kt` | | 2 |
| `presentation/screens/YourSoundScreen.kt` | | 3 |
| `data/ai/claude/taizo/TaizoEngineTools.kt` | | 4 |
| `tools/atlas/` (build script and sources list) | | 2 |
| `app/src/test/.../data/youtube/InnerTubeMusicParsersTest.kt` + fixtures; `.../data/service/player/AutoplayPolicyTest.kt`; `.../data/brain/*Test.kt` | | 1 |
| `docs/brain-spec.md` (this document, kept in both repos) | | 1 |

**Change**

| File | Change | Stage |
|---|---|---|
| `data/youtube/InnerTubeClient.kt` | stage 1: add `next`, `nextContinuation`, generic `browse`, and a text-returning sibling of `post` (`:317`). Stage 2: `browseContinuation`, `getQueue`; keep artist and album `browseId` and play count in `parseSearchItem` (`:401`) | 1, 2 |
| `presentation/viewmodel/ListeningStatsTracker.kt` | `PlayContext` on `ActiveSession`; an end reason on every finalisation; call the recorder before the 5 s gate (`:224-230`); skip the counter writes (`:249`, `:293`) for engine tracks without a library row (4.2) | 1 |
| `data/model/PlaybackQueueSnapshot.kt`; `data/service/MusicService.kt` `buildPlaybackSnapshot` (`:2297`), `buildMediaItemFromSnapshot` (`:2459`) | five optional `brain*` fields, saved and restored into the extras (4.2) | 1 |
| the Recently Played and history lists | resolve an id that is not in the library through `playable`; offer Save (7.2) | 1 |
| `presentation/viewmodel/PlaybackDispatchStateHolder.kt` | `brain.*` extras in `buildPlaybackMediaItem` (`:1002`); surface threading from `showAndPlaySong` (`:319`) | 1 |
| `data/service/MusicService.kt` | call `AutoplayController` at `:1907` and in the `STATE_ENDED` branch (`:1831`); pass `PlayContext` and end reasons from `syncLocalListeningStatsFromPlayer` (`:575`) and the finalisation sites (`:587`, `:1832`, `:2073`, `:3238`); nothing else moves into the service | 1 |
| `data/spotify/SpotifyStreamProxy.kt` | ephemeral lookup at `:360` | 1 |
| `data/spotify/SpotifyRepository.kt` | stage 1: narrowed rewrites in `importYouTubeMusicTracks` (`:1020`-`:1021`). Stage 2: facts sink at `:303`, `:474`, `:949`; stop calling the removed `top-tracks` endpoint (`:867` [R]) | 1, 2 |
| `data/network/spotify/SpotifyApiService.kt` | `PLAYLIST_TRACK_FIELDS` (`:206`): add `explicit`, `album(release_date,release_date_precision)`; artist albums `limit` 50 to 10 (`:141` [R]) | 2 |
| `data/DailyMixManager.kt`, `presentation/viewmodel/DailyMixStateHolder.kt` | whole mix from the brain behind `BrainSwitch`, saved with non-library tracks | 2 |
| `presentation/viewmodel/HomeDiscoveryStateHolder.kt` | append the "Because you listened to" sections and stop passing `discoveries` to the planner (stage 1); replaced by `HomePlanStateHolder` (stage 2); drop the `PlusLicenseManager` variant choice (`:124-126` [C]) (stage 2) | 1, 2 |
| `presentation/screens/HomeScreen.kt`, `presentation/components/HomeDiscoverySections.kt` | the new row and its why-lines (1); new layout (2) | 1, 2 |
| `DailyMixScreen.kt`, `YourMixScreen.kt` | non-library rows, why-lines | 2 |
| queue and player-menu composables | divider, why-lines, "Start station" (song, artist), "Not for me" | 1 |
| `presentation/screens/search/components/SearchCategories.kt` | tiles start stations | 2 |
| `presentation/screens/GenreDetailScreen.kt` | rebuilt on the atlas | 3 |
| `data/ai/claude/taizo/TaizoTools.kt`, `TaizoToolExecutor.kt`, `TasteProfileProvider.kt` | append the tools; play through `playable`; profile from the brain | 4 |
| `app/compose_stability.conf` | new UI state packages | 1 |
| `CLAUDE.md` | database version, brain module, the YouTube and knowledge client rule | 1 |

**Retire**

| File | When | How |
|---|---|---|
| `data/recommendation/MusicDiscoveryRepository.kt` | stage 1: its eager import is switched off (it returns its input unchanged). Stage 2: deleted, when the mixes move | the eager import is the library-pollution bug [R] |
| `data/recommendation/HomeCatalogRepository.kt` | stage 1: the "Beyond your library" text search is no longer called; the releases search stays. Stage 2: deleted | `playableSongs`' lazy-import idea lives on in `playable` |
| `data/worker/AiDailyMixWorker.kt` and the `music_intelligence_periodic` job | stage 2 | replaced by `BrainRefreshWorker` (it contains no AI [R]) |
| `data/recommendation/Muselle.kt` (`Muselle2`, the BASIC / PLUS split), `PremiumSmartPlaylistEngine`, `PremiumInsightEngine`, `PremiumFeatureLimits.discoveryCandidates` | stage 2: no longer called from Home. Stage 3: deleted | Plus keeps stems and spatial processing only |
| `data/recommendation/MusicRecommendationEngine.kt`, `HomeRecommendationPlanner.kt`, `DailyMixManager.personalizedPicks`, `RecommendationGoldenEqualityTest` and the Legacy copies | untouched through stage 2 as the fallback; deleted after stage 3's gate (owner question 5) | `MusicRecommendationEngine.record` and `MusicTasteRepository` stay as long as the cloud prepare-ahead rankers read `Signal` [R] |
| `data/recommendation/TasteAdjustments*.kt`, `BlockedArtistsRepository` | never | they are the hard layer (5.11) |

### 13.2 iOS

**Add**

| Path | Content | Stage |
|---|---|---|
| `Packages/PixlCore/Sources/PixlLibrary/Brain/*.swift` | the same file names as `:brain`, including the generated `FoldTable.swift` and `TitleRules.swift` | 1+ |
| `Packages/PixlCore/Sources/PixlLibrary/BrainStore/KeyedLogStore.swift` | file-backed store; outside the purity scan | 1 |
| `Packages/PixlCore/Sources/PixlModel/BrainRows.swift` | `RadioRow`, `RadioList`, `ArtistRef`: the types `PixlNet` parsers produce and `PixlLibrary` consumes (10.1) | 1 |
| the atlas | PixlCore targets declare no resources ([C]: only test targets copy `Fixtures`, `Package.swift:32`), so the two small tables are generated Swift source (above) and the atlas is loaded from the app bundle, its bytes passed into `GenreAtlas.load` | 2 |
| `Packages/PixlCore/Sources/PixlNet/YouTube/InnerTubeRadio.swift` | stage 1: public `next`, continuation, related and artist-page calls and row parsers (`nextBody` and `browseBody` already exist, `InnerTubeRequests.swift:40-59` [C]; note `nextBody` always adds `isAudioOnly: true`, which the radio accepts [L]). Stage 2: discography, album-audio, `get_queue` | 1, 2 |
| `Packages/PixlCore/Sources/PixlNet/Knowledge/DeezerCatalog.swift`, `MusicBrainzCatalog.swift`, `ListenBrainzCatalog.swift`, `WikidataCatalog.swift`, `ITunesCatalog.swift` | | 2 |
| `Packages/PixlCore/Tests/PixlLibraryTests/Fixtures/brain/*.jsonl`, `BrainGoldenTests.swift`, `BrainPurityTests.swift`; `Tests/PixlNetTests/Fixtures/yt-*.json`, `InnerTubeRadioTests.swift` | | 1+ |
| `App/Services/Brain/BrainService.swift`, `BrainStore.swift`, `BrainEventLog.swift`, `CandidatePoolService.swift`, `HostBudget.swift` | | 1 |
| `App/Services/Brain/BrainRefreshTask.swift` (+ the Info.plist task identifier) | | 2 |
| `App/Playback/AutoplayController.swift` | | 1 |
| `App/Features/NowPlaying/WhyThisSongSheet.swift`, `App/Features/Home/HowPicksWorkSheet.swift` | | 1 |
| `App/Features/Taste/YourSoundView.swift`, `YourSoundStore.swift` | | 3 |
| `docs/brain-spec.md`; rows in `docs/parity.md` and `docs/test-parity.md` | | 1 |

**Change**

| File | Change | Stage |
|---|---|---|
| `App/Playback/ListeningStatsTracker.swift` (`Record`, `:28-37`), `App/Playback/PlaybackServices.swift` (`onRecord` `:174`, `onUpcomingChanged` `:26`) | richer record without the 5 s floor for the brain; chained hooks | 1 |
| `App/Stores/PlaybackStore.swift`, `App/Playback/PlaybackQueue.swift` | play-source tag on queue entries; engine-owned flag | 1 |
| `App/Features/Home/HomeStore.swift` (`:497-503`), `HomeSections.swift`, `HomeView.swift` | the "Because you listened to" row; Recently Played resolves non-library ids through `playable` (1); saved plan and new layout, day component in the refresh key (2) | 1, 2 |
| `App/Features/Queue/QueueSheet.swift`, `App/Features/NowPlaying/PlayerMoreMenu.swift` | divider, why-lines, "Start station", "Not for me" | 1 |
| `App/Features/Mixes/MixScreens.swift` | new music in mixes | 2 |
| `App/Features/Detail/GenreDetailView.swift` | rebuilt on the atlas | 3 |
| Spotify sync (`SpotifyAPI.playlistTrackFields`, `SpotifyLibrarySync.fetchArtistGenres` [R]) | facts to the brain side store; keep every genre | 2 |
| `Packages/PixlCore/Sources/PixlNet/Claude/TaizoAssistant.swift`, `App/Services/AI/Claude/TaizoToolbox.swift` | tools | 4 |
| `Packages/PixlCore/Sources/PixlBackup/` | a `brain` module (events, feedback, snapshot) | 3 |

**Retire.** `Packages/PixlCore/Sources/PixlLibrary/Recommendation.swift` (`MusicRecommendationEngine`, `Muselle`, `Muselle2`, `DailyMix`, `HomeRecommendationPlanner`) and `recommendation-golden.jsonl`: untouched through stage 2, deleted with the Android originals after stage 3. `PremiumSmartPlaylistEngine` / `PremiumInsightEngine` in `SmartPlaylists.swift` are unused by the app [R]: deleted in stage 3. There is no paid tier on iOS to change [R]. The unused `AISettings.musicDiscoveryEnabled` becomes the autoplay-and-discovery switch.

Only PixlCore compiles on the Windows machine; nothing under `App/` is type-checked before CI [R]. Keep `App/` changes thin and put every decision in PixlCore.

---

## 14. Staged plan

Each stage ships on both platforms, Android first and iOS as the port, with its golden files. Each stage leaves the app fully working if the next never ships.

### Stage 1: "It keeps playing, and it listens"

What the listener gets: music never stops at the end of a queue; a station from any song or artist; one Home row of music they do not have yet; skips that visibly change what comes next; a "Not for me" that sticks; a reason on every pick. What the project gets: the event log, with full context and the fast skips, recording from this release on. Every later stage trains on it.

Not in stage 1 (moved to stage 2 on review; see section 16): new music inside Daily Mix and Your Mix, the New releases row, album and playlist stations, the background worker and every enrichment source, chips as tags, the Spotify facts sink, "More like this", "Don't learn from this", Private session, the served log.

**Build order.** Three milestones; each leaves a shippable app, so a pass that runs out of time ships what is finished.

**1a. A track from outside the library plays, and the queue does not end.**
1. **Spike (Android):** play one track that is not in the library through the `playable` path (7.2), including a restart with it in the saved queue, and an append onto a windowed queue (7.2, point 5c). Nothing else starts until this works or the fallback is chosen. iOS: play one `yt:` song that was never imported, end to end.
2. InnerTube `next` (song radio), continuation, the Related tab, the artist page and artist radio; parsers with fixtures cut from `music-brain\yt\raw`; the junk detector; rows deduplicated across pages.
3. `brain.db` / the iOS record files with the stage 1 tables of 3.8; `Ids` with `fold` and `cleanTitle`; `playable`.
4. `AutoplayController` with the queue divider, the trigger on the full-queue count, the 1.5 s settle rule, the backstop, the library-only fallback. Picks are in **radio order** under the hard constraints of 6.4 and the filters of 6.1: no scorer yet.
5. The queue-snapshot fields (4.2); Recently Played resolving non-library tracks; Like and Save importing an engine track for good (7.2, point 7).

**1b. It listens.**
6. The event recorder: `PlayContext`, start and end reasons, the `brain.*` extras through dispatch, sub-five-second skips, the legacy counter writes skipped for engine tracks.
7. The pure core of 10.1's stage 1 list, with prior weights `M0`, in both languages with the stage 1 golden files.
8. The one-shot background migration: the `playback_history` copy and the imported-history adapter (4.4, steps 1, 2 and 4).
9. The session reactions of 7.3 (artist, similarity and skip-run rows), anchors, the tail re-score as one queue edit.

**1c. It shows.**
10. "Start station" from a song and from an artist, with the station queue header.
11. The "Because you listened to *X*" Home row; the legacy "Beyond your library" search and `MusicDiscoveryRepository`'s eager import switched off.
12. "Not for me" with Undo; the why-line (arm keys) on queue rows and cards; "How picks work".
13. Familiar / Blend / Discover on the queue header.

**If the pass runs long, cut from the bottom:** item 13, then the artist station (keep the song station), then the second Home row. Do not cut 1b: an app that ships 1a and 1c without the recorder delays every later stage by however long it stays out.

**Tests.** Golden files marked stage 1 in 10.4, green in `:brain` and in PixlCore on Windows and in the Linux CI job; parser fixture tests on both platforms; `AutoplayPolicyTest` (trigger count on a windowed queue, no top-up under repeat, deferral during a transition); recorder tests (the reason table of 4.2, a 2-second skip, an engine track leaving the legacy counters alone); migration tests (idempotent, late events, a clock jump); the purity test; the existing `RecommendationGoldenEqualityTest` and `recommendationMatchesAndroid` still pass untouched.

**Done means**
- Tap one song: when it ends, related music keeps playing, with a reason on every engine row. With a one-song queue skipped at once, picks arrive within the backstop window or the queue ends cleanly.
- "Start station" works from a song and from an artist, and its first track starts within the budget of 12.1.
- Skip two engine tracks by one artist: that artist is gone from the tail (except a station's own seed artist, 5.5). Skip three in a row: the queue says it changed direction.
- An hour of untouched autoplay still sounds like where it started: the seed set holds only the listener's own choices.
- Nothing the engine played is in the library, in "Saved from Spotify", in `feedback_v1` or in `song_engagements` until the listener saves it; it is in Recently Played, with Save.
- Kill the app mid-autoplay and reopen: the divider and the reasons are still there, and the next track plays.
- A skip after two seconds appears in `play_event` with `endReason = next`.
- App start does no brain work, and the app schedules no new background job (measured through `PerformanceMetrics`; checked in `dumpsys jobscheduler`).
- With the YouTube source flag off, or offline, autoplay continues from the library without errors.

### Stage 2: "It knows your music"

**Scope.** *Moved here from stage 1:* `BrainRefreshWorker` and background radio seeding (lanes 1-2); new music in Daily Mix and Your Mix with the saved-mix format and non-library rows in the mix screens; the New releases row with the discography, album-audio and `get_queue` calls; album and playlist stations; the Spotify facts sink and field-list changes; chips mapped to tags; `graph_edge`, `served_list`, `feedback`; "More like this", "Don't learn from this" with `Affinity.subtract`, Private session; repeat activation (5.6). *As first planned:* the atlas (build script, asset, loader); knowledge clients and enrichment lanes 3-5; tag vectors; FastRP embeddings; PageRank retrieval; islands; the SIM, BACK and EDGE arms; the brain scorer (still `M0`) replaces the legacy scorer for Home and mixes behind `BrainSwitch` (default `brain`, falling back to `legacy` when no state exists); the new Home with a saved plan and fixed shelf order; Daily Mix 1..K, First Listen, Just Dropped, On Repeat, Rediscover; the served-log repetition budget; genre and mood stations and the Search tiles; cold-start flows; the evaluation harness with tests 1-5 and 7; the Muselle 2 gate removed.

**This stage is now large.** Build it in two halves, each shippable: 2a = everything moved from stage 1 plus the brain scorer behind `BrainSwitch` and Daily Mix / Your Mix with new music (it needs no atlas); 2b = the atlas, the knowledge clients, tags, embeddings, islands, the new Home and the island mixes.

**Before it starts:** measure real DNA coverage on a real library (how many tracks get a tag vector, a year, a popularity) with a throwaway run of the clients on a copy of the phone's database [S2]. If fewer than 60% of plays get tags, add the constrained assistant tagging job from stage 4 to this stage.

**Tests.** Stage 2 golden files; `Eval` on three synthetic listeners in CI; tests 1-5 on at least one real export, run locally; atlas SHA test; client fixture tests.

**Done means**
- Home opens from `home_plan.json` with no visible loading, and shows mixes that are each one recognisable side of the listener's taste, named from real genres.
- No track is in two mixes on one day; over a simulated 30 days a daily mix serves at least 60% distinct tracks.
- Test 1 shows the brain's prior scorer at least 0.05 AUC above the legacy score on the real export; if not, `BrainSwitch` stays `legacy` for Home ranking and the gap is investigated before stage 3.
- A genre station plays; unknown genres are absent, not guessed.

### Stage 3: "It learns, and shows it"

**Scope.** Ranker updates and replay training; `M0` re-fitted on pooled exports from consenting friends (processed locally); the arm bandit and learned novelty appetite; impressions and the shelf bandit; context lift and the daypart mix; the frozen-prior control and the automatic fall-back; Your sound with the accuracy figure; genre pages; the `brain` backup module; test 6; deletion of the legacy engine, `Muselle`, the premium recommendation stubs and their golden files once the gate passes.

**Tests.** `ekf.jsonl`, `replay.jsonl`; the batch-refit comparison as a unit test; test 6 on real exports; a two-week friends panel reading the learned-versus-control completion rates.

**Done means**
- For a listener with 2,000 or more events, held-out log-loss with learned weights beats the prior by at least 1%, or that listener is on the prior and Your sound says so.
- Your sound shows islands, genres, months and the accuracy figure from real data, and "Reset what I've learned" returns the picks to the prior within one rebuild.
- From this stage the UI may say "learning".

### Stage 4: "Taizo is the voice"

**Scope.** The ten tools; sentence-to-mix with steer chips; explanations; set notes; the weekly note; assistant-written island names; the constrained tagging job; the ASK arm. **Tests.** Tool schema tests mirrored on both platforms; a grounding test (every track in a reply came from a tool result); budget accounting. **Done means:** "Make me something like Espresso but slower" returns a playable mix whose every track resolved; "Why this song?" answers from `explain_track`; with no network the on-device model still starts a station from a sentence [S4].

### Stage 5 (optional)

On-device tempo and loudness from decoded audio (flow ordering, the energy section). A shared read-through cache for public artist facts on the existing Worker, no listener data. Autoplay during Cast and Connect sessions.

### 14.6 Things nobody has verified yet

| Item | Stage |
|---|---|
| An engine track playing on Android without a library row; every reader that assumes a `songs` row | 1, first task |
| Appending to the player while it holds a windowed queue (more than 200 items after a crossfade) | 1, in the spike |
| Which transition reason a crossfade hand-over reports to `onMediaItemTransition` | 1 |
| A `kotlin("jvm")` module beside AGP `9.5.0-alpha07` with the configuration cache on (the catalogue has no JVM plugin alias today [C]) | 1 |
| `cleanTitle` and `fold` read over the titles of one real library; decomposed Hangul | 1 |
| Bit-equality of the hand-rolled `exp` / `ln` between the JVM, ART on a phone, and Swift on Windows, Linux and arm64 (argued in 10.2; proved only by `math.jsonl` passing everywhere, which includes an on-device run of the golden test) | 1 |
| iOS `yt:` playback of a never-imported song end to end (read in code only) | 1 |
| Whether Spotify still fills artist `genres` for this client id | 1 |
| YouTube Music radio from a phone on a Vietnamese or European network, and on cellular (all probes were one US IP) | 1 |
| Radio continuation paging and chip ids beyond the 13 seeds probed (the reviewer's 3 extra seeds showed pages that repeat earlier rows) | 1 |
| Every hyperparameter. None of `M0`, the trust factors of 4.3, or the session constants of 5.5 has been run against a real listener; stage 1 ships them behind radio order (an empty state *is* radio order) and stage 2's harness is the first measurement | 2 |
| Phone timings for every budget in 12.1 | 1-2 |
| MusicBrainz genre relationship coverage beyond 35 sampled pages | 2 |
| Real DNA coverage on a real library | 2 |
| How Spotify Connect and Cast handle a track with no Spotify URI | 2 |
| The learner on real listening data; the step clip and curvature floor | 3 |
| ListenBrainz batch sizes above 16 ids; rate limits at scale | 2 |
| The on-device models driving the new tools inside their context windows | 4 |

---

## 15. Questions only the owner can answer

Each has a default; the spec proceeds on the default unless told otherwise.

1. **Spotify's terms forbid using Spotify content to train a model [R].** The learner trains on the app's own play events. Do Liked Songs, top lists, followed artists and an imported Spotify listening export count as "Spotify content"? **Default:** use them (as prior pseudo-counts and as replayed events), with one setting, "Use my Spotify history to shape picks", that removes both at the next rebuild.
2. **Deezer's API terms are non-commercial, and MusicBrainz tag votes are CC BY-NC-SA [R]; the app has a paid Plus tier.** **Default:** use both while the testers are friends and nothing in the brain is paid; each has its own off switch; before charging anyone, ask Deezer and MetaBrainz or switch them off (the engine then runs on YouTube chips, Wikidata, Spotify and the atlas).
3. **The engine leans on YouTube Music's private API** for about 60-80 calls a day per device, on top of playback. **Default:** accept it, keep every call on the device, keep the remote off switch.
4. **Show the real accuracy figure in Your sound?** Some weeks it will go down. **Default:** yes; it is the proof that the learning is real.
5. **Delete the legacy engine after stage 3**, and are the names First Listen, Just Dropped, Rediscover and Your sound, and text-only set notes (no voice), right? **Default:** yes to all.
6. **(Added on review.) Stage 1 no longer puts new music into Daily Mix and Your Mix; stage 2a does.** Stage 1's new music arrives through autoplay, stations and the "Because you listened to" row. If new music inside the mixes matters more to the testers than stations do, swap stage 1 item 10 (stations) with the mixes work of 2a; do not add it on top. **Default:** as written.
7. **(Added on review.) Autoplay is off while playing through Spotify Connect or Cast** until stage 2 traces how a track with no Spotify URI travels. If most listening at home goes through a Connect speaker, stage 1 will be invisible there. **Default:** accept for stage 1 and make it the first task of 2a.

---

## 16. Review changes

A second reader attacked version 1 of this document on 2026-11-17 and edited it. Each row is one change and why. "First version" means the text before this pass (kept as `music-brain\review-probe\SPEC.before-review.md`).

**Feasibility**

| # | Section | Change | Why |
|---|---|---|---|
| R1 | header, 3.3 | New tag [V]; the load-bearing YouTube Music calls were re-run | The design hangs on anonymous song radio. It answered on 6 of 6 seeds at the exact JSON path, 50 rows, 47-50 official audio, also with no `visitorData` at all. Continuation, Related tab, `get_queue`, artist page, artist radio and discography also answered. |
| R2 | 3.3, 6.2 | Continuation pages **repeat earlier rows**; count a page by its new ids; stop a chain after two thin pages; station pool sizes restated | The first version (and the research) said 49 new rows per page and "no repeats". Three seeds gave 28/11/0/35, 49/49/2/49 and 49/49/49/49 new ids. |
| R3 | 3.3 | Artist radio request written out; "Top songs" is 5 rows, not 10 | The first version named the endpoint but not the body; the three `watchEndpoint` values must be sent as received. |
| R4 | 4.2 | The Android recording hook was rewritten: `PlayContext` from the service, an end-reason table, absolute index | The tracker gets a song id and nothing else. It cannot know end reasons, start reasons or extras; only `MusicService` can. The first version said "the tracker calls the recorder with raw facts" as if it had them. |
| R5 | 4.2, 12.3, 13.1 | `PlaybackQueueItemSnapshot` gains five `brain*` fields | The first version claimed the queue snapshot "restores engine items with their extras". It saves no extras at all, so after a restart the divider, the reasons and the surface attribution would be gone. |
| R6 | 4.2, 7.1 | Remaining-track count and index come from the engine's full queue | After a crossfade the active player can hold a 200-item window of the queue; `player.mediaItemCount` is then wrong. |
| R7 | 7.2 | Spike list extended: append onto a windowed queue; what the reviewer could already confirm in code | A `PLAYLIST_CHANGED` event makes the engine rebuild its full-queue snapshot from the windowed player. Untested with appends. |
| R8 | 4.2 | Legacy counter stores are not written for engine tracks without a library row | They are capped at 5,000 songs and feed the cloud prepare-ahead rankers, which cost money. |
| R9 | 7.2, 13 | Recently Played resolves non-library tracks through `playable` on Android too | Otherwise a listener cannot find the song autoplay just played them. The first version had this for iOS only. |
| R10 | 3.1, 10.5 | `rid` resolution and merge rewritten as four numbered steps; the `n:` key carries the identity flags; remaster ignored for identity | The first version made `n:` both a primary key and a thing two rids could share, and never said what happens when a name matches but the length does not. |
| R11 | 10.5 | `fold` and `cleanTitle` specified without regular expressions, with the starting rule lists | The first version said "one shipped rules table" and gave no rules. The two platforms' regex engines differ, so a regex-based rule could not be bit-equal. |
| R12 | 3.1 | Stage 1 joins artists by folded name; the brain never splits `spotify_songs.artist` | It is a `", "`-joined display string. Spotify artist ids help nothing until stage 2 has something to join them to. |
| R13 | 10.1, 13.2 | Shared row types go in `PixlModel` | `PixlNet` (parsers) and `PixlLibrary` (brain) cannot import each other. |
| R14 | 10.3 r.15, 13 | Tables are generated source, not runtime resources | It removes any dependence on Java-resource packaging inside the APK, and PixlCore declares no resources at all. |
| R15 | 3.7 | iOS background task needs an Info.plist identifier; moved to stage 2 | Not mentioned before. |

**Honesty of the learning**

| # | Section | Change | Why |
|---|---|---|---|
| R16 | 4.3 | Reward rules reordered and completed; imports keyed on unknown `playedMs` | "First match wins" with the import rule listed last meant it never fired: a Spotify recently-played row (no `ms_played`) would have been graded as a 0-second skip. Rule 8 divided by an unknown duration. |
| R17 | 4.3 | Imported plays lose the `2^(-ageDays/365)` factor | "Age" was measured from the day the replay ran, so one log gave different state on different days. That contradicts principle 2. Decay in 5.2 already ages them. |
| R18 | 4.3 | Trust flipped: a completed engine pick counts 0.6, a completed own choice 1.0; skips the other way round | The first version trusted engine-surface plays more than the listener's own choices, which lets autoplay teach the engine its own picks. |
| R19 | 3.6, 5.5, 5.12, 7.1, 8.1 | Anchors: only the listener's own choices (or liked, saved, replayed picks) seed radios, pools and Home rows | Without it, an hour of passive autoplay is the radio of a radio of a radio, and the Home row says "Because you listened to" something the app chose. |
| R20 | 5.2 | `apply` defined for late events; clock guards; reads never write; family totals as their own key | `touch` with a negative time gap multiplied counters by more than 1. Imports and a clock set back both produce that. A clock set ahead would have zeroed the state for good. |
| R21 | 4.3 | Plays ended by stop, kill or error under 30 s carry no weight; `prev` 0.3; `seekBack` is 1.5x, not a like; `neverAudible` 0 | Pausing a song after 8 seconds and putting the phone down was graded as a hard skip. Any backward seek was graded as a like. |
| R22 | 5.3 | `sim` renormalised when a tag vector is missing | Stage 1 has no tags, so `0.6 * adj + 0.4 * 0` capped similarity at 0.48 and the 0.5 and 0.6 thresholds in section 7 could never be met. |
| R23 | 5.12 | Frozen-prior gate decided by prequential log-loss on 2,000 events; control sessions only reported | A 1-in-20 control after 500 recommender plays is about 25 plays. |
| R24 | 5.8 | Stage 1's live features listed; "From" corrected for 9, 10, 11, 24, 39, 40 | The table implied 30-odd live features in stage 1. Seventeen are computed and five decide the order. Stage 1 is a modest re-ranking of YouTube Music's radio and the spec now says so. |
| R25 | 5, 5.9 | "Fitted to this listener" corrected for the graph and the affinity tables; daily forgetting bounded | The graph is the crowd's, not the listener's. Affinity is bookkeeping. A clock jump could have applied thousands of forgetting steps. |
| R26 | 4.1 | `eventId` sequence defined; `retrQ`, `radioRank`, `otherAids` added; `migratedAggregate` removed | "counter" was undefined, so the migration could not be idempotent. Stage 3 trains on stage 1's plays and could not have rebuilt features 37-38. Other credited artists were not recoverable in replay. |
| R27 | 4.4 | Counter migration cut; top-artist pseudo-count is the largest range, not the sum | The synthetic aggregate rows needed fields the event record does not have, for plays the history file already holds. |
| R28 | 10.2, 10.3 | Rules 10-16: unsigned hashes, Swift overflow and conversion traps, `floorDiv`, no string comparison, `gaussian12`, no regex; `ln`/`exp` domain | Each is a place where a straight transliteration compiles on both sides and gives different numbers, or crashes on one. Signed `h mod 6` in Kotlin is the clearest: it is negative half the time. |

**The listener**

| # | Section | Change | Why |
|---|---|---|---|
| R29 | 3.8, 5.2, 12.1 | Affinity counters are rows upserted with the event, never a state blob | A listener with a large import has over 10,000 keys; the first version rewrote the whole state every 10 plays. |
| R30 | 2.3, 7.1, 7.3 | Tail re-score is one `replaceMediaItems`, skipped when nothing changed, and never touches a prefetched track | Each timeline change republishes the whole queue; replacing a warmed track throws its bytes away. |
| R31 | 3.7, 7.1, 12.1 | Stage 1 has no background job; radios are fetched on demand, 2 at a time, after the 1.5 s settle | The first version added a daily worker and up to 80 requests a day in stage 1. On-demand is about 2 per 10 autoplayed tracks. |
| R32 | 7.1 | Backstop defined; library-only fallback pool defined; sleep timer untouched | "Append and resume" had no time limit and no state for the listener to see. |
| R33 | 5.5 | A station's seed artist is exempt from the one-skip block | One skip in an artist station would have removed the artist the listener asked for. |
| R34 | 7.3 | The `p >= 0.7` condition removed until stage 3 | With hand-set weights a probability threshold is arbitrary. |
| R35 | 8.9 | "How picks work" shows only promises that are true in stage 1 | "Never in two mixes on one day" is false for the legacy mixes. |
| R36 | 6.1 | "Ignored three times" defined from `play_event`; served-log retention 60 days | The rule needed 60 days of a log that was kept for 30, and "served" was undefined. The unsuitable-title filter is now the version flags, the same on both platforms. |

**Scope**

| # | Section | Change | Why |
|---|---|---|---|
| R37 | 14 | Stage 1 re-cut into milestones 1a, 1b, 1c with a cut order | The first version's stage 1 was the whole core, seven InnerTube calls, a worker, a three-store migration, mixes, two Home rows, four station kinds and six feedback controls, twice. |
| R38 | 6.2, 8.1, 8.2, 13, 14 | New music in Daily Mix / Your Mix moved to stage 2a | It needed background seeding, a new saved-mix format and non-library rows in both mix screens, all rebuilt in stage 2 anyway. |
| R39 | 6.1, 6.3, 8.1, 13, 14 | New releases moved to stage 2 | Four more endpoints, a baseline pass per artist and year-only dates, for a row that hides under 3 items. |
| R40 | 3.6, 3.8 | No persisted graph in stage 1 | `adj` only needs the radio lists already cached for the session. |
| R41 | 8.3, 8.5, 13, 14 | Album and playlist stations, "More like this", "Don't learn from this", Private session moved to stage 2 | None changes what stage 1 plays; the event flag is there from the start. |
| R42 | 14 | Stage 2 split into 2a and 2b | It absorbed what left stage 1. |
| R43 | 14.6, 15 | Six more unverified items; two more owner questions | See there. |

**Not resolved by this review**

1. Nothing was built or run on a phone. The `playable` path, the windowed-queue append and the crossfade transition reason are still read-only findings.
2. Every probe came from one US IP. A Vietnamese or European network, and cellular, are untested.
3. No hyperparameter has met real listening data. Stage 1 hides behind radio order when the state is empty; that is the safety net, not evidence.
4. `title-rules-v1` is a first list. It will mis-clean some Vietnamese and K-pop titles until it has been read over a real library.
5. Bit-parity of the hand-rolled maths is an argument plus a test that does not exist yet. If `math.jsonl` ever fails on one platform there is no designed fallback; this review did not write one.
6. Stage 2 is now the largest stage. Its 2a half is specified to the same depth as before the move; it was not re-attacked.
7. How Spotify Connect and Cast carry a track with no Spotify URI is still untraced, so stage 1 autoplay is silent there.

