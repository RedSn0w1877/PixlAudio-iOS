// Where everything sits on a Pixl ring code, in integers (a transliteration of the Android `RingCodeLayout.kt`).
// Lengths are permille of the plate's half-size (the plate is the square [-1000, 1000] on both axes, y down, so a dot at
// ring radius 800 is 80 percent of the way from the centre to the plate's edge). Angles run clockwise from 12 o'clock.
//
//   centre            art disc, radius 280 (the album art), a light gap, then a dark outline ring 305..330
//   ring 0..4         24, 32, 40, 48, 56 slots at radius 420, 515, 610, 705, 800 (pitch 95)
//   slot i of N       angle i/N of a turn, i = 0 at 12 o'clock
//   one dot per slot  BIG (radius 32) = bit 1, SMALL (radius 16) = bit 0: the dot's centre never moves,
//                     so the scanner always knows where to look and only measures a size
//   start dot         orange, radius 42, at 12 o'clock at radius 895: one ring pitch outside the outer ring
//
// The 200 slots carry exactly one 25-byte Reed-Solomon codeword. Slot ids run ring by ring (ring 0 first), clockwise
// inside a ring: ring 0 is 0..23, ring 1 24..55, ring 2 56..95, ring 3 96..143, ring 4 144..199.
//
// Byte map (deviates from RING-CODE-SPEC.md on purpose, see the handoff): byte b owns the eight consecutive slots
// 8b ... 8b+7, most significant bit first. Every ring size is a multiple of 8, so a byte is always a run of eight
// neighbours on one ring. `specByteOfSlot` keeps the spec's map so a test can show the difference.

public enum RingCodeLayout {
    public static let rings = 5
    public static let ringSlots: [Int] = [24, 32, 40, 48, 56]
    public static let ringFirstSlot: [Int] = [0, 24, 56, 96, 144]
    public static let slots = 200
    public static let bytes = 25
    public static let bitsPerByte = 8

    // Geometry, permille of the plate half-size.
    public static let artRadius = 280
    public static let bezelInner = 305
    public static let bezelOuter = 330
    public static let ringRadius: [Int] = [420, 515, 610, 705, 800]
    public static let bigRadius = 32
    public static let smallRadius = 16
    public static let markerRadiusAt = 895
    public static let markerRadius = 42
    public static let plateCorner = 180

    /// The one fixed colour of the code, on every device (ARGB as a signed 32 bit integer, like Android's `Int`).
    public static let markerArgb: Int32 = Int32(bitPattern: 0xFFD9480F)

    public static func ringOf(_ slot: Int) -> Int {
        precondition(slot >= 0 && slot < slots, "slot \(slot)")
        var r = rings - 1
        while ringFirstSlot[r] > slot { r -= 1 }
        return r
    }

    public static func indexInRing(_ slot: Int) -> Int { slot - ringFirstSlot[ringOf(slot)] }

    public static func slotOf(ring: Int, index: Int) -> Int {
        precondition(ring >= 0 && ring < rings && index >= 0 && index < ringSlots[ring], "ring \(ring) index \(index)")
        return ringFirstSlot[ring] + index
    }

    /// The slot's angle as millionths of a turn from 12 o'clock, clockwise: index * 1,000,000 / count (rounded down).
    public static func angleMicroTurns(_ slot: Int) -> Int {
        let ring = ringOf(slot)
        return Int(Int64(indexInRing(slot)) * 1_000_000 / Int64(ringSlots[ring]))
    }

    public static func byteOfSlot(_ slot: Int) -> Int { slot / bitsPerByte }

    /// The bit (7 = most significant) a slot carries inside its byte.
    public static func bitOfSlot(_ slot: Int) -> Int { bitsPerByte - 1 - slot % bitsPerByte }

    /// The spec's interleave (byte j owns j, j+25, ...), kept for comparison only.
    public static func specByteOfSlot(_ slot: Int) -> Int { slot % bytes }

    /// 25 codeword bytes to 200 slot bits (0 or 1 per element, index = slot id).
    public static func codewordToSlots(_ codeword: [UInt8]) -> [UInt8] {
        precondition(codeword.count == bytes, "a codeword has \(bytes) bytes")
        var bits = [UInt8](repeating: 0, count: slots)
        for slot in 0..<slots {
            bits[slot] = (codeword[byteOfSlot(slot)] >> UInt8(bitOfSlot(slot))) & 1
        }
        return bits
    }

    /// 200 slot bits (any non-zero value counts as 1) back to 25 bytes.
    public static func slotsToCodeword(_ bits: [UInt8]) -> [UInt8] {
        precondition(bits.count == slots, "a code has \(slots) slots")
        var out = [UInt8](repeating: 0, count: bytes)
        for slot in 0..<slots where bits[slot] != 0 {
            out[byteOfSlot(slot)] |= UInt8(1) << UInt8(bitOfSlot(slot))
        }
        return out
    }

    /// How many different bytes a run of `count` consecutive slots starting at `first` (wrapping inside its ring) touches.
    public static func bytesTouched(first: Int, count: Int, byteOf: (Int) -> Int) -> Int {
        let ring = ringOf(first)
        let n = ringSlots[ring]
        let start = indexInRing(first)
        var seen = [Bool](repeating: false, count: bytes)
        for k in 0..<count { seen[byteOf(slotOf(ring: ring, index: (start + k) % n))] = true }
        return seen.reduce(0) { $0 + ($1 ? 1 : 0) }
    }
}
