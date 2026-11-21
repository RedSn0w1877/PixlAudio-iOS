// One Song Tap session as a pure `reduce(state, event) -> (state, effects)`: no clock, no radio, no storage. A
// transport (QR now, Bluetooth next) turns what it sees into `SongTapSessionEvent`s, the controller performs the
// `SongTapSessionEffect`s, and both platforms are proven to agree by golden event traces. A transliteration of
// `SongTapSession.kt` (spec 6).
//
// Phases: idle (Song Tap is off), armed (on, nobody around), found (a peer is in range), near (a peer is close),
// offered (a real offer exists and waits for a decision: the sender for an acknowledgement, the receiver for
// Add / Not now), transferring (bytes or a save in flight, then the beam), saved, declined, failed, cancelled. The last
// four are shown for a moment and then `dismiss` returns to armed.
//
// An event that does not make sense in the current phase (a late acknowledgement after a cancel, a duplicate offer, a
// second tap) changes nothing and has no effects.

public enum SongTapRole: String, Sendable, CaseIterable {
    case send = "send"
    case receive = "receive"

    public var code: String { rawValue }
}

public enum SongTapPhase: String, Sendable, CaseIterable {
    case idle, armed, found, near, offered, transferring, saved, declined, failed, cancelled

    public var code: String { rawValue }
}

public enum SongTapFailReason: String, Sendable, CaseIterable {
    case nothingToSend = "nothing_to_send"
    case bothSending = "both_sending"
    case peerLost = "peer_lost"
    case timeout = "timeout"
    case invalidOffer = "invalid_offer"
    case notFound = "not_found"
    case saveFailed = "save_failed"
    case tooSoon = "too_soon"
    case limit = "limit"
    case duplicate = "duplicate"
    case muted = "muted"

    public var code: String { rawValue }
}

public enum SongTapSaveOutcome: String, Sendable, CaseIterable {
    case saved = "saved"
    case alreadyHad = "already_had"
    case notFound = "not_found"
    case failed = "failed"

    public var code: String { rawValue }
}

public enum SongTapTimeoutTag: String, Sendable, CaseIterable {
    case ack, read, consent, save, target

    public var code: String { rawValue }
}

public enum SongTapHapticCue: String, Sendable, CaseIterable {
    case tick, confirm, success, warn

    public var code: String { rawValue }
}

public struct SongTapSessionState: Sendable, Equatable {
    public var phase: SongTapPhase
    public var role: SongTapRole
    /// The peer's number as the transport gave it, 0 for none (and for a QR code, which has no peer).
    public var peer: Int
    /// The song in play in this session: the one offered, or the one received; empty before there is one.
    public var videoId: String
    public var fail: SongTapFailReason?
    /// The first beam a receiver ever gets asks (Add / Not now); cleared once the listener has said yes.
    public var askFirst: Bool
    /// The song was already in the library: nothing was added and there is nothing to undo.
    public var alreadyHad: Bool
    /// The number `SongTapSigning.senderKey` gave the sender of the offer on the table, 0 when unknown.
    public var senderKey: Int32
    public var limits: SongTapRateLimits
    /// Beams saved without asking since the listener last said yes; at `SongTapSession.askAgainAfter` the next one asks again.
    public var autoSaves: Int
    /// Sender: the peer the listener said "Song drop to X?" yes to (spec 5); 0 when none. The offer is published for that phone only.
    public var target: Int
    /// Sender: the target has read the offer (so the data is already in hand over there).
    public var offerRead: Bool
    /// Sender: a tap came before the target had read the offer; the beam starts when the read arrives.
    public var tapSeen: Bool
    /// Sender: the receiver acknowledged (it saved).
    public var acked: Bool
    /// Sender: the beam has played out; the session ends when the acknowledgement is also in.
    public var beamDone: Bool
    /// Receiver: a checked offer from `peer` is in hand (`videoId`, `senderKey`) and waits for the tap (spec 5 prefetch).
    public var pre: Bool

    public init(phase: SongTapPhase, role: SongTapRole, peer: Int, videoId: String, fail: SongTapFailReason?, askFirst: Bool, alreadyHad: Bool,
                senderKey: Int32, limits: SongTapRateLimits, autoSaves: Int = 0, target: Int = 0, offerRead: Bool = false,
                tapSeen: Bool = false, acked: Bool = false, beamDone: Bool = false, pre: Bool = false) {
        self.phase = phase
        self.role = role
        self.peer = peer
        self.videoId = videoId
        self.fail = fail
        self.askFirst = askFirst
        self.alreadyHad = alreadyHad
        self.senderKey = senderKey
        self.limits = limits
        self.autoSaves = autoSaves
        self.target = target
        self.offerRead = offerRead
        self.tapSeen = tapSeen
        self.acked = acked
        self.beamDone = beamDone
        self.pre = pre
    }

    public func describe() -> String {
        "\(phase.code) role=\(role.code) peer=\(peer) vid=\(videoId.isEmpty ? "-" : videoId) fail=\(fail?.code ?? "-") " +
            "ask=\(askFirst ? 1 : 0) had=\(alreadyHad ? 1 : 0) key=\(senderKey)" +
            (target != 0 ? " tgt=\(target)" : "") +
            (offerRead ? " read=1" : "") +
            (tapSeen ? " tapseen=1" : "") +
            (acked ? " acked=1" : "") +
            (beamDone ? " beamdone=1" : "") +
            (pre ? " pre=1" : "")
    }

    public static func initial(askFirst: Bool = true) -> SongTapSessionState {
        SongTapSessionState(phase: .idle, role: .send, peer: 0, videoId: "", fail: nil, askFirst: askFirst, alreadyHad: false,
                     senderKey: 0, limits: SongTapRateLimits())
    }
}

public enum SongTapSessionEvent: Sendable, Equatable {
    case arm(role: SongTapRole, askFirst: Bool)
    case disarm
    case setRole(SongTapRole)
    case peerFound(Int)
    case peerLost(Int)
    case peerNear(Int)
    case peerFar(Int)
    case peerRole(peer: Int, role: SongTapRole)
    case peerDeclined(Int)
    /// The detector fired for `peer` (or, for a sender, the receiver told it so); `videoId` is what plays now on this phone
    /// (empty when nothing does), `nowMs` this phone's clock: it is the moment of the commit.
    case tapDetected(peer: Int, videoId: String, nowMs: Int64)
    /// Sender: the listener said yes to "Song drop to X?" for `peer`; the offer for `videoId` is published for that phone only.
    case approve(peer: Int, videoId: String)
    /// Sender: the song changed, or the offer is being refreshed: publish `videoId` again for the target (a new read is needed).
    case republish(videoId: String)
    /// Sender: the target phone has read the offer.
    case offerRead(peer: Int, nowMs: Int64)
    /// Sender: the phone that read the offer went away (before the beam).
    case offerReadLost(peer: Int)
    /// Receiver: a valid, checked offer from `peer` was fetched before any tap and is now in hand (spec 5 prefetch).
    case offerPrefetched(peer: Int, videoId: String, senderKey: Int32)
    /// Receiver: the offer in hand is no longer valid (the sender withdrew it or changed it).
    case offerGone(peer: Int)
    /// The sender put its QR code up for `videoId`.
    case qrShown(videoId: String)
    /// A valid offer arrived (checked by the transport): from `peer` (0 for a QR code), made by `senderKey`.
    case offerReceived(peer: Int, videoId: String, senderKey: Int32, nowMs: Int64)
    /// Something arrived that is not a valid offer (a stranger's QR code, a bad signature, a stale frame).
    case offerRejected
    case ackReceived(nowMs: Int64, rttMs: Int64)
    case beamFinished
    case accept(nowMs: Int64)
    case decline
    case saveResult(SongTapSaveOutcome, nowMs: Int64)
    case undo(nowMs: Int64)
    case cancel
    case dismiss
    case timeout(SongTapTimeoutTag)

    /// The text the golden traces use: `name(arg,arg)`.
    public func describe() -> String {
        switch self {
        case .arm(let role, let askFirst): "arm(\(role.code),\(askFirst ? 1 : 0))"
        case .disarm: "disarm"
        case .setRole(let role): "setRole(\(role.code))"
        case .peerFound(let p): "peerFound(\(p))"
        case .peerLost(let p): "peerLost(\(p))"
        case .peerNear(let p): "peerNear(\(p))"
        case .peerFar(let p): "peerFar(\(p))"
        case .peerRole(let p, let role): "peerRole(\(p),\(role.code))"
        case .peerDeclined(let p): "peerDeclined(\(p))"
        case .tapDetected(let p, let v, let now): "tap(\(p),\(v.isEmpty ? "-" : v),\(now))"
        case .approve(let p, let v): "approve(\(p),\(v.isEmpty ? "-" : v))"
        case .republish(let v): "republish(\(v.isEmpty ? "-" : v))"
        case .offerRead(let p, let now): "offerRead(\(p),\(now))"
        case .offerReadLost(let p): "offerReadLost(\(p))"
        case .offerPrefetched(let p, let v, let k): "offerPrefetched(\(p),\(v),\(k))"
        case .offerGone(let p): "offerGone(\(p))"
        case .qrShown(let v): "qrShown(\(v))"
        case .offerReceived(let p, let v, let k, let now): "offer(\(p),\(v),\(k),\(now))"
        case .offerRejected: "offerRejected"
        case .ackReceived(let now, let rtt): "ack(\(now),\(rtt))"
        case .beamFinished: "beamFinished"
        case .accept(let now): "accept(\(now))"
        case .decline: "decline"
        case .saveResult(let outcome, let now): "saveResult(\(outcome.code),\(now))"
        case .undo(let now): "undo(\(now))"
        case .cancel: "cancel"
        case .dismiss: "dismiss"
        case .timeout(let tag): "timeout(\(tag.code))"
        }
    }
}

public enum SongTapSessionEffect: Sendable, Equatable {
    case startTransport(SongTapRole)
    case stopTransport
    case publishOffer(peer: Int, videoId: String)
    case readOffer(peer: Int)
    case sendAck(peer: Int)
    case sendDecline(peer: Int)
    case startBeam(role: SongTapRole, startMs: Int64)
    case saveSong(videoId: String)
    case undoSave(videoId: String)
    case abortTransfer(peer: Int)
    case haptic(SongTapHapticCue)
    case scheduleTimeout(SongTapTimeoutTag, afterMs: Int64)
    case notice(SongTapFailReason)
    case noticeInvalidCode

    public func describe() -> String {
        switch self {
        case .startTransport(let role): "startTransport(\(role.code))"
        case .stopTransport: "stopTransport"
        case .publishOffer(let p, let v): "publishOffer(\(p),\(v))"
        case .readOffer(let p): "readOffer(\(p))"
        case .sendAck(let p): "sendAck(\(p))"
        case .sendDecline(let p): "sendDecline(\(p))"
        case .startBeam(let role, let start): "startBeam(\(role.code),\(start))"
        case .saveSong(let v): "saveSong(\(v))"
        case .undoSave(let v): "undoSave(\(v))"
        case .abortTransfer(let p): "abortTransfer(\(p))"
        case .haptic(let cue): "haptic(\(cue.code))"
        case .scheduleTimeout(let tag, let after): "scheduleTimeout(\(tag.code),\(after))"
        case .notice(let reason): "notice(\(reason.code))"
        case .noticeInvalidCode: "noticeInvalidCode"
        }
    }
}

public struct SongTapReduction: Sendable, Equatable {
    public var state: SongTapSessionState
    public var effects: [SongTapSessionEffect]

    public init(state: SongTapSessionState, effects: [SongTapSessionEffect]) {
        self.state = state
        self.effects = effects
    }
}

public enum SongTapSession {
    /// How long a sender waits to hear back. The receiver may first ask its listener (up to `consentTimeoutMs`) and then
    /// save (up to `saveTimeoutMs`) before it answers, so this is longer than both together.
    public static let ackTimeoutMs: Int64 = 45_000
    public static let readTimeoutMs: Int64 = 8_000
    public static let consentTimeoutMs: Int64 = 20_000
    public static let saveTimeoutMs: Int64 = 20_000

    /// How long a sender stays armed to a phone it said yes to, waiting for the tap.
    public static let targetTimeoutMs: Int64 = 60_000

    /// After this many beams saved without asking, the next one asks (Add / Not now) again.
    public static let askAgainAfter = 5

    /// How long the saved card offers Undo.
    public static let undoWindowMs: Int64 = 6_000

    private static func stay(_ s: SongTapSessionState) -> SongTapReduction { SongTapReduction(state: s, effects: []) }

    public static func reduce(_ s: SongTapSessionState, _ e: SongTapSessionEvent) -> SongTapReduction {
        switch e {
        case .arm(let role, let askFirst): return arm(s, role: role, askFirst: askFirst)
        case .disarm: return disarm(s)
        case .setRole(let role): return setRole(s, role)
        case .peerFound(let peer): return peerFound(s, peer)
        case .peerLost(let peer): return peerLost(s, peer)
        case .peerNear(let peer): return peerNear(s, peer)
        case .peerFar(let peer): return peerFar(s, peer)
        case .peerRole(let peer, let role): return peerRole(s, peer: peer, role: role)
        case .peerDeclined(let peer): return peerDeclined(s, peer)
        case .tapDetected(let peer, let videoId, let nowMs): return tap(s, peer: peer, videoId: videoId, nowMs: nowMs)
        case .approve(let peer, let videoId): return approve(s, peer: peer, videoId: videoId)
        case .republish(let videoId): return republish(s, videoId)
        case .offerRead(let peer, let nowMs): return offerRead(s, peer: peer, nowMs: nowMs)
        case .offerReadLost(let peer): return offerReadLost(s, peer)
        case .offerPrefetched(let peer, let videoId, let senderKey): return offerPrefetched(s, peer: peer, videoId: videoId, senderKey: senderKey)
        case .offerGone(let peer): return offerGone(s, peer)
        case .qrShown(let videoId): return qrShown(s, videoId)
        case .offerReceived(let peer, let videoId, let senderKey, let nowMs):
            return offerReceived(s, peer: peer, videoId: videoId, senderKey: senderKey, nowMs: nowMs)
        case .offerRejected: return offerRejected(s)
        case .ackReceived(let nowMs, _): return ackReceived(s, nowMs: nowMs)
        case .beamFinished: return beamFinished(s)
        case .accept(let nowMs): return accept(s, nowMs: nowMs)
        case .decline: return decline(s)
        case .saveResult(let outcome, let nowMs): return saveResult(s, outcome: outcome, nowMs: nowMs)
        case .undo(let nowMs): return undo(s, nowMs: nowMs)
        case .cancel: return cancel(s)
        case .dismiss: return dismiss(s)
        case .timeout(let tag): return timeout(s, tag)
        }
    }

    /// Runs `events` from `start`; the states and the effects after each one.
    public static func run(start: SongTapSessionState, events: [SongTapSessionEvent]) -> [SongTapReduction] {
        var out: [SongTapReduction] = []
        out.reserveCapacity(events.count)
        var state = start
        for event in events {
            let r = reduce(state, event)
            out.append(r)
            state = r.state
        }
        return out
    }

    private static func isTerminal(_ p: SongTapPhase) -> Bool {
        p == .saved || p == .declined || p == .failed || p == .cancelled
    }

    private static func clear(_ s: SongTapSessionState, _ phase: SongTapPhase, role: SongTapRole? = nil) -> SongTapSessionState {
        var n = s
        n.phase = phase
        n.role = role ?? s.role
        n.peer = 0
        n.videoId = ""
        n.fail = nil
        n.alreadyHad = false
        n.senderKey = 0
        n.target = 0
        n.offerRead = false
        n.tapSeen = false
        n.acked = false
        n.beamDone = false
        n.pre = false
        return n
    }

    private static func failed(_ s: SongTapSessionState, _ reason: SongTapFailReason) -> SongTapSessionState {
        var n = s
        n.phase = .failed
        n.fail = reason
        return n
    }

    private static func arm(_ s: SongTapSessionState, role: SongTapRole, askFirst: Bool) -> SongTapReduction {
        if s.phase != .idle && !isTerminal(s.phase) { return stay(s) }
        var n = clear(s, .armed, role: role)
        n.askFirst = askFirst
        return SongTapReduction(state: n, effects: [.startTransport(role)])
    }

    /// What to stop when a session is torn down in the middle of something. A save that is still running is not undone
    /// here: its outcome is not known yet, and a song the listener already had must never be removed. The controller
    /// takes back a save that finishes after the session is gone, and only when that save really added the song.
    private static func teardown(_ s: SongTapSessionState) -> [SongTapSessionEffect] {
        let inFlight = s.phase == .offered || s.phase == .transferring
        return inFlight && s.peer != 0 ? [.abortTransfer(peer: s.peer)] : []
    }

    private static func disarm(_ s: SongTapSessionState) -> SongTapReduction {
        if s.phase == .idle { return stay(s) }
        return SongTapReduction(state: clear(s, .idle), effects: teardown(s) + [.stopTransport])
    }

    private static func setRole(_ s: SongTapSessionState, _ role: SongTapRole) -> SongTapReduction {
        if s.role == role { return stay(s) }
        switch s.phase {
        case .armed, .found, .near:
            return SongTapReduction(state: clear(s, .armed, role: role), effects: [.stopTransport, .startTransport(role)])
        default:
            return stay(s)
        }
    }

    private static func peerFound(_ s: SongTapSessionState, _ peer: Int) -> SongTapReduction {
        if peer == 0 { return stay(s) }
        if s.phase == .armed {
            var n = s
            n.phase = .found
            n.peer = peer
            return SongTapReduction(state: n, effects: [])
        }
        return stay(s)
    }

    private static func peerLost(_ s: SongTapSessionState, _ peer: Int) -> SongTapReduction {
        if s.peer == 0 || s.peer != peer { return stay(s) }
        switch s.phase {
        case .found, .near:
            var n = s
            n.phase = .armed
            n.peer = 0
            n.pre = false
            n.videoId = ""
            n.senderKey = 0
            return SongTapReduction(state: n, effects: [])
        case .offered:
            // A sender armed to a phone it said yes to keeps waiting for the tap when that phone's link drops or it is out of
            // sight for a moment: only the read is lost. The listener cancels, or the target timeout does.
            if s.role == .send && s.target != 0 {
                var n = s
                n.offerRead = false
                return SongTapReduction(state: n, effects: [])
            }
            return peerLostMidBeam(s)
        case .transferring:
            return peerLostMidBeam(s)
        default:
            return stay(s)
        }
    }

    private static func peerLostMidBeam(_ s: SongTapSessionState) -> SongTapReduction {
        // After the receiver's acknowledgement the sender has nothing left to lose.
        if s.role == .send && s.acked { return stay(s) }
        switch s.phase {
        case .offered, .transferring:
            // A receiver that holds a checked offer does not need the sender any more: pulling the phones apart after a tap is
            // normal, and Add / save must still work. Only a beam still being read is lost.
            if s.role == .receive && !s.videoId.isEmpty {
                var n = s
                n.peer = 0
                return SongTapReduction(state: n, effects: [])
            }
            return SongTapReduction(state: failed(s, .peerLost), effects: teardown(s) + [.haptic(.warn)])
        default:
            return stay(s)
        }
    }

    private static func peerNear(_ s: SongTapSessionState, _ peer: Int) -> SongTapReduction {
        if s.phase == .found && s.peer == peer {
            var n = s
            n.phase = .near
            return SongTapReduction(state: n, effects: [])
        }
        return stay(s)
    }

    private static func peerFar(_ s: SongTapSessionState, _ peer: Int) -> SongTapReduction {
        if s.phase == .near && s.peer == peer {
            var n = s
            n.phase = .found
            return SongTapReduction(state: n, effects: [])
        }
        return stay(s)
    }

    private static func peerRole(_ s: SongTapSessionState, peer: Int, role: SongTapRole) -> SongTapReduction {
        if s.peer != peer || s.peer == 0 { return stay(s) }
        let active = s.phase == .found || s.phase == .near || s.phase == .offered || s.phase == .transferring
        if active && s.role == .send && role == .send {
            return SongTapReduction(state: failed(s, .bothSending), effects: teardown(s) + [.notice(.bothSending)])
        }
        return stay(s)
    }

    private static func peerDeclined(_ s: SongTapSessionState, _ peer: Int) -> SongTapReduction {
        if s.role != .send || s.peer != peer || peer == 0 { return stay(s) }
        if s.phase == .offered || s.phase == .transferring {
            var n = s
            n.phase = .declined
            return SongTapReduction(state: n, effects: [])
        }
        return stay(s)
    }

    private static func tap(_ s: SongTapSessionState, peer: Int, videoId: String, nowMs: Int64) -> SongTapReduction {
        if s.role == .send {
            // A sender beams only to the phone its listener said yes to; a tap with anybody else changes nothing.
            if s.phase != .offered || s.target == 0 || s.peer != peer { return stay(s) }
            // The target already holds the offer: the tap is the commit. If it has not read it yet, the beam starts when it does.
            if s.offerRead { return commitSend(s, nowMs: nowMs) }
            var n = s
            n.tapSeen = true
            return stay(n)
        }
        if (s.phase != .found && s.phase != .near) || s.peer != peer { return stay(s) }
        // The offer was fetched before the tap: the tap is the commit, with nothing slow left to do.
        if s.pre {
            var n = s
            n.pre = false
            return admitOffer(n, peer: peer, videoId: s.videoId, senderKey: s.senderKey, nowMs: nowMs, withTick: true)
        }
        var n = s
        n.phase = .transferring
        n.videoId = ""
        return SongTapReduction(state: n, effects: [
            .readOffer(peer: peer),
            .scheduleTimeout(.read, afterMs: readTimeoutMs),
        ])
    }

    /// The sender's commit: the first haptic, the beam, and the wait for the receiver's answer.
    private static func commitSend(_ s: SongTapSessionState, nowMs: Int64) -> SongTapReduction {
        var n = s
        n.phase = .transferring
        n.tapSeen = false
        return SongTapReduction(state: n, effects: [
            .haptic(.tick),
            .startBeam(role: .send, startMs: nowMs),
            .scheduleTimeout(.ack, afterMs: ackTimeoutMs),
        ])
    }

    private static func approve(_ s: SongTapSessionState, peer: Int, videoId: String) -> SongTapReduction {
        if s.role != .send || peer <= 0 { return stay(s) }
        if s.phase != .armed && s.phase != .found && s.phase != .near { return stay(s) }
        if videoId.isEmpty {
            return SongTapReduction(state: failed(s, .nothingToSend), effects: [.notice(.nothingToSend), .haptic(.warn)])
        }
        var n = s
        n.phase = .offered
        n.peer = peer
        n.videoId = videoId
        n.target = peer
        n.offerRead = false
        n.tapSeen = false
        return SongTapReduction(state: n, effects: [.publishOffer(peer: peer, videoId: videoId),
                                                    .scheduleTimeout(.target, afterMs: targetTimeoutMs)])
    }

    private static func republish(_ s: SongTapSessionState, _ videoId: String) -> SongTapReduction {
        if s.role != .send || s.phase != .offered || s.target == 0 || videoId.isEmpty { return stay(s) }
        var n = s
        n.videoId = videoId
        n.offerRead = false
        return SongTapReduction(state: n, effects: [.publishOffer(peer: s.target, videoId: videoId)])
    }

    private static func offerRead(_ s: SongTapSessionState, peer: Int, nowMs: Int64) -> SongTapReduction {
        if s.role != .send || s.phase != .offered || s.target == 0 || s.target != peer { return stay(s) }
        var n = s
        n.offerRead = true
        // A tap that came first starts the beam now that the offer is in hand.
        return s.tapSeen ? commitSend(n, nowMs: nowMs) : stay(n)
    }

    private static func offerReadLost(_ s: SongTapSessionState, _ peer: Int) -> SongTapReduction {
        if s.role != .send || s.phase != .offered || s.target == 0 || s.target != peer { return stay(s) }
        var n = s
        n.offerRead = false
        return stay(n)
    }

    private static func offerPrefetched(_ s: SongTapSessionState, peer: Int, videoId: String, senderKey: Int32) -> SongTapReduction {
        if s.role != .receive || peer == 0 || s.peer != peer { return stay(s) }
        if s.phase != .found && s.phase != .near { return stay(s) }
        var n = s
        n.pre = true
        n.videoId = videoId
        n.senderKey = senderKey
        return stay(n)
    }

    private static func offerGone(_ s: SongTapSessionState, _ peer: Int) -> SongTapReduction {
        if s.role != .receive || !s.pre || s.peer != peer { return stay(s) }
        var n = s
        n.pre = false
        n.videoId = ""
        n.senderKey = 0
        return stay(n)
    }

    private static func qrShown(_ s: SongTapSessionState, _ videoId: String) -> SongTapReduction {
        if s.role != .send { return stay(s) }
        if s.phase != .armed && s.phase != .found && s.phase != .near { return stay(s) }
        if videoId.isEmpty {
            return SongTapReduction(state: failed(s, .nothingToSend), effects: [.notice(.nothingToSend)])
        }
        var n = s
        n.phase = .offered
        n.peer = 0
        n.videoId = videoId
        return SongTapReduction(state: n, effects: [.publishOffer(peer: 0, videoId: videoId)])
    }

    private static func verdictReason(_ v: SongTapLimitVerdict) -> SongTapFailReason {
        switch v {
        case .tooSoon: .tooSoon
        case .duplicate: .duplicate
        case .muted: .muted
        default: .limit
        }
    }

    private static func offerReceived(_ s: SongTapSessionState, peer: Int, videoId: String, senderKey: Int32, nowMs: Int64) -> SongTapReduction {
        let waiting = s.phase == .armed || s.phase == .found || s.phase == .near || (s.phase == .transferring && s.videoId.isEmpty)
        if s.role == .send {
            // A sender being offered a song: both phones are sending.
            let active = s.phase == .found || s.phase == .near || s.phase == .offered
            return active ? SongTapReduction(state: failed(s, .bothSending), effects: teardown(s) + [.notice(.bothSending)]) : stay(s)
        }
        if !waiting { return stay(s) }
        // A beam fetched after the tap (no prefetch) commits when it arrives: that is when the haptic belongs.
        var n = s
        n.pre = false
        return admitOffer(n, peer: peer, videoId: videoId, senderKey: senderKey, nowMs: nowMs, withTick: peer != 0)
    }

    /// The receiver has a checked offer in hand and the tap (or a code) says take it: limits, then ask or save and beam.
    private static func admitOffer(_ s: SongTapSessionState, peer: Int, videoId: String, senderKey: Int32, nowMs: Int64,
                                   withTick: Bool) -> SongTapReduction {
        let verdict = s.limits.admit(nowMs: nowMs, videoId: videoId, senderKey: senderKey)
        if verdict != .allowed {
            let reason = verdictReason(verdict)
            var withPeer = s
            withPeer.peer = peer
            // The sender has already started its beam (spec 5): it is told this one will not be taken.
            return SongTapReduction(state: failed(withPeer, reason),
                                    effects: (peer != 0 ? [.sendDecline(peer: peer)] : []) + [.notice(reason), .haptic(.warn)])
        }
        var known = s
        known.peer = peer
        known.videoId = videoId
        known.senderKey = senderKey
        let tick: [SongTapSessionEffect] = withTick ? [.haptic(.tick)] : []
        if s.askFirst {
            known.phase = .offered
            return SongTapReduction(state: known, effects: tick + [.scheduleTimeout(.consent, afterMs: consentTimeoutMs)])
        }
        known.phase = .transferring
        return SongTapReduction(state: known, effects: tick + saveEffects(videoId: videoId, nowMs: nowMs))
    }

    /// Saving starts and the beam starts with it, on every route: the beam does not wait for the save, the sender or a `go`
    /// (spec 5). The receiver's card says "Adding" until the save result arrives; a save that fails ends the beam.
    private static func saveEffects(videoId: String, nowMs: Int64) -> [SongTapSessionEffect] {
        [.saveSong(videoId: videoId), .scheduleTimeout(.save, afterMs: saveTimeoutMs), .startBeam(role: .receive, startMs: nowMs)]
    }

    private static func offerRejected(_ s: SongTapSessionState) -> SongTapReduction {
        if s.role != .receive { return stay(s) }
        if s.phase == .armed || s.phase == .found || s.phase == .near { return SongTapReduction(state: s, effects: [.noticeInvalidCode]) }
        if s.phase == .transferring && s.videoId.isEmpty {
            return SongTapReduction(state: failed(s, .invalidOffer), effects: [.notice(.invalidOffer), .haptic(.warn)])
        }
        return stay(s)
    }

    private static func ackReceived(_ s: SongTapSessionState, nowMs: Int64) -> SongTapReduction {
        if s.role != .send || s.peer == 0 { return stay(s) }
        if s.phase == .offered {
            // The receiver committed and saved before this phone noticed the tap: the beam starts now.
            var n = s
            n.acked = true
            return commitSend(n, nowMs: nowMs)
        }
        if s.phase != .transferring || s.acked { return stay(s) }
        var n = s
        n.acked = true
        if s.beamDone {
            n.phase = .saved
            return SongTapReduction(state: n, effects: [.haptic(.success)])
        }
        return stay(n)
    }

    private static func beamFinished(_ s: SongTapSessionState) -> SongTapReduction {
        if s.role != .send || s.phase != .transferring { return stay(s) }
        var n = s
        n.beamDone = true
        // The session ends when the beam has played and the receiver has said it saved (a QR beam has no peer to wait for).
        if s.acked || s.peer == 0 {
            n.phase = .saved
            return SongTapReduction(state: n, effects: [.haptic(.success)])
        }
        return stay(n)
    }

    private static func accept(_ s: SongTapSessionState, nowMs: Int64) -> SongTapReduction {
        if s.role != .receive || s.phase != .offered || s.videoId.isEmpty { return stay(s) }
        var n = s
        n.phase = .transferring
        n.askFirst = false
        n.autoSaves = 0
        return SongTapReduction(state: n, effects: saveEffects(videoId: s.videoId, nowMs: nowMs))
    }

    private static func decline(_ s: SongTapSessionState) -> SongTapReduction {
        if s.role != .receive || s.phase != .offered { return stay(s) }
        var n = s
        n.phase = .declined
        return SongTapReduction(state: n, effects: s.peer != 0 ? [.sendDecline(peer: s.peer)] : [])
    }

    private static func saveResult(_ s: SongTapSessionState, outcome: SongTapSaveOutcome, nowMs: Int64) -> SongTapReduction {
        if s.role != .receive || s.phase != .transferring || s.videoId.isEmpty { return stay(s) }
        let linked = s.peer != 0
        let ack: [SongTapSessionEffect] = linked ? [.sendAck(peer: s.peer)] : []
        let decline: [SongTapSessionEffect] = linked ? [.sendDecline(peer: s.peer)] : []
        switch outcome {
        case .saved:
            // Every `askAgainAfter`-th beam saved without asking makes the next one ask: consent is not for ever.
            let auto = s.autoSaves + 1
            let ask = auto >= askAgainAfter
            var n = s
            n.phase = .saved
            n.askFirst = ask
            n.alreadyHad = false
            n.autoSaves = ask ? 0 : auto
            n.limits = s.limits.accepted(nowMs: nowMs, videoId: s.videoId)
            return SongTapReduction(state: n, effects: ack + [.haptic(.success)])
        case .alreadyHad:
            var n = s
            n.phase = .saved
            n.alreadyHad = true
            n.limits = s.limits.accepted(nowMs: nowMs, videoId: s.videoId)
            return SongTapReduction(state: n, effects: ack + [.haptic(.tick)])
        case .notFound:
            var n = failed(s, .notFound)
            n.limits = s.limits.attempted(nowMs: nowMs)
            return SongTapReduction(state: n, effects: decline + [.notice(.notFound), .haptic(.warn)])
        case .failed:
            var n = failed(s, .saveFailed)
            n.limits = s.limits.attempted(nowMs: nowMs)
            return SongTapReduction(state: n, effects: decline + [.notice(.saveFailed), .haptic(.warn)])
        }
    }

    private static func undo(_ s: SongTapSessionState, nowMs: Int64) -> SongTapReduction {
        if s.role != .receive || s.phase != .saved || s.alreadyHad || s.videoId.isEmpty { return stay(s) }
        var next = clear(s, .armed)
        next.limits = s.limits.undone(nowMs: nowMs, senderKey: s.senderKey)
        return SongTapReduction(state: next, effects: [.undoSave(videoId: s.videoId)])
    }

    private static func cancel(_ s: SongTapSessionState) -> SongTapReduction {
        switch s.phase {
        case .found, .near, .offered, .transferring:
            var n = s
            n.phase = .cancelled
            return SongTapReduction(state: n, effects: teardown(s))
        default:
            return stay(s)
        }
    }

    private static func dismiss(_ s: SongTapSessionState) -> SongTapReduction {
        isTerminal(s.phase) ? SongTapReduction(state: clear(s, .armed), effects: []) : stay(s)
    }

    private static func timeout(_ s: SongTapSessionState, _ tag: SongTapTimeoutTag) -> SongTapReduction {
        if tag == .ack && s.role == .send && s.phase == .transferring && !s.acked && s.peer != 0 {
            return SongTapReduction(state: failed(s, .timeout), effects: teardown(s) + [.haptic(.warn)])
        }
        if tag == .target && s.role == .send && s.phase == .offered && s.target != 0 {
            var n = s
            n.phase = .cancelled
            return SongTapReduction(state: n, effects: teardown(s))
        }
        if tag == .read && s.role == .receive && s.phase == .transferring && s.videoId.isEmpty {
            return SongTapReduction(state: failed(s, .timeout), effects: teardown(s) + [.haptic(.warn)])
        }
        if tag == .consent && s.role == .receive && s.phase == .offered {
            var n = s
            n.phase = .declined
            return SongTapReduction(state: n, effects: s.peer != 0 ? [.sendDecline(peer: s.peer)] : [])
        }
        if tag == .save && s.role == .receive && s.phase == .transferring && !s.videoId.isEmpty {
            return SongTapReduction(state: failed(s, .timeout), effects: teardown(s) + [.haptic(.warn)])
        }
        return stay(s)
    }
}
