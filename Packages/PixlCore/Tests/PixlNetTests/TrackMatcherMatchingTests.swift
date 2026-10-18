import Foundation
import Testing
@testable import PixlNet

/// The lenient live matching (`TrackMatcher.scoreForMatching` / `matchScore`) and the YouTube Music result parsing
/// that feeds it: popular Spotify titles with credits and remaster tags used to score 0.
@Suite("TrackMatcher live matching")
struct TrackMatcherMatchingTests {
    struct Case: Sendable {
        let title: String
        let artist: String
        let candidateTitle: String
        let candidateArtist: String
        let seconds: Int
        var isVideo = false
    }

    static let cases: [Case] = [
        Case(title: "Starboy", artist: "The Weeknd, Daft Punk", candidateTitle: "Starboy (feat. Daft Punk)",
             candidateArtist: "The Weeknd", seconds: 230),
        Case(title: "Stay (with Justin Bieber)", artist: "The Kid LAROI, Justin Bieber", candidateTitle: "STAY",
             candidateArtist: "The Kid LAROI & Justin Bieber", seconds: 141),
        Case(title: "Bohemian Rhapsody - Remastered 2011", artist: "Queen", candidateTitle: "Bohemian Rhapsody",
             candidateArtist: "Queen", seconds: 355),
        Case(title: "Hotel California - 2013 Remaster", artist: "Eagles", candidateTitle: "Hotel California",
             candidateArtist: "Eagles", seconds: 391),
        Case(title: "Empire State Of Mind", artist: "JAY-Z, Alicia Keys",
             candidateTitle: "Empire State Of Mind (feat. Alicia Keys)", candidateArtist: "JAY-Z", seconds: 276),
        Case(title: "One Dance", artist: "Drake, Wizkid, Kyla",
             candidateTitle: "Drake - One Dance (Lyrics) ft. Wizkid & Kyla", candidateArtist: "Lyrics Channel",
             seconds: 174, isVideo: true),
        Case(title: "Die With A Smile", artist: "Lady Gaga, Bruno Mars", candidateTitle: "Die With A Smile",
             candidateArtist: "Lady Gaga & Bruno Mars", seconds: 251),
    ]

    @Test(arguments: cases) func popularTitlesMatch(_ c: Case) {
        let song = MatchableTrack(title: c.title, artist: c.artist, album: "", durationMs: Int64(c.seconds) * 1000 + 400)
        let candidate = YouTubeSearchResult(videoId: "abcdefghijk", title: c.candidateTitle, artist: c.candidateArtist,
                                            album: nil, durationSeconds: c.seconds, isMusicVideo: c.isVideo)
        #expect(TrackMatcher.scoreForMatching(song, candidate) >= TrackMatcher.earlyAcceptScore)
        #expect(TrackMatcher.matchScore(song, candidate) >= TrackMatcher.earlyAcceptScore)
    }

    @Test func titleLabelsAreStrippedButVariantsStay() {
        #expect(TrackMatcher.cleanTitle("Song (feat. X) [2011 Remaster]") == "song")
        #expect(TrackMatcher.cleanTitle("Song - Radio Edit") == "song")
        #expect(TrackMatcher.cleanTitle("Song (Live at Wembley)") == "song live at wembley")
        #expect(TrackMatcher.cleanTitle("Song - Remix") == "song remix")
        #expect(TrackMatcher.cleanTitle("(Remastered)") == "remastered")
    }

    @Test func aLiveOrRemixVersionStillLosesToTheStudioRecording() {
        let song = MatchableTrack(title: "Stay (with Justin Bieber)", artist: "The Kid LAROI", album: "", durationMs: 141_000)
        let studio = YouTubeSearchResult(videoId: "aaaaaaaaaaa", title: "STAY", artist: "The Kid LAROI", album: nil, durationSeconds: 141)
        let live = YouTubeSearchResult(videoId: "bbbbbbbbbbb", title: "STAY (Live)", artist: "The Kid LAROI", album: nil, durationSeconds: 141)
        #expect(TrackMatcher.matchScore(song, studio) > TrackMatcher.matchScore(song, live))
    }

    @Test func aDifferentSongWithAShortTitleIsStillRejected() {
        let song = MatchableTrack(title: "Stay", artist: "Rihanna", album: "", durationMs: 240_000)
        let other = YouTubeSearchResult(videoId: "aaaaaaaaaaa", title: "Stay Away", artist: "Rihanna", album: nil, durationSeconds: 240)
        #expect(TrackMatcher.matchScore(song, other) < TrackMatcher.minAcceptScore)
    }

    @Test func aTenSecondEditStillMatchesButTwoMinutesOffDoesNot() {
        let song = MatchableTrack(title: "Night Drive", artist: "Nova", album: "", durationMs: 200_000)
        let radio = YouTubeSearchResult(videoId: "aaaaaaaaaaa", title: "Night Drive", artist: "Nova", album: nil, durationSeconds: 188)
        let long = YouTubeSearchResult(videoId: "bbbbbbbbbbb", title: "Night Drive", artist: "Nova", album: nil, durationSeconds: 330)
        #expect(TrackMatcher.matchScore(song, radio) >= TrackMatcher.minAcceptScore)
        #expect(TrackMatcher.matchScore(song, long) < TrackMatcher.minAcceptScore)
    }

    @Test func excludedVideoIdsAreNeverChosen() async throws {
        struct Search: YouTubeMusicSearching {
            func searchSongs(_ query: String, limit: Int) async throws -> [YouTubeSearchResult] {
                [YouTubeSearchResult(videoId: "badbadbadba", title: "Starboy", artist: "The Weeknd", album: nil, durationSeconds: 230),
                 YouTubeSearchResult(videoId: "goodgoodgoo", title: "Starboy", artist: "The Weeknd", album: nil, durationSeconds: 231)]
            }
            func searchVideos(_ query: String, limit: Int) async throws -> [YouTubeSearchResult] { [] }
        }
        let song = MatchableTrack(title: "Starboy", artist: "The Weeknd", album: "", durationMs: 230_000)
        let first = try await TrackMatcher(search: Search()).findMatch(song)
        #expect(first?.videoId == "badbadbadba")
        let second = try await TrackMatcher(search: Search()).findMatch(song, excludingVideoIds: ["badbadbadba"])
        #expect(second?.videoId == "goodgoodgoo")
        let fan = try await TrackMatcher(search: Search()).findMatchFanOut(song, excludingVideoIds: ["badbadbadba"])
        #expect(fan?.videoId == "goodgoodgoo")
    }

    @Test func multiArtistCreditsStayOneSegment() {
        let runs = ["Lady Gaga", " & ", "Bruno Mars", " • ", "MAYHEM", " • ", "4:12"]
        #expect(InnerTubeParsing.splitBulletSegments(runs) == ["Lady Gaga & Bruno Mars", "MAYHEM", "4:12"])
        #expect(InnerTubeParsing.splitBulletSegments(["Song", " • ", "Artist", " • ", "3:07"]) == ["Song", "Artist", "3:07"])
        #expect(InnerTubeParsing.splitBulletSegments(["", "•", " "]).isEmpty)
    }
}
