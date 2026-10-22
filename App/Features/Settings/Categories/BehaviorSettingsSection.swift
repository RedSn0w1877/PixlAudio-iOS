import PixlAudioCore
import SwiftUI

/// Settings › Gestures & haptics (the `behavior` category; Android `SettingsCategoryScreen` BEHAVIOR): the full
/// player's, the mini player's and the song rows' gestures, then the haptics. iOS-first additions (2026-10-18): the
/// gestures and Music Haptics. The old Gestures page is gone — its switches sit here, under Android's wording. In
/// developer mode an "Advanced" block shows the music haptics' status line.
struct BehaviorSettingsSection: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppEnvironment.self) private var env
    @Environment(\.appTheme) private var theme
    @State private var strength: Double = 100

    var body: some View {
        @Bindable var behavior = settings.behavior
        let haptics = env.musicHaptics
        let developerMode = settings.experimental.developerMode
        SettingsCategoryScaffold(category: .behavior) {
            SettingsSubsection(title: L10n.settingsSectionFullPlayer) {
                SwitchSettingRow(title: L10n.settingsGestureCoverSwipeTitle,
                                 subtitle: L10n.settingsGestureCoverSwipeSubtitle,
                                 isOn: $behavior.gesturePlayerArtworkSwipe, systemImage: "arrow.left.arrow.right")
                SwitchSettingRow(title: L10n.settingsGestureCoverLikeTitle,
                                 subtitle: L10n.settingsGestureCoverLikeSubtitle,
                                 isOn: $behavior.gesturePlayerArtworkDoubleTapLike, systemImage: "heart")
                SwitchSettingRow(title: L10n.settingsGestureCoverActionsTitle,
                                 subtitle: L10n.settingsGestureActionsSubtitle,
                                 isOn: $behavior.gesturePlayerArtworkLongPress, systemImage: "hand.tap")
                SwitchSettingRow(title: L10n.settingsTapBgClosesTitle, subtitle: L10n.settingsRowTapBackgroundSubtitle,
                                 isOn: $behavior.tapBackgroundClosesPlayer, systemImage: "xmark.rectangle")
            }
            SettingsSubsection(title: L10n.settingsSectionMiniPlayer) {
                SwitchSettingRow(title: L10n.settingsGestureMiniSkipTitle, subtitle: L10n.settingsGestureMiniSkipSubtitle,
                                 isOn: $behavior.gestureMiniSwipeSkip, systemImage: "arrow.left.arrow.right")
                SwitchSettingRow(title: L10n.settingsGestureMiniUpTitle, subtitle: L10n.settingsGestureMiniUpSubtitle,
                                 isOn: $behavior.gestureMiniSwipeUpOpen, systemImage: "chevron.up")
                SwitchSettingRow(title: L10n.settingsGestureMiniActionsTitle,
                                 subtitle: L10n.settingsGestureActionsSubtitle,
                                 isOn: $behavior.gestureMiniLongPress, systemImage: "hand.tap")
            }
            SettingsSubsection(title: L10n.settingsSectionSongLists, addBottomSpace: false) {
                SwitchSettingRow(title: L10n.settingsGestureRowTitle, subtitle: L10n.settingsGestureRowSubtitle,
                                 isOn: $behavior.gestureListSwipeQueue,
                                 systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            // The page's note on the gestures (VoiceOver turns them off; the same actions are in the actions menu).
            Text(L10n.settingsGestureFooter)
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            SettingsSubsection(title: L10n.settingsHapticsSection, addBottomSpace: developerMode && haptics.isSupported) {
                SwitchSettingRow(title: L10n.settingsHapticFeedbackTitle, subtitle: L10n.settingsHapticFeedbackSubtitle,
                                 isOn: $behavior.hapticsEnabled, systemImage: "hand.tap")
                if haptics.isSupported {
                    SwitchSettingRow(title: L10n.settingsMusicHapticsTitle, subtitle: L10n.settingsMusicHapticsSubtitle,
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
                }
            }
            if haptics.isSupported {
                SettingsAdvancedSubsection {
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
}
