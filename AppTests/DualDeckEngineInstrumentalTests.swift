import Foundation
import PixlAudioCore
import PixlModel
import Synchronization
import XCTest
@testable import PixlAudio

/// Stands in for the caller that places a swap: records the earliest start the engine offered and answers with a start
/// shifted from it and a fade.
@MainActor
private final class PlacementSpy {
    private(set) var earliestStarts: [Double] = []
    private let startOffsetSeconds: Double
    private let fadeSeconds: Double
    /// Runs inside the placement, before it answers (a seek that lands while the other audio is being set up).
    private let beforeAnswering: (@MainActor () -> Void)?

    init(startOffsetSeconds: Double, fadeSeconds: Double, beforeAnswering: (@MainActor () -> Void)? = nil) {
        self.startOffsetSeconds = startOffsetSeconds
        self.fadeSeconds = fadeSeconds
        self.beforeAnswering = beforeAnswering
    }

    func ask(_ earliest: Double) -> (startSeconds: Double, fadeSeconds: Double) {
        earliestStarts.append(earliest)
        beforeAnswering?()
        return (startSeconds: earliest + startOffsetSeconds, fadeSeconds: fadeSeconds)
    }

    var placement: DualDeckEngine.SwitchPlacement {
        return { [self] earliest in self.ask(earliest) }
    }
}

/// The real engine on the simulator switching the current song to another audio of the same length and back
/// (`switchCurrentAudio`): where a placement puts the swap, how long it fades, and what ends an attempt instead of
/// playing the other audio out of place (a seek while it loads, a song-to-song transition about to begin, an audio of
/// another length).
@MainActor
final class DualDeckEngineInstrumentalTests: XCTestCase {
    private func makeEngine() -> DualDeckEngine {
        DualDeckEngine(session: AudioSessionController())
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

    /// A song of `seconds` and the same length of another audio (a different tone) to switch to.
    private func makeSong(seconds: Double = 10, id: String = "f:a") throws -> (song: Song, other: URL) {
        let original = try TestAudio.sine(frequency: 440, seconds: seconds)
        let other = try TestAudio.sine(frequency: 660, seconds: seconds)
        return (TestAudio.song(original, id: id, seconds: seconds), other)
    }

    // MARK: The swap

    func testASwitchWithoutAPlacementStartsAtOnceAndFadesFor700Ms() async throws {
        let (song, other) = try makeSong()
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setQueue([song], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let first = try XCTUnwrap(engine.activeItem)
        let before = first.positionSeconds

        let outcome = await engine.switchCurrentAudio(to: other, placement: nil, requireAligned: false)
        XCTAssertEqual(outcome, .switched)
        let second = try XCTUnwrap(engine.activeItem)
        XCTAssertFalse(second === first, "the other audio is the current item")
        XCTAssertEqual(second.entry.song.id, "f:a", "the queue entry stays the same")
        XCTAssertEqual(engine.queue.currentIndex, 0)
        let incoming = try XCTUnwrap(second.tap.ramp.read(), "the other audio fades in")
        let outgoing = try XCTUnwrap(first.tap.ramp.read(), "the song fades out")
        XCTAssertEqual(incoming.role, .incoming)
        XCTAssertEqual(outgoing.role, .outgoing)
        XCTAssertEqual(incoming.curve, .linear)
        XCTAssertEqual(outgoing.curve, .linear)
        XCTAssertEqual(incoming.duration, 0.7, accuracy: 0.001)
        XCTAssertEqual(outgoing.duration, 0.7, accuracy: 0.001)
        XCTAssertGreaterThan(incoming.startTime, before, "ahead of the playhead")
        XCTAssertLessThan(incoming.startTime, before + 2.5, "as soon as the other audio is ready")

        let finished = await waitUntil(timeout: 4) { !engine.isTransitionRunning }
        XCTAssertTrue(finished)
        XCTAssertTrue(engine.idle.items.isEmpty, "the song's deck is emptied after the fade")
        XCTAssertNil(second.tap.ramp.read(), "the other audio is left at full gain")
    }

    func testAPlacementDecidesWhereTheSwapStartsAndHowLongItFades() async throws {
        let (song, other) = try makeSong()
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setQueue([song], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let first = try XCTUnwrap(engine.activeItem)
        let before = first.positionSeconds
        let spy = PlacementSpy(startOffsetSeconds: 0.6, fadeSeconds: 0.3)

        let outcome = await engine.switchCurrentAudio(to: other, placement: spy.placement, requireAligned: true)
        XCTAssertEqual(outcome, .switched, "an audio of the same length passes the alignment check")
        let asked = try XCTUnwrap(spy.earliestStarts.first, "the engine asks where to start once the audio is loaded")
        XCTAssertGreaterThanOrEqual(asked, before + 0.44, "never closer to the playhead than the lead the taps need")
        let last = try XCTUnwrap(spy.earliestStarts.last)
        let second = try XCTUnwrap(engine.activeItem)
        let incoming = try XCTUnwrap(second.tap.ramp.read())
        let outgoing = try XCTUnwrap(first.tap.ramp.read())
        XCTAssertEqual(incoming.startTime, last + 0.6, accuracy: 0.03, "the swap starts where the placement said")
        XCTAssertEqual(incoming.duration, 0.3, accuracy: 0.001, "and fades for as long as it said")
        XCTAssertEqual(outgoing.duration, 0.3, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(outgoing.startTime, incoming.startTime - 0.001, "the song's tap never fades in the past")

        // Equal gain: whatever the incoming lacks the outgoing still has, all through the 300 ms.
        for step in 0...12 {
            let into = Double(step) / 12 * 0.3
            let sum = incoming.gain(at: incoming.startTime + into) + outgoing.gain(at: outgoing.startTime + into)
            XCTAssertEqual(sum, 1, accuracy: 0.001, "\(into) s into the fade")
        }
    }

    func testAPlacementThatAsksForTheImpossibleIsClamped() async throws {
        let (song, other) = try makeSong()
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setQueue([song], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        // A start before the earliest one, and a fade far longer than a switch ever fades.
        let spy = PlacementSpy(startOffsetSeconds: -5, fadeSeconds: 5)

        let outcome = await engine.switchCurrentAudio(to: other, placement: spy.placement, requireAligned: false)
        XCTAssertEqual(outcome, .switched)
        let asked = try XCTUnwrap(spy.earliestStarts.last)
        let incoming = try XCTUnwrap(engine.activeItem?.tap.ramp.read())
        XCTAssertGreaterThanOrEqual(incoming.startTime, asked - 0.03, "never before the earliest start")
        XCTAssertLessThan(incoming.startTime, asked + 0.5)
        XCTAssertEqual(incoming.duration, 0.7, accuracy: 0.001, "the longest fade")
    }

    func testAFadeShorterThanTheShortestIsLifted() async throws {
        let (song, other) = try makeSong()
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setQueue([song], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let spy = PlacementSpy(startOffsetSeconds: 0.2, fadeSeconds: 0.05)

        let outcome = await engine.switchCurrentAudio(to: other, placement: spy.placement, requireAligned: false)
        XCTAssertEqual(outcome, .switched)
        let incoming = try XCTUnwrap(engine.activeItem?.tap.ramp.read())
        XCTAssertEqual(incoming.duration, 0.3, accuracy: 0.001, "the shortest fade")
    }

    func testBackToTheOriginalPlaysTheSongsOwnFileAgain() async throws {
        let (song, other) = try makeSong()
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setQueue([song], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let first = try XCTUnwrap(engine.activeItem)

        let switched = await engine.switchCurrentAudio(to: other)
        XCTAssertTrue(switched, "the Bool API still answers whether it switched")
        let onOther = try XCTUnwrap(engine.activeItem)
        XCTAssertEqual(onOther.asset.url.lastPathComponent, other.lastPathComponent)
        let settled = await waitUntil(timeout: 4) { !engine.isTransitionRunning }
        XCTAssertTrue(settled)

        let back = await engine.switchCurrentAudio(to: nil, placement: nil, requireAligned: false)
        XCTAssertEqual(back, .switched)
        let onOriginal = try XCTUnwrap(engine.activeItem)
        XCTAssertFalse(onOriginal === onOther)
        XCTAssertEqual(onOriginal.asset.url.lastPathComponent, first.asset.url.lastPathComponent)
        XCTAssertEqual(onOriginal.entry.song.id, "f:a")
    }

    // MARK: What ends an attempt

    func testASeekWhileTheOtherAudioIsBeingSetUpEndsTheAttemptAndTheSongPlaysOn() async throws {
        let (songA, other) = try makeSong(id: "f:a")
        let songB = TestAudio.song(try TestAudio.sine(frequency: 550, seconds: 10), id: "f:b", seconds: 10)
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setQueue([songA, songB], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let first = try XCTUnwrap(engine.activeItem)
        XCTAssertNotNil(engine.plannedHandOver, "the song has its own hand-over to the next one")
        // The person scrubs just as the engine asks where the swap goes.
        let spy = PlacementSpy(startOffsetSeconds: 0, fadeSeconds: 0.7) { engine.seek(toMs: 6_000) }

        let outcome = await engine.switchCurrentAudio(to: other, placement: spy.placement, requireAligned: false)
        XCTAssertEqual(outcome, .abortedBySeek)
        XCTAssertTrue(engine.activeItem === first, "the song keeps playing")
        XCTAssertTrue(engine.idle.items.isEmpty, "the other audio is dropped")
        XCTAssertFalse(engine.isTransitionRunning)
        XCTAssertNil(first.tap.ramp.read(), "no fade was published")
        XCTAssertNotNil(engine.plannedHandOver, "the song's own plan for what comes next is made again")
        XCTAssertGreaterThanOrEqual(engine.currentPositionMs(), 5_900, "the seek itself was honoured")
    }

    func testAnAudioOfAnotherLengthIsNotSwitchedToWhenAlignmentIsRequired() async throws {
        let (song, _) = try makeSong(seconds: 10)
        let shorter = try TestAudio.sine(frequency: 660, seconds: 6)
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setQueue([song], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let first = try XCTUnwrap(engine.activeItem)

        let outcome = await engine.switchCurrentAudio(to: shorter, placement: nil, requireAligned: true)
        XCTAssertEqual(outcome, .misaligned)
        XCTAssertTrue(engine.activeItem === first)
        XCTAssertTrue(engine.idle.items.isEmpty, "the other audio is dropped")

        // A tap on the instrumental is the person's own call: no alignment check.
        let anyway = await engine.switchCurrentAudio(to: shorter, placement: nil, requireAligned: false)
        XCTAssertEqual(anyway, .switched)
    }

    func testASwitchTooCloseToTheSongsOwnTransitionIsNotMadeAndTheTransitionStays() async throws {
        let a = TestAudio.song(try TestAudio.sine(frequency: 440, seconds: 3), id: "f:a", seconds: 3)
        let b = TestAudio.song(try TestAudio.sine(frequency: 550, seconds: 3), id: "f:b", seconds: 3)
        let other = try TestAudio.sine(frequency: 660, seconds: 3)
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setQueue([a, b], startIndex: 0, startPositionMs: 0, playWhenReady: true)
        try await waitForAudio(engine)
        let first = try XCTUnwrap(engine.activeItem)
        let plan = try XCTUnwrap(engine.plannedHandOver, "a 3 s song hands over at 2 s")

        let outcome = await engine.switchCurrentAudio(to: other, placement: nil, requireAligned: false)
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(engine.activeItem === first)
        XCTAssertEqual(engine.plannedHandOver?.id, plan.id, "the hand-over was left alone")
    }

    func testNothingLoadedIsAFailure() async {
        let engine = makeEngine()
        defer { engine.stop() }
        let outcome = await engine.switchCurrentAudio(to: nil, placement: nil, requireAligned: false)
        XCTAssertEqual(outcome, .failed)
    }

    // MARK: Paused

    func testPausedTheSwapIsSilentAtTheSamePositionAndNeverAsksForAPlacement() async throws {
        let (song, other) = try makeSong()
        let engine = makeEngine()
        defer { engine.stop() }
        engine.setQueue([song], startIndex: 0, startPositionMs: 0, playWhenReady: false)
        let loaded = await waitUntil(timeout: 5) { engine.activeItem != nil }
        XCTAssertTrue(loaded)
        let first = try XCTUnwrap(engine.activeItem)
        let spy = PlacementSpy(startOffsetSeconds: 0.6, fadeSeconds: 0.3)

        let outcome = await engine.switchCurrentAudio(to: other, placement: spy.placement, requireAligned: true)
        XCTAssertEqual(outcome, .switched)
        XCTAssertTrue(spy.earliestStarts.isEmpty, "a paused song has no playhead to place a swap on")
        let second = try XCTUnwrap(engine.activeItem)
        XCTAssertFalse(second === first)
        XCTAssertFalse(engine.isTransitionRunning, "no fade")
        XCTAssertFalse(engine.playWhenReady)
        XCTAssertLessThan(second.positionSeconds, 0.5, "the same place")
        XCTAssertNil(second.tap.ramp.read())
    }
}
