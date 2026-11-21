// Song Tap over Bluetooth LE: finds the other phone, decides they touched, and carries the offer. A port of Android's
// `BleTransport`; the wire is `SongTapWire`, the same bytes on both platforms.
//
// All decisions live here and in the pure core; the platform is behind `SongTapBleRadio` and the accelerometer behind
// `SongTapImpulseSource`, so the whole route is tested over fakes (drop, duplicate, late, cancel, both sending). Nothing runs
// until `start`, and `start` is only called while the Song Tap screen is armed in the foreground: no scanning or
// advertising otherwise, and no sensor either.
//
// Roles. A phone sending advertises the send service and serves the offer; a phone receiving advertises the receive service
// and connects, as a client, to the sender it is near. A beam therefore always travels one way over one connection. Both
// phones scan for both services, so each learns the other's role from the advertisement alone.
//
// Main actor only. Events reach the engine after the call that raised them has finished (never in the middle of it), in the
// order they were raised, so the engine may call straight back into the route.

/// The numbers of the Bluetooth route that are not the tap detector's (those are `SongTapTuning`, in the core).
public enum SongTapBleTuning {
    /// How often the housekeeping runs while armed.
    public static let tickMs: Int64 = 250
    /// A phone not heard from for this long has left.
    public static let peerTimeoutMs: Int64 = 2_500
    /// The detector follows one phone; another takes over only when it is this many dB stronger.
    public static let focusSwitchDb = 6
    /// After a failed or dropped connection, wait this long before trying again.
    public static let reconnectMs: Int64 = 1_500
    /// A connection to a phone that has not been near for this long is closed.
    public static let idleDisconnectMs: Int64 = 4_000
    /// The sender may not have its offer ready when the receiver first reads it; ask again this often.
    public static let readRetryMs: Int64 = 250
    public static let maxReadAttempts = 10
    /// A sender takes a receiver's tap message as a tap when its own detector saw that receiver's signal jump within this long.
    public static let peerTapJumpWindowMs: Int64 = 1_500
    /// A jerk the other phone reports only counts when its signal is at least this strong. The other phone's word cannot be
    /// checked (anything that advertises our service can claim it was jerked just now), so it may shorten the hold only for a
    /// phone that is close, never for one that is merely in the room.
    public static let peerImpulseMinDbm = -62
    /// At most this many phones are tracked at once; a flood of made-up addresses pushes out the one heard longest ago (never
    /// the one being followed).
    public static let maxPeers = 24
    /// A connection that has not come up in this long is given up (the phone may still be advertising but not answering).
    public static let connectTimeoutMs: Int64 = 3_000
    /// A signed frame is the payload plus this many bytes (see `SongTapSigning.encodeFrame`).
    public static let frameOverheadBytes = 142
}

@MainActor
public final class SongTapBleRoute: SongTapTransport, SongTapBleRadioListener {
    public let id = "ble"
    public var onEvent: ((SongTapTransportEvent) -> Void)?

    /// Whether Bluetooth is running, and if not why (the screen words it).
    public private(set) var status: SongTapBleStatus = .idle
    /// The approach glow, 0...500 permille, from the smoothed signal of the phone being followed.
    public private(set) var glow = 0

    /// Called when `status` or `glow` changed.
    public var onStatusChange: ((SongTapBleStatus) -> Void)?
    public var onGlowChange: ((Int) -> Void)?

    private enum Conn { case closed, connecting, ready }
    private enum Write { case hello, tap, ack, decline }

    private final class Peer {
        let id: Int
        let address: String
        var role = SongTapRole.send
        var lastSeenMs: Int64 = 0
        var lastNearMs: Int64 = 0
        var rssi = 0
        var detector = SongTapDetectorState.initial
        var nearReported = false
        var glow = 0
        var peerImpulseLocalMs: Int64 = -1
        var infoAskedAtMs: Int64 = 0
        var conn = Conn.closed
        var nextConnectAtMs: Int64 = 0
        var challenge: [UInt8]?
        var writes: [Write] = []
        var ackAtMs: Int64 = 0
        var rttMs: Int64 = 0
        var wantRead = false
        var readInFlight = false
        var readAttempts = 0
        var inTransfer = false
        var lastFire = SongTapFireReason.none
        var lastFireMs: Int64 = -1
        var lastJumpMs: Int64 = -1
        var connectStartedMs: Int64 = 0

        init(id: Int, address: String) {
            self.id = id
            self.address = address
        }
    }

    private let radio: any SongTapBleRadio
    private let impulses: any SongTapImpulseSource
    private let clock: any SongTapClock
    private let diag: SongTapDiagnostics
    private let scheduler: any SongTapBleScheduler
    private let newSigner: () -> any SongTapSignerPort
    private let verifier: any SongTapSignatureVerifier
    private let random: (Int) -> [UInt8]

    private var started = false
    private var ticking = false
    private var role = SongTapRole.send
    private var nextPeerId = 1
    private var peers: [String: Peer] = [:]
    private var byId: [Int: Peer] = [:]
    private var focus: Peer?
    private var ownImpulseMs: Int64 = -1

    // The sender's side. Three separate facts about who is talking to our GATT server, because a control write is only
    // believed from the phone it is about: `tapClient` wrote the tap message, `offerClient` read the offer, `ackClient`
    // acknowledged it. An acknowledgement or a decline from any other connection is ignored, and Go goes to `ackClient`.
    private var signer: (any SongTapSignerPort)?
    private var offer: [UInt8]?
    private var challenges: [String: [UInt8]] = [:]
    private var tapClient: String?
    private var offerClient: String?
    private var ackClient: String?

    // Events wait here until the call that raised them is over.
    private var pending: [SongTapTransportEvent] = []
    private var draining = false

    public init(radio: any SongTapBleRadio, impulses: any SongTapImpulseSource, clock: any SongTapClock, diag: SongTapDiagnostics,
                scheduler: any SongTapBleScheduler, newSigner: @escaping () -> any SongTapSignerPort,
                verifier: any SongTapSignatureVerifier, random: @escaping (Int) -> [UInt8]) {
        self.radio = radio
        self.impulses = impulses
        self.clock = clock
        self.diag = diag
        self.scheduler = scheduler
        self.newSigner = newSigner
        self.verifier = verifier
        self.random = random
    }

    private func emit(_ e: SongTapTransportEvent) { pending.append(e) }

    private func drain() {
        if draining { return }
        draining = true
        while !pending.isEmpty {
            let e = pending.removeFirst()
            onEvent?(e)
        }
        draining = false
    }

    private func setStatus(_ s: SongTapBleStatus) {
        if status == s { return }
        status = s
        onStatusChange?(s)
    }

    private func setGlow(_ g: Int) {
        if glow == g { return }
        glow = g
        onGlowChange?(g)
    }

    // MARK: SongTapTransport

    public func start(role: SongTapRole) {
        defer { drain() }
        startLocked(role)
    }

    public func stop() {
        defer { drain() }
        if started { diag.log(clock.elapsedMs(), "disarmed") }
        stopLocked()
    }

    /// The permission or Bluetooth state changed while armed: try again.
    public func restart() {
        defer { drain() }
        if started && (status == .noPermission || status == .bluetoothOff || status == .unsupported) { startLocked(role) }
    }

    /// The session is back to waiting: say again which phone is close, so it can be tapped.
    public func resync() {
        defer { drain() }
        guard let f = focus else { return }
        emit(.peerFound(f.id))
        if f.detector.near { emit(.peerNear(f.id)) }
        f.nearReported = f.detector.near
    }

    private func startLocked(_ newRole: SongTapRole) {
        if started { stopLocked() }
        role = newRole
        started = true
        signer = newRole == .send ? newSigner() : nil
        let result = radio.start(role: newRole, listener: self)
        setStatus(result)
        if result != .active {
            diag.log(clock.elapsedMs(), "bluetooth unavailable: \(result.rawValue)")
            return
        }
        beginActiveLocked()
    }

    /// The radio is running: listen to the accelerometer and start the housekeeping.
    private func beginActiveLocked() {
        if ticking { return }
        ticking = true
        impulses.start { [weak self] t in self?.onImpulse(t) }
        scheduler.startTicking(everyMs: SongTapBleTuning.tickMs) { [weak self] in self?.tick() }
        diag.log(clock.elapsedMs(), "armed to \(role == .send ? "send" : "receive")")
    }

    private func stopLocked() {
        started = false
        ticking = false
        scheduler.stopTicking()
        impulses.stop()
        radio.stop()
        peers.removeAll()
        byId.removeAll()
        focus = nil
        signer = nil
        offer = nil
        challenges.removeAll()
        tapClient = nil
        offerClient = nil
        ackClient = nil
        ownImpulseMs = -1
        setGlow(0)
        setStatus(.idle)
    }

    // MARK: Sender

    public func publishOffer(peer: Int, payload: [UInt8]) {
        defer { drain() }
        if !started || role != .send { return }
        offer = fit(payload)
        // A new offer starts with nobody having read or acknowledged it: a late answer to the last one is not an answer to this.
        offerClient = nil
        ackClient = nil
        diag.log(clock.elapsedMs(), offer == nil ? "offer does not fit one frame" : "offer ready (\(payload.count) bytes)")
    }

    public func withdrawOffer() {
        offer = nil
        offerClient = nil
        ackClient = nil
        tapClient = nil
    }

    /// A signed frame has to fit one attribute: drop the optional parts, art first, until it does.
    private func fit(_ payload: [UInt8]) -> [UInt8]? {
        func fits(_ b: [UInt8]) -> Bool { b.count + SongTapBleTuning.frameOverheadBytes <= SongTapSigning.maxFrameBytes }
        if fits(payload) { return payload }
        guard case .ok(let decoded) = SongTapPayloads.decode(payload) else { return nil }
        var p = decoded
        p.artUrl = nil
        if let bytes = SongTapPayloads.encode(p), fits(bytes) { return bytes }
        p.isrc = nil
        if let bytes = SongTapPayloads.encode(p), fits(bytes) { return bytes }
        if p.ytVideoId != nil {
            p.spotifyId = nil
            if let bytes = SongTapPayloads.encode(p), fits(bytes) { return bytes }
        }
        return nil
    }

    public func sendGo(peer: Int, startMs: Int64) {
        defer { drain() }
        guard let client = ackClient else { return }
        radio.notifyGo(client: client)
        diag.log(clock.elapsedMs(), "go sent")
    }

    // Server callbacks (a receiver talking to our GATT server).

    public func serverInfo() -> [UInt8] {
        SongTapWire.encodeInfo(ageMs: SongTapHandshake.impulseAgeMs(nowMs: clock.elapsedMs(), impulseMs: ownImpulseMs))
    }

    public func serverOffer(client: String) -> [UInt8]? {
        if !started || role != .send { return nil }
        guard let payload = offer else { return nil }
        // Only the phone that tapped (and, once somebody has read it, only that reader) is given the offer.
        if let taker = tapClient, taker != client { return nil }
        if let reader = offerClient, reader != client { return nil }
        guard let challenge = challenges[client], let key = signer else { return nil }
        let ts = clock.wallMs()
        guard let message = SongTapSigning.signingBytes(payload: payload, challenge: challenge, timestampMs: ts),
              let signature = key.sign(message) else { return nil }
        let frame = SongTapSigning.encodeFrame(SongTapSignedOffer(payload: payload, timestampMs: ts, publicKey: key.publicKey, signature: signature))
        // A challenge answers one read: the receiver sends a new one for the next beam.
        challenges[client] = nil
        if frame != nil { offerClient = client }
        diag.log(clock.elapsedMs(), frame == nil ? "frame too big" : "offer read by a receiver (\(frame?.count ?? 0) bytes)")
        return frame
    }

    public func serverControl(client: String, value: [UInt8]) -> Bool {
        defer { drain() }
        if !started || role != .send { return false }
        guard let message = SongTapWire.decodeControl(value) else { return false }
        let t = clock.elapsedMs()
        switch message {
        case .hello(let challenge):
            challenges[client] = challenge
        case .ack:
            if offer == nil || client != offerClient {
                diag.log(t, "ack from a phone that did not read the offer, ignored")
            } else {
                ackClient = client
                diag.log(t, "ack from receiver")
                if let f = focus { emit(.ack(peer: f.id)) }
            }
        case .decline:
            if offer == nil || client != offerClient {
                diag.log(t, "decline from a phone that did not read the offer, ignored")
            } else {
                diag.log(t, "declined by receiver")
                if let f = focus { emit(.declined(peer: f.id)) }
            }
        case .tap(let ageMs):
            // The tap is believed when this phone saw the signal of the phone it is following jump just now.
            let f = focus
            let sawJump = f != nil && f!.lastJumpMs >= 0 && t - f!.lastJumpMs <= SongTapBleTuning.peerTapJumpWindowMs
            diag.log(t, "receiver reports a tap (jerk \(ageMs) ms ago), own jump \(sawJump ? "seen" : "not seen")")
            if let f, f.role == .receive, sawJump, offer == nil {
                tapClient = client
                emit(.tap(peer: f.id))
            }
        }
        return true
    }

    public func serverClientGone(client: String) {
        defer { drain() }
        challenges[client] = nil
        let had = ackClient == client || offerClient == client
        if ackClient == client { ackClient = nil }
        if offerClient == client { offerClient = nil }
        if tapClient == client { tapClient = nil }
        // A receiver leaving in the middle of a beam is a lost peer; leaving afterwards is nothing.
        if had && offer != nil, let f = focus { emit(.peerLost(f.id)) }
    }

    // MARK: Receiver

    public func readOffer(peer: Int) {
        defer { drain() }
        guard let p = byId[peer], role == .receive, p.role == .send else {
            emit(.offerInvalid)
            return
        }
        p.inTransfer = true
        p.wantRead = true
        p.readAttempts = 0
        switch p.conn {
        case .ready: startRead(p)
        case .closed: connect(p, clock.elapsedMs())
        case .connecting: break
        }
    }

    private func startRead(_ p: Peer) {
        p.wantRead = false
        p.readInFlight = true
        radio.readOffer(address: p.address)
    }

    public func sendAck(peer: Int) {
        defer { drain() }
        guard let p = byId[peer], p.conn == .ready else { emit(.peerLost(peer)); return }
        queueWrite(p, .ack, SongTapWire.encodeAck())
    }

    public func sendDecline(peer: Int) {
        defer { drain() }
        guard let p = byId[peer] else { return }
        p.inTransfer = false
        if p.conn == .ready { queueWrite(p, .decline, SongTapWire.encodeDecline()) }
    }

    public func abort(peer: Int) {
        defer { drain() }
        if role == .send {
            if let c = ackClient ?? offerClient { radio.dropClient(client: c) }
            return
        }
        guard let p = byId[peer] else { return }
        p.inTransfer = false
        p.wantRead = false
        p.readInFlight = false
        if p.conn != .closed {
            radio.disconnect(address: p.address)
            p.conn = .closed
            p.writes.removeAll()
            p.challenge = nil
            p.nextConnectAtMs = clock.elapsedMs() + SongTapBleTuning.reconnectMs
        }
    }

    private func queueWrite(_ p: Peer, _ kind: Write, _ bytes: [UInt8]) {
        p.writes.append(kind)
        if kind == .ack { p.ackAtMs = clock.elapsedMs() }
        radio.writeControl(address: p.address, value: bytes)
    }

    private func sendHello(_ p: Peer) {
        let challenge = random(SongTapSigning.challengeBytes)
        p.challenge = challenge
        guard let bytes = SongTapWire.encodeHello(challenge: challenge) else { return }
        queueWrite(p, .hello, bytes)
    }

    private func connect(_ p: Peer, _ t: Int64) {
        p.conn = .connecting
        p.connectStartedMs = t
        radio.connect(address: p.address)
        diag.log(t, "connecting to #\(p.id)")
    }

    private func failTransfer(_ p: Peer) {
        p.inTransfer = false
        p.wantRead = false
        emit(.peerLost(p.id))
    }

    public func onConnected(address: String, ok: Bool) {
        defer { drain() }
        let t = clock.elapsedMs()
        guard let p = peers[address], started else { radio.disconnect(address: address); return }
        if !ok {
            p.conn = .closed
            p.nextConnectAtMs = t + SongTapBleTuning.reconnectMs
            diag.log(t, "connection to #\(p.id) failed")
            if p.inTransfer { failTransfer(p) }
            return
        }
        p.conn = .ready
        diag.log(t, "connected to #\(p.id)")
        sendHello(p)
        if p.wantRead { startRead(p) }
    }

    public func onDisconnected(address: String) {
        defer { drain() }
        guard let p = peers[address] else { return }
        let t = clock.elapsedMs()
        p.conn = .closed
        p.writes.removeAll()
        p.readInFlight = false
        p.challenge = nil
        p.nextConnectAtMs = t + SongTapBleTuning.reconnectMs
        diag.log(t, "disconnected from #\(p.id)")
        if p.inTransfer { failTransfer(p) }
    }

    public func onInfoRead(address: String, value: [UInt8]?) {
        defer { drain() }
        guard let p = peers[address] else { return }
        let t = clock.elapsedMs()
        let age = value.flatMap { SongTapWire.decodeInfo($0) } ?? -1
        p.peerImpulseLocalMs = SongTapHandshake.peerImpulseLocalMs(receiptMs: t, ageMs: age, rttMs: t - p.infoAskedAtMs)
        diag.log(t, "sender's last jerk \(age < 0 ? "none" : "\(age) ms ago")")
    }

    public func onOfferRead(address: String, value: [UInt8]?) {
        defer { drain() }
        guard let p = peers[address] else { return }
        p.readInFlight = false
        if !p.inTransfer { return }
        guard let value else {
            p.readAttempts += 1
            if p.readAttempts < SongTapBleTuning.maxReadAttempts {
                scheduler.after(ms: SongTapBleTuning.readRetryMs) { [weak self, weak p] in
                    guard let self, let p else { return }
                    if self.started && p.inTransfer && p.conn == .ready && !p.readInFlight { self.startRead(p) }
                    self.drain()
                }
            } else {
                diag.log(clock.elapsedMs(), "the sender had no offer")
                p.inTransfer = false
                emit(.offerInvalid)
                if p.conn == .ready { sendHello(p) }
            }
            return
        }
        let challenge = p.challenge
        let frame = SongTapSigning.decodeFrame(value)
        let verdict: SongTapOfferCheck
        if let frame, let challenge {
            verdict = SongTapSigning.check(frame, challenge: challenge, nowMs: clock.wallMs(), verifier: verifier)
        } else {
            verdict = .badFrame
        }
        p.challenge = nil
        if p.conn == .ready { sendHello(p) }
        if verdict == .ok, let frame {
            diag.log(clock.elapsedMs(), "offer read and checked")
            emit(.offer(peer: p.id, payload: frame.payload, senderKey: SongTapSigning.senderKey(frame.publicKey)))
        } else {
            diag.log(clock.elapsedMs(), "offer refused: \(verdict.code)")
            p.inTransfer = false
            emit(.offerInvalid)
        }
    }

    public func onControlWritten(address: String, ok: Bool) {
        defer { drain() }
        guard let p = peers[address], !p.writes.isEmpty else { return }
        let kind = p.writes.removeFirst()
        let t = clock.elapsedMs()
        if ok {
            if kind == .ack { p.rttMs = t - p.ackAtMs }
            return
        }
        diag.log(t, "write \(kind) failed")
        if kind == .ack || kind == .decline || kind == .hello {
            if p.inTransfer { failTransfer(p) }
        }
    }

    public func onNotified(address: String, value: [UInt8]) {
        defer { drain() }
        guard let p = peers[address] else { return }
        if !SongTapWire.isGo(value) { return }
        diag.log(clock.elapsedMs(), "go received (round trip \(p.rttMs) ms)")
        p.inTransfer = false
        emit(.go(peer: p.id, rttMs: p.rttMs))
    }

    public func onStatus(_ newStatus: SongTapBleStatus) {
        defer { drain() }
        if !started { return }
        if newStatus == .active {
            setStatus(newStatus)
            // Bluetooth was off or not yet allowed when Song Tap armed and is now ready.
            beginActiveLocked()
            return
        }
        // Bluetooth went away under us: whatever was in flight is lost.
        if let f = focus { emit(.peerLost(f.id)) }
        peers.removeAll()
        byId.removeAll()
        focus = nil
        offer = nil
        challenges.removeAll()
        ackClient = nil
        offerClient = nil
        tapClient = nil
        setGlow(0)
        ticking = false
        scheduler.stopTicking()
        impulses.stop()
        setStatus(newStatus)
        diag.log(clock.elapsedMs(), "bluetooth status: \(newStatus.rawValue)")
    }

    // MARK: Detection

    public func onSeen(address: String, role seenRole: SongTapRole, rssi: Int) {
        defer { drain() }
        if !started { return }
        let t = clock.elapsedMs()
        let p: Peer
        if let known = peers[address] {
            p = known
        } else {
            if peers.count >= SongTapBleTuning.maxPeers { evictOldest() }
            p = Peer(id: nextPeerId, address: address)
            nextPeerId += 1
            peers[address] = p
            byId[p.id] = p
            diag.log(t, "phone #\(p.id) appears, \(seenRole == .send ? "sending" : "receiving")")
        }
        p.role = seenRole
        p.lastSeenMs = t
        p.rssi = rssi

        let impulse = impulseFor(p, own: ownImpulseMs)
        let wasHeld = p.detector.heldSinceMs >= 0
        let step = SongTapDetector.step(p.detector, SongTapRssiSample(tMs: t, rssi: rssi), impulseMs: impulse)
        p.detector = step.state
        p.glow = step.glowPermille
        if step.state.near { p.lastNearMs = t }
        let jumping = step.state.heldSinceMs >= 0
        if jumping || step.fire != .none { p.lastJumpMs = t }
        if jumping && !wasHeld { onJumpStart(p, t) }

        updateFocus(t, p)
        if p === focus {
            setGlow(p.glow)
            if step.state.near != p.nearReported {
                p.nearReported = step.state.near
                emit(step.state.near ? .peerNear(p.id) : .peerFar(p.id))
                diag.log(t, step.state.near ? "#\(p.id) is near" : "#\(p.id) moved away")
            }
            diag.sample(t, rssi: rssi, smoothedDbm: dbm(step.state.fastQ), baselineDbm: dbm(step.state.baselineQ))
        }
        if step.fire != .none { onFire(p, step.fire, t) }
        maybeConnect(p, t)
        if diag.isEnabled() { diag.publish(t) { snapshot(t) } }
    }

    private func dbm(_ q: Int) -> Int { SongTapDetector.floorDiv(q, songTapRssiScale) }

    private func strength(_ p: Peer) -> Int { dbm(p.detector.fastQ) }

    /// The latest jerk the detector may use for `p`: this phone's own, or the peer's word when it is close enough to be believed.
    private func impulseFor(_ p: Peer, own: Int64) -> Int64 {
        let peer = p.peerImpulseLocalMs
        if own >= peer { return own }
        let close = p.detector.started && dbm(p.detector.fastQ) >= SongTapBleTuning.peerImpulseMinDbm
        return close ? peer : own
    }

    private func evictOldest() {
        var oldest: Peer?
        for q in peers.values where q !== focus && (oldest == nil || q.lastSeenMs < oldest!.lastSeenMs) { oldest = q }
        guard let gone = oldest else { return }
        peers[gone.address] = nil
        byId[gone.id] = nil
        if gone.conn != .closed { radio.disconnect(address: gone.address) }
        radio.forget(address: gone.address)
    }

    /// The jump has started: a receiver asks the sender how long ago it was jerked.
    private func onJumpStart(_ p: Peer, _ t: Int64) {
        diag.log(t, "signal of #\(p.id) jumped")
        if role == .receive && p.role == .send && p.conn == .ready {
            p.infoAskedAtMs = t
            radio.readInfo(address: p.address)
        }
    }

    private func updateFocus(_ t: Int64, _ seen: Peer) {
        if let current = focus {
            if current === seen { return }
            let busy = current.inTransfer || offer != nil
            let gone = t - current.lastSeenMs > SongTapBleTuning.peerTimeoutMs
            if busy && !gone { return }
            if !gone && strength(seen) < strength(current) + SongTapBleTuning.focusSwitchDb { return }
        }
        setFocus(seen, t)
    }

    private func setFocus(_ next: Peer?, _ t: Int64) {
        let old = focus
        if old === next { return }
        if let old {
            emit(.peerLost(old.id))
            if old.conn != .closed {
                radio.disconnect(address: old.address)
                old.conn = .closed
                old.writes.removeAll()
            }
        }
        focus = next
        guard let next else { setGlow(0); return }
        next.nearReported = next.detector.near
        setGlow(next.glow)
        emit(.peerFound(next.id))
        if next.nearReported { emit(.peerNear(next.id)) }
        diag.log(t, "following #\(next.id)")
    }

    private func onFire(_ p: Peer, _ reason: SongTapFireReason, _ t: Int64) {
        if p !== focus { setFocus(p, t) }
        p.lastFire = reason
        p.lastFireMs = t
        diag.log(t, "tap detected (\(reason.code)) with #\(p.id)")
        emit(.peerRole(peer: p.id, role: p.role))
        if role == .receive && p.role == .receive { return }
        emit(.tap(peer: p.id))
        if role == .receive && p.role == .send && p.conn == .ready {
            let age = SongTapHandshake.impulseAgeMs(nowMs: t, impulseMs: ownImpulseMs)
            queueWrite(p, .tap, SongTapWire.encodeTap(ageMs: age))
        }
    }

    private func maybeConnect(_ p: Peer, _ t: Int64) {
        if role != .receive || p.role != .send || p !== focus { return }
        if p.conn != .closed || !p.detector.near || t < p.nextConnectAtMs { return }
        connect(p, t)
    }

    /// The housekeeping, every `SongTapBleTuning.tickMs` while armed.
    public func tick() {
        defer { drain() }
        if !started { return }
        let t = clock.elapsedMs()
        for p in Array(peers.values) where t - p.lastSeenMs > SongTapBleTuning.peerTimeoutMs {
            peers[p.address] = nil
            byId[p.id] = nil
            if p.conn != .closed { radio.disconnect(address: p.address) }
            radio.forget(address: p.address)
            if p === focus {
                focus = nil
                setGlow(0)
                emit(.peerLost(p.id))
                diag.log(t, "#\(p.id) is gone")
            }
        }
        if focus == nil {
            var best: Peer?
            for p in peers.values.sorted(by: { $0.id < $1.id }) where best == nil || strength(p) > strength(best!) { best = p }
            if let best { setFocus(best, t) }
        }
        // A connection that never comes up is given up, so the peer can be tried again instead of staying "connecting".
        for p in peers.values where p.conn == .connecting && t - p.connectStartedMs > SongTapBleTuning.connectTimeoutMs {
            radio.disconnect(address: p.address)
            p.conn = .closed
            p.writes.removeAll()
            p.nextConnectAtMs = t + SongTapBleTuning.reconnectMs
            diag.log(t, "connection to #\(p.id) timed out")
            if p.inTransfer { failTransfer(p) }
        }
        if let f = focus {
            if f.conn == .ready && !f.inTransfer && !f.detector.near && t - f.lastNearMs > SongTapBleTuning.idleDisconnectMs {
                radio.disconnect(address: f.address)
                f.conn = .closed
                f.writes.removeAll()
                f.challenge = nil
            }
            maybeConnect(f, t)
        }
        if diag.isEnabled() { diag.publish(t) { snapshot(t) } }
    }

    private func onImpulse(_ tMs: Int64) {
        if !started { return }
        ownImpulseMs = tMs
        if focus?.detector.near == true { diag.log(tMs, "this phone was jerked") }
    }

    private func snapshot(_ t: Int64) -> SongTapDiagSnapshot {
        var s = SongTapDiagSnapshot()
        let f = focus
        let d = f?.detector
        s.status = status
        s.role = role == .send ? "send" : "receive"
        s.peersSeen = peers.count
        s.focus = f.map { "#\($0.id) \($0.role == .send ? "sending" : "receiving")" } ?? ""
        s.rssi = f?.rssi ?? 0
        s.smoothed = d.map { dbm($0.fastQ) } ?? 0
        s.baseline = d.map { dbm($0.baselineQ) } ?? 0
        s.jump = d.map { dbm($0.fastQ - $0.baselineQ) } ?? 0
        s.heldMs = (d == nil || d!.heldSinceMs < 0) ? -1 : t - d!.heldSinceMs
        s.near = d?.near == true
        switch f?.conn {
        case nil, .some(.closed): s.connection = "none"
        case .some(.connecting): s.connection = "connecting"
        case .some(.ready): s.connection = "connected"
        }
        s.ownJerkAgeMs = SongTapHandshake.impulseAgeMs(nowMs: t, impulseMs: ownImpulseMs)
        s.peerJerkAgeMs = f == nil ? -1 : SongTapHandshake.impulseAgeMs(nowMs: t, impulseMs: f!.peerImpulseLocalMs)
        if f == nil {
            s.detector = "no phone"
        } else if let d, d.heldSinceMs >= 0 {
            s.detector = "jump building"
        } else if d?.near == true {
            s.detector = "near"
        } else {
            s.detector = "far"
        }
        s.lastFire = (f == nil || f!.lastFireMs < 0) ? "-" : "\(f!.lastFire.code) \(t - f!.lastFireMs) ms ago"
        s.samples = diag.sampleCount()
        return s
    }

    /// For the diagnostics screen's "mark" buttons: write the current signal into the log under `label`.
    public func mark(_ label: String) {
        let t = clock.elapsedMs()
        if let f = focus {
            diag.log(t, "mark \(label): rssi \(f.rssi), smoothed \(dbm(f.detector.fastQ)), baseline \(dbm(f.detector.baselineQ))")
        } else {
            diag.log(t, "mark \(label): no phone")
        }
    }
}
