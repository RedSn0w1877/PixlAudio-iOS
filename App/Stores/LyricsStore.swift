import Foundation
import Observation
import PixlModel

/// Lyrics of the current song as the UI shows them. Stage 9 (`LyricsService`: providers, cache, embedded tags)
/// drives it; the karaoke view reads `state`, never the per-frame engine values (those live in the lyrics driver).
@Observable
final class LyricsStore {
    nonisolated enum State: Equatable, Sendable {
        case idle
        case loading(songId: String)
        case loaded(songId: String, doc: LyricsDoc, source: String?)
        case notFound(songId: String)
        case failed(songId: String, message: String)
    }

    private(set) var state: State = .idle
    /// The user's sync offset for the current song (Android `lyrics_sync_offsets_json`), in milliseconds.
    var offsetMs: Int = 0

    func set(_ newState: State) {
        if state != newState { state = newState }
    }

    var currentDoc: LyricsDoc? {
        if case .loaded(_, let doc, _) = state { return doc }
        return nil
    }
}
