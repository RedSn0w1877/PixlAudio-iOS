import Foundation
import Testing
@testable import PixlLibrary

/// Track DNA on disk (docs/brain-spec.md, 3.8): the three record files, their versions, and a stage 1 or 2a install that
/// has none of them.
@Suite("Track DNA store")
struct DnaStoreTests {
    func row(_ rid: Int64, spotifyId: String? = nil, tags: [UInt8] = [], tagsAtMs: Int64 = 0, popAtMs: Int64 = 0, mask: Int = 0,
             updatedAtMs: Int64 = 0) -> TrackDnaRow {
        TrackDnaRow(rid: rid, spotifyId: spotifyId, title: "T\(rid)", firstYear: 1999, tags: Data(tags), fetchedMask: mask, updatedAtMs: updatedAtMs,
                    tagsAtMs: tagsAtMs, popAtMs: popAtMs, tagInputs: Data([1, 0, 5, 200]), yearClaims: "1:1999", popClaims: "d:500")
    }

    @Test func aStageOneInstallHasNoFilesAndIsAnEmptyStore() async {
        let dir = makeTempDirectory()
        let store = DnaRepository(directory: dir)
        #expect(await store.count() == 0)
        #expect(await store.track(1) == nil)
        #expect(await store.coverage() == DnaCoverage())
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("track_dna.pbl").path), "reading creates nothing")
    }

    @Test func rowsComeBackAfterARestartWithTheirBytes() async throws {
        let dir = makeTempDirectory()
        let store = DnaRepository(directory: dir)
        let r = row(7, spotifyId: "sp7", tags: [0, 5, 200])
        let artist = ArtistDnaRow(aid: 3, mbid: "m", name: "Band", country: "GB", tags: Data([0, 9, 255]), tagInputs: Data([2, 0, 9, 255]))
        #expect(await store.upsert(track: r, artist: artist))
        let again = DnaRepository(directory: dir)
        #expect(await again.track(7) == r)
        #expect(await again.artists([3]) == [artist])
        #expect(await again.knownSpotifyIds(["sp7", "sp8"]) == ["sp7"])
        #expect(await again.artistCountWithTags() == 1)
    }

    @Test func aRecordOfAVersionThisCodeDoesNotKnowIsSkippedNotRead() async throws {
        let dir = makeTempDirectory()
        var future = row(8)
        future.v = TrackDnaRow.formatVersion + 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let file = KeyedLogStore(url: dir.appendingPathComponent("track_dna.pbl"))
        file.put("8", [UInt8](try encoder.encode(future)))
        file.put("9", [UInt8](try encoder.encode(row(9))))
        file.put("10", Array("{\"v\":1,\"junk\":".utf8))
        let store = DnaRepository(directory: dir)
        #expect(await store.track(8) == nil)
        #expect(await store.track(9) != nil)
        #expect(await store.track(10) == nil)
        #expect(await store.count() == 1)
    }

    @Test func expiredRowsAreTheStalestFirstAndFreshOnesAreLeftAlone() async {
        let store = DnaRepository(directory: makeTempDirectory())
        let day: Int64 = 86_400_000
        let now: Int64 = 1_795_000_000_000
        let all = DnaSource.deezer | DnaSource.musicbrainz | DnaSource.itunes
        _ = await store.upsert(track: row(1, tagsAtMs: now - 100 * day, popAtMs: now, mask: all, updatedAtMs: now - 5 * day), artist: nil)
        _ = await store.upsert(track: row(2, tagsAtMs: now, popAtMs: now - 10 * day, mask: all, updatedAtMs: now - 9 * day), artist: nil)
        _ = await store.upsert(track: row(3, tagsAtMs: now, popAtMs: now, mask: all, updatedAtMs: now), artist: nil)
        _ = await store.upsert(track: row(4, tagsAtMs: now, popAtMs: now, mask: DnaSource.deezer, updatedAtMs: now - 3 * day), artist: nil)
        _ = await store.upsert(track: row(5, tagsAtMs: now, popAtMs: now, mask: DnaSource.deezer, updatedAtMs: now - 3_600_000), artist: nil)
        let due = await store.expired(tagsBefore: now - 90 * day, popBefore: now - 7 * day, retryBefore: now - day, limit: 10)
        #expect(due.map(\.rid) == [2, 1, 4], "stalest first; row 3 is fresh and row 5 was looked at an hour ago")
        #expect(await store.expired(tagsBefore: now - 90 * day, popBefore: now - 7 * day, retryBefore: now - day, limit: 2).count == 2)
    }

    @Test func coverageCountsWhatIsKnownAndNotWhatIsGuessed() async {
        let store = DnaRepository(directory: makeTempDirectory())
        _ = await store.upsert(track: row(1, tags: [0, 5, 200]), artist: nil)
        var blank = row(2)
        blank.firstYear = 0
        _ = await store.upsert(track: blank, artist: nil)
        let c = await store.coverage()
        #expect(c.tracks == 2)
        #expect(c.withTags == 1)
        #expect(c.withYear == 1)
        #expect(c.withPopularity == 0)
        #expect(c.withEnergy == 0)
        #expect(c.withTempo == 0)
    }

    @Test func theNegativeCacheKeepsItsCountAndPrunesWhatEndedLongAgo() async {
        let store = DnaRepository(directory: makeTempDirectory())
        let now: Int64 = 1_795_000_000_000
        await store.putMiss(entity: "t:1", source: 0, retryAfterMs: now + 1000, misses: 3)
        await store.putMiss(entity: "t:2", source: 0, retryAfterMs: now - 200 * 86_400_000, misses: 1)
        #expect(await store.misses(entity: "t:1", source: 0) == 3)
        #expect(await store.activeMissCount(nowMs: now) == 1)
        #expect(await store.pruneMisses(nowMs: now) == 1)
        #expect(await store.misses(entity: "t:2", source: 0) == 0)
    }
}
