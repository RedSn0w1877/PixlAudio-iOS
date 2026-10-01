// FLAC metadata blocks: reading, Vorbis comment / picture editing and rewriting with TagLib's padding rule
// (`FLAC::File::scan` / `save`).

import Foundation

/// FLAC `STREAMINFO`.
public struct FLACStreamInfo: Sendable, Hashable {
    public var minBlockSize: UInt16
    public var maxBlockSize: UInt16
    public var minFrameSize: UInt32
    public var maxFrameSize: UInt32
    public var sampleRate: UInt32
    public var channels: UInt8
    public var bitsPerSample: UInt8
    public var totalSamples: UInt64
    public var md5: Data

    /// Parses the 34-byte `STREAMINFO` block body.
    public static func parse(_ b: [UInt8]) -> FLACStreamInfo? {
        guard b.count >= 34 else { return nil }
        let sampleRate = UInt32(b[10]) << 12 | UInt32(b[11]) << 4 | UInt32(b[12]) >> 4
        let channels = ((b[12] >> 1) & 0x07) + 1
        let bits = (((b[12] & 0x01) << 4) | (b[13] >> 4)) + 1
        let total = UInt64(b[13] & 0x0F) << 32 | UInt64(ByteIO.uint32BE(b, 14))
        return FLACStreamInfo(minBlockSize: ByteIO.uint16BE(b, 0), maxBlockSize: ByteIO.uint16BE(b, 2),
                              minFrameSize: ByteIO.uint24BE(b, 4), maxFrameSize: ByteIO.uint24BE(b, 7),
                              sampleRate: sampleRate, channels: channels, bitsPerSample: bits, totalSamples: total,
                              md5: Data(b[18..<34]))
    }

    /// Duration in milliseconds (nil when the sample rate or sample count is unknown).
    public var durationMs: Int64? {
        guard sampleRate > 0, totalSamples > 0 else { return nil }
        return Int64(totalSamples * 1000 / UInt64(sampleRate))
    }

    /// Android `SongMetadataEditor.isProblematicFlacFile`: reads the sample rate and bit depth at the fixed
    /// offsets 18…21 of the file (STREAMINFO right after `fLaC`) and flags files above 96 kHz or 24 bit, which
    /// Android routes away from TagLib. `fileExtension` must be `flac` (case-insensitive), as on Android.
    public static func analyze(fileHeader data: Data, fileExtension: String) -> FLACAnalysis {
        guard fileExtension.lowercased() == "flac" else { return .notFlac }
        let h = data.bytes(0..<min(42, data.count))
        guard h.count >= 42, h[0] == 0x66, h[1] == 0x4C, h[2] == 0x61, h[3] == 0x43 else { return .notFlac }
        let sampleRate = Int(h[18]) << 12 | Int(h[19]) << 4 | Int(h[20] & 0xF0) >> 4
        let bits = ((Int(h[20]) & 0x01) << 4 | (Int(h[21]) & 0xF0) >> 4) + 1
        return sampleRate > 96_000 || bits > 24 ? .problematic(sampleRate: sampleRate, bitsPerSample: bits)
                                                : .safe(sampleRate: sampleRate, bitsPerSample: bits)
    }
}

/// Result of `FLACStreamInfo.analyze` (Android's `FlacAnalysisResult`; `Unknown` was the I/O-error case).
public enum FLACAnalysis: Sendable, Hashable {
    case notFlac
    case safe(sampleRate: Int, bitsPerSample: Int)
    case problematic(sampleRate: Int, bitsPerSample: Int)
}

/// One metadata block. Padding blocks are not kept (TagLib drops them and writes one fresh padding block).
public enum FLACMetadataBlock: Sendable, Hashable {
    case streamInfo(Data)
    case vorbisComment(VorbisComment)
    case picture(TagPicture)
    case other(type: UInt8, data: Data)

    public static let streamInfoType: UInt8 = 0
    public static let paddingType: UInt8 = 1
    public static let applicationType: UInt8 = 2
    public static let seekTableType: UInt8 = 3
    public static let vorbisCommentType: UInt8 = 4
    public static let cueSheetType: UInt8 = 5
    public static let pictureType: UInt8 = 6

    var type: UInt8 {
        switch self {
        case .streamInfo: return Self.streamInfoType
        case .vorbisComment: return Self.vorbisCommentType
        case .picture: return Self.pictureType
        case .other(let type, _): return type
        }
    }

    func renderBody() -> [UInt8] {
        switch self {
        case .streamInfo(let d): return [UInt8](d)
        case .vorbisComment(let c): return [UInt8](c.render(framingBit: false))
        case .picture(let p): return FLACPicture.render(p)
        case .other(_, let d): return [UInt8](d)
        }
    }
}

/// The metadata of a FLAC file.
public struct FLACFile: Sendable, Hashable {
    /// Metadata blocks in file order (padding removed, duplicate Vorbis comments and invalid pictures dropped).
    public var blocks: [FLACMetadataBlock]
    /// Offset of `fLaC`.
    public var flacStart: Int
    /// Offset just past the last metadata block (where the audio frames start).
    public var streamStart: Int
    /// A leading ID3v2 tag, if any (kept byte for byte when the file is rewritten).
    public var id3v2: ID3v2Tag?
    /// A trailing ID3v1 tag, if any (kept byte for byte).
    public var id3v1: ID3v1Tag?

    /// TagLib's minimum padding (`MinPaddingLength`) and the cap on reused padding.
    public static let minPaddingLength = 4096
    public static let maxPaddingLength = 1024 * 1024

    /// Parses the metadata of a FLAC file (optionally preceded by ID3v2 tags).
    public static func parse(_ data: Data) throws -> FLACFile {
        var offset = 0
        var id3v2: ID3v2Tag?
        while let size = ID3v2Tag.totalSize(in: data, at: offset) {
            if id3v2 == nil { id3v2 = ID3v2Tag.parse(data, at: offset) }
            offset += size
        }
        // TagLib searches for "fLaC" after the ID3v2 tag; bound the search to 1 MiB of junk.
        let window = data.bytes(offset..<min(data.count, offset + 1024 * 1024 + 4))
        guard let magic = ByteIO.find(window, Array("fLaC".utf8), from: 0) else {
            throw TagError.invalid("FLAC: no fLaC marker")
        }
        let flacStart = offset + magic
        var pos = flacStart + 4
        var blocks: [FLACMetadataBlock] = []
        var sawComment = false
        while true {
            guard pos + 4 <= data.count else { throw TagError.truncated("FLAC: block header") }
            let header = data.bytes(pos..<(pos + 4))
            let type = header[0] & 0x7F
            let isLast = header[0] & 0x80 != 0
            let length = Int(ByteIO.uint24BE(header, 1))
            if blocks.isEmpty && type != FLACMetadataBlock.streamInfoType {
                throw TagError.invalid("FLAC: first block is not STREAMINFO")
            }
            if length == 0 && type != FLACMetadataBlock.paddingType && type != FLACMetadataBlock.seekTableType {
                throw TagError.invalid("FLAC: zero-sized metadata block")
            }
            guard pos + 4 + length <= data.count else { throw TagError.truncated("FLAC: metadata block") }
            let body = data.bytes((pos + 4)..<(pos + 4 + length))
            switch type {
            case FLACMetadataBlock.streamInfoType:
                blocks.append(.streamInfo(Data(body)))
            case FLACMetadataBlock.vorbisCommentType:
                if !sawComment { blocks.append(.vorbisComment(VorbisComment.parse(body))); sawComment = true }
            case FLACMetadataBlock.pictureType:
                if let picture = FLACPicture.parse(body) { blocks.append(.picture(picture)) }
            case FLACMetadataBlock.paddingType:
                break
            default:
                blocks.append(.other(type: type, data: Data(body)))
            }
            pos += 4 + length
            if isLast { break }
        }
        return FLACFile(blocks: blocks, flacStart: flacStart, streamStart: pos, id3v2: id3v2,
                        id3v1: ID3v1Tag.parse(fileData: data))
    }

    /// The parsed `STREAMINFO`.
    public var streamInfo: FLACStreamInfo? {
        for b in blocks { if case .streamInfo(let d) = b { return FLACStreamInfo.parse([UInt8](d)) } }
        return nil
    }

    /// The Vorbis comment block, if any. Setting it replaces the existing one (or adds one).
    public var vorbisComment: VorbisComment? {
        get {
            for b in blocks { if case .vorbisComment(let c) = b { return c } }
            return nil
        }
        set {
            if let i = blocks.firstIndex(where: { if case .vorbisComment = $0 { return true } else { return false } }) {
                if let newValue { blocks[i] = .vorbisComment(newValue) } else { blocks.remove(at: i) }
            } else if let newValue {
                blocks.append(.vorbisComment(newValue))
            }
        }
    }

    /// The `PICTURE` blocks (TagLib `FLAC::File::pictureList`).
    public var pictures: [TagPicture] {
        blocks.compactMap { if case .picture(let p) = $0 { return p } else { return nil } }
    }

    /// TagLib's `PICTURE` complex property setter: removes every picture block and appends the new ones.
    public mutating func setPictures(_ pictures: [TagPicture]) {
        blocks.removeAll { if case .picture = $0 { return true } else { return false } }
        blocks.append(contentsOf: pictures.map { .picture($0) })
    }

    /// TagLib `FLAC::File::properties()`: the first non-empty tag of Vorbis comment, ID3v2, ID3v1.
    public var properties: TagProperties {
        if let c = vorbisComment, !c.isEmpty { return c.properties }
        if let t = id3v2, !t.frames.isEmpty { return t.properties }
        if let t = id3v1 { return t.properties }
        return TagProperties()
    }

    /// TagLib `FLAC::File::setProperties()`: writes into the Vorbis comment (created when missing).
    @discardableResult
    public mutating func setProperties(_ properties: TagProperties) -> TagProperties {
        var comment = vorbisComment ?? VorbisComment()
        let invalid = comment.setProperties(properties)
        vorbisComment = comment
        return invalid
    }

    /// The metadata blocks as TagLib writes them (`FLAC::File::save`): the Vorbis comment goes before the first
    /// picture (or last), then one padding block. The padding reuses the original metadata space when the new blocks
    /// fit and the leftover is ≤ 1 % of the file (at least 4 KiB, at most 1 MiB); otherwise it is 4 KiB.
    /// Returns the bytes that replace `flacStart + 4 ..< streamStart`.
    public func renderMetadata(fileLength: Int) -> Data {
        var ordered: [FLACMetadataBlock] = []
        var pendingComment: FLACMetadataBlock? = .vorbisComment(vorbisComment ?? VorbisComment())
        for b in blocks {
            if case .vorbisComment = b { continue }
            if case .picture = b, let c = pendingComment { ordered.append(c); pendingComment = nil }
            ordered.append(b)
        }
        if let c = pendingComment { ordered.append(c) }
        var out: [UInt8] = []
        for b in ordered {
            let body = b.renderBody()
            out.append(b.type & 0x7F)
            ByteIO.appendUInt24BE(UInt32(body.count), to: &out)
            out += body
        }
        let originalLength = streamStart - (flacStart + 4)
        var padding = originalLength - out.count - 4
        if padding <= 0 {
            padding = Self.minPaddingLength
        } else {
            var threshold = fileLength / 100
            threshold = max(threshold, Self.minPaddingLength)
            threshold = min(threshold, Self.maxPaddingLength)
            if padding > threshold { padding = Self.minPaddingLength }
        }
        out.append(FLACMetadataBlock.paddingType | 0x80)
        ByteIO.appendUInt24BE(UInt32(padding), to: &out)
        out += [UInt8](repeating: 0, count: padding)
        return Data(out)
    }

    /// The whole file with the rewritten metadata (`fileData` must be the file this was parsed from).
    public func render(into fileData: Data) -> TagWriteResult {
        let metadata = renderMetadata(fileLength: fileData.count)
        return TagWriteResult(original: fileData, patches: [TagPatch(range: (flacStart + 4)..<streamStart, bytes: metadata)])
    }
}

/// One replaced byte range of a file.
public struct TagPatch: Sendable, Hashable {
    /// The range of the original file that is replaced.
    public var range: Range<Int>
    /// The bytes that replace it.
    public var bytes: Data

    public init(range: Range<Int>, bytes: Data) {
        self.range = range
        self.bytes = bytes
    }
}

/// The result of rewriting a file's tags.
public struct TagWriteResult: Sendable, Hashable {
    /// The complete new file.
    public var data: Data
    /// What changed, as non-overlapping patches of the original file in ascending order.
    public var patches: [TagPatch]

    /// Applies `patches` (ascending, non-overlapping) to `original`.
    public init(original: Data, patches: [TagPatch]) {
        var out = Data()
        out.reserveCapacity(original.count + patches.reduce(0) { $0 + $1.bytes.count - $1.range.count })
        var cursor = 0
        for p in patches {
            out.append(original.subdata(offsets: cursor..<p.range.lowerBound))
            out.append(p.bytes)
            cursor = p.range.upperBound
        }
        out.append(original.subdata(offsets: cursor..<original.count))
        self.data = out
        self.patches = patches
    }

    /// Whether every patch keeps its size, so the original file could be patched in place (the audio does not
    /// move).
    public var fitsInPlace: Bool { patches.allSatisfy { $0.bytes.count == $0.range.count } }
}
