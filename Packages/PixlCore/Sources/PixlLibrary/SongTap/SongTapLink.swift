// The text form of a beam, for a QR code (Song Tap): `pixlsong1:` and the payload's bytes in base64url without
// padding. Strict on the way back: only the 64 url-safe characters, no padding, and a length and trailing bits that
// only `encode` produces, so one payload has exactly one link. A transliteration of `SongTapLink.kt`.

/// The link a QR code carries.
public enum SongTapLink {
    public static let prefix = "pixlsong1:"

    private static let alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    public static func encode(_ payloadBytes: [UInt8]) -> String {
        var out = Array(prefix.utf8)
        out.reserveCapacity(prefix.utf8.count + (payloadBytes.count * 4 + 2) / 3)
        var i = 0
        while i + 2 < payloadBytes.count {
            let n = (Int(payloadBytes[i]) << 16) | (Int(payloadBytes[i + 1]) << 8) | Int(payloadBytes[i + 2])
            out.append(alphabet[(n >> 18) & 63]); out.append(alphabet[(n >> 12) & 63])
            out.append(alphabet[(n >> 6) & 63]); out.append(alphabet[n & 63])
            i += 3
        }
        switch payloadBytes.count - i {
        case 1:
            let n = Int(payloadBytes[i]) << 16
            out.append(alphabet[(n >> 18) & 63]); out.append(alphabet[(n >> 12) & 63])
        case 2:
            let n = (Int(payloadBytes[i]) << 16) | (Int(payloadBytes[i + 1]) << 8)
            out.append(alphabet[(n >> 18) & 63]); out.append(alphabet[(n >> 12) & 63]); out.append(alphabet[(n >> 6) & 63])
        default:
            break
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The payload bytes inside `link`, or nil when it is not exactly a link `encode` could have written.
    public static func decode(_ link: String) -> [UInt8]? {
        let bytes = Array(link.utf8)
        let head = Array(prefix.utf8)
        if bytes.count < head.count || Array(bytes[0..<head.count]) != head { return nil }
        let body = Array(bytes[head.count...])
        if body.isEmpty || body.count % 4 == 1 { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(body.count * 3 / 4)
        var acc = 0
        var bits = 0
        for c in body {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            acc = (acc << 6) | v
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((acc >> bits) & 0xFF))
                acc &= (1 << bits) - 1
            }
        }
        // Leftover bits must be zero: that is what makes the encoding unique.
        if acc != 0 { return nil }
        return out
    }
}
