import SwiftUI

/// Settings › Lyrics › "Tap timing" (Android `LyricsTapTimingDialog`): the reaction time taken off every tap in the
/// sync editor (10 ms steps, 0…400 ms, Android `MAX_LYRICS_TAP_OFFSET_MS`) and the haptics switch. Reset restores
/// 100 ms (`DEFAULT_LYRICS_TAP_OFFSET_SPEAKER_MS`). Android's alert dialog becomes a small system sheet.
struct LyricsTapTimingSheet: View {
    static let stepMs = 10
    static let maxMs = 400
    static let defaultMs = 100

    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var lyrics = settings.lyrics
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.settingsLyricsTapTiming)
                .pixlFont(.headlineSmall)
                .foregroundStyle(theme.onSurface)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.settingsLyricsTapTimingBody)
                .pixlFont(.bodyMedium)
                .foregroundStyle(theme.onSurfaceVariant)
            HStack {
                GlassCircleButton(systemImage: "minus", accessibilityLabel: LocalizedStringKey(L10n.lyricsSyncDecrease),
                                  tint: theme.secondaryContainer.opacity(GlassTint.container)) {
                    lyrics.tapOffsetSpeakerMs = max(0, lyrics.tapOffsetSpeakerMs - Self.stepMs)
                }
                .disabled(lyrics.tapOffsetSpeakerMs <= 0)
                Text(L10n.settingsLyricsTapTimingValue(lyrics.tapOffsetSpeakerMs))
                    .pixlFont(.headlineSmall, weight: .semibold)
                    .foregroundStyle(theme.onSurface)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText())
                GlassCircleButton(systemImage: "plus", accessibilityLabel: LocalizedStringKey(L10n.lyricsSyncIncrease),
                                  tint: theme.secondaryContainer.opacity(GlassTint.container)) {
                    lyrics.tapOffsetSpeakerMs = min(Self.maxMs, lyrics.tapOffsetSpeakerMs + Self.stepMs)
                }
                .disabled(lyrics.tapOffsetSpeakerMs >= Self.maxMs)
            }
            .animation(PixlMotion.state, value: lyrics.tapOffsetSpeakerMs)
            HStack {
                Text(L10n.settingsLyricsTapHaptics)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurface)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(L10n.settingsLyricsTapHaptics, isOn: $lyrics.syncHaptics)
                    .labelsHidden()
                    .tint(theme.primary)
            }
            .padding(.top, 4)
            HStack(spacing: 8) {
                Spacer()
                GlassPillButton(title: LocalizedStringKey(L10n.commonReset)) {
                    lyrics.tapOffsetSpeakerMs = Self.defaultMs
                }
                GlassPillButton(title: LocalizedStringKey(L10n.commonDone), tint: theme.primary.opacity(GlassTint.prominent),
                                foreground: theme.onPrimary) { dismiss() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("screen.lyricsTapTiming")
    }
}
