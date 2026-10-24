import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Imported listening history (spec B): the file parsers on small samples in the exact export shapes, de-duplication,
/// the codec, weights / decay, mapping to library songs, what it adds to the recommendations, and the read API.
@Suite("Listening history import")
struct ListeningHistoryTests {
    private let day: Int64 = 86_400_000
    /// 2024-03-01T12:00:00Z.
    private let march1: Int64 = 1_709_294_400_000

    private func fixture(_ name: String) throws -> [UInt8] {
        let base = (name as NSString).deletingPathExtension
        let url = try #require(Bundle.module.url(forResource: base, withExtension: "json", subdirectory: "Fixtures/history"))
        return [UInt8](try Data(contentsOf: url))
    }

    private func play(_ source: ImportedPlaySource, _ ts: Int64, _ title: String, _ artist: String, id: String? = nil,
                      video: String? = nil, ms: Int64 = 0) -> ImportedPlay {
        ImportedPlay(source: source, timestampMs: ts, title: title, artist: artist, spotifyTrackId: id, videoId: video,
                     msPlayed: ms)
    }

    // MARK: Parsers

    @Test func spotifyExtendedHistoryKeepsSongsAndTheirOutcomes() throws {
        let name = "Streaming_History_Audio_2023-2024_0.json"
        let parsed = ListeningHistoryParsers.parse(fileName: name, bytes: try fixture(name))
        #expect(parsed.kind == .spotifyExtended)
        #expect(parsed.plays.count == 3)
        #expect(parsed.skipped == 1) // the podcast episode
        let first = parsed.plays[0]
        #expect(first.source == .spotifyExport && first.timestampMs == march1)
        #expect(first.title == "Blinding Lights" && first.artist == "The Weeknd" && first.album == "After Hours")
        #expect(first.spotifyTrackId == "0VjIjW4GlUZAMYd2vXMi3b" && first.msPlayed == 215_000)
        #expect(first.reasonStart == "clickrow" && first.reasonEnd == "trackdone" && first.skipped == nil && first.shuffle == false)
        let outcome = ImportedPlayOutcome(first)
        #expect(outcome.isKnown && outcome.completed && !outcome.earlySkip && outcome.voluntary)
        let skipped = ImportedPlayOutcome(parsed.plays[1])
        #expect(skipped.isKnown && !skipped.completed && skipped.earlySkip && !skipped.voluntary)
        // 2 s: too short to count at all.
        #expect(!ListeningHistoryWeights.counts(parsed.plays[2]))
    }

    @Test func spotifyBasicHistoryReadsMinutePreciseTimes() throws {
        let name = "StreamingHistory_music_0.json"
        let parsed = ListeningHistoryParsers.parse(fileName: name, bytes: try fixture(name))
        #expect(parsed.kind == .spotifyBasic)
        #expect(parsed.plays.map(\.title) == ["Blinding Lights", "One More Time"])
        #expect(parsed.plays[0].timestampMs == march1 && parsed.plays[0].msPlayed == 215_000)
        #expect(parsed.plays[0].spotifyTrackId == nil)
    }

    @Test func takeoutKeepsYouTubeMusicAndPlainMusicChannelsOnly() throws {
        let parsed = ListeningHistoryParsers.parse(fileName: "Takeout/YouTube and YouTube Music/history/watch-history.json",
                                                   bytes: try fixture("watch-history.json"))
        #expect(parsed.kind == .takeoutWatchHistory)
        #expect(parsed.plays.count == 2)
        #expect(parsed.skipped == 3) // the bike video, the removed video, the ad
        let lucky = parsed.plays[0]
        #expect(lucky.source == .takeout && lucky.title == "Get Lucky (feat. Pharrell Williams)" && lucky.artist == "Daft Punk")
        #expect(lucky.videoId == "5NV6Rdv1a3I")
        #expect(lucky.timestampMs == ListeningHistoryTime.parse("2024-04-10T20:15:30.123Z"))
        let vevo = parsed.plays[1]
        #expect(vevo.artist == "The Weeknd" && vevo.title == "Blinding Lights (Official Video)" && vevo.videoId == "4NRXx6U8ABQ")
    }

    @Test func fileKindsByNameAndByContent() {
        #expect(ListeningHistoryFileKind.fromName("Spotify Extended Streaming History/Streaming_History_Audio_2019.json") == .spotifyExtended)
        #expect(ListeningHistoryFileKind.fromName("MyData/endsong_3.json") == .spotifyExtended)
        #expect(ListeningHistoryFileKind.fromName("Streaming_History_Video_2020.json") == .ignored)
        #expect(ListeningHistoryFileKind.fromName("StreamingHistory0.json") == .spotifyBasic)
        #expect(ListeningHistoryFileKind.fromName("StreamingHistory_podcast_0.json") == .ignored)
        #expect(ListeningHistoryFileKind.fromName("history/watch-history.json") == .takeoutWatchHistory)
        #expect(ListeningHistoryFileKind.fromName("history/watch-history.html") == .ignored)
        #expect(ListeningHistoryFileKind.fromName("anything.json") == .unknown)
        #expect(ListeningHistoryFileKind.sniff(Array(#"[{"ts":"x","ms_played":1}]"#.utf8)) == .spotifyExtended)
        #expect(ListeningHistoryFileKind.sniff(Array(#" [ {"endTime":"x","msPlayed":1} ]"#.utf8)) == .spotifyBasic)
        #expect(ListeningHistoryFileKind.sniff(Array(#"[{"header":"YouTube"}]"#.utf8)) == .takeoutWatchHistory)
        #expect(ListeningHistoryFileKind.sniff(Array(#"{"not":"an array"}"#.utf8)) == .unknown)
    }

    @Test func arrayScannerSplitsTopLevelElementsOnly() {
        let text = "\u{FEFF}[ {\"a\":\"x, ] } \\\" [\",\"b\":[1,2,{\"c\":3}]} , 7, \"s,t\" ,[1,[2]] ]"
        var elements: [String] = []
        JSONArrayScanner.forEachElement(Array(text.utf8)) { slice, _ in
            elements.append(String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces))
            return true
        }
        #expect(elements == ["{\"a\":\"x, ] } \\\" [\",\"b\":[1,2,{\"c\":3}]}", "7", "\"s,t\"", "[1,[2]]"])
        var none = 0
        JSONArrayScanner.forEachElement(Array("[]".utf8)) { _, _ in none += 1; return true }
        #expect(none == 0)
    }

    @Test func timestamps() {
        #expect(ListeningHistoryTime.parse("2024-03-01T12:00:00Z") == march1)
        #expect(ListeningHistoryTime.parse("2024-03-01 12:00") == march1)
        #expect(ListeningHistoryTime.parse("2024-03-01T12:00:00.5Z") == march1 + 500)
        #expect(ListeningHistoryTime.parse("2024-03-01T14:00:00+02:00") == march1)
        #expect(ListeningHistoryTime.parse("2024-03-01T12:00:00") == march1)
        #expect(ListeningHistoryTime.parse("1 March 2024") == nil)
        #expect(ListeningHistoryTime.parse("2024-13-01T12:00:00Z") == nil)
    }

    @Test func spotifyTrackIdsAndVideoIds() {
        #expect(ListeningHistoryParsers.spotifyTrackId(fromURI: "spotify:track:0VjIjW4GlUZAMYd2vXMi3b") == "0VjIjW4GlUZAMYd2vXMi3b")
        #expect(ListeningHistoryParsers.spotifyTrackId(fromURI: "spotify:episode:0VjIjW4GlUZAMYd2vXMi3b") == nil)
        #expect(ListeningHistoryParsers.spotifyTrackId(fromURI: "spotify:track:short") == nil)
        #expect(ListeningHistoryParsers.videoId(fromURL: "https://music.youtube.com/watch?v=5NV6Rdv1a3I&list=x") == "5NV6Rdv1a3I")
        #expect(ListeningHistoryParsers.videoId(fromURL: "https://www.youtube.com/watch?feature=a&v=5NV6Rdv1a3I") == "5NV6Rdv1a3I")
        #expect(ListeningHistoryParsers.videoId(fromURL: "https://www.youtube.com/post/xyz") == nil)
    }

    // MARK: Identity, merging, codec

    @Test func titlesAndArtistsNormaliseForMatching() {
        #expect(ImportedPlayIdentity.normalizedTitle("Get Lucky (feat. Pharrell Williams)") == "get lucky")
        #expect(ImportedPlayIdentity.normalizedTitle("Here Comes The Sun - Remastered 2009") == "here comes the sun")
        #expect(ImportedPlayIdentity.normalizedTitle("Blinding Lights [Official Video]") == "blinding lights")
        #expect(ImportedPlayIdentity.normalizedTitle("Song (Live)") == "song (live)")
        #expect(ImportedPlayIdentity.primaryArtistKey("Daft Punk, Pharrell Williams") == "daft punk")
        #expect(ImportedPlayIdentity.primaryArtistKey("Simon & Garfunkel") == "simon")
        #expect(ImportedPlayIdentity.primaryArtistKey("  THE  Weeknd ") == "the weeknd")
    }

    @Test func reimportingTheSameFileAddsNothing() throws {
        let name = "Streaming_History_Audio_2023-2024_0.json"
        let plays = ListeningHistoryParsers.parse(fileName: name, bytes: try fixture(name)).plays
        let first = ImportedHistoryMerge.merge(existing: [], adding: plays)
        #expect(first.added == 3)
        let again = ImportedHistoryMerge.merge(existing: first.plays, adding: plays)
        #expect(again.added == 0 && again.plays.count == 3)
    }

    @Test func theSamePlayFromTheAPIAndTheExportsCountsOnce() {
        let export = play(.spotifyExport, march1, "Blinding Lights", "The Weeknd", id: "0VjIjW4GlUZAMYd2vXMi3b", ms: 200_000)
        // The API's played_at has milliseconds and may differ by a second.
        let api = play(.spotifyAPI, march1 + 1_400, "Blinding Lights", "The Weeknd", id: "0VjIjW4GlUZAMYd2vXMi3b")
        // The basic export: no id, minute precision, written as 12:00 for a play that ended 12:00:40.
        let basic = play(.spotifyExport, march1, "Blinding Lights", "The Weeknd", ms: 200_000)
        let exact = ImportedHistoryMerge.merge(existing: [], adding: [export])
        #expect(ImportedHistoryMerge.merge(existing: exact.plays, adding: [api, basic]).added == 0)
        let later = play(.spotifyExport, march1 + 40_000, "Blinding Lights", "The Weeknd", id: "0VjIjW4GlUZAMYd2vXMi3b")
        #expect(ImportedHistoryMerge.merge(existing: [basic], adding: [later]).added == 0)
        // A real replay a few minutes later is a new play.
        let replay = play(.spotifyAPI, march1 + 230_000, "Blinding Lights", "The Weeknd", id: "0VjIjW4GlUZAMYd2vXMi3b")
        #expect(ImportedHistoryMerge.merge(existing: exact.plays, adding: [replay]).added == 1)
    }

    @Test func youTubeHistoryPageEntriesMoveForwardInsteadOfAdding() {
        let old = play(.ytmusic, march1, "Get Lucky", "Daft Punk", video: "5NV6Rdv1a3I")
        let seenAgain = play(.ytmusic, march1 + 3 * day, "Get Lucky", "Daft Punk", video: "5NV6Rdv1a3I")
        let merged = ImportedHistoryMerge.merge(existing: [old], adding: [seenAgain])
        #expect(merged.added == 0 && merged.plays.count == 1 && merged.plays[0].timestampMs == march1 + 3 * day)
        // Takeout plays have exact times: every one counts.
        let takeout = [play(.takeout, march1, "Get Lucky", "Daft Punk", video: "5NV6Rdv1a3I"),
                       play(.takeout, march1 + day, "Get Lucky", "Daft Punk", video: "5NV6Rdv1a3I")]
        #expect(ImportedHistoryMerge.merge(existing: merged.plays, adding: takeout).added == 2)
        #expect(ImportedHistoryMerge.removing([.ytmusic], from: merged.plays + takeout).count == 2)
    }

    @Test func codecRoundTripsEveryField() {
        let plays = [
            ImportedPlay(source: .spotifyExport, timestampMs: march1, title: "Tab\there\nnew\\line", artist: "A, B",
                         album: "Al", spotifyTrackId: "0VjIjW4GlUZAMYd2vXMi3b", msPlayed: 1_234, durationMs: 200_000,
                         skipped: true, reasonStart: "clickrow", reasonEnd: "fwdbtn", shuffle: false),
            ImportedPlay(source: .ytmusic, timestampMs: 5, title: "T", artist: "", videoId: "5NV6Rdv1a3I"),
        ]
        let text = ImportedHistoryCodec.encode(plays)
        #expect(text.hasPrefix("PIXLHIST1\n"))
        #expect(ImportedHistoryCodec.decode(text) == plays)
        // A damaged line is skipped, not the file.
        #expect(ImportedHistoryCodec.decode(text + "garbage\tline\n").count == 2)
        #expect(ImportedHistoryCodec.decode("").isEmpty)
    }

    // MARK: Weights

    @Test func spotifyOutweighsYouTubeAndOldPlaysFade() {
        let now = march1
        let spotify = play(.spotifyExport, now, "x", "y")
        let youTube = play(.takeout, now, "x", "y")
        #expect(ListeningHistoryWeights.weight(spotify, nowMs: now) == 1.0)
        #expect(ListeningHistoryWeights.weight(youTube, nowMs: now) == 0.35)
        let halfYear = play(.spotifyAPI, now - 180 * day, "x", "y")
        #expect(abs(ListeningHistoryWeights.weight(halfYear, nowMs: now) - 0.5) < 1e-12)
        let year = play(.ytmusic, now - 360 * day, "x", "y")
        #expect(abs(ListeningHistoryWeights.weight(year, nowMs: now) - 0.35 * 0.25) < 1e-12)
        #expect(ListeningHistoryWeights.weight(play(.spotifyAPI, now + day, "x", "y"), nowMs: now) == 1.0)
    }

    // MARK: Feeding the recommendations

    private func librarySongs() -> [Song] {
        [testSong("sp:0VjIjW4GlUZAMYd2vXMi3b", title: "Blinding Lights", artist: "The Weeknd", spotifyId: "0VjIjW4GlUZAMYd2vXMi3b"),
         testSong("sp:aaaaaaaaaaaaaaaaaaaaaa", title: "Get Lucky", artist: "Daft Punk, Pharrell Williams",
                  spotifyId: "aaaaaaaaaaaaaaaaaaaaaa"),
         testSong("sp:bbbbbbbbbbbbbbbbbbbbbb", title: "Around the World", artist: "Daft Punk", spotifyId: "bbbbbbbbbbbbbbbbbbbbbb"),
         testSong("sp:cccccccccccccccccccccc", title: "Quiet Song", artist: "Nobody", spotifyId: "cccccccccccccccccccccc")]
    }

    @Test func playsMapToSongsAndFeedEngagementSignalsAndArtists() {
        let now = march1
        var plays: [ImportedPlay] = []
        // Three finished Spotify plays today, one early skip.
        for i in 0..<3 {
            plays.append(ImportedPlay(source: .spotifyExport, timestampMs: now - Int64(i) * 3_600_000, title: "Blinding Lights",
                                      artist: "The Weeknd", spotifyTrackId: "0VjIjW4GlUZAMYd2vXMi3b", msPlayed: 200_000,
                                      reasonStart: "clickrow", reasonEnd: "trackdone"))
        }
        plays.append(ImportedPlay(source: .spotifyExport, timestampMs: now - 4 * 3_600_000, title: "Blinding Lights",
                                  artist: "The Weeknd", spotifyTrackId: "0VjIjW4GlUZAMYd2vXMi3b", msPlayed: 9_000,
                                  skipped: true, reasonEnd: "fwdbtn"))
        // A YouTube Music play of a library song by name (feat. stripped), and plays of a song not in the library.
        plays.append(play(.takeout, now, "Get Lucky (feat. Pharrell Williams)", "Daft Punk", video: "5NV6Rdv1a3I"))
        for i in 0..<5 { plays.append(play(.spotifyAPI, now - Int64(i) * day, "Not In Library", "Nobody", id: "dddddddddddddddddddddd")) }

        let aggregate = ImportedHistoryAggregate.build(plays: plays, nowMs: now)
        #expect(aggregate.totalPlays == 10 && aggregate.spotifyPlays == 9 && aggregate.youTubePlays == 1)
        #expect(aggregate.tracks.first?.title == "Not In Library" || aggregate.tracks.first?.title == "Blinding Lights")
        let inputs = aggregate.recommendationInputs(library: librarySongs())
        #expect(inputs.mappedTracks == 2 && inputs.unmappedTracks == 1)
        let blinding = inputs.engagements["sp:0VjIjW4GlUZAMYd2vXMi3b"]
        #expect(blinding?.playCount == 4 && blinding?.lastPlayedTimestamp == now)
        let signal = inputs.signals["sp:0VjIjW4GlUZAMYd2vXMi3b"]
        #expect(signal?.sessions == 4 && signal?.completions == 3 && signal?.earlySkips == 1 && signal?.voluntaryPlays == 3)
        // 0.35 rounds to 0 but a heard song is never "unheard".
        #expect(inputs.engagements["sp:aaaaaaaaaaaaaaaaaaaaaa"]?.playCount == 1)
        // The plays outside the library lift their artist: ln(1 + Σ weights) × 0.6.
        let expectedWeight = (0..<5).reduce(0.0) { $0 + pow(2.0, -Double($1) / 180.0) }
        #expect(abs((inputs.artistAffinity["nobody"] ?? 0) - log(1 + expectedWeight) * 0.6) < 1e-9)
        #expect(inputs.artistAffinity["the weeknd"] == nil)

        let merged = inputs.mergedEngagements(["sp:0VjIjW4GlUZAMYd2vXMi3b": EngagementStats(playCount: 2, totalPlayDurationMs: 10,
                                                                                         lastPlayedTimestamp: now + 5)])
        #expect(merged["sp:0VjIjW4GlUZAMYd2vXMi3b"]?.playCount == 6)
        #expect(merged["sp:0VjIjW4GlUZAMYd2vXMi3b"]?.lastPlayedTimestamp == now + 5)
        let mergedSignals = inputs.mergedSignals(["sp:0VjIjW4GlUZAMYd2vXMi3b": MusicRecommendationEngine.Signal(sessions: 1, completions: 1)])
        #expect(mergedSignals["sp:0VjIjW4GlUZAMYd2vXMi3b"]?.sessions == 5)
        #expect(mergedSignals["sp:0VjIjW4GlUZAMYd2vXMi3b"]?.completions == 4)
    }

    @Test func aPlayWithoutAnIdJoinsTheTrackWithTheSameName() {
        let plays = [play(.spotifyAPI, march1, "Blinding Lights", "The Weeknd", id: "0VjIjW4GlUZAMYd2vXMi3b"),
                     play(.spotifyExport, march1 - day, "Blinding Lights", "The Weeknd")]
        let aggregate = ImportedHistoryAggregate.build(plays: plays, nowMs: march1)
        #expect(aggregate.tracks.count == 1 && aggregate.tracks[0].plays == 2)
        #expect(aggregate.tracks[0].spotifyTrackId == "0VjIjW4GlUZAMYd2vXMi3b")
    }

    @Test func spotifyTasteAddsFamiliarityAndArtistAffinity() {
        let taste = ExternalTasteSnapshot(
            topTracks: [.init(range: .longTerm, rank: 0, title: "Around the World", artist: "Daft Punk",
                              spotifyTrackId: "bbbbbbbbbbbbbbbbbbbbbb"),
                        .init(range: .shortTerm, rank: 25, title: "Quiet Song", artist: "Nobody")],
            topArtists: [.init(range: .mediumTerm, rank: 0, name: "Daft Punk", genres: ["french house", "electro"]),
                         .init(range: .longTerm, rank: 49, name: "Daft Punk")],
            followedArtists: ["Daft Punk", "Nobody"], fetchedAtMs: march1)
        let inputs = ImportedHistoryAggregate.build(plays: [], taste: taste, nowMs: march1)
            .recommendationInputs(library: librarySongs())
        #expect(inputs.engagements["sp:bbbbbbbbbbbbbbbbbbbbbb"]?.playCount == 8)
        #expect(inputs.engagements["sp:cccccccccccccccccccccc"]?.playCount == 2)
        // 2.0 × 1 + 2.5 × (1 − 49/50) + 1.0 (followed)
        #expect(abs((inputs.artistAffinity["daft punk"] ?? 0) - (2.0 + 2.5 * 0.02 + 1.0)) < 1e-9)
        #expect(inputs.artistAffinity["nobody"] == 1.0)
    }

    @Test func artistAffinityLiftsAnArtistsSongsAndEmptyAffinityChangesNothing() {
        let now = march1
        let songs = (0..<6).map { testSong("s\($0)", title: "Track \($0)", artist: $0 < 3 ? "Alpha" : "Beta") }
        let base = MusicRecommendationEngine.rank(songs: songs, favorites: [], signals: [:], history: [:], nowMs: now, seed: 7)
        let same = MusicRecommendationEngine.rank(songs: songs, favorites: [], signals: [:], history: [:], nowMs: now, seed: 7,
                                                  artistAffinity: [:])
        #expect(base == same)
        let lifted = MusicRecommendationEngine.rank(songs: songs, favorites: [], signals: [:], history: [:], nowMs: now, seed: 7,
                                                    artistAffinity: ["beta": 3.0])
        #expect(lifted.prefix(3).allSatisfy { $0.song.artist == "Beta" })
        #expect(lifted.first { $0.song.artist == "Beta" }?.reason == "Discover more from an artist you enjoy")
        // A multi-artist credit finds its first artist's affinity.
        let duet = [testSong("d", title: "Duet", artist: "Beta, Gamma"), testSong("o", title: "Other", artist: "Delta")]
        let ranked = MusicRecommendationEngine.rank(songs: duet, favorites: [], signals: [:], history: [:], nowMs: now, seed: 7,
                                                    artistAffinity: ["beta": 3.0])
        #expect(ranked.first?.song.id == "d")
    }

    // MARK: Read API

    @Test func insightsWeighSourcesAndRespectPeriods() {
        let now = march1
        var plays: [ListeningPlay] = []
        for i in 0..<3 {
            plays.append(ListeningPlay(title: "A\(i)", artist: "Spotty", timestampMs: now - Int64(i) * day, source: .spotify))
        }
        for i in 0..<5 {
            plays.append(ListeningPlay(title: "Tube", artist: "Tuber", timestampMs: now - Int64(i) * day, source: .youTubeMusic))
        }
        plays.append(ListeningPlay(title: "Old", artist: "Oldie", timestampMs: now - 400 * day, listenedMs: 1_000,
                                   source: .app, songId: "s1"))
        plays.append(ListeningPlay(title: "Old", artist: "Oldie", timestampMs: now - 401 * day, source: .app, songId: "s1"))
        let month = ListeningHistoryInsights.topArtists(plays, period: .month, nowMs: now)
        // 3 × 1.0 beats 5 × 0.35.
        #expect(month.map(\.name) == ["Spotty", "Tuber"])
        #expect(month[1].plays == 5 && abs(month[1].score - 1.75) < 1e-12)
        let all = ListeningHistoryInsights.topArtists(plays, period: .allTime, nowMs: now, limit: 1)
        #expect(all.map(\.name) == ["Spotty"])
        let tracks = ListeningHistoryInsights.topTracks(plays, period: .allTime, nowMs: now, limit: 2)
        #expect(tracks.first?.title == "Old" && tracks.first?.plays == 2 && tracks.first?.songId == "s1")
        #expect(ListeningHistoryInsights.recentPlays(plays, count: 2).map(\.timestampMs) == [now, now])
        let summary = ListeningHistoryInsights.summary(plays, taste: ExternalTasteSnapshot(
            topArtists: [.init(range: .shortTerm, rank: 0, name: "X", genres: ["pop", "rock"]),
                         .init(range: .longTerm, rank: 0, name: "Y", genres: ["rock"])],
            followedArtists: ["X"]), nowMs: now)
        #expect(summary.totalPlays == 10 && summary.appPlays == 2 && summary.spotifyPlays == 3 && summary.youTubeMusicPlays == 5)
        #expect(summary.uniqueArtists == 3 && summary.playsLast30Days == 8)
        #expect(summary.topArtists.first == "Spotty")
        #expect(summary.topGenres == ["rock", "pop"])
        #expect(summary.followedArtists == 1 && summary.firstPlayMs == now - 401 * day)
    }

    @Test func gatheringMapsImportedPlaysAndAppEvents() {
        let library = librarySongs()
        let mapper = ImportedHistoryMapper(library: library)
        let imported = [play(.spotifyAPI, march1, "Blinding Lights", "The Weeknd", id: "0VjIjW4GlUZAMYd2vXMi3b"),
                        play(.spotifyExport, march1, "Short", "X", ms: 1_000)]
        let gathered = ListeningHistoryInsights.plays(imported: imported, mapper: mapper)
        #expect(gathered.count == 1 && gathered[0].songId == "sp:0VjIjW4GlUZAMYd2vXMi3b" && gathered[0].source == .spotify)
        let events = [PlaybackEvent(songId: "sp:bbbbbbbbbbbbbbbbbbbbbb", timestamp: march1, durationMs: 60_000),
                      PlaybackEvent(songId: "gone", timestamp: march1, durationMs: 60_000)]
        let app = ListeningHistoryInsights.plays(events: events, songsById: Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) }))
        #expect(app.count == 1 && app[0].title == "Around the World" && app[0].source == .app)
    }
}
