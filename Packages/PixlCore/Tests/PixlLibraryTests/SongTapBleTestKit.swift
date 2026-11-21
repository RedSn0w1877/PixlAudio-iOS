import Foundation
@testable import PixlLibrary

// The fakes the Bluetooth route is tested over (Android `BleTestKit.kt`): a clock moved by hand, a scheduler on that clock, a
// radio that only records, a sensor that is told when to jerk, and a signer whose "signatures" are checked by a matching
// verifier (the real CryptoKit signer lives in the app and is never part of these tests).

@MainActor
final class SongTapTestClock: SongTapClock {
    var elapsed: Int64 = 10_000
    var wall: Int64 = 1_763_600_000_000

    func elapsedMs() -> Int64 { elapsed }
    func wallMs() -> Int64 { wall }
    func advance(_ ms: Int64) { elapsed += ms; wall += ms }
}

@MainActor
final class FakeImpulses: SongTapImpulseSource {
    var running = false
    private var callback: (@MainActor (Int64) -> Void)?

    func start(onImpulse: @escaping @MainActor (Int64) -> Void) { running = true; callback = onImpulse }
    func stop() { running = false; callback = nil }
    func jerk(atMs: Int64) { callback?(atMs) }
}

/// Timers that run when the test's clock says so.
@MainActor
final class FakeScheduler: SongTapBleScheduler {
    private struct Timer {
        var seq: Int
        var key: String?
        var due: Int64
        var action: @MainActor () -> Void
    }

    private let clock: SongTapTestClock
    private var every: Int64 = 0
    private var nextTick: Int64 = 0
    private var tick: (@MainActor () -> Void)?
    private var timers: [Timer] = []
    private var seq = 0

    init(clock: SongTapTestClock) { self.clock = clock }

    var isTicking: Bool { tick != nil }

    func startTicking(everyMs: Int64, _ tick: @escaping @MainActor () -> Void) {
        every = everyMs
        nextTick = clock.elapsed + everyMs
        self.tick = tick
    }

    func stopTicking() { tick = nil }

    func after(ms: Int64, _ action: @escaping @MainActor () -> Void) { add(nil, ms, action) }

    /// A timer the test's port replaces or cancels by key.
    func set(_ key: String, ms: Int64, _ action: @escaping @MainActor () -> Void) {
        cancel(key)
        add(key, ms, action)
    }

    func cancel(_ key: String) { timers.removeAll { $0.key == key } }
    func isSet(_ key: String) -> Bool { timers.contains { $0.key == key } }

    private func add(_ key: String?, _ ms: Int64, _ action: @escaping @MainActor () -> Void) {
        seq += 1
        timers.append(Timer(seq: seq, key: key, due: clock.elapsed + ms, action: action))
    }

    /// Runs everything that is due at the clock's time, in the order of its due time.
    func pump() {
        while true {
            let due = timers.filter { $0.due <= clock.elapsed }.min { ($0.due, $0.seq) < ($1.due, $1.seq) }
            if let tick, nextTick <= clock.elapsed, due == nil || nextTick <= due!.due {
                nextTick += every
                tick()
                continue
            }
            guard let due else { return }
            timers.removeAll { $0.seq == due.seq }
            due.action()
        }
    }

    /// Moves the clock `ms` forward in small steps, running what falls due on the way.
    func advance(_ ms: Int64) {
        let target = clock.elapsed + ms
        while clock.elapsed < target {
            clock.advance(min(50, target - clock.elapsed))
            pump()
        }
    }
}

/// A radio that only records what it is asked and lets the test play the platform's part.
@MainActor
final class FakeRadio: SongTapBleRadio {
    var listener: (any SongTapBleRadioListener)?
    var startStatus = SongTapBleStatus.active
    var running = false
    var role = SongTapRole.send
    var calls: [String] = []
    var controlWrites: [[UInt8]] = []
    var goNotifications: [String] = []
    var dropped: [String] = []

    func start(role: SongTapRole, listener: any SongTapBleRadioListener) -> SongTapBleStatus {
        self.listener = listener
        self.role = role
        calls.append("start:\(role.code)")
        running = startStatus == .active
        return startStatus
    }

    func stop() { calls.append("stop"); running = false }
    func connect(address: String) { calls.append("connect:\(address)") }
    func disconnect(address: String) { calls.append("disconnect:\(address)") }
    func readInfo(address: String) { calls.append("readInfo:\(address)") }
    func readOffer(address: String) { calls.append("readOffer:\(address)") }
    func writeControl(address: String, value: [UInt8]) { calls.append("write:\(address)"); controlWrites.append(value) }
    func notifyGo(client: String) { calls.append("go:\(client)"); goNotifications.append(client) }
    func dropClient(client: String) { calls.append("drop:\(client)"); dropped.append(client) }
    func forget(address: String) { calls.append("forget:\(address)") }

    func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
}

/// "Signatures" that the matching `FakeVerifier` accepts: 64 bytes derived from the key and the message, so a changed message,
/// another key or a bit flipped in the signature fails exactly like a real one would.
struct FakeSigner: SongTapSignerPort {
    nonisolated(unsafe) static var made: UInt8 = 0

    let publicKey: [UInt8]

    init() {
        FakeSigner.made &+= 1
        var key: [UInt8] = [4]
        for i in 0..<64 { key.append(UInt8(truncatingIfNeeded: Int(FakeSigner.made) * 31 + i * 7)) }
        publicKey = key
    }

    func sign(_ message: [UInt8]) -> [UInt8]? { FakeSigner.mac(publicKey, message) }

    static func mac(_ key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for lane in 0..<8 {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ UInt64(lane)
            for b in key + message { h = (h ^ UInt64(b)) &* 0x1000_0000_01b3 }
            for k in 0..<8 { out.append(UInt8(truncatingIfNeeded: h >> UInt64(8 * k))) }
        }
        return out
    }
}

struct FakeVerifier: SongTapSignatureVerifier {
    func verify(publicKey: [UInt8], message: [UInt8], signature: [UInt8]) -> Bool {
        publicKey.count == SongTapSigning.publicKeyBytes && signature == FakeSigner.mac(publicKey, message)
    }
}

@MainActor
final class TestByteSource {
    var value: UInt8 = 0
    func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in value &+= 1; return value } }
}

/// One route with everything around it under the test's hand.
@MainActor
final class BleRig {
    let radio = FakeRadio()
    let clock = SongTapTestClock()
    let impulses = FakeImpulses()
    let scheduler: FakeScheduler
    let diag: SongTapDiagnostics
    let route: SongTapBleRoute
    var events: [SongTapTransportEvent] = []
    private let counter = TestByteSource()

    init(diag: SongTapDiagnostics = SongTapDiagnostics()) {
        self.diag = diag
        let scheduler = FakeScheduler(clock: clock)
        self.scheduler = scheduler
        let counter = counter
        route = SongTapBleRoute(radio: radio, impulses: impulses, clock: clock, diag: diag, scheduler: scheduler,
                                newSigner: { FakeSigner() }, verifier: FakeVerifier(), random: { counter.bytes($0) })
        route.onEvent = { [unowned self] in events.append($0) }
    }

    var listener: any SongTapBleRadioListener { radio.listener! }

    /// One scan result, `stepMs` after the last.
    func see(_ address: String, _ role: SongTapRole, _ rssi: Int, stepMs: Int64 = 100) {
        clock.advance(stepMs)
        listener.onSeen(address: address, role: role, rssi: rssi)
    }

    /// A phone sits near at `rssi`, long enough for the detector to settle.
    func settle(_ address: String, _ role: SongTapRole, rssi: Int = -62, samples: Int = 8) {
        for _ in 0..<samples { see(address, role, rssi) }
    }

    /// The signal jumps and stays: a tap that is held.
    func touch(_ address: String, _ role: SongTapRole, rssi: Int = -40, samples: Int = 8) {
        for _ in 0..<samples { see(address, role, rssi) }
    }

    func advance(_ ms: Int64) { scheduler.advance(ms) }

    var founds: [Int] { events.compactMap { if case .peerFound(let p) = $0 { p } else { nil } } }
    var nears: [Int] { events.compactMap { if case .peerNear(let p) = $0 { p } else { nil } } }
    var losts: [Int] { events.compactMap { if case .peerLost(let p) = $0 { p } else { nil } } }
    var taps: [Int] { events.compactMap { if case .tap(let p) = $0 { p } else { nil } } }
    var acks: [Int] { events.compactMap { if case .ack(let p) = $0 { p } else { nil } } }
    var declines: [Int] { events.compactMap { if case .declined(let p) = $0 { p } else { nil } } }
    var roles: [SongTapRole] { events.compactMap { if case .peerRole(_, let r) = $0 { r } else { nil } } }
    var invalids: Int { events.filter { $0 == .offerInvalid }.count }
    var gos: [(peer: Int, rttMs: Int64)] { events.compactMap { if case .go(let p, let r) = $0 { (p, r) } else { nil } } }
    var offers: [(peer: Int, payload: [UInt8], senderKey: Int32)] {
        events.compactMap { if case .offer(let p, let b, let k) = $0 { (p, b, k) } else { nil } }
    }

    var controlsDecoded: [SongTapControlMessage?] { radio.controlWrites.map { SongTapWire.decodeControl($0) } }
    var hellos: [[UInt8]] { controlsDecoded.compactMap { if case .hello(let c)? = $0 { c } else { nil } } }
    var tapWrites: Int { controlsDecoded.filter { if case .tap? = $0 { true } else { false } }.count }
    var lastControl: SongTapControlMessage? { controlsDecoded.last ?? nil }
}
