// Byte-level builders for synthetic test files (minimal but valid MP3, ID3v2.2/2.3/2.4, FLAC and MP4 structures,
// written by hand so the tests do not depend on the code under test) and fixture helpers.

import Foundation
import Testing
@testable import PixlTags

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        let url = try #require(Bundle.module.url(forResource: parts[0], withExtension: parts.count > 1 ? parts[1] : nil,
                                                 subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var chars = Array(s.replacingOccurrences(of: " ", with: ""))
        if chars.count % 2 == 1 { chars.removeLast() }
        var i = 0
        while i < chars.count {
            out.append(UInt8(String(chars[i...(i + 1)]), radix: 16)!)
            i += 2
        }
        return out
    }

    static func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
}

enum B {
    // MARK: Text

    static func latin1(_ s: String) -> [UInt8] { s.unicodeScalars.map { UInt8($0.value) } }
    static func utf8(_ s: String) -> [UInt8] { Array(s.utf8) }
    static func utf16LE(_ s: String, bom: Bool = true) -> [UInt8] {
        var out: [UInt8] = bom ? [0xFF, 0xFE] : []
        for u in s.utf16 { out += [UInt8(u & 0xFF), UInt8(u >> 8)] }
        return out
    }
    static func utf16BE(_ s: String, bom: Bool = true) -> [UInt8] {
        var out: [UInt8] = bom ? [0xFE, 0xFF] : []
        for u in s.utf16 { out += [UInt8(u >> 8), UInt8(u & 0xFF)] }
        return out
    }

    static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func be24(_ v: Int) -> [UInt8] { [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
    static func syncsafe(_ v: Int) -> [UInt8] {
        [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }

    // MARK: MPEG audio

    /// `count` silent MPEG-1 Layer III frames (128 kbit/s, 44.1 kHz, 417 bytes each).
    static func mp3Frames(_ count: Int = 3) -> [UInt8] {
        var out: [UInt8] = []
        for _ in 0..<count { out += [0xFF, 0xFB, 0x90, 0x64] + [UInt8](repeating: 0, count: 413) }
        return out
    }

    // MARK: ID3v2

    /// A complete ID3v2 tag: header (`version`, `flags`) + `body` (frames, padding, extended header…).
    static func id3(_ version: UInt8, flags: UInt8 = 0, _ body: [UInt8], footer: Bool = false) -> [UInt8] {
        var out: [UInt8] = [0x49, 0x44, 0x33, version, 0, flags] + syncsafe(body.count) + body
        if footer { out += [0x33, 0x44, 0x49, version, 0, flags] + syncsafe(body.count) }
        return out
    }

    static func frame22(_ id: String, _ body: [UInt8]) -> [UInt8] { latin1(id) + be24(body.count) + body }

    static func frame23(_ id: String, _ body: [UInt8], status: UInt8 = 0, format: UInt8 = 0) -> [UInt8] {
        latin1(id) + be32(body.count) + [status, format] + body
    }

    static func frame24(_ id: String, _ body: [UInt8], status: UInt8 = 0, format: UInt8 = 0, plainSize: Bool = false) -> [UInt8] {
        latin1(id) + (plainSize ? be32(body.count) : syncsafe(body.count)) + [status, format] + body
    }

    /// Text-frame body: encoding byte + already-encoded payload.
    static func text(_ encoding: UInt8, _ payload: [UInt8]) -> [UInt8] { [encoding] + payload }

    static func apicBody(encoding: UInt8 = 0, mime: String, type: UInt8, description: [UInt8], terminator: [UInt8] = [0],
                         data: [UInt8]) -> [UInt8] {
        [encoding] + latin1(mime) + [0, type] + description + terminator + data
    }

    // MARK: FLAC

    static func streamInfo(sampleRate: Int = 44_100, channels: Int = 2, bits: Int = 16, totalSamples: Int = 441_000) -> [UInt8] {
        var b = be16(4096) + be16(4096) + be24(14) + be24(9000)
        b.append(UInt8((sampleRate >> 12) & 0xFF))
        b.append(UInt8((sampleRate >> 4) & 0xFF))
        b.append(UInt8(((sampleRate & 0xF) << 4) | (((channels - 1) & 7) << 1) | (((bits - 1) >> 4) & 1)))
        b.append(UInt8((((bits - 1) & 0xF) << 4) | ((totalSamples >> 32) & 0xF)))
        b += be32(totalSamples & 0xFFFF_FFFF)
        b += [UInt8](repeating: 0xAB, count: 16)
        return b
    }

    static func vorbisComment(vendor: String = "reference libFLAC 1.4.3", _ fields: [String]) -> [UInt8] {
        var out = le32(vendor.utf8.count) + utf8(vendor) + le32(fields.count)
        for f in fields { out += le32(f.utf8.count) + utf8(f) }
        return out
    }

    static func flacPicture(type: Int = 3, mime: String = "image/png", description: String = "", width: Int = 2,
                            height: Int = 2, depth: Int = 24, colors: Int = 0, data: [UInt8]) -> [UInt8] {
        be32(type) + be32(mime.utf8.count) + utf8(mime) + be32(description.utf8.count) + utf8(description)
            + be32(width) + be32(height) + be32(depth) + be32(colors) + be32(data.count) + data
    }

    /// `fLaC` + blocks (the last one gets the last-block flag) + fake audio frames.
    static func flac(_ blocks: [(type: UInt8, body: [UInt8])], audio: [UInt8] = flacAudio) -> [UInt8] {
        var out = latin1("fLaC")
        for (i, b) in blocks.enumerated() {
            out.append(b.type | (i == blocks.count - 1 ? 0x80 : 0))
            out += be24(b.body.count) + b.body
        }
        return out + audio
    }

    /// Bytes standing in for FLAC frames (a frame sync followed by a recognisable pattern).
    static let flacAudio: [UInt8] = [0xFF, 0xF8, 0x69, 0x18] + (0..<200).map { UInt8($0 & 0xFF) }

    // MARK: MP4

    static func atom(_ name: String, _ body: [UInt8]) -> [UInt8] { be32(body.count + 8) + latin1(name) + body }

    static func data(type: Int, _ payload: [UInt8]) -> [UInt8] { atom("data", be32(type) + [0, 0, 0, 0] + payload) }

    static func textItem(_ name: String, _ values: String...) -> [UInt8] {
        atom(name, values.flatMap { data(type: 1, utf8($0)) })
    }

    static func freeForm(mean: String = "com.apple.iTunes", name: String, values: [String], type: Int = 1) -> [UInt8] {
        atom("----", atom("mean", [0, 0, 0, 0] + utf8(mean)) + atom("name", [0, 0, 0, 0] + utf8(name))
                + values.flatMap { data(type: type, utf8($0)) })
    }

    /// A minimal M4A: `ftyp`, `moov` (`mvhd` + `udta/meta/hdlr/ilst`), `mdat`.
    static func m4a(_ items: [UInt8], isoMeta: Bool = true, mdatFirst: Bool = false) -> [UInt8] {
        let hdlr = atom("hdlr", [0, 0, 0, 0] + [0, 0, 0, 0] + latin1("mdir") + latin1("appl") + [UInt8](repeating: 0, count: 9))
        let meta = atom("meta", (isoMeta ? [0, 0, 0, 0] : []) + hdlr + atom("ilst", items))
        let moov = atom("moov", atom("mvhd", [UInt8](repeating: 0, count: 100)) + atom("udta", meta))
        let ftyp = atom("ftyp", latin1("M4A ") + be32(0) + latin1("M4A ") + latin1("isom"))
        let mdat = atom("mdat", [0xDE, 0xAD, 0xBE, 0xEF])
        return mdatFirst ? ftyp + mdat + moov : ftyp + moov + mdat
    }

    // MARK: Images

    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D] + latin1("IHDR") + [0, 0, 0, 2, 0, 0, 0, 2]
    static let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + latin1("JFIF") + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xD9]
}

extension Data {
    var byteArray: [UInt8] { [UInt8](self) }
}
