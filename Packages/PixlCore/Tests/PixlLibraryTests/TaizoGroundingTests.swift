import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

/// The grounding rule over a whole conversation (docs/brain-spec.md, 1 principle 9 and 9.4): what a tool returned may be said, nothing else.
/// The same expectations as Android's `TaizoGroundingTest`.
@Suite("Ask Taizo grounding")
struct TaizoGroundingTests {
    let g = TaizoGrounding()
    let placeholder = "(unchecked)"

    @Test func aNameAToolReturnedMayBeNamedMarkedOrNotAndAnInventedOneIsReplaced() {
        g.noteTrack(AssistantTrack(ref: "yt:abcdefghijk", title: "Espresso", artist: "Sabrina Carpenter, Chappell Roan", year: 2024,
                                   inLibrary: false, album: "Short n' Sweet"))
        let v = g.check("Try [[Espresso]] by [[Sabrina Carpenter]], from [[Short n' Sweet]]. Also [[Good Luck, Babe!]].", placeholder: placeholder)
        #expect(v.ungroundedNames == ["Good Luck, Babe!"])
        #expect(v.cleaned == "Try Espresso by Sabrina Carpenter, from Short n' Sweet. Also (unchecked).")
        // Each credited artist is a name of its own.
        #expect(g.check("[[Chappell Roan]]", placeholder: placeholder).ok)
        #expect(g.check("[[Sabrina Carpenter & Chappell Roan]]", placeholder: placeholder).ok)
    }

    @Test func aRefIsUsableOnceAToolIssuedItAndNotBefore() {
        #expect(!g.isKnownRef("yt:abcdefghijk"))
        g.noteTrack(AssistantTrack(ref: "yt:abcdefghijk", title: "Espresso", artist: "Sabrina Carpenter", year: 2024, inLibrary: false))
        #expect(g.isKnownRef("yt:abcdefghijk"))
        var unknown: [String] = []
        #expect(g.known(["yt:abcdefghijk", "yt:zzzzzzzzzzz"], &unknown) == ["yt:abcdefghijk"])
        #expect(unknown == ["yt:zzzzzzzzzzz"])
        g.reset()
        #expect(!g.isKnownRef("yt:abcdefghijk"))
        #expect(!g.check("[[Espresso]]", placeholder: placeholder).ok)
    }

    @Test func anyToolResultTheOlderOnesTooMakesItsNamesAndNumbersSayable() {
        g.noteToolResult(#"{"results":[{"id":"12","title":"Blinding Lights","artist":"The Weeknd","plays":212}],"note":"x"}"#)
        #expect(g.check("[[Blinding Lights]] by [[The Weeknd]]: 212 plays.", placeholder: placeholder).ok)
        #expect(!g.check("[[Save Your Tears]].", placeholder: placeholder).ok)
        #expect(!g.check("That is 400 plays.", placeholder: placeholder).ok)
    }

    @Test func whatTheAppShowedTheModelCountsLineByLine() {
        g.noteContext("Top artists: Radiohead (212), Phoebe Bridgers (90)\nMost played songs:\n- Motion Sickness - Phoebe Bridgers (40 plays)")
        #expect(g.check("[[Radiohead]] and [[Phoebe Bridgers]] and [[Motion Sickness]]; 212 plays.", placeholder: placeholder).ok)
        #expect(!g.check("[[Thom Yorke]]", placeholder: placeholder).ok)
    }

    @Test func whatTheListenerWroteIsTheirsAcrossTurns() {
        g.noteUser("play something like Please Please Please")
        g.noteUser("make it 30 songs")
        #expect(g.check("[[Please Please Please]] is a good place to start, with 30 songs.", placeholder: placeholder).ok)
        #expect(!g.check("[[Taste]] and 99 songs.", placeholder: placeholder).ok)
    }

    @Test func anOlderChatsToolResultsAndWordsComeBackFromItsHistory() throws {
        func parse(_ s: String) throws -> JSONValue { try JSONParser().parse(s) }
        let history: [JSONValue] = [
            try parse(#"{"role":"user","content":[{"type":"text","text":"who is Boygenius"}]}"#),
            try parse(#"{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"{\"artists\":[{\"name\":\"Lucy Dacus\",\"score\":88}]}"}]}"#),
            try parse(#"{"role":"assistant","content":[{"type":"text","text":"[[Lucy Dacus]] is one of them."}]}"#),
        ]
        g.noteHistory(history)
        #expect(g.isSeeded)
        #expect(g.check("[[Lucy Dacus]] and [[Boygenius]].", placeholder: placeholder).ok)
        #expect(!g.check("[[Julien Baker]]", placeholder: placeholder).ok)
    }

    @Test func whatAWebPageReturnedIsHeldButTheModelsOwnTextNeverIs() throws {
        let messages: [JSONValue] = [
            try JSONParser().parse(#"{"role":"assistant","content":[{"type":"web_search_tool_result","tool_use_id":"s1","content":[{"type":"web_search_result","title":"Boygenius tour dates","page_content":"Lucy Dacus, Julien Baker and Phoebe Bridgers play 12 shows"}]},{"type":"text","text":"[[Taylor Swift]] is great."}]}"#),
        ]
        g.noteServerResults(messages)
        #expect(g.check("The page is [[Boygenius tour dates]].", placeholder: placeholder).ok)
        #expect(g.check("It says \"Lucy Dacus, Julien Baker and Phoebe Bridgers play 12 shows\".", placeholder: placeholder).ok)
        // The reply's own words are not held: a name only the model said stays unchecked and is replaced.
        #expect(!g.check("[[Taylor Swift]]", placeholder: placeholder).ok)
    }

    @Test func aNameThatIsTooLongToBeANameIsNotRegistered() {
        // The app's own words are always known; nothing else is yet.
        let own = g.knownNames
        #expect(own == TaizoGrounding.appNames.count)
        g.noteName(String(repeating: "x", count: 500))
        #expect(g.knownNames == own)
        g.noteName("   ")
        g.noteName(nil)
        #expect(g.knownNames == own)
    }

    // MARK: The review (stage 4 milestone 2): the guarantee does not rest on the model marking names

    @Test func aNameWrittenWithNoMarkAndNoQuoteIsCheckedToo() {
        g.noteTrack(AssistantTrack(ref: "yt:abcdefghijk", title: "Espresso", artist: "Sabrina Carpenter", year: 2024, inLibrary: false))
        let v = g.check("You might also try Radiohead or OK Computer. Espresso by Sabrina Carpenter is a good start.", placeholder: placeholder)
        #expect(!v.ok)
        #expect(v.ungroundedNames.contains("Radiohead"))
        #expect(!v.cleaned.contains("Radiohead"))
        #expect(v.cleaned.contains("Sabrina Carpenter"))
        // The app's own words are not names to check.
        #expect(g.check("Your Mix and First Listen both lean on your sound.", placeholder: placeholder).ok)
    }

    @Test func aReplyWhoseEverySentenceIsLeftOutIsNeverShownRaw() {
        g.noteUser("what did I play lately")
        let raw = "You have played it 500 times."
        let shown = g.shown(raw)
        #expect(shown == TaizoGrounding.unverifiedReply)
        #expect(!shown.contains("500"))
        // An invented name AND a number in one reply: nothing of the raw text is in what is shown.
        let both = g.shown("[[Fake Band]] has 500 plays.")
        #expect(!both.contains("Fake Band") && !both.contains("500"))
        #expect(g.shown("") == "")
    }

    @Test func aReplyThatStillStreamsHoldsBackWhatItCannotJudgeYet() {
        #expect(TaizoGrounding.holdBack("Try [[Fake Ba") == "")
        #expect(TaizoGrounding.holdBack("Also try [[Fake Ba") == "Also try ")
        #expect(TaizoGrounding.holdBack("He said \"Fake") == "He said ")
        #expect(TaizoGrounding.holdBack("It is nice and Radiohe") == "It is nice ")
        // A run of capitalised words at the end may still grow: the next word can belong to it.
        #expect(TaizoGrounding.holdBack("You might like Sabrina ") == "You might like ")
        #expect(TaizoGrounding.holdBack("Nothing yet") == "")
        #expect(TaizoGrounding.holdBack("It is nothing yet") == "It is nothing ")
        #expect(TaizoGrounding.holdBack("one") == "")
        g.noteTrack(AssistantTrack(ref: "yt:abcdefghijk", title: "Espresso", artist: "Sabrina Carpenter", year: 2024, inLibrary: false))
        // The invented name never shows, not even for the moment it streams; the real one does once it is whole.
        #expect(!g.streaming("Try [[Fake Band]] and also [[Sabrina").contains("Fake Band"))
        #expect(g.streaming("Try [[Fake Band]] and also ").contains("(a name I could not check)"))
        #expect(g.streaming("Try [[Sabrina Carpenter]] now ").contains("Sabrina Carpenter"))
        #expect(g.streaming("") == "")
    }

    @Test func aPhoneModelsAnswerMayNameWhatIsInTheListenersLibraryAndNothingElse() {
        let song = Song(id: "1", title: "Harbor Lights", artist: "Luma Vale, Orla", artistId: 1,
                        artists: [ArtistRef(id: 1, name: "Luma Vale", isPrimary: true), ArtistRef(id: 2, name: "Orla", isPrimary: false)],
                        album: "Night Swim", albumId: 1, path: "", contentUriString: "", albumArtUriString: nil, duration: 1_000, genre: "Indie",
                        mimeType: nil, bitrate: nil, sampleRate: nil)
        let known: ([String]) -> [String] = { TaizoGrounding.libraryNames(among: $0, in: [song]) }
        let text = "Try Luma Vale, or Radiohead if you like, and the album Night Swim."
        let shown = g.shown(text, numbers: false, alsoKnown: known)
        #expect(shown.contains("Luma Vale") && shown.contains("Night Swim"))
        #expect(!shown.contains("Radiohead"))
        #expect(TaizoGrounding.libraryNames(among: ["luma vale", "Nobody"], in: [song]) == ["luma vale"])
        // Names only: a count the app cannot see does not cut the answer.
        #expect(g.shown("You have 12 songs in your library.", numbers: false) == "You have 12 songs in your library.")
        #expect(g.shown("You have 12 songs in your library.") == TaizoGrounding.unverifiedReply)
    }

    @Test func anIntroLineThatNamesWhatNoToolReturnedIsDropped() {
        #expect(g.introLine("Here are 2 songs.") == "Here are 2 songs.")
        #expect(g.introLine("Some Radiohead warmth for you.") == nil)
        g.noteUser("play some radiohead")
        #expect(g.introLine("Some Radiohead warmth for you.") != nil)
    }

    @Test func refsAndIdsOfTheToolResultsOfThisChatAreTheOnlyOnesTheNextCallMayUse() {
        // A similar artist's ref and a lookup's id are in tool results: the next call may use them though no track was noted.
        g.noteToolResult(#"{"artists":[{"name":"Mono","ref":"yt:abcdefghijk","rank":1}]}"#)
        #expect(g.isKnownRef("yt:abcdefghijk"))
        #expect(!g.isKnownRef("yt:zzzzzzzzzzz"))
        g.noteToolResult(#"{"found":true,"kind":"genre","id":12,"name":"Bedroom pop"}"#)
        g.noteToolResult(#"{"found":true,"kind":"mood","id":3,"name":"Calm"}"#)
        var unknown: [String] = []
        #expect(g.knownGenreIds([12, 99, 0], &unknown) == [12, 0])
        #expect(unknown == ["genre 99"])
        unknown = []
        // A mood and a genre share numbers: mood 12 is not a mood, genre 3 is not a genre.
        #expect(g.knownMoodIds([3, 12], &unknown) == [3])
        #expect(unknown == ["mood 12"])
        #expect(g.genreName(12) == "Bedroom pop")
        #expect(g.genreName(3) == nil)
        // An older chat's history brings its refs back, and a new chat forgets them.
        g.reset()
        #expect(!g.isKnownRef("yt:abcdefghijk"))
        #expect(g.genreName(12) == nil)
    }

    @Test func creditsSplitOnTheJoinersListenersWrite() {
        #expect(TaizoGrounding.splitCredits("A, B & C feat. D") == ["A", "B", "C", "D"])
        #expect(TaizoGrounding.splitCredits("Tyler, The Creator") == ["Tyler", "The Creator"])
    }
}
