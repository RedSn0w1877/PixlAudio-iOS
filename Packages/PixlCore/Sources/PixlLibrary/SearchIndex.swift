// An in-memory replacement for the Android app's Room/SQLite search (`MusicDao` + `MusicRepositoryImpl.searchAll`):
// - songs: the FTS4 `songs_fts(title, artist_name, genre, tokenize=unicode61)` prefix query built by
//   `buildSongSearchMatchQuery` (up to six `[\p{L}\p{N}]+` tokens, each `tok*`, AND-ed; `title:` for title-only),
//   ordered by title (BINARY), then the `LIKE '%q%'` fallback (ASCII case-insensitive, `%`/`_` wildcards), merged
//   without duplicates and capped at 100;
// - albums / artists: `LIKE '%q%'` on title or artist / name, ordered by title / name;
// - playlists: `name.contains(q, ignoreCase = true)`.
// The unicode61 tokenizer (case folding, diacritic removal, token characters) is table-driven from SQLite itself
// (`Unicode61Tables`), so folding matches Android exactly, e.g. "cafe" finds "Café" but "ασμα" does not find "ΆΣΜΑ".

import Foundation
import PixlFoundation
import PixlModel

/// SQLite's unicode61 tokenizer with `remove_diacritics=1`.
public enum Unicode61 {
    /// 0 separator, 1 token character, 2 continues a token only (a combining mark).
    static func tokenClass(_ v: UInt32) -> UInt8 {
        let runs = Unicode61Tables.classRuns
        var lo = 0, hi = runs.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if runs[mid].0 <= v { lo = mid } else { hi = mid - 1 }
        }
        return runs[lo].1
    }

    /// The folded scalar (0 = dropped).
    static func fold(_ v: UInt32) -> UInt32 {
        if v < 0x80 { return (v >= 0x41 && v <= 0x5A) ? v + 0x20 : v }
        let runs = Unicode61Tables.foldRuns
        var lo = 0, hi = runs.count - 1
        guard hi >= 0, runs[0].0 <= v else { return v }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if runs[mid].0 <= v { lo = mid } else { hi = mid - 1 }
        }
        let run = runs[lo]
        guard v < run.0 + run.1 else { return v }
        if run.2 == Int32.min { return 0 }
        return UInt32(Int64(v) + Int64(run.2))
    }

    /// The folded tokens of `text`, as UTF-8 bytes.
    public static func tokenize(_ text: String) -> [[UInt8]] {
        var tokens: [[UInt8]] = []
        var current: [UInt8] = []
        var inToken = false
        func append(_ v: UInt32) {
            guard v != 0, let scalar = Unicode.Scalar(v) else { return }
            current.append(contentsOf: String(scalar).utf8)
        }
        for scalar in text.unicodeScalars {
            let cls = tokenClass(scalar.value)
            if inToken {
                if cls != 0 {
                    append(fold(scalar.value))
                } else {
                    tokens.append(current)
                    current = []
                    inToken = false
                }
            } else if cls == 1 {
                inToken = true
                append(fold(scalar.value))
            }
        }
        if inToken { tokens.append(current) }
        return tokens
    }

    /// Tokens as strings (for tests and diagnostics).
    public static func tokenStrings(_ text: String) -> [String] {
        tokenize(text).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// SQLite `LIKE` without ESCAPE: `%` any run, `_` one character, ASCII letters case-insensitive.
enum SQLiteLike {
    static func matches(_ text: String, pattern: [UInt32]) -> Bool { matches(folded: folded(text), pattern: pattern) }

    /// The text's scalars with ASCII letters lower-cased (precomputed by the index).
    static func folded(_ text: String) -> [UInt32] { text.unicodeScalars.map { fold($0.value) } }

    static func matches(folded s: [UInt32], pattern: [UInt32]) -> Bool {
        let p = pattern
        // Wildcard matching with backtracking on the last `%` (linear for typical patterns).
        var si = 0, pi = 0
        var starP = -1, starS = 0
        while si < s.count {
            if pi < p.count, p[pi] == 0x25 {
                starP = pi
                starS = si
                pi += 1
            } else if pi < p.count, p[pi] == 0x5F || p[pi] == s[si] {
                si += 1
                pi += 1
            } else if starP >= 0 {
                pi = starP + 1
                starS += 1
                si = starS
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == 0x25 { pi += 1 }
        return pi == p.count
    }

    /// The pattern `'%' || q || '%'`, folded.
    static func containsPattern(_ query: String) -> [UInt32] {
        [0x25] + query.unicodeScalars.map { fold($0.value) } + [0x25]
    }

    @inline(__always)
    static func fold(_ v: UInt32) -> UInt32 { (v >= 0x41 && v <= 0x5A) ? v + 0x20 : v }
}

/// A snapshot search index over the library.
public struct SearchIndex: Sendable {
    /// `SEARCH_RESULTS_LIMIT`.
    public static let resultsLimit = 100
    /// `EMPTY_SONG_SEARCH_MATCH_QUERY`: the query used when the input has no letters or digits.
    public static let emptyMatchQuery = "pixelplayemptyquery*"

    struct SongEntry: Sendable {
        let song: Song
        /// Folded tokens per FTS column: title, artist_name, genre.
        let columns: [[[UInt8]]]
        let likeTitle: [UInt32]
        let likeArtist: [UInt32]
        let likeGenre: [UInt32]?
    }

    /// One token occurrence for prefix lookups.
    struct Posting: Sendable {
        let token: [UInt8]
        let song: Int32
        let column: UInt8
    }

    let songs: [SongEntry]
    /// Every token, sorted by bytes, for binary-searched prefix terms.
    let postings: [Posting]
    /// Each song's position in title (BINARY) order, ties in insertion order (SQLite's `ORDER BY title`).
    let titleRank: [Int32]
    let albums: [Album]
    let artists: [Artist]
    let playlists: [Playlist]

    /// Builds the index. `songs` order stands in for row ids (ties in title order keep it).
    public init(songs: [Song], albums: [Album] = [], artists: [Artist] = [], playlists: [Playlist] = []) {
        let entries = songs.map {
            SongEntry(song: $0,
                      columns: [Unicode61.tokenize($0.title), Unicode61.tokenize($0.artist), Unicode61.tokenize($0.genre ?? "")],
                      likeTitle: SQLiteLike.folded($0.title), likeArtist: SQLiteLike.folded($0.artist),
                      likeGenre: $0.genre.map(SQLiteLike.folded))
        }
        var postings: [Posting] = []
        for (index, entry) in entries.enumerated() {
            for (column, tokens) in entry.columns.enumerated() {
                for token in tokens { postings.append(Posting(token: token, song: Int32(index), column: UInt8(column))) }
            }
        }
        postings.sort { $0.token.lexicographicallyPrecedes($1.token) }
        var rank = [Int32](repeating: 0, count: entries.count)
        let order = Array(entries.indices).kotlinSorted { KotlinText.compareBinary(entries[$0].song.title, entries[$1].song.title) }
        for (position, index) in order.enumerated() { rank[index] = Int32(position) }
        self.songs = entries
        self.postings = postings
        self.titleRank = rank
        self.albums = albums
        self.artists = artists
        self.playlists = playlists
    }

    // MARK: Query building (MusicDao)

    /// `buildSongSearchMatchQuery` / `buildSongTitleSearchMatchQuery`.
    public static func matchQuery(_ query: String, titleOnly: Bool) -> String {
        let tokens = queryTokens(query)
        if tokens.isEmpty { return emptyMatchQuery }
        return tokens.map { titleOnly ? "title:\($0)*" : "\($0)*" }.joined(separator: " AND ")
    }

    /// Up to six runs of letters/digits (Java `[\p{L}\p{N}]+`).
    static func queryTokens(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty { tokens.append(String(current)) }
            current = String.UnicodeScalarView()
        }
        for scalar in query.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                current.append(scalar)
            default:
                flush()
            }
        }
        flush()
        return Array(tokens.map { $0.kotlinTrimmed() }.filter { !$0.isEmpty }.prefix(6))
    }

    // MARK: Songs

    struct Term {
        /// Folded tokens; prefix match on the last.
        let phrase: [[UInt8]]
        let titleOnly: Bool
    }

    static func terms(_ query: String, titleOnly: Bool) -> [Term] {
        let tokens = queryTokens(query)
        if tokens.isEmpty { return [Term(phrase: Unicode61.tokenize("pixelplayemptyquery"), titleOnly: false)] }
        return tokens.map { Term(phrase: Unicode61.tokenize($0), titleOnly: titleOnly) }
    }

    static func phraseMatches(_ column: [[UInt8]], _ phrase: [[UInt8]]) -> Bool {
        guard !phrase.isEmpty, column.count >= phrase.count else { return false }
        for start in 0...(column.count - phrase.count) {
            var ok = true
            for (offset, token) in phrase.enumerated() {
                let candidate = column[start + offset]
                let isLast = offset == phrase.count - 1
                if isLast ? !candidate.starts(with: token) : candidate != token { ok = false; break }
            }
            if ok { return true }
        }
        return false
    }

    /// Songs with a token starting with `prefix` in an allowed column (binary search over the postings).
    func songsWithPrefix(_ prefix: [UInt8], titleOnly: Bool) -> Set<Int32> {
        var lo = 0, hi = postings.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if postings[mid].token.lexicographicallyPrecedes(prefix) { lo = mid + 1 } else { hi = mid }
        }
        var result = Set<Int32>()
        var i = lo
        while i < postings.count, postings[i].token.starts(with: prefix) {
            if !titleOnly || postings[i].column == 0 { result.insert(postings[i].song) }
            i += 1
        }
        return result
    }

    /// Rows matching the FTS query, ordered by title (BINARY), at most `limit`.
    func ftsSongs(_ query: String, titleOnly: Bool, limit: Int) -> [Song] {
        var candidates: Set<Int32>?
        for term in Self.terms(query, titleOnly: titleOnly) {
            let matches: Set<Int32>
            if term.phrase.isEmpty {
                matches = []
            } else if term.phrase.count == 1 {
                matches = songsWithPrefix(term.phrase[0], titleOnly: term.titleOnly)
            } else {
                // Multi-token phrase: consecutive tokens within one column.
                let first = songsWithPrefix(term.phrase[0], titleOnly: term.titleOnly)
                matches = first.filter { index in
                    let columns = songs[Int(index)].columns
                    return (term.titleOnly ? [columns[0]] : columns).contains { Self.phraseMatches($0, term.phrase) }
                }
            }
            candidates = candidates.map { $0.intersection(matches) } ?? matches
            if candidates?.isEmpty == true { break }
        }
        let hits = (candidates ?? []).sorted { titleRank[Int($0)] < titleRank[Int($1)] }
        return hits.prefix(limit).map { songs[Int($0)].song }
    }

    /// Rows matching `LIKE '%q%'` (title only, or title/artist/genre), ordered by title, at most `limit`.
    func likeSongs(_ trimmedQuery: String, titleOnly: Bool, limit: Int) -> [Song] {
        let pattern = SQLiteLike.containsPattern(trimmedQuery)
        var hits: [Int] = []
        for (index, entry) in songs.enumerated() {
            if SQLiteLike.matches(folded: entry.likeTitle, pattern: pattern)
                || (!titleOnly && (SQLiteLike.matches(folded: entry.likeArtist, pattern: pattern)
                    || (entry.likeGenre.map { SQLiteLike.matches(folded: $0, pattern: pattern) } ?? false))) {
                hits.append(index)
            }
        }
        hits.sort { titleRank[$0] < titleRank[$1] }
        return hits.prefix(limit).map { songs[$0].song }
    }

    /// `searchSongs` (`MusicDao.searchSongsLimited`): FTS hits, then LIKE hits, without duplicates.
    public func searchSongs(_ query: String, titleOnly: Bool = false, limit: Int = resultsLimit) -> [Song] {
        if query.isKotlinBlank { return [] }
        return mergedSongs(query, titleOnly: titleOnly, limit: limit)
    }

    func mergedSongs(_ query: String, titleOnly: Bool, limit: Int) -> [Song] {
        let fts = ftsSongs(query, titleOnly: titleOnly, limit: limit)
        let like = likeSongs(query.kotlinTrimmed(), titleOnly: titleOnly, limit: limit)
        var seen = Set<KotlinKey>()
        var merged: [Song] = []
        for song in fts + like where seen.insert(KotlinKey(song.id)).inserted { merged.append(song) }
        return Array(merged.prefix(limit))
    }

    // MARK: Albums, artists, playlists

    /// `searchAlbums`: title or artist `LIKE '%q%'`, at least `minTracks` songs, ordered by title.
    public func searchAlbums(_ query: String, minTracks: Int = 1, limit: Int = resultsLimit) -> [Album] {
        if query.isKotlinBlank { return [] }
        return likeAlbums(query, minTracks: minTracks, limit: limit)
    }

    func likeAlbums(_ query: String, minTracks: Int, limit: Int) -> [Album] {
        let pattern = SQLiteLike.containsPattern(query)
        let hits = albums.filter { album in
            album.songCount >= max(minTracks, 1)
                && (SQLiteLike.matches(album.title, pattern: pattern) || SQLiteLike.matches(album.artist, pattern: pattern))
        }
        return Array(hits.kotlinSorted { KotlinText.compareBinary($0.title, $1.title) }.prefix(limit))
    }

    /// `searchArtists`: name `LIKE '%q%'` among artists with songs, ordered by name.
    public func searchArtists(_ query: String, limit: Int = resultsLimit) -> [Artist] {
        if query.isKotlinBlank { return [] }
        return likeArtists(query, limit: limit)
    }

    func likeArtists(_ query: String, limit: Int) -> [Artist] {
        let pattern = SQLiteLike.containsPattern(query)
        let hits = artists.filter { $0.songCount > 0 && SQLiteLike.matches($0.name, pattern: pattern) }
        return Array(hits.kotlinSorted { KotlinText.compareBinary($0.name, $1.name) }.prefix(limit))
    }

    /// `searchPlaylists`: names containing the query, ignoring case.
    public func searchPlaylists(_ query: String) -> [Playlist] {
        if query.isKotlinBlank { return [] }
        return playlists.filter { KotlinText.contains($0.name, query, ignoreCase: true) }
    }

    /// `searchAll`: All = songs, albums, artists, playlists; Songs searches titles only. Catalogue and YouTube
    /// Music results come from the network, not the library.
    public func searchAll(_ query: String, filter: SearchFilterType, minTracksPerAlbum: Int = 1) -> [SearchResultItem] {
        if query.isKotlinBlank { return [] }
        switch filter {
        case .all:
            return searchSongs(query).map(SearchResultItem.song)
                + searchAlbums(query, minTracks: minTracksPerAlbum).map(SearchResultItem.album)
                + searchArtists(query).map(SearchResultItem.artist)
                + searchPlaylists(query).map(SearchResultItem.playlist)
        case .songs: return searchSongs(query, titleOnly: true).map(SearchResultItem.song)
        case .albums: return searchAlbums(query, minTracks: minTracksPerAlbum).map(SearchResultItem.album)
        case .artists: return searchArtists(query).map(SearchResultItem.artist)
        case .playlists: return searchPlaylists(query).map(SearchResultItem.playlist)
        case .catalog, .youtubeMusic: return []
        }
    }
}
