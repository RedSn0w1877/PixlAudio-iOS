import UIKit

/// VoiceOver notifications the app posts itself: toasts and status messages are read out (they disappear after a
/// couple of seconds and are never focused), and the full player's expand / collapse moves focus to the new screen.
/// Nothing is posted while VoiceOver is off.
enum PixlAccessibility {
    /// Reads a short message (a toast, an error) without moving focus.
    static func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning, !text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// The screen's content changed wholesale (the full player came up or went): VoiceOver re-reads it and moves
    /// focus to its first element.
    static func screenChanged() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// Settings › Accessibility › Motion › Reduce Motion.
    static var reducesMotion: Bool { UIAccessibility.isReduceMotionEnabled }
}
