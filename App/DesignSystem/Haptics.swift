import SwiftUI

/// Settings › Behavior › Haptic feedback (Android `haptics_enabled`: "Enable vibration feedback across the app"),
/// readable when a haptic fires without putting the setting in every view's environment. `BehaviorSettings` keeps
/// it current.
enum HapticsPreference {
    static var isEnabled = true
}

extension View {
    /// `sensoryFeedback(_:trigger:)` that plays only while Haptic feedback is on. Use it for every haptic in the app.
    func pixlHaptic<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        sensoryFeedback(feedback, trigger: trigger) { _, _ in HapticsPreference.isEnabled }
    }
}
