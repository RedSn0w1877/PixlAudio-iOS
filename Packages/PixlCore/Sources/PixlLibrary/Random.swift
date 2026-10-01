// The two pseudo-random generators the Android code seeds explicitly, bit for bit: `java.util.Random` (the
// recommendation jitter and the Your Mix day seed) and Kotlin's `Random(seed)` (XorWow, used by QueueUtils).

/// A source of uniform integers for shuffling (Kotlin `Random.nextInt(until)`).
public protocol ShuffleRandom {
    /// A uniform integer in `0..<bound`; `bound` must be positive.
    mutating func nextInt(until bound: Int) -> Int
}

/// The system generator (Kotlin `Random.Default`).
public struct SystemShuffleRandom: ShuffleRandom, Sendable {
    public init() {}

    public mutating func nextInt(until bound: Int) -> Int {
        precondition(bound > 0, "bound must be positive")
        return Int.random(in: 0..<bound)
    }
}

/// `java.util.Random`: the 48-bit linear congruential generator.
public struct JavaRandom: Sendable {
    private static let multiplier: Int64 = 0x5_DEEC_E66D
    private static let addend: Int64 = 0xB
    private static let mask: Int64 = (1 << 48) - 1
    private var seed: Int64

    public init(seed: Int64) { self.seed = (seed ^ Self.multiplier) & Self.mask }

    /// `next(bits)`.
    public mutating func next(_ bits: Int) -> Int32 {
        seed = (seed &* Self.multiplier &+ Self.addend) & Self.mask
        return Int32(truncatingIfNeeded: Int64(bitPattern: UInt64(bitPattern: seed) >> UInt64(48 - bits)))
    }

    /// `nextInt()`.
    public mutating func nextInt() -> Int32 { next(32) }

    /// `nextInt(bound)`.
    public mutating func nextInt(_ bound: Int32) -> Int32 {
        precondition(bound > 0, "bound must be positive")
        var r = next(31)
        let m = bound - 1
        if bound & m == 0 {
            return Int32(truncatingIfNeeded: (Int64(bound) &* Int64(r)) >> 31)
        }
        var u = r
        while true {
            r = u % bound
            if u &- r &+ m >= 0 { break }
            u = next(31)
        }
        return r
    }

    /// `nextLong()`.
    public mutating func nextLong() -> Int64 {
        let high = Int64(next(32)) << 32
        return high &+ Int64(next(32))
    }

    /// `nextDouble()`: 53 random bits scaled by 2⁻⁵³.
    public mutating func nextDouble() -> Double {
        let high = Int64(next(26)) << 27
        let value = high + Int64(next(27))
        return Double(value) * 0x1.0p-53
    }
}

/// Kotlin's seeded `Random(seed)` (`XorWowRandom`).
public struct KotlinRandom: ShuffleRandom, Sendable {
    private var x: Int32, y: Int32, z: Int32, w: Int32, v: Int32, addend: Int32

    /// `Random(seed: Int)`.
    public init(seed: Int32) { self.init(seed1: seed, seed2: seed >> 31) }

    /// `Random(seed: Long)`.
    public init(seed: Int64) {
        self.init(seed1: Int32(truncatingIfNeeded: seed), seed2: Int32(truncatingIfNeeded: seed >> 32))
    }

    private init(seed1: Int32, seed2: Int32) {
        x = seed1
        y = seed2
        z = 0
        w = 0
        v = ~seed1
        addend = (seed1 << 10) ^ Int32(bitPattern: UInt32(bitPattern: seed2) >> 4)
        precondition((x | y | z | w | v) != 0, "Initial state must have at least one non-zero element.")
        for _ in 0..<64 { _ = nextInt() }
    }

    /// `nextInt()`.
    public mutating func nextInt() -> Int32 {
        var t = x
        t = t ^ Int32(bitPattern: UInt32(bitPattern: t) >> 2)
        x = y
        y = z
        z = w
        let v0 = v
        w = v0
        t = (t ^ (t << 1)) ^ v0 ^ (v0 << 4)
        v = t
        addend = addend &+ 362_437
        return t &+ addend
    }

    /// `nextBits(bitCount)`.
    public mutating func nextBits(_ bitCount: Int) -> Int32 {
        let value = UInt32(bitPattern: nextInt())
        guard bitCount > 0 else { return 0 }
        return Int32(bitPattern: value >> UInt32(32 - bitCount))
    }

    /// `nextInt(until)` (= `nextInt(0, until)`).
    public mutating func nextInt(until bound: Int32) -> Int32 {
        precondition(bound > 0, "bound must be positive")
        let n = bound
        if n & -n == n {
            let bitCount = 31 - n.leadingZeroBitCount
            return nextBits(bitCount)
        }
        var v: Int32
        while true {
            let bits = Int32(bitPattern: UInt32(bitPattern: nextInt()) >> 1)
            v = bits % n
            if bits &- v &+ (n &- 1) >= 0 { break }
        }
        return v
    }

    public mutating func nextInt(until bound: Int) -> Int {
        Int(nextInt(until: Int32(clamping: bound)))
    }
}
