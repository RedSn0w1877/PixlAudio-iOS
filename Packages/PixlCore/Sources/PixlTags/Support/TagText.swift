// Text codecs for tags: ISO-8859-1, UTF-16 (with or without BOM), UTF-16BE and UTF-8, with TagLib's rules for
// terminators, field splitting and "decoded strings stop at the first NUL".

import Foundation

/// The four ID3v2 text encodings (the encoding byte of text-carrying frames).
public enum ID3v2TextEncoding: UInt8, Sendable, Hashable, CaseIterable {
    /// ISO-8859-1.
    case latin1 = 0
    /// UTF-16 with a byte-order mark (written little-endian with `FF FE`, like TagLib).
    case utf16 = 1
    /// UTF-16 big-endian without BOM (ID3v2.4 only).
    case utf16BE = 2
    /// UTF-8 (ID3v2.4 only).
    case utf8 = 3

    /// The string terminator / field delimiter: one NUL byte for single-byte encodings, two for UTF-16.
    var delimiter: [UInt8] { (self == .latin1 || self == .utf8) ? [0] : [0, 0] }

    /// Alignment used when searching for the delimiter.
    var byteAlign: Int { (self == .latin1 || self == .utf8) ? 1 : 2 }
}

enum TagText {
    /// Byte order of a UTF-16 run.
    enum ByteOrder: Sendable { case little, big }

    /// Cuts `s` at its first U+0000 (TagLib's `String(ByteVector, Type)` shrinks to `wcslen`).
    static func truncatedAtNul(_ s: String) -> String {
        guard let i = s.unicodeScalars.firstIndex(of: "\u{0}") else { return s }
        return String(s.unicodeScalars[..<i])
    }

    static func decodeLatin1<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var scalars = String.UnicodeScalarView()
        for b in bytes {
            if b == 0 { break }
            scalars.append(Unicode.Scalar(b))
        }
        return String(scalars)
    }

    static func decodeUTF8<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        truncatedAtNul(String(decoding: bytes, as: UTF8.self))
    }

    /// Decodes UTF-16. A leading BOM selects the byte order (and is dropped); otherwise `fallback` is used.
    /// Returns the decoded string and the byte order it used.
    static func decodeUTF16(_ bytes: ArraySlice<UInt8>, fallback: ByteOrder) -> (String, ByteOrder) {
        var order = fallback
        var start = bytes.startIndex
        if bytes.count >= 2 {
            let b0 = bytes[start], b1 = bytes[start + 1]
            if b0 == 0xFF && b1 == 0xFE { order = .little; start += 2 }
            else if b0 == 0xFE && b1 == 0xFF { order = .big; start += 2 }
        }
        var units: [UInt16] = []
        units.reserveCapacity((bytes.endIndex - start) / 2)
        var i = start
        while i + 1 < bytes.endIndex {
            let u = order == .little ? UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
                                     : UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
            units.append(u)
            i += 2
        }
        return (truncatedAtNul(String(decoding: units, as: UTF16.self)), order)
    }

    /// Whether `bytes` starts with a UTF-16 byte-order mark.
    static func hasBOM(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.count >= 2 else { return false }
        let b0 = bytes[bytes.startIndex], b1 = bytes[bytes.startIndex + 1]
        return (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF)
    }

    /// Decodes one string in `encoding`. For `.utf16` without a BOM, `utf16Fallback` gives the byte order.
    static func decode(_ bytes: ArraySlice<UInt8>, _ encoding: ID3v2TextEncoding,
                       utf16Fallback: ByteOrder = .little) -> String {
        switch encoding {
        case .latin1: return decodeLatin1(bytes)
        case .utf8: return decodeUTF8(bytes)
        case .utf16: return decodeUTF16(bytes, fallback: utf16Fallback).0
        case .utf16BE:
            // UTF-16BE never carries a BOM; a stray one is decoded as U+FEFF like TagLib.
            var units: [UInt16] = []
            var i = bytes.startIndex
            while i + 1 < bytes.endIndex { units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])); i += 2 }
            return truncatedAtNul(String(decoding: units, as: UTF16.self))
        }
    }

    /// Encodes `s` (without terminator). UTF-16 gets a little-endian BOM per string, like TagLib's
    /// `String::data(UTF16)`. Latin-1 maps scalars above U+00FF to `?`.
    static func encode(_ s: String, _ encoding: ID3v2TextEncoding) -> [UInt8] {
        switch encoding {
        case .latin1:
            return s.unicodeScalars.map { $0.value <= 0xFF ? UInt8($0.value) : UInt8(ascii: "?") }
        case .utf8:
            return Array(s.utf8)
        case .utf16:
            var out: [UInt8] = [0xFF, 0xFE]
            for u in s.utf16 { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
            return out
        case .utf16BE:
            var out: [UInt8] = []
            for u in s.utf16 { out.append(UInt8(u >> 8)); out.append(UInt8(u & 0xFF)) }
            return out
        }
    }

    /// Whether every scalar of `s` fits ISO-8859-1 (TagLib `String::isLatin1`).
    static func isLatin1(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { $0.value <= 0xFF } }

    /// ASCII-only upper-casing (TagLib `String::upper`, used for property keys).
    static func asciiUpper(_ s: String) -> String {
        guard s.utf8.contains(where: { $0 >= 0x61 && $0 <= 0x7A }) else { return s }
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u.value >= 0x61 && u.value <= 0x7A { scalars.append(Unicode.Scalar(u.value - 32)!) } else { scalars.append(u) }
        }
        return String(scalars)
    }

    /// TagLib `TextIdentificationFrame::parseFields`: splits a text-frame body (encoding byte excluded) into fields.
    /// Trailing NULs are stripped, the rest split on the delimiter; empty fields are dropped except the first one
    /// when `keepEmptyFirst` (TXXX descriptions). UTF-16 fields without a BOM inherit the first field's byte order.
    static func splitFields(_ body: ArraySlice<UInt8>, _ encoding: ID3v2TextEncoding, keepEmptyFirst: Bool) -> [String] {
        let align = encoding.byteAlign
        var length = body.count
        while length > 0 && body[body.startIndex + length - 1] == 0 { length -= 1 }
        while length % align != 0 { length += 1 }
        length = min(length, body.count)
        let content = body[body.startIndex..<(body.startIndex + length)]
        let chunks = ByteIO.split(content, encoding.delimiter, byteAlign: align)
        var fields: [String] = []
        var order: ByteOrder = .little
        var sawBOM = false
        for (index, chunk) in chunks.enumerated() {
            guard !chunk.isEmpty || (index == 0 && keepEmptyFirst) else { continue }
            if encoding == .utf16 {
                let hadBOM = hasBOM(chunk)
                let (s, used) = decodeUTF16(chunk, fallback: order)
                if hadBOM && !sawBOM { order = used; sawBOM = true }
                fields.append(s)
            } else {
                fields.append(decode(chunk, encoding))
            }
        }
        return fields
    }

    /// TagLib `Frame::readStringField`: reads a terminated string at `position` and advances past the terminator.
    /// Returns nil (and leaves `position` alone) when no terminator is found.
    static func readTerminated(_ data: [UInt8], _ encoding: ID3v2TextEncoding, _ position: inout Int,
                               utf16Fallback: ByteOrder = .little) -> String? {
        guard let end = ByteIO.find(data, encoding.delimiter, from: position, byteAlign: encoding.byteAlign) else {
            return nil
        }
        let s = decode(data[position..<end], encoding, utf16Fallback: utf16Fallback)
        position = end + encoding.delimiter.count
        return s
    }

    /// TagLib `Frame::checkTextEncoding`: the encoding a frame is rendered with. UTF-8 and UTF-16BE become UTF-16 in
    /// ID3v2.3; Latin-1 is upgraded (UTF-8 in v2.4, UTF-16 in v2.3) when a field does not fit.
    static func checkEncoding(_ fields: [String], _ encoding: ID3v2TextEncoding, version: UInt8) -> ID3v2TextEncoding {
        if (encoding == .utf8 || encoding == .utf16BE) && version != 4 { return .utf16 }
        if encoding != .latin1 { return encoding }
        for f in fields where !isLatin1(f) { return version == 4 ? .utf8 : .utf16 }
        return .latin1
    }
}
