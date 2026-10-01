import Foundation
import PixlFoundation
import Testing
@testable import PixlLibrary

/// Port of `data/worker/ArtistParsingUtilsTest.kt` plus golden vectors from the compiled Android code.
@Suite struct ArtistParsingTests {
    let defaults = ArtistParsing.defaultArtistDelimiters
    let words = ArtistParsing.defaultWordDelimiters

    @Test func defaultDelimitersPreserveAmpersandSlashCommaAndPlusInsideArtistNames() {
        #expect(ArtistParsing.collectArtistNames(rawArtistName: "W&W", title: "Rave Culture",
                                                 artistDelimiters: defaults, wordDelimiters: words) == ["W&W"])
        #expect(ArtistParsing.collectArtistNames(rawArtistName: "AC/DC", title: "Back In Black",
                                                 artistDelimiters: defaults, wordDelimiters: words) == ["AC/DC"])
        #expect(ArtistParsing.collectArtistNames(rawArtistName: "Lost & Found", title: "Found",
                                                 artistDelimiters: defaults, wordDelimiters: words) == ["Lost & Found"])
        #expect(ArtistParsing.collectArtistNames(rawArtistName: "Black Country, New Road", title: "Track X",
                                                 artistDelimiters: defaults, wordDelimiters: words)
            == ["Black Country, New Road"])
    }

    @Test func choosePreferredArtistNamePrefersMediaStoreWhenItContainsMoreArtists() {
        let result = ArtistParsing.choosePreferredArtistName(
            localArtistName: "Calvin Harris",
            mediaStoreArtistName: "Calvin Harris, Pharrell Williams, Katy Perry, Big Sean, Funk Wav",
            artistDelimiters: [",", "&"], wordDelimiters: [])
        #expect(result == "Calvin Harris, Pharrell Williams, Katy Perry, Big Sean, Funk Wav")
    }

    @Test func choosePreferredArtistNamePreservesRicherLocalMetadataWhenMediaStoreIsReducedToPrimary() {
        let result = ArtistParsing.choosePreferredArtistName(
            localArtistName: "Calvin Harris, Pharrell Williams, Katy Perry", mediaStoreArtistName: "Calvin Harris",
            artistDelimiters: [",", "&"], wordDelimiters: [])
        #expect(result == "Calvin Harris, Pharrell Williams, Katy Perry")
    }

    @Test func collectArtistNamesMergesTitleFeaturesWithoutDuplicatingExistingArtists() {
        let result = ArtistParsing.collectArtistNames(
            rawArtistName: "Calvin Harris, Pharrell Williams", title: "Feels (feat. Katy Perry & Big Sean)",
            artistDelimiters: [",", "&"], wordDelimiters: ["feat."], extractFromTitle: true)
        #expect(result == ["Calvin Harris", "Pharrell Williams", "Katy Perry", "Big Sean"])
    }

    // Examples from the KDoc of `splitArtistsByDelimiters`.
    @Test func kdocExamples() {
        #expect(ArtistParsing.split("Artist1/Artist2", delimiters: ["/"]) == ["Artist1", "Artist2"])
        #expect(ArtistParsing.split("AC\\\\/DC", delimiters: ["/"]) == ["AC/DC"])
        #expect(ArtistParsing.split("Drake feat. Rihanna", delimiters: [], wordDelimiters: ["feat."]) == ["Drake", "Rihanna"])
        #expect(ArtistParsing.split("Marshmello x Bastille", delimiters: [], wordDelimiters: ["x"]) == ["Marshmello", "Bastille"])
        #expect(ArtistParsing.split("   ", delimiters: [";"]) == [])
    }

    @Test func legacyDefaultDelimitersMigrate() {
        #expect(ArtistParsing.normalizeLegacyDefaultArtistDelimiters(["/", ";", ",", "+", "&"]) == [";"])
        #expect(ArtistParsing.normalizeLegacyDefaultArtistDelimiters(["/", ";"]) == ["/", ";"])
    }

    @Test func metadataTextRepairsMojibake() {
        #expect(MetadataText.normalize("CafÃ©") == "Café")
        #expect(MetadataText.normalize(nil) == nil)
        #expect(MetadataText.normalize("  ") == "")
        #expect(MetadataText.normalize("e\u{301}")!.unicodeScalars.count == 1)
    }

    /// Every case run through the Android app's compiled `splitArtistsByDelimiters`, `extractArtistsFromTitle`,
    /// `collectArtistNames`, `choosePreferredArtistName` and `normalizeMetadataText`.
    @Test func matchesAndroidGoldenVectors() throws {
        var failures: [String] = []
        var count = 0
        for line in try goldenLines("artist-parsing-golden.jsonl") {
            let input = line["in"]!, out = line["out"]!
            count += 1
            switch line["fn"]!.str {
            case "split":
                let got = ArtistParsing.split(input["s"]!.str, delimiters: input["d"]!.strings, wordDelimiters: input["w"]!.strings)
                if !got.elementsEqual(out.strings, by: KotlinText.equals) { failures.append("split \(input) → \(got) ≠ \(out.strings)") }
            case "title":
                let got = ArtistParsing.extractArtistsFromTitle(input["s"]!.str, delimiters: input["d"]!.strings,
                                                                wordDelimiters: input["w"]!.strings)
                if !KotlinText.equals(got.title, out["title"]!.str) || !got.artists.elementsEqual(out["artists"]!.strings, by: KotlinText.equals) {
                    failures.append("title \(input) → \(got) ≠ \(out)")
                }
            case "collect":
                let got = ArtistParsing.collectArtistNames(rawArtistName: input["raw"]!.str, title: input["title"]!.str,
                                                           artistDelimiters: input["d"]!.strings,
                                                           wordDelimiters: input["w"]!.strings,
                                                           extractFromTitle: input["extract"]!.bool)
                if !got.elementsEqual(out.strings, by: KotlinText.equals) { failures.append("collect \(input) → \(got) ≠ \(out)") }
            case "prefer":
                let got = ArtistParsing.choosePreferredArtistName(localArtistName: input["local"]!.str,
                                                                  mediaStoreArtistName: input["media"]!.str,
                                                                  artistDelimiters: input["d"]!.strings,
                                                                  wordDelimiters: input["w"]!.strings)
                if !KotlinText.equals(got, out.str) { failures.append("prefer \(input) → \(got) ≠ \(out)") }
            case "normalize":
                let got = MetadataText.normalize(input.optStr)
                let expected = out.optStr
                let same = (got == nil && expected == nil) || (got != nil && expected != nil && KotlinText.equals(got!, expected!))
                if !same { failures.append("normalize \(input) → \(String(reflecting: got)) ≠ \(String(reflecting: expected))") }
            default:
                Issue.record("unknown fn")
            }
        }
        #expect(count > 7000)
        #expect(failures.isEmpty, "\(failures.count) mismatches, first: \(failures.prefix(15).joined(separator: "\n"))")
    }
}
