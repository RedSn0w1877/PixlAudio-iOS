// Blocked artists (iOS-first, owner request 2026-10-18): the pure matching rules and the stored list's codec.
//
// A song is blocked when any of its credited artists is blocked. Matching is id-based first (the artist id the
// block was made from), then by normalised name: artists created by the YouTube / Spotify matcher or by a rescan do
// not keep their ids, so the name (case, diacritics and spacing folded, as search folds them) is what survives.

import Foundation
import PixlFoundation
import PixlModel

/// Text folding shared by "Find in playlist" and the blocked-artist names: the same table-driven case and diacritic
/// folding search uses (`Unicode61`), so "cafe" finds "Café" and "BEYONCÉ" equals "beyonce".
public enum SearchFolding {
    /// `text` folded to lowercase without diacritics; whitespace runs collapse to one space, ends trimmed.
    public static func fold(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
                continue
            }
            let folded = Unicode61.fold(scalar.value)
            guard folded != 0, let out = Unicode.Scalar(folded) else { continue }
            scalars.append(out)
            lastWasSpace = false
        }
        var result = String(scalars)
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}

/// One blocked artist as stored: the id and name at the time of the block.
public struct BlockedArtist: Sendable, Hashable, Codable, Identifiable {
    public var artistId: Int64
    public var name: String
    /// Milliseconds since 1970.
    public var blockedAt: Int64

    public var id: String { "\(artistId)|\(BlockedArtistMatcher.normalize(name))" }

    public init(artistId: Int64, name: String, blockedAt: Int64 = 0) {
        self.artistId = artistId
        self.name = name
        self.blockedAt = blockedAt
    }
}

/// The blocked list as a value that can answer "is this song blocked?" quickly (two set lookups per credited artist).
public struct BlockedArtistMatcher: Sendable, Equatable {
    public static let empty = BlockedArtistMatcher(entries: [])

    private let ids: Set<Int64>
    private let names: Set<String>
    public let entries: [BlockedArtist]

    public init(entries: [BlockedArtist]) {
        self.entries = entries
        ids = Set(entries.map(\.artistId).filter(Self.isUsableId))
        names = Set(entries.map { Self.normalize($0.name) }.filter { !$0.isEmpty })
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// The name key: folded (case, diacritics, spacing).
    public static func normalize(_ name: String) -> String { SearchFolding.fold(name) }

    /// `-1` and `0` mean "no artist" (`Song.emptySong`, unresolved credits).
    private static func isUsableId(_ id: Int64) -> Bool { id != -1 && id != 0 }

    public func isBlocked(artist: ArtistRef) -> Bool {
        isBlocked(artistId: artist.id, name: artist.name)
    }

    public func isBlocked(artistId: Int64, name: String) -> Bool {
        if isEmpty { return false }
        if Self.isUsableId(artistId), ids.contains(artistId) { return true }
        let key = Self.normalize(name)
        return !key.isEmpty && names.contains(key)
    }

    /// Any credited artist (every `artists` entry; the legacy single-artist fields when there are none).
    public func isBlocked(_ song: Song) -> Bool {
        if isEmpty { return false }
        if song.artists.isEmpty { return isBlocked(artistId: song.artistId, name: song.artist) }
        for ref in song.artists where isBlocked(artist: ref) { return true }
        return false
    }

    /// The blocked credited artists of `song` (for "Blocked: <name>" captions).
    public func blockedArtists(of song: Song) -> [ArtistRef] {
        if isEmpty { return [] }
        if song.artists.isEmpty {
            let ref = ArtistRef(id: song.artistId, name: song.artist, isPrimary: true)
            return isBlocked(artist: ref) ? [ref] : []
        }
        return song.artists.filter { isBlocked(artist: $0) }
    }

    /// `songs` without the blocked ones, order kept.
    public func allowed(_ songs: [Song]) -> [Song] {
        isEmpty ? songs : songs.filter { !isBlocked($0) }
    }

    /// The matcher with `artist` added (an existing entry for the same artist is kept as it is).
    public func adding(_ artist: BlockedArtist) -> BlockedArtistMatcher {
        if isBlocked(artistId: artist.artistId, name: artist.name) { return self }
        return BlockedArtistMatcher(entries: entries + [artist])
    }

    /// The matcher without the entries `artist` matches (by id or by name).
    public func removing(artistId: Int64, name: String) -> BlockedArtistMatcher {
        let key = Self.normalize(name)
        return BlockedArtistMatcher(entries: entries.filter { entry in
            let sameId = Self.isUsableId(artistId) && entry.artistId == artistId
            let sameName = !key.isEmpty && Self.normalize(entry.name) == key
            return !(sameId || sameName)
        })
    }
}

/// The stored form: a JSON array, sorted by name (newest first would shuffle the settings list on every change).
public enum BlockedArtistCodec {
    public static func encode(_ entries: [BlockedArtist]) -> String {
        let sorted = entries.sorted { lhs, rhs in
            let a = BlockedArtistMatcher.normalize(lhs.name), b = BlockedArtistMatcher.normalize(rhs.name)
            return a != b ? a < b : lhs.artistId < rhs.artistId
        }
        guard let data = try? JSONEncoder().encode(sorted) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Unreadable text is an empty list; duplicates (same id or name) collapse to the first.
    public static func decode(_ text: String?) -> [BlockedArtist] {
        guard let text, let data = text.data(using: .utf8),
              let entries = try? JSONDecoder().decode([BlockedArtist].self, from: data) else { return [] }
        var seen = Set<String>()
        var result: [BlockedArtist] = []
        for entry in entries {
            let key = BlockedArtistMatcher.normalize(entry.name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(entry)
        }
        return result
    }
}

/// Which queue position plays next / previous when some entries are blocked: the nearest one in the direction that is
/// not blocked, nil when every candidate is blocked (or the end is reached without wrapping).
public enum BlockedNavigation {
    /// The first index after `current` (wrapping to the start when `wraps`) for which `isBlocked` is false.
    /// Walks at most one full cycle; `current` itself is the last candidate when wrapping.
    public static func next(after current: Int, count: Int, wraps: Bool, isBlocked: (Int) -> Bool) -> Int? {
        guard count > 0, current >= 0, current < count else { return nil }
        for step in 1...count {
            var index = current + step
            if index >= count {
                guard wraps else { return nil }
                index %= count
            }
            if !isBlocked(index) { return index }
        }
        return nil
    }

    /// The first index before `current` (wrapping to the end when `wraps`) for which `isBlocked` is false.
    public static func previous(before current: Int, count: Int, wraps: Bool, isBlocked: (Int) -> Bool) -> Int? {
        guard count > 0, current >= 0, current < count else { return nil }
        for step in 1...count {
            var index = current - step
            if index < 0 {
                guard wraps else { return nil }
                index = (index % count + count) % count
            }
            if !isBlocked(index) { return index }
        }
        return nil
    }

    /// The first index at or after `start` (wrapping) that is not blocked: where "Play" starts a list.
    public static func firstPlayable(from start: Int, count: Int, isBlocked: (Int) -> Bool) -> Int? {
        guard count > 0 else { return nil }
        let from = min(max(start, 0), count - 1)
        if !isBlocked(from) { return from }
        return next(after: from, count: count, wraps: true, isBlocked: isBlocked)
    }
}
