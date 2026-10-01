// The 128-byte ID3v1/ID3v1.1 trailer (TagLib `ID3v1::Tag`). MP3 files without an ID3v2 tag fall back to it, the
// way TagLib's tag union does.

import Foundation

public struct ID3v1Tag: Sendable, Hashable {
    public var title: String
    public var artist: String
    public var album: String
    public var year: String
    public var comment: String
    /// ID3v1.1 track number (0 = none).
    public var track: UInt8
    /// ID3v1 genre index (255 = none).
    public var genre: UInt8

    public init(title: String = "", artist: String = "", album: String = "", year: String = "", comment: String = "",
                track: UInt8 = 0, genre: UInt8 = 255) {
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.comment = comment
        self.track = track
        self.genre = genre
    }

    public static let size = 128

    /// Parses the last 128 bytes of `data` when they start with `TAG`.
    public static func parse(fileData data: Data) -> ID3v1Tag? {
        guard data.count >= size else { return nil }
        return parse(data.bytes((data.count - size)..<data.count))
    }

    /// Whether the file ends with an ID3v1 tag.
    public static func isPresent(in data: Data) -> Bool {
        data.count >= size && data.byte(at: data.count - 128) == 0x54 && data.byte(at: data.count - 127) == 0x41
            && data.byte(at: data.count - 126) == 0x47
    }

    static func parse(_ b: [UInt8]) -> ID3v1Tag? {
        guard b.count == size, b[0] == 0x54, b[1] == 0x41, b[2] == 0x47 else { return nil }
        func field(_ start: Int, _ length: Int) -> String { strip(TagText.decodeLatin1(b[start..<(start + length)])) }
        var tag = ID3v1Tag()
        tag.title = field(3, 30)
        tag.artist = field(33, 30)
        tag.album = field(63, 30)
        tag.year = field(93, 4)
        // ID3v1.1: a zero byte before a non-zero track byte (a track of 0 cannot be told apart from the comment end).
        if b[97 + 28] == 0 && b[97 + 29] != 0 {
            tag.comment = field(97, 28)
            tag.track = b[97 + 29]
        } else {
            tag.comment = field(97, 30)
        }
        tag.genre = b[127]
        return tag
    }

    /// TagLib `String::stripWhiteSpace` (tab, LF, FF, CR, space).
    static func strip(_ s: String) -> String {
        let ws: Set<Unicode.Scalar> = ["\t", "\n", "\u{0C}", "\r", " "]
        let u = Array(s.unicodeScalars)
        var a = 0, b = u.count
        while a < b, ws.contains(u[a]) { a += 1 }
        while b > a, ws.contains(u[b - 1]) { b -= 1 }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: u[a..<b])
        return String(out)
    }

    /// The 128-byte tag.
    public func render() -> Data {
        func field(_ s: String, _ length: Int) -> [UInt8] {
            var bytes = TagText.encode(s, .latin1)
            if bytes.count > length { bytes = Array(bytes[0..<length]) }
            return bytes + [UInt8](repeating: 0, count: length - bytes.count)
        }
        var out: [UInt8] = [0x54, 0x41, 0x47]
        out += field(title, 30) + field(artist, 30) + field(album, 30) + field(year, 4)
        out += field(comment, 28)
        out.append(0)
        out.append(track)
        out.append(genre)
        return Data(out)
    }

    /// TagLib's generic `Tag::properties()` over the ID3v1 fields.
    public var properties: TagProperties {
        var map = TagProperties()
        if !title.isEmpty { map.insert("TITLE", [title]) }
        if !artist.isEmpty { map.insert("ARTIST", [artist]) }
        if !album.isEmpty { map.insert("ALBUM", [album]) }
        if !comment.isEmpty { map.insert("COMMENT", [comment]) }
        let genreName = ID3v1Genres.name(Int(genre))
        if !genreName.isEmpty { map.insert("GENRE", [genreName]) }
        if let y = TagLibInt.parse(year), y != 0 { map.insert("DATE", [String(y)]) }
        if track != 0 { map.insert("TRACKNUMBER", [String(track)]) }
        return map
    }

    /// TagLib's generic `Tag::setProperties()`: the first value of each basic key; numbers must parse whole.
    public mutating func setProperties(_ properties: TagProperties) {
        func value(_ key: String) -> String? { properties[key]?.first }
        title = value("TITLE") ?? ""
        artist = value("ARTIST") ?? ""
        album = value("ALBUM") ?? ""
        comment = value("COMMENT") ?? ""
        genre = value("GENRE").map { UInt8(clamping: ID3v1Genres.index(of: $0)) } ?? 255
        if let d = value("DATE"), let y = TagLibInt.parse(d), y > 0 { year = String(y) } else { year = "" }
        if let t = value("TRACKNUMBER"), let n = TagLibInt.parse(t), (0...255).contains(n) { track = UInt8(n) } else { track = 0 }
    }
}
