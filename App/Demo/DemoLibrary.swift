import Foundation
import PixlModel

/// Deterministic demo data for UI tests, screenshots and previews: a small library of invented songs with
/// generated gradient artwork (`demo-art://<seed>`, one seed per album). All names are invented.
nonisolated enum DemoLibrary {
    private static let raw: [(title: String, artist: String, album: String, seconds: Int, genre: String)] = [
        ("Neon Harbor", "Luma Vale", "City of Glass", 214, "Synthpop"),
        ("Paper Satellites", "The Quiet Arcade", "Low Orbit", 187, "Indie"),
        ("Midnight Transit", "Sora Kline", "Night Lines", 243, "Electronic"),
        ("Velvet Static", "Luma Vale", "City of Glass", 198, "Synthpop"),
        ("Golden Hour Loop", "Aurelio & The Tides", "Seaside Tapes", 226, "Indie"),
        ("Glasshouse", "Mira Okafor", "Greenhouse Sessions", 201, "R&B"),
        ("Signal Fire", "Northbound Echo", "Wayfinder", 255, "Rock"),
        ("Soft Machines", "The Quiet Arcade", "Low Orbit", 176, "Indie"),
        ("Cloud Atlas Drive", "Sora Kline", "Night Lines", 232, "Electronic"),
        ("Lanterns", "Hollow Pines", "Evergreen", 209, "Folk"),
        ("After the Rain", "Mira Okafor", "Greenhouse Sessions", 194, "R&B"),
        ("Chromatic", "Pixel Parade", "Eight Bit Hearts", 168, "Electronic"),
        ("Tidal Memory", "Aurelio & The Tides", "Seaside Tapes", 247, "Indie"),
        ("Wildflower Radio", "Hollow Pines", "Evergreen", 221, "Folk"),
        ("Parallel Lines", "Northbound Echo", "Wayfinder", 238, "Rock"),
        ("Kaleidoscope Heart", "Pixel Parade", "Eight Bit Hearts", 183, "Electronic"),
        ("Slow Burn", "Juniper Rae", "Embers", 262, "Soul"),
        ("Silver Lining", "Juniper Rae", "Embers", 205, "Soul"),
        ("Northern Lights", "Luma Vale", "Aurora", 229, "Synthpop"),
        ("Blue Hour", "Sora Kline", "Aurora", 216, "Electronic"),
        ("Echo Park", "The Quiet Arcade", "Postcards", 191, "Indie"),
        ("Starling", "Mira Okafor", "Postcards", 203, "R&B"),
        ("Weightless", "Hollow Pines", "Drift", 274, "Ambient"),
        ("Afterglow", "Pixel Parade", "Drift", 199, "Ambient"),
    ]

    /// The demo library as a snapshot (built once).
    static let snapshot: LibrarySnapshot = build()

    static var songs: [Song] { snapshot.songs }

    private static func build() -> LibrarySnapshot {
        var albumIds: [String: Int64] = [:]
        var artistIds: [String: Int64] = [:]
        for item in raw {
            if albumIds[item.album] == nil { albumIds[item.album] = Int64(albumIds.count + 1) }
            if artistIds[item.artist] == nil { artistIds[item.artist] = Int64(artistIds.count + 1) }
        }
        // 2026-09-01T00:00:00Z, minus a day per song so "recently added" has an order.
        let base: Int64 = 1_788_220_800_000
        let songs = raw.enumerated().map { index, item -> Song in
            let albumId = albumIds[item.album]!
            let artistId = artistIds[item.artist]!
            return Song(id: "demo:\(index)", title: item.title, artist: item.artist, artistId: artistId,
                        artists: [ArtistRef(id: artistId, name: item.artist, isPrimary: true)],
                        album: item.album, albumId: albumId, albumArtist: item.artist,
                        path: "/Demo/\(item.artist)/\(item.album)/\(item.title).m4a",
                        contentUriString: "demo://song/\(index)", albumArtUriString: "demo-art://\(albumId * 3)",
                        duration: Int64(item.seconds) * 1000, genre: item.genre, isFavorite: index % 5 == 0,
                        trackNumber: index % 6 + 1, year: 2020 + index % 6,
                        dateAdded: base - Int64(index) * 86_400_000, dateModified: base - Int64(index) * 86_400_000,
                        mimeType: "audio/mp4", bitrate: 256_000, sampleRate: 44_100)
        }
        let albums = albumIds.sorted { $0.value < $1.value }.map { name, id -> Album in
            let tracks = songs.filter { $0.albumId == id }
            return Album(id: id, title: name, artist: tracks.first?.artist ?? "", year: tracks.first?.year ?? 0,
                         dateAdded: tracks.map(\.dateAdded).max() ?? 0, albumArtUriString: "demo-art://\(id * 3)",
                         songCount: tracks.count, albumArtist: tracks.first?.artist)
        }
        let artists = artistIds.sorted { $0.value < $1.value }.map { name, id in
            Artist(id: id, name: name, songCount: songs.filter { $0.artistId == id }.count)
        }
        let electronic = songs.filter { $0.genre == "Electronic" }.map(\.id)
        let calm = songs.filter { ["Folk", "Soul", "Ambient"].contains($0.genre ?? "") }.map(\.id)
        let indie = songs.filter { $0.genre == "Indie" }.map(\.id)
        let playlists = [
            Playlist(id: "demo-playlist-1", name: "Late Night Drive", songIds: electronic, createdAt: base,
                     lastModified: base, sortOrder: 0),
            Playlist(id: "demo-playlist-2", name: "Sunday Morning", songIds: calm, createdAt: base,
                     lastModified: base, sortOrder: 1),
            Playlist(id: "demo-playlist-3", name: "Indie Favourites", songIds: indie, createdAt: base,
                     lastModified: base, isAiGenerated: true, sortOrder: 2),
        ]
        return LibrarySnapshot(songs: songs, albums: albums, artists: artists, playlists: playlists)
    }

    /// Genres of the demo library (Search's genre grid placeholder).
    static var genreNames: [String] { Array(Set(raw.map(\.genre))).sorted() }
}
