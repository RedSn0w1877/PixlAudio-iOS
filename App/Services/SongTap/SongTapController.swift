import Foundation
import Observation
import PixlFoundation
import PixlLibrary
import PixlModel
import UIKit

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

    /// Sender: which code is on screen (the ring code, or the plain QR as the last resort), the ring code's dots (a new one with a fresh
    /// tag every minute), and why a QR came up by itself.
    private(set) var codeKind: RingCodeKind?
    private(set) var ringSlots: RingCodeSlots?
    private(set) var ringNote: RingSendNote?
    /// Receiver: what the ring scan is doing, and whether "Use QR code instead" is on offer.
    private(set) var ringScan = RingScanView.idle

    let settings: SongTapSettings

    @ObservationIgnored private let engine = SongTapEngine()
    @ObservationIgnored private let receiver: SongTapReceiver
    @ObservationIgnored private let sender: SongTapSender
    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let qr: SongTapQrTransport
    /// The Bluetooth route (PixlCore): it makes no manager, scans nothing and listens to no sensor until the screen arms it.
    @ObservationIgnored let ble: SongTapBleRoute
    /// The numbers behind the tap detector, for Developer mode's Song Tap diagnostics.
    @ObservationIgnored let diagnostics = SongTapDiagnostics()
    /// The approach glow (0...500 permille), in a small model of its own so a signal reading redraws only the glow.
    let glow = SongTapGlowModel()
    @ObservationIgnored private var timeouts: [SongTapTimeoutTag: Task<Void, Never>] = [:]
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingTask: Task<Void, Never>?
    @ObservationIgnored private var beamTask: Task<Void, Never>?
    @ObservationIgnored private var showCodeTask: Task<Void, Never>?
    @ObservationIgnored private var approveTask: Task<Void, Never>?
    @ObservationIgnored private var targetRefreshTask: Task<Void, Never>?
    /// The ring code receiver's rules over time (three reads, the freshness and replay guard, when the QR is offered), in PixlCore.
    @ObservationIgnored private let ringSession: RingScanSession
    @ObservationIgnored private var ringTickTask: Task<Void, Never>?
    /// The numbers behind the ring scanner, for Developer mode's Ring code diagnostics: copies pictures only while that screen is open.
    @ObservationIgnored let ringDiagnostics = RingCodeDiagnostics()
    /// The sender chose "Use QR code instead": a rebuilt code stays a QR until the listener leaves.
    @ObservationIgnored private var qrPreferred = false
    @ObservationIgnored private var ringSerial = 0
    /// The song that plays, as the Song Tap screen last heard of it.
    @ObservationIgnored private var playingSong: Song?
    /// Song Drop: the song picked from a song's options is what is offered, instead of the one that plays, until the screen is left.
    @ObservationIgnored private var dropSong: Song?

    init(settings: SongTapSettings, receiver: SongTapReceiver, sender: SongTapSender, playback: PlaybackStore,
         ringLookup: any RingCodeLookup) {
        self.settings = settings
        ringSession = RingScanSession(lookup: ringLookup, clock: { currentTimeMillis() })
        self.receiver = receiver
        self.sender = sender
        self.playback = playback
        let qr = SongTapQrTransport()
        self.qr = qr
        ble = SongTapBleRoute(
            radio: SongTapBluetoothRadio(), impulses: SongTapMotionSource(), clock: SongTapSystemClock(), diag: diagnostics,
            scheduler: SongTapTaskScheduler(), newSigner: { SongTapSigner() }, verifier: SongTapVerifier(),
            random: { count in
                var generator = SystemRandomNumberGenerator()
                return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
            })
        engine.port = self
        qr.onEvent = { [weak self] event in self?.engine.handle(event) }
        ble.onEvent = { [weak self] event in self?.engine.handle(event) }
        ble.onStatusChange = { [weak self] status in self?.engine.setBluetooth(status) }
        ble.onGlowChange = { [weak self] value in self?.glow.value = value }
        ble.onNearbyChange = { [weak self] list, ask in self?.engine.setNearby(list, prompt: ask) }
        ble.setOwnName(settings.name)
        ble.setSensitivity(settings.sensitivity)
        engine.setSensitivity(settings.sensitivity)
        engine.setAllowed(settings.allowed)
        ringSession.onView = { [weak self] view in self?.ringScan = view }
        // The song a ring code named goes through the same consent, save and Undo as every other beam.
        ringSession.onSong = { [weak self] song in self?.engine.ringOffer(song) }
    }

    /// A code has no peer (0); a phone found over Bluetooth has a number.
    private func transport(for peer: Int) -> any SongTapTransport { peer == 0 ? qr : ble }

    // MARK: What the listener does

    var allowed: Bool { settings.allowed }

    func setAllowed(_ on: Bool) {
        settings.allowed = on
        engine.setAllowed(on)
    }

    func arm(_ role: SongTapRole) {
        engine.setAllowed(settings.allowed)
        // The name and the sensitivity are read when the radio starts (and the sensitivity again whenever it changes).
        ble.setOwnName(settings.name)
        ble.setSensitivity(settings.sensitivity)
        engine.setSensitivity(settings.sensitivity)
        engine.arm(role, askFirst: settings.firstBeamAsks)
    }

    func disarm() {
        engine.disarm()
        qrPreferred = false
        ringScanStop()
        showCodeTask?.cancel()
        showCodeTask = nil
        nowPlayingTask?.cancel()
        approveTask?.cancel()
        approveTask = nil
        targetRefreshTask?.cancel()
        targetRefreshTask = nil
    }

    // MARK: Settings: your name, sensitivity

    var name: String { settings.name }

    func setName(_ raw: String) {
        settings.setName(raw)
        ble.setOwnName(settings.name)
    }

    var sensitivity: SongTapSensitivity { settings.sensitivity }

    /// Normal or High, saved and applied live to the detector and the jerk threshold.
    func setSensitivity(_ value: SongTapSensitivity) {
        settings.setSensitivity(value)
        ble.setSensitivity(value)
        engine.setSensitivity(value)
    }

    // MARK: Song Drop

    /// The song a sender offers: the one picked for Song Drop, else the one that plays.
    private var offeredSong: Song? { dropSong ?? playingSong }

    /// A song's options raised "Song Drop": that song is what is offered, and the Song Tap screen opens on Send.
    func beginSongDrop(_ song: Song) {
        dropSong = song
        engine.setDropMode(true)
        nowPlayingChanged(playingSong)
    }

    /// The Song Tap screen was left (a Song Drop song is for the screen that was open), or opened without a song of its own: the song
    /// that plays is offered again. Not part of `disarm`: the app going inactive for a moment (the system's Bluetooth question) must
    /// not take the picked song away.
    func endSongDrop() {
        guard dropSong != nil else { return }
        dropSong = nil
        engine.setDropMode(false)
        nowPlayingChanged(playingSong)
    }

    /// "Song drop to X?" answered yes for the phone `peer` (a number from the nearby list or the prompt): the offer is published for
    /// that phone only, and the beam starts when the two phones touch.
    func approve(peer: Int, name: String) {
        approveTask?.cancel()
        let song = offeredSong
        approveTask = Task { [sender, engine] in
            let payload: SongTapPayload?
            if let song { payload = await sender.payload(for: song, nowMs: currentTimeMillis()) } else { payload = nil }
            guard !Task.isCancelled else { return }
            engine.approve(peer: peer, name: name, payload: payload)
            if payload != nil { startTargetRefresh() }
        }
    }

    /// "No": that phone is not asked about for a minute.
    func decideNo(peer: Int) { ble.ignorePrompt(peer) }

    /// Stop being armed to the phone that was said yes to.
    func cancelDrop() {
        approveTask?.cancel()
        targetRefreshTask?.cancel()
        targetRefreshTask = nil
        engine.cancelDrop()
    }

    /// The offer a sender holds for a phone carries a time: while armed it is made again every `SongTapEngine.targetRefreshMs`.
    private func startTargetRefresh() {
        targetRefreshTask?.cancel()
        targetRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(SongTapEngine.targetRefreshMs))
                guard !Task.isCancelled, let self else { return }
                guard ui.session.phase == .offered, ui.session.target != 0 else { return }
                await republishTarget()
            }
        }
    }

    private func republishTarget() async {
        guard let song = offeredSong else { return }
        let payload = await sender.payload(for: song, nowMs: currentTimeMillis())
        guard !Task.isCancelled else { return }
        engine.republish(payload)
    }

    func switchRole(_ role: SongTapRole) {
        refreshTask?.cancel()
        showCodeTask?.cancel()
        engine.switchRole(role)
    }

    /// The song that is playing changed (or the screen opened): the Send side shows it, and says when it cannot be shared.
    func nowPlayingChanged(_ playing: Song?) {
        playingSong = playing
        nowPlayingTask?.cancel()
        // The song shown is the one that is offered: a Song Drop song stays on screen whatever plays.
        guard let song = offeredSong else { engine.setNowPlaying(nil); return }
        // A code that is up is for the song that plays: when the track changes, the code changes with it.
        if ui.session.role == .send, ui.session.phase == .offered, ui.session.peer == 0, ui.code != nil {
            hideCode(keepQrChoice: true)
            showCode()
        }
        // A phone the listener said yes to is offered the new song at once (not at the next refresh).
        if ui.session.role == .send, ui.session.phase == .offered, ui.session.target != 0, dropSong == nil {
            Task { await republishTarget() }
        }
        nowPlayingTask = Task { [sender] in
            let payload = await sender.payload(for: song, nowMs: currentTimeMillis())
            guard !Task.isCancelled else { return }
            engine.setNowPlaying(SongTapNowPlaying(title: song.title, artist: song.artist, artUrl: song.albumArtUriString,
                                                   canSend: payload != nil))
        }
    }

    /// Sender: put the song that is playing up as a code. A song with a video id gets the Pixl ring code, made again with a fresh tag every
    /// minute. A song that was never matched to a video has nothing the ring code could carry, so it goes straight to the QR code and the
    /// screen says why (`ringNote`).
    func showCode() {
        let song = offeredSong
        showCodeTask?.cancel()
        showCodeTask = Task { [sender] in
            let payload: SongTapPayload?
            if let song { payload = await sender.payload(for: song, nowMs: currentTimeMillis()) } else { payload = nil }
            // Hiding the code (or leaving Send) while the payload was being made cancels this: the session must not be put
            // into "offered" with nothing on screen to answer it.
            guard !Task.isCancelled else { return }
            let plan = RingSendPlan.of(videoId: payload?.ytVideoId, qrPreferred: qrPreferred)
            codeKind = payload == nil ? nil : plan.kind
            ringNote = payload == nil ? nil : plan.note
            ringSlots = nil
            if payload != nil, plan.kind == .ring, let video = payload?.ytVideoId { makeRing(video) }
            engine.showCode(payload)
            if payload != nil {
                if plan.kind == .ring { startRingRefresh() } else { startRefresh() }
            }
        }
    }

    /// The listener is done with the code (or the song changed under it: then the choice of QR is kept).
    func hideCode(keepQrChoice: Bool = false) {
        if !keepQrChoice { qrPreferred = false }
        refreshTask?.cancel()
        showCodeTask?.cancel()
        showCodeTask = nil
        engine.hideCode()
    }

    /// "Use QR code instead": the ring code gives way to the plain QR code for the same song. Offered by the screen after the code has been
    /// up for six seconds without being taken; the two are never shown together.
    func showQrInstead() {
        guard ui.session.role == .send, ui.session.phase == .offered, ui.session.peer == 0, let song = offeredSong else { return }
        qrPreferred = true
        refreshTask?.cancel()
        codeKind = .qr
        ringSlots = nil
        refreshTask = Task { [sender] in
            guard let fresh = await sender.payload(for: song, nowMs: currentTimeMillis()), !Task.isCancelled else { return }
            engine.refreshCode(fresh)
            startRefresh()
        }
    }

    /// A ring code for `videoId` with a fresh tag: this minute's bucket and a random byte.
    private func makeRing(_ videoId: String) {
        var generator = SystemRandomNumberGenerator()
        let random = Int(UInt8.random(in: 0...255, using: &generator))
        guard let bits = RingCodePayloads.encodeSlots(videoId: videoId, minuteBucket: RingCodePayloads.bucketOf(nowMs: currentTimeMillis()),
                                                      random: random) else { return }
        ringSerial += 1
        ringSlots = RingCodeSlots(bits: bits, serial: ringSerial)
    }

    /// While a ring code is up it is made again with a fresh tag every `RingSendRules.codeLifeMs`, for the song that plays at that moment.
    private func startRingRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self, sender] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(RingSendRules.codeLifeMs))
                guard !Task.isCancelled, let self else { return }
                guard ui.session.phase == .offered, ui.session.peer == 0, codeKind == .ring, let song = offeredSong else { return }
                let video = await sender.payload(for: song, nowMs: currentTimeMillis())?.ytVideoId
                guard !Task.isCancelled, RingSendRules.canRing(video), let video else { return }
                makeRing(video)
            }
        }
    }

    // MARK: The ring code, receiving

    /// Where the ring camera's queue reports: the diagnostics (which copies only while its screen is open) and the scan itself.
    var ringSink: RingCodeCamera.Sink {
        let diagnostics = ringDiagnostics
        var sink = RingCodeCamera.Sink()
        sink.onFrame = { now in diagnostics.onFrame(nowMs: now) }
        sink.onScan = { [weak self] frame, result, details, rotation, now in
            diagnostics.record(frame: frame, result: result, diagnostics: details, rotationDegrees: rotation, nowMs: now)
            Task { @MainActor in self?.ringScanned(result) }
        }
        sink.onSlow = { [weak self] in
            diagnostics.onSlow()
            Task { @MainActor in self?.ringSession.scannerTooSlow() }
        }
        sink.onFailed = { [weak self] in Task { @MainActor in self?.ringSession.cameraFailed() } }
        return sink
    }

    /// The receiver opened the camera for a ring code. `cameraAvailable` is false on a phone with no camera.
    func ringScanStart(cameraAvailable: Bool) {
        ringSession.start(cameraAvailable: cameraAvailable)
        ringTickTask?.cancel()
        ringTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(RingScanSession.tickMs))
                self?.ringSession.tick()
            }
        }
    }

    /// The camera closed (the screen was left, the listener went back, or a code was taken).
    func ringScanStop() {
        ringTickTask?.cancel()
        ringTickTask = nil
        ringSession.stop()
    }

    /// One scanner result (handed over from the camera's queue). Three equal fresh decodes in a row start the lookup of the song.
    private func ringScanned(_ result: RingScanResult) {
        guard ui.session.role == .receive else { return }
        ringSession.offer(result)
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

    func startTransport(_ role: SongTapRole) {
        qr.start(role: role)
        ble.start(role: role)
    }

    func stopTransport() {
        qr.stop()
        ble.stop()
    }

    func publishOffer(peer: Int, payload: [UInt8]) { transport(for: peer).publishOffer(peer: peer, payload: payload) }

    /// A sender keeps its Bluetooth offer through the beam (`keepBluetooth`): the receiver's answer is still matched to the phone that read it.
    func withdrawOffer(keepBluetooth: Bool) {
        qr.withdrawOffer()
        if !keepBluetooth { ble.withdrawOffer() }
    }

    func readOffer(peer: Int) { transport(for: peer).readOffer(peer: peer) }
    func sendAck(peer: Int) { transport(for: peer).sendAck(peer: peer) }
    func sendDecline(peer: Int) { transport(for: peer).sendDecline(peer: peer) }
    func abortTransfer(peer: Int) { transport(for: peer).abort(peer: peer) }

    func resync() { ble.resync() }

    func reducedMotion() -> Bool { UIAccessibility.isReduceMotionEnabled }

    func scheduleBeamEnd(afterMs: Int64?) {
        beamTask?.cancel()
        beamTask = nil
        guard let afterMs else { return }
        beamTask = Task {
            try? await Task.sleep(for: .milliseconds(afterMs))
            guard !Task.isCancelled else { return }
            engine.beamTimerFired()
        }
    }

    /// The beam's own vibrations, on the beam's clock; the screen runs this for as long as a beam plays.
    func playBeamCues(role: SongTapRole, startMs: Int64, reduced: Bool) async {
        for timed in SongTapHaptics.cues(role: role, reducedMotion: reduced) {
            let wait = startMs + timed.tMs - currentTimeMillis()
            if wait < -120 { continue }
            if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
            if Task.isCancelled { return }
            haptic(timed.cue)
        }
    }

    /// Developer mode diagnostics: write the current signal into the log under `label` ("touching", "1 cm"...).
    func mark(_ label: String) { ble.mark(label) }

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
        targetRefreshTask?.cancel()
        targetRefreshTask = nil
    }

    func markFirstBeamAccepted() { settings.markFirstBeamAccepted() }

    func uiChanged(_ ui: SongTapUiState) {
        self.ui = ui
        // The ring code is on screen only while a code offer is on the table.
        if codeKind != nil, ui.session.phase != .offered || ui.session.target != 0 {
            codeKind = nil
            ringSlots = nil
            ringNote = nil
        }
    }

    // MARK: The code's refresh

    /// A code expires after five minutes; while it is up, make a fresh one every four.
    private func startRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [sender] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(SongTapEngine.qrRefreshMs))
                // The song that is offered at that moment, not the one the code was first made for.
                guard !Task.isCancelled, ui.session.phase == .offered, let song = offeredSong else { return }
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
                                     sender: SongTapSender(ids: AppSongTapSongIds(persistence: persistence)), playback: env.playback,
                                     ringLookup: AppRingCodeLookup(source: env.youtube.radioSource))
        controller = made
        return made
    }
}

extension AppEnvironment {
    /// Song Tap's controller, made on first use.
    var songTap: SongTapController { SongTapHub.controller(for: self) }
}

/// The approach glow's strength, 0...500 permille, from the smoothed signal of the phone coming closer. Its own small model, so
/// the screen's body does not re-run for every signal reading.
@MainActor
@Observable
final class SongTapGlowModel {
    var value = 0
}
