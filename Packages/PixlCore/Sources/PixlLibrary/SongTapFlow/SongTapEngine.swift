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
    /// Song Drop (sender): phones advertising as receivers inside the list gate, strongest first, from advertisements only.
    public var nearby: [SongTapNearbyEntry] = []
    /// Song Drop (sender): the phone inside the near gate to ask "Song drop to X?" about, or nil.
    public var prompt: SongTapNearbyEntry?
    /// The other phone's name for the cards: the sender on a receiver, the target on a sender; nil when unknown.
    public var peerName: String?
    /// True while the song being offered is a Song Drop song picked from a song's options (not just the one that plays).
    public var dropMode = false
    /// How sensitive the tap is (Settings > Song Tap), applied live.
    public var sensitivity = SongTapSensitivity.default

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
    /// The other phone's name (its full name once connected): a label for the cards, never an identity.
    case peerName(peer: Int, name: String)
    /// The commit: this phone's detector fired for `peer`, or the other phone's tap message was accepted by `SongTapPeerTap.judge`.
    case tap(peer: Int)
    /// An offer arrived from `peer` (0 for a QR code): the payload bytes and the number of the key that signed it (0 when unsigned); `name` is the sender's name.
    case offer(peer: Int, payload: [UInt8], senderKey: Int32, name: String? = nil)
    /// Receiver: a checked offer was fetched from `peer` before any tap and is now in hand (spec 5 prefetch).
    case offerPrefetched(peer: Int, payload: [UInt8], senderKey: Int32, name: String? = nil)
    /// Receiver: the offer fetched ahead is no good any more (the sender withdrew it, or the connection closed).
    case offerGone(peer: Int)
    /// Sender: the phone the listener said yes to has read the offer, or went away before the beam.
    case offerRead(peer: Int)
    case offerReadLost(peer: Int)
    /// Something arrived that is not an offer this phone can use.
    case offerInvalid
    case ack(peer: Int)
    case declined(peer: Int)
}

/// What the engine needs from the app: the clock, the transports, the library, timers and haptics.
@MainActor
public protocol SongTapPort: AnyObject {
    func nowMs() -> Int64
    func startTransport(_ role: SongTapRole)
    func stopTransport()
    func publishOffer(peer: Int, payload: [UInt8])
    /// Takes the offer off the table. A sender keeps its Bluetooth offer through the beam (`keepBluetooth`), because the receiver's
    /// answer still has to be matched to the phone that read it.
    func withdrawOffer(keepBluetooth: Bool)
    func readOffer(peer: Int)
    func sendAck(peer: Int)
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
    /// A sender armed to a phone makes its offer again this often (the offer carries a time), and a receiver accepts one this old.
    public static let targetRefreshMs: Int64 = 20_000
    public static let prefetchPayloadWindowMs: Int64 = 120_000

    public weak var port: (any SongTapPort)?

    public private(set) var session = SongTapSessionState.initial()
    public private(set) var ui = SongTapUiState() {
        didSet { if ui != oldValue { port?.uiChanged(ui) } }
    }

    private var pendingOffer: SongTapPayload?
    /// Receiver (spec 5): the checked offer fetched ahead of the tap, kept until the session commits to it or lets it go.
    private var prefetched: SongTapPayload?
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

    public func setBluetooth(_ status: SongTapBleStatus) {
        ui.bluetooth = status
        // Bluetooth went away under a sender that was armed to a phone: the offer is gone with it.
        if status != .active && status != .idle && session.phase == .offered && session.target != 0 {
            dispatch(.cancel)
            dispatch(.dismiss)
        }
    }

    public func setNearby(_ list: [SongTapNearbyEntry], prompt: SongTapNearbyEntry?) {
        ui.nearby = list
        ui.prompt = prompt
    }

    public func setSensitivity(_ value: SongTapSensitivity) { ui.sensitivity = value }

    /// A song picked from a song's options is being offered instead of the one that plays (Song Drop).
    public func setDropMode(_ on: Bool) { ui.dropMode = on }

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

    /// Sender: "Song drop to X?" was answered yes for `peer` (a number from `ui.nearby` or `ui.prompt`): the offer for `payload` is
    /// published for that phone only, and the beam starts when the two phones touch. A nil payload (the song cannot be named) says so.
    public func approve(peer: Int, name: String?, payload: SongTapPayload?) {
        pendingOffer = payload
        ui.peerName = name
        dispatch(.approve(peer: peer, videoId: payload?.songKey ?? ""))
    }

    /// Sender: the offer's payload is made again (it carries a time, and the song may have changed): the target reads it anew.
    public func republish(_ fresh: SongTapPayload?) {
        guard session.phase == .offered, session.target != 0, let fresh else { return }
        pendingOffer = fresh
        dispatch(.republish(videoId: fresh.songKey))
    }

    /// Stop being armed to the phone that was said yes to.
    public func cancelDrop() {
        dispatch(.cancel)
        dispatch(.dismiss)
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
        case .peerName(let p, let name):
            if p == session.peer && session.role == .receive { ui.peerName = name }
        case .tap(let p):
            // The commit: nothing is made and nothing is waited for, so the haptic and the beam start at the moment of the tap. The
            // sender's song was made at "Yes", the receiver's offer is already in hand (prefetched).
            dispatch(.tapDetected(peer: p, videoId: session.role == .receive ? "" : pendingOffer?.songKey ?? "", nowMs: now()))
        case .offerPrefetched(let peer, let bytes, let senderKey, let name):
            if case .ok(let payload) = SongTapPayloads.decode(bytes),
               SongTapSigning.isFresh(tsMs: payload.ts, nowMs: now(), windowMs: Self.prefetchPayloadWindowMs) {
                prefetched = payload
                if let name { ui.peerName = name }
                dispatch(.offerPrefetched(peer: peer, videoId: payload.songKey, senderKey: senderKey))
            }
        case .offerGone(let p): dispatch(.offerGone(peer: p))
        case .offerRead(let p): dispatch(.offerRead(peer: p, nowMs: now()))
        case .offerReadLost(let p): dispatch(.offerReadLost(peer: p))
        case .offer(let peer, let bytes, let senderKey, let name):
            let window = peer == 0 ? SongTapSigning.qrWindowMs : Self.prefetchPayloadWindowMs
            if case .ok(let payload) = SongTapPayloads.decode(bytes),
               SongTapSigning.isFresh(tsMs: payload.ts, nowMs: now(), windowMs: window) {
                // Written down only once the session has taken it (see `step`): an offer it ignored (one already being asked
                // about, or being saved) must not replace the card or the song that Undo would remove.
                candidate = payload
                if let name { ui.peerName = name }
                dispatch(.offerReceived(peer: peer, videoId: payload.songKey, senderKey: senderKey, nowMs: now()))
            } else {
                dispatch(.offerRejected)
            }
        case .offerInvalid: dispatch(.offerRejected)
        case .ack: dispatch(.ackReceived(nowMs: now(), rttMs: 0))
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
        // A tap that committed to an offer that was fetched ahead: that offer is now the one on the table.
        if case .tapDetected = event, previous.pre, !session.pre, session.phase == .offered || session.phase == .transferring,
           let held = prefetched, held.songKey == session.videoId {
            incoming = held
            ui.card = Self.card(of: held)
        }
        if !session.pre { prefetched = nil }
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
        // A code is up, and an offer readable over Bluetooth, only while an offer is on the table. A sender keeps its Bluetooth offer
        // through the beam (the receiver's answer still has to be matched to the phone that read it).
        if session.phase != .offered {
            port?.withdrawOffer(keepBluetooth: session.role == .send && session.phase == .transferring)
            if ui.code != nil { ui.code = nil }
        }
        // Back to waiting after a result: the phone that is close has to be announced again to be tappable.
        if before != .armed && before != .idle && session.phase == .armed { port?.resync() }
        watchTerminal()
    }

    private func updateUi(after event: SongTapSessionEvent) {
        var next = ui
        next.session = session
        if session.phase == .armed || session.phase == .idle {
            next.card = nil
            next.peerName = nil
        }
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
        // The beam starts with the save (spec 5), so the Undo window starts at the save as well: nothing waits for the other phone.
        let stay = phase == .saved ? SongTapSession.undoWindowMs : Self.resultMs
        port?.scheduleDismiss(afterMs: stay)
    }

    private func cancelJobs() {
        dismissPending = false
        port?.cancelTimers()
    }
}
