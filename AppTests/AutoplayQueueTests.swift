import PixlLibrary
import PixlModel
import XCTest
@testable import PixlAudio

/// The queue's side of Autoplay (docs/brain-spec.md, 7.1 "Ownership", 4.2): engine entries are appended last and
/// carry their tag, what the listener queues goes above them, and the tags survive a save and a restore.
@MainActor
final class AutoplayQueueTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(id: id, title: "Song \(id)", artist: "A", artistId: 1, album: "B", albumId: 1, path: "",
             contentUriString: "pixlstream://\(id)", albumArtUriString: nil, duration: 200_000, mimeType: nil,
             bitrate: nil, sampleRate: nil)
    }

    private func tag(_ slot: Int) -> BrainItemTag {
        BrainItemTag(surface: Surface.nameOf(Surface.autoplay), surfaceId: "u0", recId: 77, slot: slot,
                     arm: Arm.nameOf(Arm.radio))
    }

    private func ids(_ queue: PlaybackQueue) -> [String] { queue.songs.map(\.id) }

    func testEngineEntriesGoLastAndWhatTheListenerQueuesGoesAboveThem() {
        var queue = PlaybackQueue()
        queue.replace(with: [song("u0"), song("u1")], startIndex: 0, shuffle: false)
        XCTAssertNil(queue.firstUpcomingEngineIndex)
        queue.appendEngine([song("e0"), song("e1")], tags: [tag(0), tag(1)])
        XCTAssertEqual(ids(queue), ["u0", "u1", "e0", "e1"])
        XCTAssertEqual(queue.entries.map(\.isEngineOwned), [false, false, true, true])
        XCTAssertEqual(queue.firstUpcomingEngineIndex, 2)
        XCTAssertEqual(queue.entries[3].brain?.slot, 1)

        // "Add to queue" lands above the Autoplay line; "Play next" right after the current song.
        queue.append([song("u2")])
        XCTAssertEqual(ids(queue), ["u0", "u1", "u2", "e0", "e1"])
        queue.playNext([song("u3")])
        XCTAssertEqual(ids(queue), ["u0", "u3", "u1", "u2", "e0", "e1"])
        XCTAssertEqual(queue.firstUpcomingEngineIndex, 4)
        XCTAssertFalse(queue.entries[2].isEngineOwned)

        // Once an engine entry is the current one, the line is at the next engine entry.
        queue.setCurrentIndex(4)
        XCTAssertEqual(queue.firstUpcomingEngineIndex, 5)
        queue.setCurrentIndex(5)
        XCTAssertNil(queue.firstUpcomingEngineIndex)
        // With nothing of the engine's left to come, the listener's songs are appended at the end again.
        queue.append([song("u4")])
        XCTAssertEqual(ids(queue).last, "u4")
    }

    func testAnEmptyAppendChangesNothing() {
        var queue = PlaybackQueue()
        queue.replace(with: [song("u0")], startIndex: 0, shuffle: false)
        queue.appendEngine([], tags: [])
        XCTAssertEqual(ids(queue), ["u0"])
    }

    func testEngineEntriesComeBackAsEngineEntriesAfterASaveAndARestore() throws {
        var queue = PlaybackQueue()
        queue.replace(with: [song("u0")], startIndex: 0, shuffle: false)
        queue.appendEngine([song("e0"), song("e1")], tags: [tag(0), tag(1)])
        let capture = QueueSnapshotCapture(queue: queue, positionMs: 1_000, playWhenReady: true, shuffleEnabled: false,
                                           nowMs: 5)
        let saved = try XCTUnwrap(capture.makeSnapshot())
        XCTAssertNil(saved.items[0].brainArm)
        XCTAssertEqual(saved.items[1].brainArm, "RADIO")
        XCTAssertEqual(saved.items[2].brainSlot, 1)
        XCTAssertEqual(saved.items[1].brainSurface, "autoplay")

        let text = try XCTUnwrap(QueueSnapshotCoding.encodeNow(saved))
        let loaded = try XCTUnwrap(QueueSnapshotCoding.decodeNow(text))
        XCTAssertEqual(loaded, saved)
        // The songs are not in any library: they are rebuilt from the snapshot's own fields.
        let songs = QueueSnapshotStore.songs(for: loaded, lookup: { _ in nil })
        XCTAssertEqual(songs.map(\.id), ["u0", "e0", "e1"])
        XCTAssertEqual(songs[1].contentUriString, "pixlstream://e0")

        var restored = PlaybackQueue()
        restored.restore(songs: songs, currentIndex: 0, originalSongs: nil, tags: loaded.items.map { $0.brainTag() })
        XCTAssertEqual(restored.entries.map(\.isEngineOwned), [false, true, true])
        XCTAssertEqual(restored.firstUpcomingEngineIndex, 1)
        XCTAssertEqual(restored.entries[2].brain?.recId, 77)

        // A queue saved before the brain existed has no tags, and restores as before.
        var plain = PlaybackQueue()
        plain.restore(songs: songs, currentIndex: 0, originalSongs: nil)
        XCTAssertEqual(plain.entries.map(\.isEngineOwned), [false, false, false])
    }

    func testAnEngineTrackIsTheSongTheYouTubeImporterMakes() {
        let track = EngineTrack(row: RadioRow(videoId: "J7p4bzqLvCw", title: "Blinding Lights",
                                              artists: [RadioArtistRef(name: "The Weeknd", channelId: "UCw")],
                                              album: "After Hours", durationSec: 202, kind: .atv), rid: 9)
        let queued = BrainService.queueSong(for: track, nowMs: 10)
        let imported = YouTubeSongFactory.song(
            YouTubeMusicTrack(videoId: track.videoId, title: track.title, artist: track.artistDisplay, album: track.album,
                              thumbnailUrl: track.artUrl, durationMs: track.durationMs), now: 10)
        // The id and the URL the track plays under are the importer's, so saving it never changes what the queue,
        // the history and the library call it.
        XCTAssertEqual(queued.id, imported.id)
        XCTAssertEqual(queued.contentUriString, imported.contentUriString)
        XCTAssertEqual(queued.artistId, imported.artistId)
        XCTAssertEqual(queued.albumId, imported.albumId)
        XCTAssertEqual(YouTubeSongIdentity.videoId(for: queued), "J7p4bzqLvCw")
        XCTAssertTrue(AutoplayController.isSyntheticId("0123456789abcdef012345"))
        XCTAssertFalse(AutoplayController.isSyntheticId("4uLU6hMCjMI75M1A2tKUQC"))
    }
}
