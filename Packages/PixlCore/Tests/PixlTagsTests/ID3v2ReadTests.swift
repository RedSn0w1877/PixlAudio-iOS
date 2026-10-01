import Foundation
import Testing
@testable import PixlTags

@Suite("ID3v2 reading")
struct ID3v2ReadTests {
    func parse(_ bytes: [UInt8]) throws -> ID3v2Tag { try #require(ID3v2Tag.parse(Data(bytes))) }

    @Test func v24CoreFramesBecomeTagLibProperties() throws {
        let body = B.frame24("TIT2", B.text(3, B.utf8("Héllo 日本")))
            + B.frame24("TPE1", B.text(3, B.utf8("A") + [0] + B.utf8("B")))
            + B.frame24("TPE2", B.text(0, B.latin1("Album Artist")))
            + B.frame24("TALB", B.text(0, B.latin1("Album")))
            + B.frame24("TRCK", B.text(0, B.latin1("3/12")))
            + B.frame24("TPOS", B.text(0, B.latin1("1/2")))
            + B.frame24("TDRC", B.text(0, B.latin1("2021-05-04T10:20")))
            + B.frame24("TCON", B.text(0, B.latin1("Rock")))
            + B.frame24("TCOM", B.text(0, B.latin1("Composer")))
            + [UInt8](repeating: 0, count: 64)
        let tag = try parse(B.id3(4, body) + B.mp3Frames(1))
        #expect(tag.version == 4)
        #expect(tag.frames.count == 9)
        let p = tag.properties
        #expect(p["TITLE"] == ["Héllo 日本"])
        #expect(p["ARTIST"] == ["A", "B"])
        #expect(p["ALBUMARTIST"] == ["Album Artist"])
        #expect(p["ALBUM"] == ["Album"])
        #expect(p["TRACKNUMBER"] == ["3/12"])
        #expect(p["DISCNUMBER"] == ["1/2"])
        #expect(p["DATE"] == ["2021-05-04 10:20"])  // TagLib swaps the ISO 'T' for a space
        #expect(p["GENRE"] == ["Rock"])
        #expect(p["COMPOSER"] == ["Composer"])
        #expect(tag.originalSize == 10 + body.count)
        #expect(tag.originalBodySize == body.count)
        #expect(p["title"] == ["Héllo 日本"])  // keys are case-insensitive (ASCII)
    }

    @Test func textEncodingsAndTerminators() throws {
        let body = B.frame24("TIT1", B.text(0, B.latin1("Café") + [0]))                       // trailing NUL
            + B.frame24("TIT2", B.text(1, B.utf16LE("Ünï") + [0, 0] + B.utf16LE("second", bom: false) + [0, 0]))
            + B.frame24("TIT3", B.text(1, B.utf16BE("Big") + [0, 0] + B.utf16BE("Endian", bom: false)))
            + B.frame24("TPE3", B.text(2, B.utf16BE("NoBOM", bom: false)))
            + B.frame24("TPE4", B.text(3, B.utf8("ü") + [0, 0, 0]))
        let tag = try parse(B.id3(4, body))
        let p = tag.properties
        #expect(p["WORK"] == ["Café"])
        #expect(p["TITLE"] == ["Ünï", "second"])      // a BOM-less second UTF-16 value inherits the first BOM
        #expect(p["SUBTITLE"] == ["Big", "Endian"])
        #expect(p["CONDUCTOR"] == ["NoBOM"])
        #expect(p["REMIXER"] == ["ü"])
        if case .text(let enc, _) = tag.frame("TIT2")!.content { #expect(enc == .utf16) } else { Issue.record("TIT2") }
    }

    @Test func emptyFieldsAreDroppedAndTruncatedAtNul() throws {
        let body = B.frame24("TPE1", B.text(0, B.latin1("A") + [0, 0] + B.latin1("B")))
            + B.frame24("TXXX", B.text(0, [0] + B.latin1("no description")))
            + B.frame24("TIT2", B.text(3, []))  // only an encoding byte: TagLib needs ≥ 2 bytes
        let tag = try parse(B.id3(4, body))
        #expect(tag.properties["ARTIST"] == ["A", "B"])
        #expect(tag.properties[""] == ["no description"])
        if case .userText(_, let d, let v) = tag.frames[1].content {
            #expect(d == "")
            #expect(v == ["no description"])
        } else { Issue.record("TXXX") }
        #expect(tag.frames.count == 3)
        if case .binary(let d) = tag.frames[2].content { #expect(d == Data([3])) } else { Issue.record("1-byte text frame") }
    }

    @Test func userTextFramesAndReplayGain() throws {
        let body = B.frame24("TXXX", B.text(0, B.latin1("REPLAYGAIN_TRACK_GAIN") + [0] + B.latin1("-6.54 dB")))
            + B.frame24("TXXX", B.text(0, B.latin1("replaygain_album_gain") + [0] + B.latin1("-8.20 dB")))
            + B.frame24("TXXX", B.text(3, B.utf8("MusicBrainz Album Id") + [0] + B.utf8("abc")))
            + B.frame24("TXXX", B.text(3, B.utf8("Acoustid Id") + [0] + B.utf8("x") + [0] + B.utf8("y")))
            + B.frame24("TXXX", B.text(0, B.latin1("ONLY_DESCRIPTION")))
        let tag = try parse(B.id3(4, body))
        let p = tag.properties
        #expect(p["REPLAYGAIN_TRACK_GAIN"] == ["-6.54 dB"])
        #expect(p["REPLAYGAIN_ALBUM_GAIN"] == ["-8.20 dB"])
        #expect(p["MUSICBRAINZ_ALBUMID"] == ["abc"])
        #expect(p["ACOUSTID_ID"] == ["x", "y"])
        #expect(p["ONLY_DESCRIPTION"] == nil)
        #expect(tag.userText("replaygain_track_gain") == ["-6.54 dB"])
    }

    @Test func commentsLyricsUrlsAndIdentifiers() throws {
        let comm = { (desc: String, text: String) in B.frame24("COMM", [0] + B.latin1("eng") + B.latin1(desc) + [0] + B.latin1(text)) }
        let body = comm("", "plain comment")
            + comm("iTunNORM", " 0000")
            + comm("Comment", "named comment")
            + B.frame24("USLT", [1] + B.latin1("eng") + B.utf16LE("") + [0, 0] + B.utf16LE("Line 1\nLine 2"))
            + B.frame24("USLT", [3] + B.latin1("deu") + B.utf8("Deutsch") + [0] + B.utf8("Zeile") + [0])
            + B.frame24("WXXX", [0] + B.latin1("") + [0] + B.latin1("https://example.com"))
            + B.frame24("WXXX", [0] + B.latin1("shop") + [0] + B.latin1("https://shop.example"))
            + B.frame24("WOAR", B.latin1("https://artist.example"))
            + B.frame24("UFID", B.latin1("http://musicbrainz.org") + [0] + B.latin1("track-id"))
            + B.frame24("UFID", B.latin1("other") + [0] + [1, 2, 3])
        let tag = try parse(B.id3(4, body))
        let p = tag.properties
        #expect(p["COMMENT"] == ["plain comment", "named comment"])
        #expect(p["COMMENT:ITUNNORM"] == [" 0000"])
        #expect(p["LYRICS"] == ["Line 1\nLine 2"])
        #expect(p["LYRICS:DEUTSCH"] == ["Zeile"])
        #expect(p["URL"] == ["https://example.com"])
        #expect(p["URL:SHOP"] == ["https://shop.example"])
        #expect(p["ARTISTWEBPAGE"] == ["https://artist.example"])
        #expect(p["MUSICBRAINZ_TRACKID"] == ["track-id"])
        #expect(tag.unsyncedLyrics.map(\.language) == ["eng", "deu"])
    }

    @Test func attachedPictures() throws {
        let body = B.frame24("APIC", B.apicBody(encoding: 1, mime: "image/png", type: 3, description: B.utf16LE("Cover"),
                                                terminator: [0, 0], data: B.png))
            + B.frame24("APIC", B.apicBody(mime: "image/jpeg", type: 4, description: [], data: B.jpeg))
            + B.frame24("APIC", [0, 0x41])  // truncated: kept as binary
        let tag = try parse(B.id3(4, body))
        #expect(tag.pictures.count == 2)
        #expect(tag.pictures[0] == TagPicture(data: Data(B.png), mimeType: "image/png", description: "Cover", pictureType: 3))
        #expect(tag.pictures[1].mimeType == "image/jpeg")
        #expect(tag.pictures[1].pictureType == 4)
        #expect(tag.pictures[1].typeName == "Back Cover")
        #expect(tag.properties.isEmpty)  // pictures are not properties
        if case .binary = tag.frames[2].content {} else { Issue.record("truncated APIC") }
    }

    @Test func syncedLyricsFrame() throws {
        var sylt: [UInt8] = [1] + B.latin1("eng") + [2, 1] + B.utf16LE("desc") + [0, 0]
        sylt += B.utf16LE("First") + [0, 0] + B.be32(1000)
        sylt += B.utf16LE("\nSecond", bom: false) + [0, 0] + B.be32(2500)
        sylt += B.utf16LE("Broken") + [0, 0] + [0, 0]  // incomplete timestamp: parsing stops
        let tag = try parse(B.id3(4, B.frame24("SYLT", sylt)))
        let s = try #require(tag.syncedLyrics.first)
        #expect(s.language == "eng")
        #expect(s.timestampFormat == .milliseconds)
        #expect(s.contentType == 1)
        #expect(s.description == "desc")
        #expect(s.entries == [.init(text: "First", time: 1000), .init(text: "\nSecond", time: 2500)])
        #expect(tag.properties.isEmpty)
    }

    @Test func v23DatesAreFoldedIntoTDRC() throws {
        let body = B.frame23("TYER", B.text(0, B.latin1("2019")))
            + B.frame23("TDAT", B.text(0, B.latin1("3112")))
            + B.frame23("TIME", B.text(0, B.latin1("2359")))
            + B.frame23("TORY", B.text(0, B.latin1("1999")))
            + B.frame23("IPLS", B.text(0, B.latin1("PRODUCER") + [0] + B.latin1("P1,P2") + [0] + B.latin1("ARRANGER") + [0] + B.latin1("A")))
            + B.frame23("RVAD", [0, 0, 0])
            + B.frame23("TSIZ", B.text(0, B.latin1("123")))
        let tag = try parse(B.id3(3, body))
        #expect(tag.version == 3)
        #expect(tag.frames.map(\.id) == ["TDRC", "TDOR", "TIPL"])
        let p = tag.properties
        #expect(p["DATE"] == ["2019-12-31 23:59"])
        #expect(p["ORIGINALDATE"] == ["1999"])
        #expect(p["PRODUCER"] == ["P1", "P2"])
        #expect(p["ARRANGER"] == ["A"])
    }

    @Test func v23DateAggregationRules() throws {
        // TDAT without TYER is dropped; a TYER that is not 4 characters is not extended.
        let noYear = try parse(B.id3(3, B.frame23("TDAT", B.text(0, B.latin1("0102")))))
        #expect(noYear.frames.isEmpty)
        let longYear = try parse(B.id3(3, B.frame23("TYER", B.text(0, B.latin1("20190"))) + B.frame23("TDAT", B.text(0, B.latin1("0102")))))
        #expect(longYear.properties["DATE"] == ["20190"])
        let badDate = try parse(B.id3(3, B.frame23("TYER", B.text(0, B.latin1("2019"))) + B.frame23("TDAT", B.text(0, B.latin1("012")))))
        #expect(badDate.properties["DATE"] == ["2019"])
        let noTime = try parse(B.id3(3, B.frame23("TYER", B.text(0, B.latin1("2019"))) + B.frame23("TDAT", B.text(1, B.utf16LE("0102")))))
        #expect(noTime.properties["DATE"] == ["2019-02-01"])
    }

    @Test func v22FramesAreConverted() throws {
        let pic: [UInt8] = [0] + B.latin1("PNG") + [3] + B.latin1("c") + [0] + B.png
        let body = B.frame22("TT2", B.text(0, B.latin1("Title")))
            + B.frame22("TP1", B.text(0, B.latin1("Artist")))
            + B.frame22("TAL", B.text(0, B.latin1("Album")))
            + B.frame22("TRK", B.text(0, B.latin1("7")))
            + B.frame22("TYE", B.text(0, B.latin1("1987")))
            + B.frame22("TCO", B.text(0, B.latin1("(13)")))
            + B.frame22("COM", [0] + B.latin1("eng") + [0] + B.latin1("hi"))
            + B.frame22("ULT", [0] + B.latin1("eng") + [0] + B.latin1("words"))
            + B.frame22("TXX", B.text(0, B.latin1("REPLAYGAIN_TRACK_GAIN") + [0] + B.latin1("-1 dB")))
            + B.frame22("PIC", pic)
            + B.frame22("ZZZ", [1, 2, 3])            // unknown: dropped
            + B.frame22("TDA", B.text(0, B.latin1("0101")))  // obsolete: dropped
        let tag = try parse(B.id3(2, body))
        #expect(tag.version == 2)
        #expect(tag.frames.map(\.id) == ["TIT2", "TPE1", "TALB", "TRCK", "TDRC", "TCON", "COMM", "USLT", "TXXX", "APIC"])
        let p = tag.properties
        #expect(p["TITLE"] == ["Title"])
        #expect(p["DATE"] == ["1987"])
        #expect(p["GENRE"] == ["Pop"])
        #expect(p["COMMENT"] == ["hi"])
        #expect(p["LYRICS"] == ["words"])
        #expect(p["REPLAYGAIN_TRACK_GAIN"] == ["-1 dB"])
        #expect(tag.pictures.first?.mimeType == "image/png")
        #expect(tag.pictures.first?.description == "c")
    }

    @Test func genreReferences() throws {
        func genre(_ s: String) throws -> [String]? {
            try parse(B.id3(4, B.frame24("TCON", B.text(0, B.latin1(s))))).properties["GENRE"]
        }
        #expect(try genre("(17)") == ["Rock"])
        #expect(try genre("(17)Rock") == ["Rock"])
        #expect(try genre("(4)(17)Eurodisco") == ["Disco", "Rock", "Eurodisco"])
        #expect(try genre("(RX)(CR)") == ["RX", "CR"])
        #expect(try genre("17") == ["Rock"])
        #expect(try genre("Synthwave") == ["Synthwave"])
        #expect(try genre("(255)") == [])     // genre(255) is "" == the rest: TagLib drops it and keeps an empty list
        #expect(try genre("(abc)Jazz") == ["Jazz"])
        #expect(ID3v2Tag.updateGenre(["(17)Rock", "x"]) == ["Rock", "x"])
        #expect(ID3v1Genres.names.count == 192)
        #expect(ID3v1Genres.index(of: "Bebob") == 85)
        #expect(ID3v1Genres.index(of: "Nope") == 255)
    }

    @Test func v23TagLevelUnsynchronisation() throws {
        let apic = B.apicBody(mime: "image/jpeg", type: 3, description: [], data: B.jpeg + [0xFF, 0x00, 0xFF])
        let frames = B.frame23("TIT2", B.text(0, B.latin1("ÿÿ") + [0xFF, 0xE2])) + B.frame23("APIC", apic)
        let body = Unsynchronisation.encode(frames)
        #expect(body.count > frames.count)
        let tag = try parse(B.id3(3, flags: 0x80, body))
        #expect(tag.wasUnsynchronised)
        #expect(tag.pictures.first?.data == Data(B.jpeg + [0xFF, 0x00, 0xFF]))
        #expect(tag.properties["TITLE"] == ["ÿÿÿâ"])
    }

    @Test func v24FrameLevelUnsynchronisationAndDataLength() throws {
        let raw = B.apicBody(mime: "image/jpeg", type: 3, description: [], data: B.jpeg)
        let encoded = Unsynchronisation.encode(raw)
        let withLength = B.syncsafe(raw.count) + encoded
        let body = B.frame24("APIC", withLength, format: 0x03)
            + B.frame24("TIT2", Unsynchronisation.encode(B.text(0, [0xFF, 0xFF, 0x41])), format: 0x02)
        let tag = try parse(B.id3(4, body))
        #expect(tag.pictures.first?.data == Data(B.jpeg))
        #expect(tag.properties["TITLE"] == ["ÿÿA"])
        // The tag-level flag alone also means every frame is unsynchronised.
        let tagLevel = try parse(B.id3(4, flags: 0x80, B.frame24("TIT2", Unsynchronisation.encode(B.text(0, [0xFF, 0xFF, 0x42])))))
        #expect(tagLevel.properties["TITLE"] == ["ÿÿB"])
    }

    @Test func unsynchronisationCodec() {
        #expect(Unsynchronisation.decode([0xFF, 0x00, 0xE0, 0xFF, 0x00, 0x00][...]) == [0xFF, 0xE0, 0xFF, 0x00])
        #expect(Unsynchronisation.decode([0xFF, 0x00][...]) == [0xFF])
        #expect(Unsynchronisation.decode([0xFF][...]) == [0xFF])
        #expect(Unsynchronisation.decode([][...]) == [])
        #expect(Unsynchronisation.encode([0xFF, 0xE0, 0xFF, 0x00, 0x41, 0xFF]) == [0xFF, 0x00, 0xE0, 0xFF, 0x00, 0x00, 0x41, 0xFF, 0x00])
        let sample: [UInt8] = (0..<1000).map { UInt8(($0 * 37) & 0xFF) } + [0xFF, 0xFF, 0x00, 0xFF]
        #expect(Unsynchronisation.decode(Unsynchronisation.encode(sample)[...]) == sample)
    }

    @Test func extendedHeaders() throws {
        let frames = B.frame23("TIT2", B.text(0, B.latin1("Ext")))
        let v23 = try parse(B.id3(3, flags: 0x40, B.be32(6) + [0, 0] + B.be32(16) + frames + [UInt8](repeating: 0, count: 16)))
        #expect(v23.hadExtendedHeader)
        #expect(v23.properties["TITLE"] == ["Ext"])
        let v23crc = try parse(B.id3(3, flags: 0x40, B.be32(10) + [0x80, 0] + B.be32(0) + B.be32(0x1234_5678) + frames))
        #expect(v23crc.properties["TITLE"] == ["Ext"])
        let frames24 = B.frame24("TIT2", B.text(0, B.latin1("Ext4")))
        let v24 = try parse(B.id3(4, flags: 0x40, B.syncsafe(6) + [1, 0] + frames24))
        #expect(v24.properties["TITLE"] == ["Ext4"])
        let v24crc = try parse(B.id3(4, flags: 0x40, B.syncsafe(11) + [1, 0x20] + [5] + [0, 0, 0, 0] + frames24))
        #expect(v24crc.properties["TITLE"] == ["Ext4"])
    }

    @Test func footerIsCountedInTheTagSize() throws {
        let body = B.frame24("TIT2", B.text(0, B.latin1("Foot")))
        let file = B.id3(4, flags: 0x10, body, footer: true) + B.mp3Frames(1)
        let tag = try parse(file)
        #expect(tag.hadFooter)
        #expect(tag.originalSize == 20 + body.count)
        #expect(ID3v2Tag.totalSize(in: Data(file)) == 20 + body.count)
        let tags = try AudioTagReader.read(Data(file))
        #expect(tags.properties["TITLE"] == ["Foot"])
    }

    @Test func iTunesPlainFrameSizes() throws {
        let long = [UInt8](repeating: 0x61, count: 299)  // 300-byte body: syncsafe misreads 00 00 01 2C as 172
        let body = B.frame24("TIT2", B.text(0, long), plainSize: true) + B.frame24("TPE1", B.text(0, B.latin1("Next")))
        let tag = try parse(B.id3(4, body))
        #expect(tag.properties["TITLE"] == [String(repeating: "a", count: 299)])
        #expect(tag.properties["ARTIST"] == ["Next"])
    }

    @Test func frameFlagsAndOpaqueFrames() throws {
        let body = B.frame23("TIT2", B.text(0, B.latin1("Keep")))
            + B.frame23("TPE1", B.text(0, B.latin1("Discard")), status: 0x80)
            + B.frame23("TALB", B.be32(9) + [0x78, 0x9C, 1, 2, 3], format: 0x80)    // zlib-compressed: opaque
            + B.frame23("TCOM", [7] + B.text(0, B.latin1("Grouped")), format: 0x20) // grouping byte stripped
        let tag = try parse(B.id3(3, body))
        #expect(tag.frames[1].discardOnTagAlteration)
        if case .opaque(let data, let flags, let version) = tag.frames[2].content {
            #expect(data == Data(B.be32(9) + [0x78, 0x9C, 1, 2, 3]))
            #expect(flags == 0x80)
            #expect(version == 3)
        } else { Issue.record("opaque") }
        #expect(tag.properties["COMPOSER"] == ["Grouped"])
        #expect(tag.properties["ALBUM"] == nil)
        let v24 = try parse(B.id3(4, B.frame24("TCOM", [9] + B.syncsafe(5) + B.text(0, B.latin1("Both")), format: 0x41)))
        #expect(v24.properties["COMPOSER"] == ["Both"])
    }

    @Test func paddingAndGarbageStopParsing() throws {
        let body = B.frame24("TIT2", B.text(0, B.latin1("A"))) + [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + B.frame24("TPE1", B.text(0, B.latin1("hidden")))
        #expect(try parse(B.id3(4, body)).frames.count == 1)
        let garbage = B.frame24("TIT2", B.text(0, B.latin1("A"))) + B.latin1("ab!d") + [0, 0, 0, 1, 0, 0, 0x41] + [UInt8](repeating: 0, count: 4)
        #expect(try parse(B.id3(4, garbage)).frames.count == 1)
        let oversized = B.latin1("TIT2") + B.syncsafe(500) + [0, 0, 0, 0x41]
        #expect(try parse(B.id3(4, oversized + [UInt8](repeating: 0, count: 10))).frames.isEmpty)
    }

    @Test func headerValidation() {
        #expect(ID3v2Tag.parse(Data(B.latin1("ID3") + [5, 0, 0] + B.syncsafe(0))) == nil)        // unknown major
        #expect(ID3v2Tag.totalSize(in: Data(B.latin1("ID3") + [5, 0, 0] + B.syncsafe(20))) == 30)
        #expect(ID3v2Tag.totalSize(in: Data(B.latin1("ID3") + [3, 0, 0, 0, 0, 0x80, 0])) == nil) // not syncsafe
        #expect(ID3v2Tag.totalSize(in: Data(B.latin1("ID3") + [0xFF, 0, 0, 0, 0, 0, 0])) == nil)
        #expect(ID3v2Tag.totalSize(in: Data(B.latin1("TAG") + [3, 0, 0, 0, 0, 0, 0])) == nil)
        #expect(ID3v2Tag.parse(Data(B.latin1("ID3"))) == nil)
        // A header claiming more bytes than the file has still parses what is there.
        let truncated = B.latin1("ID3") + [4, 0, 0] + B.syncsafe(1000) + B.frame24("TIT2", B.text(0, B.latin1("T")))
        #expect(ID3v2Tag.parse(Data(truncated))?.properties["TITLE"] == ["T"])
    }

    @Test func tagLibIntegerParsing() {
        #expect(TagLibInt.parse("17") == 17)
        #expect(TagLibInt.parse(" 17") == 17)
        #expect(TagLibInt.parse("-3") == -3)
        #expect(TagLibInt.parse("") == 0)
        #expect(TagLibInt.parse("17 ") == nil)
        #expect(TagLibInt.parse("RX") == nil)
        #expect(TagLibInt.parse("99999999999") == nil)
    }
}
