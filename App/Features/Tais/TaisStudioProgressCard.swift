import PixlModel
import PixlNet
import SwiftUI

/// Android `TaisStudioProgressCard` — "Make an instrumental": a sparkles header with the one line that helps choose,
/// then two equal buttons side by side, "Process on-device" and "Process in cloud". Under them come the on-device
/// job's live progress bar + "detail · N%" (and Cancel), its ready line (check) or failure (error), and the song's
/// cloud job as "Cloud: <status>". In Experimental the Render Studio Master (BS-RoFormer) row follows, separated by an
/// `outlineVariant` divider. Android: a 10 dp `surfaceContainer` surface, 16 dp padding, 12 dp spacing → a 10 pt glass
/// panel tinted `surfaceContainer`; the buttons and bars sit on it as fills.
///
/// iOS additions: a running job can be cancelled from its row (Android cancels from the notification), a job
/// whose model isn't on the phone yet shows the model download inside its row, and the cloud button starts at once
/// (no confirm sheet) and says when it cannot (cloud off, nothing to process, over the month's budget).
struct TaisStudioProgressCard: View {
    let song: Song?
    var showRoformerTools = false
    /// Glass tint strength (the Experimental panels use their own row strength).
    var tintStrength: Double = GlassTint.surface
    /// Android's toasts: called once when the instrumental of this card finishes with an update.
    var onInstrumentalReady: (() -> Void)?
    /// The card no longer syncs lyrics; kept (and ignored) so the call sites written for it still compile.
    var onLyricsReady: (() -> Void)?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @State private var isStartingCloud = false
    /// Why "Process in cloud" did nothing. The toast says it too, but the song sheet this card sits in can cover it.
    @State private var cloudNotice: String?

    var body: some View {
        let studio = env.tais.studio
        let cloud = env.cloud
        let instrumental = song.flatMap { studio.state(.instrumental, songId: $0.id) }
        // The song's own job, not a Sing preview piece of it.
        let cloudJob = song.flatMap { song in cloud.job(forSong: song.id) }
        VStack(alignment: .leading, spacing: 12) {
            header
            if let song {
                // Equal widths, and equal heights should a large text size wrap one label.
                HStack(spacing: 8) {
                    TaisStartButton(title: "Process on-device", enabled: instrumental?.isActive != true) {
                        studio.start(.instrumental, song: song)
                    }
                    .accessibilityIdentifier("tais.instrumental.start")
                    TaisStartButton(title: "Process in cloud",
                                    enabled: cloudJob?.state.isPending != true && !cloud.isPreviewing && !isStartingCloud) {
                        startInCloud(song)
                    }
                    .accessibilityIdentifier("tais.cloud.start")
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                SettingsFillButton(title: "Play a song first", style: .tonal, enabled: false) {}
                    .accessibilityIdentifier("tais.instrumental.start")
            }
            if let instrumental {
                TaisJobStatus(song: song, kind: .instrumental, readyLabel: "Instrumental ready.", state: instrumental,
                              onCancel: { studio.cancel(.instrumental, songId: $0.id) })
            }
            if let cloudJob {
                cloudStatus(cloudJob, progress: cloud.transferProgress[cloudJob.jobKey])
            }
            if let cloudNotice {
                Label {
                    Text(verbatim: cloudNotice)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(theme.onSurfaceVariant)
                }
                .accessibilityIdentifier("tais.cloud.notice")
            }
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
        .animation(PixlMotion.state, value: instrumental?.phase)
        .animation(PixlMotion.state, value: cloudNotice)
        .onChange(of: instrumental?.phase) { _, phase in
            if phase == .succeeded(updated: true) { onInstrumentalReady?() }
        }
        .onChange(of: song?.id) { _, _ in cloudNotice = nil }
        // `.contain` keeps the rows' own identifiers (an identifier on a plain stack would replace them).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tais.studio")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.secondary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Make an instrumental").pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                Text("Cloud yields better results but requires a Wi-Fi connection.")
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var divider: some View {
        Rectangle().fill(theme.outlineVariant).frame(height: 1)
    }

    /// The song's cloud job, once it has one.
    private func cloudStatus(_ job: CloudJobRecord, progress: Double?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: CloudJobStateIcon.symbol(job.state))
                .foregroundStyle(job.state == .failed ? theme.error : theme.primary)
            Text(verbatim: "Cloud: " + CloudJobRowText.status(job, progress: progress))
                .pixlFont(.bodySmall)
                .foregroundStyle(job.state == .failed ? theme.error : theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("tais.cloud.status")
    }

    /// Sends the song to the cloud at once and says what happened; the card keeps the words when nothing started.
    private func startInCloud(_ song: Song) {
        let cloud = env.cloud
        isStartingCloud = true
        cloudNotice = nil
        Task {
            let outcome = await cloud.startNow(songs: [song], title: song.title)
            let message = outcome.message(useCellular: cloud.settings.useCellular)
            isStartingCloud = false
            cloudNotice = outcome.didStart ? nil : message
            LibraryToast.shared.show(message)
        }
    }
}

/// One of the card's two start buttons: tonal, text only, filling its half of the row.
private struct TaisStartButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            Text(title)
                .pixlFont(.labelLarge)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.onSecondaryContainer)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: .infinity)
                .background(theme.secondaryContainer, in: Capsule())
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.38)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
        .disabled(!enabled)
    }
}

/// A job with a button of its own (Android `TaisJobRow`): its status, then the tonal button.
private struct TaisJobRow: View {
    let song: Song?
    let kind: TaisStudio.JobKind
    let buttonLabel: String
    let readyLabel: String
    let state: TaisStudio.JobState?
    let onStart: (Song) -> Void
    let onCancel: (Song) -> Void

    var body: some View {
        let running = state?.isActive == true
        VStack(alignment: .leading, spacing: 8) {
            if let state {
                TaisJobStatus(song: song, kind: kind, readyLabel: readyLabel, state: state, onCancel: onCancel)
            }
            SettingsFillButton(title: song == nil ? "Play a song first" : buttonLabel, style: .tonal,
                               enabled: song != nil && !running) {
                if let song { onStart(song) }
            }
            .accessibilityIdentifier("tais.\(kind.rawValue).start")
        }
    }
}

/// What a job is doing or did: the progress bar + "detail · N%" with Cancel, the ready line, or the failure.
private struct TaisJobStatus: View {
    let song: Song?
    let kind: TaisStudio.JobKind
    let readyLabel: String
    let state: TaisStudio.JobState
    let onCancel: (Song) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isActive {
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
            if case .succeeded = state.phase {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.primary)
                    Text(state.detail ?? readyLabel)
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
        }
    }

    private var failure: String? {
        switch state.phase {
        case .failed(let reason): reason
        case .cancelled: "Cancelled — you can start it again."
        default: nil
        }
    }
}

/// Android `LinearProgressIndicator` (6 pt, 3 pt corners): `primary` over a `secondaryContainer` track.
struct TaisProgressBar: View {
    let fraction: Double
    /// Indicator and track (default: the app scheme's `primary` over `secondaryContainer`).
    var colors: (indicator: Color, track: Color)?
    @Environment(\.appTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(colors?.track ?? theme.secondaryContainer)
                Capsule().fill(colors?.indicator ?? theme.primary)
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 6))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: fraction)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(fraction * 100)) percent"))
    }
}
