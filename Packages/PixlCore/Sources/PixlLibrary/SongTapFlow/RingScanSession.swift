// One receiver's ring code scan, from the screen opening to a song being put to the Song Tap session: `RingReceiveFlow`'s rules (three
// equal reads, the freshness and replay guard, when "Use QR code instead" is offered) joined to a clock, the lookup of the song and
// the hand-over to the engine. This is the Android state holder's ring half with the camera and the screen taken out, so it is tested
// over fakes. Main actor only: the camera's queue hands its results over with a `Task { @MainActor in ... }`.

@MainActor
public final class RingScanSession {
    /// The app asks `tick()` this often while a scan is open (the QR button is due after six seconds).
    public static let tickMs: Int64 = 500
    /// How long a song may take to be looked up.
    public static let resolveTimeoutMs: Int64 = 10_000

    /// What the scan screen draws besides the camera.
    public private(set) var view = RingScanView.idle {
        didSet { if view != oldValue { onView?(view) } }
    }
    public var onView: ((RingScanView) -> Void)?
    /// The song a code named, found. The app puts it to `SongTapEngine.ringOffer`.
    public var onSong: ((SongTapPayload) -> Void)?

    private let flow: RingReceiveFlow
    private let lookup: any RingCodeLookup
    private let clock: @MainActor () -> Int64
    private let timeoutMs: Int64
    private var resolving: Task<Void, Never>?

    public init(lookup: any RingCodeLookup, clock: @escaping @MainActor () -> Int64, flow: RingReceiveFlow = RingReceiveFlow(),
                timeoutMs: Int64 = RingScanSession.resolveTimeoutMs) {
        self.lookup = lookup
        self.clock = clock
        self.flow = flow
        self.timeoutMs = timeoutMs
    }

    /// The receiver opened the camera for a ring code. `cameraAvailable` is false on a phone with no camera.
    public func start(cameraAvailable: Bool) {
        resolving?.cancel()
        resolving = nil
        view = flow.start(nowMs: clock(), cameraAvailable: cameraAvailable)
    }

    /// The camera closed (the screen was left, the listener went back, or a code was taken).
    public func stop() {
        resolving?.cancel()
        resolving = nil
        view = flow.stop()
    }

    /// The camera would not start.
    public func cameraFailed() { view = flow.cameraFailed() }

    /// The scanner cannot keep up on this phone.
    public func scannerTooSlow() { view = flow.scannerTooSlow() }

    /// Time passed: the QR may be due.
    public func tick() {
        if flow.tick(nowMs: clock()) { view = flow.view() }
    }

    /// One scanner result. Three equal fresh decodes in a row start the lookup of the song.
    public func offer(_ result: RingScanResult) {
        let step = flow.offer(result, nowMs: clock())
        switch step {
        case .resolve(let code):
            view = flow.view()
            resolve(code)
        case .rejected:
            view = flow.view()
        case .none:
            break
        }
    }

    /// The song named by the code's video id is looked up (it needs the internet), then goes on as an offer.
    private func resolve(_ code: RingCodePayload) {
        resolving?.cancel()
        let lookup = lookup
        let timeoutMs = timeoutMs
        let startedAt = clock()
        resolving = Task { [weak self] in
            let song = await Self.look(lookup, code.videoId, startedAt, timeoutMs)
            guard let self, !Task.isCancelled, flow.view().stage == .resolving else { return }
            view = flow.resolved(code, ok: song != nil, nowMs: clock())
            if let song { onSong?(song) }
        }
    }

    /// The lookup against a timer: whichever finishes first, a song that arrives late is dropped.
    private nonisolated static func look(_ lookup: any RingCodeLookup, _ videoId: String, _ nowMs: Int64, _ timeoutMs: Int64) async -> SongTapPayload? {
        await withTaskGroup(of: SongTapPayload?.self) { group in
            group.addTask { await lookup.resolve(videoId: videoId, nowMs: nowMs) }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
