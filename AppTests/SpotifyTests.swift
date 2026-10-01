import PixlLibrary
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// Stage 12: the unified-library rows built from the Spotify tables (`syncUnifiedLibrarySongsFromSpotify` +
/// `mirrorPlaylistsIntoApp`), their diffed write through `PersistenceActor` (SwiftData, in memory), the Spotify DAO
/// semantics on SwiftData, the playback resolver's id handling and the Keychain token round trip.
@MainActor
final class SpotifyTests: XCTestCase {
    private func row(_ spotifyId: String, playlist: String, artist: String = "Luma Vale", album: String = "City",
                     albumId: String? = "al1", state: SpotifyMatchState = .pending, video: String? = nil) -> SpotifyTrackRecord {
        SpotifyTrackRecord(id: "\(playlist)_\(spotifyId)", spotifyId: spotifyId, playlistId: playlist, title: "Song \(spotifyId)",
                           artist: artist, album: album, albumId: albumId, durationMs: 200_000, albumArtUrl: "https://i/\(spotifyId)",
                           isrc: nil, dateAdded: 1_000, matchedVideoId: video, matchScore: video == nil ? nil : 0.9, matchState: state,
                           genre: "pop")
    }

    func testUnifiedLibraryRowsBandsAndMirroredPlaylists() {
        let rows = [row("a", playlist: "p1", artist: "Luma Vale; Sora Kline"), row("b", playlist: "p1", albumId: nil),
                    row("a", playlist: SpotifyLibrary.likedSongsPlaylistId)]
        let playlists = [SpotifyPlaylistRow(id: "p1", name: "Mix", coverUrl: "https://c", songCount: 2, lastSyncTime: 1),
                         SpotifyPlaylistRow(id: SpotifyLibrary.likedSongsPlaylistId, name: "Liked Songs", coverUrl: nil, songCount: 1, lastSyncTime: 1)]
        var existing = Song(id: "sp:a", title: "x", artist: "x", artistId: 0, album: "x", albumId: 0, path: "", contentUriString: "",
                            albumArtUriString: nil, duration: 0, mimeType: nil, bitrate: nil, sampleRate: nil)
        existing.isFavorite = true
        existing.dateAdded = 42
        let built = SpotifyUnifiedLibrary.build(rows: rows, playlists: playlists, existing: ["sp:a": existing], nowMs: 7)

        XCTAssertEqual(built.songs.map(\.id), ["sp:a", "sp:b"])
        let a = built.songs[0]
        XCTAssertEqual(a.contentUriString, "spotify://a")
        XCTAssertEqual(a.spotifyId, "a")
        XCTAssertTrue(a.isFavorite)
        XCTAssertEqual(a.dateAdded, 42)
        XCTAssertEqual(a.artists.map(\.name), ["Luma Vale", "Sora Kline"])
        XCTAssertEqual(a.artists.first?.id, SpotifyLibrary.unifiedArtistId("luma vale"))
        XCTAssertEqual(a.albumId, SpotifyLibrary.unifiedAlbumId("al1"))
        XCTAssertEqual(built.songs[1].albumId, SpotifyLibrary.unifiedAlbumId("City|Luma Vale"))
        XCTAssertTrue(built.albums.allSatisfy { SpotifyUnifiedLibrary.isSpotifyAlbumId($0.id) })
        XCTAssertTrue(built.artists.allSatisfy { SpotifyUnifiedLibrary.isSpotifyArtistId($0.id) })
        XCTAssertEqual(built.artists.first { $0.name == "Luma Vale" }?.songCount, 2)
        XCTAssertEqual(built.links.filter { $0.songId == "sp:a" }.map(\.isPrimary), [true, false])

        XCTAssertEqual(built.playlists.map(\.id), ["spotify_playlist:p1", "spotify_playlist:\(SpotifyLibrary.likedSongsPlaylistId)"])
        XCTAssertEqual(built.playlists[0].songIds, ["sp:a", "sp:b"])
        XCTAssertEqual(built.playlists[0].source, "SPOTIFY")
        XCTAssertEqual(built.playlists[0].coverImageUri, "https://c")
        XCTAssertEqual(built.playlists[1].songIds, ["sp:a"])
    }

    func testDefaultDelimitersKeepCommaSeparatedArtistsTogether() {
        // Android `CloudMusicUtils.parseArtistNames` uses the conservative defaults (";" only + word delimiters).
        XCTAssertEqual(SpotifyUnifiedLibrary.parseArtistNames("A, B"), ["A, B"])
        XCTAssertEqual(SpotifyUnifiedLibrary.parseArtistNames("A feat. B"), ["A", "B"])
        XCTAssertEqual(SpotifyUnifiedLibrary.parseArtistNames("  "), ["Unknown Artist"])
    }

    func testPersistenceStoresSpotifyRowsAndWritesTheUnifiedLibrary() async throws {
        let persistence = PersistenceActor(modelContainer: try PersistenceActor.makeContainer(inMemory: true))
        try await persistence.upsertPlaylist(SpotifyPlaylistRow(id: "p1", name: "Mix", coverUrl: nil, songCount: 2, lastSyncTime: 0))
        try await persistence.replaceSongs(playlistId: "p1", with: [row("b", playlist: "p1"), row("a", playlist: "p1", state: .matched, video: "vid")])
        try await persistence.insertSongs([row("a", playlist: SpotifyLibrary.likedSongsPlaylistId)])

        let pending = try await persistence.pendingSongs(after: "", limit: 10)
        XCTAssertEqual(pending.map(\.spotifyId), ["a", "b"], "distinct tracks, ascending, rows of one track collapse")
        let known = try await persistence.knownMatches()
        XCTAssertEqual(known["a"]?.matchedVideoId, "vid")
        let matchedVideo = try await persistence.matchedVideoId(spotifyId: "a")
        XCTAssertEqual(matchedVideo, "vid")

        try await persistence.updateAutomaticMatch(spotifyId: "b", videoId: nil, score: nil, state: .unmatched)
        let unmatched = try await persistence.countTracks(in: .unmatched)
        XCTAssertEqual(unmatched, 1)
        let requeued = try await persistence.requeueUnmatched()
        XCTAssertEqual(requeued, 1)

        try await persistence.rebuildSpotifyUnifiedLibrary()
        var snapshot = try await persistence.loadLibrarySnapshot()
        XCTAssertEqual(Set(snapshot.songs.map(\.id)), ["sp:a", "sp:b"])
        XCTAssertEqual(snapshot.playlists.first { $0.id == "spotify_playlist:p1" }?.songIds.count, 2)

        // A favourite set by the user survives a rebuild; a playlist removed on Spotify disappears with its rows.
        try await persistence.setFavorites(["sp:b"], isFavorite: true, timestamp: 5)
        try await persistence.deleteSongs(playlistId: "p1")
        try await persistence.deletePlaylist(id: "p1")
        try await persistence.rebuildSpotifyUnifiedLibrary()
        snapshot = try await persistence.loadLibrarySnapshot()
        XCTAssertEqual(snapshot.songs.map(\.id), ["sp:a"])
        XCTAssertNil(snapshot.playlists.first { $0.id == "spotify_playlist:p1" })

        try await persistence.clearAll()
        try await persistence.rebuildSpotifyUnifiedLibrary()
        snapshot = try await persistence.loadLibrarySnapshot()
        XCTAssertTrue(snapshot.songs.isEmpty)
        XCTAssertTrue(snapshot.albums.isEmpty && snapshot.artists.isEmpty)
    }

    func testResolverReadsSpotifyIdsCaseSensitively() {
        func song(_ uri: String, spotifyId: String? = nil) -> Song {
            Song(id: "x", title: "", artist: "", artistId: 0, album: "", albumId: 0, path: "", contentUriString: uri,
                 albumArtUriString: nil, duration: 0, mimeType: nil, bitrate: nil, sampleRate: nil, spotifyId: spotifyId)
        }
        XCTAssertEqual(SpotifyPlayableURLResolver.spotifyId(of: song("spotify://4uLU6hMCjMI75M1A2tKUQC")), "4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(SpotifyPlayableURLResolver.spotifyId(of: song("file:///a.mp3", spotifyId: "AbC")), "AbC")
        XCTAssertNil(SpotifyPlayableURLResolver.spotifyId(of: song("file:///a.mp3")))
        XCTAssertEqual(SpotifyPlayableURLResolver.youTubeSong(videoId: "dQw4w9WgXcQ").contentUriString, "pixlstream://dQw4w9WgXcQ")
        XCTAssertEqual(SpotifyPlaybackTest.twoDecimals(0.555), "0.56")
        XCTAssertEqual(SpotifyPlaybackTest.twoDecimals(0.9), "0.90")
    }

    func testPKCEWithCryptoKitAndKeychainRoundTrip() async throws {
        // RFC 7636 appendix B.
        let challenge = SpotifyAuth.codeChallenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", sha256: SpotifyPlatform.sha256)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(SpotifyPlatform.randomBytes(64).count, 64)

        let store = KeychainSpotifyTokenStore()
        let tokens = SpotifyTokens(accessToken: "A", refreshToken: "R2", expiresAtMs: 99, scope: "user-top-read")
        do {
            try await store.save(tokens)
        } catch {
            throw XCTSkip("Keychain unavailable in this test host: \(error)")
        }
        let loaded = await store.load()
        XCTAssertEqual(loaded, tokens)
        await store.clear()
        let cleared = await store.load()
        XCTAssertNil(cleared)
    }

    func testDemoServiceStates() {
        let accounts = AccountsStore()
        let signedOut = SpotifyService(launch: LaunchConfiguration(arguments: ["-uiTest", "-screen", "accounts"]),
                                       accounts: accounts, persistence: nil)
        XCTAssertFalse(signedOut.isLoggedIn)
        XCTAssertEqual(accounts.spotify, .signedOut)
        let signedIn = SpotifyService(launch: LaunchConfiguration(arguments: ["-uiTest", "-screen", "accounts.signedIn"]),
                                      accounts: accounts, persistence: nil)
        XCTAssertTrue(signedIn.isLoggedIn)
        XCTAssertEqual(signedIn.playlists.count, 5)
        XCTAssertEqual(accounts.spotify, .signedIn(displayName: "Alex Rivera"))
    }
}
