// The whole library for Ask Taizo (spec taizo-taste §3): `search_library` with filters, sorting and paging, and
// `get_library_overview`. Pure, so the same code answers on the phone and in tests. Nothing here caps what Taizo can
// see: a query pages through every song, 200 at a time.

import Foundation
import PixlFoundation
import PixlModel

/// What the app knows about a song's listening.
public struct SongPlayStats: Sendable, Hashable {
    public var plays: Int
    public var lastPlayedMs: Int64

    public init(plays: Int, lastPlayedMs: Int64 = 0) {
        self.plays = plays
        self.lastPlayedMs = lastPlayedMs
    }
}

extension SongPlayStats {
    /// Plays and the last play per library song, from every play there is (the app's and the imported ones that name a
    /// library song).
    public static func build(plays: [ListeningPlay]) -> [String: SongPlayStats] {
        var out: [String: SongPlayStats] = [:]
        for play in plays {
            guard let id = play.songId else { continue }
            var stats = out[id] ?? SongPlayStats(plays: 0)
            stats.plays += 1
            stats.lastPlayedMs = max(stats.lastPlayedMs, play.timestampMs)
            out[id] = stats
        }
        return out
    }
}

public struct LibraryQuery: Sendable, Hashable {
    public enum Sort: String, Sendable, Hashable, CaseIterable {
        case relevance
        case mostPlayed = "most_played"
        case recentlyPlayed = "recently_played"
        case recentlyAdded = "recently_added"
        case random
        case title
    }

    public static let defaultLimit = 20
    public static let maxLimit = 200

    public var text: String
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var yearFrom: Int?
    public var yearTo: Int?
    public var minPlays: Int?
    public var maxPlays: Int?
    public var likedOnly: Bool
    public var neverPlayed: Bool
    public var sort: Sort
    public var limit: Int
    public var offset: Int

    public init(text: String = "", artist: String? = nil, album: String? = nil, genre: String? = nil, yearFrom: Int? = nil,
                yearTo: Int? = nil, minPlays: Int? = nil, maxPlays: Int? = nil, likedOnly: Bool = false,
                neverPlayed: Bool = false, sort: Sort = .relevance, limit: Int = defaultLimit, offset: Int = 0) {
        self.text = text
        self.artist = artist
        self.album = album
        self.genre = genre
        self.yearFrom = yearFrom
        self.yearTo = yearTo
        self.minPlays = minPlays
        self.maxPlays = maxPlays
        self.likedOnly = likedOnly
        self.neverPlayed = neverPlayed
        self.sort = sort
        self.limit = limit
        self.offset = offset
    }

    /// Whether any filter besides the words is set.
    public var hasFilters: Bool {
        artist != nil || album != nil || genre != nil || yearFrom != nil || yearTo != nil || minPlays != nil
            || maxPlays != nil || likedOnly || neverPlayed
    }
}

public struct LibraryPage: Sendable {
    public var songs: [Song]
    /// Songs that match (before paging).
    public var totalMatches: Int
    public var offset: Int
    /// The `offset` for the next page, nil at the end.
    public var nextOffset: Int?
    /// Words were searched and the index returned its cap: more may match than `totalMatches` says.
    public var totalIsLowerBound: Bool
}

public enum LibraryQueryEngine {
    /// Words are searched in the index up to this many hits (the index orders them by relevance).
    public static let textHitCap = 5_000

    public static func run(_ query: LibraryQuery, songs: [Song], stats: [String: SongPlayStats], index: SearchIndex? = nil,
                           seed: Int64 = 0) -> LibraryPage {
        let limit = min(max(query.limit, 1), LibraryQuery.maxLimit)
        let offset = max(query.offset, 0)
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Candidates: the words' hits in relevance order, or the whole library.
        var candidates: [Song]
        var lowerBound = false
        if text.isEmpty {
            candidates = songs
        } else {
            let idx = index ?? SearchIndex(songs: songs)
            candidates = idx.searchSongs(text, limit: textHitCap)
            lowerBound = candidates.count >= textHitCap
            // The index matches title, artist and genre words; a genre named in the words also matches by substring.
            let lower = text.lowercased()
            var seen = Set(candidates.map(\.id))
            for song in songs where (song.genre?.lowercased().contains(lower) ?? false) && seen.insert(song.id).inserted {
                candidates.append(song)
            }
        }

        // 2. Filters.
        let artistKey = query.artist.map(TasteKey.of).flatMap { $0.isEmpty ? nil : $0 }
        let albumKey = query.album.map(TasteKey.of).flatMap { $0.isEmpty ? nil : $0 }
        let genreKey = query.genre.map(TasteKey.of).flatMap { $0.isEmpty ? nil : $0 }
        if query.hasFilters {
            candidates = candidates.filter { song in
                if let artistKey, !TasteKey.artists(song).contains(where: { $0.contains(artistKey) }) { return false }
                if let albumKey, !TasteKey.album(song).contains(albumKey) { return false }
                if let genreKey, !TasteKey.genres(song).contains(where: { $0.contains(genreKey) }) { return false }
                if let from = query.yearFrom, song.year < from || song.year <= 0 { return false }
                if let to = query.yearTo, song.year > to || song.year <= 0 { return false }
                let plays = stats[song.id]?.plays ?? 0
                if let minimum = query.minPlays, plays < minimum { return false }
                if let maximum = query.maxPlays, plays > maximum { return false }
                if query.neverPlayed, plays > 0 { return false }
                if query.likedOnly, !song.isFavorite { return false }
                return true
            }
        }

        // 3. Order.
        let sort = (query.sort == .relevance && text.isEmpty) ? LibraryQuery.Sort.title : query.sort
        func plays(_ song: Song) -> Int { stats[song.id]?.plays ?? 0 }
        func last(_ song: Song) -> Int64 { stats[song.id]?.lastPlayedMs ?? 0 }
        switch sort {
        case .relevance:
            break
        case .mostPlayed:
            candidates.sort { plays($0) != plays($1) ? plays($0) > plays($1) : titleBefore($0, $1) }
        case .recentlyPlayed:
            candidates.sort { last($0) != last($1) ? last($0) > last($1) : titleBefore($0, $1) }
        case .recentlyAdded:
            candidates.sort { $0.dateAdded != $1.dateAdded ? $0.dateAdded > $1.dateAdded : titleBefore($0, $1) }
        case .title:
            let keys = Dictionary(candidates.map { ($0.id, SearchFolding.fold($0.title)) }, uniquingKeysWith: { first, _ in first })
            candidates.sort { lhs, rhs in
                let a = keys[lhs.id] ?? "", b = keys[rhs.id] ?? ""
                return a != b ? a < b : lhs.id < rhs.id
            }
        case .random:
            var random = JavaRandom(seed: seed)
            var keyed = candidates.map { ($0, random.nextDouble()) }
            keyed.sort { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.id < $1.0.id }
            candidates = keyed.map(\.0)
        }

        // 4. The page.
        let total = candidates.count
        let start = min(offset, total)
        let end = min(start + limit, total)
        return LibraryPage(songs: Array(candidates[start..<end]), totalMatches: total, offset: start,
                           nextOffset: end < total ? end : nil, totalIsLowerBound: lowerBound)
    }

    private static func titleBefore(_ lhs: Song, _ rhs: Song) -> Bool {
        let a = SearchFolding.fold(lhs.title), b = SearchFolding.fold(rhs.title)
        return a != b ? a < b : lhs.id < rhs.id
    }
}

// MARK: - Overview

public struct LibraryOverview: Sendable {
    public struct Bucket: Sendable, Hashable {
        public var name: String
        public var songs: Int
    }

    public var songs: Int
    public var artists: Int
    public var albums: Int
    public var playlists: Int
    public var liked: Int
    public var neverPlayed: Int
    public var withGenre: Int
    public var withYear: Int
    public var topGenres: [Bucket]
    public var decades: [Bucket]

    public static let maxGenres = 12

    /// `artists`, `albums` and `playlists` come from the library's own lists when it has them; otherwise the distinct
    /// artists and albums of the songs are counted.
    public static func build(songs: [Song], stats: [String: SongPlayStats], artists: Int? = nil, albums: Int? = nil,
                             playlists: Int = 0) -> LibraryOverview {
        var genreCounts: [String: Int] = [:]
        var genreNames: [String: String] = [:]
        var decadeCounts: [Int: Int] = [:]
        var artistKeys = Set<String>()
        var albumKeys = Set<String>()
        var liked = 0, never = 0, withGenre = 0, withYear = 0
        for song in songs {
            if song.isFavorite { liked += 1 }
            if (stats[song.id]?.plays ?? 0) == 0 { never += 1 }
            if let genre = song.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty,
               let key = TasteKey.genres(song).first {
                genreCounts[key, default: 0] += 1
                if genreNames[key] == nil { genreNames[key] = genre }
                withGenre += 1
            }
            if song.year > 0 {
                decadeCounts[song.year / 10 * 10, default: 0] += 1
                withYear += 1
            }
            if artists == nil, let key = TasteKey.artists(song).first { artistKeys.insert(key) }
            if albums == nil, !song.album.isEmpty { albumKeys.insert(TasteKey.album(song) + "|" + (TasteKey.artists(song).first ?? "")) }
        }
        let topGenres = genreCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maxGenres).map { Bucket(name: genreNames[$0.key] ?? $0.key, songs: $0.value) }
        let decades = decadeCounts.sorted { $0.key < $1.key }.map { Bucket(name: "\($0.key)s", songs: $0.value) }
        return LibraryOverview(songs: songs.count, artists: artists ?? artistKeys.count, albums: albums ?? albumKeys.count,
                               playlists: playlists, liked: liked, neverPlayed: never, withGenre: withGenre, withYear: withYear,
                               topGenres: Array(topGenres), decades: decades)
    }

    public func json() -> JSONValue {
        func object(_ members: [(String, JSONValue)]) -> JSONValue { .object(JSONObject(members.map { (key: $0.0, value: $0.1) })) }
        func buckets(_ items: [Bucket]) -> JSONValue {
            .array(items.map { object([("name", .string($0.name)), ("songs", .integer($0.songs))]) })
        }
        var members: [(String, JSONValue)] = [
            ("songs", .integer(songs)), ("artists", .integer(artists)), ("albums", .integer(albums)),
            ("playlists", .integer(playlists)), ("liked_songs", .integer(liked)), ("never_played", .integer(neverPlayed)),
        ]
        if !topGenres.isEmpty { members.append(("top_genres", buckets(topGenres))) }
        if !decades.isEmpty { members.append(("decades", buckets(decades))) }
        // What the library does not say about its songs, so a missing genre is not read as "no such songs".
        members.append(("songs_with_genre", .integer(withGenre)))
        members.append(("songs_with_year", .integer(withYear)))
        members.append(("paging", object([("search_library_max_limit", .integer(LibraryQuery.maxLimit)),
                                          ("pages_for_whole_library", .integer(songs == 0 ? 0 : (songs + LibraryQuery.maxLimit - 1) / LibraryQuery.maxLimit))])))
        return object(members)
    }
}
