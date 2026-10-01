// Port of `data/youtube/PlaybackDiagnostics.kt`: runs the whole chain on one track and says, in plain sentences,
// which step broke — from outside every failure looks the same ("it doesn't play"). Android's last step probed its
// local HTTP proxy; iOS has no proxy, so the last step probes the app's streaming loader (the same ranged fetch the
// AVAssetResourceLoader delegate makes). The app supplies the network pieces as closures.

import Foundation

/// The playback test's result (`PlaybackDiagnosticsReport`).
public struct PlaybackDiagnosticsReport: Sendable, Hashable {
    public struct Step: Sendable, Hashable {
        public var title: String
        public var ok: Bool
        public var detail: String

        public init(title: String, ok: Bool, detail: String) {
            self.title = title
            self.ok = ok
            self.detail = detail
        }
    }

    public var steps: [Step]
    public var succeeded: Bool

    public init(steps: [Step], succeeded: Bool) {
        self.steps = steps
        self.succeeded = succeeded
    }

    /// `asPlainText()`: one line per step to paste in a message (`OK  ` / `FAIL `, title, " — ", detail).
    public func asPlainText() -> String {
        var out = ""
        for step in steps {
            out += step.ok ? "OK  " : "FAIL "
            out += step.title
            out += " — "
            out += step.detail
            out += "\n"
        }
        return out
    }
}

/// The song the test runs on.
public struct DiagnosticsTrack: Sendable, Hashable {
    public var title: String
    public var artist: String
    public var album: String
    public var durationMs: Int64
    /// Set for songs that came from YouTube Music (no matching needed); nil for Spotify songs.
    public var videoId: String?

    public init(title: String, artist: String, album: String, durationMs: Int64, videoId: String?) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.videoId = videoId
    }
}

/// What the stream resolution did (the chain, then Piped).
public struct StreamResolutionOutcome: Sendable, Hashable {
    public var stream: ResolvedStream?
    public var attempts: [String]
    public var successfulStrategy: String?

    public init(stream: ResolvedStream?, attempts: [String], successfulStrategy: String?) {
        self.stream = stream
        self.attempts = attempts
        self.successfulStrategy = successfulStrategy
    }
}

/// `PlaybackDiagnostics`.
public struct PlaybackDiagnostics: Sendable {
    public static let titleTrack = "Imported tracks"
    public static let titleSearch = "YouTube Music search"
    public static let titleMatching = "Track matching"
    public static let titleStream = "Audio stream"
    /// Android: "Local audio server" (its HTTP proxy). iOS: the resource loader's fetch.
    public static let titleLoader = "Streaming loader"

    public let search: any YouTubeMusicSearching
    public let lastSearchFailure: @Sendable () async -> String?
    public let resolve: @Sendable (_ videoId: String) async -> StreamResolutionOutcome
    public let probeLoader: @Sendable (_ videoId: String, _ stream: ResolvedStream) async -> StreamProbe

    public init(search: any YouTubeMusicSearching, lastSearchFailure: @escaping @Sendable () async -> String?,
                resolve: @escaping @Sendable (_ videoId: String) async -> StreamResolutionOutcome,
                probeLoader: @escaping @Sendable (_ videoId: String, _ stream: ResolvedStream) async -> StreamProbe) {
        self.search = search
        self.lastSearchFailure = lastSearchFailure
        self.resolve = resolve
        self.probeLoader = probeLoader
    }

    public func run(track: DiagnosticsTrack?) async -> PlaybackDiagnosticsReport {
        typealias Step = PlaybackDiagnosticsReport.Step
        var steps: [Step] = []

        // 1. Is there anything to test with?
        guard let track else {
            steps.append(Step(title: Self.titleTrack, ok: false,
                              detail: "No YouTube or Spotify songs in the library yet — add one from Search first."))
            return PlaybackDiagnosticsReport(steps: steps, succeeded: false)
        }
        steps.append(Step(title: Self.titleTrack, ok: true, detail: "Testing with \"\(track.title)\" by \(track.artist)."))

        // 2. Does YouTube Music search answer?
        let query = "\(track.title) \(NetText.trim(NetText.substringBefore(track.artist, ",")))"
        let candidates: [YouTubeSearchResult]
        do { candidates = try await search.searchSongs(query, limit: 5) } catch { candidates = [] }
        if candidates.isEmpty {
            let reason = await lastSearchFailure()
            steps.append(Step(title: Self.titleSearch, ok: false,
                              detail: reason ?? "Search returned nothing. YouTube is refusing the request."))
            return PlaybackDiagnosticsReport(steps: steps, succeeded: false)
        }
        steps.append(Step(title: Self.titleSearch, ok: true,
                          detail: "\(candidates.count) candidates, top one: \"\(candidates[0].title)\"."))

        // 3. Does one of them look close enough? (YouTube Music songs already know their video.)
        let videoId: String
        if let known = track.videoId {
            videoId = known
            steps.append(Step(title: Self.titleMatching, ok: true,
                              detail: "Already linked to video \(known) (picked in YouTube Music search)."))
        } else {
            let song = MatchableTrack(title: track.title, artist: track.artist, album: track.album, durationMs: track.durationMs)
            let match = try? await TrackMatcher(search: search).findMatch(song)
            guard let match else {
                let best = candidates.map { TrackMatcher.score(song, $0) }.max() ?? 0
                steps.append(Step(title: Self.titleMatching, ok: false,
                                  detail: "Found results but none scored high enough (best \(Self.twoDecimals(best)), need \(Self.twoDecimals(TrackMatcher.minAcceptScore)))."))
                return PlaybackDiagnosticsReport(steps: steps, succeeded: false)
            }
            videoId = match.videoId
            steps.append(Step(title: Self.titleMatching, ok: true,
                              detail: "Matched \"\(match.candidateTitle)\" (score \(Self.twoDecimals(match.score)))."))
        }

        // 4. Can the video become audio that really plays? (Resolution validates each URL before accepting it.)
        let outcome = await resolve(videoId)
        guard let stream = outcome.stream, !NetText.isBlank(stream.url) else {
            let detail = outcome.attempts.isEmpty
                ? "No YouTube client responded at all — check the internet connection."
                : "Every YouTube client refused:\n" + outcome.attempts.map { "• \($0)" }.joined(separator: "\n")
            steps.append(Step(title: Self.titleStream, ok: false, detail: detail))
            return PlaybackDiagnosticsReport(steps: steps, succeeded: false)
        }
        var streamDetail = "Playable via \(outcome.successfulStrategy ?? "unknown")."
        let rejected = outcome.attempts.dropLast()
        if !rejected.isEmpty {
            streamDetail += "\nTried first:\n" + rejected.map { "• \($0)" }.joined(separator: "\n")
        }
        steps.append(Step(title: Self.titleStream, ok: true, detail: streamDetail))

        // 5. The step the player really uses: the streaming loader's own ranged fetch.
        let probe = await probeLoader(videoId, stream)
        steps.append(Step(title: Self.titleLoader, ok: probe.ok,
                          detail: probe.ok
                              ? "Audio reaches the player (\(probe.contentType ?? "unknown type"))."
                              : "The player's own route failed: \(probe.describe()). YouTube hands over the audio, but it does not survive the trip through the streaming loader."))
        return PlaybackDiagnosticsReport(steps: steps, succeeded: probe.ok)
    }

    /// Kotlin `"%.2f".format(x)` (half-up, two decimals) without locale separators.
    static func twoDecimals(_ value: Float) -> String {
        let hundredths = Int((Double(value) * 100).rounded(.toNearestOrAwayFromZero))
        let sign = hundredths < 0 ? "-" : ""
        let magnitude = abs(hundredths)
        let fraction = magnitude % 100
        return "\(sign)\(magnitude / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}
