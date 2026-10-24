import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

private let now: Int64 = 1_800_000_000_000
private let day: Int64 = 86_400_000
private let utc = TimeZone(identifier: "UTC")!

/// `get_taste_profile`: counted by code from every play, honest about what it does not know.
@Suite struct TasteProfileTests {
    private func song(_ id: String, _ title: String, _ artist: String, genre: String? = nil, year: Int = 0) -> Song {
        testSong(id, title: title, artist: artist, genre: genre, year: year)
    }

    private func play(_ title: String, _ artist: String, ago: Int64, source: ListeningSource = .spotify, songId: String? = nil) -> ListeningPlay {
        ListeningPlay(title: title, artist: artist, timestampMs: now - ago, listenedMs: 200_000, source: source, songId: songId)
    }

    /// 60 plays: Aria 30 (library), Beat 20 (library), Cove 10 (YouTube Music).
    private func inputs(adjustments: [TasteAdjustment] = []) -> TasteProfileInputs {
        let songs = [song("a1", "Aria One", "Aria", genre: "Pop", year: 1996), song("b1", "Beat One", "Beat", genre: "Hip-Hop", year: 2014)]
        var plays: [ListeningPlay] = []
        for n in 0..<30 { plays.append(play("Aria One", "Aria", ago: Int64(n) * 3_600_000 + 1_000, songId: "a1")) }
        for n in 0..<20 { plays.append(play("Beat One", "Beat", ago: Int64(n) * 7_200_000 + 2_000, source: .app, songId: "b1")) }
        for n in 0..<10 { plays.append(play("Cove Song", "Cove", ago: Int64(n) * 86_400_000 + 5_000, source: .youTubeMusic)) }
        return TasteProfileInputs(songs: songs, plays: plays, adjustments: adjustments, nowMs: now, timeZone: utc)
    }

    @Test func countsPlaysAndSharesFromTheRealPlays() {
        let profile = TasteProfileBuilder.build(inputs(), period: .allTime)
        #expect(profile.playsInPeriod == 60 && profile.totalPlays == 60)
        #expect(profile.appPlays == 20 && profile.spotifyPlays == 30 && profile.youTubeMusicPlays == 10)
        #expect(profile.topArtists.map(\.name) == ["Aria", "Beat", "Cove"])
        #expect(profile.topArtists.map(\.plays) == [30, 20, 10])
        #expect(profile.topArtists[0].sharePercent == 50.0)
        #expect(abs(profile.topArtists[2].sharePercent - 16.666) < 0.01)
        // YouTube Music plays weigh 0.35: 10 plays = 3.5.
        #expect(abs(profile.topArtists[2].score - 3.5) < 1e-9)
        #expect(profile.topTracks.first?.title == "Aria One" && profile.topTracks.first?.songId == "a1")
        #expect(profile.uniqueArtists == 3)
        #expect(profile.recentPlays.count == TasteProfileBuilder.recentCount)
    }

    @Test func genresAndErasOnlyCountSongsTheLibraryKnows() {
        let profile = TasteProfileBuilder.build(inputs(), period: .allTime)
        #expect(profile.genres.map(\.name) == ["Pop", "Hip-Hop"] && profile.genres.map(\.plays) == [30, 20])
        // 50 of the 60 plays are of songs with a genre: the profile says so rather than pretending to know the rest.
        #expect(abs(profile.genreCoveragePercent - 50.0 * 100.0 / 60.0) < 0.01)
        #expect(profile.decades.map(\.name) == ["1990s", "2010s"])
        #expect(profile.notAvailable.contains("language") && profile.notAvailable.contains("energy"))
        let json = profile.json()
        #expect(json["genre_coverage_percent"] != nil && json["eras"]?.arrayValue?.count == 2)
    }

    @Test func confidenceFollowsTheNumberOfPlays() {
        func level(_ count: Int) -> TasteProfile.Confidence {
            let plays = (0..<count).map { play("S", "A", ago: Int64($0) * 60_000 + 1) }
            return TasteProfileBuilder.build(TasteProfileInputs(songs: [], plays: plays, nowMs: now, timeZone: utc), period: .allTime).confidence
        }
        #expect(level(0) == .empty && level(1) == .low && level(49) == .low && level(50) == .medium && level(499) == .medium && level(500) == .high)
        let thin = TasteProfileBuilder.build(TasteProfileInputs(songs: [], plays: [play("S", "A", ago: 5)], nowMs: now, timeZone: utc), period: .allTime)
        #expect(thin.confidenceNote.contains("1 play") && thin.confidenceNote.contains("thin"))
        let none = TasteProfileBuilder.build(TasteProfileInputs(songs: [], plays: [], nowMs: now, timeZone: utc), period: .month)
        #expect(none.confidence == .empty && none.topArtists.isEmpty && none.json()["confidence"]?["level"]?.stringValue == "none")
    }

    @Test func aPeriodWithoutPlaysFallsBackToAllTimeAndSaysSo() {
        var all = inputs()
        all.plays = all.plays.map { var p = $0; p.timestampMs -= 400 * day; return p }
        let profile = TasteProfileBuilder.build(all, period: .month)
        #expect(profile.period == .month && profile.periodUsed == .allTime && profile.playsInPeriod == 60)
        #expect(profile.confidenceNote.contains("all time"))
        let json = profile.json()
        #expect(json["period"]?.stringValue == "all_time" && json["period_requested"]?.stringValue == "month")
        let recent = TasteProfileBuilder.build(inputs(), period: .month)
        #expect(recent.periodUsed == .month && recent.playsInPeriod == 60)
        #expect(ListeningPeriod(toolValue: "six_months") == .sixMonths && ListeningPeriod(toolValue: "week") == nil)
    }

    @Test func listeningPatternNeedsRealTimestampsAndEnoughOfThem() throws {
        let profile = TasteProfileBuilder.build(inputs(), period: .allTime)
        let pattern = try #require(profile.pattern)
        #expect(pattern.basisPlays == 60)
        #expect(abs(pattern.timeOfDay.map(\.sharePercent).reduce(0, +) - 100.0) < 1e-6)
        #expect(abs(pattern.weekdayPlaysPercent + pattern.weekendPlaysPercent - 100.0) < 1e-6)
        #expect((0..<24).contains(pattern.peakHour))
        let few = TasteProfileInputs(songs: [], plays: Array(inputs().plays.prefix(10)), nowMs: now, timeZone: utc)
        let thin = TasteProfileBuilder.build(few, period: .allTime)
        #expect(thin.pattern == nil && thin.notAvailable.contains("time_of_day") && thin.json()["listening_pattern"] == nil)
        // Plays without a time don't count towards it.
        let undated = TasteProfileInputs(songs: [], plays: (0..<40).map {
            ListeningPlay(title: "S\($0)", artist: "A", timestampMs: 0, source: .spotify)
        }, nowMs: now, timeZone: utc)
        #expect(TasteProfileBuilder.datedPattern(undated.plays, timeZone: utc) == nil)
    }

    @Test func skipHeavyArtistsComeFromKnownOutcomes() throws {
        var imported: [ImportedPlay] = []
        for n in 0..<8 {
            imported.append(ImportedPlay(source: .spotifyExport, timestampMs: now - Int64(n) * 1_000_000 - 1_000, title: "Skip \(n)",
                                         artist: "Skippy", spotifyTrackId: nil, msPlayed: 8_000, durationMs: 200_000, skipped: true,
                                         reasonStart: "fwdbtn", reasonEnd: "fwdbtn"))
        }
        for n in 0..<6 {
            imported.append(ImportedPlay(source: .spotifyExport, timestampMs: now - Int64(n) * 1_000_000 - 500_000, title: "Done \(n)",
                                         artist: "Loved", msPlayed: 200_000, durationMs: 200_000, reasonStart: "clickrow", reasonEnd: "trackdone"))
        }
        let plays = ListeningHistoryInsights.plays(imported: imported)
        var input = TasteProfileInputs(songs: [], plays: plays, importedPlays: imported, nowMs: now, timeZone: utc)
        let profile = TasteProfileBuilder.build(input, period: .allTime)
        #expect(profile.sessionsWithKnownOutcome == 14 && profile.completions == 6 && profile.earlySkips == 8)
        #expect(profile.skippedArtists.map(\.name) == ["Skippy"] && profile.skippedArtists[0].skipRate == 1.0)
        let skippy = try #require(profile.topArtists.first { $0.name == "Skippy" })
        #expect(skippy.earlySkips == 8 && skippy.sessions == 8)
        let outcomes = try #require(profile.json()["completions_and_skips"])
        #expect(outcomes["early_skips"]?.int64Value == 8 && outcomes["completion_rate_percent"] != nil)
        // The app's own learned sessions join in (all time).
        input.songs = [song("k1", "Keeps", "Keeper")]
        input.localSignals = ["k1": MusicRecommendationEngine.Signal(sessions: 10, completions: 9, earlySkips: 1)]
        let withLocal = TasteProfileBuilder.build(input, period: .allTime)
        #expect(withLocal.sessionsWithKnownOutcome == 24 && withLocal.completions == 15)
    }

    @Test func spotifyListsAndAdjustmentsAreReported() {
        var input = inputs(adjustments: [
            TasteAdjustment(kind: .boost, strength: 2, targetType: .artist, key: "aria", label: "Aria", reason: "loves them",
                            source: .taizo, createdMs: now - 3 * day, expiresMs: now + 10 * day),
            TasteAdjustment(kind: .mute, strength: 0, targetType: .genre, key: "jazz", label: "Jazz", reason: "",
                            source: .user, createdMs: now - day),
            TasteAdjustment(kind: .block, strength: 0, targetType: .artist, key: "old", label: "Old", reason: "expired",
                            source: .taizo, createdMs: now - 9 * day, expiresMs: now - day),
        ])
        input.taste = ExternalTasteSnapshot(
            topTracks: [.init(range: .mediumTerm, rank: 0, title: "Hit", artist: "Aria")],
            topArtists: [.init(range: .mediumTerm, rank: 0, name: "Aria", genres: ["pop", "dance pop"]),
                         .init(range: .longTerm, rank: 1, name: "Beat", genres: ["pop"])],
            followedArtists: ["Aria", "Beat", "Cove"], fetchedAtMs: now)
        let profile = TasteProfileBuilder.build(input, period: .allTime)
        #expect(profile.adjustments.map(\.target) == ["Jazz", "Aria"], "newest first, expired left out")
        #expect(profile.adjustments[1].ageDays == 3 && profile.adjustments[1].expiresInDays == 10 && profile.adjustments[1].setBy == "taizo")
        #expect(profile.spotifyGenres.first == "pop" && profile.followedArtistCount == 3)
        let json = profile.json()
        #expect(json["spotify"]?["top_artists_medium_term"]?.arrayValue?.first?.stringValue == "Aria")
        #expect(json["spotify"]?["followed_artists"]?.int64Value == 3)
        #expect(json["taste_adjustments"]?.arrayValue?.count == 2)
        #expect(json["weights_in_use"]?["youtube_music"]?.doubleValue == 0.35 && json["weights_in_use"]?["spotify"]?.doubleValue == 1.0)
    }

    @Test func theJsonIsCompactAndWellFormed() throws {
        let text = JSONWriter.write(TasteProfileBuilder.build(inputs(), period: .allTime).json())
        let parsed = try JSONParser(mode: .strict, maxDepth: 32).parse(text)
        #expect(parsed["top_artists"]?.arrayValue?.count == 3)
        #expect(text.count < 6_000, "a profile stays small enough to read every turn")
        #expect(!text.contains("e-0") && !text.contains("nan") && !text.contains("inf"))
        #expect(TasteProfile.number(0.1 + 0.2, places: 1) == .number("0.3"))
        #expect(TasteProfile.number(50.0) == .number("50") && TasteProfile.number(.nan) == .number("0"))
    }

    @Test func theDigestIsShortAndCarriesWhatTheContextNeeds() {
        let adjustment = TasteAdjustment(kind: .reduce, strength: 1, targetType: .genre, key: "jazz", label: "Jazz", reason: "too mellow",
                                         source: .taizo, createdMs: now - 2 * day)
        let profile = TasteProfileBuilder.build(inputs(adjustments: [adjustment]), period: .allTime)
        let lines = profile.digestLines()
        let text = lines.joined(separator: "\n")
        #expect(text.contains("60 plays") && text.contains("Confidence: medium"))
        #expect(text.contains("Top artists: Aria (30), Beat (20), Cove (10)"))
        #expect(text.contains("Top genres: Pop (30), Hip-Hop (20)"))
        #expect(text.contains("reduce genre Jazz x1") && text.contains(adjustment.id) && text.contains("too mellow"))
        #expect(text.count < 2_500)
    }
}
