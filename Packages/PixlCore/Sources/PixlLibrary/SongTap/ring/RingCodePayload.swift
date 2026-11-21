// What a ring code says: the YouTube Music video id of the song and a 22-bit session tag. Nothing else: the receiver looks
// the title and the art up itself. A transliteration of the Android `RingCodePayload.kt`.
//
// Bits, most significant first, 88 in all = 11 bytes = the data of the Reed-Solomon word:
//
//   66 bits  the 11 characters of the video id, 6 bits each (A-Z 0..25, a-z 26..51, 0-9 52..61, '-' 62, '_' 63)
//    6 bits  the minute bucket: (sender's clock in whole minutes) mod 64
//    8 bits  random (injected by the caller)
//    8 bits  a CRC-8 (x^8 + x^2 + x + 1, start value 0xFF) over the 80 bits above
//
// The task text asked for 6 + 16 bits of tag; eight of the 16 random bits are the checksum instead: a decode that leans on
// many erasures can land on a wrong word, and the checksum rejects 255 of 256 of those. Freshness: a code is accepted when
// its bucket is the receiver's current minute, one of the two before it, or the one after it (2 to 3 minutes of life, and
// the receiver's clock may run up to a minute behind the sender's).

public struct RingCodePayload: Sendable, Hashable {
    public let videoId: String
    public let minuteBucket: Int
    public let random: Int

    public init(videoId: String, minuteBucket: Int, random: Int) {
        self.videoId = videoId
        self.minuteBucket = minuteBucket
        self.random = random
    }

    /// The 22-bit tag as it is packed.
    public func tag() -> Int { RingCodePayloads.tagOf(videoId: videoId, bucket: minuteBucket, random: random) }
}

public enum RingReject: String, Sendable {
    case badLength = "length"
    case badChecksum = "checksum"
    case badVideoId = "video_id"
    case badTag = "tag"

    public var code: String { rawValue }
}

public enum RingUnpack: Sendable, Equatable {
    case ok(RingCodePayload)
    case rejected(RingReject)
}

public enum Freshness: String, Sendable {
    case fresh
    case expired
    case future

    public var code: String { rawValue }
}

public enum RingCodePayloads {
    public static let videoIdLength = 11
    public static let dataBytes = 11
    public static let minuteBuckets = 64
    public static let randomBits = 8
    public static let checkBits = 8
    public static let minuteMs: Int64 = 60_000

    /// A code stays valid while the receiver's minute is at most this many buckets after the code's.
    public static let freshPastMinutes = 2

    /// ...and at most this many before it (the receiver's clock runs behind the sender's).
    public static let freshFutureMinutes = 1

    /// The 64 characters, in symbol order (as ASCII bytes).
    private static let alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// 0..63 for a character of the alphabet, -1 for anything else (compared as UTF-8 bytes, never as Swift characters).
    private static func symbolOf(byte: UInt8) -> Int {
        switch byte {
        case 0x41...0x5A: return Int(byte) - 0x41
        case 0x61...0x7A: return Int(byte) - 0x61 + 26
        case 0x30...0x39: return Int(byte) - 0x30 + 52
        case 0x2D: return 62
        case 0x5F: return 63
        default: return -1
        }
    }

    public static func isValidVideoId(_ id: String) -> Bool {
        let u = Array(id.utf8)
        if u.count != videoIdLength { return false }
        for b in u where symbolOf(byte: b) < 0 { return false }
        return true
    }

    /// The minute bucket of a clock reading in epoch milliseconds.
    public static func bucketOf(nowMs: Int64) -> Int {
        var minutes = nowMs / minuteMs
        if nowMs % minuteMs < 0 { minutes -= 1 }
        return Int(mod(minutes, Int64(minuteBuckets)))
    }

    private static func mod(_ a: Int64, _ m: Int64) -> Int64 {
        let r = a % m
        return r < 0 ? r + m : r
    }

    /// The 22-bit tag: bucket (6) + random (8) + CRC-8 (8) of the id and those 14 bits.
    public static func tagOf(videoId: String, bucket: Int, random: Int) -> Int {
        var reg = 0xFF
        for b in videoId.utf8 { reg = crcStep(reg, Int64(symbolOf(byte: b)), 6) }
        reg = crcStep(reg, Int64((bucket << randomBits) | random), 6 + randomBits)
        return (bucket << 16) | (random << 8) | reg
    }

    private static func crcStep(_ start: Int, _ value: Int64, _ bits: Int) -> Int {
        var reg = start
        var i = bits - 1
        while i >= 0 {
            let inBit = Int((value >> Int64(i)) & 1)
            let top = (reg >> 7) & 1
            reg = (reg << 1) & 0xFF
            if (top ^ inBit) != 0 { reg ^= 0x07 }
            i -= 1
        }
        return reg
    }

    /// The 11 data bytes for a code, or nil when the id is not 11 characters of the alphabet or a field is out of range.
    public static func pack(videoId: String, minuteBucket: Int, random: Int) -> [UInt8]? {
        if !isValidVideoId(videoId) { return nil }
        if minuteBucket < 0 || minuteBucket >= minuteBuckets { return nil }
        if random < 0 || random >= (1 << randomBits) { return nil }
        let tag = tagOf(videoId: videoId, bucket: minuteBucket, random: random)
        // 88 bits: id (66) then tag (22).
        var out = [UInt8](repeating: 0, count: dataBytes)
        var bitPos = 0
        func put(_ value: Int64, _ bits: Int) {
            var i = bits - 1
            while i >= 0 {
                if (value >> Int64(i)) & 1 != 0 { out[bitPos >> 3] |= UInt8(0x80) >> UInt8(bitPos & 7) }
                bitPos += 1
                i -= 1
            }
        }
        for b in videoId.utf8 { put(Int64(symbolOf(byte: b)), 6) }
        put(Int64(tag), 22)
        return out
    }

    public static func pack(_ payload: RingCodePayload) -> [UInt8]? {
        pack(videoId: payload.videoId, minuteBucket: payload.minuteBucket, random: payload.random)
    }

    public static func unpack(_ data: [UInt8]) -> RingUnpack {
        if data.count != dataBytes { return .rejected(.badLength) }
        func bit(_ pos: Int) -> Int { (Int(data[pos >> 3]) >> (7 - (pos & 7))) & 1 }
        var id: [UInt8] = []
        id.reserveCapacity(videoIdLength)
        var pos = 0
        for _ in 0..<videoIdLength {
            var sym = 0
            for _ in 0..<6 { sym = (sym << 1) | bit(pos); pos += 1 }
            id.append(alphabet[sym])
        }
        var bucket = 0
        for _ in 0..<6 { bucket = (bucket << 1) | bit(pos); pos += 1 }
        var random = 0
        for _ in 0..<randomBits { random = (random << 1) | bit(pos); pos += 1 }
        var check = 0
        for _ in 0..<checkBits { check = (check << 1) | bit(pos); pos += 1 }
        let text = String(decoding: id, as: UTF8.self)
        let expected = tagOf(videoId: text, bucket: bucket, random: random) & 0xFF
        if check != expected { return .rejected(.badChecksum) }
        return .ok(RingCodePayload(videoId: text, minuteBucket: bucket, random: random))
    }

    /// The whole 25-byte word for a code.
    public static func encodeCodeword(videoId: String, minuteBucket: Int, random: Int) -> [UInt8]? {
        guard let data = pack(videoId: videoId, minuteBucket: minuteBucket, random: random) else { return nil }
        return ReedSolomon.encode(data)
    }

    /// The 200 slot bits (0/1) for a code: the picture's information.
    public static func encodeSlots(videoId: String, minuteBucket: Int, random: Int) -> [UInt8]? {
        guard let word = encodeCodeword(videoId: videoId, minuteBucket: minuteBucket, random: random) else { return nil }
        return RingCodeLayout.codewordToSlots(word)
    }

    /// A corrected codeword's payload (its first 11 bytes).
    public static func fromCodeword(_ word: [UInt8]) -> RingUnpack {
        if word.count != ReedSolomon.n { return .rejected(.badLength) }
        return unpack(Array(word[0..<dataBytes]))
    }

    /// Is a code with this bucket still good on a clock reading of `nowMs`? `age` is the receiver's minute minus the code's,
    /// modulo 64, read as a number between -32 and 31.
    public static func freshness(bucket: Int, nowMs: Int64) -> Freshness {
        let age = Int(mod(Int64(bucketOf(nowMs: nowMs) - bucket + 32), Int64(minuteBuckets))) - 32
        if age > freshPastMinutes { return .expired }
        if age < -freshFutureMinutes { return .future }
        return .fresh
    }
}
