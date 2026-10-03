import Foundation
import Testing
@testable import PixlTags

@Suite("MP4 metadata")
struct MP4Tests {
    static let items: [UInt8] = B.textItem("\u{A9}nam", "Title")
        + B.textItem("\u{A9}ART", "Artist")
        + B.textItem("aART", "Album Artist")
        + B.textItem("\u{A9}alb", "Album")
        + B.atom("trkn", B.data(type: 0, [0, 0, 0, 3, 0, 12, 0, 0]))
        + B.atom("disk", B.data(type: 0, [0, 0, 0, 1, 0, 0]))
        + B.textItem("\u{A9}day", "2021-05-04T00:00:00Z")
        + B.textItem("\u{A9}gen", "Synthpop")
        + B.textItem("\u{A9}lyr", "Line 1\rLine 2")
        + B.textItem("\u{A9}wrt", "Composer")
        + B.atom("cpil", B.data(type: 21, [1]))
        + B.atom("tmpo", B.data(type: 21, [0, 120]))
        + B.atom("covr", B.data(type: 13, B.jpeg) + B.data(type: 14, B.png) + B.data(type: 99, [1, 2]))
        + B.freeForm(name: "REPLAYGAIN_TRACK_GAIN", values: ["-6.54 dB"])
        + B.freeForm(name: "replaygain_album_gain", values: ["-8.20 dB"])
        + B.freeForm(name: "MusicBrainz Album Id", values: ["mbid"])
        + B.freeForm(mean: "org.example", name: "OTHER", values: ["x"])
        + B.freeForm(name: "iTunSMPB", values: ["bin"], type: 0)
        + B.textItem("desc", "Podcast description")
        + B.textItem("\u{A9}xyz", "unknown item")

    @Test func readsIlstItemsAsTagLibProperties() throws {
        let file = Data(B.m4a(Self.items))
        #expect(MP4Tag.isMP4(file))
        #expect(AudioContainer.detect(file) == .mp4)
        let tag = try MP4Tag.parse(file)
        let p = tag.properties
        #expect(p["TITLE"] == ["Title"])
        #expect(p["ARTIST"] == ["Artist"])
        #expect(p["ALBUMARTIST"] == ["Album Artist"])
        #expect(p["ALBUM"] == ["Album"])
        #expect(p["TRACKNUMBER"] == ["3/12"])
        #expect(p["DISCNUMBER"] == ["1"])          // total 0: no "/total"
        #expect(p["DATE"] == ["2021-05-04T00:00:00Z"])
        #expect(p["GENRE"] == ["Synthpop"])
        #expect(p["LYRICS"] == ["Line 1\rLine 2"])
        #expect(p["COMPOSER"] == ["Composer"])
        #expect(p["COMPILATION"] == ["1"])
        #expect(p["BPM"] == ["120"])
        #expect(p["REPLAYGAIN_TRACK_GAIN"] == ["-6.54 dB"])
        #expect(p["REPLAYGAIN_ALBUM_GAIN"] == ["-8.20 dB"])   // free-form names are upper-cased like every key
        #expect(p["MUSICBRAINZ_ALBUMID"] == ["mbid"])
        #expect(p["OTHER"] == nil)                            // another issuer is not mapped
        #expect(p["ITUNSMPB"] == [])                          // binary free-form: key without values
        #expect(p["PODCASTDESC"] == ["Podcast description"])
        #expect(p.count == 17)
        #expect(tag["\u{A9}xyz"] == .strings(["unknown item"]))
        #expect(tag["----:org.example:OTHER"] == .strings(["x"]))
        #expect(tag.pictures == [TagPicture(data: Data(B.jpeg), mimeType: "image/jpeg"),
                                 TagPicture(data: Data(B.png), mimeType: "image/png")])
        let tags = try AudioTagReader.read(file)
        #expect(tags.container == .mp4)
        #expect(tags.properties == p)
    }

    @Test func itemTypes() throws {
        let items = B.atom("gnre", B.data(type: 0, [0, 19]))                         // ID3v1 index + 1 → Techno
            + B.atom("pgap", B.data(type: 21, [0]))
            + B.atom("tvsn", B.data(type: 21, B.be32(4)))
            + B.atom("stik", B.data(type: 21, [9]))
            + B.atom("plID", B.data(type: 21, B.be32(0) + B.be32(77)))
            + B.atom("\u{A9}mvi", B.data(type: 21, [0xFF, 0xFE]))                      // signed short
            + B.textItem("\u{A9}nam", "One", "Two")                                     // several data atoms
            + B.atom("\u{A9}cmt", B.data(type: 0, B.utf8("implicit type is not text")))
            + B.atom("\u{A9}grp", B.atom("name", [0, 0, 0, 0] + B.utf8("x")))           // not a data atom
        let tag = try MP4Tag.parse(Data(B.m4a(items)))
        let p = tag.properties
        #expect(p["GENRE"] == ["Techno"])
        #expect(p["GAPLESSPLAYBACK"] == ["0"])
        #expect(p["TVSEASON"] == ["4"])
        #expect(p["MOVEMENTNUMBER"] == ["-2"])
        #expect(p["TITLE"] == ["One", "Two"])
        #expect(p["COMMENT"] == nil)
        #expect(p["GROUPING"] == nil)
        #expect(tag["stik"] == .byte(9))
        #expect(tag["plID"] == .longLong(77))
    }

    @Test func duplicatesQuickTimeMetaAndLayouts() throws {
        // The first of two items with the same name wins; gnre and ©gen share a name.
        let dup = B.textItem("\u{A9}nam", "First") + B.textItem("\u{A9}nam", "Second")
            + B.textItem("\u{A9}gen", "Text genre") + B.atom("gnre", B.data(type: 0, [0, 1]))
        #expect(try MP4Tag.parse(Data(B.m4a(dup))).properties["TITLE"] == ["First"])
        #expect(try MP4Tag.parse(Data(B.m4a(dup))).properties["GENRE"] == ["Text genre"])
        // QuickTime-style meta without version/flags, moov after mdat.
        let qt = try MP4Tag.parse(Data(B.m4a(B.textItem("\u{A9}nam", "QT"), isoMeta: false, mdatFirst: true)))
        #expect(qt.properties["TITLE"] == ["QT"])
        // 64-bit atom size on the item.
        let wide = B.be32(1) + B.latin1("\u{A9}nam") + [0, 0, 0, 0] + B.be32(16 + 20) + B.data(type: 1, B.utf8("Wide"))
        #expect(try MP4Tag.parse(Data(B.m4a(wide))).properties["TITLE"] == ["Wide"])
        // gnre 0 is ignored.
        #expect(try MP4Tag.parse(Data(B.m4a(B.atom("gnre", B.data(type: 0, [0, 0]))))).properties.isEmpty)
    }

    @Test func missingMetadataAndBrokenFiles() throws {
        let noUdta = B.atom("ftyp", B.latin1("M4A ") + B.be32(0)) + B.atom("moov", B.atom("mvhd", [UInt8](repeating: 0, count: 100)))
        #expect(try MP4Tag.parse(Data(noUdta)).items.isEmpty)
        let noMoov = B.atom("ftyp", B.latin1("M4A ") + B.be32(0)) + B.atom("mdat", [1, 2, 3])
        #expect(throws: TagError.self) { try MP4Tag.parse(Data(noMoov)) }
        let badSize = B.atom("ftyp", B.latin1("M4A ") + B.be32(0)) + B.be32(4) + B.latin1("moov")
        #expect(throws: TagError.self) { try MP4Tag.parse(Data(badSize)) }
        // A truncated item ends the list without failing.
        let truncatedItem = B.textItem("\u{A9}nam", "OK") + B.be32(100) + B.latin1("\u{A9}ART")
        #expect(try MP4Tag.parse(Data(B.m4a(truncatedItem))).properties["TITLE"] == ["OK"])
        #expect(throws: TagError.self) { try AudioTagWriter.write(TagChanges(properties: ["TITLE": ["x"]]), to: Data(B.m4a([]))) }
    }

    /// A forged 64-bit box size (`size == 1`, largesize 0xFFFF_FFFF_FFFF_FFFF) used to overflow `pos + size` and
    /// trap: after `ftyp`, inside `moov` and inside `ilst`. Each must fail or stop cleanly instead.
    @Test func hugeSixtyFourBitSizesDoNotTrap() throws {
        let ftyp = B.atom("ftyp", B.latin1("M4A ") + B.be32(0))
        let max64 = [UInt8](repeating: 0xFF, count: 8)
        let hugeFree: [UInt8] = B.be32(1) + B.latin1("free") + max64
        #expect(throws: TagError.self) { try MP4Tag.parse(Data(ftyp + hugeFree)) }
        let hugeChild = B.atom("moov", B.be32(1) + B.latin1("udta") + max64 + [UInt8](repeating: 0, count: 8))
        #expect(throws: TagError.self) { try MP4Tag.parse(Data(ftyp + hugeChild)) }
        let hugeItem: [UInt8] = B.be32(1) + B.latin1("\u{A9}nam") + max64
        let tag = try MP4Tag.parse(Data(B.m4a(B.textItem("\u{A9}ART", "Artist") + hugeItem)))
        #expect(tag.properties["ARTIST"] == ["Artist"])
        #expect(tag.properties["TITLE"] == nil)
    }

    @Test func propertyKeyTable() {
        #expect(MP4Tag.propertyKey(forItem: "----:com.apple.iTunes:REPLAYGAIN_TRACK_GAIN") == "REPLAYGAIN_TRACK_GAIN")
        #expect(MP4Tag.propertyKey(forItem: "----:com.apple.iTunes:MusicBrainz Track Id") == "MUSICBRAINZ_TRACKID")
        #expect(MP4Tag.propertyKey(forItem: "----:com.apple.iTunes:") == nil)
        #expect(MP4Tag.propertyKey(forItem: "----:org:X") == nil)
        #expect(MP4Tag.propertyKey(forItem: "covr") == nil)
        #expect(ReplayGainTags.mp4FieldId("REPLAYGAIN_TRACK_GAIN") == "----:com.apple.iTunes:REPLAYGAIN_TRACK_GAIN")
        #expect(MP4Cover(format: 27, data: Data()).mimeType == "image/bmp")
        #expect(MP4Cover(format: 12, data: Data()).mimeType == "image/gif")
        #expect(MP4Cover(format: 0, data: Data()).mimeType == "")
    }
}
