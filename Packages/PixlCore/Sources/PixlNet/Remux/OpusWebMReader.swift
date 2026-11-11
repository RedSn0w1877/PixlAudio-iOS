// Reads the Opus packets out of a WebM (Matroska) audio file, as YouTube serves itag 251: EBML header, one Segment
// with Info, Tracks (one `A_OPUS` track whose CodecPrivate is the OpusHead), Cues, and Clusters of SimpleBlocks or
// BlockGroups. Nothing is decoded. Every packet's length comes from its own TOC byte, never from the WebM's 1 ms
// timestamps, and the timestamps are only used to prove that no packet is missing. Anything unexpected throws, and
// the caller plays AAC instead. References: the Matroska and EBML specs (RFC 9559, RFC 8794), the Opus codec
// mapping for Matroska, RFC 6716 section 3.1 (packet TOC) and RFC 7845 section 5.1 (OpusHead).

import Foundation

/// Why a WebM file could not be repackaged. The description is the diagnostics line.
public enum OpusRemuxError: Error, Equatable, Sendable, CustomStringConvertible {
    case notEBML
    case notWebM(String)
    case truncated(String)
    case malformed(String)
    case noOpusTrack
    case multipleAudioTracks
    case unsupported(String)
    case badOpusHead(String)
    case badPacket(index: Int, reason: String)
    case timestampDrift(index: Int, driftMicroseconds: Int64)
    case preSkipMismatch(codecDelaySamples: Int, preSkip: Int)
    case badEndTrim(String)
    case empty
    case tooLarge

    public var description: String {
        switch self {
        case .notEBML: "not an EBML file"
        case .notWebM(let docType): "not WebM (DocType \(docType))"
        case .truncated(let what): "file ends inside \(what)"
        case .malformed(let what): "malformed \(what)"
        case .noOpusTrack: "no Opus track"
        case .multipleAudioTracks: "more than one audio track"
        case .unsupported(let what): "unsupported: \(what)"
        case .badOpusHead(let why): "bad OpusHead: \(why)"
        case .badPacket(let index, let reason): "bad packet \(index): \(reason)"
        case .timestampDrift(let index, let drift): "packet \(index) is \(drift / 1000) ms away from its sample position"
        case .preSkipMismatch(let delay, let preSkip): "CodecDelay \(delay) samples but pre-skip \(preSkip)"
        case .badEndTrim(let why): "bad end trim: \(why)"
        case .empty: "no audio"
        case .tooLarge: "file too large"
        }
    }
}

/// The OpusHead identification header (RFC 7845 section 5.1, little-endian).
public struct OpusHead: Sendable, Equatable {
    public var version: UInt8
    public var channelCount: Int
    /// Samples at 48 kHz to drop from the decoder output at the start.
    public var preSkip: Int
    public var inputSampleRate: UInt32
    /// Q7.8 dB.
    public var outputGain: Int16
    public var mappingFamily: UInt8
    /// Family != 0 only.
    public var streamCount: Int?
    public var coupledCount: Int?
    public var channelMapping: [UInt8]

    public init(version: UInt8 = 1, channelCount: Int, preSkip: Int, inputSampleRate: UInt32, outputGain: Int16 = 0,
                mappingFamily: UInt8 = 0, streamCount: Int? = nil, coupledCount: Int? = nil, channelMapping: [UInt8] = []) {
        self.version = version
        self.channelCount = channelCount
        self.preSkip = preSkip
        self.inputSampleRate = inputSampleRate
        self.outputGain = outputGain
        self.mappingFamily = mappingFamily
        self.streamCount = streamCount
        self.coupledCount = coupledCount
        self.channelMapping = channelMapping
    }

    public init<C: Collection>(parsing bytes: C) throws where C.Element == UInt8 {
        let b = Array(bytes)
        guard b.count >= 19 else { throw OpusRemuxError.badOpusHead("\(b.count) bytes") }
        guard Array(b[0..<8]) == Array("OpusHead".utf8) else { throw OpusRemuxError.badOpusHead("no OpusHead magic") }
        // Version 1; any 0x0X is compatible (RFC 7845: the upper four bits are the major version).
        guard b[8] >> 4 == 0, b[8] != 0 else { throw OpusRemuxError.badOpusHead("version \(b[8])") }
        version = b[8]
        channelCount = Int(b[9])
        guard channelCount > 0 else { throw OpusRemuxError.badOpusHead("no channels") }
        preSkip = Int(b[10]) | Int(b[11]) << 8
        inputSampleRate = UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24
        outputGain = Int16(bitPattern: UInt16(b[16]) | UInt16(b[17]) << 8)
        mappingFamily = b[18]
        if mappingFamily == 0 {
            guard channelCount <= 2 else { throw OpusRemuxError.badOpusHead("family 0 with \(channelCount) channels") }
            streamCount = nil
            coupledCount = nil
            channelMapping = []
        } else {
            guard b.count >= 21 + channelCount else { throw OpusRemuxError.badOpusHead("short channel mapping table") }
            streamCount = Int(b[19])
            coupledCount = Int(b[20])
            channelMapping = Array(b[21..<(21 + channelCount)])
        }
    }
}

/// One Opus packet of the source file: where its bytes are and how many samples (at 48 kHz) it decodes to.
public struct OpusPacketRef: Sendable, Equatable {
    public var range: Range<Int>
    public var samples: Int

    public init(range: Range<Int>, samples: Int) {
        self.range = range
        self.samples = samples
    }
}

/// The Opus packet TOC byte (RFC 6716 section 3.1).
public enum OpusPacket {
    /// The longest packet the format allows: 120 ms.
    public static let maxSamples = 5760

    /// Samples per frame at 48 kHz for each of the 32 configurations (SILK 10/20/40/60 ms, hybrid 10/20 ms, CELT
    /// 2.5/5/10/20 ms).
    public static func frameSamples(config: Int) -> Int {
        switch config {
        case 0...11: return [480, 960, 1920, 2880][config & 3]
        case 12...15: return [480, 960][config & 1]
        default: return [120, 240, 480, 960][config & 3]
        }
    }

    /// The packet's length in samples at 48 kHz, or nil when it is not a valid packet header.
    public static func sampleCount<C: Collection>(_ packet: C) -> Int? where C.Element == UInt8 {
        guard let toc = packet.first else { return nil }
        let perFrame = frameSamples(config: Int(toc >> 3))
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count >= 2 else { return nil }
            frames = Int(packet[packet.index(after: packet.startIndex)] & 0x3F)
        }
        let total = frames * perFrame
        guard frames > 0, total <= maxSamples else { return nil }
        return total
    }
}

/// The Opus stream of a WebM file.
public struct OpusWebMStream: Sendable, Equatable {
    public var head: OpusHead
    public var packets: [OpusPacketRef]
    /// Samples cut from the end of the last packet (the last block's DiscardPadding).
    public var endTrim: Int
    /// Info's TimestampScale, in nanoseconds.
    public var timestampScaleNs: Int64
    /// Info's Duration, in nanoseconds (nil when the file has none).
    public var durationNs: Double?
    public var codecDelayNs: Int64?
    public var seekPreRollNs: Int64?
    public var docType: String

    /// Every decoded sample, pre-skip and end padding included.
    public var totalSamples: Int { packets.reduce(0) { $0 + $1.samples } }
    /// What plays: everything minus the pre-skip and the end trim.
    public var validSamples: Int { totalSamples - head.preSkip - endTrim }
}

/// The WebM reader.
public enum OpusWebMReader {
    // Element ids (with their length marker bits, as written in the file).
    static let idEBML: UInt32 = 0x1A45DFA3
    static let idDocType: UInt32 = 0x4282
    static let idSegment: UInt32 = 0x18538067
    static let idSeekHead: UInt32 = 0x114D9B74
    static let idInfo: UInt32 = 0x1549A966
    static let idTimestampScale: UInt32 = 0x2AD7B1
    static let idDuration: UInt32 = 0x4489
    static let idTracks: UInt32 = 0x1654AE6B
    static let idTrackEntry: UInt32 = 0xAE
    static let idTrackNumber: UInt32 = 0xD7
    static let idTrackType: UInt32 = 0x83
    static let idCodecID: UInt32 = 0x86
    static let idCodecPrivate: UInt32 = 0x63A2
    static let idCodecDelay: UInt32 = 0x56AA
    static let idSeekPreRoll: UInt32 = 0x56BB
    static let idContentEncodings: UInt32 = 0x6D80
    static let idCluster: UInt32 = 0x1F43B675
    static let idClusterTimestamp: UInt32 = 0xE7
    static let idSimpleBlock: UInt32 = 0xA3
    static let idBlockGroup: UInt32 = 0xA0
    static let idBlock: UInt32 = 0xA1
    static let idDiscardPadding: UInt32 = 0x75A2
    static let idEncryptedBlock: UInt32 = 0xAF
    static let idCues: UInt32 = 0x1C53BB6B
    static let idTags: UInt32 = 0x1254C367
    static let idChapters: UInt32 = 0x1043A770
    static let idAttachments: UInt32 = 0x1941A469
    static let idVoid: UInt32 = 0xEC
    static let idCRC32: UInt32 = 0xBF

    /// Children that end an unknown-size Cluster: the next top-level element of the Segment (or a new file).
    static let segmentLevelIds: Set<UInt32> = [idCluster, idCues, idTags, idChapters, idAttachments, idSeekHead,
                                               idInfo, idTracks, idEBML, idSegment]

    /// How far a block's timestamp may sit from its sample position: rounding to the timestamp unit, plus slack.
    public static let maxDriftNs: Int64 = 3_000_000

    struct Header {
        var id: UInt32
        var start: Int
        var dataStart: Int
        /// nil: unknown size (ends at the parent's end or at the next element that cannot be a child).
        var dataEnd: Int?
    }

    struct Track {
        var number: UInt64?
        var type: UInt64?
        var codecID: String?
        var codecPrivate: Range<Int>?
        var codecDelay: UInt64?
        var seekPreRoll: UInt64?
        var encoded = false
    }

    struct Block {
        var track: UInt64
        /// The first frame's absolute timestamp, in TimestampScale units.
        var timestamp: Int64
        var frames: [Range<Int>]
        var discardPaddingNs: Int64
    }

    /// Parses `bytes` (a complete file).
    public static func read(_ bytes: [UInt8]) throws -> OpusWebMStream {
        var pos = 0
        // EBML header (Void elements may precede nothing; the header must come first).
        let ebml = try header(bytes, at: pos, limit: bytes.count)
        guard ebml.id == idEBML, let ebmlEnd = ebml.dataEnd else { throw OpusRemuxError.notEBML }
        var docType = "matroska"
        try forEachChild(bytes, from: ebml.dataStart, to: ebmlEnd) { child in
            if child.id == idDocType, let end = child.dataEnd {
                docType = String(decoding: bytes[child.dataStart..<end].prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        guard docType == "webm" || docType == "matroska" else { throw OpusRemuxError.notWebM(docType) }
        pos = ebmlEnd
        // The Segment (skipping Void elements in front of it).
        var segment: Header?
        while pos < bytes.count {
            let next = try header(bytes, at: pos, limit: bytes.count)
            if next.id == idSegment {
                segment = next
                break
            }
            guard next.id == idVoid || next.id == idCRC32, let end = next.dataEnd else {
                throw OpusRemuxError.malformed("element 0x\(String(next.id, radix: 16)) before the Segment")
            }
            pos = end
        }
        guard let segment else { throw OpusRemuxError.truncated("the file before any Segment") }
        let segmentEnd = segment.dataEnd ?? bytes.count

        var scale: UInt64 = 1_000_000
        var durationUnits: Double?
        var tracks: [Track] = []
        var blocks: [Block] = []
        var sawTracks = false
        pos = segment.dataStart
        while pos < segmentEnd {
            let child = try header(bytes, at: pos, limit: segmentEnd)
            switch child.id {
            case idInfo:
                let end = try known(child, "Info")
                try forEachChild(bytes, from: child.dataStart, to: end) { field in
                    guard let fieldEnd = field.dataEnd else { throw OpusRemuxError.malformed("unknown-size Info field") }
                    if field.id == idTimestampScale { scale = try uint(bytes, field.dataStart..<fieldEnd) }
                    if field.id == idDuration { durationUnits = try float(bytes, field.dataStart..<fieldEnd) }
                }
                pos = end
            case idTracks:
                let end = try known(child, "Tracks")
                sawTracks = true
                try forEachChild(bytes, from: child.dataStart, to: end) { entry in
                    guard entry.id == idTrackEntry else { return }
                    guard let entryEnd = entry.dataEnd else { throw OpusRemuxError.malformed("unknown-size TrackEntry") }
                    tracks.append(try track(bytes, from: entry.dataStart, to: entryEnd))
                }
                pos = end
            case idCluster:
                guard sawTracks else { throw OpusRemuxError.malformed("Cluster before Tracks") }
                pos = try cluster(bytes, child, segmentEnd: segmentEnd, into: &blocks)
            case idSegment, idEBML:
                // A second Segment (a concatenated file): not ours.
                throw OpusRemuxError.unsupported("more than one Segment")
            default:
                // SeekHead, Cues, Tags, Chapters, Attachments, Void, CRC-32 and anything unknown: skipped.
                pos = try known(child, "element 0x\(String(child.id, radix: 16))")
            }
        }

        let audio = tracks.filter { $0.type == 2 }
        guard let opus = audio.first(where: { $0.codecID == "A_OPUS" }) else { throw OpusRemuxError.noOpusTrack }
        guard audio.count == 1 else { throw OpusRemuxError.multipleAudioTracks }
        guard !opus.encoded else { throw OpusRemuxError.unsupported("compressed or encrypted blocks") }
        guard let number = opus.number, let privateRange = opus.codecPrivate else {
            throw OpusRemuxError.badOpusHead("no CodecPrivate")
        }
        let head = try OpusHead(parsing: bytes[privateRange])
        guard head.mappingFamily == 0 else { throw OpusRemuxError.unsupported("channel mapping family \(head.mappingFamily)") }
        if let delay = opus.codecDelay, delay > 0 {
            let delaySamples = Int((Double(delay) * 48_000 / 1_000_000_000).rounded())
            guard abs(delaySamples - head.preSkip) <= 1 else {
                throw OpusRemuxError.preSkipMismatch(codecDelaySamples: delaySamples, preSkip: head.preSkip)
            }
        }
        guard scale > 0, scale <= 1_000_000_000 else { throw OpusRemuxError.malformed("TimestampScale \(scale)") }

        // Packets, their sample counts, and the timestamp check.
        let ours = blocks.filter { $0.track == number }
        var packets: [OpusPacketRef] = []
        packets.reserveCapacity(ours.count)
        var cumulative = 0
        var firstTimestampNs: Int64?
        var endTrim = 0
        let scaleNs = Int64(scale)
        let tolerance = max(maxDriftNs, 2 * scaleNs)
        for (blockIndex, block) in ours.enumerated() {
            let timestampNs = block.timestamp &* scaleNs
            let base = firstTimestampNs ?? timestampNs
            firstTimestampNs = base
            let expected = base + Int64(cumulative) * 1_000_000_000 / 48_000
            let drift = timestampNs - expected
            guard abs(drift) <= tolerance else {
                throw OpusRemuxError.timestampDrift(index: packets.count, driftMicroseconds: drift / 1000)
            }
            for frame in block.frames {
                guard let samples = OpusPacket.sampleCount(bytes[frame]) else {
                    throw OpusRemuxError.badPacket(index: packets.count,
                                                  reason: frame.isEmpty ? "empty" : "invalid TOC")
                }
                packets.append(OpusPacketRef(range: frame, samples: samples))
                cumulative += samples
            }
            if block.discardPaddingNs != 0 {
                guard blockIndex == ours.count - 1 else {
                    throw OpusRemuxError.unsupported("DiscardPadding before the last block")
                }
                guard block.discardPaddingNs > 0 else { throw OpusRemuxError.badEndTrim("negative DiscardPadding") }
                endTrim = Int((Double(block.discardPaddingNs) * 48_000 / 1_000_000_000).rounded())
            }
        }
        guard let last = packets.last else { throw OpusRemuxError.empty }
        guard endTrim < last.samples else {
            throw OpusRemuxError.badEndTrim("\(endTrim) samples, last packet \(last.samples)")
        }
        let stream = OpusWebMStream(
            head: head, packets: packets, endTrim: endTrim, timestampScaleNs: scaleNs,
            durationNs: durationUnits.map { $0 * Double(scale) },
            codecDelayNs: opus.codecDelay.map { Int64(clamping: $0) }, seekPreRollNs: opus.seekPreRoll.map { Int64(clamping: $0) },
            docType: docType)
        guard stream.validSamples > 0 else { throw OpusRemuxError.empty }
        return stream
    }

    // MARK: Elements

    /// The element header at `pos` (its id, size and where its data starts). Its data must end by `limit`.
    static func header(_ bytes: [UInt8], at pos: Int, limit: Int) throws -> Header {
        guard pos < limit else { throw OpusRemuxError.truncated("an element header") }
        let first = bytes[pos]
        let idLength: Int
        if first & 0x80 != 0 { idLength = 1 }
        else if first & 0x40 != 0 { idLength = 2 }
        else if first & 0x20 != 0 { idLength = 3 }
        else if first & 0x10 != 0 { idLength = 4 }
        else { throw OpusRemuxError.malformed("element id at byte \(pos)") }
        guard pos + idLength <= limit else { throw OpusRemuxError.truncated("an element id") }
        var id: UInt32 = 0
        for i in 0..<idLength { id = id << 8 | UInt32(bytes[pos + i]) }
        let (size, sizeLength) = try vint(bytes, at: pos + idLength, limit: limit)
        let dataStart = pos + idLength + sizeLength
        guard let size else { return Header(id: id, start: pos, dataStart: dataStart, dataEnd: nil) }
        guard size <= UInt64(limit - dataStart) else {
            throw OpusRemuxError.truncated("element 0x\(String(id, radix: 16))")
        }
        return Header(id: id, start: pos, dataStart: dataStart, dataEnd: dataStart + Int(size))
    }

    /// An EBML variable-size integer (marker bit removed); nil value = "unknown" (all value bits set).
    static func vint(_ bytes: [UInt8], at pos: Int, limit: Int) throws -> (value: UInt64?, length: Int) {
        guard pos < limit else { throw OpusRemuxError.truncated("an element size") }
        let first = bytes[pos]
        guard first != 0 else { throw OpusRemuxError.malformed("element size at byte \(pos)") }
        let length = first.leadingZeroBitCount + 1
        guard pos + length <= limit else { throw OpusRemuxError.truncated("an element size") }
        var value = UInt64(first) & (0xFF >> UInt64(length))
        var allOnes = value == (0xFF >> UInt64(length))
        for i in 1..<length {
            value = value << 8 | UInt64(bytes[pos + i])
            allOnes = allOnes && bytes[pos + i] == 0xFF
        }
        return (allOnes ? nil : value, length)
    }

    static func known(_ header: Header, _ what: String) throws -> Int {
        guard let end = header.dataEnd else { throw OpusRemuxError.unsupported("unknown-size \(what)") }
        return end
    }

    /// Calls `body` for each child of a known-size master element.
    static func forEachChild(_ bytes: [UInt8], from start: Int, to end: Int, _ body: (Header) throws -> Void) throws {
        var pos = start
        while pos < end {
            let child = try header(bytes, at: pos, limit: end)
            try body(child)
            guard let childEnd = child.dataEnd else {
                throw OpusRemuxError.unsupported("unknown-size element 0x\(String(child.id, radix: 16))")
            }
            pos = childEnd
        }
    }

    static func uint(_ bytes: [UInt8], _ range: Range<Int>) throws -> UInt64 {
        guard range.count <= 8 else { throw OpusRemuxError.malformed("integer of \(range.count) bytes") }
        return bytes[range].reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func int(_ bytes: [UInt8], _ range: Range<Int>) throws -> Int64 {
        guard range.count <= 8 else { throw OpusRemuxError.malformed("integer of \(range.count) bytes") }
        guard let first = range.first else { return 0 }
        let raw = try uint(bytes, range)
        guard bytes[first] & 0x80 != 0, range.count < 8 else { return Int64(bitPattern: raw) }
        return Int64(bitPattern: raw) - (Int64(1) << (8 * range.count))
    }

    static func float(_ bytes: [UInt8], _ range: Range<Int>) throws -> Double {
        let raw = try uint(bytes, range)
        switch range.count {
        case 0: return 0
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
        case 8: return Double(bitPattern: raw)
        default: throw OpusRemuxError.malformed("float of \(range.count) bytes")
        }
    }

    static func track(_ bytes: [UInt8], from start: Int, to end: Int) throws -> Track {
        var track = Track()
        try forEachChild(bytes, from: start, to: end) { field in
            guard let fieldEnd = field.dataEnd else { return }
            let data = field.dataStart..<fieldEnd
            switch field.id {
            case idTrackNumber: track.number = try uint(bytes, data)
            case idTrackType: track.type = try uint(bytes, data)
            case idCodecID: track.codecID = String(decoding: bytes[data].prefix { $0 != 0 }, as: UTF8.self)
            case idCodecPrivate: track.codecPrivate = data
            case idCodecDelay: track.codecDelay = try uint(bytes, data)
            case idSeekPreRoll: track.seekPreRoll = try uint(bytes, data)
            case idContentEncodings: track.encoded = true
            default: break
            }
        }
        return track
    }

    // MARK: Clusters and blocks

    /// Reads one Cluster's blocks; returns where the next Segment child starts.
    static func cluster(_ bytes: [UInt8], _ cluster: Header, segmentEnd: Int, into blocks: inout [Block]) throws -> Int {
        let limit = cluster.dataEnd ?? segmentEnd
        var timestamp: UInt64?
        var pos = cluster.dataStart
        while pos < limit {
            let child = try header(bytes, at: pos, limit: limit)
            if cluster.dataEnd == nil, segmentLevelIds.contains(child.id) {
                return pos   // the end of an unknown-size Cluster
            }
            guard let end = child.dataEnd else {
                throw OpusRemuxError.unsupported("unknown-size element 0x\(String(child.id, radix: 16)) in a Cluster")
            }
            switch child.id {
            case idClusterTimestamp:
                timestamp = try uint(bytes, child.dataStart..<end)
            case idSimpleBlock:
                guard let timestamp else { throw OpusRemuxError.malformed("block before the Cluster timestamp") }
                blocks.append(try block(bytes, child.dataStart..<end, clusterTimestamp: timestamp, discardPaddingNs: 0))
            case idBlockGroup:
                guard let timestamp else { throw OpusRemuxError.malformed("block before the Cluster timestamp") }
                var blockRange: Range<Int>?
                var discard: Int64 = 0
                try forEachChild(bytes, from: child.dataStart, to: end) { field in
                    guard let fieldEnd = field.dataEnd else { return }
                    if field.id == idBlock {
                        guard blockRange == nil else { throw OpusRemuxError.malformed("two Blocks in one BlockGroup") }
                        blockRange = field.dataStart..<fieldEnd
                    }
                    if field.id == idDiscardPadding { discard = try int(bytes, field.dataStart..<fieldEnd) }
                }
                guard let blockRange else { throw OpusRemuxError.malformed("BlockGroup without a Block") }
                blocks.append(try block(bytes, blockRange, clusterTimestamp: timestamp, discardPaddingNs: discard))
            case idEncryptedBlock:
                throw OpusRemuxError.unsupported("encrypted blocks")
            default:
                break   // Position, PrevSize, SilentTracks, Void, CRC-32, ...
            }
            pos = end
        }
        return limit
    }

    /// A SimpleBlock or Block: track number, 16-bit relative timestamp, flags, then one frame or a laced set.
    static func block(_ bytes: [UInt8], _ range: Range<Int>, clusterTimestamp: UInt64, discardPaddingNs: Int64) throws -> Block {
        var pos = range.lowerBound
        let (trackValue, trackLength) = try vint(bytes, at: pos, limit: range.upperBound)
        guard let track = trackValue else { throw OpusRemuxError.malformed("block track number") }
        pos += trackLength
        guard pos + 3 <= range.upperBound else { throw OpusRemuxError.truncated("a block header") }
        let relative = Int64(Int16(bitPattern: UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1])))
        let flags = bytes[pos + 2]
        pos += 3
        let frames: [Range<Int>]
        switch (flags >> 1) & 3 {
        case 0:
            frames = [pos..<range.upperBound]
        case 1:
            frames = try xiphLacing(bytes, from: pos, to: range.upperBound)
        case 2:
            frames = try fixedLacing(bytes, from: pos, to: range.upperBound)
        default:
            frames = try ebmlLacing(bytes, from: pos, to: range.upperBound)
        }
        return Block(track: track, timestamp: Int64(clamping: clusterTimestamp) + relative, frames: frames,
                     discardPaddingNs: discardPaddingNs)
    }

    static func lacedCount(_ bytes: [UInt8], _ pos: Int, _ end: Int) throws -> Int {
        guard pos < end else { throw OpusRemuxError.truncated("a lacing header") }
        return Int(bytes[pos]) + 1
    }

    static func split(_ start: Int, _ end: Int, sizes: [Int]) throws -> [Range<Int>] {
        var frames: [Range<Int>] = []
        var pos = start
        for size in sizes {
            guard size >= 0, pos + size <= end else { throw OpusRemuxError.malformed("lace sizes") }
            frames.append(pos..<(pos + size))
            pos += size
        }
        guard pos <= end else { throw OpusRemuxError.malformed("lace sizes") }
        frames.append(pos..<end)
        return frames
    }

    static func xiphLacing(_ bytes: [UInt8], from start: Int, to end: Int) throws -> [Range<Int>] {
        let count = try lacedCount(bytes, start, end)
        var pos = start + 1
        var sizes: [Int] = []
        for _ in 0..<(count - 1) {
            var size = 0
            while true {
                guard pos < end else { throw OpusRemuxError.truncated("Xiph lace sizes") }
                let byte = Int(bytes[pos])
                pos += 1
                size += byte
                if byte != 255 { break }
            }
            sizes.append(size)
        }
        return try split(pos, end, sizes: sizes)
    }

    static func fixedLacing(_ bytes: [UInt8], from start: Int, to end: Int) throws -> [Range<Int>] {
        let count = try lacedCount(bytes, start, end)
        let total = end - start - 1
        guard total % count == 0 else { throw OpusRemuxError.malformed("fixed-size lacing") }
        let size = total / count
        return try split(start + 1, end, sizes: Array(repeating: size, count: count - 1))
    }

    static func ebmlLacing(_ bytes: [UInt8], from start: Int, to end: Int) throws -> [Range<Int>] {
        let count = try lacedCount(bytes, start, end)
        var pos = start + 1
        var sizes: [Int] = []
        if count > 1 {
            let (first, length) = try vint(bytes, at: pos, limit: end)
            guard let first, first <= UInt64(end - pos) else { throw OpusRemuxError.malformed("EBML lace size") }
            pos += length
            sizes.append(Int(first))
            for _ in 0..<max(count - 2, 0) {
                let (raw, rawLength) = try vint(bytes, at: pos, limit: end)
                guard let raw else { throw OpusRemuxError.malformed("EBML lace delta") }
                pos += rawLength
                // Signed: subtract half the range (2^(7n-1) - 1).
                let bias = (Int64(1) << (7 * rawLength - 1)) - 1
                let next = Int64(sizes[sizes.count - 1]) + Int64(raw) - bias
                guard next >= 0 else { throw OpusRemuxError.malformed("EBML lace delta") }
                sizes.append(Int(next))
            }
        }
        return try split(pos, end, sizes: sizes)
    }
}
