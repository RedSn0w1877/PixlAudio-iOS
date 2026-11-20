// The decisions of the search history, as pure functions (docs/handoff/2026-11-20-search-history.md). The app's
// SwiftData layer only loads the rows into `SearchHistoryItem`s, calls these, and writes the answer back, so everything
// that decides anything (the key, the upsert, the cap, the prefix filter, the private rule, the merge on restore) is
// tested here on Windows. Android's twin uses the same constants and the same `BrainText.fold` key, so a query
// folds to the same key on both apps (Vietnamese diacritics included).

import PixlModel

/// What one recorded search or opened result carries (the input of `SearchHistoryRules.record`).
public struct SearchHistoryInput: Sendable, Hashable {
    public var query: String
    public var kind: SearchHistoryKind?
    public var targetId: String?
    public var targetTitle: String?
    public var imageUrl: String?

    public init(query: String, kind: SearchHistoryKind? = nil, targetId: String? = nil, targetTitle: String? = nil,
                imageUrl: String? = nil) {
        self.query = query
        self.kind = kind
        self.targetId = targetId
        self.targetTitle = targetTitle
        self.imageUrl = imageUrl
    }
}

/// How two rows with one key add up their counts: a backfill of old duplicates adds them (two uses were two uses), a
/// restore takes the larger (restoring one backup twice must not double the counts).
public enum SearchHistoryCountMerge: Sendable {
    case sum
    case max
}

extension SearchHistoryItem {
    /// The kind a row opens, or nil for a plain typed search: a kind other than `query` with a target id that is not
    /// blank (Android `SearchHistoryItem.openKind`).
    public var openKind: SearchHistoryKind? {
        guard let kind, kind != .query, let targetId, !BrainText.trim(targetId).isEmpty else { return nil }
        return kind
    }

    /// What the row opens (`artist:42`), nil for a plain search: rows with the same one are the same thing.
    public var targetKey: String? {
        guard let kind = openKind, let targetId else { return nil }
        return "\(kind.rawValue):\(targetId)"
    }
}

public enum SearchHistoryRules {
    /// Shorter queries are not stored (the same two-character rule as the remote searches).
    public static let minQueryLength = 2
    /// Longer queries are cut to this many UTF-16 units (Kotlin's `String.take(100)`).
    public static let maxQueryLength = 100
    /// Rows kept: after every write the oldest rows beyond this are dropped.
    public static let capacity = 50
    /// Rows shown while typing, above the live results.
    public static let suggestionLimit = 5
    /// Tiles in the strip above the genre grid.
    public static let stripLimit = 10
    /// The name of an opened result is cut to this many UTF-16 units (Android `MAX_TARGET_TITLE_LENGTH`).
    public static let maxTargetTitleLength = 200
    /// A count read from a backup is held to this (a guard against a hand-edited file).
    public static let maxRestoredCount = 1_000_000

    /// The stored form of a typed text: trimmed, cut to `maxQueryLength`, and its folded key. nil when the text is too
    /// short to store (under `minQueryLength` after trimming) or folds to nothing (only punctuation).
    public static func normalize(_ raw: String) -> (query: String, key: String)? {
        guard let query = display(raw), query.utf16.count >= minQueryLength else { return nil }
        let key = BrainText.fold(query)
        if key.isEmpty { return nil }
        return (query, key)
    }

    /// `raw` trimmed and cut to `maxQueryLength` units (never in the middle of a surrogate pair), nil when blank.
    static func display(_ raw: String) -> String? {
        var text = BrainText.trim(raw)
        if text.isEmpty { return nil }
        if text.utf16.count > maxQueryLength { text = BrainText.trim(cutUnits(text, maxQueryLength)) }
        return text.isEmpty ? nil : text
    }

    /// `text` cut to `max` UTF-16 units, never in the middle of a surrogate pair (Android `cutUnits`).
    static func cutUnits(_ text: String, _ max: Int) -> String {
        guard text.utf16.count > max else { return text }
        var units = Array(text.utf16.prefix(max))
        if let last = units.last, last >= 0xD800, last <= 0xDBFF { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// What an opened result keeps of its name: trimmed and cut to `maxTargetTitleLength`.
    static func title(_ raw: String?) -> String? {
        raw.map { cutUnits(BrainText.trim($0), maxTargetTitleLength) }
    }

    /// The row with its key computed and its text normalised, or nil when it cannot be keyed. The minimum length is
    /// not applied: a row that already exists survives (it only has to fold to something).
    public static func sanitized(_ item: SearchHistoryItem) -> SearchHistoryItem? {
        guard let query = display(item.query) else { return nil }
        let key = BrainText.fold(query)
        if key.isEmpty { return nil }
        var out = item
        out.query = query
        out.key = key
        out.count = Swift.max(1, item.count)
        // A target only counts with a known kind and a target id (Android `toEntityOrNull`): anything else is a plain search.
        if let opened = item.openKind {
            out.kind = opened
            out.targetTitle = title(item.targetTitle)
        } else {
            out.kind = nil
            out.targetId = nil
            out.targetTitle = nil
            out.imageUrl = nil
        }
        return out
    }

    /// Whether a search is written at all: never during a private session.
    public static func shouldRecord(isPrivate: Bool) -> Bool { !isPrivate }

    /// `entries` (any order) with `input` recorded: the row of the same key is updated (newest text kept, timestamp
    /// bumped to `now`, count + 1, the opened result replaced when the input has one) or a new row is added; the rows
    /// come back newest first, trimmed to `capacity`. Unchanged (the same array) during a private session or when the
    /// text is not storable.
    public static func record(into entries: [SearchHistoryItem], _ input: SearchHistoryInput, isPrivate: Bool,
                              now: Int64) -> [SearchHistoryItem] {
        guard shouldRecord(isPrivate: isPrivate), let stored = normalize(input.query) else { return entries }
        var rows: [SearchHistoryItem] = []
        rows.reserveCapacity(entries.count + 1)
        var updated: SearchHistoryItem?
        for entry in entries {
            if updated == nil, entry.key == stored.key {
                updated = entry
            } else {
                rows.append(entry)
            }
        }
        var row = updated ?? SearchHistoryItem(query: stored.query, timestamp: now, key: stored.key, count: 0)
        row.query = stored.query
        row.key = stored.key
        row.timestamp = Swift.max(row.timestamp, now)
        row.count = Swift.max(0, row.count) + 1
        // Only a real target replaces the one already there; a plain submit (or a `query` kind) keeps it.
        let opened = SearchHistoryItem(query: stored.query, timestamp: now, kind: input.kind, targetId: input.targetId,
                                       targetTitle: input.targetTitle, imageUrl: input.imageUrl)
        if let kind = opened.openKind {
            row.kind = kind
            row.targetId = input.targetId
            row.targetTitle = title(input.targetTitle)
            row.imageUrl = input.imageUrl
        }
        return capped([row] + rows)
    }

    /// The rows newest first (a stable order: rows of one timestamp keep theirs), as (position, row) pairs.
    private static func newestFirst(_ entries: [SearchHistoryItem]) -> [(offset: Int, element: SearchHistoryItem)] {
        entries.enumerated().sorted { a, b in
            a.element.timestamp != b.element.timestamp ? a.element.timestamp > b.element.timestamp : a.offset < b.offset
        }
    }

    /// Newest first, at most `capacity` rows.
    public static func capped(_ entries: [SearchHistoryItem], capacity: Int = SearchHistoryRules.capacity) -> [SearchHistoryItem] {
        Array(newestFirst(entries).prefix(capacity).map(\.element))
    }

    /// The rows that go when `entries` is capped: the oldest ones beyond `capacity` (for a store that deletes them).
    public static func trimmedAway(_ entries: [SearchHistoryItem], capacity: Int = SearchHistoryRules.capacity) -> [SearchHistoryItem] {
        Array(newestFirst(entries).dropFirst(capacity).map(\.element))
    }

    /// The rows whose key starts with the folded `typed` text, most used first, then newest, at most `limit`. Nothing
    /// for a text that folds to nothing. Compared byte by byte on the folded UTF-8, as the keys are.
    public static func suggestions(_ entries: [SearchHistoryItem], typed: String,
                                   limit: Int = SearchHistoryRules.suggestionLimit) -> [SearchHistoryItem] {
        let prefix = BrainText.fold(typed)
        if prefix.isEmpty { return [] }
        let matches = entries.enumerated().filter { $0.element.key.utf8.starts(with: prefix.utf8) }
        let ordered = matches.sorted { a, b in
            if a.element.count != b.element.count { return a.element.count > b.element.count }
            if a.element.timestamp != b.element.timestamp { return a.element.timestamp > b.element.timestamp }
            return a.offset < b.offset
        }
        return Array(ordered.prefix(limit).map(\.element))
    }

    /// One row per thing opened (the strip and the list): the same artist reached from two typed searches is one tile,
    /// the newest of them. Rows that open nothing are all kept; the order is kept (Android `collapseByTarget`).
    public static func collapseByTarget(_ entries: [SearchHistoryItem]) -> [SearchHistoryItem] {
        var seen = Set<String>()
        return entries.filter { row in
            guard let target = row.targetKey else { return true }
            return seen.insert(target).inserted
        }
    }

    /// The rows of a backup as they will be merged (Android `toEntityOrNull` + the in-payload part of `mergeRestore`):
    /// a row without a storable text (under two characters, or only punctuation) is dropped, the key is recomputed, a
    /// target needs a known kind and a target id, the count is held to 1...1,000,000. Spellings of one key inside the
    /// payload add up, oldest first (they were separate uses): the newest text wins, the target of the newest row that
    /// has one, the latest time. Merging with the stored rows is `merged(_:with:counts:)`.
    public static func restoredRows(_ incoming: [SearchHistoryItem]) -> [SearchHistoryItem] {
        let ordered = incoming.enumerated().sorted { a, b in
            a.element.timestamp != b.element.timestamp ? a.element.timestamp < b.element.timestamp : a.offset < b.offset
        }
        var order: [String] = []
        var byKey: [String: SearchHistoryItem] = [:]
        for (_, raw) in ordered {
            guard normalize(raw.query) != nil, var row = sanitized(raw) else { continue }
            row.count = Swift.min(Swift.max(1, raw.count), maxRestoredCount)
            guard var before = byKey[row.key] else {
                order.append(row.key)
                byKey[row.key] = row
                continue
            }
            before.query = row.query
            before.timestamp = Swift.max(before.timestamp, row.timestamp)
            before.count += row.count
            if row.kind != nil {
                before.kind = row.kind
                before.targetId = row.targetId
                before.targetTitle = row.targetTitle
                before.imageUrl = row.imageUrl
            }
            byKey[row.key] = before
        }
        return order.compactMap { byKey[$0] }
    }

    /// The first `limit` rows, newest first (the strip, the recent list).
    public static func recent(_ entries: [SearchHistoryItem], limit: Int = SearchHistoryRules.capacity) -> [SearchHistoryItem] {
        capped(entries, capacity: limit)
    }

    /// `existing` and `incoming` merged by key (a backfill of rows saved before keys existed, a restore): rows that
    /// cannot be keyed are dropped; one row per key keeps the newest text and the newest opened result, the latest
    /// timestamp and the counts combined (`counts`); newest first, trimmed to `capacity`. Never clears: a key that is
    /// in `existing` stays unless the cap pushes it out as the oldest.
    public static func merged(_ existing: [SearchHistoryItem], with incoming: [SearchHistoryItem],
                              counts: SearchHistoryCountMerge) -> [SearchHistoryItem] {
        var order: [String] = []
        var byKey: [String: SearchHistoryItem] = [:]
        for raw in existing + incoming {
            guard let item = sanitized(raw) else { continue }
            guard let row = byKey[item.key] else {
                order.append(item.key)
                byKey[item.key] = item
                continue
            }
            let itemIsNewer = item.timestamp > row.timestamp
            let older = itemIsNewer ? row : item
            var out = itemIsNewer ? item : row
            if out.kind == nil {
                out.kind = older.kind
                out.targetId = older.targetId
                out.targetTitle = older.targetTitle
                out.imageUrl = older.imageUrl
            }
            if out.id == nil { out.id = older.id }
            switch counts {
            case .sum: out.count = row.count + item.count
            case .max: out.count = Swift.max(row.count, item.count)
            }
            byKey[item.key] = out
        }
        return capped(order.compactMap { byKey[$0] })
    }
}
