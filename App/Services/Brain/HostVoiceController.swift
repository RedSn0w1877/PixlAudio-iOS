import AVFoundation
import CallKit
import Foundation
import Observation
import PixlLibrary
import PixlModel

/// The spoken host of Endless Listening (milestone E2, the port of Android's `HostVoiceStateHolder`): says the short note of a song aloud, at
/// a calm moment, with the music brought down.
///
/// Everything about *when* is `HostVoice` (pure, in PixlLibrary, tested against Android's `hostvoice.jsonl`); this class only reads the world
/// and does what it says:
///  - **Armed** only while "Spoken host notes" and Host notes are on and Endless Listening is the queue's station. With the switch off it
///    registers nothing at all (no observation, no notification, no synthesizer); with the switch on it watches four observable values and,
///    only while armed, the audio session's route and interruptions.
///  - On each new song it makes the very note the player shows (`SetNoteLines.forQueue`, the same inputs as `PlayerSetNoteLine`), turns it
///    into a line (`HostVoice.line`) and asks `HostVoice.decide` again and again (every 300 ms at most) until the answer is to speak or to
///    give up. Each end of a note is written to the developer log.
///  - To speak it brings the music down through `DualDeckEngine.hostDuck`, waits for the ramp, speaks, and brings it back. A skip, a pause,
///    a transition, an interruption (a call), a route change or the end of the station stops the line at once (`HostVoice.cancelReason`).
///
/// The synthesizer is created on the first line, or when the person taps "Test the voice", and handed back when the host is disarmed.
@MainActor
@Observable
final class HostVoiceController {
    /// How "Test the voice" ended.
    enum TestResult: Sendable { case spoke, noVoice, busy, inCall, error }

    /// The last 20 decisions, newest first, for the developer row "Host voice log".
    private(set) var log: [HostVoiceLogEntry] = []

    @ObservationIgnored private unowned let endless: EndlessState
    @ObservationIgnored private weak var brain: BrainService?
    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let engine: DualDeckEngine?
    @ObservationIgnored private let speaker = HostSpeaker()
    /// The call observer reports calls only once it has a delegate (the delegate does nothing: `inCall()` reads `calls`), so it is made with one,
    /// the first time the host is armed or a voice test is asked for.
    @ObservationIgnored private let callWatcher = HostCallWatcher()
    @ObservationIgnored private lazy var callObserver: CXCallObserver = {
        let observer = CXCallObserver()
        observer.setDelegate(callWatcher, queue: .main)
        return observer
    }()

    @ObservationIgnored private var observing = false
    @ObservationIgnored private var armed = false
    @ObservationIgnored private var lastSongId: String?
    @ObservationIgnored private var trackTask: Task<Void, Never>?
    @ObservationIgnored private var trackCounter = 0
    @ObservationIgnored private var lastSpokenCounter: Int?
    @ObservationIgnored private var lastSpokenText = ""
    @ObservationIgnored private var secondLastText = ""
    @ObservationIgnored private var speaking = false
    @ObservationIgnored private var testing = false
    @ObservationIgnored private var duckEnded: String?
    @ObservationIgnored private var routeChangedAtSpeech = false
    @ObservationIgnored private var pausedByEvent = false
    @ObservationIgnored private var lastRouteChangeMs: Int64 = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(endless: EndlessState, brain: BrainService?, playback: PlaybackStore, engine: DualDeckEngine?) {
        self.endless = endless
        self.brain = brain
        self.playback = playback
        self.engine = engine
        engine?.hostDuck.onEnded = { [weak self] reason in self?.duckEndedOnItsOwn(reason) }
    }

    // MARK: Switching on and off

    /// The switch of Settings changed (or the app started with it on): watch, or stop watching. Cheap, and nothing but a flag read while
    /// the switch is off.
    func switchChanged() {
        if endless.spokenNotesEnabled { startObserving() }
        refresh()
    }

    private func startObserving() {
        guard !observing, endless.spokenNotesEnabled else { return }
        observing = true
        withObservationTracking {
            _ = endless.spokenNotesEnabled
            _ = endless.hostNotesEnabled
            _ = endless.isActive
            _ = playback.currentSongId
            _ = playback.isPlaying
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observing = false
                self.refresh()
                self.startObserving()
            }
        }
    }

    /// Reads the world once and does what changed: arm or disarm, start a song's note, stop a line when the music paused.
    private func refresh() {
        let shouldArm = endless.spokenNotesEnabled && endless.hostNotesEnabled && endless.isActive && engine != nil
        guard shouldArm else {
            disarm()
            return
        }
        if !armed { arm() }
        let id = playback.currentSongId
        if id != lastSongId {
            lastSongId = id
            trackTask?.cancel()
            trackTask = nil
            if let id { trackTask = Task { @MainActor [weak self] in await self?.handleTrack(id) } }
        }
        if !playback.isPlaying { cancelNow("pause") }
    }

    private func arm() {
        armed = true
        // Calls are only reported once the observer has its delegate: make it now, before a call can come.
        _ = callObserver
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { @Sendable [weak self] note in
            let reason = AudioSessionController.routeChangeReason(note)
            MainActor.assumeIsolated { self?.routeChanged(reason) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { @Sendable [weak self] note in
            let began = AudioSessionController.interruptionInfo(note).began
            MainActor.assumeIsolated { if began { self?.interruptionBegan() } }
        })
    }

    private func disarm() {
        guard armed || trackTask != nil || lastSongId != nil else { return }
        armed = false
        trackTask?.cancel()
        trackTask = nil
        lastSongId = nil
        let center = NotificationCenter.default
        for o in observers { center.removeObserver(o) }
        observers.removeAll()
        if !speaking && !testing {
            engine?.hostDuck.end(quick: true)
            speaker.shutdown()
        }
    }

    // MARK: One song

    private func handleTrack(_ songId: String) async {
        guard let engine else { return }
        trackCounter += 1
        let mine = trackCounter
        guard let note = await noteFor(songId), !Task.isCancelled else { return }
        // The note is the app's own (its banned words were looked for in what the app wrote, not in a name): only its length is checked again.
        let line = HostVoice.line(note, noteChecked: true)
        if line.isEmpty {
            record(spoke: false, cancelled: false, reason: "no_line", text: note)
            return
        }
        let startedAt = Self.nowMs() - (engine.hostPlayingSongId == songId ? engine.hostTiming().positionMs : 0)
        while !Task.isCancelled {
            let d = HostVoice.decide(inputs(engine, songId: songId, line: line, counter: mine, startedAt: startedAt))
            if d.action == HostVoice.actWait {
                if d.reason == "voice_pending" {
                    // Every other rule allows the line: only now is the synthesizer made (the voices are listed once, for a line that
                    // will be said). The next decision sees a ready voice, or "no_voice".
                    speaker.ensure()
                    continue
                }
                try? await Task.sleep(for: .milliseconds(d.waitMs))
            } else if d.action == HostVoice.actSkip {
                record(spoke: false, cancelled: false, reason: d.reason, text: line)
                return
            } else {
                await speakNow(engine, songId: songId, line: line, counter: mine)
                return
            }
        }
    }

    /// The note the player shows for `songId` (the one that starts at that song), or nil when there is none: the same window, the same
    /// history and the same facts as `PlayerSetNoteLine`.
    private func noteFor(_ songId: String) async -> String? {
        let queue = playback.queue
        guard !queue.isEmpty else { return nil }
        let index = playback.currentIndex ?? -1
        let at = index >= 0 && index < queue.count && queue[index].id == songId ? index : (queue.firstIndex { $0.id == songId } ?? -1)
        guard at >= 0 else { return nil }
        let window = SetNoteLines.window(queue, currentIndex: at)
        let heard = await SetNoteHistoryLoader.heard(window, repository: brain?.repository, engine: brain?.engine)
        let facts = await endless.hostFacts(window: window)
        return SetNoteLines.forQueue(queue, currentIndex: at, heard: heard, host: facts).current
    }

    private func inputs(_ engine: DualDeckEngine, songId: String, line: String, counter: Int, startedAt: Int64) -> HostVoice.Inputs {
        let isTarget = engine.hostPlayingSongId == songId && engine.hostQueueSongId == songId
        let timing = engine.hostTiming()
        let now = Self.nowMs()
        return HostVoice.Inputs(
            enabled: endless.spokenNotesEnabled,
            endless: endless.isActive,
            notesOn: endless.hostNotesEnabled,
            line: line,
            sameAsLast: line == lastSpokenText || line == secondLastText,
            tracksSinceLast: lastSpokenCounter.map { counter - $0 - 1 } ?? HostVoice.never,
            sinceStartMs: now - startedAt,
            currentIsTarget: isTarget,
            transitionRunning: engine.isTransitionRunning || engine.scheduledHandOver != nil,
            playing: engine.hostIsPlaying,
            inCall: inCall(),
            msSinceRoute: lastRouteChangeMs == 0 ? Self.longAgoMs : now - lastRouteChangeMs,
            positionMs: isTarget ? timing.positionMs : 0,
            remainingMs: isTarget ? timing.remainingMs : -1,
            voice: speaker.decisionVoiceState,
            canDuck: engine.hostCanDuck)
    }

    // MARK: Speaking

    private func speakNow(_ engine: DualDeckEngine, songId: String, line: String, counter: Int) async {
        duckEnded = nil
        routeChangedAtSpeech = false
        pausedByEvent = false
        guard engine.hostDuck.begin() else {
            record(spoke: false, cancelled: false, reason: "cant_duck", text: line)
            return
        }
        speaking = true
        var stoppedFor = ""
        var said = false
        var began = false
        try? await Task.sleep(for: .milliseconds(HostVoice.rampDownMs))
        if Task.isCancelled {
            stoppedFor = "skip"
        } else {
            stoppedFor = stopReason(engine, songId: songId, sinceSpeechStartMs: 0)
            if stoppedFor.isEmpty {
                let startedAt = Self.nowMs()
                began = true
                lastSpokenCounter = counter
                secondLastText = lastSpokenText
                lastSpokenText = line
                speaker.speak(line)
                while speaker.isSpeaking {
                    if Task.isCancelled {
                        stoppedFor = "skip"
                        break
                    }
                    stoppedFor = stopReason(engine, songId: songId, sinceSpeechStartMs: Self.nowMs() - startedAt)
                    if !stoppedFor.isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(Self.pollMs))
                }
                if stoppedFor.isEmpty {
                    switch speaker.lastOutcome {
                    case .done: said = true
                    case .stopped: stoppedFor = duckEnded ?? "stopped"
                    case .error: stoppedFor = "voice_error"
                    }
                }
            }
        }
        speaker.stop()
        engine.hostDuck.end(quick: !said)
        speaking = false
        // The switch went off while the line was said (`disarm` leaves a running line to end): the synthesizer is given back now.
        if !armed && !testing { speaker.shutdown() }
        if said {
            record(spoke: true, cancelled: false, reason: "speak", text: line)
        } else {
            record(spoke: false, cancelled: began, reason: stoppedFor.isEmpty ? "stopped" : stoppedFor, text: line)
        }
    }

    private func stopReason(_ engine: DualDeckEngine, songId: String, sinceSpeechStartMs: Int64) -> String {
        let ended = duckEnded
        return HostVoice.cancelReason(HostVoice.Running(
            enabled: endless.spokenNotesEnabled,
            endless: endless.isActive,
            notesOn: endless.hostNotesEnabled,
            songChanged: engine.hostQueueSongId != songId,
            playing: engine.hostIsPlaying && !pausedByEvent,
            transitionRunning: engine.isTransitionRunning || ended == "transition",
            focusLost: ended == "interruption" || ended == "reset",
            inCall: inCall(),
            routeChanged: routeChangedAtSpeech,
            volumeTaken: ended != nil && ended != "interruption" && ended != "reset" && ended != "transition",
            sinceSpeechStartMs: sinceSpeechStartMs))
    }

    /// The duck ended on its own (a crossfade, an interruption, a rebuilt deck): the line stops this instant.
    private func duckEndedOnItsOwn(_ reason: String) {
        duckEnded = reason
        if speaking { speaker.stop() }
    }

    private func cancelNow(_ reason: String) {
        guard speaking else { return }
        if reason == "pause" { pausedByEvent = true }
        speaker.stop()
    }

    // MARK: The world: calls and the audio route

    /// A call that has not ended. The audio interruption notification covers a call that takes the audio session; this covers one that
    /// does not (a call on another route) while a note is due.
    private func inCall() -> Bool { callObserver.calls.contains { !$0.hasEnded } }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        // A device came or went (headphones, Bluetooth, AirPlay); the other reasons (a category change, a sample rate) are not a new route.
        guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
        lastRouteChangeMs = Self.nowMs()
        if speaking {
            routeChangedAtSpeech = true
            speaker.stop()
        }
    }

    private func interruptionBegan() {
        // A call or an alarm: the system has paused the music already; the line goes with it.
        engine?.hostDuck.abort(reason: "interruption")
        if speaking {
            pausedByEvent = true
            speaker.stop()
        }
    }

    // MARK: "Test the voice" and the log

    /// Says a short sample so the person hears the voice: the one place the system voice is started because the person asked. Brings the
    /// music down like a note does when it can, and does not touch it otherwise. Never over a call; refused while a note is being said.
    func testVoice() async -> TestResult {
        if speaking || testing { return .busy }
        if inCall() { return .inCall }
        testing = true
        defer {
            testing = false
            // The voice is given back unless the host is armed and may use it.
            if !armed { speaker.shutdown() }
        }
        let line = HostVoice.line(EndlessStrings.voiceTestLine)
        speaker.ensure()
        guard speaker.voiceState == HostVoice.voiceReady, !line.isEmpty else {
            record(spoke: false, cancelled: false, reason: "no_voice", text: "test")
            return .noVoice
        }
        var ducked = false
        if let engine, engine.hostCanDuck, engine.hostDuck.begin() {
            ducked = true
            try? await Task.sleep(for: .milliseconds(HostVoice.rampDownMs))
        }
        speaker.speak(line)
        let deadline = Self.nowMs() + HostVoice.maxSpeechMs
        while speaker.isSpeaking, Self.nowMs() < deadline {
            try? await Task.sleep(for: .milliseconds(Self.pollMs))
        }
        let finished = !speaker.isSpeaking && speaker.lastOutcome == .done
        speaker.stop()
        if ducked { engine?.hostDuck.end(quick: !finished) }
        record(spoke: finished, cancelled: false, reason: "test", text: line)
        return finished ? .spoke : .error
    }

    private func record(spoke: Bool, cancelled: Bool, reason: String, text: String) {
        let entry = HostVoiceLogEntry(atMs: currentTimeMillis(), spoke: spoke, cancelled: cancelled, reason: reason,
                                      text: String(text.prefix(Self.logTextChars)))
        log = HostVoiceLog.add(log, entry)
    }

    // MARK: Numbers

    private static let pollMs = 100
    private static let longAgoMs: Int64 = 3_600_000
    private static let logTextChars = 80

    /// A monotonic clock in milliseconds (never the wall clock: a change of time zone or a clock correction must not move a decision).
    private static func nowMs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
}

/// The call observer's delegate: it does nothing. `CXCallObserver.calls` is read when a note is due; the delegate only has to exist.
nonisolated final class HostCallWatcher: NSObject, CXCallObserverDelegate, @unchecked Sendable {
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {}
}
