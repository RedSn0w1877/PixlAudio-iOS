// ID3v2.2/2.3/2.4 tag reading and ID3v2.3/2.4 writing, following TagLib 2 (what the Android app uses through
// `com.kyant.taglib`): tag-level and frame-level unsynchronisation, extended headers, footers, the iTunes
// non-syncsafe frame-size workaround, ID3v2.2/2.3 → 2.4 frame conversion on read, 2.4 → 2.3 conversion on write,
// and TagLib's padding rule (reuse the old tag's space when the new frames fit).

import Foundation

/// An ID3v2 tag.
public struct ID3v2Tag: Sendable, Hashable {
    /// Major version as read (2, 3 or 4). New tags are 4. Frames are always held in their ID3v2.4 form.
    public var version: UInt8
    public var revision: UInt8
    public var frames: [ID3v2Frame]
    /// Size of the tag in the file (header, body and footer), 0 for a new tag.
    public var originalSize: Int
    /// The original header's size field (body without header/footer). TagLib keeps the tag this size when the new
    /// frames fit, so the audio does not move.
    public var originalBodySize: Int
    /// Header flags of the tag as read (informational; the writer never sets them).
    public var wasUnsynchronised: Bool
    public var hadExtendedHeader: Bool
    public var hadFooter: Bool
    public var experimental: Bool

    public init(version: UInt8 = 4, frames: [ID3v2Frame] = []) {
        self.version = version
        self.revision = 0
        self.frames = frames
        self.originalSize = 0
        self.originalBodySize = 0
        self.wasUnsynchronised = false
        self.hadExtendedHeader = false
        self.hadFooter = false
        self.experimental = false
    }

    /// TagLib's minimum padding (`MinPaddingSize`) and the cap on reused padding (`MaxPaddingSize`).
    public static let minPaddingSize = 1024
    public static let maxPaddingSize = 1024 * 1024

    // MARK: Locating

    /// The total size (header + body + footer) of the ID3v2 tag starting at `offset`, or nil when there is no valid
    /// ID3v2 header there. Works for any major version, so unsupported tags can still be skipped or replaced.
    public static func totalSize(in data: Data, at offset: Int = 0) -> Int? {
        guard offset >= 0, offset + 10 <= data.count else { return nil }
        let h = data.bytes(offset..<(offset + 10))
        guard h[0] == 0x49, h[1] == 0x44, h[2] == 0x33, h[3] != 0xFF, h[4] != 0xFF,
              ByteIO.isSyncsafe(h, 6) else { return nil }
        let size = Int(ByteIO.syncsafe(h, 6))
        let footer = h[3] == 4 && h[5] & 0x10 != 0
        return 10 + size + (footer ? 10 : 0)
    }

    // MARK: Reading

    /// Parses the ID3v2 tag at `offset`. Returns nil when there is no valid header or the major version is not 2–4.
    public static func parse(_ data: Data, at offset: Int = 0) -> ID3v2Tag? {
        guard let total = totalSize(in: data, at: offset) else { return nil }
        let h = data.bytes(offset..<(offset + 10))
        let major = h[3]
        guard (2...4).contains(major) else { return nil }
        let flags = h[5]
        let bodySize = Int(ByteIO.syncsafe(h, 6))
        var tag = ID3v2Tag(version: major)
        tag.revision = h[4]
        tag.originalSize = total
        tag.originalBodySize = bodySize
        tag.wasUnsynchronised = flags & 0x80 != 0
        tag.hadExtendedHeader = major >= 3 && flags & 0x40 != 0
        tag.experimental = major >= 3 && flags & 0x20 != 0
        tag.hadFooter = major == 4 && flags & 0x10 != 0
        var body = data.bytes((offset + 10)..<(offset + 10 + bodySize))
        if tag.wasUnsynchronised && major <= 3 { body = Unsynchronisation.decode(body[...]) }
        tag.frames = parseFrames(body, major: major, tagUnsynchronised: tag.wasUnsynchronised,
                                 extendedHeader: tag.hadExtendedHeader)
        return tag
    }

    /// Frames removed when an ID3v2.3 tag is upgraded (TagLib `FrameFactory::updateFrame`); `TDAT`/`TIME` are first
    /// folded into `TDRC`.
    static let droppedV23Frames: Set<String> = ["EQUA", "RVAD", "TIME", "TRDA", "TSIZ", "TDAT"]
    static let droppedV22Frames: Set<String> = ["CRM", "EQU", "LNK", "RVA", "TIM", "TSI", "TDA"]

    static func parseFrames(_ body: [UInt8], major: UInt8, tagUnsynchronised: Bool, extendedHeader: Bool) -> [ID3v2Frame] {
        var pos = 0
        if extendedHeader {
            if major == 3 {
                let extSize = Int(ByteIO.uint32BE(body, 0))
                if 4 + extSize <= body.count { pos = 4 + extSize }
            } else {
                let extSize = Int(ByteIO.syncsafe(body, 0))
                if extSize <= body.count { pos = extSize }
            }
        }
        let headerSize = major == 2 ? 6 : 10
        let idLength = major == 2 ? 3 : 4
        var frames: [ID3v2Frame] = []
        var tdat: [UInt8]?
        var time: [UInt8]?
        var tdatCount = 0
        var timeCount = 0

        while pos < body.count - headerSize {
            if body[pos] == 0 { break }  // padding
            let idBytes = body[pos..<(pos + idLength)]
            guard ID3v2Frame.isValidID(idBytes) else { break }
            var id = String(decoding: idBytes, as: UTF8.self)
            var size: Int
            var status: UInt8 = 0
            var format: UInt8 = 0
            switch major {
            case 2:
                size = Int(ByteIO.uint24BE(body, pos + 3))
            case 3:
                size = Int(ByteIO.uint32BE(body, pos + 4))
                status = body[pos + 8]
                format = body[pos + 9]
            default:
                size = Int(ByteIO.syncsafe(body, pos + 4))
                status = body[pos + 8]
                format = body[pos + 9]
                // iTunes writes ID3v2.4 tags with ID3v2.3 (plain integer) frame sizes.
                if size > 127 && !isValidFrameID(body, pos + headerSize + size) {
                    let plain = Int(ByteIO.uint32BE(body, pos + 4))
                    if isValidFrameID(body, pos + headerSize + plain) { size = plain }
                }
            }
            let hasDataLength = major == 4 && format & 0x01 != 0
            let remaining = body.count - pos
            guard size > (hasDataLength ? 4 : 0), size <= remaining else { break }
            let start = pos + headerSize
            let end = min(start + size, body.count)
            var frameBody = Array(body[start..<end])
            pos += headerSize + size

            var discardOnTag = false, discardOnFile = false, readOnly = false
            var compressed = false, encrypted = false, grouped = false
            if major == 3 {
                discardOnTag = status & 0x80 != 0; discardOnFile = status & 0x40 != 0; readOnly = status & 0x20 != 0
                compressed = format & 0x80 != 0; encrypted = format & 0x40 != 0; grouped = format & 0x20 != 0
            } else if major == 4 {
                discardOnTag = status & 0x40 != 0; discardOnFile = status & 0x20 != 0; readOnly = status & 0x10 != 0
                grouped = format & 0x40 != 0; compressed = format & 0x08 != 0; encrypted = format & 0x04 != 0
                if tagUnsynchronised || format & 0x02 != 0 {
                    frameBody = Unsynchronisation.decode(frameBody[...])
                }
            }

            // ID conversion to ID3v2.4.
            if major == 2 {
                if droppedV22Frames.contains(id) { continue }
                if id == "PIC" {
                    let content: ID3v2Frame.Content = ID3v2Frame.parsePIC(frameBody).map { .picture($0) } ?? .binary(Data(frameBody))
                    frames.append(ID3v2Frame(id: "APIC", content: content))
                    continue
                }
                guard let mapped = v22FrameIDs[id] else { continue }  // unknown 3-character frames cannot be written
                id = mapped
            } else if major == 3 {
                if id == "TDAT" { tdat = frameBody; tdatCount += 1; continue }
                if id == "TIME" { time = frameBody; timeCount += 1; continue }
                if droppedV23Frames.contains(id) { continue }
                if id == "TORY" { id = "TDOR" } else if id == "TYER" { id = "TDRC" } else if id == "IPLS" { id = "TIPL" }
            }

            let content: ID3v2Frame.Content
            if compressed || encrypted {
                content = .opaque(body: Data(frameBody), formatFlags: major == 4 ? format & ~0x02 : format, version: major)
            } else {
                if grouped, !frameBody.isEmpty { frameBody.removeFirst() }
                if hasDataLength { frameBody = frameBody.count >= 4 ? Array(frameBody[4...]) : [] }
                var parsed = ID3v2Frame.parseContent(id: id, body: frameBody, version: major)
                if id == "TCON", case .text(let enc, let values) = parsed {
                    parsed = .text(encoding: enc, values: updateGenre(values))
                }
                content = parsed
            }
            frames.append(ID3v2Frame(id: id, content: content, discardOnTagAlteration: discardOnTag,
                                     discardOnFileAlteration: discardOnFile, readOnly: readOnly))
        }

        // TagLib `FrameFactory::rebuildAggregateFrames`: TYER (now TDRC) + TDAT (+ TIME) → one ISO date.
        if major < 4, tdatCount == 1, let tdat, tdat.count >= 5 {
            let tdrcIndices = frames.indices.filter { frames[$0].id == "TDRC" }
            if tdrcIndices.count == 1, case .text(let enc, let values) = frames[tdrcIndices[0]].content,
               values.count == 1, values[0].utf16.count == 4 {
                let date = Array(decodeAggregate(tdat).utf16)
                if date.count == 4 {
                    var value = values[0] + "-" + String(decoding: date[2..<4], as: UTF16.self) + "-"
                        + String(decoding: date[0..<2], as: UTF16.self)
                    if timeCount == 1, let time, time.count >= 5 {
                        let t = Array(decodeAggregate(time).utf16)
                        if t.count == 4 {
                            value += "T" + String(decoding: t[0..<2], as: UTF16.self) + ":"
                                + String(decoding: t[2..<4], as: UTF16.self)
                        }
                    }
                    frames[tdrcIndices[0]].content = .text(encoding: enc, values: [value])
                }
            }
        }
        return frames
    }

    /// `String(data.mid(1), String::Type(data[0]))` for the TDAT/TIME aggregation.
    private static func decodeAggregate(_ body: [UInt8]) -> String {
        guard let enc = ID3v2TextEncoding(rawValue: body[0]) else { return "" }
        return TagText.decode(body[1...], enc)
    }

    /// Whether 4 valid frame-ID characters start at `i` (TagLib `isValidFrameID`).
    static func isValidFrameID(_ b: [UInt8], _ i: Int) -> Bool {
        guard i >= 0, i + 4 <= b.count else { return false }
        return ID3v2Frame.isValidID(b[i..<(i + 4)])
    }

    /// TagLib `FrameFactory::updateGenre`: splits ID3v1-style `(17)Rock` references out of `TCON` values.
    static func updateGenre(_ fields: [String]) -> [String] {
        var result: [String] = []
        for field in fields {
            var s = Array(field.utf16)
            while !s.isEmpty, s[0] == 0x28, let close = s[1...].firstIndex(of: 0x29) {
                let code = String(decoding: s[1..<close], as: UTF16.self)
                s = Array(s[(close + 1)...])
                let rest = String(decoding: s, as: UTF16.self)
                if let n = TagLibInt.parse(code), n >= 0, n <= 255, ID3v1Genres.name(n) != rest {
                    result.append(code)
                } else if code == "RX" || code == "CR" {
                    result.append(code)
                }
            }
            if !s.isEmpty { result.append(String(decoding: s, as: UTF16.self)) }
        }
        return result
    }

    /// TagLib's ID3v2.2 → 2.4 frame ID table (`frameConversion2`); `PIC` is handled separately.
    static let v22FrameIDs: [String: String] = [
        "BUF": "RBUF", "CNT": "PCNT", "COM": "COMM", "CRA": "AENC", "ETC": "ETCO", "GEO": "GEOB", "IPL": "TIPL",
        "MCI": "MCDI", "MLL": "MLLT", "POP": "POPM", "REV": "RVRB", "SLT": "SYLT", "STC": "SYTC", "TAL": "TALB",
        "TBP": "TBPM", "TCM": "TCOM", "TCO": "TCON", "TCP": "TCMP", "TCR": "TCOP", "TDY": "TDLY", "TEN": "TENC",
        "TFT": "TFLT", "TKE": "TKEY", "TLA": "TLAN", "TLE": "TLEN", "TMT": "TMED", "TOA": "TOAL", "TOF": "TOFN",
        "TOL": "TOLY", "TOR": "TDOR", "TOT": "TOAL", "TP1": "TPE1", "TP2": "TPE2", "TP3": "TPE3", "TP4": "TPE4",
        "TPA": "TPOS", "TPB": "TPUB", "TRC": "TSRC", "TRD": "TDRC", "TRK": "TRCK", "TS2": "TSO2", "TSA": "TSOA",
        "TSC": "TSOC", "TSP": "TSOP", "TSS": "TSSE", "TST": "TSOT", "TT1": "TIT1", "TT2": "TIT2", "TT3": "TIT3",
        "TXT": "TOLY", "TXX": "TXXX", "TYE": "TDRC", "UFI": "UFID", "ULT": "USLT", "WAF": "WOAF", "WAR": "WOAR",
        "WAS": "WOAS", "WCM": "WCOM", "WCP": "WCOP", "WPB": "WPUB", "WXX": "WXXX",
        "PCS": "PCST", "TCT": "TCAT", "TDR": "TDRL", "TDS": "TDES", "TID": "TGID", "WFD": "WFED", "MVN": "MVNM",
        "MVI": "MVIN", "GP1": "GRP1",
    ]

    // MARK: Writing

    /// Frames TagLib drops when writing ID3v2.3 (`downgradeFrames`).
    static let unsupportedV23Frames: Set<String> = [
        "ASPI", "EQU2", "RVA2", "SEEK", "SIGN", "TDRL", "TDTG", "TMOO", "TPRO", "TSOA", "TSOT", "TSST", "TSOP",
    ]

    /// The frames as written for `version`: for 3, TagLib's `downgradeFrames` (TDOR → TORY, TDRC → TYER/TDAT/TIME,
    /// TIPL/TMCL → IPLS, ID3v2.4-only frames dropped).
    func framesForWriting(version: UInt8) -> [ID3v2Frame] {
        guard version == 3 else { return frames }
        var out: [ID3v2Frame] = []
        var tdor: ID3v2Frame?, tdrc: ID3v2Frame?, tipl: ID3v2Frame?, tmcl: ID3v2Frame?
        for f in frames {
            if Self.unsupportedV23Frames.contains(f.id) { continue }
            switch f.id {
            case "TDOR": tdor = f
            case "TDRC": tdrc = f
            case "TIPL": tipl = f
            case "TMCL": tmcl = f
            default: out.append(f)
            }
        }
        func joined(_ f: ID3v2Frame?) -> [UInt16]? {
            guard let f, case .text(_, let values) = f.content else { return nil }
            return Array(values.joined(separator: " ").utf16)
        }
        func str(_ u: ArraySlice<UInt16>) -> String { String(decoding: u, as: UTF16.self) }
        if let content = joined(tdor), content.count >= 4 {
            out.append(.text("TORY", str(content[0..<4]), encoding: .latin1))
        }
        if let content = joined(tdrc), content.count >= 4 {
            out.append(.text("TYER", str(content[0..<4]), encoding: .latin1))
            if content.count >= 10 && content[4] == 0x2D && content[7] == 0x2D {
                out.append(.text("TDAT", str(content[8..<10]) + str(content[5..<7]), encoding: .latin1))
                if content.count >= 16 && content[10] == 0x54 && content[13] == 0x3A {
                    out.append(.text("TIME", str(content[11..<13]) + str(content[14..<16]), encoding: .latin1))
                }
            }
        }
        if tipl != nil || tmcl != nil {
            var people: [String] = []
            for f in [tmcl, tipl] {
                guard let f, case .text(_, let values) = f.content else { continue }
                var i = 0
                while i + 1 < values.count { people.append(values[i]); people.append(values[i + 1]); i += 2 }
            }
            out.append(.text("IPLS", people, encoding: .latin1))
        }
        return out
    }

    /// Renders the frames (without header and padding) for `version` 3 or 4.
    public func renderFrames(version: UInt8 = 4) -> Data {
        let v: UInt8 = version == 3 ? 3 : 4
        var out: [UInt8] = []
        for frame in framesForWriting(version: v) {
            if frame.discardOnTagAlteration { continue }
            let idBytes = Array(frame.id.utf8)
            guard idBytes.count == 4, ID3v2Frame.isValidID(idBytes[...]) else { continue }
            guard let body = frame.renderBody(version: v), !body.isEmpty else { continue }
            out += idBytes
            if v == 4 { ByteIO.appendSyncsafe(UInt32(body.count), to: &out) } else { ByteIO.appendUInt32BE(UInt32(body.count), to: &out) }
            out.append(0)
            if case .opaque(_, let formatFlags, _) = frame.content { out.append(formatFlags) } else { out.append(0) }
            out += body
        }
        return Data(out)
    }

    /// TagLib's padding: reuse the original tag size when the frames fit and the leftover is not more than 1 % of the
    /// file (at least 1 KiB, at most 1 MiB); otherwise 1 KiB.
    public static func paddingSize(framesSize: Int, originalBodySize: Int, fileLength: Int?) -> Int {
        let padding = originalBodySize - framesSize
        if padding <= 0 { return minPaddingSize }
        var threshold = (fileLength ?? 0) / 100
        threshold = max(threshold, minPaddingSize)
        threshold = min(threshold, maxPaddingSize)
        return padding > threshold ? minPaddingSize : padding
    }

    /// Renders the complete tag (header, frames, padding) as ID3v2.`version` (3 or 4). `fileLength` is the length
    /// of the whole file the tag belongs to (for TagLib's padding threshold). The writer never unsynchronises and
    /// writes no extended header or footer, like TagLib.
    public func render(version: UInt8 = 4, fileLength: Int? = nil) -> Data {
        let v: UInt8 = version == 3 ? 3 : 4
        let framesData = renderFrames(version: v)
        let padding = Self.paddingSize(framesSize: framesData.count, originalBodySize: originalBodySize,
                                       fileLength: fileLength)
        var out: [UInt8] = [0x49, 0x44, 0x33, v, 0, 0]
        ByteIO.appendSyncsafe(UInt32(framesData.count + padding), to: &out)
        out.reserveCapacity(out.count + framesData.count + padding)
        out += framesData
        out += [UInt8](repeating: 0, count: padding)
        return Data(out)
    }
}

/// TagLib 2 `String::toInt(bool *ok)` (`wcstol` that must consume the whole string): leading whitespace, optional
/// sign, digits; an empty string is 0.
enum TagLibInt {
    static func parse(_ s: String) -> Int? {
        let u = Array(s.unicodeScalars)
        if u.isEmpty { return 0 }
        var i = 0
        while i < u.count, u[i] == " " || ("\t"..."\r").contains(u[i]) { i += 1 }
        var negative = false
        if i < u.count, u[i] == "+" || u[i] == "-" { negative = u[i] == "-"; i += 1 }
        let digitsStart = i
        var value = 0
        while i < u.count, ("0"..."9").contains(u[i]) {
            value = value * 10 + Int(u[i].value - 48)
            if value > Int(Int32.max) { return nil }
            i += 1
        }
        guard i > digitsStart, i == u.count else { return nil }
        return negative ? -value : value
    }
}
