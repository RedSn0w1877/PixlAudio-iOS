// What the Song Tap screen does with the ring code, as plain rules over time (integers, no clock: the caller says what time it is).
// A transliteration of the Android `RingFlow.kt`. Both phones' halves live here so they are tested without a camera or a screen.
//
// The order of ways to beam is the Bluetooth tap, the ring code, the QR code last:
// - The sender shows the ring code for a song that has a video id; a song without one goes straight to the QR
//   (`RingSendRules.canRing`). The code is made again with a fresh tag every `RingSendRules.codeLifeMs`.
// - The receiver scans it. "Use QR code instead" shows only after the ring scan has failed for `RingSendRules.qrOfferAfterMs`
//   or the camera cannot run the scanner (`RingReceiveFlow`); the sender offers the same button once its code has been up that
//   long (a sender cannot see the receiver's scan).

public enum RingSendRules {
    /// A code is made again with a fresh tag this often (the tag itself is good for two to three minutes).
    public static let codeLifeMs: Int64 = 60_000

    /// "Use QR code instead" appears after this long.
    public static let qrOfferAfterMs: Int64 = 6_000

    public static func canRing(_ videoId: String?) -> Bool {
        guard let videoId else { return false }
        return RingCodePayloads.isValidVideoId(videoId)
    }

    public static func qrButtonVisible(shownForMs: Int64) -> Bool { shownForMs >= qrOfferAfterMs }
}

/// Which code a sender is showing: the Pixl ring code (the default) or the plain QR (the last resort, or for a song with no video yet).
public enum RingCodeKind: String, Sendable {
    case ring
    case qr
}

/// Why a sender shows the QR code without being asked to.
public enum RingSendNote: String, Sendable {
    case noVideo = "no_video"
}

/// What the sender shows for one song: the ring code, or the QR (and, for a song that was never matched to a video, why).
public struct RingSendPlan: Sendable, Equatable {
    public let kind: RingCodeKind
    public let note: RingSendNote?

    /// The plan for a song whose video id is `videoId` (nil when it has none). `qrPreferred` is the listener's choice of "Use QR code
    /// instead", which a rebuilt code (the song changed under it) keeps until the listener leaves.
    public static func of(videoId: String?, qrPreferred: Bool) -> RingSendPlan {
        let ringable = RingSendRules.canRing(videoId)
        return RingSendPlan(kind: ringable && !qrPreferred ? .ring : .qr, note: ringable ? nil : .noVideo)
    }
}

public enum RingVerdict: String, Sendable {
    case accept
    /// The tag is older than the receiver allows (the sender's code is stale, or this phone's clock is ahead).
    case expired
    /// The tag is from the future (this phone's clock is behind the sender's by more than a minute).
    case future
    /// This exact code (video and tag) was already taken a moment ago.
    case replay

    public var code: String { rawValue }
}

/// Decides whether a decoded ring code may be used: fresh tag, and not one that was already taken. `check` only looks; `commit`
/// remembers a code that was used, so a lookup that failed (no internet) can be tried again.
public final class RingCodeGuard {
    private let memoryMs: Int64
    private let capacity: Int
    /// Insertion order, oldest first.
    private var seen: [(key: String, atMs: Int64)] = []

    public init(memoryMs: Int64 = 5 * 60_000, capacity: Int = 32) {
        self.memoryMs = memoryMs
        self.capacity = capacity
    }

    private func keyOf(_ p: RingCodePayload) -> String { p.videoId + "/" + String(p.tag()) }

    private func forget(_ nowMs: Int64) {
        seen.removeAll { nowMs - $0.atMs > memoryMs }
        while seen.count >= capacity && !seen.isEmpty { seen.removeFirst() }
    }

    public func check(_ p: RingCodePayload, nowMs: Int64) -> RingVerdict {
        switch RingCodePayloads.freshness(bucket: p.minuteBucket, nowMs: nowMs) {
        case .expired: return .expired
        case .future: return .future
        case .fresh: break
        }
        let key = keyOf(p)
        if let at = seen.first(where: { $0.key == key })?.atMs, nowMs - at <= memoryMs { return .replay }
        return .accept
    }

    public func commit(_ p: RingCodePayload, nowMs: Int64) {
        forget(nowMs)
        let key = keyOf(p)
        if let i = seen.firstIndex(where: { $0.key == key }) { seen[i].atMs = nowMs } else { seen.append((key, nowMs)) }
    }
}

/// What the receiver's scan screen shows besides the camera.
public enum RingScanMessage: String, Sendable {
    case none
    /// A code was read but its tag is too old.
    case expired
    /// A code was read but its tag is from the future: the clocks differ.
    case clock
    /// The song could not be looked up (no internet).
    case lookupFailed = "lookup_failed"
    /// The same code was already taken.
    case replay

    public var code: String { rawValue }
}

public enum RingScanStage: String, Sendable {
    /// Not scanning.
    case idle
    /// The camera is reading frames for a ring code.
    case scanning
    /// A code was read and the song is being looked up.
    case resolving
    /// The camera cannot run the ring scanner (no camera, it would not start, or the phone is too slow for it).
    case unavailable

    public var code: String { rawValue }
}

/// What the screen draws. `qrOffered` is the one switch that shows "Use QR code instead".
public struct RingScanView: Sendable, Equatable {
    public let stage: RingScanStage
    public let qrOffered: Bool
    public let message: RingScanMessage

    public init(stage: RingScanStage, qrOffered: Bool, message: RingScanMessage) {
        self.stage = stage
        self.qrOffered = qrOffered
        self.message = message
    }

    public static let idle = RingScanView(stage: .idle, qrOffered: false, message: .none)
}

/// What one scan result asks the app to do next.
public enum RingStep: Sendable, Equatable {
    case none
    /// Three equal fresh decodes in a row: look the song up, then call `RingReceiveFlow.resolved`.
    case resolve(RingCodePayload)
    case rejected(RingVerdict)
}

/// The receiver's side of the ring code over one scan session: collects results, needs three equal decodes in a row (the
/// accumulator), asks the guard, and tracks when "Use QR code instead" may be offered. One thread at a time (the app's main actor).
public final class RingReceiveFlow {
    /// Decodes this recent count as a scan that is working.
    public static let decodeGraceMs: Int64 = 2_000

    /// After a lookup that failed the same code is left alone for this long.
    public static let retryAfterFailureMs: Int64 = 3_000

    private let codeGuard: RingCodeGuard
    private var accumulator: RingScanAccumulator
    private var stage = RingScanStage.idle
    private var qrOffered = false
    private var message = RingScanMessage.none
    private var startedMs: Int64 = 0
    private var lastDecodeMs: Int64?
    private var ignoreUntilMs: Int64?

    public init(codeGuard: RingCodeGuard = RingCodeGuard(), accumulator: RingScanAccumulator = RingScanAccumulator()) {
        self.codeGuard = codeGuard
        self.accumulator = accumulator
    }

    public func view() -> RingScanView { RingScanView(stage: stage, qrOffered: qrOffered, message: message) }

    /// The scan screen opened. A phone whose camera cannot run the scanner offers the QR at once.
    @discardableResult
    public func start(nowMs: Int64, cameraAvailable: Bool) -> RingScanView {
        accumulator.reset()
        startedMs = nowMs
        lastDecodeMs = nil
        ignoreUntilMs = nil
        message = .none
        stage = cameraAvailable ? .scanning : .unavailable
        qrOffered = !cameraAvailable
        return view()
    }

    /// The camera would not start, or died.
    @discardableResult
    public func cameraFailed() -> RingScanView {
        if stage == .idle { return view() }
        accumulator.reset()
        stage = .unavailable
        qrOffered = true
        return view()
    }

    /// The scanner cannot keep up on this phone (the average scan is too slow to be useful).
    @discardableResult
    public func scannerTooSlow() -> RingScanView {
        if stage == .scanning { qrOffered = true }
        return view()
    }

    /// Time passed with no news: after `RingSendRules.qrOfferAfterMs` without a working scan the QR is offered. True when the view changed.
    public func tick(nowMs: Int64) -> Bool {
        if stage != .scanning || qrOffered { return false }
        if nowMs - startedMs < RingSendRules.qrOfferAfterMs { return false }
        // A scan that keeps reading codes (even ones not good enough yet) is working: wait for it.
        if let last = lastDecodeMs, nowMs - last <= Self.decodeGraceMs { return false }
        qrOffered = true
        return true
    }

    /// One scanner result.
    public func offer(_ result: RingScanResult, nowMs: Int64) -> RingStep {
        if stage != .scanning { return .none }
        if let until = ignoreUntilMs, nowMs < until { return .none }
        if result.isDecoded { lastDecodeMs = nowMs }
        guard let payload = accumulator.offer(result, nowMs: nowMs) else { return .none }
        let verdict = codeGuard.check(payload, nowMs: nowMs)
        switch verdict {
        case .accept:
            stage = .resolving
            message = .none
            return .resolve(payload)
        case .expired: return reject(verdict, .expired, offerQr: true)
        case .future: return reject(verdict, .clock, offerQr: true)
        case .replay: return reject(verdict, .replay, offerQr: false)
        }
    }

    private func reject(_ verdict: RingVerdict, _ why: RingScanMessage, offerQr: Bool) -> RingStep {
        accumulator.reset()
        message = why
        if offerQr { qrOffered = true }
        return .rejected(verdict)
    }

    /// The lookup of `payload` finished. A failure goes back to scanning with the QR on offer; the same code is not tried again for a few seconds.
    @discardableResult
    public func resolved(_ payload: RingCodePayload, ok: Bool, nowMs: Int64) -> RingScanView {
        if stage != .resolving { return view() }
        accumulator.reset()
        if ok {
            codeGuard.commit(payload, nowMs: nowMs)
            stage = .idle
            message = .none
        } else {
            stage = .scanning
            message = .lookupFailed
            qrOffered = true
            ignoreUntilMs = nowMs + Self.retryAfterFailureMs
        }
        return view()
    }

    /// The scan screen closed.
    @discardableResult
    public func stop() -> RingScanView {
        accumulator.reset()
        stage = .idle
        qrOffered = false
        message = .none
        return view()
    }
}
