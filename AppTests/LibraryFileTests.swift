import Foundation
import PixlModel
import PixlTags
import XCTest
@testable import PixlAudio

/// What is left of stage 6's file tests now that the app is Spotify-only: the tag-region reader (still used for a
/// downloaded song's embedded lyrics and ISRC), the song-id helpers, the tag override record and the kinds of file
/// the app accepts when one is opened from Files or the share sheet.
final class LibraryFileTests: XCTestCase {
    private var workDirectory: URL!

    override func setUp() async throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// A 64-bit box size of 0xFFFF… must stop the walk instead of overflowing the offset.
    func testForgedSixtyFourBitBoxSizeStopsTheMP4Walk() throws {
        var bytes: [UInt8] = [0, 0, 0, 16] + Array("ftyp".utf8) + Array("M4A ".utf8) + [0, 0, 0, 0]
        bytes += [0, 0, 0, 1] + Array("free".utf8) + [UInt8](repeating: 0xFF, count: 8)
        bytes += [UInt8](repeating: 0, count: 32)
        let url = workDirectory.appendingPathComponent("forged.m4a")
        try Data(bytes).write(to: url)
        XCTAssertNil(TagRegionReader.read(url: url))
    }

    /// Files opened in PixlAudio from Files or the share sheet go where their type belongs; audio is not one of them
    /// any more — songs come from Spotify.
    func testOpenedFilesAreSortedByKind() {
        func kind(_ name: String) -> ExternalFiles.Kind { ExternalFiles.kind(of: URL(fileURLWithPath: "/x/" + name)) }
        XCTAssertEqual(kind("PixlAudio.pxpl"), .backup)
        XCTAssertEqual(kind("pixelplay_backup.json.gz"), .backup)
        XCTAssertEqual(kind("Road Trip.M3U8"), .playlist)
        XCTAssertEqual(kind("Road Trip.m3u"), .playlist)
        XCTAssertEqual(kind("Song.lrc"), .lyrics)
        XCTAssertEqual(kind("Song.ttml"), .lyrics)
        XCTAssertEqual(kind("Song.flac"), .unsupported)
        XCTAssertEqual(kind("notes.txt"), .unsupported)
    }

    func testIdentityHelpers() {
        XCTAssertEqual(LibraryIdentity.parentDirectory(ofLibraryPath: "/Music/A/b.mp3"), "/Music/A")
        XCTAssertEqual(LibraryIdentity.parentDirectory(ofLibraryPath: "b.mp3"), "")
        XCTAssertTrue(LibraryIdentity.isManaged("f:abc/A/b.mp3"))
        XCTAssertTrue(LibraryIdentity.isManaged("mp:42"))
        XCTAssertFalse(LibraryIdentity.isManaged("yt:abc"))
    }

    func testTagOverrideRoundTripsAsJSON() throws {
        let fields = TagOverrideFields(title: "T", artist: "A", trackNumber: 3)
        XCTAssertEqual(TagOverrideFields.decode(try fields.encoded()), fields)
        XCTAssertTrue(TagOverrideFields().isEmpty)
    }
}
