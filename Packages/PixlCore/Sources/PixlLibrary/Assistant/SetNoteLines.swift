// Set notes on the queue (docs/brain-spec.md, 9.3 "What the listener gets", stage 4 milestone 2): one line about what is coming, in the queue
// and under the player title: "Three from your V-pop side, then something new from HIEUTHUHAI." A port of Android's `SetNoteLines`. The
// words are a template over the queue (`SetNotes`); there is no model and no network, and a line is true of the queue it was made from: it is
// made again whenever the queue or the current song changes, and a queue it cannot say anything true about has none.

import Foundation
import PixlModel

public enum SetNoteLines {
    /// At most this many upcoming tracks are looked at: a note describes the next few, and a long queue is not walked.
    public static let lookahead = 40

    /// The notes of the queue from the current song on, by the id of the song each sits on; `current` is the note of the group the current
    /// song starts.
    public struct Result: Sendable, Equatable {
        public let bySongId: [String: String]
        public let current: String?

        public static let none = Result(bySongId: [:], current: nil)

        public init(bySongId: [String: String], current: String?) {
            self.bySongId = bySongId
            self.current = current
        }
    }

    /// `known` is true for a song the listener has: a library row. One the engine found outside the library is the "something new".
    public static func slot(of song: Song, known: Bool) -> SetNotes.Slot {
        SetNotes.Slot(artist: BrainFeedback.artistOf(song), genre: SetNotes.firstGenre(song.genre), known: known)
    }

    public static func forQueue(_ queue: [Song], currentIndex: Int, isKnown: (Song) -> Bool) -> Result {
        if currentIndex < 0 || currentIndex >= queue.count { return .none }
        let end = min(queue.count, currentIndex + lookahead)
        var slots: [SetNotes.Slot] = []
        slots.reserveCapacity(end - currentIndex)
        for i in currentIndex..<end { slots.append(slot(of: queue[i], known: isKnown(queue[i]))) }
        let notes = SetNotes.notes(slots)
        if notes.isEmpty { return .none }
        var byId: [String: String] = [:]
        var current: String?
        for n in notes {
            let text = SetNotes.text(n)
            if n.index == 0 { current = text }
            byId[queue[currentIndex + n.index].id] = text
        }
        return Result(bySongId: byId, current: current)
    }
}
