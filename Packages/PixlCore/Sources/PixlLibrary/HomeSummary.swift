// The short, contextual summary at the top of Home (owner decision 2026-10-26): a one-line headline and a one-line
// subtitle that read like someone glanced at your day, never a statistic. Everything that decides the words lives
// here, as plain values in and plain strings out, so it is tested without the app:
// - the local headline / subtitle / insight (also the fallback whenever the AI assistant has no answer),
// - the prompts the assistant gets (no totals in them, so it has nothing to count aloud),
// - `clean`, which cuts an assistant's answer to length on a word boundary and refuses stat phrasing
//   ("340 plays across 490 songs in your library" and its relatives).

import Foundation

/// What the summary may talk about. Everything optional is simply left out of the sentence when it is missing.
public struct HomeSummaryFacts: Sendable, Equatable {
    /// Local hour of day, 0...23.
    public var hour: Int
    /// 0 = Monday ... 6 = Sunday.
    public var weekday: Int
    /// Days since 1970 in the listener's time zone: the seed that rotates wording from one day to the next.
    public var epochDay: Int64
    public var topArtist: String?
    public var topGenre: String?
    /// The most recent play, and how long ago it ended.
    public var lastPlayedTitle: String?
    public var lastPlayedArtist: String?
    public var lastPlayedMinutesAgo: Int?
    /// Consecutive days with listening, counting today (or yesterday, when today has none yet).
    public var streakDays: Int
    /// The newest song added to the library lately, when there is one.
    public var freshSongTitle: String?
    public var freshSongArtist: String?
    /// The library has songs at all (an empty library gets the plain invitation).
    public var hasLibrary: Bool

    public init(hour: Int = 12, weekday: Int = 0, epochDay: Int64 = 0, topArtist: String? = nil, topGenre: String? = nil,
                lastPlayedTitle: String? = nil, lastPlayedArtist: String? = nil, lastPlayedMinutesAgo: Int? = nil,
                streakDays: Int = 0, freshSongTitle: String? = nil, freshSongArtist: String? = nil, hasLibrary: Bool = true) {
        self.hour = hour
        self.weekday = weekday
        self.epochDay = epochDay
        self.topArtist = topArtist
        self.topGenre = topGenre
        self.lastPlayedTitle = lastPlayedTitle
        self.lastPlayedArtist = lastPlayedArtist
        self.lastPlayedMinutesAgo = lastPlayedMinutesAgo
        self.streakDays = streakDays
        self.freshSongTitle = freshSongTitle
        self.freshSongArtist = freshSongArtist
        self.hasLibrary = hasLibrary
    }
}

public enum HomeSummary {
    /// The headline has to fit one line of the Home card next to its chevron.
    public static let headlineLimit = 30
    /// The longest assistant headline kept (cut on a word boundary); the card scales its text down a little to fit it.
    public static let headlineHardLimit = 38
    /// The subtitle is one line of body text.
    public static let subtitleLimit = 44
    /// The expandable insight: a couple of short sentences.
    public static let insightLimit = 320

    /// What the card says before there is anything to say.
    public static let invitation = "Let's find your next favorite song."

    // MARK: Time

    /// morning 5-10, afternoon 11-16, evening 17-21, else night.
    public static func dayPhase(hour: Int) -> String {
        switch hour {
        case 5...10: "morning"
        case 11...16: "afternoon"
        case 17...21: "evening"
        default: "night"
        }
    }

    public static func weekdayName(_ weekday: Int) -> String {
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        return names[((weekday % 7) + 7) % 7]
    }

    /// 0 = Monday for a day count since 1970 (1970-01-01 was a Thursday).
    public static func weekday(epochDay: Int64) -> Int {
        Int(((epochDay + 3) % 7 + 7) % 7)
    }

    public static func salutation(hour: Int) -> String {
        switch dayPhase(hour: hour) {
        case "morning": "Good morning"
        case "afternoon": "Good afternoon"
        case "evening": "Good evening"
        default: "Still up?"
        }
    }

    /// A song added within `days` days. `dateAdded` is milliseconds for songs imported by the app and seconds for
    /// ones a media store stamped (Android's MediaStore): anything below 10^11 counts as seconds.
    public static func isFresh(dateAdded: Int64, nowMs: Int64, days: Int = 14) -> Bool {
        guard dateAdded > 0 else { return false }
        let addedMs = dateAdded < 100_000_000_000 ? dateAdded * 1000 : dateAdded
        let age = nowMs - addedMs
        return age >= 0 && age <= Int64(days) * 86_400_000
    }

    /// Consecutive listening days ending today, or ending yesterday when today has no play yet. Days are epoch days.
    public static func streakDays(playDays: Set<Int64>, today: Int64) -> Int {
        var day = playDays.contains(today) ? today : today - 1
        var count = 0
        while playDays.contains(day) {
            count += 1
            day -= 1
        }
        return count
    }

    // MARK: Local texts

    /// One short line: a greeting, sometimes with a nod to what you have been playing or to the day itself.
    public static func headline(_ facts: HomeSummaryFacts) -> String {
        let hello = salutation(hour: facts.hour)
        guard facts.hasLibrary else { return hello }
        var options: [String] = [hello]
        if let artist = nonEmpty(facts.topArtist), artist.count <= 12 {
            options.append("\(hello) — more \(artist)?")
        }
        if let genre = nonEmpty(facts.topGenre), genre.count <= 12 {
            options.append("\(hello) — some \(genre)?")
        }
        if let day = dayLine(facts) { options.append(day) }
        let fitting = options.filter { $0.count <= headlineLimit }
        guard !fitting.isEmpty else { return hello }
        return fitting[Int(((facts.epochDay % Int64(fitting.count)) + Int64(fitting.count)) % Int64(fitting.count))]
    }

    /// A line for a moment of the week that deserves one (nil: nothing special).
    static func dayLine(_ facts: HomeSummaryFacts) -> String? {
        let phase = dayPhase(hour: facts.hour)
        switch (facts.weekday, phase) {
        case (0, "morning"): return "Monday morning. Let's go."
        case (4, "evening"), (4, "night"): return "Friday night. Make it count."
        case (5, "morning"), (6, "morning"): return "Slow weekend morning."
        case (6, "evening"): return "Sunday evening, nice and easy."
        default: return nil
        }
    }

    /// One short line about right now: what just played, a streak, something new, what you keep coming back to.
    public static func subtitle(_ facts: HomeSummaryFacts) -> String {
        guard facts.hasLibrary else { return invitation }
        var candidates: [String?] = []
        if let title = nonEmpty(facts.lastPlayedTitle), let ago = facts.lastPlayedMinutesAgo {
            if ago <= 45 {
                candidates.append(fit("Just played ", title, ""))
            } else if ago <= 360 {
                candidates.append(fit("Earlier: ", title, ""))
            }
        }
        if facts.streakDays >= 3 { candidates.append("\(facts.streakDays) days in a row. Keep it rolling.") }
        if let title = nonEmpty(facts.freshSongTitle) { candidates.append(fit("New to try: ", title, "")) }
        if let artist = nonEmpty(facts.topArtist) { candidates.append(fit("", artist, " has been on repeat")) }
        if let genre = nonEmpty(facts.topGenre) { candidates.append(fit("Leaning ", genre, " lately")) }
        return candidates.compactMap { $0 }.first { $0.count <= subtitleLimit } ?? invitation
    }

    /// The expanded card's text when no assistant answers: what you keep playing and what to try, in plain words.
    public static func insight(_ facts: HomeSummaryFacts) -> String {
        guard facts.hasLibrary else { return "Play a few songs and this fills in with what you like." }
        var sentences: [String] = []
        switch (nonEmpty(facts.topArtist), nonEmpty(facts.topGenre)) {
        case let (artist?, genre?): sentences.append("\(artist) has been on repeat, and \(genre) keeps coming back.")
        case let (artist?, nil): sentences.append("\(artist) has been on repeat lately.")
        case let (nil, genre?): sentences.append("You have been leaning \(genre) lately.")
        case (nil, nil): break
        }
        if facts.streakDays >= 3 { sentences.append("That is \(facts.streakDays) days in a row.") }
        if let title = nonEmpty(facts.freshSongTitle) {
            let by = nonEmpty(facts.freshSongArtist).map { " by \($0)" } ?? ""
            sentences.append("\(title)\(by) is new, so it could be worth a spin.")
        }
        if sentences.isEmpty { return "Play a few songs and this fills in with what you like." }
        return sentences.joined(separator: " ")
    }

    // MARK: Prompts

    /// The facts as the assistant reads them. No totals on purpose: with no count to quote it cannot say one.
    public static func factsLine(_ facts: HomeSummaryFacts) -> String {
        var parts = ["time_of_day=\(dayPhase(hour: facts.hour))", "weekday=\(weekdayName(facts.weekday))"]
        if let artist = nonEmpty(facts.topArtist) { parts.append("top_artist=\(artist)") }
        if let genre = nonEmpty(facts.topGenre) { parts.append("top_genre=\(genre)") }
        if let title = nonEmpty(facts.lastPlayedTitle) {
            var played = "last_played=\(title)"
            if let artist = nonEmpty(facts.lastPlayedArtist) { played += " by \(artist)" }
            if let ago = facts.lastPlayedMinutesAgo { played += " (\(agoWords(ago)))" }
            parts.append(played)
        }
        if facts.streakDays >= 3 { parts.append("streak_days=\(facts.streakDays)") }
        if let title = nonEmpty(facts.freshSongTitle) { parts.append("new_song=\(title)") }
        return parts.joined(separator: ", ")
    }

    public static let noStatsRule = "Never mention play counts, totals or how many songs are in the library."

    /// Added after the shared GREETING prompt layer (a byte-for-byte Android port with a 90-character limit and a
    /// `total_plays` example): Home's card is one short line and never a statistic, so these rules win.
    public static let headlineRules = "<home_card_rules>\nThis greeting sits on one short line of a card: keep it under \(headlineLimit) "
        + "characters, which overrides any longer limit above. \(noStatsRule) Ignore total_plays and library_size in "
        + "the examples above. Return only the line.\n</home_card_rules>"
    public static let headlineRulesSeparator = "\n\n"

    public static func headlinePrompt(_ facts: HomeSummaryFacts) -> String {
        factsLine(facts) + ". Write one short greeting under \(headlineLimit) characters that fits the moment. "
            + noStatsRule
    }

    public static func insightPrompt(_ facts: HomeSummaryFacts) -> String {
        factsLine(facts) + ". Write 2 short sentences about what the listener has been into and what to try next. "
            + noStatsRule
    }

    // MARK: Cleaning an assistant's answer

    /// Trims, drops wrapping quotes, cuts to `limit` characters on a word boundary (no ellipsis, no dangling
    /// punctuation) and refuses stat phrasing. nil when nothing usable is left.
    public static func clean(_ text: String, limit: Int, singleLine: Bool = true) -> String? {
        var slice = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while slice.first == "\"" { slice = slice.dropFirst() }
        while slice.last == "\"" { slice = slice.dropLast() }
        let trimmed = String(slice).trimmingCharacters(in: .whitespacesAndNewlines)
        // One line only: an assistant that wrote a paragraph gets its first line.
        let firstLine = singleLine
            ? String(trimmed.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
            : trimmed
        let cut = shortened(firstLine, limit: limit)
        guard !cut.isEmpty, !isStatPhrasing(cut) else { return nil }
        return cut
    }

    /// `text` within `limit` characters, cut at the last space (a single long word is cut hard), trailing
    /// punctuation and joiners removed.
    public static func shortened(_ text: String, limit: Int) -> String {
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard whole.count > limit else { return whole }
        var cut = String(whole.prefix(limit))
        // Cutting right before a space keeps the last word whole.
        let nextIsBoundary = whole[whole.index(whole.startIndex, offsetBy: limit)] == " "
        if !nextIsBoundary, let space = cut.lastIndex(of: " ") { cut = String(cut[..<space]) }
        let junk = CharacterSet(charactersIn: " ,;:-—–·&")
        return cut.trimmingCharacters(in: junk)
    }

    /// "340 plays", "12 songs", "in your library", "plays across": the statistic voice the card must not use.
    public static func isStatPhrasing(_ text: String) -> Bool {
        let lower = text.lowercased()
        for phrase in ["plays across", "in your library", "songs in your", "tracks in your", "plays logged",
                       "plays so far", "total plays", "logged "] where lower.contains(phrase) {
            return true
        }
        let chars = Array(lower)
        var i = 0
        while i < chars.count {
            guard chars[i].isNumber else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j].isNumber || chars[j] == "," || chars[j] == "." { j += 1 }
            var k = j
            while k < chars.count, chars[k] == " " { k += 1 }
            let word = String(chars[k..<min(chars.count, k + 6)])
            if word.hasPrefix("play") || word.hasPrefix("song") || word.hasPrefix("track") || word.hasPrefix("listen") {
                return true
            }
            i = max(j, i + 1)
        }
        return false
    }

    // MARK: Helpers

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `prefix + name + suffix` within the subtitle limit, shortening `name` on a word boundary when it has to
    /// (nil when less than 8 characters of it would remain).
    private static func fit(_ prefix: String, _ name: String, _ suffix: String) -> String? {
        let room = subtitleLimit - prefix.count - suffix.count
        guard room >= 8 else { return nil }
        let shown = name.count <= room ? name : shortened(name, limit: room)
        guard shown.count >= 8 || name.count <= room else { return nil }
        return prefix + shown + suffix
    }

    private static func agoWords(_ minutes: Int) -> String {
        switch minutes {
        case ..<2: "just now"
        case ..<60: "\(minutes) minutes ago"
        case ..<(60 * 24): "\(minutes / 60) hours ago"
        default: "\(minutes / (60 * 24)) days ago"
        }
    }
}
