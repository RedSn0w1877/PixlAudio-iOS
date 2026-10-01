import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Golden vectors produced by running the Android app's compiled classes (see `tools/android-reference/LibGen.java`).
@Suite struct GoldenVectorTests {
    // MARK: Random + QueueUtils

    @Test func randomAndQueueMatchAndroid() async throws {
        var failures: [String] = []
        let bounds: [Int32] = [1, 2, 3, 7, 16, 100, 1000, 1 << 30, Int32.max, 5, 10_000]
        func kotlinSeq(_ r: inout KotlinRandom) -> [Int64] {
            var out: [Int64] = []
            for _ in 0..<4 { out.append(Int64(r.nextInt())) }
            for b in bounds { out.append(Int64(r.nextInt(until: b))) }
            for b in bounds { out.append(Int64(r.nextInt(until: b))) }
            return out
        }
        for line in try goldenLines("queue-golden.jsonl") {
            let input = line["in"]!, out = line["out"]!
            switch line["fn"]!.str {
            case "kotlinRandomInt":
                var r = KotlinRandom(seed: Int32(input.i64))
                if kotlinSeq(&r) != out.arr.map(\.i64) { failures.append("kotlinRandomInt \(input)") }
            case "kotlinRandomLong":
                var r = KotlinRandom(seed: input.i64)
                if kotlinSeq(&r) != out.arr.map(\.i64) { failures.append("kotlinRandomLong \(input)") }
            case "javaRandom":
                var r = JavaRandom(seed: Int64(input.str)!)
                let o = out.arr
                var ok = Int64(r.nextInt()) == o[0].i64
                ok = ok && r.nextDouble().bitPattern == o[1].bitsDouble.bitPattern
                ok = ok && r.nextLong() == Int64(o[2].str)!
                for (i, b) in bounds.enumerated() { ok = ok && Int64(r.nextInt(b)) == o[3 + i].i64 }
                ok = ok && r.nextDouble().bitPattern == o[3 + bounds.count].bitsDouble.bitPattern
                ok = ok && r.nextLong() == Int64(o[4 + bounds.count].str)!
                if !ok { failures.append("javaRandom \(input)") }
            case "hashCode":
                if Int64(KotlinText.hashCode(input.str)) != out.i64 { failures.append("hashCode \(input)") }
            case "fisherYates":
                var r = KotlinRandom(seed: Int32(input["seed"]!.i64))
                let got = QueueUtils.fisherYatesCopy(Array(0..<input["n"]!.int), random: &r)
                if got != out.arr.map(\.int) { failures.append("fisherYates \(input)") }
            case "anchored":
                var r = KotlinRandom(seed: Int32(input["seed"]!.i64))
                let ids = (0..<input["n"]!.int).map { "song-\($0)" }
                let got = QueueUtils.buildAnchoredShuffleQueue(ids, anchorIndex: input["anchor"]!.int, random: &r)
                if got != out.strings { failures.append("anchored \(input)") }
            case "anchoredSuspending":
                var r = KotlinRandom(seed: Int32(input["seed"]!.i64))
                let ids = (0..<input["n"]!.int).map { "song-\($0)" }
                let got = await QueueUtils.buildAnchoredShuffleQueue(ids, anchorIndex: input["anchor"]!.int,
                                                                     startAtZero: input["startAtZero"]!.bool, random: &r)
                if got != out.strings { failures.append("anchoredSuspending \(input)") }
            default: Issue.record("unknown fn")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) mismatches: \(failures.prefix(10))")
    }

    // MARK: Folders

    static func folderJSON(_ folders: [MusicFolder]) -> [JSONValue] {
        folders.map { f in
            var o = JSONObject()
            o.append("path", .string(f.path))
            o.append("name", .string(f.name))
            o.append("songs", .array(f.songs.map { s in
                .array([.string(s.id), .string(s.title), .string(s.path), s.albumArtUriString.map(JSONValue.string) ?? .null])
            }))
            o.append("sub", .array(folderJSON(f.subFolders)))
            o.append("total", .integer(f.totalSongCount))
            o.append("totalSub", .integer(f.totalSubFolderCount))
            return .object(o)
        }
    }

    @Test func folderTreeAndRulesMatchAndroid() throws {
        var failures: [String] = []
        for line in try goldenLines("folder-golden.jsonl") {
            let input = line["in"]!, out = line["out"]!
            switch line["fn"]!.str {
            case "tree", "infer":
                let rows = input["rows"]!.arr.map { r in
                    FolderSongRow(id: String(r.arr[0].i64), parentDirectoryPath: r.arr[1].str, title: r.arr[2].str,
                                  albumArtUriString: r.arr[3].optStr)
                }
                if line["fn"]!.str == "tree" {
                    let tree = FolderTreeBuilder.buildFolderTreeForRoots(folderSongs: rows, selectedRootPaths: input["roots"]!.strings)
                    let got = JSONValue.array(Self.folderJSON(tree))
                    if JSONWriter.write(got) != JSONWriter.write(out) {
                        failures.append("tree \(JSONWriter.write(input))\n got \(JSONWriter.write(got))\nwant \(JSONWriter.write(out))")
                    }
                } else {
                    let got = FolderTreeBuilder.inferRemovableStorageRoots(folderSongs: rows, internalStorageRoot: input["internal"]!.str,
                                                                          knownRemovableRoots: input["known"]!.strings)
                    if got != out.strings { failures.append("infer \(input) → \(got)") }
                }
            case "rules":
                let resolver = DirectoryRuleResolver(allowed: input["allowed"]!.strings, blocked: input["blocked"]!.strings)
                let got = input["paths"]!.strings.map { resolver.isBlocked($0) }
                if got != out.arr.map(\.bool) { failures.append("rules \(input) → \(got)") }
            default: Issue.record("unknown fn")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) mismatches: \(failures.prefix(5).joined(separator: "\n"))")
    }

    // MARK: Recommendation

    struct Evidence {
        var signals: [String: MusicRecommendationEngine.Signal] = [:]
        var history: [String: MusicRecommendationEngine.History] = [:]
        var signalSources: [String: String] = [:]
        var historySources: [String: String] = [:]
    }

    static func evidence(_ input: JSONValue) -> Evidence {
        var e = Evidence()
        for s in input["signals"]!.arr {
            let key = s["key"]!.str
            e.signals[key] = MusicRecommendationEngine.Signal(
                sessions: s["sessions"]!.int, completions: s["completions"]!.int, earlySkips: s["earlySkips"]!.int,
                voluntaryPlays: s["voluntaryPlays"]!.int, lastPlayedMs: s["lastPlayedMs"]!.i64, listenedMs: s["listenedMs"]!.i64)
            e.signalSources[key] = "src\(s["src"]!.int)"
        }
        for h in input["history"]!.arr {
            let key = h["key"]!.str
            e.history[key] = MusicRecommendationEngine.History(plays: h["plays"]!.int, listenedMs: h["listenedMs"]!.i64,
                                                               lastPlayedMs: h["lastPlayedMs"]!.i64)
            e.historySources[key] = "src\(h["src"]!.int)"
        }
        return e
    }

    static func picksMatch(_ got: [MusicRecommendationEngine.Pick], _ want: [JSONValue]) -> String? {
        guard got.count == want.count else { return "count \(got.count) ≠ \(want.count)" }
        for (g, w) in zip(got, want) {
            let a = w.arr
            if g.song.id != a[0].str || g.reason != a[2].str || g.unheard != a[3].bool {
                return "pick \(g.song.id) \(g.reason) ≠ \(a)"
            }
            if g.score.bitPattern != a[1].bitsDouble.bitPattern {
                return "score \(g.song.id) \(g.score) ≠ \(a[1].bitsDouble)"
            }
        }
        return nil
    }

    static func sectionsMatch(_ got: [HomeMusicSection], _ want: [JSONValue]) -> String? {
        guard got.count == want.count else { return "sections \(got.map(\.id)) ≠ \(want.map { $0["id"]!.str })" }
        for (g, w) in zip(got, want) {
            if g.id != w["id"]!.str || g.title != w["title"]!.str || g.subtitle != w["subtitle"]!.str {
                return "section \(g.id) ≠ \(w["id"]!.str)"
            }
            if g.songs.map(\.id) != w["songs"]!.strings { return "songs of \(g.id): \(g.songs.map(\.id)) ≠ \(w["songs"]!.strings)" }
            let reasons = w["reasons"]!.arr.map { ($0.arr[0].str, $0.arr[1].str) }
            if g.reasonOrder != reasons.map(\.0) || reasons.contains(where: { g.reasons[$0.0] != $0.1 }) {
                return "reasons of \(g.id)"
            }
        }
        return nil
    }

    @Test func recommendationMatchesAndroid() throws {
        var failures: [String] = []
        var scenarios = 0
        for line in try goldenLines("recommendation-golden.jsonl") {
            let input = line["in"]!, out = line["out"]!
            switch line["fn"]!.str {
            case "scenario":
                scenarios += 1
                let songs = input["songs"]!.arr.map(fixtureSong)
                let favorites = Set(input["favorites"]!.strings)
                let e = Self.evidence(input)
                let now = input["now"]!.i64
                let seed = Int64(input["seed"]!.str)!
                let discoveries = input["discoveries"]!.arr.map(fixtureSong)
                let releases = input["releases"]!.arr.map(fixtureSong)
                let tag = "scenario \(scenarios)"
                for (song, keys) in zip(songs, out["keys"]!.arr) {
                    if MusicRecommendationEngine.artistKey(song) != keys.arr[0].str
                        || MusicRecommendationEngine.recordingKey(song) != keys.arr[1].str {
                        failures.append("\(tag) keys \(song.title)|\(song.artist) → \(MusicRecommendationEngine.recordingKey(song)) ≠ \(keys)")
                    }
                }
                let ranked = MusicRecommendationEngine.rank(songs: songs, favorites: favorites, signals: e.signals,
                                                            history: e.history, nowMs: now, seed: seed,
                                                            signalSources: e.signalSources, historySources: e.historySources)
                if let m = Self.picksMatch(ranked, out["rank"]!.arr) { failures.append("\(tag) rank: \(m)") }
                for s in out["select"]!.arr {
                    let fraction = Float(s["fraction"]!.doubleValue!)
                    let got = MusicRecommendationEngine.select(ranked, limit: s["limit"]!.int, explorationFraction: fraction).map(\.song.id)
                    if got != s["ids"]!.strings { failures.append("\(tag) select \(s["limit"]!.int)/\(fraction): \(got) ≠ \(s["ids"]!.strings)") }
                }
                let m2 = Muselle2.rank(songs: songs, favorites: favorites, signals: e.signals, history: e.history, nowMs: now,
                                       seed: seed, signalSources: e.signalSources, historySources: e.historySources)
                if let m = Self.picksMatch(m2, out["muselle2"]!.arr) { failures.append("\(tag) muselle2: \(m)") }
                for (variant, key) in [(MuselleVariant.basic, "planBasic"), (.plus, "planPlus")] {
                    let plan = HomeRecommendationPlanner.plan(library: songs, favorites: favorites, signals: e.signals,
                                                              history: e.history, discoveries: discoveries, releases: releases,
                                                              nowMs: now, seed: seed, variant: variant,
                                                              signalSources: e.signalSources, historySources: e.historySources)
                    if let m = Self.sectionsMatch(plan.mixes, out[key]!["mixes"]!.arr) { failures.append("\(tag) \(key) mixes: \(m)") }
                    if let m = Self.sectionsMatch(plan.shelves, out[key]!["shelves"]!.arr) { failures.append("\(tag) \(key) shelves: \(m)") }
                }
                let limit = input["smartLimit"]!.int
                for preset in SmartPlaylistPreset.allCases {
                    let got = PremiumSmartPlaylistEngine.build(preset, songs: songs, favorites: favorites, history: e.history,
                                                               signals: e.signals, nowMs: now, seed: seed, limit: limit)
                    if got.songs.map(\.id) != out["smart"]![preset.rawValue]!.strings {
                        failures.append("\(tag) smart \(preset): \(got.songs.map(\.id)) ≠ \(out["smart"]![preset.rawValue]!.strings)")
                    }
                }
                let insights = PremiumInsightEngine.summarize(songs, history: e.history, signals: e.signals)
                let wi = out["insights"]!
                let artists = wi["topArtists"]!.arr.map { ($0.arr[0].str, $0.arr[1].int) }
                let genres = wi["topGenres"]!.arr.map { ($0.arr[0].str, $0.arr[1].int) }
                if insights.songCount != wi["songCount"]!.int || insights.playedSongCount != wi["playedSongCount"]!.int
                    || insights.totalListeningMs != wi["totalListeningMs"]!.i64
                    || insights.completionRatePercent != wi["completionRatePercent"]!.int
                    || insights.discoveryRatePercent != wi["discoveryRatePercent"]!.int
                    || insights.totalListeningLabel != wi["label"]!.str
                    || !insights.topArtists.elementsEqual(artists, by: { $0.name == $1.0 && $0.plays == $1.1 })
                    || !insights.topGenres.elementsEqual(genres, by: { $0.name == $1.0 && $0.count == $1.1 }) {
                    failures.append("\(tag) insights \(insights) ≠ \(wi)")
                }
            case "record":
                let p = input["prev"]!
                let prev = MusicRecommendationEngine.Signal(sessions: p["sessions"]!.int, completions: p["completions"]!.int,
                                                            earlySkips: p["earlySkips"]!.int, voluntaryPlays: p["voluntaryPlays"]!.int,
                                                            lastPlayedMs: p["lastPlayedMs"]!.i64, listenedMs: p["listenedMs"]!.i64)
                let got = MusicRecommendationEngine.record(prev, listenedMs: input["listened"]!.i64, durationMs: input["duration"]!.i64,
                                                           voluntary: input["voluntary"]!.bool, changedTrack: input["changedTrack"]!.bool,
                                                           nowMs: input["now"]!.i64)
                let want = MusicRecommendationEngine.Signal(sessions: out["sessions"]!.int, completions: out["completions"]!.int,
                                                            earlySkips: out["earlySkips"]!.int, voluntaryPlays: out["voluntaryPlays"]!.int,
                                                            lastPlayedMs: out["lastPlayedMs"]!.i64, listenedMs: out["listenedMs"]!.i64)
                if got != want { failures.append("record \(input) → \(got)") }
            case "recentRelease":
                let today = LocalDate.parseISO(input["today"]!.str)!
                if HomeRecommendationPlanner.isRecentRelease(input["value"]!.optStr, today: today) != out.bool {
                    failures.append("recentRelease \(input)")
                }
            default: Issue.record("unknown fn")
            }
        }
        #expect(scenarios == 90)
        #expect(failures.isEmpty, "\(failures.count) mismatches: \(failures.prefix(8).joined(separator: "\n"))")
    }

    // MARK: Stats

    static func summaryJSON(_ s: PlaybackStatsSummary) -> JSONValue {
        func arr(_ items: [JSONValue]) -> JSONValue { .array(items) }
        func str(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
        func timeline(_ t: TimelineEntry) -> JSONValue { arr([.string(t.label), .integer(t.totalDurationMs), .integer(t.playCount)]) }
        func buckets(_ b: [DailyListeningBucket]) -> JSONValue {
            arr(b.map { arr([.integer($0.startMinute), .integer($0.endMinuteExclusive), .integer($0.totalDurationMs)]) })
        }
        var o = JSONObject()
        o.append("start", s.startTimestamp.map(JSONValue.integer) ?? .null)
        o.append("end", .integer(s.endTimestamp))
        o.append("totalDurationMs", .integer(s.totalDurationMs))
        o.append("totalPlayCount", .integer(s.totalPlayCount))
        o.append("uniqueSongs", .integer(s.uniqueSongs))
        o.append("averageDailyDurationMs", .integer(s.averageDailyDurationMs))
        o.append("songs", arr(s.songs.map {
            arr([.string($0.songId), .string($0.title), .string($0.artist), str($0.albumArtUri), .integer($0.totalDurationMs), .integer($0.playCount)])
        }))
        o.append("topSongs", .integer(s.topSongs.count))
        o.append("topGenres", arr(s.topGenres.map { arr([.string($0.genre), .integer($0.totalDurationMs), .integer($0.playCount), .integer($0.uniqueArtists)]) }))
        o.append("timeline", arr(s.timeline.map(timeline)))
        o.append("topArtists", arr(s.topArtists.map { arr([.string($0.artist), .integer($0.totalDurationMs), .integer($0.playCount), .integer($0.uniqueSongs)]) }))
        o.append("topAlbums", arr(s.topAlbums.map {
            arr([.string($0.album), str($0.albumArtUri), .integer($0.totalDurationMs), .integer($0.playCount), .integer($0.uniqueSongs)])
        }))
        o.append("activeDays", .integer(s.activeDays))
        o.append("longestStreakDays", .integer(s.longestStreakDays))
        o.append("totalSessions", .integer(s.totalSessions))
        o.append("averageSessionDurationMs", .integer(s.averageSessionDurationMs))
        o.append("longestSessionDurationMs", .integer(s.longestSessionDurationMs))
        o.append("averageSessionsPerDay", .string("0x" + String(s.averageSessionsPerDay.bitPattern, radix: 16)))
        if let d = s.dayListeningDistribution {
            var dj = JSONObject()
            dj.append("bucketSizeMinutes", .integer(d.bucketSizeMinutes))
            dj.append("buckets", buckets(d.buckets))
            dj.append("max", .integer(d.maxBucketDurationMs))
            dj.append("days", arr(d.days.map { day in
                var x = JSONObject()
                x.append("date", .string(day.date.description))
                x.append("buckets", buckets(day.buckets))
                x.append("total", .integer(day.totalDurationMs))
                return .object(x)
            }))
            o.append("distribution", .object(dj))
        } else {
            o.append("distribution", .null)
        }
        o.append("peakTimeline", s.peakTimeline.map(timeline) ?? .null)
        o.append("peakDayLabel", str(s.peakDayLabel))
        o.append("peakDayDurationMs", .integer(s.peakDayDurationMs))
        return .object(o)
    }

    @Test func statsMatchAndroid() throws {
        var failures: [String] = []
        var ranges = 0
        for line in try goldenLines("stats-golden.jsonl") {
            let input = line["in"]!, out = line["out"]!
            let zone = try #require(TimeZone(identifier: input["zone"]!.str), "time zone \(input["zone"]!.str)")
            let songs = input["songs"]!.arr.map(fixtureSong)
            let events = input["events"]!.arr.map { e in
                PlaybackEvent(songId: e.arr[0].str, timestamp: e.arr[1].i64, durationMs: e.arr[2].i64,
                              startTimestamp: e.arr[3].isNull ? nil : e.arr[3].i64, endTimestamp: e.arr[4].isNull ? nil : e.arr[4].i64)
            }
            for range in StatsTimeRange.allCases {
                guard let want = out[range.rawValue] else { continue }
                ranges += 1
                let summary = PlaybackStats.buildSummary(range: range, songs: songs, nowMillis: input["now"]!.i64,
                                                         events: events, timeZone: zone)
                let got = JSONWriter.write(Self.summaryJSON(summary)), expected = JSONWriter.write(want)
                if got != expected {
                    failures.append("\(input["zone"]!.str) \(input["now"]!.i64) \(range):\n got \(got)\nwant \(expected)")
                }
            }
        }
        #expect(ranges >= 600)
        #expect(failures.isEmpty, "\(failures.count) mismatches: \(failures.prefix(3).joined(separator: "\n"))")
    }

    // MARK: playback_history.json

    /// Inputs only Gson's lenient reader accepts (comments, single quotes, unquoted names): documented deviation.
    static let lenientOnly: Set<String> = [
        "[{'songId':'a','timestamp':1000,'durationMs':1}]",
        "[{songId:a,timestamp:1000,durationMs:1}]",
        "[{\"songId\":\"a\",\"timestamp\":1000,\"durationMs\":1} // c\n]",
    ]

    @Test func historyCodecMatchesAndroid() throws {
        var failures: [String] = []
        for line in try goldenLines("history-codec-golden.jsonl") {
            let input = line["in"]!, out = line["out"]!
            switch line["fn"]!.str {
            case "parse":
                if let text = input.optStr, Self.lenientOnly.contains(text) {
                    #expect(PlaybackHistoryCodec.decode(text).isEmpty)
                    continue
                }
                let got = PlaybackHistoryCodec.encode(PlaybackHistoryCodec.decode(input.optStr))
                if got != out.str { failures.append("parse \(String(reflecting: input.optStr)) → \(got) ≠ \(out.str)") }
            case "serialize":
                let events = input.arr.map { e in
                    PlaybackEvent(songId: e.arr[0].str, timestamp: e.arr[1].i64, durationMs: e.arr[2].i64,
                                  startTimestamp: e.arr[3].isNull ? nil : e.arr[3].i64, endTimestamp: e.arr[4].isNull ? nil : e.arr[4].i64)
                }
                let got = PlaybackHistoryCodec.encode(events)
                if got != out.str { failures.append("serialize → \(got) ≠ \(out.str)") }
                if PlaybackHistoryCodec.encode(PlaybackHistoryCodec.decode(got)) != got { failures.append("round trip \(got)") }
            default: Issue.record("unknown fn")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) mismatches: \(failures.prefix(8).joined(separator: "\n"))")
    }

    // MARK: Search

    @Test func searchMatchesAndroidSQLite() throws {
        let lines = try goldenLines("search-golden.jsonl")
        let library = try #require(lines.first { $0["fn"]!.str == "library" })["in"]!
        var albumSongCounts: [Int64: Int] = [:]
        var artistSongCounts: [Int64: Int] = [:]
        let songs = library["songs"]!.arr.map { r -> Song in
            let a = r.arr
            albumSongCounts[a[4].i64, default: 0] += 1
            artistSongCounts[a[5].i64, default: 0] += 1
            var s = Song.emptySong()
            s.id = String(a[0].i64)
            s.title = a[1].str
            s.artist = a[2].str
            s.genre = a[3].optStr
            s.albumId = a[4].i64
            return s
        }
        let albums = library["albums"]!.arr.map { r in
            Album(id: r.arr[0].i64, title: r.arr[1].str, artist: r.arr[2].str, year: 0, dateAdded: 0, albumArtUriString: nil,
                  songCount: albumSongCounts[r.arr[0].i64] ?? 0)
        }
        let artists = library["artists"]!.arr.map { r in
            Artist(id: r.arr[0].i64, name: r.arr[1].str, songCount: artistSongCounts[r.arr[0].i64] ?? 0)
        }
        let index = SearchIndex(songs: songs, albums: albums, artists: artists)
        var failures: [String] = []
        var cases = 0
        for line in lines {
            let input = line["in"]!, out = line["out"]!
            switch line["fn"]!.str {
            case "library": continue
            case "songs":
                cases += 1
                let q = input["q"]!.str, titleOnly = input["titleOnly"]!.bool
                if SearchIndex.matchQuery(q, titleOnly: titleOnly) != out["match"]!.str {
                    failures.append("match \(q): \(SearchIndex.matchQuery(q, titleOnly: titleOnly)) ≠ \(out["match"]!.str)")
                }
                let fts = index.ftsSongs(q, titleOnly: titleOnly, limit: 100).map(\.id)
                if fts != out["fts"]!.arr.map({ String($0.i64) }) { failures.append("fts \(q) \(titleOnly): \(fts) ≠ \(out["fts"]!)") }
                let like = index.likeSongs(q.kotlinTrimmed(), titleOnly: titleOnly, limit: 100).map(\.id)
                if like != out["like"]!.arr.map({ String($0.i64) }) { failures.append("like \(q) \(titleOnly): \(like) ≠ \(out["like"]!)") }
                let merged = index.mergedSongs(q, titleOnly: titleOnly, limit: 100).map(\.id)
                if merged != out["merged"]!.arr.map({ String($0.i64) }) { failures.append("merged \(q)") }
            case "albums":
                let got = index.likeAlbums(input["q"]!.str, minTracks: input["minTracks"]!.int, limit: 100).map(\.id)
                if got != out.arr.map(\.i64) { failures.append("albums \(input) → \(got) ≠ \(out)") }
            case "artists":
                let got = index.likeArtists(input.str, limit: 100).map(\.id)
                if got != out.arr.map(\.i64) { failures.append("artists \(input) → \(got) ≠ \(out)") }
            case "playlists":
                let q = input["q"]!.str
                let got = input["names"]!.strings.map { KotlinText.contains($0, q, ignoreCase: true) }
                if got != out.arr.map(\.bool) { failures.append("playlists \(input) → \(got)") }
            default: Issue.record("unknown fn")
            }
        }
        #expect(cases >= 200)
        #expect(failures.isEmpty, "\(failures.count) mismatches: \(failures.prefix(10).joined(separator: "\n"))")
    }
}
