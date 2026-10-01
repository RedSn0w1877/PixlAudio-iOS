import Foundation
import PixlModel
import PixlNet

/// The dashboard's "Test playback" report (Android `PlaybackDiagnosticsReport`): one step per link of the chain.
nonisolated struct SpotifyPlaybackTestReport: Sendable, Equatable {
    struct Step: Sendable, Equatable, Identifiable {
        var title: String
        var ok: Bool
        var detail: String
        var id: String { title }
    }

    var steps: [Step]
    var succeeded: Bool

    /// `asPlainText`.
    var plainText: String {
        steps.map { "\($0.ok ? "OK  " : "FAIL ")\($0.title) — \($0.detail)" }.joined(separator: "\n")
    }
}

/// Port of `PlaybackDiagnostics.run()`: imported track → YouTube Music search → matching → audio stream → the
/// player's own route. Android's last step probed its local HTTP proxy; iOS has none, so it checks the URL the
/// player would open (`SpotifyPlayableURLResolver`) — the streaming loader is registered for it, or a direct URL
/// answers a ranged GET with audio.
nonisolated struct SpotifyPlaybackTest {
    let persistence: PersistenceActor
    let bridge: any SpotifyYouTubeBridge
    let resolver: SpotifyPlayableURLResolver
    let http: any HTTPClient

    func run() async -> SpotifyPlaybackTestReport {
        typealias Step = SpotifyPlaybackTestReport.Step
        var steps: [Step] = []

        // 1. Anything imported?
        guard let song = (try? await persistence.allSongs())?.first else {
            steps.append(Step(title: "Imported tracks", ok: false, detail: "No Spotify tracks in the database yet — run Sync first."))
            return SpotifyPlaybackTestReport(steps: steps, succeeded: false)
        }
        steps.append(Step(title: "Imported tracks", ok: true, detail: "Testing with \"\(song.title)\" by \(song.artist)."))

        // 2. Does YouTube Music search answer?
        let primaryArtist = song.artist.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? song.artist
        let query = "\(song.title) \(primaryArtist.trimmingCharacters(in: .whitespaces))"
        let candidates = (try? await bridge.search.searchSongs(query, limit: 5)) ?? []
        if candidates.isEmpty {
            let reason = await bridge.lastSearchFailure()
            steps.append(Step(title: "YouTube Music search", ok: false,
                              detail: reason ?? "Search returned nothing. YouTube is refusing the request."))
            return SpotifyPlaybackTestReport(steps: steps, succeeded: false)
        }
        steps.append(Step(title: "YouTube Music search", ok: true,
                          detail: "\(candidates.count) candidates, top one: \"\(candidates[0].title)\"."))

        // 3. Does one look close enough?
        let matcher = TrackMatcher(search: bridge.search)
        guard let found = try? await matcher.findMatch(song.matchable), let match = found else {
            let best = candidates.map { TrackMatcher.score(song.matchable, $0) }.max() ?? 0
            steps.append(Step(title: "Track matching", ok: false,
                              detail: "Found results but none scored high enough (best \(Self.twoDecimals(best)), need \(TrackMatcher.minAcceptScore))."))
            return SpotifyPlaybackTestReport(steps: steps, succeeded: false)
        }
        steps.append(Step(title: "Track matching", ok: true,
                          detail: "Matched \"\(match.candidateTitle)\" (score \(Self.twoDecimals(match.score)))."))

        // 4. Can the video become audio that really downloads? (resolution validates each URL first)
        let stream = await bridge.resolveForDiagnostics(videoId: match.videoId)
        guard let url = stream.url, !url.isEmpty else {
            let detail = stream.attempts.isEmpty
                ? "No YouTube client responded at all — check the internet connection."
                : "Every YouTube client refused:\n" + stream.attempts.map { "• \($0)" }.joined(separator: "\n")
            steps.append(Step(title: "Audio stream", ok: false, detail: detail))
            return SpotifyPlaybackTestReport(steps: steps, succeeded: false)
        }
        var streamDetail = "Playable via \(stream.strategy ?? "unknown")."
        let rejected = stream.attempts.dropLast()
        if !rejected.isEmpty { streamDetail += "\nTried first:\n" + rejected.map { "• \($0)" }.joined(separator: "\n") }
        steps.append(Step(title: "Audio stream", ok: true, detail: streamDetail))

        // 5. The route the player really takes. The match is saved first: the resolver looks it up.
        try? await persistence.updateMatch(spotifyId: song.spotifyId, videoId: match.videoId, score: match.score, state: .matched)
        guard let playable = await resolver.playableURL(for: song.toSong()) else {
            steps.append(Step(title: "Player route", ok: false, detail: "The player could not build an address for this track."))
            return SpotifyPlaybackTestReport(steps: steps, succeeded: false)
        }
        if playable.scheme == "https" {
            let probe = await StreamUrlValidator(http: http).probe(url: playable.absoluteString,
                                                                  userAgent: stream.userAgent ?? InnerTubeContexts.androidVR.userAgent,
                                                                  sendRange: false)
            steps.append(Step(title: "Player route", ok: probe.ok,
                              detail: probe.ok ? "Audio reaches the player (\(probe.contentType ?? "unknown type"))."
                                  : "The player's own route failed: \(probe.describe())."))
            return SpotifyPlaybackTestReport(steps: steps, succeeded: probe.ok)
        }
        let streamable = await MainActor.run { StreamingResourceLoaderRegistry.shared.handles(playable) }
        steps.append(Step(title: "Player route", ok: streamable,
                          detail: streamable ? "The player streams it through the in-app loader (\(playable.scheme ?? "")://)."
                              : "The player would open \(playable.absoluteString), which nothing can stream yet."))
        return SpotifyPlaybackTestReport(steps: steps, succeeded: streamable)
    }

    /// Kotlin `"%.2f".format(x)` (root locale).
    static func twoDecimals(_ value: Float) -> String {
        let rounded = (Double(value) * 100).rounded() / 100
        let whole = Int(rounded)
        let cents = Int(((rounded - Double(whole)) * 100).rounded())
        return "\(whole).\(cents < 10 ? "0" : "")\(cents)"
    }
}
