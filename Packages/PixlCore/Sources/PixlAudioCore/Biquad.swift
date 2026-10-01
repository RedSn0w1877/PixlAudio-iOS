// RBJ biquad filters ("Cookbook formulae for audio EQ biquad filter coefficients", Robert Bristow-Johnson), their
// frequency response, and an allocation-free cascade processor. Android used the platform `audiofx` effects; iOS
// computes the coefficients here and runs them in the processing tap (vDSP_biquadm takes the same
// [b0, b1, b2, a1, a2] layout, normalised by a0).

import Foundation

/// Normalised biquad coefficients: H(z) = (b0 + b1·z⁻¹ + b2·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²).
public struct BiquadCoefficients: Sendable, Hashable, Codable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Passes the signal through unchanged.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// True for the identity filter.
    public var isIdentity: Bool { self == .identity }

    /// The five coefficients in vDSP order.
    public var vDSPOrder: [Double] { [b0, b1, b2, a1, a2] }

    /// Both poles strictly inside the unit circle (|a2| < 1 and |a1| < 1 + a2).
    public var isStable: Bool { abs(a2) < 1 && abs(a1) < 1 + a2 }

    /// |H(e^{jω})| at `frequency` Hz.
    @inlinable
    public func magnitude(atFrequency frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2
        let ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2
        let di = -(a1 * s1 + a2 * s2)
        return ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
    }

    /// The response in dB at `frequency` Hz.
    @inlinable
    public func magnitudeDb(atFrequency frequency: Double, sampleRate: Double) -> Double {
        20 * log10(magnitude(atFrequency: frequency, sampleRate: sampleRate))
    }
}

/// The cookbook filter shapes.
public enum BiquadShape: Sendable, Hashable, Codable {
    /// Peaking EQ: `gainDb` at the centre, bandwidth set by Q.
    case peaking
    /// Low shelf: `gainDb` below the corner.
    case lowShelf
    /// High shelf: `gainDb` above the corner.
    case highShelf
    /// Second-order low-pass (gain ignored).
    case lowPass
    /// Second-order high-pass (gain ignored).
    case highPass
}

/// Designs RBJ biquads.
public enum BiquadDesigner {
    /// Butterworth Q (1/√2): flattest shelf/pass-band (shelf slope S = 1).
    public static let butterworthQ = 1 / 2.0.squareRoot()
    /// Highest usable centre frequency as a fraction of the sample rate (just under Nyquist).
    public static let maxFrequencyRatio = 0.49

    /// The coefficients of `shape` at `frequency` Hz with `q` and `gainDb` for sample rate `sampleRate`.
    /// The frequency is clamped to 1 Hz…0.49·fs; a non-positive or non-finite Q falls back to Butterworth; a 0 dB
    /// peaking or shelf filter is exactly the identity.
    public static func design(_ shape: BiquadShape, frequency: Double, sampleRate: Double, q: Double = butterworthQ,
                              gainDb: Double = 0) -> BiquadCoefficients {
        guard sampleRate > 0, sampleRate.isFinite else { return .identity }
        let gain = gainDb.isFinite ? gainDb : 0
        switch shape {
        case .peaking, .lowShelf, .highShelf: if gain == 0 { return .identity }
        case .lowPass, .highPass: break
        }
        let f0 = min(max(frequency.isFinite ? frequency : 1000, 1), maxFrequencyRatio * sampleRate)
        let qq = (q.isFinite && q > 0) ? q : butterworthQ
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cw = cos(w0)
        let sw = sin(w0)
        let alpha = sw / (2 * qq)
        let a = Foundation.pow(10, gain / 40)
        var b0, b1, b2, a0, a1, a2: Double
        switch shape {
        case .peaking:
            b0 = 1 + alpha * a
            b1 = -2 * cw
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cw
            a2 = 1 - alpha / a
        case .lowShelf:
            let sq = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cw + sq)
            b1 = 2 * a * ((a - 1) - (a + 1) * cw)
            b2 = a * ((a + 1) - (a - 1) * cw - sq)
            a0 = (a + 1) + (a - 1) * cw + sq
            a1 = -2 * ((a - 1) + (a + 1) * cw)
            a2 = (a + 1) + (a - 1) * cw - sq
        case .highShelf:
            let sq = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cw + sq)
            b1 = -2 * a * ((a - 1) + (a + 1) * cw)
            b2 = a * ((a + 1) + (a - 1) * cw - sq)
            a0 = (a + 1) - (a - 1) * cw + sq
            a1 = 2 * ((a - 1) - (a + 1) * cw)
            a2 = (a + 1) - (a - 1) * cw - sq
        case .lowPass:
            b0 = (1 - cw) / 2
            b1 = 1 - cw
            b2 = (1 - cw) / 2
            a0 = 1 + alpha
            a1 = -2 * cw
            a2 = 1 - alpha
        case .highPass:
            b0 = (1 + cw) / 2
            b1 = -(1 + cw)
            b2 = (1 + cw) / 2
            a0 = 1 + alpha
            a1 = -2 * cw
            a2 = 1 - alpha
        }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

/// A cascade of biquads over interleaved multichannel audio (transposed direct form II, Double state). Storage is
/// sized once in `init`; `process` and `setCoefficients` never allocate (the struct must be uniquely owned, as it is
/// inside a tap context).
public struct BiquadCascade: Sendable {
    public let sectionCount: Int
    public let channelCount: Int
    /// 5 coefficients per section.
    private var coefficients: [Double]
    /// 2 state values per section per channel.
    private var state: [Double]

    public init(sectionCount: Int, channelCount: Int) {
        precondition(sectionCount >= 0 && channelCount > 0)
        self.sectionCount = sectionCount
        self.channelCount = channelCount
        coefficients = [Double](repeating: 0, count: sectionCount * 5)
        state = [Double](repeating: 0, count: sectionCount * channelCount * 2)
        for s in 0..<sectionCount { coefficients[s * 5] = 1 }
    }

    /// The coefficients of section `index`.
    public func coefficients(at index: Int) -> BiquadCoefficients {
        let o = index * 5
        return BiquadCoefficients(b0: coefficients[o], b1: coefficients[o + 1], b2: coefficients[o + 2],
                                  a1: coefficients[o + 3], a2: coefficients[o + 4])
    }

    /// Replaces section `index` (filter state is kept, so changes are click-free for small steps).
    public mutating func setCoefficients(_ c: BiquadCoefficients, at index: Int) {
        precondition(index >= 0 && index < sectionCount)
        coefficients.withUnsafeMutableBufferPointer { k in
            let o = index * 5
            k[o] = c.b0; k[o + 1] = c.b1; k[o + 2] = c.b2; k[o + 3] = c.a1; k[o + 4] = c.a2
        }
    }

    /// Clears the filter memory (after a seek or a track change).
    public mutating func reset() {
        state.withUnsafeMutableBufferPointer { s in
            for i in s.indices { s[i] = 0 }
        }
    }

    /// Filters `frames` interleaved frames in place. Sections that are exactly the identity are skipped.
    public mutating func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0, sectionCount > 0 else { return }
        let channels = channelCount
        let sections = sectionCount
        coefficients.withUnsafeBufferPointer { k in
            state.withUnsafeMutableBufferPointer { z in
                for s in 0..<sections {
                    let o = s * 5
                    let b0 = k[o], b1 = k[o + 1], b2 = k[o + 2], a1 = k[o + 3], a2 = k[o + 4]
                    if b0 == 1 && b1 == 0 && b2 == 0 && a1 == 0 && a2 == 0 { continue }
                    for ch in 0..<channels {
                        let zi = (s * channels + ch) * 2
                        var z1 = z[zi], z2 = z[zi + 1]
                        var index = ch
                        for _ in 0..<frames {
                            let x = Double(samples[index])
                            let y = b0 * x + z1
                            z1 = b1 * x - a1 * y + z2
                            z2 = b2 * x - a2 * y
                            samples[index] = Float(y)
                            index += channels
                        }
                        // Flush denormals so a silent tail never slows the render thread.
                        if abs(z1) < 1e-25 { z1 = 0 }
                        if abs(z2) < 1e-25 { z2 = 0 }
                        z[zi] = z1
                        z[zi + 1] = z2
                    }
                }
            }
        }
    }
}
