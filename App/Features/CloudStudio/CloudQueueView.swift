import PixlModel
import PixlNet
import SwiftUI

/// The "process later" queue (design §7.3; iOS-first): what is on its way to the cloud, what came back, and what
/// needs the person. Songs are added from here (Current song / Songs without word-timed lyrics / Songs without an
/// instrumental) through the confirm sheet. Rows are one glass shape each in a lazy stack; progress comes from the
/// orchestrator (whole percents), never from a timer.
struct CloudQueueView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var confirmsCancelAll = false

    var body: some View {
        let cloud = env.cloud
        let active = cloud.activeJobs
        let attention = cloud.attentionJobs
        let finished = cloud.finishedJobs
        SettingsScaffold(title: "Cloud queue", screenID: "cloudQueue") {
            if let notice = cloud.notice {
                SettingsPanel(tint: notice == .capReached || notice == .endpointPaused ? theme.tertiaryContainer : theme.errorContainer) {
                    Label(notice.message, systemImage: "exclamationmark.triangle")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurface)
                    if notice != .off && notice != .capReached && notice != .endpointPaused {
                        SettingsFillButton(title: "Open Cloud processing", style: .tonal) { router.push(.cloudProcessing) }
                    }
                }
                .padding(.bottom, 10)
                .accessibilityIdentifier("cloud.notice")
            }
            SettingsSubsection(title: "Add songs") {
                addRow("Current song", "The song that's playing now.", "music.note", .current)
                addRow("Songs without word-timed lyrics", "Up to 200 songs from your library.", "text.word.spacing",
                       .missingLyrics)
                addRow("Songs without an instrumental", "Up to 200 songs from your library.", "waveform", .missingInstrumental)
            }
            if active.isEmpty && attention.isEmpty && finished.isEmpty {
                SettingsPanel {
                    Text(verbatim: "Nothing in the queue yet. Songs you send come back here with their instrumental and word-timed lyrics.")
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .accessibilityIdentifier("cloud.empty")
            }
            if !active.isEmpty {
                SettingsSubsection(title: "On its way (\(active.count))") {
                    ForEach(active) { record in
                        CloudJobRow(record: record, progress: cloud.transferProgress[record.jobKey])
                    }
                }
                SettingsFillButton(title: "Cancel all", systemImage: "xmark", style: .destructive) {
                    confirmsCancelAll = true
                }
                .padding(.bottom, 10)
                .accessibilityIdentifier("cloud.cancelAll")
            }
            if !attention.isEmpty {
                SettingsSubsection(title: "Needs you (\(attention.count))") {
                    ForEach(attention) { record in CloudJobRow(record: record, progress: nil) }
                }
                // Failed, cancelled and expired jobs can be cleared out without retrying them.
                SettingsFillButton(title: "Clear failed", systemImage: "trash", style: .outlined) { cloud.clearAttention() }
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("cloud.clearFailed")
            }
            if !finished.isEmpty {
                SettingsSubsection(title: "Done (\(finished.count))") {
                    ForEach(finished) { record in CloudJobRow(record: record, progress: nil) }
                }
                SettingsFillButton(title: "Clear done", systemImage: "checkmark", style: .outlined) { cloud.clearFinished() }
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("cloud.clearDone")
            }
            SettingsPanel {
                Text(verbatim: CloudProcessingCopy.monthLine(committed: cloud.committedThisMonthMicroUSD,
                                                             cap: cloud.settings.effectiveMonthlyCapMicroUSD))
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurface)
                Text(verbatim: CloudProcessingCopy.promise(builtIn: cloud.settings.usesBuiltInKeys))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Spacer().frame(height: 24)
        }
        .overlay {
            if cloud.isPreviewing {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("Looking through your library")
            }
        }
        .task { await cloud.loadForDisplay() }
        .alert("Cancel everything in the queue?", isPresented: $confirmsCancelAll) {
            Button("Cancel all", role: .destructive) { Task { await cloud.cancelAll() } }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Songs on their way stop, and their files are removed from the cloud. Finished songs stay.")
        }
    }

    private func addRow(_ title: String, _ subtitle: String, _ systemImage: String, _ kind: CloudBatchKind) -> some View {
        let cloud = env.cloud
        return SettingsItemRow(title: title, subtitle: subtitle, systemImage: systemImage, showsChevron: true,
                               identifier: "cloud.add.\(kind.rawValue)") {
            guard !cloud.isPreviewing else { return }
            Task {
                await cloud.requestBatch(kind)
                if cloud.pendingBatch != nil { router.present(AppSheet.cloudConfirm) }
            }
        }
    }
}

/// One job: its song, where it is (with transfer or worker progress), what went wrong with Retry, or what it cost.
struct CloudJobRow: View {
    let record: CloudJobRecord
    let progress: Double?

    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CloudJobStateIcon(state: record.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: record.title)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(1)
                Text(verbatim: record.artist)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
                Text(verbatim: CloudJobRowText.status(record, progress: progress))
                    .pixlFont(.bodySmall, weight: .semibold)
                    .foregroundStyle(record.state == .failed ? theme.error : theme.primary)
                    .lineLimit(2)
                if let detail = CloudJobRowText.detail(record) {
                    Text(verbatim: detail)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .settingsRowGlass()
        .contextMenu {
            if record.state.isFinished {
                Button("Remove from the list", systemImage: "trash") { env.cloud.remove(record.jobKey) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloud.job.\(record.jobKey)")
    }

    @ViewBuilder
    private var trailing: some View {
        switch record.state {
        case .failed, .cancelled, .expired:
            SettingsFillButton(title: "Retry", style: .tonal, fullWidth: false) { env.cloud.retry(record.jobKey) }
                .accessibilityIdentifier("cloud.retry.\(record.jobKey)")
        case .imported:
            EmptyView()
        default:
            Button {
                Task { await env.cloud.cancel(record.jobKey) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(width: 36, height: 36)
                    .background(theme.surfaceContainerHighest.opacity(0.6), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.9))
            .accessibilityLabel("Cancel")
            .accessibilityIdentifier("cloud.cancel.\(record.jobKey)")
        }
    }
}

/// The leading symbol of a job's state.
struct CloudJobStateIcon: View {
    let state: CloudJobState
    @Environment(\.appTheme) private var theme

    var body: some View {
        Image(systemName: Self.symbol(state))
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(state == .failed ? theme.error : theme.secondary)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
    }

    nonisolated static func symbol(_ state: CloudJobState) -> String {
        switch state {
        case .queued: "clock"
        case .preparing: "waveform.badge.magnifyingglass"
        case .uploading: "arrow.up.circle"
        case .uploaded, .submitted: "hourglass"
        case .running: "cpu"
        case .resultsReady, .downloading: "arrow.down.circle"
        case .imported: "checkmark.circle.fill"
        case .failed: "exclamationmark.octagon"
        case .cancelled: "xmark.circle"
        case .expired: "clock.badge.exclamationmark"
        }
    }
}

/// A row's words, built once per change (no formatting work in the views' bodies beyond these calls).
nonisolated enum CloudJobRowText {
    static func status(_ record: CloudJobRecord, progress: Double?) -> String {
        switch record.state {
        case .uploading, .downloading:
            if let progress { return "\(record.state.label) \(Int((progress * 100).rounded(.down)))%" }
            return record.state.label
        case .running:
            if let stage = record.progressStage {
                let label = CloudProgress(stage: stage, percent: record.progressPercent).label
                return record.progressPercent.map { "\(label) \($0)%" } ?? label
            }
            return record.state.label
        case .failed:
            if let code = record.lastErrorCode { return "Failed · \(code)" }
            return record.state.label
        case .imported:
            var parts = ["Done"]
            if record.importedInstrumental { parts.append("instrumental") }
            if record.importedLyrics { parts.append(record.lyricsTranscribed ? "AI-written lyrics" : "word-timed lyrics") }
            return parts.count == 1 ? "Done" : parts[0] + " · " + parts.dropFirst().joined(separator: " + ")
        default:
            if record.nextAttemptAtMs != nil, let error = record.lastError, !error.isEmpty { return "Trying again soon" }
            return record.state.label
        }
    }

    static func detail(_ record: CloudJobRecord) -> String? {
        var lines: [String] = []
        if record.state == .failed || record.state == .expired || record.nextAttemptAtMs != nil,
           let error = record.lastError, !error.isEmpty {
            lines.append(error)
        }
        if record.lowQualitySource { lines.append("Low-quality source: only a low-bitrate stream was on offer.") }
        if record.state != .imported, record.lyricsMode == .transcribe, record.tasks.contains(.lyrics) {
            lines.append("No lyrics yet: the cloud will write them (AI-written lyrics).")
        }
        if record.state == .imported {
            var cost: [String] = []
            if let microUSD = record.costMicroUSD { cost.append(CloudCost.format(microUSD: microUSD)) }
            if let gpu = record.gpu { cost.append(gpu) }
            if !cost.isEmpty { lines.append(cost.joined(separator: " · ")) }
            lines.append(contentsOf: record.warnings)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
