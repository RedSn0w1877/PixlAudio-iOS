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

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var openTick = 0

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
        .animation(PixlMotion.state, value: count)
        .accessibilityLabel("Active jobs")
        .accessibilityValue(Text(verbatim: ActiveJobBoard.accessibilityValue(count: count)))
        .accessibilityHint("Shows what is running")
        .accessibilityIdentifier("home.jobs")
    }
}
