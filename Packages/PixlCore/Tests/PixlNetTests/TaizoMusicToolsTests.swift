import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlNet

/// The ten music tools of Ask Taizo (docs/brain-spec.md, 9.3): their schemas, their place in the cached prefix, the strict split and the
/// prompt additions. The same expectations as Android's `TaizoMusicToolsTest` (schema half) and `TaizoMusicPromptTest`.
@Suite("Ask Taizo music tool schemas")
struct TaizoMusicToolsTests {
    private func parse(_ text: String) throws -> JSONValue { try JSONParser(mode: .strict).parse(text) }

    private func validate(_ tool: TaizoTool, _ text: String) throws -> [String] {
        ClaudeSchemaValidator.validate(try parse(text), against: tool.definition.inputSchema)
    }

    private static let musicNames = [
        "resolve_tracks", "recommend", "build_mix", "start_station", "steer_session",
        "explain_track", "explain_taste", "lookup_genre", "similar_artists", "new_releases",
    ]

    @Test func theTenToolsComeAfterTheSixteenInAFixedOrder() {
        let all = TaizoTool.allCases.map(\.rawValue)
        #expect(TaizoTool.legacy.count == 16)
        #expect(TaizoTool.music.map(\.rawValue) == Self.musicNames)
        #expect(AssistantVocabulary.musicToolNames == Self.musicNames)
        #expect(all == TaizoTool.legacy.map(\.rawValue) + Self.musicNames)
        // The cached prefix: the first 16 never move.
        #expect(all.prefix(16).map { $0 } == [
            "search_library", "search_spotify_catalog", "play_songs", "add_to_queue", "playback_control", "create_playlist",
            "add_to_playlist", "get_listening_insights", "get_lyrics", "start_sing", "like_song", "get_taste_profile",
            "get_library_overview", "adjust_taste", "list_taste_adjustments", "remove_taste_adjustment",
        ])
        #expect(Set(all).count == all.count)
    }

    @Test func everyMusicToolIsClosedAndHasEveryParameterRequiredAndTheStrictOnesStayWithinTheApis20() throws {
        // 15 older strict tools + 5 music ones = 20 (deviation 222): the five small read-only tools are validated locally instead.
        let strictMusic = TaizoTool.music.filter(\.definition.strict).map(\.rawValue)
        #expect(strictMusic == ["resolve_tracks", "recommend", "build_mix", "start_station", "steer_session"])
        #expect(TaizoTool.definitions.filter(\.strict).count <= 20)
        for tool in TaizoTool.music {
            let definition = tool.definition
            #expect(definition.strict == !AssistantVocabulary.nonStrictMusicTools.contains(tool.rawValue))
            #expect(definition.json(streaming: true)["eager_input_streaming"]?.boolValue == true)
            let schema = definition.inputSchema
            #expect(schema["additionalProperties"]?.boolValue == false)
            let properties = (schema["properties"]?.objectValue?.members ?? []).map(\.key)
            let required = (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
            #expect(Set(required) == Set(properties) && required.count == properties.count, "\(tool.rawValue): every parameter is required")
            // Nested objects (resolve_tracks items) are closed and fully required too.
            for member in schema["properties"]?.objectValue?.members ?? [] {
                guard let items = member.value["items"], items["type"]?.stringValue == "object" else { continue }
                #expect(items["additionalProperties"]?.boolValue == false)
                let inner = (items["properties"]?.objectValue?.members ?? []).map(\.key)
                #expect(Set((items["required"]?.arrayValue ?? []).compactMap(\.stringValue)) == Set(inner))
            }
        }
    }

    @Test func theMusicToolsSpendNoneOfThe24OptionalParametersAStrictGrammarAllows() {
        func optionalIn(_ schema: JSONValue) -> Int {
            let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
            var n = 0
            for member in schema["properties"]?.objectValue?.members ?? [] {
                if !required.contains(member.key) { n += 1 }
                if let items = member.value["items"], items["type"]?.stringValue == "object" { n += optionalIn(items) }
            }
            return n
        }
        let music = TaizoTool.music.map { optionalIn($0.definition.inputSchema) }.reduce(0, +)
        #expect(music == 0)
        let legacy = TaizoTool.legacy.filter(\.definition.strict).map { optionalIn($0.definition.inputSchema) }.reduce(0, +)
        #expect(legacy + music <= 24)
    }

    @Test func theEnumsAreTheOnesTheSharedVocabularyHolds() {
        func enumOf(_ tool: TaizoTool, _ prop: String) -> [String] {
            (tool.definition.inputSchema["properties"]?[prop]?["enum"]?.arrayValue ?? []).compactMap(\.stringValue)
        }
        #expect(enumOf(.recommend, "energy") == AssistantVocabulary.energy)
        #expect(enumOf(.recommend, "novelty") == AssistantVocabulary.novelty)
        #expect(enumOf(.buildMix, "tempo") == AssistantVocabulary.tempo)
        #expect(enumOf(.startStation, "seed_kind") == AssistantVocabulary.seedKinds)
        #expect(enumOf(.startStation, "mode") == AssistantVocabulary.stationModes)
        #expect(enumOf(.steerSession, "change") == AssistantVocabulary.steerChanges)
        #expect(enumOf(.steerSession, "scope") == AssistantVocabulary.steerScopes)
        #expect(enumOf(.explainTaste, "scope") == AssistantVocabulary.explainScopes)
        #expect(enumOf(.newReleases, "scope") == AssistantVocabulary.releaseScopes)
    }

    @Test func anInputWithAMissingParameterOrAStrayOneIsRefusedBeforeItRuns() throws {
        let ok = #"{"seed_refs":[],"genre_ids":[],"year_from":0,"year_to":0,"energy":"any","novelty":"any","count":10}"#
        let fine = try validate(.recommend, ok)
        #expect(fine.isEmpty)
        let missing = try validate(.recommend, ok.replacingOccurrences(of: #","count":10"#, with: ""))
        #expect(missing.contains { $0.contains("count: required") })
        let stray = try validate(.recommend, ok.replacingOccurrences(of: #""count":10"#, with: #""count":10,"mood":"x""#))
        #expect(stray.contains { $0.contains("unknown property") })
        let badEnum = try validate(.recommend, ok.replacingOccurrences(of: #""energy":"any""#, with: #""energy":"loud""#))
        #expect(!badEnum.isEmpty)
        let badInt = try validate(.recommend, ok.replacingOccurrences(of: #""genre_ids":[]"#, with: #""genre_ids":["x"]"#))
        #expect(!badInt.isEmpty)
        let resolveOk = try validate(.resolveTracks, #"{"items":[{"title":"A","artist":""}]}"#)
        #expect(resolveOk.isEmpty)
        let resolveMissing = try validate(.resolveTracks, #"{"items":[{"title":"A"}]}"#)
        #expect(resolveMissing.contains { $0.contains("artist: required") })
        // The five that are not strict are validated just the same.
        let explainMissing = try validate(.explainTrack, #"{}"#)
        #expect(explainMissing.contains { $0.contains("ref: required") })
        let releasesOk = try validate(.newReleases, #"{"scope":"my_artists","count":10}"#)
        #expect(releasesOk.isEmpty)
    }

    @Test func onlyTheStartAndSteerToolsChangeAnything() {
        for tool in TaizoTool.music { #expect(tool.isReadOnly == !(tool == .startStation || tool == .steerSession)) }
        let offlineMusic = TaizoTool.offline.filter(\.isMusicTool)
        #expect(offlineMusic.isEmpty, "the on-device model has none of the music tools")
    }

    // MARK: Confirmation

    @Test func aLastingSteerAsksAndAQueueSteerDoesNot() throws {
        func question(_ tool: TaizoTool, _ text: String, queue: Int = 0) throws -> String? {
            let input = try #require(try parse(text).objectValue)
            return TaizoAssistant.confirmationQuestion(tool: tool.rawValue, input: input, currentQueueCount: queue)
        }
        let lasting = try question(.steerSession, #"{"change":"less_artist","target":"Drake","scope":"always"}"#)
        #expect(lasting?.contains("for good") == true)
        let session = try question(.steerSession, #"{"change":"energy_down","target":"","scope":"session"}"#)
        #expect(session == nil)
        let replace = try question(.startStation, #"{"seed_ref":"Radiohead","seed_kind":"artist","mode":"blend"}"#, queue: 12)
        #expect(replace?.contains("Replace your queue") == true)
        let single = try question(.startStation, #"{"seed_ref":"Radiohead","seed_kind":"artist","mode":"blend"}"#, queue: 1)
        #expect(single == nil)
        let other = try question(.recommend, #"{}"#, queue: 12)
        #expect(other == nil)
    }

    @Test func aMixIsCountedBySongsNotAsOneIdAndASteerNamesWhatItChanges() throws {
        func question(_ tool: TaizoTool, _ text: String, queue: Int = 0, mixes: [String: Int] = [:],
                      nameOf: (String) -> String? = { _ in nil }) throws -> String? {
            let input = try #require(try parse(text).objectValue)
            return TaizoAssistant.confirmationQuestion(tool: tool.rawValue, input: input, currentQueueCount: queue, mixCounts: mixes, nameOf: nameOf)
        }
        // A 30-song mix is not "1 song".
        let play = try question(.playSongs, #"{"song_ids":["mix:ab12"],"queries":[],"start_index":0}"#, queue: 8, mixes: ["ab12": 30])
        #expect(play == "Replace your queue (8 songs) with 30 songs?")
        // A playlist of two mixes passes the 50-song line, though the call holds two ids.
        let big = try question(.createPlaylist, #"{"name":"Road","song_ids":["mix:a","mix:b"],"queries":[]}"#, mixes: ["a": 30, "b": 30])
        #expect(big == "Create \u{201C}Road\u{201D} with 60 songs?")
        let small = try question(.createPlaylist, #"{"name":"Road","song_ids":["mix:a"],"queries":[]}"#, mixes: ["a": 30])
        #expect(small == nil)
        // A lasting steer says the artist or genre, never the raw ref or id.
        let nameOf: (String) -> String? = { $0 == "12" ? "Bedroom pop" : ($0 == "yt:abcdefghijk" ? "Mono" : nil) }
        let genre = try question(.steerSession, #"{"change":"less_genre","target":"12","scope":"always"}"#, nameOf: nameOf)
        #expect(genre == "Keep this for good: play less of Bedroom pop? You can undo it in Settings.")
        let artist = try question(.steerSession, #"{"change":"more_artist","target":"yt:abcdefghijk","scope":"always"}"#, nameOf: nameOf)
        #expect(artist?.contains("play more of Mono") == true)
        let unknown = try question(.steerSession, #"{"change":"more_artist","target":"yt:zzzzzzzzzzz","scope":"always"}"#, nameOf: nameOf)
        #expect(unknown?.contains("yt:") == false)
    }

    // MARK: The prompt

    @Test func theMusicRulesComeAfterTheExistingGuidanceAndSayWhatTheSpecSays() {
        let text = TaizoAssistant.instructions
        #expect(text.hasSuffix(TaizoAssistant.musicRules))
        #expect(text.range(of: "closest alternative")!.lowerBound < text.range(of: "Music picks come from the listener's own engine")!.lowerBound)
        for line in [
            "Never name a track, album or artist as a recommendation unless a tool returned it in this conversation.",
            "If you think of a song yourself, pass it to resolve_tracks first and drop anything not found.",
            "To recommend, call recommend or build_mix with structured filters. Do not rank or reorder what they return.",
            "Genre and mood filters are ids. Get them from lookup_genre; do not guess ids.",
            "To explain a pick or the listener's taste, call explain_track or explain_taste and report only what they return.",
            "If a field is listed as unknown, say it is unknown.",
            "Numbers about the listener come only from tool results.",
            "Put [[double square brackets]] around every track, album and artist you name, spelled as a tool returned it. The app takes the brackets off.",
        ] { #expect(text.contains(line)) }
        // Every tool the rules name exists.
        let names = Set(TaizoTool.allCases.map(\.rawValue))
        for name in ["resolve_tracks", "recommend", "build_mix", "lookup_genre", "explain_track", "explain_taste"] { #expect(names.contains(name)) }
    }

    @Test func everyMusicToolHasALineForTheListenerAndNoOtherToolDoes() {
        for tool in TaizoTool.music { #expect(TaizoMusicStrings.activity(for: tool)?.isEmpty == false, "\(tool.rawValue)") }
        for tool in TaizoTool.legacy { #expect(TaizoMusicStrings.activity(for: tool) == nil) }
        #expect(TaizoMusicStrings.withoutMarks("[[Espresso]] by [[Sabrina Carpenter]]") == "Espresso by Sabrina Carpenter")
        #expect(TaizoMusicStrings.withoutMarks("[[Esp") == "Esp")
    }

    @Test func theAssistantsWordsNeverNameTheVendorOrTheModelOrTheForbiddenFeatureWords() {
        let forbidden = ["lossless", "hi-res", "dolby", "atmos", "360 reality", "claude", "anthropic", "binilyrics", "enhanced"]
        var texts = [TaizoAssistant.musicRules, TaizoMusicStrings.unverifiedName]
        texts += TaizoTool.music.compactMap(TaizoMusicStrings.activity(for:))
        for tool in TaizoTool.music {
            texts.append(tool.definition.description)
            texts.append(JSONWriter.write(tool.definition.inputSchema))
        }
        for text in texts {
            for word in forbidden { #expect(!text.lowercased().contains(word), "\"\(word)\" in: \(text.prefix(60))") }
        }
    }
}
