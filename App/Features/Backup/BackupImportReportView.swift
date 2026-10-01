import PixlBackup
import SwiftUI

/// The restore report (iOS addition; Android only toasts the result), in the layout of PixlAudio's backup dialogs:
/// the top bar, a status card (outcome, where the backup came from, when it was made), one card per restored module
/// with what was restored and how many entries matched no song in this library, the explanation of why songs go
/// unmatched, the pending playlist songs, failures, skipped settings and warnings, and "Done".
struct BackupImportReportView: View {
    let report: BackupRestoreReport
    let onDone: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var showsSkippedKeys = false

    var body: some View {
        VStack(spacing: 0) {
            BackupFlowTopBar(title: L10n.backupReportTitle, systemImage: "xmark", accessibilityLabel: L10n.commonClose,
                             action: onDone)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    statusCard
                        .padding(.top, 12)
                    if !report.entries.isEmpty {
                        sectionTitle(L10n.backupReportRestoredSection)
                        ForEach(report.entries) { entry in
                            BackupReportEntryCard(entry: entry)
                        }
                    }
                    if report.hasUnmatchedSongData {
                        noteCard(symbol: "music.note.list", title: L10n.backupReportUnmatchedTitle,
                                 body: L10n.backupReportUnmatchedBody(report.totalUnmatched),
                                 tint: theme.tertiaryContainer, content: theme.onTertiaryContainer)
                            .accessibilityIdentifier("backup.report.unmatched")
                    }
                    if report.pendingPlaylistSongs > 0 {
                        noteCard(symbol: "arrow.triangle.2.circlepath", title: nil,
                                 body: L10n.backupReportPending(report.pendingPlaylistSongs),
                                 tint: theme.secondaryContainer, content: theme.onSecondaryContainer)
                    }
                    if report.restoredSettings {
                        noteCard(symbol: "gearshape", title: nil, body: L10n.backupReportSettingsRestart,
                                 tint: theme.secondaryContainer, content: theme.onSecondaryContainer)
                    }
                    if !report.failures.isEmpty {
                        sectionTitle(L10n.backupReportFailedSection)
                        ForEach(report.failures) { failure in
                            BackupWarningCard(text: "\(failure.section.label): \(failure.message)")
                        }
                    }
                    if !report.skippedSettings.isEmpty {
                        skippedSettingsCard
                    }
                    if !report.warnings.isEmpty {
                        sectionTitle(L10n.backupReportWarningsTitle)
                        ForEach(report.warnings, id: \.self) { BackupWarningCard(text: $0) }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            HStack {
                Spacer()
                BackupPrimaryButton(title: L10n.commonDone, systemImage: "checkmark", action: onDone)
                    .accessibilityIdentifier("backup.report.done")
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .background(theme.surfaceContainerLowest.ignoresSafeArea())
        .accessibilityIdentifier("screen.backupReport")
    }

    // MARK: Cards

    private var statusCard: some View {
        let style = statusStyle
        let symbol = style.symbol, title = style.title, tint = style.tint, content = style.content
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(content, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .pixlFont(.titleLarge, weight: .semibold)
                    .foregroundStyle(content)
                if case .failed(let message) = report.outcome {
                    Text(message).pixlFont(.bodyMedium).foregroundStyle(content.opacity(0.9))
                } else {
                    Text(report.fromAndroid ? L10n.backupReportFromAndroid : L10n.backupReportFromPixlAudio)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(content.opacity(0.9))
                    if report.createdAt > 0 {
                        Text(L10n.backupReportCreated(BackupDates.created(report.createdAt)))
                            .pixlFont(.bodySmall)
                            .foregroundStyle(content.opacity(0.8))
                    }
                    if report.entries.isEmpty {
                        Text(L10n.backupReportNothingRestored).pixlFont(.bodySmall).foregroundStyle(content.opacity(0.8))
                    }
                }
                Text(report.fileName)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(content.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous), tint: tint.opacity(GlassTint.container))
    }

    private var statusStyle: (symbol: String, title: String, tint: Color, content: Color) {
        switch report.outcome {
        case .success: ("checkmark", L10n.backupReportSuccess, theme.primaryContainer, theme.onPrimaryContainer)
        case .partial: ("exclamationmark", L10n.backupReportPartial, theme.tertiaryContainer, theme.onTertiaryContainer)
        case .failed: ("xmark", L10n.backupReportFailed, theme.errorContainer, theme.onErrorContainer)
        }
    }

    private var skippedSettingsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(PixlMotion.state) { showsSkippedKeys.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17))
                        .foregroundStyle(theme.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.backupReportSkippedSettingsTitle)
                            .pixlFont(.titleSmall, weight: .semibold)
                            .foregroundStyle(theme.onSurface)
                        Text(L10n.backupReportSkippedSettingsBody(report.skippedSettings.count))
                            .pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .rotationEffect(.degrees(showsSkippedKeys ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle(pressedScale: 0.98))
            if showsSkippedKeys {
                Text(report.skippedSettings.joined(separator: ", "))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.leading, 34)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(SettingsTint.row))
    }

    private func noteCard(symbol: String, title: String?, body: String, tint: Color, content: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(content)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title).pixlFont(.titleSmall, weight: .semibold).foregroundStyle(content)
                }
                Text(body).pixlFont(.bodySmall).foregroundStyle(content.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous), tint: tint.opacity(GlassTint.container))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .pixlFont(.titleSmall, weight: .semibold)
            .foregroundStyle(theme.primary)
            .padding(.top, 6)
            .padding(.leading, 4)
    }
}

/// One restored module: the module's icon tile, label, "n restored" and, when entries were dropped, "m not matched".
private struct BackupReportEntryCard: View {
    let entry: BackupRestoreReport.Entry
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.section.systemImage)
                .font(.system(size: 19))
                .foregroundStyle(theme.primary)
                .frame(width: 48, height: 48)
                .background(theme.secondaryContainer, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.section.label).pixlFont(.titleMedium, weight: .bold).foregroundStyle(theme.onSurface)
                Text(L10n.backupReportCountRestored(entry.restored))
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                if entry.unmatched > 0 {
                    Text(L10n.backupReportCountUnmatched(entry.unmatched))
                        .pixlFont(.labelSmall)
                        .foregroundStyle(theme.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: entry.unmatched > 0 ? "exclamationmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(entry.unmatched > 0 ? theme.tertiary : theme.primary)
        }
        .padding(14)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(SettingsTint.row))
        .accessibilityElement(children: .combine)
    }
}
