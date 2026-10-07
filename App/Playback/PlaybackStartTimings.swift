import Foundation
import os
import Synchronization

/// How long each song took to start, step by step (streaming speed, R12). Nothing here is measured in Instruments
/// only: the owner reads the breakdown on the phone in Settings › Developer › Test playback › Stream start timings
/// (and in the deep probe's "Last start" line). Signposts (category "Streaming") mark the same steps for Instruments.
///
/// - The engine opens one record per start (`begin`) and marks the steps it owns: URL resolved, audio track loaded,
///   item built, first `.playing` (or ready while paused, or failed).
/// - The streaming layer reports by key — the item URL's text (`pixlstream://<videoId>`), so App/Playback stays free
///   of YouTube code — the stream resolution (time, client, remote-config wait, whether the URL carries `n`), the
///   resource loader's requests and cancellations, the network fetches and the first answer to AVPlayer.
///
/// Thread-safe (one `Mutex`); called from the main actor, the resource loader's queue and background tasks. Never
/// from the audio render path.
nonisolated final class PlaybackStartTimings: @unchecked Sendable {
    /// The app-wide store (the engine and the streaming layer report here).
    static let shared = PlaybackStartTimings()

    /// Records kept (newest first in `records`).
    static let capacity = 8
    /// Streaming events count towards a start for this long after it began (the start-up phase).
    static let windowMs = 10_000

    nonisolated enum Kind: String, Sendable {
        /// The item was built for this start (tap, skip, auto-advance without a prepared item).
        case load
        /// A skip took over the item already prepared on the idle deck (R7).
        case prepared
    }

    /// One stream resolution (InnerTube or Piped).
    nonisolated struct Resolve: Sendable, Equatable {
        var ms: Int
        /// Time spent waiting for the remote client table before resolving.
        var configMs: Int
        var strategy: String?
        /// The winning client's attempt detail (itag, bitrate, whether `n` changed).
        var detail: String?
        /// Whether the resolved URL carries an `n` parameter (it then needs base.js).
        var hasN: Bool?
    }

    nonisolated struct Record: Sendable, Equatable {
        let id: Int
        let title: String
        let kind: Kind
        let began: ContinuousClock.Instant
        /// The item URL's text (the streaming layer's key); nil until the URL is known.
        var key: String?
        var isFile = false
        /// Milliseconds from `began` to each step.
        var urlMs: Int?
        var tracksMs: Int?
        var builtMs: Int?
        var playingMs: Int?
        /// Ready to play, but playback was paused (a restored queue).
        var readyPausedMs: Int?
        var failure: String?
        var failedMs: Int?
        /// Left before it played (another song was chosen, or playback stopped).
        var abandonedMs: Int?
        var resolve: Resolve?
        /// A resolution that finished before this start (the prefetcher's), with how long before.
        var earlierResolve: Resolve?
        var requests = 0
        var infoRequests = 0
        var toEndRequests = 0
        var cancelled = 0
        var fetches = 0
        var fetchedBytes: Int64 = 0
        var firstFetchMs: Int?
        var firstFetchBytes: Int?
        var firstAnswerMs: Int?

        init(id: Int, title: String, kind: Kind, began: ContinuousClock.Instant) {
            self.id = id
            self.title = title
            self.kind = kind
            self.began = began
        }

        /// The plain-text breakdown (2–5 lines).
        func lines(now: ContinuousClock.Instant = .now) -> [String] {
            let name = title.isEmpty ? "Song" : title
            var out: [String] = []
            if let playingMs {
                out.append("• \(name) — \(playingMs) ms to play" + (kind == .prepared ? " (skip into the prepared song)" : ""))
            } else if let readyPausedMs {
                out.append("• \(name) — ready in \(readyPausedMs) ms (paused)")
            } else if let failure {
                out.append("• \(name) — failed after \(failedMs ?? 0) ms: \(failure)")
            } else if let abandonedMs {
                out.append("• \(name) — left after \(abandonedMs) ms, before it played")
            } else {
                out.append("• \(name) — still starting (\(PlaybackStartTimings.ms(from: began, to: now)) ms so far)")
            }
            var steps: [String] = []
            if let urlMs { steps.append("url \(urlMs)") }
            if let tracksMs { steps.append("tracks \(tracksMs - (urlMs ?? 0))") }
            if let builtMs { steps.append("item \(builtMs - (tracksMs ?? urlMs ?? 0))") }
            if let playingMs { steps.append("start \(playingMs - (builtMs ?? 0))") }
            if !steps.isEmpty { out.append("   steps (ms): " + steps.joined(separator: " · ") + (isFile ? " · local file" : "")) }
            guard !isFile, key != nil else { return out }
            if let resolve {
                out.append("   resolve: " + Self.describe(resolve))
            } else if let earlierResolve {
                out.append("   resolve: done before the tap (prefetch), " + Self.describe(earlierResolve))
            } else {
                out.append("   resolve: none needed (link or head bytes cached)")
            }
            if fetches == 0 {
                out.append("   network: none before playback (head bytes cached)")
            } else {
                var network = "   network: first chunk at \(firstFetchMs ?? 0) ms"
                if let firstFetchBytes { network += " (\(Self.size(Int64(firstFetchBytes))))" }
                network += ", \(fetches) fetch\(fetches == 1 ? "" : "es"), \(Self.size(fetchedBytes))"
                out.append(network)
            }
            var loader = "   loader: \(requests) request\(requests == 1 ? "" : "s") (\(infoRequests) info, \(toEndRequests) to end)"
            loader += ", \(cancelled) cancelled"
            if let firstAnswerMs { loader += " · first answer at \(firstAnswerMs) ms" }
            out.append(loader)
            return out
        }

        static func describe(_ resolve: Resolve) -> String {
            var text = "\(resolve.ms) ms via \(resolve.strategy ?? "nothing")"
            if let detail = resolve.detail, !detail.isEmpty { text += " (\(detail))" }
            if let hasN = resolve.hasN { text += " · n: \(hasN ? "yes" : "no")" }
            text += " · config wait \(resolve.configMs) ms"
            return text
        }

        static func size(_ bytes: Int64) -> String {
            if bytes >= 1 << 20 { return String(format: "%.1f MB", Double(bytes) / Double(1 << 20)) }
            return "\(max(bytes, 0) >> 10) KB"
        }
    }

    private nonisolated struct State: Sendable {
        var nextId = 1
        /// Oldest first.
        var records: [Record] = []
        /// The last resolution per key (the prefetcher resolves ahead of the tap).
        var lastResolve: [String: (resolve: Resolve, at: ContinuousClock.Instant)] = [:]
    }

    private let state = Mutex(State())
    private let signposter = OSSignposter(subsystem: "io.github.redsn0w1877.pixlaudio", category: "Streaming")

    // MARK: Engine marks

    /// Opens a record for a start; returns its id for the later marks. `url` is the item's URL when it is already
    /// known (a prepared item taken over).
    func begin(title: String, kind: Kind = .load, url: URL? = nil) -> Int {
        signposter.emitEvent("StartBegin")
        let now = ContinuousClock.now
        return state.withLock { s in
            let id = s.nextId
            s.nextId += 1
            var record = Record(id: id, title: title, kind: kind, began: now)
            record.key = url?.absoluteString
            record.isFile = url?.isFileURL ?? false
            s.records.append(record)
            if s.records.count > Self.capacity { s.records.removeFirst(s.records.count - Self.capacity) }
            return id
        }
    }

    /// The playable URL is known (Spotify matched, download / cache / stream chosen).
    func urlResolved(_ id: Int, url: URL) {
        signposter.emitEvent("StartURL")
        let key = url.absoluteString
        let isFile = url.isFileURL
        update(id) { record, now in
            record.urlMs = Self.ms(from: record.began, to: now)
            record.key = key
            record.isFile = isFile
        }
        guard !isFile else { return }
        // A resolution that happened before the tap (prefetch) explains a start without one.
        state.withLock { s in
            guard let earlier = s.lastResolve[key], let index = s.records.lastIndex(where: { $0.id == id }),
                  earlier.at < s.records[index].began else { return }
            s.records[index].earlierResolve = earlier.resolve
        }
    }

    func tracksLoaded(_ id: Int) {
        signposter.emitEvent("StartTracks")
        update(id) { record, now in record.tracksMs = Self.ms(from: record.began, to: now) }
    }

    func itemBuilt(_ id: Int) {
        signposter.emitEvent("StartItem")
        update(id) { record, now in record.builtMs = Self.ms(from: record.began, to: now) }
    }

    /// The first `.playing` of the started item.
    func playing(_ id: Int) {
        signposter.emitEvent("StartPlaying")
        update(id) { record, now in
            guard record.playingMs == nil, record.abandonedMs == nil, record.failure == nil else { return }
            record.playingMs = Self.ms(from: record.began, to: now)
        }
    }

    /// The item is ready but playback is paused (nothing more to measure).
    func readyPaused(_ id: Int) {
        update(id) { record, now in record.readyPausedMs = Self.ms(from: record.began, to: now) }
    }

    func failed(_ id: Int, _ message: String) {
        signposter.emitEvent("StartFailed")
        update(id) { record, now in
            record.failure = message
            record.failedMs = Self.ms(from: record.began, to: now)
        }
    }

    /// The start ended without playing (another song was chosen, or playback stopped).
    func abandoned(_ id: Int) {
        update(id) { record, now in
            if record.playingMs == nil, record.readyPausedMs == nil, record.failure == nil {
                record.abandonedMs = Self.ms(from: record.began, to: now)
            }
        }
    }

    // MARK: Streaming marks (keyed by the item URL's text)

    func resolved(key: String, _ resolve: Resolve) {
        signposter.emitEvent("StreamResolved")
        let now = ContinuousClock.now
        state.withLock { s in
            s.lastResolve[key] = (resolve, now)
            if s.lastResolve.count > 32, let oldest = s.lastResolve.min(by: { $0.value.at < $1.value.at })?.key {
                s.lastResolve[oldest] = nil
            }
        }
        updateOpen(key: key) { record, _ in
            if record.resolve == nil { record.resolve = resolve }
        }
    }

    func loaderRequest(key: String, contentInfo: Bool, toEnd: Bool) {
        updateOpen(key: key) { record, _ in
            record.requests += 1
            if contentInfo { record.infoRequests += 1 }
            if toEnd { record.toEndRequests += 1 }
        }
    }

    func loaderCancelled(key: String) {
        updateOpen(key: key) { record, _ in record.cancelled += 1 }
    }

    /// A ranged GET finished (`bytes` of body).
    func networkFetched(key: String, bytes: Int) {
        var isFirst = false
        updateOpen(key: key) { record, now in
            if record.fetches == 0 {
                record.firstFetchMs = Self.ms(from: record.began, to: now)
                record.firstFetchBytes = bytes
                isFirst = true
            }
            record.fetches += 1
            record.fetchedBytes += Int64(bytes)
        }
        if isFirst { signposter.emitEvent("StreamFirstChunk") }
    }

    /// Bytes went to AVPlayer (`respond(with:)`).
    func answered(key: String) {
        updateOpen(key: key) { record, now in
            if record.firstAnswerMs == nil { record.firstAnswerMs = Self.ms(from: record.began, to: now) }
        }
    }

    // MARK: Reading

    /// Newest first.
    var records: [Record] { state.withLock { Array($0.records.reversed()) } }

    /// The newest start's breakdown (the deep probe's "Last start").
    func lastStartSummary() -> String? {
        records.first.map { $0.lines().joined(separator: "\n") }
    }

    /// Every kept start, newest first (the Stream start timings card).
    func report() -> String {
        let all = records
        guard !all.isEmpty else { return "No starts measured yet. Play a song, then come back." }
        return all.map { $0.lines().joined(separator: "\n") }.joined(separator: "\n\n")
    }

    // MARK: Private

    private func update(_ id: Int, _ body: (inout Record, ContinuousClock.Instant) -> Void) {
        let now = ContinuousClock.now
        state.withLock { s in
            guard let index = s.records.lastIndex(where: { $0.id == id }) else { return }
            body(&s.records[index], now)
        }
    }

    /// The newest record for `key` still inside its start-up window.
    private func updateOpen(key: String, _ body: (inout Record, ContinuousClock.Instant) -> Void) {
        let now = ContinuousClock.now
        state.withLock { s in
            guard let index = s.records.lastIndex(where: { $0.key == key }),
                  Self.ms(from: s.records[index].began, to: now) <= Self.windowMs else { return }
            body(&s.records[index], now)
        }
    }

    static func ms(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Int {
        let parts = (end - start).components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
