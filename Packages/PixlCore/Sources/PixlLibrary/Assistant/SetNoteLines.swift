// Set notes on the queue (docs/brain-spec.md, 9.3 "What the listener gets", stage 4 milestone 2): one line about what is coming, in the queue
// and under the player title: "Three from your V-pop side, then something new from HIEUTHUHAI." A port of Android's `SetNoteLines`. The
// words are a template over the queue (`SetNotes`); there is no model and no network, and a line is true of the queue it was made from: it is
// made again whenever the queue or the current song changes, and a queue it cannot say anything true about has none.
//
// What a note may claim comes from recorded plays (`SetNoteHistory`), never from where a song lives: "your side" is a song the listener has a
// recorded play of, "something new" is a song from outside the library with none. A library song nobody has played (a First Listen queue is
// made of them) is neither, so no note claims it; a song that played through a radio is not "new".

import Foundation
import PixlModel

public enum SetNoteLines {
    /// At most this many upcoming tracks are looked at: a note describes the next few, and a long queue is not walked.
    public static let lookahead = 40

    /// The notes of the queue from the current song on, by the position in the queue of the row each sits on (a song can be in a queue twice,
    /// and a note belongs to one row); `current` is the note of the group the current song starts.
    public struct Result: Sendable, Equatable {
        public let byIndex: [Int: String]
        public let current: String?

        public static let none = Result(byIndex: [:], current: nil)

        public init(byIndex: [Int: String], current: String?) {
            self.byIndex = byIndex
            self.current = current
        }
    }

    /// True for a song from outside the library (the engine's own track, `yt:<videoId>`).
    public static func isEngineOnly(_ song: Song) -> Bool { TrackCatalog.videoId(ofSongId: song.id) != nil }

    /// One upcoming song as a note sees it. `heard` is the ids of the songs with a recorded play: only those are "your side", and only an
    /// engine track with no recorded play is "something new". A library song with no play is neither.
    public static func slot(of song: Song, heard: Set<String>) -> SetNotes.Slot {
        let played = heard.contains(song.id)
        let fresh = !played && isEngineOnly(song)
        return SetNotes.Slot(artist: (played || fresh) ? BrainFeedback.artistOf(song) : "", genre: SetNotes.firstGenre(song.genre), known: played)
    }

    /// The notes of `queue` from `currentIndex`. `heard` nil means the history is not loaded yet: no note is made (a note is true or absent).
    public static func forQueue(_ queue: [Song], currentIndex: Int, heard: Set<String>?) -> Result {
        guard let heard, currentIndex >= 0, currentIndex < queue.count else { return .none }
        let end = min(queue.count, currentIndex + lookahead)
        var slots: [SetNotes.Slot] = []
        slots.reserveCapacity(end - currentIndex)
        for i in currentIndex..<end { slots.append(slot(of: queue[i], heard: heard)) }
        let notes = SetNotes.notes(slots)
        if notes.isEmpty { return .none }
        var byIndex: [Int: String] = [:]
        var current: String?
        for n in notes {
            let text = SetNotes.text(n)
            if n.index == 0 { current = text }
            byIndex[currentIndex + n.index] = text
        }
        return Result(byIndex: byIndex, current: current)
    }

    /// The songs a note looks at (the current one and the next few), so the history is read for those only.
    public static func window(_ queue: [Song], currentIndex: Int) -> [Song] {
        guard currentIndex >= 0, currentIndex < queue.count else { return [] }
        return Array(queue[currentIndex..<min(queue.count, currentIndex + lookahead)])
    }
}

/// Which songs of the queue the listener has really played, for the set notes. The two lookups are the app's: the recording ids of songs
/// (the alias table) and which of them the listener's affinity says were heard. Never throws; a song it cannot place is simply not heard.
public enum SetNoteHistory {
    /// The identity request of a song, as the engine resolves it: a library row by its Spotify id and names, a song from outside the library
    /// by its video id and names.
    public static func request(of song: Song) -> TrackRequest? {
        let primary = BrainLibraryIndex.primaryArtistName(song)
        let nameKey = Ids.nameKey(primaryArtist: primary, rawTitle: song.title)
        if let video = TrackCatalog.videoId(ofSongId: song.id) {
            return TrackRequest(keys: Ids.TrackKeys(videoId: video, nameKey: nameKey), durationMs: Int32(clamping: max(song.duration, 0)))
        }
        guard let facts = TrackCatalog.facts(of: song) else { return nil }
        return TrackRequest(keys: facts.keys, durationMs: Int32(clamping: max(song.duration, 0)))
    }

    /// The ids of those of `songs` that have a recorded play. `ridsOf` returns one recording id per request (0: unknown); `heard` returns
    /// those of a set of recording ids that were played.
    public static func heardSongIds(_ songs: [Song], ridsOf: ([TrackRequest]) async -> [Int64],
                                    heard: (Set<Int64>) async -> Set<Int64>) async -> Set<String> {
        var requests: [TrackRequest] = []
        var owners: [String] = []
        for s in songs {
            guard let r = request(of: s) else { continue }
            requests.append(r)
            owners.append(s.id)
        }
        if requests.isEmpty { return [] }
        let rids = await ridsOf(requests)
        var ridOf: [String: Int64] = [:]
        for (i, owner) in owners.enumerated() where i < rids.count && rids[i] != 0 { ridOf[owner] = rids[i] }
        if ridOf.isEmpty { return [] }
        let heardRids = await heard(Set(ridOf.values))
        return Set(ridOf.filter { heardRids.contains($0.value) }.keys)
    }
}
