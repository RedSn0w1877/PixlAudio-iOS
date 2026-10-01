// The TAIS DFT, ported operation for operation from data/tais/dsp/Fft.kt: an in-place iterative radix-2
// Cooley–Tukey FFT for power-of-two lengths and Bluestein's chirp-z algorithm for any other length (the stem
// separator's 6144-point STFT). Float arithmetic in the same order as Kotlin, so results match Android bit for bit
// (twiddles come from Double sin/cos, as there).

import Foundation
import Synchronization

/// Errors of the FFT entry points (Android throws `IllegalArgumentException`).
public enum FftError: Error, Sendable, Hashable {
    /// A workspace needs a positive size.
    case nonPositiveSize(Int)
    /// The input arrays do not match the workspace size; the input is left untouched.
    case sizeMismatch(expected: Int, re: Int, im: Int)
}

/// `Fft`: the DFT dispatcher.
public enum Fft {
    /// A fixed-size workspace for repeated transforms of one length (one per render/STFT). Owns its scratch, so
    /// `transform` never allocates. A value type: copies are independent (no sharing, hence no locking).
    public struct Workspace: Sendable {
        public let size: Int
        private var bluestein: Bluestein.Workspace?

        public init(size: Int) throws {
            guard size > 0 else { throw FftError.nonPositiveSize(size) }
            self.size = size
            bluestein = size & (size - 1) == 0 ? nil : Bluestein.Workspace(size)
        }

        /// Transforms `re`/`im` in place (inverse transforms are scaled by 1/n).
        public mutating func transform(re: UnsafeMutableBufferPointer<Float>, im: UnsafeMutableBufferPointer<Float>,
                                       inverse: Bool) throws {
            guard re.count == size && im.count == size else {
                throw FftError.sizeMismatch(expected: size, re: re.count, im: im.count)
            }
            guard let reBase = re.baseAddress, let imBase = im.baseAddress else { return }
            if bluestein == nil {
                Fft.radix2(reBase, imBase, count: size, inverse: inverse)
            } else {
                bluestein!.transform(reBase, imBase, inverse: inverse)
            }
        }

        /// Array convenience for `transform(re:im:inverse:)`.
        public mutating func transform(re: inout [Float], im: inout [Float], inverse: Bool) throws {
            guard re.count == size && im.count == size else {
                throw FftError.sizeMismatch(expected: size, re: re.count, im: im.count)
            }
            try re.withUnsafeMutableBufferPointer { r in
                try im.withUnsafeMutableBufferPointer { i in
                    try transform(re: r, im: i, inverse: inverse)
                }
            }
        }
    }

    /// `Fft.transform`: any length (Bluestein builds a throw-away workspace, as on Android). `re` and `im` must have
    /// the same length.
    public static func transform(re: inout [Float], im: inout [Float], inverse: Bool) {
        let n = re.count
        precondition(im.count == n, "FFT re/im lengths differ")
        guard n > 0 else { return }
        if n & (n - 1) == 0 {
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    radix2(r.baseAddress!, i.baseAddress!, count: n, inverse: inverse)
                }
            }
        } else {
            var workspace = Bluestein.Workspace(n)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    workspace.transform(r.baseAddress!, i.baseAddress!, inverse: inverse)
                }
            }
        }
    }

    /// In-place iterative radix-2 Cooley–Tukey FFT; `count` must be a power of two.
    public static func radix2(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>, count n: Int,
                              inverse: Bool) {
        var j = 0
        if n > 1 {
            for i in 1..<n {
                var bit = n >> 1
                while j & bit != 0 {
                    j ^= bit
                    bit >>= 1
                }
                j |= bit
                if i < j {
                    let tr = re[i]; re[i] = re[j]; re[j] = tr
                    let ti = im[i]; im[i] = im[j]; im[j] = ti
                }
            }
        }

        var len = 2
        while len <= n {
            let ang = (inverse ? 2.0 : -2.0) * Double.pi / Double(len)
            let wRe = Float(cos(ang))
            let wIm = Float(sin(ang))
            let half = len / 2
            var i = 0
            while i < n {
                var curRe: Float = 1
                var curIm: Float = 0
                for k in 0..<half {
                    let a = i + k
                    let b = a + half
                    let uRe = re[a]
                    let uIm = im[a]
                    let pr1 = re[b] * curRe
                    let pr2 = im[b] * curIm
                    let vRe = pr1 - pr2
                    let pi1 = re[b] * curIm
                    let pi2 = im[b] * curRe
                    let vIm = pi1 + pi2
                    re[a] = uRe + vRe
                    im[a] = uIm + vIm
                    re[b] = uRe - vRe
                    im[b] = uIm - vIm
                    let n1 = curRe * wRe
                    let n2 = curIm * wIm
                    let m1 = curRe * wIm
                    let m2 = curIm * wRe
                    curRe = n1 - n2
                    curIm = m1 + m2
                }
                i += len
            }
            len <<= 1
        }

        if inverse {
            let fn = Float(n)
            for i in 0..<n {
                re[i] /= fn
                im[i] /= fn
            }
        }
    }
}

/// Bluestein's algorithm (chirp-z transform): an arbitrary-length DFT as a power-of-two convolution through
/// `Fft.radix2`. Inverse = conj(DFT(conj(x)))/n. Chirp and kernel arrays depend only on the length and are cached
/// process-wide; each workspace owns its convolution scratch.
enum Bluestein {
    /// Immutable per-length tables.
    final class Plan: Sendable {
        let m: Int
        let wRe: [Float]
        let wIm: [Float]
        let bFftRe: [Float]
        let bFftIm: [Float]

        init(_ n: Int) {
            var mm = 1
            while mm < 2 * n - 1 { mm <<= 1 }
            m = mm
            var wr = [Float](repeating: 0, count: n)
            var wi = [Float](repeating: 0, count: n)
            for k in 0..<n {
                // k² mod 2n keeps the angle bounded for large k.
                let kk = (Int64(k) * Int64(k)) % (2 * Int64(n))
                let angle = Double.pi * Double(kk) / Double(n)
                wr[k] = Float(cos(angle))
                wi[k] = -Float(sin(angle))
            }
            var br = [Float](repeating: 0, count: mm)
            var bi = [Float](repeating: 0, count: mm)
            br[0] = wr[0]
            bi[0] = -wi[0]
            if n > 1 {
                for k in 1..<n {
                    br[k] = wr[k]
                    bi[k] = -wi[k]
                    br[mm - k] = wr[k]
                    bi[mm - k] = -wi[k]
                }
            }
            br.withUnsafeMutableBufferPointer { r in
                bi.withUnsafeMutableBufferPointer { i in
                    Fft.radix2(r.baseAddress!, i.baseAddress!, count: mm, inverse: false)
                }
            }
            wRe = wr
            wIm = wi
            bFftRe = br
            bFftIm = bi
        }
    }

    private static let plans = Mutex<[Int: Plan]>([:])

    static func plan(_ n: Int) -> Plan {
        plans.withLock { cache in
            if let existing = cache[n] { return existing }
            let created = Plan(n)
            cache[n] = created
            return created
        }
    }

    /// Owns the convolution scratch for one length.
    struct Workspace: Sendable {
        let n: Int
        let plan: Plan
        private var aRe: [Float]
        private var aIm: [Float]

        init(_ n: Int) {
            self.n = n
            plan = Bluestein.plan(n)
            aRe = [Float](repeating: 0, count: plan.m)
            aIm = [Float](repeating: 0, count: plan.m)
        }

        mutating func transform(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>, inverse: Bool) {
            if inverse {
                for i in 0..<n { im[i] = -im[i] }
            }
            forward(re, im)
            if inverse {
                let fn = Float(n)
                for i in 0..<n {
                    re[i] /= fn
                    im[i] = -im[i] / fn
                }
            }
        }

        private mutating func forward(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
            let n = self.n
            let plan = self.plan
            let m = plan.m
            plan.wRe.withUnsafeBufferPointer { wRe in
            plan.wIm.withUnsafeBufferPointer { wIm in
            plan.bFftRe.withUnsafeBufferPointer { bRe in
            plan.bFftIm.withUnsafeBufferPointer { bIm in
            aRe.withUnsafeMutableBufferPointer { aReBuf in
            aIm.withUnsafeMutableBufferPointer { aImBuf in
                let ar = aReBuf.baseAddress!
                let ai = aImBuf.baseAddress!
                // Clear the padding left by the previous transform (reuse == fresh zero-filled scratch).
                for i in n..<m {
                    ar[i] = 0
                    ai[i] = 0
                }
                for k in 0..<n {
                    let p1 = re[k] * wRe[k]
                    let p2 = im[k] * wIm[k]
                    ar[k] = p1 - p2
                    let q1 = re[k] * wIm[k]
                    let q2 = im[k] * wRe[k]
                    ai[k] = q1 + q2
                }
                Fft.radix2(ar, ai, count: m, inverse: false)
                for i in 0..<m {
                    let r1 = ar[i] * bRe[i]
                    let r2 = ai[i] * bIm[i]
                    let s1 = ar[i] * bIm[i]
                    let s2 = ai[i] * bRe[i]
                    ar[i] = r1 - r2
                    ai[i] = s1 + s2
                }
                Fft.radix2(ar, ai, count: m, inverse: true)
                for k in 0..<n {
                    let cRe = ar[k]
                    let cIm = ai[k]
                    let x1 = cRe * wRe[k]
                    let x2 = cIm * wIm[k]
                    let y1 = cRe * wIm[k]
                    let y2 = cIm * wRe[k]
                    re[k] = x1 - x2
                    im[k] = y1 + y2
                }
            }}}}}}
        }
    }
}
