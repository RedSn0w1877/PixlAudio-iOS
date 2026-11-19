import SwiftUI

/// The "Private" pill (docs/brain-spec.md, 8.5): visible at the top of the screen for as long as a private session is on,
/// so the listener knows what is not being counted. Tapping it ends the session. Off at every app start.
struct PrivatePill: View {
    let onEnd: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: onEnd) {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash").font(.system(size: 13, weight: .semibold))
                Text(BrainStrings.privatePill).pixlFont(.labelLarge)
            }
            .foregroundStyle(theme.onTertiaryContainer)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(PressScaleButtonStyle())
        .pixlGlass(in: Capsule(), tint: theme.tertiaryContainer.opacity(GlassTint.prominent), interactive: true)
        .accessibilityLabel(BrainStrings.privatePillDescription)
        .accessibilityIdentifier("brain.privatePill")
    }
}

/// Shows the pill over the content while `BrainActions.isPrivate` is on.
struct PrivatePillOverlay: ViewModifier {
    @Environment(AppEnvironment.self) private var env

    func body(content: Content) -> some View {
        let actions = env.brainActions
        content.overlay(alignment: .top) {
            if actions.isPrivate {
                PrivatePill { actions.setPrivate(false) }
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(PixlMotion.bars, value: actions.isPrivate)
    }
}

extension View {
    /// The "Private" pill, over the shell while a private session is on.
    func brainPrivatePill() -> some View { modifier(PrivatePillOverlay()) }
}
