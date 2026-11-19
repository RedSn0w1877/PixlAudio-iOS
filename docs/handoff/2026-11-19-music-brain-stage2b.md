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
| Spotify | what the sync already returns (ids, release date, explicit, the top artists' genres) | Spotify terms: **never used to train a model**; nothing here trains anything | the existing "Use my Spotify music to shape picks" switch |

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
