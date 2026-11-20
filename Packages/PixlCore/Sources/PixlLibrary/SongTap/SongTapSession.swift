// One Song Tap session as a pure `reduce(state, event) -> (state, effects)`: no clock, no radio, no storage. A
// transport (QR now, Bluetooth next) turns what it sees into `SongTapSessionEvent`s, the controller performs the
// `SongTapSessionEffect`s, and both platforms are proven to agree by golden event traces. A transliteration of
// `SongTapSession.kt`.
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
    case ack, read, consent, save

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

    public init(phase: SongTapPhase, role: SongTapRole, peer: Int, videoId: String, fail: SongTapFailReason?, askFirst: Bool, alreadyHad: Bool,
                senderKey: Int32, limits: SongTapRateLimits, autoSaves: Int = 0) {
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
    }

    public func describe() -> String {
        "\(phase.code) role=\(role.code) peer=\(peer) vid=\(videoId.isEmpty ? "-" : videoId) fail=\(fail?.code ?? "-") " +
            "ask=\(askFirst ? 1 : 0) had=\(alreadyHad ? 1 : 0) key=\(senderKey)"
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
    /// The detector fired for `peer`; `videoId` is what plays now on this phone (empty when nothing does).
    case tapDetected(peer: Int, videoId: String)
    /// The sender put its QR code up for `videoId`.
    case qrShown(videoId: String)
    /// A valid offer arrived (checked by the transport): from `peer` (0 for a QR code), made by `senderKey`.
    case offerReceived(peer: Int, videoId: String, senderKey: Int32, nowMs: Int64)
    /// Something arrived that is not a valid offer (a stranger's QR code, a bad signature, a stale frame).
    case offerRejected
    case ackReceived(nowMs: Int64, rttMs: Int64)
    case goReceived(nowMs: Int64, rttMs: Int64)
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
        case .tapDetected(let p, let v): "tap(\(p),\(v.isEmpty ? "-" : v))"
        case .qrShown(let v): "qrShown(\(v))"
        case .offerReceived(let p, let v, let k, let now): "offer(\(p),\(v),\(k),\(now))"
        case .offerRejected: "offerRejected"
        case .ackReceived(let now, let rtt): "ack(\(now),\(rtt))"
        case .goReceived(let now, let rtt): "go(\(now),\(rtt))"
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
    case sendGo(peer: Int, startMs: Int64)
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
        case .sendGo(let p, let start): "sendGo(\(p),\(start))"
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
        case .tapDetected(let peer, let videoId): return tap(s, peer: peer, videoId: videoId)
        case .qrShown(let videoId): return qrShown(s, videoId)
        case .offerReceived(let peer, let videoId, let senderKey, let nowMs):
            return offerReceived(s, peer: peer, videoId: videoId, senderKey: senderKey, nowMs: nowMs)
        case .offerRejected: return offerRejected(s)
        case .ackReceived(let nowMs, _): return ackReceived(s, nowMs: nowMs)
        case .goReceived(let nowMs, let rttMs): return goReceived(s, nowMs: nowMs, rttMs: rttMs)
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
            return SongTapReduction(state: n, effects: [])
        case .offered, .transferring:
            // A receiver that holds a checked offer does not need the sender any more: pulling the phones apart after a
            // tap is normal, and Add / save must still work. Only a beam still being read is lost.
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

    private static func tap(_ s: SongTapSessionState, peer: Int, videoId: String) -> SongTapReduction {
        if (s.phase != .found && s.phase != .near) || s.peer != peer { return stay(s) }
        if s.role == .send {
            if videoId.isEmpty {
                return SongTapReduction(state: failed(s, .nothingToSend), effects: [.notice(.nothingToSend), .haptic(.warn)])
            }
            var n = s
            n.phase = .offered
            n.videoId = videoId
            return SongTapReduction(state: n, effects: [
                .publishOffer(peer: peer, videoId: videoId),
                .haptic(.tick),
                .scheduleTimeout(.ack, afterMs: ackTimeoutMs),
            ])
        }
        var n = s
        n.phase = .transferring
        n.videoId = ""
        return SongTapReduction(state: n, effects: [
            .readOffer(peer: peer),
            .haptic(.tick),
            .scheduleTimeout(.read, afterMs: readTimeoutMs),
        ])
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
        let verdict = s.limits.admit(nowMs: nowMs, videoId: videoId, senderKey: senderKey)
        if verdict != .allowed {
            let reason = verdictReason(verdict)
            var withPeer = s
            withPeer.peer = peer
            return SongTapReduction(state: failed(withPeer, reason), effects: [.notice(reason), .haptic(.warn)])
        }
        var known = s
        known.peer = peer
        known.videoId = videoId
        known.senderKey = senderKey
        if s.askFirst {
            known.phase = .offered
            return SongTapReduction(state: known, effects: [.scheduleTimeout(.consent, afterMs: consentTimeoutMs)])
        }
        known.phase = .transferring
        return SongTapReduction(state: known, effects: saveEffects(peer: peer, videoId: videoId, nowMs: nowMs))
    }

    /// Saving starts. Over Bluetooth the sender is told only when the save is done (`saveResult`), so it never celebrates a
    /// beam that did not land; without a peer (a QR code, or the phones already apart) the beam starts at once.
    private static func saveEffects(peer: Int, videoId: String, nowMs: Int64) -> [SongTapSessionEffect] {
        var out: [SongTapSessionEffect] = [.saveSong(videoId: videoId), .scheduleTimeout(.save, afterMs: saveTimeoutMs)]
        if peer == 0 { out.append(.startBeam(role: .receive, startMs: nowMs)) }
        return out
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
        if s.role != .send || s.phase != .offered || s.peer == 0 { return stay(s) }
        let start = SongTapHandshake.senderStartMs(nowMs)
        var n = s
        n.phase = .transferring
        return SongTapReduction(state: n, effects: [.sendGo(peer: s.peer, startMs: start), .startBeam(role: .send, startMs: start)])
    }

    private static func goReceived(_ s: SongTapSessionState, nowMs: Int64, rttMs: Int64) -> SongTapReduction {
        if s.role != .receive || s.peer == 0 || s.videoId.isEmpty { return stay(s) }
        if s.phase != .transferring && s.phase != .saved { return stay(s) }
        return SongTapReduction(state: s, effects: [.startBeam(role: .receive, startMs: SongTapHandshake.receiverStartMs(receiptMs: nowMs, rttMs: rttMs))])
    }

    private static func beamFinished(_ s: SongTapSessionState) -> SongTapReduction {
        if s.role == .send && s.phase == .transferring {
            var n = s
            n.phase = .saved
            return SongTapReduction(state: n, effects: [.haptic(.success)])
        }
        return stay(s)
    }

    private static func accept(_ s: SongTapSessionState, nowMs: Int64) -> SongTapReduction {
        if s.role != .receive || s.phase != .offered || s.videoId.isEmpty { return stay(s) }
        // The beam of a Bluetooth offer starts when the sender answers, a QR beam now.
        var n = s
        n.phase = .transferring
        n.askFirst = false
        n.autoSaves = 0
        return SongTapReduction(state: n, effects: saveEffects(peer: s.peer, videoId: s.videoId, nowMs: nowMs))
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
        if tag == .ack && s.role == .send && s.phase == .offered && s.peer != 0 {
            return SongTapReduction(state: failed(s, .timeout), effects: teardown(s) + [.haptic(.warn)])
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
