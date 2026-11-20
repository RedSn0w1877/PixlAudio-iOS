import PixlModel
import Testing
@testable import PixlLibrary

/// The search history's decisions (`SearchHistoryRules`): the key, the upsert, the cap, the typed-prefix suggestions, the
/// private rule and the merge. Android's twin runs the same cases with the same constants.
@Suite("Search history rules")
struct SearchHistoryRulesTests {
    private static let t0: Int64 = 1_760_000_000_000

    private func row(_ query: String, at t: Int64, count: Int = 1, kind: SearchHistoryKind? = nil) -> SearchHistoryItem {
        SearchHistoryItem(query: query, timestamp: t, key: BrainText.fold(query), kind: kind, count: count)
    }

    // MARK: Constants (the parity contract)

    @Test func theConstantsMatchTheContract() {
        #expect(SearchHistoryRules.minQueryLength == 2)
        #expect(SearchHistoryRules.maxQueryLength == 100)
        #expect(SearchHistoryRules.capacity == 50)
        #expect(SearchHistoryRules.suggestionLimit == 5)
        #expect(SearchHistoryRules.stripLimit == 10)
        #expect(SearchHistoryKind.allCases.map(\.rawValue) == ["query", "song", "album", "artist", "playlist"])
    }

    // MARK: Key folding

    @Test func keysFoldWithTheSharedBrainFold() {
        #expect(SearchHistoryRules.normalize("  Beyoncé  ")?.key == "beyonce")
        #expect(SearchHistoryRules.normalize("BEYONCE")?.key == "beyonce")
        #expect(SearchHistoryRules.normalize("  Beyoncé  ")?.query == "Beyoncé")
        // Punctuation folds to one space.
        #expect(SearchHistoryRules.normalize("AC/DC - Back In Black")?.key == "ac dc back in black")
    }

    @Test func vietnameseDiacriticsFoldComposedAndDecomposed() {
        let composed = "Sơn Tùng M-TP"
        let decomposed = "So\u{031B}\u{0301}n Tu\u{0300}ng M-TP".replacingOccurrences(of: "\u{031B}\u{0301}", with: "\u{031B}")
        #expect(SearchHistoryRules.normalize(composed)?.key == "son tung m tp")
        #expect(SearchHistoryRules.normalize("SON TUNG M-TP")?.key == "son tung m tp")
        #expect(SearchHistoryRules.normalize(decomposed)?.key == "son tung m tp")
        #expect(SearchHistoryRules.normalize("Đen Vâu")?.key == "den vau")
        #expect(SearchHistoryRules.normalize("đen vau")?.key == "den vau")
        #expect(SearchHistoryRules.normalize("Nguyễn Hữu Tiến")?.key == "nguyen huu tien")
    }

    @Test func tooShortOrEmptyFoldingTextIsNotStored() {
        #expect(SearchHistoryRules.normalize("a") == nil)
        #expect(SearchHistoryRules.normalize("  a  ") == nil)
        #expect(SearchHistoryRules.normalize("") == nil)
        #expect(SearchHistoryRules.normalize("   ") == nil)
        #expect(SearchHistoryRules.normalize("!!") == nil)
        #expect(SearchHistoryRules.normalize("ab")?.key == "ab")
        // Two units are enough even when the text is one scalar of two units.
        #expect(SearchHistoryRules.normalize("🎵")?.key == "🎵")
    }

    @Test func longTextIsCutTo100UnitsAndNeverInsideASurrogatePair() {
        let long = String(repeating: "a", count: 140)
        #expect(SearchHistoryRules.normalize(long)?.query.utf16.count == 100)
        // 99 letters, then a two-unit emoji straddling the limit: the emoji goes whole.
        let straddle = String(repeating: "b", count: 99) + "🎵" + "tail"
        let cut = SearchHistoryRules.normalize(straddle)?.query
        #expect(cut == String(repeating: "b", count: 99))
        // A trailing space after the cut is trimmed.
        let spaced = String(repeating: "c", count: 99) + " dddd"
        #expect(SearchHistoryRules.normalize(spaced)?.query == String(repeating: "c", count: 99))
    }

    // MARK: Upsert and de-dupe

    @Test func recordingTheSameKeyKeepsOneRowWithTheNewestTextAndACount() {
        var rows = SearchHistoryRules.record(into: [], SearchHistoryInput(query: "Beyonce"), isPrivate: false, now: Self.t0)
        rows = SearchHistoryRules.record(into: rows, SearchHistoryInput(query: "night"), isPrivate: false, now: Self.t0 + 1)
        rows = SearchHistoryRules.record(into: rows, SearchHistoryInput(query: "BEYONCÉ"), isPrivate: false, now: Self.t0 + 2)
        #expect(rows.map(\.query) == ["BEYONCÉ", "night"])
        #expect(rows.map(\.key) == ["beyonce", "night"])
        #expect(rows[0].count == 2)
        #expect(rows[0].timestamp == Self.t0 + 2)
        #expect(rows[1].count == 1)
    }

    @Test func vietnameseVariantsOfOneNameDeDupe() {
        var rows: [SearchHistoryItem] = []
        for (i, q) in ["Sơn Tùng", "son tung", "SƠN TÙNG", "Son Tung "].enumerated() {
            rows = SearchHistoryRules.record(into: rows, SearchHistoryInput(query: q), isPrivate: false, now: Self.t0 + Int64(i))
        }
        #expect(rows.count == 1)
        #expect(rows[0].count == 4)
        #expect(rows[0].query == "Son Tung")
    }

    @Test func aResultTapSetsTheKindAndTargetAndAPlainSubmitKeepsThem() {
        var rows = SearchHistoryRules.record(into: [], SearchHistoryInput(query: "taylor"), isPrivate: false, now: Self.t0)
        #expect(rows[0].kind == nil)
        rows = SearchHistoryRules.record(into: rows, SearchHistoryInput(query: "taylor", kind: .artist, targetId: "42",
                                                                       targetTitle: "Taylor Swift", imageUrl: "https://x/y.jpg"),
                                         isPrivate: false, now: Self.t0 + 1)
        #expect(rows.count == 1)
        #expect(rows[0].kind == .artist && rows[0].targetId == "42" && rows[0].targetTitle == "Taylor Swift")
        #expect(rows[0].imageUrl == "https://x/y.jpg")
        // Submitting the same text again does not wipe what was opened from it.
        rows = SearchHistoryRules.record(into: rows, SearchHistoryInput(query: "Taylor"), isPrivate: false, now: Self.t0 + 2)
        #expect(rows[0].kind == .artist && rows[0].targetTitle == "Taylor Swift")
        #expect(rows[0].count == 3)
        // Opening another result replaces it.
        rows = SearchHistoryRules.record(into: rows, SearchHistoryInput(query: "taylor", kind: .album, targetId: "7",
                                                                       targetTitle: "1989"), isPrivate: false, now: Self.t0 + 3)
        #expect(rows[0].kind == .album && rows[0].targetId == "7" && rows[0].imageUrl == nil)
    }

    @Test func unstorableTextChangesNothing() {
        let rows = [row("keep", at: Self.t0)]
        #expect(SearchHistoryRules.record(into: rows, SearchHistoryInput(query: "x"), isPrivate: false, now: Self.t0 + 1) == rows)
        #expect(SearchHistoryRules.record(into: rows, SearchHistoryInput(query: "  "), isPrivate: false, now: Self.t0 + 1) == rows)
    }

    // MARK: Cap

    @Test func theCapKeepsTheNewest50() {
        var rows: [SearchHistoryItem] = []
        for i in 0..<60 {
            rows = SearchHistoryRules.record(into: rows, SearchHistoryInput(query: "query \(i)"), isPrivate: false,
                                             now: Self.t0 + Int64(i))
        }
        #expect(rows.count == 50)
        #expect(rows.first?.query == "query 59")
        #expect(rows.last?.query == "query 10")
        // Using an old row again keeps it and drops the oldest instead.
        rows = SearchHistoryRules.record(into: rows, SearchHistoryInput(query: "query 10"), isPrivate: false, now: Self.t0 + 100)
        #expect(rows.count == 50 && rows.first?.query == "query 10" && rows.last?.query == "query 11")
    }

    @Test func trimmedAwayNamesTheOldestBeyondTheCap() {
        let rows = (0..<53).map { row("query \($0)", at: Self.t0 + Int64($0)) }
        let away = SearchHistoryRules.trimmedAway(rows)
        #expect(away.map(\.query) == ["query 2", "query 1", "query 0"])
        #expect(SearchHistoryRules.capped(rows).count == 50)
        #expect(SearchHistoryRules.trimmedAway(Array(rows.prefix(50))).isEmpty)
    }

    @Test func rowsOfOneTimestampKeepTheirOrder() {
        let rows = [row("alpha", at: 5), row("bravo", at: 5), row("charlie", at: 5)]
        #expect(SearchHistoryRules.capped(rows).map(\.query) == ["alpha", "bravo", "charlie"])
        #expect(SearchHistoryRules.recent(rows, limit: 2).map(\.query) == ["alpha", "bravo"])
    }

    // MARK: Suggestions

    @Test func suggestionsAreTheFoldedPrefixOrderedByCountThenNewest() {
        let rows = [
            row("Sơn Tùng", at: 10, count: 1),
            row("son goku", at: 30, count: 3),
            row("Songs for a rainy day", at: 20, count: 3),
            row("Taylor", at: 40, count: 9),
            row("Soulful", at: 50, count: 1),
            row("Sơn", at: 5, count: 1),
            row("sound of silence", at: 60, count: 1),
            row("Sonata", at: 70, count: 1),
        ]
        let found = SearchHistoryRules.suggestions(rows, typed: "SON")
        // "son", "son goku", "songs", "sonata", "son tung", "sound" is not a prefix match ("soun"). Count 3 first (newest first), then newest.
        #expect(found.map(\.query) == ["son goku", "Songs for a rainy day", "Sonata", "Sơn Tùng", "Sơn"])
        #expect(SearchHistoryRules.suggestions(rows, typed: "son", limit: 2).count == 2)
        #expect(SearchHistoryRules.suggestions(rows, typed: "SƠN TÙ").map(\.query) == ["Sơn Tùng"])
        #expect(SearchHistoryRules.suggestions(rows, typed: "zzz").isEmpty)
        #expect(SearchHistoryRules.suggestions(rows, typed: "").isEmpty)
        #expect(SearchHistoryRules.suggestions(rows, typed: "  ").isEmpty)
        #expect(SearchHistoryRules.suggestions(rows, typed: "??").isEmpty)
    }

    @Test func aTrailingSpaceInTheTypedTextStillMatches() {
        let rows = [row("taylor swift", at: 1)]
        #expect(SearchHistoryRules.suggestions(rows, typed: "taylor ").map(\.query) == ["taylor swift"])
    }

    // MARK: Private session

    @Test func privateSessionRecordsNothingAndBumpsNothing() {
        let rows = [row("keep", at: Self.t0, count: 2)]
        let after = SearchHistoryRules.record(into: rows, SearchHistoryInput(query: "keep"), isPrivate: true, now: Self.t0 + 9)
        #expect(after == rows)
        #expect(after[0].count == 2 && after[0].timestamp == Self.t0)
        let added = SearchHistoryRules.record(into: [], SearchHistoryInput(query: "secret", kind: .song, targetId: "1"),
                                              isPrivate: true, now: Self.t0)
        #expect(added.isEmpty)
        #expect(!SearchHistoryRules.shouldRecord(isPrivate: true) && SearchHistoryRules.shouldRecord(isPrivate: false))
    }

    // MARK: Merge (the backfill of old rows, restore)

    @Test func theBackfillMergesRowsSavedBeforeKeysExisted() {
        // Rows as the first schema saved them: an exact string each, no key, no count.
        let old = [
            SearchHistoryItem(query: "Beyonce", timestamp: 10),
            SearchHistoryItem(query: "BEYONCÉ", timestamp: 30),
            SearchHistoryItem(query: "night", timestamp: 20),
            SearchHistoryItem(query: "!!", timestamp: 40),
            SearchHistoryItem(query: "x", timestamp: 50),
        ]
        let merged = SearchHistoryRules.merged(old, with: [], counts: .sum)
        // The junk that folds to nothing goes; the one-letter row survives (existing rows are not held to the minimum).
        #expect(merged.map(\.query) == ["x", "BEYONCÉ", "night"])
        #expect(merged.map(\.key) == ["x", "beyonce", "night"])
        #expect(merged.first { $0.key == "beyonce" }?.count == 2)
        #expect(merged.first { $0.key == "beyonce" }?.timestamp == 30)
    }

    @Test func restoreMergesByKeyAndNeverClears() {
        let local = [row("local only", at: 100), row("Beyonce", at: 50, count: 3)]
        let backup = [SearchHistoryItem(query: "BEYONCÉ", timestamp: 40, count: 2), SearchHistoryItem(query: "from backup", timestamp: 60)]
        let merged = SearchHistoryRules.merged(local, with: backup, counts: .max)
        #expect(merged.map(\.query) == ["local only", "from backup", "Beyonce"])
        #expect(merged.first { $0.key == "beyonce" }?.count == 3)
        // Restoring the same backup again changes nothing (counts do not double).
        #expect(SearchHistoryRules.merged(merged, with: backup, counts: .max) == merged)
    }

    @Test func restoreCapsAt50WithoutDroppingTheNewest() {
        let local = (0..<40).map { row("local \($0)", at: 1000 + Int64($0)) }
        let backup = (0..<40).map { SearchHistoryItem(query: "backup \($0)", timestamp: Int64($0)) }
        let merged = SearchHistoryRules.merged(local, with: backup, counts: .max)
        #expect(merged.count == 50)
        #expect(merged.prefix(40).allSatisfy { $0.query.hasPrefix("local") })
    }

    @Test func mergeKeepsTheOpenedResultOfTheOlderRowWhenTheNewerHasNone() {
        let older = SearchHistoryItem(query: "taylor", timestamp: 1, kind: .artist, targetId: "9", targetTitle: "Taylor Swift")
        let newer = SearchHistoryItem(query: "Taylor", timestamp: 2)
        let merged = SearchHistoryRules.merged([older], with: [newer], counts: .max)
        #expect(merged.count == 1 && merged[0].query == "Taylor" && merged[0].kind == .artist && merged[0].targetId == "9")
    }

    @Test func aTypedKeyInAPayloadIsNeverTrusted() {
        let lying = SearchHistoryItem(query: "Beyonce", timestamp: 1, key: "something else")
        #expect(SearchHistoryRules.sanitized(lying)?.key == "beyonce")
        #expect(SearchHistoryRules.merged([], with: [lying], counts: .max).first?.key == "beyonce")
    }
}
