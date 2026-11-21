import Foundation

// Reads a Pixl ring code from a camera frame (a port of the Android `RingScanner.kt`, same steps and same constants).
//
// One camera frame as the scanner takes it: the luma (Y) plane, row-major, `width` x `height`, and optionally a coarse
// "orangeness" map (`hue`, `hueWidth` x `hueHeight`, 0 = not orange, 255 = the start dot's colour) that the app builds from the
// U and V planes with `RingHue.orangeness`. The hue map is only a tie-breaker: the scanner finds the start dot by where it is
// (the one dot outside the outer ring), so a device colour that is itself orange cannot hide it. A frame without a hue map is fine.

public struct RingFrame: Sendable {
    public let width: Int
    public let height: Int
    public let luma: [UInt8]
    public let hue: [UInt8]?
    public let hueWidth: Int
    public let hueHeight: Int

    public init(width: Int, height: Int, luma: [UInt8], hue: [UInt8]? = nil, hueWidth: Int? = nil, hueHeight: Int? = nil) {
        self.width = width
        self.height = height
        self.luma = luma
        self.hue = hue
        self.hueWidth = hueWidth ?? width
        self.hueHeight = hueHeight ?? height
    }
}

public enum RingHue {
    /// How orange a pixel is, 0..255, from its chroma values (U = Cb, V = Cr, 0..255, 128 = neutral). The start dot (0xD9480F)
    /// has U about 75 and V about 205: strong V, weak U.
    public static func orangeness(u: Int, v: Int) -> Int {
        let du = 128 - u
        let dv = v - 128
        if du <= 10 || dv <= 25 { return 0 }
        let ratio = dv * 100 / du
        if ratio < 90 || ratio > 280 { return 0 }
        return min(255, (min(du, dv) - 10) * 5)
    }
}

public enum RingScanFailure: String, Sendable {
    /// No round outline found.
    case noPlate = "no_plate"
    /// An outline, but no start dot where one belongs.
    case noMarker = "no_marker"
    /// Too few dots matched the layout to trust the geometry.
    case tooFewDots = "too_few_dots"
    /// The dots were read but the code could not be repaired.
    case unreadable = "unreadable"
    /// Repaired, but the checksum says it is not a code of ours.
    case badChecksum = "bad_checksum"

    public var code: String { rawValue }
}

/// What the last scan saw, for the Developer mode screen. Owned by the scanner and overwritten by the next scan.
public struct RingScanDiagnostics: Sendable {
    public var scale = 1
    public var found = false
    public var centreX = 0.0
    public var centreY = 0.0
    public var bezelRadiusPx = 0.0
    public var markerFound = false
    public var markerX = 0.0
    public var markerY = 0.0
    public var matched = 0
    public var residualPx = 0.0
    public var homography = [Double](repeating: 0, count: 9)
    public var rsCorrected = 0
    public var erasuresUsed = 0
    public var candidates = 0
    public var scanMicros: Int64 = 0
    /// Per slot: 0..100, how clearly the dot read as big or small.
    public var slotConfidence = [Int](repeating: 0, count: RingCodeLayout.slots)
    /// Per slot: the measured dot mass in squared permille (a small dot is about 800, a big one about 3200).
    public var slotMass = [Double](repeating: 0, count: RingCodeLayout.slots)
    public var slotBits = [UInt8](repeating: 0, count: RingCodeLayout.slots)
}

public enum RingScanResult: Sendable {
    case decoded(payload: RingCodePayload, corrected: Int, erasures: Int)
    case failed(RingScanFailure)

    public var payload: RingCodePayload? {
        if case .decoded(let p, _, _) = self { return p }
        return nil
    }

    public var isDecoded: Bool { payload != nil }
}

/// Reads a Pixl ring code from a camera frame. Pure Swift over a luma array; one instance owns its scratch memory and must be
/// used from one thread (the app's analysis queue). The app skips frames so a scan never starves the UI.
///
/// How it works (RING-CODE-SPEC.md, "Scanning"):
/// 1. Downscale to at most `maxSide` pixels on the long side (box average) and threshold each pixel against the mean of its
///    neighbourhood (an integral image), so a gradient or a glare edge does not matter.
/// 2. Label the dark blobs. The plate's outline ring around the artwork is a large round blob: its outer boundary is an ellipse
///    whatever the artwork holds (every row's leftmost and rightmost pixel give the filled shape; its second moments give the
///    centre and the two axes). That undoes scale and tilt up to the rotation, which the start dot then fixes: it is the one
///    dot-sized blob beyond the outer ring.
/// 3. Match every expected slot position to the nearest dot blob and fit a homography in five steps, adding one ring at a time,
///    so perspective is learnt from the inner rings first and extrapolated outward.
/// 4. Measure the dark mass in a small window around each of the 200 slots (normalised by the plate's own light and dark
///    levels), compare each to its ring's two clusters (two-means, seeded with the expected sizes), and call it big (1) or small
///    (0). Confidence is the distance from the decision line.
/// 5. Reed-Solomon decode, first as it is, then with the least certain bytes flagged as erasures (at most 10), and check the
///    payload's checksum.
public final class RingScanner {
    private let maxSide: Int

    public private(set) var diagnostics = RingScanDiagnostics()

    /// Test hook: where the scanner says what it decided. Nil in the app.
    public var trace: ((String) -> Void)?

    // working buffers (grown on demand)
    private var gw = 0
    private var gh = 0
    private var gray = [Int](repeating: 0, count: 0)
    private var integral = [Int](repeating: 0, count: 0)
    private var mask = [UInt8](repeating: 0, count: 0)
    private var labels = [Int](repeating: 0, count: 0)
    private var parent = [Int](repeating: 0, count: 1024)

    // blob stats, per compact component id
    private var compCount = 0
    private var cArea = [Int](repeating: 0, count: 256)
    private var cMinX = [Int](repeating: 0, count: 256)
    private var cMaxX = [Int](repeating: 0, count: 256)
    private var cMinY = [Int](repeating: 0, count: 256)
    private var cMaxY = [Int](repeating: 0, count: 256)
    private var cSumX = [Double](repeating: 0, count: 256)
    private var cSumY = [Double](repeating: 0, count: 256)

    private var hist = [Int](repeating: 0, count: 256)
    private var slotCx = [Double](repeating: 0, count: RingCodeLayout.slots)
    private var slotCy = [Double](repeating: 0, count: RingCodeLayout.slots)
    private var slotMass = [Double](repeating: 0, count: RingCodeLayout.slots)
    private var slotBit = [UInt8](repeating: 0, count: RingCodeLayout.slots)
    private var slotConf = [Int](repeating: 0, count: RingCodeLayout.slots)

    // plate-plane coordinates of the slots (and, last, the start dot), permille
    private var qx = [Double](repeating: 0, count: RingCodeLayout.slots + 1)
    private var qy = [Double](repeating: 0, count: RingCodeLayout.slots + 1)

    public init(maxSide: Int = 800) {
        self.maxSide = maxSide
        for slot in 0..<RingCodeLayout.slots {
            let ring = RingCodeLayout.ringOf(slot)
            let exact = Double(RingCodeLayout.indexInRing(slot)) / Double(RingCodeLayout.ringSlots[ring]) * 2.0 * Double.pi
            qx[slot] = Double(RingCodeLayout.ringRadius[ring]) * sin(exact)
            qy[slot] = -Double(RingCodeLayout.ringRadius[ring]) * cos(exact)
        }
        qx[RingCodeLayout.slots] = 0.0
        qy[RingCodeLayout.slots] = -Double(RingCodeLayout.markerRadiusAt)
    }

    // MARK: Public

    /// Scans one frame. `clockNanos` is optional and only used for `RingScanDiagnostics.scanMicros`.
    public func scan(_ frame: RingFrame, clockNanos: (() -> Int64)? = nil) -> RingScanResult {
        let t0 = clockNanos?() ?? 0
        let result = scanInner(frame)
        if let clockNanos { diagnostics.scanMicros = (clockNanos() - t0) / 1000 }
        return result
    }

    private func scanInner(_ frame: RingFrame) -> RingScanResult {
        diagnostics.found = false; diagnostics.markerFound = false; diagnostics.matched = 0; diagnostics.residualPx = 0.0
        diagnostics.rsCorrected = 0; diagnostics.erasuresUsed = 0; diagnostics.candidates = 0
        if frame.width < 64 || frame.height < 64 || frame.luma.count < frame.width * frame.height {
            return .failed(.noPlate)
        }
        prepare(frame)
        threshold()
        label()
        let bezels = findBezels()
        if bezels.isEmpty { return .failed(.noPlate) }
        // Best outline first. A second reading of the same outline (the arc fit beside the moments fit) is the way out when a
        // smudge or a glare patch hid part of it and the first ellipse came out a little skewed.
        var firstFailure: RingScanResult?
        for bezel in bezels {
            let r = readCode(frame, bezel)
            if r.isDecoded { return r }
            if firstFailure == nil { firstFailure = r }
        }
        return firstFailure ?? .failed(.noPlate)
    }

    // MARK: 1. working image

    private func prepare(_ frame: RingFrame) {
        let f = max(1, (max(frame.width, frame.height) + maxSide - 1) / maxSide)
        diagnostics.scale = f
        gw = frame.width / f
        gh = frame.height / f
        if gray.count < gw * gh {
            gray = [Int](repeating: 0, count: gw * gh)
            mask = [UInt8](repeating: 0, count: gw * gh)
            labels = [Int](repeating: 0, count: gw * gh)
        }
        if integral.count < (gw + 1) * (gh + 1) { integral = [Int](repeating: 0, count: (gw + 1) * (gh + 1)) }
        frame.luma.withUnsafeBufferPointer { luma in
            if f == 1 {
                for i in 0..<(gw * gh) { gray[i] = Int(luma[i]) }
            } else {
                let area = f * f
                for y in 0..<gh {
                    for x in 0..<gw {
                        var acc = 0
                        let base = y * f * frame.width + x * f
                        for dy in 0..<f {
                            let row = base + dy * frame.width
                            for dx in 0..<f { acc += Int(luma[row + dx]) }
                        }
                        gray[y * gw + x] = acc / area
                    }
                }
            }
        }
        let stride = gw + 1
        for x in 0...gw { integral[x] = 0 }
        for y in 0..<gh {
            var rowSum = 0
            integral[(y + 1) * stride] = 0
            for x in 0..<gw {
                rowSum += gray[y * gw + x]
                integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + rowSum
            }
        }
    }

    private func threshold() {
        let half = max(10, min(gw, gh) / 20)
        let stride = gw + 1
        for y in 0..<gh {
            let y0 = max(0, y - half)
            let y1 = min(gh, y + half + 1)
            for x in 0..<gw {
                let x0 = max(0, x - half)
                let x1 = min(gw, x + half + 1)
                let sum = integral[y1 * stride + x1] - integral[y0 * stride + x1] - integral[y1 * stride + x0] + integral[y0 * stride + x0]
                let n = (x1 - x0) * (y1 - y0)
                // dark when under 80 percent of the neighbourhood's mean
                mask[y * gw + x] = gray[y * gw + x] * n * 100 < sum * 80 ? 1 : 0
            }
        }
    }

    // MARK: 2. blobs

    private func find(_ a: Int) -> Int {
        var x = a
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }

    private func union(_ a: Int, _ b: Int) {
        let ra = find(a)
        let rb = find(b)
        if ra != rb {
            if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
        }
    }

    private func label() {
        var next = 1
        parent[0] = 0
        for y in 0..<gh {
            for x in 0..<gw {
                let i = y * gw + x
                if mask[i] == 0 {
                    labels[i] = 0
                    continue
                }
                let left = x > 0 ? labels[i - 1] : 0
                let up = y > 0 ? labels[i - gw] : 0
                if left == 0 && up == 0 {
                    if next >= parent.count { parent += [Int](repeating: 0, count: parent.count) }
                    parent[next] = next
                    labels[i] = next
                    next += 1
                } else if left != 0 && up != 0 {
                    labels[i] = min(left, up)
                    if left != up { union(left, up) }
                } else {
                    labels[i] = left != 0 ? left : up
                }
            }
        }
        var compact = [Int](repeating: -1, count: next)
        compCount = 0
        if next > 1 {
            for l in 1..<next {
                let r = find(l)
                if compact[r] < 0 {
                    compact[r] = compCount
                    compCount += 1
                    if compCount > cArea.count { growStats() }
                    let c = compact[r]
                    cArea[c] = 0; cMinX[c] = Int.max; cMaxX[c] = -1; cMinY[c] = Int.max; cMaxY[c] = -1
                    cSumX[c] = 0.0; cSumY[c] = 0.0
                }
            }
        }
        for y in 0..<gh {
            for x in 0..<gw {
                let i = y * gw + x
                let l = labels[i]
                if l == 0 { continue }
                let c = compact[find(l)]
                labels[i] = c + 1 // 1-based component id from here on
                cArea[c] += 1
                if x < cMinX[c] { cMinX[c] = x }
                if x > cMaxX[c] { cMaxX[c] = x }
                if y < cMinY[c] { cMinY[c] = y }
                if y > cMaxY[c] { cMaxY[c] = y }
                cSumX[c] += Double(x) + 0.5
                cSumY[c] += Double(y) + 0.5
            }
        }
    }

    private func growStats() {
        let extra = cArea.count
        cArea += [Int](repeating: 0, count: extra); cMinX += [Int](repeating: 0, count: extra); cMaxX += [Int](repeating: 0, count: extra)
        cMinY += [Int](repeating: 0, count: extra); cMaxY += [Int](repeating: 0, count: extra)
        cSumX += [Double](repeating: 0, count: extra); cSumY += [Double](repeating: 0, count: extra)
    }

    @inline(__always) private func blobX(_ c: Int) -> Double { cSumX[c] / Double(cArea[c]) }
    @inline(__always) private func blobY(_ c: Int) -> Double { cSumY[c] / Double(cArea[c]) }

    // MARK: The outline and the affine map

    /// The outline's ellipse: its centre and the 2x2 matrix that takes the unit disc to the outline's outer edge (working pixels).
    private struct Bezel {
        let cx: Double
        let cy: Double
        let a11: Double
        let a12: Double
        let a21: Double
        let a22: Double
        let comp: Int
    }

    private func spanMoments(_ c: Int) -> Bezel? {
        var area = 0.0
        var sx = 0.0
        var sy = 0.0
        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        let id = c + 1
        for y in cMinY[c]...cMaxY[c] {
            var lo = -1
            var hi = -1
            let row = y * gw
            var x = cMinX[c]
            while x <= cMaxX[c] { if labels[row + x] == id { lo = x; break }; x += 1 }
            if lo < 0 { continue }
            x = cMaxX[c]
            while x >= lo { if labels[row + x] == id { hi = x; break }; x -= 1 }
            let len = Double(hi - lo + 1)
            let x0 = Double(lo)
            let x1 = Double(hi) + 1.0 // the span covers [x0, x1)
            let yc = Double(y) + 0.5
            area += len
            sx += len * (x0 + x1) / 2.0
            sy += len * yc
            sxx += (x1 * x1 * x1 - x0 * x0 * x0) / 3.0
            syy += len * (yc * yc + 1.0 / 12.0)
            sxy += yc * len * (x0 + x1) / 2.0
        }
        if area < 200.0 { return nil }
        let mx = sx / area
        let my = sy / area
        let cxx = sxx / area - mx * mx
        let cyy = syy / area - my * my
        let cxy = sxy / area - mx * my
        let det = cxx * cyy - cxy * cxy
        if det <= 1.0 { return nil }
        let ratio = area / (4.0 * Double.pi * det.squareRoot())
        if ratio < 0.88 || ratio > 1.12 { return nil }
        // symmetric square root of the covariance: (C + s I) / t with s = sqrt(det), t = sqrt(trace + 2 s)
        let s = det.squareRoot()
        let t = (cxx + cyy + 2.0 * s).squareRoot()
        let r11 = (cxx + s) / t
        let r12 = cxy / t
        let r22 = (cyy + s) / t
        return Bezel(cx: mx, cy: my, a11: 2.0 * r11, a12: 2.0 * r12, a21: 2.0 * r12, a22: 2.0 * r22, comp: c)
    }

    /// The outline when part of it is hidden (a smudge, a glare patch): the blob is an open arc, so its filled shape is no
    /// ellipse. Fit a conic to the arc's own pixels (a x^2 + b xy + c y^2 + d x + e y = 1, in coordinates centred on the blob and
    /// scaled to its size) and take the ellipse of the arc's centre line, scaled to the outer edge. Needs the arc to cover a
    /// good part of the turn.
    private func arcFit(_ c: Int) -> Bezel? {
        let bw = cMaxX[c] - cMinX[c] + 1
        let bh = cMaxY[c] - cMinY[c] + 1
        let fill = Double(cArea[c]) / Double(bw * bh)
        if fill > 0.30 || cArea[c] < 60 { return nil }
        let id = c + 1
        let mx0 = cSumX[c] / Double(cArea[c])
        let my0 = cSumY[c] / Double(cArea[c])
        let scale = Double(max(bw, bh))
        let step = max(1, cArea[c] / 1500)
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 5), count: 5)
        var atb = [Double](repeating: 0, count: 5)
        var row = [Double](repeating: 0, count: 5)
        var seen = 0
        var n = 0
        for y in cMinY[c]...cMaxY[c] {
            for x in cMinX[c]...cMaxX[c] {
                if labels[y * gw + x] != id { continue }
                let take = seen % step == 0
                seen += 1
                if !take { continue }
                let u = (Double(x) + 0.5 - mx0) / scale
                let v = (Double(y) + 0.5 - my0) / scale
                row[0] = u * u; row[1] = u * v; row[2] = v * v; row[3] = u; row[4] = v
                for i in 0..<5 {
                    for j in 0..<5 { ata[i][j] += row[i] * row[j] }
                    atb[i] += row[i]
                }
                n += 1
            }
        }
        if n < 40 { return nil }
        // a short arc cannot tell an ellipse from a circle: pull the fit toward a circle (a = c, b = 0)
        let prior = Double(n) * 0.35
        let pa: [Double] = [1.0, 0.0, -1.0, 0.0, 0.0]
        for i in 0..<5 { for j in 0..<5 { ata[i][j] += prior * pa[i] * pa[j] } }
        ata[1][1] += prior
        guard let sol = gauss(ata, atb, 5) else { return nil }
        let qa = sol[0]
        let qb = sol[1] / 2.0
        let qc = sol[2]
        let det = qa * qc - qb * qb
        if det <= 1e-12 || qa <= 0.0 { return nil }
        // centre: M c0 = -(d, e) / 2
        let c0u = -(qc * sol[3] / 2.0 - qb * sol[4] / 2.0) / det
        let c0v = -(-qb * sol[3] / 2.0 + qa * sol[4] / 2.0) / det
        let k = 1.0 + (qa * c0u * c0u + 2.0 * qb * c0u * c0v + qc * c0v * c0v)
        if k <= 1e-9 { return nil }
        // shape matrix S = M / k; unit circle -> ellipse is S^(-1/2)
        let s11 = qa / k
        let s12 = qb / k
        let s22 = qc / k
        let sdet = s11 * s22 - s12 * s12
        if sdet <= 1e-12 { return nil }
        // S^(-1/2) = (S^(-1))^(1/2); S^(-1) = [[s22, -s12], [-s12, s11]] / sdet
        let i11 = s22 / sdet
        let i12 = -s12 / sdet
        let i22 = s11 / sdet
        let idet = i11 * i22 - i12 * i12
        let rs = idet.squareRoot()
        let rt = (i11 + i22 + 2.0 * rs).squareRoot()
        let a11 = (i11 + rs) / rt
        let a12 = i12 / rt
        let a22 = (i22 + rs) / rt
        let centreLine = Double(RingCodeLayout.bezelInner + RingCodeLayout.bezelOuter) / 2.0
        let grow = Double(RingCodeLayout.bezelOuter) / centreLine
        let m11 = a11 * scale * grow
        let m12 = a12 * scale * grow
        let m22 = a22 * scale * grow
        let centreX = mx0 + c0u * scale
        let centreY = my0 + c0v * scale
        // sanity: ellipse not wild, and the arc's pixels sit on it
        let ev = abs(m11 * m22 - m12 * m12).squareRoot()
        if ev < 14.0 || ev > Double(min(gw, gh)) * 0.5 { return nil }
        let tr = m11 * m11 + 2 * m12 * m12 + m22 * m22
        let disc = max(0.0, tr * tr - 4.0 * ev * ev * ev * ev).squareRoot()
        let l1 = (tr + disc) / 2.0
        let l2 = (tr - disc) / 2.0
        if l2 <= 1e-9 || (l1 / l2).squareRoot() > 1.8 { return nil }
        // residual along the arc, and angular coverage
        let det2 = m11 * m22 - m12 * m12
        let inv11 = m22 / det2
        let inv12 = -m12 / det2
        let inv21 = -m12 / det2
        let inv22 = m11 / det2
        var err = 0.0
        var bins = [Bool](repeating: false, count: 12)
        var m = 0
        seen = 0
        for y in cMinY[c]...cMaxY[c] {
            for x in cMinX[c]...cMaxX[c] {
                if labels[y * gw + x] != id { continue }
                let take = seen % step == 0
                seen += 1
                if !take { continue }
                let px = Double(x) + 0.5 - centreX
                let py = Double(y) + 0.5 - centreY
                let ux = inv11 * px + inv12 * py
                let uy = inv21 * px + inv22 * py
                let r = (ux * ux + uy * uy).squareRoot() * Double(RingCodeLayout.bezelOuter)
                err += abs(r - centreLine)
                var a = atan2(uy, ux)
                if a < 0 { a += 2.0 * Double.pi }
                bins[min(11, ringInt(a / (2.0 * Double.pi) * 12.0))] = true
                m += 1
            }
        }
        if m == 0 { return nil }
        if err / Double(m) > 22.0 { return nil } // mean distance from the centre line over 22 permille: not our ring
        if bins.reduce(0, { $0 + ($1 ? 1 : 0) }) < 5 { return nil }
        return Bezel(cx: centreX, cy: centreY, a11: m11, a12: m12, a21: m12, a22: m22, comp: c)
    }

    /// The share of the blob's pixels that lie in the outline's band (the ring, 35 permille either side) under this ellipse.
    private func ringFitness(_ b: Bezel, _ c: Int) -> Double {
        let inv = invAffine(b)
        let id = c + 1
        let step = max(1, cArea[c] / 1500)
        var seen = 0
        var inBand = 0
        var n = 0
        for y in cMinY[c]...cMaxY[c] {
            for x in cMinX[c]...cMaxX[c] {
                if labels[y * gw + x] != id { continue }
                let take = seen % step == 0
                seen += 1
                if !take { continue }
                let px = Double(x) + 0.5 - b.cx
                let py = Double(y) + 0.5 - b.cy
                let ex = inv[0] * px + inv[1] * py
                let ey = inv[2] * px + inv[3] * py
                let r = (ex * ex + ey * ey).squareRoot() * Double(RingCodeLayout.bezelOuter)
                n += 1
                if r >= Double(RingCodeLayout.bezelInner) - 35.0 && r <= Double(RingCodeLayout.bezelOuter) + 35.0 { inBand += 1 }
            }
        }
        return n == 0 ? 0.0 : Double(inBand) / Double(n)
    }

    /// The outlines worth trying, best first (at most `maxOutlines`): per large round blob the moments fit and the arc fit, each
    /// kept when it explains the blob and has dot-sized blobs where the rings would be.
    private func findBezels() -> [Bezel] {
        let limit = min(gw, gh)
        var ids: [Int] = []
        for c in 0..<compCount {
            let bw = cMaxX[c] - cMinX[c] + 1
            let bh = cMaxY[c] - cMinY[c] + 1
            if min(bw, bh) < 36 || max(bw, bh) > limit * 98 / 100 { continue }
            if Double(max(bw, bh)) / Double(min(bw, bh)) > 2.1 { continue }
            let fill = Double(cArea[c]) / Double(bw * bh)
            if fill < 0.05 || fill > 0.86 { continue }
            ids.append(c)
        }
        ids.sort { cArea[$0] != cArea[$1] ? cArea[$0] > cArea[$1] : $0 < $1 }
        if let trace {
            for c in ids.prefix(6) { trace("blob \(c) box=\(cMaxX[c] - cMinX[c] + 1)x\(cMaxY[c] - cMinY[c] + 1) area=\(cArea[c])") }
        }
        var found: [Bezel] = []
        var scores: [Double] = []
        for c in ids.prefix(6) {
            var candidates: [(Bezel, String)] = []
            if let m = spanMoments(c), ringFitness(m, c) >= 0.9 { candidates.append((m, "moments")) }
            if let a = arcFit(c), ringFitness(a, c) >= 0.8 { candidates.append((a, "arc")) }
            for (bezel, kind) in candidates {
                let score = scoreCandidate(bezel)
                trace?("outline \(kind) centre=(\(bezel.cx),\(bezel.cy)) score=\(score)")
                diagnostics.candidates += 1
                if score >= 20.0 {
                    found.append(bezel)
                    scores.append(score)
                }
            }
        }
        let order = found.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
        return order.prefix(Self.maxOutlines).map { found[$0] }
    }

    private func invAffine(_ b: Bezel) -> [Double] {
        let det = b.a11 * b.a22 - b.a12 * b.a21
        return [b.a22 / det, -b.a12 / det, -b.a21 / det, b.a11 / det]
    }

    /// How many dot-sized blobs sit where the rings are, if this outline is the plate's.
    private func scoreCandidate(_ b: Bezel) -> Double {
        let inv = invAffine(b)
        let sc = abs(b.a11 * b.a22 - b.a12 * b.a21).squareRoot() / Double(RingCodeLayout.bezelOuter)
        let smallA = Double.pi * Double(RingCodeLayout.smallRadius * RingCodeLayout.smallRadius) * sc * sc
        let bigA = Double.pi * Double(RingCodeLayout.bigRadius * RingCodeLayout.bigRadius) * sc * sc
        var inRings = 0
        for c in 0..<compCount {
            if c == b.comp { continue }
            let a = Double(cArea[c])
            if a < smallA * 0.3 || a > bigA * 2.6 { continue }
            let px = cSumX[c] / a - b.cx
            let py = cSumY[c] / a - b.cy
            let ux = inv[0] * px + inv[1] * py
            let uy = inv[2] * px + inv[3] * py
            let rho = (ux * ux + uy * uy).squareRoot() * Double(RingCodeLayout.bezelOuter)
            if rho >= 380.0 && rho <= 850.0 { inRings += 1 }
        }
        return Double(inRings)
    }

    // MARK: 3. the code

    private func readCode(_ frame: RingFrame, _ bezel: Bezel) -> RingScanResult {
        let f = diagnostics.scale
        let sc = abs(bezel.a11 * bezel.a22 - bezel.a12 * bezel.a21).squareRoot() / Double(RingCodeLayout.bezelOuter)
        diagnostics.found = true
        diagnostics.centreX = bezel.cx * Double(f)
        diagnostics.centreY = bezel.cy * Double(f)
        diagnostics.bezelRadiusPx = sc * Double(RingCodeLayout.bezelOuter) * Double(f)
        let inv = invAffine(bezel)

        var dotIds = [Int](repeating: 0, count: compCount)
        var nd = 0
        let smallA = Double.pi * Double(RingCodeLayout.smallRadius * RingCodeLayout.smallRadius) * sc * sc
        let bigA = Double.pi * Double(RingCodeLayout.bigRadius * RingCodeLayout.bigRadius) * sc * sc
        for c in 0..<compCount {
            if c == bezel.comp { continue }
            let a = Double(cArea[c])
            if a >= smallA * 0.3 && a <= bigA * 2.8 {
                dotIds[nd] = c
                nd += 1
            }
        }
        if nd < 40 { return .failed(.tooFewDots) }

        let marker = findMarker(bezel, inv, sc, frame)
        var markerFailure: RingScanResult?
        if let marker {
            diagnostics.markerFound = true
            diagnostics.markerX = blobX(marker) * Double(f)
            diagnostics.markerY = blobY(marker) * Double(f)
            // the start dot's direction in unit-disc coordinates gives the rotation
            let mx = blobX(marker) - bezel.cx
            let my = blobY(marker) - bezel.cy
            let psi = atan2(inv[0] * mx + inv[1] * my, -(inv[2] * mx + inv[3] * my))
            let first = fitAndDecode(bezel, sc, psi, marker, dotIds, nd)
            if first.isDecoded { return first }
            // A blob that is not the start dot can pass for one (the real one smudged, a stray dot beyond the rings).
            // The positions of the dots fit the plate in eight turns, so the blind search below still finds the code.
            markerFailure = first
        }
        // The start dot is hidden. The dots alone fit the plate in eight turns (every ring size divides by 8), so find the
        // 45 degree class that matches best and try each of its eight turns until one decodes.
        var bestPsi = 0.0
        var bestCost = Double.greatestFiniteMagnitude
        let coarse = 30
        for i in 0..<coarse {
            let psi = Double(i) * (Double.pi / 4.0) / Double(coarse)
            let cost = stage0Cost(affineFor(bezel, psi), sc, dotIds, nd)
            if cost < bestCost {
                bestCost = cost
                bestPsi = psi
            }
        }
        let centre = bestPsi
        for i in -10...10 {
            let psi = centre + Double(i) * (Double.pi / 4.0 / Double(coarse)) / 10.0
            let cost = stage0Cost(affineFor(bezel, psi), sc, dotIds, nd)
            if cost < bestCost {
                bestCost = cost
                bestPsi = psi
            }
        }
        let bestHits = ringInt(60.0 * (1.0 - bestCost))
        if bestCost > 0.55 { return markerFailure ?? .failed(.noMarker) }
        var last: RingScanResult = markerFailure ?? .failed(.noMarker)
        for k in 0..<8 {
            let r = fitAndDecode(bezel, sc, bestPsi + Double(k) * Double.pi / 4.0, -1, dotIds, nd)
            if let trace {
                trace("blind turn \(k) hits=\(bestHits) matched=\(diagnostics.matched) resid=\(diagnostics.residualPx)")
            }
            if r.isDecoded { return r }
            if case .failed(let reason) = r, reason == .unreadable || reason == .badChecksum { last = r }
        }
        if case .failed(let reason) = last, reason != .noMarker { return last }
        return .failed(.noMarker)
    }

    private func affineFor(_ bezel: Bezel, _ psi: Double) -> [Double] {
        let cp = cos(psi)
        let sp = sin(psi)
        // plate permille -> working pixels: p = c + A * R(psi) * q / bezelOuter
        let k = 1.0 / Double(RingCodeLayout.bezelOuter)
        return [
            (bezel.a11 * cp + bezel.a12 * sp) * k, (-bezel.a11 * sp + bezel.a12 * cp) * k, bezel.cx,
            (bezel.a21 * cp + bezel.a22 * sp) * k, (-bezel.a21 * sp + bezel.a22 * cp) * k, bezel.cy,
            0.0, 0.0, 1.0,
        ]
    }

    /// The mean distance (as a share of the matching tolerance, at most 1) from the slots of rings 0 and 1 to the nearest dot blob under the affine map `h`.
    private func stage0Cost(_ h: [Double], _ sc: Double, _ dotIds: [Int], _ nd: Int) -> Double {
        let tol = 0.46 * 90.0 * sc
        var sum = 0.0
        let count = RingCodeLayout.ringFirstSlot[2]
        for slot in 0..<count {
            let px = project(h, qx[slot], qy[slot], 0)
            let py = project(h, qx[slot], qy[slot], 1)
            var best = tol * tol
            for i in 0..<nd {
                let c = dotIds[i]
                let dx = blobX(c) - px
                let dy = blobY(c) - py
                let dd = dx * dx + dy * dy
                if dd < best { best = dd }
            }
            sum += best.squareRoot() / tol
        }
        return sum / Double(count)
    }

    /// Matches, fits (ring by ring) and reads the code for one assumed rotation; `marker` is the start dot's blob, or -1 when it is hidden.
    private func fitAndDecode(_ bezel: Bezel, _ sc: Double, _ psi: Double, _ marker: Int, _ dotIds: [Int], _ nd: Int) -> RingScanResult {
        let f = diagnostics.scale
        var h = affineFor(bezel, psi)
        var matchSlot = [Int](repeating: 0, count: RingCodeLayout.slots + 1)
        var matchBlob = [Int](repeating: 0, count: RingCodeLayout.slots + 1)
        var used = [Int](repeating: -1, count: compCount)
        var matched = 0
        // Five steps: rings 0..1 twice (affine; the first with a wide net, in case the outline was found a little off),
        // then 0..2, 0..3, and finally everything plus the start dot (homography).
        for stage in 0..<5 {
            let maxRing = Self.stageRings[stage]
            let tolPx = Self.stageTolerance[stage] * 90.0 * sc
            matched = 0
            for i in 0..<used.count { used[i] = -1 }
            for slot in 0...RingCodeLayout.slots {
                if slot < RingCodeLayout.slots && RingCodeLayout.ringOf(slot) > maxRing { continue }
                if slot == RingCodeLayout.slots && (stage < 4 || marker < 0) { continue }
                let px = project(h, qx[slot], qy[slot], 0)
                let py = project(h, qx[slot], qy[slot], 1)
                var bestBlob = -1
                var bestD = tolPx
                for i in 0..<nd {
                    let c = dotIds[i]
                    let dx = blobX(c) - px
                    let dy = blobY(c) - py
                    let dd = (dx * dx + dy * dy).squareRoot()
                    if dd < bestD {
                        bestD = dd
                        bestBlob = c
                    }
                }
                if slot == RingCodeLayout.slots && marker >= 0 && bestBlob != marker {
                    // the start dot is not in the dot list when it is bigger than a big dot: use its own blob
                    let dx = blobX(marker) - px
                    let dy = blobY(marker) - py
                    if (dx * dx + dy * dy).squareRoot() < tolPx { bestBlob = marker }
                }
                if bestBlob < 0 { continue }
                let prev = used[bestBlob]
                if prev >= 0 {
                    // two slots want one blob (merged dots): keep the nearer one
                    let dx = blobX(bestBlob) - project(h, qx[prev], qy[prev], 0)
                    let dy = blobY(bestBlob) - project(h, qx[prev], qy[prev], 1)
                    if (dx * dx + dy * dy).squareRoot() <= bestD { continue }
                    for m in 0..<matched where matchSlot[m] == prev {
                        matchSlot[m] = matchSlot[matched - 1]
                        matchBlob[m] = matchBlob[matched - 1]
                        matched -= 1
                        break
                    }
                }
                used[bestBlob] = slot
                matchSlot[matched] = slot
                matchBlob[matched] = bestBlob
                matched += 1
            }
            if matched < 12 { return .failed(.tooFewDots) }
            guard let fit = fitHomography(matchSlot, matchBlob, matched, stage < 2 ? 6 : 8) else { return .failed(.tooFewDots) }
            h = fit
        }
        diagnostics.matched = matched
        if matched < 60 { return .failed(.tooFewDots) }
        var resid = 0.0
        for m in 0..<matched {
            let s = matchSlot[m]
            let dx = blobX(matchBlob[m]) - project(h, qx[s], qy[s], 0)
            let dy = blobY(matchBlob[m]) - project(h, qx[s], qy[s], 1)
            resid += (dx * dx + dy * dy).squareRoot()
        }
        diagnostics.residualPx = resid / Double(matched) * Double(f)
        // diagnostics report frame pixels: scale the image-space rows by f
        for i in 0..<9 { diagnostics.homography[i] = h[i] }
        for i in 0..<6 { diagnostics.homography[i] = h[i] * Double(f) }

        measure(h)
        return decode()
    }

    @inline(__always)
    private func project(_ h: [Double], _ x: Double, _ y: Double, _ axis: Int) -> Double {
        let w = h[6] * x + h[7] * y + h[8]
        return axis == 0 ? (h[0] * x + h[1] * y + h[2]) / w : (h[3] * x + h[4] * y + h[5]) / w
    }

    /// The start dot: the dot-sized blob out beyond the outer ring, nearest the right size, helped by its colour.
    private func findMarker(_ bezel: Bezel, _ inv: [Double], _ sc: Double, _ frame: RingFrame) -> Int? {
        let markerA = Double.pi * Double(RingCodeLayout.markerRadius * RingCodeLayout.markerRadius) * sc * sc
        var best = -1
        var bestScore = 0.0
        for c in 0..<compCount {
            if c == bezel.comp { continue }
            let a = Double(cArea[c])
            if a < markerA * 0.4 || a > markerA * 2.4 { continue }
            let px = cSumX[c] / a - bezel.cx
            let py = cSumY[c] / a - bezel.cy
            let ux = inv[0] * px + inv[1] * py
            let uy = inv[2] * px + inv[3] * py
            let rho = (ux * ux + uy * uy).squareRoot() * Double(RingCodeLayout.bezelOuter)
            if rho < 842.0 || rho > 960.0 { continue }
            let bw = cMaxX[c] - cMinX[c] + 1
            let bh = cMaxY[c] - cMinY[c] + 1
            if Double(max(bw, bh)) > 2.6 * Double(min(bw, bh)) { continue }
            var score = min(a, markerA) / max(a, markerA)
            score *= 1.0 - abs(rho - Double(RingCodeLayout.markerRadiusAt)) / 300.0
            if let hue = frame.hue {
                let hx = min(max(ringInt((cSumX[c] / a) * Double(diagnostics.scale) * Double(frame.hueWidth) / Double(frame.width)), 0), frame.hueWidth - 1)
                let hy = min(max(ringInt((cSumY[c] / a) * Double(diagnostics.scale) * Double(frame.hueHeight) / Double(frame.height)), 0), frame.hueHeight - 1)
                let index = hy * frame.hueWidth + hx
                if index >= 0 && index < hue.count { score *= 1.0 + Double(hue[index]) / 255.0 }
            }
            if score > bestScore {
                bestScore = score
                best = c
            }
        }
        return best >= 0 && bestScore > 0.25 ? best : nil
    }

    /// Least-squares fit of the matched slots' plate coordinates to their blob centroids. `dof` 6 fits an affine map, 8 a
    /// homography. Drops matches further than 2.5 times the median residual and fits once more.
    private func fitHomography(_ slots: [Int], _ blobs: [Int], _ n: Int, _ dof: Int) -> [Double]? {
        guard var h = solve(slots, blobs, n, dof, nil) else { return nil }
        var residuals = [Double](repeating: 0, count: n)
        for m in 0..<n {
            let s = slots[m]
            let dx = blobX(blobs[m]) - project(h, qx[s], qy[s], 0)
            let dy = blobY(blobs[m]) - project(h, qx[s], qy[s], 1)
            residuals[m] = (dx * dx + dy * dy).squareRoot()
        }
        let sorted = residuals.sorted()
        let cut = max(1.2, 2.5 * sorted[n / 2])
        var keep = [Bool](repeating: false, count: n)
        var kept = 0
        for m in 0..<n {
            keep[m] = residuals[m] <= cut
            if keep[m] { kept += 1 }
        }
        if kept >= dof + 2 && kept < n { h = solve(slots, blobs, n, dof, keep) ?? h }
        return h
    }

    private func solve(_ slots: [Int], _ blobs: [Int], _ n: Int, _ dof: Int, _ keep: [Bool]?) -> [Double]? {
        // normalise: plate coordinates / 1000; pixel coordinates relative to their mean and divided by their spread
        var mu = 0.0
        var mv = 0.0
        var cnt = 0
        for m in 0..<n {
            if let keep, !keep[m] { continue }
            mu += blobX(blobs[m])
            mv += blobY(blobs[m])
            cnt += 1
        }
        if cnt < dof / 2 + 2 { return nil }
        mu /= Double(cnt)
        mv /= Double(cnt)
        var spread = 0.0
        for m in 0..<n {
            if let keep, !keep[m] { continue }
            let u = blobX(blobs[m]) - mu
            let v = blobY(blobs[m]) - mv
            spread += u * u + v * v
        }
        spread = (spread / Double(cnt)).squareRoot()
        if spread < 1e-6 { return nil }
        let size = dof == 8 ? 8 : 6
        var ata = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
        var atb = [Double](repeating: 0, count: size)
        var row = [Double](repeating: 0, count: size)
        func add(_ rhs: Double) {
            for i in 0..<size {
                if row[i] == 0.0 { continue }
                for j in 0..<size { ata[i][j] += row[i] * row[j] }
                atb[i] += row[i] * rhs
            }
        }
        for m in 0..<n {
            if let keep, !keep[m] { continue }
            let s = slots[m]
            let x = qx[s] / 1000.0
            let y = qy[s] / 1000.0
            let u = (blobX(blobs[m]) - mu) / spread
            let v = (blobY(blobs[m]) - mv) / spread
            for i in 0..<size { row[i] = 0.0 }
            row[0] = x; row[1] = y; row[2] = 1.0
            if dof == 8 { row[6] = -u * x; row[7] = -u * y }
            add(u)
            for i in 0..<size { row[i] = 0.0 }
            row[3] = x; row[4] = y; row[5] = 1.0
            if dof == 8 { row[6] = -v * x; row[7] = -v * y }
            add(v)
        }
        guard let sol = gauss(ata, atb, size) else { return nil }
        var g = [Double](repeating: 0, count: 9)
        for i in 0..<size { g[i] = sol[i] }
        g[8] = 1.0
        // undo the normalisation: pixel = (mu, mv) + spread * (u, v), and plate permille / 1000 = x
        let a0 = g[0] / 1000.0, a1 = g[1] / 1000.0, a2 = g[2]
        let b0 = g[3] / 1000.0, b1 = g[4] / 1000.0, b2 = g[5]
        let c0 = g[6] / 1000.0, c1 = g[7] / 1000.0, c2 = g[8]
        return [
            spread * a0 + mu * c0, spread * a1 + mu * c1, spread * a2 + mu * c2,
            spread * b0 + mv * c0, spread * b1 + mv * c1, spread * b2 + mv * c2,
            c0, c1, c2,
        ]
    }

    private func gauss(_ a: [[Double]], _ b: [Double], _ n: Int) -> [Double]? {
        var m = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for i in 0..<n { for j in 0...n { m[i][j] = j < n ? a[i][j] : b[i] } }
        for col in 0..<n {
            var piv = col
            if col + 1 < n { for r in (col + 1)..<n where abs(m[r][col]) > abs(m[piv][col]) { piv = r } }
            if abs(m[piv][col]) < 1e-12 { return nil }
            m.swapAt(col, piv)
            if col + 1 < n {
                for r in (col + 1)..<n {
                    let f = m[r][col] / m[col][col]
                    if f == 0.0 { continue }
                    for c in col...n { m[r][c] -= f * m[col][c] }
                }
            }
        }
        var x = [Double](repeating: 0, count: n)
        var r = n - 1
        while r >= 0 {
            var s = m[r][n]
            if r + 1 < n { for c in (r + 1)..<n { s -= m[r][c] * x[c] } }
            x[r] = s / m[r][r]
            r -= 1
        }
        return x
    }

    // MARK: 4. measure

    private func invert3(_ h: [Double]) -> [Double]? {
        let a = h[0], b = h[1], c = h[2]
        let d = h[3], e = h[4], f = h[5]
        let g = h[6], hh = h[7], i = h[8]
        let det = a * (e * i - f * hh) - b * (d * i - f * g) + c * (d * hh - e * g)
        if abs(det) < 1e-18 { return nil }
        let inv = 1.0 / det
        return [
            (e * i - f * hh) * inv, (c * hh - b * i) * inv, (b * f - c * e) * inv,
            (f * g - d * i) * inv, (a * i - c * g) * inv, (c * d - a * f) * inv,
            (d * hh - e * g) * inv, (b * g - a * hh) * inv, (a * e - b * d) * inv,
        ]
    }

    private static let windowRadius = 50.0

    /// The dot is measured inside this radius (permille); the ring of plate around it, from `annulusFrom` to the window radius,
    /// says how light the plate is right there.
    private static let dotRadius = 41.0
    private static let annulusFrom = 44.0

    private func measure(_ h: [Double]) {
        for i in 0..<slotMass.count { slotMass[i] = 0.0 }
        guard let inv = invert3(h) else { return }
        for i in 0..<hist.count { hist[i] = 0 }
        let r2 = Self.windowRadius * Self.windowRadius
        // pass 1: the plate's light and dark levels, from the pixels inside the slot windows
        for slot in 0..<RingCodeLayout.slots {
            let cx = project(h, qx[slot], qy[slot], 0)
            let cy = project(h, qx[slot], qy[slot], 1)
            slotCx[slot] = cx
            slotCy[slot] = cy
            forWindow(h, inv, slot, cx, cy, r2) { x, y, _ in hist[gray[y * gw + x]] += 1 }
        }
        var total = 0
        for v in hist { total += v }
        if total < 100 { return }
        var acc = 0
        var fg = 0
        var bg = 255
        var gotFg = false
        for v in 0...255 {
            acc += hist[v]
            if !gotFg && acc * 100 >= total * 8 {
                fg = v
                gotFg = true
            }
            if acc * 100 >= total * 92 {
                bg = v
                break
            }
        }
        if bg - fg < 24 { return }
        let dotR2 = Self.dotRadius * Self.dotRadius
        let annR2 = Self.annulusFrom * Self.annulusFrom
        let darkShare = 1.0 - Double(fg) / Double(bg)
        for slot in 0..<RingCodeLayout.slots {
            var dotSum = 0
            var dotCount = 0
            var annSum = 0
            var annCount = 0
            forWindow(h, inv, slot, slotCx[slot], slotCy[slot], r2) { x, y, d2 in
                let g = gray[y * gw + x]
                if d2 <= dotR2 {
                    dotSum += g
                    dotCount += 1
                } else if d2 >= annR2 {
                    annSum += g
                    annCount += 1
                }
            }
            if dotCount == 0 || annCount == 0 { continue }
            // The plate's own level right at this dot (a smudge, a gradient or a glare edge moves it), and how far under it the
            // dot's pixels sit, in units of a full dot's depth at that level. A dot hidden under an opaque smudge has the
            // smudge's level all round it and reads as no dot at all.
            let local = Double(annSum) / Double(annCount)
            let depth = local * darkShare
            if depth < 12.0 { continue }
            var mass = 0.0
            forWindow(h, inv, slot, slotCx[slot], slotCy[slot], dotR2) { x, y, _ in
                mass += min(1.0, max(0.0, (local - Double(gray[y * gw + x])) / depth))
            }
            slotMass[slot] = mass / Double(dotCount) * Double.pi * dotR2
        }
    }

    private func forWindow(_ h: [Double], _ inv: [Double], _ slot: Int, _ cx: Double, _ cy: Double, _ r2: Double,
                           _ body: (Int, Int, Double) -> Void) {
        let rr = r2.squareRoot()
        let ex = project(h, qx[slot] + rr, qy[slot], 0) - cx
        let ey = project(h, qx[slot] + rr, qy[slot], 1) - cy
        let fx = project(h, qx[slot], qy[slot] + rr, 0) - cx
        let fy = project(h, qx[slot], qy[slot] + rr, 1) - cy
        let hx = abs(ex) + abs(fx) + 1.5
        let hy = abs(ey) + abs(fy) + 1.5
        let x0 = max(0, ringInt(cx - hx))
        let x1 = min(gw - 1, ringInt(cx + hx))
        let y0 = max(0, ringInt(cy - hy))
        let y1 = min(gh - 1, ringInt(cy + hy))
        if x0 > x1 || y0 > y1 { return }
        let qxs = qx[slot]
        let qys = qy[slot]
        for y in y0...y1 {
            for x in x0...x1 {
                let px = Double(x) + 0.5
                let py = Double(y) + 0.5
                let w = inv[6] * px + inv[7] * py + inv[8]
                let ux = (inv[0] * px + inv[1] * py + inv[2]) / w - qxs
                let uy = (inv[3] * px + inv[4] * py + inv[5]) / w - qys
                let d2 = ux * ux + uy * uy
                if d2 <= r2 { body(x, y, d2) }
            }
        }
    }

    // MARK: 5. decode

    private func decode() -> RingScanResult {
        let smallM = Double.pi * Double(RingCodeLayout.smallRadius) * Double(RingCodeLayout.smallRadius)
        let bigM = Double.pi * Double(RingCodeLayout.bigRadius) * Double(RingCodeLayout.bigRadius)
        let globalT = twoMeans(0, RingCodeLayout.slots, smallM, bigM, (smallM + bigM) / 2.0)
        let gap = (bigM - smallM) / 2.0
        for ring in 0..<RingCodeLayout.rings {
            let first = RingCodeLayout.ringFirstSlot[ring]
            let n = RingCodeLayout.ringSlots[ring]
            let t = twoMeans(first, first + n, smallM, bigM, globalT)
            for s in first..<(first + n) {
                let m = slotMass[s]
                slotBit[s] = m > t ? 1 : 0
                var conf = abs(m - t) / gap
                if m < smallM * 0.3 { conf = 0.0 } // no dot at all (covered up): nothing is known
                if m > bigM * 1.25 { conf = 0.0 } // more dark than the biggest dot can make: nothing is known
                slotConf[s] = ringInt(min(1.0, conf) * 100.0)
            }
        }
        for s in 0..<RingCodeLayout.slots {
            diagnostics.slotBits[s] = slotBit[s]
            diagnostics.slotConfidence[s] = slotConf[s]
            diagnostics.slotMass[s] = slotMass[s]
        }
        let word = RingCodeLayout.slotsToCodeword(slotBit)
        var byteConf = [Int](repeating: 100, count: RingCodeLayout.bytes)
        for s in 0..<RingCodeLayout.slots {
            let b = RingCodeLayout.byteOfSlot(s)
            if slotConf[s] < byteConf[b] { byteConf[b] = slotConf[s] }
        }
        let order = (0..<RingCodeLayout.bytes).sorted { byteConf[$0] != byteConf[$1] ? byteConf[$0] < byteConf[$1] : $0 < $1 }
        var sawChecksumFailure = false
        for k in Self.erasureSteps {
            let rs = ReedSolomon.decode(word, erasures: Array(order.prefix(k)))
            guard rs.ok, let corrected = rs.codeword else { continue }
            switch RingCodePayloads.fromCodeword(corrected) {
            case .ok(let payload):
                diagnostics.rsCorrected = rs.corrected
                diagnostics.erasuresUsed = k
                return .decoded(payload: payload, corrected: rs.corrected, erasures: k)
            case .rejected:
                sawChecksumFailure = true
            }
        }
        return .failed(sawChecksumFailure ? .badChecksum : .unreadable)
    }

    /// Two-means on masses [from, to): the decision line between the two clusters, or `fallback` when the data does not show two.
    private func twoMeans(_ from: Int, _ to: Int, _ lowSeed: Double, _ highSeed: Double, _ fallback: Double) -> Double {
        var lo = lowSeed
        var hi = highSeed
        var t = (lo + hi) / 2.0
        for _ in 0..<8 {
            var sl = 0.0
            var nl = 0
            var sh = 0.0
            var nh = 0
            for s in from..<to {
                let m = slotMass[s]
                if m > t { sh += m; nh += 1 } else { sl += m; nl += 1 }
            }
            if nl > 0 { lo = sl / Double(nl) }
            if nh > 0 { hi = sh / Double(nh) }
            t = (lo + hi) / 2.0
        }
        if hi / max(lo, 1.0) < 1.8 { return fallback }
        let mid = (lowSeed + highSeed) / 2.0
        return min(max(t, mid * 0.6), mid * 1.5)
    }

    /// How many outlines are tried at most.
    private static let maxOutlines = 4
    /// How many of the least certain bytes are flagged as erasures, in the order they are tried. More than 10 is not tried.
    private static let erasureSteps = [0, 3, 5, 7, 10]
    private static let stageRings = [1, 1, 2, 3, 4]
    private static let stageTolerance = [0.46, 0.36, 0.40, 0.40, 0.40]
}

/// Collects scan results over time and accepts a code only after `required` consistent decodes: the same payload each time, with
/// no different decode in between and no gap longer than `maxGapMs` between two decodes. A frame that fails to decode neither
/// counts nor breaks the run (a blurred frame is not a disagreement), but it cannot keep a stale run alive past the gap.
public struct RingScanAccumulator: Sendable {
    private let required: Int
    private let maxGapMs: Int64
    private var last: RingCodePayload?
    private var count = 0
    private var lastAtMs: Int64 = 0

    public init(required: Int = 3, maxGapMs: Int64 = 2_000) {
        self.required = required
        self.maxGapMs = maxGapMs
    }

    /// The accepted payload once it has been seen `required` times in a row, else nil.
    public mutating func offer(_ result: RingScanResult, nowMs: Int64) -> RingCodePayload? {
        guard let p = result.payload else {
            if last != nil && nowMs - lastAtMs > maxGapMs { reset() }
            return nil
        }
        if last != nil && p == last && nowMs - lastAtMs <= maxGapMs {
            count += 1
        } else {
            last = p
            count = 1
        }
        lastAtMs = nowMs
        return count >= required ? p : nil
    }

    public mutating func reset() {
        last = nil
        count = 0
    }
}
