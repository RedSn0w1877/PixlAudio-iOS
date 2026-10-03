import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlLyrics

/// BiniLyrics: candidate matching (`BiniLyricsMatching`) and the TTML document parser (`TtmlDocumentParser`).
/// Every lyric line here is invented for the tests.
@Suite("Parsing — BiniLyrics matching and TTML documents")
struct ParsingBiniLyricsTests {
    static func song(title: String = "Glass Harbor", artist: String = "Nova Reed", album: String = "Tidal Rooms",
                     duration: Int64 = 200_000) -> Song {
        Song(id: "7", title: title, artist: artist, artistId: 1, album: album, albumId: 1, path: "", contentUriString: "",
             albumArtUriString: nil, duration: duration, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    static func candidate(_ title: String = "Glass Harbor", artist: String = "Nova Reed", album: String = "Tidal Rooms",
                          seconds: Double = 200, isrc: String? = nil, timing: BiniLyricsCandidate.Timing = .word,
                          id: String = "QZAA12500001") -> BiniLyricsCandidate {
        BiniLyricsCandidate(trackName: title, artistName: artist, albumName: album, durationSeconds: seconds, isrc: isrc,
                            lyricsURL: "https://lrc.red/s/\(id).ttml", timing: timing)
    }

    static let header = #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:lrc="http://lrc.red/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata""#

    // MARK: Matching

    @Test func isrcLookupTakesTheExactRecording() {
        let wanted = "QZ-AA1-25-00042"
        let results = [Self.candidate("Glass Harbor", album: "Hits of the Year", isrc: "QZAA12599999", id: "QZAA12599999"),
                       Self.candidate("Glass Harbor", album: "Tidal Rooms", timing: .line, id: "QZAA12500042")
                           .with(isrc: "QZAA12500042")]
        let chosen = BiniLyricsMatching.choose(results, song: Self.song(), isrc: wanted)
        #expect(chosen?.isrc == "QZAA12500042")
        // The ISRC lookup still checks the duration and the title or the artist.
        #expect(BiniLyricsMatching.choose(results, song: Self.song(duration: 240_000), isrc: wanted) == nil)
        #expect(BiniLyricsMatching.choose(results, song: Self.song(title: "Other Song", artist: "Somebody"), isrc: wanted) == nil)
        #expect(BiniLyricsMatching.choose(results, song: Self.song(title: "Other Song"), isrc: wanted) != nil)
        // An ISRC no result carries finds nothing (the search by title runs next).
        #expect(BiniLyricsMatching.choose(results, song: Self.song(), isrc: "QZAA12500043") == nil)
    }

    @Test func remixDecoyNeverMatchesTheAlbumVersion() {
        let remix = Self.candidate("Glass Harbor (Night Remix)", artist: "Nova Reed, Kite", seconds: 201, timing: .word, id: "R1")
        let live = Self.candidate("Glass Harbor (Live)", seconds: 199, timing: .word, id: "L1")
        let original = Self.candidate("Glass Harbor", seconds: 201, timing: .line, id: "O1")
        let chosen = BiniLyricsMatching.choose([remix, live, original], song: Self.song())
        #expect(chosen?.lyricsURL == "https://lrc.red/s/O1.ttml")
        // …and the remix still finds the remix.
        let remixSong = Self.song(title: "Glass Harbor (Night Remix)")
        #expect(BiniLyricsMatching.choose([original, remix], song: remixSong)?.lyricsURL == "https://lrc.red/s/R1.ttml")
        #expect(BiniLyricsMatching.choose([original, live], song: remixSong) == nil)
    }

    @Test func durationMustAgreeWithinThreeSeconds() {
        #expect(BiniLyricsMatching.choose([Self.candidate(seconds: 210)], song: Self.song()) == nil)
        #expect(BiniLyricsMatching.choose([Self.candidate(seconds: 203)], song: Self.song()) != nil)
        #expect(BiniLyricsMatching.choose([Self.candidate(seconds: 196.9)], song: Self.song()) == nil)
        // Unknown on either side: nothing to compare.
        #expect(BiniLyricsMatching.choose([Self.candidate(seconds: 0)], song: Self.song()) != nil)
    }

    @Test func ambiguityReturnsNil() {
        // Without a song duration, finalists that cannot be the same recording are ambiguous.
        let short = Self.candidate(seconds: 180, id: "A"), long = Self.candidate(seconds: 240, id: "B")
        #expect(BiniLyricsMatching.choose([short, long], song: Self.song(duration: 0)) == nil)
        #expect(BiniLyricsMatching.choose([short, Self.candidate(seconds: 181, id: "C")], song: Self.song(duration: 0)) != nil)
        // A different artist or title never matches.
        #expect(BiniLyricsMatching.choose([Self.candidate(artist: "Someone Else")], song: Self.song()) == nil)
        #expect(BiniLyricsMatching.choose([Self.candidate("Glass Harbour Lights")], song: Self.song()) == nil)
        // Unknown artist: only an ISRC lookup can match.
        let unknown = Self.song(artist: "<unknown>")
        #expect(BiniLyricsMatching.choose([Self.candidate()], song: unknown) == nil)
        #expect(BiniLyricsMatching.choose([Self.candidate(isrc: "QZAA12500001")], song: unknown, isrc: "QZAA12500001") != nil)
    }

    @Test func wordTimingThenAlbumThenDuration() {
        let compilationWord = Self.candidate(album: "Summer Sampler", seconds: 202, timing: .word, id: "W1")
        let albumLine = Self.candidate(album: "Tidal Rooms", seconds: 200, timing: .line, id: "L1")
        let albumWord = Self.candidate(album: "Tidal Rooms", seconds: 202, timing: .word, id: "W2")
        let closerWord = Self.candidate(album: "Summer Sampler", seconds: 200, timing: .word, id: "W3")
        #expect(BiniLyricsMatching.choose([albumLine, compilationWord], song: Self.song())?.lyricsURL.hasSuffix("W1.ttml") == true)
        #expect(BiniLyricsMatching.choose([compilationWord, closerWord, albumWord], song: Self.song())?.lyricsURL.hasSuffix("W2.ttml") == true)
        #expect(BiniLyricsMatching.choose([compilationWord, closerWord], song: Self.song())?.lyricsURL.hasSuffix("W3.ttml") == true)
    }

    @Test func titlesAndArtistsNormalise() {
        #expect(BiniLyricsMatching.titleMatches("Glass Harbor (feat. Kite)", "Glass Harbor"))
        #expect(BiniLyricsMatching.titleMatches("Glass Harbor - Remastered 2011", "Glass Harbor (2011 Remaster)"))
        #expect(BiniLyricsMatching.titleMatches("Glass Harbor - Remastered 2011", "Glass Harbor"))
        #expect(BiniLyricsMatching.titleMatches("Glass Harbor [Explicit]", "glass harbor"))
        #expect(!BiniLyricsMatching.titleMatches("Glass Harbor", "Glass Harbor (Radio Edit)"))
        #expect(!BiniLyricsMatching.titleMatches("Glass Harbor", "Glass Harbor (Mixed)"))
        #expect(BiniLyricsMatching.artistMatches(Self.song(artist: "Nova Reed & Kite"), "Nova Reed, Kite"))
        #expect(BiniLyricsMatching.artistMatches(Self.song(artist: "Nova Reed"), "Nova Reed, Kite"))
        #expect(BiniLyricsMatching.artistMatches(Self.song(artist: "Nova Reed feat. Kite"), "Nova Reed"))
        #expect(BiniLyricsMatching.artistMatches(Self.song(artist: "Café Lumière"), "Cafe Lumiere"))
        #expect(!BiniLyricsMatching.artistMatches(Self.song(artist: "Nova Reed"), "Nova"))
        #expect(BiniLyricsMatching.credits("A & B feat. C x D, E") == ["A", "B", "C", "D", "E"])
    }

    @Test func requestsAndURLs() throws {
        #expect(BiniLyricsMatching.normalizedISRC(" qz-aa1-25-00042 ") == "QZAA12500042")
        #expect(BiniLyricsMatching.normalizedISRC("qz-aa1-25-00042") == "QZAA12500042")
        #expect(BiniLyricsMatching.normalizedISRC("QZAA1250004") == nil)
        #expect(BiniLyricsMatching.normalizedISRC("12AA12500042") == nil)
        #expect(BiniLyricsMatching.normalizedISRC(nil) == nil)
        let query = try #require(BiniLyricsMatching.searchQuery(song: Self.song(title: "Glass Harbor (feat. Kite) - Remastered 2011",
                                                                                  artist: "Nova Reed & Kite")))
        #expect(query.map(\.name) == ["track", "artist"] && query.map(\.value) == ["Glass Harbor", "Nova Reed"])
        #expect(BiniLyricsMatching.searchQuery(song: Self.song(title: "Glass Harbor (Night Remix)"))?.first?.value == "Glass Harbor (Night Remix)")
        #expect(BiniLyricsMatching.searchQuery(song: Self.song(artist: "Unknown Artist")) == nil)
        #expect(BiniLyricsMatching.searchQuery(song: Self.song(title: "  ")) == nil)
    }

    @Test func hostAllowlist() {
        for allowed in ["https://lyrics-api.binimum.org/?isrc=X", "https://lrc.red/api/v1?isrc=X", "https://LRC.RED/s/A.ttml",
                        "https://lyrics-storage.binimum.org/a.ttml", "https://lrc.red:443/s/A.ttml"] {
            #expect(BiniLyricsMatching.isAllowedURL(allowed), "\(allowed)")
        }
        for refused in ["http://lrc.red/s/A.ttml", "https://lrc.red.example.com/s/A.ttml", "https://example.com/?u=https://lrc.red",
                        "https://lrc.red@example.com/s/A.ttml", "https://user:pw@lrc.red/s/A.ttml", "https://lrc.red:8443/s/A.ttml",
                        "ftp://lrc.red/s/A.ttml", "file:///etc/hosts", "https://binimum.org/", "not a url", ""] {
            #expect(!BiniLyricsMatching.isAllowedURL(refused), "\(refused)")
        }
        #expect(BiniLyricsMatching.redirectTarget(location: "https://lrc.red/api/v1?isrc=X", from: "https://lyrics-api.binimum.org/?isrc=X")
                == "https://lrc.red/api/v1?isrc=X")
        #expect(BiniLyricsMatching.redirectTarget(location: "/api/v1?isrc=X", from: "https://lrc.red/old") == "https://lrc.red/api/v1?isrc=X")
        #expect(BiniLyricsMatching.redirectTarget(location: "https://example.com/", from: "https://lrc.red/") == nil)
        #expect(BiniLyricsMatching.redirectTarget(location: "http://lrc.red/", from: "https://lrc.red/") == nil)
        #expect(BiniLyricsMatching.documentURL(Self.candidate().withURL("https://lrc.red/s/A.lrc")) == "https://lrc.red/s/A.ttml")
        #expect(BiniLyricsMatching.documentURL(Self.candidate().withURL("https://example.com/s/A.ttml")) == nil)
        #expect(BiniLyricsMatching.choose([Self.candidate().withURL("https://example.com/s/A.ttml")], song: Self.song()) == nil)
    }

    @Test func decodesSearchResponses() throws {
        let body = #"{"results":[{"album_name":"Tidal Rooms","artist_name":"Nova Reed","duration":200,"id":"QZAA12500001","isrc":"QZAA12500001","lyricsUrl":"https://lrc.red/s/QZAA12500001.ttml","timing_type":"word","track_name":"Glass Harbor"},{"artist_name":"Nova Reed","duration":"201.5","lyricsUrl":"https://lrc.red/s/B.ttml","timing_type":"none","track_name":"Glass Harbor (Mixed)"},{"track_name":"No link"},7],"source":"HIT-LRC-RED","total":3}"#
        let results = try #require(BiniLyricsMatching.candidates(fromBody: Array(body.utf8)))
        #expect(results.count == 2)
        #expect(results[0].timing == .word && results[0].durationMs == 200_000 && results[0].isrc == "QZAA12500001")
        #expect(results[1].timing == .none && results[1].durationMs == 201_500 && results[1].albumName.isEmpty)
        #expect(BiniLyricsCandidate.Timing("Line") == .line && BiniLyricsCandidate.Timing("syllable") == .word)
        #expect(BiniLyricsCandidate.Timing("karaoke") == .none && BiniLyricsCandidate.Timing(nil) == .none)
        #expect(BiniLyricsMatching.candidates(fromBody: Array(#"{"results":[],"source":"MISS-LRC-RED","total":0}"#.utf8)) == [])
        #expect(BiniLyricsMatching.candidates(fromBody: Array("<html>".utf8)) == nil)
        #expect(BiniLyricsMatching.candidates(fromBody: [UInt8](repeating: 0x20, count: BiniLyricsMatching.maxSearchBytes + 1)) == nil)
    }

    @Test func raceDecidesAsSoonAsTheAnswerCannotChange() {
        let word = OnlineSyncedLyrics(lyrics: LyricsUtils.parseLyrics("[00:01.00]<00:01.00>word"), source: "BiniLyrics")
        let line = OnlineSyncedLyrics(lyrics: LyricsUtils.parseLyrics("[00:01.00]line"), source: "BiniLyrics")
        let otherWord = OnlineSyncedLyrics(lyrics: LyricsUtils.parseLyrics("[00:02.00]<00:02.00>other"), source: "AMLL TTML")
        let lrc = OnlineSyncedLyrics(lyrics: LyricsUtils.parseLyrics("[00:01.00]line"), source: "LRCLIB")
        // Word-synced BiniLyrics ends the race at once.
        #expect(LyricsRepositoryLogic.decidedCatalogResult([.some(word), nil, nil, nil], syncedOnly: false)??.source == "BiniLyrics")
        // A line-synced BiniLyrics result waits: word timing from another catalog would beat it…
        #expect(LyricsRepositoryLogic.decidedCatalogResult([.some(line), nil, .some(nil), .some(lrc)], syncedOnly: false) == nil)
        #expect(LyricsRepositoryLogic.decidedCatalogResult([.some(line), .some(otherWord), nil, nil], syncedOnly: false)??.source == "AMLL TTML")
        // …and wins over line timing elsewhere once everyone answered.
        #expect(LyricsRepositoryLogic.decidedCatalogResult([.some(line), .some(nil), .some(nil), .some(lrc)], syncedOnly: false)??.source == "BiniLyrics")
        // An earlier catalog still running keeps a later word-synced result waiting.
        #expect(LyricsRepositoryLogic.decidedCatalogResult([nil, .some(otherWord), nil, nil], syncedOnly: false) == nil)
        let allEmpty: [OnlineSyncedLyrics??] = [.some(nil), .some(nil), .some(nil), .some(nil)]
        #expect(LyricsRepositoryLogic.decidedCatalogResult(allEmpty, syncedOnly: false) == .some(nil))
        #expect(LyricsRepositoryLogic.chooseCatalogResult([line, otherWord, lrc], syncedOnly: true)?.source == "AMLL TTML")
    }

    // MARK: TTML documents

    static let wordTimed = header + #" lrc:timing="Word" xml:lang="en"><head><metadata><ttm:agent type="person" xml:id="v1"><ttm:name type="full">Singer</ttm:name></ttm:agent><sourceMetadata xmlns="http://lrc.red/lyric-ttml-internal" leadingSilence="0"><translations/><songwriters><songwriter>Writer</songwriter></songwriters><audio lyricOffset="1.115" role="spatial"/></sourceMetadata></metadata></head><body dur="1:00.000"><div begin="10.000" end="20.000" lrc:songPart="Verse"><p begin="10.000" end="12.500" lrc:key="L1" ttm:agent="v1"><span begin="10.000" end="10.400">Paper</span> <span begin="10.400" end="10.800">lan</span><span begin="10.800" end="11.200">terns</span> <span begin="11.200" end="12.500">drift</span></p><p begin="13.000" end="16.000" lrc:key="L2" ttm:agent="v1"><span ttm:role="x-bg"><span begin="13.000" end="13.600">(far</span> <span begin="13.600" end="14.100">away)</span></span> <span begin="13.200" end="14.000">over</span> <span begin="14.000" end="16.000">water</span></p></div></body></tt>"#

    @Test func wordTimedDocumentKeepsSyllablesAndBackgroundVocals() throws {
        let lyrics = try #require(TtmlDocumentParser.parse(Self.wordTimed, metadata: LyricsMetadata(source: "BiniLyrics")))
        let doc = try #require(lyrics.document)
        #expect(LyricsDocCodec.isValid(doc) && doc.metadata.source == "BiniLyrics" && lyrics.areFromRemote)
        #expect(doc.lines.map(\.text) == ["Paper lanterns drift", "over water", "far away"])
        #expect(doc.lines.map(\.voiceId) == ["lead", "lead", "background"])
        #expect(doc.voices.map(\.role) == [VoiceRole.lead, VoiceRole.background])
        // Syllables keep their exact times; "lan"+"terns" is one word (no space between the spans).
        #expect(doc.lines[0].syllables.map(\.text) == ["Paper ", "lan", "terns ", "drift"])
        #expect(doc.lines[0].syllables.map(\.startMs) == [10_000, 10_400, 10_800, 11_200])
        #expect(doc.lines[0].syllables.map(\.durationMs) == [400, 400, 400, 1_300])
        #expect(doc.lines[0].startMs == 10_000 && doc.lines[0].endMs == 12_500)
        let words = try #require(lyrics.synced?[0].words)
        #expect(words.map(\.word) == ["Paper", "lan", "terns", "drift"])
        #expect(words.map(\.startsNewWord) == [true, true, false, true])
        // The background part: parentheses gone, its own times, ending with its last syllable.
        #expect(doc.lines[2].startMs == 13_000 && doc.lines[2].endMs == 14_100)
        #expect(doc.lines[2].syllables.map(\.text) == ["far ", "away"])
        #expect(lyrics.synced?.map(\.voiceRole) == ["lead", "lead", "background"])
        // The karaoke model reads it.
        #expect(PreparedLyricsBuilder.build(lyrics) != nil)
    }

    @Test func duetAgentsBecomeLeadAndDuetVoices() throws {
        let ttml = Self.header + #" lrc:timing="Word"><head><metadata><ttm:agent type="person" xml:id="v1"/><ttm:agent type="person" xml:id="v2"/><ttm:agent type="group" xml:id="v3"/></metadata></head><body ttm:agent="v2"><div ttm:agent="v1"><p begin="1.000" end="2.000"><span begin="1.000" end="2.000">first</span></p></div><div><p begin="3.000" end="4.000"><span begin="3.000" end="4.000">second</span></p><p begin="5.000" end="6.000" ttm:agent="v3"><span begin="5.000" end="6.000">together</span></p><p begin="7.000" end="8.000" ttm:agent="v1"><span begin="7.000" end="8.000">again</span></p></div></body></tt>"#
        let doc = try #require(TtmlDocumentParser.parse(ttml)?.document)
        #expect(doc.lines.map(\.voiceId) == ["lead", "duet", "lead", "lead"])
        #expect(doc.voices.map(\.id) == ["lead", "duet"] && doc.voices.map(\.role) == [VoiceRole.lead, VoiceRole.duet])
        // One singer only: everything is the lead.
        let solo = Self.header + #"><body><div><p begin="1" end="2" ttm:agent="voice1">only</p></div></body></tt>"#
        #expect(TtmlDocumentParser.parse(solo)?.document?.voices.map(\.id) == ["lead"])
    }

    @Test func lineTimedAndUntimedDocuments() throws {
        let lineTimed = Self.header + #" lrc:timing="Line"><body dur="0:30.000"><div><p begin="1.500" end="4.000" lrc:key="L1">Morning comes <br/>slowly</p><p begin="5.000" lrc:key="L2">Into the room</p><p begin="7.250">   </p></div></body></tt>"#
        let lyrics = try #require(TtmlDocumentParser.parse(lineTimed))
        let doc = try #require(lyrics.document)
        #expect(doc.lines.map(\.text) == ["Morning comes slowly", "Into the room"])
        #expect(doc.lines.allSatisfy { $0.syllables.isEmpty })
        // A missing end falls back to the body's duration (no next line).
        #expect(doc.lines.map(\.endMs) == [4_000, 30_000])
        #expect(lyrics.synced?.allSatisfy { $0.words == nil } == true)

        let untimed = Self.header + #" lrc:timing="None"><body><div><p>Morning comes</p><p>Into the room</p></div><div><p>  </p></div></body></tt>"#
        let plain = try #require(TtmlDocumentParser.parse(untimed))
        #expect(plain.document == nil && plain.synced == nil && plain.plain == ["Morning comes", "Into the room"])
    }

    @Test func timeFormats() throws {
        #expect(try TtmlDocumentParser.timeMs("27.395") == 27_395)
        #expect(try TtmlDocumentParser.timeMs("1:02.5") == 62_500)
        #expect(try TtmlDocumentParser.timeMs("1:02:03.250") == 3_723_250)
        #expect(try TtmlDocumentParser.timeMs("00:01.000") == 1_000)
        #expect(try TtmlDocumentParser.timeMs("12.5s") == 12_500)
        #expect(try TtmlDocumentParser.timeMs("750ms") == 750)
        #expect(try TtmlDocumentParser.timeMs("2m") == 120_000)
        #expect(try TtmlDocumentParser.timeMs("") == nil)
        #expect(try TtmlDocumentParser.timeMs("soon") == nil)
        // Mixed formats in one document.
        let mixed = Self.header + #"><body><div><p begin="0:59.500" end="1:01.000"><span begin="59.5" end="1:00.250">tick</span> <span begin="0:01:00.250" end="61s">tock</span></p></div></body></tt>"#
        let doc = try #require(TtmlDocumentParser.parse(mixed)?.document)
        #expect(doc.lines[0].syllables.map(\.startMs) == [59_500, 60_250])
        #expect(doc.lines[0].syllables.map(\.durationMs) == [750, 750])
    }

    @Test func translationsAndRomanisationFollowTheLineKeys() throws {
        let ttml = Self.header + #" lrc:timing="Word" xml:lang="es"><head><metadata><sourceMetadata xmlns="http://lrc.red/lyric-ttml-internal"><translations><translation type="subtitle" xml:lang="fr-FR"><text for="L1">Bonjour lune</text></translation><translation type="subtitle" xml:lang="en-US"><text for="L1">Hello moon</text><text for="L2">Hello again</text></translation><translation type="subtitle" xml:lang="es"><text for="L1">Hola luna</text></translation></translations><transliterations><transliteration xml:lang="es-Latn"><text for="L2"><span begin="3" end="4" xmlns="http://www.w3.org/ns/ttml">o</span><span begin="4" end="5" xmlns="http://www.w3.org/ns/ttml">la</span> <span begin="5" end="6" xmlns="http://www.w3.org/ns/ttml">otra vez</span></text></transliteration></transliterations></sourceMetadata></metadata></head><body><div><p begin="1" end="2" lrc:key="L1"><span begin="1" end="2">Hola luna</span></p><p begin="3" end="6" lrc:key="L2"><span begin="3" end="6">Hola otra vez</span></p></div></body></tt>"#
        let english = try #require(TtmlDocumentParser.parse(ttml, preferredLanguages: ["en-GB", "fr"]))
        #expect(english.synced?.map(\.translation) == ["Hello moon", "Hello again"])
        #expect(english.synced?.map(\.romanization) == [nil, "ola otra vez"])
        #expect(english.plain?.first == "Hola luna\nHello moon")
        let french = try #require(TtmlDocumentParser.parse(ttml, preferredLanguages: ["fr-CA"]))
        #expect(french.synced?.first?.translation == "Bonjour lune" && french.synced?.last?.translation == nil)
        // No preference: the first translation that is not in the lyrics' own language.
        #expect(try #require(TtmlDocumentParser.parse(ttml)).synced?.first?.translation == "Bonjour lune")

        let inline = Self.header + #"><body><div><p begin="1" end="2"><span begin="1" end="2">Hola</span><span ttm:role="x-translation" xml:lang="en">Hello</span><span ttm:role="x-roman">ola</span></p></div></body></tt>"#
        let inlineLyrics = try #require(TtmlDocumentParser.parse(inline))
        #expect(inlineLyrics.synced?.first?.line == "Hola")
        #expect(inlineLyrics.synced?.first?.translation == "Hello" && inlineLyrics.synced?.first?.romanization == "ola")
    }

    @Test func refusesUnsafeOrBrokenDocuments() {
        let entity = #"<?xml version="1.0"?><!DOCTYPE tt [<!ENTITY x SYSTEM "file:///etc/passwd">]><tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1" end="2">&x;</p></div></body></tt>"#
        #expect(TtmlDocumentParser.parse(entity) == nil)
        #expect(TtmlDocumentParser.parse("<tt><body><p begin=\"1\">open") == nil)
        #expect(TtmlDocumentParser.parse("<html><body><p begin=\"1\" end=\"2\">x</p></body></html>") == nil)
        #expect(TtmlDocumentParser.parse("") == nil)
        #expect(TtmlDocumentParser.parse(String(repeating: " ", count: TtmlDocumentParser.maxInputLength + 1)) == nil)
    }

    @Test func recognisesBiniLyricsDocumentsAndChecksParsedLyrics() throws {
        #expect(BiniLyricsMatching.isBiniLyricsDocument(Self.wordTimed))
        #expect(BiniLyricsMatching.isBiniLyricsDocument("\u{FEFF}<?xml version=\"1.0\"?>\n" + Self.wordTimed))
        #expect(!BiniLyricsMatching.isBiniLyricsDocument(#"<tt xmlns="http://www.w3.org/ns/ttml"><body/></tt>"#))
        #expect(!BiniLyricsMatching.isBiniLyricsDocument(#"{"format":"pixelplay-lyrics","lrc.red/lyric-ttml":1}"#))

        let lyrics = try #require(TtmlDocumentParser.parse(Self.wordTimed))
        #expect(BiniLyricsMatching.isPlausible(lyrics, song: Self.song(duration: 60_000)))
        // Words far past the song's end: the wrong recording.
        #expect(!BiniLyricsMatching.isPlausible(lyrics, song: Self.song(duration: 12_000)))
        #expect(BiniLyricsMatching.isPlausible(lyrics, song: Self.song(duration: 0)))
        #expect(!BiniLyricsMatching.isPlausible(Lyrics(plain: ["  "]), song: Self.song()))
        #expect(BiniLyricsMatching.isPlausible(Lyrics(plain: ["words"]), song: Self.song()))
        #expect(!BiniLyricsMatching.isPlausible(LyricsUtils.parseLyrics("[00:00.00]zero"), song: Self.song()))
    }
}

extension ParsingBiniLyricsTests {
    @Test func fetchDialogEntry() throws {
        let lyrics = try #require(TtmlDocumentParser.parse(Self.wordTimed))
        let entry = try #require(BiniLyricsMatching.searchResult(candidate: Self.candidate(), lyrics: lyrics,
                                                                 document: Self.wordTimed))
        #expect(entry.source == "BiniLyrics" && entry.record.id == -1 && entry.rawLyrics == Self.wordTimed)
        #expect(entry.record.name == "Glass Harbor" && entry.record.duration == 200)
        #expect(entry.record.syncedLyrics?.hasPrefix("[00:10.00]Paper lanterns drift") == true)
        #expect(LyricsSearchResult(record: entry.record, lyrics: lyrics, rawLyrics: "").source == "LRCLIB")
        #expect(BiniLyricsMatching.searchResult(candidate: Self.candidate(), lyrics: Lyrics(), document: "") == nil)
    }
}

extension BiniLyricsCandidate {
    func with(isrc: String) -> BiniLyricsCandidate {
        var copy = self
        copy.isrc = isrc
        return copy
    }

    func withURL(_ url: String) -> BiniLyricsCandidate {
        var copy = self
        copy.lyricsURL = url
        return copy
    }
}
