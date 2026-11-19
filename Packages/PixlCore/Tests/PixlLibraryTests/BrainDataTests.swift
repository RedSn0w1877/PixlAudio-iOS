import Foundation
import Testing
@testable import PixlLibrary

/// What Brain data shows (docs/brain-spec.md, 3.7 and 12), read from fakes.
@Suite("Brain data")
struct BrainDataTests {
    func reader(dna: DnaRepository, ledger: KnowledgeLedger, clock: KnowledgeClock, local: @escaping @Sendable (KnowledgeHost) -> Bool = { _ in true },
                remote: @escaping @Sendable (KnowledgeHost) -> Bool = { _ in true }, atlas: any AtlasProvider = FixtureAtlas()) -> BrainDataReader {
        BrainDataReader(dna: dna, ledger: ledger, atlas: atlas, localEnabled: local, remoteAllowed: remote,
                        youTubeToday: { 7 }, spotifyArtists: { (total: 4, withGenres: 3) }, spotifyShapes: { true },
                        lastNote: { "1795000000000|r5+3|a1+0|n0+2|m4|d7+8+9|time" }, clock: clock.read)
    }

    @Test func theReportHoldsTheAtlasWhatIsKnownAndEachSource() async throws {
        let clock = KnowledgeClock()
        let dna = DnaRepository(directory: makeTempDirectory())
        let ledger = KnowledgeLedger(store: MemoryValueStore(), clock: clock.read)
        await ledger.record(.deezer, nowMs: clock.now - 60_000)
        await ledger.record(.deezer, nowMs: clock.now - 120_000)
        _ = await dna.upsert(track: TrackDnaRow(rid: 1, firstYear: 2001, tags: Data([0, 5, 200]), fetchedMask: DnaSource.deezer | DnaSource.itunes), artist: nil)
        _ = await dna.upsert(track: TrackDnaRow(rid: 2, fetchedMask: DnaSource.deezer), artist: ArtistDnaRow(aid: 4, name: "A", tags: Data([0, 5, 200])))
        let r = await reader(dna: dna, ledger: ledger, clock: clock, local: { $0 != .itunes }, remote: { $0 != .wikidata }).read()
        #expect(r.atlasLoaded)
        #expect(r.atlasGenres == 2249 && r.atlasFamilies == 24 && r.atlasVersion == 1)
        #expect(r.atlasDescribed > 100)
        #expect(r.coverage.tracks == 2 && r.coverage.withTags == 1 && r.coverage.withYear == 1)
        #expect(r.artistsKnown == 1 && r.artistsWithGenres == 1)
        #expect(r.sources.map(\.host) == KnowledgeHost.allCases)
        let deezer = try #require(r.sources.first { $0.host == .deezer })
        #expect(deezer.requestsToday == 2 && deezer.tracksAnswered == 2 && deezer.lastRequestMs == clock.now - 60_000)
        #expect(deezer.switchIsOn)
        #expect(try #require(r.sources.first { $0.host == .itunes }).switchIsOn == false, "the local switch is off")
        let wikidata = try #require(r.sources.first { $0.host == .wikidata })
        #expect(wikidata.enabled && !wikidata.remoteAllowed && !wikidata.switchIsOn, "off for every phone shows off")
        #expect(r.youTubeToday == 7 && r.spotifyArtistSeeds == 4 && r.spotifyArtistSeedsWithGenres == 3)
        #expect(r.lastRun?.tracksEnriched == 24 && r.lastRun?.stopped == "time")
    }

    @Test func aMissingAtlasIsSaidNotHidden() async {
        let clock = KnowledgeClock()
        let r = await reader(dna: DnaRepository(directory: makeTempDirectory()),
                             ledger: KnowledgeLedger(store: MemoryValueStore(), clock: clock.read), clock: clock,
                             atlas: FixtureAtlas(value: nil)).read()
        #expect(!r.atlasLoaded)
        #expect(r.coverage.tracks == 0)
    }

    @Test func percentsAndAgoWordsFollowAndroid() {
        #expect(BrainDataFormat.percent(1, of: 3) == 33)
        #expect(BrainDataFormat.percent(5, of: 0) == 0)
        #expect(BrainDataFormat.ago(nowMs: 100_000, thenMs: 99_000) == .now)
        #expect(BrainDataFormat.ago(nowMs: 3_600_000, thenMs: 0) == .hours(1))
        #expect(BrainDataFormat.ago(nowMs: 59 * 60_000, thenMs: 0) == .minutes(59))
        #expect(BrainDataFormat.ago(nowMs: 47 * 3_600_000, thenMs: 0) == .hours(47))
        #expect(BrainDataFormat.ago(nowMs: 72 * 3_600_000, thenMs: 0) == .days(3))
        #expect(BrainDataFormat.ago(nowMs: 0, thenMs: 5_000_000) == .now, "a clock that went back never reads as the future")
        #expect(BrainDataFormat.stop("TIME") == .time)
        #expect(BrainDataFormat.stop("playing") == .playing)
        #expect(BrainDataFormat.stop("none") == .done)
    }
}
