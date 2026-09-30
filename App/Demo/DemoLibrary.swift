import Foundation

/// A song in the stage-0 demo library. Replaced by `PixlModel.Song` in later stages.
nonisolated struct DemoSong: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Int
    /// Hue (0…1) of the generated gradient artwork.
    let hue: Double

    /// "m:ss", computed once at creation (never in `body`).
    let durationText: String

    init(id: String, title: String, artist: String, album: String, durationSeconds: Int, hue: Double) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.hue = hue
        self.durationText = "\(durationSeconds / 60):" + String(format: "%02d", durationSeconds % 60)
    }
}

/// Library categories shown on the Library tab (architecture §3).
nonisolated enum LibraryCategory: String, Hashable, Sendable, CaseIterable, Identifiable {
    case playlists, artists, albums, songs, genres, folders, liked, downloaded, spotify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playlists: "Playlists"
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .genres: "Genres"
        case .folders: "Folders"
        case .liked: "Liked Songs"
        case .downloaded: "Downloaded"
        case .spotify: "Spotify"
        }
    }

    var systemImage: String {
        switch self {
        case .playlists: "music.note.list"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genres: "guitars"
        case .folders: "folder"
        case .liked: "heart"
        case .downloaded: "arrow.down.circle"
        case .spotify: "dot.radiowaves.left.and.right"
        }
    }
}

/// A genre tile on the empty Search screen.
nonisolated struct DemoGenre: Identifiable, Hashable, Sendable {
    let name: String
    let hue: Double
    var id: String { name }
}

/// Deterministic demo data for UI tests, screenshots and the placeholder screens.
/// All names are invented.
nonisolated struct DemoLibrary: Sendable {
    let songs: [DemoSong]
    let genres: [DemoGenre]

    init() {
        let raw: [(String, String, String, Int)] = [
            ("Neon Harbor", "Luma Vale", "City of Glass", 214),
            ("Paper Satellites", "The Quiet Arcade", "Low Orbit", 187),
            ("Midnight Transit", "Sora Kline", "Night Lines", 243),
            ("Velvet Static", "Luma Vale", "City of Glass", 198),
            ("Golden Hour Loop", "Aurelio & The Tides", "Seaside Tapes", 226),
            ("Glasshouse", "Mira Okafor", "Greenhouse Sessions", 201),
            ("Signal Fire", "Northbound Echo", "Wayfinder", 255),
            ("Soft Machines", "The Quiet Arcade", "Low Orbit", 176),
            ("Cloud Atlas Drive", "Sora Kline", "Night Lines", 232),
            ("Lanterns", "Hollow Pines", "Evergreen", 209),
            ("After the Rain", "Mira Okafor", "Greenhouse Sessions", 194),
            ("Chromatic", "Pixel Parade", "Eight Bit Hearts", 168),
            ("Tidal Memory", "Aurelio & The Tides", "Seaside Tapes", 247),
            ("Wildflower Radio", "Hollow Pines", "Evergreen", 221),
            ("Parallel Lines", "Northbound Echo", "Wayfinder", 238),
            ("Kaleidoscope Heart", "Pixel Parade", "Eight Bit Hearts", 183),
            ("Slow Burn", "Juniper Rae", "Embers", 262),
            ("Silver Lining", "Juniper Rae", "Embers", 205),
            ("Northern Lights", "Luma Vale", "Aurora", 229),
            ("Blue Hour", "Sora Kline", "Aurora", 216),
            ("Echo Park", "The Quiet Arcade", "Postcards", 191),
            ("Starling", "Mira Okafor", "Postcards", 203),
            ("Weightless", "Hollow Pines", "Drift", 274),
            ("Afterglow", "Pixel Parade", "Drift", 199),
        ]
        songs = raw.enumerated().map { index, item in
            DemoSong(
                id: "demo:\(index)",
                title: item.0,
                artist: item.1,
                album: item.2,
                durationSeconds: item.3,
                hue: Double((index * 37) % 100) / 100
            )
        }
        genres = [
            DemoGenre(name: "Pop", hue: 0.93), DemoGenre(name: "Indie", hue: 0.08),
            DemoGenre(name: "Electronic", hue: 0.62), DemoGenre(name: "Hip-Hop", hue: 0.75),
            DemoGenre(name: "Rock", hue: 0.02), DemoGenre(name: "Jazz", hue: 0.12),
            DemoGenre(name: "Ambient", hue: 0.52), DemoGenre(name: "Classical", hue: 0.33),
            DemoGenre(name: "R&B", hue: 0.83), DemoGenre(name: "Lo-fi", hue: 0.45),
        ]
    }

    var recentlyPlayed: ArraySlice<DemoSong> { songs.prefix(6) }
    var recentlyAdded: ArraySlice<DemoSong> { songs.suffix(6) }

    /// Case- and diacritic-insensitive match on title, artist or album. Demo only — the real app uses
    /// PixlLibrary's SearchIndex.
    func search(_ query: String) -> [DemoSong] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return songs.filter {
            $0.title.range(of: q, options: options) != nil
                || $0.artist.range(of: q, options: options) != nil
                || $0.album.range(of: q, options: options) != nil
        }
    }
}
