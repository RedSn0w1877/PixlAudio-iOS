// Writes the Opus packets of a WebM file into an MP4 file the system decoder reads (Opus is supported "only in MP4"
// from iOS 17). Layout from "Encapsulation of Opus in ISO Base Media File Format" (opus-codec.org, version 0.8.1):
// an `Opus` sample entry with a big-endian `dOps` box, 48 kHz timescales, an edit list whose media_time is the
// pre-skip and whose segment_duration is the number of valid samples (the spec makes the edit list mandatory and
// PreSkip informative), the last sample shortened by the end padding (4.3.4), no `stss` (every sample is a sync
// sample) and a `roll` sample group for the 80 ms pre-roll (4.3.6.2), which needs the `iso2` brand. The packets
// themselves are copied byte for byte: nothing is re-encoded.

import Foundation

public enum OpusMP4Writer {
    public static let timescale: UInt32 = 48_000
    /// About one second of audio per chunk (`stco` entry).
    public static let chunkSamples = 48_000
    /// The pre-roll after a seek: 80 ms at 48 kHz.
    public static let preRollSamples = 3_840
    public static let majorBrand = "isom"
    public static let compatibleBrands = ["isom", "iso2", "mp41", "Opus"]

    /// The whole file: `ftyp`, `moov`, `mdat`. `source` holds the bytes the packet ranges point into.
    public static func write(_ stream: OpusWebMStream, source: [UInt8]) throws -> [UInt8] {
        let packets = stream.packets
        guard !packets.isEmpty, stream.validSamples > 0 else { throw OpusRemuxError.empty }
        let payloadBytes = packets.reduce(0) { $0 + $1.range.count }
        guard payloadBytes < Int(UInt32.max) - (1 << 20), packets.count < Int(UInt32.max) else { throw OpusRemuxError.tooLarge }

        var durations = packets.map(\.samples)
        durations[durations.count - 1] -= stream.endTrim
        guard durations[durations.count - 1] > 0 else { throw OpusRemuxError.badEndTrim("empty last sample") }
        let mediaDuration = durations.reduce(0, +)
        guard mediaDuration <= Int(UInt32.max) else { throw OpusRemuxError.tooLarge }

        var ftyp = ByteWriter()
        ftyp.box("ftyp") { w in
            w.fourCC(majorBrand)
            w.u32(512)
            for brand in compatibleBrands { w.fourCC(brand) }
        }
        let tables = SampleTables(packets: packets, durations: durations)
        // moov's size does not depend on the offsets' values: measure it, then write it with the real ones.
        let probe = try moov(stream, tables: tables, mdatDataStart: 0)
        let mdatDataStart = ftyp.bytes.count + probe.count + 8
        let moovBytes = try moov(stream, tables: tables, mdatDataStart: mdatDataStart)

        var file = ftyp
        file.bytes.reserveCapacity(mdatDataStart + payloadBytes)
        file.bytes.append(contentsOf: moovBytes)
        file.u32(UInt32(8 + payloadBytes))
        file.fourCC("mdat")
        for packet in packets { file.bytes.append(contentsOf: source[packet.range]) }
        return file.bytes
    }

    /// The per-sample tables, computed once.
    struct SampleTables {
        var sizes: [UInt32]
        /// (count, duration) runs.
        var stts: [(UInt32, UInt32)]
        /// Samples per chunk, and each chunk's offset from the start of mdat's data.
        var chunkSampleCounts: [Int]
        var chunkOffsets: [Int]
        /// (sample count, group index) runs, and each group's roll distance (negative, in samples of the track).
        var rollRuns: [(UInt32, UInt32)]
        var rollDistances: [Int16]
        var maxBitrate: UInt32
        var averageBitrate: UInt32
        var maxSampleSize: UInt32

        init(packets: [OpusPacketRef], durations: [Int]) {
            let sizes = packets.map { UInt32($0.range.count) }
            var stts: [(UInt32, UInt32)] = []
            for duration in durations {
                if let last = stts.last, last.1 == UInt32(duration) {
                    stts[stts.count - 1].0 += 1
                } else {
                    stts.append((1, UInt32(duration)))
                }
            }
            // Chunks of about a second; their bitrate gives btrt's maximum.
            var counts: [Int] = []
            var offsets: [Int] = []
            var offset = 0
            var inChunk = 0
            var chunkSamples = 0
            var chunkBytes = 0
            var maxBits = 0.0
            for (index, packet) in packets.enumerated() {
                if inChunk == 0 { offsets.append(offset) }
                inChunk += 1
                chunkSamples += durations[index]
                chunkBytes += packet.range.count
                offset += packet.range.count
                if chunkSamples >= OpusMP4Writer.chunkSamples || index == packets.count - 1 {
                    counts.append(inChunk)
                    if chunkSamples > 0 { maxBits = max(maxBits, Double(chunkBytes * 8) * 48_000 / Double(chunkSamples)) }
                    inChunk = 0
                    chunkSamples = 0
                    chunkBytes = 0
                }
            }
            let totalSamples = durations.reduce(0, +)
            let average = totalSamples > 0 ? min(Double(UInt32.max), Double(offset * 8) * 48_000 / Double(totalSamples)) : 0
            // Roll groups as ffmpeg's muxer computes them: how many earlier packets cover 80 ms (0 when there are
            // not enough), run-length coded; each run with a distance gets its own group description.
            var runs: [(UInt32, UInt32)] = []
            var distances: [Int16] = []
            var previous = -1
            for index in packets.indices {
                var remaining = OpusMP4Writer.preRollSamples
                var distance = 0
                var j = index - 1
                while j >= 0 {
                    remaining -= packets[j].samples
                    distance += 1
                    if remaining <= 0 { break }
                    j -= 1
                }
                if remaining > 0 { distance = 0 }
                if distance == previous {
                    runs[runs.count - 1].0 += 1
                } else {
                    if distance > 0 { distances.append(Int16(clamping: -distance)) }
                    runs.append((1, distance > 0 ? UInt32(distances.count) : 0))
                }
                previous = distance
            }
            self.sizes = sizes
            self.stts = stts
            chunkSampleCounts = counts
            chunkOffsets = offsets
            rollRuns = runs
            rollDistances = distances
            maxSampleSize = sizes.max() ?? 0
            averageBitrate = UInt32(average)
            maxBitrate = UInt32(min(Double(UInt32.max), max(maxBits, average)))
        }
    }

    static let unityMatrix: [UInt32] = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000]

    static func moov(_ stream: OpusWebMStream, tables: SampleTables, mdatDataStart: Int) throws -> [UInt8] {
        let head = stream.head
        let valid = UInt32(stream.validSamples)
        let mediaDuration = UInt32(tables.stts.reduce(0) { $0 + Int($1.0) * Int($1.1) })
        guard let lastOffset = tables.chunkOffsets.last, mdatDataStart + lastOffset < Int(UInt32.max) else {
            throw OpusRemuxError.tooLarge
        }
        var w = ByteWriter()
        w.box("moov") { w in
            w.fullBox("mvhd", version: 0, flags: 0) { w in
                w.u32(0)                    // creation_time
                w.u32(0)                    // modification_time
                w.u32(timescale)
                w.u32(valid)                // the edited duration
                w.u32(0x0001_0000)          // rate 1.0
                w.u16(0x0100)               // volume 1.0
                w.zeros(10)
                for value in unityMatrix { w.u32(value) }
                w.zeros(24)                 // pre_defined
                w.u32(2)                    // next_track_ID
            }
            w.box("trak") { w in
                w.fullBox("tkhd", version: 0, flags: 0x000003) { w in   // enabled, in movie
                    w.u32(0)
                    w.u32(0)
                    w.u32(1)                // track_ID
                    w.u32(0)
                    w.u32(valid)
                    w.zeros(8)
                    w.u16(0)                // layer
                    w.u16(0)                // alternate_group
                    w.u16(0x0100)           // volume
                    w.u16(0)
                    for value in unityMatrix { w.u32(value) }
                    w.u32(0)                // width
                    w.u32(0)                // height
                }
                w.box("edts") { w in
                    w.fullBox("elst", version: 0, flags: 0) { w in
                        w.u32(1)
                        w.u32(valid)                         // segment_duration (movie timescale = 48 kHz)
                        w.u32(UInt32(head.preSkip))          // media_time: skip the priming samples
                        w.u16(1)                             // media_rate_integer
                        w.u16(0)                             // media_rate_fraction
                    }
                }
                w.box("mdia") { w in
                    w.fullBox("mdhd", version: 0, flags: 0) { w in
                        w.u32(0)
                        w.u32(0)
                        w.u32(timescale)
                        w.u32(mediaDuration)
                        w.u16(0x55C4)       // "und"
                        w.u16(0)
                    }
                    w.fullBox("hdlr", version: 0, flags: 0) { w in
                        w.u32(0)
                        w.fourCC("soun")
                        w.zeros(12)
                        w.bytes.append(contentsOf: Array("SoundHandler".utf8) + [0])
                    }
                    w.box("minf") { w in
                        w.fullBox("smhd", version: 0, flags: 0) { w in
                            w.u16(0)        // balance
                            w.u16(0)
                        }
                        w.box("dinf") { w in
                            w.fullBox("dref", version: 0, flags: 0) { w in
                                w.u32(1)
                                w.fullBox("url ", version: 0, flags: 1) { _ in }   // media in this file
                            }
                        }
                        w.box("stbl") { w in
                            sampleDescription(&w, head: head, tables: tables)
                            w.fullBox("stts", version: 0, flags: 0) { w in
                                w.u32(UInt32(tables.stts.count))
                                for (count, delta) in tables.stts {
                                    w.u32(count)
                                    w.u32(delta)
                                }
                            }
                            w.fullBox("stsc", version: 0, flags: 0) { w in
                                var entries: [(UInt32, UInt32)] = []
                                for (index, count) in tables.chunkSampleCounts.enumerated()
                                    where entries.last?.1 != UInt32(count) {
                                    entries.append((UInt32(index + 1), UInt32(count)))
                                }
                                w.u32(UInt32(entries.count))
                                for (firstChunk, samples) in entries {
                                    w.u32(firstChunk)
                                    w.u32(samples)
                                    w.u32(1)        // sample_description_index
                                }
                            }
                            w.fullBox("stsz", version: 0, flags: 0) { w in
                                w.u32(0)            // sizes vary
                                w.u32(UInt32(tables.sizes.count))
                                for size in tables.sizes { w.u32(size) }
                            }
                            w.fullBox("stco", version: 0, flags: 0) { w in
                                w.u32(UInt32(tables.chunkOffsets.count))
                                for offset in tables.chunkOffsets { w.u32(UInt32(mdatDataStart + offset)) }
                            }
                            w.fullBox("sgpd", version: 1, flags: 0) { w in
                                w.fourCC("roll")
                                w.u32(2)            // default_length
                                w.u32(UInt32(tables.rollDistances.count))
                                for distance in tables.rollDistances { w.u16(UInt16(bitPattern: distance)) }
                            }
                            w.fullBox("sbgp", version: 0, flags: 0) { w in
                                w.fourCC("roll")
                                w.u32(UInt32(tables.rollRuns.count))
                                for (count, group) in tables.rollRuns {
                                    w.u32(count)
                                    w.u32(group)
                                }
                            }
                        }
                    }
                }
            }
        }
        return w.bytes
    }

    /// `stsd` with the `Opus` sample entry and its `dOps` (big-endian) and `btrt` boxes.
    static func sampleDescription(_ w: inout ByteWriter, head: OpusHead, tables: SampleTables) {
        w.fullBox("stsd", version: 0, flags: 0) { w in
            w.u32(1)
            w.box("Opus") { w in
                w.zeros(6)
                w.u16(1)                    // data_reference_index
                w.zeros(8)
                w.u16(UInt16(head.channelCount))
                w.u16(16)                   // samplesize
                w.u16(0)
                w.u16(0)
                w.u32(48_000 << 16)         // samplerate
                w.box("dOps") { w in
                    w.u8(0)                 // Version
                    w.u8(UInt8(head.channelCount))
                    w.u16(UInt16(head.preSkip))
                    w.u32(head.inputSampleRate)
                    w.u16(UInt16(bitPattern: head.outputGain))
                    w.u8(head.mappingFamily)
                    if head.mappingFamily != 0 {
                        w.u8(UInt8(head.streamCount ?? 0))
                        w.u8(UInt8(head.coupledCount ?? 0))
                        w.bytes.append(contentsOf: head.channelMapping)
                    }
                }
                w.box("btrt") { w in
                    w.u32(tables.maxSampleSize)
                    w.u32(tables.maxBitrate)
                    w.u32(tables.averageBitrate)
                }
            }
        }
    }
}

/// Big-endian box writing.
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { bytes.append(UInt8(value >> 8)); bytes.append(UInt8(value & 0xFF)) }
    mutating func u32(_ value: UInt32) {
        bytes.append(UInt8(value >> 24))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }
    mutating func zeros(_ count: Int) { bytes.append(contentsOf: repeatElement(0, count: count)) }
    mutating func fourCC(_ code: String) {
        let utf8 = Array(code.utf8)
        precondition(utf8.count == 4, "four-character code")
        bytes.append(contentsOf: utf8)
    }

    mutating func box(_ type: String, _ body: (inout ByteWriter) -> Void) {
        let start = bytes.count
        u32(0)
        fourCC(type)
        body(&self)
        let size = UInt32(bytes.count - start)
        bytes[start] = UInt8(size >> 24)
        bytes[start + 1] = UInt8((size >> 16) & 0xFF)
        bytes[start + 2] = UInt8((size >> 8) & 0xFF)
        bytes[start + 3] = UInt8(size & 0xFF)
    }

    mutating func fullBox(_ type: String, version: UInt8, flags: UInt32, _ body: (inout ByteWriter) -> Void) {
        box(type) { w in
            w.u8(version)
            w.u8(UInt8((flags >> 16) & 0xFF))
            w.u8(UInt8((flags >> 8) & 0xFF))
            w.u8(UInt8(flags & 0xFF))
            body(&w)
        }
    }
}

/// WebM in, MP4 out.
public enum OpusRemuxer {
    /// A sanity cap on the input (the app's own cap is lower).
    public static let maxInputBytes = 64 << 20

    public struct Summary: Sendable, Equatable {
        public var packets: Int
        public var channels: Int
        public var preSkip: Int
        public var endTrim: Int
        public var totalSamples: Int
        public var validSamples: Int
        public var inputSampleRate: UInt32
        public var outputGain: Int16
        /// The WebM's own Info Duration, when it has one (diagnostics only).
        public var webmDurationMs: Double?

        /// What plays, in milliseconds.
        public var durationMs: Double { Double(validSamples) / 48 }
    }

    public struct Output: Sendable {
        public var mp4: Data
        public var summary: Summary
    }

    public static func remux(webm: Data) throws -> Output {
        guard webm.count <= maxInputBytes else { throw OpusRemuxError.tooLarge }
        let bytes = [UInt8](webm)
        let stream = try OpusWebMReader.read(bytes)
        let mp4 = try OpusMP4Writer.write(stream, source: bytes)
        let summary = Summary(
            packets: stream.packets.count, channels: stream.head.channelCount, preSkip: stream.head.preSkip,
            endTrim: stream.endTrim, totalSamples: stream.totalSamples, validSamples: stream.validSamples,
            inputSampleRate: stream.head.inputSampleRate, outputGain: stream.head.outputGain,
            webmDurationMs: stream.durationNs.map { $0 / 1_000_000 })
        return Output(mp4: Data(mp4), summary: summary)
    }
}
