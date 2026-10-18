import SwiftUI

/// Settings › Behavior › Gestures (iOS-first, 2026-10-18): a switch per gesture, all on by default. Every gesture is a
/// horizontal-intent recogniser (`GesturePolicy`): it begins only when the drag is clearly sideways, so it never
/// competes with scrolling or the player sheet's vertical drag. With VoiceOver on, gestures are off and the same
/// actions are in the rotor's actions menu.
struct GestureSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.appTheme) private var theme

    var body: some View {
        @Bindable var behavior = settings.behavior
        SettingsScaffold(title: "Gestures", screenID: "gestureSettings") {
            SettingsSubsection(title: "Full player artwork") {
                SwitchSettingRow(title: "Swipe to skip",
                                 subtitle: "Swipe the artwork left for the next song, right for the previous one.",
                                 isOn: $behavior.gesturePlayerArtworkSwipe, systemImage: "arrow.left.arrow.right")
                SwitchSettingRow(title: "Double-tap to like",
                                 subtitle: "Double-tap the artwork to like or unlike the song.",
                                 isOn: $behavior.gesturePlayerArtworkDoubleTapLike, systemImage: "heart")
                SwitchSettingRow(title: "Press and hold for actions",
                                 subtitle: "Add to playlist, share or go to the artist.",
                                 isOn: $behavior.gesturePlayerArtworkLongPress, systemImage: "hand.tap")
            }
            SettingsSubsection(title: "Mini player") {
                SwitchSettingRow(title: "Swipe to skip",
                                 subtitle: "Swipe the mini player left for the next song, right for the previous one.",
                                 isOn: $behavior.gestureMiniSwipeSkip, systemImage: "arrow.left.arrow.right")
                SwitchSettingRow(title: "Swipe up to open",
                                 subtitle: "Drag the mini player up to open the full player.",
                                 isOn: $behavior.gestureMiniSwipeUpOpen, systemImage: "chevron.up")
                SwitchSettingRow(title: "Press and hold for actions",
                                 subtitle: "Add to playlist, share or go to the artist.",
                                 isOn: $behavior.gestureMiniLongPress, systemImage: "hand.tap")
            }
            SettingsSubsection(title: "Lists", addBottomSpace: false) {
                SwitchSettingRow(title: "Swipe songs to queue",
                                 subtitle: "Swipe a song right to play it next, left to add it to the queue.",
                                 isOn: $behavior.gestureListSwipeQueue, systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Text("The queue keeps its own swipe and reorder gestures. With VoiceOver on, these gestures are turned off and the same actions are in each item's actions menu.")
                .pixlFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        }
    }
}
