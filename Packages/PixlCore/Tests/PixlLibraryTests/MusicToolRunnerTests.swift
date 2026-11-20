import Foundation
import PixlFoundation
import Testing
@testable import PixlLibrary

/// The ten music tools of Ask Taizo (docs/brain-spec.md, 9.3) over a fake backend: what they return, what they refuse, what they never
/// invent. The same expectations as Android's `TaizoMusicToolsTest`. The schemas and their order are checked in PixlNet's tests.
@Suite("Ask Taizo music tools")
struct MusicToolRunnerTests {
    let backend = FakeMusicBackend()
    let grounding = TaizoGrounding()
    let runner: MusicToolRunner

    init() {
        runner = MusicToolRunner(backend: backend, grounding: grounding)
    }

    private func json(_ text: String) throws -> JSONValue { try JSONParser().parse(text) }

    private func run(_ name: String, _ input: String) async throws -> JSONValue {
        let object = try #require(try json(input).objectValue)
        return try json(await runner.run(name, object))
    }

    private func yt(_ n: Int) -> String { "yt:abcdefgh" + String(format: "%03d", n) }

    private func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }

    // MARK: resolve_tracks

    @Test func resolveReturnsRefsForWhatIsFoundAndSaysNothingAboutWhatIsNot() async throws {
        backend.add(yt(1), "Espresso", "Sabrina Carpenter", year: 2024)
        let out = try await run("resolve_tracks", #"{"items":[{"title":"Espresso","artist":"Sabrina Carpenter"},{"title":"A Song That Does Not Exist","artist":"Nobody"}]}"#)
        let results = try #require(out["results"]?.arrayValue)
        #expect(results.count == 2)
        #expect(results[0]["ref"]?.stringValue == yt(1))
        #expect(results[0]["year"]?.int64Value == 2024)
        #expect(results[1]["not_found"]?.boolValue == true)
        // The name that was not found is not echoed, so it can never count as "returned by a tool".
        #expect(!JSONWriter.write(out).contains("Does Not Exist"))
        #expect(grounding.check("Try [[Espresso]] by [[Sabrina Carpenter]].", placeholder: "(?)").ok)
        #expect(!grounding.check("Try [[A Song That Does Not Exist]].", placeholder: "(?)").ok)
        #expect(grounding.isKnownRef(yt(1)))
    }

    @Test func resolveTakesAtMost25ItemsACall() async throws {
        let items = (1...40).map { #"{"title":"T\#($0)","artist":"A"}"# }.joined(separator: ",")
        let out = try await run("resolve_tracks", #"{"items":[\#(items)]}"#)
        #expect(out["results"]?.arrayValue?.count == 25)
        #expect(out["ignored_over_limit"]?.int64Value == 15)
        #expect(backend.resolveCalls.first?.count == 25)
    }

    @Test func aTurnMayStartOnlySoManyLookupsAndTheDaysBudgetStopsTheRest() async throws {
        func items(_ from: Int) -> String { (from..<(from + 25)).map { #"{"title":"T\#($0)","artist":"A"}"# }.joined(separator: ",") }
        _ = try await run("resolve_tracks", #"{"items":[\#(items(0))]}"#)
        // 25 used of 40: the next call may look up 15, the other 10 are skipped without asking the backend.
        let second = try await run("resolve_tracks", #"{"items":[\#(items(100))]}"#)
        #expect(backend.resolveCalls[1].count == 15)
        let skipped = (second["results"]?.arrayValue ?? []).filter { $0["reason"] != nil }.count
        #expect(skipped == 10)
        #expect(await runner.budgetSpentThisTurn)
        // A new turn starts again.
        await runner.beginTurn()
        #expect(await runner.budgetSpentThisTurn == false)
        _ = try await run("resolve_tracks", #"{"items":[{"title":"X","artist":"A"}]}"#)
        #expect(backend.resolveCalls.last?.count == 1)
    }

    @Test func whenTheBackendSaysTheDaysRequestsAreSpentTheItemsAreReportedAsNotLookedUp() async throws {
        backend.skipAfter = 1
        backend.add(yt(1), "One", "A")
        let out = try await run("resolve_tracks", #"{"items":[{"title":"One","artist":"A"},{"title":"Two","artist":"A"}]}"#)
        let r = try #require(out["results"]?.arrayValue)
        #expect(r[0]["ref"] != nil)
        #expect(r[1]["not_found"] != nil)
        #expect(r[1]["reason"]?.stringValue?.contains("used up") == true)
        #expect(await runner.budgetSpentThisTurn)
    }

    // MARK: recommend / build_mix

    @Test func buildMixCleansTheRequestIgnoresRefsNoToolReturnedAndFillsTheCardFromTheEngine() async throws {
        let a = backend.add(yt(1), "Espresso", "Sabrina Carpenter", year: 2024)
        let b = backend.add(yt(2), "Good Luck, Babe!", "Chappell Roan", year: 2024)
        backend.mixTracks = [a, b]
        grounding.noteTrack(a)
        // Genre ids are ones lookup_genre returned in this chat (0 is the sentinel for none).
        grounding.noteToolResult(#"{"found":true,"kind":"genre","id":5,"name":"Pop"}"#)
        grounding.noteToolResult(#"{"found":true,"kind":"genre","id":7,"name":"Rap"}"#)
        let out = try await run("build_mix", """
            {"title":"  Late   drive\\n","seed_refs":["\(yt(1))","\(yt(99))"],"genre_ids":[5,5,0,7],"mood_ids":[],"year_from":2024,"year_to":2000,\
            "energy":"lower","tempo":"slow","novelty_share_pct":150,"length":500,"exclude_artist_refs":[]}
            """)
        let q = try #require(backend.mixQueries.first)
        #expect(q.title == "Late drive")
        #expect(q.seedRefs == [yt(1)])
        #expect(q.genreIds == [5, 7])
        #expect(q.yearFrom == 2000)
        #expect(q.yearTo == 2024)
        #expect(q.noveltySharePct == 100)
        #expect(q.count == AssistantRules.maxMix)
        #expect(q.energy == "lower")
        #expect(out["built"]?.boolValue == true)
        #expect(out["mix_id"]?.stringValue == "m1")
        #expect(out["total"]?.int64Value == 2)
        #expect(strings(out["refs_ignored"]) == [yt(99)])
        #expect(out["note"]?.stringValue?.contains("mix:m1") == true)
        // Both tracks were returned, so both may be named; one nobody returned may not.
        #expect(grounding.check("[[Espresso]] and [[Good Luck, Babe!]]", placeholder: "(?)").ok)
        #expect(!grounding.check("[[Please Please Please]]", placeholder: "(?)").ok)
    }

    @Test func buildMixSaysSoWhenTheEngineHasNothingToBuildFromAndNeverMakesAListItself() async throws {
        let out = try await run("build_mix", #"{"title":"x","seed_refs":[],"genre_ids":[],"mood_ids":[],"year_from":0,"year_to":0,"energy":"any","tempo":"any","novelty_share_pct":-1,"length":30,"exclude_artist_refs":[]}"#)
        #expect(out["built"]?.boolValue == false)
        #expect(out["tracks"] == nil)
        #expect(backend.mixQueries.first?.noveltySharePct == AssistantRules.shareUnset)
    }

    @Test func aMixListsAtMost25TracksButReportsHowManyItHolds() async throws {
        backend.mixTracks = (1...40).map { backend.add(yt($0), "Song \($0)", "Artist") }
        let out = try await run("build_mix", #"{"title":"big","seed_refs":[],"genre_ids":[],"mood_ids":[],"year_from":0,"year_to":0,"energy":"any","tempo":"any","novelty_share_pct":-1,"length":40,"exclude_artist_refs":[]}"#)
        #expect(out["total"]?.int64Value == 40)
        #expect(out["tracks"]?.arrayValue?.count == 25)
        // The count the tool vouches for is a number the reply may state.
        #expect(grounding.check("I made 40 songs for you.", placeholder: "(?)").ok)
        #expect(!grounding.check("I made 41 songs for you.", placeholder: "(?)").ok)
    }

    @Test func recommendReportsFiltersTheDataCouldNotAnswerInsteadOfIgnoringThemSilently() async throws {
        backend.mixTracks = [backend.add(yt(1), "Song", "Artist")]
        backend.unsupported = ["tempo"]
        let out = try await run("recommend", #"{"seed_refs":[],"genre_ids":[],"year_from":0,"year_to":0,"energy":"any","novelty":"new","count":10}"#)
        #expect(strings(out["filters_not_applied"]) == ["tempo"])
        #expect(out["picks"]?.arrayValue?.count == 1)
        #expect(out["picks"]?.arrayValue?[0]["why_key"]?.stringValue == "radio_fans")
        #expect(backend.recommendQueries.first?.novelty == "new")
    }

    // MARK: explain_*

    @Test func explainTrackListsWhatItDoesNotKnowAndInventsNoneOfIt() async throws {
        backend.explanation = AssistantTrackExplanation(ref: yt(1), title: "Song", artist: "Artist")
        grounding.noteTrack(AssistantTrack(ref: yt(1), title: "Song", artist: "Artist", inLibrary: false))
        let out = try await run("explain_track", #"{"ref":"\#(yt(1))"}"#)
        #expect(out["found"]?.boolValue == true)
        let unknown = strings(out["unknown"])
        for name in ["arm", "why", "top_factors", "genres", "year", "plays", "completion_rate"] { #expect(unknown.contains(name)) }
        #expect(out["arm"] == nil)
        #expect(out["top_factors"] == nil)
        let facts = try #require(out["facts"])
        #expect(facts["plays"] == nil)
        #expect(facts["year"] == nil)
        #expect(facts["completion_rate_pct"] == nil)
    }

    @Test func explainTrackReportsFactorsByNameAndDirectionOnlyWithTheRealNumbersItHas() async throws {
        backend.explanation = AssistantTrackExplanation(
            ref: yt(1), title: "Song", artist: "Artist", arm: "RADIO", whyKey: "radio_fans", whyArgs: ["Sabrina Carpenter"],
            factors: [AssistantRules.Factor(name: "you play this artist", up: true),
                      AssistantRules.Factor(name: "it is far from what you usually play", up: false)],
            genres: ["Pop"], year: 2024, plays: 12, completionRate: 0.75, genresSuggested: true)
        grounding.noteTrack(AssistantTrack(ref: yt(1), title: "Song", artist: "Artist", inLibrary: false))
        let out = try await run("explain_track", #"{"ref":"\#(yt(1))"}"#)
        let factors = try #require(out["top_factors"]?.arrayValue)
        #expect(factors[0]["name"]?.stringValue == "you play this artist")
        #expect(factors[0]["direction"]?.stringValue == "up")
        #expect(factors[1]["direction"]?.stringValue == "down")
        #expect(!JSONWriter.write(out).contains("weight"))
        #expect(out["facts"]?["completion_rate_pct"]?.int64Value == 75)
        #expect(out["unknown"]?.arrayValue?.isEmpty == true)
        // Genres a batch job suggested are said to be a suggestion; the factors are read under today's weights.
        #expect(out["facts"]?["genres_note"]?.stringValue?.contains("suggestion") == true)
        #expect(out["factors_note"]?.stringValue?.contains("as the engine ranks today") == true)
        #expect(grounding.check("You played it 12 times and finished 75% of them.", placeholder: "(?)").ok)
        #expect(!grounding.check("You played it 30 times.", placeholder: "(?)").ok)
    }

    @Test func explainTrackForATrackNothingIsRecordedAboutSaysSo() async throws {
        backend.explanation = nil
        let out = try await run("explain_track", #"{"ref":"\#(yt(5))"}"#)
        #expect(out["found"]?.boolValue == false)
        #expect(out["note"]?.stringValue?.contains("do not guess") == true)
    }

    @Test func explainTastePassesOnTheFactsAndTheUnknownsAsTheyAre() async throws {
        backend.taste = AssistantTasteExplanation(
            scope: "genres", lines: [AssistantTasteLine(name: "V-pop", value: "31% of plays"), AssistantTasteLine(name: "Hip hop", value: "12% of plays")],
            unknown: ["Taste islands need about 20 plays in the last 28 days."])
        let out = try await run("explain_taste", #"{"scope":"genres"}"#)
        #expect(out["facts"]?.arrayValue?.count == 2)
        #expect(out["unknown"]?.arrayValue?.count == 1)
        #expect(grounding.check("About [[V-pop]]: 31% of what you play.", placeholder: "(?)").ok)
        #expect(!grounding.check("You play 55% trap.", placeholder: "(?)").ok)
    }

    // MARK: The rest

    @Test func lookupGenreReturnsTheAtlasFactsOrTheNearestNamesAndNoIdOfItsOwn() async throws {
        backend.genre = AssistantGenreLookup(
            genre: AssistantGenreInfo(id: 7, name: "Vietnamese pop", description: "Pop sung in Vietnamese.",
                                      parents: [AssistantGenreRef(id: 1, name: "Pop")], related: [AssistantGenreRef(id: 8, name: "V-rap")],
                                      region: "Vietnam", era: 1990, descriptors: ["upbeat"]),
            nearest: [])
        let found = try await run("lookup_genre", #"{"query":"v-pop"}"#)
        #expect(found["id"]?.int64Value == 7)
        #expect(found["kind"]?.stringValue == "genre")
        #expect(found["parents"]?.arrayValue?[0]["name"]?.stringValue == "Pop")
        backend.genre = AssistantGenreLookup(genre: nil, nearest: [AssistantGenreRef(id: 3, name: "Trap"), AssistantGenreRef(id: 4, name: "Trap soul")])
        let miss = try await run("lookup_genre", #"{"query":"trapp"}"#)
        #expect(miss["found"]?.boolValue == false)
        #expect(miss["id"] == nil)
        #expect(miss["nearest"]?.arrayValue?.count == 2)
    }

    @Test func similarArtistsAndNewReleasesAreCappedAt25AndCarryTheirRefs() async throws {
        backend.similar = AssistantSimilarArtists(artists: (1...40).map {
            AssistantSimilarArtist(name: "Artist \($0)", ref: yt($0), score: 1.0 - Double($0) / 100.0, sources: ["radio"])
        })
        let s = try await run("similar_artists", #"{"artist":"X","count":50,"only_unplayed":false}"#)
        #expect(s["artists"]?.arrayValue?.count == 25)
        #expect(s["artists"]?.arrayValue?[0]["ref"]?.stringValue == yt(1))
        backend.releases = AssistantReleaseList(releases: (1...30).map { AssistantRelease(title: "Album \($0)", artist: "Artist", type: "album", year: 2026, ref: yt($0)) })
        let r = try await run("new_releases", #"{"scope":"my_artists","count":10}"#)
        #expect(r["releases"]?.arrayValue?.count == 10)
        #expect(grounding.check("[[Artist 3]] is close, and so is [[Artist 99]].", placeholder: "(?)").ungroundedNames == ["Artist 99"])
    }

    @Test func aStationFromASongNeedsARefAToolReturned() async throws {
        let made = try await run("start_station", #"{"seed_ref":"\#(yt(1))","seed_kind":"song","mode":"blend"}"#)
        #expect(made["started"]?.boolValue == false)
        #expect(backend.stationCalls.isEmpty)
        let name = try await run("start_station", #"{"seed_ref":"Espresso","seed_kind":"song","mode":"blend"}"#)
        #expect(name["reason"]?.stringValue?.contains("ref") == true)
        let info = backend.add(yt(1), "Espresso", "Sabrina Carpenter")
        grounding.noteTrack(info)
        backend.stationOutcome = AssistantStationOutcome(started: true, firstTrack: info)
        let ok = try await run("start_station", #"{"seed_ref":"\#(yt(1))","seed_kind":"song","mode":"discover"}"#)
        #expect(ok["started"]?.boolValue == true)
        #expect(backend.stationCalls.first == [yt(1), "song", "discover"])
        #expect(ok["first_track"]?["title"]?.stringValue == "Espresso")
        // An artist or a genre is named, not a ref.
        _ = try await run("start_station", #"{"seed_ref":"Radiohead","seed_kind":"artist","mode":"blend"}"#)
        #expect(backend.stationCalls.last?[1] == "artist")
    }

    @Test func steerReportsWhatChangedAndWhatItCouldNot() async throws {
        backend.steerOutcome = AssistantSteerOutcome(applied: true, tailChanged: 5, note: "Put 5 songs next.")
        let out = try await run("steer_session", #"{"change":"energy_down","target":"","scope":"session"}"#)
        #expect(out["applied"]?.boolValue == true)
        #expect(out["tail_changed"]?.int64Value == 5)
        #expect(backend.steerCalls.first == ["energy_down", "", "session"])
    }

    // MARK: Cards under the answer (stage 4 milestone 2)

    private let mixInput = #"{"title":"Late drive","seed_refs":[],"genre_ids":[],"mood_ids":[],"year_from":0,"year_to":0,"energy":"any","tempo":"any","novelty_share_pct":-1,"length":30,"exclude_artist_refs":[]}"#

    @Test func aBuiltMixGivesOneCardThatIsTakenOnceAndKeptForItsButtons() async throws {
        backend.mixTracks = (1...12).map { backend.add(yt($0), "Song \($0)", "Mono") }
        _ = try await run("build_mix", mixInput)
        let cards = await runner.takeNewMixCards()
        #expect(cards.count == 1 && cards[0].mixId == "m1" && cards[0].title == "Late drive" && cards[0].total == 12)
        #expect(await runner.takeNewMixCards().isEmpty, "a card is shown once")
        #expect(await runner.mixCard("m1")?.total == 12, "its buttons find it again")
        #expect(await runner.mixTitle("m1") == "Late drive")
        #expect(await runner.mixTitle("nope") == "Made for you")
    }

    @Test func aChipChangesTheStoredRequestOnTheDeviceAndTheNewTracksMayBeNamed() async throws {
        backend.mixTracks = (1...40).map { backend.add(yt($0), "Song \($0)", "Mono") }
        _ = try await run("build_mix", mixInput)
        let shorter = AssistantRules.Chip(kind: AssistantRules.chipShorter)
        let next = try #require(await runner.adjustMix(mixId: "m1", chip: shorter))
        #expect(next.total == 20, "Shorter takes ten off")
        #expect(backend.adjustCalls == ["m1"])
        #expect(backend.mixQueries.count == 1, "no second build_mix call: a chip is not a tool call")
        #expect(grounding.check("[[Song 7]]", placeholder: "(?)").ok)
        // A card of a mix this chat never built has no chip to apply.
        #expect(await runner.adjustMix(mixId: "zzz", chip: shorter) == nil)
    }

    @Test func onlyTheSixteenNewestMixesKeepTheirCards() async throws {
        backend.mixTracks = [backend.add(yt(1), "Song 1", "Mono")]
        for _ in 0..<10 { _ = try await run("build_mix", mixInput) }
        // The fake reuses one id, so one card is held; the limit itself is the constant.
        #expect(MusicToolRunner.maxMixes == 16)
        #expect(await runner.mixCard("m1") != nil)
    }

    @Test func theExplainToolsNameOnlyWhatTheyReturnedForLessX() async throws {
        backend.explanation = AssistantTrackExplanation(ref: yt(1), title: "Song", artist: "Mono, Clairo", genres: ["Trap", "Pop"])
        grounding.noteTrack(AssistantTrack(ref: yt(1), title: "Song", artist: "Mono, Clairo", inLibrary: false))
        _ = try await run("explain_track", "{\"ref\":\"\(yt(1))\"}")
        backend.taste = AssistantTasteExplanation(scope: "genres", lines: [AssistantTasteLine(name: "Hip Hop", value: "30% of plays", isGenre: true),
                                                                          AssistantTasteLine(name: "Late night", value: "x")], unknown: [])
        _ = try await run("explain_taste", #"{"scope":"genres"}"#)
        let named = await runner.namedThisTurn()
        #expect(named.contains(AssistantCards.Named(kind: AssistantCards.namedArtist, name: "Mono")))
        #expect(!named.contains { $0.name == "Clairo" }, "only the primary artist")
        #expect(named.contains(AssistantCards.Named(kind: AssistantCards.namedGenre, name: "Trap")))
        #expect(named.contains(AssistantCards.Named(kind: AssistantCards.namedGenre, name: "Hip Hop")))
        #expect(!named.contains { $0.name == "Late night" }, "a line that is not a genre is not offered")
        await runner.beginTurn()
        #expect(await runner.namedThisTurn().isEmpty, "a new turn starts empty")
    }

    // MARK: The review (stage 4 milestone 2)

    @Test func aGenreOrMoodIdNoLookupReturnedInThisChatIsLeftOutAndSaid() async throws {
        backend.mixTracks = [backend.add(yt(1), "Song", "Artist")]
        // Written from memory: nothing filters the list to whatever genre 12 is, and the model is told.
        let guessed = try await run("recommend", #"{"seed_refs":[],"genre_ids":[12],"year_from":0,"year_to":0,"energy":"any","novelty":"any","count":10}"#)
        #expect(backend.recommendQueries.last?.genreIds == [])
        #expect(strings(guessed["ids_ignored"]) == ["genre 12"])
        // After lookup_genre returned it, it is used; a mood id is not a genre id.
        backend.genre = AssistantGenreLookup(genre: AssistantGenreInfo(id: 12, name: "Bedroom pop"), nearest: [])
        _ = try await run("lookup_genre", #"{"query":"bedroom pop"}"#)
        let known = try await run("build_mix", """
            {"title":"x","seed_refs":[],"genre_ids":[12],"mood_ids":[12],"year_from":0,"year_to":0,"energy":"any","tempo":"any",\
            "novelty_share_pct":-1,"length":30,"exclude_artist_refs":[]}
            """)
        #expect(backend.mixQueries.last?.genreIds == [12])
        #expect(backend.mixQueries.last?.moodIds == [])
        #expect(strings(known["ids_ignored"]) == ["mood 12"])
        // A steer by genre needs an id of this chat too.
        let steered = try await run("steer_session", #"{"change":"more_genre","target":"99","scope":"session"}"#)
        #expect(steered["applied"]?.boolValue == false)
        #expect(backend.steerCalls.isEmpty)
        _ = try await run("steer_session", #"{"change":"more_genre","target":"12","scope":"session"}"#)
        #expect(backend.steerCalls.last == ["more_genre", "12", "session"])
    }

    @Test func aRefFromSimilarArtistsOrNewReleasesMaySeedTheNextCallButOneFromNowhereMayNot() async throws {
        backend.similar = AssistantSimilarArtists(artists: [AssistantSimilarArtist(name: "Mono", ref: yt(1), score: 1)])
        let out = try await run("similar_artists", #"{"artist":"X","count":5,"only_unplayed":false}"#)
        // A position, not a percentage: the closest is always first and its edge may be weak.
        #expect(out["artists"]?.arrayValue?[0]["rank"]?.int64Value == 1)
        #expect(out["artists"]?.arrayValue?[0]["score"] == nil)
        backend.mixTracks = [backend.add(yt(2), "Song", "Artist")]
        _ = try await run("recommend", #"{"seed_refs":["\#(yt(1))","\#(yt(7))"],"genre_ids":[],"year_from":0,"year_to":0,"energy":"any","novelty":"any","count":10}"#)
        #expect(backend.recommendQueries.last?.seedRefs == [yt(1)])
        // A ref that no tool of this chat returned is refused for a station, a steer and an explanation alike.
        let station = try await run("start_station", #"{"seed_ref":"\#(yt(7))","seed_kind":"song","mode":"blend"}"#)
        #expect(station["started"]?.boolValue == false)
        let steer = try await run("steer_session", #"{"change":"more_artist","target":"\#(yt(7))","scope":"session"}"#)
        #expect(steer["applied"]?.boolValue == false)
        let explain = try await run("explain_track", #"{"ref":"\#(yt(7))"}"#)
        #expect(explain["found"]?.boolValue == false)
        #expect(explain["note"]?.stringValue?.contains("not returned") == true)
        // A history of an older chat brings its refs back.
        let again = TaizoGrounding()
        again.noteHistory([.object(JSONObject([(key: "role", value: .string("user")), (key: "content", value: .array([
            .object(JSONObject([(key: "type", value: .string("tool_result")), (key: "content", value: .string(#"{"artists":[{"name":"Mono","ref":"\#(yt(1))"}]}"#))])),
        ]))]))])
        #expect(again.isKnownRef(yt(1)))
    }

    @Test func seedsNoRadioCouldBeHadForAreSaidAndNeverHiddenBehindAListThatDoesNotFollowThem() async throws {
        backend.notUsed = [yt(1)]
        backend.mixTracks = [backend.add(yt(2), "Song", "Artist")]
        grounding.noteTrack(AssistantTrack(ref: yt(1), title: "Espresso", artist: "Sabrina Carpenter", inLibrary: false))
        let mix = try await run("build_mix", mixInput.replacingOccurrences(of: #""seed_refs":[]"#, with: #""seed_refs":["\#(yt(1))"]"#))
        #expect(strings(mix["seeds_not_used"]) == [yt(1)])
        #expect(mix["seeds_note"]?.stringValue?.contains("do not say the list is like them") == true)
        let rec = try await run("recommend", #"{"seed_refs":["\#(yt(1))"],"genre_ids":[],"year_from":0,"year_to":0,"energy":"any","novelty":"any","count":10}"#)
        #expect(strings(rec["seeds_not_used"]) == [yt(1)])
        let card = try #require(await runner.takeNewMixCards().first)
        #expect(card.seedsNotUsed == 1, "the card says so too")
    }

    @Test func aChipTakesTheOldCardsPlaceAndAMixDoesNotCountWhatItDropped() async throws {
        backend.mixTracks = (1...40).map { backend.add(yt($0), "Song \($0)", "Mono") }
        _ = try await run("build_mix", mixInput)
        let next = try #require(await runner.adjustMix(mixId: "m1", chip: AssistantRules.Chip(kind: AssistantRules.chipShorter)))
        #expect(next.mixId == "m2")
        #expect(await runner.mixCard("m1") == nil, "the replaced card does not use up one of the slots")
        #expect(await runner.mixCard("m2") != nil)
    }

    @Test func aSearchThatCouldNotBeMadeIsNotReportedAsASongThatDoesNotExist() async throws {
        backend.failedTitles = ["Espresso"]
        let out = try await run("resolve_tracks", #"{"items":[{"title":"Espresso","artist":"Sabrina Carpenter"}]}"#)
        let r = try #require(out["results"]?.arrayValue?.first)
        #expect(r["not_found"]?.boolValue == true)
        #expect(r["reason"]?.stringValue?.contains("does not mean the song does not exist") == true)
    }

    @Test func aStationThatChangedTheSwitchSaysSoAndSteerNamesOneArtistNotAComma() async throws {
        let info = backend.add(yt(1), "Espresso", "Sabrina Carpenter")
        grounding.noteTrack(info)
        backend.stationOutcome = AssistantStationOutcome(started: true, firstTrack: info, note: "The Familiar / Blend / Discover switch is now on Discover. Tell the user.")
        let ok = try await run("start_station", #"{"seed_ref":"\#(yt(1))","seed_kind":"song","mode":"discover"}"#)
        #expect(ok["note"]?.stringValue?.contains("switch is now on Discover") == true)
        // "Tyler, The Creator" is one artist: the one-tap Less offers that name, never "Tyler".
        backend.explanation = AssistantTrackExplanation(ref: yt(2), title: "EARFQUAKE", artist: "Tyler, The Creator", primaryArtist: "Tyler, The Creator")
        grounding.noteTrack(AssistantTrack(ref: yt(2), title: "EARFQUAKE", artist: "Tyler, The Creator", inLibrary: false))
        _ = try await run("explain_track", #"{"ref":"\#(yt(2))"}"#)
        let named = await runner.namedThisTurn()
        #expect(named.contains(AssistantCards.Named(kind: AssistantCards.namedArtist, name: "Tyler, The Creator")))
        #expect(!named.contains { $0.name == "Tyler" })
    }

    @Test func anUnknownToolNameIsAnErrorNotACrash() async throws {
        let out = try await run("nope", "{}")
        #expect(out["error"] != nil)
        #expect(!MusicToolRunner.handles("nope"))
        #expect(MusicToolRunner.handles("recommend"))
    }
}
