import AVFoundation
import Darwin
import PixlAudioCore
import PixlModel
import Synchronization
import XCTest
@testable import PixlAudio

/// The real engine on the simulator with generated files: gapless join, crossfade (both gain curves measured through
/// the taps' meter logs), repeat-one loop, skips, interruptions, ReplayGain from tags, queue events and the snapshot.
@MainActor
final class DualDeckEngineTests: XCTestCase {
    /// A fresh engine with tap logging. Each test stops its engines with `defer`.
    private func makeEngine() -> DualDeckEngine {
        let engine = DualDeckEngine(session: AudioSessionController())
        engine.factory.tapLogCapacity = 8192
        return engine
    }

    /// Waits for the current item's tap to process audio; skips when the simulator renders nothing (no audio device).
    private func waitForAudio(_ engine: DualDeckEngine, timeout: TimeInterval = 8) async throws {
        let rendering = await waitUntil(timeout: timeout) {
            engine.activeItem?.tap.hasProcessed.load(ordering: .relaxed) == true
                && (engine.activeItem?.positionSeconds ?? 0) > 0.05
        }
        if !rendering {
            throw XCTSkip("The simulator rendered no audio (no output device?) — playback tests need a running clock")
        }
    }

    private func seconds(_ hostTicks: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(hostTicks) * Double(info.numer) / Double(info.denom) / 1e9
    }

    // MARK: Gapless

    func testGaplessJoinPreInsertsTheNextItemAndAdvancesWithoutAGap() async throws {
        let a = try TestAudio.sine(frequency: 440, seconds: 1.5)
        let b = try TestAudio.sine(frequency: 660, seconds: 1.5)
        let songA = TestAudio.song(a, id: "f:a", seconds: 1.5), songB = TestAudio.song(b, id: "f:b", seconds: 1.5)
        let engine = makeEngine()
        defer { engine.stop() }
        var transitions: [(new: String?, previous: String?, automatic: Bool)] = []
        engine.onItemTransition = { transitions.append((new: $0?.id, previous: $1?.id, automatic: $2)) }

        engine.setQueue([songA, songB], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let first = try XCTUnwrap(engine.activeItem)
        XCTAssertNotNil(engine.plannedHandOver, "NONE mode plans a gapless hand-over")
        XCTAssertNil(engine.plannedCrossfade)
        let prepared = await waitUntil(timeout: 3) { engine.preparedIncoming != nil }
        XCTAssertTrue(prepared, "the next item is prepared on the idle deck")
        let second = try XCTUnwrap(engine.preparedIncoming)
        XCTAssertEqual(second.entry.song.id, "f:b")
        XCTAssertTrue(engine.idle.items.first === second)
        XCTAssertTrue(engine.active.upcoming.isEmpty, "no pre-insert on the active deck")

        // Sample (host time, item, timebase position) through the join. The timebase follows the audio clock, so
        // extrapolating A's end and B's start from these pairs measures the gap the listener hears.
        var samples: [(host: Double, item: DeckItem?, position: Double)] = []
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            let item = engine.activeItem
            samples.append((host: seconds(mach_absolute_time()), item: item, position: item?.positionSeconds ?? 0))
            if item === second, (item?.positionSeconds ?? 0) > 0.6 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let advanced = engine.queue.currentIndex == 1 && engine.activeItem === second
        XCTAssertTrue(advanced)
        let rendered = await waitUntil(timeout: 3) { second.tap.processedFrames.load(ordering: .relaxed) > 4_410 }
        XCTAssertTrue(rendered)
        XCTAssertEqual(transitions.last?.new, "f:b")
        XCTAssertEqual(transitions.last?.previous, "f:a")
        XCTAssertEqual(transitions.last?.automatic, true)
        let cleared = await waitUntil(timeout: 2) { engine.idle.items.isEmpty && !engine.isTransitionRunning }
        XCTAssertTrue(cleared, "the outgoing deck is emptied after its last frame")

        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            return values.sorted()[values.count / 2]
        }
        let aEnd = try XCTUnwrap(median(samples.filter { $0.item === first && $0.position > 0.2 && $0.position < 1.4 }
            .map { $0.host + (1.5 - $0.position) }), "no samples while A played")
        let bStart = try XCTUnwrap(median(samples.filter { $0.item === second && $0.position > 0.1 && $0.position < 0.6 }
            .map { $0.host - $0.position }), "no samples while B played")
        XCTAssertEqual(bStart - aEnd, 0, accuracy: 0.06, "gap between the songs on the player clock: \(bStart - aEnd) s")

        // The first item was rendered to its end…
        let rate = first.tap.sampleRate.load()
        XCTAssertGreaterThan(rate, 0)
        XCTAssertEqual(first.tap.processedMediaTime.load(), 1.5, accuracy: 0.05)
        // …and the second item's tap started at its first frame.
        let firstLog = try XCTUnwrap(first.tap.log?.snapshot())
        let secondLog = try XCTUnwrap(second.tap.log?.snapshot())
        let lastOfFirst = try XCTUnwrap(firstLog.last), firstOfSecond = try XCTUnwrap(secondLog.first)
        XCTAssertEqual(lastOfFirst.mediaTime + Double(lastOfFirst.frames) / rate, 1.5, accuracy: 0.05)
        XCTAssertEqual(firstOfSecond.mediaTime, 0, accuracy: 0.01)
        // Tap pulls run ahead of the output (the player drains A's queue with silent buffers), so the host-time
        // distance between the last real pull of A and the first pull of B is informational only.
        let pullGap = seconds(firstOfSecond.hostTime &- lastOfFirst.hostTime) - Double(lastOfFirst.frames) / rate
        print("gapless: player-clock gap \(bStart - aEnd) s, tap pull gap \(pullGap) s")
    }

    // MARK: Crossfade

    func testCrossfadeOverlapsBothDecksWithTheirGainCurves() async throws {
        let a = try TestAudio.sine(frequency: 440, seconds: 3.5)
        let b = try TestAudio.sine(frequency: 880, seconds: 3.5)
        let engine = makeEngine()
        defer { engine.stop() }
        engine.crossfadeEnabled = true
        engine.globalTransition = TransitionSettings(mode: .overlap, durationMs: 1000, curveIn: .linear,
                                                     curveOut: .linear)
        engine.setQueue([TestAudio.song(a, id: "f:a", seconds: 3.5), TestAudio.song(b, id: "f:b", seconds: 3.5)],
                        startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let outgoing = try XCTUnwrap(engine.activeItem)
        XCTAssertNotNil(engine.plannedCrossfade, "a crossfade is planned instead of a gapless hand-over")
        XCTAssertTrue(engine.active.upcoming.isEmpty)

        let fired = await waitUntil(timeout: 8) { engine.queue.currentIndex == 1 }
        XCTAssertTrue(fired)
        let incoming = try XCTUnwrap(engine.activeItem)
        XCTAssertFalse(incoming === outgoing)
        XCTAssertTrue(engine.isTransitionRunning, "both decks overlap")
        let finished = await waitUntil(timeout: 4) { !engine.isTransitionRunning }
        XCTAssertTrue(finished)
        XCTAssertTrue(engine.idle.items.isEmpty, "the outgoing deck is emptied after the fade")

        let rate = outgoing.tap.sampleRate.load()
        let outRamp = try XCTUnwrap(outgoing.tap.ramp.read(), "the outgoing curve stays recorded on its tap")
        XCTAssertEqual(outRamp.role, .outgoing)
        XCTAssertEqual(outRamp.duration, 1, accuracy: 0.1)
        let inRamp = CrossfadeRamp(role: .incoming, curve: .linear, startTime: 0, duration: outRamp.duration, scale: 1)

        func check(_ item: DeckItem, _ ramp: CrossfadeRamp, label: String) throws -> Int {
            var checked = 0
            for entry in try XCTUnwrap(item.tap.log?.snapshot()) where entry.rmsIn > 0.01 && entry.frames > 64 {
                let g0 = Double(ramp.gain(at: entry.mediaTime))
                let g1 = Double(ramp.gain(at: entry.mediaTime + Double(entry.frames - 1) / rate))
                let expected = ((g0 * g0 + g0 * g1 + g1 * g1) / 3).squareRoot()
                XCTAssertEqual(Double(entry.rmsOut / entry.rmsIn), expected, accuracy: 0.03,
                               "\(label) at \(entry.mediaTime) s")
                checked += 1
            }
            return checked
        }
        XCTAssertGreaterThan(try check(outgoing, outRamp, label: "outgoing"), 10)
        XCTAssertGreaterThan(try check(incoming, inRamp, label: "incoming"), 10)

        // The decks really overlapped in time.
        let outLog = try XCTUnwrap(outgoing.tap.log?.snapshot()), inLog = try XCTUnwrap(incoming.tap.log?.snapshot())
        let inFirst = try XCTUnwrap(inLog.first), outLast = try XCTUnwrap(outLog.last)
        XCTAssertLessThan(inFirst.hostTime, outLast.hostTime)
    }

    func testModeNoneOnAPlaylistRuleOverridesAGlobalCrossfade() async throws {
        let a = try TestAudio.sine(frequency: 440, seconds: 3)
        let b = try TestAudio.sine(frequency: 550, seconds: 3)
        let engine = makeEngine()
        defer { engine.stop() }
        engine.crossfadeEnabled = true
        engine.globalTransition = TransitionSettings(mode: .overlap, durationMs: 1000)
        engine.transitionRules = [TransitionRule(playlistId: "p1", settings: TransitionSettings(mode: .none))]
        engine.queuePlaylistId = "p1"
        engine.setQueue([TestAudio.song(a, id: "f:a", seconds: 3), TestAudio.song(b, id: "f:b", seconds: 3)],
                        startIndex: 0, startPositionMs: 0, playWhenReady: false)
        let loaded = await waitUntil(timeout: 5) { engine.activeItem != nil }
        XCTAssertTrue(loaded)
        let handOver = await waitUntil(timeout: 3) { engine.plannedHandOver != nil }
        XCTAssertTrue(handOver, "the playlist's NONE rule wins: gapless hand-over")
        XCTAssertNil(engine.plannedCrossfade)

        engine.queuePlaylistId = nil   // global default → crossfade
        XCTAssertNotNil(engine.plannedCrossfade)
        XCTAssertTrue(engine.active.upcoming.isEmpty)
        engine.suspendTransitions(owner: "sync-editor")
        XCTAssertNil(engine.plannedCrossfade, "suspended transitions fall back to gapless")
        XCTAssertNotNil(engine.plannedHandOver)
        engine.resumeTransitions(owner: "sync-editor")
        XCTAssertNotNil(engine.plannedCrossfade)
    }

    // MARK: Queue, repeat, skips

    func testRepeatOneLoopsTheSameEntry() async throws {
        let a = try TestAudio.sine(frequency: 440, seconds: 1)
        let engine = makeEngine()
        defer { engine.stop() }
        var loops = 0
        engine.onRepeatLoop = { loops += 1 }
        engine.setRepeatMode(.one)
        engine.setQueue([TestAudio.song(a, id: "f:a", seconds: 1)], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let looped = await waitUntil(timeout: 4) { loops >= 1 }
        XCTAssertTrue(looped)
        XCTAssertEqual(engine.queue.currentIndex, 0)
        XCTAssertTrue(engine.playWhenReady)
    }

    func testSkipsFollowMedia3() async throws {
        let urls = try (0..<3).map { try TestAudio.sine(frequency: 300 + Double($0) * 100, seconds: 6) }
        let songs = urls.enumerated().map { TestAudio.song($1, id: "f:\($0)", seconds: 6) }
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setQueue(songs, startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        _ = await waitUntil(timeout: 3) { engine.plannedHandOver != nil }

        engine.skipToNext()
        let onSecond = await waitUntil(timeout: 3) { engine.activeItem?.entry.song.id == "f:1" }
        XCTAssertTrue(onSecond)
        XCTAssertEqual(engine.queue.currentIndex, 1)

        engine.skipToPrevious()   // within 3 s: previous song
        let back = await waitUntil(timeout: 3) { engine.activeItem?.entry.song.id == "f:0" }
        XCTAssertTrue(back)

        engine.seek(toMs: 4_000)
        let sought = await waitUntil(timeout: 3) { engine.currentPositionMs() >= 3_900 }
        XCTAssertTrue(sought)
        engine.skipToPrevious()   // past 3 s: restart
        let restarted = await waitUntil(timeout: 3) { engine.currentPositionMs() < 1_500 }
        XCTAssertTrue(restarted)
        XCTAssertEqual(engine.queue.currentIndex, 0)

        engine.skipToQueueItem(at: 2)
        let third = await waitUntil(timeout: 3) { engine.activeItem?.entry.song.id == "f:2" }
        XCTAssertTrue(third)
        engine.skipToNext()   // last song, repeat off: nothing
        XCTAssertEqual(engine.queue.currentIndex, 2)
    }

    // MARK: Skips into the prepared item (streaming speed R7)

    func testASkipTakesOverTheCrossfadesPreparedItem() async throws {
        let urls = try (0..<3).map { try TestAudio.sine(frequency: 300 + Double($0) * 100, seconds: 8) }
        let songs = urls.enumerated().map { TestAudio.song($1, id: "f:\($0)", seconds: 8) }
        let engine = makeEngine()
        defer { engine.stop() }
        let resolver = CountingPlayableURLResolver(base: engine.factory.resolver)
        engine.factory.resolver = resolver
        engine.crossfadeEnabled = true
        engine.globalTransition = TransitionSettings(mode: .overlap, durationMs: 1000, curveIn: .linear,
                                                     curveOut: .linear)
        var transitions: [(new: String?, automatic: Bool)] = []
        engine.onItemTransition = { new, _, automatic in transitions.append((new: new?.id, automatic: automatic)) }

        engine.setQueue(songs, startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        XCTAssertNotNil(engine.plannedCrossfade)
        let ready = await waitUntil(timeout: 4) { engine.preparedIncoming != nil }
        XCTAssertTrue(ready, "the crossfade prepares the next item after its 1.5 s debounce")
        let prepared = try XCTUnwrap(engine.preparedIncoming)
        XCTAssertEqual(prepared.entry.song.id, "f:1")
        XCTAssertNotNil(prepared.tap.ramp.read(), "a crossfade's incoming item waits at gain 0")
        let resolutions = resolver.calls

        engine.skipToNext()
        // Taken over at once: no new item, no new resolution, full gain.
        XCTAssertTrue(engine.activeItem === prepared)
        XCTAssertTrue(engine.active.currentItem === prepared)
        XCTAssertEqual(resolver.calls, resolutions)
        XCTAssertEqual(engine.queue.currentIndex, 1)
        XCTAssertNil(engine.preparedIncoming)
        XCTAssertNil(prepared.tap.ramp.read())
        XCTAssertTrue(engine.idle.items.isEmpty, "the outgoing deck is emptied")
        XCTAssertEqual(transitions.last?.new, "f:1")
        XCTAssertEqual(transitions.last?.automatic, false)
        XCTAssertEqual(PlaybackStartTimings.shared.records.first?.kind, .prepared)
        let playing = await waitUntil(timeout: 3) { prepared.positionSeconds > 0.2 && engine.active.isPlaying }
        XCTAssertTrue(playing, "the adopted item plays")
        let measured = await waitUntil(timeout: 2) { PlaybackStartTimings.shared.records.first?.playingMs != nil }
        XCTAssertTrue(measured, "the skip's start is timed")
        XCTAssertNotNil(engine.plannedCrossfade, "the next crossfade is planned from the adopted item")
    }

    func testASkipTakesOverTheGaplessHandOversPreparedItem() async throws {
        // 6 s songs: the hand-over (transition at 5 s) prepares the next item once within its last 4.5 s.
        let urls = try (0..<3).map { try TestAudio.sine(frequency: 350 + Double($0) * 100, seconds: 6) }
        let songs = urls.enumerated().map { TestAudio.song($1, id: "f:\($0)", seconds: 6) }
        let engine = makeEngine()
        defer { engine.stop() }
        let resolver = CountingPlayableURLResolver(base: engine.factory.resolver)
        engine.factory.resolver = resolver
        engine.setQueue(songs, startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        XCTAssertNotNil(engine.plannedHandOver)
        let ready = await waitUntil(timeout: 4) { engine.preparedIncoming != nil }
        XCTAssertTrue(ready)
        let prepared = try XCTUnwrap(engine.preparedIncoming)
        XCTAssertEqual(prepared.entry.song.id, "f:1")
        let resolutions = resolver.calls

        engine.skipToNext()
        XCTAssertTrue(engine.activeItem === prepared)
        XCTAssertEqual(resolver.calls, resolutions)
        XCTAssertEqual(engine.queue.currentIndex, 1)
        let playing = await waitUntil(timeout: 3) { prepared.positionSeconds > 0.2 }
        XCTAssertTrue(playing)
        XCTAssertLessThan(prepared.positionSeconds, 3, "the adopted item starts from its beginning")

        // A skip to a song nothing prepared still loads it.
        engine.skipToQueueItem(at: 0)
        let back = await waitUntil(timeout: 3) { engine.activeItem?.entry.song.id == "f:0" }
        XCTAssertTrue(back)
        XCTAssertGreaterThan(resolver.calls, resolutions)
    }

    /// Gapless mode (the default): the next song from the library's files is parked on the idle deck as soon as the
    /// countdown's debounce has run, so a skip anywhere in the song takes it over instead of building it from scratch.
    func testGaplessModeParksALocalNextSongEarlySoASkipIsInstant() async throws {
        let urls = try (0..<3).map { try TestAudio.sine(frequency: 320 + Double($0) * 90, seconds: 14) }
        let songs = urls.enumerated().map { TestAudio.song($1, id: "f:\($0)", seconds: 14) }
        let engine = makeEngine()
        defer { engine.stop() }
        let resolver = CountingPlayableURLResolver(base: engine.factory.resolver)
        engine.factory.resolver = resolver
        engine.setQueue(songs, startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        XCTAssertNotNil(engine.plannedHandOver, "the default mode plans a gapless hand-over")
        // Before, the next item was only built in the last 4.5 s (from about 8.5 s into this song).
        let early = await waitUntil(timeout: 5) { engine.preparedIncoming != nil }
        XCTAssertTrue(early, "the next song is prepared after the debounce")
        XCTAssertLessThan(engine.currentPositionMs(), 6_000, "well before the last 4.5 s")
        let prepared = try XCTUnwrap(engine.preparedIncoming)
        XCTAssertEqual(prepared.entry.song.id, "f:1")
        let resolutions = resolver.calls

        engine.skipToNext()
        XCTAssertTrue(engine.activeItem === prepared, "the skip takes the prepared item over")
        XCTAssertEqual(resolver.calls, resolutions, "nothing is resolved or built for the skip")
        XCTAssertEqual(PlaybackStartTimings.shared.records.first?.kind, .prepared)
        let playing = await waitUntil(timeout: 3) { prepared.positionSeconds > 0.2 && engine.active.isPlaying }
        XCTAssertTrue(playing)
        let measured = await waitUntil(timeout: 2) { PlaybackStartTimings.shared.records.first?.playingMs != nil }
        XCTAssertTrue(measured)
        if let playingMs = PlaybackStartTimings.shared.records.first?.playingMs {
            print("measured [skipNext.gapless.local] playingMs=\(playingMs)")
        }
        // The next song after the adopted one is planned and parked again.
        let again = await waitUntil(timeout: 5) { engine.preparedIncoming?.entry.song.id == "f:2" }
        XCTAssertTrue(again)
    }

    /// A streamed target keeps the late lead: nothing is resolved (so nothing could be downloaded) early in the song.
    func testGaplessModeDoesNotPrepareAStreamedNextSongEarly() async throws {
        let urls = try (0..<2).map { try TestAudio.sine(frequency: 400 + Double($0) * 100, seconds: 14) }
        let songs = [TestAudio.song(urls[0], id: "f:0", seconds: 14), TestAudio.song(urls[1], id: "yt:abc", seconds: 14)]
        let engine = makeEngine()
        defer { engine.stop() }
        let resolver = CountingPlayableURLResolver(base: engine.factory.resolver)
        engine.factory.resolver = resolver
        engine.setQueue(songs, startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        XCTAssertNotNil(engine.plannedHandOver)
        let resolutions = resolver.calls
        try await Task.sleep(for: .milliseconds(3_500))
        XCTAssertLessThan(engine.currentPositionMs(), 8_000)
        XCTAssertNil(engine.preparedIncoming)
        XCTAssertEqual(resolver.calls, resolutions, "no early resolution of a streamed song")
    }

    func testQueueEventsReachThePlaybackStore() async throws {
        let urls = try (0..<5).map { try TestAudio.sine(frequency: 300 + Double($0) * 50, seconds: 2) }
        let songs = urls.enumerated().map { TestAudio.song($1, id: "f:\($0)", seconds: 2) }
        let engine = makeEngine()
        defer { engine.stop() }
        let store = PlaybackStore(engine: engine)
        store.play(songs, startIndex: 2, playWhenReady: false)
        store.setShuffleEnabled(true)
        let synced = await waitUntil(timeout: 2) { store.queue.map(\.id) == engine.queue.songs.map(\.id) }
        XCTAssertTrue(synced)
        XCTAssertEqual(store.current?.id, "f:2", "shuffle keeps the current song")
        XCTAssertTrue(store.isShuffleEnabled)

        store.addToQueue([songs[0]])
        let appended = await waitUntil(timeout: 2) { store.queue.count == 6 }
        XCTAssertTrue(appended)
        store.removeQueueItem(at: 5)
        let removed = await waitUntil(timeout: 2) { store.queue.count == 5 }
        XCTAssertTrue(removed)

        engine.setRepeatMode(.all)   // e.g. from the lock screen
        let repeatSynced = await waitUntil(timeout: 2) { store.repeatMode == .all }
        XCTAssertTrue(repeatSynced)
    }

    // MARK: Interruptions

    func testInterruptionPausesAndResumesTheEngine() async throws {
        let a = try TestAudio.sine(frequency: 440, seconds: 6)
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setQueue([TestAudio.song(a, id: "f:a", seconds: 6)], startIndex: 0, startPositionMs: 0,
                        playWhenReady: true)
        try await waitForAudio(engine)
        engine.session.handleInterruption(began: true, shouldResume: false)
        XCTAssertFalse(engine.playWhenReady)
        XCTAssertEqual(engine.active.player.rate, 0)
        let pausedAt = engine.currentPositionMs()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(Double(engine.currentPositionMs()), Double(pausedAt), accuracy: 60)

        engine.session.handleInterruption(began: false, shouldResume: true)
        XCTAssertTrue(engine.playWhenReady)
        let moving = await waitUntil(timeout: 3) { engine.currentPositionMs() > pausedAt + 200 }
        XCTAssertTrue(moving, "playback resumed after the interruption")

        engine.session.handleInterruption(began: true, shouldResume: false)
        engine.session.handleInterruption(began: false, shouldResume: false)
        XCTAssertFalse(engine.playWhenReady, "no resume without .shouldResume")
    }

    // MARK: ReplayGain

    func testReplayGainFromTagsReachesTheTap() async throws {
        let tag = TestAudio.id3Tag([("REPLAYGAIN_TRACK_GAIN", "-6.00 dB"), ("REPLAYGAIN_ALBUM_GAIN", "-3.00 dB")])
        let url = try TestAudio.sine(frequency: 440, seconds: 3, id3: tag)
        let values = try XCTUnwrap(ReplayGainReader.read(url), "PixlTags reads the WAV's id3 chunk")
        XCTAssertEqual(values.trackGainDb ?? 0, -6, accuracy: 0.001)
        XCTAssertEqual(values.albumGainDb ?? 0, -3, accuracy: 0.001)

        let engine = makeEngine()
        defer { engine.stop() }
        engine.replayGainEnabled = true
        engine.setQueue([TestAudio.song(url, id: "f:rg", seconds: 3)], startIndex: 0, startPositionMs: 0,
                        playWhenReady: false)
        let applied = await waitUntil(timeout: 5) {
            abs((engine.activeItem?.tap.replayGainVolume.load() ?? 1) - ReplayGain.gainDbToVolume(-6)) < 0.001
        }
        XCTAssertTrue(applied)
        engine.replayGainUseAlbumGain = true
        let album = await waitUntil(timeout: 5) {
            abs((engine.activeItem?.tap.replayGainVolume.load() ?? 1) - ReplayGain.gainDbToVolume(-3)) < 0.001
        }
        XCTAssertTrue(album)
        engine.replayGainEnabled = false
        XCTAssertEqual(engine.activeItem?.tap.replayGainVolume.load(), 1)
    }

    // MARK: Snapshot

    func testQueueSnapshotMovesFromUserDefaultsToItsFile() async throws {
        let suite = "pixlaudio.tests.snapshot.file"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = QueueSnapshotFile(url: directory.appendingPathComponent("queue.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = PlaybackQueueSnapshot(
            items: [PlaybackQueueItemSnapshot(mediaId: "a", uri: "file:///a", title: "A", artist: "X", albumTitle: "Y",
                                              artworkUri: nil, durationMs: 1_000)],
            currentMediaId: "a", currentIndex: 0, currentPositionMs: 5, playWhenReady: false, repeatMode: 0,
            shuffleEnabled: false, savedAtEpochMs: 1)
        defaults.set(try XCTUnwrap(QueueSnapshotCoding.encodeNow(snapshot)), forKey: PreferenceKeys.playbackQueueSnapshot)

        let store = QueueSnapshotStore(defaults: defaults, file: file)
        let migrated = await store.loadInBackground()
        XCTAssertEqual(migrated?.items.map(\.mediaId), ["a"])
        XCTAssertNil(defaults.string(forKey: PreferenceKeys.playbackQueueSnapshot))
        XCTAssertNotNil(file.read())

        // A newer save wins over an older one that arrives later; removing deletes the file.
        file.write("new", token: 5)
        file.write("old", token: 4)
        XCTAssertEqual(file.read(), "new")
        file.remove(token: 6)
        XCTAssertNil(file.read())
    }

    func testQueueSnapshotSavesAndRestores() async throws {
        let urls = try (0..<3).map { try TestAudio.sine(frequency: 300 + Double($0) * 100, seconds: 4) }
        let songs = urls.enumerated().map { TestAudio.song($1, id: "f:\($0)", seconds: 4) }
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setRepeatMode(.all)
        engine.setQueue(songs, startIndex: 1, startPositionMs: 1_500, playWhenReady: false)
        let loaded = await waitUntil(timeout: 5) { engine.activeItem != nil }
        XCTAssertTrue(loaded)

        let suite = "pixlaudio.tests.snapshot"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = QueueSnapshotStore(defaults: defaults)
        store.makeSnapshot = { engine.makeSnapshot() }
        store.saveNow()
        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.items.map(\.mediaId), ["f:0", "f:1", "f:2"])
        XCTAssertEqual(snapshot.currentMediaId, "f:1")
        XCTAssertEqual(snapshot.currentIndex, 1)
        XCTAssertEqual(snapshot.repeatMode, RepeatMode.all.rawValue)
        XCTAssertEqual(Double(snapshot.currentPositionMs), 1_500, accuracy: 100)

        // Songs the library no longer knows are rebuilt from the snapshot's own metadata.
        let known = Dictionary(uniqueKeysWithValues: songs.prefix(2).map { ($0.id, $0) })
        let restoredSongs = QueueSnapshotStore.songs(for: snapshot, lookup: { known[$0] })
        XCTAssertEqual(restoredSongs.map(\.id), ["f:0", "f:1", "f:2"])
        XCTAssertEqual(restoredSongs[2].contentUriString, songs[2].contentUriString)

        let restored = makeEngine()
        defer { restored.stop() }
        restored.restore(snapshot, songs: restoredSongs)
        XCTAssertEqual(restored.queue.songs.map(\.id), ["f:0", "f:1", "f:2"])
        XCTAssertEqual(restored.queue.currentIndex, 1)
        XCTAssertEqual(restored.queue.repeatMode, .all)
        XCTAssertFalse(restored.playWhenReady, "restored paused")
        let ready = await waitUntil(timeout: 5) { restored.activeItem != nil }
        XCTAssertTrue(ready)
        XCTAssertEqual(Double(restored.currentPositionMs()), 1_500, accuracy: 150)
        defaults.removePersistentDomain(forName: suite)
    }
}

/// Counts resolutions around another resolver (each built item resolves once).
nonisolated final class CountingPlayableURLResolver: PlayableURLResolving, Sendable {
    let base: any PlayableURLResolving
    private let count = Mutex(0)

    init(base: any PlayableURLResolving) {
        self.base = base
    }

    var calls: Int { count.withLock { $0 } }

    func playableURL(for song: Song) async -> URL? {
        count.withLock { $0 += 1 }
        return await base.playableURL(for: song)
    }
}
