// Vorbis comments (FLAC `VORBIS_COMMENT` block) and the FLAC picture structure, following TagLib's
// `Ogg::XiphComment` and `FLAC::Picture`.

import Foundation

/// A Vorbis comment: vendor string, fields and embedded pictures (`METADATA_BLOCK_PICTURE` / legacy `COVERART`).
public struct VorbisComment: Sendable, Hashable {
    public var vendor: String
    /// Fields with TagLib's normalisation: upper-case keys, values in insertion order; rendered in key order.
    public var fields: TagProperties
    /// Pictures stored inside the comment (Ogg style). FLAC files normally use `PICTURE` blocks instead.
    public var pictures: [TagPicture]

    public init(vendor: String = "", fields: TagProperties = TagProperties(), pictures: [TagPicture] = []) {
        self.vendor = vendor
        self.fields = fields
        self.pictures = pictures
    }

    /// TagLib `XiphComment::checkKey`: ASCII 0x20…0x7D without `=`, at least one character.
    public static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7D && $0 != "=" }
    }

    /// TagLib `XiphComment::parse`. Malformed input yields whatever was read before the problem.
    public static func parse(_ data: [UInt8]) -> VorbisComment {
        var comment = VorbisComment()
        guard data.count >= 8 else { return comment }
        let vendorLength = Int(ByteIO.uint32LE(data, 0))
        guard vendorLength <= data.count - 8 else { return comment }
        var pos = 4
        comment.vendor = TagText.decodeUTF8(data[pos..<(pos + vendorLength)])
        pos += vendorLength
        let count = Int(ByteIO.uint32LE(data, pos))
        pos += 4
        guard count <= (data.count - 8) / 4 else { return comment }
        for _ in 0..<count {
            guard pos + 4 <= data.count else { break }
            let length = Int(ByteIO.uint32LE(data, pos))
            pos += 4
            guard length <= data.count - pos else { break }
            let entry = data[pos..<(pos + length)]
            pos += length
            guard let sep = entry.firstIndex(of: UInt8(ascii: "=")), sep > entry.startIndex else { continue }
            let key = TagText.asciiUpper(TagText.decodeUTF8(entry[entry.startIndex..<sep]))
            guard isValidKey(key) else { continue }
            let value = entry[(sep + 1)..<entry.endIndex]
            if key == "METADATA_BLOCK_PICTURE" || key == "COVERART" {
                guard let decoded = Data(base64Encoded: Data(value)), !decoded.isEmpty else { continue }
                if key == "METADATA_BLOCK_PICTURE" {
                    if let picture = FLACPicture.parse([UInt8](decoded)) { comment.pictures.append(picture) }
                } else {
                    comment.pictures.append(TagPicture(data: decoded, mimeType: "image/", pictureType: 0))
                }
            } else {
                comment.fields.insert(key, [TagText.decodeUTF8(value)])
            }
        }
        return comment
    }

    /// TagLib `XiphComment::render(addFramingBit)`: vendor, fields in key order, then pictures as base64
    /// `METADATA_BLOCK_PICTURE` fields. FLAC uses no framing bit; Ogg Vorbis does.
    public func render(framingBit: Bool = false) -> Data {
        var out: [UInt8] = []
        let vendorBytes = Array(vendor.utf8)
        ByteIO.appendUInt32LE(UInt32(vendorBytes.count), to: &out)
        out += vendorBytes
        let fieldCount = fields.reduce(0) { $0 + $1.values.count } + pictures.count
        ByteIO.appendUInt32LE(UInt32(fieldCount), to: &out)
        for (key, values) in fields {
            for v in values {
                let entry = Array(key.utf8) + [UInt8(ascii: "=")] + Array(v.utf8)
                ByteIO.appendUInt32LE(UInt32(entry.count), to: &out)
                out += entry
            }
        }
        for p in pictures {
            let encoded = Array(Data(FLACPicture.render(p)).base64EncodedString().utf8)
            ByteIO.appendUInt32LE(UInt32(encoded.count + 23), to: &out)
            out += Array("METADATA_BLOCK_PICTURE=".utf8)
            out += encoded
        }
        if framingBit { out.append(1) }
        return Data(out)
    }

    /// TagLib `XiphComment::isEmpty`: no field has a value.
    public var isEmpty: Bool { !fields.contains { !$0.values.isEmpty } }

    /// TagLib `XiphComment::properties()`.
    public var properties: TagProperties { fields }

    /// TagLib `XiphComment::setProperties()`: keys missing from `properties` are removed, invalid keys are ignored
    /// (and returned), keys with an empty list are removed, the others replaced.
    @discardableResult
    public mutating func setProperties(_ properties: TagProperties) -> TagProperties {
        var invalid = TagProperties()
        for key in fields.keys where !properties.contains(key) { fields.remove(key) }
        for (key, values) in properties {
            if !Self.isValidKey(key) {
                invalid.insert(key, values)
            } else if fields[key] != values {
                fields[key] = values.isEmpty ? nil : values
            }
        }
        return invalid
    }
}

/// The FLAC `PICTURE` structure (also used base64-encoded in Vorbis comments).
public enum FLACPicture {
    /// TagLib `FLAC::Picture::parse`.
    public static func parse(_ data: [UInt8]) -> TagPicture? {
        guard data.count >= 32 else { return nil }
        var pos = 0
        let type = ByteIO.uint32BE(data, pos); pos += 4
        let mimeLength = Int(ByteIO.uint32BE(data, pos)); pos += 4
        guard mimeLength <= data.count - pos - 24 else { return nil }
        let mime = TagText.decodeUTF8(data[pos..<(pos + mimeLength)]); pos += mimeLength
        let descriptionLength = Int(ByteIO.uint32BE(data, pos)); pos += 4
        guard descriptionLength <= data.count - pos - 20 else { return nil }
        let description = TagText.decodeUTF8(data[pos..<(pos + descriptionLength)]); pos += descriptionLength
        let width = ByteIO.uint32BE(data, pos); pos += 4
        let height = ByteIO.uint32BE(data, pos); pos += 4
        let depth = ByteIO.uint32BE(data, pos); pos += 4
        let colors = ByteIO.uint32BE(data, pos); pos += 4
        let length = Int(ByteIO.uint32BE(data, pos)); pos += 4
        guard length <= data.count - pos else { return nil }
        return TagPicture(data: Data(data[pos..<(pos + length)]), mimeType: mime, description: description,
                          pictureType: UInt8(truncatingIfNeeded: type), width: width, height: height,
                          colorDepth: depth, indexedColors: colors)
    }

    /// TagLib `FLAC::Picture::render`.
    public static func render(_ p: TagPicture) -> [UInt8] {
        var out: [UInt8] = []
        ByteIO.appendUInt32BE(UInt32(p.pictureType), to: &out)
        let mime = Array(p.mimeType.utf8)
        ByteIO.appendUInt32BE(UInt32(mime.count), to: &out)
        out += mime
        let description = Array(p.description.utf8)
        ByteIO.appendUInt32BE(UInt32(description.count), to: &out)
        out += description
        ByteIO.appendUInt32BE(p.width, to: &out)
        ByteIO.appendUInt32BE(p.height, to: &out)
        ByteIO.appendUInt32BE(p.colorDepth, to: &out)
        ByteIO.appendUInt32BE(p.indexedColors, to: &out)
        ByteIO.appendUInt32BE(UInt32(p.data.count), to: &out)
        out += [UInt8](p.data)
        return out
    }

    /// Android `buildVorbisPictureBlock` (SongMetadataEditor's Opus cover writer): a front-cover picture structure,
    /// base64 without line breaks. A blank MIME type becomes `image/jpeg`; Android measures width/height with
    /// BitmapFactory, here the caller passes them (0 when unknown).
    public static func vorbisPictureBlock(imageBytes: Data, mimeType: String, width: UInt32 = 0, height: UInt32 = 0) -> String {
        let safeMime = mimeType.isKotlinBlankString ? "image/jpeg" : mimeType
        let picture = TagPicture(data: imageBytes, mimeType: safeMime, description: "Front Cover", pictureType: 3,
                                 width: width, height: height)
        return Data(render(picture)).base64EncodedString()
    }
}

extension String {
    var isKotlinBlankString: Bool { KotlinText.isNullOrBlank(self) }
}
