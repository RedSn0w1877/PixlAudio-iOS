import Foundation
import Testing
@testable import PixlLibrary

/// The short, contextual summary at the top of Home: never a statistic, always one short line.
@Suite struct HomeSummaryTests {
    private func facts(hour: Int = 19, weekday: Int = 2, epochDay: Int64 = 20_000, artist: String? = nil,
                       genre: String? = nil, lastTitle: String? = nil, ago: Int? = nil, streak: Int = 0,
                       fresh: String? = nil) -> HomeSummaryFacts {
        HomeSummaryFacts(hour: hour, weekday: weekday, epochDay: epochDay, topArtist: artist, topGenre: genre,
                         lastPlayedTitle: lastTitle, lastPlayedArtist: lastTitle == nil ? nil : "Someone",
                         lastPlayedMinutesAgo: ago, streakDays: streak, freshSongTitle: fresh, hasLibrary: true)
    }

    @Test func dayPhasesAndSalutations() {
        #expect(HomeSummary.dayPhase(hour: 5) == "morning")
        #expect(HomeSummary.dayPhase(hour: 11) == "afternoon")
        #expect(HomeSummary.dayPhase(hour: 17) == "evening")
        #expect(HomeSummary.dayPhase(hour: 22) == "night")
        #expect(HomeSummary.salutation(hour: 8) == "Good morning")
        #expect(HomeSummary.salutation(hour: 2) == "Still up?")
    }

    @Test func weekdayFromEpochDay() {
        #expect(HomeSummary.weekday(epochDay: 0) == 3)        // 1970-01-01, a Thursday
        #expect(HomeSummary.weekday(epochDay: 4) == 0)        // Monday
        #expect(HomeSummary.weekday(epochDay: -1) == 2)       // Wednesday
        #expect(HomeSummary.weekdayName(HomeSummary.weekday(epochDay: 20_000)) == "Friday") // 2024-10-04
    }

    @Test func headlinesAreShortAndNeverStatistics() {
        for day in Int64(0)..<60 {
            for hour in [2, 8, 13, 19] {
                let text = HomeSummary.headline(facts(hour: hour, weekday: HomeSummary.weekday(epochDay: day), epochDay: day,
                                                      artist: "Luma Vale", genre: "Indie"))
                #expect(text.count <= HomeSummary.headlineLimit, "\(text)")
                #expect(!HomeSummary.isStatPhrasing(text), "\(text)")
            }
        }
    }

    @Test func headlineStartsWithTheGreetingOrTheDayLine() {
        let evening = HomeSummary.headline(facts(hour: 19, epochDay: 20_001))
        #expect(evening == "Good evening")
        let long = HomeSummary.headline(facts(hour: 19, artist: "The Extremely Long Artist Name"))
        #expect(long == "Good evening") // too long to name, so the plain greeting
    }

    @Test func headlineRotatesFromDayToDay() {
        var seen = Set<String>()
        for day in Int64(0)..<10 {
            seen.insert(HomeSummary.headline(facts(hour: 19, epochDay: day, artist: "Luma Vale", genre: "Indie")))
        }
        #expect(seen.count > 1)
    }

    @Test func emptyLibraryGetsTheInvitation() {
        let empty = HomeSummaryFacts(hasLibrary: false)
        #expect(HomeSummary.subtitle(empty) == HomeSummary.invitation)
        #expect(HomeSummary.headline(empty) == "Good afternoon")
    }

    @Test func subtitleFollowsTheMoment() {
        #expect(HomeSummary.subtitle(facts(lastTitle: "Blue Hour", ago: 5, streak: 9)) == "Just played Blue Hour")
        #expect(HomeSummary.subtitle(facts(lastTitle: "Blue Hour", ago: 120)) == "Earlier: Blue Hour")
        // Too long ago to mention: the streak comes next, then something new, then what keeps coming back.
        #expect(HomeSummary.subtitle(facts(lastTitle: "Blue Hour", ago: 3_000, streak: 4)) == "4 days in a row. Keep it rolling.")
        #expect(HomeSummary.subtitle(facts(artist: "Luma Vale", fresh: "Glass Rain")) == "New to try: Glass Rain")
        #expect(HomeSummary.subtitle(facts(artist: "Luma Vale", genre: "Indie")) == "Luma Vale has been on repeat")
        #expect(HomeSummary.subtitle(facts(genre: "Indie")) == "Leaning Indie lately")
        #expect(HomeSummary.subtitle(facts()) == HomeSummary.invitation)
    }

    @Test func subtitleNeverOverflowsOrCountsAnything() {
        let long = String(repeating: "Wonderful Title ", count: 6)
        for ago in [1, 100, 1_000] {
            let text = HomeSummary.subtitle(facts(artist: long, genre: long, lastTitle: long, ago: ago, streak: 5, fresh: long))
            #expect(text.count <= HomeSummary.subtitleLimit, "\(text)")
            #expect(!HomeSummary.isStatPhrasing(text), "\(text)")
        }
    }

    @Test func insightHasNoStatsEither() {
        let text = HomeSummary.insight(facts(artist: "Luma Vale", genre: "Indie", streak: 5, fresh: "Glass Rain"))
        #expect(text == "Luma Vale has been on repeat, and Indie keeps coming back. That is 5 days in a row. Glass Rain is new, so it could be worth a spin.")
        #expect(!HomeSummary.isStatPhrasing(text))
        #expect(!HomeSummary.insight(facts()).isEmpty)
    }

    @Test func promptsCarryContextAndNoTotals() {
        let line = HomeSummary.factsLine(facts(hour: 19, weekday: 4, artist: "Luma Vale", genre: "Indie", lastTitle: "Blue Hour",
                                               ago: 35, streak: 6, fresh: "Glass Rain"))
        #expect(line == "time_of_day=evening, weekday=Friday, top_artist=Luma Vale, top_genre=Indie, "
            + "last_played=Blue Hour by Someone (35 minutes ago), streak_days=6, new_song=Glass Rain")
        for prompt in [HomeSummary.headlinePrompt(facts(artist: "A")), HomeSummary.insightPrompt(facts(artist: "A"))] {
            #expect(!prompt.contains("total_plays"))
            #expect(!prompt.contains("library_size"))
            #expect(prompt.hasSuffix(HomeSummary.noStatsRule))
        }
    }

    @Test func cleanKeepsWholeWordsAndOneLine() {
        #expect(HomeSummary.clean("  \"Evening — a Luma Vale kind of night.\" ", limit: 60) == "Evening — a Luma Vale kind of night.")
        #expect(HomeSummary.clean(" \"\" ", limit: 40) == nil)
        let cut = HomeSummary.clean("Good evening, here is a much longer line than fits", limit: 24)
        #expect(cut == "Good evening, here is a")
        #expect(HomeSummary.clean("Hello\nsecond line", limit: 40) == "Hello")
        #expect(HomeSummary.clean("Hello\nsecond line", limit: 40, singleLine: false) == "Hello\nsecond line")
        #expect(HomeSummary.shortened("Good evening — and more", limit: 14) == "Good evening")
        #expect(HomeSummary.shortened(String(repeating: "a", count: 50), limit: 10).count == 10)
        #expect(HomeSummary.shortened("short", limit: 10) == "short")
    }

    @Test func cleanRefusesStatPhrasing() {
        #expect(HomeSummary.clean("340 plays across 490 songs in your library", limit: 60) == nil)
        #expect(HomeSummary.clean("You've logged a lot this week", limit: 60) == nil)
        #expect(HomeSummary.clean("Over 1,200 plays and counting", limit: 60) == nil)
        #expect(HomeSummary.clean("12 songs in a mood", limit: 60) == nil)
        #expect(HomeSummary.clean("5 days in a row. Keep it rolling.", limit: 60) == "5 days in a row. Keep it rolling.")
        #expect(HomeSummary.clean("Good evening — more Luma Vale?", limit: 60) == "Good evening — more Luma Vale?")
    }

    @Test func streakCountsBackFromTodayOrYesterday() {
        #expect(HomeSummary.streakDays(playDays: [10, 9, 8, 6], today: 10) == 3)
        #expect(HomeSummary.streakDays(playDays: [9, 8], today: 10) == 2)     // not yet today
        #expect(HomeSummary.streakDays(playDays: [8, 7], today: 10) == 0)     // broken
        #expect(HomeSummary.streakDays(playDays: [], today: 10) == 0)
    }
}

@Suite struct HomeSummaryFreshnessTests {
    private let now: Int64 = 1_800_000_000_000
    private let day: Int64 = 86_400_000

    @Test func freshMeansAddedInTheLastTwoWeeks() {
        #expect(HomeSummary.isFresh(dateAdded: now - 2 * day, nowMs: now))
        #expect(!HomeSummary.isFresh(dateAdded: now - 15 * day, nowMs: now))
        #expect(!HomeSummary.isFresh(dateAdded: 0, nowMs: now))
        #expect(!HomeSummary.isFresh(dateAdded: now + day, nowMs: now)) // from the future: not fresh
    }

    @Test func secondsAreRecognisedToo() {
        #expect(HomeSummary.isFresh(dateAdded: (now - day) / 1000, nowMs: now))
        #expect(!HomeSummary.isFresh(dateAdded: (now - 30 * day) / 1000, nowMs: now))
    }
}

@Suite struct HomeSummaryRulesTests {
    @Test func headlineRulesOverrideTheSharedLayersLimitAndTotals() {
        let rules = HomeSummary.headlineRules
        #expect(rules.contains("under \(HomeSummary.headlineLimit) characters"))
        #expect(rules.contains(HomeSummary.noStatsRule))
        #expect(rules.contains("total_plays"))
        #expect(HomeSummary.headlineRulesSeparator == "\n\n")
    }
}
