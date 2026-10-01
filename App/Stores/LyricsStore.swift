import Foundation
import Observation
import PixlModel

/// Lyrics of the current song as the UI shows them. Stage 9 (`LyricsController` over `LyricsService`: providers,
/// cache, embedded tags) drives it; the karaoke view reads `state`, never the per-frame engine values (those live in
/// the lyrics driver).
@Observable
final class LyricsStore {
    nonisolated enum State: Equatable, Sendable {
        case idle
        case loading(songId: String)
        /// Plain, line-synced or word-synced lyrics (Android `Lyrics`: `plain`, `synced`, `document`).
        case loaded(songId: String, lyrics: Lyrics, source: String?)
        case notFound(songId: String)
        case failed(songId: String, message: String)
    }

    private(set) var state: State = .idle
    /// The user's sync offset for the current song (Android `lyrics_sync_offsets_json`), in milliseconds.
    var offsetMs: Int = 0

    func set(_ newState: State) {
        if state != newState { state = newState }
    }

    var currentLyrics: Lyrics? {
        if case .loaded(_, let lyrics, _) = state { return lyrics }
        return nil
    }

    /// The `LyricsDoc` of the current lyrics, when they have one (word timing, voices, the user's sync).
    var currentDoc: LyricsDoc? { currentLyrics?.document }

    var currentSource: String? {
        if case .loaded(_, _, let source) = state { return source }
        return nil
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }
}
