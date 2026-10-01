import Foundation
import PixlModel
import Testing
@testable import PixlTags

@Suite("ID3v2 writing")
struct ID3v2WriteTests {
    func reparse(_ d: Data) throws -> ID3v2Tag { try #require(ID3v2Tag.parse(d)) }

    @Test func newV24TagLayout() throws {
        let tag = ID3v2Tag(frames: [.text("TIT2", "Hi"), .text("TPE1", ["A", "B"], encoding: .latin1)])
        let d = tag.render()
        let b = d.byteArray
        #expect(Array(b[0..<6]) == [0x49, 0x44, 0x33, 4, 0, 0])
        let frames = B.frame24("TIT2", [3] + B.utf8("Hi")) + B.frame24("TPE1", [0] + B.latin1("A") + [0] + B.latin1("B"))
        #expect(Array(b[10..<(10 + frames.count)]) == frames)
        #expect(b.count == 10 + frames.count + ID3v2Tag.minPaddingSize)  // a new tag gets 1 KiB of padding
        #expect(Array(b[6..<10]) == B.syncsafe(frames.count + 1024))
        let back = try reparse(d)
        #expect(back.frames == tag.frames)
    }

    @Test func paddingReuseRules() {
        // Fits, small leftover: keep the original size.
        #expect(ID3v2Tag.paddingSize(framesSize: 900, originalBodySize: 1000, fileLength: 10_000) == 100)
        // Leftover above max(1 % of the file, 1 KiB): fresh 1 KiB.
        #expect(ID3v2Tag.paddingSize(framesSize: 100, originalBodySize: 5000, fileLength: 10_000) == 1024)
        // 1 % of a big file allows a larger leftover.
        #expect(ID3v2Tag.paddingSize(framesSize: 100, originalBodySize: 5000, fileLength: 1_000_000) == 4900)
        // Capped at 1 MiB.
        #expect(ID3v2Tag.paddingSize(framesSize: 100, originalBodySize: 2_000_000, fileLength: 1_000_000_000) == 1024)
        // Doesn't fit (or exactly fills): 1 KiB.
        #expect(ID3v2Tag.paddingSize(framesSize: 1000, originalBodySize: 1000, fileLength: 10_000) == 1024)
        #expect(ID3v2Tag.paddingSize(framesSize: 2000, originalBodySize: 1000, fileLength: 10_000) == 1024)
        #expect(ID3v2Tag.paddingSize(framesSize: 10, originalBodySize: 0, fileLength: nil) == 1024)
    }

    @Test func rewritingKeepsTheOriginalSizeWhenTheFramesFit() throws {
        let original = B.id3(4, B.frame24("TIT2", B.text(0, B.latin1("Old title"))) + [UInt8](repeating: 0, count: 1000))
        let file = Data(original + B.mp3Frames(3))
        var tag = try #require(ID3v2Tag.parse(file))
        tag.frames[0] = .text("TIT2", "A slightly longer new title")
        let rendered = tag.render(version: 4, fileLength: file.count)
        #expect(rendered.count == original.count)
        #expect(try reparse(rendered).properties["TITLE"] == ["A slightly longer new title"])
    }

    @Test func v23RenderingConvertsFramesAndEncodings() throws {
        var tag = ID3v2Tag(frames: [
            .text("TIT2", "日本"),                                        // UTF-8 → UTF-16 in 2.3
            .text("TALB", "Plain", encoding: .latin1),
            .text("TDRC", "2020-07-08T09:10"),
            .text("TDOR", "1999-01-01"),
            .text("TIPL", ["PRODUCER", "P"], encoding: .latin1),
            .text("TMCL", ["Guitar", "G"], encoding: .latin1),
            .text("TSOP", "Sort"),                                       // 2.4-only: dropped
            .text("TMOO", "Calm"),
            .userText("REPLAYGAIN_TRACK_GAIN", "-1.00 dB"),
            .unsyncedLyrics("ü", description: "LYRICS"),
        ])
        let d = tag.render(version: 3)
        let b = d.byteArray
        #expect(b[3] == 3)
        // First frame: TIT2 in UTF-16 with BOM, plain 32-bit size.
        let tit2 = B.frame23("TIT2", [1] + B.utf16LE("日本"))
        #expect(Array(b[10..<(10 + tit2.count)]) == tit2)
        let back = try reparse(d)
        #expect(back.version == 3)
        #expect(back.frames.map(\.id) == ["TIT2", "TALB", "TXXX", "USLT", "TDOR", "TDRC", "TIPL"])
        let p = back.properties
        #expect(p["TITLE"] == ["日本"])
        #expect(p["DATE"] == ["2020-07-08 09:10"])
        #expect(p["ORIGINALDATE"] == ["1999"])
        // TMCL + TIPL become one IPLS (read back as TIPL); "Guitar" is not a TIPL role, so TagLib marks the whole frame
        // unsupported and neither the performer nor the producer comes back.
        #expect(p["PERFORMER:GUITAR"] == nil)
        #expect(p["PRODUCER"] == nil)
        #expect(back.frame("TIPL")?.textValues == ["Guitar", "G", "PRODUCER", "P"])
        #expect(p["ARTISTSORT"] == nil)
        #expect(p["LYRICS"] == ["ü"])
        tag.frames = [.text("TDRC", "2020-07-08 09:10")]
        #expect(try reparse(tag.render(version: 3)).properties["DATE"] == ["2020-07-08"])  // a space is not ISO 'T'
    }

    @Test func checkTextEncodingUpgradesLatin1() throws {
        let tag = ID3v2Tag(frames: [.text("TIT2", "Ünï", encoding: .latin1), .text("TPE1", "Привет", encoding: .latin1),
                                    .text("TALB", "x", encoding: .utf16BE)])
        let v4 = tag.render(version: 4).byteArray
        #expect(v4[10 + 10] == 0)                      // "Ünï" fits Latin-1
        let tpe1 = 10 + 10 + 4 + 10
        #expect(v4[tpe1] == 3)                         // upgraded to UTF-8 in 2.4
        let v3 = tag.render(version: 3).byteArray
        #expect(v3[tpe1 + 0] == 1)                     // and to UTF-16 in 2.3
        #expect(try reparse(Data(v3)).properties["ALBUM"] == ["x"])  // UTF-16BE becomes UTF-16 in 2.3
        #expect(TagText.checkEncoding(["a"], .utf8, version: 3) == .utf16)
        #expect(TagText.checkEncoding(["a"], .utf16BE, version: 4) == .utf16BE)
        #expect(TagText.checkEncoding(["ÿ"], .latin1, version: 4) == .latin1)
        #expect(TagText.checkEncoding(["Ā"], .latin1, version: 4) == .utf8)
    }

    @Test func framesDiscardedOrUnwritable() throws {
        var tag = ID3v2Tag(frames: [
            ID3v2Frame(id: "TIT2", content: .text(encoding: .latin1, values: ["x"]), discardOnTagAlteration: true),
            ID3v2Frame(id: "TALB", content: .opaque(body: Data([1, 2, 3, 4, 5]), formatFlags: 0x80, version: 3)),
            ID3v2Frame(id: "PRIV", content: .binary(Data())),        // empty body: discarded
            ID3v2Frame(id: "TT2", content: .text(encoding: .latin1, values: ["bad id"])),
            ID3v2Frame(id: "TPE1", content: .text(encoding: .latin1, values: ["kept"])),
        ])
        let v3 = try reparse(tag.render(version: 3))
        #expect(v3.frames.map(\.id) == ["TALB", "TPE1"])
        if case .opaque(let body, let flags, _) = v3.frames[0].content {
            #expect(body == Data([1, 2, 3, 4, 5])); #expect(flags == 0x80)
        } else { Issue.record("opaque kept in 2.3") }
        let v4 = try reparse(tag.render(version: 4))
        #expect(v4.frames.map(\.id) == ["TPE1"])  // compressed 2.3 frame cannot be rewritten as 2.4
        tag.frames = []
        #expect(tag.render().count == 10 + 1024)
    }

    @Test func allFrameKindsRoundTrip() throws {
        let sylt = ID3v2SyncedLyrics(encoding: .utf16, language: "jpn", description: "d",
                                     entries: [.init(text: "あ", time: 10), .init(text: "\nい", time: 20)])
        let frames: [ID3v2Frame] = [
            .text("TIT2", ["A", "B"], encoding: .utf16),
            .userText("X", ["1", "2"], encoding: .utf8),
            ID3v2Frame(id: "WOAR", content: .url("https://a.example")),
            ID3v2Frame(id: "WXXX", content: .userURL(encoding: .latin1, description: "d", url: "https://b.example")),
            .comment("c", description: "desc", language: "eng", encoding: .utf16BE),
            .unsyncedLyrics("l", description: "", language: "fra", encoding: .latin1),
            .syncedLyrics(sylt),
            .picture(TagPicture(data: Data(B.png), mimeType: "image/png", description: "Ω", pictureType: 3), encoding: .utf8),
            ID3v2Frame(id: "UFID", content: .uniqueFileIdentifier(owner: "o", identifier: Data([0, 1, 2]))),
            ID3v2Frame(id: "PRIV", content: .binary(Data([9, 8, 7]))),
        ]
        let back = try reparse(ID3v2Tag(frames: frames).render(version: 4))
        #expect(back.frames == frames)
    }

    @Test func setPropertiesFollowsTagLib() throws {
        var tag = ID3v2Tag(frames: [
            .text("TIT2", "Same", encoding: .latin1),
            .text("TPE1", "Old artist", encoding: .latin1),
            .text("TCON", "Rock", encoding: .latin1),
            .picture(TagPicture(data: Data(B.png), mimeType: "image/png")),
            .syncedLyrics(ID3v2SyncedLyrics(entries: [.init(text: "a", time: 1)])),
            .userText("REPLAYGAIN_TRACK_GAIN", "-1 dB"),
            ID3v2Frame(id: "PRIV", content: .binary(Data([1]))),
        ])
        var p = tag.properties
        p["ARTIST"] = ["New artist"]
        p.remove("GENRE")
        p["LYRICS"] = ["la la"]
        p["COMMENT"] = ["note"]
        p["COMMENT:ITUNNORM"] = ["x"]
        p["MUSICBRAINZ_ALBUMID"] = ["mb"]
        p["CUSTOM KEY"] = ["v1", "v2"]
        p["URL"] = ["https://u.example"]
        p["ARTISTWEBPAGE"] = ["https://a.example"]
        p["MUSICBRAINZ_TRACKID"] = ["tid"]
        p["PRODUCER"] = ["P1", "P2"]
        p["PERFORMER:GUITAR"] = ["G"]
        p["LYRICS:EXTRA"] = ["e1", "e2"]
        tag.setProperties(p)
        // Untouched frames stay first and keep their encoding; frames without properties stay too.
        #expect(tag.frames[0] == .text("TIT2", "Same", encoding: .latin1))
        #expect(tag.frames.contains { $0.id == "APIC" })
        #expect(tag.frames.contains { $0.id == "SYLT" })
        #expect(tag.frames.contains { $0.id == "PRIV" })
        #expect(!tag.frames.contains { $0.id == "TCON" })
        #expect(tag.frame("TPE1") == .text("TPE1", "New artist", encoding: .utf8))
        #expect(tag.frame("USLT") == .unsyncedLyrics("la la", description: "LYRICS", language: "XXX", encoding: .utf8))
        #expect(tag.frame("UFID") == ID3v2Frame(id: "UFID", content: .uniqueFileIdentifier(owner: "http://musicbrainz.org",
                                                                                          identifier: Data("tid".utf8))))
        #expect(tag.frame("WOAR") == ID3v2Frame(id: "WOAR", content: .url("https://a.example")))
        #expect(tag.frame("WXXX") == ID3v2Frame(id: "WXXX", content: .userURL(encoding: .utf8, description: "URL",
                                                                              url: "https://u.example")))
        #expect(tag.userText("MUSICBRAINZ ALBUM ID") == ["mb"])
        #expect(tag.userText("CUSTOM KEY") == ["v1", "v2"])
        #expect(tag.userText("LYRICS:EXTRA") == ["e1", "e2"])  // two values: TXXX instead of USLT
        #expect(tag.frame("TIPL") == .text("TIPL", ["PRODUCER", "P1,P2"], encoding: .latin1))
        #expect(tag.frame("TMCL") == .text("TMCL", ["GUITAR", "G"], encoding: .latin1))
        // New frames come after the kept ones: TIPL, TMCL, then the rest in key order.
        let ids = tag.frames.map(\.id)
        #expect(ids.firstIndex(of: "TIPL")! < ids.firstIndex(of: "TMCL")!)
        #expect(ids.firstIndex(of: "TMCL")! < ids.firstIndex(of: "TPE1")!)
        // Reading back gives the same properties.
        let back = try reparse(tag.render())
        #expect(back.properties == p)
    }

    @Test func setPropertiesRemovesDuplicatesOfAKey() {
        var tag = ID3v2Tag(frames: [.text("TPE1", "A", encoding: .latin1), .text("TPE1", "B", encoding: .latin1)])
        #expect(tag.properties["ARTIST"] == ["A", "B"])
        tag.setProperties(["ARTIST": ["A", "B"]])
        #expect(tag.frames == [.text("TPE1", ["A", "B"], encoding: .utf8)])
    }

    @Test func picturesAndSyncedLyricsSetters() throws {
        var tag = ID3v2Tag(frames: [.picture(TagPicture(data: Data(B.png), mimeType: "image/png")), .text("TIT2", "t")])
        tag.setPictures([TagPicture(data: Data(B.jpeg), mimeType: "image/jpeg", description: "Front Cover")])
        #expect(tag.pictures.map(\.mimeType) == ["image/jpeg"])
        #expect(tag.frames.last?.id == "APIC")
        tag.setPictures([])
        #expect(tag.pictures.isEmpty)
        tag.setSyncedLyrics(ID3v2SyncedLyrics(entries: [.init(text: "x", time: 5)]))
        tag.setSyncedLyrics(ID3v2SyncedLyrics(entries: [.init(text: "y", time: 6)]))
        #expect(tag.syncedLyrics.count == 1)
        tag.setSyncedLyrics(nil)
        #expect(tag.syncedLyrics.isEmpty)
    }

    @Test func syncedLyricsModelConversions() {
        let lineLevel = ID3v2SyncedLyrics(entries: [.init(text: "One", time: 1000), .init(text: "Two", time: 61_230)])
        #expect(lineLevel.syncedLines() == [SyncedLine(time: 1000, line: "One"), SyncedLine(time: 61_230, line: "Two")])
        #expect(lineLevel.lrcText() == "[00:01.00]One\n[01:01.23]Two")

        let wordLevel = ID3v2SyncedLyrics(entries: [
            .init(text: "Hel", time: 100), .init(text: "lo ", time: 300), .init(text: "world", time: 500),
            .init(text: "\nNext", time: 2000), .init(text: " line", time: 2400),
        ])
        let lines = wordLevel.syncedLines()!
        #expect(lines.count == 2)
        #expect(lines[0].line == "Hello world")
        #expect(lines[0].words == [SyncedWord(time: 100, word: "Hel"), SyncedWord(time: 300, word: "lo", startsNewWord: false),
                                   SyncedWord(time: 500, word: "world")])
        #expect(lines[1] == SyncedLine(time: 2000, line: "Next line",
                                       words: [SyncedWord(time: 2000, word: "Next"), SyncedWord(time: 2400, word: "line")]))
        #expect(wordLevel.lrcText() == "[00:00.10]<00:00.10>Hel<00:00.30>lo <00:00.50>world\n[00:02.00]<00:02.00>Next <00:02.40>line")

        // Building from lines and reading back is lossless for line and word timing.
        let source = [SyncedLine(time: 0, line: "a b", words: [SyncedWord(time: 0, word: "a"), SyncedWord(time: 400, word: "b")]),
                      SyncedLine(time: 1500, line: "plain")]
        let built = ID3v2SyncedLyrics(syncedLines: source, language: "eng")
        #expect(built.entries.map(\.text) == ["a", " b", "\nplain"])
        #expect(built.syncedLines() == source)

        var frames = ID3v2SyncedLyrics(entries: [.init(text: "x", time: 10)])
        frames.timestampFormatByte = 1
        #expect(frames.syncedLines() == nil)
        #expect(frames.syncedLines(mpegFrameDurationMs: 26.122)?.first?.time == 261)
        frames.timestampFormatByte = 9
        #expect(frames.lrcText() == nil)
    }

    @Test func mp3FileWriting() throws {
        let audio = B.mp3Frames(3)
        let v1: [UInt8] = [0x54, 0x41, 0x47] + B.latin1("Old") + [UInt8](repeating: 0, count: 27) + [UInt8](repeating: 0, count: 60)
            + B.latin1("1999") + [UInt8](repeating: 0, count: 28) + [0, 5, 17]
        #expect(v1.count == 128)
        let original = B.id3(3, B.frame23("TIT2", B.text(0, B.latin1("Old"))) + B.frame23("TYER", B.text(0, B.latin1("1999")))
                                + [UInt8](repeating: 0, count: 100)) + audio + v1
        let file = Data(original)
        let before = try AudioTagReader.read(file)
        #expect(before.properties["TITLE"] == ["Old"])
        #expect(before.id3v1?.track == 5)

        var props = before.properties
        props["TITLE"] = ["New title"]
        props["ARTIST"] = ["Ärtist"]
        let result = try AudioTagWriter.write(TagChanges(properties: props), to: file)
        let after = try AudioTagReader.read(result.data)
        #expect(after.id3v2?.version == 4)
        #expect(after.properties["TITLE"] == ["New title"])
        #expect(after.properties["DATE"] == ["1999"])
        #expect(after.id3v1?.title == "New title")
        #expect(after.id3v1?.artist == "Ärtist")
        #expect(after.id3v1?.genre == 255)    // GENRE was not in the map: cleared like TagLib's setProperties
        let tagSize = try #require(ID3v2Tag.totalSize(in: result.data))
        #expect(Array(result.data.byteArray[tagSize..<(tagSize + audio.count)]) == audio)
        #expect(result.data.count == tagSize + audio.count + 128)
        #expect(result.patches.count == 2)

        // Keep the 2.3 version when asked.
        let kept = try AudioTagWriter.write(TagChanges(properties: props, id3v2Version: nil), to: file)
        #expect(try AudioTagReader.read(kept.data).id3v2?.version == 3)
        #expect(kept.fitsInPlace)  // the frames fit the original tag; ID3v1 is always 128 bytes

        // Removing every property removes the ID3v2 tag.
        let stripped = try AudioTagWriter.write(TagChanges(properties: TagProperties()), to: file)
        #expect(ID3v2Tag.totalSize(in: stripped.data) == nil)
        #expect(Array(stripped.data.byteArray.prefix(audio.count)) == audio)
    }

    @Test func mp3WithoutTagsGetsAnID3v2Tag() throws {
        let file = Data(B.mp3Frames(2))
        let result = try AudioTagWriter.write(TagChanges(properties: ["TITLE": ["T"]],
                                                         pictures: [TagPicture(data: Data(B.png), mimeType: "image/png")],
                                                         syncedLyrics: .some(ID3v2SyncedLyrics(entries: [.init(text: "s", time: 1)]))),
                                              to: file)
        let tags = try AudioTagReader.read(result.data)
        #expect(tags.container == .mpeg)
        #expect(tags.properties["TITLE"] == ["T"])
        #expect(tags.pictures.count == 1)
        #expect(tags.syncedLyrics.first?.entries.first?.text == "s")
        #expect(tags.id3v1 == nil)  // never added
        #expect(result.data.suffix(file.count) == file)
        // No changes on a tag-less file leave it as it is.
        #expect(try AudioTagWriter.write(TagChanges(), to: file).data == file)
    }

    @Test func unsupportedVersionTagIsReplaced() throws {
        let file = Data(B.latin1("ID3") + [5, 0, 0] + B.syncsafe(20) + [UInt8](repeating: 0x41, count: 20) + B.mp3Frames(1))
        let result = try AudioTagWriter.write(TagChanges(properties: ["TITLE": ["X"]]), to: file)
        let tags = try AudioTagReader.read(result.data)
        #expect(tags.properties["TITLE"] == ["X"])
        #expect(result.data.suffix(417) == Data(B.mp3Frames(1)))
    }
}
