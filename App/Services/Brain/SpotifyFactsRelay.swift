import Foundation
import PixlLibrary
import PixlModel

/// Hands the facts the Spotify sync receives with every track (docs/brain-spec.md, 13.1) to the brain's store. The
/// sync is built before the brain is, so it holds this relay and the brain plugs its store in when it exists: until
/// then, and in UI tests, a fact is dropped. One lock, no work: a sync pays nothing for it.
nonisolated final class SpotifyFactsRelay: SpotifyFactsSink, @unchecked Sendable {
    static let shared = SpotifyFactsRelay()

    private let lock = NSLock()
    private var target: SpotifyFactStore?

    func set(_ store: SpotifyFactStore?) {
        lock.lock()
        target = store
        lock.unlock()
    }

    func record(_ fact: SpotifyFactInput) {
        lock.lock()
        let store = target
        lock.unlock()
        store?.record(fact)
    }
}
