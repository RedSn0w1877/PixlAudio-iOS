// Ports of the image helpers in Android's `AudioMetadataUtils.kt`: `guessImageMimeType` (Java's
// `URLConnection.guessContentTypeFromStream`), `imageExtensionFromMimeType`, and a header check standing in for
// `isValidImageData` (BitmapFactory bounds decoding, which PixlCore cannot do).

import Foundation

public enum ImageSniffing {
    /// Java `URLConnection.guessContentTypeFromStream` over the first 16 bytes (what Android's `guessImageMimeType`
    /// returns). The FlashPix branch (Microsoft Structured Storage + `checkfpx`) is not ported and returns nil.
    public static func guessContentType(_ data: Data) -> String? {
        let head = data.bytes(0..<min(16, data.count))
        func c(_ i: Int) -> Int { i - 1 < head.count ? Int(head[i - 1]) : -1 }
        let c1 = c(1), c2 = c(2), c3 = c(3), c4 = c(4), c5 = c(5), c6 = c(6), c7 = c(7), c8 = c(8)
        let c9 = c(9), c10 = c(10), c11 = c(11), c12 = c(12), c13 = c(13), c14 = c(14), c15 = c(15), c16 = c(16)
        func ch(_ s: Character) -> Int { Int(s.asciiValue!) }

        if c1 == 0xCA && c2 == 0xFE && c3 == 0xBA && c4 == 0xBE { return "application/java-vm" }
        if c1 == 0xAC && c2 == 0xED { return "application/x-java-serialized-object" }
        if c1 == ch("<") {
            func word(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> Bool {
                c2 == ch(a) && c3 == ch(b) && c4 == ch(c) && c5 == ch(d)
            }
            let lower = word("h", "t", "m", "l") || word("h", "e", "a", "d") || word("b", "o", "d", "y")
            let upper = word("H", "T", "M", "L") || word("H", "E", "A", "D") || word("B", "O", "D", "Y")
            if c2 == ch("!") || lower || upper { return "text/html" }
            if c2 == ch("?") && c3 == ch("x") && c4 == ch("m") && c5 == ch("l") && c6 == ch(" ") { return "application/xml" }
        }
        if c1 == 0xEF && c2 == 0xBB && c3 == 0xBF {
            if c4 == ch("<") && c5 == ch("?") && c6 == ch("x") { return "application/xml" }
        }
        if c1 == 0xFE && c2 == 0xFF {
            if c3 == 0 && c4 == ch("<") && c5 == 0 && c6 == ch("?") && c7 == 0 && c8 == ch("x") { return "application/xml" }
        }
        if c1 == 0xFF && c2 == 0xFE {
            if c3 == ch("<") && c4 == 0 && c5 == ch("?") && c6 == 0 && c7 == ch("x") && c8 == 0 { return "application/xml" }
        }
        if c1 == 0x00 && c2 == 0x00 && c3 == 0xFE && c4 == 0xFF {
            if c5 == 0 && c6 == 0 && c7 == 0 && c8 == ch("<") && c9 == 0 && c10 == 0 && c11 == 0 && c12 == ch("?")
                && c13 == 0 && c14 == 0 && c15 == 0 && c16 == ch("x") { return "application/xml" }
        }
        if c1 == 0xFF && c2 == 0xFE && c3 == 0x00 && c4 == 0x00 {
            if c5 == ch("<") && c6 == 0 && c7 == 0 && c8 == 0 && c9 == ch("?") && c10 == 0 && c11 == 0 && c12 == 0
                && c13 == ch("x") && c14 == 0 && c15 == 0 && c16 == 0 { return "application/xml" }
        }
        if c1 == ch("G") && c2 == ch("I") && c3 == ch("F") && c4 == ch("8") { return "image/gif" }
        if c1 == ch("#") && c2 == ch("d") && c3 == ch("e") && c4 == ch("f") { return "image/x-bitmap" }
        if c1 == ch("!") && c2 == ch(" ") && c3 == ch("X") && c4 == ch("P") && c5 == ch("M") && c6 == ch("2") { return "image/x-pixmap" }
        if c1 == 137 && c2 == 80 && c3 == 78 && c4 == 71 && c5 == 13 && c6 == 10 && c7 == 26 && c8 == 10 { return "image/png" }
        if c1 == 0xFF && c2 == 0xD8 && c3 == 0xFF {
            if c4 == 0xE0 || c4 == 0xEE { return "image/jpeg" }
            if c4 == 0xE1 && c7 == ch("E") && c8 == ch("x") && c9 == ch("i") && c10 == ch("f") && c11 == 0 { return "image/jpeg" }
        }
        if (c1 == 0x49 && c2 == 0x49 && c3 == 0x2A && c4 == 0x00) || (c1 == 0x4D && c2 == 0x4D && c3 == 0x00 && c4 == 0x2A) {
            return "image/tiff"
        }
        if c1 == 0x2E && c2 == 0x73 && c3 == 0x6E && c4 == 0x64 { return "audio/basic" }
        if c1 == 0x64 && c2 == 0x6E && c3 == 0x73 && c4 == 0x2E { return "audio/basic" }
        if c1 == ch("R") && c2 == ch("I") && c3 == ch("F") && c4 == ch("F") { return "audio/x-wav" }
        return nil
    }

    /// Android `imageExtensionFromMimeType` (case-insensitive variant from `AudioMetadataUtils.kt`).
    public static func imageExtension(forMimeType mimeType: String?) -> String? {
        switch mimeType.map({ $0.lowercased() }) {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        default: return nil
        }
    }

    /// Stand-in for Android's `isValidImageData` (BitmapFactory decodes the bounds): true when the bytes start with
    /// the signature of a format Android's decoder reads — JPEG, PNG, GIF, WebP, BMP, HEIF/AVIF. The app can still
    /// confirm with ImageIO.
    public static func isLikelyDecodableImage(_ data: Data) -> Bool {
        let h = data.bytes(0..<min(16, data.count))
        guard h.count >= 4 else { return false }
        if h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF { return true }                       // JPEG
        if ByteIO.matches(h, 0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true } // PNG
        if ByteIO.matches(h, 0, Array("GIF87a".utf8)) || ByteIO.matches(h, 0, Array("GIF89a".utf8)) { return true }
        if ByteIO.matches(h, 0, Array("RIFF".utf8)) && ByteIO.matches(h, 8, Array("WEBP".utf8)) { return true }
        if h[0] == 0x42 && h[1] == 0x4D && h.count >= 14 { return true }                       // BMP
        if ByteIO.matches(h, 4, Array("ftyp".utf8)) && h.count >= 12 {
            let brand = String(decoding: h[8..<12], as: UTF8.self)
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis"].contains(brand) { return true }
        }
        return false
    }
}
