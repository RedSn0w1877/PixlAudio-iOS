import Foundation
import PixlAudioCore
import PixlModel
import Synchronization

// Parameters shared between the main actor (single writer) and the processing-tap render thread (reader).
// Real-time rules (AGENTS.md): the render thread never allocates, locks or logs. Everything it reads is either an
// `Atomic` scalar or a slot of a preallocated ring whose index is published with release/acquire ordering.

/// A single-writer ring of plain-old-data values. The writer fills the next slot, then publishes its generation;
/// the reader loads the generation (acquire) and copies that slot. With 8 slots a torn read would need eight
/// publishes during one copy of a few bytes — impossible at UI rates. `Value` must be trivial (no references).
nonisolated final class ParameterRing<Value>: @unchecked Sendable {
    private static var slotMask: Int { 7 }
    private let slots: UnsafeMutablePointer<Value>
    private let published = Atomic<Int>(0)

    init(_ initial: Value) {
        slots = .allocate(capacity: 8)
        slots.initialize(repeating: initial, count: 8)
    }

    deinit {
        slots.deinitialize(count: 8)
        slots.deallocate()
    }

    /// Writer side (one writer at a time; the main actor in the app).
    func publish(_ value: Value) {
        let next = published.load(ordering: .relaxed) &+ 1
        slots[next & Self.slotMask] = value
        published.store(next, ordering: .releasing)
    }

    /// The generation of the latest value (changes on every publish).
    var generation: Int { published.load(ordering: .acquiring) }

    /// Reader side (render thread): the latest value. No allocation.
    @inline(__always)
    func read() -> Value { slots[published.load(ordering: .acquiring) & Self.slotMask] }

    /// The latest value and its generation.
    @inline(__always)
    func readWithGeneration() -> (generation: Int, value: Value) {
        let g = published.load(ordering: .acquiring)
        return (g, slots[g & Self.slotMask])
    }
}

/// A `Float` in an atomic (bit pattern in a `UInt32`).
nonisolated final class AtomicFloat: @unchecked Sendable {
    private let bits: Atomic<UInt32>
    init(_ value: Float) { bits = Atomic(value.bitPattern) }
    @inline(__always) func load() -> Float { Float(bitPattern: bits.load(ordering: .acquiring)) }
    @inline(__always) func store(_ value: Float) { bits.store(value.bitPattern, ordering: .releasing) }
}

/// A `Double` in an atomic (bit pattern in a `UInt64`).
nonisolated final class AtomicDouble: @unchecked Sendable {
    private let bits: Atomic<UInt64>
    init(_ value: Double) { bits = Atomic(value.bitPattern) }
    @inline(__always) func load() -> Double { Double(bitPattern: bits.load(ordering: .acquiring)) }
    @inline(__always) func store(_ value: Double) { bits.store(value.bitPattern, ordering: .releasing) }
}

// MARK: - Global effects (one instance, shared by every tap)

/// Coefficients for one prepared tap at its actual input rate. The settings writer and render reader each own a
/// block. They exchange ownership of the third block atomically, so repeated edits cannot overwrite a block that
/// vDSP is reading. Preparation and publication may allocate; taking the latest block at a buffer boundary cannot.
nonisolated final class TapEqualizerCoefficients: @unchecked Sendable {
    let sampleRate: Double
    private let blocks: UnsafeMutablePointer<Double>
    private static let pending = 4
    private let middle = Atomic<Int>(1)
    private var front = 0   // reader only
    private var back = 2    // writer only

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        blocks = .allocate(capacity: 3 * AudioEffectsParameters.blockSize)
        blocks.initialize(repeating: 0, count: 3 * AudioEffectsParameters.blockSize)
    }

    deinit { blocks.deallocate() }

    func publish(_ settings: EqualizerSettings) {
        let parameters = EqualizerDesigner.design(settings, sampleRate: sampleRate)
        AudioEffectsParameters.write(parameters, into: blocks + back * AudioEffectsParameters.blockSize)
        back = middle.exchange(back | Self.pending, ordering: .acquiringAndReleasing) & ~Self.pending
    }

    /// The pointer remains exclusively the reader's until its next successful exchange.
    @inline(__always)
    func takeUpdate() -> UnsafePointer<Double>? {
        guard middle.load(ordering: .acquiring) & Self.pending != 0 else { return nil }
        front = middle.exchange(front, ordering: .acquiringAndReleasing) & ~Self.pending
        return UnsafePointer(blocks + front * AudioEffectsParameters.blockSize)
    }
}

/// Global effect preferences and the active taps, including both decks during a crossfade.
nonisolated final class AudioEffectsParameters: @unchecked Sendable {
    static let sectionCount = EqualizerChainParameters.sectionCount
    static let blockSize = sectionCount * 5 + 4

    private struct TapReference: Sendable {
        weak var coefficients: TapEqualizerCoefficients?
    }

    private struct State: Sendable {
        var settings = EqualizerSettings()
        var taps: [TapReference] = []
    }

    private let state = Mutex(State())
    /// Mid/side vocal attenuation 0…1 (0 = off).
    let midSideAttenuation = AtomicFloat(0)
    /// Allow ReplayGain gains above unity (+6 dB max) through the soft limiter. Android caps at 1 (parity: false).
    let allowReplayGainBoost = Atomic<Bool>(false)
    /// Music Haptics: the shared signal the taps publish onsets and the bass level to (inactive unless switched on).
    let haptics = HapticSignalBus()
    /// Spatial audio's on-device stage: the profile every tap plays (or none) and the shared coefficients.
    let spatial = SpatialTapShared()

    /// Register with the current settings atomically so a racing edit reaches even a newly prepared tap.
    func coefficients(for sampleRate: Double) -> TapEqualizerCoefficients {
        let coefficients = TapEqualizerCoefficients(sampleRate: sampleRate)
        state.withLock { state in
            state.taps.removeAll { $0.coefficients == nil }
            coefficients.publish(state.settings)
            state.taps.append(TapReference(coefficients: coefficients))
        }
        return coefficients
    }

    func setEqualizer(_ settings: EqualizerSettings) {
        state.withLock { state in
            guard settings != state.settings else { return }
            state.settings = settings
            state.taps.removeAll { $0.coefficients == nil }
            for tap in state.taps { tap.coefficients?.publish(settings) }
        }
    }

    /// Lays out `parameters` as a block.
    static func write(_ parameters: EqualizerChainParameters, into block: UnsafeMutablePointer<Double>) {
        for s in 0..<sectionCount {
            let c = s < parameters.sections.count ? parameters.sections[s] : .identity
            let o = s * 5
            block[o] = c.b0; block[o + 1] = c.b1; block[o + 2] = c.b2; block[o + 3] = c.a1; block[o + 4] = c.a2
        }
        let tail = sectionCount * 5
        block[tail] = Double(parameters.preGain)
        block[tail + 1] = Double(parameters.stereoWidth.width)
        block[tail + 2] = parameters.needsLimiter ? 1 : 0
        block[tail + 3] = parameters.isBypass ? 1 : 0
    }
}

// MARK: - Per-item parameters and meters

/// What one item's tap applies on top of the global effects, plus its meters. Created with the item, owned by
/// both the deck (writer) and the tap context (reader).
nonisolated final class TapItemParameters: @unchecked Sendable {
    /// ReplayGain volume multiplier (1 = unchanged), from `ReplayGain.volumeMultiplier`.
    let replayGainVolume = AtomicFloat(1)
    /// The crossfade gain curve of this item, evaluated from its own media time (nil = unity).
    let ramp = ParameterRing<CrossfadeRamp?>(nil)
    /// A constant gain applied after everything (0 mutes a preparing deck; 1 normally).
    let fixedGain = AtomicFloat(1)
    /// The item's duration in seconds (0 = unknown). Buffers past it are not counted as media by the meters.
    let mediaDuration = AtomicDouble(0)
    /// What Spatial audio does with this item (`SpatialItemRole`), set before the tap is created and never changed:
    /// the on-device stage may run on the song's own audio only, never on a render (never spatialized twice) nor on
    /// Sing's audio.
    let spatialRole = Atomic<Int>(SpatialItemRole.none)
    /// A render's headroom (its manifest's `headroomDb`): the level rule gives it back while the render plays.
    let spatialHeadroomDb = AtomicDouble(0)
    /// Written by the tap's prepare (`SpatialItemFormat`): whether the stage can run on this item's format.
    let spatialFormat = Atomic<Int>(SpatialItemFormat.unknown)
    /// How engaged the stage is, after the last buffer (0 … 1; diagnostics and tests).
    let spatialEngagement = AtomicFloat(0)

    // Meters, written by the render thread.
    /// Media time (s) just past the last processed frame.
    let processedMediaTime = AtomicDouble(0)
    /// Media frames processed (buffers past the end of the item are not counted).
    let processedFrames = Atomic<Int>(0)
    /// Peak absolute sample value of the last buffer, after processing.
    let lastPeak = AtomicFloat(0)
    /// The sample rate the tap was prepared with (0 until then).
    let sampleRate = AtomicDouble(0)
    /// Set once the tap's process callback has run.
    let hasProcessed = Atomic<Bool>(false)

    /// Optional per-buffer log for tests and diagnostics (`enableLog`).
    let log: TapMeterLog?

    init(logCapacity: Int = 0) {
        log = logCapacity > 0 ? TapMeterLog(capacity: logCapacity) : nil
    }
}

/// A preallocated, render-thread-written log of per-buffer measurements: media time of the first frame, frame count,
/// RMS before and after this item's processing. Read only after the item stopped (tests, diagnostics).
nonisolated final class TapMeterLog: @unchecked Sendable {
    struct Entry: Sendable, Hashable {
        var mediaTime: Double
        var frames: Int
        var rmsIn: Float
        var rmsOut: Float
        /// `mach_absolute_time()` when the buffer was processed.
        var hostTime: UInt64
    }

    let capacity: Int
    private let entries: UnsafeMutablePointer<Entry>
    private let count = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        entries = .allocate(capacity: capacity)
        entries.initialize(repeating: Entry(mediaTime: 0, frames: 0, rmsIn: 0, rmsOut: 0, hostTime: 0), count: capacity)
    }

    deinit {
        entries.deinitialize(count: capacity)
        entries.deallocate()
    }

    /// Render thread: appends while there is room (drops the rest).
    @inline(__always)
    func append(_ entry: Entry) {
        let n = count.load(ordering: .relaxed)
        guard n < capacity else { return }
        entries[n] = entry
        count.store(n + 1, ordering: .releasing)
    }

    /// A copy of the entries written so far.
    func snapshot() -> [Entry] {
        let n = count.load(ordering: .acquiring)
        return Array(UnsafeBufferPointer(start: entries, count: n))
    }
}
