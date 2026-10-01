// CAM16, HCT and the HCT solver: a line-for-line Swift port of Google's colour utilities (Apache-2.0;
// `utils/MathUtils`, `utils/ColorUtils`, `hct/ViewingConditions`, `hct/Cam16`, `hct/Hct`, `hct/HctSolver`), the
// version Android ships in com.google.android.material:material 1.14.0. See THIRD_PARTY_NOTICES.md.
//
// JVM semantics kept on purpose: `Math.round` is floor(x + 0.5) (`KotlinMath.roundToLong`), `Math.toDegrees` /
// `toRadians` multiply by the JDK 9+ constants, `(int)` casts truncate, `%` on doubles is `truncatingRemainder`.

import Foundation
import PixlFoundation

typealias ARGB = UInt32

// MARK: - MathUtils

enum ColorMath {
    static let radiansToDegrees = 57.29577951308232
    static let degreesToRadians = 0.017453292519943295

    @inline(__always) static func toDegrees(_ radians: Double) -> Double { radians * radiansToDegrees }
    @inline(__always) static func toRadians(_ degrees: Double) -> Double { degrees * degreesToRadians }

    /// `MathUtils.signum` (an Int) and `Math.signum` (a double) agree on finite input.
    @inline(__always) static func signum(_ x: Double) -> Double { x < 0 ? -1 : (x == 0 ? 0 : 1) }

    @inline(__always) static func lerp(_ start: Double, _ stop: Double, _ amount: Double) -> Double {
        (1.0 - amount) * start + amount * stop
    }

    @inline(__always) static func clampInt(_ lo: Int, _ hi: Int, _ x: Int) -> Int { x < lo ? lo : (x > hi ? hi : x) }

    @inline(__always) static func clampDouble(_ lo: Double, _ hi: Double, _ x: Double) -> Double {
        x < lo ? lo : (x > hi ? hi : x)
    }

    static func sanitizeDegreesInt(_ degrees: Int) -> Int {
        var d = degrees % 360
        if d < 0 { d += 360 }
        return d
    }

    static func sanitizeDegreesDouble(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360.0)
        if d < 0 { d += 360.0 }
        return d
    }

    static func differenceDegrees(_ a: Double, _ b: Double) -> Double { 180.0 - abs(abs(a - b) - 180.0) }

    /// `Math.round(x)` as a double (ties toward +∞).
    @inline(__always) static func jround(_ x: Double) -> Double { Double(KotlinMath.roundToLong(x)) }

    static func matrixMultiply(_ row: (Double, Double, Double), _ m: [[Double]]) -> (Double, Double, Double) {
        let a = row.0 * m[0][0] + row.1 * m[0][1] + row.2 * m[0][2]
        let b = row.0 * m[1][0] + row.1 * m[1][1] + row.2 * m[1][2]
        let c = row.0 * m[2][0] + row.1 * m[2][1] + row.2 * m[2][2]
        return (a, b, c)
    }
}

// MARK: - ColorUtils

enum ColorUtils {
    static let srgbToXyz: [[Double]] = [
        [0.41233895, 0.35762064, 0.18051042],
        [0.2126, 0.7152, 0.0722],
        [0.01932141, 0.11916382, 0.95034478],
    ]
    static let xyzToSrgb: [[Double]] = [
        [3.2413774792388685, -1.5376652402851851, -0.49885366846268053],
        [-0.9691452513005321, 1.8758853451067872, 0.04156585616912061],
        [0.05562093689691305, -0.20395524564742123, 1.0571799111220335],
    ]
    static let whitePointD65: (Double, Double, Double) = (95.047, 100.0, 108.883)

    @inline(__always) static func argbFromRgb(_ r: Int, _ g: Int, _ b: Int) -> ARGB {
        0xFF00_0000 | ARGB(r & 255) << 16 | ARGB(g & 255) << 8 | ARGB(b & 255)
    }

    static func argbFromLinrgb(_ lin: (Double, Double, Double)) -> ARGB {
        argbFromRgb(delinearized(lin.0), delinearized(lin.1), delinearized(lin.2))
    }

    @inline(__always) static func alpha(_ argb: ARGB) -> Int { Int(argb >> 24 & 255) }
    @inline(__always) static func red(_ argb: ARGB) -> Int { Int(argb >> 16 & 255) }
    @inline(__always) static func green(_ argb: ARGB) -> Int { Int(argb >> 8 & 255) }
    @inline(__always) static func blue(_ argb: ARGB) -> Int { Int(argb & 255) }

    static func argbFromXyz(_ x: Double, _ y: Double, _ z: Double) -> ARGB {
        let m = xyzToSrgb
        let linearR = m[0][0] * x + m[0][1] * y + m[0][2] * z
        let linearG = m[1][0] * x + m[1][1] * y + m[1][2] * z
        let linearB = m[2][0] * x + m[2][1] * y + m[2][2] * z
        return argbFromRgb(delinearized(linearR), delinearized(linearG), delinearized(linearB))
    }

    static func xyzFromArgb(_ argb: ARGB) -> (Double, Double, Double) {
        ColorMath.matrixMultiply((linearized(red(argb)), linearized(green(argb)), linearized(blue(argb))), srgbToXyz)
    }

    static func argbFromLab(_ l: Double, _ a: Double, _ b: Double) -> ARGB {
        let fy = (l + 16.0) / 116.0
        let fx = a / 500.0 + fy
        let fz = fy - b / 200.0
        return argbFromXyz(labInvf(fx) * whitePointD65.0, labInvf(fy) * whitePointD65.1, labInvf(fz) * whitePointD65.2)
    }

    static func labFromArgb(_ argb: ARGB) -> (Double, Double, Double) {
        let linearR = linearized(red(argb)), linearG = linearized(green(argb)), linearB = linearized(blue(argb))
        let m = srgbToXyz
        let x = m[0][0] * linearR + m[0][1] * linearG + m[0][2] * linearB
        let y = m[1][0] * linearR + m[1][1] * linearG + m[1][2] * linearB
        let z = m[2][0] * linearR + m[2][1] * linearG + m[2][2] * linearB
        let fx = labF(x / whitePointD65.0)
        let fy = labF(y / whitePointD65.1)
        let fz = labF(z / whitePointD65.2)
        return (116.0 * fy - 16, 500.0 * (fx - fy), 200.0 * (fy - fz))
    }

    static func argbFromLstar(_ lstar: Double) -> ARGB {
        let component = delinearized(yFromLstar(lstar))
        return argbFromRgb(component, component, component)
    }

    static func lstarFromArgb(_ argb: ARGB) -> Double {
        116.0 * labF(xyzFromArgb(argb).1 / 100.0) - 16.0
    }

    static func yFromLstar(_ lstar: Double) -> Double { 100.0 * labInvf((lstar + 16.0) / 116.0) }

    static func lstarFromY(_ y: Double) -> Double { labF(y / 100.0) * 116.0 - 16.0 }

    static func linearized(_ component: Int) -> Double {
        let normalized = Double(component) / 255.0
        if normalized <= 0.040449936 {
            return normalized / 12.92 * 100.0
        }
        return pow((normalized + 0.055) / 1.055, 2.4) * 100.0
    }

    static func delinearized(_ component: Double) -> Int {
        let normalized = component / 100.0
        let delinearized: Double
        if normalized <= 0.0031308 {
            delinearized = normalized * 12.92
        } else {
            delinearized = 1.055 * pow(normalized, 1.0 / 2.4) - 0.055
        }
        return ColorMath.clampInt(0, 255, Int(KotlinMath.roundToLong(delinearized * 255.0)))
    }

    static func labF(_ t: Double) -> Double {
        let e = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        return t > e ? pow(t, 1.0 / 3.0) : (kappa * t + 16) / 116
    }

    static func labInvf(_ ft: Double) -> Double {
        let e = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        let ft3 = ft * ft * ft
        return ft3 > e ? ft3 : (116 * ft - 16) / kappa
    }
}

// MARK: - ViewingConditions

struct ViewingConditions: Sendable {
    let n: Double, aw: Double, nbb: Double, ncb: Double, c: Double, nc: Double
    let rgbD: (Double, Double, Double)
    let fl: Double, flRoot: Double, z: Double

    static let standard = ViewingConditions.defaultWithBackgroundLstar(50.0)

    static func make(whitePoint: (Double, Double, Double), adaptingLuminance: Double, backgroundLstar: Double,
                     surround: Double, discountingIlluminant: Bool) -> ViewingConditions {
        let backgroundLstar = max(0.1, backgroundLstar)
        let m = Cam16.xyzToCam16Rgb
        let xyz = whitePoint
        let rW = xyz.0 * m[0][0] + xyz.1 * m[0][1] + xyz.2 * m[0][2]
        let gW = xyz.0 * m[1][0] + xyz.1 * m[1][1] + xyz.2 * m[1][2]
        let bW = xyz.0 * m[2][0] + xyz.1 * m[2][1] + xyz.2 * m[2][2]
        let f = 0.8 + surround / 10.0
        let c = f >= 0.9 ? ColorMath.lerp(0.59, 0.69, (f - 0.9) * 10.0) : ColorMath.lerp(0.525, 0.59, (f - 0.8) * 10.0)
        var d = discountingIlluminant ? 1.0 : f * (1.0 - (1.0 / 3.6) * exp((-adaptingLuminance - 42.0) / 92.0))
        d = ColorMath.clampDouble(0.0, 1.0, d)
        let nc = f
        let rgbD = (d * (100.0 / rW) + 1.0 - d, d * (100.0 / gW) + 1.0 - d, d * (100.0 / bW) + 1.0 - d)
        let k = 1.0 / (5.0 * adaptingLuminance + 1.0)
        let k4 = k * k * k * k
        let k4F = 1.0 - k4
        let fl = k4 * adaptingLuminance + 0.1 * k4F * k4F * cbrt(5.0 * adaptingLuminance)
        let n = ColorUtils.yFromLstar(backgroundLstar) / whitePoint.1
        let z = 1.48 + n.squareRoot()
        let nbb = 0.725 / pow(n, 0.2)
        let ncb = nbb
        let fR = pow(fl * rgbD.0 * rW / 100.0, 0.42)
        let fG = pow(fl * rgbD.1 * gW / 100.0, 0.42)
        let fB = pow(fl * rgbD.2 * bW / 100.0, 0.42)
        let aR = 400.0 * fR / (fR + 27.13)
        let aG = 400.0 * fG / (fG + 27.13)
        let aB = 400.0 * fB / (fB + 27.13)
        let aw = (2.0 * aR + aG + 0.05 * aB) * nbb
        return ViewingConditions(n: n, aw: aw, nbb: nbb, ncb: ncb, c: c, nc: nc, rgbD: rgbD, fl: fl,
                                 flRoot: pow(fl, 0.25), z: z)
    }

    static func defaultWithBackgroundLstar(_ lstar: Double) -> ViewingConditions {
        // Java: 200.0 / Math.PI * yFromLstar(50.0) / 100.f
        make(whitePoint: ColorUtils.whitePointD65,
             adaptingLuminance: 200.0 / Double.pi * ColorUtils.yFromLstar(50.0) / 100.0,
             backgroundLstar: lstar, surround: 2.0, discountingIlluminant: false)
    }
}

// MARK: - Cam16

struct Cam16: Sendable {
    static let xyzToCam16Rgb: [[Double]] = [
        [0.401288, 0.650173, -0.051461],
        [-0.250268, 1.204414, 0.045854],
        [-0.002079, 0.048952, 0.953127],
    ]
    static let cam16RgbToXyz: [[Double]] = [
        [1.8620678, -1.0112547, 0.14918678],
        [0.38752654, 0.62144744, -0.00897398],
        [-0.01584150, -0.03412294, 1.0499644],
    ]

    let hue: Double, chroma: Double, j: Double, q: Double, m: Double, s: Double
    let jstar: Double, astar: Double, bstar: Double

    func distance(_ other: Cam16) -> Double {
        let dJ = jstar - other.jstar, dA = astar - other.astar, dB = bstar - other.bstar
        let dEPrime = (dJ * dJ + dA * dA + dB * dB).squareRoot()
        return 1.41 * pow(dEPrime, 0.63)
    }

    static func fromInt(_ argb: ARGB) -> Cam16 { fromInt(argb, in: .standard) }

    static func fromInt(_ argb: ARGB, in vc: ViewingConditions) -> Cam16 {
        let redL = ColorUtils.linearized(ColorUtils.red(argb))
        let greenL = ColorUtils.linearized(ColorUtils.green(argb))
        let blueL = ColorUtils.linearized(ColorUtils.blue(argb))
        let x = 0.41233895 * redL + 0.35762064 * greenL + 0.18051042 * blueL
        let y = 0.2126 * redL + 0.7152 * greenL + 0.0722 * blueL
        let z = 0.01932141 * redL + 0.11916382 * greenL + 0.95034478 * blueL
        return fromXyz(x, y, z, in: vc)
    }

    static func fromXyz(_ x: Double, _ y: Double, _ z: Double, in vc: ViewingConditions) -> Cam16 {
        let mx = xyzToCam16Rgb
        let rT = x * mx[0][0] + y * mx[0][1] + z * mx[0][2]
        let gT = x * mx[1][0] + y * mx[1][1] + z * mx[1][2]
        let bT = x * mx[2][0] + y * mx[2][1] + z * mx[2][2]
        let rD = vc.rgbD.0 * rT, gD = vc.rgbD.1 * gT, bD = vc.rgbD.2 * bT
        let rAF = pow(vc.fl * abs(rD) / 100.0, 0.42)
        let gAF = pow(vc.fl * abs(gD) / 100.0, 0.42)
        let bAF = pow(vc.fl * abs(bD) / 100.0, 0.42)
        let rA = ColorMath.signum(rD) * 400.0 * rAF / (rAF + 27.13)
        let gA = ColorMath.signum(gD) * 400.0 * gAF / (gAF + 27.13)
        let bA = ColorMath.signum(bD) * 400.0 * bAF / (bAF + 27.13)
        let a = (11.0 * rA + -12.0 * gA + bA) / 11.0
        let b = (rA + gA - 2.0 * bA) / 9.0
        let u = (20.0 * rA + 20.0 * gA + 21.0 * bA) / 20.0
        let p2 = (40.0 * rA + 20.0 * gA + bA) / 20.0
        let atanDegrees = ColorMath.toDegrees(atan2(b, a))
        let hue = atanDegrees < 0 ? atanDegrees + 360.0 : (atanDegrees >= 360 ? atanDegrees - 360.0 : atanDegrees)
        let hueRadians = ColorMath.toRadians(hue)
        let ac = p2 * vc.nbb
        let j = 100.0 * pow(ac / vc.aw, vc.c * vc.z)
        let q = 4.0 / vc.c * (j / 100.0).squareRoot() * (vc.aw + 4.0) * vc.flRoot
        let huePrime = hue < 20.14 ? hue + 360 : hue
        let eHue = 0.25 * (cos(ColorMath.toRadians(huePrime) + 2.0) + 3.8)
        let p1 = 50000.0 / 13.0 * eHue * vc.nc * vc.ncb
        let t = p1 * hypot(a, b) / (u + 0.305)
        let alpha = pow(1.64 - pow(0.29, vc.n), 0.73) * pow(t, 0.9)
        let c = alpha * (j / 100.0).squareRoot()
        let m = c * vc.flRoot
        let s = 50.0 * ((alpha * vc.c) / (vc.aw + 4.0)).squareRoot()
        let jstar = (1.0 + 100.0 * 0.007) * j / (1.0 + 0.007 * j)
        let mstar = 1.0 / 0.0228 * log1p(0.0228 * m)
        return Cam16(hue: hue, chroma: c, j: j, q: q, m: m, s: s, jstar: jstar,
                     astar: mstar * cos(hueRadians), bstar: mstar * sin(hueRadians))
    }

    static func fromJch(_ j: Double, _ c: Double, _ h: Double, in vc: ViewingConditions = .standard) -> Cam16 {
        let q = 4.0 / vc.c * (j / 100.0).squareRoot() * (vc.aw + 4.0) * vc.flRoot
        let m = c * vc.flRoot
        let alpha = c / (j / 100.0).squareRoot()
        let s = 50.0 * ((alpha * vc.c) / (vc.aw + 4.0)).squareRoot()
        let hueRadians = ColorMath.toRadians(h)
        let jstar = (1.0 + 100.0 * 0.007) * j / (1.0 + 0.007 * j)
        let mstar = 1.0 / 0.0228 * log1p(0.0228 * m)
        return Cam16(hue: h, chroma: c, j: j, q: q, m: m, s: s, jstar: jstar,
                     astar: mstar * cos(hueRadians), bstar: mstar * sin(hueRadians))
    }

    static func fromUcs(_ jstar: Double, _ astar: Double, _ bstar: Double,
                        in vc: ViewingConditions = .standard) -> Cam16 {
        let m = hypot(astar, bstar)
        let m2 = expm1(m * 0.0228) / 0.0228
        let c = m2 / vc.flRoot
        var h = atan2(bstar, astar) * (180.0 / Double.pi)
        if h < 0.0 { h += 360.0 }
        let j = jstar / (1.0 - (jstar - 100.0) * 0.007)
        return fromJch(j, c, h, in: vc)
    }

    func toInt() -> ARGB { viewed(in: .standard) }

    func viewed(in vc: ViewingConditions) -> ARGB {
        let xyz = xyz(in: vc)
        return ColorUtils.argbFromXyz(xyz.0, xyz.1, xyz.2)
    }

    func xyz(in vc: ViewingConditions) -> (Double, Double, Double) {
        let alpha = (chroma == 0.0 || j == 0.0) ? 0.0 : chroma / (j / 100.0).squareRoot()
        let t = pow(alpha / pow(1.64 - pow(0.29, vc.n), 0.73), 1.0 / 0.9)
        let hRad = ColorMath.toRadians(hue)
        let eHue = 0.25 * (cos(hRad + 2.0) + 3.8)
        let ac = vc.aw * pow(j / 100.0, 1.0 / vc.c / vc.z)
        let p1 = eHue * (50000.0 / 13.0) * vc.nc * vc.ncb
        let p2 = ac / vc.nbb
        let hSin = sin(hRad), hCos = cos(hRad)
        let gamma = 23.0 * (p2 + 0.305) * t / (23.0 * p1 + 11.0 * t * hCos + 108.0 * t * hSin)
        let a = gamma * hCos, b = gamma * hSin
        let rA = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0
        let gA = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0
        let bA = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0
        let rCBase = max(0, (27.13 * abs(rA)) / (400.0 - abs(rA)))
        let rC = ColorMath.signum(rA) * (100.0 / vc.fl) * pow(rCBase, 1.0 / 0.42)
        let gCBase = max(0, (27.13 * abs(gA)) / (400.0 - abs(gA)))
        let gC = ColorMath.signum(gA) * (100.0 / vc.fl) * pow(gCBase, 1.0 / 0.42)
        let bCBase = max(0, (27.13 * abs(bA)) / (400.0 - abs(bA)))
        let bC = ColorMath.signum(bA) * (100.0 / vc.fl) * pow(bCBase, 1.0 / 0.42)
        let rF = rC / vc.rgbD.0, gF = gC / vc.rgbD.1, bF = bC / vc.rgbD.2
        let m = Cam16.cam16RgbToXyz
        return (rF * m[0][0] + gF * m[0][1] + bF * m[0][2],
                rF * m[1][0] + gF * m[1][1] + bF * m[1][2],
                rF * m[2][0] + gF * m[2][1] + bF * m[2][2])
    }
}

// MARK: - Hct

/// Hue (CAM16), chroma (CAM16) and tone (L*), always snapped to a real sRGB colour.
struct Hct: Sendable, Hashable {
    private(set) var hue: Double
    private(set) var chroma: Double
    private(set) var tone: Double
    private(set) var argb: ARGB

    static func from(_ hue: Double, _ chroma: Double, _ tone: Double) -> Hct {
        Hct(argb: HctSolver.solveToInt(hue, chroma, tone))
    }

    static func fromInt(_ argb: ARGB) -> Hct { Hct(argb: argb) }

    init(argb: ARGB) {
        let cam = Cam16.fromInt(argb)
        self.argb = argb
        hue = cam.hue
        chroma = cam.chroma
        tone = ColorUtils.lstarFromArgb(argb)
    }

    func toInt() -> ARGB { argb }

    func withTone(_ newTone: Double) -> Hct { Hct.from(hue, chroma, newTone) }
    func withHue(_ newHue: Double) -> Hct { Hct.from(newHue, chroma, tone) }
    func withChroma(_ newChroma: Double) -> Hct { Hct.from(hue, newChroma, tone) }
}

// MARK: - HctSolver

enum HctSolver {
    static let scaledDiscountFromLinrgb: [[Double]] = [
        [0.001200833568784504, 0.002389694492170889, 0.0002795742885861124],
        [0.0005891086651375999, 0.0029785502573438758, 0.0003270666104008398],
        [0.00010146692491640572, 0.0005364214359186694, 0.0032979401770712076],
    ]
    static let linrgbFromScaledDiscount: [[Double]] = [
        [1373.2198709594231, -1100.4251190754821, -7.278681089101213],
        [-271.815969077903, 559.6580465940733, -32.46047482791194],
        [1.9622899599665666, -57.173814538844006, 308.7233197812385],
    ]
    static let yFromLinrgb: (Double, Double, Double) = (0.2126, 0.7152, 0.0722)

    typealias Vec = (Double, Double, Double)

    static func sanitizeRadians(_ angle: Double) -> Double {
        (angle + Double.pi * 8).truncatingRemainder(dividingBy: Double.pi * 2)
    }

    static func trueDelinearized(_ component: Double) -> Double {
        let normalized = component / 100.0
        let d: Double
        if normalized <= 0.0031308 {
            d = normalized * 12.92
        } else {
            d = 1.055 * pow(normalized, 1.0 / 2.4) - 0.055
        }
        return d * 255.0
    }

    static func chromaticAdaptation(_ component: Double) -> Double {
        let af = pow(abs(component), 0.42)
        return ColorMath.signum(component) * 400.0 * af / (af + 27.13)
    }

    static func hueOf(_ linrgb: Vec) -> Double {
        let sd = ColorMath.matrixMultiply(linrgb, scaledDiscountFromLinrgb)
        let rA = chromaticAdaptation(sd.0), gA = chromaticAdaptation(sd.1), bA = chromaticAdaptation(sd.2)
        let a = (11.0 * rA + -12.0 * gA + bA) / 11.0
        let b = (rA + gA - 2.0 * bA) / 9.0
        return atan2(b, a)
    }

    static func areInCyclicOrder(_ a: Double, _ b: Double, _ c: Double) -> Bool {
        sanitizeRadians(b - a) < sanitizeRadians(c - a)
    }

    static func intercept(_ source: Double, _ mid: Double, _ target: Double) -> Double {
        (mid - source) / (target - source)
    }

    static func lerpPoint(_ s: Vec, _ t: Double, _ e: Vec) -> Vec {
        (s.0 + (e.0 - s.0) * t, s.1 + (e.1 - s.1) * t, s.2 + (e.2 - s.2) * t)
    }

    static func component(_ v: Vec, _ axis: Int) -> Double { axis == 0 ? v.0 : (axis == 1 ? v.1 : v.2) }

    static func setCoordinate(_ source: Vec, _ coordinate: Double, _ target: Vec, _ axis: Int) -> Vec {
        let t = intercept(component(source, axis), coordinate, component(target, axis))
        return lerpPoint(source, t, target)
    }

    static func isBounded(_ x: Double) -> Bool { 0.0 <= x && x <= 100.0 }

    static func nthVertex(_ y: Double, _ n: Int) -> Vec {
        let kR = yFromLinrgb.0, kG = yFromLinrgb.1, kB = yFromLinrgb.2
        let coordA = n % 4 <= 1 ? 0.0 : 100.0
        let coordB = n % 2 == 0 ? 0.0 : 100.0
        if n < 4 {
            let g = coordA, b = coordB
            let r = (y - g * kG - b * kB) / kR
            return isBounded(r) ? (r, g, b) : (-1.0, -1.0, -1.0)
        } else if n < 8 {
            let b = coordA, r = coordB
            let g = (y - r * kR - b * kB) / kG
            return isBounded(g) ? (r, g, b) : (-1.0, -1.0, -1.0)
        } else {
            let r = coordA, g = coordB
            let b = (y - r * kR - g * kG) / kB
            return isBounded(b) ? (r, g, b) : (-1.0, -1.0, -1.0)
        }
    }

    static func bisectToSegment(_ y: Double, _ targetHue: Double) -> (Vec, Vec) {
        var left: Vec = (-1.0, -1.0, -1.0)
        var right = left
        var leftHue = 0.0, rightHue = 0.0
        var initialized = false
        var uncut = true
        for n in 0..<12 {
            let mid = nthVertex(y, n)
            if mid.0 < 0 { continue }
            let midHue = hueOf(mid)
            if !initialized {
                left = mid; right = mid
                leftHue = midHue; rightHue = midHue
                initialized = true
                continue
            }
            if uncut || areInCyclicOrder(leftHue, midHue, rightHue) {
                uncut = false
                if areInCyclicOrder(leftHue, targetHue, midHue) {
                    right = mid; rightHue = midHue
                } else {
                    left = mid; leftHue = midHue
                }
            }
        }
        return (left, right)
    }

    static func midpoint(_ a: Vec, _ b: Vec) -> Vec { ((a.0 + b.0) / 2, (a.1 + b.1) / 2, (a.2 + b.2) / 2) }

    static func criticalPlaneBelow(_ x: Double) -> Int { Int(KotlinMath.toInt((x - 0.5).rounded(.down))) }
    static func criticalPlaneAbove(_ x: Double) -> Int { Int(KotlinMath.toInt((x - 0.5).rounded(.up))) }

    static func bisectToLimit(_ y: Double, _ targetHue: Double) -> Vec {
        let segment = bisectToSegment(y, targetHue)
        var left = segment.0
        var leftHue = hueOf(left)
        var right = segment.1
        for axis in 0..<3 where component(left, axis) != component(right, axis) {
            var lPlane: Int
            var rPlane: Int
            if component(left, axis) < component(right, axis) {
                lPlane = criticalPlaneBelow(trueDelinearized(component(left, axis)))
                rPlane = criticalPlaneAbove(trueDelinearized(component(right, axis)))
            } else {
                lPlane = criticalPlaneAbove(trueDelinearized(component(left, axis)))
                rPlane = criticalPlaneBelow(trueDelinearized(component(right, axis)))
            }
            for _ in 0..<8 {
                if abs(rPlane - lPlane) <= 1 { break }
                let mPlane = Int((Double(lPlane + rPlane) / 2.0).rounded(.down))
                let midPlaneCoordinate = criticalPlanes[mPlane]
                let mid = setCoordinate(left, midPlaneCoordinate, right, axis)
                let midHue = hueOf(mid)
                if areInCyclicOrder(leftHue, targetHue, midHue) {
                    right = mid
                    rPlane = mPlane
                } else {
                    left = mid
                    leftHue = midHue
                    lPlane = mPlane
                }
            }
        }
        return midpoint(left, right)
    }

    static func inverseChromaticAdaptation(_ adapted: Double) -> Double {
        let adaptedAbs = abs(adapted)
        let base = max(0, 27.13 * adaptedAbs / (400.0 - adaptedAbs))
        return ColorMath.signum(adapted) * pow(base, 1.0 / 0.42)
    }

    static func findResultByJ(_ hueRadians: Double, _ chroma: Double, _ y: Double) -> ARGB {
        var j = y.squareRoot() * 11.0
        let vc = ViewingConditions.standard
        let tInnerCoeff = 1 / pow(1.64 - pow(0.29, vc.n), 0.73)
        let eHue = 0.25 * (cos(hueRadians + 2.0) + 3.8)
        let p1 = eHue * (50000.0 / 13.0) * vc.nc * vc.ncb
        let hSin = sin(hueRadians), hCos = cos(hueRadians)
        for iterationRound in 0..<5 {
            let jNormalized = j / 100.0
            let alpha = chroma == 0.0 || j == 0.0 ? 0.0 : chroma / jNormalized.squareRoot()
            let t = pow(alpha * tInnerCoeff, 1.0 / 0.9)
            let ac = vc.aw * pow(jNormalized, 1.0 / vc.c / vc.z)
            let p2 = ac / vc.nbb
            let gamma = 23.0 * (p2 + 0.305) * t / (23.0 * p1 + 11 * t * hCos + 108.0 * t * hSin)
            let a = gamma * hCos, b = gamma * hSin
            let rA = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0
            let gA = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0
            let bA = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0
            let linrgb = ColorMath.matrixMultiply(
                (inverseChromaticAdaptation(rA), inverseChromaticAdaptation(gA), inverseChromaticAdaptation(bA)),
                linrgbFromScaledDiscount)
            if linrgb.0 < 0 || linrgb.1 < 0 || linrgb.2 < 0 { return 0 }
            let fnj = yFromLinrgb.0 * linrgb.0 + yFromLinrgb.1 * linrgb.1 + yFromLinrgb.2 * linrgb.2
            if fnj <= 0 { return 0 }
            if iterationRound == 4 || abs(fnj - y) < 0.002 {
                if linrgb.0 > 100.01 || linrgb.1 > 100.01 || linrgb.2 > 100.01 { return 0 }
                return ColorUtils.argbFromLinrgb(linrgb)
            }
            j = j - (fnj - y) * j / (2 * fnj)
        }
        return 0
    }

    static func solveToInt(_ hueDegrees: Double, _ chroma: Double, _ lstar: Double) -> ARGB {
        if chroma < 0.0001 || lstar < 0.0001 || lstar > 99.9999 {
            return ColorUtils.argbFromLstar(lstar)
        }
        let hue = ColorMath.sanitizeDegreesDouble(hueDegrees)
        let hueRadians = hue / 180 * Double.pi
        let y = ColorUtils.yFromLstar(lstar)
        let exact = findResultByJ(hueRadians, chroma, y)
        if exact != 0 { return exact }
        return ColorUtils.argbFromLinrgb(bisectToLimit(y, hueRadians))
    }
}
