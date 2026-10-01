import Foundation
import PixlNet

/// Demo Spotify data for UI tests and screenshots (`-uiTest`): no network, no Keychain, deterministic. The account
/// screens start signed out on their plain ids (`accounts`, `spotifyDashboard`) and signed in on the `.signedIn`
/// variants; browse is always signed in. Artwork uses the generated demo art (`demo-art://<seed>`).
nonisolated struct SpotifyDemo: Sendable {
    let screen: DemoScreen?

    var signedIn: Bool {
        switch screen {
        case .accounts, .spotifyDashboard: false
        default: true
        }
    }

    var showsTestReport: Bool { screen == .spotifyDashboardTested }

    let accountName = "Alex Rivera"
    let accountEmail = "listener@example.com"

    let playlists: [SpotifyPlaylistRow] = [
        SpotifyPlaylistRow(id: SpotifyLibrary.likedSongsPlaylistId, name: "Liked Songs", coverUrl: "demo-art://12", songCount: 248, lastSyncTime: 1),
        SpotifyPlaylistRow(id: "demo-pl-1", name: "Late Night Drive", coverUrl: "demo-art://21", songCount: 42, lastSyncTime: 1),
        SpotifyPlaylistRow(id: "demo-pl-2", name: "Morning Glass", coverUrl: "demo-art://33", songCount: 27, lastSyncTime: 1),
        SpotifyPlaylistRow(id: "demo-pl-3", name: "Indie Rotation", coverUrl: "demo-art://45", songCount: 63, lastSyncTime: 1),
        SpotifyPlaylistRow(id: "demo-pl-4", name: "Focus Flow", coverUrl: nil, songCount: 18, lastSyncTime: 1),
    ]
    let totalSongs = 371
    let matched = 342
    let pending = 21
    let unmatched = 8

    static func image(_ seed: Int) -> [SpotifyImage] { [SpotifyImage(url: "demo-art://\(seed)", width: 300, height: 300)] }

    let topArtists: [SpotifyArtistFull] = [
        SpotifyArtistFull(id: "demo-ar-1", name: "Luma Vale", images: SpotifyDemo.image(41), genres: ["dream pop", "indie pop"]),
        SpotifyArtistFull(id: "demo-ar-2", name: "Sora Kline", images: SpotifyDemo.image(47), genres: ["synthwave"]),
        SpotifyArtistFull(id: "demo-ar-3", name: "Hollow Pines", images: SpotifyDemo.image(50), genres: ["indie folk"]),
        SpotifyArtistFull(id: "demo-ar-4", name: "Neon Atlas", images: SpotifyDemo.image(53), genres: ["electropop"]),
        SpotifyArtistFull(id: "demo-ar-5", name: "Marlow Fields", images: nil, genres: []),
    ]

    static func track(_ id: String, _ name: String, _ artist: String, _ album: String, _ seed: Int, _ ms: Int64) -> SpotifyTrack {
        SpotifyTrack(id: id, name: name, durationMs: ms, artists: [SpotifyArtistRef(id: nil, name: artist)],
                     album: SpotifyAlbumRef(id: "demo-al-\(seed)", name: album, images: SpotifyDemo.image(seed)), type: "track")
    }

    let topTracks: [SpotifyTrack] = [
        SpotifyDemo.track("demo-tr-1", "Prism Avenue", "Luma Vale", "Prism Avenue", 41, 207_000),
        SpotifyDemo.track("demo-tr-2", "Midnight Transit", "Sora Kline", "Night Lines", 47, 268_000),
        SpotifyDemo.track("demo-tr-3", "Harbor Lights", "Luma Vale", "City of Glass", 44, 221_000),
        SpotifyDemo.track("demo-tr-4", "Night Swim", "Hollow Pines", "Drift", 50, 244_000),
        SpotifyDemo.track("demo-tr-5", "Static Bloom", "Neon Atlas", "Signal", 53, 198_000),
        SpotifyDemo.track("demo-tr-6", "Paper Moons", "Marlow Fields", "Paper Moons", 56, 233_000),
    ]

    let albums: [SpotifyAlbumFull] = [
        SpotifyAlbumFull(id: "demo-al-44", name: "City of Glass", images: SpotifyDemo.image(44), releaseDate: "2025-03-14", totalTracks: 11,
                         albumType: "album", artists: [SpotifyArtistRef(id: "demo-ar-1", name: "Luma Vale")]),
        SpotifyAlbumFull(id: "demo-al-41", name: "Prism Avenue", images: SpotifyDemo.image(41), releaseDate: "2024-09-06", totalTracks: 1,
                         albumType: "single", artists: [SpotifyArtistRef(id: "demo-ar-1", name: "Luma Vale")]),
        SpotifyAlbumFull(id: "demo-al-59", name: "Soft Weather", images: SpotifyDemo.image(59), releaseDate: "2022-05-20", totalTracks: 9,
                         albumType: "album", artists: [SpotifyArtistRef(id: "demo-ar-1", name: "Luma Vale")]),
    ]

    func search(_ query: String) -> SpotifyCatalogResults {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SpotifyCatalogResults() }
        func has(_ s: String?) -> Bool { (s ?? "").lowercased().contains(q) }
        return SpotifyCatalogResults(
            tracks: topTracks.filter { has($0.name) || has($0.artists?.first?.name) },
            artists: topArtists.filter { has($0.name) },
            albums: albums.filter { has($0.name) || has($0.artists?.first?.name) })
    }

    func artistTopTracks(_ artistId: String) -> [SpotifyTrack] {
        let name = topArtists.first { $0.id == artistId }?.name
        let own = topTracks.filter { $0.artists?.first?.name == name }
        return own + topTracks.filter { $0.artists?.first?.name != name }.prefix(3)
    }

    func artistAlbums(_ artistId: String) -> [SpotifyAlbumFull] {
        albums.filter { $0.artists?.contains { $0.id == artistId } ?? false }
    }

    func albumTracks(_ albumId: String) -> [SpotifyTrack] {
        let album = albums.first { $0.id == albumId }
        let seed = Int(albumId.split(separator: "-").last ?? "") ?? 44
        return ["Glass Hour", "Harbor Lights", "Ferris Wheel", "Low Tide", "Blue Static", "Afterglow"].enumerated().map { index, name in
            Self.track("demo-at-\(index)", name, album?.artists?.first?.name ?? "Luma Vale", album?.name ?? "Album", seed, Int64(190_000 + index * 9_000))
        }
    }

    let testReport = SpotifyPlaybackTestReport(steps: [
        .init(title: "Imported tracks", ok: true, detail: "Testing with \"Prism Avenue\" by Luma Vale."),
        .init(title: "YouTube Music search", ok: true, detail: "5 candidates, top one: \"Prism Avenue\"."),
        .init(title: "Track matching", ok: true, detail: "Matched \"Prism Avenue\" (score 0.95)."),
        .init(title: "Audio stream", ok: true, detail: "Playable via VISIONOS."),
        .init(title: "Player route", ok: true, detail: "The player streams it through the in-app loader (pixlstream://)."),
    ], succeeded: true)
}
