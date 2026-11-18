import Foundation
import PixlModel
import Testing
@testable import PixlLibrary

/// The pure core of the music brain, with the vectors of the Android `:brain` module's own tests (`BrainHashTest`,
/// `BrainTextTest`, `IdsTest`, `ArmsTest`): the same inputs must give the same outputs on both platforms. The
/// generated golden files of docs/brain-spec.md 10.4 arrive with milestone 1b; until then these are the contract.
@Suite("Brain hashing")
struct BrainHashTests {
    @Test func fnv1a64MatchesThePublishedTestVectors() {
        // Reference values from the FNV specification (Fowler, Noll, Vo).
        #expect(BrainHash.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
        #expect(BrainHash.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(BrainHash.fnv1a64("foobar") == 0x8594_4171_f739_67e8)
        #expect(BrainHash.id(BrainHash.fnv1a64("foobar")) == Int64(bitPattern: 0x8594_4171_f739_67e8))
    }

    @Test func fnv1a64HashesUtf8Bytes() {
        #expect(BrainHash.fnv1a64(bytes: [0xC4, 0x91]) == BrainHash.fnv1a64("\u{0111}")) // d with stroke
    }

    @Test func splitmix64MatchesTheReferenceStreamForSeedZero() {
        // First outputs of Vigna's splitmix64.c with x = 0.
        var rng = BrainHash.Rng(seed: 0)
        #expect(rng.next() == 0xe220_a839_7b1d_cdaf)
        #expect(rng.next() == 0x6e78_9e6a_a1b9_65f4)
        #expect(rng.next() == 0x06c4_5d18_8009_454f)
        #expect(BrainHash.splitmix64(0) == 0xe220_a839_7b1d_cdaf)
    }

    @Test func uniformStaysInTheHalfOpenUnitIntervalAndAdvancesOnce() {
        var rng = BrainHash.Rng(seed: 42)
        let before = rng.state
        let u = rng.uniform()
        #expect(u >= 0 && u < 1)
        #expect(rng.state == before &+ 0x9E37_79B9_7F4A_7C15)
        // The state wraps instead of trapping.
        var top = BrainHash.Rng(seed: UInt64.max)
        _ = top.next()
        #expect(top.state == 0x9E37_79B9_7F4A_7C14)
    }

    @Test func gaussian12ConsumesTwelveUniformsAndIsCentred() {
        var a = BrainHash.Rng(seed: 7)
        var b = BrainHash.Rng(seed: 7)
        var sum = 0.0
        for _ in 0..<12 { sum += b.uniform() }
        #expect(a.gaussian12() == sum - 6.0)
        #expect(a.state == b.state)

        var rng = BrainHash.Rng(seed: 1234)
        var mean = 0.0
        for _ in 0..<20_000 { mean += rng.gaussian12() }
        mean /= 20_000
        #expect(mean > -0.05 && mean < 0.05, "mean was \(mean)")
    }

    @Test func aBrainKeyComparesBytesNotCanonicalEquivalence() {
        // Swift calls these two strings equal; Kotlin does not, and the brain follows Kotlin.
        let composed = "\u{AC00}"
        let jamo = "\u{1100}\u{1161}"
        #expect(BrainKey(composed) != BrainKey(jamo))
        #expect(!BrainKey.sameBytes(composed, jamo))
        var keys: [BrainKey: Int] = [:]
        keys[BrainKey(composed)] = 1
        keys[BrainKey(jamo)] = 2
        #expect(keys.count == 2)
        #expect(BrainKey("abc") == BrainKey("abc"))
    }
}

@Suite("Brain text folding and title cleaning")
struct BrainTextTests {
    private func clean(_ raw: String) -> BrainText.CleanTitle { BrainText.cleanTitle(raw) }

    @Test func foldLowerCasesAsciiAndTurnsPunctuationIntoSingleSpaces() {
        #expect(BrainText.fold("AC/DC") == "ac dc")
        #expect(BrainText.fold("Tyler, The Creator") == "tyler the creator")
        #expect(BrainText.fold("  P!nk  ") == "p nk")
        #expect(BrainText.fold(" -- ") == "")
        #expect(BrainText.fold("") == "")
        #expect(BrainText.fold("blink-182") == "blink 182")
    }

    @Test func foldRemovesVietnameseDiacriticsComposedOrDecomposed() {
        #expect(BrainText.fold("S\u{01A1}n T\u{00F9}ng M-TP") == "son tung m tp")
        #expect(BrainText.fold("\u{0110}en V\u{00E2}u") == "den vau")
        #expect(BrainText.fold("Ng\u{01B0}\u{1EDD}i L\u{1EA1} \u{01A0}i") == "nguoi la oi")
        // The same name written with combining marks (NFD).
        #expect(BrainText.fold("So\u{031B}n Tu\u{0300}ng") == "son tung")
        #expect(BrainKey.sameBytes(BrainText.fold("Ho\u{00E0}ng Th\u{00F9}y Linh"),
                                   BrainText.fold("Hoa\u{0300}ng Thu\u{0300}y Linh")))
    }

    @Test func foldMapsLettersUnicodeDoesNotDecompose() {
        #expect(BrainText.fold("Stra\u{00DF}e") == "strasse")
        #expect(BrainText.fold("\u{00C6}r\u{00F8}") == "aero")
        #expect(BrainText.fold("\u{0141}\u{00F3}d\u{017A}") == "lodz")
        #expect(BrainText.fold("Bj\u{00F6}rk") == "bjork")
        #expect(BrainText.fold("Sigur R\u{00F3}s") == "sigur ros")
        #expect(BrainText.fold("Beyonc\u{00E9}") == "beyonce")
        #expect(BrainText.fold("M\u{00F6}tley Cr\u{00FC}e") == "motley crue")
    }

    @Test func foldLowerCasesGreekAndCyrillicAndLeavesOtherScriptsAlone() {
        #expect(BrainKey.sameBytes(BrainText.fold("\u{041A}\u{0418}\u{041D}\u{041E}"), "\u{043A}\u{0438}\u{043D}\u{043E}"))
        #expect(BrainKey.sameBytes(BrainText.fold("\u{0391}\u{0392}\u{0393}"), "\u{03B1}\u{03B2}\u{03B3}"))
        #expect(BrainKey.sameBytes(BrainText.fold("\u{C544}\u{C774}\u{C720}"), "\u{C544}\u{C774}\u{C720}"))
        #expect(BrainKey.sameBytes(BrainText.fold("\u{7C73}\u{6D25}\u{7384}\u{5E2B}"), "\u{7C73}\u{6D25}\u{7384}\u{5E2B}"))
        #expect(BrainKey.sameBytes(BrainText.fold("\u{30E8}\u{30EB}\u{30B7}\u{30AB}"), "\u{30E8}\u{30EB}\u{30B7}\u{30AB}"))
        // Decomposed Hangul is not composed (the spec's open item): it passes through as it came.
        #expect(BrainKey.sameBytes(BrainText.fold("\u{1100}\u{1161}"), "\u{1100}\u{1161}"))
    }

    @Test func foldHandlesFullWidthFormsCjkAndGeneralPunctuation() {
        #expect(BrainText.fold("\u{FF21}\u{FF22}\u{FF23}\u{3000}\u{FF11}\u{FF12}\u{FF13}") == "abc 123")
        #expect(BrainText.fold("a\u{2014}b") == "a b")
        #expect(BrainText.fold("Don\u{2019}t") == "don t")
        #expect(BrainText.fold("a\u{00A0}b") == "a b")
        // A lone surrogate cannot be in a Swift string; it arrives as U+FFFD, which folds to the same space.
        #expect(BrainText.fold("a\u{FFFD}b") == "a b")
        // A valid supplementary scalar passes through.
        #expect(BrainKey.sameBytes(BrainText.fold("a\u{1F3B5}b"), "a\u{1F3B5}b"))
    }

    @Test func cleanTitleDropsVersionSegmentsAndSetsTheirFlags() {
        var it = clean("Dreams (2004 Remaster)")
        #expect(it.title == "dreams" && it.versionFlags == BrainText.flagRemaster && it.identityFlags == 0)
        it = clean("Hotel California - Live at the Forum")
        #expect(it.title == "hotel california" && it.versionFlags == BrainText.flagLive)
        it = clean("Love Story (Taylor's Version)")
        #expect(it.title == "love story" && it.versionFlags == BrainText.flagReRecorded)
        it = clean("Blinding Lights [Chromatics Remix]")
        #expect(it.title == "blinding lights" && it.versionFlags == BrainText.flagRemix)
        it = clean("Heather (slowed + reverb)")
        #expect(it.title == "heather" && it.versionFlags == BrainText.flagSlowed)
        // A segment that matches several flag rules sets every one of them (Android's rule; the cover filter needs it).
        it = clean("Bad Habits (Acoustic Cover)")
        #expect(it.title == "bad habits" && it.versionFlags == BrainText.flagAcoustic | BrainText.flagCover)
        it = clean("Numb\u{FF08}Instrumental\u{FF09}")
        #expect(it.title == "numb" && it.versionFlags == BrainText.flagInstrumental)
    }

    @Test func cleanTitleDropsPackagingWithoutAFlag() {
        #expect(clean("Espresso (feat. Someone)").title == "espresso")
        #expect(clean("Espresso (feat. Someone)").versionFlags == 0)
        #expect(clean("STAY (with Justin Bieber)").title == "stay")
        #expect(clean("What Was I Made For? [From The Motion Picture \"Barbie\"]").title == "what was i made for")
        #expect(clean("Song - Radio Edit").title == "song")
        #expect(clean("Song (Deluxe Edition)").title == "song")
        #expect(clean("Song - Radio Edit").versionFlags == 0)
    }

    @Test func cleanTitleKeepsSegmentsThatArePartOfTheName() {
        #expect(clean("(I Can't Get No) Satisfaction").title == "satisfaction i can t get no")
        #expect(clean("Heroes (Part 2)").title == "heroes part 2")
        #expect(clean("Up - Tempo").title == "up tempo")
        // Words in the head never set a flag.
        #expect(clean("Live Forever").title == "live forever" && clean("Live Forever").versionFlags == 0)
        #expect(clean("Cover Me Up").versionFlags == 0)
        // "inst" must be a whole token.
        #expect(clean("Song (Instant Crush)").versionFlags == 0)
    }

    @Test func cleanTitleSurvivesOddInput() {
        #expect(clean("(Live)").title == "live")
        #expect(clean("(Live)").versionFlags == BrainText.flagLive)
        #expect(clean("Open (bracket never closes").title == "open bracket never closes")
        #expect(clean("").title == "")
        #expect(clean("A (B (nested) ) ").title == "a b nested")
        #expect(clean("Em Dash \u{2014} Remastered").title == "em dash")
        #expect(clean("Em Dash \u{2014} Remastered").versionFlags == BrainText.flagRemaster)
    }

    @Test func spotifyAndYouTubeSpellingsOfOneSong() {
        // "(Official Audio)" is not a rule: it stays, so the two differ. Radio rows are official-audio entries whose
        // titles carry no such suffix; this pins the behaviour so a rule change is deliberate.
        #expect(clean("Ch\u{1EA1}y Ngay \u{0110}i").title == "chay ngay di")
        #expect(clean("CH\u{1EA0}Y NGAY \u{0110}I (Official Audio)").title == "chay ngay di official audio")
    }

    @Test func blankAndTrimUseAFixedListOfSpaces() {
        #expect(BrainText.isBlank(""))
        #expect(BrainText.isBlank(" \t\n\u{00A0}\u{3000}\u{2003}"))
        #expect(!BrainText.isBlank(" a "))
        // U+0085 is whitespace to Swift's Character but not to Kotlin's Char.
        #expect(!BrainText.isBlank("\u{0085}"))
        #expect(BrainText.trim("  usabc\u{00A0}") == "usabc")
        #expect(BrainText.trim("abc") == "abc")
    }
}

@Suite("Brain identity")
struct BrainIdsTests {
    private let dreams = Ids.nameKey(primaryArtist: "Fleetwood Mac", rawTitle: "Dreams (2004 Remaster)")

    private func rid(_ key: String) -> Int64 { BrainHash.id(BrainHash.fnv1a64(key)) }

    @Test func nameKeyFoldsTheArtistCleansTheTitleAndIgnoresTheRemasterFlag() {
        #expect(dreams == "n:fleetwood mac|dreams|0")
        #expect(Ids.nameKey(primaryArtist: "FLEETWOOD MAC", rawTitle: "Dreams") == dreams)
        #expect(Ids.nameKey(primaryArtist: "Eagles", rawTitle: "Hotel California (Live)") == "n:eagles|hotel california|1")
        #expect(Ids.nameKey(primaryArtist: "S\u{01A1}n T\u{00F9}ng M-TP", rawTitle: "Ch\u{1EA1}y Ngay \u{0110}i")
                == "n:son tung m tp|chay ngay di|0")
        #expect(Ids.nameKey(primaryArtist: "", rawTitle: "Dreams") == nil)
        #expect(Ids.nameKey(primaryArtist: "Artist", rawTitle: "!!!") == nil)
        // The flags are lower-case hexadecimal, as `Integer.toHexString` writes them.
        #expect(Ids.nameKey(primaryArtist: "A", rawTitle: "B (Sped Up) (Slowed) (Rerecorded)") == "n:a|b|380")
        #expect(Ids.hex(0x2af) == "2af" && Ids.hex(0) == "0")
    }

    @Test func mintIsFnvOfTheFirstKeyAndStepsPastZeroAndTakenIds() {
        #expect(Ids.mint("y:abc", isTaken: { _ in false }) == rid("y:abc"))
        let first = rid("y:abc")
        #expect(Ids.mint("y:abc", isTaken: { $0 == first }) == rid("y:abc#1"))
        let second = rid("y:abc#1")
        #expect(Ids.mint("y:abc", isTaken: { $0 == first || $0 == second }) == rid("y:abc#2"))
    }

    @Test func step1AKnownStrongKeyDecidesInTheOrderSThenIThenY() throws {
        let table = Ids.MemoryAliasTable()
        let a = try #require(table.resolveTrack(Ids.TrackKeys(spotifyId: "SP1"), durationMs: 200_000))
        let b = try #require(table.resolveTrack(Ids.TrackKeys(videoId: "VID1"), durationMs: 200_000))
        #expect(a != b)
        // Both known: the Spotify key wins and the two recordings become one.
        let both = try #require(Ids.resolveTrack(Ids.TrackKeys(spotifyId: "SP1", videoId: "VID1"), durationMs: 200_000,
                                                 table: table))
        #expect(both.id == a)
        #expect(both.merges == [Ids.MergeWrite(from: b, into: a)])
        table.apply(both)
        #expect(table.resolveTrack(Ids.TrackKeys(videoId: "VID1"), durationMs: 0) == a)
    }

    @Test func step2TheNameKeyBridgesALibraryTrackAndARadioRowOfTheSameLength() throws {
        let table = Ids.MemoryAliasTable()
        let library = try #require(table.resolveTrack(Ids.TrackKeys(spotifyId: "SP1", nameKey: dreams), durationMs: 257_000))
        let radio = try #require(table.resolveTrack(Ids.TrackKeys(videoId: "VID1", nameKey: dreams), durationMs: 258_500))
        #expect(library == radio)
        // The radio's video id is now an alias of the library recording.
        #expect(table.resolveTrack(Ids.TrackKeys(videoId: "VID1"), durationMs: 0) == library)
    }

    @Test func step2ADifferentLengthUnderTheSameNameIsAnotherRecording() throws {
        let table = Ids.MemoryAliasTable()
        let studio = try #require(table.resolveTrack(Ids.TrackKeys(spotifyId: "SP1", nameKey: dreams), durationMs: 257_000))
        let edit = try #require(Ids.resolveTrack(Ids.TrackKeys(videoId: "VID2", nameKey: dreams), durationMs: 201_000,
                                                 table: table))
        #expect(studio != edit.id)
        #expect(edit.minted)
        #expect(edit.aliases.map(\.key) == ["y:VID2"])
        table.apply(edit)
        // The name still points at the first recording.
        #expect(table.resolveTrack(Ids.TrackKeys(nameKey: dreams), durationMs: 0) == studio)
    }

    @Test func step2ANamesOnlyImportOrAnUnknownLengthAlwaysAcceptsTheName() throws {
        let table = Ids.MemoryAliasTable()
        let library = try #require(table.resolveTrack(Ids.TrackKeys(spotifyId: "SP1", nameKey: dreams), durationMs: 257_000))
        #expect(table.resolveTrack(Ids.TrackKeys(nameKey: dreams), durationMs: 100_000) == library)
        #expect(table.resolveTrack(Ids.TrackKeys(videoId: "VID9", nameKey: dreams), durationMs: 0) == library)
    }

    @Test func step3MintsFromTheStrongestKeyTheCallerHas() throws {
        let table = Ids.MemoryAliasTable()
        #expect(table.resolveTrack(Ids.TrackKeys(isrc: "usabc1234567", videoId: "V", nameKey: dreams), durationMs: 1)
                == rid("i:USABC1234567"))
        let other = Ids.MemoryAliasTable()
        #expect(other.resolveTrack(Ids.TrackKeys(nameKey: dreams), durationMs: 0) == rid(try #require(dreams)))
        #expect(other.resolveTrack(Ids.TrackKeys(), durationMs: 0) == nil)
        #expect(other.resolveTrack(Ids.TrackKeys(spotifyId: "  ", videoId: ""), durationMs: 0) == nil)
    }

    @Test func step4EveryNewKeyIsStoredOnceAndASecondResolveWritesNothing() throws {
        let table = Ids.MemoryAliasTable()
        let keys = Ids.TrackKeys(spotifyId: "SP1", isrc: "USABC1234567", videoId: "V1", nameKey: dreams)
        let first = try #require(Ids.resolveTrack(keys, durationMs: 257_000, table: table))
        #expect(first.aliases.map(\.key) == ["s:SP1", "i:USABC1234567", "y:V1", try #require(dreams)])
        table.apply(first)
        let second = try #require(Ids.resolveTrack(keys, durationMs: 257_000, table: table))
        #expect(first.id == second.id)
        #expect(second.aliases.isEmpty)
        #expect(second.merges.isEmpty)
        #expect(table.aliasCount == 4)
    }

    @Test func mergeChainsAreFlattened() throws {
        let table = Ids.MemoryAliasTable()
        let a = try #require(table.resolveTrack(Ids.TrackKeys(spotifyId: "A"), durationMs: 0))
        let b = try #require(table.resolveTrack(Ids.TrackKeys(isrc: "B"), durationMs: 0))
        let c = try #require(table.resolveTrack(Ids.TrackKeys(videoId: "C"), durationMs: 0))
        _ = table.resolveTrack(Ids.TrackKeys(isrc: "B", videoId: "C"), durationMs: 0) // c into b
        #expect(table.survivorOf(c) == b)
        _ = table.resolveTrack(Ids.TrackKeys(spotifyId: "A", isrc: "B"), durationMs: 0) // b into a
        #expect(table.survivorOf(b) == a)
        #expect(table.survivorOf(c) == a)
        #expect(table.resolveTrack(Ids.TrackKeys(videoId: "C"), durationMs: 0) == a)
    }

    @Test func artistsJoinByFoldedNameAndANameHitIsAlwaysAccepted() throws {
        let table = Ids.MemoryAliasTable()
        let library = try #require(table.resolveArtist(Ids.ArtistKeys(name: "S\u{01A1}n T\u{00F9}ng M-TP")))
        let radio = try #require(table.resolveArtist(Ids.ArtistKeys(youTubeChannelId: "UCabc", name: "SON TUNG M-TP")))
        #expect(library == radio)
        #expect(table.resolveArtist(Ids.ArtistKeys(youTubeChannelId: "UCabc")) == library)
        #expect(library == rid("na:son tung m tp"))
        #expect(table.resolveArtist(Ids.ArtistKeys(name: "  ")) == nil)
    }
}

@Suite("Brain arms and surfaces")
struct BrainArmsTests {
    @Test func armCodesArePinnedAndRoundTripThroughTheirNames() {
        #expect([Arm.fav, Arm.deep, Arm.back, Arm.radio, Arm.sim, Arm.artist, Arm.new, Arm.edge, Arm.ask, Arm.none]
                == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
        for code in Int32(0)...9 { #expect(Arm.codeOf(Arm.nameOf(code)) == code) }
        #expect(Arm.nameOf(Arm.radio) == "RADIO")
        #expect(Arm.codeOf(nil) == Arm.none)
        #expect(Arm.codeOf("nonsense") == Arm.none)
        #expect(Arm.nameOf(42) == "NONE")
        #expect(Arm.isNovel(Arm.radio))
        #expect(!Arm.isNovel(Arm.fav))
        #expect(!Arm.isNovel(Arm.deep))
    }

    @Test func surfaceCodesArePinnedAndRoundTripThroughTheirNames() {
        #expect(Surface.autoplay == 5)
        #expect(Surface.nameOf(Surface.autoplay) == "autoplay")
        for code in Int32(0)...14 { #expect(Surface.codeOf(Surface.nameOf(code)) == code) }
        #expect(Surface.codeOf(nil) == Surface.unknown)
        #expect(Surface.codeOf("nope") == Surface.unknown)
    }

    @Test func anItemWithAnArmIsEngineOwned() {
        #expect(BrainItemTag(arm: "RADIO").isEngineOwned)
        #expect(BrainItemTag(arm: "FAV").isEngineOwned)
        #expect(!BrainItemTag(arm: "NONE").isEngineOwned)
        #expect(!BrainItemTag(arm: "nonsense").isEngineOwned)
        #expect(!BrainItemTag(surface: "album").isEngineOwned)
    }
}

/// The two generated tables against the reviewed `.tsv` files they come from (copies of the Android repo's
/// `brain/tables/`): a table edited on one side only fails here.
@Suite("Brain tables in sync")
struct BrainTablesInSyncTests {
    private func lines(_ name: String) throws -> [Substring] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "tsv", subdirectory: "Fixtures/brain"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
    }

    @Test func foldTableMatchesFoldV1() throws {
        var rows: [(UInt32, [UInt32])] = []
        for line in try lines("fold-v1") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let key = try #require(UInt32(parts[0], radix: 16))
            let value = parts.count > 1 ? parts[1].split(separator: " ").compactMap { UInt32($0, radix: 16) } : []
            rows.append((key, value))
        }
        rows.sort { $0.0 < $1.0 }
        #expect(rows.count == FoldTable.rows)
        #expect(FoldTable.keys.count == rows.count)
        #expect(FoldTable.offsets.count == rows.count + 1)
        for (i, row) in rows.enumerated() where i < FoldTable.keys.count {
            #expect(UInt32(FoldTable.keys[i]) == row.0)
            let from = Int(FoldTable.offsets[i]), to = Int(FoldTable.offsets[i + 1])
            #expect(FoldTable.values[from..<to].map(UInt32.init) == row.1, "row \(String(row.0, radix: 16))")
        }
        // Every row is what `fold` does to that one scalar (a replacement of spaces alone folds to nothing).
        for row in rows {
            let scalar = try #require(Unicode.Scalar(row.0))
            var expected = String.UnicodeScalarView()
            for value in row.1 where value != 0x20 { expected.append(try #require(Unicode.Scalar(value))) }
            #expect(BrainKey.sameBytes(BrainText.fold(String(scalar)), String(expected)), "U+\(String(row.0, radix: 16))")
        }
    }

    @Test func titleRulesMatchTitleRulesV1() throws {
        let names = ["live", "remix", "acoustic", "instrumental", "remaster", "cover", "karaoke", "sped-up", "slowed",
                     "re-recorded"]
        var flagBits: [Int32] = [], flagTokens: [String] = [], prefixes: [String] = [], equals: [String] = []
        for line in try lines("title-rules-v1") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            let kind = String(parts[0]), tokens = parts.count > 1 ? String(parts[1]) : ""
            if let bit = names.firstIndex(of: kind) {
                flagBits.append(Int32(bit))
                flagTokens.append(tokens)
            } else if kind == "neutral-prefix" {
                prefixes.append(tokens)
            } else {
                #expect(kind == "neutral-equals")
                equals.append(tokens)
            }
        }
        #expect(TitleRules.flagBits == flagBits)
        #expect(TitleRules.flagTokens == flagTokens)
        #expect(TitleRules.neutralPrefix == prefixes)
        #expect(TitleRules.neutralEquals == equals)
        // The flag bits of the table are the public constants.
        #expect(BrainText.flagLive == 1 << 0 && BrainText.flagReRecorded == 1 << 9)
    }
}
