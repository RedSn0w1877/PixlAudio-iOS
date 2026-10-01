import SwiftUI

/// The tap-sync lyrics editor (Android `LyricsSyncControls` + sync screens) — placeholder until stage 10.
struct LyricsSyncEditorView: View {
    let songId: String
    @Environment(Router.self) private var router

    var body: some View {
        NavigationStack {
            PlaceholderScreen(title: "Sync lyrics", systemImage: "hand.tap", owner: "Stage 10 — sync editor",
                              screenID: "lyricsSync")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { router.dismissCover() }
                    }
                }
        }
    }
}
