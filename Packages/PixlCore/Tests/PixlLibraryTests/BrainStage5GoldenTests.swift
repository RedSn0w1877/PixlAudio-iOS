import Foundation
import Testing
@testable import PixlLibrary

/// Music brain stage 5: the on-device estimator (`audiofeatures.jsonl`) and flow ordering (`flow.jsonl`) against Android's golden files,
/// bit for bit, and the same unit cases as Android's `AudioFeaturesTest` and `FlowTest`.
@Suite("Brain stage 5 golden vectors (brainMatchesAndroid)")
struct BrainStage5GoldenTests {
    typealias G = BrainGoldenTests
    typealias Value = BrainJson.Value

    // MARK: audiofeatures.jsonl

    @Test func audioFeaturesMatchAndroid() throws {
        var report = G.Report(file: "audiofeatures.jsonl")
        var counts: [String: Int] = [:]
        var fixture = 0
        let rendered = AudioFixtures.rendered
        for c in try G.cases("audiofeatures.jsonl") {
            counts[c.fn, default: 0] += 1
            let i = c.input
            switch c.fn {
            case "estimate":
                // The fixtures are listed in the order of `AudioFixtures.specs()`; the line's own parameters must be that spec.
                guard fixture < rendered.count else { report.record(c, false); continue }
                let r = rendered[fixture]
                fixture += 1
                let s = r.spec
                let same = G.string(i, "kind") == s.kind && Int(G.int(i, "sampleRate")) == s.sampleRate
                    && Int(G.int(i, "channels")) == s.channels && Int(G.int(i, "seconds")) == s.seconds
                    && Int(G.int(i, "param")) == s.param && Int(G.int(i, "levelDbX10")) == s.levelDbX10
                    && G.long(i, "seed") == s.seed && G.int(i, "block") == 4096
                let m = r.result
                report.record(c, same && c.matches {
                    $0.long("pcmHash", r.pcmHash); $0.int("samples", r.samples)
                    $0.int("bpmX10", m.bpmX10); $0.int("tempoConf", m.tempoConf); $0.int("lufsX10", m.lufsX10)
                    $0.int("analysedMs", m.analysedMs); $0.int("onsetX1000", m.onsetX1000); $0.int("version", m.version)
                })
            case "tanSmall":
                let y = AudioFeatures.tanSmall(G.double(i, "x"))
                report.record(c, c.matches { $0.double("y", y) })
            case "windowStartMs":
                let s = AudioFeatures.windowStartMs(G.long(i, "durationMs"))
                report.record(c, c.matches { $0.long("startMs", s) })
            case "choose":
                var measured: AudioFeatures.Result?
                if let m = i["measured"], !m.isNull {
                    measured = AudioFeatures.Result(bpmX10: Int(G.int(m, "bpmX10")), tempoConf: Int(G.int(m, "tempoConf")),
                                                    lufsX10: Int(G.int(m, "lufsX10")), analysedMs: 40_000)
                }
                let t = AudioFeatures.chooseTempo(Int(G.int(i, "deezerBpmX10")), measured)
                let g = AudioFeatures.chooseGain(Int(G.int(i, "deezerGainX10")), measured)
                report.record(c, c.matches {
                    $0.int("bpmX10", t.bpmX10); $0.int("tempoSource", t.source); $0.int("gainDbX10", g.gainDbX10)
                    $0.int("gainMeasured", g.measured)
                })
            default: report.record(c, false)
            }
        }
        report.verify(atLeast: 80)
        #expect(counts["estimate"] == AudioFixtures.specs().count)
        #expect(counts["tanSmall"] == 8)
        #expect(counts["windowStartMs"] == 8)
        #expect(counts["choose"] == 40)
    }

    // MARK: flow.jsonl

    static func facts(_ v: Value?) -> Flow.Facts {
        let a = v?.arrayValue ?? []
        func at(_ k: Int) -> Int { k < a.count ? Int(a[k].bareLong ?? 0) : 0 }
        return Flow.Facts(tempoBpmX10: at(0), gainDbX10: at(1), energy: at(2))
    }

    @Test func flowMatchesAndroid() throws {
        let atlas = try BrainStage2bGoldenTests.atlas()
        var report = G.Report(file: "flow.jsonl")
        var counts: [String: Int] = [:]
        for c in try G.cases("flow.jsonl") {
            counts[c.fn, default: 0] += 1
            let i = c.input
            switch c.fn {
            case "tempoDist":
                let d = Flow.tempoDist(Int(G.int(i, "a")), Int(G.int(i, "b")))
                report.record(c, c.matches { $0.double("d", d) })
            case "step":
                let cost = Flow.step(Self.facts(i["prev"]), Self.facts(i["next"]))
                report.record(c, c.matches { $0.double("cost", cost) })
            case "arc":
                let mid = Int(G.int(i, "mid")), slot = Int(G.int(i, "slot")), count = Int(G.int(i, "count"))
                let e = Int(G.int(i, "energy"))
                let target = Flow.target(mid, slot, count)
                let cost = Flow.arc(mid, slot, count, e)
                report.record(c, c.matches { $0.int("target", target); $0.double("cost", cost) })
            case "feelTempo":
                let f = TrackDna.feel(atlas, BrainStage2bGoldenTests.vector(i["tags"]), gainDbX10: Int(G.int(i, "gainDbX10")),
                                      tempoBpmX10: Int(G.int(i, "tempoBpmX10")))
                report.record(c, c.matches { $0.int("energy", f.energy); $0.int("valence", f.valence) })
            case "build":
                report.record(c, Self.replayBuild(c))
            default: report.record(c, false)
            }
        }
        report.verify(atLeast: 628)
        #expect(counts["tempoDist"] == 200)
        #expect(counts["step"] == 200)
        #expect(counts["feelTempo"] == 80)
        #expect(counts["build"] == 48)
    }

    static func replayBuild(_ c: G.Case) -> Bool {
        let i = c.input
        var scored: [ListBuilder.Scored] = []
        var factMap: [Int64: Flow.Facts] = [:]
        for p in G.array(i, "pool") {
            let rid = G.long(p, "rid")
            let novel = G.bool(p, "novel")
            scored.append(ListBuilder.Scored(c: Candidate(rid: rid, aid: G.long(p, "aid"), albumKey: 0, inLibrary: !novel),
                                             arm: Arm.radio, z: G.double(p, "z"), p: G.double(p, "p"), novel: novel, bestRank: 0,
                                             bestSeed: -1, newestSeedRank: 0, lastMs: 0, retrQ: 500))
            factMap[rid] = Flow.Facts(tempoBpmX10: Int(G.int(p, "tempo")), gainDbX10: Int(G.int(p, "gain")), energy: Int(G.int(p, "energy")))
        }
        let withFlow = G.bool(i, "flow")
        let finite = G.bool(i, "finite")
        let ctx: Flow.Context? = withFlow ? Flow.Context(facts: factMap, lead: facts(i["lead"]), arc: finite) : nil
        if let ctx, ctx.mid != Int(G.int(i, "mid")) { return false }
        let request = ListBuilder.Request(count: Int(G.int(i, "count")), prior: [], nu: G.double(i, "nu"), tieSeed: G.long(i, "tieSeed"),
                                          nowMs: G.long(i, "nowMs"), tzOffsetMin: G.int(i, "tzOffsetMin"), finite: finite, flow: ctx)
        let picks = ListBuilder.build(request, scored: scored, graph: Graph.Builder().build())
        let order = picks.map { factMap[$0.scored.c.rid] ?? .unknown }
        let roughness = Flow.roughness(order)
        return c.matches {
            $0.beginArray("picks")
            for pk in picks {
                var w = BrainJson.Writer()
                w.beginObject(); w.long("rid", pk.scored.c.rid); w.int("kind", pk.kind); w.long("key", pk.key); w.endObject()
                $0.rawItem(w.text)
            }
            $0.endArray()
            $0.double("roughness", roughness)
        }
    }

    @Test func theStage5FilesAreInTheManifest() throws {
        let manifest = String(decoding: try G.fixtureData("MANIFEST.sha256"), as: UTF8.self)
        for name in ["audiofeatures.jsonl", "flow.jsonl"] {
            let data = [UInt8](try G.fixtureData(name))
            let line = manifest.split(separator: "\n").first { $0.hasSuffix("  \(name)") }
            let hash = try #require(line.map { String($0.prefix(64)) }, "\(name) is not in MANIFEST.sha256")
            #expect(TestSHA256.hex(data) == hash, "\(name) is not the file Android generated")
        }
    }

    // MARK: AudioFeaturesTest

    private static func expectedLufs(_ spec: AudioFixtures.Spec) -> Double {
        Double(spec.levelDbX10) / 10.0 - 3.0103 + 10.0 * log10(Double(spec.channels))
    }

    @Test func accuracyOnTheFixtures() {
        var tempoN = 0
        var tempoOk = 0
        var octave = 0
        var failures: [String] = []
        for r in AudioFixtures.rendered {
            let spec = r.spec
            let m = r.result
            switch spec.kind {
            case AudioFixtures.kindClicks, AudioFixtures.kindGroove:
                tempoN += 1
                let truth = Double(spec.param) / 10.0
                let got = Double(m.bpmX10) / 10.0
                if abs(got - truth) <= truth * 0.01 {
                    tempoOk += 1
                } else if abs(got - truth * 2) <= truth * 0.02 || abs(got - truth / 2) <= truth * 0.005 {
                    octave += 1
                }
                if m.tempoConf < AudioFeatures.trustConf { failures.append("\(spec.name): confidence \(m.tempoConf)") }
            case AudioFixtures.kindTone:
                if spec.param == 1000 {
                    let want = Self.expectedLufs(spec)
                    if abs(Double(m.lufsX10) / 10.0 - want) > 0.5 { failures.append("\(spec.name): \(m.lufsX10) LUFS x 10, want \(want)") }
                }
                if m.tempoTrusted { failures.append("\(spec.name): a steady tone has no tempo to trust (\(m.tempoConf))") }
            case AudioFixtures.kindNoise:
                if spec.seconds < 3 {
                    #expect(m.bpmX10 == 0)
                    #expect(m.lufsX10 == AudioFeatures.loudnessUnknown)
                } else if m.tempoTrusted {
                    failures.append("\(spec.name): noise has no tempo to trust (\(m.tempoConf))")
                }
            default: break
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(tempoN == tempoOk + octave, "every rhythm fixture is within 1% or an octave off")
        #expect(tempoOk >= tempoN - 2, "at most two octave errors")
    }

    @Test func theResultDoesNotDependOnHowTheSamplesAreSplitIntoBlocks() {
        let spec = AudioFixtures.specs()[4]
        let pcm = AudioFixtures.render(spec)
        let whole = AudioFixtures.estimate(spec, pcm, block: pcm.count / spec.channels)
        let split = AudioFixtures.estimate(spec, pcm)
        let odd = AudioFixtures.estimate(spec, pcm, block: 777)
        #expect(whole == split)
        #expect(odd == split)
    }

    @Test func tanSmallMatchesTanOnTheKFiltersRange() {
        var x = 0.0
        while x < 0.15 {
            #expect(abs(AudioFeatures.tanSmall(x) - tan(x)) < 1e-12, "x = \(x)")
            x += 0.01
        }
    }

    @Test func aTrustedMeasurementBeatsDeezerAndDeezerBeatsAnUntrustedOne() {
        let strong = AudioFeatures.Result(bpmX10: 1280, tempoConf: 800, lufsX10: -90, analysedMs: 40_000)
        let weak = AudioFeatures.Result(bpmX10: 1280, tempoConf: 300, lufsX10: -90, analysedMs: 40_000)
        #expect(Self.pair(AudioFeatures.chooseTempo(1200, strong)) == [1280, TrackDna.tempoOnDevice])
        #expect(Self.pair(AudioFeatures.chooseTempo(1200, weak)) == [1200, TrackDna.tempoDeezer])
        #expect(Self.pair(AudioFeatures.chooseTempo(0, weak)) == [1280, TrackDna.tempoOnDeviceWeak])
        #expect(Self.pair(AudioFeatures.chooseTempo(0, nil)) == [0, TrackDna.tempoUnknown])
        #expect(Self.pair(AudioFeatures.chooseGain(-75, strong)) == [-75, 0])
        #expect(Self.pair(AudioFeatures.chooseGain(TrackDna.gainUnknown, strong)) == [-90, 1])
    }

    private static func pair(_ t: (Int, Int)) -> [Int] { [t.0, t.1] }

    @Test func theWindowStarts20PercentInAndNeverRunsOffTheEnd() {
        #expect(AudioFeatures.windowStartMs(300_000) == 60_000)
        #expect(AudioFeatures.windowStartMs(50_000) == 10_000)
        #expect(AudioFeatures.windowStartMs(30_000) == 0)
        #expect(AudioFeatures.windowStartMs(0) == 0)
    }

    // MARK: FlowTest

    @Test func tempoDistanceFoldsOctavesAndUnknownCostsNothing() {
        #expect(Flow.tempoDist(1200, 1200) == 0.0)
        #expect(Flow.tempoDist(1200, 600) == 0.0)
        #expect(Flow.tempoDist(1200, 2400) == 0.0)
        #expect(Flow.tempoDist(0, 1200) == 0.0)
        #expect(Flow.tempoDist(1200, 1800) > 0.4)
        #expect(Flow.step(Flow.Facts(tempoBpmX10: 1200, gainDbX10: -80, energy: 120), Flow.Facts(tempoBpmX10: 1250, gainDbX10: -90, energy: 140)) == 0.0)
        #expect(Flow.step(Flow.Facts(tempoBpmX10: 700, gainDbX10: -60, energy: 220), Flow.Facts(tempoBpmX10: 1700, gainDbX10: -150, energy: 40)) > 0.15)
        #expect(Flow.step(.unknown, Flow.Facts(tempoBpmX10: 1700, gainDbX10: -150, energy: 40)) == 0.0)
    }

    @Test func theArcRisesToAPeakTwoThirdsInAndSettles() {
        let mid = 128
        let t = (0..<21).map { Flow.target(mid, $0, 21) }
        #expect(t[0] == 110)
        let peak = t.indices.max { t[$0] < t[$1] }!
        #expect((12...14).contains(peak), "peak at \(peak)")
        #expect(t[20] < t[peak] && t[20] > t[0])
        #expect(Flow.target(-1, 3, 10) == -1)
        #expect(Flow.arc(mid, 13, 21, t[13]) == 0.0)
    }

    private static func pool(_ seed: UInt64, _ n: Int) -> ([ListBuilder.Scored], [Int64: Flow.Facts]) {
        var rng = BrainHash.Rng(seed: seed)
        var scored: [ListBuilder.Scored] = []
        var facts: [Int64: Flow.Facts] = [:]
        for i in 0..<n {
            let rid = Int64(10 + i)
            scored.append(ListBuilder.Scored(c: Candidate(rid: rid, aid: Int64(100 + i), inLibrary: true), arm: Arm.fav, z: rng.uniform() * 0.4,
                                             p: 0.5, novel: false, bestRank: 0, bestSeed: -1, newestSeedRank: 0, lastMs: 0, retrQ: 500))
            let tempo = 600 + Int(rng.uniform() * 1200.0)
            let gain = -150 + Int(rng.uniform() * 120.0)
            let energy = Int(rng.uniform() * 255.0)
            facts[rid] = Flow.Facts(tempoBpmX10: tempo, gainDbX10: gain, energy: energy)
        }
        return (scored, facts)
    }

    @Test func flowMakesListsSmootherAndAnEmptyContextChangesNothing() {
        var rougher = 0.0
        var smoother = 0.0
        let graph = Graph.Builder().build()
        for s in 0..<40 {
            let (scored, facts) = Self.pool(BrainHash.fnv1a64("flow test \(s)"), 60)
            func build(_ ctx: Flow.Context?) -> [ListBuilder.Pick] {
                ListBuilder.build(ListBuilder.Request(count: 15, prior: [], nu: 0.0, tieSeed: Int64(s), nowMs: 0, tzOffsetMin: 0, flow: ctx),
                                  scored: scored, graph: graph)
            }
            rougher += Flow.roughness(build(nil).map { facts[$0.scored.c.rid]! })
            smoother += Flow.roughness(build(Flow.Context(facts: facts)).map { facts[$0.scored.c.rid]! })
            // A context that knows nothing is the same list as no context.
            #expect(build(nil).map(\.scored.c.rid) == build(Flow.Context(facts: [:])).map(\.scored.c.rid))
        }
        #expect(smoother < rougher * 0.6, "flow should cut the roughness: \(rougher) -> \(smoother)")
    }
}
