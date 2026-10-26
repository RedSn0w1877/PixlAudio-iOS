// Explicit taste adjustments (Ask Taizo's taste changes, spec taizo-taste §2). The listener (or Taizo, at the listener's
// word) can say "more of this artist", "less of that genre", "never put this song in a mix". They sit ABOVE the learned
// signals in the recommendation engine: the engine's own scores are computed first and an adjustment then moves the
// taste term of the songs it targets, bounded and reversible.
//
//   boost / reduce  strength 1 / 2 / 3  →  ×1.25 / ×1.6 / ×2.2 (reduce: the inverse). All the factors that touch one song
//                   multiply, then the product is capped to 0.4 … 2.5, so nothing can run away.
//   mute            never in an auto-generated mix, shelf or candidate pool; still playable by hand.
//   block           the same, and Taizo's own play / queue / playlist tools leave the song out as well.
//
// With NO active adjustment the engine takes the exact same code path as before (a test proves it bit for bit).
// Nothing here ever deletes a song or any history.

import Foundation
import PixlFoundation
import PixlModel

// MARK: - Vocabulary

public enum TasteTargetType: String, Sendable, Hashable, Codable, CaseIterable {
    case artist, song, genre, album
}

/// What an active adjustment does.
public enum TasteAdjustmentKind: String, Sendable, Hashable, Codable {
    case boost, reduce, mute, block

    /// boost / reduce move the score; mute / block remove songs from the automatic picks.
    public var isWeight: Bool { self == .boost || self == .reduce }
}

/// What the tool (or the Settings list) asks for. `unmute` / `unblock` undo a mute / block.
public enum TasteAction: String, Sendable, Hashable, Codable, CaseIterable {
    case boost, reduce, mute, unmute, block, unblock
}

public enum TasteAdjustmentSource: String, Sendable, Hashable, Codable {
    case taizo, user
}

// MARK: - Keys

/// How a target is compared: folded (case, diacritics), letters and digits only, no spaces — "AC/DC" = "acdc",
/// "Hip-Hop" = "hip hop" = "hiphop", "Beyoncé" = "beyonce".
public enum TasteKey {
    public static func of(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in SearchFolding.fold(text).unicodeScalars
        where scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
            out.append(scalar)
        }
        return String(out)
    }

    /// `artist|title` of a recording: duplicates across sources share it.
    public static func recording(artist: String, title: String) -> String { "\(of(artist))|\(of(title))" }

    public static func recording(_ song: Song) -> String { recording(artist: song.artist, title: song.title) }

    /// The credited artists of a song as keys: the display string, each credited artist, and the parts of "A & B".
    public static func artists(_ song: Song) -> [String] {
        var keys: [String] = []
        func add(_ name: String) {
            let key = of(name)
            if !key.isEmpty, !keys.contains(key) { keys.append(key) }
        }
        add(song.artist)
        for part in credits(song.artist) { add(part) }
        for ref in song.artists { add(ref.name) }
        return keys
    }

    /// The genre as a key, plus its parts when several are listed ("Rock; Indie", "R&B/Soul").
    public static func genres(_ song: Song) -> [String] {
        guard let genre = song.genre else { return [] }
        var keys: [String] = []
        func add(_ name: String) {
            let key = of(name)
            if !key.isEmpty, key != "unknown", !keys.contains(key) { keys.append(key) }
        }
        add(genre)
        let parts = genre.split(whereSeparator: { ";,/".contains($0) })
        if parts.count > 1 { for part in parts { add(String(part)) } }
        return keys
    }

    public static func album(_ song: Song) -> String { of(song.album) }

    static let creditSeparators = [" & ", ", ", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " x ", " / ", "; ", " and "]

    /// "A feat. B & C" → ["A", "B", "C"]; a single artist → [].
    static func credits(_ artist: String) -> [String] {
        // Most artists are one name: skip the separator work for them (this runs for every song when ranking).
        let lower = artist.lowercased()
        guard lower.contains(",") || lower.contains("&") || lower.contains("/") || lower.contains(";") || lower.contains(" feat")
            || lower.contains(" ft") || lower.contains(" x ") || lower.contains(" and ") else { return [] }
        let marker = "\u{1F}"
        var text = artist
        for separator in creditSeparators {
            text = text.replacingOccurrences(of: separator, with: marker, options: .caseInsensitive)
        }
        let parts = text.components(separatedBy: marker).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.count > 1 ? parts : []
    }
}

// MARK: - One adjustment

public struct TasteAdjustment: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var kind: TasteAdjustmentKind
    /// 1…3 for boost / reduce; 0 for mute / block.
    public var strength: Int
    public var targetType: TasteTargetType
    /// The comparison key (`TasteKey`; for songs the recording key).
    public var key: String
    /// What the list shows: "Daft Punk", "Get Lucky — Daft Punk".
    public var label: String
    /// Shown to the listener (short).
    public var reason: String
    public var source: TasteAdjustmentSource
    public var createdMs: Int64
    /// nil = until removed.
    public var expiresMs: Int64?

    public init(kind: TasteAdjustmentKind, strength: Int, targetType: TasteTargetType, key: String, label: String,
                reason: String, source: TasteAdjustmentSource, createdMs: Int64, expiresMs: Int64? = nil) {
        self.id = Self.makeId(isWeight: kind.isWeight, targetType: targetType, key: key)
        self.kind = kind
        self.strength = kind.isWeight ? min(max(strength, 1), 3) : 0
        self.targetType = targetType
        self.key = key
        self.label = label
        self.reason = reason
        self.source = source
        self.createdMs = createdMs
        self.expiresMs = expiresMs
    }

    /// One adjustment per target and channel (weight or exclusion), so the id follows from them.
    static func makeId(isWeight: Bool, targetType: TasteTargetType, key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(isWeight ? "w" : "x")|\(targetType.rawValue)|\(key)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return "ta_" + String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    public func isActive(nowMs: Int64) -> Bool { expiresMs.map { $0 > nowMs } ?? true }

    /// The multiplier a boost / reduce stands for (1 for mute / block).
    public var factor: Double {
        switch kind {
        case .boost: TasteAdjustmentMath.factor(strength: strength)
        case .reduce: 1.0 / TasteAdjustmentMath.factor(strength: strength)
        case .mute, .block: 1.0
        }
    }
}

public enum TasteAdjustmentMath {
    /// Strength 1 / 2 / 3.
    public static let strengthFactors: [Double] = [1.25, 1.6, 2.2]
    /// One song's combined factor never leaves this band.
    public static let minFactor = 0.4
    public static let maxFactor = 2.5
    /// How much of ln(factor) is added to the taste term, so an artist with no history can still be lifted.
    public static let biasWeight = 1.0
    public static let maxReasonLength = 160

    public static func factor(strength: Int) -> Double { strengthFactors[min(max(strength, 1), 3) - 1] }

    /// The taste term (−1…1 in the engine) after the combined factor: positive taste grows with a boost and shrinks
    /// with a reduction, negative taste the other way round, and ln(factor) moves targets that have no taste yet.
    /// Strictly increasing in `factor` for a given taste, so "boost moves a song up, reduce moves it down" holds.
    public static func adjustedTaste(_ taste: Double, factor: Double) -> Double {
        if factor == 1.0 { return taste }
        let scaled = taste >= 0 ? taste * factor : taste / factor
        return scaled + biasWeight * log(factor)
    }
}

// MARK: - The stored list

/// What a change did.
public enum TasteChangeOutcome: Sendable, Hashable {
    /// Added or replaced (`replaced` = what it overwrote).
    case set(TasteAdjustment, replaced: TasteAdjustment?)
    /// `unmute` / `unblock`: this one went.
    case removed(TasteAdjustment)
    /// `unmute` / `unblock` on a target that was not muted / blocked.
    case nothingToRemove
    /// The list is at `TasteAdjustmentList.maxItems`.
    case listFull
}

/// One requested change (a `adjust_taste` entry, or a Settings action).
public struct TasteChange: Sendable, Hashable {
    public var action: TasteAction
    public var targetType: TasteTargetType
    public var key: String
    public var label: String
    public var strength: Int
    public var reason: String
    public var expiresDays: Int?
    public var source: TasteAdjustmentSource

    public init(action: TasteAction, targetType: TasteTargetType, key: String, label: String, strength: Int = 2,
                reason: String = "", expiresDays: Int? = nil, source: TasteAdjustmentSource = .taizo) {
        self.action = action
        self.targetType = targetType
        self.key = key
        self.label = label
        self.strength = strength
        self.reason = reason
        self.expiresDays = expiresDays
        self.source = source
    }
}

/// The persisted list. Pure value; `TasteAdjustmentStore` (app) loads and saves it.
public struct TasteAdjustmentList: Sendable, Hashable, Codable {
    public static let maxItems = 200
    public static let maxPerCall = 20
    /// More targets than this in one call ask the listener first.
    public static let confirmAbove = 5
    public static let maxExpiryDays = 365
    static let day: Int64 = 86_400_000

    public var items: [TasteAdjustment]

    public init(items: [TasteAdjustment] = []) { self.items = items }

    public static let empty = TasteAdjustmentList()

    /// The adjustments still in force, oldest first.
    public func active(nowMs: Int64) -> [TasteAdjustment] { items.filter { $0.isActive(nowMs: nowMs) } }

    /// The value the engine reads.
    public func set(nowMs: Int64) -> TasteAdjustmentSet { TasteAdjustmentSet(adjustments: items, nowMs: nowMs) }

    /// Drops the expired ones; true when something went.
    @discardableResult
    public mutating func prune(nowMs: Int64) -> Bool {
        let before = items.count
        items.removeAll { !$0.isActive(nowMs: nowMs) }
        return items.count != before
    }

    public static func cleanReason(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(TasteAdjustmentMath.maxReasonLength))
    }

    /// Applies one change. A boost / reduce replaces the target's earlier boost / reduce; a mute / block replaces its
    /// earlier mute / block (a block can be softened to a mute and the other way round). `unmute` / `unblock` remove
    /// only a mute / block.
    @discardableResult
    public mutating func apply(_ change: TasteChange, nowMs: Int64) -> TasteChangeOutcome {
        prune(nowMs: nowMs)
        let kind: TasteAdjustmentKind
        switch change.action {
        case .boost: kind = .boost
        case .reduce: kind = .reduce
        case .mute: kind = .mute
        case .block: kind = .block
        case .unmute, .unblock:
            let wanted: TasteAdjustmentKind = change.action == .unmute ? .mute : .block
            guard let index = items.firstIndex(where: {
                $0.targetType == change.targetType && $0.key == change.key && $0.kind == wanted
            }) else { return .nothingToRemove }
            return .removed(items.remove(at: index))
        }
        let isWeight = kind.isWeight
        let existing = items.firstIndex {
            $0.targetType == change.targetType && $0.key == change.key && $0.kind.isWeight == isWeight
        }
        if existing == nil, items.count >= Self.maxItems { return .listFull }
        let days = change.expiresDays.map { min(max($0, 1), Self.maxExpiryDays) }
        let adjustment = TasteAdjustment(
            kind: kind, strength: change.strength, targetType: change.targetType, key: change.key,
            label: change.label, reason: Self.cleanReason(change.reason), source: change.source, createdMs: nowMs,
            expiresMs: days.map { nowMs + Int64($0) * Self.day })
        if let existing {
            let replaced = items[existing]
            items[existing] = adjustment
            return .set(adjustment, replaced: replaced)
        }
        items.append(adjustment)
        return .set(adjustment, replaced: nil)
    }

    /// Removes one by id; true when it existed.
    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = items.count
        items.removeAll { $0.id == id }
        return items.count != before
    }

    /// Removes everything; returns how many went.
    @discardableResult
    public mutating func removeAll() -> Int {
        let count = items.count
        items = []
        return count
    }

    // MARK: Codec

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// An unreadable file is an empty list (the adjustments are a convenience, never a reason to fail a launch).
    public static func decode(_ data: Data) -> TasteAdjustmentList {
        (try? JSONDecoder().decode(TasteAdjustmentList.self, from: data)) ?? .empty
    }
}

// MARK: - What the engine reads

/// The active adjustments as lookup tables. `.empty` (and any set with nothing in force) leaves the engine untouched.
public struct TasteAdjustmentSet: Sendable, Hashable {
    private var factors: [String: Double] = [:]
    private var excluded: Set<String> = []
    private var blocked: Set<String> = []
    private var types: Set<TasteTargetType> = []

    public static let empty = TasteAdjustmentSet()

    public init() {}

    public init(adjustments: [TasteAdjustment], nowMs: Int64) {
        for adjustment in adjustments where adjustment.isActive(nowMs: nowMs) {
            let slot = Self.slot(adjustment.targetType, adjustment.key)
            types.insert(adjustment.targetType)
            switch adjustment.kind {
            case .boost, .reduce: factors[slot, default: 1.0] *= adjustment.factor
            case .mute: excluded.insert(slot)
            case .block:
                excluded.insert(slot)
                blocked.insert(slot)
            }
        }
    }

    public var isEmpty: Bool { factors.isEmpty && excluded.isEmpty }

    private static func slot(_ type: TasteTargetType, _ key: String) -> String { "\(type.rawValue):\(key)" }

    /// The combined factor, whether the song stays out of automatic picks, and whether it is blocked outright.
    public struct Evaluation: Sendable, Hashable {
        public var factor: Double
        public var isExcluded: Bool
        public var isBlocked: Bool

        public static let neutral = Evaluation(factor: 1.0, isExcluded: false, isBlocked: false)
    }

    public func evaluate(_ song: Song) -> Evaluation {
        if isEmpty { return .neutral }
        var factor = 1.0
        var isExcluded = false
        var isBlocked = false
        func visit(_ type: TasteTargetType, _ keys: [String]) {
            guard types.contains(type) else { return }
            for key in keys {
                let slot = Self.slot(type, key)
                if let value = factors[slot] { factor *= value }
                if excluded.contains(slot) { isExcluded = true }
                if blocked.contains(slot) { isBlocked = true }
            }
        }
        visit(.artist, types.contains(.artist) ? TasteKey.artists(song) : [])
        visit(.genre, types.contains(.genre) ? TasteKey.genres(song) : [])
        visit(.album, types.contains(.album) && !song.album.isEmpty ? [TasteKey.album(song)] : [])
        visit(.song, types.contains(.song) ? [TasteKey.recording(song)] : [])
        let capped = min(max(factor, TasteAdjustmentMath.minFactor), TasteAdjustmentMath.maxFactor)
        return Evaluation(factor: capped, isExcluded: isExcluded, isBlocked: isBlocked)
    }

    public func factor(for song: Song) -> Double { evaluate(song).factor }

    /// Muted or blocked: out of every automatic mix, shelf and candidate pool.
    public func isExcluded(_ song: Song) -> Bool { !excluded.isEmpty && evaluate(song).isExcluded }

    /// Blocked: also out of anything Taizo queues or plays on its own.
    public func isBlocked(_ song: Song) -> Bool { !blocked.isEmpty && evaluate(song).isBlocked }

    /// `songs` without the muted and blocked ones (the same array when nothing is).
    public func allowed(_ songs: [Song]) -> [Song] {
        excluded.isEmpty ? songs : songs.filter { !evaluate($0).isExcluded }
    }
}

// MARK: - Resolving what the listener named

/// The keys of a library, computed once per call (folding every artist and genre of a big library is the costly part
/// of resolving a target) and only for the kinds of target the call names.
public struct TasteLibraryKeys: Sendable {
    let artists: [[String]]
    let genres: [[String]]
    let albums: [String]

    public init(songs: [Song], types: Set<TasteTargetType>) {
        artists = types.contains(.artist) ? songs.map(TasteKey.artists) : []
        genres = types.contains(.genre) ? songs.map(TasteKey.genres) : []
        albums = types.contains(.album) ? songs.map(TasteKey.album) : []
    }
}

/// Turns the words (or ids) of a request into the key to store, against the library.
public enum TasteTargetResolver {
    public struct Resolved: Sendable, Hashable {
        public var type: TasteTargetType
        public var key: String
        public var label: String
        /// The library has songs for it (an artist the listener only knows from outside the library is allowed).
        public var inLibrary: Bool
        public var songCount: Int
    }

    public enum Failure: Error, Sendable, Hashable {
        case empty
        case noSuchSong(String)
        case noSuchGenre(String, known: [String])
        case noSuchAlbum(String)
        case ambiguous(String, candidates: [String])

        public var message: String {
            switch self {
            case .empty: "Name what to change."
            case .noSuchSong(let target): "No library song matches \"\(target)\". Search the library and pass a song id."
            case .noSuchGenre(let target, let known):
                "No genre like \"\(target)\" in the library. Genres: " + known.prefix(20).joined(separator: "; ")
            case .noSuchAlbum(let target): "No library album matches \"\(target)\"."
            case .ambiguous(let target, let candidates):
                "\"\(target)\" matches several: " + candidates.prefix(6).joined(separator: "; ") + ". Be more specific or use an id."
            }
        }
    }

    /// `target` is a library song id, a Spotify id (`spotify:track:…`), or the name as text. `keys` (from
    /// `TasteLibraryKeys`) saves refolding the library when several targets are resolved in one go.
    public static func resolve(type: TasteTargetType, target: String, songs: [Song],
                               keys: TasteLibraryKeys? = nil) -> Result<Resolved, Failure> {
        let text = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        let byId = songs.first { $0.id == text }
            ?? (text.hasPrefix("spotify:track:") ? songs.first { $0.spotifyId == String(text.dropFirst(14)) } : nil)
        let keys = keys ?? TasteLibraryKeys(songs: songs, types: [type])
        switch type {
        case .song:
            if let song = byId { return .success(resolvedSong(song)) }
            let key = TasteKey.of(text)
            // "title artist" / "title - artist" / "artist title": every word of the request is in the song.
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            var exact: [Song] = []
            var loose: [Song] = []
            var seen = Set<String>()
            for song in songs where seen.insert(TasteKey.recording(song)).inserted {
                let title = TasteKey.of(song.title)
                if title == key { exact.append(song); continue }
                let haystack = (song.title + " " + song.displayArtist).lowercased()
                if !words.isEmpty, words.allSatisfy({ haystack.contains($0) }) { loose.append(song) }
            }
            let found = exact.isEmpty ? loose : exact
            if found.count == 1 { return .success(resolvedSong(found[0])) }
            if found.isEmpty { return .failure(.noSuchSong(text)) }
            return .failure(.ambiguous(text, candidates: found.prefix(6).map { "\($0.title) — \($0.displayArtist) (\($0.id))" }))
        case .artist:
            // A song id names that song's (first) artist.
            let key: String
            let label: String
            if let song = byId {
                key = TasteKey.of(song.artist)
                label = song.artist
            } else {
                key = TasteKey.of(text)
                label = text
            }
            guard !key.isEmpty else { return .failure(.empty) }
            let count = keys.artists.reduce(0) { $0 + ($1.contains(key) ? 1 : 0) }
            return .success(Resolved(type: .artist, key: key, label: label, inLibrary: count > 0, songCount: count))
        case .genre:
            let key = byId.flatMap { TasteKey.genres($0).first } ?? TasteKey.of(text)
            guard !key.isEmpty else { return .failure(.empty) }
            var names: [String: Int] = [:]
            var display: [String: String] = [:]
            for (index, song) in songs.enumerated() {
                guard let genre = song.genre, !genre.isEmpty else { continue }
                for k in keys.genres[index] {
                    names[k, default: 0] += 1
                    if display[k] == nil { display[k] = genre }
                }
            }
            if let count = names[key] {
                return .success(Resolved(type: .genre, key: key, label: display[key] ?? text, inLibrary: true, songCount: count))
            }
            // "indie" finds "Indie Rock": a unique containing genre is that genre.
            let partial = names.keys.filter { $0.contains(key) || key.contains($0) }.sorted()
            if partial.count == 1, let only = partial.first {
                return .success(Resolved(type: .genre, key: only, label: display[only] ?? text, inLibrary: true,
                                         songCount: names[only] ?? 0))
            }
            let known = names.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.compactMap { display[$0.key] }
            return .failure(.noSuchGenre(text, known: known))
        case .album:
            let key = byId.map { TasteKey.album($0) } ?? TasteKey.of(text)
            guard !key.isEmpty else { return .failure(.empty) }
            var count = 0
            var label: String?
            for (index, song) in songs.enumerated() where !song.album.isEmpty && keys.albums[index] == key {
                count += 1
                if label == nil { label = song.album }
            }
            guard let label else { return .failure(.noSuchAlbum(text)) }
            return .success(Resolved(type: .album, key: key, label: label, inLibrary: true, songCount: count))
        }
    }

    private static func resolvedSong(_ song: Song) -> Resolved {
        Resolved(type: .song, key: TasteKey.recording(song), label: "\(song.title) — \(song.displayArtist)",
                 inLibrary: true, songCount: 1)
    }
}
