import Foundation
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
            case "fact":
                let f = HostNotes.factOf(G.string(i, "raw"))
                report.record(c, c.matches { $0.string("fact", f) })
            case "speakable":
                let ok = HostNotes.isSpeakable(G.string(i, "text"))
                report.record(c, c.matches { $0.bool("ok", ok) })
            default: report.record(c, false)
            }
        }
        report.verify(atLeast: 140)
        #expect(counts["seeds"] == 60)
        #expect(counts["notes"] == 70)
        #expect(counts["fact"] == 9)
        #expect(counts["speakable"] == 8)
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

    @Test func aStepSidewaysNamesTheGenreItComesFromAndNeedsOne() {
        let slots = [slot(genre: "Hip hop"), slot(genre: "Hip hop"), slot(genre: "Bedroom pop", side: true)]
        #expect(HostNotes.notes(Array(slots.prefix(2)) + [slot(genre: "Hip hop", side: true)]).isEmpty)
        let notes = HostNotes.notes([slots[0], slots[1], slot(genre: "Bedroom pop", island: "", side: true)])
        #expect(notes.count == 1)
        #expect(HostNotes.text(notes[0]) == "A step sideways, from Hip hop to Bedroom pop.")
        #expect(notes[0].index == 2)
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
            HostNotes.Note(index: 0, kind: HostNotes.kindSideways, a: "Hip hop", b: "Bedroom pop"),
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
