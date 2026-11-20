import Foundation
import PixlFoundation
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
        g.noteName(String(repeating: "x", count: 500))
        #expect(g.knownNames == 0)
        g.noteName("   ")
        g.noteName(nil)
        #expect(g.knownNames == 0)
    }

    @Test func creditsSplitOnTheJoinersListenersWrite() {
        #expect(TaizoGrounding.splitCredits("A, B & C feat. D") == ["A", "B", "C", "D"])
        #expect(TaizoGrounding.splitCredits("Tyler, The Creator") == ["Tyler", "The Creator"])
    }
}
