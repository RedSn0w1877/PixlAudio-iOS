import PixlLibrary
import PixlModel
import SwiftUI

/// The notes of the queue, made again only when the queue's next songs, the current song or the library change (docs/brain-spec.md, 9.3 "Set
/// notes"). A reference type held in `@State`: reading a note in a view's body never writes observed state, and a body that runs for another
/// reason (a drag, a progress tick) finds the same notes without walking the queue again. No model, no network.
final class SetNoteMemo {
    private var window: [String] = []
    private var current = -2
    private var revision = -1
    private var result = SetNoteLines.Result.none

    func notes(queue: [Song], currentIndex: Int, library: LibraryStore) -> SetNoteLines.Result {
        guard currentIndex >= 0, currentIndex < queue.count else { return .none }
        let end = min(queue.count, currentIndex + SetNoteLines.lookahead)
        let ids = queue[currentIndex..<end].map(\.id)
        if ids == window, current == currentIndex, revision == library.songsRevision { return result }
        window = ids
        current = currentIndex
        revision = library.songsRevision
        result = SetNoteLines.forQueue(queue, currentIndex: currentIndex) { library.song(id: $0.id) != nil }
        return result
    }
}

/// The note above a group of upcoming songs in the queue (Android `SetNoteRowLabel`): one quiet line.
struct SetNoteRowLabel: View {
    let text: String

    @Environment(\.appTheme) private var theme

    var body: some View {
        Text(text)
            .pixlFont(.labelMedium)
            .foregroundStyle(theme.onSurfaceVariant)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
            .accessibilityIdentifier("queue.setNote")
    }
}

/// The note under the player's artist line (Android `SetNoteLine`), or nothing. Reads the queue and the current index itself, so only this
/// line is re-evaluated when they change.
struct PlayerSetNoteLine: View {
    let color: Color

    @Environment(PlaybackStore.self) private var playback
    @Environment(LibraryStore.self) private var library
    @State private var memo = SetNoteMemo()

    var body: some View {
        if let note = memo.notes(queue: playback.queue, currentIndex: playback.currentIndex ?? -1, library: library).current {
            Text(note)
                .pixlFont(.labelLarge)
                .foregroundStyle(color)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .accessibilityIdentifier("player.setNote")
        }
    }
}
