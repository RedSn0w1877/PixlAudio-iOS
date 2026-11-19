# Music brain, stage 2b (iOS): running handoff

Branch `music-brain`. The contract is `docs/brain-spec.md` (v1.1), section 14 "Stage 2", half 2b: the atlas, the knowledge
clients, tags, embeddings, islands, the new Home and the island mixes. This file is **milestone 1 of 2b, "it knows what a song
is"**: the port of Android's milestone 1 (its commits `253a107` to `56705d2` and its handoff
`handoff/2026-11-19-music-brain-stage2b.md`): the coverage result, the genre atlas, the five knowledge clients and enrichment
lanes 3 to 5, track DNA and tag vectors, Spotify artist genres, and the Developer screen "Brain data". Embeddings, islands, the
new Home and the island mixes are later milestones, as on Android.

The earlier handoffs are the map of what exists: `docs/handoff/2026-11-17-music-brain-stage1.md` (deviations 1 to 66) and
`docs/handoff/2026-11-18-music-brain-stage2a.md` (67 to 106). This file continues the iOS numbering at **107**. Android's 128 to
151 (its milestone 1) hold here unless a line below says otherwise.

**Nothing below has been run on a phone.** Only `Packages/PixlCore` compiles on the Windows machine; `App/` is compiled by
GitHub CI alone. "Works" means: unit tests pass, the golden files match Android's bit for bit, and the code paths were read
end to end. Every section ends with what is still unverified.

---

## What the listener gets (once checked on a phone)

Nothing new on a screen except one row. Under the hood, once a day (the same one background job as stage 2a, never a second
one), after the YouTube lanes, the app now learns facts about the songs in the library from five open-data sources: genres,
first year, popularity, tempo, loudness. A song nothing could place shows no genre: unknown stays unknown. Nothing reads those
facts yet (no mix, no row, no chip): that is the next milestone.

- Settings › Developer mode › Maintenance › **Brain data**: the atlas (version, genres, families, how many describe how they
  sound), what is known about the listener's songs (a genre, a year, a popularity, an energy and a mood, a tempo; artists
  known and with a genre), each of the five sources with **its own switch**, its requests today of its daily ceiling, when it
  was last asked, how many songs it answered and the terms it is used under, the Spotify line ("n of m top artists came with
  genres") with YouTube Music's requests today, and the last refresh in plain words.

## Where things are

**`Packages/PixlCore/Sources/PixlLibrary/Brain/`** (pure; scanned by `BrainPurityTests`; same names as `:brain`)
`GenreAtlas.swift` (the atlas and its lookups, with a small ordered-JSON reader), `Tags.swift` (the noisy-OR merge of 3.4),
`TrackDna.swift` (year, popularity, energy and valence, moods, the language of a title), and the additions to `Features.swift`
(`Candidate.tags`, `tagAff`, `sessTagPen`, features 4 and 24), `Session.swift` (`tagPen`, `applyTags`), `Affinity.swift`
(`applyTags`).

**`Packages/PixlCore/Sources/PixlLibrary/Knowledge/`** (new; the network is injected)
`KnowledgeModels.swift` (the five hosts with their spacing, daily ceiling and terms; the row types; `Lookup`),
`KnowledgeParsers.swift` (text to rows, never throws), `TrackMatch.swift`, `KnowledgeHttp.swift` (**the one door**:
`GatedKnowledgeHttp` asks the switch before every request and again after the wait, then the ledger, the host's token bucket,
the spacing, the back-off on 429, 502, 503, 504 and iTunes 403; `KnowledgeLedger` keeps the day's requests per host in
`brain_state` `request_ledger_<host>`), `KnowledgeSources.swift` (`DeezerSource`, `MusicBrainzSource`, `ListenBrainzSource`,
`WikidataSource`, `ITunesSource`), `DnaAssembler.swift` (pure: evidence to rows), `DnaEnricher.swift` (the fallback order, the
caches, the negative cache, `CachedAtlasProvider`, `DnaLanes`), `DnaTargets.swift` (who lanes 3 to 5 work on, `DnaSources`),
`BrainData.swift` (`BrainDataReader`, `BrainDataReport`, `BrainDataFormat`: what the screen shows, decided here).

**`Packages/PixlCore/Sources/PixlLibrary/BrainStore/`** `DnaStore.swift` (`DnaRepository`: `track_dna.pbl`, `artist_dna.pbl`,
`source_miss.pbl`), and in `BrainRefresh.swift` lanes 3 to 5 inside `BrainRefreshRunner` (`Stop.time`, `Report.dnaLane3/4/5`,
`RefreshSchedule.parseNote`, the `d<3>+<4>+<5>` part of the note), in `BrainEngineChoice.swift` `BrainRemoteConfig.sourceAllowed`.

**`App/`** `Services/Brain/BrainKnowledge.swift` (the `URLSession` transport with the app's User-Agent, `BrainSourceSwitch`
= the local switch AND the remote one, the atlas read from the bundle with `Gzip`, `BrainKnowledge` which wires it all),
`BrainService.configureKnowledge` and `brainDataReport`, `BrainRemoteFlags.sourceAllowed`, `AppEnvironment` (the `DnaSources`
closures), `Features/Brain/BrainDataView.swift` (the screen, its model and every word), `Resources/genre-atlas-v1.json.gz` (the
asset), the route `.brainData`, the demo screen `brainData`, a row in `DeveloperSettingsSection`, `PreferenceKeys.brainSourceEnabled`,
and `remote/config.json` (`brain.sources.<key>.enabled`, all true).

**`Packages/PixlCore/Tests/PixlLibraryTests/`** `BrainStage2bGoldenTests`, `BrainTagsAndDnaTests`, `KnowledgeSourcesTests`,
`KnowledgeHttpTests`, `DnaAssemblerTests`, `DnaEnricherTests`, `DnaLanesTests`, `DnaStoreTests`, `BrainDataTests`,
`KnowledgeTestSupport`; fixtures `Fixtures/brain/{atlas,tags,dna,tagfeatures}.jsonl`, `genre-atlas-v1.json.gz`, the new
`README.md` and `MANIFEST.sha256`, and the 13 files of `Fixtures/knowledge/`.

## Task 1: the coverage probe (read, not repeated)

The probe measures what the sources know, not what this app does with it, so it cannot differ on iOS. Android's result is in
its `docs/brain-coverage-2b.md` (704 real tracks: a genre for 96.6%, a specific genre for 69.2% and only 27.8% of the
Vietnamese ones, a year for 99.9%, popularity 87.4%, tempo 22.3%; the 60% rule is met, so no assistant tagging job). What iOS
checks instead: the five parsers read the **same 13 fixtures** Android cut from the real services and give the same facts
(`KnowledgeSourcesTests`), and the assembler turns them into the same row (`DnaEnricherTests` repeats Android's expectations:
2019 from MusicBrainz, popularity 984,833 -> 984, tempo 1708, gain -88, R&B from Deezer's album and iTunes). The real-library
run is the Brain data screen on a phone.

## Task 2: the atlas

`Fixtures/brain/genre-atlas-v1.json.gz` and `App/Resources/genre-atlas-v1.json.gz` are the bytes of Android's
`app/src/main/assets/genre-atlas-v1.json.gz` (`git show music-brain:...`), SHA-256
`60d0291897b91ce97ec89ac2ff9d8811c79666ebdd66cdcad389e1ef33970eb4`, pinned by `theAtlasAssetIsTheFileAndroidShips` and, for the
app's copy, `theAppBundlesTheSameBytesAndroidShips`. 2,249 genres, 24 families, 40 moods. The loader (`GenreAtlas.parse(utf8:)`)
is pure; the app reads and gunzips the bundle file (`GenreAtlasAsset.load`, PixlBackup's pure-Swift inflate) on a detached
utility task the first time something asks for a genre: the refresh or the Brain data screen. **Never at launch**, never on the
main thread. Name lookups use the FNV-1a hash of the folded UTF-8 (10.3 rule 13); when two names fold alike the smaller atlas id
wins, and the source tables are read **in the order of the file** (Kotlin's insertion order), which is why the atlas has its own
small reader (`OrderedJson`, deviation 110). The Vietnamese and K-pop corner and the descriptors are Android's, assistant-drafted
and **not yet read by a person** (Android's handoff says so; it holds here).

Unverified: how long the load takes on a phone (on this PC, in a debug build, parse plus the lookups of the golden cases take
about half a second; a phone has not been asked). It is timed into the diagnostics log as `brain_atlas_load`.

## Task 3: the knowledge clients and lanes 3 to 5

Same rules as Android's `KnowledgeHttp`, in this order for every request: the source's local switch and the remote one
(`brain.sources.<key>.enabled`; a missing key is on), the remote-allowed check, the day's ledger (a spent day is a hard stop and
survives a restart), the host's token bucket (the existing `HostBudget`, capacity = the daily ceiling, one token per
24 h / ceiling), the polite spacing from the start of the last request, the switch **again** after the wait (flipping it stops the
very next request), then the request; 429, 502, 503, 504 (and iTunes 403) and a transport that failed back the host off
exponentially with jitter, honouring Retry-After. A reply of `nil` means "not asked": nothing is recorded and the next run tries
again. Per host: Deezer 200 ms and 600 a day, MusicBrainz 1.1 s and 200, ListenBrainz 1 s and 150, Wikidata 6 s and 3, iTunes
3.5 s and 60. The order per track, the negative cache (14 days doubling to 120), the TTLs (tags 90 days, popularity 7, ids, year
and tempo never), the batches (16 recordings to ListenBrainz, up to 100 artists to Wikidata) are `DnaEnricher`, a line-for-line
port. The lanes are inside the one `BrainRefreshRunner` (3: the most played without DNA, 4: the rest of the library, 5: expired
rows), after the YouTube lanes, never a second job; the same off switches, never while music plays, 16 tracks a round, at most
10, 10 and 4 rounds, **at most 8 minutes** (`Stop.time`; a `BGProcessingTask` gets about ten), and a round that saved nothing
ends the lane. They spend no YouTube request: a day with no YouTube requests left still enriches (the run then reports
`budget`). The refresh runs from the system's `BGProcessingTask` and from the foreground after 90 s idle, both through
`BrainService.runRefresh`, so the lanes run in both.

### Terms and off switches (the owner decision, default; also in Android's handoff)

Every source has its own off switch (Settings › Developer mode › Brain data, default on) and a remote one
(`brain.sources.<key>.enabled` in the saved remote config; `remote/config.json` lists all five as `true`). Used at run time
only; the atlas is the only thing bundled, and it is CC0. Probes and clients are anonymous, carry no listener data, use the
User-Agent below, and stay at or under one request per second per host (the real figures above).

| source | what the brain takes | terms | before charging anyone |
|---|---|---|---|
| Deezer | album genres, popularity rank, release date, tempo, loudness, ids | non-commercial API terms | ask Deezer, or switch off `deezer` |
| MusicBrainz | recording id and first release year, artist genres and country | core data CC0; **tag and genre votes CC BY-NC-SA** | ask MetaBrainz, or switch off `musicbrainz` |
| ListenBrainz | recording and artist genre tags (MusicBrainz votes), listener count | derived from MusicBrainz, **CC BY-NC-SA votes** | as MusicBrainz, switch off `listenbrainz` |
| Wikidata | artist genres, Wikidata id | CC0 | none |
| iTunes Search | a song's genre and release date, by name | the Search API's terms | review them, or switch off `itunes` |
| Spotify | what the sync already returns (ids, release date, explicit, the top artists' genres) | Spotify terms: **never used to train a model**. Since the review pass no genre or year Spotify gave is a feature of the island fit (see "After the independent review"); Spotify likes and history still weigh the listener's own tracks as pseudo-counts (owner question 1, default) | the existing "Use my Spotify music to shape picks" switch |

Without Deezer, MusicBrainz and ListenBrainz the engine keeps iTunes, Wikidata, Spotify genres, the radio chips and the atlas.
**User-Agent**: `PixlAudio/<version> ( https://github.com/RedSn0w1877/PixlAudio-iOS )`, this repository, which is public
(`gh repo view` says `PUBLIC`). **Owner: confirm that is the URL you want hosts to see**, or change
`KnowledgeUserAgent.projectUrl`, before the refresh runs on a friend's phone.

## Task 4: track DNA and tag vectors

`Tags.merge` is the whole of 3.4 as Android has it (ten sources with their trust, the late ones only when the first are weak,
the spreading to parents at 0.5 and 0.25 from the weights before any spreading, `min(2.4, 1 + 0.35 * depth)`, the 12 largest,
L2 normalisation, `q = floor(255 w + 0.5)`, "unknown" when nothing reaches 0.25). `TrackDna` has the year (earliest believable,
never Deezer alone), popularity (Deezer rank, YouTube play text, ListenBrainz listeners), energy and valence (the tag-weighted
mean of the descriptors, plus the loudness nudge), moods and the language of a title. **Proven bit for bit by Android's golden
files**: `atlas.jsonl` (721 cases), `tags.jsonl` (486), `dna.jsonl` (466), `tagfeatures.jsonl` (120), all green on the first
run, and by the ported unit tests. `Brain.specVersion` stays 2. Features 4 and 24 are pure functions with `Candidate.tags`;
**no live code path fills `Candidate.tags` or calls `Session.applyTags` / `Affinity.applyTags` yet** (the seam the scorer
milestone turns on, as on Android, deviation 143). Unknown genres are absent: an empty vector, no chip, no "sounds like".

Storage: three record files next to the others in `Application Support/Brain/` (`track_dna.pbl`, `artist_dna.pbl`,
`source_miss.pbl`), JSON with a version field `v`, byte fields in base64, a record this code cannot read or of a version it does
not know is skipped; a stage 1 or 2a install has none of them and is an empty store (no migration). The rows hold the same
columns as Android's `brain.db` 4 (including the per-source claims, 4 bytes each, so a refresh of one source re-merges the others
without asking them again).

## Task 5: Spotify artist genres

The Spotify sync already keeps the listener's **top artists with their genres** (`ExternalTasteSnapshot.RankedArtist`), by name
(no Spotify ids; the followed artists are names only). The lanes read those strings, place them through the atlas (tag source 3,
trust 0.7) by the folded name of the track's primary artist, and add **no Spotify request**. All of it is behind "Use my Spotify
music to shape picks": off, no Spotify genre, release date or explicit flag is used. The screen shows "n of m top artists came
with genres" (or a plain sentence when none did), which is the S1 check of spec 14.6: whether Spotify still sends genres to
this client id could not be checked here and is one look at the screen on the phone.

## Task 6: Developer mode > Brain data

`BrainDataView` (route `.brainData`, demo screen `brainData`, a row in Settings › Developer mode › Maintenance). Every number and
sentence of Android's screen, the same words (`BrainDataStrings`), as glass cards: the atlas, what is known, the sources with
their switches, the Spotify line, the last refresh. It reads when it opens (`BrainDataReader`, off the main actor) and again
after a switch is flipped; nothing at app start, nothing animated, no per-frame work. A source switched off by the remote
config shows off, disabled, with "Switched off for every phone".

## Deviations 107 and on

107. **The clients live in `PixlLibrary/Knowledge/`, not PixlNet.** They need `BrainText` (title folding, 10.5) and PixlNet cannot
     import PixlLibrary. The network is a `KnowledgeTransport` the app supplies (`KnowledgeURLTransport`, `URLSession`); every rule
     (switch, ledger, budget, spacing, back-off) is above it and tested without a network.
108. **`Package.swift` gained one line of data**: `extraTestDependencies`, so `PixlLibraryTests` (and only it) imports PixlBackup,
     whose pure-Swift `Gzip` and `SHA256` the atlas tests need (PixlBackup depends on PixlLibrary, so PixlLibrary itself cannot).
109. **The User-Agent names this repository** (`PixlAudio-iOS`, public), not Android's repo (Android deviation 142). Same shape.
110. **The atlas has its own ordered JSON reader** (`OrderedJson` in `GenreAtlas.swift`), because `BrainJson.Value` keeps objects
     as dictionaries and the source tables must be read in file order. `GenreAtlas.parse(utf8:)` takes bytes, not a `String`.
111. **Spotify genres are found by artist name** (see Task 5): the iOS sync keeps top artists by name with their genres, no ids,
     and followed artists without genres. The screen therefore counts top artists only.
112. **The artist-key sink is not ported** (Android deviation 149: a source's Spotify, Deezer and MusicBrainz artist ids stored
     beside the name key). iOS `Ids.ArtistKeys` has no Deezer or MusicBrainz key, and nothing reads them on Android either. The
     ids are still stored on `artist_dna`.
113. **The ISRC comes only from the Spotify facts** (`SpotifyFactStore`), so with "Use my Spotify music to shape picks" off the
     lookups go by name; Android also reads the ISRC from its library table in that case (iOS `Song` has none).
114. **The year and play count of the cached YouTube row are not read** (Android deviation 137): iOS has no cached seed row to
     read, so `ytYear` and `ytPlays` are 0 and popularity comes from Deezer, then ListenBrainz. The chips of the track's own radio
     (3.4 source 4) are read as on Android.
115. **Lane 3 resolves the library to recording ids once per run** (iOS has no reverse lookup from an id to a track key, which
     Android uses): the whole library goes through `resolveTracks` in one pass the first time lane 3 runs in a process, in the
     background task, and the result is kept for the rest of the run.
116. **The DNA files are in memory once opened** (the rows are small, about 0.6 KB; 10,000 songs are about 6 MB), opened by the
     first lane or by the screen, never at launch.
117. **The token buckets reuse `HostBudget`** (capacity = the daily ceiling, parallelism 1) and the ledger is asked separately
     before a token is taken; Android's `HostBudget` takes the ledger as a callback.
118. **The iTunes terms line says "the Search API's terms"** (AGENTS rule 9: no "Apple" in any UI string).
119. **`remote/config.json` lists the five sources as `true`** so the owner finds the keys; a missing key still means on.

## Cut or deferred (and why)

- `DeezerRadioSource`, Discogs, the related-artists vote, the shared-playlist vote and the assistant tagging (tag sources 5, 7,
  9, 10): not built, as on Android (deviations 134 and "cut").
- `emb` and everything about embeddings, islands, the SIM, BACK and EDGE arms, First Listen, Just Dropped, On Repeat,
  Rediscover, genre and mood stations, Search tiles, cold-start flows, the new Home and the Muselle 2 gate: later milestones.
- DNA for songs outside the library (lane 4's second half), as on Android.
- Live use of tags (`Candidate.tags`, `Session.applyTags`, `Affinity.applyTags` have no caller yet), as on Android.
- A human review of the atlas descriptors (Android's handoff: assistant-drafted, not read by a person).
- The artist-key sink (112), the cached YouTube row (114), the ISRC with the Spotify switch off (113).

## Not verified on a device

Everything above. In particular: that the atlas loads on a phone and how long it takes; a whole enrichment run on a real library
(the budgets, MusicBrainz's 503s at 1.1 s spacing, the 8-minute limit inside a `BGProcessingTask`, a cancelled round losing up
to 16 unsaved songs); that Spotify still sends artist genres to this client id; that every host accepts the User-Agent; that
`URLSession` is not held up by Low Data Mode (the refresh already refuses to run in it); how the Brain data screen looks;
the Swift 6 concurrency of the new `App/` lines (CI says).

## How to test on a phone

Developer mode on, Spotify connected, ten songs played, on Wi-Fi, music paused.
1. Settings › Developer mode › Maintenance › **Brain data**: "Version 1, 2249 genres in 24 families". Nothing else yet.
2. Leave the app in front and idle for 90 s (or let iOS grant the background task), music off. Open Brain data again: "What is
   known about your tracks" fills in; each source shows its requests today and how many songs it answered. Switch Deezer off:
   its next request never goes out (the count stops). The remote switch is `brain.sources.deezer.enabled: false` in the saved
   remote config.
3. Spotify card: "n of m top artists came with genres" (the S1 check of 14.6).
4. A song nothing could place shows no genre: nothing on iOS shows genres yet in this milestone.
5. Settings app › PixlAudio › Background App Refresh: still one task (`...brain-refresh`).

## Commands and results

```
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore"       # full suite before the last test file: 2,373 tests in 8 bundles, 0 failed
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainTagsAndDna"   # 27 tests, 0 failed (the file added after that run)
bash ./ci/check-forbidden.sh                                           # OK
powershell -NoProfile -ExecutionPolicy Bypass -File ci/parse-check.ps1  # 205 files OK
```

The PixlCore bundles of the CI run together total 2,400 tests (2,305 at the end of 2a). Golden files: `atlas` 721 cases, `tags` 486,
`dna` 466, `tagfeatures` 120, every one green on the first run. Android has moved on (its milestone 2 added `arms`, `fastrp`,
`homeplan`, `islandfeatures`, `islandmixes`, `islands`, `listmixes`, `ppr` golden files and changed `README.md` and
`MANIFEST.sha256`): those belong to the next iOS milestone; the milestone 1 files and the atlas asset are byte-identical to Android's
tip (checked by git blob id).

## CI

Workflow `ci`, branch `music-brain`. Run 44486765629 (`e86e3b4`): `core` passed, `app` compiled everything (Swift 6, strict
concurrency) and ran 664 unit tests with 1 failure, `testPlaybackStoreWithDemoEngine` (`StoreTests`), which touches nothing of
this work. Run **44488832203** (`751e6d4`, the same code plus the lazy `URLSession`) is **green**: `core` and `app` passed, 664 app
unit tests, 0 failures; `ipa` skipped as on every push. So the one failure was a flake of that test. As before, green CI says
nothing about whether the new screen and the lanes work on a phone.

---

# Milestone 2 of 2b (iOS): "it knows your music"

The port of Android's milestone 2 (its commits `85efa6e`, `4a01e6b`, `8450d76`, its handoff part "Milestone 2 of 2b"). Read the text
above first. This part continues the iOS numbering at **120**; Android's 152 to 168 hold here unless a line below says otherwise.
**Nothing here has run on a phone.** Only `Packages/PixlCore` compiles on the Windows machine; `App/` is compiled by GitHub CI alone.
"Works" means: unit tests pass, the golden files match Android's bit for bit, and the code paths were read end to end.

## What is done (per task)

1. **The pure core, bit for bit.** `PixlLibrary/Brain/`: `Embeddings.swift` (`Embeddings`, `FastRp`), `Ppr.swift`, `Islands.swift`
   (`Islands`, `TagProjection`, `IslandNames`), `ArmRules.swift`, `ListMixes.swift`, `Calibration.swift` (`Calibration`,
   `SimilarityIndex`), `HomePlanner.swift`, and the changes to `Features` (the new `Candidate` fields, `IslandContext`, features 5, 6,
   19, 20 and 39), `StationPlanner` (`modeFirstListen`, the arm flags, islands, calibration), `MixPlanner` (`kindFirstListen`, a Daily
   Mix of one island, Your Mix across islands), `ListBuilder` (calibration gain, the similarity source, the cap per artist, the
   new-artist share), `Repetition` (`takenOnDay` with an id), `Graph` (`nodeIds`, `weightedDegree`, `SimilaritySource`).
   Android's eight new golden files (`fastrp` 30 cases, `ppr` 12, `islands` 71, `arms` 77, `listmixes` 10, `islandfeatures` 22,
   `islandmixes` 12, `homeplan` 84), `README.md` and `MANIFEST.sha256` are copied unchanged (git blob ids equal Android's);
   `BrainStage2bM2GoldenTests` replays every case byte for byte and **every one was green on the first run**. The older golden
   files and `recommendationMatchesAndroid` are untouched and green.
2. **The record files** (`BrainStore/IslandStore.swift`, `HomePlan.swift`, `PickedArtists.swift`), all versioned, all tolerating a
   stage 1 or 2a install that has none: `node_embedding.bin` (magic `PEMB`, format 1, ids ascending, 64 bytes a node), `island.pbl`
   (one record per island, centroid as 96 big-endian doubles), `island_member.pbl` (one record), `brain_state` values
   `island_last_id`, `island_tag_shares`, `emb_count`, `island_fit_at`, `picked_artists`; `home_plan.json` (at most 50 KB,
   tested), `recent_contexts.json`. A file this code cannot read is no islands, never an error.
3. **The lists** (`BrainMixes` + `BrainStore/MadeForYou.swift`): `MixSpec`/`MixKinds` (`daily`, `daily:<islandId>`, `your`, `first`,
   `dropped`, `repeat`, `rediscover`), the saved-mix format with the new optional fields (`mixId`, `islandId`, `number`, `subtitle`;
   a 2a record still reads), Daily Mix 1..K (one per island, at most six, numbered by ascending stable id, "Soft pop & R&B · Artist,
   Artist" subtitles from real atlas genres and artists), Your Mix across islands, First Listen (weekly, fixed from Monday 04:00,
   held against every other list all week), Just Dropped, On Repeat, Rediscover; stable for the day, no track in two lists of a day.
   `IslandBuilder` fits weekly or after 200 qualified plays, inside the one refresh (`RefreshWork.fitIslands`) and from the Home plan.
4. **The new Home.** `HomePlanBuilder` (PixlCore, the shelves in the fixed order of 8.1, then `HomePlanner`'s page rules, the hero)
   saves `home_plan.json`; `App/Features/Home/HomePlanState.swift` reads it when Home first appears (one small file, never at
   launch), shows it, plans again when the day (04:00), the daypart or the taste changed, and shows the new plan the next time Home
   appears; `HomePlanSections.swift` draws the date line, chips (For you, Mixes, Spatial, New), hero, Jump back in, the mix shelf, the
   station shelf, the track shelves (the existing `HomeDiscoveryShelf`, played through the existing `BrainActions.play`). No spinner and
   no empty state: without a plan Home shows Jump back in and the library rows. The legacy whole-library ranking still runs for the
   legacy page; while the plan owns Home its mixes, Your Mix block and shelves are not drawn.
5. **Stations, Search tiles, the cold start, the picker, the setup page.** `GenreStations` (cards, songs under a node, `idForName`,
   `knownNames`), `BrainActions.startGenreStation`/`startGenreStationByName`/`knownGenreTiles`, `Station.sourceGenre`/`sourceMood`,
   the Search tiles (a genre the atlas lacks has no tile; a tile with songs under it starts a station; otherwise the live search it
   always was), `ColdStart` (8 radios, two at a time, "Getting to know your music · 3 of 8"), `PickedArtists` + `ArtistPickerView`
   (search-based), the setup page "How much new music?" (Familiar / Blend / Discover after Spotify, with the history-import link).
6. **The Muselle 2 gate.** iOS Home never had one: `Muselle`/`Muselle2` live only in `Recommendation.swift` (the pure port of the
   legacy engine, untouched), and nothing in the brain's features or in `App/` asks for a Plus tier. Nothing to remove; nothing in the
   brain is behind Plus.
7. **The eval tests** (`BrainStage2bM2EvalTests`): Android's `Stage2bM2Test` with the same planted listeners (the same random
   draws) and the same expected numbers (purity at least 0.95 for 3, 4, 5 and 6 clusters, ids kept and a new island getting a new
   one, KL under 0.15, the Home rules on 400 random pages), 22 tests, green. `BrainStage2bM2Tests` (14) covers the files, the fit,
   every list end to end over real record files, the plan size, Jump back in and the cold start.

## Deviations (120 and on)

120. **Embeddings are one binary table** (`node_embedding.bin`), not per-node records: the fit rewrites the whole table, a lookup is
     a sorted-array search, and it is read once, off the main actor, on first use.
121. **Islands are one record per island plus one members record** (`island_member.pbl`, key `all`); the quantised `weightQ` is
     stored as Android does, so a reread island equals the fitted one.
122. **`Candidate.point` is computed on demand** (a Swift struct cannot cache a lazy value); `Calibration` is a `final class`
     (`@unchecked Sendable`), because the list builder adds each pick to it.
123. **`ServedListStore.put` stamps a list a millisecond later when another list of the same surface has the same `recId`**. Android's
     `recId` is `(builtAt << 8) | surface`, so two Daily Mixes built in one millisecond would overwrite each other. A test found it.
124. **Jump back in holds made-for-you lists only.** An iOS queue has no name (`PlaybackStore.play` takes songs and a source tag), so
     the new `PlaybackStore.onQueueStarted` hook records a queue when its tag says Daily Mix, Your Mix or a named list. Playlists,
     albums and stations are not recorded (Android records them from its dispatch path by queue name). Cut, said here.
125. **The Muselle 2 gate** (task 6): see above, nothing to remove on iOS.
126. **The Spatial chip opens Cloud processing** (Android 161).
127. **The island refit also runs from the Home plan** (Android 168), through `IslandBuilder.ensure()`.
128. **The setup page sits at raw value 2** of `SetupView.Page` (after Spotify, as on Android). A setup that was closed mid-way before
     this build resumes one page later than it was; `BackupServiceTests` now expects 7 pages and the new resume indexes.
129. **A Daily Mix of an island has no "Regenerate" button**, as on Android (only Your Mix has one); the new `MixDetailView` reuses
     `MixScreen` with the list's own tags.
130. **Genre and mood stations are seeded by five songs** (`StationSeeds.genreSeeds`); their queue line says "Music like your songs in
     this genre, picked as you listen".
131. **The artist picker's search** is `InnerTubeClient.searchSongs` (20 results, the first artist of each credit), as on Android.
132. **SIM and BACK are in the core and the planner, and nothing sets them yet** (Android 160); EDGE offers library songs only.
133. **`RefreshWork.fitIslands()`** is a protocol method with a default no-op, so a work without islands runs as it did.

## Cut or deferred

The same as Android's list: "Popular where you are" and the picker's chart grid (no chart call), assistant-written island names,
seeding radios from each island's medoid, co-play and same-playlist graph edges, islands inside `Eval`, a Developer screen section
for islands, feeding SIM and BACK. Also on iOS: Jump back in for playlists, albums and stations (124).

## Not verified on a device

Everything in `App/` (CI compiles it; nothing runs it). In particular: how the new Home looks and that nothing jumps; that a plan
built while Home is open waits for the next appearance; the 04:00 and daypart rollover; island fit time on a real library (timed into
the diagnostics log as `brain_island_fit`) and whether real islands read as sides of someone's taste (only planted ones are proven);
the first-minute strip and the picker's search (they call YouTube Music); the genre station start and the Search tiles; the setup page
and the history-import link; the Swift 6 concurrency of the new `App/` lines; that the refresh still shows ONE background task.

## How to test on a phone

Developer mode on, Spotify connected.
1. Play ten different songs, leave Home open a few seconds, leave and come back: date line ("Friday night"), chips, hero, Jump back in,
   "Made for you". Kill and reopen: it paints from `home_plan.json` with no wait.
2. After the first refresh (or 90 s idle in front), Daily Mix 1..K appear with subtitles; tap Daily Mix 2: the list opens.
3. "Stations for you": tap a genre card, the queue line says "Station · <genre>". Search with the brain on: Pop starts a station.
4. A new install with Spotify connected: the strip counts to 8 and goes. Under 30 songs: "Pick three artists you love".
5. Setup: the new page after Spotify; "Import your listening history" opens the import when Home first appears.

## Commands and results

```
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore"          # 2,445 tests in 8 bundles, 0 failed (2,400 before: +9 golden, +22 eval, +14 lists)
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainStage2bM2"   # golden 9, eval 22, lists 14: all green
bash ci/check-forbidden.sh                                              # OK
powershell -NoProfile -ExecutionPolicy Bypass -File ci/parse-check.ps1  # 232 files OK
```

## CI

Run **44508593496** (`8b263f7`, workflow `ci`, branch `music-brain`) is **green on its first run**: `core` passed, `app` compiled
everything (Swift 6, strict concurrency) and ran 664 unit tests with 0 failures, `ipa` skipped as on every push. The CI run that
followed milestone 1 (44488832203) was green too, so nothing from it needed fixing. Green CI says nothing about how the new Home
looks or behaves on a phone.


# After the independent review (iOS)

An independent reviewer read the whole iOS stage 2b diff and gave 17 findings. Each was checked against the code. Android's own
review pass (`9f29a21`) changed no `:brain` file, so **no golden file moved** (the blob ids of `MANIFEST.sha256`, `islands`,
`homeplan`, `eval` and `islandmixes` were compared and are equal); its app-layer rules were copied by hand where they applied.

## Findings, one by one

| # | Finding | Result |
|---|---------|--------|
| 1 | Island save was remove-all then put-one-by-one | Fixed. `IslandStore.save` stamps `island_last_id` first, then writes every island AND the member record in ONE append (`island.pbl`; the member record is last and names the islands of its fit in `ids`), then removes the keys that are gone. A reader takes the islands the member record names and no others, and a first fit with no member record is no set. The separate `island_member.pbl` is gone (nothing had run on a phone). A fit is also due again when `node_embedding.bin` holds another number of rows than `emb_count` says (Android's rule). Tests: kill before the member record leaves the previous fit; unfinished first fit is no islands; stale islands are removed. |
| 2 | Setup's "Import your listening history" set a flag Home had already stopped reading | Fixed. Home reads the flag in its `.task` AND when the setup cover closes (`router.cover == nil`), never under a cover; the page's button now says "It opens when you finish setup" after a tap. |
| 3 | Spotify off left stored Spotify genre claims | Fixed. `DnaTarget.spotifyOff`; `assemble` drops provider-3 claims from the track and the artist row, the Spotify year and the "asked Spotify" bit, and re-merges tags, moods and the year. `SpotifyDnaPurge` (new, run by the one refresh before the island fit, Android's design) rewrites every row that still carries them once and marks the islands due; switching the switch on clears the mark. Spotify track ids and ISRCs stay on the rows (identifiers the library already holds). Tests: assemble with the switch off, other sources keep their genres, the purge runs once and resets. |
| 4 | Spotify genres fed the island fit | Fixed in the stricter direction. The island fit reads each row's tags with the Spotify claims taken out (`DnaAssembler.tagVectorWithoutSpotify`); with no readable atlas it reads no tags. **This differs from Android, which still fits on the stored vector; Android should do the same** (one line in `IslandInputs.live`). What stays: the listener's own play history and Spotify likes weigh the tracks (pseudo-counts, owner question 1 default, removed with the same switch at the next rebuild); the clustering itself is k-means over that and over the YouTube Music graph, not a trained model. Test: `theIslandFitReadsNoGenreOnlySpotifyGave`. |
| 5 | A saved plan with no shelves hid the legacy rows | Fixed. `HomePlan.hasContent` (hero, a mix card or a shelf); Home is owned only when what is drawn has a hero or a shelf, else Jump back in and the library rows carry the page. |
| 6 | A shelf under 6 could show after songs were removed | Fixed. A library shelf with fewer than `HomePlanner.minTracks` songs left is hidden; the songs a plan draws come through the library minus blocked, muted and "Not for me" songs (`AppEnvironment`). |
| 7 | The hero release was also in "New from artists you love" | Fixed. The hero is chosen before the shelves and its recording is taken out of the shelf. |
| 8 | Daily Mix numbers from the island set at build time | Fixed. The number is read from today's islands when a list is read back (`BrainMixes.liveNumber`); an island that is not one of today's six has no list (not shown, not built); the plan records `islandFitAtMs` and is due when the islands were fitted again. Cards still open by the number-1 route, now consistent with the plan. |
| 9 | An empty fit overwrote good islands and retried at every plan | Fixed. A fit that places nothing keeps the stored islands, stamps `island_empty_fit_at`, and waits a day. |
| 10 | Genre index cached on library size only | Fixed. The key holds the DNA row count and a write counter (`DnaRepository.revision`). Cards are also ranked by what the listener plays (decayed play weight), then by song count (Android's rule). |
| 11 | Engine switched to legacy left brain bits on screen | Fixed. Home's state resets to the legacy page, whole. |
| 12 | A failed atlas load was retried by every caller | Fixed. A failure is remembered for ten minutes. |
| 13 | Track and artist DNA rows written separately | Fixed. The artist row goes first, so a kill never leaves "MusicBrainz done" on a track with its artist lost. |
| 14 | A plan over 50 KB was not saved, silently | Fixed. Retried with 10, 8 and 6 songs a shelf and two covers a card; a plan that still does not fit logs `brain_home_plan_not_saved`. |
| 15 | The date line was the saved plan's | Fixed. Weekday and daypart come from the clock when Home draws. |
| 16 | A Search tile with no songs toasted and opened browse | Fixed. A tile with a fallback says nothing; a Home card (no fallback) still says so. |
| 17 | Atlas families wrong for two Vietnamese genres | Deferred. The atlas is one shared CC0 file pinned by SHA on both apps; changing `nhac tien chien` (853) and `nhac do` (231) to a south and southeast asian family has to land on Android and iOS together. Nothing user-visible depends on `family` yet. |

Also copied from Android's review pass: tracks are deduplicated by recording id before the graph and the fit; the graph is capped at
30,000 nodes (library edges first, then the heaviest of the rest); an island gets a genre name only when 40% of its tracks carry a genre
and the genre is among its top tags; genre names with a banned word (substring, so "atmospheric ..." is hidden) are never shown on a card, a
Search tile, an island name or "A step sideways"; On Repeat is built first; `takenOnDay` reads the newest build of each list only; the "New"
and "Mixes" chips are offered only with something behind them; Home draws nothing below the top bar until the saved plan has been looked
for (120 ms fade). Not needed on iOS: the served-log cache (the iOS log is an in-memory index), the ISRC in the exported log (the
knowledge transport logs no URL).

## Deviations 134 and on

134. **`island_member.pbl` is gone**: the member record is the key `members` in `island.pbl`, written last in the same append (Android: one Room transaction).
135. **`SpotifyDnaPurge` and `DnaTarget.spotifyOff`** (Android 170/171); `RefreshWork.purgeSpotify()` has a default no-op.
136. **The island fit excludes Spotify-sourced tags** (stricter than Android; see finding 4). The same input switch exists nowhere else.
137. **`HomePlan.islandFitAtMs`** (optional field, 0 when absent) and `HomePlan.hasContent` / `shrunk(maxItems:)`.
138. **`CachedAtlasProvider.init(load:clock:)`**: the clock is the second parameter so a trailing closure still means `load`.
139. **The setup page's import button changes its words after a tap** (new string "It opens when you finish setup").

## Cut or deferred (this pass)

- The 30-day, 60%-distinct simulation with islands in `Eval` (as on Android: needs islands plus novel candidates with embeddings inside `Eval`).
- The atlas family fix (finding 17).
- The song count on a mix card stays the plan's until the next plan (as on Android); the plan is now due again when the islands were refitted.
- Android's `brain.db` migration and instrumented tests have no iOS twin (record files).

## How to test on a phone (stage 2b, whole)

Developer mode on, Spotify connected. Use a build installed over one that has stage 2a files if you have it.
1. **Update over an old build.** The app opens, nothing is lost: Brain data still counts the same plays.
2. **Home from the file.** Play ten different songs, leave Home open a few seconds, go away and come back: date line (it follows the clock),
   chips, hero, Jump back in, "Made for you". Kill and reopen: Home fades in already showing the plan; the old rows are never drawn first.
3. **Chips.** "New" and "Mixes" are only there with something behind them; a remembered chip with nothing falls back to "For you".
4. **No blank Home.** With few songs and picked artists but no network: Jump back in and the library rows are there, never just the chips.
5. **Mixes named from real genres.** After one refresh (or 90 s idle in front) the Daily Mixes appear numbered 1..K; a name appears only when
   many of that island's songs have a genre; a thin corner shows only artists. No card says "atmospheric ...".
6. **A song is in one mix a day.** Open Daily Mix 1, 2, 3, Your Mix, On Repeat, Rediscover and the hero release: look for a song twice (none
   expected). Over a week the Daily Mixes should mostly differ (no automated evidence for islands: write down what you see).
7. **Genre stations.** Tap a card under "Stations for you": the queue line says "Station · <genre>". A Search tile for a genre you have no songs in
   opens the search without a message.
8. **Spotify switch.** Settings > Developer mode > Brain: "Use my Spotify music to shape picks" off, then after the next refresh Brain data shows
   fewer genres and the Daily Mix names may go to artists alone; on again, they return after a refresh.
9. **Knowledge sources.** Brain data lists Deezer, MusicBrainz, ListenBrainz, Wikidata and iTunes with their terms, each with its own switch;
   Deezer off stops its counter. (Non-commercial sources: switch each off before charging anyone.)
10. **One background job.** The Developer screen / Console shows one `brain refresh` task; while music plays no enrichment runs.
11. **Cold start.** Fresh install with Spotify: "Getting to know your music" counts to 8 and goes. Under 30 songs: "Pick three artists you love";
    after three, Your Mix and a Daily Mix exist.
12. **Setup.** The new page after Spotify; tap "Import your listening history": the button says it opens when you finish; on Finish the import opens.
13. **Kill during a refresh.** Start a refresh, kill the app, reopen: Daily Mixes keep their numbers (the fit lands whole or not at all).

## What nobody has verified on a device (stage 2b, whole)

Everything in `App/` (CI compiles it, nothing runs it): the look of the new Home, the fade-in and that nothing jumps when a plan arrives; the
chips; the setup page and the import hand-over; the picker and the first-minute strip (they call YouTube Music); genre station starts and Search
tiles; the 04:00 and daypart rollover; island fit time and memory on a real 3,000 to 20,000 song library (timed as `brain_island_fit`) and whether
real islands read as sides of someone's taste and whether the 40% naming rule leaves too many unnamed; the purge on a real library; the transaction
behaviour when iOS ends the background task mid-fit (the tests prove a half-written fit is never read, not what iOS does to the process); the
30-day distinct share of island Daily Mixes; the Swift 6 concurrency of the new `App/` lines beyond what CI compiles; that the refresh is still one task.

## Commands and results (review pass)

```
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore --filter BrainStage2b"   # 71 tests, 5 suites, 0 failed
cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore"                         # 2,461 tests in 8 bundles, 0 failed
bash ci/check-forbidden.sh                                                              # OK
powershell -NoProfile -ExecutionPolicy Bypass -File ci/parse-check.ps1                  # 235 files OK
```
