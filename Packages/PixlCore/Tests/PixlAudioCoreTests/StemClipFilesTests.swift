import Foundation
import Testing
@testable import PixlAudioCore

/// Sing's preview pieces on disk: their names never pass for a song's instrumental, so no "has an instrumental" check
/// counts one.
@Suite struct StemClipFilesTests {
    @Test func aClipIsNamedAfterItsSongAndStart() {
        #expect(StemFiles.clipFileName(songId: "sp:abc", startMs: 87_000, flac: false) == "sp_3a_abc_clip_87000.m4a")
        #expect(StemFiles.clipFileName(songId: "sp:abc", startMs: 87_000, flac: true) == "sp_3a_abc_clip_87000.flac")
        #expect(StemFiles.clipFileName(songId: "a", startMs: -3, flac: false) == "a_clip_0.m4a")
        #expect(StemFiles.clipFileName(songId: "sp:abc", startMs: 87_000, flac: false)
            .hasPrefix(StemFiles.clipPrefix(songId: "sp:abc")))
    }

    @Test func aClipIsNeverTakenForTheSongsInstrumental() {
        for id in ["sp:abc", "f:root/a.m4a", "plain"] {
            let names = [StemFiles.clipFileName(songId: id, startMs: 0, flac: false),
                         StemFiles.clipFileName(songId: id, startMs: 197_000, flac: true)]
            for name in names {
                #expect(StemFiles.songId(fileName: name) == nil, "\(name)")
                #expect(!StemFiles.candidates(songId: id).contains(name), "\(name)")
            }
        }
    }

    @Test func oneSongsClipsAreNotAnothersEvenWithASimilarId() {
        // `_` in an id is escaped, so "a_clip" can't collide with song "a"'s clips.
        #expect(!StemFiles.clipFileName(songId: "a_clip", startMs: 0, flac: false).hasPrefix(StemFiles.clipPrefix(songId: "a")))
    }
}
