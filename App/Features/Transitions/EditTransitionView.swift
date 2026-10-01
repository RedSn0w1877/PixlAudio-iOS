import SwiftUI

/// Transition rules (Android `EditTransitionScreen`) — stage 7d.
struct EditTransitionView: View {
    /// nil = the global default rule.
    let playlistId: String?

    var body: some View {
        PlaceholderScreen(title: "Transitions", systemImage: "arrow.triangle.merge", owner: "Stage 7d — Settings, EQ, transitions, delimiters", screenID: "editTransition")
    }
}
