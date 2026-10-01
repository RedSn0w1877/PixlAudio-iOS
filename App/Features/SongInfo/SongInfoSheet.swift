import PixlModel
import SwiftUI

/// Song info and actions (Android `SongInfoBottomSheet`). Stage 7a ported the sheet's body as `SongOptionsSheet`
/// (Features/Library) because every song row's ⋮ opens it; stage 8 adds the header's edit button, which opens
/// `EditSongSheet` full screen (Android's full-screen dialog) for songs that can be edited.
struct SongInfoSheet: View {
    let songId: String

    @Environment(LibraryStore.self) private var library
    @State private var showsEditor = false

    var body: some View {
        let editable = library.song(id: songId).map(SongTagEditor.isEditable) ?? false
        SongOptionsSheet(songId: songId, onEdit: editable ? { showsEditor = true } : nil)
            .fullScreenCover(isPresented: $showsEditor) {
                EditSongSheet(songId: songId)
            }
    }
}
