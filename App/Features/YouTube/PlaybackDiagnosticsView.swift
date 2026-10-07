import Observation
import PixlModel
import PixlNet
import SwiftUI
import UIKit

/// Runs the playback test (Android `PlaybackDiagnostics` via the Spotify dashboard's "Test playback") and the
/// debug probe (Android "Deep probe": the cipher's base.js steps, the client attempts, the client table source),
/// and shows the stream start timings (iOS only: how long the last starts took, step by step).
@MainActor
@Observable
final class PlaybackDiagnosticsModel {
    var isRunning = false
    var report: PlaybackDiagnosticsReport?
    var didRun = false
    var isProbing = false
    var probeReport: String?
    /// The Stream start timings card's text (a snapshot taken when the button is tapped).
    var timingsReport: String?

    /// The song to test: the current one when it streams, else the first YouTube / Spotify song in the library.
    static func track(playback: PlaybackStore, library: LibraryStore) -> DiagnosticsTrack? {
        let candidates = [playback.current].compactMap { $0 } + library.songs
        guard let song = candidates.first(where: { YouTubeSongIdentity.videoId(for: $0) != nil || $0.spotifyId != nil })
        else { return nil }
        return DiagnosticsTrack(title: song.title, artist: song.displayArtist, album: song.album, durationMs: song.duration,
                                videoId: YouTubeSongIdentity.videoId(for: song))
    }

    func run(_ youtube: YouTubeServices, track: DiagnosticsTrack?) {
        guard !isRunning, let service = youtube.service, let fetcher = youtube.fetcher else { return }
        isRunning = true
        didRun = true
        report = nil
        Task {
            let diagnostics = PlaybackDiagnostics(
                search: service.client,
                lastSearchFailure: { await service.lastClientFailure() },
                resolve: { videoId in await service.diagnosticsOutcome(videoId: videoId) },
                probeLoader: { videoId, _ in await fetcher.probe(videoId: videoId) })
            report = await diagnostics.run(track: track)
            isRunning = false
        }
    }

    func deepProbe(_ youtube: YouTubeServices) {
        guard !isProbing, let service = youtube.service else { return }
        isProbing = true
        probeReport = nil
        let poTokens = youtube.poTokens
        Task {
            var out = "Client table: \(await service.remoteSource())\n"
            out += "Overlapping clients: \(await service.hedgingDescription())\n\n"
            out += "Signature cipher (base.js):\n\(await service.cipherReport())\n"
            let attempts = await service.lastAttempts
            out += "Last resolution:\n" + (attempts.isEmpty ? "(none yet)\n" : attempts.map { "• \($0)" }.joined(separator: "\n") + "\n")
            if let error = poTokens?.lastError { out += "\nPoToken: \(error)\n" }
            if let last = PlaybackStartTimings.shared.lastStartSummary() { out += "\nLast start:\n\(last)\n" }
            probeReport = out
            isProbing = false
        }
    }

    /// Snapshots the measured starts (newest first) into the Stream start timings card.
    func showTimings() {
        timingsReport = PlaybackStartTimings.shared.report()
    }

    // MARK: Demo (UI tests)

    static let demoPassed = PlaybackDiagnosticsReport(steps: [
        .init(title: PlaybackDiagnostics.titleTrack, ok: true, detail: "Testing with \"Neon Harbor\" by Luma Vale."),
        .init(title: PlaybackDiagnostics.titleSearch, ok: true, detail: "5 candidates, top one: \"Neon Harbor\"."),
        .init(title: PlaybackDiagnostics.titleMatching, ok: true, detail: "Matched \"Neon Harbor\" (score 0.97)."),
        .init(title: PlaybackDiagnostics.titleStream, ok: true, detail: "Playable via VISIONOS."),
        .init(title: PlaybackDiagnostics.titleLoader, ok: true, detail: "Audio reaches the player (audio/mp4)."),
    ], succeeded: true)

    /// Two demo starts in the real format: a cold stream, then a skip into the prepared next song.
    static var demoTimings: String {
        let began = ContinuousClock.now
        var cold = PlaybackStartTimings.Record(id: 1, title: "Neon Harbor", kind: .load, began: began)
        cold.key = "pixlstream://dQw4w9WgXcQ"
        cold.urlMs = 12
        cold.tracksMs = 622
        cold.builtMs = 627
        cold.playingMs = 840
        cold.resolve = PlaybackStartTimings.Resolve(ms: 310, configMs: 0, strategy: "VISIONOS",
                                                    detail: "itag 140, 129 kbps, n sin cambiar (sin validar)", hasN: false)
        cold.requests = 3
        cold.infoRequests = 1
        cold.toEndRequests = 1
        cold.cancelled = 1
        cold.fetches = 3
        cold.fetchedBytes = 2_752_512
        cold.firstFetchMs = 420
        cold.firstFetchBytes = 131_072
        cold.firstAnswerMs = 455
        var skip = PlaybackStartTimings.Record(id: 2, title: "Glass Tides", kind: .prepared, began: began)
        skip.key = "pixlstream://Zz9_-Zz9_-Z"
        skip.playingMs = 38
        skip.earlierResolve = PlaybackStartTimings.Resolve(ms: 290, configMs: 0, strategy: "VISIONOS",
                                                           detail: "itag 140, 129 kbps, n sin cambiar (sin validar)",
                                                           hasN: false)
        return [skip, cold].map { $0.lines(now: began).joined(separator: "\n") }.joined(separator: "\n\n")
    }

    static let demoFailed = PlaybackDiagnosticsReport(steps: [
        .init(title: PlaybackDiagnostics.titleTrack, ok: true, detail: "Testing with \"Neon Harbor\" by Luma Vale."),
        .init(title: PlaybackDiagnostics.titleSearch, ok: true, detail: "5 candidates, top one: \"Neon Harbor\"."),
        .init(title: PlaybackDiagnostics.titleMatching, ok: true, detail: "Already linked to video dQw4w9WgXcQ (picked in YouTube Music search)."),
        .init(title: PlaybackDiagnostics.titleStream, ok: false,
              detail: "Every YouTube client refused:\n• VISIONOS: LOGIN_REQUIRED — Sign in to confirm you're not a bot\n• IOS: OK but 0 usable formats\n• TVHTML5 (deciphered): could not run base.js\n• WEB_REMIX (deciphered): HTTP 403\n• Piped: no Piped instance resolved dQw4w9WgXcQ"),
    ], succeeded: false)
}

/// The playback test screen: Android's "Test playback" button and `DiagnosticsCard` (20 pt card, 16 pt padding,
/// 10 pt spacing; a passed / failed icon per step with its title and detail; the summary line; Close), plus the
/// "Deep probe (debug)" card (`DeepProbeCard`: monospace-free plain text here, scrollable, Copy / Close).
struct PlaybackDiagnosticsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback
    @Environment(LibraryStore.self) private var library
    @Environment(\.appTheme) private var theme
    @State private var model = PlaybackDiagnosticsModel()

    var body: some View {
        VStack(spacing: 0) {
            YouTubeTopBar(title: "Playback test")
            ScrollView {
                VStack(spacing: YouTubeMetrics.itemSpacing) {
                    intro
                    YouTubeWideButton(title: "Test playback", systemImage: "ladybug", enabled: !model.isRunning) {
                        model.run(env.youtube, track: PlaybackDiagnosticsModel.track(playback: playback, library: library))
                    }
                    .accessibilityIdentifier("diagnostics.run")
                    YouTubeWideButton(title: "Deep probe (debug)", systemImage: "ladybug", enabled: !model.isProbing) {
                        model.deepProbe(env.youtube)
                    }
                    // iOS only (streaming speed): how long the last starts took, step by step.
                    YouTubeWideButton(title: "Stream start timings", systemImage: "stopwatch") {
                        model.showTimings()
                    }
                    .accessibilityIdentifier("diagnostics.showTimings")
                    if model.isRunning || model.didRun {
                        DiagnosticsCard(isRunning: model.isRunning, report: model.report) {
                            model.report = nil
                            model.didRun = false
                        }
                    }
                    if model.isProbing || model.probeReport != nil {
                        DeepProbeCard(isRunning: model.isProbing, report: model.probeReport) { model.probeReport = nil }
                    }
                    if let timings = model.timingsReport {
                        DeepProbeCard(title: "Stream start timings", isRunning: false, report: timings) {
                            model.timingsReport = nil
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("diagnostics.timings")
                    }
                }
                .padding(.horizontal, YouTubeMetrics.screenPadding)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("screen.playbackDiagnostics")
        .onAppear(perform: applyDemoState)
    }

    private var intro: some View {
        Text("Plays one streamed song through every step — search, matching, the YouTube clients and the streaming loader — and shows where it breaks.")
            .pixlFont(.bodyMedium)
            .foregroundStyle(theme.onSurfaceVariant)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private func applyDemoState() {
        switch env.launch.screen {
        case .playbackDiagnostics:
            model.report = PlaybackDiagnosticsModel.demoPassed
            model.didRun = true
        case .playbackDiagnosticsFailed:
            model.report = PlaybackDiagnosticsModel.demoFailed
            model.didRun = true
        case .playbackDiagnosticsTimings:
            model.timingsReport = PlaybackDiagnosticsModel.demoTimings
        default:
            break
        }
    }
}

/// Android `DiagnosticsCard`.
struct DiagnosticsCard: View {
    let isRunning: Bool
    let report: PlaybackDiagnosticsReport?
    let onDismiss: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        GlassCard(cornerRadius: 20, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface / GlassTint.container)) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Playback test")
                    .pixlFont(.titleMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                if isRunning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Trying one song end to end…")
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurface)
                    }
                } else if let report {
                    ForEach(Array(report.steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: step.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(step.ok ? YouTubeMetrics.passedGreen : theme.error)
                                .frame(width: 18, height: 18)
                                .accessibilityLabel(step.ok ? "Passed" : "Failed")
                            VStack(alignment: .leading, spacing: 0) {
                                Text(step.title)
                                    .pixlFont(.bodyMedium, weight: .semibold)
                                    .foregroundStyle(theme.onSurface)
                                Text(step.detail)
                                    .pixlFont(.bodySmall)
                                    .foregroundStyle(theme.onSurfaceVariant)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text(report.succeeded ? "Everything works — this song is playable." : "The first red line above is where it breaks.")
                        .pixlFont(.bodyMedium, weight: .semibold)
                        .foregroundStyle(theme.onSurface)
                    HStack(spacing: 8) {
                        YouTubeWideButton(title: "Copy", systemImage: "doc.on.doc", onGlass: true) {
                            UIPasteboard.general.string = report.asPlainText()
                        }
                        YouTubeWideButton(title: "Close", onGlass: true, action: onDismiss)
                    }
                } else {
                    Text("The test could not run.")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurface)
                    YouTubeWideButton(title: "Close", onGlass: true, action: onDismiss)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diagnostics.card")
    }
}

/// Android `DeepProbeCard`: the raw report, scrollable (max 340 pt), Copy / Close. The Stream start timings card
/// (iOS only) is the same card under its own title.
struct DeepProbeCard: View {
    var title = "Deep probe (debug)"
    let isRunning: Bool
    let report: String?
    let onDismiss: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        GlassCard(cornerRadius: 20, tint: theme.surfaceContainerHigh.opacity(GlassTint.surface / GlassTint.container)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .pixlFont(.titleMedium, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                if isRunning {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Firing every request shape at YouTube… this takes a bit.")
                            .pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurface)
                    }
                } else {
                    let text = report ?? "No output."
                    ScrollView {
                        Text(text)
                            .pixlFont(.custom(size: 11))
                            .foregroundStyle(theme.onSurface)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 340)
                    HStack(spacing: 8) {
                        YouTubeWideButton(title: "Copy", onGlass: true) { UIPasteboard.general.string = text }
                        YouTubeWideButton(title: "Close", onGlass: true, action: onDismiss)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
