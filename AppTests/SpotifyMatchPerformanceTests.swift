import Foundation
import PixlNet
import XCTest
@testable import PixlAudio

/// The Spotify matcher's store work (docs/performance.md): a keyset page reads a page's worth of rows, a batch of
/// matches is one save, and the counters read only the id column.
final class SpotifyMatchPerformanceTests: XCTestCase {
    private func row(_ spotifyId: String, playlist: String, state: SpotifyMatchState = .pending,
                     video: String? = nil) -> SpotifyTrackRecord {
        SpotifyTrackRecord(id: "\(playlist)_\(spotifyId)", spotifyId: spotifyId, playlistId: playlist,
                           title: "Song \(spotifyId)", artist: "Luma Vale", album: "City", albumId: "al1",
                           durationMs: 200_000, albumArtUrl: nil, isrc: nil, dateAdded: 1_000, matchedVideoId: video,
                           matchScore: video == nil ? nil : 0.9, matchState: state, genre: "pop")
    }

    /// 1,200 tracks over 3 playlists = 3,600 rows (a 200-track playlist repeats in the others); every third matched.
    private func seeded(tracks: Int = 1_200) async throws -> (PersistenceActor, pending: [String]) {
        let persistence = PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: true))
        var pending: [String] = []
        for playlist in ["p1", "p2", "p3"] {
            var rows: [SpotifyTrackRecord] = []
            for index in 0..<tracks {
                // p2 and p3 hold the same tracks as p1 for the first 800 ids, so the page has to skip repeats.
                guard playlist == "p1" || index < 800 else { continue }
                let id = String(format: "t%05d", index)
                let matched = index % 3 == 0
                rows.append(row(id, playlist: playlist, state: matched ? .matched : .pending, video: matched ? "v" : nil))
                if !matched && playlist == "p1" { pending.append(id) }
            }
            try await persistence.insertSongs(rows)
        }
        return (persistence, pending)
    }

    func testPendingPagesEqualTheDistinctAscendingPendingTracks() async throws {
        let (persistence, expected) = try await seeded()
        var cursor = ""
        var pages: [[String]] = []
        while true {
            let page = try await persistence.pendingSongs(after: cursor, limit: SpotifyMatchRunner.batchSize)
            if page.isEmpty { break }
            pages.append(page.map(\.spotifyId))
            cursor = try XCTUnwrap(page.last).spotifyId
        }
        XCTAssertEqual(pages.flatMap { $0 }, expected, "every pending track once, ascending")
        XCTAssertTrue(pages.dropLast().allSatisfy { $0.count == SpotifyMatchRunner.batchSize })
    }

    func testAPageStopsEarlyAndSkipsTracksLeftPending() async throws {
        let (persistence, expected) = try await seeded()
        let start = ContinuousClock.now
        let page = try await persistence.pendingSongs(after: "", limit: 48)
        let elapsed = ContinuousClock.now - start
        print("measured [spotify.pendingSongs.3600rows] \(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) s")
        XCTAssertEqual(page.map(\.spotifyId), Array(expected.prefix(48)))
        // The cursor passes tracks a failed search left pending: the next page starts after the last one returned.
        let next = try await persistence.pendingSongs(after: try XCTUnwrap(page.last).spotifyId, limit: 48)
        XCTAssertEqual(next.map(\.spotifyId), Array(expected[48..<96]))
        let none = try await persistence.pendingSongs(after: try XCTUnwrap(expected.last), limit: 48)
        XCTAssertTrue(none.isEmpty)
    }

    func testABatchOfMatchesIsWrittenInOrderAndKeepsManualAndMatchedRows() async throws {
        let persistence = PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: true))
        try await persistence.insertSongs([
            row("a", playlist: "p1"), row("a", playlist: "p2"), row("b", playlist: "p1"),
            row("m", playlist: "p1", state: .manual, video: "mine"), row("k", playlist: "p1", state: .matched, video: "kept"),
        ])
        try await persistence.updateAutomaticMatches([
            SpotifyAutoMatchUpdate(spotifyId: "a", videoId: "va", score: 0.8, state: .matched),
            SpotifyAutoMatchUpdate(spotifyId: "b", videoId: nil, score: nil, state: .unmatched),
            SpotifyAutoMatchUpdate(spotifyId: "m", videoId: "other", score: 0.5, state: .matched),
            SpotifyAutoMatchUpdate(spotifyId: "k", videoId: "new", score: 0.5, state: .matched),
        ])
        let rows = try await persistence.allSongs()
        XCTAssertTrue(rows.filter { $0.spotifyId == "a" }.allSatisfy { $0.matchedVideoId == "va" && $0.matchState == .matched },
                      "every row of the track")
        XCTAssertEqual(rows.first { $0.spotifyId == "b" }?.matchState, .unmatched)
        XCTAssertEqual(rows.first { $0.spotifyId == "m" }?.matchedVideoId, "mine", "a manual match is never overridden")
        XCTAssertEqual(rows.first { $0.spotifyId == "k" }?.matchedVideoId, "kept", "a track that has a video keeps it")
        try await persistence.updateAutomaticMatches([])
    }

    func testCountsAreDistinctTracks() async throws {
        let (persistence, expected) = try await seeded(tracks: 300)
        let pending = try await persistence.countTracks(in: .pending)
        XCTAssertEqual(pending, expected.count)
        let matched = try await persistence.countTracks(in: .matched)
        XCTAssertEqual(matched, 100)
        let total = try await persistence.distinctSongCount()
        XCTAssertEqual(total, 300, "the tracks of the three playlists, once each")
    }

    func testTheThrottleLetsOneThroughPerInterval() {
        let throttle = RefreshThrottle(interval: .seconds(2))
        let start = ContinuousClock.now
        XCTAssertTrue(throttle.allows(now: start))
        XCTAssertFalse(throttle.allows(now: start + .milliseconds(500)))
        XCTAssertFalse(throttle.allows(now: start + .milliseconds(1_999)))
        XCTAssertTrue(throttle.allows(now: start + .seconds(2)))
        XCTAssertFalse(throttle.allows(now: start + .seconds(3)))
    }
}
