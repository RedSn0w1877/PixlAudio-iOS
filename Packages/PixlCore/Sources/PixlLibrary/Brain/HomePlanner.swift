// The Home page rules (docs/brain-spec.md, 8.1, stage 2), in pure logic: which shelves the page shows, in what order,
// with which items. The shelves arrive already built (each from its own arm and surface) in the fixed order of the
// table in 8.1; this decides what the page can hold. A transliteration of the Android `:brain` module's
// `HomePlanner.kt`.
//
// Page rules:
//  - a track appears once on the page;
//  - an artist at most twice per shelf and four times per page;
//  - two all-novel shelves are never adjacent;
//  - at least one familiar shelf sits in the first three shelf slots (slots 4 to 6 of the page: the hero, the ask pill
//    and Jump back in come first);
//  - a shelf with too few playable items is hidden, not padded;
//  - at most seven shelves.
//
// The order of the shelves is fixed in stage 2; the bandit that would reorder them is stage 3.

public enum HomePlanner {
    // Shelf types, in the fixed order of the table in 8.1.
    public static let madeForYou: Int32 = 0
    public static let becauseListened: Int32 = 1
    public static let newFromLoved: Int32 = 2
    public static let onRepeat: Int32 = 3
    public static let rediscover: Int32 = 4
    public static let stations: Int32 = 5
    public static let stepSideways: Int32 = 6
    public static let moreLikeAlbum: Int32 = 7
    public static let popular: Int32 = 8

    public static let maxShelves = 7
    public static let itemsPerShelf = 12

    /// A shelf of tracks needs this many playable items to be shown (8.1).
    public static let minTracks = 6

    /// A shelf of cards (mixes, stations) needs this many cards: each card is itself a list of playable music.
    public static let minMixCards = 1
    public static let minStationCards = 4

    public static let artistPerShelf = 2
    public static let artistPerPage = 4

    // Hero kinds.
    public static let heroNone: Int32 = 0
    public static let heroFirstListen: Int32 = 1
    public static let heroRelease: Int32 = 2
    public static let heroDaily: Int32 = 3

    public static func isCardShelf(_ type: Int32) -> Bool { type == madeForYou || type == stations }

    /// The shelves whose music is all new to the listener (novel share 1 in 8.1).
    public static func isAllNovel(_ type: Int32) -> Bool { type == newFromLoved || type == stepSideways || type == popular }

    public static func minItems(_ type: Int32) -> Int {
        switch type {
        case madeForYou: return minMixCards
        case stations: return minStationCards
        default: return minTracks
        }
    }

    /// One card or track of a shelf. `key` is whatever the caller needs to find the item again (an index into its own table).
    public struct Item: Sendable, Equatable {
        public let rid: Int64
        public let aid: Int64
        public let key: Int

        public init(rid: Int64, aid: Int64, key: Int) {
            self.rid = rid; self.aid = aid; self.key = key
        }
    }

    public struct ShelfIn: Sendable {
        public let type: Int32
        /// Tells two shelves of one type apart ("Because you listened to X" has up to two); free text for the caller.
        public let id: String
        public let items: [Item]

        public init(type: Int32, id: String, items: [Item]) {
            self.type = type; self.id = id; self.items = items
        }
    }

    public struct Shelf: Sendable {
        public let type: Int32
        public let id: String
        public let items: [Item]
    }

    private struct ShelfKey: Hashable {
        let type: Int32
        let id: BrainKey
    }

    /// Applies the page rules to `shelves` (given in the fixed order) and returns the shelves the page shows.
    public static func plan(_ shelves: [ShelfIn]) -> [Shelf] {
        // 1. Viable shelves by their raw count; the order is fixed.
        var order: [ShelfIn] = shelves.filter { $0.items.count >= minItems($0.type) }
        // 2. Order rules, then the item rules in that order; a shelf that ends too small leaves, and the order rules run again.
        var result: [Shelf] = []
        var rounds = 0
        while rounds <= shelves.count + 1 {
            order = arrangeOrder(order)
            var shown: [Shelf] = []
            shown.reserveCapacity(order.count)
            var pageRids = Set<Int64>()
            var pageArtists: [Int64: Int] = [:]
            var dropped = 0
            for s in order {
                if shown.count >= maxShelves {
                    dropped += 1
                    continue
                }
                let items = filterItems(s, pageRids, pageArtists)
                if items.count < minItems(s.type) {
                    dropped += 1
                    continue
                }
                if !isCardShelf(s.type) {
                    for item in items {
                        pageRids.insert(item.rid)
                        if item.aid != 0 { pageArtists[item.aid] = (pageArtists[item.aid] ?? 0) + 1 }
                    }
                }
                shown.append(Shelf(type: s.type, id: s.id, items: items))
            }
            result = shown
            if dropped == 0 { break }
            var keep = Set<ShelfKey>()
            for s in shown { keep.insert(ShelfKey(type: s.type, id: BrainKey(s.id))) }
            order = order.filter { keep.contains(ShelfKey(type: $0.type, id: BrainKey($0.id))) }
            rounds += 1
        }
        return result
    }

    private static func filterItems(_ shelf: ShelfIn, _ pageRids: Set<Int64>, _ pageArtists: [Int64: Int]) -> [Item] {
        if isCardShelf(shelf.type) {
            let n = shelf.items.count < itemsPerShelf ? shelf.items.count : itemsPerShelf
            return Array(shelf.items[0..<n])
        }
        var out: [Item] = []
        out.reserveCapacity(itemsPerShelf)
        var shelfArtists: [Int64: Int] = [:]
        var seen = Set<Int64>()
        for item in shelf.items {
            if out.count >= itemsPerShelf { break }
            if item.rid == 0 || pageRids.contains(item.rid) || !seen.insert(item.rid).inserted { continue }
            if item.aid != 0 {
                if (shelfArtists[item.aid] ?? 0) >= artistPerShelf { continue }
                if (pageArtists[item.aid] ?? 0) + (shelfArtists[item.aid] ?? 0) >= artistPerPage { continue }
                shelfArtists[item.aid] = (shelfArtists[item.aid] ?? 0) + 1
            }
            out.append(item)
        }
        return out
    }

    /// The order rules: no two all-novel shelves side by side (the next familiar shelf is pulled forward, or the
    /// all-novel shelf leaves when none is left) and a familiar shelf among the first three.
    private static func arrangeOrder(_ input: [ShelfIn]) -> [ShelfIn] {
        var order = input
        // A familiar shelf in the first three slots: pull the first one forward when they are all new.
        let firstThree = order.count < 3 ? order.count : 3
        var anyFamiliarFirst = false
        for i in 0..<firstThree where !isAllNovel(order[i].type) { anyFamiliarFirst = true }
        if !anyFamiliarFirst {
            var j = firstThree
            while j < order.count {
                if !isAllNovel(order[j].type) {
                    let s = order.remove(at: j)
                    order.insert(s, at: 0)
                    break
                }
                j += 1
            }
        }
        var i = 1
        while i < order.count {
            if isAllNovel(order[i].type) && isAllNovel(order[i - 1].type) {
                var j = i + 1
                while j < order.count && isAllNovel(order[j].type) { j += 1 }
                if j < order.count {
                    let s = order.remove(at: j)
                    order.insert(s, at: i)
                } else {
                    order.remove(at: i)
                    continue
                }
            }
            i += 1
        }
        return order
    }

    // MARK: The hero, the date line

    public static let daypartMorning: Int32 = 0
    public static let daypartAfternoon: Int32 = 1
    public static let daypartEvening: Int32 = 2
    public static let daypartNight: Int32 = 3

    /// Morning 05-12, afternoon 12-17, evening 17-22, night otherwise, by the listener's local hour.
    public static func daypart(nowMs: Int64, tzOffsetMin: Int32) -> Int32 {
        let hour = BrainMath.floorMod(BrainMath.floorDiv(nowMs &+ Int64(tzOffsetMin) &* 60_000, 3_600_000), 24)
        if hour >= 5 && hour < 12 { return daypartMorning }
        if hour >= 12 && hour < 17 { return daypartAfternoon }
        if hour >= 17 && hour < 22 { return daypartEvening }
        return daypartNight
    }

    /// Monday is 0 (see `BrainMath.weekday`).
    public static func weekday(nowMs: Int64, tzOffsetMin: Int32) -> Int32 {
        BrainMath.weekday(BrainMath.localDay(nowMs, tzOffsetMin: tzOffsetMin))
    }

    /// The plan is rebuilt when this changes: the local day (it starts at 04:00) and the daypart.
    public static func planKey(nowMs: Int64, tzOffsetMin: Int32) -> Int64 {
        Repetition.mixDay(nowMs, tzOffsetMin: tzOffsetMin) &* 4 &+ Int64(daypart(nowMs: nowMs, tzOffsetMin: tzOffsetMin))
    }

    public struct Hero: Sendable, Equatable {
        public let kind: Int32
        /// Index of the Daily Mix for `heroDaily`; 0 otherwise.
        public let index: Int
    }

    /// The hero (8.1 slot 1): First Listen on Mondays, else a new release from a top-5 artist, else one of the Daily
    /// Mixes (rotating at each daypart boundary).
    public static func hero(hasFirstListen: Bool, hasTopRelease: Bool, dailyCount: Int, nowMs: Int64,
                            tzOffsetMin: Int32, salt: Int64) -> Hero {
        let monday = weekday(nowMs: nowMs &- 4 &* 3_600_000, tzOffsetMin: tzOffsetMin) == 0
        if hasFirstListen && monday { return Hero(kind: heroFirstListen, index: 0) }
        if hasTopRelease { return Hero(kind: heroRelease, index: 0) }
        if dailyCount > 0 {
            let h = BrainHash.splitmix64(UInt64(bitPattern: salt ^ planKey(nowMs: nowMs, tzOffsetMin: tzOffsetMin)))
            return Hero(kind: heroDaily, index: Int(h % UInt64(dailyCount)))
        }
        if hasFirstListen { return Hero(kind: heroFirstListen, index: 0) }
        return Hero(kind: heroNone, index: 0)
    }

    /// The "Jump back in" tiles: the first `count` distinct contexts of `keys`, newest first.
    public static func distinctContexts(_ keys: [String], count: Int) -> [Int] {
        var seen = Set<BrainKey>()
        var out: [Int] = []
        out.reserveCapacity(count)
        for i in 0..<keys.count {
            if out.count >= count { break }
            if seen.insert(BrainKey(keys[i])).inserted { out.append(i) }
        }
        return out
    }
}
