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
        let preInserted = await waitUntil(timeout: 3) { engine.active.upcoming.count == 1 }
        XCTAssertTrue(preInserted, "NONE mode pre-inserts the next item on the active deck")
        let second = try XCTUnwrap(engine.active.upcoming.first)
        XCTAssertEqual(second.entry.song.id, "f:b")

        let advanced = await waitUntil(timeout: 6) { engine.queue.currentIndex == 1 && engine.activeItem === second }
        XCTAssertTrue(advanced)
        let rendered = await waitUntil(timeout: 3) { second.tap.processedFrames.load(ordering: .relaxed) > 4_410 }
        XCTAssertTrue(rendered)
        XCTAssertEqual(transitions.last?.new, "f:b")
        XCTAssertEqual(transitions.last?.previous, "f:a")
        XCTAssertEqual(transitions.last?.automatic, true)
        XCTAssertTrue(engine.idle.items.isEmpty, "no second deck involved")

        // The first item was rendered to its end…
        let rate = first.tap.sampleRate.load()
        XCTAssertGreaterThan(rate, 0)
        XCTAssertEqual(Double(first.tap.processedFrames.load(ordering: .relaxed)), 1.5 * rate, accuracy: 2_048)
        // …and the second followed straight on (same render stream: no gap between their buffers).
        let firstLog = try XCTUnwrap(first.tap.log?.snapshot())
        let secondLog = try XCTUnwrap(second.tap.log?.snapshot())
        let lastOfFirst = try XCTUnwrap(firstLog.last), firstOfSecond = try XCTUnwrap(secondLog.first)
        XCTAssertEqual(lastOfFirst.mediaTime + Double(lastOfFirst.frames) / rate, 1.5, accuracy: 0.05)
        XCTAssertEqual(firstOfSecond.mediaTime, 0, accuracy: 0.01)
        let gap = seconds(firstOfSecond.hostTime &- lastOfFirst.hostTime) - Double(lastOfFirst.frames) / rate
        XCTAssertLessThan(gap, 0.15, "gap between the songs: \(gap) s")
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
        XCTAssertNotNil(engine.plannedCrossfade, "a crossfade is planned instead of a gapless pre-insert")
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
        let preInserted = await waitUntil(timeout: 3) { engine.active.upcoming.count == 1 }
        XCTAssertTrue(preInserted, "the playlist's NONE rule wins: gapless")
        XCTAssertNil(engine.plannedCrossfade)

        engine.queuePlaylistId = nil   // global default → crossfade
        XCTAssertNotNil(engine.plannedCrossfade)
        XCTAssertTrue(engine.active.upcoming.isEmpty)
        engine.suspendTransitions(owner: "sync-editor")
        XCTAssertNil(engine.plannedCrossfade, "suspended transitions fall back to gapless")
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
        _ = await waitUntil(timeout: 3) { engine.active.upcoming.count == 1 }

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
