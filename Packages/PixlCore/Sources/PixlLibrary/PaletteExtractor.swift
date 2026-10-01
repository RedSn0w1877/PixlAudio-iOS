// A small, deterministic k-means palette for album art (architecture §3: `ColorExtractor` decodes a 32×32 RGBA
// thumbnail with ImageIO and hands the pixels here). Clustering runs in Oklab so clusters follow perceived colour;
// the accent favours saturated, mid-light clusters with real presence over large grey or near-black areas, and the
// average luminance drives the "dim the glass over bright art" rule. Pure Swift: no CoreGraphics.

import Foundation

/// An sRGB colour with components in 0…1.
public struct PaletteColor: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#RRGGBB`.
    public var hex: String {
        func byte(_ c: Double) -> String {
            let v = Int((c.coerced(in: 0, 1) * 255).rounded())
            let s = String(v, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }
        return "#" + byte(red) + byte(green) + byte(blue)
    }

    /// ARGB as a 32-bit integer (opaque), the format Android stores colours in.
    public var argb: UInt32 {
        func byte(_ c: Double) -> UInt32 { UInt32((c.coerced(in: 0, 1) * 255).rounded()) }
        return 0xFF00_0000 | byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    /// WCAG relative luminance (0 black … 1 white).
    public var relativeLuminance: Double {
        0.2126 * Oklab.linear(red) + 0.7152 * Oklab.linear(green) + 0.0722 * Oklab.linear(blue)
    }
}

/// One cluster: its mean colour and the share of the (opaque) image it covers.
public struct PaletteSwatch: Sendable, Hashable {
    public var color: PaletteColor
    /// 0…1.
    public var population: Double
    /// Oklab lightness 0…1.
    public var lightness: Double
    /// Oklab chroma (0 = grey; vivid colours ≈ 0.1–0.3).
    public var chroma: Double
}

public struct ArtworkPalette: Sendable, Hashable {
    /// Clusters, largest first.
    public var swatches: [PaletteSwatch]
    /// The largest cluster.
    public var dominant: PaletteSwatch
    /// The colour to tint with (the play button, mix cards, header gradients).
    public var accent: PaletteSwatch
    /// Mean relative luminance of the opaque pixels (> 0.6 = bright art).
    public var averageLuminance: Double

    public var isBright: Bool { averageLuminance > 0.6 }
}

public enum PaletteExtractor {
    /// Extracts the palette of an RGBA8 buffer (row-major, `bytesPerRow` ≥ 4·width). Pixels under 50 % alpha are
    /// ignored; larger images are box-averaged to at most `maxSide`² cells first. Nil when nothing is opaque.
    public static func extract(rgba: [UInt8], width: Int, height: Int, bytesPerRow: Int? = nil,
                               premultipliedAlpha: Bool = false, clusterCount: Int = 5, maxSide: Int = 32,
                               maxIterations: Int = 16) -> ArtworkPalette? {
        let stride = bytesPerRow ?? width * 4
        guard width > 0, height > 0, stride >= width * 4, rgba.count >= stride * (height - 1) + width * 4 else { return nil }
        let samples = downsample(rgba, width: width, height: height, stride: stride, premultiplied: premultipliedAlpha,
                                 maxSide: max(maxSide, 1))
        guard !samples.isEmpty else { return nil }
        let totalWeight = samples.reduce(0.0) { $0 + $1.weight }
        let averageLuminance = samples.reduce(0.0) { $0 + $1.luminance * $1.weight } / totalWeight
        let clusters = kMeans(samples, k: max(1, clusterCount), maxIterations: maxIterations)
        let swatches = clusters.map { cluster -> PaletteSwatch in
            let rgb = Oklab.toSRGB(cluster.l, cluster.a, cluster.b)
            return PaletteSwatch(color: rgb, population: cluster.weight / totalWeight, lightness: cluster.l,
                                 chroma: (cluster.a * cluster.a + cluster.b * cluster.b).squareRoot())
        }.kotlinSorted { javaDoubleCompare($1.population, $0.population) }
        let dominant = swatches[0]
        let accent = chooseAccent(swatches) ?? dominant
        return ArtworkPalette(swatches: swatches, dominant: dominant, accent: accent, averageLuminance: averageLuminance)
    }

    /// The accent: highest `√population · (chroma + 0.02) · lightness fit` among clusters covering at least 3 %
    /// with some colour; nil for grey art (the dominant colour is used).
    static func chooseAccent(_ swatches: [PaletteSwatch]) -> PaletteSwatch? {
        var best: (swatch: PaletteSwatch, score: Double)?
        for swatch in swatches where swatch.population >= 0.03 && swatch.chroma >= 0.03 {
            let lightnessFit = max(0.1, 1.0 - abs(swatch.lightness - 0.65) * 1.6)
            let score = swatch.population.squareRoot() * (swatch.chroma + 0.02) * lightnessFit
            if best == nil || score > best!.score { best = (swatch, score) }
        }
        return best?.swatch
    }

    struct Sample {
        var l: Double, a: Double, b: Double
        var weight: Double
        var luminance: Double
    }

    static func downsample(_ px: [UInt8], width: Int, height: Int, stride: Int, premultiplied: Bool,
                           maxSide: Int) -> [Sample] {
        let cellsX = min(width, maxSide), cellsY = min(height, maxSide)
        var samples: [Sample] = []
        samples.reserveCapacity(cellsX * cellsY)
        for cy in 0..<cellsY {
            let y0 = cy * height / cellsY, y1 = max((cy + 1) * height / cellsY, y0 + 1)
            for cx in 0..<cellsX {
                let x0 = cx * width / cellsX, x1 = max((cx + 1) * width / cellsX, x0 + 1)
                var r = 0.0, g = 0.0, b = 0.0, w = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = y * stride + x * 4
                        let alpha = Double(px[i + 3]) / 255
                        if alpha < 0.5 { continue }
                        var cr = Double(px[i]) / 255, cg = Double(px[i + 1]) / 255, cb = Double(px[i + 2]) / 255
                        if premultiplied {
                            cr = min(cr / alpha, 1)
                            cg = min(cg / alpha, 1)
                            cb = min(cb / alpha, 1)
                        }
                        // Average in linear light so a cell of black and white pixels is a true mid grey.
                        r += Oklab.linear(cr) * alpha
                        g += Oklab.linear(cg) * alpha
                        b += Oklab.linear(cb) * alpha
                        w += alpha
                    }
                }
                guard w > 0 else { continue }
                let lr = r / w, lg = g / w, lb = b / w
                let lab = Oklab.fromLinear(lr, lg, lb)
                samples.append(Sample(l: lab.0, a: lab.1, b: lab.2, weight: w,
                                      luminance: 0.2126 * lr + 0.7152 * lg + 0.0722 * lb))
            }
        }
        return samples
    }

    struct Cluster {
        var l: Double, a: Double, b: Double
        var weight: Double
    }

    static func distance2(_ s: Sample, _ c: Cluster) -> Double {
        let dl = s.l - c.l, da = s.a - c.a, db = s.b - c.b
        return dl * dl + da * da + db * db
    }

    /// Weighted k-means with deterministic k-means++ seeding (fixed-seed `KotlinRandom`), so the same art always
    /// gives the same palette.
    static func kMeans(_ samples: [Sample], k: Int, maxIterations: Int) -> [Cluster] {
        var random = KotlinRandom(seed: Int32(0x5EED))
        var centers: [Cluster] = []
        let first = samples.indices.max { samples[$0].weight < samples[$1].weight } ?? 0
        centers.append(Cluster(l: samples[first].l, a: samples[first].a, b: samples[first].b, weight: 0))
        var nearest = samples.map { distance2($0, centers[0]) }
        while centers.count < min(k, samples.count) {
            let total = zip(samples, nearest).reduce(0.0) { $0 + $1.0.weight * $1.1 }
            if total <= 1e-12 { break }
            let target = Double(random.nextInt(until: Int32(1 << 30))) / Double(1 << 30) * total
            var acc = 0.0
            var chosen = samples.count - 1
            for i in samples.indices {
                acc += samples[i].weight * nearest[i]
                if acc >= target && nearest[i] > 0 { chosen = i; break }
            }
            let s = samples[chosen]
            let center = Cluster(l: s.l, a: s.a, b: s.b, weight: 0)
            centers.append(center)
            for i in samples.indices { nearest[i] = min(nearest[i], distance2(samples[i], center)) }
        }
        var assignment = [Int](repeating: 0, count: samples.count)
        for _ in 0..<max(1, maxIterations) {
            for i in samples.indices {
                var best = 0
                var bestDistance = Double.infinity
                for (c, center) in centers.enumerated() {
                    let d = distance2(samples[i], center)
                    if d < bestDistance { bestDistance = d; best = c }
                }
                assignment[i] = best
            }
            var sums = [Cluster](repeating: Cluster(l: 0, a: 0, b: 0, weight: 0), count: centers.count)
            for i in samples.indices {
                let s = samples[i], c = assignment[i]
                sums[c].l += s.l * s.weight
                sums[c].a += s.a * s.weight
                sums[c].b += s.b * s.weight
                sums[c].weight += s.weight
            }
            var moved = 0.0
            for c in centers.indices where sums[c].weight > 0 {
                let w = sums[c].weight
                let next = Cluster(l: sums[c].l / w, a: sums[c].a / w, b: sums[c].b / w, weight: w)
                let dl = next.l - centers[c].l, da = next.a - centers[c].a, db = next.b - centers[c].b
                moved = max(moved, dl * dl + da * da + db * db)
                centers[c] = next
            }
            for c in centers.indices where sums[c].weight == 0 { centers[c].weight = 0 }
            if moved < 1e-10 { break }
        }
        return centers.filter { $0.weight > 0 }
    }
}

/// Oklab (Björn Ottosson) and the sRGB transfer functions.
enum Oklab {
    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gamma(_ c: Double) -> Double {
        let v = c.coerced(in: 0, 1)
        return v <= 0.003_130_8 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    static func fromLinear(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let l = cbrt(0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b)
        let m = cbrt(0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b)
        let s = cbrt(0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b)
        return (0.210_454_255_3 * l + 0.793_617_785_0 * m - 0.004_072_046_8 * s,
                1.977_998_495_1 * l - 2.428_592_205_0 * m + 0.450_593_709_9 * s,
                0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766_0 * s)
    }

    static func toSRGB(_ L: Double, _ a: Double, _ b: Double) -> PaletteColor {
        let l = pow(L + 0.396_337_777_4 * a + 0.215_803_757_3 * b, 3)
        let m = pow(L - 0.105_561_345_8 * a - 0.063_854_172_8 * b, 3)
        let s = pow(L - 0.089_484_177_5 * a - 1.291_485_548_0 * b, 3)
        return PaletteColor(red: gamma(4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s),
                            green: gamma(-1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s),
                            blue: gamma(-0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s))
    }
}
