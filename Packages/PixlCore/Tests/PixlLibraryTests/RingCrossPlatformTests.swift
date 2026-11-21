import Foundation
import Testing
@testable import PixlLibrary

/// The shared scenes of the ring code (`Fixtures/songtap-ring`): `scenes.jsonl` says what to draw (a code and integer
/// parameters) and `kotlin/*.pgm` are those scenes as the Android renderer and its committed code drew them. Swift reads what
/// Kotlin renders, and the Swift renderer draws the same picture (on Windows byte for byte; on other platforms the maths
/// library's last bit may move a pixel on an edge by a level, which the tolerance allows). Because the pictures are the same,
/// the Kotlin scanner reads what Swift renders too: checked when the files were made (README.md there).
@Suite("Pixl ring code across platforms")
struct RingCrossPlatformTests {
    typealias Value = BrainJson.Value

    struct Scene {
        let name: String
        let payload: RingCodePayload
        let bits: [UInt8]
        let params: RenderParams
    }

    static func data(_ subfolder: String, _ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/songtap-ring\(subfolder)"))
        return try Data(contentsOf: url)
    }

    static func scenes() throws -> [Scene] {
        let text = String(decoding: try data("", "scenes", "jsonl"), as: UTF8.self)
        var out: [Scene] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let v = try BrainJson.parse(String(line))
            func num(_ key: String, _ def: Int64) -> Int64 { v[key]?.bareLong ?? def }
            func deg(_ key: String) -> Double { Double(num(key, 0)) * (Double.pi / 180.0) }
            let id = v["id"]?.stringValue ?? ""
            let payload = RingCodePayload(videoId: id, minuteBucket: Int(num("bucket", 0)), random: Int(num("random", 0)))
            let bits = try #require(RingCodePayloads.encodeSlots(videoId: id, minuteBucket: payload.minuteBucket, random: payload.random))
            let width = Int(num("width", 360))
            let height = Int(num("height", 360))
            let cx = v["cx"] != nil ? Double(num("cx", 0)) : Double(width) / 2.0
            let cy = v["cy"] != nil ? Double(num("cy", 0)) : Double(height) / 2.0
            let half = Double(num("half", 130))
            let art = ArtMode.allCases[Int(num("art", 0))]
            let base = RenderParams(width: width, height: height, centerX: cx, centerY: cy, plateHalfPx: half,
                                    rotationRad: deg("rotDeg"), tiltRad: deg("tiltDeg"), tiltAxisRad: deg("axisDeg"),
                                    blurSigmaPx: Double(num("blurMilli", 0)) / 1000.0, noiseSigma: Double(num("noiseMilli", 0)) / 1000.0,
                                    noiseSeed: num("noiseSeed", 1),
                                    dotLuma: Int(num("dotLuma", 58)), plateLuma: Int(num("plateLuma", 238)), markerLuma: Int(num("markerLuma", 105)),
                                    clutter: num("clutter", 0) != 0, artMode: art, artSeed: Int(num("artSeed", 7)),
                                    supersample: Int(num("supersample", 2)), contrast: Double(num("contrastMilli", 1000)) / 1000.0,
                                    marker: num("marker", 1) != 0)
            var smudges: [Smudge] = []
            if v["smudgeSlot"] != nil {
                smudges.append(RingCodeRenderer.smudgeCovering(bits, base, centerSlot: Int(num("smudgeSlot", 0)), fraction: Double(num("smudgePercent", 10)) / 100.0,
                                                               luma: Int(num("smudgeLuma", 200))))
            }
            var glares: [Glare] = []
            if let g = v["glare"]?.arrayValue, g.count == 6 {
                let n = g.map { Double($0.bareLong ?? 0) }
                glares.append(Glare(cx: n[0], cy: n[1], rx: n[2], ry: n[3], angle: n[4] * (Double.pi / 180.0), gain: n[5]))
            }
            let params = RenderParams(width: width, height: height, centerX: cx, centerY: cy, plateHalfPx: half,
                                      rotationRad: base.rotationRad, tiltRad: base.tiltRad, tiltAxisRad: base.tiltAxisRad,
                                      blurSigmaPx: base.blurSigmaPx, noiseSigma: base.noiseSigma, noiseSeed: base.noiseSeed,
                                      glares: glares, smudges: smudges,
                                      dotLuma: base.dotLuma, plateLuma: base.plateLuma, markerLuma: base.markerLuma,
                                      clutter: base.clutter, artMode: base.artMode, artSeed: base.artSeed,
                                      supersample: base.supersample, contrast: base.contrast, marker: base.marker)
            out.append(Scene(name: v["name"]?.stringValue ?? "", payload: payload, bits: bits, params: params))
        }
        return out
    }

    /// A binary PGM (P5, 8 bits) as a scanner frame.
    static func readPgm(_ bytes: [UInt8]) -> RingFrame? {
        var pos = 0
        func token() -> String? {
            while pos < bytes.count && (bytes[pos] == 0x20 || bytes[pos] == 0x0A || bytes[pos] == 0x0D || bytes[pos] == 0x09) { pos += 1 }
            let start = pos
            while pos < bytes.count && !(bytes[pos] == 0x20 || bytes[pos] == 0x0A || bytes[pos] == 0x0D || bytes[pos] == 0x09) { pos += 1 }
            return start == pos ? nil : String(decoding: bytes[start..<pos], as: UTF8.self)
        }
        guard token() == "P5", let w = token().flatMap({ Int($0) }), let h = token().flatMap({ Int($0) }), token() == "255" else { return nil }
        pos += 1
        guard bytes.count - pos >= w * h else { return nil }
        return RingFrame(width: w, height: h, luma: Array(bytes[pos..<(pos + w * h)]))
    }

    @Test func theScenesFileHasTheTwelveScenes() throws {
        let all = try Self.scenes()
        #expect(all.count == 12)
        #expect(Set(all.map(\.name)).count == 12)
    }

    @Test func swiftReadsWhatKotlinRendered() throws {
        let scanner = RingScanner()
        var good = 0
        var failures: [String] = []
        let all = try Self.scenes()
        for s in all {
            let frame = try #require(Self.readPgm(Array(try Self.data("/kotlin", s.name, "pgm"))), "\(s.name).pgm")
            let result = scanner.scan(frame)
            if result.payload == s.payload { good += 1 } else { failures.append("\(s.name): \(RingScanHarness.describe(result, scanner))") }
        }
        print("Swift scanner on the Kotlin renders: \(good) / \(all.count) read")
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func swiftReadsWhatSwiftRendersNow() throws {
        let scanner = RingScanner()
        for s in try Self.scenes() {
            let r = RingCodeRenderer.render(s.bits, s.params)
            let result = scanner.scan(RingScanHarness.frameOf(r))
            #expect(result.payload == s.payload, "\(s.name): \(RingScanHarness.describe(result, scanner))")
        }
    }

    /// The two renderers draw the same picture: the same geometry, the same seeds, the same noise; only the maths library's last
    /// bit may differ, which moves a few pixels on an edge by a level or two.
    @Test func theSwiftRendererDrawsTheSamePictureAsTheKotlinOne() throws {
        for s in try Self.scenes() {
            let kotlin = try #require(Self.readPgm(Array(try Self.data("/kotlin", s.name, "pgm"))))
            let swift = RingCodeRenderer.render(s.bits, s.params).image
            #expect(kotlin.width == swift.width && kotlin.height == swift.height, "\(s.name) size")
            var sum = 0
            var far = 0
            var worst = 0
            for i in 0..<min(kotlin.luma.count, swift.luma.count) {
                let d = abs(Int(kotlin.luma[i]) - Int(swift.luma[i]))
                sum += d
                if d > 8 { far += 1 }
                worst = max(worst, d)
            }
            let n = max(1, swift.luma.count)
            let mean = Double(sum) / Double(n)
            print("render parity \(s.name): mean abs diff \(mean), \(far) of \(n) pixels more than 8 levels apart, worst \(worst)")
            #expect(mean < 0.5, "\(s.name): mean difference \(mean)")
            #expect(far * 500 < n, "\(s.name): \(far) pixels far apart")
        }
    }
}
