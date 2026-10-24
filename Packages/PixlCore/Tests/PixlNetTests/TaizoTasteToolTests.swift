import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

/// Ask Taizo's taste tools: schemas, confirmation, the injection guard and the prompt/context wording.
@Suite struct TaizoTasteToolTests {
    private func object(_ members: [(String, JSONValue)]) -> JSONObject {
        JSONObject(members.map { (key: $0.0, value: $0.1) })
    }

    private func change(_ action: String, _ target: String = "Daft Punk", type: String = "artist") -> JSONValue {
        ClaudeJSON.object([("action", .string(action)), ("target_type", .string(type)), ("target", .string(target)),
                           ("reason", .string("asked"))])
    }

    private func validate(_ tool: TaizoTool, _ members: [(String, JSONValue)]) -> [String] {
        ClaudeSchemaValidator.validate(ClaudeJSON.object(members), against: tool.definition.inputSchema)
    }

    // MARK: Schemas

    @Test func theNewToolsAreRegisteredAfterTheOldOnesInAFixedOrder() {
        let names = TaizoTool.allCases.map(\.rawValue)
        #expect(names.suffix(5) == ["get_taste_profile", "get_library_overview", "adjust_taste", "list_taste_adjustments",
                                    "remove_taste_adjustment"])
        #expect(names.prefix(11).last == "like_song", "the earlier tools keep their place in the cached prefix")
        #expect(Set(names).count == names.count)
    }

    @Test func mutatingTasteToolsAreNotReadOnly() {
        #expect(TaizoTool.getTasteProfile.isReadOnly && TaizoTool.getLibraryOverview.isReadOnly)
        #expect(TaizoTool.listTasteAdjustments.isReadOnly && TaizoTool.searchLibrary.isReadOnly)
        #expect(!TaizoTool.adjustTaste.isReadOnly && !TaizoTool.removeTasteAdjustment.isReadOnly)
        #expect(!TaizoTool.playSongs.isReadOnly)
        #expect(TaizoTool.offline.contains(.getTasteProfile) && !TaizoTool.offline.contains(.adjustTaste),
                "the on-device model can read the taste but not change it")
    }

    @Test func tasteProfileTakesAnOptionalPeriod() {
        #expect(validate(.getTasteProfile, []).isEmpty)
        for period in TaizoTool.tastePeriods { #expect(validate(.getTasteProfile, [("period", .string(period))]).isEmpty) }
        #expect(!validate(.getTasteProfile, [("period", .string("week"))]).isEmpty)
        #expect(!validate(.getTasteProfile, [("who", .string("me"))]).isEmpty)
        #expect(validate(.getLibraryOverview, []).isEmpty && validate(.listTasteAdjustments, []).isEmpty)
    }

    @Test func adjustTasteValidatesEveryEntry() {
        let ok: [(String, JSONValue)] = [("adjustments", .array([change("boost"), change("mute", "Jazz", type: "genre")])),
                                         ("user_asked", .bool(true))]
        #expect(validate(.adjustTaste, ok).isEmpty)
        for action in TaizoTool.tasteActions { #expect(validate(.adjustTaste, [("adjustments", .array([change(action)])), ("user_asked", .bool(true))]).isEmpty) }
        #expect(!validate(.adjustTaste, [("adjustments", .array([change("delete")])), ("user_asked", .bool(true))]).isEmpty)
        #expect(!validate(.adjustTaste, [("adjustments", .array([change("boost", type: "playlist")])), ("user_asked", .bool(true))]).isEmpty)
        #expect(!validate(.adjustTaste, [("adjustments", .array([change("boost")]))]).isEmpty, "user_asked is required")
        #expect(!validate(.adjustTaste, [("user_asked", .bool(true))]).isEmpty, "adjustments is required")
        // Strength and expiry may be integers or null; anything else is rejected.
        func entry(_ extra: [(String, JSONValue)]) -> JSONValue {
            ClaudeJSON.object([("action", .string("boost")), ("target_type", .string("artist")), ("target", .string("A")),
                               ("reason", .string("r"))] + extra)
        }
        #expect(validate(.adjustTaste, [("adjustments", .array([entry([("strength", .integer(3)), ("expires_days", .null)])])),
                                        ("user_asked", .bool(true))]).isEmpty)
        #expect(!validate(.adjustTaste, [("adjustments", .array([entry([("strength", .string("high"))])])), ("user_asked", .bool(true))]).isEmpty)
        #expect(!validate(.adjustTaste, [("adjustments", .array([entry([("volume", .integer(1))])])), ("user_asked", .bool(true))]).isEmpty,
                "entries are closed objects")
    }

    @Test func removalTakesAnIdOrAll() {
        #expect(validate(.removeTasteAdjustment, [("id", .string("ta_1"))]).isEmpty)
        #expect(validate(.removeTasteAdjustment, [("all", .bool(true))]).isEmpty)
        #expect(!validate(.removeTasteAdjustment, [("all", .string("yes"))]).isEmpty)
    }

    @Test func searchLibraryTakesTheFullLibraryFilters() {
        let filters: [(String, JSONValue)] = [
            ("query", .string("")), ("artist", .string("Air")), ("album", .string("Moon Safari")), ("genre", .string("Electronic")),
            ("year_from", .integer(1995)), ("year_to", .integer(2005)), ("min_plays", .integer(1)), ("max_plays", .integer(50)),
            ("liked_only", .bool(true)), ("never_played", .bool(false)), ("sort", .string("most_played")),
            ("limit", .integer(200)), ("offset", .integer(400)),
        ]
        #expect(validate(.searchLibrary, filters).isEmpty)
        for sort in TaizoTool.searchSorts { #expect(validate(.searchLibrary, [("query", .string("")), ("sort", .string(sort))]).isEmpty) }
        #expect(!validate(.searchLibrary, [("query", .string("")), ("sort", .string("loudest"))]).isEmpty)
        #expect(!validate(.searchLibrary, [("query", .string("")), ("year_from", .string("1995"))]).isEmpty)
        let description = TaizoTool.searchLibrary.definition.description
        #expect(description.contains("200") && description.contains("offset"))
    }

    // MARK: Confirmation

    @Test func blockingManyTargetsAndClearingAllAskFirst() {
        func ask(_ tool: TaizoTool, _ members: [(String, JSONValue)], count: Int = 0) -> String? {
            TaizoAssistant.confirmationQuestion(tool: tool.rawValue, input: object(members), currentQueueCount: 0, adjustmentCount: count)
        }
        // Everything else applies at once.
        #expect(ask(.adjustTaste, [("adjustments", .array([change("boost"), change("reduce"), change("mute")]))]) == nil)
        #expect(ask(.adjustTaste, [("adjustments", .array((0..<5).map { change("boost", "A\($0)") }))]) == nil, "5 targets is still fine")
        #expect(ask(.adjustTaste, [("adjustments", .array([change("unblock")]))]) == nil)
        // Block asks, naming what it blocks.
        let block = ask(.adjustTaste, [("adjustments", .array([change("boost"), change("block", "Nickelback")]))])
        #expect(block?.hasPrefix("Block Nickelback?") == true)
        let blocks = ask(.adjustTaste, [("adjustments", .array((0..<5).map { change("block", "Artist \($0)") }))])
        #expect(blocks?.contains("Artist 0, Artist 1, Artist 2 and 2 more") == true)
        // More than 5 targets asks.
        #expect(ask(.adjustTaste, [("adjustments", .array((0..<6).map { change("boost", "A\($0)") }))]) == "Change your taste for 6 things at once?")
        // Clearing everything asks (and says how many), removing one does not.
        #expect(ask(.removeTasteAdjustment, [("all", .bool(true))], count: 7) == "Clear all 7 of your taste changes?")
        #expect(ask(.removeTasteAdjustment, [("all", .bool(true))], count: 0) == nil)
        #expect(ask(.removeTasteAdjustment, [("id", .string("ta_1"))], count: 7) == nil)
        // The earlier rules are unchanged.
        #expect(TaizoAssistant.confirmationQuestion(tool: "play_songs", input: object([("song_ids", .array([.string("a")]))]),
                                                    currentQueueCount: 12) == "Replace your queue (12 songs) with 1 song?")
        #expect(TaizoTasteRules.confirmAbove == 5 && TaizoTasteRules.maxPerCall == 20 && TaizoTasteRules.maxPageSize == 200)
    }

    // MARK: Injection guard

    @Test func onlyTheUsersOwnWordsCanChangeTheTaste() {
        let asked = object([("adjustments", .array([change("boost")])), ("user_asked", .bool(true))])
        #expect(TasteChangeGuard.check(input: asked, lastUserMessage: "play more daft punk") == .allowed)
        // The model says nobody asked (or doesn't say): refused.
        let unasked = object([("adjustments", .array([change("block")])), ("user_asked", .bool(false))])
        if case .refused(let why) = TasteChangeGuard.check(input: unasked, lastUserMessage: "play more daft punk") {
            #expect(why.contains("user_asked"))
        } else { Issue.record("must refuse without user_asked") }
        #expect(TasteChangeGuard.check(input: object([("adjustments", .array([]))]), lastUserMessage: "hi") != .allowed)
        // Claimed but there is no real user message for the turn (a tool result or a page is the only text around).
        for empty in [nil, "", "   \n"] as [String?] {
            if case .refused = TasteChangeGuard.check(input: asked, lastUserMessage: empty) {} else { Issue.record("must refuse with no user message") }
        }
        #expect(TasteChangeGuard.checkRemoval(lastUserMessage: "undo that") == .allowed)
        #expect(TasteChangeGuard.checkRemoval(lastUserMessage: nil) != .allowed)
    }

    // MARK: Prompt and context

    @Test func thePromptGroundsClaimsAndTreatsOutsideTextAsData() {
        let text = TaizoAssistant.instructions
        for needle in ["get_taste_profile", "get_library_overview", "adjust_taste", "list_taste_adjustments", "remove_taste_adjustment",
                       "user_asked", "DATA", "web_search", "web_fetch", "confidence", "how to undo", "never invent ids", "offset"] {
            #expect(text.contains(needle), "the instructions mention \(needle)")
        }
        #expect(text.contains("lyric") && text.contains("tool result"), "outside text is named as data")
        // Everything the prompt names is a real tool.
        let names = Set(TaizoTool.allCases.map(\.rawValue))
        for token in text.split(whereSeparator: { !($0.isLetter || $0 == "_") }).map(String.init) where token.contains("_") {
            if ["user_asked", "six_months", "all_time", "listening_context"].contains(token) { continue }
            #expect(names.contains(token) || ["web_search", "web_fetch"].contains(token), "\(token) is a tool")
        }
        #expect(TaizoAssistant.serverTools == [.webSearch, .webFetch])
        #expect(ClaudeAPI.webToolMaxUses == 10)
    }

    @Test func theContextCarriesTheCodeBuiltDigestAfterTheCacheableBlocks() {
        let digest = ["Taste digest (all time, 60 plays). Confidence: medium.", "Top artists: Aria (30), Beat (20)"]
        let context = TaizoListeningContext(librarySongCount: 10, libraryArtistCount: 4, tasteDigest: digest)
        let text = context.render()
        #expect(text.contains("Top artists: Aria (30), Beat (20)") && text.hasSuffix("</listening_context>"))
        let system = TaizoAssistant.system(context: text)
        #expect(system.count == 2 && system[1].cacheBreakpoint && !system[0].cacheBreakpoint, "the breakpoint stays on the last stable block")
        #expect(TaizoListeningContext.maxRecent == 10 && TaizoListeningContext.maxArtists == 15)
    }
}
