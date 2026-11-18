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

    // MARK: Stage 1c: stations, a Home row's cards, taste changes

    func testAStationIsTheQueueThatHoldsItsTaggedSeed() throws {
        let station = Station.song(seedMediaId: "u1", title: "Song u1", primaryArtist: "A", nowMs: 1)
        func holdsSeed(_ queue: PlaybackQueue) -> Bool {
            queue.entries.contains { station.isSeed(mediaId: $0.song.id, tag: $0.brain) }
        }
        // Started from another song: a one-song queue tagged as the station's.
        var fresh = PlaybackQueue()
        fresh.replace(with: [song("u1")], startIndex: 0, shuffle: false, source: station.seedTag)
        XCTAssertTrue(holdsSeed(fresh))
        XCTAssertFalse(fresh.entries[0].isEngineOwned)

        // Started from the song that is playing: it keeps its place and becomes the seed.
        var queue = PlaybackQueue()
        queue.replace(with: [song("u0"), song("u1"), song("u2")], startIndex: 1, shuffle: false, source: .album)
        XCTAssertFalse(holdsSeed(queue))
        XCTAssertTrue(queue.retagCurrent(station.seedTag))
        queue.clearUpcoming()
        XCTAssertEqual(ids(queue), ["u0", "u1"])
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertTrue(holdsSeed(queue))
        XCTAssertEqual(queue.entries[0].brain?.surface, "album")

        // A saved and restored queue is still the station's.
        let capture = QueueSnapshotCapture(queue: queue, positionMs: 0, playWhenReady: false, shuffleEnabled: false, nowMs: 5)
        let saved = try XCTUnwrap(capture.makeSnapshot())
        var restored = PlaybackQueue()
        restored.restore(songs: QueueSnapshotStore.songs(for: saved, lookup: { _ in nil }), currentIndex: 1,
                         originalSongs: nil, tags: saved.items.map { $0.brainTag() })
        XCTAssertTrue(holdsSeed(restored))

        // Any other play replaces the entries, and with them the seed: the station is over.
        queue.replace(with: [song("u1"), song("u5")], startIndex: 0, shuffle: false, source: .album)
        XCTAssertFalse(holdsSeed(queue))
        var empty = PlaybackQueue()
        XCTAssertFalse(empty.retagCurrent(station.seedTag))
    }

    func testAHomeRowsCardsCarryTheirOwnPickAndStayTheListeners() {
        let card = BrainItemTag(surface: "homeShelf", surfaceId: "because_1f", recId: 5, slot: 1, arm: "RADIO",
                                whyArg: "Espresso", whyKey: "because_listened", chosen: true)
        var queue = PlaybackQueue()
        queue.replace(with: [song("c0"), song("c1")], startIndex: 0, shuffle: false, source: .homeShelf,
                      tagsBySongId: ["c1": card])
        XCTAssertEqual(queue.entries[0].brain?.surface, "homeShelf")
        XCTAssertNil(queue.entries[0].brain?.arm)
        XCTAssertEqual(queue.entries[1].brain, card)
        // A card has an arm (it was a recommendation) and is still the listener's item: no Autoplay line above it.
        XCTAssertEqual(queue.entries.map(\.isEngineOwned), [false, false])
        XCTAssertNil(queue.firstUpcomingEngineIndex)
        XCTAssertEqual(QueueWhy.map(queue.entries.map { (mediaId: $0.song.id, tag: $0.brain) }),
                       ["c1": QueueWhy(key: "because_listened", arg: "Espresso")])
    }

    func testATasteChangeTakesTheEnginesMatchingPicksOutInOneEdit() {
        var queue = PlaybackQueue()
        queue.replace(with: [song("u0"), song("u1")], startIndex: 0, shuffle: false)
        queue.appendEngine([song("e0"), song("e1"), song("e2")], tags: [tag(0), tag(1), tag(2)])
        XCTAssertTrue(queue.removeUpcomingEngine(ids: ["e0", "e2", "u1", "nope"]))
        // The listener's own song with the same id stays; so does everything else.
        XCTAssertEqual(ids(queue), ["u0", "u1", "e1"])
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertFalse(queue.removeUpcomingEngine(ids: ["u0", "u1"]))
        XCTAssertFalse(queue.removeUpcomingEngine(ids: []))
        // The pick that is playing is never taken away.
        queue.setCurrentIndex(2)
        XCTAssertFalse(queue.removeUpcomingEngine(ids: ["e1"]))
        XCTAssertEqual(ids(queue), ["u0", "u1", "e1"])
    }

    func testTheStationAndTheNoveltySwitchAreRememberedAcrossAStart() throws {
        let suite = "pixlaudio.tests.station.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StationStore(defaults: defaults)
        XCTAssertNil(store.current)
        XCTAssertEqual(store.novelty, Novelty.blend)
        let station = Station.artist(seedMediaId: "u1", artistName: "A", nowMs: 9)
        store.start(station)
        XCTAssertTrue(store.setNovelty(Novelty.discover))
        XCTAssertFalse(store.setNovelty(Novelty.discover))
        let reopened = StationStore(defaults: defaults)
        XCTAssertEqual(reopened.current, station)
        XCTAssertEqual(reopened.novelty, Novelty.discover)
        reopened.clear()
        XCTAssertNil(StationStore(defaults: defaults).current)
        // Nothing stored: everything stays in memory (UI tests).
        let memory = StationStore(defaults: nil)
        memory.start(station)
        XCTAssertEqual(memory.current, station)
    }

    func testTheWordsOfAReasonLine() {
        XCTAssertEqual(BrainStrings.whyLine(.radioFans("d4vd")), "Fans of d4vd also play this")
        XCTAssertEqual(BrainStrings.whyLine(.becauseLiked("Woman")), "Because you liked Woman")
        XCTAssertEqual(BrainStrings.whyLine(.becauseListened("Espresso")), "Because you listened to Espresso")
        XCTAssertEqual(BrainStrings.whyLine(.artistMore("Chappell Roan")), "More from Chappell Roan")
        XCTAssertEqual(BrainStrings.stationTitle("Espresso"), "Station \u{B7} Espresso")
        XCTAssertEqual(BrainStrings.novelty(Novelty.familiar), "Familiar")
        XCTAssertEqual(BrainStrings.novelty(Novelty.discover), "Discover")
        let notice = BrainNotice(serial: 1, kind: .lessFrom, adjustmentId: "x", artistName: "Doja Cat")
        XCTAssertEqual(BrainStrings.notice(notice), "You'll hear less from Doja Cat.")
    }
}
