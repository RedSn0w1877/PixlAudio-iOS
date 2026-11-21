// The camera side of the ring scanner, as plain code over bytes (the Android `RingFrameBuilder.kt`): a frame's luma and chroma planes
// become the scanner's `RingFrame`, and a pacer decides how often the scanner may look. The app's AVFoundation glue only hands in the
// planes of a pixel buffer; everything with a decision in it is here, so it runs in the unit tests without a camera.

/// Turns a camera's planes (the luma plane and the U and V samples) into the scanner's `RingFrame`: the luma copied without its row
/// padding and, from the chroma samples, the coarse "orangeness" map the scanner uses to tell the start dot from an ordinary dark dot.
/// Both arrays are reused from frame to frame (they are reallocated only when the picture changes size), so a frame allocates nothing
/// beyond the small `RingFrame` wrapper as long as the previous frame has been let go. One instance belongs to one analysis queue.
public final class RingFrameBuilder {
    private var luma: [UInt8] = []
    private var hue: [UInt8] = []

    public init() {}

    /// 256 x 256 table of `RingHue.orangeness` by (U, V): one lookup per chroma sample instead of a division.
    private static let orangenessTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256 * 256)
        for u in 0..<256 {
            for v in 0..<256 { table[(u << 8) | v] = UInt8(RingHue.orangeness(u: u, v: v)) }
        }
        return table
    }()

    /// - Parameters:
    ///   - yRowStride: bytes from one luma row to the next (at least `width`).
    ///   - u / v: the chroma samples of a half-size grid (one sample per 2 x 2 pixels), read at `uvRowStride` bytes per row and
    ///     `uvPixelStride` bytes per sample. A biplanar camera buffer (Cb and Cr interleaved) passes the same plane twice, `v` one byte on.
    ///     Pass nil for either to leave the hue map out.
    public func build(width: Int, height: Int, y: UnsafeRawBufferPointer, yRowStride: Int,
                      u: UnsafeRawBufferPointer?, v: UnsafeRawBufferPointer?, uvRowStride: Int, uvPixelStride: Int) -> RingFrame {
        let need = width * height
        if luma.count != need { luma = [UInt8](repeating: 0, count: need) }
        luma.withUnsafeMutableBytes { out in
            guard let dst = out.baseAddress, let src = y.baseAddress else { return }
            if yRowStride == width && y.count >= need {
                dst.copyMemory(from: src, byteCount: need)
            } else {
                for row in 0..<height {
                    let from = row * yRowStride
                    // A row the plane does not hold is left as it was (never read past the end).
                    if from + width > y.count { break }
                    (dst + row * width).copyMemory(from: src + from, byteCount: width)
                }
            }
        }
        guard let u, let v else { return RingFrame(width: width, height: height, luma: luma) }
        let cw = (width + 1) / 2
        let ch = (height + 1) / 2
        if hue.count != cw * ch { hue = [UInt8](repeating: 0, count: cw * ch) }
        let table = Self.orangenessTable
        let uLimit = u.count
        let vLimit = v.count
        hue.withUnsafeMutableBufferPointer { out in
            table.withUnsafeBufferPointer { map in
                for cy in 0..<ch {
                    let rowBase = cy * uvRowStride
                    let outRow = cy * cw
                    for cx in 0..<cw {
                        let at = rowBase + cx * uvPixelStride
                        if at < uLimit && at < vLimit {
                            out[outRow + cx] = map[(Int(u[at]) << 8) | Int(v[at])]
                        } else {
                            out[outRow + cx] = 0
                        }
                    }
                }
            }
        }
        return RingFrame(width: width, height: height, luma: luma, hue: hue, hueWidth: cw, hueHeight: ch)
    }
}

extension RingFrameBuilder {
    /// A biplanar camera buffer (a luma plane and one plane of interleaved Cb, Cr pairs: the camera's usual 4:2:0 layout): Cb is the
    /// plane's first byte of every pair, Cr the second.
    public func buildBiplanar(width: Int, height: Int, luma: UnsafeRawBufferPointer, lumaRowStride: Int,
                              chroma: UnsafeRawBufferPointer?, chromaRowStride: Int) -> RingFrame {
        guard let chroma, chroma.count > 1, let base = chroma.baseAddress else {
            return build(width: width, height: height, y: luma, yRowStride: lumaRowStride, u: nil, v: nil, uvRowStride: 0, uvPixelStride: 0)
        }
        let u = UnsafeRawBufferPointer(start: base, count: chroma.count)
        let v = UnsafeRawBufferPointer(start: base + 1, count: chroma.count - 1)
        return build(width: width, height: height, y: luma, yRowStride: lumaRowStride, u: u, v: v,
                     uvRowStride: chromaRowStride, uvPixelStride: 2)
    }
}

/// How often the scanner may look, so it never starves the screen. It looks at most every `minGapMs`; when a scan takes long it waits
/// `load` times that long before the next (so the scanner uses about one part in `load` + 1 of the analysis queue); and when the average
/// scan is longer than `tooSlowMs` the phone cannot use the ring scanner usefully and the screen says so.
public struct RingScanPacer: Sendable {
    private let minGapMs: Int64
    private let load: Int64
    private let tooSlowMs: Int64
    private let window: Int
    private var recent: [Int64]
    private var count = 0
    private var next = 0
    private var nextAllowedMs: Int64 = 0

    public init(minGapMs: Int64 = 110, load: Int64 = 2, tooSlowMs: Int64 = 450, window: Int = 8) {
        self.minGapMs = minGapMs
        self.load = load
        self.tooSlowMs = tooSlowMs
        self.window = window
        recent = [Int64](repeating: 0, count: window)
    }

    public func shouldScan(nowMs: Int64) -> Bool { nowMs >= nextAllowedMs }

    /// A scan that took `micros` has just finished at `nowMs`.
    public mutating func recordScan(micros: Int64, nowMs: Int64) {
        recent[next] = micros
        next = (next + 1) % window
        if count < window { count += 1 }
        nextAllowedMs = nowMs + max(minGapMs, micros / 1000 * load)
    }

    public func averageMs() -> Int64 {
        if count == 0 { return 0 }
        var sum: Int64 = 0
        for i in 0..<count { sum += recent[i] }
        return sum / Int64(count) / 1000
    }

    /// True after a full window of scans whose average is over the limit.
    public func tooSlow() -> Bool { count >= window && averageMs() > tooSlowMs }

    public mutating func reset() {
        count = 0
        next = 0
        nextAllowedMs = 0
    }
}
