import SwiftUI

/// Song info and actions (Android `SongInfoBottomSheet`). Stage 7a ported the sheet as `SongOptionsSheet`
/// (Features/Library) because every song row's ⋮ opens it; tag editing (`EditSongSheet`) is still to come.
struct SongInfoSheet: View {
    let songId: String

    var body: some View {
        SongOptionsSheet(songId: songId)
    }
}
