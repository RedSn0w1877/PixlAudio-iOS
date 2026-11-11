import Foundation
import Testing
@testable import PixlNet

/// The WebM fixture: `ffmpeg -f lavfi -i sine=frequency=440:duration=3 -ac 2 -c:a libopus -b:a 64k -cues_to_front 1
/// -f webm` (ffmpeg 8.1). Cues before the Clusters, like YouTube's itag 251 files; the last block is a BlockGroup
/// with DiscardPadding. ffmpeg decodes it to exactly 144000 frames (3 s).
enum OpusFixture {
    static func webm() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "sine-440hz-3s", withExtension: "webm",
                                                 subdirectory: "Fixtures/opus"))
        return try Data(contentsOf: url)
    }

    static func packets(of stream: OpusWebMStream, in bytes: [UInt8]) -> [[UInt8]] {
        stream.packets.map { Array(bytes[$0.range]) }
    }
}

// MARK: - A small MP4 reader (the test's own, independent of the writer)

struct MP4Box {
    var type: String
    var body: Range<Int>
    var children: [MP4Box]

    func child(_ type: String) -> MP4Box? { children.first { $0.type == type } }

    func find(_ path: String) -> MP4Box? {
        var box: MP4Box? = self
        for part in path.split(separator: "/") { box = box?.child(String(part)) }
        return box
    }
}

enum MP4Reader {
    static let containers: Set<String> = ["moov", "trak", "edts", "mdia", "minf", "dinf", "stbl"]

    static func boxes(_ b: [UInt8], _ range: Range<Int>) throws -> [MP4Box] {
        var out: [MP4Box] = []
        var pos = range.lowerBound
        while pos < range.upperBound {
            try #require(pos + 8 <= range.upperBound)
            let size = Int(u32(b, pos))
            let type = String(decoding: b[(pos + 4)..<(pos + 8)], as: UTF8.self)
            try #require(size >= 8 && pos + size <= range.upperBound, "box \(type) size \(size)")
            let body = (pos + 8)..<(pos + size)
            let children = containers.contains(type) ? try boxes(b, body) : []
            out.append(MP4Box(type: type, body: body, children: children))
            pos += size
        }
        return out
    }

    static func root(_ b: [UInt8]) throws -> MP4Box {
        MP4Box(type: "", body: 0..<b.count, children: try boxes(b, 0..<b.count))
    }

    static func u16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) << 8 | UInt16(b[at + 1]) }
    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }
    static func fourCC(_ b: [UInt8], _ at: Int) -> String { String(decoding: b[at..<(at + 4)], as: UTF8.self) }

    /// A FullBox table of fixed-size rows after a 4-byte count (`stts`, `stsc`, `stco`, `elst` v0, `sbgp`).
    static func rows(_ b: [UInt8], _ box: MP4Box, skip: Int = 0, columns: Int) -> [[UInt32]] {
        let start = box.body.lowerBound + 4 + skip
        let count = Int(u32(b, start))
        return (0..<count).map { row in (0..<columns).map { u32(b, start + 4 + (row * columns + $0) * 4) } }
    }

    /// Every sample's bytes, from stsz/stsc/stco.
    static func samples(_ b: [UInt8], stbl: MP4Box) throws -> [[UInt8]] {
        let stsz = try #require(stbl.child("stsz"))
        let fixed = u32(b, stsz.body.lowerBound + 4)
        let count = Int(u32(b, stsz.body.lowerBound + 8))
        let sizes = (0..<count).map { fixed != 0 ? Int(fixed) : Int(u32(b, stsz.body.lowerBound + 12 + $0 * 4)) }
        let stsc = rows(b, try #require(stbl.child("stsc")), columns: 3)
        let offsets = rows(b, try #require(stbl.child("stco")), columns: 1).map { Int($0[0]) }
        var out: [[UInt8]] = []
        var sample = 0
        for (chunk, offset) in offsets.enumerated() {
            let entry = try #require(stsc.last { Int($0[0]) <= chunk + 1 })
            var pos = offset
            for _ in 0..<Int(entry[1]) where sample < count {
                out.append(Array(b[pos..<(pos + sizes[sample])]))
                pos += sizes[sample]
                sample += 1
            }
        }
        try #require(sample == count, "chunks hold \(sample) of \(count) samples")
        return out
    }
}

// MARK: - A small WebM writer, to make the layouts the fixture does not have

enum WebMBuilder {
    enum Lacing { case none, xiph, fixed, ebml }

    struct Layout {
        var head: [UInt8]
        var codecID = "A_OPUS"
        var codecDelayNs: UInt64? = 6_500_000
        var unknownSizes = false
        var lacing = Lacing.none
        var framesPerBlock = 1
        var blockGroups = false
        var voidAndCRC = false
        var packetsPerCluster = 50
        /// Written on the last block (as a BlockGroup).
        var discardPaddingNs: Int64?
        /// DiscardPadding on this block instead (not the last).
        var discardPaddingOnBlock: Int?
        /// Every block from this packet on is stamped 40 ms late (a hole in the stream).
        var gapAtPacket: Int?
        var contentEncodings = false
        var cuesAtEnd = true

        init(head: [UInt8]) { self.head = head }
    }

    static func idBytes(_ id: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        var started = false
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((id >> UInt32(shift)) & 0xFF)
            if byte != 0 || started { out.append(byte); started = true }
        }
        return out
    }

    static func vint(_ value: UInt64, length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        var v = value
        for i in stride(from: length - 1, through: 0, by: -1) {
            out[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        out[0] |= UInt8(0x80 >> (length - 1))
        return out
    }

    static func size(_ n: Int) -> [UInt8] {
        for length in 1...8 where UInt64(n) < (UInt64(1) << UInt64(7 * length)) - 1 { return vint(UInt64(n), length: length) }
        return vint(UInt64(n), length: 8)
    }

    static func element(_ id: UInt32, _ payload: [UInt8], unknownSize: Bool = false) -> [UInt8] {
        idBytes(id) + (unknownSize ? [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] : size(payload.count)) + payload
    }

    static func uint(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var v = value
        repeat {
            out.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return out
    }

    static func sint(_ value: Int64) -> [UInt8] {
        for length in 1...8 {
            let bits = Int64(8 * length)
            if length == 8 || (value >= -(Int64(1) << (bits - 1)) && value < (Int64(1) << (bits - 1))) {
                let raw = UInt64(bitPattern: value)
                return (0..<length).reversed().map { UInt8((raw >> UInt64(8 * $0)) & 0xFF) }
            }
        }
        return []
    }

    static func lace(_ frames: [[UInt8]], _ lacing: Lacing) -> (flags: UInt8, bytes: [UInt8]) {
        guard frames.count > 1 || lacing != .none else { return (0, frames.flatMap { $0 }) }
        var header: [UInt8] = [UInt8(frames.count - 1)]
        switch lacing {
        case .none:
            return (0, frames.flatMap { $0 })
        case .xiph:
            for frame in frames.dropLast() {
                var n = frame.count
                while n >= 255 { header.append(255); n -= 255 }
                header.append(UInt8(n))
            }
            return (0x02, header + frames.flatMap { $0 })
        case .fixed:
            return (0x04, header + frames.flatMap { $0 })
        case .ebml:
            if frames.count > 1 {
                header += vint(UInt64(frames[0].count), length: 2)
                for i in 1..<(frames.count - 1) {
                    let delta = Int64(frames[i].count) - Int64(frames[i - 1].count)
                    let length = abs(delta) < 63 ? 1 : 2
                    let bias = (Int64(1) << Int64(7 * length - 1)) - 1
                    header += vint(UInt64(delta + bias), length: length)
                }
            }
            return (0x06, header + frames.flatMap { $0 })
        }
    }

    static func make(packets: [[UInt8]], _ layout: Layout) -> [UInt8] {
        let r = OpusWebMReader.self
        let header = element(r.idEBML, element(r.idDocType, Array("webm".utf8)) + element(0x4287, uint(4)))
        var info = element(r.idTimestampScale, uint(1_000_000)) + element(r.idDuration, uint(Double(3000).bitPattern))
        if layout.voidAndCRC { info = element(r.idCRC32, [1, 2, 3, 4]) + info }
        var entry = element(r.idTrackNumber, uint(1)) + element(0x73C5, uint(77)) + element(r.idTrackType, uint(2))
            + element(r.idCodecID, Array(layout.codecID.utf8)) + element(r.idCodecPrivate, layout.head)
            + element(r.idSeekPreRoll, uint(80_000_000))
        if let delay = layout.codecDelayNs { entry += element(r.idCodecDelay, uint(delay)) }
        if layout.contentEncodings { entry += element(r.idContentEncodings, element(0x6240, element(0x5031, uint(0)))) }
        entry += element(0xE1, element(0xB5, uint(Double(48_000).bitPattern)) + element(0x9F, uint(2)))
        let tracks = element(r.idTracks, element(r.idTrackEntry, entry))
        let cues = element(r.idCues, element(0xBB, element(0xB3, uint(0))))

        // Group packets into blocks, blocks into clusters.
        var clusters: [UInt8] = []
        var index = 0
        var samples = 0
        var blockNumber = 0
        while index < packets.count {
            let clusterStartMs = Int64(samples / 48) + (layout.gapAtPacket.map { index >= $0 ? 40 : 0 } ?? 0)
            var body = element(r.idClusterTimestamp, uint(UInt64(clusterStartMs)))
            if layout.voidAndCRC { body = element(r.idCRC32, [9, 9, 9, 9]) + body + element(r.idVoid, [0, 0, 0]) }
            let clusterEnd = min(packets.count, index + layout.packetsPerCluster)
            while index < clusterEnd {
                let frames = Array(packets[index..<min(clusterEnd, index + layout.framesPerBlock)])
                var stampMs = Int64((Double(samples) / 48).rounded())
                if let gap = layout.gapAtPacket, index >= gap { stampMs += 40 }
                let relative = Int16(stampMs - clusterStartMs)
                let (laceFlags, payload) = lace(frames, layout.lacing)
                let rel = UInt16(bitPattern: relative)
                let isLast = index + frames.count == packets.count
                let discard = isLast ? layout.discardPaddingNs : (layout.discardPaddingOnBlock == blockNumber ? 1_000_000 : nil)
                if layout.blockGroups || discard != nil {
                    let block = [0x81, UInt8(rel >> 8), UInt8(rel & 0xFF), laceFlags] + payload
                    var group = element(r.idBlock, block) + element(0x9B, uint(20))
                    if blockNumber > 0 { group += element(0xFB, sint(-20)) }
                    if let discard { group += element(r.idDiscardPadding, sint(discard)) }
                    body += element(r.idBlockGroup, group)
                } else {
                    body += element(r.idSimpleBlock, [0x81, UInt8(rel >> 8), UInt8(rel & 0xFF), 0x80 | laceFlags] + payload)
                }
                for frame in frames { samples += OpusPacket.sampleCount(frame) ?? 0 }
                index += frames.count
                blockNumber += 1
            }
            clusters += element(r.idCluster, body, unknownSize: layout.unknownSizes)
        }
        var segment = element(r.idSeekHead, element(0x4DBB, element(0x53AB, idBytes(r.idInfo)))) + element(r.idVoid, [0, 0])
            + element(r.idInfo, info) + tracks
        if !layout.cuesAtEnd { segment += cues }
        segment += clusters
        if layout.cuesAtEnd { segment += cues }
        segment += element(r.idTags, element(0x7373, []))
        return header + element(r.idSegment, segment, unknownSize: layout.unknownSizes)
    }

    /// A stereo OpusHead (family 0).
    static func head(channels: UInt8 = 2, preSkip: UInt16 = 312, family: UInt8 = 0) -> [UInt8] {
        var out = Array("OpusHead".utf8) + [1, channels, UInt8(preSkip & 0xFF), UInt8(preSkip >> 8), 0x80, 0xBB, 0, 0, 0, 0, family]
        if family != 0 { out += [UInt8(channels - 2), 2] + (0..<channels).map { UInt8($0) } }
        return out
    }
}

// MARK: - Tests

@Suite("Opus remux: WebM in, MP4 out")
struct OpusRemuxTests {
    @Test func readsTheFixture() throws {
        let bytes = [UInt8](try OpusFixture.webm())
        let stream = try OpusWebMReader.read(bytes)
        #expect(stream.docType == "webm")
        #expect(stream.head == OpusHead(channelCount: 2, preSkip: 312, inputSampleRate: 48_000))
        #expect(stream.packets.count == 151)
        #expect(stream.packets.allSatisfy { $0.samples == 960 })
        #expect(stream.endTrim == 648)                 // DiscardPadding 13.5 ms
        #expect(stream.totalSamples == 144_960)
        #expect(stream.validSamples == 144_000)        // exactly 3 s, what ffmpeg decodes the WebM to
        #expect(stream.codecDelayNs == 6_500_000)      // = 312 samples
        #expect(stream.seekPreRollNs == 80_000_000)
        #expect(stream.timestampScaleNs == 1_000_000)
    }

    @Test func writesTheBoxesTheSpecAsksFor() throws {
        let webm = try OpusFixture.webm()
        let output = try OpusRemuxer.remux(webm: webm)
        let b = [UInt8](output.mp4)
        let root = try MP4Reader.root(b)
        #expect(root.children.map(\.type) == ["ftyp", "moov", "mdat"])

        let ftyp = try #require(root.child("ftyp"))
        #expect(MP4Reader.fourCC(b, ftyp.body.lowerBound) == "isom")
        #expect(MP4Reader.u32(b, ftyp.body.lowerBound + 4) == 512)
        let brands = stride(from: ftyp.body.lowerBound + 8, to: ftyp.body.upperBound, by: 4).map { MP4Reader.fourCC(b, $0) }
        #expect(brands == ["isom", "iso2", "mp41", "Opus"])

        let moov = try #require(root.child("moov"))
        let mvhd = try #require(moov.child("mvhd"))
        #expect(b[mvhd.body.lowerBound] == 0)
        #expect(MP4Reader.u32(b, mvhd.body.lowerBound + 12) == 48_000)
        #expect(MP4Reader.u32(b, mvhd.body.lowerBound + 16) == 144_000)

        let trak = try #require(moov.child("trak"))
        let tkhd = try #require(trak.child("tkhd"))
        #expect(MP4Reader.u32(b, tkhd.body.lowerBound) & 0xFFFFFF == 3)
        #expect(MP4Reader.u32(b, tkhd.body.lowerBound + 12) == 1)
        #expect(MP4Reader.u32(b, tkhd.body.lowerBound + 20) == 144_000)

        // The edit removes exactly the pre-skip and stops after the last valid sample.
        let elst = try #require(trak.find("edts/elst"))
        #expect(b[elst.body.lowerBound] == 0)
        #expect(MP4Reader.rows(b, elst, columns: 3) == [[144_000, 312, 0x0001_0000]])

        let mdhd = try #require(trak.find("mdia/mdhd"))
        #expect(MP4Reader.u32(b, mdhd.body.lowerBound + 12) == 48_000)
        #expect(MP4Reader.u32(b, mdhd.body.lowerBound + 16) == 144_312)   // 150 × 960 + the trimmed 312
        let hdlr = try #require(trak.find("mdia/hdlr"))
        #expect(MP4Reader.fourCC(b, hdlr.body.lowerBound + 8) == "soun")

        let stbl = try #require(trak.find("mdia/minf/stbl"))
        #expect(stbl.children.map(\.type) == ["stsd", "stts", "stsc", "stsz", "stco", "sgpd", "sbgp"])   // no stss
        // stsd → Opus sample entry → dOps.
        let stsd = try #require(stbl.child("stsd"))
        #expect(MP4Reader.u32(b, stsd.body.lowerBound + 4) == 1)
        let entry = stsd.body.lowerBound + 8
        #expect(MP4Reader.fourCC(b, entry + 4) == "Opus")
        let fields = entry + 8
        #expect(MP4Reader.u16(b, fields + 6) == 1)          // data_reference_index
        #expect(MP4Reader.u16(b, fields + 16) == 2)         // channelcount
        #expect(MP4Reader.u16(b, fields + 18) == 16)        // samplesize
        #expect(MP4Reader.u32(b, fields + 24) == 48_000 << 16)
        let entryBoxes = try MP4Reader.boxes(b, (fields + 28)..<(entry + Int(MP4Reader.u32(b, entry))))
        #expect(entryBoxes.map(\.type) == ["dOps", "btrt"])
        let dOps = try #require(entryBoxes.first)
        #expect(Array(b[dOps.body]) == [0, 2, 0x01, 0x38, 0, 0, 0xBB, 0x80, 0, 0, 0])   // v0, 2 ch, 312, 48000, 0 dB, family 0

        #expect(MP4Reader.rows(b, try #require(stbl.child("stts")), columns: 2) == [[150, 960], [1, 312]])
        #expect(MP4Reader.rows(b, try #require(stbl.child("stsc")), columns: 3) == [[1, 50, 1], [4, 1, 1]])

        let sgpd = try #require(stbl.child("sgpd"))
        #expect(b[sgpd.body.lowerBound] == 1)
        #expect(MP4Reader.fourCC(b, sgpd.body.lowerBound + 4) == "roll")
        #expect(MP4Reader.u32(b, sgpd.body.lowerBound + 8) == 2)
        #expect(MP4Reader.u32(b, sgpd.body.lowerBound + 12) == 1)
        #expect(Int16(bitPattern: MP4Reader.u16(b, sgpd.body.lowerBound + 16)) == -4)   // 4 × 20 ms = 80 ms
        let sbgp = try #require(stbl.child("sbgp"))
        #expect(MP4Reader.fourCC(b, sbgp.body.lowerBound + 4) == "roll")
        #expect(MP4Reader.rows(b, sbgp, skip: 4, columns: 2) == [[4, 0], [147, 1]])

        #expect(output.summary == OpusRemuxer.Summary(
            packets: 151, channels: 2, preSkip: 312, endTrim: 648, totalSamples: 144_960, validSamples: 144_000,
            inputSampleRate: 48_000, outputGain: 0, webmDurationMs: 3008))
        #expect(output.summary.durationMs == 3000)
    }

    @Test func everySampleIsTheWebMPacketByteForByte() throws {
        let webm = [UInt8](try OpusFixture.webm())
        let stream = try OpusWebMReader.read(webm)
        let mp4 = [UInt8](try OpusRemuxer.remux(webm: Data(webm)).mp4)
        let root = try MP4Reader.root(mp4)
        let stbl = try #require(root.find("moov/trak/mdia/minf/stbl"))
        let samples = try MP4Reader.samples(mp4, stbl: stbl)
        #expect(samples == OpusFixture.packets(of: stream, in: webm))
        let mdat = try #require(root.child("mdat"))
        #expect(mdat.body.count == stream.packets.reduce(0) { $0 + $1.range.count })
    }

    @Test func packetLengthsComeFromTheTOC() {
        #expect(OpusPacket.sampleCount([0x00]) == 480)           // SILK 10 ms
        #expect(OpusPacket.sampleCount([0x08]) == 960)           // SILK 20 ms
        #expect(OpusPacket.sampleCount([0x18]) == 2880)          // SILK 60 ms
        #expect(OpusPacket.sampleCount([0x19, 0]) == 5760)       // two 60 ms frames
        #expect(OpusPacket.sampleCount([0x1B, 0x03]) == nil)     // three 60 ms frames: over 120 ms
        #expect(OpusPacket.sampleCount([0x78]) == 960)           // hybrid 20 ms
        #expect(OpusPacket.sampleCount([0x80]) == 120)           // CELT 2.5 ms
        #expect(OpusPacket.sampleCount([0x83, 48]) == 5760)      // 48 × 2.5 ms
        #expect(OpusPacket.sampleCount([0x83, 49]) == nil)
        #expect(OpusPacket.sampleCount([0xFC]) == 960)           // CELT 20 ms stereo
        #expect(OpusPacket.sampleCount([0xFE, 1, 2]) == 1920)    // code 2: two frames
        #expect(OpusPacket.sampleCount([0xFF, 0x00]) == nil)     // code 3 with no frames
        #expect(OpusPacket.sampleCount([0xFF]) == nil)           // code 3 without its count byte
        #expect(OpusPacket.sampleCount([UInt8]()) == nil)
    }

    // MARK: Other layouts give the same packets

    func fixturePackets() throws -> (head: [UInt8], packets: [[UInt8]], stream: OpusWebMStream) {
        let webm = [UInt8](try OpusFixture.webm())
        let stream = try OpusWebMReader.read(webm)
        return (WebMBuilder.head(), OpusFixture.packets(of: stream, in: webm), stream)
    }

    func expectSameStream(_ file: [UInt8], packets: [[UInt8]], endTrim: Int = 648) throws {
        let stream = try OpusWebMReader.read(file)
        #expect(OpusFixture.packets(of: stream, in: file) == packets)
        #expect(stream.endTrim == endTrim)
        #expect(stream.head.preSkip == 312)
        // And the MP4 holds them in order.
        let mp4 = [UInt8](try OpusMP4Writer.write(stream, source: file))
        let stbl = try #require(try MP4Reader.root(mp4).find("moov/trak/mdia/minf/stbl"))
        #expect(try MP4Reader.samples(mp4, stbl: stbl) == packets)
    }

    @Test func unknownSizeSegmentAndClusters() throws {
        let (head, packets, _) = try fixturePackets()
        var layout = WebMBuilder.Layout(head: head)
        layout.unknownSizes = true
        layout.discardPaddingNs = 13_500_000
        try expectSameStream(WebMBuilder.make(packets: packets, layout), packets: packets)
        layout.cuesAtEnd = false
        layout.packetsPerCluster = 7
        try expectSameStream(WebMBuilder.make(packets: packets, layout), packets: packets)
    }

    @Test func blockGroupsVoidAndCRCElements() throws {
        let (head, packets, _) = try fixturePackets()
        var layout = WebMBuilder.Layout(head: head)
        layout.blockGroups = true
        layout.voidAndCRC = true
        layout.discardPaddingNs = 13_500_000
        try expectSameStream(WebMBuilder.make(packets: packets, layout), packets: packets)
        // No DiscardPadding at all: nothing trimmed at the end.
        layout.discardPaddingNs = nil
        try expectSameStream(WebMBuilder.make(packets: packets, layout), packets: packets, endTrim: 0)
    }

    @Test func xiphAndEBMLLacing() throws {
        let (head, packets, _) = try fixturePackets()
        for lacing in [WebMBuilder.Lacing.xiph, .ebml] {
            for perBlock in [2, 3, 8] {
                for clusterSize in [24, 50] {
                    var layout = WebMBuilder.Layout(head: head)
                    layout.lacing = lacing
                    layout.framesPerBlock = perBlock
                    layout.packetsPerCluster = clusterSize   // 50 leaves short blocks at cluster ends
                    layout.blockGroups = perBlock == 3 && clusterSize == 24
                    layout.unknownSizes = clusterSize == 50
                    layout.discardPaddingNs = 13_500_000
                    try expectSameStream(WebMBuilder.make(packets: packets, layout), packets: packets)
                }
            }
        }
    }

    @Test func xiphLacingWithLongFrames() throws {
        // Frames of 255 bytes and more need several size bytes each.
        let packets = (0..<30).map { i in [UInt8(0xFC)] + [UInt8](repeating: UInt8(i), count: 250 + i * 3) }
        var layout = WebMBuilder.Layout(head: WebMBuilder.head())
        layout.lacing = .xiph
        layout.framesPerBlock = 5
        let stream = try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout))
        #expect(stream.packets.map { $0.range.count } == packets.map(\.count))
        #expect(stream.validSamples == 30 * 960 - 312)
    }

    @Test func fixedSizeLacing() throws {
        let packets = (0..<40).map { i in [UInt8(0xFC)] + [UInt8](repeating: UInt8(i), count: 99) }
        var layout = WebMBuilder.Layout(head: WebMBuilder.head())
        layout.lacing = .fixed
        layout.framesPerBlock = 4
        let file = WebMBuilder.make(packets: packets, layout)
        let stream = try OpusWebMReader.read(file)
        #expect(OpusFixture.packets(of: stream, in: file) == packets)
        #expect(stream.totalSamples == 40 * 960)
    }

    // MARK: What is refused (the app then plays AAC)

    @Test func refusesTruncatedAndForeignFiles() throws {
        let webm = [UInt8](try OpusFixture.webm())
        #expect(throws: OpusRemuxError.self) { try OpusWebMReader.read(Array(webm.prefix(webm.count / 2))) }
        #expect(throws: OpusRemuxError.self) { try OpusWebMReader.read(Array(webm.prefix(40))) }
        #expect(throws: OpusRemuxError.notEBML) {
            try OpusWebMReader.read(WebMBuilder.element(0x1F43B675, [0xE7, 0x81, 0x00]))
        }
        #expect(throws: OpusRemuxError.self) { try OpusWebMReader.read(Array("OggS not a webm file at all".utf8)) }
        #expect(throws: OpusRemuxError.self) { try OpusWebMReader.read([]) }
    }

    @Test func refusesOtherCodecsAndOddTracks() throws {
        let (head, packets, _) = try fixturePackets()
        var layout = WebMBuilder.Layout(head: head)
        layout.codecID = "A_VORBIS"
        #expect(throws: OpusRemuxError.noOpusTrack) { try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout)) }
        layout = WebMBuilder.Layout(head: head)
        layout.contentEncodings = true
        #expect(throws: OpusRemuxError.unsupported("compressed or encrypted blocks")) {
            try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout))
        }
        layout = WebMBuilder.Layout(head: WebMBuilder.head(channels: 6, family: 1))
        #expect(throws: OpusRemuxError.unsupported("channel mapping family 1")) {
            try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout))
        }
        layout = WebMBuilder.Layout(head: Array(head.prefix(12)))
        #expect(throws: OpusRemuxError.badOpusHead("12 bytes")) {
            try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout))
        }
    }

    @Test func refusesTimingItCannotKeep() throws {
        let (head, packets, _) = try fixturePackets()
        // A hole: everything after packet 75 would play 40 ms early.
        var layout = WebMBuilder.Layout(head: head)
        layout.gapAtPacket = 75
        #expect(throws: OpusRemuxError.timestampDrift(index: 75, driftMicroseconds: 40_000)) {
            try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout))
        }
        // CodecDelay says 10 ms but the OpusHead says 312 samples.
        layout = WebMBuilder.Layout(head: head)
        layout.codecDelayNs = 10_000_000
        #expect(throws: OpusRemuxError.preSkipMismatch(codecDelaySamples: 480, preSkip: 312)) {
            try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout))
        }
        // No CodecDelay at all is fine: the OpusHead's pre-skip rules.
        layout.codecDelayNs = nil
        #expect(try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout)).head.preSkip == 312)
        // An end trim as long as the last packet, and DiscardPadding in the middle.
        layout = WebMBuilder.Layout(head: head)
        layout.discardPaddingNs = 20_000_000
        #expect(throws: OpusRemuxError.badEndTrim("960 samples, last packet 960")) {
            try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout))
        }
        layout = WebMBuilder.Layout(head: head)
        layout.discardPaddingOnBlock = 10
        #expect(throws: OpusRemuxError.unsupported("DiscardPadding before the last block")) {
            try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout))
        }
    }

    @Test func refusesBrokenPackets() throws {
        var packets = (0..<10).map { _ in [UInt8(0xFC), 1, 2, 3] }
        packets[4] = []
        let layout = WebMBuilder.Layout(head: WebMBuilder.head())
        #expect(throws: OpusRemuxError.badPacket(index: 4, reason: "empty")) {
            try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout))
        }
        packets[4] = [0xFF, 0x00]
        #expect(throws: OpusRemuxError.badPacket(index: 4, reason: "invalid TOC")) {
            try OpusWebMReader.read(WebMBuilder.make(packets: packets, layout))
        }
        // Pre-skip longer than the audio: nothing would play.
        var tiny = WebMBuilder.Layout(head: WebMBuilder.head(preSkip: 2000))
        tiny.codecDelayNs = nil
        #expect(throws: OpusRemuxError.empty) { try OpusWebMReader.read(WebMBuilder.make(packets: [[0xFC, 1]], tiny)) }
    }

    /// `tools/opus/check-remux.sh` sets PIXL_OPUS_DUMP_DIR and reads these files with ffprobe and ffmpeg.
    @Test func dumpsFilesForTheFFmpegCheck() throws {
        guard let dir = ProcessInfo.processInfo.environment["PIXL_OPUS_DUMP_DIR"], !dir.isEmpty else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let webm = try OpusFixture.webm()
        try webm.write(to: folder.appendingPathComponent("fixture.webm"))
        try OpusRemuxer.remux(webm: webm).mp4.write(to: folder.appendingPathComponent("fixture.mp4"))
        let (head, packets, _) = try fixturePackets()
        var layout = WebMBuilder.Layout(head: head)
        layout.unknownSizes = true
        layout.lacing = .xiph
        layout.framesPerBlock = 3
        layout.discardPaddingNs = 13_500_000
        let variant = WebMBuilder.make(packets: packets, layout)
        try Data(variant).write(to: folder.appendingPathComponent("laced-unknown-size.webm"))
        try OpusRemuxer.remux(webm: Data(variant)).mp4.write(to: folder.appendingPathComponent("laced-unknown-size.mp4"))
    }
}
