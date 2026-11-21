import AVFoundation
import Foundation
import PixlLibrary

/// The voice the host of Endless Listening speaks with: the system's own `AVSpeechSynthesizer`, nothing bundled, no network (the system
/// lists only voices that are installed).
///
/// Lazy by construction: nothing here exists until `ensure()` is called, and that is called only when "Spoken host notes" is on and a note
/// has a line to say, or when the person asks to test the voice. `shutdown()` gives the synthesizer back.
///
/// Which voice: the notes are English text, so an English voice is asked for (`HostVoiceChoice`, tested in PixlLibrary: the listener's own
/// English first, else US English). With none installed the host stays silent and the log says `no_voice`.
///
/// The audio session is not touched. The synthesizer plays through the app's own session (`usesApplicationAudioSession` is left on), so
/// there is no `.duckOthers`, no category change and no activation of its own: either would stop the music. The music is brought down by
/// `HostDuck` instead. Main actor only; the synthesizer's callbacks hop onto it.
@MainActor
final class HostSpeaker {
    /// How a line ended.
    enum Outcome: Sendable { case done, stopped, error }

    private var synthesizer: AVSpeechSynthesizer?
    private var voice: AVSpeechSynthesisVoice?
    private var current: ObjectIdentifier?
    private var utterance: AVSpeechUtterance?
    private let relay = HostSpeechRelay()

    /// True from `speak` until the line ended or was stopped.
    private(set) var isSpeaking = false
    /// How the last line ended (read when `isSpeaking` turned false).
    private(set) var lastOutcome: Outcome = .stopped
    /// True once `ensure()` was asked and it found no usable voice. Cleared by `shutdown()`.
    private(set) var unavailable = false

    /// `HostVoice.voiceNone` before `ensure()` and when no usable voice exists; `HostVoice.voiceReady` after it found one.
    var voiceState: Int { synthesizer != nil && voice != nil ? HostVoice.voiceReady : HostVoice.voiceNone }

    init() {
        relay.onEnd = { [weak self] id, cancelled in
            Task { @MainActor in self?.ended(id, cancelled: cancelled) }
        }
    }

    /// Creates the synthesizer and picks the voice, if that was not done. Cheap to call again.
    func ensure() {
        guard synthesizer == nil, !unavailable else { return }
        let candidates = AVSpeechSynthesisVoice.speechVoices().map { v in
            HostVoiceChoice.Candidate(identifier: v.identifier, language: v.language, quality: Self.rank(v.quality),
                                      isNovelty: v.voiceTraits.contains(.isNoveltyVoice),
                                      isPersonal: v.voiceTraits.contains(.isPersonalVoice))
        }
        guard let id = HostVoiceChoice.pick(candidates, preferredLanguages: Locale.preferredLanguages),
              let chosen = AVSpeechSynthesisVoice(identifier: id) else {
            unavailable = true
            return
        }
        let made = AVSpeechSynthesizer()
        made.delegate = relay
        synthesizer = made
        voice = chosen
    }

    /// Starts saying `line`. A line already running is stopped first.
    func speak(_ line: String) {
        guard let synthesizer, let voice, !line.isEmpty else {
            lastOutcome = .error
            isSpeaking = false
            return
        }
        if isSpeaking { stop() }
        let u = AVSpeechUtterance(string: line)
        u.voice = voice
        u.prefersAssistiveTechnologySettings = false
        u.preUtteranceDelay = 0
        u.postUtteranceDelay = 0
        utterance = u
        current = ObjectIdentifier(u)
        isSpeaking = true
        lastOutcome = .stopped
        synthesizer.speak(u)
    }

    /// Stops the line at once (a skip, a pause, a call, a route change). Safe when nothing is said.
    func stop() {
        guard isSpeaking else { return }
        synthesizer?.stopSpeaking(at: .immediate)
        // The delegate says so as well; the line is over for the caller now.
        isSpeaking = false
        lastOutcome = .stopped
        current = nil
        utterance = nil
    }

    /// Gives the synthesizer back (the switch went off, Endless Listening stopped).
    func shutdown() {
        stop()
        synthesizer?.delegate = nil
        synthesizer = nil
        voice = nil
        unavailable = false
    }

    private func ended(_ id: ObjectIdentifier, cancelled: Bool) {
        guard id == current else { return }   // an older line's end never ends a newer line
        isSpeaking = false
        lastOutcome = cancelled ? .stopped : .done
        current = nil
        utterance = nil
    }

    private static func rank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: 2
        case .enhanced: 1
        default: 0
        }
    }
}

/// Receives the synthesizer's callbacks (any thread) and hands them to the main actor.
nonisolated final class HostSpeechRelay: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    /// Set once, before the delegate is installed: which line ended, and whether it was cut short.
    var onEnd: (@Sendable (ObjectIdentifier, Bool) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onEnd?(ObjectIdentifier(utterance), false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onEnd?(ObjectIdentifier(utterance), true)
    }
}
