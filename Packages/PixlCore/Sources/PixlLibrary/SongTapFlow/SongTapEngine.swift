// Song Tap's controller logic, as far as it can be decided without a phone: it owns the session state machine, feeds it
// what the transports and the listener do, and carries out what the state machine asks for through a small port (timers,
// transports, haptics, the library) that the app implements. The Android `SongTapStateHolder` split the same way: this
// file is its decisions, the app's `SongTapController` is its coroutines.
//
// Single-threaded by design: the app calls it from the main actor only.

/// The song that is playing, as the Send side shows it.
public struct SongTapNowPlaying: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var artUrl: String?
    public var canSend: Bool

    public init(title: String, artist: String, artUrl: String?, canSend: Bool) {
        self.title = title
        self.artist = artist
        self.artUrl = artUrl
        self.canSend = canSend
    }
}

/// Why the last attempt did not go through, as something the screen can word.
public enum SongTapNotice: String, Sendable, CaseIterable {
    case invalidCode, nothingToSend, notFound, saveFailed, timeout, tooSoon, limit, duplicate, muted, bothSending, peerLost, invalidOffer

    public static func of(_ reason: SongTapFailReason) -> SongTapNotice {
        switch reason {
        case .nothingToSend: .nothingToSend
        case .bothSending: .bothSending
        case .peerLost: .peerLost
        case .timeout: .timeout
        case .invalidOffer: .invalidOffer
        case .notFound: .notFound
        case .saveFailed: .saveFailed
        case .tooSoon: .tooSoon
        case .limit: .limit
        case .duplicate: .duplicate
        case .muted: .muted
        }
    }
}

/// What the Song Tap screen draws.
public struct SongTapUiState: Sendable, Equatable {
    /// "Allow Song Tap" is on.
    public var allowed = false
    public var session = SongTapSessionState.initial()
    public var nowPlaying: SongTapNowPlaying?
    /// The text of the QR code while the sender shows one.
    public var code: String?
    /// The song on the table: the offer waiting for Add / Not now, or what was just saved.
    public var card: SongTapCard?
    public var notice: SongTapNotice?
    /// When the animation of the current beam starts on this phone's clock, and which side it plays.
    public var beamStartMs: Int64 = 0
    public var beamRole: SongTapRole?
    /// The current beam plays the short cross-fade (Reduce Motion is on), not the flight.
    public var beamReduced = false
    /// Whether Bluetooth is running, and if not why. The code route works either way.
    public var bluetooth: SongTapBleStatus = .idle

    public init() {}

    public var phase: SongTapPhase { session.phase }
    public var role: SongTapRole { session.role }
}

/// What a transport tells the engine. A transport is the way two phones find each other and carry an offer (a QR code
/// now, Bluetooth next); it knows nothing about the session's rules. It checks what it can on its own (a Bluetooth
/// offer's signature and challenge) and hands over only bytes that passed.
public enum SongTapTransportEvent: Sendable, Equatable {
    case peerFound(Int)
    case peerLost(Int)
    case peerNear(Int)
    case peerFar(Int)
    case peerRole(peer: Int, role: SongTapRole)
    /// The two phones touched: the detector fired.
    case tap(peer: Int)
    /// An offer arrived from `peer` (0 for a QR code): the payload bytes and the number of the key that signed it (0 when unsigned).
    case offer(peer: Int, payload: [UInt8], senderKey: Int32)
    /// Something arrived that is not an offer this phone can use.
    case offerInvalid
    case ack(peer: Int)
    /// The sender said go (receiver side); `rttMs` is the receiver's measured round trip of its acknowledgement.
    case go(peer: Int, rttMs: Int64)
    case declined(peer: Int)
}

/// What the engine needs from the app: the clock, the transports, the library, timers and haptics.
@MainActor
public protocol SongTapPort: AnyObject {
    func nowMs() -> Int64
    func startTransport(_ role: SongTapRole)
    func stopTransport()
    func publishOffer(peer: Int, payload: [UInt8])
    func withdrawOffer()
    func readOffer(peer: Int)
    func sendAck(peer: Int)
    func sendGo(peer: Int, startMs: Int64)
    func sendDecline(peer: Int)
    func abortTransfer(peer: Int)
    /// Starts saving `payload`; the app reports back with `SongTapEngine.saveFinished`.
    func save(_ payload: SongTapPayload)
    /// Stops waiting for a save in flight (the result is still reported if the work finishes).
    func cancelSave()
    func undoSave(videoId: String)
    func haptic(_ cue: SongTapHapticCue)
    /// Calls `SongTapEngine.timeout(tag)` after `afterMs`, replacing a timer of the same tag.
    func schedule(_ tag: SongTapTimeoutTag, afterMs: Int64)
    /// Calls `SongTapEngine.dismissTimerFired()` after `afterMs`.
    func scheduleDismiss(afterMs: Int64)
    func cancelDismiss()
    /// Calls `SongTapEngine.clearInvalidCodeNotice()` after `afterMs`.
    func scheduleInvalidNoticeClear(afterMs: Int64)
    /// Stops every timer (timeouts, dismiss, the code's refresh).
    func cancelTimers()
    func markFirstBeamAccepted()
    func uiChanged(_ ui: SongTapUiState)
    /// Sender: the phones touched; build the payload of the song that plays now and answer with `SongTapEngine.tap(peer:payload:)`.
    func requestTapPayload(peer: Int)
    /// True when Reduce Motion is on: the beam then cross-fades instead of flying.
    func reducedMotion() -> Bool
    /// Calls `SongTapEngine.beamTimerFired()` after `afterMs`; nil cancels the timer.
    func scheduleBeamEnd(afterMs: Int64?)
    /// The session is back to waiting: tell the Bluetooth route to announce the phone that is close again.
    func resync()
}

@MainActor
public final class SongTapEngine {
    /// A result stays on screen for a moment and then the screen goes back to waiting.
    public static let resultMs: Int64 = 4_000
    public static let invalidNoticeMs: Int64 = 2_500
    /// A code expires after five minutes; while it is up, make a fresh one every four.
    public static let qrRefreshMs: Int64 = 240_000
    /// The same code seen again within this long is the same beam.
    public static let sameScanMs: Int64 = 10_000
    /// After a save over Bluetooth, how long to wait for the sender's go before the Undo window starts without a beam.
    public static let goGraceMs: Int64 = 3_000

    public weak var port: (any SongTapPort)?

    public private(set) var session = SongTapSessionState.initial()
    public private(set) var ui = SongTapUiState() {
        didSet { if ui != oldValue { port?.uiChanged(ui) } }
    }

    private var pendingOffer: SongTapPayload?
    /// The offer the session accepted and is acting on (set only when the session took it, never by a mere arrival).
    private var incoming: SongTapPayload?
    /// An offer that has arrived and is being put to the session: it becomes `incoming` only if the session takes it.
    private var candidate: SongTapPayload?
    private var lastScanText: String?
    private var lastScanAtMs: Int64 = 0
    private var dismissPending = false
    /// The video the last save put in the library (a song that came without one was matched to a video first).
    private var savedVideoId: String?
    /// The song key the save that produced `savedVideoId` was for.
    private var savedKey = ""
    private var dispatching = false
    private var queued: [SongTapSessionEvent] = []

    public init() {}

    private func now() -> Int64 { port?.nowMs() ?? 0 }

    // MARK: What the app tells the engine

    public func setAllowed(_ on: Bool) {
        ui.allowed = on
        if !on { disarm() }
    }

    public func setNowPlaying(_ nowPlaying: SongTapNowPlaying?) { ui.nowPlaying = nowPlaying }

    public func setBluetooth(_ status: SongTapBleStatus) { ui.bluetooth = status }

    /// The beam's own timer ran out: the sender's beam is the whole send, so the session is done; the receiver's card is over
    /// when the Undo window is, which is also when the saved result is put away.
    public func beamTimerFired() {
        guard let role = ui.beamRole else { return }
        if role == .send { dispatch(.beamFinished) } else { dispatch(.dismiss) }
        clearBeam()
    }

    private func clearBeam() {
        if ui.beamRole != nil {
            port?.scheduleBeamEnd(afterMs: nil)
            ui.beamRole = nil
            ui.beamStartMs = 0
        }
    }

    public func arm(_ role: SongTapRole, askFirst: Bool) {
        guard ui.allowed else { return }
        dispatch(.arm(role: role, askFirst: askFirst))
    }

    public func disarm() {
        dispatch(.disarm)
        cancelJobs()
    }

    /// The listener flipped Send / Receive: whatever was on the table is put away first.
    public func switchRole(_ role: SongTapRole) {
        dispatch(.cancel)
        dispatch(.dismiss)
        dispatch(.setRole(role))
    }

    /// Sender: put `payload` (the song that is playing) up as a code. Nil when it cannot be named.
    public func showCode(_ payload: SongTapPayload?) {
        pendingOffer = payload
        dispatch(.qrShown(videoId: payload?.songKey ?? ""))
    }

    /// The code's refresh: a fresh payload for the same song, while the code is still up.
    public func refreshCode(_ fresh: SongTapPayload?) {
        guard session.phase == .offered, let fresh else { return }
        pendingOffer = fresh
        publish(peer: 0, payload: fresh)
    }

    public func hideCode() {
        dispatch(.cancel)
        dispatch(.dismiss)
    }

    /// The camera read `text`. The same code seen again within a few seconds is the same beam.
    public func scanned(_ text: String) {
        let t = now()
        if text == lastScanText && t - lastScanAtMs < Self.sameScanMs { return }
        lastScanText = text
        lastScanAtMs = t
        if let bytes = SongTapLink.decode(text) {
            handle(.offer(peer: 0, payload: bytes, senderKey: 0))
        } else {
            handle(.offerInvalid)
        }
    }

    public func accept() {
        port?.markFirstBeamAccepted()
        dispatch(.accept(nowMs: now()))
    }

    public func decline() { dispatch(.decline) }
    public func undo() { dispatch(.undo(nowMs: now())) }
    public func cancel() { dispatch(.cancel) }
    public func dismiss() { dispatch(.dismiss) }

    /// A Bluetooth tap: the detector fired for `peer`; `payload` is the song that plays now, if it can be named.
    public func tap(peer: Int, payload: SongTapPayload?) {
        pendingOffer = payload
        dispatch(.tapDetected(peer: peer, videoId: payload?.songKey ?? ""))
    }

    public func timeout(_ tag: SongTapTimeoutTag) { dispatch(.timeout(tag)) }

    public func dismissTimerFired() {
        dismissPending = false
        dispatch(.dismiss)
    }

    public func clearInvalidCodeNotice() {
        if ui.notice == .invalidCode { ui.notice = nil }
    }

    public func handle(_ event: SongTapTransportEvent) {
        switch event {
        case .peerFound(let p): dispatch(.peerFound(p))
        case .peerLost(let p): dispatch(.peerLost(p))
        case .peerNear(let p): dispatch(.peerNear(p))
        case .peerFar(let p): dispatch(.peerFar(p))
        case .peerRole(let p, let role): dispatch(.peerRole(peer: p, role: role))
        case .tap(let p):
            if session.role == .receive {
                // The receiver sends nothing: the tap only means "read the offer now".
                dispatch(.tapDetected(peer: p, videoId: ""))
            } else {
                port?.requestTapPayload(peer: p)
            }
        case .offer(let peer, let bytes, let senderKey):
            let window = peer == 0 ? SongTapSigning.qrWindowMs : SongTapSigning.offerWindowMs
            if case .ok(let payload) = SongTapPayloads.decode(bytes),
               SongTapSigning.isFresh(tsMs: payload.ts, nowMs: now(), windowMs: window) {
                // Written down only once the session has taken it (see `step`): an offer it ignored (one already being asked
                // about, or being saved) must not replace the card or the song that Undo would remove.
                candidate = payload
                dispatch(.offerReceived(peer: peer, videoId: payload.songKey, senderKey: senderKey, nowMs: now()))
            } else {
                dispatch(.offerRejected)
            }
        case .offerInvalid: dispatch(.offerRejected)
        case .ack: dispatch(.ackReceived(nowMs: now(), rttMs: 0))
        case .go(_, let rtt): dispatch(.goReceived(nowMs: now(), rttMs: rtt))
        case .declined(let p): dispatch(.peerDeclined(p))
        }
    }

    /// The app's answer to `SongTapPort.save`. A result nobody waits for any more (the session was cancelled meanwhile) is
    /// taken back at once.
    public func saveFinished(_ result: SongTapSaveResult, for payload: SongTapPayload) {
        let stillWanted = session.phase == .transferring && session.videoId == payload.songKey
        switch result {
        case .saved(let card):
            if !stillWanted { port?.undoSave(videoId: card.videoId); return }
            savedVideoId = card.videoId
            savedKey = payload.songKey
            ui.card = card
            dispatch(.saveResult(.saved, nowMs: now()))
        case .alreadyHad(let card):
            if !stillWanted { return }
            ui.card = card
            dispatch(.saveResult(.alreadyHad, nowMs: now()))
        case .notFound:
            if stillWanted { dispatch(.saveResult(.notFound, nowMs: now())) }
        case .failed:
            if stillWanted { dispatch(.saveResult(.failed, nowMs: now())) }
        }
    }

    // MARK: The session

    /// Run to completion: an event raised while another is being handled (a transport answers the call the engine just made)
    /// waits its turn, so the state machine never sees two events at once.
    private func dispatch(_ event: SongTapSessionEvent) {
        queued.append(event)
        if dispatching { return }
        dispatching = true
        while !queued.isEmpty { step(queued.removeFirst()) }
        dispatching = false
    }

    private func step(_ event: SongTapSessionEvent) {
        let before = session.phase
        let previous = session
        let r = SongTapSession.reduce(session, event)
        session = r.state
        if case .offerReceived(_, let videoId, _, _) = event {
            let offered = candidate
            candidate = nil
            if let offered, offered.songKey == videoId, previous.videoId != videoId, session.videoId == videoId,
               session.phase == .offered || session.phase == .transferring {
                incoming = offered
                ui.card = Self.card(of: offered)
            }
        }
        updateUi(after: event)
        for effect in r.effects { perform(effect) }
        // A code is up only while an offer is on the table.
        if session.phase != .offered {
            port?.withdrawOffer()
            if ui.code != nil { ui.code = nil }
        }
        // Back to waiting after a result: the phone that is close has to be announced again to be tappable.
        if before != .armed && before != .idle && session.phase == .armed { port?.resync() }
        watchTerminal()
    }

    private func updateUi(after event: SongTapSessionEvent) {
        var next = ui
        next.session = session
        if session.phase == .armed || session.phase == .idle { next.card = nil }
        switch event {
        case .dismiss, .arm, .disarm:
            next.notice = nil
        default:
            // A failure the session reports without a notice of its own (a lost peer, a timeout) is worded from its reason.
            if session.phase == .failed, let fail = session.fail { next.notice = SongTapNotice.of(fail) }
        }
        ui = next
        // A beam belongs to a session that is sending or saving; anything else (a failure, a cancel, Undo) ends it at once.
        if session.phase != .transferring && session.phase != .saved { clearBeam() }
    }

    private static func card(of p: SongTapPayload) -> SongTapCard {
        SongTapCard(videoId: p.ytVideoId ?? "", songId: "", title: p.title, artist: p.artist, artUrl: p.artUrl)
    }

    private func publish(peer: Int, payload: SongTapPayload) {
        guard let bytes = SongTapPayloads.encode(payload) else { return }
        if peer == 0 { ui.code = SongTapLink.encode(bytes) }
        port?.publishOffer(peer: peer, payload: bytes)
    }

    private func perform(_ effect: SongTapSessionEffect) {
        guard let port else { return }
        switch effect {
        case .startTransport(let role): port.startTransport(role)
        case .stopTransport: port.stopTransport(); cancelJobs()
        case .publishOffer(let peer, _):
            if let p = pendingOffer { publish(peer: peer, payload: p) }
        case .readOffer(let peer): port.readOffer(peer: peer)
        case .sendAck(let peer): port.sendAck(peer: peer)
        case .sendGo(let peer, let startMs): port.sendGo(peer: peer, startMs: startMs)
        case .sendDecline(let peer): port.sendDecline(peer: peer)
        case .abortTransfer(let peer): port.abortTransfer(peer: peer)
        case .startBeam(let role, let startMs):
            // From here the beam owns the end of the result (the receiver's card goes with the beam's own end).
            if dismissPending { dismissPending = false; port.cancelDismiss() }
            let reduced = port.reducedMotion()
            ui.beamStartMs = startMs
            ui.beamRole = role
            ui.beamReduced = reduced
            let end = startMs + SongTapTimeline.totalMs(role: role, reducedMotion: reduced) - now()
            port.scheduleBeamEnd(afterMs: max(0, end))
        case .saveSong:
            savedVideoId = nil
            savedKey = ""
            if let payload = incoming { port.save(payload) }
        case .undoSave(let songKey):
            port.cancelSave()
            // What this session's save added, by the session's own song key; never whatever the card happens to show.
            let videoId = savedVideoId.flatMap { savedKey == songKey && !$0.isEmpty ? $0 : nil }
                ?? incoming.flatMap { $0.songKey == songKey ? $0.ytVideoId : nil } ?? songKey
            port.undoSave(videoId: videoId)
        case .haptic(let cue):
            // A beam (playing, or about to: any phone found over Bluetooth) does its own vibrating from the timeline's cue
            // list; the session's "success" would buzz twice.
            if !(cue == .success && (ui.beamRole != nil || session.peer != 0)) { port.haptic(cue) }
        case .scheduleTimeout(let tag, let afterMs): port.schedule(tag, afterMs: afterMs)
        case .notice(let reason): ui.notice = SongTapNotice.of(reason)
        case .noticeInvalidCode:
            ui.notice = .invalidCode
            // A stranger's code is a passing remark, not a result: it goes by itself.
            port.scheduleInvalidNoticeClear(afterMs: Self.invalidNoticeMs)
        }
    }

    /// A result stays on screen for a moment and then the screen goes back to waiting.
    private func watchTerminal() {
        let phase = session.phase
        let terminal = phase == .saved || phase == .declined || phase == .failed || phase == .cancelled
        if !terminal {
            if dismissPending { dismissPending = false; port?.cancelDismiss() }
            return
        }
        if dismissPending { return }
        // A saved card that came with a beam is put away by the beam's own end (its Undo chip lives inside it).
        if phase == .saved && ui.beamRole == .receive { return }
        dismissPending = true
        // Over Bluetooth the receiver saves first and the sender's go (which starts the beam) arrives a moment later: the Undo
        // window must not begin before the beam does, or the card would be taken away in the middle of it.
        let waitForBeam = phase == .saved && session.role == .receive && session.peer != 0
        let stay = phase == .saved ? SongTapSession.undoWindowMs : Self.resultMs
        port?.scheduleDismiss(afterMs: waitForBeam ? Self.goGraceMs + stay : stay)
    }

    private func cancelJobs() {
        dismissPending = false
        port?.cancelTimers()
    }
}
