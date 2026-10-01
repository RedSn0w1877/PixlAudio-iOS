import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

/// `PlaybackQueue`: Media3's next/previous rules per repeat mode, anchored shuffle and un-shuffle (Android
/// `toggleShuffle`), and queue edits.
final class PlaybackQueueTests: XCTestCase {
    private func songs(_ n: Int) -> [Song] {
        (0..<n).map { i in
            Song(id: "s\(i)", title: "Song \(i)", artist: "A", artistId: 1, album: "B", albumId: 1, path: "",
                 contentUriString: "", albumArtUriString: nil, duration: 1000, mimeType: nil, bitrate: nil,
                 sampleRate: nil)
        }
    }

    private func ids(_ queue: PlaybackQueue) -> [String] { queue.songs.map(\.id) }

    func testReplaceClampsStartAndKeepsOrder() {
        var queue = PlaybackQueue()
        queue.replace(with: songs(4), startIndex: 9, shuffle: false)
        XCTAssertEqual(ids(queue), ["s0", "s1", "s2", "s3"])
        XCTAssertEqual(queue.currentIndex, 3)
        queue.replace(with: [], startIndex: 0, shuffle: false)
        XCTAssertNil(queue.currentIndex)
        XCTAssertNil(queue.current)
    }

    func testNextAndPreviousFollowMedia3PerRepeatMode() {
        var queue = PlaybackQueue()
        queue.replace(with: songs(3), startIndex: 2, shuffle: false)
        queue.repeatMode = .off
        XCTAssertNil(queue.nextIndexForAutoAdvance)
        XCTAssertNil(queue.nextIndexForSkip)
        XCTAssertNil(queue.crossfadeTargetIndex)
        queue.repeatMode = .all
        XCTAssertEqual(queue.nextIndexForAutoAdvance, 0)
        XCTAssertEqual(queue.nextIndexForSkip, 0)
        XCTAssertNil(queue.crossfadeTargetIndex, "crossfades never wrap (Android getNextTransitionTarget)")
        queue.repeatMode = .one
        XCTAssertEqual(queue.nextIndexForAutoAdvance, 2)
        XCTAssertNil(queue.nextIndexForSkip, "skip ignores repeat-one")
        XCTAssertEqual(queue.crossfadeTargetIndex, 2)

        queue.setCurrentIndex(0)
        queue.repeatMode = .off
        XCTAssertNil(queue.previousIndex)
        queue.repeatMode = .all
        XCTAssertEqual(queue.previousIndex, 2)
        queue.setCurrentIndex(1)
        XCTAssertEqual(queue.previousIndex, 0)
        XCTAssertEqual(queue.nextIndexForAutoAdvance, 2)
        XCTAssertEqual(PlaybackQueue.restartThresholdMs, 3000)
    }

    func testShuffleAnchorsTheCurrentSongAndUnshuffleRestoresTheOrder() {
        var queue = PlaybackQueue()
        queue.replace(with: songs(20), startIndex: 7, shuffle: false)
        var random = KotlinRandom(seed: Int64(42))
        queue.setShuffle(true, random: &random)
        XCTAssertTrue(queue.isShuffled)
        XCTAssertEqual(queue.currentIndex, 7)
        XCTAssertEqual(queue.current?.song.id, "s7")
        XCTAssertNotEqual(ids(queue), songs(20).map(\.id))
        XCTAssertEqual(Set(ids(queue)), Set(songs(20).map(\.id)))

        // Same order as PixlLibrary's anchored shuffle with the same seed (Android-exact).
        var expectedRandom = KotlinRandom(seed: Int64(42))
        let expected = QueueUtils.buildAnchoredShuffleQueue(songs(20).map(\.id), anchorIndex: 7, random: &expectedRandom)
        XCTAssertEqual(ids(queue), expected)

        queue.setCurrentIndex(3)
        let playing = queue.current?.song.id
        queue.setShuffle(false, random: &random)
        XCTAssertFalse(queue.isShuffled)
        XCTAssertEqual(ids(queue), songs(20).map(\.id))
        XCTAssertEqual(queue.current?.song.id, playing, "the playing song stays current")
    }

    func testShuffledReplaceStartsAtTheChosenSong() {
        var queue = PlaybackQueue()
        var random = KotlinRandom(seed: Int64(3))
        queue.replace(with: songs(10), startIndex: 4, shuffle: true, random: &random)
        XCTAssertEqual(queue.current?.song.id, "s4")
        XCTAssertTrue(queue.isShuffled)
        queue.setShuffle(false)
        XCTAssertEqual(ids(queue), songs(10).map(\.id))
        XCTAssertEqual(queue.currentIndex, 4)
    }

    func testEditsKeepTheCurrentEntry() {
        var queue = PlaybackQueue()
        queue.replace(with: songs(5), startIndex: 2, shuffle: false)
        let current = queue.current?.id

        queue.playNext(songs(2).map { s in var c = s; c.id = "n" + s.id; return c })
        XCTAssertEqual(ids(queue), ["s0", "s1", "s2", "ns0", "ns1", "s3", "s4"])
        XCTAssertEqual(queue.current?.id, current)

        queue.append([songs(1)[0]])
        XCTAssertEqual(ids(queue).last, "s0")
        XCTAssertEqual(queue.count, 8)
        XCTAssertNotEqual(queue.entries[0].id, queue.entries[7].id, "duplicates get distinct entries")

        queue.move(from: 0, to: 6)
        XCTAssertEqual(queue.current?.id, current)
        XCTAssertEqual(queue.currentIndex, 1)

        XCTAssertFalse(queue.remove(at: 0))
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(queue.current?.id, current)

        XCTAssertTrue(queue.remove(at: 0), "removing the current entry moves to the next one")
        XCTAssertEqual(queue.current?.song.id, "ns0")

        queue.clearUpcoming()
        XCTAssertEqual(ids(queue), ["ns0"])
        XCTAssertTrue(queue.remove(at: 0))
        XCTAssertNil(queue.currentIndex)
        XCTAssertTrue(queue.isEmpty)
    }

    func testEditsWhileShuffledSurviveUnshuffle() {
        var queue = PlaybackQueue()
        var random = KotlinRandom(seed: Int64(9))
        queue.replace(with: songs(6), startIndex: 0, shuffle: true, random: &random)
        queue.append([Song(id: "extra", title: "", artist: "", artistId: 0, album: "", albumId: 0, path: "",
                           contentUriString: "", albumArtUriString: nil, duration: 0, mimeType: nil, bitrate: nil,
                           sampleRate: nil)])
        let removedId = queue.entries[3].song.id
        queue.remove(at: 3)
        queue.setShuffle(false, random: &random)
        XCTAssertEqual(ids(queue), songs(6).map(\.id).filter { $0 != removedId } + ["extra"])
    }

    func testRestoreKeepsTheSavedOrder() {
        var queue = PlaybackQueue()
        queue.restore(songs: Array(songs(3).reversed()), currentIndex: 5, originalSongs: nil)
        XCTAssertEqual(ids(queue), ["s2", "s1", "s0"])
        XCTAssertEqual(queue.currentIndex, 2)
    }
}
