// The weekly note on First Listen (docs/brain-spec.md, 9.3 and 9.4, stage 4 milestone 2): two or three sentences about this week's list. A port
// of Android's `WeeklyNoteRepository`.
//
// ONE cloud call a week, over a few evidence rows (`WeeklyNote.Evidence`), only when the assistant's own consent and switches allow it
// (`mayAsk`: the automatic route, a connection, the monthly budget). Never at app start (it runs when the list is opened), never offline (the
// call is not even attempted, and not counted as the week's), and when it does not run, or its answer is not clearly true of the evidence
// (`WeeklyNote.check`), the template is shown instead. The answer is kept for the week, so reopening the list asks for nothing.
//
// Nothing about the listener leaves the phone except the evidence rows: counts, the first three artists of the list and one genre name.

import Foundation
import PixlModel

public actor WeeklyNoteService {
    public static let fileName = "weekly_note.json"
    public static let maxTokens = 320

    /// The instruction. It never names the vendor or the model; the evidence rows follow as the user turn.
    public static let system = """
        You write one short note for the top of a music app's weekly list called First Listen.
        Write two or three plain sentences in the second person, sentence case, at most 400 characters in all.
        Use only the facts in the evidence rows you are given. Do not add any number, name, genre or claim that is not in them.
        Put [[double square brackets]] around every artist name and every genre name you write.
        Do not use lists, headings, emoji or the words learn, learned or learning. Do not mention any company or product.
        If a row is missing, say nothing about it.
        """

    /// What is kept between opens of the list.
    public struct Stored: Codable, Sendable, Equatable {
        /// The week's list (its `builtAtMs`): a new list is a new week.
        public var week: Int64 = 0
        /// The cloud call of this week was made (or tried): no second one.
        public var asked = false
        public var cloudHash: Int64 = 0
        public var cloudText = ""

        public init(week: Int64 = 0, asked: Bool = false, cloudHash: Int64 = 0, cloudText: String = "") {
            self.week = week
            self.asked = asked
            self.cloudHash = cloudHash
            self.cloudText = cloudText
        }
    }

    private let file: URL?
    private let mayAsk: @Sendable () async -> Bool
    private let ask: @Sendable (_ system: String, _ prompt: String, _ maxTokens: Int) async -> String?

    /// `file` is nil in tests that keep nothing. `mayAsk` is the route, the connection and the budget; `ask` is the one call.
    public init(file: URL?, mayAsk: @escaping @Sendable () async -> Bool,
                ask: @escaping @Sendable (_ system: String, _ prompt: String, _ maxTokens: Int) async -> String?) {
        self.file = file
        self.mayAsk = mayAsk
        self.ask = ask
    }

    /// The note to show for this week's First Listen, or nil when there is nothing true to say. Off the main actor.
    public func note(for evidence: WeeklyNote.Evidence, week: Int64) async -> String? {
        let template = WeeklyNote.template(evidence)
        if template.isEmpty { return nil }
        let hash = WeeklyNote.evidenceHash(evidence)
        var stored = read().flatMap { $0.week == week ? $0 : nil } ?? Stored(week: week)
        if !stored.cloudText.isEmpty && stored.cloudHash == hash { return stored.cloudText }
        if !stored.asked, await mayAsk() {
            // Counted before the call: a crash or a double tap cannot make a second one this week.
            stored = Stored(week: week, asked: true)
            write(stored)
            if let text = await cloud(evidence) {
                stored = Stored(week: week, asked: true, cloudHash: hash, cloudText: text)
                write(stored)
                return text
            }
        }
        return template
    }

    private func cloud(_ evidence: WeeklyNote.Evidence) async -> String? {
        guard let answer = await ask(Self.system, WeeklyNote.evidenceLines(evidence), Self.maxTokens) else { return nil }
        return WeeklyNote.check(answer, evidence)
    }

    private func read() -> Stored? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private func write(_ stored: Stored) {
        guard let file, let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: file, options: [.atomic])
    }
}

/// What First Listen's note is told about the list: from the list itself and Your sound's novelty figure (Android deviation 229).
public enum WeeklyNoteEvidence {
    /// The first three distinct artists of the list, in order.
    public static func artists(of songs: [Song]) -> [String] {
        var out: [String] = []
        for s in songs {
            let a = BrainFeedback.artistOf(s)
            if !a.isEmpty && !out.contains(where: { KotlinText.equals($0, a) }) { out.append(a) }
            if out.count == 3 { break }
        }
        return out
    }

    /// The recordings of the list's adjacent-genre picks (the reason "adjacent_genre").
    public static func adjacentRids(_ view: MixView) -> [Int64] {
        var seen = Set<Int64>()
        var out: [Int64] = []
        for s in view.songs where view.reasons[s.id]?.key == "adjacent_genre" {
            if let rid = view.rids[s.id], seen.insert(rid).inserted { out.append(rid) }
        }
        return out
    }

    /// The genre most of `topTagIds` name, ties to the lower atlas id; `GenreAtlas.none` for none.
    public static func mostVoted(_ topTagIds: [Int]) -> Int {
        var votes: [Int: Int] = [:]
        for id in topTagIds { votes[id, default: 0] += 1 }
        return votes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.first?.key ?? GenreAtlas.none
    }

    /// The evidence of a list, or nil for an empty one. `genre` is "" when none is known: nothing is guessed. `newSharePct` is -1 when unknown.
    public static func of(_ view: MixView, genre: String, newSharePct: Int) -> WeeklyNote.Evidence? {
        if view.songs.isEmpty { return nil }
        return WeeklyNote.Evidence(tracks: view.songs.count, newSongs: view.novelIds.count, artists: artists(of: view.songs), genre: genre,
                                   island: "", newSharePct: newSharePct)
    }
}

/// First Listen's note for a list: the evidence from the brain's own tables, then the service. Built from the parts the app already has.
public struct FirstListenNote: Sendable {
    private let service: WeeklyNoteService
    private let parts: Stage2bParts?
    private let yourSound: YourSoundReader?

    public init(service: WeeklyNoteService, parts: Stage2bParts?, yourSound: YourSoundReader?) {
        self.service = service
        self.parts = parts
        self.yourSound = yourSound
    }

    /// The note for `view` (First Listen only), or nil. Off the main actor; never throws.
    public func note(for view: MixView) async -> String? {
        guard view.kind == MixKinds.firstListen else { return nil }
        var share = -1
        if let novelty = await yourSound?.load().novelty { share = (novelty.permille + 5) / 10 }
        let genre = await adjacentGenre(of: view)
        guard let evidence = WeeklyNoteEvidence.of(view, genre: genre, newSharePct: share) else { return nil }
        return await service.note(for: evidence, week: view.builtAtMs)
    }

    /// The genre most of the list's adjacent-genre picks are tagged with, or "" when none is: nothing is guessed.
    private func adjacentGenre(of view: MixView) async -> String {
        let rids = WeeklyNoteEvidence.adjacentRids(view)
        guard !rids.isEmpty, let dna = parts?.dna, let atlas = await parts?.atlas.atlas() else { return "" }
        var tops: [Int] = []
        for rid in rids {
            guard let row = await dna.track(rid) else { continue }
            let v = row.tagVector
            if let top = v.tags.max(by: { $0.q < $1.q }) { tops.append(top.atlasId) }
        }
        let best = WeeklyNoteEvidence.mostVoted(tops)
        return best == GenreAtlas.none ? "" : (atlas.genre(best)?.name ?? "")
    }
}
