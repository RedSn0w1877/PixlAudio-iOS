// iOS only: the rules for playing YouTube's Opus stream (itag 251) instead of AAC (itag 140). AVPlayer does not read
// WebM, so the app downloads the whole Opus file ahead of time, repackages it into MP4 (PixlNet `Remux/`), checks it
// with the system decoder and plays it the next time the song starts. Everything here is a pure rule or a small
// state machine, so it is tested on Windows; the app's `OpusStreams.swift` does the I/O.

import Foundation

/// When the app prepares an Opus file, and what it accepts.
public enum OpusStreamPolicy {
    /// The next song's file is prepared once the current song has played this long (a quick skip costs nothing).
    public static let nextSongStartPositionMs: Int64 = 10_000
    /// The playing song's own file (for its next play) once it has played this long.
    public static let currentSongStartPositionMs: Int64 = 30_000
    /// Larger WebM files are left alone (about 16 minutes at 160 kbps).
    public static let maxWebMBytes: Int64 = 20 << 20
    /// Ranged GET size for the whole-file download.
    public static let downloadChunkBytes: Int64 = 2 << 20
    /// A download slower than this is abandoned (googlevideo throttling an unsolved `n`, a bad network).
    public static let downloadTimeoutSeconds: Double = 120
    /// YouTube's lengths of the Opus and AAC streams must agree this closely (the engine's in-song switch rule).
    public static let maxDurationDifferenceMs: Double = 50
    /// The system decoder's frame count of the whole file may differ from the valid samples by this much.
    public static let maxDecodedFrameDifference: Int64 = 64
    /// The asset's duration may differ from the valid samples by this much.
    public static let maxAssetDurationDifferenceSeconds: Double = 0.002
    /// The prepared files' folder is trimmed to this, least recently used first.
    public static let cacheMaxBytes: Int64 = 500_000_000
    /// A file used this recently is never evicted (it may be playing).
    public static let recentlyUsedSeconds: Double = 600

    /// Whether preparing may run now: Wi-Fi or Ethernet that is neither metered (a hotspot) nor in Low Data Mode,
    /// no Low Power Mode, no recent memory warning, not in safe mode. The app's being in the background is fine:
    /// that is when people listen, and the next song's hand-over is what benefits.
    public static func allowsPreparation(_ conditions: StreamPrefetchPolicy.Conditions, lowPowerMode: Bool,
                                         recentMemoryPressure: Bool, launchWorkAllowed: Bool) -> Bool {
        guard !lowPowerMode, !recentMemoryPressure, launchWorkAllowed, !conditions.isConstrained,
              !conditions.isExpensive else { return false }
        switch conditions.network {
        case .wifi, .wired: return true
        case .cellular, .other, .offline, .unknown: return false
        }
    }

    /// YouTube's own length of a googlevideo stream (`dur`, seconds with millisecond precision), in milliseconds.
    public static func durationMs(streamURL: String) -> Double? {
        guard let text = URLCoding.androidQueryParameter(streamURL, "dur"), let seconds = Double(text),
              seconds.isFinite, seconds > 0 else { return nil }
        return (seconds * 1000).rounded()
    }

    /// The stream's size in bytes (`clen`).
    public static func contentLength(streamURL: String) -> Int64? {
        guard let text = URLCoding.androidQueryParameter(streamURL, "clen"), let bytes = Int64(text), bytes > 0 else {
            return nil
        }
        return bytes
    }

    /// Whether two lengths agree; a missing one passes (nothing to compare against).
    public static func durationsAgree(_ first: Double?, _ second: Double?) -> Bool {
        guard let first, let second else { return true }
        return abs(first - second) <= maxDurationDifferenceMs
    }

    /// The itag of a googlevideo URL.
    public static func itag(streamURL: String) -> Int? {
        URLCoding.androidQueryParameter(streamURL, "itag").flatMap { Int($0) }
    }

    /// Whether the system decoder's full decode of a repackaged file has the right length. It must cut the
    /// pre-skip (the edit's start): otherwise every position would be late by it, and that is refused. It may keep the
    /// end padding: `AVAssetReader` decodes the last packet whole (CI, iOS 27 simulator: 48,648 frames for a
    /// 48,000-frame edit with 648 padded), as it does with other formats, while the player stops at the edit's end
    /// (the item's duration).
    public static func acceptsDecodedFrames(_ frames: Int64, validSamples: Int, endTrim: Int) -> Bool {
        let valid = Int64(validSamples)
        return abs(frames - valid) <= maxDecodedFrameDifference
            || abs(frames - valid - Int64(endTrim)) <= maxDecodedFrameDifference
    }
}

/// Why a video plays AAC instead of Opus, and for how long that holds.
public enum OpusFailureKind: String, Codable, Sendable, CaseIterable {
    /// No client offered a better Opus stream than the AAC one.
    case noOpusOffered
    /// The download failed or timed out.
    case network
    /// Longer than `OpusStreamPolicy.maxWebMBytes`.
    case tooLarge
    /// The WebM could not be repackaged (an unexpected layout).
    case remux
    /// YouTube's Opus and AAC streams disagree on the song's length.
    case durationMismatch
    /// The system decoder refused the file, or decoded it to the wrong length.
    case verify
    /// The player could not open the file.
    case playerRefused

    /// How long the video stays on AAC before it may be tried again.
    public var retryAfterSeconds: Double {
        switch self {
        case .network: 30 * 60
        case .noOpusOffered: 7 * 86_400
        case .tooLarge, .remux, .durationMismatch, .verify, .playerRefused: 30 * 86_400
        }
    }
}

/// The remembered failures (saved by the app as JSON next to the files).
public struct OpusFailureLedger: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var kind: OpusFailureKind
        public var detail: String
        /// Unix seconds.
        public var at: Double

        public init(kind: OpusFailureKind, detail: String, at: Double) {
            self.kind = kind
            self.detail = detail
            self.at = at
        }

        public func isInEffect(now: Double) -> Bool { now - at < kind.retryAfterSeconds }
    }

    /// Resolutions in a row (any video) without an Opus stream before attempts pause.
    public static let missesBeforePause = 5
    public static let pauseSeconds: Double = 86_400
    /// Files the system decoder refuses on an OS version where none was ever accepted before Opus is switched off
    /// until the OS changes.
    public static let refusalsBeforeOff = 2
    public static let maxEntries = 2_000

    public var videos: [String: Entry] = [:]
    public var missesInARow = 0
    public var pausedUntil: Double?
    public var refusals = 0
    /// The OS version the refusals were counted on.
    public var refusalsOS: String?
    /// An OS version on which a file passed the check (refusals there are the file's fault, not the decoder's).
    public var acceptedOS: String?

    public init() {}

    /// The failure keeping `videoId` on AAC, when one is in effect.
    public func failure(videoId: String, now: Double) -> Entry? {
        guard let entry = videos[videoId], entry.isInEffect(now: now) else { return nil }
        return entry
    }

    /// Why no Opus file is prepared at all right now, or nil.
    public func pauseReason(os: String, now: Double) -> String? {
        if let pausedUntil, now < pausedUntil {
            return "no client offered Opus for \(Self.missesBeforePause) songs in a row; trying again later"
        }
        if refusalsOS == os, refusals >= Self.refusalsBeforeOff, acceptedOS != os {
            return "the system decoder refused the files on this iOS version"
        }
        return nil
    }

    public mutating func record(_ kind: OpusFailureKind, detail: String, videoId: String, now: Double, os: String) {
        videos[videoId] = Entry(kind: kind, detail: detail, at: now)
        if kind == .verify, acceptedOS != os {
            if refusalsOS != os {
                refusalsOS = os
                refusals = 0
            }
            refusals += 1
        }
        if videos.count > Self.maxEntries {
            for (key, _) in videos.sorted(by: { $0.value.at < $1.value.at }).prefix(videos.count - Self.maxEntries) {
                videos[key] = nil
            }
        }
    }

    /// A file passed the check and was published.
    public mutating func recordSuccess(videoId: String, os: String) {
        videos[videoId] = nil
        acceptedOS = os
        refusals = 0
        refusalsOS = nil
        missesInARow = 0
        pausedUntil = nil
    }

    /// An Opus resolution finished: `found` when a client offered a usable Opus stream.
    public mutating func recordResolution(found: Bool, now: Double) {
        guard !found else {
            missesInARow = 0
            return
        }
        missesInARow += 1
        if missesInARow >= Self.missesBeforePause {
            pausedUntil = now + Self.pauseSeconds
            missesInARow = 0
        }
    }

    /// The player could not open a published file: the video goes back to AAC.
    public mutating func forget(videoId: String) {
        videos[videoId] = nil
    }
}

/// Keeps the `player` responses of the AAC resolution for a few minutes, so the Opus resolution of the same video
/// reads them instead of asking YouTube again (on the usual path, VISIONOS, choosing Opus then costs no request).
/// The AAC side always asks live, as before: its retries after a 403 need fresh URLs.
public actor PlayerResponseMemo {
    public static let lifetimeSeconds: Double = 600
    public static let capacity = 16

    public nonisolated let inner: any YouTubePlayerFetching
    private let now: @Sendable () -> Double
    private var entries: [String: (response: YouTubePlayerResponse, at: Double)] = [:]
    private var order: [String] = []

    public init(inner: any YouTubePlayerFetching, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.inner = inner
        self.now = now
    }

    /// The fetcher for the AAC chain: always live; playable responses are remembered.
    public nonisolated var live: MemoPlayerFetcher { MemoPlayerFetcher(memo: self, reuse: false) }
    /// The fetcher for the Opus chain: a remembered response when fresh, else live.
    public nonisolated var remembered: MemoPlayerFetcher { MemoPlayerFetcher(memo: self, reuse: true) }

    func fetch(videoId: String, profile: InnerTubeClientProfile, reuse: Bool) async throws -> YouTubePlayerResponse? {
        let key = "\(videoId)|\(profile.name)"
        if reuse, let entry = entries[key], now() - entry.at < Self.lifetimeSeconds { return entry.response }
        let response = try await inner.fetchPlayer(videoId: videoId, profile: profile)
        if let response, response.isPlayable {
            entries[key] = (response, now())
            order.removeAll { $0 == key }
            order.append(key)
            while order.count > Self.capacity { entries[order.removeFirst()] = nil }
        }
        return response
    }

    /// Drops a video's remembered responses (its Opus URL was refused).
    public func forget(videoId: String) {
        let prefix = "\(videoId)|"
        for key in order where key.hasPrefix(prefix) { entries[key] = nil }
        order.removeAll { $0.hasPrefix(prefix) }
    }
}

/// One face of `PlayerResponseMemo`.
public struct MemoPlayerFetcher: YouTubePlayerFetching {
    let memo: PlayerResponseMemo
    let reuse: Bool

    public func fetchPlayer(videoId: String, profile: InnerTubeClientProfile) async throws -> YouTubePlayerResponse? {
        try await memo.fetch(videoId: videoId, profile: profile, reuse: reuse)
    }

    public var lastFailureReason: String? {
        get async { await memo.inner.lastFailureReason }
    }
}

/// An Opus stream ready to download, with what the checks need.
public struct OpusStreamResolution: Sendable, Hashable {
    public var stream: ResolvedStream
    public var itag: Int?
    /// YouTube's lengths of this stream and of the AAC stream the song would otherwise play.
    public var opusDurationMs: Double?
    public var aacDurationMs: Double?
    public var contentLength: Int64?

    public init(stream: ResolvedStream, aacStreamURL: String?) {
        self.stream = stream
        itag = OpusStreamPolicy.itag(streamURL: stream.url)
        opusDurationMs = OpusStreamPolicy.durationMs(streamURL: stream.url)
        aacDurationMs = aacStreamURL.flatMap { OpusStreamPolicy.durationMs(streamURL: $0) }
        contentLength = OpusStreamPolicy.contentLength(streamURL: stream.url)
    }
}
