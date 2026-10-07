import PixlLibrary
import SwiftUI

/// Settings › Appearance › Accent Color (iOS-only, owner request 2026-10-07; Android has no accent setting): one
/// settings row with PixlAudio's violet, ten presets and Custom (the system colour picker) as two rows of six
/// swatches. Laid out like `ThemeSelectorRow` (icon, title, description), with the grid where the value capsule was.
///
/// The swatches are plain fills on the row's glass (no glass on glass) and show the named colour itself; the app
/// shows the accent scheme's tone of it (deeper in light mode, pastel in dark mode, so text on it stays legible).
/// The selected swatch gets a ring and a check. A choice re-themes the whole app at once (`ThemeStore`).
struct AccentColorRow: View {
    /// The stored value (`AppearanceSettings.accentColor`): `"#RRGGBB"`, `""` = PixlAudio's violet.
    let selectedHex: String
    let onSelect: (String) -> Void

    @Environment(\.appTheme) private var theme
    /// The custom picker's colour, seeded from the current accent. The picker reports every drag step; a step is
    /// committed only after a short pause (each commit re-themes the app).
    @State private var picked: Color
    /// The value `picked` was last seeded with or committed as. It is never committed again, so opening the page
    /// never saves the violet's seed over the default `""`.
    @State private var seededHex: String

    init(selectedHex: String, onSelect: @escaping (String) -> Void) {
        self.selectedHex = selectedHex
        self.onSelect = onSelect
        let seed = AccentPalette.seed(hex: selectedHex) ?? ArtworkTheme.brandSeed
        _picked = State(initialValue: Color(argb: seed))
        _seededHex = State(initialValue: AccentPalette.hex(argb: seed))
    }

    /// Swatch, selection ring and touch target sizes. Six 44 pt cells fit the narrowest text column (375 pt phone:
    /// 375 − 2·16 page − 2·16 row − 24 icon − 16 = 271 pt); wider phones spread them out.
    private enum Metrics {
        static let cell: CGFloat = 44
        static let swatch: CGFloat = 32
        static let ring: CGFloat = 42
        static let perRow = 6
    }

    var body: some View {
        let selected = AccentPalette.preset(for: selectedHex)
        HStack(alignment: .top, spacing: 0) {
            SettingsIcon(systemImage: "paintpalette")
                .padding(.trailing, 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.settingsAccentColorTitle)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.onSurface)
                Spacer().frame(height: 6)
                Text(L10n.settingsAccentColorSubtitle)
                    .pixlFont(.bodyMedium)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer().frame(height: 12)
                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        ForEach(AccentPalette.presets.prefix(Metrics.perRow)) { preset in
                            presetCell(preset, isSelected: preset == selected)
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(AccentPalette.presets.dropFirst(Metrics.perRow)) { preset in
                            presetCell(preset, isSelected: preset == selected)
                        }
                        customCell(isSelected: selected == nil)
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .settingsRowGlass()
        .pixlHaptic(.selection, trigger: selectedHex)
        // The custom picker, debounced. Cancelling the sleep (a newer step, or the page closing) commits nothing.
        .task(id: picked) {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            let hex = AccentPalette.hex(picked)
            guard hex != seededHex else { return }
            seededHex = hex
            if hex != selectedHex { onSelect(hex) }
        }
        // A preset, a restored backup or a reset: start the picker from the new accent.
        .onChange(of: selectedHex) { _, hex in reseed(hex) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.accentColor")
    }

    private func presetCell(_ preset: AccentPalette.Preset, isSelected: Bool) -> some View {
        Button {
            reseed(preset.hex)
            if preset.hex != selectedHex { onSelect(preset.hex) }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(argb: preset.seed))
                    .frame(width: Metrics.swatch, height: Metrics.swatch)
                if isSelected {
                    Circle()
                        .strokeBorder(theme.onSurface, lineWidth: 2.5)
                        .frame(width: Metrics.ring, height: Metrics.ring)
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Self.checkColor(on: preset.seed))
                }
            }
            .frame(width: Metrics.cell, height: Metrics.cell)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.accent.\(preset.id)")
    }

    /// The system colour picker's well (it opens the system picker sheet), ringed while a custom colour is the accent.
    private func customCell(isSelected: Bool) -> some View {
        ZStack {
            ColorPicker(L10n.settingsAccentColorCustom, selection: $picked, supportsOpacity: false)
                .labelsHidden()
            if isSelected {
                Circle()
                    .strokeBorder(theme.onSurface, lineWidth: 2.5)
                    .frame(width: Metrics.ring, height: Metrics.ring)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: Metrics.cell, height: Metrics.cell)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(L10n.settingsAccentColorCustom)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("settings.accent.custom")
    }

    /// Points the picker at `hex`'s colour without committing it.
    private func reseed(_ hex: String) {
        let seed = AccentPalette.seed(hex: hex) ?? ArtworkTheme.brandSeed
        let normalised = AccentPalette.hex(argb: seed)
        guard normalised != seededHex else { return }
        seededHex = normalised
        picked = Color(argb: seed)
    }

    /// White on the swatch unless it falls below 3:1 (graphical-object contrast), then black: white on blue, red,
    /// pink, purple and graphite; black on orange, yellow, green and mint.
    private static func checkColor(on argb: UInt32) -> Color {
        relativeLuminance(argb: argb) <= 0.30 ? .white : .black
    }
}
