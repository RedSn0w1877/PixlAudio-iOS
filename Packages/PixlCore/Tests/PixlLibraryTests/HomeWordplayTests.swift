import Foundation
import Testing
@testable import PixlLibrary

/// Android `HomeWordplayTest` (redesign batch 3): the picker behind Home's greeting and section titles.
@Suite struct HomeWordplayTests {
    @Test func timeBucketsFollowTheClock() {
        #expect(HomeWordplay.timeBucket(hour: 5) == .morning)
        #expect(HomeWordplay.timeBucket(hour: 11) == .morning)
        #expect(HomeWordplay.timeBucket(hour: 12) == .afternoon)
        #expect(HomeWordplay.timeBucket(hour: 16) == .afternoon)
        #expect(HomeWordplay.timeBucket(hour: 17) == .evening)
        #expect(HomeWordplay.timeBucket(hour: 21) == .evening)
        #expect(HomeWordplay.timeBucket(hour: 22) == .lateNight)
        #expect(HomeWordplay.timeBucket(hour: 0) == .lateNight)
        #expect(HomeWordplay.timeBucket(hour: 4) == .lateNight)
    }

    @Test func aRealStreakWinsOverTheTimeOfDay() {
        #expect(HomeWordplay.greetingSet(hour: 9, topSongPlaysThisWeek: HomeWordplay.streakMinPlays) == .streak)
        #expect(HomeWordplay.greetingSet(hour: 9, topSongPlaysThisWeek: HomeWordplay.streakMinPlays - 1) == .morning)
        #expect(HomeWordplay.greetingSet(hour: 23, topSongPlaysThisWeek: 0) == .lateNight)
    }

    @Test func thePickIsDeterministicForOneDayAndBucket() {
        let a = HomeWordplay.greeting(epochDay: 20_000, hour: 13, topSongPlaysThisWeek: 0) { _ in 3 }
        let b = HomeWordplay.greeting(epochDay: 20_000, hour: 15, topSongPlaysThisWeek: 2) { _ in 3 }
        #expect(a == b)
    }

    @Test func noLineRepeatsOnTwoDaysInARowForEverySetSize() {
        for size in 2 ... 9 {
            for salt in 0 ... 60 {
                var previous = HomeWordplay.rotate(epochDay: 19_000, size: size, salt: salt)
                for day in Int64(19_001) ... 19_400 {
                    let index = HomeWordplay.rotate(epochDay: day, size: size, salt: salt)
                    #expect((0 ..< size).contains(index))
                    #expect(index != previous)
                    previous = index
                }
            }
        }
    }

    @Test func everyLineComesRound() {
        for size in 2 ... 7 {
            let seen = Set((0 ..< Int64(size)).map { HomeWordplay.rotate(epochDay: 20_100 + $0, size: size, salt: 5) })
            #expect(seen.count == size)
        }
    }

    @Test func aSetOfOneLineOrNoneIsIndexZero() {
        #expect(HomeWordplay.rotate(epochDay: 123, size: 1, salt: 4) == 0)
        #expect(HomeWordplay.rotate(epochDay: 123, size: 0, salt: 4) == 0)
        #expect(HomeWordplay.section(epochDay: -5, .fresh, size: 1) == 0)
    }

    @Test func negativeDaysStillLandInRange() {
        #expect((0 ..< 3).contains(HomeWordplay.rotate(epochDay: -1, size: 3, salt: 2)))
        #expect((0 ..< 3).contains(HomeWordplay.subLine(epochDay: -400, size: 3)))
    }

    /// The same numbers as Kotlin's `Math.floorMod(day * step + offset, size)` (checked by hand for a few days).
    @Test func matchesKotlinForKnownDays() {
        // size 3, salt 11 (morning greeting): coprime steps of 3 are [1, 2], pick 11 mod 2 = 1 -> step 2;
        // offset floorMod(11 * 7 + 3, 3) = 80 mod 3 = 2. Day 20_000: (40_000 + 2) mod 3 = 0.
        #expect(HomeWordplay.rotate(epochDay: 20_000, size: 3, salt: 11) == 0)
        // Day -1: floorMod(-2 + 2, 3) = 0.
        #expect(HomeWordplay.rotate(epochDay: -1, size: 3, salt: 11) == 0)
    }

    @Test func epochDayIsTheLocalCalendarDay() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(HomeWordplay.epochDay(Date(timeIntervalSince1970: 0), timeZone: utc) == 0)
        #expect(HomeWordplay.epochDay(Date(timeIntervalSince1970: -1), timeZone: utc) == -1)
        #expect(HomeWordplay.epochDay(Date(timeIntervalSince1970: 86_400 * 20_000 + 3_600), timeZone: utc) == 20_000)
        let minusFive = TimeZone(secondsFromGMT: -5 * 3_600)!
        #expect(HomeWordplay.epochDay(Date(timeIntervalSince1970: 86_400 * 20_000 + 3_600), timeZone: minusFive) == 19_999)
    }
}
