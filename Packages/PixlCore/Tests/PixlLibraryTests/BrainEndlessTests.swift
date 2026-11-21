import Foundation
import PixlModel
import Testing
@testable import PixlLibrary

/// Endless Listening, milestone E1: the island seed picker and the host notes (the pure core) against Android's golden file
/// `endless.jsonl`, the same unit cases as Android's `EndlessTest`, and the station of source 6 (`EndlessStationTest`).
@Suite("Endless Listening (brainMatchesAndroid)")
struct BrainEndlessTests {
    typealias G = BrainGoldenTests

    // MARK: endless.jsonl

    private static func tracks(_ v: BrainJson.Value?) -> [EndlessSeeds.Track] {
        (v?.arrayValue ?? []).map { t in
            let a = t.arrayValue ?? []
            return EndlessSeeds.Track(rid: a[0].longValue ?? 0, aid: a[1].longValue ?? 0, weight: a[2].doubleValue ?? .nan)
        }
    }

    @Test func goldenMatchesAndroid() throws {
        var report = G.Report(file: "endless.jsonl")
        var counts: [String: Int] = [:]
        for c in try G.cases("endless.jsonl") {
            counts[c.fn, default: 0] += 1
            let i = c.input
            switch c.fn {
            case "seeds":
                let islands = G.array(i, "islands").map { v -> EndlessSeeds.IslandIn in
                    let a = v.arrayValue ?? []
                    return EndlessSeeds.IslandIn(id: Int(a[0].bareLong ?? 0), weight: a[1].doubleValue ?? .nan, tracks: Self.tracks(a[2]))
                }
                let artists = G.array(i, "artists").map { v -> EndlessSeeds.ArtistIn in
                    let a = v.arrayValue ?? []
                    return EndlessSeeds.ArtistIn(aid: a[0].longValue ?? 0, weight: a[1].doubleValue ?? .nan, tracks: Self.tracks(a[2]))
                }
                let seeds = EndlessSeeds.pick(islands: islands, artists: artists)
                report.record(c, c.matches {
                    $0.beginArray("seeds")
                    for s in seeds { $0.beginArray(); $0.longItem(s.rid); $0.longItem(s.aid); $0.intItem(s.islandId); $0.endArray() }
                    $0.endArray()
                })
            case "notes":
                let slots = G.array(i, "slots").map { v -> HostNotes.Slot in
                    let a = v.arrayValue ?? []
                    return HostNotes.Slot(artist: a[0].stringValue ?? "", genre: a[1].stringValue ?? "", genreFact: a[2].stringValue ?? "",
                                          year: Int(a[3].bareLong ?? 0), island: a[4].stringValue ?? "",
                                          newFromPlayedArtist: (a[5].bareLong ?? 0) == 1, sideways: (a[6].bareLong ?? 0) == 1)
                }
                let taken = G.array(i, "taken").map { v -> HostNotes.Taken in
                    let a = v.arrayValue ?? []
                    return HostNotes.Taken(index: Int(a[0].bareLong ?? 0), span: Int(a[1].bareLong ?? 0))
                }
                let notes = HostNotes.notes(slots, taken: taken)
                report.record(c, c.matches {
                    $0.beginArray("notes")
                    for x in notes {
                        $0.beginArray(); $0.intItem(x.index); $0.intItem(x.kind); $0.stringItem(x.a); $0.stringItem(x.b)
                        $0.stringItem(HostNotes.text(x)); $0.endArray()
                    }
                    $0.endArray()
                })
            case "notes_since":
                let slots = G.array(i, "slots").map { v -> HostNotes.Slot in
                    let a = v.arrayValue ?? []
                    return HostNotes.Slot(artist: a[0].stringValue ?? "", genre: a[1].stringValue ?? "", genreFact: a[2].stringValue ?? "",
                                          year: Int(a[3].bareLong ?? 0), island: a[4].stringValue ?? "",
                                          newFromPlayedArtist: (a[5].bareLong ?? 0) == 1, sideways: (a[6].bareLong ?? 0) == 1)
                }
                let since = Int(i["since"]?.bareLong ?? 0)
                let notes = HostNotes.notes(slots, taken: [], sinceLast: since)
                report.record(c, c.matches {
                    $0.beginArray("notes")
                    for x in notes {
                        $0.beginArray(); $0.intItem(x.index); $0.intItem(x.kind); $0.stringItem(x.a); $0.stringItem(x.b)
                        $0.stringItem(HostNotes.text(x)); $0.endArray()
                    }
                    $0.endArray()
                })
            case "since_note":
                let ids = G.array(i, "ids").map { $0.stringValue ?? "" }
                let noted = Set(G.array(i, "noted").map { $0.stringValue ?? "" })
                let index = Int(i["index"]?.bareLong ?? 0)
                let since = HostNotes.tracksSinceNote(ids, index: index, noted: noted)
                report.record(c, c.matches { $0.int("since", since) })
            case "note_names":
                let a = G.array(i, "slot")
                let slot = HostNotes.Slot(artist: a[0].stringValue ?? "", genre: a[1].stringValue ?? "", genreFact: a[2].stringValue ?? "",
                                          year: Int(a[3].bareLong ?? 0), island: a[4].stringValue ?? "",
                                          newFromPlayedArtist: (a[5].bareLong ?? 0) == 1, sideways: (a[6].bareLong ?? 0) == 1)
                let notes = HostNotes.notes([slot])
                report.record(c, c.matches {
                    $0.beginArray("notes")
                    for x in notes {
                        $0.beginArray(); $0.intItem(x.index); $0.intItem(x.kind); $0.stringItem(x.a); $0.stringItem(x.b)
                        $0.stringItem(HostNotes.text(x)); $0.endArray()
                    }
                    $0.endArray()
                })
            case "fact":
                let f = HostNotes.factOf(G.string(i, "raw"))
                report.record(c, c.matches { $0.string("fact", f) })
            case "speakable":
                let ok = HostNotes.isSpeakable(G.string(i, "text"))
                report.record(c, c.matches { $0.bool("ok", ok) })
            default: report.record(c, false)
            }
        }
        report.verify(atLeast: 190)
        #expect(counts["seeds"] == 60)
        #expect(counts["notes"] == 70)
        #expect(counts["fact"] == 9)
        #expect(counts["speakable"] == 8)
        #expect(counts["notes_since"] == 30)
        #expect(counts["since_note"] == 20)
        #expect(counts["note_names"] == 7)
    }

    @Test func theEndlessFileIsInTheManifest() throws {
        let manifest = String(decoding: try G.fixtureData("MANIFEST.sha256"), as: UTF8.self)
        #expect(manifest.contains("  endless.jsonl"), "endless.jsonl is not in MANIFEST.sha256")
    }

    // MARK: EndlessSeeds

    private func t(_ rid: Int64, _ aid: Int64, _ w: Double) -> EndlessSeeds.Track { EndlessSeeds.Track(rid: rid, aid: aid, weight: w) }

    @Test func oneSeedPerIslandBiggestFirstTheMostPlayedTrackOfEach() {
        let islands = [
            EndlessSeeds.IslandIn(id: 1, weight: 2, tracks: [t(10, 1, 3), t(11, 2, 9)]),
            EndlessSeeds.IslandIn(id: 2, weight: 5, tracks: [t(20, 3, 1)]),
            EndlessSeeds.IslandIn(id: 3, weight: 1, tracks: [t(30, 4, 0)]),
        ]
        let seeds = EndlessSeeds.pick(islands: islands, artists: [])
        #expect(seeds.map(\.rid) == [20, 11, 30])
        #expect(seeds.map(\.islandId) == [2, 1, 3])
    }

    @Test func atMostFiveSeedsAndNoArtistTwice() {
        let islands = (1...8).map { k -> EndlessSeeds.IslandIn in
            EndlessSeeds.IslandIn(id: k, weight: Double(10 - k),
                                  tracks: [t(Int64(k) * 10, k <= 2 ? 7 : Int64(k), 1), t(Int64(k) * 10 + 1, 50 + Int64(k), 0.5)])
        }
        let seeds = EndlessSeeds.pick(islands: islands, artists: [])
        #expect(seeds.count == 5)
        let aids = seeds.map(\.aid).filter { $0 != 0 }
        #expect(Set(aids).count == aids.count)
        // The second island's best track is by the artist the first island already seeded with: its next track stands in.
        #expect(seeds.prefix(2).map(\.rid) == [10, 21])
    }

    @Test func anIslandWithNoUsableTrackIsSkippedTiesGoToTheLowerRecordingId() {
        let islands = [
            EndlessSeeds.IslandIn(id: 1, weight: 3, tracks: []),
            EndlessSeeds.IslandIn(id: 2, weight: 2, tracks: [t(0, 1, 9), t(25, 2, 4), t(24, 3, 4)]),
            EndlessSeeds.IslandIn(id: 3, weight: 1, tracks: [t(30, 4, 1)]),
        ]
        #expect(EndlessSeeds.pick(islands: islands, artists: []).map(\.rid) == [24, 30])
    }

    @Test func fewerThanTwoIslandsFallBackToTheTopArtists() {
        let one = [EndlessSeeds.IslandIn(id: 1, weight: 5, tracks: [t(10, 1, 3)])]
        let artists = [
            EndlessSeeds.ArtistIn(aid: 70, weight: 1, tracks: [t(701, 70, 1)]),
            EndlessSeeds.ArtistIn(aid: 71, weight: 9, tracks: [t(711, 71, 2), t(712, 71, 5)]),
            EndlessSeeds.ArtistIn(aid: 72, weight: 4, tracks: []),
        ]
        let seeds = EndlessSeeds.pick(islands: one, artists: artists)
        #expect(seeds.map(\.rid) == [712, 701])
        #expect(seeds.allSatisfy { $0.islandId == -1 })
        #expect(EndlessSeeds.pick(islands: [], artists: []).isEmpty)
        // Two islands that cannot give two seeds (one artist) fall back as well.
        let same = [
            EndlessSeeds.IslandIn(id: 1, weight: 2, tracks: [t(10, 1, 1)]),
            EndlessSeeds.IslandIn(id: 2, weight: 1, tracks: [t(20, 1, 1)]),
        ]
        #expect(EndlessSeeds.pick(islands: same, artists: [EndlessSeeds.ArtistIn(aid: 2, weight: 1, tracks: [t(30, 2, 1)])]).map(\.rid) == [30])
    }

    // MARK: HostNotes

    private func slot(artist: String = "A", genre: String = "", fact: String = "", year: Int = 0, island: String = "",
                      fresh: Bool = false, side: Bool = false) -> HostNotes.Slot {
        HostNotes.Slot(artist: artist, genre: genre, genreFact: fact, year: year, island: island, newFromPlayedArtist: fresh, sideways: side)
    }

    @Test func aSlotWithNothingRealToSayHasNoNote() {
        #expect(HostNotes.notes(Array(repeating: slot(), count: 12)).isEmpty)
        // A year outside 1900 to 2100 is not a year; a fact that is too long is dropped, not cut.
        #expect(HostNotes.notes([slot(year: 1850), slot(year: 2500), slot(genre: "Pop", fact: "a b c d e f g h i j k l m n o p")]).isEmpty)
    }

    @Test func eachKindFillsItsTemplateFromItsOwnData() {
        let notes = HostNotes.notes([
            slot(artist: "Mono", fresh: true),
            slot(), slot(), slot(), slot(),
            slot(genre: "Shoegaze"), // the genre before is "": no step sideways
            slot(), slot(), slot(), slot(),
            slot(island: "Bedroom pop"),
            slot(), slot(), slot(), slot(),
            slot(genre: "Dream pop", fact: "Hazy pop made of echo."),
            slot(), slot(), slot(), slot(),
            slot(year: 1999),
        ])
        #expect(notes.map { HostNotes.text($0) } == [
            "New from Mono, an artist you play.",
            "From your Bedroom pop side.",
            "Dream pop: Hazy pop made of echo.",
            "Released in 1999.",
        ])
        #expect(notes.map(\.index) == [0, 10, 15, 20])
    }

    @Test func aStepSidewaysNamesOnlyTheGenreTheEngineFlaggedWithNoFromGenre() {
        // The engine computed one thing: this pick is from a genre next to the listener's own. No earlier track is needed and none is named.
        let alone = HostNotes.notes([slot(genre: "Bossa nova", side: true)])
        #expect(alone.count == 1)
        #expect(HostNotes.text(alone[0]) == "A step sideways: Bossa nova.")
        #expect(alone[0].index == 0)
        let after = HostNotes.notes([slot(genre: "K-pop"), slot(genre: "K-pop"), slot(genre: "Bossa nova", side: true)])
        #expect(after.map { HostNotes.text($0) } == ["A step sideways: Bossa nova."])
        #expect(after[0].index == 2)
        // No genre, no note.
        #expect(HostNotes.notes([slot(side: true)]).isEmpty)
    }

    @Test func theLastNotesDistanceKeepsTheCadenceAcrossWindows() {
        let all = (0..<20).map { slot(year: 2000 + $0) }
        // Nothing before: the current track has a note, then every fifth.
        #expect(HostNotes.notes(all).map(\.index) == [0, 5, 10, 15])
        // A note one track ago: the window starts four tracks later, the same absolute tracks as before.
        #expect(HostNotes.notes(all, sinceLast: 1).map(\.index) == [4, 9, 14, 19])
        #expect(HostNotes.notes(all, sinceLast: 3).map(\.index) == [2, 7, 12, 17])
        // Four tracks ago: the current track is free again; five or more is the same as none.
        #expect(HostNotes.notes(all, sinceLast: 4).map(\.index) == [1, 6, 11, 16])
        #expect(HostNotes.notes(all, sinceLast: 5).map(\.index) == HostNotes.notes(all).map(\.index))
        #expect(HostNotes.notes(all, sinceLast: 99).map(\.index) == HostNotes.notes(all).map(\.index))
    }

    @Test func tracksSinceANoteLooksOnlyAtTheFourTracksBeforeAndOnlyAtSongsThatHadOne() {
        let ids = ["a", "b", "c", "d", "e", "f", "g"]
        #expect(HostNotes.tracksSinceNote(ids, index: 4, noted: []) == HostNotes.minGap)
        #expect(HostNotes.tracksSinceNote(ids, index: 4, noted: ["d"]) == 1)
        #expect(HostNotes.tracksSinceNote(ids, index: 4, noted: ["b", "a"]) == 3)
        // The nearest one wins; five tracks back is out of reach; the song itself does not count.
        #expect(HostNotes.tracksSinceNote(ids, index: 4, noted: ["b", "c", "a"]) == 2)
        #expect(HostNotes.tracksSinceNote(ids, index: 5, noted: ["a"]) == HostNotes.minGap)
        #expect(HostNotes.tracksSinceNote(ids, index: 4, noted: ["e"]) == HostNotes.minGap)
        #expect(HostNotes.tracksSinceNote(ids, index: 0, noted: ["a"]) == HostNotes.minGap)
    }

    @Test func walkingTheQueueOneTrackAtATimeNeverShowsTwoNotesWithinFiveTracks() {
        let queue = (0..<30).map { slot(year: 2000 + $0, island: "Pop") }
        let ids = (0..<queue.count).map { "s\($0)" }
        var noted = Set<String>()
        var last = -100
        for current in queue.indices {
            let window = Array(queue[current..<min(queue.count, current + 40)])
            let notes = HostNotes.notes(window, sinceLast: HostNotes.tracksSinceNote(ids, index: current, noted: noted))
            if notes.first?.index == 0 {
                #expect(current - last >= HostNotes.minGap, "a note on \(current) after one on \(last)")
                noted.insert(ids[current])
                last = current
            }
        }
        #expect(ids.indices.filter { noted.contains(ids[$0]) } == [0, 5, 10, 15, 20, 25])
    }

    @Test func aNameIsNotCopyButTheTemplateAndTheFactAre() {
        #expect(HostNotes.notes([slot(artist: "Claude Debussy", fresh: true)]).map { HostNotes.text($0) } == ["New from Claude Debussy, an artist you play."])
        #expect(HostNotes.notes([slot(artist: "Atmosphere", fresh: true)]).map { HostNotes.text($0) } == ["New from Atmosphere, an artist you play."])
        // "learn" and "atmos" are whole words only: "learner" is not "learn".
        #expect(HostNotes.isClean("A learner and the Atmosphere."))
        #expect(!HostNotes.isClean("Learn the genre."))
        #expect(!HostNotes.isClean("Dolby Atmos sound."))
        #expect(!HostNotes.isClean("Hi-Res audio."))
        // A fact (the atlas' sentence) with a banned word is dropped, a clean one stays.
        #expect(HostNotes.notes([slot(genre: "Dance", fact: "Made for learn and lossless nights.")]).isEmpty)
        #expect(HostNotes.notes([slot(genre: "Dance", fact: "Made for late nights.")]).count == 1)
    }

    @Test func atMostOneNotePerFiveTracksAndNoneInsideASetNote() {
        let all = (0..<40).map { slot(year: 2000 + $0 % 20, island: "Pop") }
        let notes = HostNotes.notes(all)
        for i in 1..<notes.count { #expect(notes[i].index - notes[i - 1].index >= 5) }
        let taken = [HostNotes.Taken(index: 2, span: 4), HostNotes.Taken(index: 14, span: 6)]
        let withSet = HostNotes.notes(all, taken: taken)
        for n in withSet {
            for s in taken {
                #expect(!(n.index >= s.index && n.index < s.index + s.span), "note \(n.index) inside the set note at \(s.index)")
                #expect(n.index >= s.index + max(s.span, 5) || n.index <= s.index - 5, "note \(n.index) too near \(s.index)")
            }
        }
        for i in 1..<withSet.count { #expect(withSet[i].index - withSet[i - 1].index >= 5) }
    }

    @Test func aTextWithAWordTheAppNeverSaysOrALongSentenceIsNotSpoken() {
        #expect(HostNotes.isSpeakable("From your Bedroom pop side."))
        #expect(!HostNotes.isSpeakable("Dance music with a lossless feel."))
        #expect(!HostNotes.isSpeakable("Learn the genre."))
        #expect(!HostNotes.isSpeakable("One. Two. Three."))
        #expect(!HostNotes.isSpeakable("A very very very very very very very very very very long sentence here."))
        #expect(!HostNotes.isSpeakable(""))
        // A genre fact that holds a forbidden word never becomes a note.
        #expect(HostNotes.notes([slot(genre: "House", fact: "Dance music with a lossless feel.")]).isEmpty)
    }

    @Test func everyKindsTextIsShortEnoughToBeSpoken() {
        let notes = [
            HostNotes.Note(index: 0, kind: HostNotes.kindNewFromArtist, a: "HIEUTHUHAI", b: ""),
            HostNotes.Note(index: 0, kind: HostNotes.kindSideways, a: "Bedroom pop", b: ""),
            HostNotes.Note(index: 0, kind: HostNotes.kindIsland, a: "Soft pop & R&B", b: ""),
            HostNotes.Note(index: 0, kind: HostNotes.kindGenreFact, a: "Dream pop", b: "Hazy pop made of echo and reverb"),
            HostNotes.Note(index: 0, kind: HostNotes.kindYear, a: "2019", b: ""),
        ]
        for n in notes { #expect(HostNotes.isSpeakable(HostNotes.text(n)), "\(HostNotes.text(n))") }
    }

    @Test func factReadsTheFirstSentenceOnly() {
        #expect(HostNotes.factOf("Hushed pop. It began in 1985.") == "Hushed pop")
        #expect(HostNotes.factOf("  ") == "")
        #expect(HostNotes.factOf("No full stop") == "No full stop")
    }

    // MARK: The station of source 6

    @Test func anEndlessStationKeepsItsSourceAndItsFiveSeedsThroughARestart() {
        let station = Station.endless(seedMediaIds: ["10", "11", "12", "13", "14"], title: "Endless Listening", nowMs: 9)
        #expect(station.source == Station.sourceEndless)
        #expect(Station.sourceEndless == 6)
        #expect(station.kind == Session.seedStationSong)
        #expect(station.isEndless)
        #expect(!station.isArtist)
        let back = Station.decode(station.encode())
        #expect(back == station)
        #expect(back?.source == Station.sourceEndless)
        #expect(back?.seedMediaIds == ["10", "11", "12", "13", "14"])
        #expect(back?.title == "Endless Listening")
    }

    @Test func itIsAStationOfItsOwnNotTheSameAsAPlaylistStationFromTheSameFirstSeed() {
        let endless = Station.endless(seedMediaIds: ["10", "11"], title: "Endless Listening", nowMs: 1)
        #expect(endless.id != Station.fromSource(Station.sourcePlaylist, seedMediaIds: ["10", "11"], title: "Endless Listening", nowMs: 1).id)
        #expect(endless.id != Station.song(seedMediaId: "10", title: "T", primaryArtist: "A", nowMs: 1).id)
        // The same seeds on another day are the same station (its id is for its plays' surface, not the day).
        #expect(endless.id == Station.endless(seedMediaIds: ["10", "11"], title: "Endless Listening", nowMs: 99).id)
    }

    @Test func theRadiosOfEveryIslandSeedAreAsked() {
        let seeds = ["a", "b", "c", "d", "e"]
        let station = Station.endless(seedMediaIds: seeds, title: "Endless Listening", nowMs: 1)
        // The pool of a station is seeded from every one of its seeds, and the two re-seeds fit beside them.
        #expect(StationReseed.seedIds(primary: "a", station: station, reseedIds: ["x", "y"]) == ["a", "b", "c", "d", "e", "x", "y"])
        #expect(StationReseed.seedIds(primary: "a", station: station, reseedIds: []) == seeds)
    }

    @Test func stringsSavedBeforeSource6ExistedStillDecodeAndASourceBeyondItIsRefused() {
        let sep = "\u{1F}"
        let kind = String(Session.seedStationSong)
        let five = [kind, "m1", "Title", "Artist", "7"].joined(separator: sep)
        #expect(Station.decode(five)?.source == Station.sourceSong)
        for source in 0...5 {
            let seven = [kind, "m1", "T", "A", "7", String(source), "m1"].joined(separator: sep)
            let decoded = Station.decode(seven)
            #expect(decoded?.source == source, "source \(source)")
            #expect(decoded?.isEndless == false)
        }
        let endless = [kind, "m1", "Endless Listening", "", "7", "6", "m1\u{1E}m2"].joined(separator: sep)
        #expect(Station.decode(endless)?.seedMediaIds == ["m1", "m2"])
        #expect(Station.decode(endless)?.isEndless == true)
        #expect(Station.decode([kind, "m1", "T", "A", "7", "7", "m1"].joined(separator: sep)) == nil)
        #expect(Station.decode(nil) == nil)
        #expect(Station.decode("") == nil)
    }
}

/// The host's notes of Endless Listening in the queue (Android `SetNoteLinesHostTest`): they come from real facts only, never share a track
/// with a set note, and come at most once in five tracks. Without host facts the queue has the set notes alone.
@Suite("Host notes on the queue")
struct SetNoteLinesHostTests {
    private func library(_ id: String, _ artist: String, genre: String? = nil, year: Int = 0) -> Song {
        Song(id: id, title: "T\(id)", artist: artist, artistId: 1, artists: [ArtistRef(id: 1, name: artist, isPrimary: true)], album: "A",
             albumId: 7, path: "", contentUriString: "content://x/\(id)", albumArtUriString: nil, duration: 1_000, genre: genre,
             year: year, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    private func outside(_ id: String, _ artist: String) -> Song {
        Song(id: "yt:" + id, title: "T\(id)", artist: artist, artistId: -1, artists: [ArtistRef(id: -1, name: artist, isPrimary: true)],
             album: "A", albumId: -1, path: "", contentUriString: "pixlstream://\(id)", albumArtUriString: nil, duration: 1_000,
             genre: nil, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    private func facts(islands: [String: String] = [:], why: [String: String] = [:],
                       genreFact: @escaping @Sendable (String) -> String = { _ in "" }) -> SetNoteLines.HostFacts {
        SetNoteLines.HostFacts(islandOf: islands, whyKeyOf: why, genreFact: genreFact)
    }

    private var eight: [Song] { (1...8).map { library("\($0)", "Artist \($0)") } }

    @Test func withoutHostFactsTheQueueHasNoHostNote() {
        #expect(SetNoteLines.forQueue(eight, currentIndex: 0, heard: [], host: nil).byIndex.isEmpty)
        #expect(SetNoteLines.forQueue(eight, currentIndex: 0, heard: []).byIndex.isEmpty)
    }

    @Test func anIslandNameMakesANoteAndTheNextOneIsAtLeastFiveTracksLater() {
        var islands: [String: String] = [:]
        for song in eight { islands[song.id] = "Soft pop" }
        let notes = SetNoteLines.forQueue(eight, currentIndex: 0, heard: Set(eight.map(\.id)), host: facts(islands: islands))
        #expect(Set(notes.byIndex.keys) == [0, 5])
        #expect(notes.byIndex[0] == "From your Soft pop side.")
        #expect(notes.current == "From your Soft pop side.")
    }

    @Test func aNewReleaseByAnArtistYouPlayComesFirstAndATrackNothingIsKnownAboutHasNoNote() {
        let queue = [library("1", "Clairo"), library("2", "Mono")]
        let notes = SetNoteLines.forQueue(queue, currentIndex: 0, heard: [], host: facts(why: ["1": "new_release"]))
        #expect(notes.byIndex == [0: "New from Clairo, an artist you play."])
        #expect(SetNoteLines.forQueue(queue, currentIndex: 0, heard: [], host: facts()).byIndex.isEmpty)
    }

    @Test func aYearOrAShortGenreFactIsUsedOnlyWhenItIsReallyThere() {
        let withYear = [library("1", "A", year: 1999), library("2", "B")]
        #expect(SetNoteLines.forQueue(withYear, currentIndex: 0, heard: [], host: facts()).byIndex == [0: "Released in 1999."])
        #expect(SetNoteLines.forQueue([library("1", "A", year: 12)], currentIndex: 0, heard: [], host: facts()).byIndex.isEmpty)
        let withGenre = [library("1", "A", genre: "Shoegaze")]
        let fact = facts(genreFact: { $0 == "Shoegaze" ? "Guitar noise as a wall of sound. More text after." : "" })
        #expect(SetNoteLines.forQueue(withGenre, currentIndex: 0, heard: [], host: fact).byIndex == [0: "Shoegaze: Guitar noise as a wall of sound."])
        // A description too long to say as it stands is not shortened: the note is dropped.
        let long = facts(genreFact: { _ in "A very long description that goes on and on past what a short note can hold at all, honestly." })
        #expect(SetNoteLines.forQueue(withGenre, currentIndex: 0, heard: [], host: long).byIndex.isEmpty)
    }

    @Test func aTrackNeverHasTwoNotesASetNoteKeepsTheHostAwayFromTheTracksItDescribes() {
        let queue = [library("1", "A", genre: "pop"), library("2", "B", genre: "pop"), library("3", "C", genre: "pop"),
                     outside("aaaaaaaaaa4", "D"), library("5", "E"), library("6", "F"), library("7", "G"), library("8", "H")]
        var islands: [String: String] = [:]
        for song in queue { islands[song.id] = "Soft pop" }
        let result = SetNoteLines.forQueue(queue, currentIndex: 0, heard: Set(queue.map(\.id)).subtracting(["yt:aaaaaaaaaa4"]),
                                           host: facts(islands: islands))
        // The set note is on the first of its three tracks; the host speaks again only after the five tracks it covers.
        #expect(result.byIndex[0] == "Three from your pop side, then something new from D.")
        #expect(result.byIndex.keys.filter { (1...4).contains($0) }.isEmpty)
        #expect(Set(result.byIndex.keys) == [0, 5])
        #expect(result.byIndex[5] == "From your Soft pop side.")
    }

    @Test func anIslandNoteNeedsARecordedPlayAndANewReleaseMustNotHaveBeenHeard() {
        let queue = [library("1", "Clairo"), library("2", "Mono")]
        let islands = ["1": "Soft pop", "2": "Soft pop"]
        #expect(SetNoteLines.forQueue(queue, currentIndex: 0, heard: [], host: facts(islands: islands)).byIndex.isEmpty)
        #expect(SetNoteLines.forQueue(queue, currentIndex: 0, heard: ["1"], host: facts(islands: islands)).byIndex == [0: "From your Soft pop side."])
        // The stale reason of a song that was already heard must not claim "new".
        #expect(SetNoteLines.forQueue(queue, currentIndex: 0, heard: ["1"], host: facts(why: ["1": "new_release"])).byIndex.isEmpty)
    }

    @Test func movingOnOneTrackAtATimeKeepsOneNoteInFiveTracks() {
        var islands: [String: String] = [:]
        for song in eight { islands[song.id] = "Soft pop" }
        let heard = Set(eight.map(\.id))
        let f = facts(islands: islands)
        // Track 0 shows its note; going on to tracks 1 to 4 shows none (the card used to repeat at every track); track 5 may.
        let shown = (0...6).filter { SetNoteLines.forQueue(eight, currentIndex: $0, heard: heard, host: f).current != nil }
        #expect(shown == [0, 5])
    }

    @Test func theCardTheRowsAndTheVoiceShareOneMemoryAndSoAgree() {
        // The three callers (player card, queue rows, spoken line) call forQueue on their own with the same facts: whoever asks first
        // for a track marks it, and the others see the same answer for it and for the tracks after it.
        var islands: [String: String] = [:]
        for song in eight { islands[song.id] = "Soft pop" }
        let heard = Set(eight.map(\.id))
        let f = facts(islands: islands)
        for i in 0...6 {
            let card = SetNoteLines.forQueue(eight, currentIndex: i, heard: heard, host: f)
            let rows = SetNoteLines.forQueue(eight, currentIndex: i, heard: heard, host: f)
            let voice = SetNoteLines.forQueue(eight, currentIndex: i, heard: heard, host: f)
            #expect(card == rows && rows == voice, "track \(i)")
        }
        #expect(f.memory.has("1") && f.memory.has("6"))
        #expect(!f.memory.has("2"))
    }

    @Test func aStepSidewaysSaysOnlyTheGenreTheEngineFlagged() {
        let queue = [library("1", "A", genre: "k-pop"), library("2", "B", genre: "bossa nova")]
        let notes = SetNoteLines.forQueue(queue, currentIndex: 1, heard: ["1"], host: facts(why: ["2": "adjacent_genre"]))
        #expect(notes.byIndex == [1: "A step sideways: bossa nova."])
    }

    @Test func withEndlessListeningsHostNotesOffTheQueueHasNoNoteAtAll() {
        let queue = [library("1", "A", genre: "pop"), library("2", "B", genre: "pop"), library("3", "C", genre: "pop"), outside("aaaaaaaaaa4", "D")]
        let heard: Set<String> = ["1", "2", "3"]
        #expect(!SetNoteLines.forQueue(queue, currentIndex: 0, heard: heard, host: nil).byIndex.isEmpty, "the set note exists when notes are on")
        #expect(SetNoteLines.forQueue(queue, currentIndex: 0, heard: heard, host: nil, notesOff: true).byIndex.isEmpty)
    }

    @Test func theMemoryKeepsOnlyAFewIdsAndCanBeCleared() {
        let memory = HostNoteMemory()
        for k in 0..<(HostNoteMemory.capacity + 10) { memory.mark("s\(k)") }
        #expect(memory.snapshot().count == HostNoteMemory.capacity)
        #expect(!memory.has("s0") && memory.has("s\(HostNoteMemory.capacity + 9)"))
        memory.mark("s20")
        memory.mark("s20")
        #expect(memory.snapshot().count == HostNoteMemory.capacity)
        memory.clear()
        #expect(memory.snapshot().isEmpty)
    }
}

/// Where the seeds come from (Android `BrainMixesTest`, the two Endless Listening cases): the Your Mix shortlist, the top artists without
/// islands, and nothing for an empty library.
@Suite("Endless Listening seeds")
struct EndlessSeedSourceTests {
    @Test func seedsFromTheTopArtistsWhenThereAreNoIslandsOneLibrarySongEachAtMostFive() async throws {
        let world = BrainMixesTests.World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository)
        let mixes = world.mixes(repository, world.engine(repository))
        let seeds = await mixes.endlessSeeds(now: BrainMixesTests.start)
        #expect(seeds.count == 5)
        #expect(Set(seeds.map(\.aid)).count == 5, "one seed for each artist")
        #expect(Set(seeds.map(\.song.id)).count == 5)
        #expect(seeds.allSatisfy { $0.islandId == -1 }, "no islands: the seeds stand for artists")
        #expect(seeds.allSatisfy { $0.song.id.hasPrefix("lib") }, "library songs only")
        // No island, no island name: the card says nothing it cannot back.
        #expect(await mixes.endlessIslandNames(seeds).isEmpty)
    }

    @Test func noSeedUntilTheListenerHasPlayedSomething() async {
        // A library with nothing played: "starts from what you play" would be false, so the card hides and a tap says to play a few songs first.
        let world = BrainMixesTests.World()
        defer { world.tidy() }
        let repository = world.repository()
        let mixes = world.mixes(repository, world.engine(repository))
        #expect(await mixes.endlessSeeds(now: BrainMixesTests.start).isEmpty)
    }

    @Test func onlySongsTheListenerPlayedCanBeASeed() async {
        let world = BrainMixesTests.World()
        defer { world.tidy() }
        let repository = world.repository()
        await world.listen(repository, songs: 0..<3)
        let mixes = world.mixes(repository, world.engine(repository))
        let seeds = await mixes.endlessSeeds(now: BrainMixesTests.start)
        #expect((2...3).contains(seeds.count), "the three played songs, one for each artist: \(seeds.count)")
        #expect(seeds.allSatisfy { ["lib0", "lib1", "lib2"].contains($0.song.id) }, "never a song nobody played")
    }

    @Test func noSeedsInALibraryWithNothingInIt() async {
        let world = BrainMixesTests.World()
        defer { world.tidy() }
        world.libraryOverride.value = []
        let repository = world.repository()
        let mixes = world.mixes(repository, world.engine(repository))
        #expect(await mixes.endlessSeeds(now: BrainMixesTests.start).isEmpty)
    }
}

/// The chips of "Ask the host" (Android `HostChip`): six, in this order, and what each one asks of the phone.
@Suite("Ask the host chips")
struct HostChipTests {
    @Test func sixChipsInOrderEachWithOneThingToDo() {
        #expect(HostChip.allCases == [.new, .familiar, .why, .upbeat, .slower, .surprise])
        #expect(HostChip.new.noveltyLevel == Novelty.discover)
        #expect(HostChip.familiar.noveltyLevel == Novelty.familiar)
        #expect(HostChip.upbeat.steerChange == "energy_up")
        #expect(HostChip.slower.steerChange == "energy_down")
        #expect(HostChip.surprise.steerChange == "more_new")
        for chip in HostChip.allCases {
            let actions = [chip.noveltyLevel != nil, chip.steerChange != nil, chip == .why].filter { $0 }
            #expect(actions.count == 1, "\(chip) does one thing")
        }
    }
}

@Suite("Ask the host: chips apply to this listening only")
struct HostChipPutBackTests {
    @Test func theLevelBeforeTheChipsComesBackWhenTheStationEnds() {
        var hold = HostNoveltyHold()
        // The listener has Blend saved. "Something new" holds Discover without saving it.
        #expect(hold.hold(level: Novelty.discover, current: Novelty.blend) == Novelty.discover)
        #expect(hold.isHolding)
        // A second chip does not overwrite what was saved.
        #expect(hold.hold(level: Novelty.discover, current: Novelty.discover) == Novelty.discover)
        #expect(hold.savedLevel == Novelty.blend)
        #expect(hold.release() == Novelty.blend)
        #expect(!hold.isHolding && hold.release() == nil, "put back once")
    }

    @Test func backToFamiliarGoesToTheLevelBeforeTheChipsAndNeverToDiscover() {
        var hold = HostNoveltyHold()
        // Nothing held and Discover in force (saved by the listener): back is Blend, not the Discover they had.
        #expect(hold.levelBeforeHost(current: Novelty.discover) == Novelty.blend)
        #expect(hold.levelBeforeHost(current: Novelty.familiar) == Novelty.familiar)
        _ = hold.hold(level: Novelty.discover, current: Novelty.familiar)
        #expect(hold.levelBeforeHost(current: Novelty.discover) == Novelty.familiar, "the level before the chips")
        var discoverSaved = HostNoveltyHold(savedLevel: Novelty.discover)
        #expect(discoverSaved.levelBeforeHost(current: Novelty.discover) == Novelty.blend)
        #expect(discoverSaved.release() == Novelty.discover)
    }

    @Test func aSwitchTheListenerMovesThemselvesCancelsThePutBack() {
        var hold = HostNoveltyHold()
        _ = hold.hold(level: Novelty.discover, current: Novelty.blend)
        hold.forget()
        #expect(hold.release() == nil)
    }

    @Test func aReplyNamesTheNumberTheSteerReallyQueued() {
        #expect(HostSteerReply.of(applied: true, tailChanged: 2, note: "") == .queued(2))
        #expect(HostSteerReply.of(applied: true, tailChanged: 1, note: "") == .queued(1))
        #expect(HostSteerReply.of(applied: true, tailChanged: 5, note: "x") == .queued(5))
        // Applied with nothing queued, or not applied: the engine's own words when it gave some.
        #expect(HostSteerReply.of(applied: true, tailChanged: 0, note: "") == .nothing(note: ""))
        #expect(HostSteerReply.of(applied: false, tailChanged: 3, note: "No energy data yet.") == .nothing(note: "No energy data yet."))
    }
}

@Suite("Endless Listening introduction")
struct EndlessIntroTests {
    @Test func theBarsStayInRangeAndNeverMoveTogether() {
        for bar in 0..<EndlessIntro.barCount {
            for step in 0..<400 {
                let v = EndlessIntro.scale(bar: bar, seconds: Double(step) * 0.05)
                #expect(v >= EndlessIntro.minScale - 1e-9 && v <= 1.0 + 1e-9)
            }
        }
        let at = (0..<EndlessIntro.barCount).map { EndlessIntro.scale(bar: $0, seconds: 3.0) }
        #expect(Set(at.map { ($0 * 1000).rounded() }).count == EndlessIntro.barCount)
        #expect(EndlessIntro.stillScales.count == EndlessIntro.barCount)
        #expect(EndlessIntro.stillScales.allSatisfy { $0 >= EndlessIntro.minScale && $0 <= 1.0 })
        #expect(EndlessIntro.pageCount == 3)
    }
}
