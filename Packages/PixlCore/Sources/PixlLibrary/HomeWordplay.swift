import Foundation

/// Home's wordplay (redesign batch 3; the port of Android `presentation/components/redesign/HomeWordplay.kt`): the greeting
/// and the section titles change with the time of day and with what the listener plays. The lines themselves live in the app
/// (`HomeWordplayStrings`, Android `strings_home_redesign.xml`); this only decides WHICH line, so it is pure and unit-tested.
///
/// Rules:
///  - Deterministic: the same day, the same time bucket and the same listening give the same line (no flicker on a re-render or a
///    new process).
///  - No repeats back to back: the line of one day is never the line of the day before in the same set (the step between two days is
///    never a multiple of the set's size). Two buckets of one day use different sets, so they never repeat either.
///  - Real data only: a streak needs a real top song with at least `streakMinPlays` plays this week.
public enum HomeWordplay {
    /// A song played at least this many times this week puts Home in the "on a streak" set.
    public static let streakMinPlays = 5

    public enum TimeBucket: Int, Sendable, CaseIterable { case morning, afternoon, evening, lateNight }

    /// The greeting's line sets: one per time bucket, plus the streak set that wins over them (Kotlin ordinals).
    public enum GreetingSet: Int, Sendable, CaseIterable { case morning, afternoon, evening, lateNight, streak }

    /// The section titles that rotate (Kotlin ordinals).
    public enum Section: Int, Sendable, CaseIterable { case mixes, recent, fresh }

    /// Morning 5-11, afternoon 12-16, evening 17-21, late night 22-4.
    public static func timeBucket(hour: Int) -> TimeBucket {
        switch floorMod(hour, 24) {
        case 5 ... 11: .morning
        case 12 ... 16: .afternoon
        case 17 ... 21: .evening
        default: .lateNight
        }
    }

    public static func greetingSet(hour: Int, topSongPlaysThisWeek: Int) -> GreetingSet {
        if topSongPlaysThisWeek >= streakMinPlays { return .streak }
        switch timeBucket(hour: hour) {
        case .morning: return .morning
        case .afternoon: return .afternoon
        case .evening: return .evening
        case .lateNight: return .lateNight
        }
    }

    /// One greeting: which set and which line of it.
    public struct Greeting: Sendable, Hashable {
        public let set: GreetingSet
        public let index: Int

        public init(set: GreetingSet, index: Int) {
            self.set = set
            self.index = index
        }
    }

    public static func greeting(epochDay: Int64, hour: Int, topSongPlaysThisWeek: Int, setSize: (GreetingSet) -> Int) -> Greeting {
        let set = greetingSet(hour: hour, topSongPlaysThisWeek: topSongPlaysThisWeek)
        return Greeting(set: set, index: rotate(epochDay: epochDay, size: setSize(set), salt: saltGreeting + set.rawValue))
    }

    public static func section(epochDay: Int64, _ section: Section, size: Int) -> Int {
        rotate(epochDay: epochDay, size: size, salt: saltSection + section.rawValue)
    }

    /// The sub line under the greeting (only shown with a real play count).
    public static func subLine(epochDay: Int64, size: Int) -> Int { rotate(epochDay: epochDay, size: size, salt: saltSub) }

    /// Index in 0 ..< size for `epochDay`: `(day * step + offset) mod size`, with a step in 1 ..< size coprime with the size, so
    /// consecutive days always differ and every line comes round. `salt` separates the sets so they do not move in lockstep.
    public static func rotate(epochDay: Int64, size: Int, salt: Int) -> Int {
        if size <= 1 { return 0 }
        let n = Int64(size)
        let step = stepFor(size: size, salt: salt)
        let offset = floorMod(Int64(salt) &* 7 &+ 3, n)
        // (day mod n) keeps the product small: the same residue as Kotlin's floorMod(day * step + offset, n) without overflow.
        return Int(floorMod(floorMod(epochDay, n) * step + offset, n))
    }

    /// The local calendar day of `date` (days since 1970-01-01 in `timeZone`), Android's
    /// `floorDiv(now + zoneOffset + dstOffset, 86_400_000)`.
    public static func epochDay(_ date: Date, timeZone: TimeZone = .current) -> Int64 {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        let offset = Int64(timeZone.secondsFromGMT(for: date)) * 1000
        let shifted = ms + offset
        let day: Int64 = 86_400_000
        return shifted >= 0 ? shifted / day : -((-shifted + day - 1) / day)
    }

    private static func stepFor(size: Int, salt: Int) -> Int64 {
        // Candidates 1 ..< size coprime with size; there is always at least one (1).
        var count = 0
        for s in 1 ..< size where gcd(s, size) == 1 { count += 1 }
        var pick = floorMod(salt, count)
        for s in 1 ..< size where gcd(s, size) == 1 {
            if pick == 0 { return Int64(s) }
            pick -= 1
        }
        return 1
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    private static func floorMod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }
    private static func floorMod(_ a: Int64, _ n: Int64) -> Int64 { ((a % n) + n) % n }

    private static let saltGreeting = 11
    private static let saltSection = 31
    private static let saltSub = 53
}
