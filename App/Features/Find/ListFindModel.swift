import Foundation
import Observation
import PixlLibrary
import PixlModel

/// "Find in playlist" (iOS-first, owner request 2026-10-18): the state of the search field a list page reveals when
/// it is pulled down past the top, and the filtered list it produces.
///
/// Cheap on large lists: the folded search strings of the page's songs are built once per list (`SongFilterIndex`),
/// off the main actor, and each keystroke only runs a debounced (80 ms) substring scan, also off the main actor. The
/// page shows `results` while a query is typed and its own list otherwise; results keep the page's order.
@Observable
final class ListFindModel {
    /// The field is on screen.
    private(set) var isOpen = false
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    /// The songs matching the query, in the page's order; nil while the query is empty (the page shows everything).
    private(set) var results: [Song]?
    /// A query has been typed and the filter finished: used for the "No matches" state.
    var hasNoMatches: Bool { results?.isEmpty ?? false }

    @ObservationIgnored private var songs: [Song] = []
    @ObservationIgnored private var signature = 0
    @ObservationIgnored private var index: SongFilterIndex?
    @ObservationIgnored private var indexedSignature = -1
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The debounce between the last keystroke and the scan.
    static let debounce: Duration = .milliseconds(80)

    /// The page's songs (call when they change; cheap when they do not).
    func setSongs(_ songs: [Song]) {
        var hasher = Hasher()
        hasher.combine(songs.count)
        for song in songs { hasher.combine(song.id) }
        let newSignature = hasher.finalize()
        self.songs = songs
        guard newSignature != signature else { return }
        signature = newSignature
        index = nil
        indexedSignature = -1
        if isOpen, results != nil { runFilter(immediately: true) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        // Build the index now, while the person reaches for the keyboard.
        warmIndex()
    }

    /// Cancel, or the page scrolled away from the top with nothing typed: clears the query and hides the field.
    func close() {
        task?.cancel()
        task = nil
        isOpen = false
        query = ""
        results = nil
    }

    private func warmIndex() {
        guard index == nil, !songs.isEmpty else { return }
        let songs = self.songs, key = signature
        Task { [weak self] in
            let built = await Self.buildIndex(songs)
            guard let self, self.signature == key, self.index == nil else { return }
            self.index = built
            self.indexedSignature = key
        }
    }

    private func queryChanged() {
        guard isOpen else { return }
        if SongFilterIndex.words(of: query).isEmpty {
            task?.cancel()
            task = nil
            results = nil
            return
        }
        runFilter(immediately: false)
    }

    private func runFilter(immediately: Bool) {
        task?.cancel()
        let songs = self.songs, query = self.query, key = signature
        let known = indexedSignature == key ? index : nil
        task = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: Self.debounce) }
            guard !Task.isCancelled else { return }
            let outcome = await Self.filter(songs: songs, index: known, query: query)
            guard !Task.isCancelled, let self, self.signature == key else { return }
            self.index = outcome.index
            self.indexedSignature = key
            self.results = outcome.results
        }
    }

    @concurrent
    private static func buildIndex(_ songs: [Song]) async -> SongFilterIndex {
        SongFilterIndex(songs: songs)
    }

    @concurrent
    private static func filter(songs: [Song], index: SongFilterIndex?, query: String) async
        -> (index: SongFilterIndex, results: [Song]) {
        let index = index ?? SongFilterIndex(songs: songs)
        return (index, index.filter(songs, query: query))
    }
}
