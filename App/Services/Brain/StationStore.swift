import Foundation
import PixlLibrary

/// The station of the current queue and the novelty switch (docs/brain-spec.md, 8.3), in memory and in the
/// preferences, so a restored queue is still a station after a restart. The port of Android's `StationStore`.
///
/// Two small values of `UserDefaults`, read the first time something asks (the queue's line, the first trigger of
/// Autoplay), never at launch. Not observable: the queue's line reads `AutoplayState`, which the controller and
/// `BrainActions` keep in step. `defaults` nil keeps everything in memory (UI tests).
final class StationStore {
    private let defaults: UserDefaults?
    private var isLoaded = false
    private var station: Station?
    private var level = Novelty.blend

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    private func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let defaults else { return }
        station = Station.decode(defaults.string(forKey: PreferenceKeys.brainStation))
        if defaults.object(forKey: PreferenceKeys.brainNovelty) != nil {
            level = Novelty.clamp(defaults.integer(forKey: PreferenceKeys.brainNovelty))
        }
    }

    /// The station the listener last started and that has not ended; nil for none.
    var current: Station? {
        ensureLoaded()
        return station
    }

    /// `Novelty.familiar`, `.blend` or `.discover`.
    var novelty: Int {
        ensureLoaded()
        return level
    }

    func start(_ station: Station) {
        ensureLoaded()
        self.station = station
        defaults?.set(station.encode(), forKey: PreferenceKeys.brainStation)
    }

    /// The queue is no longer this station's. Safe to call when there is none.
    func clear() {
        ensureLoaded()
        guard station != nil else { return }
        station = nil
        defaults?.removeObject(forKey: PreferenceKeys.brainStation)
    }

    /// True when the level changed.
    @discardableResult
    func setNovelty(_ newLevel: Int) -> Bool {
        ensureLoaded()
        let next = Novelty.clamp(newLevel)
        guard next != level else { return false }
        level = next
        defaults?.set(next, forKey: PreferenceKeys.brainNovelty)
        return true
    }
}
