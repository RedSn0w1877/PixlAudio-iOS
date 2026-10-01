import SwiftUI

/// First-run setup (Android `SetupScreen`: permissions → here folders, the music library, Android backup import) —
/// placeholder until stage 15.
struct SetupView: View {
    @Environment(Router.self) private var router

    var body: some View {
        NavigationStack {
            PlaceholderScreen(title: "Welcome", systemImage: "music.note.house", owner: "Stage 15 — onboarding",
                              screenID: "setup")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { router.dismissCover() }
                    }
                }
        }
    }
}
