import Foundation
import Testing
@testable import PixlTags

@Suite("FLAC metadata")
struct FLACTests {
    static let picture = B.flacPicture(mime: "image/png", description: "front", data: B.png)

    static func sample(padding: Int = 1000, commentFirst: Bool = true) -> [UInt8] {
        let comment = (type: UInt8(4), body: B.vorbisComment([
            "TITLE=Song", "artist=Artist One", "Artist=Artist Two", "ALBUM=Album", "TRACKNUMBER=3/12",
            "REPLAYGAIN_TRACK_GAIN=-7.10 dB", "bad key=dropped", "=empty key", "noseparator", "LYRICS=a\nb",
        ]))
        let picture = (type: UInt8(6), body: Self.picture)
        var blocks: [(type: UInt8, body: [UInt8])] = [(0, B.streamInfo(sampleRate: 96_000, channels: 2, bits: 24, totalSamples: 960_000))]
        blocks += commentFirst ? [comment, picture] : [picture, comment]
        blocks += [(2, B.latin1("APPL") + [1, 2, 3]), (1, [UInt8](repeating: 0, count: padding))]
        return B.flac(blocks)
    }

    @Test func readsBlocksCommentsAndPictures() throws {
        let flac = try FLACFile.parse(Data(Self.sample()))
        #expect(flac.blocks.count == 4)  // padding is not kept
        let info = try #require(flac.streamInfo)
        #expect(info.sampleRate == 96_000)
        #expect(info.channels == 2)
        #expect(info.bitsPerSample == 24)
        #expect(info.totalSamples == 960_000)
        #expect(info.durationMs == 10_000)
        let c = try #require(flac.vorbisComment)
        #expect(c.vendor == "reference libFLAC 1.4.3")
        let p = flac.properties
        #expect(p["TITLE"] == ["Song"])
        #expect(p["ARTIST"] == ["Artist One", "Artist Two"])  // keys are upper-cased and merged
        #expect(p["TRACKNUMBER"] == ["3/12"])
        #expect(p["REPLAYGAIN_TRACK_GAIN"] == ["-7.10 dB"])
        #expect(p["LYRICS"] == ["a\nb"])
        #expect(p["BAD KEY"] == ["dropped"])  // a space is a legal key character (0x20…0x7D)
        #expect(p.count == 7)
        #expect(flac.pictures == [TagPicture(data: Data(B.png), mimeType: "image/png", description: "front", pictureType: 3,
                                             width: 2, height: 2, colorDepth: 24, indexedColors: 0)])
        let tags = try AudioTagReader.read(Data(Self.sample()))
        #expect(tags.container == .flac)
        #expect(tags.pictures.count == 1)
    }

    @Test func vorbisCommentRules() {
        #expect(VorbisComment.isValidKey("TITLE"))
        #expect(VorbisComment.isValidKey("A B"))
        #expect(!VorbisComment.isValidKey(""))
        #expect(!VorbisComment.isValidKey("A=B"))
        #expect(!VorbisComment.isValidKey("~"))   // 0x7E is outside the range
        #expect(!VorbisComment.isValidKey("TÏTLE"))
        let pictureField = "METADATA_BLOCK_PICTURE=" + Data(B.flacPicture(data: B.jpeg)).base64EncodedString()
        let coverArt = "COVERART=" + Data(B.png).base64EncodedString()
        let comment = VorbisComment.parse(B.vorbisComment(vendor: "v", [pictureField, coverArt, "COVERART=!!!", "Ä=x", "K=v\u{0}tail"]))
        #expect(comment.pictures.count == 2)
        #expect(comment.pictures[0].data == Data(B.jpeg))
        #expect(comment.pictures[1].mimeType == "image/")
        #expect(comment.pictures[1].pictureType == 0)
        #expect(comment.fields.dictionary == ["K": ["v"]])  // non-ASCII key dropped, value cut at NUL
        // Malformed headers give what was read so far.
        #expect(VorbisComment.parse([1, 2]).vendor == "")
        #expect(VorbisComment.parse(B.le32(100) + B.utf8("short")).fields.isEmpty)
        #expect(VorbisComment.parse(B.le32(1) + B.utf8("v") + B.le32(1_000_000)).fields.isEmpty)
        #expect(VorbisComment.parse(B.le32(1) + B.utf8("v") + B.le32(2) + B.le32(3) + B.utf8("A=1") + B.le32(99) + B.utf8("B=2"))
            .fields.dictionary == ["A": ["1"]])
    }

    @Test func vorbisCommentRenderingIsSortedAndRoundTrips() {
        var c = VorbisComment(vendor: "PixlAudio")
        c.fields.insert("title", ["T"])
        c.fields.insert("ARTIST", ["B", "A"])
        c.pictures = [TagPicture(data: Data(B.png), mimeType: "image/png")]
        let rendered = c.render().byteArray
        let expectedStart = B.le32(9) + B.utf8("PixlAudio") + B.le32(4) + B.le32(8) + B.utf8("ARTIST=B") + B.le32(8)
            + B.utf8("ARTIST=A") + B.le32(7) + B.utf8("TITLE=T")
        #expect(Array(rendered.prefix(expectedStart.count)) == expectedStart)
        #expect(VorbisComment.parse(rendered) == c)
        #expect(c.render(framingBit: true).last == 1)
    }

    @Test func setPropertiesSemantics() {
        var c = VorbisComment(fields: ["A": ["1"], "B": ["2"], "C": ["3"]])
        let invalid = c.setProperties(["A": ["1"], "B": ["x", "y"], "D": [], "BAD=KEY": ["v"]])
        #expect(c.fields.dictionary == ["A": ["1"], "B": ["x", "y"]])
        #expect(invalid.dictionary == ["BAD=KEY": ["v"]])
    }

    @Test func rewriteReusesPaddingAndKeepsAudio() throws {
        let original = Data(Self.sample(padding: 1000))
        var flac = try FLACFile.parse(original)
        var p = flac.properties
        p["TITLE"] = ["A new, longer title"]
        p.remove("BAD KEY")
        flac.setProperties(p)
        let result = flac.render(into: original)
        #expect(result.fitsInPlace)
        #expect(result.data.count == original.count)
        #expect(result.data.suffix(B.flacAudio.count) == Data(B.flacAudio))
        let back = try FLACFile.parse(result.data)
        #expect(back.properties == p)
        #expect(back.pictures == flac.pictures)
        #expect(back.streamStart == flac.streamStart)
        // Order: STREAMINFO, the comment before the first picture, other blocks, then one padding block.
        let types = back.blocks.map { b -> UInt8 in
            switch b { case .streamInfo: 0; case .vorbisComment: 4; case .picture: 6; case .other(let t, _): t }
        }
        #expect(types == [0, 4, 6, 2])
    }

    @Test func commentGoesBeforeTheFirstPicture() throws {
        let original = Data(Self.sample(commentFirst: false))
        var flac = try FLACFile.parse(original)
        flac.setProperties(["TITLE": ["x"]])
        let back = try FLACFile.parse(flac.render(into: original).data)
        if case .vorbisComment = back.blocks[1] {} else { Issue.record("comment should be second") }
        if case .picture = back.blocks[2] {} else { Issue.record("picture should follow") }
        // Without pictures the comment goes last.
        var noPictures = flac
        noPictures.setPictures([])
        let again = try FLACFile.parse(noPictures.render(into: original).data)
        if case .vorbisComment = again.blocks.last! {} else { Issue.record("comment should be last") }
        #expect(again.pictures.isEmpty)
    }

    @Test func paddingRules() throws {
        // Growing past the old space: a fresh 4 KiB padding block.
        let small = Data(Self.sample(padding: 10))
        var flac = try FLACFile.parse(small)
        flac.setProperties(["TITLE": [String(repeating: "t", count: 500)]])
        let grown = flac.render(into: small)
        #expect(!grown.fitsInPlace)
        let reparsed = try FLACFile.parse(grown.data)
        let metadataBytes = reparsed.streamStart - reparsed.flacStart - 4
        let blockBytes = reparsed.blocks.reduce(0) { $0 + 4 + $1.renderBody().count }
        #expect(metadataBytes - blockBytes - 4 == FLACFile.minPaddingLength)
        // A big leftover in a small file: replaced by 4 KiB.
        let roomy = Data(Self.sample(padding: 50_000))
        let shrunk = try FLACFile.parse(roomy)
        let out = try FLACFile.parse(shrunk.render(into: roomy).data)
        let outBlocks = out.blocks.reduce(0) { $0 + 4 + $1.renderBody().count }
        #expect(out.streamStart - out.flacStart - 4 - outBlocks - 4 == FLACFile.minPaddingLength)
    }

    @Test func picturesCanBeReplacedAndRemoved() throws {
        let original = Data(Self.sample())
        let jpeg = TagPicture(data: Data(B.jpeg), mimeType: "image/jpeg", description: "Front Cover")
        let result = try AudioTagWriter.write(TagChanges(pictures: [jpeg, jpeg]), to: original)
        let back = try FLACFile.parse(result.data)
        #expect(back.pictures == [jpeg, jpeg])
        #expect(back.properties == (try FLACFile.parse(original)).properties)
        let none = try FLACFile.parse(try AudioTagWriter.write(TagChanges(pictures: []), to: original).data)
        #expect(none.pictures.isEmpty)
    }

    @Test func leadingID3v2AndTrailingID3v1AreKept() throws {
        let id3 = B.id3(4, B.frame24("TIT2", B.text(0, B.latin1("id3 title"))))
        let v1: [UInt8] = B.latin1("TAG") + [UInt8](repeating: 0x20, count: 124) + [255]
        let file = Data(id3 + Self.sample() + v1)
        let flac = try FLACFile.parse(file)
        #expect(flac.flacStart == id3.count)
        #expect(flac.id3v2?.properties["TITLE"] == ["id3 title"])
        #expect(flac.id3v1 != nil)
        #expect(flac.properties["TITLE"] == ["Song"])  // the Vorbis comment wins
        #expect(AudioContainer.detect(file) == .mp3)  // Android's magic check sees the ID3 header
        let tags = try AudioTagReader.read(file)
        #expect(tags.container == .flac)
        let written = try AudioTagWriter.write(TagChanges(properties: ["TITLE": ["new"]]), to: file)
        #expect(written.data.prefix(id3.count) == Data(id3))
        #expect(written.data.suffix(128) == Data(v1))
        #expect(try FLACFile.parse(written.data).properties["TITLE"] == ["new"])
    }

    @Test func emptyCommentFallsBackToID3() throws {
        let id3 = B.id3(4, B.frame24("TIT2", B.text(0, B.latin1("from id3"))))
        let file = Data(id3 + B.flac([(0, B.streamInfo()), (4, B.vorbisComment([]))]))
        #expect(try FLACFile.parse(file).properties["TITLE"] == ["from id3"])
        // A file without a comment block gets one when written.
        let bare = Data(B.flac([(0, B.streamInfo())]))
        var flac = try FLACFile.parse(bare)
        #expect(flac.vorbisComment == nil)
        flac.setProperties(["TITLE": ["t"]])
        #expect(try FLACFile.parse(flac.render(into: bare).data).vorbisComment?.fields.dictionary == ["TITLE": ["t"]])
        let written = try FLACFile.parse(FLACFile.parse(bare).render(into: bare).data)
        #expect(written.vorbisComment == VorbisComment())  // TagLib always writes a comment block
    }

    @Test func duplicateCommentsAndInvalidPicturesAreDropped() throws {
        let file = Data(B.flac([(0, B.streamInfo()), (4, B.vorbisComment(["A=1"])), (4, B.vorbisComment(["B=2"])),
                                (6, [0, 0, 0, 3]), (3, [])]))  // empty SEEKTABLE is allowed
        let flac = try FLACFile.parse(file)
        #expect(flac.properties.dictionary == ["A": ["1"]])
        #expect(flac.pictures.isEmpty)
        #expect(flac.blocks.count == 3)
    }

    @Test func structuralErrors() {
        #expect(throws: TagError.self) { try FLACFile.parse(Data(B.latin1("OggS0000"))) }
        #expect(throws: TagError.self) { try FLACFile.parse(Data(B.flac([(4, B.vorbisComment([]))]))) }
        #expect(throws: TagError.self) { try FLACFile.parse(Data(B.flac([(0, B.streamInfo()), (2, [])]))) }
        #expect(throws: TagError.self) { try FLACFile.parse(Data(B.latin1("fLaC") + [0x80, 0, 0, 34] + [1, 2, 3])) }
        #expect(throws: TagError.self) { try FLACFile.parse(Data(B.latin1("fLaC") + [0x00, 0, 0, 34] + B.streamInfo())) }
    }

    @Test func androidHighResAnalysis() {
        func header(_ rate: Int, _ bits: Int) -> Data { Data(B.latin1("fLaC") + [0x80, 0, 0, 34] + B.streamInfo(sampleRate: rate, bits: bits)) }
        #expect(FLACStreamInfo.analyze(fileHeader: header(44_100, 16), fileExtension: "flac") == .safe(sampleRate: 44_100, bitsPerSample: 16))
        #expect(FLACStreamInfo.analyze(fileHeader: header(192_000, 24), fileExtension: "FLAC") == .problematic(sampleRate: 192_000, bitsPerSample: 24))
        #expect(FLACStreamInfo.analyze(fileHeader: header(44_100, 16), fileExtension: "mp3") == .notFlac)
        #expect(FLACStreamInfo.analyze(fileHeader: header(44_100, 16).prefix(41), fileExtension: "flac") == .notFlac)
    }

    @Test func androidVorbisPictureBlock() throws {
        let encoded = FLACPicture.vorbisPictureBlock(imageBytes: Data(B.jpeg), mimeType: " ", width: 640, height: 480)
        let decoded = try #require(Data(base64Encoded: encoded))
        let expected = B.be32(3) + B.be32(10) + B.utf8("image/jpeg") + B.be32(11) + B.utf8("Front Cover") + B.be32(640)
            + B.be32(480) + B.be32(0) + B.be32(0) + B.be32(B.jpeg.count) + B.jpeg
        #expect(decoded.byteArray == expected)
        #expect(!encoded.contains("\n"))
        #expect(FLACPicture.parse(decoded.byteArray)?.mimeType == "image/jpeg")
        #expect(FLACPicture.parse(Array(expected.prefix(31))) == nil)
        #expect(FLACPicture.parse(B.be32(3) + B.be32(1000) + [UInt8](repeating: 0, count: 40)) == nil)
    }
}
