// The music brain's hashing and randomness (docs/brain-spec.md, 10.3 rules 5, 10 and 14). A line-by-line
// transliteration of the Android `:brain` module's `BrainHash.kt`; both must give the same bits.
//
// Hashes are unsigned 64-bit values: `UInt64` with the wrapping operators `&+` and `&*` (plain `+` and `*` trap on
// overflow). A hash becomes an id by reusing its bits as a signed `Int64` (`BrainHash.id`).

/// The only hashing and the only randomness the brain uses.
public enum BrainHash {
    static let fnvOffset: UInt64 = 0xcbf2_9ce4_8422_2325
    static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    static let splitmixGamma: UInt64 = 0x9E37_79B9_7F4A_7C15
    static let splitmixM1: UInt64 = 0xBF58_476D_1CE4_E5B9
    static let splitmixM2: UInt64 = 0x94D0_49BB_1331_11EB

    /// 2^-53, the weight of one unit in the last place of a double in [0, 1).
    static let twoPowMinus53: Double = 1.0 / 9_007_199_254_740_992.0

    /// FNV-1a, 64-bit, over raw bytes.
    public static func fnv1a64<Bytes: Sequence>(bytes: Bytes) -> UInt64 where Bytes.Element == UInt8 {
        var h = fnvOffset
        for b in bytes {
            h ^= UInt64(b)
            h = h &* fnvPrime
        }
        return h
    }

    /// FNV-1a over the UTF-8 bytes of `text`.
    public static func fnv1a64(_ text: String) -> UInt64 { fnv1a64(bytes: text.utf8) }

    /// A hash as an id: the same bits, read as a signed 64-bit integer.
    public static func id(_ hash: UInt64) -> Int64 { Int64(bitPattern: hash) }

    /// The SplitMix64 output for the state AFTER it has been advanced by the gamma.
    public static func mix(_ advancedState: UInt64) -> UInt64 {
        var z = advancedState
        z = (z ^ (z >> 30)) &* splitmixM1
        z = (z ^ (z >> 27)) &* splitmixM2
        return z ^ (z >> 31)
    }

    /// One SplitMix64 step from `state`: advance by the gamma, then mix. Stateless form.
    public static func splitmix64(_ state: UInt64) -> UInt64 { mix(state &+ splitmixGamma) }

    /// The top 53 bits of `h` as a number in [0, 1): `(h >>> 11) * 2^-53`.
    public static func unit(_ h: UInt64) -> Double { Double(h >> 11) * twoPowMinus53 }

    /// A SplitMix64 stream. `uniform` advances the state once; `gaussian12` twelve times.
    public struct Rng: Sendable {
        public private(set) var state: UInt64

        public init(seed: UInt64) { state = seed }

        public mutating func next() -> UInt64 {
            state = state &+ BrainHash.splitmixGamma
            return BrainHash.mix(state)
        }

        /// Uniform in [0, 1): the top 53 bits times 2^-53.
        public mutating func uniform() -> Double { Double(next() >> 11) * BrainHash.twoPowMinus53 }

        /// Sum of twelve uniforms minus six: mean 0, variance 1, no transcendental function.
        public mutating func gaussian12() -> Double {
            var sum = 0.0
            for _ in 0..<12 { sum += uniform() }
            return sum - 6.0
        }
    }
}

/// A text key compared and hashed by its UTF-8 bytes (docs/brain-spec.md, 10.3 rule 13). Swift's own `String`
/// equality is canonical equivalence, so two spellings Kotlin keeps apart (precomposed Hangul and its conjoining
/// jamo, for one) would be one dictionary key here and two on Android. Every dictionary or set of the brain that is
/// keyed by text uses this.
public struct BrainKey: Hashable, Sendable {
    public let text: String

    public init(_ text: String) { self.text = text }

    public static func == (lhs: BrainKey, rhs: BrainKey) -> Bool { BrainKey.sameBytes(lhs.text, rhs.text) }

    public func hash(into hasher: inout Hasher) {
        var text = self.text
        text.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }

    /// True when the two strings are the same UTF-8 bytes: the brain's only string comparison.
    public static func sameBytes(_ a: String, _ b: String) -> Bool {
        a.utf8.count == b.utf8.count && a.utf8.elementsEqual(b.utf8)
    }
}
