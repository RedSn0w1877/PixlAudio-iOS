import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

private typealias Engine = MusicRecommendationEngine
private typealias Signal = MusicRecommendationEngine.Signal
private typealias History = MusicRecommendationEngine.History

private let now: Int64 = 1_800_000_000_000

/// Port of `data/recommendation/MusicRecommendationEngineTest.kt`.
@Suite struct MusicRecommendationEngineTests {
    private func song(_ id: String, _ artist: String? = nil, _ title: String? = nil) -> Song {
        var s = testSong(id, title: title, artist: artist)
        s.artistId = -1
        return s
    }

    @Test func endingAPausedSessionDoesNotTeachAnEarlySkip() {
        let feedback = Engine.record(Signal(), listenedMs: 10_000, durationMs: 180_000, voluntary: false, changedTrack: false, nowMs: now)
        #expect(feedback.earlySkips == 0)
        #expect(feedback.sessions == 1)
    }

    @Test func completedListeningAndEarlyTrackChangesProvideDifferentRewards() {
        let completed = Engine.record(Signal(), listenedMs: 170_000, durationMs: 180_000, voluntary: true, changedTrack: true, nowMs: now)
        let skipped = Engine.record(Signal(), listenedMs: 8_000, durationMs: 180_000, voluntary: false, changedTrack: true, nowMs: now)
        #expect(completed.completions == 1)
        #expect(completed.earlySkips == 0)
        #expect(skipped.earlySkips == 1)
        #expect(skipped.completions == 0)
    }

    @Test func loadingFailuresDoNotPoisonTheTasteModel() {
        let old = Signal(sessions: 3)
        #expect(Engine.record(old, listenedMs: 1_000, durationMs: 180_000, voluntary: false, changedTrack: true, nowMs: now) == old)
    }

    @Test func frequentSkipsReduceRankingEvenWithHighPlayCount() {
        let liked = song("liked", "Same artist"), skipped = song("skipped", "Same artist")
        let signals = [liked.id: Signal(sessions: 8, completions: 7), skipped.id: Signal(sessions: 20, earlySkips: 19)]
        let ranked = Engine.rank(songs: [skipped, liked], favorites: [], signals: signals,
                                 history: [skipped.id: History(plays: 40)], nowMs: now, seed: 1)
        #expect(ranked.first?.song.id == liked.id)
    }

    @Test func discoveryHasReservedSpaceAndUnknownArtistIdsDoNotCollapseArtists() {
        let songs = (1...20).map { song(String($0)) }
        let history = Dictionary(uniqueKeysWithValues: songs.prefix(10).map { ($0.id, History(plays: 10)) })
        let ranked = Engine.rank(songs: songs, favorites: Set(songs.prefix(10).map(\.id)), signals: [:], history: history,
                                 nowMs: now, seed: 42)
        let selected = Engine.select(ranked, limit: 12, explorationFraction: 0.5)
        #expect(selected.count == 12)
        #expect(selected.filter(\.unheard).count >= 6)
        #expect(Set(selected.map(\.song.artist)).count == 12)
    }

    @Test func duplicateRecordingAcrossSourcesAppearsOnceAndOrderingIsReproducible() {
        let songs = [song("local", "Artist", "Track"), song("spotify_remote", " artist ", "track"), song("other")]
        let first = Engine.select(Engine.rank(songs: songs, favorites: [], signals: [:], history: [:], nowMs: now, seed: 5), limit: 30)
        let second = Engine.select(Engine.rank(songs: songs, favorites: [], signals: [:], history: [:], nowMs: now, seed: 5), limit: 30)
        #expect(first.count == 2)
        #expect(first == second)
        #expect(first.allSatisfy { $0.score.isFinite && !$0.reason.isKotlinBlank })
    }

    @Test func artistDiversityReducesBackToBackSameArtistSelections() {
        let songs = [song("a1", "A"), song("a2", "A"), song("b1", "B"), song("c1", "C")]
        let picks = songs.enumerated().map { Engine.Pick(song: $1, score: 1.0 - Double($0) * 0.01, reason: "history", unheard: false) }
        let selected = Engine.select(picks, limit: 4)
        #expect(selected[0].song.artist != selected[1].song.artist)
        #expect(selected.count == 4)
        #expect(Engine.select(picks, limit: 0).isEmpty)
    }

    @Test func firstRunLearnsArtistAffinityFromExistingFavoritesWithoutNewSignals() {
        let favorite = song("favorite", "Preferred"), related = song("related", "Preferred"), unrelated = song("unrelated", "Other")
        let songs = [favorite, unrelated, related]
        let ranked = Engine.rank(songs: songs, favorites: [favorite.id],
                                 signals: Dictionary(uniqueKeysWithValues: songs.map { ($0.id, Signal()) }), history: [:],
                                 nowMs: now, seed: 5)
        let relatedScore = ranked.first { $0.song.id == related.id }!.score
        let unrelatedScore = ranked.first { $0.song.id == unrelated.id }!.score
        #expect(relatedScore > unrelatedScore + 0.1)
    }

    @Test func lateFeedbackPreservesTheNewestListeningTimestamp() {
        let previous = Signal(sessions: 2, lastPlayedMs: now)
        let updated = Engine.record(previous, listenedMs: 170_000, durationMs: 180_000, voluntary: false, changedTrack: true, nowMs: now - 60_000)
        #expect(updated.lastPlayedMs == now)
        #expect(updated.sessions == 3)
        #expect(updated.completions == 1)
    }

    @Test func duplicateSourcesRetainFavoritesAndListeningEvidenceFromTheRemovedVersion() {
        let local = song("local", "Artist", "Track")
        var remote = local
        remote.id = "spotify_remote"
        let feedback = Signal(sessions: 6, completions: 5, lastPlayedMs: now - 86_400_000)
        let history = History(plays: 8, lastPlayedMs: now - 86_400_000)
        let duplicatePick = Engine.rank(songs: [local, remote], favorites: [remote.id], signals: [remote.id: feedback],
                                        history: [remote.id: history], nowMs: now, seed: 5)
        let expected = Engine.rank(songs: [local], favorites: [local.id], signals: [local.id: feedback],
                                   history: [local.id: history], nowMs: now, seed: 5)
        #expect(duplicatePick.count == 1)
        #expect(duplicatePick[0].song.id == local.id)
        #expect(duplicatePick[0].reason == "One of your favorites")
        #expect(!duplicatePick[0].unheard)
        #expect(abs(duplicatePick[0].score - expected[0].score) < 0.0000001)
    }

    @Test func numericAndStreamingAliasesDoNotCountASharedFeedbackObjectTwice() {
        var canonical = song("-42", "Artist", "Track")
        canonical.spotifyId = "remote"
        var alias = canonical
        alias.id = "spotify_remote"
        let feedback = Signal(sessions: 8, completions: 4, earlySkips: 3, lastPlayedMs: now)
        let history = History(plays: 8, lastPlayedMs: now)
        let expected = Engine.rank(songs: [canonical], favorites: [], signals: [canonical.id: feedback],
                                   history: [canonical.id: history], nowMs: now, seed: 7)
        // Both ids read the same stored record (Kotlin: the same object instance under two keys).
        let actual = Engine.rank(songs: [canonical, alias], favorites: [],
                                 signals: [canonical.id: feedback, alias.id: feedback],
                                 history: [canonical.id: history, alias.id: history], nowMs: now, seed: 7,
                                 signalSources: [canonical.id: "stored", alias.id: "stored"],
                                 historySources: [canonical.id: "stored", alias.id: "stored"])
        #expect(actual.count == 1)
        #expect(abs(expected[0].score - actual[0].score) < 0.0000001)
    }

    @Test func separateRecordingHistoriesCombineEvenWhenTheirCountersMatch() {
        let local = song("local", "Artist", "Track")
        var remote = local
        remote.id = "spotify_remote"
        let first = Signal(sessions: 3, completions: 2, earlySkips: 1, lastPlayedMs: now)
        let second = first
        var expectedSignal = first
        expectedSignal.sessions = 6
        expectedSignal.completions = 4
        expectedSignal.earlySkips = 2
        let expected = Engine.rank(songs: [local], favorites: [], signals: [local.id: expectedSignal], history: [:],
                                   nowMs: now, seed: 9)
        let actual = Engine.rank(songs: [local, remote], favorites: [], signals: [local.id: first, remote.id: second],
                                 history: [:], nowMs: now, seed: 9)
        #expect(actual.count == 1)
        #expect(abs(expected[0].score - actual[0].score) < 0.0000001)
    }

    // Swift-only: inputs resolve the `spotify_` alias like DailyMixManager / HomeDiscoveryStateHolder.
    @Test func recommendationInputsResolveSpotifyAliasesToOneSource() {
        var a = song("-42", "Artist", "Track")
        a.spotifyId = "remote"
        let b = song("other")
        let stored = ["spotify_remote": Signal(sessions: 2)]
        let inputs = RecommendationInputs.resolve(library: [a, b], storedSignals: stored, storedHistory: [:])
        #expect(inputs.signals[a.id] == Signal(sessions: 2))
        #expect(inputs.signalSources[a.id] == "stored:spotify_remote")
        #expect(inputs.signals[b.id] == Signal())
        #expect(inputs.signalSources[b.id] == "default:other")
        #expect(inputs.historySources[b.id] == "default:other")
    }

    @Test func normalizeFoldsCompatibilityFormsCaseAndWhitespace() {
        #expect(Engine.normalize("  Ｔｒａｃｋ\t\t1 ") == "track 1")
        #expect(Engine.normalize("ΣΊΣΥΦΟΣ") == "σίσυφος")
        #expect(Engine.artistKey(song("x", "  ")) == "unknown:x")
        #expect(Engine.recordingKey(song("x", "A", "B")) == "a|b")
    }
}

/// Port of `data/recommendation/HomeRecommendationPlannerTest.kt`.
@Suite struct HomeRecommendationPlannerTests {
    private func song(_ id: String, _ artist: String? = nil, _ title: String? = nil) -> Song {
        testSong(id, title: title, artist: artist)
    }

    private func plan(_ library: [Song], favorites: Set<String> = [], signals: [String: Signal] = [:],
                      history: [String: History] = [:], discoveries: [Song] = [], releases: [Song] = []) -> HomeRecommendations {
        HomeRecommendationPlanner.plan(library: library, favorites: favorites, signals: signals, history: history,
                                       discoveries: discoveries, releases: releases, nowMs: now, seed: 42)
    }

    @Test func firstLaunchProvidesRealLocalChoicesWithoutANetworkOrListeningHistory() {
        let songs = (1...30).map { song(String($0)) }
        let result = plan(songs)
        #expect(!result.mixes.isEmpty)
        #expect(!result.shelves.isEmpty)
        #expect(result.mixes.flatMap(\.songs).allSatisfy { songs.contains($0) })
        #expect(result.shelves.flatMap(\.songs).allSatisfy { songs.contains($0) })
        #expect(!result.shelves.contains { $0.id == "discovery" || $0.id == "recent_releases" })
    }

    @Test func aRecordingAppearsOnlyOnceAcrossShelvesDespiteSourceAndCasingDifferences() {
        var local = song("local", "Singer", "The Track")
        local.isFavorite = true
        let online = song("online", " singer ", "the track")
        let result = plan([local, song("other")], discoveries: [online], releases: [online])
        let keys = result.shelves.flatMap(\.songs).map(Engine.recordingKey)
        #expect(keys.count == Set(keys).count)
        #expect(keys.filter { $0 == Engine.recordingKey(local) }.count == 1)
    }

    @Test func beyondLibraryExcludesAnAlreadySavedRecordingWithAnotherCatalogId() {
        let local = song("local", "A", "Same"), duplicate = song("remote", "A", "Same"), outside = song("new", "A", "New")
        let result = plan([local], discoveries: [duplicate, outside])
        #expect(result.shelves.first { $0.id == "discovery" }?.songs.map(\.id) == [outside.id])
    }

    @Test func favoritesAndUnfamiliarPresetsAreBasedOnDistinctListeningBehavior() {
        let favorite = song("favorite"), played = song("played"), unheard = song("unheard")
        let result = plan([favorite, played, unheard], favorites: [favorite.id], history: [played.id: History(plays: 5)])
        #expect(Set(result.mixes.first { $0.id == "comfort" }!.songs.map(\.id)) == [favorite.id, played.id])
        #expect(result.mixes.first { $0.id == "fresh_ears" }!.songs.map(\.id) == [unheard.id])
    }

    @Test func backInRotationExcludesRecentlyPlayedAndNeverPlayedSongs() {
        let old = song("old"), recent = song("recent"), unheard = song("unheard")
        let result = plan([old, recent, unheard], history: [
            old.id: History(plays: 2, lastPlayedMs: now - 8 * 86_400_000),
            recent.id: History(plays: 2, lastPlayedMs: now - 60_000),
        ])
        #expect(result.shelves.first { $0.id == "rediscover" }?.songs.map(\.id) == [old.id])
    }

    @Test func catalogRankingFollowsPositiveListeningSignalsAndPenalizesSkips() {
        let liked = song("liked", "Preferred"), skipped = song("skipped", "Avoided")
        let related = song("related", "Preferred"), unrelated = song("unrelated", "Avoided")
        let result = plan([liked, skipped], favorites: [liked.id], signals: [
            liked.id: Signal(sessions: 10, completions: 9), skipped.id: Signal(sessions: 10, earlySkips: 9),
        ], discoveries: [unrelated, related])
        #expect(result.shelves.first { $0.id == "discovery" }?.songs.first?.id == related.id)
    }

    @Test func noInventedGenreMixIsShownWhenGenreMetadataIsMissing() {
        let songs = (1...20).map { song(String($0)) }
        #expect(!plan(songs).mixes.contains { $0.id.hasPrefix("genre_") })
        let jazz = songs.map { s -> Song in var j = s; j.genre = "Jazz"; return j }
        #expect(plan(jazz, favorites: [jazz[0].id]).mixes.contains { $0.title == "Jazz mix" })
    }

    @Test func sameDayInputsAreStableAndShelfQueuesAreBounded() {
        let songs = (1...200).map { song(String($0)) }
        let first = plan(songs, favorites: Set(songs.prefix(50).map(\.id)))
        let second = plan(songs, favorites: Set(songs.prefix(50).map(\.id)))
        #expect(first == second)
        #expect(first.mixes.allSatisfy { (1...24).contains($0.songs.count) })
        #expect(first.shelves.allSatisfy { (1...12).contains($0.songs.count) })
    }

    @Test func emptyAndOneSongLibrariesDoNotCreateEmptyOrDuplicatePresetCards() {
        #expect(plan([]).mixes.isEmpty)
        #expect(plan([]).shelves.isEmpty)
        let one = plan([song("one")])
        #expect(one.mixes.count == 1)
        #expect(one.shelves.flatMap(\.songs).count == 1)
    }

    @Test func releaseDatesMustBeRecentCompleteDatesAndCannotBeInTheFuture() {
        let today = LocalDate(year: 2026, month: 9, day: 8)
        #expect(HomeRecommendationPlanner.isRecentRelease("2026-09-08", today: today))
        #expect(HomeRecommendationPlanner.isRecentRelease(today.plusDays(-180).description, today: today))
        #expect(!HomeRecommendationPlanner.isRecentRelease(today.plusDays(-181).description, today: today))
        #expect(!HomeRecommendationPlanner.isRecentRelease("2026-09-09", today: today))
        #expect(!HomeRecommendationPlanner.isRecentRelease("2026", today: today))
        #expect(!HomeRecommendationPlanner.isRecentRelease("2026-08", today: today))
        #expect(!HomeRecommendationPlanner.isRecentRelease("2026-02-30", today: today))
        #expect(!HomeRecommendationPlanner.isRecentRelease(nil, today: today))
    }

    @Test func demotedReasonsAreNotShownOnRecommendationCards() {
        let skipped = song("skipped", "A")
        let result = plan([skipped, song("b"), song("c")], signals: [skipped.id: Signal(sessions: 10, earlySkips: 9)])
        for section in result.mixes + result.shelves {
            #expect(!section.reasons.values.contains { $0.hasPrefix(Engine.reasonPrefixDemoted) })
        }
    }
}

/// Port of `data/premium/PremiumSmartToolsTest.kt`.
@Suite struct PremiumSmartToolsTests {
    private func song(_ id: String, _ artist: String? = nil, duration: Int64 = 180_000) -> Song {
        testSong(id, title: "Track \(id)", artist: artist, duration: duration)
    }

    @Test func deepDiscoveryReservesUnheardSongsAndRemovesDuplicateRecordings() {
        let first = song("1", "A")
        var duplicate = first
        duplicate.id = "remote-1"
        let heard = song("2", "B")
        let unseen = (3...12).map { song(String($0), "Artist \($0)") }
        let result = PremiumSmartPlaylistEngine.build(.discover, songs: [first, duplicate, heard] + unseen,
                                                      history: [heard.id: History(plays: 20)], seed: 7, limit: 8)
        #expect(result.songs.count == 8)
        #expect(Set(result.songs.map(Engine.recordingKey)).count == result.songs.count)
        #expect(result.songs.filter { $0.id != heard.id }.count >= 4)
    }

    @Test func recentlyAddedIsStableAndShortListensSortByDuration() {
        var old = song("old", duration: 300_000)
        old.dateAdded = 10
        var newest = song("new", duration: 60_000)
        newest.dateAdded = 30
        var middle = song("middle", duration: 120_000)
        middle.dateAdded = 20
        #expect(PremiumSmartPlaylistEngine.build(.recentlyAdded, songs: [old, newest, middle], limit: 3).songs.map(\.id) == ["new", "middle", "old"])
        #expect(PremiumSmartPlaylistEngine.build(.shortListen, songs: [old, newest, middle], limit: 3).songs.map(\.id) == ["new", "middle", "old"])
    }

    @Test func insightsAreLocalAndReportCompletionAndDiscoveryRates() {
        let played = song("played", "A"), unseen = song("unseen", "B")
        let insights = PremiumInsightEngine.summarize([played, unseen],
                                                      history: [played.id: History(plays: 2, listenedMs: 1000)],
                                                      signals: [played.id: Signal(sessions: 2, completions: 1, listenedMs: 1000)])
        #expect(insights.songCount == 2)
        #expect(insights.playedSongCount == 1)
        #expect(insights.completionRatePercent == 50)
        #expect(insights.discoveryRatePercent == 50)
        #expect(insights.totalListeningMs == 1000)
        #expect(insights.totalListeningLabel == "0m")
    }

    @Test func listeningLabelUsesHoursFromSixtyMinutes() {
        let insights = ListeningInsights(songCount: 0, playedSongCount: 0, totalListeningMs: 3_723_000,
                                         completionRatePercent: 0, topArtists: [], topGenres: [], discoveryRatePercent: 0)
        #expect(insights.totalListeningLabel == "1h 2m")
    }
}

/// Swift-only: the Daily Mix seeds and selection wrapper (`DailyMixManager`).
@Suite struct DailyMixTests {
    @Test func seedsFollowAndroid() {
        #expect(DailyMix.dailySeed(epochDay: 20_000) == 20_000)
        #expect(DailyMix.aiCandidatesSeed(epochDay: 20_000) == 20_042)
        var random = JavaRandom(seed: 2026 * 1000 + 273 + 17)
        #expect(DailyMix.yourMixSeed(year: 2026, dayOfYear: 273) == random.nextLong())
    }

    @Test func personalizedPicksFavoriteThroughSpotifyAlias() {
        var a = testSong("1", artist: "A")
        a.spotifyId = "abc"
        let b = testSong("2", artist: "B")
        let picks = DailyMix.personalizedPicks(allSongs: [a, b], favoriteSongIds: ["spotify_abc"], engagements: [:],
                                               storedSignals: [:], nowMs: now, limit: 30, seed: 1)
        #expect(picks.first { $0.song.id == "1" }?.reason == "One of your favorites")
        #expect(DailyMix.personalizedPicks(allSongs: [], favoriteSongIds: [], engagements: [:], storedSignals: [:],
                                           nowMs: now, seed: 1).isEmpty)
        #expect(DailyMix.personalizedPicks(allSongs: [a], favoriteSongIds: [], engagements: [:], storedSignals: [:],
                                           nowMs: now, limit: 0, seed: 1).isEmpty)
    }

    @Test func personalizedPicksUsesEngagementHistory() {
        let a = testSong("1", artist: "A"), b = testSong("2", artist: "B")
        let picks = DailyMix.personalizedPicks(allSongs: [a, b], favoriteSongIds: [],
                                               engagements: ["2": EngagementStats(playCount: 30, totalPlayDurationMs: 1, lastPlayedTimestamp: now - 3 * 86_400_000)],
                                               storedSignals: [:], exploration: 0, nowMs: now, seed: 3)
        #expect(picks.first?.song.id == "2")
        #expect(picks.first { $0.song.id == "1" }?.unheard == true)
    }
}
