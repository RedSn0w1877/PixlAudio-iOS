import PixlLibrary
import SwiftUI

/// Colours and glass for the editor (Android `SyncEditorPalette`, Liquid Glass mode). Everything sits on the animated
/// artwork (dark, graded), so text is white. Android's glass mode drew translucent white fills with a thin rim; here
/// they are real clear Liquid Glass (clear: the editor sits over media) with the same tints — chips white 12 %, the pad
/// white 16 %, the preview panel black 32 % — and a 35 % black tint over bright art. The accent (the word being sung,
/// selections, the primary action) is the album's `primary` when it reads on dark art, else `inversePrimary`.
struct SyncEditorPalette {
    let accent: Color
    let onAccent: Color
    let brightArt: Bool

    init(theme: ThemeColors, brightArt: Bool) {
        let primary = theme.argb(\.primary)
        let accentARGB = relativeLuminance(argb: primary) > 0.30 ? primary : theme.argb(\.inversePrimary)
        accent = Color(argb: accentARGB)
        onAccent = relativeLuminance(argb: accentARGB) > 0.45 ? Color(argb: 0xFF111114) : .white
        self.brightArt = brightArt
    }

    /// Chips, the ✕ circle, secondary buttons (Android `chipContainer`, white 12 %).
    func chipGlass(interactive: Bool = true) -> Glass {
        Glass.clear.tint(brightArt ? Color.black.opacity(0.35) : Color.white.opacity(0.12)).interactive(interactive)
    }

    /// The tap pad (Android `padContainer`, white 16 %).
    var padGlass: Glass {
        Glass.clear.tint(brightArt ? Color.black.opacity(0.35) : Color.white.opacity(0.16))
    }

    /// The preview panel (Android `panelContainer`, black 32 %).
    var panelGlass: Glass {
        Glass.clear.tint(Color.black.opacity(brightArt ? 0.45 : 0.32))
    }

    /// The primary action and selections (Android `prominent` / `accent` fills).
    func accentGlass(interactive: Bool = true, enabled: Bool = true) -> Glass {
        Glass.clear.tint(accent.opacity(enabled ? GlassTint.prominent : GlassTint.prominent * 0.45)).interactive(interactive)
    }

    /// Buttons inside the preview panel are fills, not glass (no glass on glass; Android `panelButton`, white 12 %).
    let panelButtonFill = Color.white.opacity(0.12)
}

/// The editor's shapes (Android glass mode: continuous corners).
nonisolated enum SyncShapes {
    static let pad = RoundedRectangle(cornerRadius: 36, style: .continuous)
    static let panel = RoundedRectangle(cornerRadius: 32, style: .continuous)
}

/// The editor's one button shape: a 56 pt capsule (Android `EditorButton`). `prominent` is the primary action;
/// `onPanel` buttons sit inside the preview panel and are fills.
struct EditorButton<ButtonLabel: View>: View {
    let palette: SyncEditorPalette
    var prominent = false
    var onPanel = false
    var enabled = true
    var height: CGFloat = 56
    var horizontalPadding: CGFloat = 20
    var fillWidth = false
    let action: () -> Void
    @ViewBuilder let label: (Color) -> ButtonLabel

    private var contentColor: Color {
        let base = prominent ? palette.onAccent : .white
        return enabled ? base : base.opacity(0.5)
    }

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: 0) { label(contentColor) }
                .padding(.horizontal, horizontalPadding)
                .frame(maxWidth: fillWidth ? .infinity : nil, minHeight: height)
                .contentShape(.capsule)
        }
        .disabled(!enabled)
        if onPanel && !prominent {
            button
                .buttonStyle(PressScaleButtonStyle(pressedScale: 0.96))
                .background(enabled ? palette.panelButtonFill : palette.panelButtonFill.opacity(0.45), in: Capsule())
        } else {
            button
                .buttonStyle(.plain)
                .glassEffect(prominent ? palette.accentGlass(enabled: enabled) : palette.chipGlass(), in: Capsule())
        }
    }
}

/// A button label in the editor's text style (16 pt, semibold for the primary action, medium otherwise).
struct EditorButtonText: View {
    let text: String
    let color: Color
    var bold = true

    var body: some View {
        Text(text)
            .pixlFont(.custom(size: 16, weight: bold ? .semibold : .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            // SF Pro at the boosted weight runs wider than Roboto: shrink a little before truncating ("Find lyrics
            // online" in a half-width button).
            .minimumScaleFactor(0.8)
    }
}

/// A compact button: icon over a short label, so three side by side read in full (Android `EditorStackedButton`).
struct EditorStackedButton: View {
    let systemImage: String
    let label: String
    let palette: SyncEditorPalette
    var enabled = true
    let action: () -> Void

    var body: some View {
        EditorButton(palette: palette, enabled: enabled, height: 60, horizontalPadding: 6, fillWidth: true,
                     action: action) { color in
            VStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 22, height: 22)
                Text(label)
                    .pixlFont(.custom(size: 13, weight: .medium, lineHeight: 15))
                    .lineLimit(1)
            }
            .foregroundStyle(color)
        }
        .accessibilityLabel(label)
    }
}

/// ✕, the song title (14 pt, 70 %) and the speed pill (Android `SyncTopBar`, 56 pt tall).
struct SyncTopBar: View {
    let title: String
    let palette: SyncEditorPalette
    let onClose: () -> Void
    var speed: Float?
    var onSpeedChange: (Float) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(palette.chipGlass(), in: Circle())
            .accessibilityLabel(SyncStrings.close)
            .accessibilityIdentifier("sync.close")
            Text(title)
                .pixlFont(.custom(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let speed { SpeedPill(speed: speed, palette: palette, onSpeedChange: onSpeedChange) }
        }
        .frame(height: 56)
    }
}

/// Speed choices: Normal, Slower (0.75×), Slowest (0.5×).
nonisolated enum SyncSpeedOption: CaseIterable {
    case normal, slower, slowest

    var value: Float {
        switch self {
        case .normal: 1
        case .slower: 0.75
        case .slowest: 0.5
        }
    }

    var label: String {
        switch self {
        case .normal: SyncStrings.speedNormal
        case .slower: SyncStrings.speedSlower
        case .slowest: SyncStrings.speedSlowest
        }
    }

    /// The pill's label: "Normal", "0.75×", "0.5×".
    static func pillLabel(_ speed: Float) -> String {
        if speed == 1 { return SyncStrings.speedNormal }
        return SyncStrings.speedX(speed == 0.5 ? "0.5" : "0.75")
    }
}

/// The speed pill with its menu (Android `SpeedPill` + `DropdownMenu`): plain glass at Normal, accent glass when
/// slowed down.
private struct SpeedPill: View {
    let speed: Float
    let palette: SyncEditorPalette
    let onSpeedChange: (Float) -> Void

    var body: some View {
        let slowed = speed != 1
        let color = slowed ? palette.onAccent : Color.white
        Menu {
            ForEach(SyncSpeedOption.allCases, id: \.self) { option in
                Button {
                    onSpeedChange(option.value)
                } label: {
                    if option.value == speed {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(SyncSpeedOption.pillLabel(speed))
                    .pixlFont(.custom(size: 14, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 20, height: 20)
            }
            .foregroundStyle(color)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(slowed ? palette.accentGlass() : palette.chipGlass(), in: Capsule())
        .accessibilityIdentifier("sync.speed")
    }
}

/// Three-way speed picker for the intro screen (Android `SpeedSegments`): 48 pt capsules 8 pt apart; the selected one
/// is accent glass that glides between them.
struct SpeedSegments: View {
    let speed: Float
    let palette: SyncEditorPalette
    let onSpeedChange: (Float) -> Void
    @Namespace private var glassNamespace

    var body: some View {
        GlassEffectContainer(spacing: 3) {
            HStack(spacing: 8) {
                ForEach(SyncSpeedOption.allCases, id: \.self) { option in
                    let selected = option.value == speed
                    Button {
                        withAnimation(PixlMotion.selection) { onSpeedChange(option.value) }
                    } label: {
                        Text(option.label)
                            .pixlFont(.custom(size: 15, weight: selected ? .bold : .medium))
                            .foregroundStyle(selected ? palette.onAccent : .white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(selected ? palette.accentGlass() : palette.chipGlass(), in: Capsule())
                    .glassEffectID(selected ? SyncGlassID.selectedSpeed : SyncGlassID.speed(option.value), in: glassNamespace)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

nonisolated enum SyncGlassID: Hashable, Sendable {
    case selectedSpeed
    case speed(Float)
}

/// The transient message pill ("Removed timing for 14 words · Undo"); dismisses itself after 4 s (Android
/// `SyncNoticePill`: a dark 20 pt rounded surface — a glass panel here).
struct SyncNoticePill: View {
    let notice: SyncNotice
    let palette: SyncEditorPalette
    let onUndo: () -> Void
    let onTimeout: (Int) -> Void

    static let durationMs: Int64 = 4_000

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .pixlFont(.custom(size: 14))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if notice.canUndo {
                Button(action: onUndo) {
                    Text(SyncStrings.commonUndo)
                        .pixlFont(.custom(size: 14, weight: .bold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(.capsule)
                }
                .buttonStyle(PressScaleButtonStyle())
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, notice.canUndo ? 6 : 18)
        .frame(minHeight: 48)
        .glassEffect(Glass.clear.tint(Color(argb: 0xE6202024).opacity(0.85)),
                     in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .task(id: notice.id) {
            try? await Task.sleep(for: .milliseconds(Self.durationMs))
            guard !Task.isCancelled else { return }
            onTimeout(notice.id)
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch notice.kind {
        case .removedWords: SyncStrings.removedWords(notice.count)
        case .waitTip: SyncStrings.waitTip
        case .pastNextLine: SyncStrings.pastNextLine
        }
    }
}

/// A centred glass card over a dim backdrop (Android `AdaptiveAlertDialog` with a list inside — the lyrics fetch
/// dialog's look): title, content, and a trailing text button.
struct SyncDialogCard<Content: View>: View {
    let title: String
    let dismissTitle: String
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .pixlFont(.headlineSmall)
                    .foregroundStyle(.white)
                content()
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Text(dismissTitle)
                            .pixlFont(.labelLarge)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(PressScaleButtonStyle())
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .glassEffect(Glass.regular.tint(Color.black.opacity(0.3)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 24)
        }
        // A modal dialog for VoiceOver; escape dismisses it.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onDismiss)
    }
}
