import PixlNet
import SwiftUI

/// The confirm sheet before anything is sent (design §5 app guards, §7.3): songs, minutes, upload size, the estimated
/// cost and what is left of the month's cap, plus what was skipped and why. Presented with the system sheet at the
/// see-through 92 % detent; the figures sit on plain fills (no glass on the sheet's glass).
struct CloudConfirmSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Router.self) private var router
    @Environment(\.appTheme) private var theme
    @State private var isSending = false

    var body: some View {
        let cloud = env.cloud
        SheetScaffold("Send to the cloud") {
            if let batch = cloud.pendingBatch {
                content(batch, cloud: cloud)
            } else {
                Text(verbatim: "Nothing to send.")
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 24)
            }
        }
        .accessibilityIdentifier("screen.cloudConfirm")
        .onDisappear {
            if !isSending { cloud.pendingBatch = nil }
        }
    }

    private func content(_ batch: CloudBatchPreview, cloud: CloudStudio) -> some View {
        let estimate = batch.estimate
        let canSend = !batch.isEmpty && estimate.fitsCap && cloud.settings.isEnabled && !isSending
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: batch.title)
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        figure("Songs", "\(estimate.songs)", "music.note.list")
                        figure("Minutes", "\(estimate.minutes)", "clock")
                        figure("Upload", "\(estimate.uploadMB) MB", "arrow.up.circle")
                        figure("Estimated cost", CloudCost.format(microUSD: estimate.costMicroUSD), "dollarsign.circle")
                    }
                    line(estimate.fitsCap
                         ? "This month: \(CloudCost.format(microUSD: estimate.remainingMicroUSD)) left of \(CloudCost.format(microUSD: estimate.capMicroUSD))."
                         : "Over this month's cap: \(CloudCost.format(microUSD: estimate.remainingMicroUSD)) left of \(CloudCost.format(microUSD: estimate.capMicroUSD)). Raise it in Cloud processing, or send fewer songs.",
                         systemImage: estimate.fitsCap ? "gauge.with.dots.needle.33percent" : "exclamationmark.triangle",
                         emphasis: !estimate.fitsCap)
                    if estimate.streamedSongs > 0 {
                        line(estimate.streamedSongs == 1
                             ? "1 streamed song is downloaded to this iPhone first, then sent."
                             : "\(estimate.streamedSongs) streamed songs are downloaded to this iPhone first, then sent.",
                             systemImage: "arrow.down.to.line")
                    }
                    if !cloud.settings.useCellular {
                        line("Uploads wait for Wi-Fi (Use cellular data is off).", systemImage: "wifi")
                    }
                    ForEach(batch.skipped) { skip in
                        line("\(skip.count) skipped — \(skip.reason.label)", systemImage: "minus.circle")
                    }
                    if !cloud.settings.isEnabled {
                        line(CloudStudio.Notice.off.message, systemImage: "lock", emphasis: true)
                    }
                    Text(verbatim: CloudProcessingCopy.promise)
                        .pixlFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            HStack(spacing: 12) {
                SettingsFillButton(title: "Cancel", style: .outlined) {
                    cloud.pendingBatch = nil
                    router.dismissSheet()
                }
                .accessibilityIdentifier("cloud.confirm.cancel")
                SettingsFillButton(title: batch.isEmpty ? "Nothing to send"
                                   : (batch.plans.count == 1 ? "Send 1 song" : "Send \(batch.plans.count) songs"),
                                   systemImage: "icloud.and.arrow.up", style: .filled, enabled: canSend) {
                    isSending = true
                    Task {
                        await cloud.send(batch)
                        router.dismissSheet()
                    }
                }
                .accessibilityIdentifier("cloud.confirm.send")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func figure(_ title: String, _ value: String, _ systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .pixlFont(.labelMedium)
                .foregroundStyle(theme.onSurfaceVariant)
            Text(verbatim: value)
                .pixlFont(.headlineSmall, weight: .bold)
                .foregroundStyle(theme.onSurface)
                .monospacedDigit()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainerHigh.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func line(_ text: String, systemImage: String, emphasis: Bool = false) -> some View {
        Label {
            Text(verbatim: text)
                .pixlFont(.bodyMedium)
                .foregroundStyle(emphasis ? theme.error : theme.onSurface)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(emphasis ? theme.error : theme.secondary)
        }
    }
}
