// SHA-1 (FIPS 180-4) in plain Swift, for the SAPISIDHASH authorization YouTube's web clients compute (copied from
// PixlLyrics' internal helper; PixlCore may not import CryptoKit). Not a security primitive here.

enum SHA1 {
    /// Lowercase hex digest of the UTF-8 bytes of `text`.
    static func hexDigest(_ text: String) -> String {
        let digest = hash(Array(text.utf8))
        let hex: [Character] = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(40)
        for byte in digest {
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
        }
        return out
    }

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bitLength = UInt64(message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

        var w = [UInt32](repeating: 0, count: 80)
        var chunk = 0
        while chunk < padded.count {
            for t in 0..<16 {
                let i = chunk + t * 4
                w[t] = UInt32(padded[i]) << 24 | UInt32(padded[i + 1]) << 16 | UInt32(padded[i + 2]) << 8 | UInt32(padded[i + 3])
            }
            for t in 16..<80 { w[t] = rotl(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1) }
            var (a, b, c, d, e) = h
            for t in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch t {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[t]
                e = d
                d = c
                c = rotl(b, 30)
                b = a
                a = temp
            }
            h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d, h.4 &+ e)
            chunk += 64
        }
        var out: [UInt8] = []
        out.reserveCapacity(20)
        for word in [h.0, h.1, h.2, h.3, h.4] {
            for shift in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: word >> UInt32(shift))) }
        }
        return out
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
}
