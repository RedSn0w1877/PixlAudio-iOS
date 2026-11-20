import Foundation
import Observation
import PixlFoundation
import PixlLibrary
import PixlModel

/// Song Tap's controller (the Android `SongTapStateHolder`, a process-wide state holder): the decisions are in
/// `SongTapEngine` (PixlCore, tested without a phone); this class is its coroutines: it gives the engine a clock, timers,
/// haptics, the library and the transports, and shows the engine's state to SwiftUI.
///
/// Nothing runs until the Song Tap screen arms it, and `disarm` stops everything: no camera, scanning or advertising outside
/// the screen, and none while PixlAudio is in the background.
@MainActor
@Observable
final class SongTapController: SongTapPort {
    /// What the screen draws.
    private(set) var ui = SongTapUiState()
    /// The vibration the screen performs next (it owns the user's Haptic feedback setting): bumps `hapticSerial` each time.
    private(set) var hapticCue: SongTapHapticCue = .tick
    private(set) var hapticSerial = 0

    let settings: SongTapSettings

    @ObservationIgnored private let engine = SongTapEngine()
    @ObservationIgnored private let receiver: SongTapReceiver
    @ObservationIgnored private let sender: SongTapSender
    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let qr: SongTapQrTransport
    @ObservationIgnored private var transport: any SongTapTransport
    @ObservationIgnored private var timeouts: [SongTapTimeoutTag: Task<Void, Never>] = [:]
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingTask: Task<Void, Never>?

    init(settings: SongTapSettings, receiver: SongTapReceiver, sender: SongTapSender, playback: PlaybackStore) {
        self.settings = settings
        self.receiver = receiver
        self.sender = sender
        self.playback = playback
        let qr = SongTapQrTransport()
        self.qr = qr
        transport = qr
        engine.port = self
        qr.onEvent = { [weak self] event in self?.engine.handle(event) }
        engine.setAllowed(settings.allowed)
    }

    // MARK: What the listener does

    var allowed: Bool { settings.allowed }

    func setAllowed(_ on: Bool) {
        settings.allowed = on
        engine.setAllowed(on)
    }

    func arm(_ role: SongTapRole) {
        engine.setAllowed(settings.allowed)
        engine.arm(role, askFirst: settings.firstBeamAsks)
    }

    func disarm() {
        engine.disarm()
        nowPlayingTask?.cancel()
    }

    func switchRole(_ role: SongTapRole) {
        refreshTask?.cancel()
        engine.switchRole(role)
    }

    /// The song that is playing changed (or the screen opened): the Send side shows it, and says when it cannot be shared.
    func nowPlayingChanged(_ song: Song?) {
        nowPlayingTask?.cancel()
        guard let song else { engine.setNowPlaying(nil); return }
        nowPlayingTask = Task { [sender] in
            let payload = await sender.payload(for: song, nowMs: currentTimeMillis())
            guard !Task.isCancelled else { return }
            engine.setNowPlaying(SongTapNowPlaying(title: song.title, artist: song.artist, artUrl: song.albumArtUriString,
                                                   canSend: payload != nil))
        }
    }

    /// Sender: put the song that is playing up as a code.
    func showCode() {
        let song = playback.current
        Task { [sender] in
            let payload: SongTapPayload?
            if let song { payload = await sender.payload(for: song, nowMs: currentTimeMillis()) } else { payload = nil }
            engine.showCode(payload)
            if payload != nil, let song { startRefresh(song) }
        }
    }

    func hideCode() {
        refreshTask?.cancel()
        engine.hideCode()
    }

    /// The camera read `text`.
    func scanned(_ text: String) { engine.scanned(text) }

    func accept() { engine.accept() }
    func decline() { engine.decline() }
    func undo() { engine.undo() }
    func cancel() { engine.cancel() }
    func dismiss() { engine.dismiss() }

    // MARK: SongTapPort

    func nowMs() -> Int64 { currentTimeMillis() }

    func startTransport(_ role: SongTapRole) { transport.start(role: role) }
    func stopTransport() { transport.stop() }
    func publishOffer(peer: Int, payload: [UInt8]) { transport.publishOffer(peer: peer, payload: payload) }
    func withdrawOffer() { transport.withdrawOffer() }
    func readOffer(peer: Int) { transport.readOffer(peer: peer) }
    func sendAck(peer: Int) { transport.sendAck(peer: peer) }
    func sendGo(peer: Int, startMs: Int64) { transport.sendGo(peer: peer, startMs: startMs) }
    func sendDecline(peer: Int) { transport.sendDecline(peer: peer) }
    func abortTransfer(peer: Int) { transport.abort(peer: peer) }

    func save(_ payload: SongTapPayload) {
        // The import is not interrupted half way: whatever happens to the session meanwhile, the engine is told how it ended
        // and takes the song back if nobody waits for it any more.
        Task { [receiver] in
            let result = await receiver.save(payload)
            engine.saveFinished(result, for: payload)
        }
    }

    func cancelSave() {}

    func undoSave(videoId: String) {
        Task { [receiver] in _ = await receiver.undo(videoId: videoId) }
    }

    func haptic(_ cue: SongTapHapticCue) {
        hapticCue = cue
        hapticSerial += 1
    }

    func schedule(_ tag: SongTapTimeoutTag, afterMs: Int64) {
        timeouts[tag]?.cancel()
        timeouts[tag] = Task {
            try? await Task.sleep(for: .milliseconds(afterMs))
            guard !Task.isCancelled else { return }
            engine.timeout(tag)
        }
    }

    func scheduleDismiss(afterMs: Int64) {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .milliseconds(afterMs))
            guard !Task.isCancelled else { return }
            engine.dismissTimerFired()
        }
    }

    func cancelDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    func scheduleInvalidNoticeClear(afterMs: Int64) {
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .milliseconds(afterMs))
            guard !Task.isCancelled else { return }
            engine.clearInvalidCodeNotice()
        }
    }

    func cancelTimers() {
        for task in timeouts.values { task.cancel() }
        timeouts.removeAll()
        dismissTask?.cancel()
        dismissTask = nil
        noticeTask?.cancel()
        noticeTask = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func markFirstBeamAccepted() { settings.markFirstBeamAccepted() }

    func uiChanged(_ ui: SongTapUiState) { self.ui = ui }

    // MARK: The code's refresh

    /// A code expires after five minutes; while it is up, make a fresh one every four.
    private func startRefresh(_ song: Song) {
        refreshTask?.cancel()
        refreshTask = Task { [sender] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(SongTapEngine.qrRefreshMs))
                guard !Task.isCancelled, ui.session.phase == .offered else { return }
                let fresh = await sender.payload(for: song, nowMs: currentTimeMillis())
                guard !Task.isCancelled else { return }
                engine.refreshCode(fresh)
            }
        }
    }
}

/// The one controller of the process (Android's `@Singleton` state holder). It is made on first use, so nothing about Song
/// Tap exists at app start.
@MainActor
enum SongTapHub {
    private static var controller: SongTapController?

    static func controller(for env: AppEnvironment) -> SongTapController {
        if let controller { return controller }
        let library = env.library, persistence = env.persistence, launch = env.launch
        let editor = { LibraryEditor(store: library, persistence: persistence, writesCache: !launch.isUITest) }
        let importer = YouTubeLibraryImporter(library: library, persistence: persistence, writesCache: !launch.isUITest)
        let songLibrary = AppSongTapLibrary(library: library, persistence: persistence, importer: importer, editor: editor,
                                            search: env.spotify.bridge.search)
        let made = SongTapController(settings: SongTapSettings(), receiver: SongTapReceiver(library: songLibrary),
                                     sender: SongTapSender(ids: AppSongTapSongIds(persistence: persistence)), playback: env.playback)
        controller = made
        return made
    }
}

extension AppEnvironment {
    /// Song Tap's controller, made on first use.
    var songTap: SongTapController { SongTapHub.controller(for: self) }
}
