import Foundation
import PixlFoundation
import Testing
@testable import PixlBackup

@Suite struct ChecksumTests {
    @Test func crc32KnownValues() {
        #expect(CRC32.checksum([UInt8]()) == 0)
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Array("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
        var incremental = CRC32()
        incremental.update(Array("12345".utf8))
        incremental.update(Array("6789".utf8))
        #expect(incremental.value == 0xCBF4_3926)
    }

    @Test func sha256NistVectors() {
        #expect(SHA256.hex([UInt8]()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(SHA256.hex(Array("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu".utf8))
                == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
        #expect(SHA256.hex([UInt8](repeating: 0x61, count: 1_000_000))
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func sha256IncrementalMatchesOneShotAcrossBlockBoundaries() {
        let data = (0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        for split in [0, 1, 55, 56, 63, 64, 65, 127, 128, 999, 1000] {
            var h = SHA256()
            h.update(data[0..<split])
            h.update(data[split...])
            #expect(SHA256.hexString(h.finalize()) == SHA256.hex(data), "split \(split)")
        }
    }

    @Test func injectedHasherIsUsedForChecksums() {
        let fake: SHA256Hasher = { _ in [UInt8](repeating: 0xAB, count: 32) }
        #expect(BackupHashing.hex([1, 2, 3], hasher: fake) == String(repeating: "ab", count: 32))
        #expect(BackupHashing.hex(Array("abc".utf8)) == SHA256.hex(Array("abc".utf8)))
    }
}

@Suite struct InflateTests {
    /// Raw DEFLATE streams from `java.util.zip.Deflater` (levels 0/1/6/9, filtered, Huffman-only, sync flushes).
    @Test func inflatesJavaDeflaterOutput() throws {
        let cases = try goldenLines("inflate-cases.jsonl")
        #expect(cases.count == 44)
        for c in cases {
            let deflated = Array(Data(base64Encoded: c["deflate"]!.str)!)
            let output = try Inflate.inflate(deflated)
            #expect(output.count == Int(c["size"]!.i64), "size level \(c["level"]!.i64) strategy \(c["strategy"]!.i64)")
            #expect(SHA256.hex(output) == c["sha256"]!.str, "digest level \(c["level"]!.i64) size \(output.count)")
            if let plain = c["plain"]?.str { #expect(output == Array(Data(base64Encoded: plain)!)) }
        }
    }

    @Test func storedEncoderRoundTrips() throws {
        for size in [0, 1, 65_535, 65_536, 200_000] {
            let data = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7) }
            #expect(try Inflate.inflate(StoredDeflate.encode(data)) == data, "size \(size)")
        }
    }

    @Test func fixedHuffmanBlockByHand() throws {
        // "a" with a fixed-Huffman block: zlib's minimal encoding 4b 04 00.
        #expect(try Inflate.inflate([0x4B, 0x04, 0x00]) == Array("a".utf8))
        // Empty input in a fixed block (the end-of-block code only).
        #expect(try Inflate.inflate([0x03, 0x00]) == [])
    }

    @Test func reportsCorruptStreams() {
        #expect(throws: InflateError.truncated) { try Inflate.inflate([]) }
        #expect(throws: InflateError.invalidBlockType) { try Inflate.inflate([0x07]) }
        #expect(throws: InflateError.storedLengthMismatch) { try Inflate.inflate([0x01, 0x05, 0x00, 0x00, 0x00]) }
        #expect(throws: InflateError.truncated) { try Inflate.inflate([0x01, 0x05, 0x00, 0xFA, 0xFF, 0x61]) }
        // A fixed block whose first code is a back-reference with nothing to copy.
        #expect(throws: InflateError.invalidDistance) { try Inflate.inflate([0x03, 0x02]) }
        // A stream that stops in the middle of a block.
        #expect(throws: InflateError.truncated) { try Inflate.inflate([0x4B, 0x04]) }
    }

    @Test func enforcesTheOutputLimit() throws {
        let zeros = [UInt8](repeating: 0, count: 100_000)
        let deflated = StoredDeflate.encode(zeros)
        #expect(throws: InflateError.outputLimitExceeded(99_999)) { try Inflate.inflate(deflated, maxOutput: 99_999) }
        #expect(try Inflate.inflate(deflated, maxOutput: 100_000).count == 100_000)
        // A highly compressed stream (Java level 9 zeros) is stopped as soon as it passes the limit.
        let cases = try goldenLines("inflate-cases.jsonl")
        let bomb = try #require(cases.first { $0["size"]!.i64 == 300_000 && $0["level"]!.i64 == 9 })
        #expect(throws: InflateError.outputLimitExceeded(1000)) {
            try Inflate.inflate(Array(Data(base64Encoded: bomb["deflate"]!.str)!), maxOutput: 1000)
        }
    }

    /// Megabytes of back-references (a 16 MB module is allowed) must decode in linear time.
    @Test func longBackReferenceRunsDecodeInLinearTime() throws {
        var bits = BitWriter()
        bits.put(1, 1) // BFINAL
        bits.put(1, 2) // fixed Huffman
        bits.putCode(0x30 + 0x61, 8) // literal "a"
        let references = 32_000
        for _ in 0..<references {
            bits.putCode(0b1100_0101, 8) // length symbol 285 = 258 bytes
            bits.putCode(0, 5) // distance symbol 0 = 1 byte back
        }
        bits.putCode(0, 7) // end of block
        let start = Date()
        let output = try Inflate.inflate(bits.bytes)
        #expect(output.count == 1 + references * 258)
        #expect(output.allSatisfy { $0 == 0x61 })
        #expect(Date().timeIntervalSince(start) < 30)
    }

    struct BitWriter {
        var bytes: [UInt8] = []
        var bitCount = 0

        /// Appends `count` bits of `value`, least significant first (header fields, extra bits).
        mutating func put(_ value: Int, _ count: Int) {
            for i in 0..<count {
                if bitCount % 8 == 0 { bytes.append(0) }
                if (value >> i) & 1 == 1 { bytes[bytes.count - 1] |= UInt8(1 << (bitCount % 8)) }
                bitCount += 1
            }
        }

        /// Appends a Huffman code, most significant bit first.
        mutating func putCode(_ code: Int, _ length: Int) {
            for i in stride(from: length - 1, through: 0, by: -1) { put((code >> i) & 1, 1) }
        }
    }

    @Test func reportsConsumedBytesForTrailingData() throws {
        let stream = StoredDeflate.encode(Array("hello".utf8)) + [0xDE, 0xAD]
        let result = try Inflate.inflate(stream, from: 0)
        #expect(result.output == Array("hello".utf8))
        #expect(result.consumed == stream.count - 2)
    }
}

@Suite struct GzipTests {
    @Test func decompressesTheAndroidLegacyFixtures() throws {
        let v2 = try fixtureBytes("android-v2-legacy.pxpl")
        let json = String(decoding: try Gzip.decompress(v2, from: 4), as: UTF8.self)
        #expect(json.hasPrefix("{\n  \"formatVersion\": 2"))
        let v1 = try fixtureBytes("android-v1-legacy.json.gz")
        #expect(try Gzip.decompress(v1) == fixtureBytes("android-v1-legacy.json"))
    }

    @Test func roundTripsAndConcatenatesMembers() throws {
        let a = Array("first member ".utf8), b = Array("second member".utf8)
        #expect(try Gzip.decompress(Gzip.compress(a)) == a)
        #expect(try Gzip.decompress(Gzip.compress(a) + Gzip.compress(b)) == a + b)
        // Trailing bytes that are not a gzip header are ignored, like GZIPInputStream.
        #expect(try Gzip.decompress(Gzip.compress(a) + Array(repeating: 0, count: 20)) == a)
        #expect(try Gzip.decompress(Gzip.compress(a) + [0x1F]) == a)
    }

    @Test func readsOptionalHeaderFields() throws {
        let payload = Array("named".utf8)
        var member: [UInt8] = [0x1F, 0x8B, 8, 0x1E, 0, 0, 0, 0, 0, 3] // FHCRC | FEXTRA | FNAME | FCOMMENT
        member += [3, 0, 1, 2, 3]
        member += Array("backup.json".utf8) + [0]
        member += Array("comment".utf8) + [0]
        let crc = CRC32.checksum(member)
        member += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF)]
        member += StoredDeflate.encode(payload)
        Gzip.appendLE32(&member, CRC32.checksum(payload))
        Gzip.appendLE32(&member, UInt32(payload.count))
        #expect(try Gzip.decompress(member) == payload)
        var badHeader = member
        badHeader[member.count - payload.count - 5 - 8 - 2] ^= 0xFF
        #expect(throws: GzipError.corruptHeader) { try Gzip.decompress(badHeader) }
    }

    @Test func rejectsCorruptData() {
        var good = Gzip.compress(Array("data".utf8))
        #expect(throws: GzipError.notGzip) { try Gzip.decompress([0x50, 0x4B, 3, 4, 0, 0, 0, 0, 0, 0, 0]) }
        #expect(throws: GzipError.unsupportedMethod(7)) { try Gzip.decompress([0x1F, 0x8B, 7, 0, 0, 0, 0, 0, 0, 0, 0]) }
        #expect(throws: GzipError.truncated) { try Gzip.decompress(Array(good.dropLast(3))) }
        good[good.count - 5] ^= 0x01 // CRC
        #expect(throws: GzipError.corruptTrailer) { try Gzip.decompress(good) }
    }
}

@Suite struct ZipTests {
    @Test func readsTheAndroidArchiveWithDataDescriptors() throws {
        let file = try fixtureBytes("android-v3.pxpl")
        #expect(Array(file[0..<4]) == BackupFormatDetector.pxplMagic)
        let archive = try ZipArchive(bytes: Array(file[4...]))
        #expect(archive.hasCentralDirectory)
        #expect(archive.entries.map(\.name) == ["manifest.json", "playlists.json", "global_settings.json", "favorites.json",
                                                "lyrics.json", "search_history.json", "transitions.json", "engagement_stats.json",
                                                "playback_history.json", "quick_fill.json", "artist_images.json",
                                                "equalizer.json", "ai_usage_logs.json"])
        for entry in archive.entries {
            #expect(entry.method == 8)
            #expect(entry.flags & 0x8 != 0, "ZipOutputStream writes data descriptors")
            let data = try archive.data(for: entry)
            #expect(data.count == entry.uncompressedSize)
        }
    }

    @Test func walksLocalHeadersWhenTheCentralDirectoryIsMissing() throws {
        let file = try fixtureBytes("android-v3.pxpl")
        let full = try ZipArchive(bytes: Array(file[4...]))
        // Cut the archive at the start of the central directory (a truncated download).
        let last = full.entries.last!
        let lastData = try full.data(for: last)
        let zipBytes = Array(file[4...])
        let eocd = try #require(ZipArchive.findEndOfCentralDirectory(zipBytes))
        let cut = Array(zipBytes[..<Int(ZipArchive.u32(zipBytes, eocd + 16))])
        let walked = try ZipArchive(bytes: cut)
        #expect(!walked.hasCentralDirectory)
        #expect(walked.entries.map(\.name) == full.entries.map(\.name))
        #expect(try walked.data(for: walked.entries.last!) == lastData)
        for (a, b) in zip(walked.entries, full.entries) { #expect(try walked.data(for: a) == full.data(for: b)) }
    }

    @Test func writerRoundTripsAndIsReadLikeZipInputStream() throws {
        var writer = ZipWriter()
        writer.addStored(name: "manifest.json", data: Array("{}".utf8))
        writer.addStored(name: "café.json", data: Array("[1]".utf8))
        writer.addStored(name: "empty.json", data: [])
        let bytes = writer.finish()
        let archive = try ZipArchive(bytes: bytes)
        #expect(archive.entries.map(\.name) == ["manifest.json", "café.json", "empty.json"])
        #expect(try archive.data(for: archive.entry(named: "café.json")!) == Array("[1]".utf8))
        #expect(try archive.data(for: archive.entry(named: "empty.json")!) == [])
        // Without the central directory the local headers carry everything (no data descriptors).
        let eocd = ZipArchive.findEndOfCentralDirectory(bytes)!
        let centralOffset = Int(ZipArchive.u32(bytes, eocd + 16))
        let walked = try ZipArchive(bytes: Array(bytes[..<centralOffset]))
        #expect(walked.entries.map(\.name) == archive.entries.map(\.name))
        // The fixture written by Java's ZipOutputStream with STORED entries reads the same way.
        let javaStored = try fixtureBytes("android-v3-stored.pxpl")
        let javaArchive = try ZipArchive(bytes: Array(javaStored[4...]))
        #expect(javaArchive.entries.map(\.method) == [0, 0, 0])
    }

    @Test func firstEntryWinsForDuplicateNames() throws {
        var writer = ZipWriter()
        writer.addStored(name: "a.json", data: Array("1".utf8))
        writer.addStored(name: "a.json", data: Array("2".utf8))
        let archive = try ZipArchive(bytes: writer.finish())
        #expect(try archive.data(for: archive.entry(named: "a.json")!) == Array("1".utf8))
    }

    @Test func rejectsCorruptAndUnsupportedArchives() throws {
        #expect(throws: ZipError.notZip) { try ZipArchive(bytes: Array("not a zip".utf8)) }
        var writer = ZipWriter()
        writer.addStored(name: "x.json", data: Array("hello".utf8))
        var bytes = writer.finish()
        // Flip a data byte: the CRC no longer matches.
        bytes[30 + "x.json".utf8.count] ^= 0x20
        let archive = try ZipArchive(bytes: bytes)
        #expect(throws: ZipError.crcMismatch("x.json")) { try archive.data(for: archive.entries[0]) }
        // Encrypted entries are refused.
        var encrypted = archive.entries[0]
        encrypted.flags |= 1
        #expect(throws: ZipError.unsupported("encrypted entry 'x.json'")) { try archive.data(for: encrypted) }
        // Unknown compression methods are refused.
        var bzip = archive.entries[0]
        bzip.method = 12
        #expect(throws: ZipError.unsupported("compression method 12 for 'x.json'")) { try archive.data(for: bzip) }
        // The per-entry limit stops a stored entry before it is copied.
        let ok = try ZipArchive(bytes: writer.finish())
        #expect(throws: ZipError.entryTooLarge(name: "x.json", limit: 4)) { try ok.data(for: ok.entries[0], maxSize: 4) }
    }

    @Test func rejectsZip64() {
        var writer = ZipWriter()
        writer.addStored(name: "x.json", data: [1])
        var bytes = writer.finish()
        let eocd = ZipArchive.findEndOfCentralDirectory(bytes)!
        bytes[eocd + 16] = 0xFF; bytes[eocd + 17] = 0xFF; bytes[eocd + 18] = 0xFF; bytes[eocd + 19] = 0xFF
        #expect(throws: ZipError.unsupported("ZIP64")) { try ZipArchive(bytes: bytes) }
    }

    @Test func decodesCp437NamesWithoutTheUtf8Flag() {
        #expect(ZipArchive.decodeName([0x63, 0x61, 0x66, 0x82], utf8: false) == "café")
        #expect(ZipArchive.decodeName(Array("café".utf8)[...], utf8: true) == "café")
    }
}
