import Foundation
import PixlAudioCore
import Synchronization

/// What the processing tap tells the Music Haptics controller. The render thread is the only writer, the controller's
/// queue the only reader; everything here is an atomic scalar (no allocation, no lock: AGENTS.md › Performance rules).
///
/// An onset is published as three values — kind, strength, then a sequence number last (release ordering) — and the
/// reader looks at the sequence first. Two taps (a crossfade) may publish at once; at worst one onset is read with the
/// other's strength, which a haptic tap cannot show.
nonisolated final class HapticSignalBus: @unchecked Sendable {
    /// The analysis runs only while this is set (playing, enabled, nothing blocking): the tap's cost is one atomic load
    /// per buffer otherwise.
    let isActive = Atomic<Bool>(false)

    private let sequence = Atomic<Int>(0)
    private let kind = Atomic<UInt8>(0)
    private let strength = AtomicFloat(0)
    private let bass = AtomicFloat(0)

    /// Render thread: a detected onset.
    @inline(__always)
    func publish(_ onset: HapticOnset) {
        kind.store(onset.kind.rawValue, ordering: .relaxed)
        strength.store(onset.strength)
        sequence.wrappingAdd(1, ordering: .releasing)
    }

    /// Render thread: the smoothed bass level after a buffer.
    @inline(__always)
    func setBass(_ level: Float) { bass.store(level) }

    /// Reader: the number of onsets published so far (wraps).
    var onsetSequence: Int { sequence.load(ordering: .acquiring) }

    /// Reader: the latest onset (valid after `onsetSequence` changed).
    var latestOnset: HapticOnset {
        HapticOnset(kind: HapticOnset.Kind(rawValue: kind.load(ordering: .relaxed)) ?? .kick, strength: strength.load(),
                    frame: 0)
    }

    var bassLevel: Float { bass.load() }

    /// Reader: forgets stale values when the analysis is switched off.
    func clear() {
        bass.store(0)
    }
}
