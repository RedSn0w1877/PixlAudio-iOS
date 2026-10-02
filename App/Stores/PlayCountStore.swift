import Observation
import PixlModel

/// Per-song play counts (the engagement table), kept for the app's lifetime and refreshed off the main actor when
/// the listening history changes. The artist page builds "Most played" from it synchronously, so the section is
/// there in the push's first frame instead of being inserted above the albums when a fetch lands mid-push.
@Observable
final class PlayCountStore {
    /// Nil until the first fetch.
    private(set) var entries: [EngagementEntry]?
    /// Bumped whenever `entries` changes (what views key their derived data on).
    private(set) var version = 0
    @ObservationIgnored private var loadedRevision: Int?

    /// Re-reads the engagement table unless it was read for this history revision already.
    func refresh(editor: LibraryEditor, revision: Int) async {
        guard loadedRevision != revision else { return }
        loadedRevision = revision
        let fetched = await editor.engagementEntries()
        guard fetched != entries else { return }
        entries = fetched
        version &+= 1
    }
}
