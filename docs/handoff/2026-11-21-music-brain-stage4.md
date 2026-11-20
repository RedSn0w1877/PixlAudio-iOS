# Music brain, stage 4, milestone 1 (iOS): the tools, the grounding, and the two stage 3 gaps

Branch `music-brain`. The contract is `docs/brain-spec.md` sections 0, 1, 2, 9 and 14 (stage 4). This is the iOS port of Android's stage 4
milestone 1 as it stands in Android's commits `7cc704f`, `b6c4225`, `d9c26a6`, `12cb077`, `463dcd8` and `0cbc65f` and its handoff
`handoff/2026-11-21-music-brain-stage4.md` (its deviations 207 to 222 hold here unless a line below says otherwise). The earlier iOS
handoffs are the map of what exists: stage 1 (deviations 1 to 66), stage 2a (67 to 106), stage 2b (107 to 139), stage 3 (140 to 168).
This file continues the iOS numbering at **169**.

**Nothing below has been run on a phone.** Only `Packages/PixlCore` compiles on the Windows machine; `App/` is compiled by GitHub CI
alone. "Works" means: unit tests pass, the golden files match Android's bit for bit, and the code paths were read end to end.
**There is still no real-data number anywhere**: the learner and the gate have run on synthetic listeners only, and the served vector has
not been shown to help (the golden test shows the two replays differ, not that the difference is better).

## What was built

### Stage 3 gap A: the served vector

- `Brain/ServedVector.swift`: quantise (51 values x 4096, little-endian int16, 102 bytes, hex of 204 characters), `dequantize`, `toHex`,
  `fromHex`. `PlayEvent.servedX: [UInt8]?` is an additive key of the event line (`"servedX":"<hex>"` only when present; a stage 1 line has none
  and reads as nil). `LearnReplay.vectorOf` is the one function the live update and the replay call: the served vector when the row has
  one, else the reduced rebuild (every older row).
- `StationPlanner.Pick.servedX` (read again from the same state after the list is built, with the same `Features.compute` call, so it never
  changes which picks are made) and `ListBuilder.Scored.idx`.
- The vector rides with the pick: `BrainItemTag.servedX` (hex), `PlaybackQueueItemSnapshot.brainServedX`, `StoredMixItem.sx`,
  `StoredHomeItem.sx`, `PlanItem.sx`, `BrainHomeItem.servedX`; the in-flight play (`OpenPlayCodec`, key `sx`) and the event
  (`BrainEngine.record`) carry it. Every stored shape reads an older file (the key is optional, absent is "no vector").
- Tests: `BrainStage4GoldenTests.servedVectorMatchesAndroid` (24 quantisations, 5 refused texts, 3 replays: model, predictions, and the
  replay without the vectors must differ), `BrainStage4Tests` (every pick of a plan carries a 51-value vector with bias 1; the vector
  survives the tag, the saved queue and the open play; a mix, shelf or plan saved before stage 4 still reads), and one engine test
  (`theServedVectorOfTheTagIsStoredWithTheEventAndTheLearnerTrainsOnIt`, in `BrainEventRecorderTests`).

### Stage 3 gap B: the gate rule

iOS already had the 1% margin, the test 6 interval from 2,000 plays and "no control sessions while the gate is off" (deviations 161 and
163). Parity with Android's numbers is now proved: `gate2.jsonl` (60 cases of `Gate.decide` with the interval flag, and
`Summary.learnedClearlyBetter`) reproduces bit for bit. Nothing in the gate changed.

### The pure core, ported with Android's new golden files

`AssistantRules.swift` (refs, `normalize`, the filters, the chips, the fixed factor names, `topFactors`) and `Grounding.swift` (the
`[[ ]]` and quoted spans, `isGrounded`, `numbersIn`, `listenerNumbers`, `check`, `dropSentencesWith`). Both scan UTF-16 units, as the
Kotlin does (Swift's `String.contains` compares characters and would differ). `assistant.jsonl` (96 lines) reproduces bit for bit; so do
`servedvec.jsonl` and `gate2.jsonl`. Android's `README.md` and `MANIFEST.sha256` were copied again (41 entries).

### The ten tools

- `PixlModel/AssistantVocabulary.swift`: the tool names, the enum values, the sentinels and the limits. PixlNet builds the schemas from it
  and PixlLibrary's `AssistantRules` reads requests with it (the two modules cannot import each other), so they cannot drift.
- `PixlNet/Claude/TaizoMusicTools.swift` + `TaizoAssistant.swift`: ten new `TaizoTool` cases appended after the 16, in Android's order;
  descriptions word for word; every object closed, **every parameter required**, sentinels `[]`, `0`, `""`, `"any"`, `-1` for
  `novelty_share_pct`. Five are strict (`resolve_tracks`, `recommend`, `build_mix`, `start_station`, `steer_session`); the other five
  (`explain_track`, `explain_taste`, `lookup_genre`, `similar_artists`, `new_releases`) are closed and fully required but not strict, as on
  Android (a request holds at most 20 strict tools; 15 of the older 16 already are). Tool choice stays automatic. The confirmation rule
  asks before a lasting steer and before a station replaces a queue of more than one song.
- `PixlLibrary/Assistant/MusicBackend.swift`: the backend protocol and its plain types. `MusicToolRunner.swift`: the executor over it
  (an actor; at most 25 results; 40 network lookups a turn; refs a tool did not return are refused and reported; everything it returns is
  noted in the grounding record). `TaizoGrounding.swift`: one conversation's record (names, refs, numbers, the listener's own words, the
  context blocks, an older chat's history, the web results of the turn).
- `AssistantMixer.swift` (an extension of `BrainMixes`): the Your Mix pool, scorer and list builder shaped by the request, with the filters
  applied to what the DNA knows; a filter no candidate has data for is NOT applied and is reported; unknown never passes a filter on it.
  `BrainAssistantEngine.swift`: the real `MusicBackend` over the stores (resolve, recommend, build_mix and its chips, explain_track,
  explain_taste from Your sound, lookup_genre from the atlas, similar_artists from the graph, new_releases from the saved file, session
  steer). The network search, the station start, the lasting steer and the queue are the app's, through `AssistantHost`.
- App (thin): `TaizoMusic.swift` (the host over the app's YouTube search under the day's request budget, `BrainActions`, the queue),
  `TaizoToolbox` (routes the ten tools to the runner; the older tools' results are noted too; `yt:`, `sp:` and `mix:` ids in
  `play_songs`, `add_to_queue`, `create_playlist` and `add_to_playlist` resolve through the playable side and are never imported;
  `LibraryEditor` already saves an engine track before a playlist takes it), `TaisChatModel` (grounding per turn, the reply cleaned, marks
  hidden while it streams, the activity line of each tool).
- The prompt: `TaizoAssistant.musicRules` (Android's text, word for word, with the `[[ ]]` bullet) appended after the existing guidance.
  The taste digest stays after the cache breakpoint.
- The words the listener reads (`TaizoMusicStrings`: the nine activity lines and "(a name I could not check)") are Android's and are
  covered by the forbidden-words test.

## Deviations 169 and on

169. **The vocabulary lives in `PixlModel`** (`AssistantVocabulary`), not in `AssistantRules` as on Android, because PixlNet (the schemas) and
     PixlLibrary (the rules) cannot import each other. `AssistantRules` aliases it.
170. **The executor and the backend protocol are in PixlLibrary** (`MusicToolRunner`, `MusicBackend`), not PixlNet: they need `AssistantRules`
     and `Grounding`. The schemas are PixlNet's. The app's `TaizoToolbox` is the seam.
171. **The legacy order is iOS's own** (`get_taste_profile` comes before `get_library_overview`, unlike Android): the first 16 keep their place
     on each platform's cached prefix; the ten music tools follow in Android's order.
172. **Only five tools are strict**: same split as Android 222.
173. **`resolve_tracks` has no alias-table step.** Android reads `track_alias` without writing; iOS's table has no lookup-only call (resolving a
     name mints a recording id), and a name nobody found must not leave a row. So: the library, then one YouTube Music songs search under
     `HostBudget`, scored like playback (`TrackMatcher`) and accepted at its threshold.
174. **`FilterContext.excludedArtists` is `[String]`**, not a set (strings compare by UTF-16 units on both platforms, and Swift's `Set<String>`
     does not).
175. **A track queued by `steer_session` (scope session) or `add_to_queue` while something plays carries no tag**: `PlaybackStore.playNext` and
     `addToQueue` take no tags. A play started with `play_songs` carries surface assistant, the arm and the served vector. So those plays
     are logged without the vector and use the reduced one in the replay. Nothing is lost, but the learner sees them as it did before stage 4.
176. **No "untrusted content" confirmation.** Android asks before a steer that follows text from a web page or lyrics (`untrusted`); the iOS
     loop does not tell the toolbox that a server tool ran. The lasting steer and a station that replaces a queue still ask. A session steer
     only adds five songs next.
177. **Web results count as held by their short strings and quotable text** (as Android 219), read from the turn's appended messages after the
     loop (the stream event carries no text). The model's own text never counts. A name that is only somewhere inside a long page is not a
     registered name: a recommendation must still come from `recommend` or `build_mix`.
178. **`explain_track` reads its factors against the standard recipe's weights**, as the golden test does (`Ranker.weights(p0)`); it does not say
     whether the learned weights ranked the pick.
179. **A genre's descriptors are not returned by `lookup_genre`** (the atlas holds a descriptor per genre, not a list of words); id, name,
     description, parents, children, related, influences, region and era are. The "nearest names" are the atlas names that hold the words of
     the query (or are held by it), shortest first, at most five.
180. **`new_releases` has only `my_artists`** (Android 218); `similar_artists` sums the graph's edges from the library's own recordings of the
     artist (at most 40 of them), so an artist the library does not have has no answer.
181. **A lone surrogate**: `cleanTitle`'s 60-unit cut could split a surrogate pair; Kotlin keeps the lone half, a Swift `String` cannot. No
     golden case has it.
182. **Strings**: Android's `strings.xml` names are `TaizoMusicStrings` here.

## Cut or deferred (as on Android, nothing more)

- The mix card and the chips under it in the chat (`AssistantRules.chipsFor`, `BrainAssistantEngine.adjustMix`): the data, the deltas and the
  engine call exist and are tested; the UI is milestone 2. A mix plays through the chat (`play_songs` with `mix:<id>`).
- Set notes, the weekly note, the batch jobs, the one-tap "Less trap".
- `explain_track` does not give `why_key` for a track that is not a pick of this chat.

## How to test on a phone (for Hoa)

1. Open Ask Taizo. "make me something like Espresso but slower for a late drive": it should resolve Espresso, build a mix, say how many songs
   and play it when asked ("play it"). Every song it names should be one a tool returned; none should show "(a name I could not check)"
   unless it named something it did not look up.
2. "Why do I keep getting trap?": numbers that match Settings > Your sound, and "I don't know" for what the page leaves out.
3. "Slow it down": five songs next, the queue after them unchanged. "Start a station from Radiohead". "Less Drake for good" asks for a tap.
4. After some listening, `Settings > Developer > brain` should still show the model state.

## What nobody has verified on a device

- Every tool against the real stores: `BrainAssistantEngine` and `AssistantMixer` compile and are read end to end, and the tool layer is
  tested over a fake backend, but nothing exercises the engine on a library.
- The `[[ ]]` check on real model output: how often the model marks names and how often an unmarked name slips through.
- Whether the served vector improves the learner. No real export has been scored.
- The YouTube search false matches and the lookup budget (40 a turn, 60 a day, shared).
- That a `play_songs` of engine refs lands in the event log with surface assistant, arm ASK and the vector (traced only).
- A station started from the chat, the novelty switch it moves, and a lasting steer through the taste store.
- That `App/` compiles: only CI checks it.

## Third-party data terms (owner decision, unchanged)

Deezer and MusicBrainz tag votes are non-commercial sources while the app has a Plus tier, and Spotify content must never be used for
training a model. Each source is behind its own off switch (`BrainSwitch`, local, plus the remote-style flag the refresh worker reads), is
used at run time only, and is never bundled except the CC0 atlas. Nothing in stage 4 reads a new source. No listener data leaves the device
except what the existing assistant already sends under its existing consent, budget and switches; the tools' results are part of that
conversation, as the older tools' were. Nothing in the brain is behind Plus.

## Commands and results

Windows, from the iOS checkout root (Git Bash):

- `cmd //c "ci\swiftw.cmd test --package-path Packages\PixlCore"` (the whole PixlCore suite): **all green, 0 failed** (PixlLibrary 905 tests in
  98 suites, PixlNet 340, PixlBackup 157, and the other targets; the one failure on the way was my own web-result test, fixed). The new
  suites: `BrainStage4GoldenTests` (5), `BrainStage4Tests` (3), `MusicToolRunnerTests` (17), `TaizoGroundingTests` (9),
  `TaizoMusicToolsTests` (10), one more case in `BrainEventRecorderTests`, and the changed `ClaudeTests` / `TaizoTasteToolTests`.
- `bash ci/check-forbidden.sh`: OK. `ci/parse-check.ps1`: 291 files OK.
- The golden files compared by git blob id with Android's committed ones: only `MANIFEST.sha256`, `README.md`, `assistant.jsonl`,
  `gate2.jsonl` and `servedvec.jsonl` differed, and they were copied; every older file is identical.

## CI

- Round 1 (`522876b`): `core` green, `app` failed: `cannot find type 'TaizoGrounding' in scope` (`TaisChatModel` did not import PixlLibrary).
  I re-read every `App/` diff for Swift 6 concurrency and found one more: `TaizoMusic.prepare` took a non-escaping closure it stores.
- Round 2 (`849997d`): `core` and `app` (build and unit tests) green; `ipa` skipped as before. Nothing flaky was seen.

---

# Milestone 2 (iOS): what the listener sees

Branch `music-brain`, same rule as above: **nothing here ran on a phone**, `App/` is compiled by CI alone, and there is still **no real-data
number anywhere**. This is the port of Android's milestone 2 (`9c38a15`, `d4acabc`, `5e65370`) and of its later review commit `e31f835`
(pure core). Android's deviations 223 to 233 hold here unless a line below says otherwise; this file continues the iOS numbering at **183**.

An earlier attempt at this milestone was cut off when the session ended. It had committed the pure core (`4a4daaa`) and left about 36 files
uncommitted (the services, the chat cards, the queue and player notes). They were read, kept where right, finished and committed in pieces.

## What was built (per task)

1. **A mix from a sentence, as a card.** `TaisChatMessage.mix` in Ask Taizo (`App/Features/AI/TaizoViews.swift`, `TaizoMixCard`): "Late drive -
   30 songs", the first four songs, Play, Save, and the chips. `MixCard.of(AssistantMix)` (PixlLibrary) builds it from the engine's own answer; the
   model's text is never read. Play = `TaizoToolbox.playMix` (the same `play_songs` path with `mix:<id>`, so surface assistant, arm ASK and the
   served vector reach the event log). Save = the `create_playlist` path with the mix's songs (engine tracks are saved first). **A chip is a delta on
   the stored request applied on the phone with no model call**: `AssistantCards.allChips` / `chipLabel` (golden `assistantcards.jsonl`) and
   `BrainAssistantEngine.adjustMix`; a tap replaces the card in place (`TaisChatModel.applyChip`).
2. **Explanations.** `explain_taste` / `explain_track` record the genres and artists they returned (`MusicToolRunner.namedThisTurn`); after the
   answer `LessOffer.offer(userText:named:)` offers "Less trap" only when exactly one returned name is a whole-word run of what the listener wrote
   and they did not praise it (the review rule, below). The tap writes the existing taste change (`BrainActions.lessLikeThis`) and shows "Done.
   You will get less trap." with Undo. "Why this song" shows "What helped: ..." / "What held it back: ..." (`ServedFactors`, `BrainService.whyFactors`):
   from the vector the queue item carries, else the newest play of the song that stored one, else nothing. `explain_track` now uses the weights the
   pick was ranked with (this supersedes deviation 178).
3. **Steering.** `steer_session`'s description gained "\"Slow it down\" is energy_down, \"pick it up\" energy_up" (a cached-prefix change, as on
   Android), and an energy change with no energy data now answers `applied: false` and says why. `scope always` still goes through the confirm card.
4. **Set notes.** `SetNotes` (golden `setnotes.jsonl`) over `SetNoteLines.forQueue`: at most one note per five tracks, from templates over the queue
   itself, true or absent. Drawn above the first row of a group in the queue (`SetNoteRowLabel`, `QueueSheet`) and under the artist line of the player
   (`PlayerSetNoteLine`, `NowPlayingView`). `SetNoteMemo` (a class held in `@State`) makes them again only when the queue window, the current song or
   the library revision changes, so a drag or a progress tick walks nothing.
5. **Weekly note.** `WeeklyNote` (golden `weeklynote.jsonl`) and `WeeklyNoteService` (PixlLibrary), shown on First Listen (`MixDetailView` ->
   `MixScreen.note`, a "This week" block between the header and Play). **One cloud call a week**, marked as asked in `weekly_note.json` before the
   call; offline it is not attempted and not counted; a cloud answer is used only if every name and number in it is in the evidence rows
   (`WeeklyNote.check`), otherwise the template shows. Made when the list is opened, never at app start.
6. **Batch jobs.** `AssistantHelp` (PixlLibrary) is the last step of the one refresh (`RefreshWork.assistantHelp`, after `rebuildBrain`), behind
   Settings > AI features > "Let Taizo help the engine" (`brain_assist_help_enabled`, **off by default**, plus the remote `brain.assist.enabled`).
   Island names, genres for tracks no source knows (tag source 10, `DnaAssembler.withAssistantClaims`), and artist suggestions (looked up like
   `resolve_tracks`). Answers go through `AssistBatch` (golden `assistbatch.jsonl`) and are cached forever by model id, prompt version and input hash
   (`AssistCache`, `assist_cache.json`). The tags the job wrote are taken back out when the switch is off. An assistant island name is read only while
   the switch is on and only for the genres it was written for (`YourSoundReader.setAssistedIslandName`); the suggestions feed assistant mixes only
   (`BrainMixes.setAssistSuggestions`, arm ASK).
7. **No network.** `StationSentence.parse` reads "start a station from X" by rules, in `TaisDjEngine.respond` before the media route, so it needs no
   model and no connection; `TaisChatModel` tries X as an artist of the library, a genre of the atlas, a playlist and an album, through the same host
   call the chat's `start_station` makes. iOS has no on-device model path that names a seed, so nothing is asked of it.
8. **Copy.** The new sentences are `App/Features/Brain/BrainStringsTaizo.swift` (Android's `strings_brain.xml`, word for word). `BrainCopyTests`
   scans that file with the rest of `App/Features/Brain` (no forbidden word, no "learn"; the stage 3 allowance still names exactly four strings) and
   a new test pins the sentences to Android's. The templates written in PixlLibrary (chip labels, set notes, the weekly template and evidence,
   the factor names, the negative factor names) are scanned by `BrainStage4M2Tests`; the instructions of the weekly note and the batch jobs by
   `AssistantHelpTests`.

### The review commit `e31f835`, ported

Android's reviewer changed three pure functions after milestone 2 and regenerated two golden files. They are ported and `assistant.jsonl`,
`assistantcards.jsonl`, `MANIFEST.sha256` and `README.md` are copied from Android's committed ones (the blob ids match):

- `Grounding`: a second pass `unmarkedNames` (runs of capitalised words outside every mark and quote), single quotes at a word start and
  guillemets as quotes, and whole-word text lookups (`Registry.addText` pads, `inText`, `inName`); `Grounding.check` gained `scanUnmarked` (default
  false). New golden `grounding2` (3 cases).
- `AssistantRules.topFactors`: `negativeNames` ("you often skip this artist") for a negative affinity; a negative affinity under a negative weight is
  not reported.
- `AssistantCards.lessTarget`: exactly one name may remain; a name inside a longer matching name is the same mention; a liking word in the three
  words before a name drops it.

## Deviations 183 and on

183. **The cloud door for the weekly note and the jobs is `ClaudeCompletion.short`** (PixlNet, new, two tests): one non-streamed request at
     effort low under a small `max_tokens` (320 for the note, 900 / 2500 / 1800 for the jobs), the usage charged through `AIService.recordClaudeUsage`
     (the monthly budget and the usage list). Android calls `ClaudeService.complete`. The door is `ClaudeCloud.shared.route() == .claude`: the
     automatic route, a connection and budget left; an own-key override or a $0 cap closes it.
184. **`BrainAssist` (App) holds the second engine the jobs need.** The artist suggestions are looked up with `BrainAssistantEngine.resolve`; the app
     makes one lazily (same host, same library) instead of reaching into the chat's. It exists only once a job has songs to look up.
185. **Save is a playlist, cards are not saved with the chat, a chip makes a new mix id, "Less X" is for genres and artists only**: Android 223 to
     226 unchanged.
186. **Set notes: "known" is a library row** (`library.song(id:) != nil`), the iOS reading of Android's `EngineTrack.isEngineOnly` (228). The genre is
     `Song.genre`'s first value (`SetNotes.firstGenre`). On a library whose genre column is empty only the artist and "you know" forms appear.
187. **The offline station tries four kinds in Android's order** (artist, genre, playlist, album). The artist test is "the library has a song by that
     primary artist" (iOS has no artist table of the engine's to ask), the genre test is `GenreAtlas.idForName`.
188. **`scanUnmarked` is not switched on in the chat.** The pure function and its golden are ported; Android's committed app does not pass it either
     (its HEAD predates any caller). Turned on, a reply that says "Your Mix" or "First Listen" unmarked would be flagged unless the registry held those
     words, so the app's own names need adding first. Left for the owner's decision; nothing else depends on it.
189. **The settings row is shown only when the build has the built-in key** (it is the cloud door that the jobs use), under "Use cloud AI".
190. **`AssistCache` and `weekly_note.json` use `Codable`** with Android's field names; they are per-device files, not meant to be moved between the
     two apps.

## Cut or deferred

- The mix card is not shown from the on-device chat path (as on Android); an unmatched sentence there goes the old way.
- `scanUnmarked` in the chat (188).
- Batch-job cost is not measured. No prompt-injection pass on the jobs' inputs beyond the validators (the inputs are the app's own genre and
  artist names).
- Nothing was cut from the task list.

## What nobody has verified on a device

- Every screen: the card (busy, failed, Save, Play), the chips, "Less X" and Undo, the factors in "Why this song", the set note in the queue and
  under the player title (and whether a line there shifts the hero layout), the weekly note block on First Listen, the Settings row.
- That a chip really rebuilds a different list through `adjustMix` over the real tables, and that Play from a card reaches the event log with surface
  assistant, arm ASK and the vector (traced and tested over a fake backend only).
- The weekly note's cloud call: how often the model marks names with `[[ ]]` and how often `WeeklyNote.check` rejects its answer.
- The batch jobs, none has run: how often the model's island names pass `AssistBatch`, how many tracks no source knows on a real library, what a
  week costs (no figure is claimed), and whether a source-10 claim ever tips a track's merged tags (it is the weakest source: a test shows the claim is
  kept and taken back out, and `Tags.merge` decides the rest).
- That an offline artist station starts quickly and that `startStation` for a name that is not in the library fails fast.
- That `App/` compiles: only CI checks it.

## How to test on a phone (for Hoa)

1. Ask Taizo: "make me something like Espresso but slower for a late drive". A card "Late drive - 30 songs", four rows, Play, Save, chips. Tap
   "Shorter": 20 songs, no chat message. Play: the queue becomes the mix. Save: a playlist appears.
2. "Why do I keep getting trap?" (a genre you play): a "Less trap" chip; tap it, then Undo. Name two genres in the question: no chip.
3. "Why this song" on an engine pick in the queue: "What helped" and "What held it back" lines.
4. Queue three songs of one genre from the library, then an engine pick: a line above the first of them and the same under the player title.
5. First Listen: a "This week" block; airplane mode shows the template; open it again and nothing is asked.
6. Settings > AI features: "Let Taizo help the engine" is off. Turn it on and let the refresh run; turn it off and the atlas names come back.
7. Airplane mode: "start a station from Radiohead" (an artist in the library) starts one.
