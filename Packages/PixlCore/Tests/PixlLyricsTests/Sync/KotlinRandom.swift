// Kotlin's `kotlin.random.Random(seed)` (XorWow) with its bounded draws, so the Android tests' seeded random
// cases (`Random(7)`, `Random(seed)` in the 500-seed property test) generate exactly the same inputs here. Verified
// against the JVM by the `R` lines of `tapsync-android-golden.txt`.

/// `kotlin.random.XorWowRandom` plus the `kotlin.random.Random` default methods the tests use.
struct KotlinRandom {
    private var x: Int32
    private var y: Int32
    private var z: Int32
    private var w: Int32
    private var v: Int32
    private var addend: Int32

    /// `Random(seed: Int)` = `XorWowRandom(seed, seed shr 31)`.
    init(seed: Int32) {
        self.init(seed1: seed, seed2: seed >> 31)
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

    mutating func nextInt() -> Int32 {
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

    /// `nextBits(bitCount)` = `nextInt().takeUpperBits(bitCount)`.
    mutating func nextBits(_ bitCount: Int32) -> Int32 {
        let value = nextInt()
        let upper = Int32(bitPattern: UInt32(bitPattern: value) >> UInt32(32 - bitCount))
        return upper & ((-bitCount) >> 31)
    }

    /// `nextInt(until)`.
    mutating func nextInt(_ until: Int32) -> Int32 { nextInt(0, until) }

    /// `nextInt(from, until)`.
    mutating func nextInt(_ from: Int32, _ until: Int32) -> Int32 {
        precondition(until > from, "Random range is empty")
        let n = until &- from
        if n > 0 || n == Int32.min {
            let rnd: Int32
            if n & (0 &- n) == n {
                rnd = nextBits(Self.fastLog2(n))
            } else {
                var value: Int32
                var bits: Int32
                repeat {
                    bits = Int32(bitPattern: UInt32(bitPattern: nextInt()) >> 1)
                    value = bits % n
                } while bits &- value &+ (n &- 1) < 0
                rnd = value
            }
            return from &+ rnd
        }
        while true {
            let rnd = nextInt()
            if rnd >= from && rnd < until { return rnd }
        }
    }

    /// `nextLong()`.
    mutating func nextLong() -> Int64 { (Int64(nextInt()) << 32) &+ Int64(nextInt()) }

    /// `nextLong(from, until)`.
    mutating func nextLong(_ from: Int64, _ until: Int64) -> Int64 {
        precondition(until > from, "Random range is empty")
        let n = until &- from
        if n > 0 {
            let rnd: Int64
            if n & (0 &- n) == n {
                let nLow = Int32(truncatingIfNeeded: n)
                let nHigh = Int32(truncatingIfNeeded: Int64(bitPattern: UInt64(bitPattern: n) >> 32))
                if nLow != 0 {
                    rnd = Int64(nextBits(Self.fastLog2(nLow))) & 0xFFFF_FFFF
                } else if nHigh == 1 {
                    rnd = Int64(nextInt()) & 0xFFFF_FFFF
                } else {
                    rnd = (Int64(nextBits(Self.fastLog2(nHigh))) << 32) &+ (Int64(nextInt()) & 0xFFFF_FFFF)
                }
            } else {
                var value: Int64
                var bits: Int64
                repeat {
                    bits = Int64(bitPattern: UInt64(bitPattern: nextLong()) >> 1)
                    value = bits % n
                } while bits &- value &+ (n &- 1) < 0
                rnd = value
            }
            return from &+ rnd
        }
        while true {
            let rnd = nextLong()
            if rnd >= from && rnd < until { return rnd }
        }
    }

    /// `nextBoolean()`.
    mutating func nextBoolean() -> Bool { nextBits(1) != 0 }

    /// `Collection.random(random)`.
    mutating func pick<T>(_ items: [T]) -> T { items[Int(nextInt(Int32(items.count)))] }

    private static func fastLog2(_ value: Int32) -> Int32 { 31 - Int32(value.leadingZeroBitCount) }
}
