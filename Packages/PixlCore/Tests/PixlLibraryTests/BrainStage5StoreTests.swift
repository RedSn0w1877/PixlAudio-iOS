import Foundation
import Testing
@testable import PixlLibrary

/// Stage 5: when a track is measured again, what flow reads from the DNA row and the measurement together (Android's
/// `AudioMeasurePolicyTest`), and the `audio_measure.pbl` file.
@Suite("Brain stage 5 store")
struct BrainStage5StoreTests {
    private let day = AudioMeasurePolicy.retryAfterMs

    @Test func aTrackIsMeasuredOncePerEstimatorVersionAndAFailureWaits() {
        let v = AudioFeatures.version
        #expect(!AudioMeasurePolicy.wants(version: v, failures: 0, measuredAtMs: 0, nowMs: 10 * day))
        #expect(AudioMeasurePolicy.wants(version: v - 1, failures: 0, measuredAtMs: 0, nowMs: 1))
        #expect(!AudioMeasurePolicy.wants(version: v, failures: 1, measuredAtMs: 0, nowMs: day - 1))
        #expect(AudioMeasurePolicy.wants(version: v, failures: 1, measuredAtMs: 0, nowMs: day))
        #expect(!AudioMeasurePolicy.wants(version: v, failures: 3, measuredAtMs: 0, nowMs: 29 * day))
        #expect(AudioMeasurePolicy.wants(version: v, failures: 3, measuredAtMs: 0, nowMs: 30 * day))
    }

    @Test func aTrustedMeasurementReplacesDeezersTempoAndDeezersGainStays() throws {
        let strong = AudioFeatures.Result(bpmX10: 1280, tempoConf: 900, lufsX10: -75, analysedMs: 40_000)
        let f = try #require(AudioMeasurePolicy.facts(dnaTempoX10: 1200, dnaTempoSource: TrackDna.tempoDeezer, dnaGainX10: -90,
                                                      dnaEnergy: 140, measured: strong))
        #expect(f.tempoBpmX10 == 1280)
        #expect(f.gainDbX10 == -90)
        #expect(f.energy == 140)
        let weak = AudioFeatures.Result(bpmX10: 1280, tempoConf: 300, lufsX10: -75, analysedMs: 40_000)
        #expect(AudioMeasurePolicy.facts(dnaTempoX10: 1200, dnaTempoSource: TrackDna.tempoDeezer, dnaGainX10: -90, dnaEnergy: 140,
                                         measured: weak)?.tempoBpmX10 == 1200)
        let noDna = try #require(AudioMeasurePolicy.facts(dnaTempoX10: 0, dnaTempoSource: TrackDna.tempoUnknown,
                                                          dnaGainX10: TrackDna.gainUnknown, dnaEnergy: -1, measured: strong))
        #expect(noDna.gainDbX10 == -75)
        #expect(AudioMeasurePolicy.facts(dnaTempoX10: 0, dnaTempoSource: TrackDna.tempoUnknown, dnaGainX10: TrackDna.gainUnknown,
                                         dnaEnergy: -1, measured: nil) == nil)
    }

    @Test func theFileKeepsMeasurementsAndFailures() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("brain5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AudioMeasureRepository(directory: dir, dna: nil)
        #expect(await store.wants(7, nowMs: 0))
        await store.save(AudioMeasureRow(rid: 7, version: AudioFeatures.version, bpmX10: 1280, tempoConf: 900, lufsX10: -84,
                                         onsetX1000: 300, analysedMs: 40_000, windowStartMs: 60_000, durationMs: 300_000,
                                         measuredAtMs: 5, failures: 0))
        await store.failed(8, durationMs: 200_000, nowMs: 5)
        let reopened = AudioMeasureRepository(directory: dir, dna: nil)
        #expect(await reopened.measured(7)?.bpmX10 == 1280)
        #expect(await reopened.measured(8) == nil)
        #expect(await reopened.row(8)?.failures == 1)
        #expect(!(await reopened.wants(7, nowMs: 10)))
        #expect(await reopened.countMeasured() == 1)
        let facts = await reopened.flowFacts([7, 8, 0])
        #expect(facts[7] == Flow.Facts(tempoBpmX10: 1280, gainDbX10: -84, energy: -1))
        #expect(facts[8] == nil)
    }
}
