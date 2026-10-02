import Observation
import PixlModel

/// Per-song play counts (the engagement table), kept for the app's lifetime and refreshed off the main actor when
/// the listening history changes. The artist page builds "Most played" from it synchronously, so the section is
/// there in the push's first frame instead of being inserted above the albums when a fetch lands mid-push.
///
/// A finished play bumps the history revision before its engagement row is written, so a refresh keyed on that
/// revision can read the table one play early; `reload` re-reads it once the write has landed (and after a restore).
@Observable
final class PlayCountStore {
    /// Nil until the first fetch.
    private(set) var entries: [EngagementEntry]?
    /// Bumped whenever `entries` changes (what views key their derived data on).
    private(set) var version = 0
    @ObservationIgnored private var loadedRevision: Int?
    /// Only the latest fetch applies its result (an older one may have read the table before a write).
    @ObservationIgnored private var fetchGeneration = 0

    /// Re-reads the engagement table unless it was read for this history revision already.
    func refresh(editor: LibraryEditor, revision: Int) async {
        guard loadedRevision != revision else { return }
        await fetch(editor: editor, revision: revision)
    }

    /// Re-reads the engagement table even if it was read for this revision: it changed without a history change
    /// (a play's engagement write landing after the revision bump, a backup restore).
    func reload(editor: LibraryEditor, revision: Int) async {
        await fetch(editor: editor, revision: revision)
    }

    private func fetch(editor: LibraryEditor, revision: Int) async {
        loadedRevision = revision
        fetchGeneration &+= 1
        let generation = fetchGeneration
        let fetched = await editor.engagementEntries()
        guard generation == fetchGeneration, fetched != entries else { return }
        entries = fetched
        version &+= 1
    }
}
