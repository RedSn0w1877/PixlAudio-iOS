// An in-memory `SpotifyLibraryStore` with the DAO's semantics (tests, demo data). Rows keep insertion order; a
// "distinct" query returns the first row of each track, like SQLite's `GROUP BY spotify_id` over a rowid scan.

import Foundation

public actor InMemorySpotifyLibraryStore: SpotifyLibraryStore {
    public private(set) var playlists: [SpotifyPlaylistRow] = []
    public private(set) var songs: [SpotifyTrackRecord] = []
    /// Every mutating call, in order (tests assert what was — and wasn't — touched).
    public private(set) var log: [String] = []

    public init(playlists: [SpotifyPlaylistRow] = [], songs: [SpotifyTrackRecord] = []) {
        self.playlists = playlists
        self.songs = songs
    }

    public func allPlaylists() async throws -> [SpotifyPlaylistRow] {
        playlists.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public func upsertPlaylist(_ playlist: SpotifyPlaylistRow) async throws {
        log.append("upsertPlaylist:\(playlist.id)")
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index] = playlist
        } else {
            playlists.append(playlist)
        }
    }

    public func deletePlaylist(id: String) async throws {
        log.append("deletePlaylist:\(id)")
        playlists.removeAll { $0.id == id }
    }

    public func allSongs() async throws -> [SpotifyTrackRecord] { songs }

    public func insertSongs(_ newSongs: [SpotifyTrackRecord]) async throws {
        log.append("insertSongs:\(newSongs.count)")
        insert(newSongs)
    }

    private func insert(_ newSongs: [SpotifyTrackRecord]) {
        for song in newSongs {
            if let index = songs.firstIndex(where: { $0.id == song.id }) {
                songs[index] = song
            } else {
                songs.append(song)
            }
        }
    }

    public func replaceSongs(playlistId: String, with newSongs: [SpotifyTrackRecord]) async throws {
        log.append("replaceSongs:\(playlistId):\(newSongs.count)")
        songs.removeAll { $0.playlistId == playlistId }
        insert(newSongs)
    }

    public func deleteSongs(playlistId: String) async throws {
        log.append("deleteSongs:\(playlistId)")
        songs.removeAll { $0.playlistId == playlistId }
    }

    public func deleteSong(spotifyId: String, playlistId: String) async throws {
        log.append("deleteSong:\(spotifyId):\(playlistId)")
        songs.removeAll { $0.spotifyId == spotifyId && $0.playlistId == playlistId }
    }

    public func knownMatches() async throws -> [String: SpotifyMatchInfo] {
        var result: [String: SpotifyMatchInfo] = [:]
        var seen = Set<String>()
        for song in songs where song.matchState != .pending && seen.insert(song.spotifyId).inserted {
            result[song.spotifyId] = SpotifyMatchInfo(matchedVideoId: song.matchedVideoId, matchScore: song.matchScore,
                                                      matchState: song.matchState)
        }
        return result
    }

    public func pendingSongs(after: String, limit: Int) async throws -> [SpotifyTrackRecord] {
        var seen = Set<String>()
        let pending = songs.filter { $0.matchState == .pending && $0.spotifyId > after && seen.insert($0.spotifyId).inserted }
        return Array(pending.sorted { $0.spotifyId < $1.spotifyId }.prefix(limit))
    }

    public func updateAutomaticMatch(spotifyId: String, videoId: String?, score: Float?, state: SpotifyMatchState) async throws {
        log.append("updateAutomaticMatch:\(spotifyId):\(state)")
        for index in songs.indices where songs[index].spotifyId == spotifyId && songs[index].matchState != .manual
            && (songs[index].matchedVideoId ?? "").isEmpty {
            songs[index].matchedVideoId = videoId
            songs[index].matchScore = score
            songs[index].matchState = state
        }
    }

    public func updateAutomaticMatches(_ updates: [SpotifyAutoMatchUpdate]) async throws {
        log.append("updateAutomaticMatches:\(updates.count)")
        for update in updates {
            for index in songs.indices where songs[index].spotifyId == update.spotifyId && songs[index].matchState != .manual
                && (songs[index].matchedVideoId ?? "").isEmpty {
                songs[index].matchedVideoId = update.videoId
                songs[index].matchScore = update.score
                songs[index].matchState = update.state
            }
        }
    }

    public func updateMatch(spotifyId: String, videoId: String?, score: Float?, state: SpotifyMatchState) async throws {
        log.append("updateMatch:\(spotifyId):\(state)")
        for index in songs.indices where songs[index].spotifyId == spotifyId {
            songs[index].matchedVideoId = videoId
            songs[index].matchScore = score
            songs[index].matchState = state
        }
    }

    public func requeueUnmatched() async throws -> Int {
        log.append("requeueUnmatched")
        var changed = 0
        for index in songs.indices where songs[index].matchState == .unmatched {
            songs[index].matchState = .pending
            songs[index].matchedVideoId = nil
            songs[index].matchScore = nil
            changed += 1
        }
        return changed
    }

    public func countTracks(in state: SpotifyMatchState) async throws -> Int {
        var seen = Set<String>()
        return songs.filter { $0.matchState == state && seen.insert($0.spotifyId).inserted }.count
    }

    public func clearAll() async throws {
        log.append("clearAll")
        songs.removeAll()
        playlists.removeAll()
    }
}
