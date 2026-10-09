import Testing
import Foundation
@testable import PixlNet

/// A store that only records `updateAutomaticMatch`: the batch write is the protocol's default.
actor DefaultBatchStore: SpotifyLibraryStore {
    private(set) var calls: [String] = []

    func allPlaylists() async throws -> [SpotifyPlaylistRow] { [] }
    func upsertPlaylist(_ playlist: SpotifyPlaylistRow) async throws {}
    func deletePlaylist(id: String) async throws {}
    func allSongs() async throws -> [SpotifyTrackRecord] { [] }
    func insertSongs(_ songs: [SpotifyTrackRecord]) async throws {}
    func replaceSongs(playlistId: String, with songs: [SpotifyTrackRecord]) async throws {}
    func deleteSongs(playlistId: String) async throws {}
    func deleteSong(spotifyId: String, playlistId: String) async throws {}
    func knownMatches() async throws -> [String: SpotifyMatchInfo] { [:] }
    func pendingSongs(after: String, limit: Int) async throws -> [SpotifyTrackRecord] { [] }
    func updateAutomaticMatch(spotifyId: String, videoId: String?, score: Float?, state: SpotifyMatchState) async throws {
        calls.append("\(spotifyId):\(state)")
    }
    func updateMatch(spotifyId: String, videoId: String?, score: Float?, state: SpotifyMatchState) async throws {}
    func requeueUnmatched() async throws -> Int { 0 }
    func countTracks(in state: SpotifyMatchState) async throws -> Int { 0 }
    func clearAll() async throws {}
}

struct SpotifyBatchWriteTests {
    @Test func theDefaultBatchWriteAppliesEachUpdateInOrder() async throws {
        let store = DefaultBatchStore()
        try await store.updateAutomaticMatches([
            SpotifyAutoMatchUpdate(spotifyId: "a", videoId: "va", score: 0.9, state: .matched),
            SpotifyAutoMatchUpdate(spotifyId: "b", videoId: nil, score: nil, state: .unmatched),
        ])
        #expect(await store.calls == ["a:matched", "b:unmatched"])
    }
}
