import PixlModel
import SwiftUI

/// Home's active-jobs button (Android's `BadgedBox` icon button in `HomeGradientTopBar`, shown only while jobs are
/// queued or running): a Liquid Glass capsule with a sync symbol and the count, tinted with the primary container so
/// it reads as "live" next to the neutral changelog and settings circles. The symbol turns while something is actually
/// running (a system symbol effect; off with Reduce Motion), not while jobs only wait.
struct ActiveJobsButton: View {
    let count: Int
    let isWorking: Bool
    let action: () -> Void
    /// Long-press menu: "Cancel all" (after a confirmation) stops everything running or waiting.
    var onCancelAll: (() -> Void)?

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var openTick = 0
    @State private var confirmsCancelAll = false

    var body: some View {
        Button {
            openTick += 1
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .symbolEffect(.rotate, isActive: isWorking && !reduceMotion)
                Text("\(count)")
                    .pixlFont(.labelMedium, weight: .bold)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .foregroundStyle(theme.onPrimaryContainer)
            .padding(.horizontal, 13)
            .frame(minWidth: Tokens.TopBar.circleButtonSize, minHeight: Tokens.TopBar.circleButtonSize)
            // At least a 44 pt touch area around the 40 pt capsule, without changing the layout.
            .contentShape(Capsule().inset(by: -2))
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: theme.primaryContainer.opacity(GlassTint.container), interactive: true)
        .pixlHaptic(.impact(weight: .light), trigger: openTick)
        // Cancel is one long press away, not only inside the sheet.
        .contextMenu {
            Button("Open", systemImage: "list.bullet", action: action)
            if onCancelAll != nil {
                Button("Cancel all", systemImage: "xmark.circle", role: .destructive) { confirmsCancelAll = true }
            }
        }
        .alert("Cancel all jobs?", isPresented: $confirmsCancelAll) {
            Button("Cancel all", role: .destructive) { onCancelAll?() }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("Everything running or waiting stops, and downloads and scans are abandoned. Finished work stays.")
        }
        .animation(PixlMotion.state, value: count)
        .accessibilityLabel("Active jobs")
        .accessibilityValue(Text(verbatim: ActiveJobBoard.accessibilityValue(count: count)))
        .accessibilityHint("Shows what is running")
        .accessibilityIdentifier("home.jobs")
    }
}
