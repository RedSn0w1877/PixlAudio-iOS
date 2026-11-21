import Foundation
import Testing
@testable import PixlLibrary

/// The golden vectors of the Pixl ring code's pure side (`ring-*.jsonl` in `Fixtures/songtap`, written by Android's
/// `:songtap:generateGolden` and copied unchanged): layout, Reed-Solomon, payload and timeline. The Swift core must
/// reproduce every `out` from its `in` byte for byte; each test rebuilds the canonical `"out":{...}` text and compares it
/// with the bytes of the line (the same rule as `SongTapGoldenTests`). The image side has no goldens: see RingScannerTests.
@Suite("Pixl ring code golden vectors (ringCodeMatchesAndroid)")
struct RingGoldenTests {
    typealias G = SongTapGoldenTests

    static func bitString(_ bits: [UInt8]) -> String { String(decoding: bits.map { $0 != 0 ? UInt8(ascii: "1") : UInt8(ascii: "0") }, as: UTF8.self) }
    static func fromBits(_ s: String) -> [UInt8] { s.utf8.map { $0 == UInt8(ascii: "1") ? 1 : 0 } }
    static func ints(_ v: BrainJson.Value, _ k: String) -> [Int] { (v[k]?.arrayValue ?? []).map { Int($0.bareLong ?? 0) } }

    // MARK: ring-layout.jsonl

    @Test func layoutConstantsSlotsAndTheByteMap() throws {
        var report = G.Report(file: "ring-layout.jsonl")
        for c in try G.cases("ring-layout.jsonl") {
            switch c.fn {
            case "constants":
                report.record(c, c.matches { w in
                    w.beginArray("ringSlots"); for n in RingCodeLayout.ringSlots { w.intItem(n) }; w.endArray()
                    w.beginArray("ringFirstSlot"); for n in RingCodeLayout.ringFirstSlot { w.intItem(n) }; w.endArray()
                    w.beginArray("ringRadius"); for n in RingCodeLayout.ringRadius { w.intItem(n) }; w.endArray()
                    w.int("slots", RingCodeLayout.slots); w.int("bytes", RingCodeLayout.bytes)
                    w.int("artRadius", RingCodeLayout.artRadius); w.int("bezelInner", RingCodeLayout.bezelInner)
                    w.int("bezelOuter", RingCodeLayout.bezelOuter)
                    w.int("bigRadius", RingCodeLayout.bigRadius); w.int("smallRadius", RingCodeLayout.smallRadius)
                    w.int("markerAt", RingCodeLayout.markerRadiusAt); w.int("markerRadius", RingCodeLayout.markerRadius)
                    w.int("plateCorner", RingCodeLayout.plateCorner); w.int("markerArgb", Int(RingCodeLayout.markerArgb))
                })
            case "slot":
                let slot = G.int(c.input, "slot")
                report.record(c, c.matches { w in
                    let ring = RingCodeLayout.ringOf(slot)
                    w.int("ring", ring); w.int("index", RingCodeLayout.indexInRing(slot)); w.int("count", RingCodeLayout.ringSlots[ring])
                    w.int("microTurns", RingCodeLayout.angleMicroTurns(slot))
                    w.int("byte", RingCodeLayout.byteOfSlot(slot)); w.int("bit", RingCodeLayout.bitOfSlot(slot))
                })
            case "codewordToSlots":
                let word = G.bytes(G.string(c.input, "hex"))
                report.record(c, c.matches { $0.string("bits", Self.bitString(RingCodeLayout.codewordToSlots(word))) })
            case "slotsToCodeword":
                let bits = Self.fromBits(G.string(c.input, "bits"))
                report.record(c, c.matches { $0.string("hex", G.hex(RingCodeLayout.slotsToCodeword(bits))) })
            default:
                report.record(c, false)
            }
        }
        #expect(report.counts["constants"] == 1)
        #expect(report.counts["slot"] == 200)
        report.verify(atLeast: 225)
    }

    // MARK: ring-rs.jsonl

    @Test func fieldEncodeAndDecodeMatchAndroid() throws {
        var report = G.Report(file: "ring-rs.jsonl")
        for c in try G.cases("ring-rs.jsonl") {
            switch c.fn {
            case "gfMul":
                report.record(c, c.matches { $0.int("p", Gf256.mul(G.int(c.input, "a"), G.int(c.input, "b"))) })
            case "gfInv":
                report.record(c, c.matches { $0.int("inv", Gf256.inv(G.int(c.input, "a"))) })
            case "rsEncode":
                let word = ReedSolomon.encode(G.bytes(G.string(c.input, "data")))
                report.record(c, c.matches { $0.string("codeword", G.hex(word)) })
            case "rsDecode":
                let received = G.bytes(G.string(c.input, "received"))
                let result = ReedSolomon.decode(received, erasures: Self.ints(c.input, "erasures"))
                report.record(c, c.matches { w in
                    w.bool("ok", result.ok)
                    if result.ok { w.string("codeword", G.hex(result.codeword ?? [])); w.int("corrected", result.corrected) }
                })
            default:
                report.record(c, false)
            }
        }
        #expect((report.counts["rsEncode"] ?? 0) >= 40)
        #expect((report.counts["rsDecode"] ?? 0) >= 90)
        report.verify(atLeast: 140)
    }

    // MARK: ring-payload.jsonl

    @Test func packUnpackSlotsBucketsAndFreshnessMatchAndroid() throws {
        var report = G.Report(file: "ring-payload.jsonl")
        for c in try G.cases("ring-payload.jsonl") {
            switch c.fn {
            case "pack":
                let out = RingCodePayloads.pack(videoId: G.string(c.input, "id"), minuteBucket: G.int(c.input, "bucket"), random: G.int(c.input, "random"))
                report.record(c, c.matches { G.writeHex(&$0, "hex", out) })
            case "encodeSlots":
                let out = RingCodePayloads.encodeSlots(videoId: G.string(c.input, "id"), minuteBucket: G.int(c.input, "bucket"), random: G.int(c.input, "random"))
                report.record(c, c.matches { w in
                    if let out { w.string("bits", Self.bitString(out)) } else { w.raw("bits", "null") }
                })
            case "unpack":
                let result = RingCodePayloads.unpack(G.bytes(G.string(c.input, "hex")))
                report.record(c, c.matches { w in
                    switch result {
                    case .ok(let p):
                        w.bool("ok", true); w.string("id", p.videoId); w.int("bucket", p.minuteBucket); w.int("random", p.random)
                    case .rejected(let reason):
                        w.bool("ok", false); w.string("reason", reason.code)
                    }
                })
            case "bucketOf":
                report.record(c, c.matches { $0.int("bucket", RingCodePayloads.bucketOf(nowMs: G.long(c.input, "now"))) })
            case "freshness":
                let verdict = RingCodePayloads.freshness(bucket: G.int(c.input, "bucket"), nowMs: G.long(c.input, "now"))
                report.record(c, c.matches { $0.string("verdict", verdict.code) })
            default:
                report.record(c, false)
            }
        }
        #expect((report.counts["pack"] ?? 0) >= 50)
        #expect((report.counts["unpack"] ?? 0) >= 100)
        #expect((report.counts["freshness"] ?? 0) >= 20)
        report.verify(atLeast: 235)
    }

    // MARK: ring-timeline.jsonl

    @Test func framesSlotsSwayAndEasingMatchAndroid() throws {
        var report = G.Report(file: "ring-timeline.jsonl")
        let sampleSlots = [(0, 0), (0, 12), (1, 5), (2, 20), (3, 47), (4, 0), (4, 1), (4, 28), (4, 55)]
        var buffer = RingFrameBuffer()
        for c in try G.cases("ring-timeline.jsonl") {
            switch c.fn {
            case "easeNoop":
                report.record(c, c.matches { $0.int("smooth", SongTapTimeline.smooth(G.int(c.input, "x"))) })
            case "frame":
                RingCodeTimeline.frameInto(tMs: G.long(c.input, "t"), approachStartMs: G.long(c.input, "approachStart"),
                                           approachEndMs: G.long(c.input, "approachEnd"), beamStartMs: G.long(c.input, "beamStart"),
                                           reducedMotion: G.bool(c.input, "reduced"), out: &buffer)
                let beamMs = buffer.beamMs
                var checksum: Int64 = 0
                for ring in 0..<RingCodeLayout.rings {
                    for i in 0..<RingCodeLayout.ringSlots[ring] {
                        checksum += Int64(RingCodeTimeline.slotProgress(ring: ring, index: i, beamMs: beamMs)) * Int64(RingCodeLayout.slotOf(ring: ring, index: i) + 1)
                    }
                }
                let described = buffer.describe()
                report.record(c, c.matches { w in
                    w.string("frame", described)
                    w.long("progressChecksum", checksum)
                    w.beginArray("samples")
                    for (r, i) in sampleSlots { w.intItem(RingCodeTimeline.slotProgress(ring: r, index: i, beamMs: beamMs)) }
                    w.endArray()
                    w.int("marker", RingCodeTimeline.markerProgress(beamMs: beamMs))
                })
            case "slotStart":
                report.record(c, c.matches { $0.int("ms", RingCodeTimeline.slotStartMs(ring: G.int(c.input, "ring"), index: G.int(c.input, "index"))) })
            case "beamTotal":
                report.record(c, c.matches { $0.long("ms", RingCodeTimeline.beamTotal(reducedMotion: G.bool(c.input, "reduced"))) })
            case "sway":
                let t = G.long(c.input, "t")
                report.record(c, c.matches { $0.int("angle", RingCodeTimeline.swayAngle(t)); $0.int("breath", RingCodeTimeline.breathScale(t)) })
            default:
                report.record(c, false)
            }
        }
        #expect((report.counts["frame"] ?? 0) >= 240)
        report.verify(atLeast: 270)
    }
}
