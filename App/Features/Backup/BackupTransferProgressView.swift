import PixlBackup
import SwiftUI

/// Android `BackupTransferProgressDialog`: a centred 28 pt card over a scrim — "Creating Backup" / "Restoring
/// Backup", a 96 pt primary indicator with the percentage, a progress bar, the step title, "Importing • Step n of m",
/// the step detail and the module being processed. The card is glass; Material's morphing loading indicator and wavy
/// bar become a primary disc with a turning ring and a plain capsule bar.
struct BackupTransferProgressView: View {
    let progress: BackupTransferProgressUpdate
    @Environment(\.appTheme) private var theme

    var body: some View {
        let fraction = Double(progress.progress)
        let percent = min(max(Int((fraction * 100).rounded()), 0), 100)
        let status = progress.operation == .export ? L10n.settingsBackupExporting : L10n.settingsBackupImporting
        let step = L10n.settingsBackupStepFormat(max(progress.step, 1), progress.totalSteps)
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
            VStack(spacing: 12) {
                Text(progress.operation == .export ? L10n.settingsDialogCreatingBackup : L10n.settingsDialogRestoringBackup)
                    .pixlFont(.titleMedium, weight: .semibold)
                    .foregroundStyle(theme.onSurface)
                BackupSpinner(percent: percent)
                    .frame(width: 96, height: 96)
                    .padding(.vertical, 8)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.surfaceContainerHighest)
                        Capsule().fill(theme.primary)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 8)
                .animation(.easeOut(duration: 0.3), value: fraction)
                Text(progress.title)
                    .pixlFont(.bodyLarge, weight: .medium)
                    .foregroundStyle(theme.onSurface)
                    .multilineTextAlignment(.center)
                Text(L10n.settingsDialogBulletStep(status, step))
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                Text(progress.detail)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: progress.detail)
                if let section = progress.section {
                    Text(section.label)
                        .pixlFont(.labelMedium)
                        .foregroundStyle(theme.primary)
                }
            }
            .padding(20)
            .frame(maxWidth: 340)
            .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                       tint: theme.surface.opacity(GlassTint.container))
            .padding(.horizontal, 28)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("backup.progress")
    }
}

/// The primary disc with the percentage and a turning ring (stands in for Material's `LoadingIndicator`).
private struct BackupSpinner: View {
    let percent: Int
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(theme.primary.opacity(0.45), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: turning)
            Circle()
                .fill(theme.primary)
                .padding(10)
            Text(L10n.settingsDialogProgressPercent(percent))
                .pixlFont(.custom(size: 22, weight: .bold))
                .foregroundStyle(theme.onPrimary)
                .monospacedDigit()
        }
        .onAppear { turning = true }
    }
}

extension View {
    /// Shows the transfer dialog over the view while `progress` is set.
    func backupProgressOverlay(_ progress: BackupTransferProgressUpdate?) -> some View {
        overlay {
            if let progress {
                BackupTransferProgressView(progress: progress)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: progress == nil)
    }
}
