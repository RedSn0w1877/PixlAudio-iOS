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
            genres: ["Pop"], year: 2024, plays: 12, completionRate: 0.75)
        let out = try await run("explain_track", #"{"ref":"\#(yt(1))"}"#)
        let factors = try #require(out["top_factors"]?.arrayValue)
        #expect(factors[0]["name"]?.stringValue == "you play this artist")
        #expect(factors[0]["direction"]?.stringValue == "up")
        #expect(factors[1]["direction"]?.stringValue == "down")
        #expect(!JSONWriter.write(out).contains("weight"))
        #expect(out["facts"]?["completion_rate_pct"]?.int64Value == 75)
        #expect(out["unknown"]?.arrayValue?.isEmpty == true)
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

    @Test func anUnknownToolNameIsAnErrorNotACrash() async throws {
        let out = try await run("nope", "{}")
        #expect(out["error"] != nil)
        #expect(!MusicToolRunner.handles("nope"))
        #expect(MusicToolRunner.handles("recommend"))
    }
}
