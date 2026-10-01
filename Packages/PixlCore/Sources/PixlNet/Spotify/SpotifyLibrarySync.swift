// Port of the sync, catalogue and import half of `data/spotify/SpotifyRepository.kt`, written against a storage
// protocol (`SpotifyLibraryStore`, Android's `SpotifyDao`) so the snapshot rules run — and are tested — without the
// app's database. The rules that matter:
// - only a complete, advancing page sequence may replace a saved snapshot (`SpotifyLibrary.nextSnapshotOffset`);
//   any failed or anomalous page throws and leaves the stored rows untouched;
// - re-importing a playlist carries over the YouTube matches already found (`knownMatches`), so a sync never throws
//   hours of matching away;
// - a 403 on a playlist's items means the token predates a scope: `playlistAccessDenied` is raised for the UI;
// - playlists deleted on Spotify are pruned, but never Liked Songs or the browse playlist.

import Foundation
import PixlFoundation
import PixlModel

/// `SpotifyPlaylistEntity`.
public struct SpotifyPlaylistRow: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var coverUrl: String?
    public var songCount: Int
    /// When its songs were last imported (0 = never); kept across a playlist-list refresh so an interrupted pass
    /// can resume.
    public var lastSyncTime: Int64

    public init(id: String, name: String, coverUrl: String?, songCount: Int, lastSyncTime: Int64) {
        self.id = id
        self.name = name
        self.coverUrl = coverUrl
        self.songCount = songCount
        self.lastSyncTime = lastSyncTime
    }
}

/// `SpotifyMatchRow`: the YouTube match of one track.
public struct SpotifyMatchInfo: Sendable, Hashable {
    public var matchedVideoId: String?
    public var matchScore: Float?
    public var matchState: SpotifyMatchState

    public init(matchedVideoId: String?, matchScore: Float?, matchState: SpotifyMatchState) {
        self.matchedVideoId = matchedVideoId
        self.matchScore = matchScore
        self.matchState = matchState
    }
}

/// What the Spotify library is stored in (Android `SpotifyDao`). Rows are keyed by `SpotifyTrackRecord.id`
/// (`<playlistId>_<spotifyId>`); "distinct" queries collapse the rows of one track (`GROUP BY spotify_id`).
public protocol SpotifyLibraryStore: Sendable {
    func allPlaylists() async throws -> [SpotifyPlaylistRow]
    func upsertPlaylist(_ playlist: SpotifyPlaylistRow) async throws
    func deletePlaylist(id: String) async throws
    /// Every row (all playlists).
    func allSongs() async throws -> [SpotifyTrackRecord]
    /// Inserts or replaces rows by id.
    func insertSongs(_ songs: [SpotifyTrackRecord]) async throws
    /// `replaceSongsForPlaylist`: deletes the playlist's rows, then inserts `songs`, in one transaction.
    func replaceSongs(playlistId: String, with songs: [SpotifyTrackRecord]) async throws
    func deleteSongs(playlistId: String) async throws
    func deleteSong(spotifyId: String, playlistId: String) async throws
    /// `getKnownMatches`: one row per track whose state is not PENDING.
    func knownMatches() async throws -> [String: SpotifyMatchInfo]
    /// `getUnmatchedSongsAfter`: PENDING tracks with `spotifyId > after`, distinct, ascending by spotifyId.
    func pendingSongs(after: String, limit: Int) async throws -> [SpotifyTrackRecord]
    /// `updateAutomaticMatch`: every row of the track, unless MANUAL or already holding a video.
    func updateAutomaticMatch(spotifyId: String, videoId: String?, score: Float?, state: SpotifyMatchState) async throws
    /// `updateMatch`: every row of the track, unconditionally.
    func updateMatch(spotifyId: String, videoId: String?, score: Float?, state: SpotifyMatchState) async throws
    /// `requeueUnmatchedSongs`: UNMATCHED → PENDING (video and score cleared). Returns the rows changed.
    func requeueUnmatched() async throws -> Int
    /// `countByMatchState`: distinct tracks in `state`.
    func countTracks(in state: SpotifyMatchState) async throws -> Int
    /// Removes every Spotify row and playlist (`clearAllSongs` + `clearAllPlaylists`).
    func clearAll() async throws
}

/// `BulkSyncResult`.
public struct SpotifySyncResult: Sendable, Hashable {
    public var playlistCount: Int
    public var syncedSongCount: Int
    public var failedPlaylistCount: Int
    /// False when the pass stopped on `shouldContinue` with playlists left; the caller re-runs it.
    public var isComplete: Bool

    public init(playlistCount: Int, syncedSongCount: Int, failedPlaylistCount: Int, isComplete: Bool) {
        self.playlistCount = playlistCount
        self.syncedSongCount = syncedSongCount
        self.failedPlaylistCount = failedPlaylistCount
        self.isComplete = isComplete
    }
}

/// A sync step that could not finish; the stored snapshot was kept (Android throws `IOException`).
public struct SpotifySyncError: Error, Sendable, Hashable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// `SpotifyRepository`'s sync, catalogue and import operations.
public actor SpotifyLibrarySync {
    public static let flushEveryPlaylists = 4
    /// How long a playlist counts as "already fetched in this pass" (`RESUME_WINDOW_MS`).
    public static let resumeWindowMs: Int64 = 30 * 60 * 1000
    public static let artistBatchSize = 50

    private let api: SpotifyWebAPI
    private let store: any SpotifyLibraryStore
    private let sha256: SHA256Function
    private let nowMs: @Sendable () -> Int64
    /// Writes the Spotify rows into the unified library (songs/albums/artists) and mirrors the playlists
    /// (`syncUnifiedLibrarySongsFromSpotify` + `mirrorPlaylistsIntoApp`). Failures are the callee's to log.
    private let flush: @Sendable () async -> Void

    /// Spotify refuses playlist contents for permission reasons (token from before a scope was added).
    public private(set) var playlistAccessDenied = false

    public init(api: SpotifyWebAPI, store: any SpotifyLibraryStore, sha256: @escaping SHA256Function,
                nowMs: @escaping @Sendable () -> Int64 = { currentTimeMillis() },
                flush: @escaping @Sendable () async -> Void = {}) {
        self.api = api
        self.store = store
        self.sha256 = sha256
        self.nowMs = nowMs
        self.flush = flush
    }

    public func clearPlaylistAccessDenied() { playlistAccessDenied = false }

    // MARK: Profile

    /// `refreshProfile`: the account's profile, nil when the call failed.
    public func fetchProfile() async throws -> SpotifyUserProfile? {
        try await api.call("profile", build: { SpotifyAPI.profile(authorization: $0) }, decode: SpotifyUserProfile.init(json:))
    }

    // MARK: Import

    private func knownMatches() async throws -> [String: SpotifyMatchInfo] { try await store.knownMatches() }

    /// `carryingMatches`.
    static func carryingMatches(_ songs: [SpotifyTrackRecord], _ known: [String: SpotifyMatchInfo]) -> [SpotifyTrackRecord] {
        if known.isEmpty { return songs }
        return songs.map { song in
            guard let previous = known[song.spotifyId] else { return song }
            var copy = song
            copy.matchedVideoId = previous.matchedVideoId
            copy.matchScore = previous.matchScore
            copy.matchState = previous.matchState
            return copy
        }
    }

    private static func artistIds(_ items: [SpotifyPlaylistTrackItem]) -> Set<String> {
        var ids = Set<String>()
        for item in items {
            for ref in item.resolvedTrack?.artists ?? [] { if let id = ref.id { ids.insert(id) } }
        }
        return ids
    }

    /// "Liked Songs", stored as a playlist with a synthetic id.
    @discardableResult
    public func syncLikedSongs(known: [String: SpotifyMatchInfo]? = nil) async throws -> Int {
        let matches: [String: SpotifyMatchInfo]
        if let known { matches = known } else { matches = try await knownMatches() }
        var pending: [SpotifyPlaylistTrackItem] = []
        var offset = 0
        while true {
            let current = offset
            guard let page = try await api.call("liked@\(current)", build: {
                SpotifyAPI.savedTracks(authorization: $0, limit: SpotifyAPI.likedPageSize, offset: current)
            }, decode: SpotifyTracksPage.init(json:)) else {
                throw SpotifySyncError("Liked Songs could not be fully loaded; existing songs were kept")
            }
            guard let items = page.items else { throw SpotifySyncError("Liked Songs returned an incomplete page") }
            pending += items
            guard let next = try Self.advance(current, page.offset, page.limit, items.count, page.next, page.total) else { break }
            offset = next
        }
        let genres = try await fetchArtistGenres(Self.artistIds(pending))
        let now = nowMs()
        let collected = pending.compactMap {
            SpotifyLibrary.record(for: $0.resolvedTrack, playlistId: SpotifyLibrary.likedSongsPlaylistId, addedAt: $0.addedAt,
                                  genreByArtistId: genres, nowMs: now)
        }
        try await store.replaceSongs(playlistId: SpotifyLibrary.likedSongsPlaylistId, with: Self.carryingMatches(collected, matches))
        try await store.upsertPlaylist(SpotifyPlaylistRow(id: SpotifyLibrary.likedSongsPlaylistId, name: "Liked Songs",
                                                          coverUrl: collected.first?.albumArtUrl, songCount: collected.count,
                                                          lastSyncTime: nowMs()))
        return collected.count
    }

    /// Lists the user's playlists and stores their headers (no songs yet); prunes playlists deleted on Spotify.
    public func syncUserPlaylists() async throws -> [SpotifyPlaylistRow] {
        var remote: [SpotifyPlaylist] = []
        var offset = 0
        while true {
            let current = offset
            guard let page = try await api.call("playlists@\(current)", build: {
                SpotifyAPI.userPlaylists(authorization: $0, limit: SpotifyAPI.playlistPageSize, offset: current)
            }, decode: SpotifyPlaylistsPage.init(json:)) else {
                throw SpotifySyncError("Spotify playlists could not be fully loaded; existing playlists were kept")
            }
            guard let items = page.items else { throw SpotifySyncError("Spotify playlists returned an incomplete page") }
            remote += items.filter { !($0.id.map(NetText.isBlank) ?? true) }
            guard let next = try Self.advance(current, page.offset, page.limit, items.count, page.next, page.total) else { break }
            offset = next
        }

        // `lastSyncTime` comes from the previous row: it is what lets an interrupted pass resume.
        var previous: [String: Int64] = [:]
        for row in try await store.allPlaylists() { previous[row.id] = row.lastSyncTime }
        let rows = remote.map { playlist -> SpotifyPlaylistRow in
            let id = playlist.id!
            return SpotifyPlaylistRow(id: id, name: playlist.name.flatMap { NetText.isBlank($0) ? nil : $0 } ?? "Untitled playlist",
                                      coverUrl: playlist.images?.first?.url, songCount: playlist.trackTotal ?? 0,
                                      lastSyncTime: previous[id] ?? 0)
        }
        for row in rows { try await store.upsertPlaylist(row) }

        let remoteIds = Set(rows.map(\.id))
        for stale in try await store.allPlaylists()
        where stale.id != SpotifyLibrary.likedSongsPlaylistId && stale.id != SpotifyLibrary.browsePlaylistId && !remoteIds.contains(stale.id) {
            try await store.deleteSongs(playlistId: stale.id)
            try await store.deletePlaylist(id: stale.id)
        }
        return rows
    }

    /// One playlist's songs (Liked Songs goes through `syncLikedSongs`). A filtered request that fails is retried
    /// once without the `fields` filter; a 403 raises `playlistAccessDenied`.
    @discardableResult
    public func syncPlaylistSongs(_ playlistId: String, known: [String: SpotifyMatchInfo]? = nil) async throws -> Int {
        let matches: [String: SpotifyMatchInfo]
        if let known { matches = known } else { matches = try await knownMatches() }
        if playlistId == SpotifyLibrary.likedSongsPlaylistId { return try await syncLikedSongs(known: matches) }

        var pending: [SpotifyPlaylistTrackItem] = []
        var offset = 0
        var useFieldFilter = true
        let forbidden = ForbiddenFlag()
        while true {
            let current = offset
            func fetch(filtered: Bool) async throws -> SpotifyTracksPage? {
                try await api.call(filtered ? "playlist:\(playlistId)" : "playlist-nofields:\(playlistId)",
                                   onForbidden: { forbidden.raise() }, build: {
                    SpotifyAPI.playlistTracks(authorization: $0, playlistId: playlistId, limit: SpotifyAPI.trackPageSize,
                                              offset: current, fields: filtered ? SpotifyAPI.playlistTrackFields : nil)
                }, decode: SpotifyTracksPage.init(json:))
            }
            var page = try await fetch(filtered: useFieldFilter)
            if forbidden.isRaised {
                playlistAccessDenied = true
                throw SpotifySyncError("Spotify denied access to this playlist; existing songs were kept")
            }
            // `fields` only saves bandwidth: when it is what breaks the call, take the whole response.
            if page == nil && useFieldFilter {
                useFieldFilter = false
                page = try await fetch(filtered: false)
                if forbidden.isRaised {
                    playlistAccessDenied = true
                    throw SpotifySyncError("Spotify denied access to this playlist; existing songs were kept")
                }
            }
            guard let page else { throw SpotifySyncError("Playlist could not be fully loaded; existing songs were kept") }
            guard let items = page.items else { throw SpotifySyncError("Spotify playlist returned an incomplete page") }
            pending += items
            guard let next = try Self.advance(current, page.offset, page.limit, items.count, page.next, page.total) else { break }
            offset = next
        }
        let genres = try await fetchArtistGenres(Self.artistIds(pending))
        let now = nowMs()
        let collected = pending.compactMap {
            SpotifyLibrary.record(for: $0.resolvedTrack, playlistId: playlistId, addedAt: $0.addedAt, genreByArtistId: genres, nowMs: now)
        }
        try await store.replaceSongs(playlistId: playlistId, with: Self.carryingMatches(collected, matches))
        return collected.count
    }

    /// `syncAllPlaylistsAndSongs`: profile, Liked Songs, every playlist and its songs, flushing to the unified library
    /// along the way (every 4 playlists and at the end) so an interrupted pass keeps its work. `shouldContinue` is
    /// checked between playlists; `resumeInterrupted` skips what this pass already fetched (never for a user's sync).
    public func syncAll(resumeInterrupted: Bool = false, shouldContinue: @Sendable () async -> Bool = { true },
                        onProgress: (@Sendable (_ current: Int, _ total: Int, _ name: String) async -> Void)? = nil,
                        onProfile: (@Sendable (SpotifyUserProfile) async -> Void)? = nil) async throws -> SpotifySyncResult {
        if let profile = try await fetchProfile() { await onProfile?(profile) }
        playlistAccessDenied = false

        let known = try await knownMatches()
        let passStartedAt = nowMs()
        func alreadyDone(_ lastSyncTime: Int64?) -> Bool {
            resumeInterrupted && Self.isFreshlySynced(lastSyncTime, passStartedAt: passStartedAt)
        }
        var synced = 0
        var failed = 0
        var complete = true

        let liked = try await store.allPlaylists().first { $0.id == SpotifyLibrary.likedSongsPlaylistId }
        if !alreadyDone(liked?.lastSyncTime) {
            synced += try await syncLikedSongs(known: known)
            await flush()
        }

        let playlists = try await syncUserPlaylists()
        var sinceFlush = 0
        for (index, playlist) in playlists.enumerated() {
            if await !shouldContinue() {
                complete = false
                break
            }
            if alreadyDone(playlist.lastSyncTime) { continue }
            await onProgress?(index + 1, playlists.count, playlist.name)
            var count = 0
            do {
                count = try await syncPlaylistSongs(playlist.id, known: known)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
            }
            synced += count
            var updated = playlist
            updated.songCount = count
            updated.lastSyncTime = nowMs()
            try await store.upsertPlaylist(updated)
            sinceFlush += 1
            if sinceFlush >= Self.flushEveryPlaylists {
                sinceFlush = 0
                await flush()
            }
        }
        await flush()
        return SpotifySyncResult(playlistCount: playlists.count + 1, syncedSongCount: synced, failedPlaylistCount: failed,
                                 isComplete: complete)
    }

    /// `isFreshlySynced`.
    static func isFreshlySynced(_ lastSyncTime: Int64?, passStartedAt: Int64) -> Bool {
        guard let lastSyncTime, lastSyncTime > 0 else { return false }
        return passStartedAt - lastSyncTime < resumeWindowMs
    }

    private static func advance(_ current: Int, _ offset: Int?, _ limit: Int?, _ count: Int, _ next: String?, _ total: Int?) throws -> Int? {
        do {
            return try SpotifyLibrary.nextSnapshotOffset(current: current, reportedOffset: offset, reportedLimit: limit,
                                                         count: count, next: next, total: total)
        } catch {
            throw SpotifySyncError(error.message)
        }
    }

    // MARK: Catalogue

    public func searchCatalog(query: String, types: String = "track,artist,album", limit: Int = 20) async throws -> SpotifyCatalogResults {
        try await api.searchCatalog(query: query, types: types, limit: limit)
    }

    public func artist(_ artistId: String) async throws -> SpotifyArtistFull? {
        try await api.call(build: { SpotifyAPI.artist(authorization: $0, artistId: artistId) }, decode: SpotifyArtistFull.init(json:))
    }

    /// Primary genre per artist id (first listed), in batches of 50; artists without genres are absent.
    func fetchArtistGenres(_ ids: Set<String>) async throws -> [String: String] {
        if ids.isEmpty { return [:] }
        var result: [String: String] = [:]
        let sorted = ids.sorted()
        var start = 0
        while start < sorted.count {
            let batch = sorted[start..<min(start + Self.artistBatchSize, sorted.count)].joined(separator: ",")
            start += Self.artistBatchSize
            let response = try await api.call("artists", build: { SpotifyAPI.artists(authorization: $0, ids: batch) },
                                              decode: SpotifyArtistsBatchResponse.init(json:))
            for artist in response?.artists ?? [] {
                guard let artist, let id = artist.id, let genre = artist.genres?.first, !NetText.isBlank(genre) else { continue }
                result[id] = genre
            }
        }
        return result
    }

    public func artistTopTracks(_ artistId: String) async throws -> [SpotifyTrack] {
        let response = try await api.call(build: { SpotifyAPI.artistTopTracks(authorization: $0, artistId: artistId) },
                                          decode: SpotifyTopTracksResponse.init(json:))
        return (response?.tracks ?? []).filter { !($0.id.map(NetText.isBlank) ?? true) }
    }

    /// Own albums and singles, one per name + track count (Spotify repeats a release per region), newest first.
    public func artistAlbums(_ artistId: String) async throws -> [SpotifyAlbumFull] {
        let page = try await api.call(build: { SpotifyAPI.artistAlbums(authorization: $0, artistId: artistId) },
                                      decode: { SpotifyAlbumsPage(albumsJSON: $0) })
        return Self.distinctAlbums(page?.items ?? [])
    }

    /// `distinctBy { "${name?.lowercase()}|${totalTracks}" }.sortedByDescending { releaseDate.orEmpty() }`.
    static func distinctAlbums(_ albums: [SpotifyAlbumFull]) -> [SpotifyAlbumFull] {
        var seen = Set<String>()
        let unique = albums.filter { !($0.id.map(NetText.isBlank) ?? true) }.filter {
            seen.insert("\($0.name.map(NetText.lowercased) ?? "null")|\($0.totalTracks.map(String.init) ?? "null")").inserted
        }
        // Kotlin's sortedByDescending is stable.
        return unique.enumerated().sorted { a, b in
            let x = Array((a.element.releaseDate ?? "").utf16), y = Array((b.element.releaseDate ?? "").utf16)
            if x != y { return y.lexicographicallyPrecedes(x) }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Album tracks arrive without `album`: fill it from the album itself so they import with cover art.
    public func albumTracks(_ albumId: String) async throws -> [SpotifyTrack] {
        let album = try await api.call(build: { SpotifyAPI.album(authorization: $0, albumId: albumId) }, decode: SpotifyAlbumFull.init(json:))
        let ref = SpotifyAlbumRef(id: album?.id ?? albumId, name: album?.name, images: album?.images)
        let page = try await api.call(build: { SpotifyAPI.albumTracks(authorization: $0, albumId: albumId) },
                                      decode: { SpotifyTracksListPage(tracksJSON: $0) })
        return (page?.items ?? []).filter { !($0.id.map(NetText.isBlank) ?? true) }.map { track in
            var copy = track
            if copy.album == nil { copy.album = ref }
            return copy
        }
    }

    /// Most played (needs `user-top-read`).
    public func myTopTracks(timeRange: String = "medium_term") async throws -> [SpotifyTrack] {
        let page = try await api.call(build: { SpotifyAPI.myTopTracks(authorization: $0, timeRange: timeRange) },
                                      decode: { SpotifyTracksListPage(tracksJSON: $0) })
        return (page?.items ?? []).filter { !($0.id.map(NetText.isBlank) ?? true) }
    }

    public func myTopArtists(timeRange: String = "medium_term") async throws -> [SpotifyArtistFull] {
        let page = try await api.call(build: { SpotifyAPI.myTopArtists(authorization: $0, timeRange: timeRange) },
                                      decode: { SpotifyArtistsPage(artistsJSON: $0) })
        return (page?.items ?? []).filter { !($0.id.map(NetText.isBlank) ?? true) }
    }

    /// `importTracks`: tracks found while browsing go into the browse playlist (and through the same matcher).
    /// Returns how many were new.
    @discardableResult
    public func importTracks(_ tracks: [SpotifyTrack]) async throws -> Int {
        var artistIds = Set<String>()
        for track in tracks { for ref in track.artists ?? [] { if let id = ref.id { artistIds.insert(id) } } }
        let genres = try await fetchArtistGenres(artistIds)
        let now = nowMs()
        let records = tracks.compactMap {
            SpotifyLibrary.record(for: $0, playlistId: SpotifyLibrary.browsePlaylistId, addedAt: nil, genreByArtistId: genres, nowMs: now)
        }
        if records.isEmpty { return 0 }
        let alreadyKnown = Set(try await store.allSongs().map(\.spotifyId))
        try await store.insertSongs(Self.carryingMatches(records, try await knownMatches()))
        try await upsertBrowsePlaylist(fallbackCover: records.first?.albumArtUrl, keepName: false)
        await flush()
        return records.filter { !alreadyKnown.contains($0.spotifyId) }.count
    }

    /// `importYouTubeMusicTracks`: YouTube Music results stored as already-matched browse rows.
    @discardableResult
    public func importYouTubeMusicTracks(_ results: [YouTubeSearchResult]) async throws -> Int {
        let now = nowMs()
        let records = results.map { SpotifyLibrary.record(forYouTubeResult: $0, sha256: sha256, nowMs: now) }
        if records.isEmpty { return 0 }
        let alreadyKnown = Set(try await store.allSongs().map(\.spotifyId))
        try await store.insertSongs(records)
        try await upsertBrowsePlaylist(fallbackCover: records.first?.albumArtUrl, keepName: true)
        await flush()
        return records.filter { !alreadyKnown.contains($0.spotifyId) }.count
    }

    private func upsertBrowsePlaylist(fallbackCover: String?, keepName: Bool) async throws {
        let existing = try await store.allPlaylists().first { $0.id == SpotifyLibrary.browsePlaylistId }
        let count = try await store.allSongs().filter { $0.playlistId == SpotifyLibrary.browsePlaylistId }.count
        try await store.upsertPlaylist(SpotifyPlaylistRow(
            id: SpotifyLibrary.browsePlaylistId,
            name: keepName ? (existing?.name ?? SpotifyLibrary.browsePlaylistName) : SpotifyLibrary.browsePlaylistName,
            coverUrl: existing?.coverUrl ?? fallbackCover, songCount: count, lastSyncTime: nowMs()))
    }

    /// `removeFromExploredCatalog`: removes a track that is only in the browse playlist; false (untouched) when it
    /// belongs to a synced playlist or Liked Songs.
    public func removeFromExploredCatalog(spotifyId: String) async throws -> Bool {
        let all = try await store.allSongs()
        var playlists: [String] = []
        for row in all where row.spotifyId == spotifyId && !playlists.contains(row.playlistId) { playlists.append(row.playlistId) }
        guard playlists == [SpotifyLibrary.browsePlaylistId] else { return false }
        try await store.deleteSong(spotifyId: spotifyId, playlistId: SpotifyLibrary.browsePlaylistId)
        let remaining = try await store.allSongs().filter { $0.playlistId == SpotifyLibrary.browsePlaylistId }.count
        if var browse = try await store.allPlaylists().first(where: { $0.id == SpotifyLibrary.browsePlaylistId }) {
            browse.songCount = remaining
            try await store.upsertPlaylist(browse)
        }
        await flush()
        return true
    }

    // MARK: Sign-out

    /// `logout`: forgets everything imported (matches included). `reauthorize` (keep the library, drop only the
    /// token) is the session's `clearSession` plus `clearPlaylistAccessDenied`.
    public func clearLibrary() async throws {
        try await store.clearAll()
        playlistAccessDenied = false
        await flush()
    }
}

/// A flag a `@Sendable` closure can raise (the 403 callback).
final class ForbiddenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}
