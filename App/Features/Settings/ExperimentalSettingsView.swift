import SwiftUI

/// Experimental (Android `ExperimentalSettingsScreen`): "Player UI tweaks" — lyrics blur (+ strength), Magic
/// Instrumentalize, the BS-RoFormer render backend, Remaster Song, TAIS DJ, Cloud processing (iOS-first), and the
/// full-player loading steps
/// (delay, placeholders, trigger mode, thresholds) — then "Visual Quality" with the album-art resolution list. Rows
/// are 10 pt glass panels 4 pt apart.
///
/// Remaster Song is stage 14's `TaisStudioProgressCard` (followed by the iOS-only on-device models panel); the
/// BS-RoFormer fields feed its cloud render. TAIS DJ opens the DJ chat (stage 13). Dropped: the visual-style switch (Liquid Glass / Material — iOS is glass only) and
/// the Plus licence debug tools (everything is unlocked).
struct ExperimentalSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(PlaybackStore.self) private var playback
    @Environment(Router.self) private var router
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @State private var toast: String?

    var body: some View {
        @Bindable var experimental = settings.experimental
        @Bindable var lyrics = settings.lyrics
        let anyDelay = experimental.delayAlbumCarousel || experimental.delaySongMetadata
            || experimental.delayProgressBar || experimental.delayControls
        let canUseTrigger = anyDelay && experimental.showPlaceholders
        SettingsScaffold(title: L10n.settingsExpScreenTitle, screenID: "experimental", horizontalPadding: 0) {
            ExperimentalSection(title: L10n.settingsExpPlayerUiTweaksSection) {
                SwitchSettingRow(title: L10n.settingsExpLyricsBlurTitle, subtitle: L10n.settingsExpLyricsBlurSubtitle,
                                 isOn: $lyrics.animatedBlurEnabled, systemImage: "circle.dotted")
                if lyrics.animatedBlurEnabled {
                    ExperimentalSliderPanel(systemImage: "line.3.horizontal", title: L10n.settingsExpLyricsBlurStrengthTitle,
                                            chip: L10n.settingsExpLyricsBlurStrengthValue(lyrics.animatedBlurStrength),
                                            subtitle: L10n.settingsExpLyricsBlurStrengthSubtitle,
                                            value: $lyrics.animatedBlurStrength, range: 0.1...2.0, steps: 10)
                }
                ExperimentalSliderPanel(systemImage: "waveform", title: "Magic Instrumentalize",
                                        chip: "\(Int((experimental.vocalAttenuation * 100).rounded()))%",
                                        subtitle: String(localized: "settings_exp_magic_instrumentalize_body",
                                                         defaultValue: "TAIS Engine 2's zero-latency vocal reducer — attenuates the center-panned mix instantly. This is separate from the real AI separation model (see \"Remaster Song\" below), which separates vocal and instrumental tracks. The active processor and benchmark are shown in Music Intelligence settings."),
                                        value: $experimental.vocalAttenuation, range: 0...1, steps: 19)
                RoformerBackendPanel(experimental: experimental)
                // Stage 14: the real Remaster Song card (Android `TaisStudioProgressCard(showRoformerTools = true)`);
                // a finished render plays at once, like Android's `switchToStudioInstrumental`.
                TaisStudioProgressCard(song: playback.current, showRoformerTools: true, tintStrength: SettingsTint.row,
                                       onInstrumentalReady: { env.tais.instrumental.playInstrumental() })
                OnDeviceModelsPanel(tintStrength: SettingsTint.row)
                Button {
                    router.present(AppSheet.taisChat)
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemImage: "music.note")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: "TAIS DJ").pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                            Text(String(localized: "settings_exp_tais_dj_body",
                                        defaultValue: "TAIS Engine 3 — tell it a mood or genre and it finds songs, offline from your library or online via Spotify."))
                                .pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                }
                .buttonStyle(.plain)
                .experimentalPanelGlass(interactive: true)
                .accessibilityIdentifier("experimental.taisDJ")
                // Cloud Studio (iOS-first): the owner's RunPod GPU for instrumentals and word-timed lyrics.
                Button {
                    router.push(.cloudProcessing)
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemImage: "icloud.and.arrow.up")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: "Cloud processing").pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                            Text(verbatim: CloudProcessingCopy.experimentalRow(settings: env.cloud.settings,
                                                                               summary: env.cloud.summaryLine))
                                .pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    .padding(16)
                }
                .buttonStyle(.plain)
                .experimentalPanelGlass(interactive: true)
                .accessibilityIdentifier("experimental.cloudProcessing")

                header(L10n.settingsExpStep1DelayHeader)
                SwitchSettingRow(title: L10n.settingsExpDelayEverythingTitle, subtitle: L10n.settingsExpDelayEverythingSubtitle,
                                 isOn: Binding(get: { experimental.delayAll }, set: { experimental.setDelayAll($0) }),
                                 systemImage: "timer")
                if !experimental.delayAll {
                    SwitchSettingRow(title: L10n.settingsExpAlbumCarouselTitle, subtitle: L10n.settingsExpAlbumCarouselSubtitle,
                                     isOn: $experimental.delayAlbumCarousel, systemImage: "square.stack")
                    SwitchSettingRow(title: L10n.settingsExpSongMetadataTitle, subtitle: L10n.settingsExpSongMetadataSubtitle,
                                     isOn: $experimental.delaySongMetadata, systemImage: "textformat")
                    SwitchSettingRow(title: L10n.settingsExpProgressBarTitle, subtitle: L10n.settingsExpProgressBarSubtitle,
                                     isOn: $experimental.delayProgressBar, systemImage: "slider.horizontal.below.rectangle")
                    SwitchSettingRow(title: L10n.settingsExpPlaybackControlsTitle,
                                     subtitle: L10n.settingsExpPlaybackControlsSubtitle,
                                     isOn: $experimental.delayControls, systemImage: "playpause")
                } else {
                    hint(L10n.settingsExpDelayAllActiveHint)
                }
                header(L10n.settingsExpStep2PlaceholdersHeader)
                SwitchSettingRow(title: L10n.settingsExpUsePlaceholdersTitle, subtitle: L10n.settingsExpUsePlaceholdersSubtitle,
                                 isOn: $experimental.showPlaceholders, systemImage: "rectangle")
                if experimental.showPlaceholders {
                    triggerPanel(experimental: experimental, enabled: canUseTrigger)
                    if canUseTrigger && !experimental.switchOnDragRelease {
                        ExperimentalSliderPanel(systemImage: "line.3.horizontal", title: L10n.settingsExpExpandThresholdTitle,
                                                chip: nil, subtitle: L10n.settingsExpExpandThresholdSubtitle,
                                                value: Binding(get: { Double(experimental.appearThresholdPercent) },
                                                               set: { experimental.appearThresholdPercent = Int($0.rounded()) }),
                                                range: 0...100, steps: 99, enabled: anyDelay,
                                                footer: L10n.settingsExpContentAppearsAt(experimental.appearThresholdPercent))
                        SwitchSettingRow(title: L10n.settingsExpApplyOnCloseTitle, subtitle: L10n.settingsExpApplyOnCloseSubtitle,
                                         isOn: $experimental.applyPlaceholdersOnClose, systemImage: "rectangle",
                                         enabled: anyDelay)
                        if experimental.applyPlaceholdersOnClose {
                            ExperimentalSliderPanel(systemImage: "line.3.horizontal", title: L10n.settingsExpCloseThresholdTitle,
                                                    chip: nil, subtitle: L10n.settingsExpCloseThresholdSubtitle,
                                                    value: Binding(get: { Double(experimental.closeThresholdPercent) },
                                                                   set: { experimental.closeThresholdPercent = Int($0.rounded()) }),
                                                    range: 0...100, steps: 99, enabled: anyDelay,
                                                    footer: L10n.settingsExpPlaceholdersAfterCollapse(experimental.closeThresholdPercent))
                        }
                    }
                    if canUseTrigger && experimental.switchOnDragRelease {
                        hint(L10n.settingsExpDragReleaseBypass)
                    }
                    SwitchSettingRow(title: L10n.settingsExpTransparentPlaceholdersTitle,
                                     subtitle: L10n.settingsExpTransparentPlaceholdersSubtitle,
                                     isOn: $experimental.transparentPlaceholders, systemImage: "eye")
                }
            }
            HStack(spacing: 8) {
                Text(L10n.settingsExpVisualQuality)
                    .pixlFont(.labelMedium)
                    .foregroundStyle(theme.primary)
                    .layoutPriority(1)
                Rectangle().fill(theme.outlineVariant).frame(height: 1)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
            ExperimentalSection(title: L10n.settingsExpAlbumArtResolution) {
                ForEach(["LOW", "MEDIUM", "HIGH", "ORIGINAL"], id: \.self) { quality in
                    qualityRow(quality, selected: settings.appearance.albumArtQuality == quality)
                }
            }
            Spacer().frame(height: 36)
        }
        .settingsToast($toast)
        .animation(PixlMotion.state, value: lyrics.animatedBlurEnabled)
        .animation(PixlMotion.state, value: experimental.delayAll)
        .animation(PixlMotion.state, value: experimental.showPlaceholders)
        .animation(PixlMotion.state, value: experimental.switchOnDragRelease)
        .animation(PixlMotion.state, value: experimental.applyPlaceholdersOnClose)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .pixlFont(.titleSmall)
            .foregroundStyle(theme.onSurface)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .experimentalPanelGlass()
            .accessibilityAddTraits(.isHeader)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .pixlFont(.bodyMedium)
            .foregroundStyle(theme.onSurfaceVariant)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .experimentalPanelGlass()
    }

    /// Step 3: the trigger mode (Android `TriggerModeOptionCard` pair, 12 pt corners, ≥ 94 pt).
    private func triggerPanel(experimental: ExperimentalSettings, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.settingsExpStep3TriggerHeader).pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
            Text(enabled ? L10n.settingsExpTriggerModeUnlocked : L10n.settingsExpTriggerModeLocked)
                .pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
            HStack(spacing: 8) {
                triggerCard(L10n.settingsExpThresholdTitle, L10n.settingsExpThresholdSubtitle,
                            selected: !experimental.switchOnDragRelease, enabled: enabled) {
                    experimental.switchOnDragRelease = false
                }
                triggerCard(L10n.settingsExpDragReleaseTitle, L10n.settingsExpDragReleaseSubtitle,
                            selected: experimental.switchOnDragRelease, enabled: enabled) {
                    experimental.switchOnDragRelease = true
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .experimentalPanelGlass()
    }

    private func triggerCard(_ title: String, _ subtitle: String, selected: Bool, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        let fill = !enabled ? theme.surfaceVariant.opacity(0.45) : selected ? theme.primaryContainer
            : theme.surfaceContainerHighest
        let titleColor = !enabled ? theme.onSurface.opacity(0.55) : selected ? theme.onPrimaryContainer : theme.onSurface
        let subtitleColor = !enabled ? theme.onSurfaceVariant.opacity(0.55)
            : selected ? theme.onPrimaryContainer.opacity(0.8) : theme.onSurfaceVariant
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).pixlFont(.titleSmall).foregroundStyle(titleColor)
                Text(subtitle).pixlFont(.bodySmall).foregroundStyle(subtitleColor)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 94, maxHeight: .infinity, alignment: .topLeading)
            .background(fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Android's album-art quality options (12 pt corners; selected = `primaryContainer`).
    private func qualityRow(_ quality: String, selected: Bool) -> some View {
        let line = switch quality {
        case "LOW": L10n.settingsExpAlbumArtQualityLowLine
        case "HIGH": L10n.settingsExpAlbumArtQualityHighLine
        case "ORIGINAL": L10n.settingsExpAlbumArtQualityOriginalLine
        default: L10n.settingsExpAlbumArtQualityMediumLine
        }
        let parts = line.components(separatedBy: " - ")
        return Button { settings.appearance.albumArtQuality = quality } label: {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(parts.first ?? line).pixlFont(.bodyLarge, weight: selected ? .bold : .regular)
                        .foregroundStyle(theme.onSurface)
                    if parts.count > 1 {
                        Text(parts.dropFirst().joined(separator: " - ")).pixlFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(theme.primary)
                        .accessibilityLabel(L10n.commonSelected)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(selected ? theme.primaryContainer : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("experimental.quality.\(quality)")
    }
}

/// Android `SettingsSection` with its rows 4 pt apart.
private struct ExperimentalSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .pixlFont(.labelMedium, weight: .bold)
                .foregroundStyle(theme.primary)
                .padding(.leading, 12)
                .padding(.vertical, 8)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 4) {
                content.environment(\.settingsRowCorners, SettingsRowCorners(top: 10, bottom: 10))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

extension View {
    /// The 10 pt `surfaceContainer` panel of the experimental screen, as glass.
    fileprivate func experimentalPanelGlass(interactive: Bool = false) -> some View {
        modifier(ExperimentalPanelGlass(interactive: interactive))
    }
}

private struct ExperimentalPanelGlass: ViewModifier {
    let interactive: Bool
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content.pixlGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                          tint: theme.surfaceContainer.opacity(SettingsTint.row), interactive: interactive)
    }
}

/// A slider panel: icon, title with an optional value chip, subtitle, the slider and an optional footer.
private struct ExperimentalSliderPanel: View {
    let systemImage: String
    let title: String
    let chip: String?
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let steps: Int
    var enabled = true
    var footer: String?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIcon(systemImage: systemImage)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(title).pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
                        if let chip { SettingsValueChip(text: chip) }
                    }
                    Text(subtitle).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Slider(value: $value, in: range, step: (range.upperBound - range.lowerBound) / Double(steps + 1))
                .tint(theme.primary)
                .disabled(!enabled)
            if let footer {
                Text(footer).pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .experimentalPanelGlass()
    }
}

/// The BS-RoFormer render backend fields (Android keys `tais_roformer_*`).
private struct RoformerBackendPanel: View {
    @Bindable var experimental: ExperimentalSettings
    @Environment(\.appTheme) private var theme

    var body: some View {
        let gradio = experimental.roformerBackendType == "GRADIO_SPACE"
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "BS-RoFormer Render Backend").pixlFont(.titleMedium).foregroundStyle(theme.onSurface)
            Text(String(localized: "settings_exp_roformer_body",
                        defaultValue: "Point this at a hosted BS-RoFormer / Mel-Band RoFormer separator to unlock \"Render Studio Master (BS-RoFormer)\" below. Blank base URL = that button stays disabled."))
                .pixlFont(.bodyMedium).foregroundStyle(theme.onSurfaceVariant)
            GlassPillRow(items: [GlassPillRow<String>.Item(id: "GRADIO_SPACE", title: "Gradio Space"),
                                 GlassPillRow<String>.Item(id: "DIRECT_POST", title: "Direct POST")],
                         selection: $experimental.roformerBackendType, uppercase: false, height: 40, edgePadding: 0,
                         accessibilityIdentifierPrefix: "experimental.roformer")
            Text(gradio
                 ? String(localized: "settings_exp_roformer_gradio_hint",
                          defaultValue: "A public Hugging Face Space, or your own on Modal/RunPod/etc. The API route name is whatever that specific Space calls its inference function — check its \"Use via API\" page.")
                 : String(localized: "settings_exp_roformer_direct_hint",
                          defaultValue: "A bare server that takes one upload and sends the result straight back — a Colab notebook + FastAPI + ngrok/localtunnel tunnel, Modal, RunPod, or a home server. The API route name is that server's one endpoint (usually \"/predict\")."))
                .pixlFont(.bodySmall).foregroundStyle(theme.onSurfaceVariant)
            SettingsTextField(placeholder: gradio ? "https://username-spacename.hf.space" : "https://xxxx.ngrok-free.app",
                              text: $experimental.roformerBaseUrl, label: "Base URL")
            SettingsTextField(placeholder: "/predict", text: $experimental.roformerApiName, label: "API route name")
            SettingsTextField(placeholder: "", text: $experimental.roformerApiKey, secure: true,
                              label: "API key (optional, gated backends only)")
            if gradio {
                SettingsTextField(placeholder: "Standard — Vocals", text: $experimental.roformerExtraArg,
                                  label: "Extra argument (optional)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .experimentalPanelGlass()
        // The API key comes from the Keychain, read the first time this panel shows.
        .onAppear { experimental.loadSecretsIfNeeded() }
    }
}
