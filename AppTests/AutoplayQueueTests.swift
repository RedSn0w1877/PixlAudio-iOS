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

    // MARK: Stage 1b: the tail edit, the play source, the brain's play

    func testATailReplacementTouchesOnlyTheEnginesOwnRunAfterTheCurrentSong() {
        var queue = PlaybackQueue()
        queue.replace(with: [song("u0"), song("u1")], startIndex: 0, shuffle: false)
        queue.appendEngine([song("e0"), song("e1"), song("e2")], tags: [tag(0), tag(1), tag(2)])
        // From the second engine entry on, in one edit.
        XCTAssertTrue(queue.replaceTail(from: 3, songs: [song("n0"), song("n1")], tags: [tag(1), tag(2)]))
        XCTAssertEqual(ids(queue), ["u0", "u1", "e0", "n0", "n1"])
        XCTAssertEqual(queue.entries.map(\.isEngineOwned), [false, false, true, true, true])
        XCTAssertEqual(queue.currentIndex, 0)
        // Never a track the listener queued, never the current song, never with mismatched tags or past the end.
        XCTAssertFalse(queue.replaceTail(from: 1, songs: [song("x")], tags: [tag(0)]))
        XCTAssertFalse(queue.replaceTail(from: 0, songs: [song("x")], tags: [tag(0)]))
        XCTAssertFalse(queue.replaceTail(from: 3, songs: [song("x")], tags: []))
        XCTAssertFalse(queue.replaceTail(from: 9, songs: [song("x")], tags: [tag(0)]))
        XCTAssertEqual(ids(queue), ["u0", "u1", "e0", "n0", "n1"])
    }

    func testWhereAQueueWasStartedFromIsOnItsEntries() {
        var queue = PlaybackQueue()
        queue.replace(with: [song("u0"), song("u1")], startIndex: 0, shuffle: false, source: .album)
        XCTAssertEqual(queue.entries.map { $0.brain?.surface }, ["album", "album"])
        XCTAssertEqual(queue.entries.map(\.isEngineOwned), [false, false])
        queue.append([song("u2")])
        queue.playNext([song("u3")])
        XCTAssertEqual(queue.entries.map { $0.brain?.surface }, ["album", "manualQueue", "album", "manualQueue"])
        XCTAssertNil(queue.firstUpcomingEngineIndex)
        let playlist = BrainItemTag.playlist(id: "abc")
        XCTAssertEqual(playlist.surface, "playlist")
        XCTAssertNotEqual(playlist.surfaceId, "abc")
    }

    func testEveryPlayReachesTheBrainWithNoFiveSecondFloor() {
        let tracker = ListeningStatsTracker()
        var clock: Int64 = 1_000
        tracker.realtimeMs = { clock }
        tracker.epochMs = { 1_700_000_000_000 + clock }
        tracker.tzOffsetMin = { 60 }
        var plays: [FinishedPlay] = []
        var records: [ListeningStatsTracker.Record] = []
        tracker.onBrainPlay = { plays.append($0) }
        tracker.onRecord = { records.append($0) }
        let first = PlayContext(title: "Song a", artistDisplay: "A", startReason: StartReason.tap)
        tracker.onTrackChanged(songId: "a", positionMs: 0, durationMs: 200_000, isPlaying: true, context: first)
        clock += 2_000
        let second = PlayContext(title: "Song b", artistDisplay: "A", startReason: StartReason.next)
        tracker.onTrackChanged(songId: "b", positionMs: 0, durationMs: 200_000, isPlaying: true, context: second,
                               endReason: EndReason.next, isOutsideLibrary: true)
        // A two-second skip is a play for the brain and nothing for the legacy stores.
        XCTAssertEqual(plays.count, 1)
        XCTAssertEqual(plays.first?.songId, "a")
        XCTAssertEqual(plays.first?.playedMs, 2_000)
        XCTAssertEqual(plays.first?.endReason, EndReason.next)
        XCTAssertEqual(plays.first?.tzOffsetMin, 60)
        XCTAssertTrue(records.isEmpty)
        tracker.markFlag(songId: "b", flag: EventFlags.likedDuring)
        clock += 60_000
        tracker.finalizeCurrentSession(endReason: EndReason.trackDone)
        XCTAssertEqual(plays.count, 2)
        XCTAssertEqual(plays.last?.flags, EventFlags.likedDuring)
        XCTAssertEqual(plays.last?.context.startReason, StartReason.next)
        // The legacy record is still made (the play history shows the track), marked as from outside the library.
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.isOutsideLibrary, true)
    }
}
