import PixlLibrary
import PixlLyrics
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// Stage 13: the DJ media router and engine, the AI playlist controller's pure parts (request context, names,
/// error table), the AI Playlist Lab's prompt, the lyric translator, the on-device prompt detection and the
/// scripted provider — end to end through PixlNet's orchestrator with `DemoAiClient`, no network.
@MainActor
final class AITests: XCTestCase {
    private struct NoNetwork: HTTPClient {
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            throw HTTPTransportError(message: "no network in tests")
        }
    }

    private func demoOrchestrator() -> AiOrchestrator {
        AiOrchestrator(http: NoNetwork(), settings: DemoAiSettings(), sha256: AIService.sha256,
                       onDeviceClient: DemoAiClient(), clientFactory: { @Sendable _, _, _ in DemoAiClient() })
    }

    private func song(_ id: String, title: String, artist: String = "A", genre: String?) -> Song {
        Song(id: id, title: title, artist: artist, artistId: 1, album: "B", albumId: 1, path: "", contentUriString: "",
             albumArtUriString: nil, duration: 1000, genre: genre, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    // MARK: Media router (Android TaisMediaRouter / MusicDao.getSongsByGenreContaining)

    func testGenreMatchingFollowsTheLikeArms() {
        let songs = [song("1", title: "b", genre: "Rock"), song("2", title: "a", genre: "Pop, rock"),
                     song("3", title: "c", genre: "Pop,Rock,Jazz"), song("4", title: "d", genre: "Rockabilly"),
                     song("5", title: "e", genre: nil), song("6", title: "f", genre: "Punk Rock")]
        XCTAssertEqual(TaisMediaRouter.songsByGenre("rock", in: songs).map(\.id), ["2", "1", "3"])
    }

    func testOfflineRoutes() {
        let songs = [song("1", title: "Night Swim", artist: "Hollow Pines", genre: "Indie"),
                     song("2", title: "Harbor", artist: "Luma Vale", genre: "Indie"),
                     song("3", title: "Static", artist: "Luma Vale", genre: "Rock")]
        let genre = TaisIntentParser.parse("play some indie songs")
        XCTAssertEqual(TaisMediaRouter.routeOffline(genre, songs: songs), .offline([songs[1], songs[0]]))
        let both = DjIntent(rawPrompt: "", action: .play, genres: ["indie"], moods: [], searchQuery: "luma")
        XCTAssertEqual(TaisMediaRouter.routeOffline(both, songs: songs), .offline([songs[1]]))
        XCTAssertEqual(TaisMediaRouter.routeOffline(DjIntent(rawPrompt: "", action: .play, genres: [], moods: ["chill"],
                                                             searchQuery: ""), songs: songs), .noResults)
        XCTAssertEqual(TaisMediaRouter.buildQuery(DjIntent(rawPrompt: "", action: .play, genres: ["rock"], moods: ["chill"],
                                                           searchQuery: "rock")), "rock chill")
    }

    func testRouterPrefersAnExactLibraryMatchAndFallsBackToTheCatalogue() async {
        let songs = DemoLibrary.songs
        let router = TaisMediaRouter(songs: { songs }, remoteProviders: [DemoCatalogSearchProvider()])
        let title = "Neon Harbor"
        let exact = await router.route(TaisIntentParser.parse("play \(title)"))
        guard case .offline(let found) = exact else { return XCTFail("expected library songs, got \(exact)") }
        XCTAssertEqual(found.first?.title, title)
        // Nothing in the library → the (demo) Spotify catalogue.
        let remote = await router.route(TaisIntentParser.parse("play Prism Avenue"))
        guard case .online(let items, let source) = remote else { return XCTFail("expected catalogue tracks, got \(remote)") }
        XCTAssertEqual(source, .spotify)
        XCTAssertEqual(items.count, 1)
    }

    // MARK: DJ engine (Android TaisDjEngine) through the orchestrator

    func testEngineRoutesMediaRequestsAndAnswersQuestions() async {
        let songs = DemoLibrary.songs
        let engine = TaisDjEngine(router: TaisMediaRouter(songs: { songs }, remoteProviders: []), orchestrator: demoOrchestrator())
        let media = await engine.respond("Play some indie songs")
        guard case .media(let intent, .offline(let found), let intro) = media else { return XCTFail("\(media)") }
        XCTAssertEqual(intent.genres, ["indie"])
        XCTAssertTrue(found.allSatisfy { $0.genre == "Indie" })
        XCTAssertEqual(intro, DemoAiClient.introLine)
        let question = await engine.respond("Who produced Random Access Memories?")
        XCTAssertEqual(question, .conversation(DemoAiClient.chatReply))
    }

    func testChatModelReplacesTheThinkingRow() async {
        let songs = DemoLibrary.songs
        let engine = TaisDjEngine(router: TaisMediaRouter(songs: { songs }, remoteProviders: []), orchestrator: demoOrchestrator())
        let model = TaisChatModel(engine: engine, playback: PlaybackStore(engine: DemoPlaybackEngine()))
        await model.runScript(["Play some indie songs", "  ", "Who produced Random Access Memories?"])
        XCTAssertEqual(model.messages.count, 4)
        guard case .user(_, "Play some indie songs") = model.messages[0], case .djReply = model.messages[1],
              case .textReply(_, DemoAiClient.chatReply, false) = model.messages[3] else {
            return XCTFail("\(model.messages)")
        }
        XCTAssertEqual(Set(model.messages.map(\.id)).count, 4)
    }

    // MARK: Playlist generation

    func testRequestContextAndScriptedGeneration() async {
        let songs = DemoLibrary.songs
        let context = AIPlaylistController.computeContext(
            allSongs: songs, events: [], nowMs: 1_789_065_000_000, timeZone: TimeZone(identifier: "UTC")!,
            playlistNames: ["Focus"], candidateLimit: 120, safeTokenLimit: true, digestMode: "safe", includeExtendedFields: false)
        XCTAssertFalse(context.candidates.isEmpty)
        XCTAssertTrue(context.digest.hasPrefix("USER_PROFILE\n"))
        XCTAssertTrue(context.digest.contains("PL: Focus\n"))

        let generator = AiPlaylistGenerator(orchestrator: demoOrchestrator())
        let result = await generator.generate(userPrompt: "rainy day", allSongs: songs, minLength: 3, maxLength: 4,
                                              candidateSongs: context.candidates, playCounts: context.playCounts,
                                              userDigest: context.digest)
        guard case .success(let playlist) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(playlist.map(\.id), Array(context.candidates.enumerated().filter { $0.offset % 2 == 0 }.map(\.element.id).prefix(4)))
    }

    func testScriptedErrorMapsToAndroidsMessage() async {
        let generator = AiPlaylistGenerator(orchestrator: demoOrchestrator())
        let songs = DemoLibrary.songs
        let result = await generator.generate(userPrompt: "jazz \(DemoAiClient.errorTrigger)", allSongs: songs, minLength: 3,
                                              maxLength: 4, candidateSongs: songs, userDigest: "USER_PROFILE\n")
        guard case .failure(let failure) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(AIPlaylistController.resolveErrorMessage(failure.message),
                       "Permission denied by the AI provider. Check that this API key has access to the selected model and that the provider API is enabled.")
    }

    func testErrorTable() {
        XCTAssertEqual(AIPlaylistController.resolveErrorMessage("AI Error: No API key configured. Go to Settings → AI Integration to set up your API key."),
                       AIPlaylistController.apiKeyMessage)
        XCTAssertEqual(AIPlaylistController.resolveErrorMessage("Request timed out. The AI provider may be slow or overloaded. Try again."),
                       "Request timed out. The AI provider is slow or overloaded. Try again in a moment.")
        XCTAssertEqual(AIPlaylistController.resolveErrorMessage("HTTP 429 Too Many Requests"),
                       "Rate limited. The AI provider needs a short break. Wait 30 seconds and try again.")
        XCTAssertEqual(AIPlaylistController.resolveErrorMessage("AI Error: Something odd"), "AI Error: Something odd")
        XCTAssertEqual(AIPlaylistController.errorDetail("  ai error:   "), "Unknown error")
    }

    func testPlaylistNames() {
        XCTAssertEqual(AIPlaylistController.shortTitle("Core request: sunset drive with warm synths. Mood target: Chill."),
                       "Sunset Drive")
        XCTAssertEqual(AIPlaylistController.shortTitle("gym"), "Gym Mix")
        XCTAssertEqual(AIPlaylistController.shortTitle("to the club!!"), "Club Mix")
        XCTAssertEqual(AIPlaylistController.shortTitle("a b"), "Fresh Mix")
        XCTAssertEqual(AIPlaylistController.resolvePlaylistName(requestedName: nil, prompt: "gym",
                                                                existingNames: ["Gym Mix", "gym mix 2"]), "Gym Mix 3")
        XCTAssertEqual(AIPlaylistController.resolvePlaylistName(requestedName: "  Mine ", prompt: "gym", existingNames: []), "Mine")
    }

    // MARK: AI Playlist Lab (Android buildAiPlaylistPrompt)

    func testLabPromptAndValidation() {
        var form = AiPlaylistLabForm()
        XCTAssertEqual(form.prompt, "Energy level target: 3/5. Discovery target: 3/5 where 1 is familiar and 5 is deep cuts. "
                       + "Prioritize songs closer to listener favorites when possible. "
                       + "Keep transitions smooth and avoid repetitive artist clustering.")
        form.basePrompt = " sunset drive "
        form.mood = "Chill"
        form.era = "80s"
        form.avoidExplicit = true
        form.prioritizeFavorites = false
        form.minSongs = "200"
        form.maxSongs = "3"
        XCTAssertTrue(form.prompt.hasPrefix("Core request: sunset drive. Mood target: Chill. Era focus: 80s. Energy level target: 3/5."))
        XCTAssertTrue(form.prompt.contains("Avoid explicit lyrics whenever alternatives exist."))
        XCTAssertEqual(try form.validated().get(), AiPlaylistLabForm.Request(name: nil, prompt: form.prompt, min: 5, max: 150))
        form.minSongs = ""
        XCTAssertEqual(form.validated(), .failure(AiPlaylistLabForm.ValidationError(message: "Set a valid song range.")))
    }

    // MARK: Lyric translation (Android translateLyrics / translateLyricsViaAi)

    func testTranslationPromptAndOutcomes() {
        let prompt = AILyricsTranslator.prompt(lyrics: "[00:01.00] Hola\r\n[00:05.00] Adiós", targetLanguage: "English")
        XCTAssertTrue(prompt.hasPrefix("<task>Translate song lyrics into English.</task>\n\n<rules>\n"))
        XCTAssertTrue(prompt.hasSuffix("<lyrics>\n[00:01.00] Hola\n[00:05.00] Adiós\n</lyrics>"))
        XCTAssertEqual(AILyricsTranslator.outcome(forResponse: " ALREADY_IN_TARGET_LANGUAGE\n"), .alreadyInTargetLanguage)
        XCTAssertEqual(AILyricsTranslator.outcome(forResponse: "  "), .failed(detail: "Empty response"))
        guard case .translated(let validated) = AILyricsTranslator.outcome(
            forResponse: "[00:01.00] Hola\n[00:01.00] Hello\n[00:05.00] Adiós\n[00:05.00] Goodbye") else {
            return XCTFail("expected a valid translation")
        }
        XCTAssertEqual(validated.parsedLyrics.synced?.count, 2)
        if case .failed = AILyricsTranslator.outcome(forResponse: "Sorry, I can't do that.") {} else { XCTFail("plain text must fail") }
        XCTAssertEqual(AILyricsTranslator.outcome(forFailure: "No API key configured."), .notConfigured)
        XCTAssertEqual(LyricsTranslationOutcome.failed(detail: "x").message, "AI Error: x")
    }

    func testTranslatorRefusesTranslatedLyrics() async {
        let translator = AILyricsTranslator(orchestrator: demoOrchestrator())
        var line = SyncedLine(time: 1000, line: "Hola")
        line.translation = "Hello"
        let outcome = await translator.translate(rawLyrics: "[00:01.00] Hola", current: Lyrics(synced: [line]),
                                                 targetLanguage: "English")
        XCTAssertEqual(outcome, .alreadyTranslated)
        let missing = await translator.translate(rawLyrics: " ", current: nil, targetLanguage: "English")
        XCTAssertEqual(missing, .notFound)
        let scripted = await translator.translate(rawLyrics: "[00:01.00] Hola", current: nil, targetLanguage: "English")
        guard case .translated = scripted else { return XCTFail("\(scripted)") }
    }

    // MARK: Prompt shapes, scripted provider, model names

    func testPromptShapesAndScriptedPlaylist() async throws {
        let system = AiPromptEngine.buildPrompt(basePersona: AiPromptEngine.defaultSystemPrompt, type: .playlist)
        XCTAssertTrue(AIPromptShape.expectsSongIdArray(systemPrompt: system))
        XCTAssertTrue(AIPromptShape.expectsSongIdArray(systemPrompt: AiPromptEngine.buildPrompt(basePersona: "x", type: .dailyMix)))
        XCTAssertFalse(AIPromptShape.expectsSongIdArray(systemPrompt: AiPromptEngine.buildPrompt(basePersona: "x", type: .taizoChat)))
        let pool = #"[{"id":"a","t":"x"},{"id":"b"},{"id":"c"},{"id":"d \"q\""}]"#
        let prompt = AiPlaylistPrompt.fullPrompt(userDigest: "USER_PROFILE", userPrompt: "q", minLength: 1, maxLength: 2,
                                                 candidatePoolJSON: pool)
        XCTAssertEqual(AIPromptShape.candidateIds(inPrompt: prompt), ["a", "b", "c", "d \"q\""])
        XCTAssertEqual(AIPromptShape.targetLength(inPrompt: prompt)?.max, 2)
        let reply = try await DemoAiClient().generateContent(model: "", systemPrompt: system, prompt: prompt,
                                                             parameters: AiGenerationParameters())
        XCTAssertEqual(try AiPlaylistPrompt.extractSongIds(reply), ["a", "c"])
        XCTAssertEqual(AIPromptShape.jsonArray(["x\"y"]), #"["x\"y"]"#)
    }

    func testModelDisplayNames() {
        XCTAssertEqual(AIService.modelDisplayName("models/llama-3.1_8b-INSTANT"), "Llama 3.1 8b Instant")
        XCTAssertEqual(AIService.modelDisplayName("gpt-4o-mini"), "Gpt 4o Mini")
    }
}
