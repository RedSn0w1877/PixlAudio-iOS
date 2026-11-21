// Song Tap over Bluetooth LE: finds the other phone, decides they touched, and carries the offer. A port of Android's
// `BleTransport` (spec 6); the wire is `SongTapWire`, the same bytes on both platforms.
//
// All decisions live here and in the pure core; the platform is behind `SongTapBleRadio` and the accelerometer behind
// `SongTapImpulseSource`, so the whole route is tested over fakes (drop, duplicate, late, cancel, both sending). Nothing runs
// until `start`, and `start` is only called while the Song Tap screen is armed in the foreground: no scanning or advertising
// otherwise, and no sensor either.
//
// Spec 5, in short. A receiver connects only to a sender inside the near gate and, still before any tap, reads the sender's name
// and its signed offer (when the sender's listener has said yes to that phone), so when the detector fires the data is in hand and
// the beam starts at the first haptic, with nothing left to wait for. A sender serves the offer to the one phone it was armed to,
// only while that phone is near, and lists phones for the picker from advertisements alone.
//
// Spec 6, in short. Every reading is on the reference scale already (on an iPhone nothing is added: the iPhone IS the reference),
// the detector takes the sensitivity profile, and the first haptic of whichever phone's detector fires first tells the other phone at
// once over the link that exists (the one-sided tap, `SongTapPeerTap`).
//
// Roles. A phone sending advertises the send service and serves the offer; a phone receiving advertises the receive service
// and connects, as a client, to the sender it is near. A beam therefore always travels one way over one connection. Both
// phones scan for both services, so each learns the other's role from the advertisement alone.
//
// Main actor only. Events reach the engine after the call that raised them has finished (never in the middle of it), in the
// order they were raised, so the engine may call straight back into the route.

/// The numbers of the Bluetooth route that are not the tap detector's (those are `SongTapTuning` and `SongTapSensitivity`, in the core).
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
    /// The sender may not have its offer ready when the receiver reads it after the tap (no prefetch); ask again this often.
    public static let readRetryMs: Int64 = 250
    public static let maxReadAttempts = 10
    /// A jerk the other phone reports only counts when its signal (on the reference scale) is at least this strong. The other phone's
    /// word cannot be checked (anything that advertises our service can claim it was jerked just now), so it may shorten the hold only
    /// for a phone that is close, never for one that is merely in the room. (-62 before spec 6; resting 20 to 30 cm apart is about
    /// -60 on this scale, touching about -33.)
    public static let peerImpulseMinDbm = -55
    /// At most this many phones are tracked at once; a flood of made-up addresses pushes out the one heard longest ago (never
    /// the one being followed or the one a sender is armed to).
    public static let maxPeers = 24
    /// A connection that has not come up in this long is given up (the phone may still be advertising but not answering).
    public static let connectTimeoutMs: Int64 = 3_000
    /// A signed frame is the payload plus this many bytes (see `SongTapSigning.encodeFrame`).
    public static let frameOverheadBytes = 142
    /// The phone a sender is armed to is followed (and its offer served) even if its advertisements thin out for a while.
    public static let pinnedPeerTimeoutMs: Int64 = 10_000
    /// A receiver that is connected and near but holds no offer asks again this often (the sender's notification is the fast path).
    public static let prefetchRetryMs: Int64 = 2_000
    /// A prefetched offer older than this is read again (the signed frame and the payload carry times, the sender refreshes too).
    public static let prefetchMaxAgeMs: Int64 = 20_000
    /// The nearby list and the prompt are republished at most this often.
    public static let nearbyPublishMs: Int64 = 250
}

/// "No usable signal" for the one-sided tap rule: far below any gate.
private let noSignalDbm = -200

@MainActor
public final class SongTapBleRoute: SongTapTransport, SongTapBleRadioListener {
    public let id = "ble"
    public var onEvent: ((SongTapTransportEvent) -> Void)?

    /// Whether Bluetooth is running, and if not why (the screen words it).
    public private(set) var status: SongTapBleStatus = .idle
    /// The approach glow, 0...500 permille, from the smoothed signal of the phone being followed.
    public private(set) var glow = 0
    /// Sender: the phones advertising as receivers inside the list gate, strongest first, from advertisements alone (spec 5).
    public private(set) var nearby: [SongTapNearbyEntry] = []
    /// Sender: the phone to ask "Song drop to X?" about (inside the near gate, not told no), or nil.
    public private(set) var prompt: SongTapNearbyEntry?
    /// What the one-sided tap did last, for the diagnostics: the other phone's message and the verdict.
    public private(set) var lastPeerTapNote = "-"

    /// Called when `status`, `glow` or the nearby list changed.
    public var onStatusChange: ((SongTapBleStatus) -> Void)?
    public var onGlowChange: ((Int) -> Void)?
    public var onNearbyChange: (([SongTapNearbyEntry], SongTapNearbyEntry?) -> Void)?

    private enum Conn { case closed, connecting, ready }
    private enum Write { case hello, tap, ack, decline }

    /// An offer fetched ahead of the tap and checked.
    private struct Prefetch {
        var payload: [UInt8]
        var senderKey: Int32
        var atMs: Int64
    }

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
        /// The short name this phone advertised, and its full name once read from its Name characteristic.
        var name: String?
        var fullName: String?
        var nameAsked = false
        /// Receiver: the offer read and checked before any tap; nil when none.
        var prefetched: Prefetch?
        var lastPrefetchTryMs: Int64 = 0

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

    /// The name this phone shows other phones (set by the controller before arming).
    private var ownName = SongTapNames.fallback
    private var profile = SongTapSensitivity.default

    /// When this phone last fired itself or took a peer's tap, and when it last took a peer's tap (for no echo). -1 = never.
    private var lastTapMs: Int64 = -1
    private var lastPeerTapMs: Int64 = -1

    /// Sender: the phone the listener said yes to (the route's number), 0 when none.
    private var pinnedId = 0
    private var book = SongTapNearbyBook()
    private var lastNearbyMs: Int64 = -1_000_000

    // The sender's side. Three separate facts about who is talking to our GATT server, because a control write is only believed
    // from the phone it is about: `tapClient` wrote the tap message, `offerClient` read the offer, `ackClient` acknowledged it. An
    // acknowledgement or a decline from any other connection is ignored.
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

    // MARK: Settings the controller gives the route

    /// Sets the name shown to other phones; it takes effect the next time the route starts.
    public func setOwnName(_ name: String) {
        ownName = SongTapNames.orFallback(name)
    }

    /// Sets how sensitive the tap is (spec 6). Live: the next reading and the next jerk already use it.
    public func setSensitivity(_ value: SongTapSensitivity) {
        if value == profile { return }
        profile = value
        impulses.setSensitivity(value)
        diag.log(clock.elapsedMs(), "sensitivity set to \(value.code)")
    }

    public func sensitivity() -> SongTapSensitivity { profile }

    /// "No" on the prompt: that phone is not asked about for a minute.
    public func ignorePrompt(_ peer: Int) {
        book.ignore(peer, nowMs: clock.elapsedMs())
        publishNearby(clock.elapsedMs(), force: true)
    }

    /// The name of `peer` for a card: its full name when it gave one, else the short one it advertised.
    public func nameOf(_ peer: Int) -> String? {
        guard let p = byId[peer] else { return nil }
        return p.fullName ?? p.name
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
        let result = radio.start(role: newRole, listener: self, name: ownName)
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
        impulses.setSensitivity(profile)
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
        pinnedId = 0
        book.clear()
        setNearby([], nil)
        lastTapMs = -1
        lastPeerTapMs = -1
        lastPeerTapNote = "-"
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
        tapClient = nil
        let first = pinnedId != peer
        pinnedId = peer
        if first, let target = byId[peer] { setFocus(target, clock.elapsedMs()) }
        diag.log(clock.elapsedMs(), offer == nil ? "offer does not fit one frame" : "offer ready for #\(peer) (\(payload.count) bytes)")
        // The phones already connected (they said Hello) are told there is something to read; others read when they connect.
        if offer != nil { for client in challenges.keys.sorted() { radio.notify(client: client, value: SongTapWire.encodeOfferReady()) } }
        publishNearby(clock.elapsedMs(), force: true)
    }

    public func withdrawOffer() {
        defer { drain() }
        // A receiver that fetched the offer ahead of the tap must not keep it once the sender has let go of it.
        if offer != nil { for client in challenges.keys.sorted() { radio.notify(client: client, value: SongTapWire.encodeOfferWithdrawn()) } }
        offer = nil
        offerClient = nil
        ackClient = nil
        tapClient = nil
        let wasPinned = pinnedId != 0
        pinnedId = 0
        if wasPinned && started { publishNearby(clock.elapsedMs(), force: true) }
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

    // Server callbacks (a receiver talking to our GATT server).

    public func serverInfo() -> [UInt8] {
        SongTapWire.encodeInfo(ageMs: SongTapHandshake.impulseAgeMs(nowMs: clock.elapsedMs(), impulseMs: ownImpulseMs))
    }

    public func serverName() -> [UInt8] { SongTapWire.encodeName(ownName) }

    public func serverOffer(client: String) -> [UInt8]? {
        defer { drain() }
        if !started || role != .send { return nil }
        guard let payload = offer else { return nil }
        // The offer exists only for the phone the listener said yes to, and is served only while that phone is the one being followed
        // AND inside the near gate, and no other phone that could be the reader is inside it too (a connection's own address is not the
        // advertising address, so "which phone is this client" cannot be known: when two are close, serve nobody).
        guard let target = byId[pinnedId] else { return nil }
        if focus !== target || !target.detector.near { return nil }
        if anotherReceiverNear(target) { return nil }
        // Once somebody has read it, only that reader is given it again.
        if let reader = offerClient, reader != client { return nil }
        guard let challenge = challenges[client], let key = signer else { return nil }
        let ts = clock.wallMs()
        guard let message = SongTapSigning.signingBytes(payload: payload, challenge: challenge, timestampMs: ts),
              let signature = key.sign(message) else { return nil }
        let frame = SongTapSigning.encodeFrame(SongTapSignedOffer(payload: payload, timestampMs: ts, publicKey: key.publicKey, signature: signature))
        // A challenge answers one read: the receiver sends a new one for the next beam.
        challenges[client] = nil
        if frame != nil {
            offerClient = client
            emit(.offerRead(peer: target.id))
        }
        diag.log(clock.elapsedMs(), frame == nil ? "frame too big" : "offer read by a receiver (\(frame?.count ?? 0) bytes)")
        return frame
    }

    /// True when a phone other than `target` that advertises as a receiver is inside the near gate right now.
    private func anotherReceiverNear(_ target: Peer) -> Bool {
        let t = clock.elapsedMs()
        for q in peers.values where q !== target && q.role == .receive {
            if t - q.lastSeenMs <= SongTapBleTuning.peerTimeoutMs && q.detector.near { return true }
        }
        return false
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
            // One-sided tap (spec 6): the receiver felt the tap first and says so; this phone commits at once, without waiting for its own
            // detector, when `SongTapPeerTap.judge` accepts: the message is from the phone being followed (the one the listener said yes
            // to), it is the reader of this offer, this phone's own signal for it is at least the near gate, and nothing was taken lately.
            let f = focus
            let followed = f != nil && f!.id == pinnedId && f!.role == .receive
            let saidYes = offer != nil && client == offerClient
            let own = (f == nil || !f!.detector.started) ? noSignalDbm : dbm(f!.detector.fastQ)
            let verdict = SongTapPeerTap.judge(ownFastDbm: own, followed: followed, saidYes: saidYes, nowMs: t, lastTapMs: lastTapMs)
            diag.log(t, "receiver reports a tap (jerk \(ageMs) ms ago): \(verdict.code), own signal \(own) dBm")
            lastPeerTapNote = "\(verdict.code) at \(t) ms (from the receiver)"
            if verdict == .accept, let f {
                lastTapMs = t
                lastPeerTapMs = t
                tapClient = client
                emit(.tap(peer: f.id))
            }
        }
        return true
    }

    public func serverClientGone(client: String) {
        defer { drain() }
        challenges[client] = nil
        let acked = ackClient == client
        let read = offerClient == client
        if acked { ackClient = nil }
        if read { offerClient = nil }
        if tapClient == client { tapClient = nil }
        // A reader that leaves before the beam is only a read lost (the session stays armed to that phone); in the middle of a beam,
        // before its answer, it is a lost peer; after its answer it is nothing.
        if read && !acked && offer != nil {
            if let target = byId[pinnedId] { emit(.offerReadLost(peer: target.id)) }
            if let f = focus, f.id == pinnedId { emit(.peerLost(f.id)) }
        }
    }

    // MARK: Receiver

    public func readOffer(peer: Int) {
        defer { drain() }
        guard let p = byId[peer], role == .receive, p.role == .send else {
            emit(.offerInvalid)
            return
        }
        // The offer was fetched before the tap: hand it over now (this is the fast path; the session normally already holds it).
        if let held = p.prefetched {
            p.prefetched = nil
            emit(.offer(peer: p.id, payload: held.payload, senderKey: held.senderKey, name: p.fullName ?? p.name))
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
        // The beam is saved and acknowledged: this phone is free again (nothing waits for a `go` any more).
        p.inTransfer = false
        p.prefetched = nil
    }

    public func sendDecline(peer: Int) {
        defer { drain() }
        guard let p = byId[peer] else { return }
        p.inTransfer = false
        p.prefetched = nil
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
        p.prefetched = nil
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
        // Spec 5: everything slow happens now, before any tap: the sender's name, then its offer (when it has one for us).
        if !p.nameAsked {
            p.nameAsked = true
            radio.readName(address: p.address)
        }
        if p.wantRead { startRead(p) } else { startPrefetch(p, t) }
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
        dropPrefetch(p)
        p.nameAsked = false
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

    public func onNameRead(address: String, value: [UInt8]?) {
        defer { drain() }
        guard let p = peers[address], let value, let name = SongTapWire.decodeName(value) else { return }
        p.fullName = name
        diag.log(clock.elapsedMs(), "#\(p.id) is called \(name)")
        emit(.peerName(peer: p.id, name: name))
    }

    public func onOfferRead(address: String, value: [UInt8]?) {
        defer { drain() }
        guard let p = peers[address] else { return }
        p.readInFlight = false
        let t = clock.elapsedMs()
        guard let value else {
            if !p.inTransfer {
                // A prefetch with nothing to give: the sender's notification (or the retry) comes later, and an offer held from before is no good now.
                dropPrefetch(p)
                return
            }
            p.readAttempts += 1
            if p.readAttempts < SongTapBleTuning.maxReadAttempts {
                scheduler.after(ms: SongTapBleTuning.readRetryMs) { [weak self, weak p] in
                    guard let self, let p else { return }
                    if self.started && p.inTransfer && p.conn == .ready && !p.readInFlight { self.startRead(p) }
                    self.drain()
                }
            } else {
                diag.log(t, "the sender had no offer")
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
            let name = p.fullName ?? p.name
            let key = SongTapSigning.senderKey(frame.publicKey)
            if p.inTransfer {
                diag.log(t, "offer read and checked")
                emit(.offer(peer: p.id, payload: frame.payload, senderKey: key, name: name))
            } else {
                p.prefetched = Prefetch(payload: frame.payload, senderKey: key, atMs: t)
                diag.log(t, "offer fetched ahead of the tap and checked (\(frame.payload.count) bytes)")
                emit(.offerPrefetched(peer: p.id, payload: frame.payload, senderKey: key, name: name))
            }
        } else {
            diag.log(t, "offer refused: \(verdict.code)")
            if p.inTransfer {
                p.inTransfer = false
                emit(.offerInvalid)
            } else {
                dropPrefetch(p)
            }
        }
    }

    /// Receiver: ask the sender for its offer ahead of the tap (nothing happens when it has none yet).
    private func startPrefetch(_ p: Peer, _ t: Int64) {
        if role != .receive || p.role != .send || p.conn != .ready || p.readInFlight || p.inTransfer { return }
        p.lastPrefetchTryMs = t
        p.readInFlight = true
        radio.readOffer(address: p.address)
    }

    /// Receiver: whatever was fetched ahead is no longer good.
    private func dropPrefetch(_ p: Peer) {
        if p.prefetched != nil {
            p.prefetched = nil
            emit(.offerGone(peer: p.id))
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
        let t = clock.elapsedMs()
        // One-sided tap (spec 6): the sender's detector fired and it says so. This phone commits at once, without waiting for its own
        // detector, only when `SongTapPeerTap.judge` accepts it: the notification is from the sender being followed, an offer fetched ahead
        // is in hand (the sender said yes), this phone's own signal for the sender is at least the near gate, nothing was taken lately.
        if SongTapWire.isTapEvent(value) {
            let followed = role == .receive && p === focus && p.role == .send && p.conn == .ready
            let saidYes = p.prefetched != nil
            let own = !p.detector.started ? noSignalDbm : dbm(p.detector.fastQ)
            let verdict = SongTapPeerTap.judge(ownFastDbm: own, followed: followed, saidYes: saidYes, nowMs: t, lastTapMs: lastTapMs)
            diag.log(t, "the sender reports a tap: \(verdict.code), own signal \(own) dBm")
            lastPeerTapNote = "\(verdict.code) at \(t) ms (from the sender)"
            if verdict == .accept {
                lastTapMs = t
                lastPeerTapMs = t
                emit(.tap(peer: p.id))
                // The session holds the offer from here on, as after this phone's own tap.
                p.prefetched = nil
            }
            return
        }
        // The events are "the sender has an offer to read" and "the sender has none any more" (the old go is gone and ignored).
        if SongTapWire.isOfferWithdrawn(value) {
            diag.log(t, "the sender withdrew its offer")
            dropPrefetch(p)
            return
        }
        if !SongTapWire.isOfferReady(value) { return }
        diag.log(t, "the sender has an offer ready")
        if p.detector.near { startPrefetch(p, t) }
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
        pinnedId = 0
        book.clear()
        setNearby([], nil)
        setGlow(0)
        ticking = false
        scheduler.stopTicking()
        impulses.stop()
        setStatus(newStatus)
        diag.log(clock.elapsedMs(), "bluetooth status: \(newStatus.rawValue)")
    }

    // MARK: Detection

    public func onSeen(address: String, role seenRole: SongTapRole, rssi: Int, name: String?) {
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
        if let name, name != p.name {
            p.name = name
            if p.fullName == nil { emit(.peerName(peer: p.id, name: name)) }
        }

        let impulse = impulseFor(p, own: ownImpulseMs)
        let wasHeld = p.detector.heldSinceMs >= 0
        // On iOS the reading is the reference scale as it is (the offset is 0): nothing is added before the detector.
        let step = SongTapDetector.step(p.detector, SongTapRssiSample(tMs: t, rssi: rssi), impulseMs: impulse, profile: profile)
        p.detector = step.state
        p.glow = step.glowPermille
        if step.state.near { p.lastNearMs = t }
        let jumping = step.state.heldSinceMs >= 0
        if jumping || step.fire != .none { p.lastJumpMs = t }
        if jumping && !wasHeld { onJumpStart(p, t) }

        book.update(id: p.id, name: p.fullName ?? p.name ?? SongTapNames.fallback, role: p.role, fastQ: step.state.fastQ,
                    near: step.state.near, nowMs: t)
        publishNearby(t, force: false)
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
        for q in peers.values where q !== focus && q.id != pinnedId && (oldest == nil || q.lastSeenMs < oldest!.lastSeenMs) { oldest = q }
        guard let gone = oldest else { return }
        peers[gone.address] = nil
        byId[gone.id] = nil
        book.remove(gone.id)
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
        let current = focus
        if current === seen { return }
        // A sender armed to a phone follows that phone and nobody else.
        if pinnedId != 0 {
            if seen.id == pinnedId { setFocus(seen, t) }
            return
        }
        if let current {
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
            dropPrefetch(old)
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
        // A sender armed to a phone has no business with a stranger's tap: it does not even follow it.
        if pinnedId != 0 && p.id != pinnedId { return }
        if p !== focus { setFocus(p, t) }
        p.lastFire = reason
        p.lastFireMs = t
        diag.log(t, "tap detected (\(reason.code)) with #\(p.id)\(p.prefetched != nil ? ", offer already in hand" : "")")
        emit(.peerRole(peer: p.id, role: p.role))
        if role == .receive && p.role == .receive { return }
        // The phone that is not the one the listener said yes to cannot start a beam (the session ignores it too).
        if role == .send && p.id != pinnedId { return }
        // This phone already committed on the other phone's tap a moment ago: the session ignores a second tap, and nothing is sent back.
        let echo = lastPeerTapMs >= 0 && t - lastPeerTapMs < SongTapPeerTap.minGapMs
        lastTapMs = t
        emit(.tap(peer: p.id))
        // The session holds the offer from here on (it took it when the fetch finished); the next beam needs a new one.
        if role == .receive { p.prefetched = nil }
        if echo { return }
        // One-sided tap (spec 6): the first haptic tick is also the message to the other phone, sent at once and before anything else.
        if role == .receive && p.role == .send && p.conn == .ready {
            let age = SongTapHandshake.impulseAgeMs(nowMs: t, impulseMs: ownImpulseMs)
            queueWrite(p, .tap, SongTapWire.encodeTap(ageMs: age))
            lastPeerTapNote = "own tap told to the sender at \(t) ms"
        } else if role == .send {
            if offer != nil, let reader = offerClient {
                radio.notify(client: reader, value: SongTapWire.encodeTapEvent())
                diag.log(t, "tap told to the receiver")
                lastPeerTapNote = "own tap told to the receiver at \(t) ms"
            }
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
        for p in Array(peers.values) {
            let limit = p.id == pinnedId ? SongTapBleTuning.pinnedPeerTimeoutMs : SongTapBleTuning.peerTimeoutMs
            if t - p.lastSeenMs <= limit { continue }
            peers[p.address] = nil
            byId[p.id] = nil
            book.remove(p.id)
            if p.conn != .closed { radio.disconnect(address: p.address) }
            radio.forget(address: p.address)
            if p === focus {
                focus = nil
                setGlow(0)
                emit(.peerLost(p.id))
                diag.log(t, "#\(p.id) is gone")
            }
        }
        if focus == nil && pinnedId == 0 {
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
                dropPrefetch(f)
                f.nameAsked = false
            }
            maybeConnect(f, t)
            // Keep the offer in hand fresh, and ask again when the sender had nothing the first time.
            if role == .receive && f.conn == .ready && f.detector.near && !f.inTransfer {
                let due: Bool
                if let held = f.prefetched {
                    due = t - held.atMs >= SongTapBleTuning.prefetchMaxAgeMs && t - f.lastPrefetchTryMs >= SongTapBleTuning.prefetchRetryMs
                } else {
                    due = t - f.lastPrefetchTryMs >= SongTapBleTuning.prefetchRetryMs
                }
                if due { startPrefetch(f, t) }
            }
        }
        publishNearby(t, force: false)
        if diag.isEnabled() { diag.publish(t) { snapshot(t) } }
    }

    /// The list and the prompt for the Song Drop picker: only a sender uses them, and only from advertisements.
    private func publishNearby(_ t: Int64, force: Bool) {
        if !force && t - lastNearbyMs < SongTapBleTuning.nearbyPublishMs { return }
        lastNearbyMs = t
        if role != .send || !started {
            setNearby([], nil)
            return
        }
        let list = book.visible(role: .receive, nowMs: t)
        setNearby(list, pinnedId != 0 ? nil : book.promptFor(role: .receive, nowMs: t))
    }

    private func setNearby(_ list: [SongTapNearbyEntry], _ ask: SongTapNearbyEntry?) {
        if list == nearby && ask == prompt { return }
        nearby = list
        prompt = ask
        onNearbyChange?(list, ask)
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
        s.offsetDb = 0
        s.normalised = f?.rssi ?? 0
        s.profile = profile.code
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
        let listed = f != nil && book.entry(f!.id)?.listed == true
        if f == nil || d == nil {
            s.gate = "none"
        } else if d!.near {
            s.gate = "tap near"
        } else if listed {
            s.gate = "list only"
        } else {
            s.gate = "outside"
        }
        s.mayConnect = d?.near == true
        s.listed = listed
        s.offerInHand = f?.prefetched != nil
        s.names = f == nil ? "" : "\(f!.name ?? "-") / \(f!.fullName ?? "-")"
        s.peerTap = lastPeerTapNote
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
