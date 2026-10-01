import Foundation
import PixlFoundation
import Testing
@testable import PixlLibrary

/// Golden vectors for the album-art theme port, produced by running the Android code (colour utilities from
/// material 1.14.0 and the app's compiled `ColorRolesKt`) on a desktop JVM — see `tools/android-reference/ThemeGen.java`.
@Suite struct ThemeGoldenTests {
    private static func hex(_ v: JSONValue) -> UInt32 { UInt32(v.str, radix: 16) ?? 0 }
    private static func hexes(_ v: JSONValue) -> [UInt32] { v.arr.map(hex) }
    private static func num(_ v: JSONValue) -> Double { v.doubleValue ?? Double(v.int64Value ?? 0) }

    private static func lines(_ kind: String) throws -> [JSONValue] {
        try goldenLines("theme-golden.jsonl").filter { $0["kind"]?.str == kind }
    }

    @Test func hctMatchesAndroid() throws {
        var failures = [String]()
        for line in try Self.lines("hct") {
            let hct = Hct.fromInt(Self.hex(line["argb"]!))
            let expected = (line["h"]!.bitsDouble, line["c"]!.bitsDouble, line["t"]!.bitsDouble)
            if abs(hct.hue - expected.0) > 1e-9 || abs(hct.chroma - expected.1) > 1e-9 || abs(hct.tone - expected.2) > 1e-9 {
                failures.append("\(line["argb"]!.str): \(hct.hue),\(hct.chroma),\(hct.tone) vs \(expected)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) HCT mismatches, first: \(failures.prefix(3))")
    }

    @Test func solverMatchesAndroid() throws {
        var failures = [String]()
        let all = try Self.lines("solve")
        #expect(all.count > 8000)
        for line in all {
            let argb = HctSolver.solveToInt(Self.num(line["h"]!), Self.num(line["c"]!), Self.num(line["t"]!))
            if argb != Self.hex(line["argb"]!) {
                failures.append("h\(Self.num(line["h"]!)) c\(Self.num(line["c"]!)) t\(Self.num(line["t"]!)): "
                    + "\(String(argb, radix: 16)) vs \(line["argb"]!.str)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) solver mismatches, first: \(failures.prefix(5))")
    }

    @Test func tonalPalettesMatchAndroid() throws {
        let tones = [0, 4, 6, 10, 12, 17, 20, 22, 24, 25, 30, 35, 40, 49, 50, 60, 70, 80, 87, 90, 92, 94, 95, 96, 98, 99, 100]
        for line in try Self.lines("palette") {
            let palette = TonalPalette.fromHueAndChroma(Self.num(line["h"]!), Self.num(line["c"]!))
            #expect(palette.keyColor.toInt() == Self.hex(line["key"]!), "key \(line)")
            #expect(tones.map { palette.tone($0) } == Self.hexes(line["tones"]!), "tones \(line)")
        }
    }

    @Test func schemesMatchAndroid() throws {
        var failures = [String]()
        let all = try Self.lines("scheme")
        #expect(all.count == 320)
        for line in all {
            let seed = Self.hex(line["seed"]!)
            let style = ArtworkPaletteStyle.fromStorageKey(line["style"]!.str)
            let dark = line["dark"]!.bool
            let roles = SchemeBuilder.scheme(Hct.fromInt(seed), style: style, isDark: dark).colorRoles().values
            let expected = Self.hexes(line["roles"]!)
            if roles != expected {
                let diffs = zip(ColorRoles.roleNames, zip(roles, expected)).filter { $0.1.0 != $0.1.1 }
                    .map { "\($0.0) \(String($0.1.0, radix: 16)) vs \(String($0.1.1, radix: 16))" }
                failures.append("\(line["seed"]!.str) \(style) dark=\(dark): \(diffs.prefix(4))")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) scheme mismatches, first: \(failures.prefix(4))")
    }

    @Test func monochromeSchemesMatchAndroid() throws {
        for line in try Self.lines("mono") {
            let seed = Self.hex(line["seed"]!)
            let roles = DynamicScheme.monochrome(Hct.fromInt(seed), isDark: line["dark"]!.bool).colorRoles().values
            #expect(roles == Self.hexes(line["roles"]!), "mono \(line["seed"]!.str)")
        }
    }

    @Test func neutralSchemeDecisionMatchesAndroid() throws {
        for line in try Self.lines("neutral") {
            let seed = Self.hex(line["seed"]!)
            let neutral = Hct.fromInt(seed).chroma <= SeedColorSelector.grayscaleChromaThreshold
                && SeedColorSelector.isArgbNearGrayscale(seed)
            #expect(neutral == line["value"]!.bool, "neutral \(line["seed"]!.str)")
            // The public pair applies it.
            let pair = ArtworkTheme.schemePair(seed: seed)
            if neutral {
                for role in pair.light.values + pair.dark.values {
                    let r = (role >> 16) & 255, g = (role >> 8) & 255, b = role & 255
                    #expect(r == g && g == b, "neutral pair must be grey for \(line["seed"]!.str)")
                }
            }
        }
    }

    @Test func grayscaleMatchesAndroidX() throws {
        for line in try Self.lines("gray") {
            #expect(SchemeBuilder.grayscale(Self.hex(line["argb"]!)) == Self.hex(line["out"]!), "gray \(line)")
        }
    }

    @Test func blendMatchesAndroid() throws {
        for line in try Self.lines("blend") {
            let ratio = Float(bitPattern: UInt32(line["r"]!.str, radix: 16) ?? 0)
            let v = SeedColorSelector.blendArgb(Self.hex(line["a"]!), Self.hex(line["b"]!), ratio)
            #expect(v == Self.hex(line["out"]!), "blend \(line)")
        }
    }

    @Test func quantizersMatchAndroid() throws {
        var failures = [String]()
        for line in try Self.lines("wu") {
            let image = TestImage(line["image"]!)
            let colors = QuantizerWu.quantize(image.pixels, colorCount: 128)
            if colors != Self.hexes(line["colors"]!) { failures.append("wu \(image.spec)") }
        }
        for line in try Self.lines("celebi") {
            let image = TestImage(line["image"]!)
            let result = QuantizerCelebi.quantize(image.pixels, maxColors: 128)
            if result?.colors != Self.hexes(line["colors"]!) || result?.counts != line["counts"]!.arr.map(\.int) {
                failures.append("celebi \(image.spec): \(result?.colors.count ?? -1) vs \(line["colors"]!.arr.count)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) quantizer mismatches: \(failures.prefix(6))")
    }

    @Test func seedColorsMatchAndroid() throws {
        var failures = [String]()
        for line in try Self.lines("seedcolor") {
            let image = TestImage(line["image"]!)
            let seed = ArtworkTheme.seedColor(argbPixels: image.pixels, accuracyLevel: line["accuracy"]!.int)
            if seed != Self.hex(line["seed"]!) {
                failures.append("\(image.spec) acc \(line["accuracy"]!.int): \(String(seed, radix: 16)) vs \(line["seed"]!.str)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) seed mismatches: \(failures.prefix(6))")
    }

    @Test func publicAPIBasics() {
        #expect(ArtworkPaletteStyle.fromStorageKey(nil) == .tonalSpot)
        #expect(ArtworkPaletteStyle.fromStorageKey("fruit_salad") == .fruitSalad)
        #expect(ArtworkColorAccuracy.clamp(42) == 10)
        #expect(ArtworkTheme.paletteCacheKey(style: .vibrant, accuracyLevel: 3) == "vibrant|accuracy_3|algo_v7")
        #expect(ColorRoles.roleNames.count == 48)
        let pair = ArtworkTheme.brandPair
        #expect(ColorRoles(values: pair.light.values) == pair.light)
        // RGBA → ARGB with premultiplied alpha.
        let argb = ArtworkTheme.argbPixels(rgba: [100, 50, 0, 128, 10, 20, 30, 255], width: 2, height: 1)
        #expect(argb == [0x80C7_6400, 0xFF0A_141E])
        #expect(ArtworkTheme.seedColor(argbPixels: []) == SeedColorSelector.fallbackSeed)
    }
}

/// The procedural test images of `ThemeGen.java` (xorshift32, integer maths), rebuilt bit for bit.
struct TestImage {
    let spec: String
    let pixels: [UInt32]

    init(_ v: JSONValue) {
        let kind = v["type"]!.str, w = v["w"]!.int, h = v["h"]!.int
        let seed = Int32(truncatingIfNeeded: v["seed"]!.i64)
        spec = "\(kind) \(w)x\(h) \(seed)"
        pixels = TestImage.make(kind, w, h, seed)
    }

    private static func xorshift(_ x: UInt32) -> UInt32 {
        var x = x
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        return x
    }

    private static func pick(_ x: UInt32, _ n: Int) -> Int { Int(x % UInt32(n)) }
    private static func clamp255(_ v: Int) -> Int { v < 0 ? 0 : (v > 255 ? 255 : v) }

    static func make(_ kind: String, _ w: Int, _ h: Int, _ seed: Int32) -> [UInt32] {
        var px = [UInt32](repeating: 0, count: w * h)
        var x = seed == 0 ? 1 : UInt32(bitPattern: seed)
        var palette = [UInt32](repeating: 0, count: 6)
        for i in 0..<6 {
            x = xorshift(x)
            palette[i] = x & 0xFF_FFFF
        }
        x = xorshift(x)
        let baseGray = 30 + pick(x, 191)
        x = xorshift(x)
        let accentW = 2 + pick(x, max(1, w / 2))
        x = xorshift(x)
        let accentH = 2 + pick(x, max(1, h / 2))
        for yy in 0..<h {
            for xx in 0..<w {
                x = xorshift(x)
                let r = x
                var argb: UInt32
                switch kind {
                case "noise":
                    argb = 0xFF00_0000 | (r & 0xFF_FFFF)
                case "blocks":
                    let block = (Int32(yy / 8) &* 31 &+ Int32(xx / 8) &* 17 &+ seed) & 0x7FFF_FFFF
                    argb = 0xFF00_0000 | palette[Int(block % 4)]
                case "gradient":
                    let t = w > 1 ? xx * 255 / (w - 1) : 0
                    let a = palette[0], b = palette[1]
                    let noise = pick(r, 9) - 4
                    func ch(_ shift: UInt32) -> Int {
                        clamp255((Int((a >> shift) & 255) * (255 - t) + Int((b >> shift) & 255) * t) / 255 + noise)
                    }
                    argb = 0xFF00_0000 | UInt32(ch(16)) << 16 | UInt32(ch(8)) << 8 | UInt32(ch(0))
                case "gray":
                    let v = clamp255(baseGray + pick(r, 11) - 5)
                    let tint = pick(r >> 8, 5)
                    argb = 0xFF00_0000 | UInt32(clamp255(v + tint)) << 16 | UInt32(v) << 8 | UInt32(v)
                case "accent":
                    let inside = abs(xx - w / 2) < accentW / 2 + 1 && abs(yy - h / 2) < accentH / 2 + 1
                    if inside {
                        argb = 0xFF00_0000 | palette[2]
                    } else {
                        let v = UInt32(10 + pick(r, 31))
                        argb = 0xFF00_0000 | v << 16 | v << 8 | v
                    }
                case "alpha":
                    let alphas: [UInt32] = [0, 20, 128, 255]
                    let block = (yy / 6) * 13 + (xx / 6) * 7
                    argb = alphas[pick(r, 4)] << 24 | palette[block % 5]
                case "dark":
                    if pick(r, 10) == 0 {
                        argb = 0xFF00_0000 | palette[3]
                    } else {
                        let v = UInt32(pick(r >> 4, 12))
                        argb = 0xFF00_0000 | v << 16 | v << 8 | v
                    }
                default:
                    argb = 0xFF00_0000 | (xx < w / 2 ? palette[4] : palette[5])
                }
                px[yy * w + xx] = argb
            }
        }
        return px
    }
}
