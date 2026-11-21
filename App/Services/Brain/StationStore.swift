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
    /// The media ids of the album or playlist an album or playlist station came from, for its first batch (6.2: none of
    /// the source's own songs lead). Memory only: after a restart the first batch is long served.
    private(set) var sourceIds: Set<String> = []
    /// The saved level while the host's chips ("Something new") hold another one for this listening only (`HostNoveltyHold`).
    private var hostHold = HostNoveltyHold()

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

    func start(_ station: Station, sourceIds: Set<String> = []) {
        ensureLoaded()
        // Another station than Endless Listening begins: the level the host's chips held goes back.
        if !station.isEndless { putBackHostNovelty() }
        self.sourceIds = sourceIds
        self.station = station
        defaults?.set(station.encode(), forKey: PreferenceKeys.brainStation)
    }

    /// The queue is no longer this station's. Safe to call when there is none.
    func clear() {
        ensureLoaded()
        guard station != nil else { return }
        putBackHostNovelty()
        sourceIds = []
        station = nil
        defaults?.removeObject(forKey: PreferenceKeys.brainStation)
    }

    /// True when the level changed. The listener's own switch: it is saved, and nothing the host's chips held is put back.
    @discardableResult
    func setNovelty(_ newLevel: Int) -> Bool {
        ensureLoaded()
        let next = Novelty.clamp(newLevel)
        // A level a chip held is only in memory: the listener choosing it too still has to save it.
        let held = hostHold.isHolding
        hostHold.forget()
        guard next != level || held else { return false }
        let changed = next != level
        level = next
        defaults?.set(next, forKey: PreferenceKeys.brainNovelty)
        return changed
    }

    /// The host's "Something new" / "Back to familiar": `newLevel` applies now and is NOT saved; the saved level comes back when Endless
    /// Listening ends. True when the level in force changed.
    @discardableResult
    func setNoveltyForHost(_ newLevel: Int) -> Bool {
        ensureLoaded()
        let next = hostHold.hold(level: newLevel, current: level)
        guard next != level else { return false }
        level = next
        return true
    }

    /// The level "Back to familiar" goes back to: the one saved before the chips, Blend when that was Discover or is not known.
    func levelBeforeHost() -> Int {
        ensureLoaded()
        return hostHold.levelBeforeHost(current: level)
    }

    private func putBackHostNovelty() {
        guard let saved = hostHold.release() else { return }
        level = saved
    }
}
