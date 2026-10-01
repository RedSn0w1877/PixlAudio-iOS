import SwiftUI

/// Song info and actions (Android `SongInfoBottomSheet`, tag editing via `EditSongSheet`) — placeholder until
/// stage 8.
struct SongInfoSheet: View {
    let songId: String
    @Environment(LibraryStore.self) private var library

    var body: some View {
        SheetScaffold(LocalizedStringKey(library.song(id: songId)?.title ?? "Song")) {
            Text("Song info arrives in stage 8")
                .pixlFont(.bodyMedium)
                .padding(.horizontal, Tokens.Spacing.xxl)
        }
        .accessibilityIdentifier("screen.songInfo")
    }
}
