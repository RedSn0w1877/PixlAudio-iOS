// "Find in playlist" (iOS-first, owner request 2026-10-18): a list's songs reduced to one folded string each, built
// once, so a keystroke is a substring scan and nothing is lowercased, folded or allocated per song per query.
// Title, artist (every credited artist) and album are searched; case and diacritics are ignored; the page's own
// order is kept. Every word of the query must appear (in any of the three fields), so "dua radio" finds
// "Dua Lipa – Radio".

import Foundation
import PixlModel

public struct SongFilterIndex: Sendable {
    /// The indexed songs' ids, in the list's order.
    public let ids: [String]
    private let haystacks: [String]

    /// Builds the index. O(songs); call it off the main actor once per list (not per keystroke).
    public init(songs: [Song]) {
        ids = songs.map(\.id)
        haystacks = songs.map { song in
            SearchFolding.fold(song.title) + "\n" + SearchFolding.fold(song.displayArtist) + "\n"
                + SearchFolding.fold(song.album)
        }
    }

    public var count: Int { ids.count }

    /// The words of a query, folded; empty when it holds none.
    public static func words(of query: String) -> [String] {
        SearchFolding.fold(query).split(separator: " ").map(String.init)
    }

    /// Positions (indexes into the indexed list, ascending) of the songs that match every word.
    /// An empty query matches everything.
    public func matchingIndexes(for query: String) -> [Int] {
        let words = Self.words(of: query)
        if words.isEmpty { return Array(ids.indices) }
        var result: [Int] = []
        for index in haystacks.indices {
            let haystack = haystacks[index]
            var all = true
            for word in words where !haystack.contains(word) {
                all = false
                break
            }
            if all { result.append(index) }
        }
        return result
    }

    /// The songs of `songs` (the list the index was built from) that match, in their order.
    public func filter(_ songs: [Song], query: String) -> [Song] {
        let words = Self.words(of: query)
        if words.isEmpty { return songs }
        return matchingIndexes(for: query).compactMap { songs.indices.contains($0) ? songs[$0] : nil }
    }
}
