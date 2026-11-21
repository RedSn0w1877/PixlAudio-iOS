import Foundation
import PixlFoundation
import Testing
@testable import PixlLibrary

/// Stage 2b, the independent review of the iOS side: what turning the Spotify switch off removes, what the island fit may read,
/// the plan that owns Home, the shelf that is not shown twice, and the names that are hidden. The island files and the fit are
/// tested in `BrainStage2bM2Tests`.
@Suite("Brain stage 2b, review fixes")
struct BrainStage2bReviewFixesTests {
    let atlas = KnowledgeFixtures.atlas
    let now: Int64 = 1_795_000_000_000

    func id(_ name: String) -> Int {
        let v = atlas.idForName(name)
        #expect(v >= 0, "\(name) is not in the atlas")
        return v
    }

    func target(_ rid: Int64 = 1, aid: Int64 = 5, genres: [String] = [], date: String? = nil, off: Bool = false) -> DnaTarget {
        DnaTarget(rid: rid, aid: aid, spotifyId: "sp\(rid)", title: "Song \(rid)", artist: "Band", durationMs: 180_000,
                  spotifyReleaseDate: date, spotifyGenres: genres, spotifyOff: off)
    }

    func assemble(_ t: DnaTarget, prior: TrackDnaRow? = nil, priorArtist: ArtistDnaRow? = nil, evidence: DnaEvidence = DnaEvidence(),
                  at: Int64? = nil) -> DnaAssembler.Result {
        DnaAssembler.assemble(target: t, evidence: evidence, prior: prior, priorArtist: priorArtist, atlas: atlas, atlasVersion: 1,
                              nowMs: at ?? now, maxYear: 2027)
    }

    // MARK: The Spotify switch

    @Test func withTheSwitchOffSpotifyGenresAndTheSpotifyYearAreTakenOutOfAStoredRow() {
        let on = assemble(target(genres: ["shoegaze"], date: "1991-09-24"))
        #expect(on.track.tagVector.top == id("shoegaze"))
        #expect(on.track.firstYear == 1991 && on.track.yearSource == TrackDna.yearSpotify)
        #expect(on.track.fetchedMask & DnaSource.spotifyGenres != 0)
        #expect(DnaAssembler.carriesSpotify(on.track))
        // The same row assembled with the switch off: the claims, the tags built from them, the year and the "asked" bit are gone.
        let off = assemble(target(genres: ["shoegaze"], date: "1991-09-24", off: true), prior: on.track, priorArtist: on.artist, at: now + 1)
        #expect(off.track.tagVector.isEmpty, "no genre: unknown stays unknown")
        #expect(off.track.firstYear == 0)
        #expect(off.track.fetchedMask & DnaSource.spotifyGenres == 0)
        #expect(!DnaAssembler.carriesSpotify(off.track))
        #expect(off.artist.map { !DnaAssembler.carriesSpotify($0) && $0.tags.isEmpty } == true)
    }

    @Test func otherSourcesKeepTheirGenresWhenOnlySpotifyIsTakenOut() {
        let mb = MbGenreVote(name: "techno", mbid: atlas.genre(id("techno"))?.mbid ?? "", count: 9)
        let evidence = DnaEvidence(mbArtist: MbArtist(mbid: "m1", name: "Band", country: "GB", genres: [mb]), tried: DnaSource.musicbrainz)
        let on = assemble(target(genres: ["shoegaze"]), evidence: evidence)
        #expect(Set(on.track.tagVector.tags.map(\.atlasId)).isSuperset(of: [id("techno"), id("shoegaze")]))
        let off = assemble(target(genres: ["shoegaze"], off: true), prior: on.track, priorArtist: on.artist, at: now + 1)
        let ids = off.track.tagVector.tags.map(\.atlasId)
        #expect(ids.contains(id("techno")) && !ids.contains(id("shoegaze")))
    }

    @Test func theIslandFitReadsNoGenreOnlySpotifyGave() {
        let on = assemble(target(genres: ["shoegaze"]))
        // No other source: with Spotify taken away the track has no tags for the fit; the stored vector is untouched.
        #expect(DnaAssembler.tagVectorWithoutSpotify(on.track, atlas: atlas, atlasVersion: 1).isEmpty)
        #expect(!on.track.tagVector.isEmpty)
        // A row without any Spotify claim is read as it is stored; one written with another atlas gives nothing.
        let itunes = assemble(target(), evidence: DnaEvidence(itunes: ITunesSong(trackName: "Song 1", artistName: "Band", durationMs: 180_000,
                                                                                genre: "Alternative", releaseDate: nil, explicit: nil),
                                                              tried: DnaSource.itunes))
        #expect(DnaAssembler.tagVectorWithoutSpotify(itunes.track, atlas: atlas, atlasVersion: 1) == itunes.track.tagVector)
        #expect(DnaAssembler.tagVectorWithoutSpotify(itunes.track, atlas: atlas, atlasVersion: 2).isEmpty)
    }

    @Test func thePurgeRewritesTheRowsOnceWhenTheSwitchIsOffAndAsksForARefit() async throws {
        let dir = BrainStage2bM2Tests.tempDirectory("purge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DnaRepository(directory: dir)
        let a = assemble(target(1, genres: ["shoegaze"], date: "1991"))
        let b = assemble(target(2, aid: 6, genres: ["techno"]))
        let clean = assemble(target(3, aid: 7))
        for r in [a, b, clean] { await store.upsert(track: r.track, artist: r.artist) }
        let shapes = BrainStage2bM2Tests.Box<Bool>(true)
        let values = BrainStage2bM2Tests.Values()
        let refits = BrainStage2bM2Tests.Box<Int>(0)
        let purge = SpotifyDnaPurge(shapesPicks: { shapes.value }, store: store, atlas: FixtureAtlas(), state: values.state, clock: { self.now })
        #expect(await purge.run(markRefit: { refits.value += 1 }) == 0, "the switch is on: nothing leaves")
        shapes.value = false
        let changed = await purge.run(markRefit: { refits.value += 1 })
        #expect(changed >= 2)
        #expect(refits.value == 1)
        let rows = await store.spotifyCarriers()
        #expect(rows.tracks.isEmpty && rows.artists.isEmpty)
        #expect(await store.track(1)?.firstYear == 0)
        #expect(await store.track(1)?.tagVector.isEmpty == true)
        // Once: a second run finds it done. Switched on and off again, it runs again.
        #expect(await purge.run(markRefit: { refits.value += 1 }) == 0)
        shapes.value = true
        _ = await purge.run(markRefit: { refits.value += 1 })
        #expect(await values.state.get(SpotifyDnaPurge.keyPurged) == "0")
        #expect(refits.value == 1)
    }

    @Test func aTrackRowIsWrittenAfterItsArtistRowSoAKillNeverLeavesTheTrackDoneAndTheArtistLost() async throws {
        let dir = BrainStage2bM2Tests.tempDirectory("dna-order")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DnaRepository(directory: dir)
        let r = assemble(target(1))
        #expect(await store.upsert(track: r.track, artist: r.artist))
        let again = DnaRepository(directory: dir)
        #expect(await again.track(1) != nil)
        #expect(await again.artists([5]).count == 1)
        #expect(await again.revision() == 0, "a fresh reader has written nothing")
        await again.upsert(track: r.track, artist: r.artist)
        #expect(await again.revision() == 2)
    }

    // MARK: Names the listener may read

    @Test func aGenreNameWithABannedWordIsNeverShownAndTheAtlasIsNotChanged() {
        #expect(AtlasNames.isShown("shoegaze"))
        #expect(!AtlasNames.isShown("atmospheric black metal"), "hides by substring, like the copy test")
        #expect(!AtlasNames.isShown("Enhanced dance"))
        #expect(!AtlasNames.isShown("learning pop"))
        #expect(!AtlasNames.isShown("  "))
        #expect(!AtlasNames.isShown(nil))
        #expect(AtlasNames.genreName(atlas, id("shoegaze")) == "shoegaze")
    }

    // MARK: The plan

    @Test func aPlanOwnsHomeOnlyWhenItHasSomethingToShowAndShrinksUnderTheFileLimit() {
        let empty = HomePlan(generatedAtMs: 1, planKey: 1)
        #expect(!empty.hasContent, "a plan with no hero, mix or shelf is saved but does not own Home")
        let mix = PlanMix(mixId: "your", kind: MixKinds.your, count: 30, covers: ["a", "b", "c"])
        #expect(HomePlan(generatedAtMs: 1, planKey: 1, mixes: [mix]).hasContent)
        let items = (0..<12).map { PlanItem(rid: Int64($0 + 1), aid: 1, songId: "s\($0)", arm: Arm.fav, slot: $0) }
        let shelf = PlanShelf(type: HomePlanner.onRepeat, id: "on_repeat", titleKey: "on_repeat", items: items)
        let big = HomePlan(generatedAtMs: 1, planKey: 1, mixes: [mix], shelves: [shelf])
        let small = big.shrunk(maxItems: 6)
        #expect(small.shelves[0].items.count == 6 && small.mixes[0].covers.count == 2)
        #expect(big.shelves[0].items.count == 12, "the original is a value and unchanged")
    }

    @Test func aPlanFromBeforeTheIslandStampReadsAsNoIslandsAndIsDueOnceIslandsExist() throws {
        let data = Data(#"{"planVersion":1,"generatedAtMs":5,"planKey":9,"mixes":[],"shelves":[]}"#.utf8)
        let plan = try JSONDecoder().decode(HomePlan.self, from: data)
        #expect(plan.islandFitAtMs == 0)
        let round = try JSONDecoder().decode(HomePlan.self, from: JSONEncoder().encode(HomePlan(generatedAtMs: 5, planKey: 9, islandFitAtMs: 77)))
        #expect(round.islandFitAtMs == 77)
    }

    @Test func aPlanSavedBeforeTheEndlessCardIsStillReadAndIsDueAtOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("homeplan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HomePlanStore(directory: dir)
        let old = Data(#"{"planVersion":1,"generatedAtMs":5,"planKey":9,"mixes":[],"shelves":[]}"#.utf8)
        try old.write(to: dir.appendingPathComponent(HomePlanStore.fileName))
        let read = await store.read()
        #expect(read?.planVersion == 1, "shown at once, not thrown away")
        let fresh = HomePlan(generatedAtMs: 5, planKey: 9)
        #expect(fresh.planVersion == HomePlan.version && HomePlan.version > 1)
        #expect(await store.write(fresh))
        #expect(await store.read()?.planVersion == HomePlan.version)
        // A file from a newer build than this one is not read.
        let newer = Data(#"{"planVersion":99,"generatedAtMs":5,"planKey":9,"mixes":[],"shelves":[]}"#.utf8)
        try newer.write(to: dir.appendingPathComponent(HomePlanStore.fileName))
        #expect(await store.read() == nil)
    }

    @Test func onlyTheNewestBuildOfEachListIsTakenAwayFromTheOthers() {
        let log = [
            Repetition.Served(surface: 1, builtAtMs: 100, rids: [1, 2], surfaceId: "daily:1"),
            Repetition.Served(surface: 1, builtAtMs: 200, rids: [3], surfaceId: "daily:1"),
            Repetition.Served(surface: 1, builtAtMs: 150, rids: [9], surfaceId: "daily:2"),
        ]
        let newest = ServedListStore.newestPerList(log)
        #expect(newest.count == 2)
        #expect(newest.first { $0.surfaceId == "daily:1" }?.rids == [3], "the rebuilt list replaced its earlier build")
        #expect(newest.map(\.builtAtMs) == [150, 200])
    }
}
