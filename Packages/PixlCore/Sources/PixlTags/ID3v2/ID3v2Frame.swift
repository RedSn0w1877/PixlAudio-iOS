// ID3v2 frames: the typed model and the per-frame body codecs (TagLib's `TextIdentificationFrame`,
// `UserTextIdentificationFrame`, `CommentsFrame`, `UnsynchronizedLyricsFrame`, `SynchronizedLyricsFrame`,
// `AttachedPictureFrame`, `UrlLinkFrame`, `UserUrlLinkFrame`, `UniqueFileIdentifierFrame`).

import Foundation

/// Text with a language and a description (`COMM`, `USLT`).
public struct ID3v2LanguageText: Sendable, Hashable {
    public var encoding: ID3v2TextEncoding
    /// ISO-639-2 code, 3 ASCII characters (TagLib writes `XXX` when it is not 3 bytes long).
    public var language: String
    public var description: String
    public var text: String

    public init(encoding: ID3v2TextEncoding = .utf8, language: String = "XXX", description: String = "", text: String) {
        self.encoding = encoding
        self.language = language
        self.description = description
        self.text = text
    }
}

/// An attached picture (`APIC`, or `PIC` in ID3v2.2) and the encoding of its description.
public struct ID3v2Picture: Sendable, Hashable {
    public var encoding: ID3v2TextEncoding
    public var picture: TagPicture

    public init(encoding: ID3v2TextEncoding = .latin1, picture: TagPicture) {
        self.encoding = encoding
        self.picture = picture
    }
}

/// One ID3v2 frame. IDs are always the 4-character ID3v2.3/2.4 IDs (ID3v2.2 frames are converted when read).
public struct ID3v2Frame: Sendable, Hashable {
    public var id: String
    public var content: Content
    /// Status flag "tag alter preservation": the frame must be discarded when the tag is altered. TagLib drops
    /// such frames when it writes, and so does `ID3v2Tag.render`.
    public var discardOnTagAlteration: Bool
    /// Status flag "file alter preservation" (informational).
    public var discardOnFileAlteration: Bool
    /// Status flag "read only" (informational).
    public var readOnly: Bool

    public enum Content: Sendable, Hashable {
        /// `T***` (except `TXXX`) and the Apple text frames `WFED`, `MVNM`, `MVIN`, `GRP1`.
        case text(encoding: ID3v2TextEncoding, values: [String])
        /// `TXXX`.
        case userText(encoding: ID3v2TextEncoding, description: String, values: [String])
        /// `W***` (except `WXXX`).
        case url(String)
        /// `WXXX`.
        case userURL(encoding: ID3v2TextEncoding, description: String, url: String)
        /// `COMM`.
        case comment(ID3v2LanguageText)
        /// `USLT`.
        case unsyncedLyrics(ID3v2LanguageText)
        /// `SYLT`.
        case syncedLyrics(ID3v2SyncedLyrics)
        /// `APIC`.
        case picture(ID3v2Picture)
        /// `UFID`.
        case uniqueFileIdentifier(owner: String, identifier: Data)
        /// Any other frame, or one that could not be parsed: the frame body (after unsynchronisation and the data
        /// length indicator were removed), written back unchanged.
        case binary(Data)
        /// A compressed or encrypted frame, kept byte for byte with its format flags. Only written back when the tag
        /// keeps its version (the flag layouts differ between ID3v2.3 and 2.4).
        case opaque(body: Data, formatFlags: UInt8, version: UInt8)
    }

    public init(id: String, content: Content, discardOnTagAlteration: Bool = false,
                discardOnFileAlteration: Bool = false, readOnly: Bool = false) {
        self.id = id
        self.content = content
        self.discardOnTagAlteration = discardOnTagAlteration
        self.discardOnFileAlteration = discardOnFileAlteration
        self.readOnly = readOnly
    }

    // MARK: Convenience constructors

    /// A text frame with UTF-8 encoding (TagLib's default for new frames; rendered as UTF-16 in ID3v2.3).
    public static func text(_ id: String, _ values: [String], encoding: ID3v2TextEncoding = .utf8) -> ID3v2Frame {
        ID3v2Frame(id: id, content: .text(encoding: encoding, values: values))
    }

    public static func text(_ id: String, _ value: String, encoding: ID3v2TextEncoding = .utf8) -> ID3v2Frame {
        text(id, [value], encoding: encoding)
    }

    public static func userText(_ description: String, _ values: [String], encoding: ID3v2TextEncoding = .utf8) -> ID3v2Frame {
        ID3v2Frame(id: "TXXX", content: .userText(encoding: encoding, description: description, values: values))
    }

    public static func userText(_ description: String, _ value: String, encoding: ID3v2TextEncoding = .utf8) -> ID3v2Frame {
        userText(description, [value], encoding: encoding)
    }

    public static func unsyncedLyrics(_ text: String, description: String = "", language: String = "XXX",
                                      encoding: ID3v2TextEncoding = .utf8) -> ID3v2Frame {
        ID3v2Frame(id: "USLT", content: .unsyncedLyrics(ID3v2LanguageText(encoding: encoding, language: language,
                                                                           description: description, text: text)))
    }

    public static func comment(_ text: String, description: String = "", language: String = "XXX",
                               encoding: ID3v2TextEncoding = .utf8) -> ID3v2Frame {
        ID3v2Frame(id: "COMM", content: .comment(ID3v2LanguageText(encoding: encoding, language: language,
                                                                   description: description, text: text)))
    }

    public static func picture(_ picture: TagPicture, encoding: ID3v2TextEncoding = .latin1) -> ID3v2Frame {
        ID3v2Frame(id: "APIC", content: .picture(ID3v2Picture(encoding: encoding, picture: picture)))
    }

    public static func syncedLyrics(_ lyrics: ID3v2SyncedLyrics) -> ID3v2Frame {
        ID3v2Frame(id: "SYLT", content: .syncedLyrics(lyrics))
    }

    /// The values of a text frame, or the values of a `TXXX` frame (description excluded).
    public var textValues: [String]? {
        switch content {
        case .text(_, let values): return values
        case .userText(_, _, let values): return values
        default: return nil
        }
    }

    // MARK: Frame kinds

    /// Whether `id` is parsed as a text-identification frame.
    static func isTextFrameID(_ id: String) -> Bool {
        (id.hasPrefix("T") && id != "TXXX") || id == "WFED" || id == "MVNM" || id == "MVIN" || id == "GRP1"
    }

    /// Whether `id` is a valid frame ID (A–Z, 0–9).
    static func isValidID(_ bytes: ArraySlice<UInt8>) -> Bool {
        !bytes.isEmpty && bytes.allSatisfy { ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) }
    }
}

// MARK: - Body parsing

extension ID3v2Frame {
    /// Parses a frame body (unsynchronisation, grouping byte and data length indicator already removed).
    static func parseContent(id: String, body: [UInt8], version: UInt8) -> Content {
        if isTextFrameID(id) {
            guard body.count >= 2, let encoding = ID3v2TextEncoding(rawValue: body[0]) else { return .binary(Data(body)) }
            return .text(encoding: encoding, values: TagText.splitFields(body[1...], encoding, keepEmptyFirst: false))
        }
        switch id {
        case "TXXX":
            guard body.count >= 2, let encoding = ID3v2TextEncoding(rawValue: body[0]) else { return .binary(Data(body)) }
            var fields = TagText.splitFields(body[1...], encoding, keepEmptyFirst: true)
            let description = fields.isEmpty ? "" : fields.removeFirst()
            return .userText(encoding: encoding, description: description, values: fields)
        case "COMM", "USLT":
            guard body.count >= 5, let encoding = ID3v2TextEncoding(rawValue: body[0]) else { return .binary(Data(body)) }
            let language = String(decoding: body[1..<4], as: UTF8.self)
            let parts = ByteIO.split(body[4...], encoding.delimiter, byteAlign: encoding.byteAlign, max: 2)
            var description = ""
            var text = ""
            if parts.count == 2 {
                if encoding == .utf16 {
                    let (d, order) = TagText.decodeUTF16(parts[0], fallback: .little)
                    description = d
                    text = TagText.decodeUTF16(parts[1], fallback: order).0
                } else {
                    description = TagText.decode(parts[0], encoding)
                    text = TagText.decode(parts[1], encoding)
                }
            }
            let value = ID3v2LanguageText(encoding: encoding, language: language, description: description, text: text)
            return id == "COMM" ? .comment(value) : .unsyncedLyrics(value)
        case "SYLT":
            guard let lyrics = ID3v2SyncedLyrics.parse(body) else { return .binary(Data(body)) }
            return .syncedLyrics(lyrics)
        case "APIC":
            guard let picture = parseAPIC(body) else { return .binary(Data(body)) }
            return .picture(picture)
        case "WXXX":
            guard body.count >= 2, let encoding = ID3v2TextEncoding(rawValue: body[0]) else { return .binary(Data(body)) }
            var pos = 1
            // TagLib stops (empty description and URL) when the description has no terminator.
            guard let description = TagText.readTerminated(body, encoding, &pos) else {
                return .userURL(encoding: encoding, description: "", url: "")
            }
            return .userURL(encoding: encoding, description: description, url: TagText.decodeLatin1(body[pos...]))
        case "UFID":
            var pos = 0
            guard let owner = TagText.readTerminated(body, .latin1, &pos) else { return .binary(Data(body)) }
            return .uniqueFileIdentifier(owner: owner, identifier: Data(body[pos...]))
        default:
            if id.hasPrefix("W") {
                return .url(TagText.decodeLatin1(body))
            }
            return .binary(Data(body))
        }
    }

    /// TagLib `AttachedPictureFrame::parseFields`.
    static func parseAPIC(_ data: [UInt8]) -> ID3v2Picture? {
        guard data.count >= 5, let encoding = ID3v2TextEncoding(rawValue: data[0]) else { return nil }
        var pos = 1
        let mime = TagText.readTerminated(data, .latin1, &pos) ?? ""
        guard pos + 1 < data.count else { return nil }
        let type = data[pos]
        pos += 1
        let description = TagText.readTerminated(data, encoding, &pos) ?? ""
        return ID3v2Picture(encoding: encoding,
                            picture: TagPicture(data: Data(data[pos...]), mimeType: mime, description: description,
                                                pictureType: type))
    }

    /// TagLib `AttachedPictureFrameV22::parseFields` (ID3v2.2 `PIC`: a 3-character image format instead of a MIME type).
    static func parsePIC(_ data: [UInt8]) -> ID3v2Picture? {
        guard data.count >= 5, let encoding = ID3v2TextEncoding(rawValue: data[0]) else { return nil }
        let format = TagText.decodeLatin1(data[1..<4])
        let mime: String
        switch TagText.asciiUpper(format) {
        case "JPG": mime = "image/jpeg"
        case "PNG": mime = "image/png"
        default: mime = "image/" + format
        }
        let type = data[4]
        var pos = 5
        let description = TagText.readTerminated(data, encoding, &pos) ?? ""
        return ID3v2Picture(encoding: encoding,
                            picture: TagPicture(data: Data(data[pos...]), mimeType: mime, description: description,
                                                pictureType: type))
    }
}

// MARK: - Body rendering

extension ID3v2Frame {
    /// Renders the frame body for `version` (3 or 4), or nil when the frame cannot be written in that version.
    func renderBody(version: UInt8) -> [UInt8]? {
        switch content {
        case .text(let encoding, let values):
            let enc = TagText.checkEncoding(values, encoding, version: version)
            var out: [UInt8] = [enc.rawValue]
            for (i, v) in values.enumerated() {
                if i > 0 { out += enc.delimiter }
                out += TagText.encode(v, enc)
            }
            return out
        case .userText(let encoding, let description, let values):
            let fields = [description] + values
            let enc = TagText.checkEncoding(fields, encoding, version: version)
            var out: [UInt8] = [enc.rawValue]
            for (i, v) in fields.enumerated() {
                if i > 0 { out += enc.delimiter }
                out += TagText.encode(v, enc)
            }
            return out
        case .url(let url):
            return TagText.encode(url, .latin1)
        case .userURL(let encoding, let description, let url):
            let enc = TagText.checkEncoding([description], encoding, version: version)
            return [enc.rawValue] + TagText.encode(description, enc) + enc.delimiter + TagText.encode(url, .latin1)
        case .comment(let value), .unsyncedLyrics(let value):
            let enc = TagText.checkEncoding([value.description, value.text], value.encoding, version: version)
            var out: [UInt8] = [enc.rawValue]
            out += Self.languageBytes(value.language)
            out += TagText.encode(value.description, enc) + enc.delimiter
            out += TagText.encode(value.text, enc)
            return out
        case .syncedLyrics(let lyrics):
            return lyrics.render(version: version)
        case .picture(let value):
            let enc = TagText.checkEncoding([value.picture.description], value.encoding, version: version)
            var out: [UInt8] = [enc.rawValue]
            out += TagText.encode(value.picture.mimeType, .latin1) + [0]
            out.append(value.picture.pictureType)
            out += TagText.encode(value.picture.description, enc) + enc.delimiter
            out += [UInt8](value.picture.data)
            return out
        case .uniqueFileIdentifier(let owner, let identifier):
            return TagText.encode(owner, .latin1) + [0] + [UInt8](identifier)
        case .binary(let body):
            return [UInt8](body)
        case .opaque(let body, _, let frameVersion):
            return frameVersion == version ? [UInt8](body) : nil
        }
    }

    /// TagLib writes the language when it is exactly 3 bytes, `XXX` otherwise.
    static func languageBytes(_ language: String) -> [UInt8] {
        let bytes = Array(language.utf8)
        return bytes.count == 3 ? bytes : Array("XXX".utf8)
    }
}
