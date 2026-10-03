import SwiftUI

/// A capsule button (Android pills and chips: the Home quick actions, the Beta chip, Library's Shuffle) as glass.
/// Geometry defaults to `HomeQuickActionsRow`: 14×10 padding, 18 pt icon, 8 pt gap, `labelLarge`.
struct GlassPillButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    /// Glass tint (a palette role). `nil` = plain glass (Android `surfaceContainer*` pills).
    var tint: Color?
    /// Text/icon colour; defaults to the theme's `onSurface`.
    var foreground: Color?
    var style: PixlTextStyle = .labelLarge
    var iconSize: CGFloat = 18
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 10
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.s) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: iconSize, weight: .semibold))
                        .frame(width: iconSize + 2, height: iconSize + 2)
                }
                Text(title)
                    .pixlFont(style)
                    .lineLimit(1)
            }
            .foregroundStyle(foreground ?? theme.onSurface)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Capsule(), tint: tint, interactive: true)
    }
}

/// A circular icon button (Android `FilledIconButton` / `FilledTonalIconButton`, 40 dp) as a glass circle.
/// A Material 24 dp icon ≈ an SF Symbol at 20 pt.
struct GlassCircleButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringKey
    var size: CGFloat = Tokens.TopBar.circleButtonSize
    var iconSize: CGFloat = 20
    var tint: Color?
    var foreground: Color?
    /// A count badge (Android `BadgedBox` on the jobs button).
    var badge: Int?
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(foreground ?? theme.onSurface)
                .frame(width: size, height: size)
                // At least a 44 pt touch area around the 40 pt circle, without changing the layout.
                .contentShape(Circle().inset(by: -max(0, (44 - size) / 2)))
        }
        .buttonStyle(.plain)
        .pixlGlass(in: Circle(), tint: tint, interactive: true)
        .overlay(alignment: .topTrailing) {
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.onError)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(theme.error, in: Capsule())
                    .offset(x: 2, y: -2)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
