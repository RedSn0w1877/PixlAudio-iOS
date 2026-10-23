import Foundation
import Testing
import PixlModel
@testable import PixlLibrary

/// Smart auto-prepare's ranking. The numbers are written out (not recomputed from the formula) because the Android app
/// ranks with the same constants and has to give the same scores for the same inputs.
@Suite("Sing prepare ranker")
struct SingPrepareRankerTests {
    private let now: Int64 = 1_800_000_000_000
    private let day: Int64 = 86_400_000

    private func song(_ id: String, favorite: Bool = false, albumId: Int64 = -1, duration: Int64 = 180_000,
                      dateAdded: Int64 = 0, artist: String? = nil) -> Song {
        var s = testSong(id, artist: artist, duration: duration, isFavorite: favorite, dateAdded: dateAdded)
        s.albumId = albumId
        return s
    }

    private func rank(_ songs: [Song], engagements: [String: EngagementStats] = [:],
                      signals: [String: MusicRecommendationEngine.Signal] = [:], events: [PlaybackEvent] = [],
                      playlists: [Playlist] = [], excluded: Set<String> = [], blocked: BlockedArtistMatcher = .empty,
                      limit: Int = 50) -> [SingPrepareRanker.Candidate] {
        SingPrepareRanker.rank(SingPrepareInputs(songs: songs, engagements: engagements, signals: signals,
                                                 recentEvents: events, playlists: playlists, excluded: excluded,
                                                 blocked: blocked, nowMs: now), limit: limit)
    }

    private func score(_ id: String, _ candidates: [SingPrepareRanker.Candidate]) -> Double? {
        candidates.first { $0.song.id == id }?.score
    }

    private func event(_ songId: String, agoMs: Int64) -> PlaybackEvent {
        PlaybackEvent(songId: songId, timestamp: now - agoMs, durationMs: 120_000)
    }

    private func playlist(_ id: String, _ songIds: [String]) -> Playlist {
        Playlist(id: id, name: id, songIds: songIds, createdAt: 0, lastModified: 0)
    }

    // MARK: Each term on its own

    @Test func aFavouriteAloneScoresThree() throws {
        let result = rank([song("fav", favorite: true), song("plain")])
        #expect(abs(try #require(score("fav", result)) - 3.0) < 1e-9)
        #expect(result.first?.reasons == [.favorite])
        #expect(abs(try #require(score("plain", result))) < 1e-9)
    }

    @Test func playsRecencyAndSkipsFollowTheFormula() throws {
        // 4 plays, 6 sessions of which 4 were finished and 1 skipped early, last played exactly 14 days ago:
        // 2.5·ln(5)·(6/10) + 2.0·2^−1 − 3.0·(1/8)
        let signal = MusicRecommendationEngine.Signal(sessions: 6, completions: 4, earlySkips: 1)
        let result = rank([song("loved")],
                          engagements: ["loved": EngagementStats(playCount: 4, lastPlayedTimestamp: now - 14 * day)],
                          signals: ["loved": signal])
        #expect(abs(try #require(score("loved", result)) - 3.0391568686511503) < 1e-9)
    }

    @Test func withoutLearnedSignalsThePlaysAndSkipTermsAreZero() throws {
        let result = rank([song("loved")],
                          engagements: ["loved": EngagementStats(playCount: 4, lastPlayedTimestamp: now - 14 * day)])
        // Only the recency of the last play is left.
        #expect(abs(try #require(score("loved", result)) - 1.0) < 1e-9)
    }

    @Test func recentlyAddedSongsDecayWithAThirtyDayHalfLife() throws {
        let result = rank([song("new", dateAdded: now - 60 * day), song("newer", favorite: true, dateAdded: now - 30 * day),
                           song("unknown", dateAdded: 0)])
        #expect(abs(try #require(score("new", result)) - 0.25) < 1e-9)
        #expect(abs(try #require(score("newer", result)) - 3.5) < 1e-9)
        #expect(abs(try #require(score("unknown", result))) < 1e-9)
        #expect(result.first { $0.song.id == "new" }?.reasons == [])
        #expect(result.first { $0.song.id == "newer" }?.reasons == [.favorite, .addedRecently])
    }

    @Test func aPlayInTheFutureCountsAsNow() throws {
        let result = rank([song("odd")],
                          engagements: ["odd": EngagementStats(playCount: 0, lastPlayedTimestamp: now + day)])
        #expect(abs(try #require(score("odd", result)) - 2.0) < 1e-9)
    }

    // MARK: Neighbours

    @Test func theSongsAfterARecentSongInAPlaylistGetTheirShare() throws {
        let ids = ["a", "b", "x", "n1", "n2", "n3", "n4", "n5", "n6"]
        let songs = ids.map { song($0) }
        // "a" was played last, "b" before it; "n2" follows "a" by two places and "b" by one.
        let result = rank(songs, events: [event("b", agoMs: 2_000), event("a", agoMs: 1_000)],
                          playlists: [playlist("one", ["x", "a", "n1", "n2", "n3", "n4", "n5", "n6"]),
                                      playlist("two", ["b", "n2"])])
        #expect(abs(try #require(score("n1", result)) - 0.5) < 1e-9)
        #expect(abs(try #require(score("n2", result)) - 0.8333333333333333) < 1e-9)
        #expect(abs(try #require(score("n3", result)) - 0.25) < 1e-9)
        #expect(abs(try #require(score("n4", result)) - 0.2) < 1e-9)
        #expect(abs(try #require(score("n5", result)) - 0.16666666666666666) < 1e-9)
        // The sixth place after the seed, and the song before it, get nothing.
        #expect(abs(try #require(score("n6", result))) < 1e-9)
        #expect(abs(try #require(score("x", result))) < 1e-9)
        #expect(result.prefix(5).map(\.song.id) == ["n2", "n1", "n3", "n4", "n5"])
        #expect(result.first?.reasons == [.nextInPlaylist])
    }

    @Test func onlyTheFiveMostRecentDistinctSongsSeedTheNeighbours() throws {
        let songs = ["s1", "s2", "s3", "s4", "s5", "s6", "t1", "t2"].map { song($0) }
        // s1 was played twice, so it takes one place; s6 is the sixth distinct song and seeds nothing.
        let events = [event("s1", agoMs: 1_000), event("s2", agoMs: 2_000), event("s1", agoMs: 3_000),
                      event("s3", agoMs: 4_000), event("s4", agoMs: 5_000), event("s5", agoMs: 6_000),
                      event("s6", agoMs: 7_000)]
        #expect(SingPrepareRanker.recentSeeds(events) == ["s1", "s2", "s3", "s4", "s5"])
        let result = rank(songs, events: events, playlists: [playlist("p", ["s6", "t1"]), playlist("q", ["s1", "t2"])])
        #expect(abs(try #require(score("t1", result))) < 1e-9)
        #expect(abs(try #require(score("t2", result)) - 0.5) < 1e-9)
    }

    // MARK: Albums

    @Test func songsOnTheAlbumOfOneOfTheEightBestScoringSongsGetALift() throws {
        var songs = (1...8).map { song("f\($0)", favorite: true, albumId: Int64($0)) }
        songs.append(song("sib1", albumId: 1))
        songs.append(song("g9", albumId: 50))
        songs.append(song("sib50", albumId: 50))
        songs.append(song("loner", albumId: -1))
        // g9 is the ninth best (a play just now = 2.0), so its album is not lifted.
        let result = rank(songs, engagements: ["g9": EngagementStats(playCount: 0, lastPlayedTimestamp: now)])
        // A seed counts for its own album too.
        for n in 1...8 { #expect(abs(try #require(score("f\(n)", result)) - 3.8) < 1e-9) }
        #expect(abs(try #require(score("sib1", result)) - 0.8) < 1e-9)
        #expect(result.first { $0.song.id == "sib1" }?.reasons == [.sameAlbum])
        #expect(abs(try #require(score("g9", result)) - 2.0) < 1e-9)
        #expect(abs(try #require(score("sib50", result))) < 1e-9)
        #expect(abs(try #require(score("loner", result))) < 1e-9)
    }

    @Test func aSongThatCannotBePreparedStillSeedsItsAlbum() throws {
        let songs = [song("done", favorite: true, albumId: 3), song("sibling", albumId: 3)]
        let result = rank(songs, excluded: ["done"])
        #expect(result.map(\.song.id) == ["sibling"])
        #expect(abs(try #require(score("sibling", result)) - 0.8) < 1e-9)
    }

    // MARK: Exclusions

    @Test func songsThatMustBeLeftAloneAreNotCandidates() {
        let heavySkips = MusicRecommendationEngine.Signal(sessions: 8, completions: 0, earlySkips: 5)
        let fairSkips = MusicRecommendationEngine.Signal(sessions: 8, completions: 0, earlySkips: 4)
        let songs = [
            song("kept", favorite: true),
            song("has-instrumental", favorite: true),
            song("pending-job", favorite: true),
            song("too-short", favorite: true, duration: 60_000),
            song("just-long-enough", favorite: true, duration: 60_001),
            song("longest", favorite: true, duration: 480_000),
            song("too-long", favorite: true, duration: 480_001),
            song("skipped-a-lot", favorite: true),
            song("skipped-some", favorite: true),
            song("blocked", favorite: true, artist: "Nope"),
        ]
        let blocked = BlockedArtistMatcher(entries: [BlockedArtist(artistId: 5, name: "Nope")])
        let result = rank(songs, signals: ["skipped-a-lot": heavySkips, "skipped-some": fairSkips],
                          excluded: ["has-instrumental", "pending-job"], blocked: blocked)
        #expect(Set(result.map(\.song.id)) == ["kept", "just-long-enough", "longest", "skipped-some"])
    }

    // MARK: Order and limit

    @Test func equalScoresComeOutInIdOrderAndTheLimitCuts() {
        let songs = ["b", "a", "c"].map { song($0, favorite: true) }
        #expect(rank(songs).map(\.song.id) == ["a", "b", "c"])
        #expect(rank(songs, limit: 2).map(\.song.id) == ["a", "b"])
        #expect(rank(songs, limit: 0).isEmpty)
        #expect(rank([]).isEmpty)
    }

    @Test func theSameInputsGiveTheSameOrderEveryTime() {
        let songs = (0..<40).map { song("s\($0)", favorite: $0 % 3 == 0, dateAdded: now - Int64($0) * day) }
        let first = rank(songs).map(\.song.id)
        for _ in 0..<5 { #expect(rank(songs.shuffled()).map(\.song.id) == first) }
    }
}
