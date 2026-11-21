import Foundation

// The ring code's colours, from the device colour, with the contrast rule (a port of the Android `RingCodeStyle.kt`). Floating
// point, so it lives in `ring/image`, the only folder the purity test lets use Foundation's maths: the maths is CIE L*a*b*
// ("tone" is L*, the same number Material's HCT calls tone) and WCAG relative luminance. Colours are opaque ARGB values in a
// UInt32 (the Android `Int`'s bits); nothing here knows UIKit or SwiftUI.
//
// Hoa's rules (2026-11-20): the dots are the accent / device colour; the plate is a light tone of the same hue (tone 95), because
// a camera reads dark dots on a light plate best; the dots keep at least 7:1 contrast against the plate, so a pale colour is
// darkened (tone by tone, toward 30) until it passes; the orange start dot is the one fixed colour.
//
// Checked by properties (contrast at least 7, plate tone 95 plus or minus 1), not by golden vectors.

/// Saturating Double to Int, like Kotlin's `toInt()`: NaN is 0 and a huge value stops at the Int32 range (Swift's `Int(_:)` traps).
@inline(__always)
func ringInt(_ x: Double) -> Int {
    if x.isNaN { return 0 }
    if x >= 2_147_483_647.0 { return 2_147_483_647 }
    if x <= -2_147_483_648.0 { return -2_147_483_648 }
    return Int(x)
}

public enum RingCodeStyle {
    public static let plateTone = 95.0
    public static let minContrast = 7.0
    public static let darkestTone = 30.0
    /// The plate keeps a hint of the device colour: at most this much chroma (Lab C*).
    public static let plateMaxChroma = 8.0
    public static let bigToSmallRadius = 2.0

    /// The colours of one code. `clamped` is true when the device colour had to be darkened.
    public struct Palette: Sendable {
        public let dot: UInt32
        public let plate: UInt32
        public let marker: UInt32
        public let dotTone: Double
        public let plateTone: Double
        public let contrast: Double
        public let clamped: Bool
    }

    // MARK: Colour maths

    private static func srgbToLinear(_ c: Int) -> Double {
        let v = Double(c) / 255.0
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ v: Double) -> Double {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    private static func red(_ argb: UInt32) -> Int { Int((argb >> 16) & 0xFF) }
    private static func green(_ argb: UInt32) -> Int { Int((argb >> 8) & 0xFF) }
    private static func blue(_ argb: UInt32) -> Int { Int(argb & 0xFF) }

    /// WCAG relative luminance, 0..1.
    public static func relativeLuminance(_ argb: UInt32) -> Double {
        let r = srgbToLinear(red(argb))
        let g = srgbToLinear(green(argb))
        let b = srgbToLinear(blue(argb))
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// WCAG contrast ratio of two opaque colours, 1..21.
    public static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private struct Lab {
        let l: Double
        let a: Double
        let b: Double
    }

    private static let xn = 0.95047
    private static let yn = 1.0
    private static let zn = 1.08883

    private static func labF(_ t: Double) -> Double {
        t > 216.0 / 24389.0 ? cbrt(t) : (24389.0 / 27.0 * t + 16.0) / 116.0
    }

    private static func labFInv(_ t: Double) -> Double {
        let t3 = t * t * t
        return t3 > 216.0 / 24389.0 ? t3 : (116.0 * t - 16.0) / (24389.0 / 27.0)
    }

    private static func toLab(_ argb: UInt32) -> Lab {
        let r = srgbToLinear(red(argb))
        let g = srgbToLinear(green(argb))
        let b = srgbToLinear(blue(argb))
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        let fx = labF(x / xn)
        let fy = labF(y / yn)
        let fz = labF(z / zn)
        return Lab(l: 116.0 * fy - 16.0, a: 500.0 * (fx - fy), b: 200.0 * (fy - fz))
    }

    /// CIE L* of a colour, 0..100: the tone.
    public static func toneOf(_ argb: UInt32) -> Double { toLab(argb).l }

    /// The colour at `tone` with the given Lab chroma and hue (radians), chroma reduced until it fits sRGB.
    private static func fromLch(_ tone: Double, _ chroma: Double, _ hue: Double) -> UInt32 {
        var lo = 0.0
        var hi = chroma
        var best = lchToRgbOrNil(tone, 0.0, hue) ?? 0xFF00_0000
        if chroma > 0.0 {
            if let full = lchToRgbOrNil(tone, chroma, hue) { return full }
            for _ in 0..<24 {
                let mid = (lo + hi) / 2.0
                if let c = lchToRgbOrNil(tone, mid, hue) { best = c; lo = mid } else { hi = mid }
            }
        }
        return best
    }

    private static func lchToRgbOrNil(_ tone: Double, _ chroma: Double, _ hue: Double) -> UInt32? {
        let a = chroma * cos(hue)
        let b = chroma * sin(hue)
        let fy = (tone + 16.0) / 116.0
        let fx = fy + a / 500.0
        let fz = fy - b / 200.0
        let x = xn * labFInv(fx)
        let y = yn * labFInv(fy)
        let z = zn * labFInv(fz)
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let bl = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        let eps = 1e-4
        if r < -eps || r > 1.0 + eps || g < -eps || g > 1.0 + eps || bl < -eps || bl > 1.0 + eps { return nil }
        func enc(_ v: Double) -> UInt32 {
            UInt32(min(255, max(0, ringInt(linearToSrgb(min(1.0, max(0.0, v))) * 255.0 + 0.5))))
        }
        return (0xFF << 24) | (enc(r) << 16) | (enc(g) << 8) | enc(bl)
    }

    /// The device colour's colour at another tone (hue kept, chroma kept as far as sRGB allows).
    public static func withTone(_ argb: UInt32, _ tone: Double, maxChroma: Double = Double.greatestFiniteMagnitude) -> UInt32 {
        let lab = toLab(argb)
        let chroma = min((lab.a * lab.a + lab.b * lab.b).squareRoot(), maxChroma)
        let hue = atan2(lab.b, lab.a)
        return fromLch(min(100.0, max(0.0, tone)), chroma, hue)
    }

    /// The palette for a device colour. The plate is tone 95 of its hue with a hint of chroma. The dots are the device colour
    /// itself when it is at least `minContrast`:1 against that plate, otherwise the same hue one tone darker at a time (down to
    /// `darkestTone` at the most, which always passes) until it does.
    public static func palette(_ deviceArgb: UInt32) -> Palette {
        let opaque = deviceArgb | 0xFF00_0000
        let plate = withTone(opaque, plateTone, maxChroma: plateMaxChroma)
        var dot = opaque
        var contrast = contrastRatio(dot, plate)
        var clamped = false
        if contrast < minContrast {
            clamped = true
            var tone = min(toneOf(opaque), 60.0)
            while true {
                dot = withTone(opaque, tone)
                contrast = contrastRatio(dot, plate)
                if contrast >= minContrast || tone <= darkestTone { break }
                tone -= 1.0
            }
            if contrast < minContrast { // cannot happen for tone 30 on tone 95, kept as a floor
                dot = withTone(opaque, 20.0)
                contrast = contrastRatio(dot, plate)
            }
        }
        return Palette(dot: dot, plate: plate, marker: UInt32(bitPattern: RingCodeLayout.markerArgb), dotTone: toneOf(dot),
                       plateTone: toneOf(plate), contrast: contrast, clamped: clamped)
    }

    /// Dot radii in permille of the plate half-size: big and small (big = 2 x small).
    public static func bigRadius() -> Int { RingCodeLayout.bigRadius }
    public static func smallRadius() -> Int { RingCodeLayout.smallRadius }

    /// Luma (0..255, BT.601) of an ARGB colour: what a camera's Y plane would record, roughly.
    public static func lumaOf(_ argb: UInt32) -> Int {
        (299 * red(argb) + 587 * green(argb) + 114 * blue(argb) + 500) / 1000
    }

    /// True when two colours differ so little they could be the same: used by tests.
    public static func near(_ a: UInt32, _ b: UInt32, tolerance: Int = 2) -> Bool {
        abs(red(a) - red(b)) <= tolerance && abs(green(a) - green(b)) <= tolerance && abs(blue(a) - blue(b)) <= tolerance
    }
}
