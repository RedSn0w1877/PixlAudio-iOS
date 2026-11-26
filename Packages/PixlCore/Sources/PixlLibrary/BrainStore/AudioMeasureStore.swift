// Stage 5 (docs/brain-spec.md 3.3, 6.5): what the phone measured from a track's decoded audio (`AudioFeatures`), and the flow facts
// the planners read. A port of Android's `brain.db` version 8 table `audio_measure` (`BrainEntitiesV8.kt`), `AudioMeasureStore.kt`
// and `AudioMeasurePolicy`, as one keyed record file like the other brain tables:
//
//     audio_measure.pbl   `<rid>`   ->  an `AudioMeasureRow`
//
// A cache: one row per recording, measured once per `AudioFeatures.version`; a row of an older version is measured again the next
// time the track plays. Nothing here is the listener's history. A failed attempt is a row too (`failures` > 0, no values), so a
// track that cannot be decoded is not tried on every play. A stage 4 install has no such file: it is an empty store, which is the
// iOS form of Android's `MIGRATION_7_8` (a new table, nothing existing touched).

import Foundation

public struct AudioMeasureRow: Codable, Sendable, Equatable {
    public static let formatVersion = 1
    /// The record format (not the estimator's version).
    public var v: Int = AudioMeasureRow.formatVersion
    public var rid: Int64
    /// `AudioFeatures.version` of the estimator that measured it.
    public var version: Int
    /// Tempo x 10; 0 when not measured.
    public var bpmX10: Int
    /// 0...1000.
    public var tempoConf: Int
    /// Integrated loudness in LUFS x 10, or `AudioFeatures.loudnessUnknown`.
    public var lufsX10: Int
    public var onsetX1000: Int
    public var analysedMs: Int
    /// Where the decode window started in the track, and how long the track was (for the diagnostics row).
    public var windowStartMs: Int64
    public var durationMs: Int64
    public var measuredAtMs: Int64
    /// Failed attempts in a row; reset by a success.
    public var failures: Int

    public init(rid: Int64, version: Int, bpmX10: Int, tempoConf: Int, lufsX10: Int, onsetX1000: Int, analysedMs: Int,
                windowStartMs: Int64, durationMs: Int64, measuredAtMs: Int64, failures: Int) {
        self.rid = rid
        self.version = version
        self.bpmX10 = bpmX10
        self.tempoConf = tempoConf
        self.lufsX10 = lufsX10
        self.onsetX1000 = onsetX1000
        self.analysedMs = analysedMs
        self.windowStartMs = windowStartMs
        self.durationMs = durationMs
        self.measuredAtMs = measuredAtMs
        self.failures = failures
    }

    /// The measurement as the pure core reads it; nil for a failed row.
    public var result: AudioFeatures.Result? {
        if failures > 0 || analysedMs <= 0 { return nil }
        return AudioFeatures.Result(bpmX10: bpmX10, tempoConf: tempoConf, lufsX10: lufsX10, analysedMs: analysedMs,
                                    onsetX1000: onsetX1000, version: version)
    }
}

/// The pure rules of the store and the measurer, apart for the tests.
public enum AudioMeasurePolicy {
    public static let retryAfterMs: Int64 = 24 * 60 * 60 * 1000
    public static let giveUpFailures = 3
    public static let giveUpMs: Int64 = 30 * 24 * 60 * 60 * 1000

    /// True when a recording should be measured now: never measured, measured by an older estimator, or a failure whose wait is over.
    public static func wants(version: Int, failures: Int, measuredAtMs: Int64, nowMs: Int64) -> Bool {
        if version != AudioFeatures.version { return true }
        if failures <= 0 { return false }
        if failures >= giveUpFailures { return nowMs - measuredAtMs >= giveUpMs }
        return nowMs - measuredAtMs >= retryAfterMs
    }

    /// What flow reads for one recording; nil when nothing is known. A trusted measured tempo wins over the row's (unless the row's
    /// own came from the phone); the row's loudness wins (Deezer's `gain`), the measured one fills the gap.
    public static func facts(dnaTempoX10: Int, dnaTempoSource: Int, dnaGainX10: Int, dnaEnergy: Int,
                             measured: AudioFeatures.Result?) -> Flow.Facts? {
        let deezerTempo = (dnaTempoSource == TrackDna.tempoOnDevice || dnaTempoSource == TrackDna.tempoOnDeviceWeak) ? 0 : dnaTempoX10
        let chosen = AudioFeatures.chooseTempo(deezerTempo, measured)
        let tempo = chosen.bpmX10 > 0 ? chosen.bpmX10 : Swift.max(dnaTempoX10, 0)
        let gain = AudioFeatures.chooseGain(dnaGainX10, measured).gainDbX10
        let energy = (dnaEnergy >= 0 && dnaEnergy <= 255) ? dnaEnergy : -1
        if tempo <= 0 && gain == TrackDna.gainUnknown && energy < 0 { return nil }
        return Flow.Facts(tempoBpmX10: tempo, gainDbX10: gain, energy: energy)
    }
}

/// What the DNA assembly reads of the measurements: a protocol so the enricher's tests need no file.
public protocol AudioMeasureLookup: Sendable {
    func measured(_ rid: Int64) async -> AudioFeatures.Result?
}

/// Where the planners get their flow facts (6.5, stage 5). An empty answer means "no flow": the planner then builds exactly the list
/// it built before stage 5.
public protocol FlowFactsSource: Sendable {
    func flowFacts(_ rids: [Int64]) async -> [Int64: Flow.Facts]
}

/// The file behind one actor. Nothing is read until the first call, and nothing here runs at app start.
public actor AudioMeasureRepository: AudioMeasureLookup, FlowFactsSource {
    private let file: KeyedLogStore
    private let dna: DnaRepository?
    private var loaded = false
    private var rows: [Int64: AudioMeasureRow] = [:]

    public init(directory: URL, dna: DnaRepository?, compactionFloorBytes: Int = 32 * 1024) {
        file = KeyedLogStore(url: directory.appendingPathComponent("audio_measure.pbl", isDirectory: false),
                             compactionFloorBytes: compactionFloorBytes)
        self.dna = dna
    }

    private func load() {
        if loaded { return }
        loaded = true
        let decoder = JSONDecoder()
        file.open { _, payload in
            guard let row = try? decoder.decode(AudioMeasureRow.self, from: Data(payload)),
                  row.v >= 1, row.v <= AudioMeasureRow.formatVersion else { return }
            self.rows[row.rid] = row
        }
    }

    public func row(_ rid: Int64) -> AudioMeasureRow? {
        load()
        return rows[rid]
    }

    /// The measurement of `rid` by the current estimator, or nil.
    public func measured(_ rid: Int64) -> AudioFeatures.Result? {
        load()
        guard let r = rows[rid], r.version == AudioFeatures.version else { return nil }
        return r.result
    }

    /// True when `rid` should be measured now.
    public func wants(_ rid: Int64, nowMs: Int64) -> Bool {
        load()
        guard let r = rows[rid] else { return true }
        return AudioMeasurePolicy.wants(version: r.version, failures: r.failures, measuredAtMs: r.measuredAtMs, nowMs: nowMs)
    }

    @discardableResult
    public func save(_ row: AudioMeasureRow) -> Bool {
        load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(row), file.put(String(row.rid), [UInt8](payload)) else { return false }
        rows[row.rid] = row
        return true
    }

    /// One more failed attempt for `rid`.
    public func failed(_ rid: Int64, durationMs: Int64, nowMs: Int64) {
        load()
        let old = rows[rid]
        let before = (old?.version == AudioFeatures.version) ? (old?.failures ?? 0) : 0
        save(AudioMeasureRow(rid: rid, version: AudioFeatures.version, bpmX10: 0, tempoConf: 0, lufsX10: AudioFeatures.loudnessUnknown,
                             onsetX1000: 0, analysedMs: 0, windowStartMs: 0, durationMs: durationMs, measuredAtMs: nowMs,
                             failures: before + 1))
    }

    /// How many recordings have a measurement (the diagnostics).
    public func countMeasured() -> Int {
        load()
        return rows.values.filter { $0.failures == 0 }.count
    }

    /// Flow facts for `rids` (6.5): only the recordings something is known about.
    public func flowFacts(_ rids: [Int64]) async -> [Int64: Flow.Facts] {
        load()
        var seen = Set<Int64>()
        var list: [Int64] = []
        list.reserveCapacity(rids.count)
        for r in rids where r != 0 && seen.insert(r).inserted { list.append(r) }
        var measured: [Int64: AudioFeatures.Result] = [:]
        for rid in list {
            if let m = rows[rid], m.version == AudioFeatures.version, let res = m.result { measured[rid] = res }
        }
        var out: [Int64: Flow.Facts] = [:]
        if let dna {
            for row in await dna.tracks(list) {
                let m = measured.removeValue(forKey: row.rid)
                if let f = AudioMeasurePolicy.facts(dnaTempoX10: row.tempoBpmX10, dnaTempoSource: row.tempoSource,
                                                    dnaGainX10: row.gainDbX10, dnaEnergy: row.energy, measured: m) {
                    out[row.rid] = f
                }
            }
        }
        // A measured track that has no DNA row yet still steps by tempo and loudness.
        for (rid, m) in measured {
            if let f = AudioMeasurePolicy.facts(dnaTempoX10: 0, dnaTempoSource: TrackDna.tempoUnknown, dnaGainX10: TrackDna.gainUnknown,
                                                dnaEnergy: -1, measured: m) {
                out[rid] = f
            }
        }
        return out
    }
}
