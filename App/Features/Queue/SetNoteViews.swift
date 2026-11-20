import PixlLibrary
import PixlModel
import SwiftUI

/// What a note is made from: the window of the queue it looks at and the current position. A change of either asks the history again.
struct SetNoteKey: Hashable {
    let ids: [String]
    let current: Int
}

/// The notes of the queue, made again only when the queue's next songs, the current song or the history of plays change (docs/brain-spec.md,
/// 9.3 "Set notes"). A reference type held in `@State`: reading a note in a view's body never writes observed state, and a body that runs for
/// another reason (a drag, a progress tick) finds the same notes without walking the queue again. No model, no network.
final class SetNoteMemo {
    private var key = SetNoteKey(ids: [], current: -2)
    private var heard: Set<String>?
    private var result = SetNoteLines.Result.none
    private var valid = false

    func key(queue: [Song], currentIndex: Int) -> SetNoteKey {
        guard currentIndex >= 0, currentIndex < queue.count else { return SetNoteKey(ids: [], current: currentIndex) }
        let end = min(queue.count, currentIndex + SetNoteLines.lookahead)
        return SetNoteKey(ids: queue[currentIndex..<end].map(\.id), current: currentIndex)
    }

    /// The notes; none until the history of plays has been read (`heard` nil): a note is true or absent.
    func notes(queue: [Song], currentIndex: Int, heard: Set<String>?) -> SetNoteLines.Result {
        guard heard != nil, currentIndex >= 0, currentIndex < queue.count else { return .none }
        let next = key(queue: queue, currentIndex: currentIndex)
        if valid, next == key, heard == self.heard { return result }
        key = next
        self.heard = heard
        valid = true
        result = SetNoteLines.forQueue(queue, currentIndex: currentIndex, heard: heard)
        return result
    }
}

/// Which songs of a window of the queue the listener has a recorded play of (`SetNoteHistory`): the alias table and the affinity state, on
/// their own actors, never on the main thread.
nonisolated enum SetNoteHistoryLoader {
    static func heard(_ window: [Song], repository: BrainRepository?, engine: BrainEngine?) async -> Set<String> {
        guard let repository, let engine, !window.isEmpty else { return [] }
        return await SetNoteHistory.heardSongIds(
            window,
            ridsOf: { requests in await repository.resolveTracks(requests) },
            heard: { rids in
                await engine.readAffinity { state in Set(rids.filter { Affinity.isHeard(state, family: Family.track, key: $0) }) }
            })
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
    @Environment(AppEnvironment.self) private var env
    @State private var memo = SetNoteMemo()
    @State private var heard: Set<String>?

    var body: some View {
        let queue = playback.queue
        let current = playback.currentIndex ?? -1
        VStack(spacing: 0) {
            if let note = memo.notes(queue: queue, currentIndex: current, heard: heard).current {
                Text(note)
                    .pixlFont(.labelLarge)
                    .foregroundStyle(color)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .accessibilityIdentifier("player.setNote")
            }
        }
        // The history of plays is read when the window of the queue changes, off the main thread.
        .background(Color.clear.frame(width: 0, height: 0).task(id: memo.key(queue: queue, currentIndex: current)) {
            heard = await SetNoteHistoryLoader.heard(SetNoteLines.window(queue, currentIndex: current), repository: env.brain.repository,
                                                     engine: env.brain.engine)
        })
    }
}
