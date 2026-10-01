import SwiftUI

/// The queue (Android `QueueBottomSheet`) — placeholder until stage 8.
struct QueueSheet: View {
    var body: some View {
        SheetScaffold("Queue") {
            Text("Queue arrives in stage 8")
                .pixlFont(.bodyMedium)
                .padding(.horizontal, Tokens.Spacing.xxl)
        }
        .accessibilityIdentifier("screen.queue")
    }
}

/// The sleep timer (Android `TimerOptionsBottomSheet`) — placeholder until stage 8.
struct SleepTimerSheet: View {
    var body: some View {
        SheetScaffold("Sleep timer") {
            Text("Sleep timer arrives in stage 8")
                .pixlFont(.bodyMedium)
                .padding(.horizontal, Tokens.Spacing.xxl)
        }
        .accessibilityIdentifier("screen.sleepTimer")
    }
}
