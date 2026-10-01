// CRC-32 (ZIP/gzip, polynomial 0xEDB88320) and SHA-256 (FIPS 180-4) in pure Swift, so PixlBackup can verify and
// write `.pxpl` archives on Windows and Apple platforms without CryptoKit or zlib. SHA-256 is the `sha256:` module
// checksum the Android BackupWriter puts in manifest.json.

/// CRC-32 as used by ZIP and gzip (`java.util.zip.CRC32`).
public struct CRC32: Sendable {
    public private(set) var value: UInt32 = 0

    public init() {}

    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public mutating func update<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        var c = ~value
        Self.table.withUnsafeBufferPointer { t in
            for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        value = ~c
    }

    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }
}

/// SHA-256. `SHA256.hex(bytes)` is the lowercase digest the Android code formats with `"%02x"`.
public struct SHA256: Sendable {
    private var state: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) =
        (0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19)
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    public init() { buffer.reserveCapacity(64) }

    private static let k: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]

    public mutating func update<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        let input = Array(bytes)
        length &+= UInt64(input.count)
        var i = 0
        if !buffer.isEmpty {
            let take = min(64 - buffer.count, input.count)
            buffer.append(contentsOf: input[0..<take])
            i = take
            if buffer.count == 64 {
                compress(buffer[0..<64])
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while i + 64 <= input.count {
            compress(input[i..<(i + 64)])
            i += 64
        }
        if i < input.count { buffer.append(contentsOf: input[i...]) }
    }

    public mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        var i = 0
        while i < tail.count {
            compress(tail[i..<(i + 64)])
            i += 64
        }
        buffer.removeAll()
        let words = [state.0, state.1, state.2, state.3, state.4, state.5, state.6, state.7]
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for w in words {
            out.append(UInt8(truncatingIfNeeded: w >> 24))
            out.append(UInt8(truncatingIfNeeded: w >> 16))
            out.append(UInt8(truncatingIfNeeded: w >> 8))
            out.append(UInt8(truncatingIfNeeded: w))
        }
        return out
    }

    private mutating func compress(_ block: ArraySlice<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in
            compress(block, schedule: w)
        }
    }

    private mutating func compress(_ block: ArraySlice<UInt8>, schedule w: UnsafeMutableBufferPointer<UInt32>) {
        let base = block.startIndex
        for t in 0..<16 {
            let j = base + t * 4
            w[t] = UInt32(block[j]) << 24 | UInt32(block[j + 1]) << 16 | UInt32(block[j + 2]) << 8 | UInt32(block[j + 3])
        }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var (a, b, c, d, e, f, g, h) = state
        for t in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Self.k[t] &+ w[t]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        state = (state.0 &+ a, state.1 &+ b, state.2 &+ c, state.3 &+ d,
                 state.4 &+ e, state.5 &+ f, state.6 &+ g, state.7 &+ h)
    }

    @inline(__always) private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    public static func hash<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
        var h = SHA256()
        h.update(bytes)
        return h.finalize()
    }

    /// Lowercase hex digest.
    public static func hex<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        hexString(hash(bytes))
    }

    static func hexString(_ digest: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(digest.count * 2)
        for b in digest {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// The SHA-256 used for module checksums. The pure-Swift digest is the default; the app may inject a platform
/// implementation (CryptoKit) with the same output.
public typealias SHA256Hasher = @Sendable ([UInt8]) -> [UInt8]

public enum BackupHashing {
    public static let pureSwift: SHA256Hasher = { SHA256.hash($0) }

    /// `sha256(bytes)` formatted like the Android code (`joinToString("") { "%02x".format(it) }`).
    public static func hex(_ bytes: [UInt8], hasher: SHA256Hasher = pureSwift) -> String {
        SHA256.hexString(hasher(bytes))
    }
}
