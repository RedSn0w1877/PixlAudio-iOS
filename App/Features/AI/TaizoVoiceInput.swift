import AVFoundation
import Speech
import SwiftUI

/// Ask Taizo's mic (redesign 2, Android `TaizoInputPills`: the mic shows while the field is empty and the phone has a
/// recognizer; what is said is sent). Android hands off to the system recognizer, which takes audio focus for a moment;
/// here the speech recognizer listens through the microphone: playback pauses while it listens and resumes after, and
/// the audio session goes back to `.playback` + long-form (`AudioSessionController.configure`).
///
/// Listening ends by itself when the recognizer has a final result (a pause in speech) or after `maxSeconds`, or with a
/// second tap. Nothing runs until the mic is tapped; permissions are asked for on that first tap.
@Observable
final class TaizoVoiceInput {
    private(set) var isListening = false
    /// What has been heard so far (shown in the field while listening).
    private(set) var transcript = ""

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var onFinish: ((String) -> Void)?
    @ObservationIgnored private var resumeAfter: (() -> Void)?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    private static let maxSeconds: Double = 12

    /// True when the phone can turn speech into text for the current language (Android: a recognizer is installed).
    static var isAvailable: Bool {
        SFSpeechRecognizer()?.isAvailable ?? false
    }

    /// Starts listening; `onFinish` gets the text (not called when nothing was heard). `pausePlayback` runs before the
    /// microphone opens and returns how to resume, or nil when nothing was playing.
    func start(pausePlayback: () -> (() -> Void)?, onFinish: @escaping (String) -> Void) async {
        guard !isListening else { return }
        guard await Self.authorize(), let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return }
        self.onFinish = onFinish
        resumeAfter = pausePlayback()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            finish(send: false)
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            finish(send: false)
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(request))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            finish(send: false)
            return
        }
        self.engine = engine
        self.request = request
        transcript = ""
        isListening = true
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] text, isFinal, failed in
            guard let self, self.isListening else { return }
            if let text { self.transcript = text }
            if isFinal || failed { self.finish(send: true) }
        })
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxSeconds))
            guard !Task.isCancelled else { return }
            self?.finish(send: true)
        }
    }

    /// The second tap: stops listening and sends what was heard.
    func stop() {
        finish(send: true)
    }

    private func finish(send: Bool) {
        timeout?.cancel()
        timeout = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        request?.endAudio()
        task?.cancel()
        engine = nil
        request = nil
        task = nil
        let wasListening = isListening
        isListening = false
        // Back to the player's session (`AudioSessionController.configure`).
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        } catch {
            try? session.setCategory(.playback, mode: .default, options: [])
        }
        resumeAfter?()
        resumeAfter = nil
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let callback = onFinish
        onFinish = nil
        transcript = ""
        if send, wasListening, !text.isEmpty { callback?(text) }
    }

    // MARK: Off the main actor

    /// The microphone tap runs on the audio thread: built here, outside the main actor, so it carries no isolation.
    nonisolated private static func tapBlock(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        // The request is only appended to from this one thread until `endAudio`.
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    /// The recognizer answers on its own queue: the values are copied and handed to the main actor.
    nonisolated private static func resultHandler(
        _ deliver: @escaping @MainActor @Sendable (String?, Bool, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in deliver(text, isFinal, failed) }
        }
    }

    /// Outside the main actor: the permission callbacks arrive on other queues.
    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
