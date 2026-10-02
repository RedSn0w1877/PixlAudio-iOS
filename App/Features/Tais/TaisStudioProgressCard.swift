import PixlModel
import SwiftUI

/// Android `TaisStudioProgressCard` — "Remaster Song": an AutoAwesome header, then one row per job (Render
/// Instrumental, Sync / resync lyrics, and in Experimental also Render Studio Master (BS-RoFormer)) separated by
/// `outlineVariant` dividers. Each row shows its job's live progress bar + "detail · N%", the ready line (check) or
/// the failure (error), and a full-width tonal button. Android: a 10 dp `surfaceContainer` surface, 16 dp padding,
/// 12 dp spacing → a 10 pt glass panel tinted `surfaceContainer`; the buttons and bars sit on it as fills.
///
/// iOS additions: a running job can be cancelled from its row (Android cancels from the notification), and a job
/// whose model isn't on the phone yet shows the model download inside its row.
struct TaisStudioProgressCard: View {
    let song: Song?
    var showRoformerTools = false
    /// Glass tint strength (the Experimental panels use their own row strength).
    var tintStrength: Double = GlassTint.surface
    /// Android's toasts: called once when a job of this card finishes with an update.
    var onInstrumentalReady: (() -> Void)?
    var onLyricsReady: (() -> Void)?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @State private var confirmsReplace = false

    var body: some View {
        let studio = env.tais.studio
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.secondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "Remaster Song").pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                    Text("Render an instrumental or sync the lyrics word-by-word for this track — each runs on its own, so you don't have to wait on one to get the other.")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TaisJobRow(song: song, kind: .instrumental, buttonLabel: "Render Instrumental", readyLabel: "Instrumental ready.",
                       state: song.flatMap { studio.state(.instrumental, songId: $0.id) },
                       onStart: { studio.start(.instrumental, song: $0) },
                       onCancel: { studio.cancel(.instrumental, songId: $0.id) })
            divider
            TaisJobRow(song: song, kind: .lyrics, buttonLabel: "Sync / resync lyrics", readyLabel: "Lyrics synced.",
                       state: song.flatMap { studio.state(.lyrics, songId: $0.id) },
                       onStart: { startLyrics($0) },
                       onCancel: { studio.cancel(.lyrics, songId: $0.id) })
            if showRoformerTools {
                divider
                TaisJobRow(song: song, kind: .roformer, buttonLabel: "Render Studio Master (BS-RoFormer)",
                           readyLabel: "BS-RoFormer master ready.",
                           state: song.flatMap { studio.state(.roformer, songId: $0.id) },
                           onStart: { studio.start(.roformer, song: $0) },
                           onCancel: { studio.cancel(.roformer, songId: $0.id) })
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                   tint: theme.surfaceContainer.opacity(tintStrength))
        .animation(PixlMotion.state, value: song.flatMap { studio.state(.lyrics, songId: $0.id)?.phase })
        .animation(PixlMotion.state, value: song.flatMap { studio.state(.instrumental, songId: $0.id)?.phase })
        .alert("Replace your timing?", isPresented: $confirmsReplace) {
            Button("Replace") { if let song { studio.start(.lyrics, song: song, overrideUser: true) } }
            Button("Keep mine", role: .cancel) {}
        } message: {
            Text("You synced this song yourself. Replace your timing with the automatic one?")
        }
        .onChange(of: song.flatMap { studio.state(.instrumental, songId: $0.id)?.phase }) { _, phase in
            if phase == .succeeded(updated: true) { onInstrumentalReady?() }
        }
        .onChange(of: song.flatMap { studio.state(.lyrics, songId: $0.id)?.phase }) { _, phase in
            if phase == .succeeded(updated: true) { onLyricsReady?() }
        }
        .accessibilityIdentifier("tais.studio")
    }

    private var divider: some View {
        Rectangle().fill(theme.outlineVariant).frame(height: 1)
    }

    /// A song the user synced themselves asks first ("Replace" passes the override).
    private func startLyrics(_ song: Song) {
        let studio = env.tais.studio
        guard let service = env.lyricsController.lyricsService else {
            studio.start(.lyrics, song: song)
            return
        }
        Task {
            if await service.isUserSyncedStored(song) {
                confirmsReplace = true
            } else {
                studio.start(.lyrics, song: song)
            }
        }
    }
}

/// One job's button + progress / result (Android `TaisJobRow`).
private struct TaisJobRow: View {
    let song: Song?
    let kind: TaisStudio.JobKind
    let buttonLabel: String
    let readyLabel: String
    let state: TaisStudio.JobState?
    let onStart: (Song) -> Void
    let onCancel: (Song) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        let running = state?.isActive == true
        VStack(alignment: .leading, spacing: 8) {
            if running, let state {
                VStack(alignment: .leading, spacing: 6) {
                    TaisProgressBar(fraction: Double(state.percent) / 100)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(state.detail ?? "Starting…") · \(state.percent)%")
                            .pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("tais.\(kind.rawValue).detail")
                        if let song {
                            Button("Cancel") { onCancel(song) }
                                .pixlFont(.labelLarge)
                                .foregroundStyle(theme.primary)
                                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.95))
                                .accessibilityIdentifier("tais.\(kind.rawValue).cancel")
                        }
                    }
                }
                .transition(.opacity)
            }
            if case .succeeded = state?.phase {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.primary)
                    Text(state?.detail ?? readyLabel)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
            if let reason = failure {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(theme.error)
                    Text(reason)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsFillButton(title: song == nil ? "Play a song first" : buttonLabel, style: .tonal,
                               enabled: song != nil && !running) {
                if let song { onStart(song) }
            }
            .accessibilityIdentifier("tais.\(kind.rawValue).start")
        }
    }

    private var failure: String? {
        switch state?.phase {
        case .failed(let reason): reason
        case .cancelled: "Cancelled — tap below to try again."
        default: nil
        }
    }
}

/// Android `LinearProgressIndicator` (6 pt, 3 pt corners): `primary` over a `secondaryContainer` track.
struct TaisProgressBar: View {
    let fraction: Double
    @Environment(\.appTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.secondaryContainer)
                Capsule().fill(theme.primary)
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 6))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(fraction * 100)) percent"))
    }
}
