import PixlAudioCore
import SwiftUI

/// Settings › Playback (Android `SettingsCategoryScreen` PLAYBACK): background playback, ReplayGain, volume,
/// headphones, streaming audio quality, queue and transitions.
///
/// Dropped (Android-only): battery optimisation (iOS background audio needs no exemption), Chromecast autoplay
/// (iOS casts with AirPlay, which has no autoplay), Hi-Fi mode (float PCM output — iOS's audio pipeline is already
/// float end to end), and "Keep playing after closing" (iOS ends the app, and its playback, when it is swiped away
/// from the app switcher, so neither choice could be honoured; background audio keeps playing otherwise).
/// "Pause when volume reaches zero" is honoured by `VolumeZeroPauser`.
struct PlaybackSettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var env
    @State private var crossfadeSeconds: Double = 2

    var body: some View {
        @Bindable var playback = settings.playback
        SettingsCategoryScaffold(category: .playback) {
            SettingsSubsection(title: L10n.settingsReplaygainSection) {
                SwitchSettingRow(title: L10n.settingsReplaygainEnableTitle,
                                 subtitle: L10n.settingsReplaygainEnableSubtitle,
                                 isOn: $playback.replayGainEnabled, systemImage: "speaker.wave.1")
                if playback.replayGainEnabled {
                    ThemeSelectorRow(label: L10n.settingsGainModeTitle, description: L10n.settingsGainModeSubtitle,
                                     options: [SettingsOption(key: "track", label: L10n.settingsGainModeTrack),
                                               SettingsOption(key: "album", label: L10n.settingsGainModeAlbum)],
                                     selectedKey: playback.replayGainUseAlbumGain ? "album" : "track",
                                     systemImage: "speaker.wave.1") { playback.replayGainUseAlbumGain = $0 == "album" }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            SettingsSubsection(title: L10n.settingsVolumeSection) {
                SwitchSettingRow(title: L10n.settingsPauseOnVolumeZero, subtitle: L10n.settingsPauseOnVolumeZeroDesc,
                                 isOn: $playback.pauseOnVolumeZero, systemImage: "speaker.wave.1")
            }
            SettingsSubsection(title: L10n.settingsHeadphonesSection) {
                SwitchSettingRow(title: L10n.settingsHeadphonesResumeTitle,
                                 subtitle: L10n.settingsHeadphonesResumeSubtitle,
                                 isOn: $playback.resumeOnHeadsetReconnect, systemImage: "headphones")
            }
            SettingsSubsection(title: L10n.settingsAudioQualityTitle) {
                ThemeSelectorRow(label: L10n.settingsAudioQualityTitle, description: L10n.settingsAudioQualitySubtitle,
                                 options: [SettingsOption(key: "LOW", label: L10n.settingsAudioQualityLow),
                                           SettingsOption(key: "STANDARD", label: L10n.settingsAudioQualityStandard),
                                           SettingsOption(key: "HIGH", label: L10n.settingsAudioQualityHigh),
                                           SettingsOption(key: "ULTRASOUND", label: L10n.settingsAudioQualityUltrasound)],
                                 selectedKey: playback.audioQuality, systemImage: "4k.tv") { quality in
                    playback.audioQuality = quality
                    // Cached stream URLs were picked under the old cap.
                    if let service = env.youtube.service { Task { await service.invalidateAll() } }
                }
            }
            SettingsSubsection(title: L10n.settingsQueueTransitionsSection, addBottomSpace: false) {
                ThemeSelectorRow(label: L10n.settingsCrossfadeTitle, description: L10n.settingsCrossfadeSubtitle,
                                 options: [SettingsOption(key: "true", label: L10n.settingsLabelEnabled),
                                           SettingsOption(key: "false", label: L10n.settingsLabelDisabled)],
                                 selectedKey: playback.isCrossfadeEnabled ? "true" : "false",
                                 systemImage: "align.horizontal.center") { playback.isCrossfadeEnabled = $0 == "true" }
                if playback.isCrossfadeEnabled {
                    SliderSettingRow(label: L10n.settingsCrossfadeDurationTitle, value: $crossfadeSeconds,
                                     range: 1...12, steps: 10,
                                     onCommit: { playback.crossfadeDurationMs = Int(crossfadeSeconds * 1000) },
                                     valueText: { "\(Int($0))s" })
                }
                ThemeSelectorRow(label: L10n.settingsPlayerAmbientEffectsTitle,
                                 description: L10n.settingsPlayerAmbientEffectsSubtitle,
                                 options: [SettingsOption(key: "OFF", label: L10n.settingsPlayerAmbientStyleOff),
                                           SettingsOption(key: "BLENDED_COVER",
                                                          label: L10n.settingsPlayerAmbientStyleBlendedCover),
                                           SettingsOption(key: "FLOWING_GRADIENT",
                                                          label: L10n.settingsPlayerAmbientStyleFlowingGradient),
                                           SettingsOption(key: "LOW_POLY_MESH",
                                                          label: L10n.settingsPlayerAmbientStyleLowPolyMesh),
                                           SettingsOption(key: "AUDIO_WAVEFORM",
                                                          label: L10n.settingsPlayerAmbientStyleAudioWaveform)],
                                 selectedKey: playback.playerAmbientStyle, systemImage: "align.horizontal.center") {
                    playback.playerAmbientStyle = $0
                }
                SwitchSettingRow(title: L10n.settingsPersistentShuffleTitle,
                                 subtitle: L10n.settingsPersistentShuffleSubtitle,
                                 isOn: $playback.persistentShuffleEnabled, systemImage: "shuffle")
                SwitchSettingRow(title: L10n.settingsShowQueueHistoryTitle,
                                 subtitle: L10n.settingsShowQueueHistorySubtitle,
                                 isOn: $playback.showQueueHistory, systemImage: "list.bullet")
            }
        }
        .animation(PixlMotion.state, value: playback.replayGainEnabled)
        .animation(PixlMotion.state, value: playback.isCrossfadeEnabled)
        .onAppear { crossfadeSeconds = Double(playback.crossfadeDurationMs) / 1000 }
    }
}

/// Settings › Behavior (Android `SettingsCategoryScreen` BEHAVIOR): player gestures, haptics. iOS-first additions
/// (2026-10-18): the Gestures page, Blocked artists and Music Haptics.
struct BehaviorSettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var env
    @Environment(BlockedArtistsStore.self) private var blocked
    @Environment(Router.self) private var router
    @State private var strength: Double = 100

    var body: some View {
        @Bindable var behavior = settings.behavior
        let haptics = env.musicHaptics
        SettingsCategoryScaffold(category: .behavior) {
            SettingsSubsection(title: L10n.settingsPlayerGesturesSection) {
                SwitchSettingRow(title: L10n.settingsTapBgClosesTitle, subtitle: L10n.settingsTapBgClosesSubtitle,
                                 isOn: $behavior.tapBackgroundClosesPlayer, systemImage: "hand.tap")
                SettingsItemRow(title: "Gestures", subtitle: gesturesSubtitle, systemImage: "hand.draw",
                                showsChevron: true, identifier: "settings.behavior.gestures") {
                    router.push(.gestureSettings)
                }
            }
            SettingsSubsection(title: "Blocked artists") {
                SettingsItemRow(title: "Blocked artists", subtitle: blockedSubtitle, systemImage: "nosign",
                                showsChevron: true, identifier: "settings.behavior.blockedArtists") {
                    router.push(.blockedArtists)
                }
            }
            SettingsSubsection(title: L10n.settingsHapticsSection, addBottomSpace: haptics.isSupported) {
                SwitchSettingRow(title: L10n.settingsHapticFeedbackTitle, subtitle: L10n.settingsHapticFeedbackSubtitle,
                                 isOn: $behavior.hapticsEnabled, systemImage: "hand.tap")
            }
            if haptics.isSupported {
                SettingsSubsection(title: "Music Haptics", addBottomSpace: false) {
                    SwitchSettingRow(title: "Music Haptics",
                                     subtitle: "Feel the beat: the Taptic Engine plays along with the music.",
                                     isOn: $behavior.musicHapticsEnabled, systemImage: "waveform.path")
                    if behavior.musicHapticsEnabled {
                        SliderSettingRow(label: "Strength", value: $strength, range: 20...200, steps: 17,
                                         onCommit: { behavior.musicHapticsStrength = Int(strength) },
                                         valueText: { "\(Int($0))%" })
                            .transition(.move(edge: .top).combined(with: .opacity))
                        ThemeSelectorRow(label: "Follows", description: "What the haptics follow in the music.",
                                         options: [SettingsOption(key: "everything", label: "Everything"),
                                                   SettingsOption(key: "beat", label: "Beat"),
                                                   SettingsOption(key: "bass", label: "Bass")],
                                         selectedKey: behavior.musicHapticsMode.rawValue, systemImage: "waveform") { key in
                            behavior.musicHapticsMode = MusicHapticsMode(rawValue: key) ?? .everything
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    statusRow(haptics.status)
                }
            }
        }
        .animation(PixlMotion.state, value: behavior.musicHapticsEnabled)
        .onAppear { strength = Double(behavior.musicHapticsStrength) }
    }

    /// The status line: On / Off / Not available, with the reason when something blocks it.
    private func statusRow(_ status: MusicHapticsStatus) -> some View {
        SettingsItemRow(title: "Status", subtitle: statusText(status), systemImage: "info.circle",
                        identifier: "settings.musicHaptics.status") {}
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.musicHaptics.status")
    }

    private func statusText(_ status: MusicHapticsStatus) -> String {
        if let reason = status.reason { return "\(status.title) · \(reason.rawValue)" }
        return status.title
    }

    private var gesturesSubtitle: String {
        let b = settings.behavior
        let on = [b.gesturePlayerArtworkSwipe, b.gesturePlayerArtworkDoubleTapLike, b.gesturePlayerArtworkLongPress,
                  b.gestureMiniSwipeSkip, b.gestureMiniSwipeUpOpen, b.gestureMiniLongPress, b.gestureListSwipeQueue]
            .filter { $0 }.count
        return "\(on) of 7 on"
    }

    private var blockedSubtitle: String {
        switch blocked.count {
        case 0: "No blocked artists"
        case 1: "1 blocked artist"
        default: "\(blocked.count) blocked artists"
        }
    }
}
