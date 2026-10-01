// TagLib 2's mapping between ID3v2 frames and property-map keys (`Frame::asProperties`, `Tag::properties`,
// `Tag::setProperties`, `Frame::createTextualFrame`) plus the picture and lyrics accessors. This is the layer the
// Android app actually sees: `propertyMap["TITLE"]`, `["REPLAYGAIN_TRACK_GAIN"]`, `["LYRICS"]`…

import Foundation

enum ID3v2Keys {
    /// TagLib `frameTranslation` (frame ID → property key).
    static let frameToKey: [(String, String)] = [
        ("TALB", "ALBUM"), ("TBPM", "BPM"), ("TCOM", "COMPOSER"), ("TCON", "GENRE"), ("TCOP", "COPYRIGHT"),
        ("TDEN", "ENCODINGTIME"), ("TDLY", "PLAYLISTDELAY"), ("TDOR", "ORIGINALDATE"), ("TDRC", "DATE"),
        ("TDRL", "RELEASEDATE"), ("TDTG", "TAGGINGDATE"), ("TENC", "ENCODEDBY"), ("TEXT", "LYRICIST"),
        ("TFLT", "FILETYPE"), ("TIT1", "WORK"), ("TIT2", "TITLE"), ("TIT3", "SUBTITLE"), ("TKEY", "INITIALKEY"),
        ("TLAN", "LANGUAGE"), ("TLEN", "LENGTH"), ("TMED", "MEDIA"), ("TMOO", "MOOD"), ("TOAL", "ORIGINALALBUM"),
        ("TOFN", "ORIGINALFILENAME"), ("TOLY", "ORIGINALLYRICIST"), ("TOPE", "ORIGINALARTIST"), ("TOWN", "OWNER"),
        ("TPE1", "ARTIST"), ("TPE2", "ALBUMARTIST"), ("TPE3", "CONDUCTOR"), ("TPE4", "REMIXER"),
        ("TPOS", "DISCNUMBER"), ("TPRO", "PRODUCEDNOTICE"), ("TPUB", "LABEL"), ("TRCK", "TRACKNUMBER"),
        ("TRSN", "RADIOSTATION"), ("TRSO", "RADIOSTATIONOWNER"), ("TSOA", "ALBUMSORT"), ("TSOC", "COMPOSERSORT"),
        ("TSOP", "ARTISTSORT"), ("TSOT", "TITLESORT"), ("TSO2", "ALBUMARTISTSORT"), ("TSRC", "ISRC"),
        ("TSSE", "ENCODING"), ("TSST", "DISCSUBTITLE"),
        ("WCOP", "COPYRIGHTURL"), ("WOAF", "FILEWEBPAGE"), ("WOAR", "ARTISTWEBPAGE"), ("WOAS", "AUDIOSOURCEWEBPAGE"),
        ("WORS", "RADIOSTATIONWEBPAGE"), ("WPAY", "PAYMENTWEBPAGE"), ("WPUB", "PUBLISHERWEBPAGE"),
        ("COMM", "COMMENT"),
        ("PCST", "PODCAST"), ("TCAT", "PODCASTCATEGORY"), ("TDES", "PODCASTDESC"), ("TGID", "PODCASTID"),
        ("WFED", "PODCASTURL"), ("MVNM", "MOVEMENTNAME"), ("MVIN", "MOVEMENTNUMBER"), ("GRP1", "GROUPING"),
        ("TCMP", "COMPILATION"),
    ]
    static let keyByFrame: [String: String] = Dictionary(frameToKey, uniquingKeysWith: { a, _ in a })
    static let frameByKey: [String: String] = Dictionary(frameToKey.map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })

    /// ID3v2.3 frames TagLib reads as `TDRC` (`deprecationMap`).
    static let deprecated: [String: String] = ["TRDA": "TDRC", "TDAT": "TDRC", "TYER": "TDRC", "TIME": "TDRC"]

    /// TagLib `txxxFrameTranslation` (upper-cased TXXX description → property key).
    static let txxxToKey: [(String, String)] = [
        ("MUSICBRAINZ ALBUM ID", "MUSICBRAINZ_ALBUMID"), ("MUSICBRAINZ ARTIST ID", "MUSICBRAINZ_ARTISTID"),
        ("MUSICBRAINZ ALBUM ARTIST ID", "MUSICBRAINZ_ALBUMARTISTID"),
        ("MUSICBRAINZ ALBUM RELEASE COUNTRY", "RELEASECOUNTRY"), ("MUSICBRAINZ ALBUM STATUS", "RELEASESTATUS"),
        ("MUSICBRAINZ ALBUM TYPE", "RELEASETYPE"), ("MUSICBRAINZ RELEASE GROUP ID", "MUSICBRAINZ_RELEASEGROUPID"),
        ("MUSICBRAINZ RELEASE TRACK ID", "MUSICBRAINZ_RELEASETRACKID"), ("MUSICBRAINZ WORK ID", "MUSICBRAINZ_WORKID"),
        ("ACOUSTID ID", "ACOUSTID_ID"), ("ACOUSTID FINGERPRINT", "ACOUSTID_FINGERPRINT"), ("MUSICIP PUID", "MUSICIP_PUID"),
    ]
    static let keyByTxxx: [String: String] = Dictionary(txxxToKey, uniquingKeysWith: { a, _ in a })
    static let txxxByKey: [String: String] = Dictionary(txxxToKey.map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })

    /// TagLib `involvedPeople` (TIPL role → property key).
    static let involvedPeople: [(String, String)] = [
        ("ARRANGER", "ARRANGER"), ("ENGINEER", "ENGINEER"), ("PRODUCER", "PRODUCER"), ("DJ-MIX", "DJMIXER"), ("MIX", "MIXER"),
    ]
    static let roleByKey: [String: String] = Dictionary(involvedPeople.map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })
    static let instrumentPrefix = "PERFORMER:"

    static func frameIDToKey(_ id: String) -> String? {
        if let key = keyByFrame[id] { return key }
        if let modern = deprecated[id] { return keyByFrame[modern] }
        return nil
    }

    static func txxxKey(_ description: String) -> String {
        let d = TagText.asciiUpper(description)
        return keyByTxxx[d] ?? d
    }

    static func txxxDescription(_ key: String) -> String {
        txxxByKey[TagText.asciiUpper(key)] ?? key
    }

    /// Kotlin/TagLib `String::split(",")`.
    static func splitComma(_ s: String) -> [String] {
        s.unicodeScalars.split(separator: ",", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }
}

extension ID3v2Frame {
    /// TagLib `Frame::asProperties` for this frame. Frames without a property mapping (pictures, SYLT, private
    /// data…) give an empty map; `setProperties` keeps them.
    public var properties: TagProperties {
        var map = TagProperties()
        switch content {
        case .text(_, let values):
            if id == "TIPL" { return Self.tiplProperties(values) }
            if id == "TMCL" { return Self.tmclProperties(values) }
            guard let key = ID3v2Keys.frameIDToKey(id) else { return map }
            var values = values
            if key == "GENRE" {
                values = values.map { v in TagLibInt.parse(v).map { ID3v1Genres.name($0) } ?? v }
            } else if key == "DATE" {
                values = values.map { v in
                    guard let t = v.firstIndex(of: "T") else { return v }
                    var s = v
                    s.replaceSubrange(t...t, with: " ")
                    return s
                }
            }
            map.insert(key, values)
        case .userText(_, let description, let values):
            if !values.isEmpty { map.insert(ID3v2Keys.txxxKey(description), values) }
        case .comment(let value):
            let key = TagText.asciiUpper(value.description)
            map.insert(key.isEmpty || key == "COMMENT" ? "COMMENT" : "COMMENT:" + key, [value.text])
        case .unsyncedLyrics(let value):
            let key = TagText.asciiUpper(value.description)
            map.insert(key.isEmpty || key == "LYRICS" ? "LYRICS" : "LYRICS:" + key, [value.text])
        case .url(let url):
            guard let key = ID3v2Keys.frameIDToKey(id) else { return map }
            map.insert(key, [url])
        case .userURL(_, let description, let url):
            let key = TagText.asciiUpper(description)
            map.insert(key.isEmpty || key == "URL" ? "URL" : "URL:" + key, [url])
        case .uniqueFileIdentifier(let owner, let identifier):
            if owner == "http://musicbrainz.org" {
                map.insert("MUSICBRAINZ_TRACKID", [TagText.decodeLatin1([UInt8](identifier))])
            }
        case .syncedLyrics, .picture, .binary, .opaque:
            break
        }
        return map
    }

    /// TagLib `makeTIPLProperties`: role/people pairs; any unknown role or an odd count makes the frame unsupported.
    static func tiplProperties(_ fields: [String]) -> TagProperties {
        var map = TagProperties()
        guard fields.count % 2 == 0 else { return map }
        var i = 0
        while i < fields.count {
            guard let pair = ID3v2Keys.involvedPeople.first(where: { $0.0 == fields[i] }) else { return TagProperties() }
            map.insert(pair.1, ID3v2Keys.splitComma(fields[i + 1]))
            i += 2
        }
        return map
    }

    /// TagLib `makeTMCLProperties`: `PERFORMER:<INSTRUMENT>` keys.
    static func tmclProperties(_ fields: [String]) -> TagProperties {
        var map = TagProperties()
        guard fields.count % 2 == 0 else { return map }
        var i = 0
        while i < fields.count {
            let instrument = TagText.asciiUpper(fields[i])
            if instrument.isEmpty { return TagProperties() }
            map.insert(ID3v2Keys.instrumentPrefix + instrument, ID3v2Keys.splitComma(fields[i + 1]))
            i += 2
        }
        return map
    }

    /// TagLib `Frame::createTextualFrame(key, values)`: the frame a property becomes when it is added.
    public static func forProperty(_ key: String, _ values: [String]) -> ID3v2Frame {
        let key = TagProperties.normalize(key)
        if let frameID = ID3v2Keys.frameByKey[key] {
            if frameID.hasPrefix("T") || ["WFED", "MVNM", "MVIN", "GRP1"].contains(frameID) {
                return .text(frameID, values, encoding: .utf8)
            }
            if frameID.hasPrefix("W") && values.count == 1 {
                return ID3v2Frame(id: frameID, content: .url(values[0]))
            }
            if frameID == "PCST" {
                return ID3v2Frame(id: "PCST", content: .binary(Data([0, 0, 0, 0])))
            }
        }
        if key == "MUSICBRAINZ_TRACKID" && values.count == 1 {
            return ID3v2Frame(id: "UFID", content: .uniqueFileIdentifier(owner: "http://musicbrainz.org",
                                                                        identifier: Data(TagText.encode(values[0], .latin1))))
        }
        if (key == "LYRICS" || key.hasPrefix("LYRICS:")) && values.count == 1 {
            let description = key == "LYRICS" ? key : String(key.dropFirst("LYRICS:".count))
            return .unsyncedLyrics(values[0], description: description, language: "XXX", encoding: .utf8)
        }
        if (key == "URL" || key.hasPrefix("URL:")) && values.count == 1 {
            let description = key == "URL" ? key : String(key.dropFirst("URL:".count))
            return ID3v2Frame(id: "WXXX", content: .userURL(encoding: .utf8, description: description, url: values[0]))
        }
        if (key == "COMMENT" || key.hasPrefix("COMMENT:")) && values.count == 1 {
            let description = key == "COMMENT" ? "" : String(key.dropFirst("COMMENT:".count))
            return .comment(values[0], description: description, language: "XXX", encoding: .utf8)
        }
        return .userText(ID3v2Keys.txxxDescription(key), values, encoding: .utf8)
    }
}

extension ID3v2Tag {
    /// TagLib `ID3v2::Tag::properties()`: every frame's properties merged in frame order (values of repeated keys
    /// are appended).
    public var properties: TagProperties {
        var map = TagProperties()
        for f in frames {
            for (key, values) in f.properties { map.insert(key, values) }
        }
        return map
    }

    /// TagLib `ID3v2::Tag::setProperties()`: frames whose properties are not all in `newProperties` (with equal
    /// values) are removed, frames that match are kept untouched, and the remaining properties become new frames
    /// (`TIPL`, `TMCL`, then one frame per key in key order). Frames without properties (pictures, SYLT…) stay.
    public mutating func setProperties(_ newProperties: TagProperties) {
        var single = TagProperties()
        var tipl = TagProperties()
        var tmcl = TagProperties()
        for (key, values) in newProperties {
            if ID3v2Keys.roleByKey[key] != nil { tipl.insert(key, values) }
            else if key.hasPrefix(ID3v2Keys.instrumentPrefix) { tmcl.insert(key, values) }
            else { single.insert(key, values) }
        }
        var kept: [ID3v2Frame] = []
        for frame in frames {
            let props = frame.properties
            if frame.id == "TIPL" {
                if tipl != props { continue } else { tipl.erase(props) }
            } else if frame.id == "TMCL" {
                if tmcl != props { continue } else { tmcl.erase(props) }
            } else if !single.contains(props) {
                continue
            } else {
                single.erase(props)
            }
            kept.append(frame)
        }
        if !tipl.isEmpty {
            var fields: [String] = []
            for (key, values) in tipl {
                guard let role = ID3v2Keys.roleByKey[key] else { continue }
                fields.append(role); fields.append(values.joined(separator: ","))
            }
            kept.append(.text("TIPL", fields, encoding: .latin1))
        }
        if !tmcl.isEmpty {
            var fields: [String] = []
            for (key, values) in tmcl {
                fields.append(String(key.dropFirst(ID3v2Keys.instrumentPrefix.count)))
                fields.append(values.joined(separator: ","))
            }
            kept.append(.text("TMCL", fields, encoding: .latin1))
        }
        for (key, values) in single {
            kept.append(ID3v2Frame.forProperty(key, values))
        }
        frames = kept
    }

    /// The attached pictures (`APIC`) in frame order.
    public var pictures: [TagPicture] {
        frames.compactMap { if case .picture(let p) = $0.content { return p.picture } else { return nil } }
    }

    /// TagLib's `PICTURE` complex property setter: removes every `APIC` frame and appends one per picture.
    public mutating func setPictures(_ pictures: [TagPicture]) {
        frames.removeAll { $0.id == "APIC" }
        for p in pictures { frames.append(.picture(p, encoding: .latin1)) }
    }

    /// The `SYLT` frames.
    public var syncedLyrics: [ID3v2SyncedLyrics] {
        frames.compactMap { if case .syncedLyrics(let s) = $0.content { return s } else { return nil } }
    }

    /// Replaces every `SYLT` frame with `lyrics` (nil removes them).
    public mutating func setSyncedLyrics(_ lyrics: ID3v2SyncedLyrics?) {
        frames.removeAll { $0.id == "SYLT" }
        if let lyrics { frames.append(.syncedLyrics(lyrics)) }
    }

    /// The `USLT` frames.
    public var unsyncedLyrics: [ID3v2LanguageText] {
        frames.compactMap { if case .unsyncedLyrics(let s) = $0.content { return s } else { return nil } }
    }

    /// The first frame with `id`.
    public func frame(_ id: String) -> ID3v2Frame? { frames.first { $0.id == id } }

    /// The `TXXX` frame with `description` (compared case-insensitively for ASCII), if any.
    public func userText(_ description: String) -> [String]? {
        let wanted = TagText.asciiUpper(description)
        for f in frames {
            if case .userText(_, let d, let values) = f.content, TagText.asciiUpper(d) == wanted { return values }
        }
        return nil
    }
}
