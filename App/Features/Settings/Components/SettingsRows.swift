import SwiftUI

// PixlAudio's settings rows (Android `SettingsComponents.kt`, Material 3 mode) as Liquid Glass. A section is a
// caption (`labelMedium`, `primary`, 12 pt in) over rows 2 pt apart; each row was a `surfaceContainer` Surface with
// 10 dp corners inside a group clipped to 24 dp — here every row is its own glass shape with the same corners: 24 pt
// on the group's outside edges, 10 pt between rows. Controls on a row are plain fills or system controls (no glass
// on glass). One glass layer per row, no container per row.

/// Corner radii a row takes from its position in a group.
nonisolated struct SettingsRowCorners: Equatable, Sendable {
    var top: CGFloat
    var bottom: CGFloat

    static let single = SettingsRowCorners(top: SettingsMetrics.groupRadius, bottom: SettingsMetrics.groupRadius)

    static func position(_ index: Int, of count: Int, outer: CGFloat = SettingsMetrics.groupRadius,
                         inner: CGFloat = SettingsMetrics.rowInnerRadius) -> SettingsRowCorners {
        SettingsRowCorners(top: index == 0 ? outer : inner, bottom: index == count - 1 ? outer : inner)
    }

    var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                               topTrailingRadius: top, style: .continuous)
    }
}

extension EnvironmentValues {
    /// Set by `SettingsGroup` on each of its rows.
    @Entry var settingsRowCorners: SettingsRowCorners = .single
}

/// Rows stacked 2 pt apart, each told its corner radii (Android's 24 dp group clip around 10 dp rows).
struct SettingsGroup<Content: View>: View {
    var spacing: CGFloat = SettingsMetrics.rowSpacing
    var outer: CGFloat = SettingsMetrics.groupRadius
    var inner: CGFloat = SettingsMetrics.rowInnerRadius
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Group(subviews: content) { subviews in
                let count = subviews.count
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    subview.environment(\.settingsRowCorners,
                                        .position(index, of: count, outer: outer, inner: inner))
                }
            }
        }
    }
}

/// Android `SettingsSubsection`: the caption, the group, and 10 pt below unless it's the last section.
struct SettingsSubsection<Content: View>: View {
    let title: String
    var addBottomSpace = true
    @ViewBuilder var content: Content

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .pixlFont(.labelMedium)
                .foregroundStyle(theme.primary)
                .padding(.leading, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            SettingsGroup { content }
            if addBottomSpace {
                Spacer().frame(height: 10)
            }
        }
    }
}

/// The glass behind one row, shaped by its group position.
struct SettingsRowBackground: ViewModifier {
    var tint: Color?
    var interactive = false
    @Environment(\.settingsRowCorners) private var corners
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(corners.shape)
            .pixlGlass(in: corners.shape,
                       tint: (tint ?? theme.surfaceContainer).opacity(SettingsTint.row),
                       interactive: interactive)
    }
}

extension View {
    func settingsRowGlass(tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(SettingsRowBackground(tint: tint, interactive: interactive))
    }
}

/// Tint strengths for the settings surfaces (Android `surfaceContainer` rows on a `surface` background).
nonisolated enum SettingsTint {
    static let row: Double = GlassTint.surface + 0.2
}

/// A leading icon in a row (Android: a 24 dp Material icon tinted `secondary`).
struct SettingsIcon: View {
    let systemImage: String
    var color: Color?
    @Environment(\.appTheme) private var theme

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(color ?? theme.secondary)
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}

/// Android `SettingsItem`: icon, title (`titleMedium`) over subtitle (`bodyMedium`, 6 pt apart), trailing chevron.
struct SettingsItemRow: View {
    let title: String
    let subtitle: String
    var systemImage: String?
    var iconColor: Color?
    var showsChevron = false
    var identifier: String?
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if let systemImage {
                    SettingsIcon(systemImage: systemImage, color: iconColor)
                        .padding(.trailing, 16)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSurface)
                    Text(subtitle)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                ZStack {
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .padding(16)
        }
        .buttonStyle(.plain)
        .settingsRowGlass(interactive: true)
        .accessibilityIdentifier(identifier ?? "settings.item.\(title)")
    }
}

/// Android `SwitchSettingItem`: icon, title / subtitle (4 pt apart), switch; disabled rows fade to 60 %.
struct SwitchSettingRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var systemImage: String?
    var iconColor: Color?
    var enabled = true

    @Environment(\.appTheme) private var theme
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                SettingsIcon(systemImage: systemImage, color: iconColor)
                    .padding(.trailing, 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface.opacity(enabled ? 1 : 0.6))
                Text(subtitle)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant.opacity(enabled ? 1 : 0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(theme.primary)
                .disabled(!enabled)
        }
        .padding(16)
        .settingsRowGlass()
        .sensoryFeedback(.impact(weight: .light), trigger: isOn) { _, _ in settings.behavior.hapticsEnabled }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.switch.\(title)")
    }
}

/// An option of a choice row.
nonisolated struct SettingsOption: Identifiable, Hashable, Sendable {
    let key: String
    let label: String
    var id: String { key }
}

/// Android `ThemeSelectorItem`: icon, label, description, the current value as a small capsule (`labelMedium` bold,
/// `primary`), and a bottom sheet of options (72 pt rows, 24 pt corners; selected = `primaryContainer` + check).
struct ThemeSelectorRow: View {
    let label: String
    let description: String
    let options: [SettingsOption]
    let selectedKey: String
    var systemImage: String?
    let onSelect: (String) -> Void

    @State private var showsSheet = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button { showsSheet = true } label: {
            HStack(alignment: .center, spacing: 0) {
                if let systemImage {
                    SettingsIcon(systemImage: systemImage)
                        .padding(.trailing, 16)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(label)
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSurface)
                    Spacer().frame(height: 6)
                    Text(description)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                    Spacer().frame(height: 10)
                    Text(selectedLabel)
                        .pixlFont(.labelMedium, weight: .bold)
                        .foregroundStyle(theme.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(theme.surfaceContainerLowest, in: Capsule())
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .buttonStyle(.plain)
        .settingsRowGlass(interactive: true)
        .accessibilityIdentifier("settings.choice.\(label)")
        .sheet(isPresented: $showsSheet) {
            SettingsOptionSheet(title: label, options: options, selectedKey: selectedKey) { key in
                onSelect(key)
                showsSheet = false
            }
            .presentationDetents([.height(min(CGFloat(options.count) * 80 + 120, 620))])
            .presentationDragIndicator(.visible)
        }
    }

    private var selectedLabel: String { options.first { $0.key == selectedKey }?.label ?? selectedKey }
}

/// The option list of a choice row (Android `ThemeSelectorItem`'s bottom sheet).
struct SettingsOptionSheet: View {
    let title: String
    let options: [SettingsOption]
    let selectedKey: String
    let onSelect: (String) -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .pixlFont(.headlineSmall, weight: .bold)
                .foregroundStyle(theme.onSurface)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            ScrollView {
                GlassEffectContainer(spacing: 4) {
                    VStack(spacing: 8) {
                        ForEach(options) { option in
                            optionRow(option)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func optionRow(_ option: SettingsOption) -> some View {
        let isSelected = option.key == selectedKey
        let content = isSelected ? theme.onPrimaryContainer : theme.onSurface
        return Button { onSelect(option.key) } label: {
            HStack {
                Text(option.label)
                    .pixlFont(.titleMedium, weight: isSelected ? .bold : .regular)
                    .foregroundStyle(content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(content)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 72)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                   tint: isSelected ? theme.primaryContainer.opacity(GlassTint.prominent)
                                    : theme.surfaceContainer.opacity(SettingsTint.row),
                   interactive: true)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Android `SliderSettingsItem`: label and value (`bodyMedium` bold, `primary`) over a slider. `steps` are Android's
/// intermediate stops (step = range / (steps + 1)). `onCommit` mirrors `onValueChangeFinished`.
struct SliderSettingRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var steps = 0
    var onCommit: (() -> Void)?
    let valueText: (Double) -> String

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(valueText(value))
                    .pixlFont(.bodyMedium, weight: .bold)
                    .foregroundStyle(theme.primary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            slider
                .tint(theme.primary)
        }
        .padding(16)
        .settingsRowGlass()
        .accessibilityIdentifier("settings.slider.\(label)")
    }

    @ViewBuilder
    private var slider: some View {
        if steps > 0 {
            Slider(value: $value, in: range, step: (range.upperBound - range.lowerBound) / Double(steps + 1)) { editing in
                if !editing { onCommit?() }
            }
        } else {
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit?() }
            }
        }
    }
}

/// Android `ActionSettingsItem`: icon, title / subtitle, a full-width tonal button and an optional outlined one.
struct ActionSettingRow: View {
    let title: String
    let subtitle: String
    var systemImage: String?
    var iconColor: Color?
    let primaryLabel: String
    let onPrimary: () -> Void
    var secondaryLabel: String?
    var onSecondary: (() -> Void)?
    var enabled = true

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if let systemImage {
                    SettingsIcon(systemImage: systemImage, color: iconColor)
                        .padding(.trailing, 16)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .pixlFont(.titleMedium)
                        .foregroundStyle(theme.onSurface)
                    Text(subtitle)
                        .pixlFont(.bodyMedium)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
            Spacer().frame(height: 12)
            SettingsFillButton(title: primaryLabel, style: .tonal, enabled: enabled, action: onPrimary)
            if let secondaryLabel, let onSecondary {
                Spacer().frame(height: 8)
                SettingsFillButton(title: secondaryLabel, style: .outlined, enabled: enabled, action: onSecondary)
            }
        }
        .padding(16)
        .settingsRowGlass()
    }
}

/// Android's filled / tonal / outlined buttons on a row, as plain fills (they sit on glass): full-width capsules
/// 40 pt tall, `labelLarge`.
struct SettingsFillButton: View {
    enum Style { case filled, tonal, outlined, destructive, tertiary }

    let title: String
    var systemImage: String?
    var style: Style = .tonal
    var enabled = true
    var fullWidth = true
    let action: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .pixlFont(.labelLarge)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 24)
            .frame(minHeight: 40)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background, in: Capsule())
            .overlay {
                if style == .outlined || style == .destructive {
                    Capsule().strokeBorder(border, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.38)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
        .disabled(!enabled)
    }

    private var foreground: Color {
        switch style {
        case .filled: theme.onPrimary
        case .tonal: theme.onSecondaryContainer
        case .tertiary: theme.onTertiaryContainer
        case .outlined: theme.primary
        case .destructive: theme.error
        }
    }

    private var background: Color {
        switch style {
        case .filled: theme.primary
        case .tonal: theme.secondaryContainer
        case .tertiary: theme.tertiaryContainer
        case .outlined, .destructive: .clear
        }
    }

    private var border: Color {
        style == .destructive ? theme.error.opacity(0.5) : theme.outline
    }
}

/// A single-line or multi-line text field on a row (Android `OutlinedTextField`): 12 pt corners, outline stroke.
struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var axis: Axis = .horizontal
    var label: String?

    @Environment(\.appTheme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .pixlFont(.bodySmall)
                    .foregroundStyle(focused ? theme.primary : theme.onSurfaceVariant)
            }
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text, axis: axis)
                }
            }
            .pixlFont(.bodyLarge)
            .foregroundStyle(theme.onSurface)
            .focused($focused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(theme.surfaceContainerLowest.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(focused ? theme.primary : theme.outline, lineWidth: focused ? 2 : 1))
        }
    }
}

/// A free-form panel row (the many `Surface(surfaceContainer, RoundedCornerShape(10.dp))` blocks with custom
/// content in Android's settings).
struct SettingsPanel<Content: View>: View {
    var padding: CGFloat = 16
    var spacing: CGFloat = 12
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .settingsRowGlass(tint: tint)
    }
}

/// A tinted title chip (Android `Surface(secondaryContainer, RoundedCornerShape(16.dp))` value badges, 24 pt tall).
struct SettingsValueChip: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(text)
            .pixlFont(.labelSmall)
            .foregroundStyle(theme.onSecondaryContainer)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(theme.secondaryContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .monospacedDigit()
    }
}
