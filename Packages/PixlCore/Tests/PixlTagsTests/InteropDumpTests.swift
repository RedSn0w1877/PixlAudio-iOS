import Foundation
import PixlModel
import Testing
@testable import PixlTags

/// Dev tool: writes files produced by the PixlTags writers to `$PIXLTAGS_DUMP_DIR` so independent readers (ffprobe,
/// JAudioTagger) can check them. Skipped unless the variable is set; see `docs/test-parity/s03d-tags.md`.
@Suite("Interop dump")
struct InteropDumpTests {
    static let dir = ProcessInfo.processInfo.environment["PIXLTAGS_DUMP_DIR"]

    @Test(.enabled(if: dir != nil)) func dumpWrittenFiles() throws {
        let out = URL(fileURLWithPath: Self.dir!, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let mp3 = try Fixture.data("ffmpeg-id3v23.mp3")
        let lines = [SyncedLine(time: 500, line: "Hello there", words: [SyncedWord(time: 500, word: "Hello"), SyncedWord(time: 900, word: "there")]),
                     SyncedLine(time: 2000, line: "日本語の歌詞")]
        for version: UInt8 in [3, 4] {
            var props = try AudioTagReader.read(mp3).properties
            props["TITLE"] = ["Written by PixlTags v2.\(version) ✓ 日本"]
            props["LYRICS"] = ["Plain lyrics\nsecond line"]
            props["REPLAYGAIN_TRACK_GAIN"] = ["-3.21 dB"]
            props["COMMENT"] = ["A comment"]
            props["DATE"] = ["2020-07-08"]
            let changes = TagChanges(properties: props,
                                     pictures: [TagPicture(data: Data(B.jpeg), mimeType: "image/jpeg", description: "Front Cover")],
                                     syncedLyrics: .some(ID3v2SyncedLyrics(syncedLines: lines, language: "eng")),
                                     id3v2Version: version)
            let result = try AudioTagWriter.write(changes, to: mp3)
            try result.data.write(to: out.appendingPathComponent("pixltags-id3v2\(version).mp3"))
        }
        let flac = try Fixture.data("ffmpeg.flac")
        var p = try AudioTagReader.read(flac).properties
        p["TITLE"] = ["Written by PixlTags FLAC ✓"]
        p["REPLAYGAIN_TRACK_GAIN"] = ["-3.21 dB"]
        p["LYRICS"] = ["FLAC lyrics"]
        let flacResult = try AudioTagWriter.write(TagChanges(properties: p, pictures: [TagPicture(data: Data(B.jpeg), mimeType: "image/jpeg",
                                                                                                    description: "Front Cover")]), to: flac)
        try flacResult.data.write(to: out.appendingPathComponent("pixltags.flac"))
    }
}
