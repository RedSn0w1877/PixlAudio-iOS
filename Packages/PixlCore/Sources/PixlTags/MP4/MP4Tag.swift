// MP4/M4A iTunes metadata reading (`moov/udta/meta/ilst`), following TagLib 2's `MP4::Tag` item parsing and its
// item → property-key table. Writing M4A is left to the app (AVFoundation passthrough export).

import Foundation

/// One `ilst` item value.
public enum MP4ItemValue: Sendable, Hashable {
    case strings([String])
    case intPair(Int, Int)
    case bool(Bool)
    case int(Int)
    case uint(UInt32)
    case byte(UInt8)
    case longLong(Int64)
    case covers([MP4Cover])
    /// Free-form or other items with non-text data.
    case binary([Data])
}

/// One `covr` image.
public struct MP4Cover: Sendable, Hashable {
    /// The `data` atom type: 13 JPEG, 14 PNG, 27 BMP, 12 GIF, 0 implicit.
    public var format: UInt32
    public var data: Data

    public var mimeType: String {
        switch format {
        case 13: return "image/jpeg"
        case 14: return "image/png"
        case 12: return "image/gif"
        case 27: return "image/bmp"
        default: return ""
        }
    }
}

/// The iTunes-style metadata of an MP4 file.
public struct MP4Tag: Sendable, Hashable {
    /// Items by name (`©nam`, `trkn`, `----:com.apple.iTunes:REPLAYGAIN_TRACK_GAIN`…), in file order.
    public var items: [(name: String, value: MP4ItemValue)]

    public static func == (a: MP4Tag, b: MP4Tag) -> Bool {
        a.items.count == b.items.count && zip(a.items, b.items).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        for item in items { hasher.combine(item.name); hasher.combine(item.value) }
    }

    /// The value of item `name`.
    public subscript(name: String) -> MP4ItemValue? { items.first { $0.name == name }?.value }

    // MARK: Parsing

    /// Atom-data types.
    static let typeUTF8: UInt32 = 1
    static let typeJPEG: UInt32 = 13
    static let typePNG: UInt32 = 14
    static let typeGIF: UInt32 = 12
    static let typeBMP: UInt32 = 27
    static let typeImplicit: UInt32 = 0

    /// Whether `data` looks like an ISO base media file (`ftyp` at offset 4).
    public static func isMP4(_ data: Data) -> Bool {
        data.count >= 8 && data.bytes(4..<8) == Array("ftyp".utf8)
    }

    /// Parses the `moov/udta/meta/ilst` items. Returns an empty tag when the file has no metadata; throws when the
    /// top-level atom structure is broken before `moov` is found.
    public static func parse(_ data: Data) throws -> MP4Tag {
        guard let moov = try findAtom(in: data, range: 0..<data.count, path: ["moov"]) else {
            throw TagError.invalid("MP4: no moov atom")
        }
        guard let udta = try findAtom(in: data, range: moov, path: ["udta"]),
              let meta = try findAtom(in: data, range: udta, path: ["meta"]) else { return MP4Tag(items: []) }
        let metaChildren = (meta.lowerBound + metaHeaderSkip(data, meta))..<meta.upperBound
        guard let ilst = try findAtom(in: data, range: metaChildren, path: ["ilst"]) else { return MP4Tag(items: []) }
        let bytes = data.bytes(ilst)
        var items: [(name: String, value: MP4ItemValue)] = []
        var pos = 0
        while pos + 8 <= bytes.count {
            var size = Int(ByteIO.uint32BE(bytes, pos))
            var headerSize = 8
            if size == 1 {
                guard pos + 16 <= bytes.count else { break }
                size = Int(clamping: ByteIO.uint64BE(bytes, pos + 8)); headerSize = 16
            } else if size == 0 {
                size = bytes.count - pos
            }
            guard size >= headerSize, pos + size <= bytes.count else { break }
            let name = atomName(bytes, pos + 4)
            let body = Array(bytes[(pos + headerSize)..<(pos + size)])
            // TagLib `MP4::Tag::addItem`: a repeated item name is ignored (the first one wins).
            if let item = parseItem(name: name, body: body), !items.contains(where: { $0.name == item.name }) {
                items.append(item)
            }
            pos += size
        }
        return MP4Tag(items: items)
    }

    /// Atom names are 4 bytes of ISO-8859-1 (`©` is 0xA9).
    static func atomName(_ b: [UInt8], _ i: Int) -> String { TagText.decodeLatin1(b[i..<(i + 4)].map { $0 == 0 ? 0x20 : $0 }) }

    /// The ISO `meta` box has 4 bytes of version/flags before its children; QuickTime's does not. Like TagLib 2,
    /// look at what follows to decide.
    static func metaHeaderSkip(_ data: Data, _ meta: Range<Int>) -> Int {
        guard meta.count >= 12 else { return 0 }
        let next = data.bytes((meta.lowerBound + 4)..<(meta.lowerBound + 8))
        let name = String(decoding: next, as: UTF8.self)
        return ["hdlr", "ilst", "mhdr", "ctry", "lang"].contains(name) ? 0 : 4
    }

    /// Finds the first child atom with `path[0]` inside `range` and recurses; returns the body range.
    static func findAtom(in data: Data, range: Range<Int>, path: [String]) throws -> Range<Int>? {
        guard let wanted = path.first else { return range }
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            let header = data.bytes(pos..<(pos + 8))
            var size = Int(ByteIO.uint32BE(header, 0))
            var headerSize = 8
            if size == 1 {
                guard pos + 16 <= range.upperBound else { throw TagError.truncated("MP4: 64-bit atom size") }
                size = Int(clamping: ByteIO.uint64BE(data.bytes((pos + 8)..<(pos + 16)), 0))
                headerSize = 16
            } else if size == 0 {
                size = range.upperBound - pos
            }
            guard size >= headerSize, pos + size <= range.upperBound else {
                throw TagError.invalid("MP4: atom size out of range")
            }
            if atomName(header, 4) == wanted {
                let body = (pos + headerSize)..<(pos + size)
                return try findAtom(in: data, range: body, path: Array(path.dropFirst()))
            }
            pos += size
        }
        return nil
    }

    /// The `data` (and `mean`/`name`) children of an item: TagLib `parseData2`.
    static func parseData(_ body: [UInt8], freeForm: Bool, expectedFlags: Int = -1) -> [(type: UInt32, data: [UInt8])] {
        var result: [(type: UInt32, data: [UInt8])] = []
        var pos = 0
        var i = 0
        while pos < body.count {
            guard pos + 12 <= body.count else { break }
            let length = Int(ByteIO.uint32BE(body, pos))
            guard length >= 12, pos + length <= body.count else { break }
            let name = atomName(body, pos + 4)
            let flags = ByteIO.uint32BE(body, pos + 8)
            if freeForm && i < 2 {
                if i == 0 && name != "mean" { return result }
                if i == 1 && name != "name" { return result }
                result.append((type: flags, data: Array(body[(pos + 12)..<(pos + length)])))
            } else {
                guard name == "data" else { return result }
                if expectedFlags == -1 || Int(flags) == expectedFlags {
                    let start = min(pos + 16, pos + length)
                    result.append((type: flags, data: Array(body[start..<(pos + length)])))
                }
            }
            pos += length
            i += 1
        }
        return result
    }

    /// TagLib 2 `ItemFactory` name → handler table.
    static let intPairItems: Set<String> = ["trkn", "disk"]
    static let boolItems: Set<String> = ["cpil", "pgap", "pcst", "shwm"]
    static let intItems: Set<String> = ["tmpo", "\u{A9}mvi", "\u{A9}mvc", "hdvd"]
    static let uintItems: Set<String> = ["tvsn", "tves", "cnID", "sfID", "atID", "geID", "cmID"]
    static let byteItems: Set<String> = ["stik", "rtng", "akID"]
    static let longLongItems: Set<String> = ["plID"]

    static func parseItem(name: String, body: [UInt8]) -> (name: String, value: MP4ItemValue)? {
        if name == "----" {
            let data = parseData(body, freeForm: true)
            guard data.count > 2 else { return nil }
            let fullName = "----:" + TagText.decodeUTF8(data[0].data) + ":" + TagText.decodeUTF8(data[1].data)
            let values = data[2...]
            let type = values.first!.type
            var same: [(type: UInt32, data: [UInt8])] = []
            for v in values { if v.type != type { break }; same.append(v) }
            if type == typeUTF8 {
                return (fullName, .strings(same.map { TagText.decodeUTF8($0.data) }))
            }
            return (fullName, .binary(same.map { Data($0.data) }))
        }
        if name == "covr" {
            var covers: [MP4Cover] = []
            var pos = 0
            while pos < body.count {
                guard pos + 12 <= body.count else { break }
                let length = Int(ByteIO.uint32BE(body, pos))
                guard length >= 12, pos + length <= body.count else { break }
                guard atomName(body, pos + 4) == "data" else { break }
                let flags = ByteIO.uint32BE(body, pos + 8)
                if [typeJPEG, typePNG, typeBMP, typeGIF, typeImplicit].contains(flags) {
                    let start = min(pos + 16, pos + length)
                    covers.append(MP4Cover(format: flags, data: Data(body[start..<(pos + length)])))
                }
                pos += length
            }
            return (name, .covers(covers))
        }
        if name == "gnre" {
            guard let first = parseData(body, freeForm: false).first, first.data.count >= 2 else { return nil }
            let index = Int(Int16(bitPattern: UInt16(first.data[0]) << 8 | UInt16(first.data[1])))
            guard index > 0 else { return nil }
            return ("\u{A9}gen", .strings([ID3v1Genres.name(index - 1)]))
        }
        if intPairItems.contains(name) {
            guard let first = parseData(body, freeForm: false).first, first.data.count >= 6 else { return nil }
            return (name, .intPair(Int(ByteIO.int16BE(first.data, 2)), Int(ByteIO.int16BE(first.data, 4))))
        }
        if boolItems.contains(name) {
            guard let first = parseData(body, freeForm: false).first, !first.data.isEmpty else { return nil }
            return (name, .bool(first.data[0] != 0))
        }
        if intItems.contains(name) {
            guard let first = parseData(body, freeForm: false).first, first.data.count >= 2 else { return nil }
            return (name, .int(Int(ByteIO.int16BE(first.data, 0))))
        }
        if uintItems.contains(name) {
            guard let first = parseData(body, freeForm: false).first, first.data.count >= 4 else { return nil }
            return (name, .uint(ByteIO.uint32BE(first.data, 0)))
        }
        if byteItems.contains(name) {
            guard let first = parseData(body, freeForm: false).first, !first.data.isEmpty else { return nil }
            return (name, .byte(first.data[0]))
        }
        if longLongItems.contains(name) {
            guard let first = parseData(body, freeForm: false).first, first.data.count >= 8 else { return nil }
            return (name, .longLong(Int64(bitPattern: ByteIO.uint64BE(first.data, 0))))
        }
        let texts = parseData(body, freeForm: false, expectedFlags: Int(typeUTF8))
        guard !texts.isEmpty else { return nil }
        return (name, .strings(texts.map { TagText.decodeUTF8($0.data) }))
    }

    // MARK: Properties

    static let freeFormPrefix = "----:com.apple.iTunes:"

    /// TagLib 2 MP4 item name → property key.
    static let keyByItem: [String: String] = [
        "\u{A9}nam": "TITLE", "\u{A9}ART": "ARTIST", "\u{A9}alb": "ALBUM", "\u{A9}cmt": "COMMENT",
        "\u{A9}gen": "GENRE", "\u{A9}day": "DATE", "\u{A9}wrt": "COMPOSER", "\u{A9}grp": "GROUPING",
        "aART": "ALBUMARTIST", "trkn": "TRACKNUMBER", "disk": "DISCNUMBER", "cpil": "COMPILATION", "tmpo": "BPM",
        "cprt": "COPYRIGHT", "\u{A9}lyr": "LYRICS", "\u{A9}too": "ENCODEDBY", "soal": "ALBUMSORT",
        "soaa": "ALBUMARTISTSORT", "soar": "ARTISTSORT", "sonm": "TITLESORT", "soco": "COMPOSERSORT",
        "sosn": "SHOWSORT", "shwm": "SHOWWORKMOVEMENT", "pgap": "GAPLESSPLAYBACK", "pcst": "PODCAST",
        "catg": "PODCASTCATEGORY", "desc": "PODCASTDESC", "egid": "PODCASTID", "purl": "PODCASTURL",
        "tves": "TVEPISODE", "tven": "TVEPISODEID", "tvnn": "TVNETWORK", "tvsn": "TVSEASON", "tvsh": "TVSHOW",
        "\u{A9}wrk": "WORK", "\u{A9}mvn": "MOVEMENTNAME", "\u{A9}mvi": "MOVEMENTNUMBER", "\u{A9}mvc": "MOVEMENTCOUNT",
        "ownr": "OWNER",
        "----:com.apple.iTunes:MusicBrainz Track Id": "MUSICBRAINZ_TRACKID",
        "----:com.apple.iTunes:MusicBrainz Artist Id": "MUSICBRAINZ_ARTISTID",
        "----:com.apple.iTunes:MusicBrainz Album Id": "MUSICBRAINZ_ALBUMID",
        "----:com.apple.iTunes:MusicBrainz Album Artist Id": "MUSICBRAINZ_ALBUMARTISTID",
        "----:com.apple.iTunes:MusicBrainz Release Group Id": "MUSICBRAINZ_RELEASEGROUPID",
        "----:com.apple.iTunes:MusicBrainz Release Track Id": "MUSICBRAINZ_RELEASETRACKID",
        "----:com.apple.iTunes:MusicBrainz Work Id": "MUSICBRAINZ_WORKID",
        "----:com.apple.iTunes:MusicBrainz Album Release Country": "RELEASECOUNTRY",
        "----:com.apple.iTunes:MusicBrainz Album Status": "RELEASESTATUS",
        "----:com.apple.iTunes:MusicBrainz Album Type": "RELEASETYPE",
        "----:com.apple.iTunes:ARTISTS": "ARTISTS", "----:com.apple.iTunes:originaldate": "ORIGINALDATE",
        "----:com.apple.iTunes:RELEASEDATE": "RELEASEDATE", "----:com.apple.iTunes:ASIN": "ASIN",
        "----:com.apple.iTunes:LABEL": "LABEL", "----:com.apple.iTunes:LYRICIST": "LYRICIST",
        "----:com.apple.iTunes:CONDUCTOR": "CONDUCTOR", "----:com.apple.iTunes:REMIXER": "REMIXER",
        "----:com.apple.iTunes:ENGINEER": "ENGINEER", "----:com.apple.iTunes:PRODUCER": "PRODUCER",
        "----:com.apple.iTunes:DJMIXER": "DJMIXER", "----:com.apple.iTunes:MIXER": "MIXER",
        "----:com.apple.iTunes:SUBTITLE": "SUBTITLE", "----:com.apple.iTunes:DISCSUBTITLE": "DISCSUBTITLE",
        "----:com.apple.iTunes:MOOD": "MOOD", "----:com.apple.iTunes:ISRC": "ISRC",
        "----:com.apple.iTunes:CATALOGNUMBER": "CATALOGNUMBER", "----:com.apple.iTunes:BARCODE": "BARCODE",
        "----:com.apple.iTunes:SCRIPT": "SCRIPT", "----:com.apple.iTunes:LANGUAGE": "LANGUAGE",
        "----:com.apple.iTunes:LICENSE": "LICENSE", "----:com.apple.iTunes:MEDIA": "MEDIA",
    ]

    /// The property key for an item name: the table above, else the suffix of a `----:com.apple.iTunes:` free-form
    /// name (how ReplayGain reaches Android's property map), else nil (unsupported).
    public static func propertyKey(forItem name: String) -> String? {
        if let key = keyByItem[name] { return key }
        if name.hasPrefix(freeFormPrefix) && name.count > freeFormPrefix.count {
            return String(name.dropFirst(freeFormPrefix.count))
        }
        return nil
    }

    /// TagLib `MP4::Tag::properties()` (items visited in name order, like TagLib's item map; binary free-form
    /// items give an empty value list).
    public var properties: TagProperties {
        var map = TagProperties()
        let sorted = items.sorted { $0.name.unicodeScalars.lexicographicallyPrecedes($1.name.unicodeScalars) }
        for (name, value) in sorted {
            guard let key = Self.propertyKey(forItem: name) else { continue }
            switch value {
            case .strings(let s): map[key] = s
            case .intPair(let a, let b): map[key] = [b != 0 ? "\(a)/\(b)" : "\(a)"]
            case .bool(let b): map[key] = [b ? "1" : "0"]
            case .int(let i): map[key] = ["\(i)"]
            case .uint(let u): map[key] = ["\(u)"]
            case .byte(let b): map[key] = ["\(b)"]
            case .longLong(let l): map[key] = ["\(l)"]
            case .binary: map[key] = []
            case .covers: continue
            }
        }
        return map
    }

    /// The `covr` images as pictures (front covers, empty description), TagLib's `PICTURE` complex property.
    public var pictures: [TagPicture] {
        guard case .covers(let covers)? = self["covr"] else { return [] }
        return covers.map { TagPicture(data: $0.data, mimeType: $0.mimeType, description: "", pictureType: TagPicture.frontCover) }
    }
}
