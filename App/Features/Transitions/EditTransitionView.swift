import PixlModel
import SwiftUI

/// Transition rules (Android `EditTransitionScreen` + `TransitionViewModel`): the large collapsing title ("Global
/// transitions" / "Playlist rules") with back and the save circle, the intro text, the summary card (active status,
/// and for a playlist the "Custom Override" switch), a divider, the style toggle (None / Crossfade, a sliding
/// selection), and — when crossfading — the duration card (overlap visualiser + 0…12 s slider) and the fade-out /
/// fade-in curve columns. Sections 24 pt apart, 16 pt side margins.
struct EditTransitionView: View {
    /// nil = the global default rule.
    let playlistId: String?

    @Environment(AppEnvironment.self) private var environment
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme
    @State private var model = TransitionEditorModel()
    @State private var toast: String?

    var body: some View {
        let isPlaylist = playlistId != nil
        let displayed = model.displayedSettings
        SettingsScaffold(title: isPlaylist ? L10n.transitionTitlePlaylistRules : L10n.transitionTitleGlobal,
                         screenID: "editTransition", spacing: 24) {
            GlassCircleButton(systemImage: "square.and.arrow.down", accessibilityLabel: LocalizedStringKey(L10n.commonSave),
                              tint: theme.tertiaryContainer.opacity(GlassTint.container),
                              foreground: theme.onTertiaryContainer) {
                Task {
                    await model.save(playlistId: playlistId, playback: settings.playback,
                                     persistence: environment.persistence)
                    // Playlist rules live in the store; the engine re-reads them (global settings are observed).
                    if isPlaylist { await environment.playbackServices?.reloadTransitionRules() }
                    toast = isPlaylist && model.useGlobalDefaults ? L10n.transitionSnackbarUsingGlobal
                                                                   : L10n.transitionSnackbarSaved
                }
            }
            .disabled(model.isLoading)
            .padding(.trailing, 10)
            .accessibilityIdentifier("transition.save")
        } content: {
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                Text(isPlaylist ? L10n.transitionIntroPlaylist : L10n.transitionIntroGlobal)
                    .pixlFont(.bodyLarge)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .padding(.horizontal, 4)
                TransitionSummaryCard(isPlaylist: isPlaylist, hasCustomRule: model.rule != nil && !model.useGlobalDefaults,
                                      followingGlobal: model.useGlobalDefaults,
                                      onOverride: { enabled in
                                          withAnimation(PixlMotion.state) {
                                              if enabled { model.enableOverride(isPlaylist: isPlaylist) }
                                              else { model.useGlobal(isPlaylist: isPlaylist) }
                                          }
                                      })
                Rectangle().fill(theme.outlineVariant.opacity(0.5)).frame(height: 1)
                TransitionModeSection(selected: displayed.mode) { mode in
                    withAnimation(PixlMotion.state) { model.update(playlistId: playlistId) { $0.mode = mode } }
                }
                if displayed.mode != .none {
                    VStack(spacing: 24) {
                        TransitionDurationCard(durationMs: displayed.durationMs) { ms in
                            model.update(playlistId: playlistId) { $0.durationMs = ms }
                        }
                        TransitionCurvesSection(settings: displayed,
                                                onCurveIn: { c in model.update(playlistId: playlistId) { $0.curveIn = c } },
                                                onCurveOut: { c in model.update(playlistId: playlistId) { $0.curveOut = c } })
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer().frame(height: 60)
            }
        }
        .settingsToast($toast)
        .task {
            await model.load(playlistId: playlistId, playback: settings.playback, persistence: environment.persistence)
        }
    }
}

/// Android `TransitionViewModel`.
@Observable
final class TransitionEditorModel {
    private(set) var rule: TransitionSettings?
    private(set) var globalSettings = TransitionSettings()
    private(set) var isLoading = true
    private(set) var useGlobalDefaults = false

    var displayedSettings: TransitionSettings { useGlobalDefaults ? globalSettings : (rule ?? globalSettings) }

    /// Android `globalTransitionSettingsFlow`: the stored JSON, duration from `crossfade_duration` (1…12 s).
    static func globalSettings(from playback: PlaybackSettings) -> TransitionSettings {
        var settings = TransitionSettings()
        if let json = playback.globalTransitionSettingsJSON, let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(TransitionSettings.self, from: data) {
            settings = decoded
        }
        settings.durationMs = min(max(playback.crossfadeDurationMs, 1000), 12000)
        return settings
    }

    func load(playlistId: String?, playback: PlaybackSettings, persistence: PersistenceActor?) async {
        isLoading = true
        var playlistRule: TransitionSettings?
        if let playlistId, let persistence {
            playlistRule = try? await persistence.settingsPlaylistTransition(playlistId: playlistId)
        }
        globalSettings = Self.globalSettings(from: playback)
        rule = playlistRule
        useGlobalDefaults = playlistId != nil && playlistRule == nil
        isLoading = false
    }

    func update(playlistId: String?, _ change: (inout TransitionSettings) -> Void) {
        var next = displayedSettings
        change(&next)
        rule = next
        useGlobalDefaults = false
    }

    func useGlobal(isPlaylist: Bool) {
        guard isPlaylist else { return }
        rule = nil
        useGlobalDefaults = true
    }

    func enableOverride(isPlaylist: Bool) {
        guard isPlaylist else { return }
        rule = displayedSettings
        useGlobalDefaults = false
    }

    /// Android `saveSettings`: a playlist following global (or set to None) drops its rule; otherwise the rule is
    /// saved. The global screen saves the global settings — and, unlike Android (whose saved duration is
    /// overridden by `crossfade_duration` on the next read), also writes the duration there so it sticks.
    func save(playlistId: String?, playback: PlaybackSettings, persistence: PersistenceActor?) async {
        if let playlistId {
            if useGlobalDefaults || rule?.mode == TransitionMode.none {
                try? await persistence?.settingsDeletePlaylistTransition(playlistId: playlistId)
            } else if let rule {
                try? await persistence?.settingsSavePlaylistTransition(playlistId: playlistId, settings: rule)
            }
        } else {
            let current = displayedSettings
            playback.globalTransitionSettingsJSON = (try? JSONEncoder().encode(current))
                .flatMap { String(data: $0, encoding: .utf8) }
            playback.crossfadeDurationMs = min(max(current.durationMs, 1000), 12000)
        }
        await load(playlistId: playlistId, playback: playback, persistence: persistence)
    }
}

/// Android `TransitionSummaryCard`: a 28 pt `surfaceContainer` card (glass) with the status, and for a playlist
/// the override switch on a 16 pt `surface` panel.
private struct TransitionSummaryCard: View {
    let isPlaylist: Bool
    let hasCustomRule: Bool
    let followingGlobal: Bool
    let onOverride: (Bool) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: "rectangle.stack.badge.play")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.onSecondaryContainer)
                    .frame(width: 48, height: 48)
                    .background(theme.secondaryContainer, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.transitionActiveStatus).pixlFont(.labelLarge).foregroundStyle(theme.primary)
                    Text(status).pixlFont(.titleLarge).foregroundStyle(theme.onSurface)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if isPlaylist {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L10n.transitionCustomOverrideTitle).pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                        Text(L10n.transitionCustomOverrideBody).pixlFont(.bodyMedium)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(L10n.transitionCustomOverrideTitle, isOn: Binding(get: { !followingGlobal }, set: onOverride))
                        .labelsHidden()
                        .tint(theme.primary)
                }
                .padding(16)
                .background(theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                   tint: theme.surfaceContainer.opacity(SettingsTint.row))
        .accessibilityIdentifier("transition.summary")
    }

    private var status: String {
        if !isPlaylist { return L10n.transitionStatusGlobalDefault }
        if followingGlobal { return L10n.transitionStatusFollowingGlobal }
        return hasCustomRule ? L10n.transitionStatusCustomOverride : L10n.transitionStatusPlaylistDefault
    }
}

/// Android `TransitionModeSection` + `ExpressiveMorphingToggle`: a 56 pt capsule track with a sliding selection.
private struct TransitionModeSection: View {
    let selected: TransitionMode
    let onSelect: (TransitionMode) -> Void
    @Environment(\.appTheme) private var theme
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.system(size: 20, weight: .medium)).foregroundStyle(theme.primary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.transitionStyleTitle).pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                    Text(L10n.transitionStyleSubtitle).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
                }
            }
            GlassEffectContainer(spacing: 0) {
                HStack(spacing: 0) {
                    option(.none, L10n.transitionModeNone)
                    option(.overlap, L10n.transitionModeCrossfade)
                }
                .padding(4)
                .frame(height: 56)
                .pixlGlass(in: Capsule(), tint: theme.surfaceContainerLow.opacity(GlassTint.surface))
            }
        }
    }

    private func option(_ mode: TransitionMode, _ title: String) -> some View {
        let isSelected = (mode == .overlap) == (selected != .none)
        return Button { onSelect(mode) } label: {
            Text(title)
                .pixlFont(.labelLarge, weight: isSelected ? .bold : .medium)
                .foregroundStyle(isSelected ? theme.onSecondaryContainer : theme.onSurfaceVariant)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isSelected {
                        Capsule().fill(theme.secondaryContainer)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("transition.mode.\(mode.rawValue)")
    }
}

/// Android `TransitionDurationSection`: a 24 pt `surfaceContainerLow` panel (glass), the reset circle, the overlap
/// visualiser and a 0…12 s slider in 1 s steps.
private struct TransitionDurationCard: View {
    let durationMs: Int
    let onChange: (Int) -> Void
    @State private var value: Double = 2000
    @Environment(\.appTheme) private var theme

    var body: some View {
        let seconds = durationMs / 1000
        VStack(spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.transitionDurationTitle).pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                    Text(L10n.transitionDurationSubtitleFormat(seconds)).pixlFont(.bodyMedium)
                        .foregroundStyle(theme.primary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button { onChange(TransitionSettings().durationMs) } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .frame(width: 40, height: 40)
                        .background(theme.surfaceVariant, in: Circle())
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel(L10n.transitionResetCd)
            }
            CrossfadeVisualizer(durationMs: durationMs)
            Slider(value: $value, in: 0...12000, step: 1000)
                .tint(theme.primary)
                .onChange(of: value) { _, new in if Int(new) != durationMs { onChange(Int(new)) } }
                .sensoryFeedback(.selection, trigger: Int(value))
        }
        .padding(24)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(SettingsTint.row))
        .animation(PixlMotion.state, value: durationMs)
        .onAppear { value = Double(durationMs) }
        .onChange(of: durationMs) { _, new in if Int(value) != new { value = Double(new) } }
    }
}

/// Android `CrossfadeVisualizer`: two 8 pt bars (current song `tertiary`, next `secondary`) and a 32 pt capsule
/// whose width grows with the overlap, the explanation below.
private struct CrossfadeVisualizer: View {
    let durationMs: Int
    @Environment(\.appTheme) private var theme

    var body: some View {
        let factor = Double(min(max(durationMs, 0), 12000)) / 12000
        VStack(spacing: 8) {
            HStack {
                Text(L10n.transitionVisualizerCurrent).pixlFont(.labelSmall).foregroundStyle(theme.tertiary)
                Spacer()
                Text(L10n.transitionVisualizerNext).pixlFont(.labelSmall).foregroundStyle(theme.secondary)
            }
            GeometryReader { proxy in
                ZStack {
                    HStack(spacing: 0) {
                        UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4)
                            .fill(theme.tertiary.opacity(0.5))
                        UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                            .fill(theme.secondary.opacity(0.5))
                    }
                    .frame(height: 8)
                    HStack(spacing: 0) {
                        UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16)
                            .fill(theme.tertiary.opacity(0.3))
                        UnevenRoundedRectangle(bottomTrailingRadius: 16, topTrailingRadius: 16)
                            .fill(theme.secondary.opacity(0.3))
                    }
                    .background(theme.surfaceContainerLow, in: Capsule())
                    .overlay {
                        Image(systemName: "rectangle.stack.badge.play")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.onSurface)
                    }
                    .frame(width: proxy.size.width * (0.1 + factor * 0.4), height: 32)
                }
                .frame(width: proxy.size.width, height: 32)
            }
            .frame(height: 32)
            .animation(PixlMotion.state, value: factor)
            Text(L10n.transitionOverlapExplanationFormat(durationMs / 1000))
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Android `TransitionCurvesSection`: fade out (tertiary) and fade in (secondary) columns of curves.
private struct TransitionCurvesSection: View {
    let settings: TransitionSettings
    let onCurveIn: (TransitionCurve) -> Void
    let onCurveOut: (TransitionCurve) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.primary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L10n.transitionCurvesTitle).pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                    Text(L10n.transitionCurvesSubtitle).pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                column(L10n.transitionFadeOut, selected: settings.curveOut, fill: theme.tertiaryContainer,
                       content: theme.onTertiaryContainer, onSelect: onCurveOut)
                column(L10n.transitionFadeIn, selected: settings.curveIn, fill: theme.secondaryContainer,
                       content: theme.onSecondaryContainer, onSelect: onCurveIn)
            }
        }
    }

    /// Android `CurveSelectionColumn`: a 24 pt card (glass) with 12 pt-corner options; selected = filled + check.
    private func column(_ title: String, selected: TransitionCurve, fill: Color, content: Color,
                        onSelect: @escaping (TransitionCurve) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .pixlFont(.labelLarge)
                .foregroundStyle(theme.onSurface)
                .padding(.leading, 8)
                .padding(.top, 4)
                .padding(.bottom, 8)
            ForEach(TransitionCurve.allCases, id: \.self) { curve in
                let isSelected = curve == selected
                Button { onSelect(curve) } label: {
                    HStack {
                        Text(TransitionCurvesLabel.label(curve))
                            .pixlFont(.bodyMedium, weight: isSelected ? .bold : .medium)
                            .foregroundStyle(isSelected ? content : theme.onSurfaceVariant)
                        Spacer(minLength: 4)
                        if isSelected {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(content)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(isSelected ? fill : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pixlGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                   tint: theme.surfaceContainerLow.opacity(SettingsTint.row))
        .animation(PixlMotion.state, value: selected)
    }
}

nonisolated enum TransitionCurvesLabel {
    /// Android `curve.name.lowercase().replaceFirstChar { it.titlecase() }` ("Linear", "Exp", "Log", "S_curve").
    static func label(_ curve: TransitionCurve) -> String {
        let lower = curve.rawValue.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}
