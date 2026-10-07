import PixlLibrary
import PixlLyrics
import PixlModel
import PixlNet
import XCTest
@testable import PixlAudio

/// Local AI, phase 1 (2026-10-07): the on-device paths' own logic — the playlist curator (pool, prompt, budget
/// ladder, mapping back, retries, long-playlist plan), line-by-line lyric translation, Taizo's library lookup and its
/// asynchronous intro, the failure messages, Home's greeting prompts. None of it needs the system language model
/// (CI simulators have none): every model call is a stand-in.
@MainActor
final class OnDeviceAITests: XCTestCase {
    private func song(_ id: String, title: String, artist: String = "A", album: String = "B", genre: String? = nil,
                      favorite: Bool = false) -> Song {
        Song(id: id, title: title, artist: artist, artistId: 1, album: album, albumId: 1, path: "", contentUriString: "",
             albumArtUriString: nil, duration: 1000, genre: genre, isFavorite: favorite, mimeType: nil, bitrate: nil,
             sampleRate: nil)
    }

    /// Path-like ids, as a folder import makes them: none of them may reach the model.
    private func library(_ count: Int) -> [Song] {
        (1...count).map { index in
            song("f:root-\(index)/Music/Album \(index % 7)/Track \(index).flac", title: "Track \(index)",
                 artist: "Artist \(index % 5)", genre: index % 2 == 0 ? "Indie" : "Rock", favorite: index % 9 == 0)
        }
    }

    // MARK: Failures

    func testOnDeviceFailuresNeverReadAsNetworkOrKeyProblems() {
        for failure in OnDeviceFailure.fixed {
            let message = failure.message.lowercased()
            for word in OnDeviceFailure.reservedWords {
                XCTAssertFalse(message.contains(word), "\(failure) mentions \"\(word)\"")
            }
            XCTAssertFalse(failure.message.contains("Apple"))
            // PixlNet's generator classifies the text first: an on-device failure must not become "No Internet".
            let generator = AiPlaylistPrompt.detailedErrorMessage(message: "AI generation failed: ON_DEVICE: "
                + "On-device model API error: \(failure.message)")
            XCTAssertFalse(generator.contains("No Internet"), "\(failure) → \(generator)")
            if failure == .blocked {
                // PixlNet's own safety row answers first; it says the same thing.
                XCTAssertEqual(generator, "Content was blocked by safety filters. Try rephrasing your prompt.")
            } else {
                XCTAssertEqual(OnDeviceFailure.matching(generator), failure)
            }
            XCTAssertNotEqual(AILyricsTranslator.outcome(forFailure: failure.message), .notConfigured)
        }
        XCTAssertNil(OnDeviceFailure.matching("No Internet Connection"))
        // The old provider name is what made every failure read as offline.
        XCTAssertTrue(AiPlaylistPrompt.detailedErrorMessage(message: "On-Device (Offline) API error: x").contains("No Internet"))
        XCTAssertEqual(OnDeviceFailure.other("The context window was exceeded").message,
                       "The on-device model couldn't answer (The context window was exceeded). Try again.")
        XCTAssertEqual(OnDeviceFailure.other("network unreachable").message, "The on-device model couldn't answer. Try again.")
    }

    // MARK: Text helpers

    func testRepliesAreCleanedAndTokensEstimated() {
        XCTAssertEqual(OnDeviceText.cleanReply("<think>plan</think>\n Hello there "), "Hello there")
        XCTAssertEqual(OnDeviceText.cleanReply(#"{"response":"Hi!"}"#), "Hi!")
        XCTAssertEqual(OnDeviceText.cleanReply("```\nplain\n```"), "plain")
        XCTAssertEqual(OnDeviceText.singleLine("\"Indie warmth, coming up.\"\nextra", limit: 120), "Indie warmth, coming up.")
        XCTAssertNil(OnDeviceText.singleLine("  \n ", limit: 10))
        XCTAssertEqual(OnDeviceText.estimatedTokens("abcdefg"), 3) // 7 / 3.5 = 2, +10 % → 3
        XCTAssertEqual(OnDeviceText.estimatedTokens("你好世界"), 5) // one per ideograph, +10 %
        XCTAssertGreaterThan(OnDeviceText.estimatedTokens("Đường về nhà"), OnDeviceText.estimatedTokens("Duong ve nha"))
        XCTAssertEqual(OnDeviceText.responseBudget(contextSize: 4096, inputTokens: 1000, cap: 400), 400)
        XCTAssertEqual(OnDeviceText.responseBudget(contextSize: 4096, inputTokens: 4000, cap: 400), 64)
    }

    // MARK: Curator: prompt, pool, budget, mapping

    func testCuratorPromptNumbersSongsAndCarriesNoIds() {
        let pool = library(5)
        let taste = OnDeviceCuration.Taste(genres: ["Indie", "Rock"], artists: ["Artist 1"], phase: "Evening")
        let lines = OnDeviceCuration.lines(pool, playCounts: [pool[1].id: 5, pool[2].id: 1])
        let prompt = OnDeviceCuration.prompt(request: "rainy day", taste: taste, lines: lines, minimum: 2, maximum: 4)
        XCTAssertTrue(prompt.hasPrefix("Request: rainy day\nListener: plays mostly Indie, Rock; top artists Artist 1; "
                                       + "listens most in the evening.\nSongs:\n1. Track 1 — Artist 1 · Rock\n"))
        XCTAssertTrue(prompt.contains("\n2. Track 2 — Artist 2 · Indie · 5 plays\n3. Track 3 — Artist 3 · Rock · 1 play\n"))
        XCTAssertTrue(prompt.hasSuffix("Choose 2 to 4 songs for the request, in play order."))
        for song in pool { XCTAssertFalse(prompt.contains(song.id)) }
        XCTAssertFalse(prompt.contains("f:"))
        XCTAssertEqual(OnDeviceCuration.line(index: 9, song: song("x", title: "T", genre: nil, favorite: true), plays: 0),
                       "9. T — A · liked")
        XCTAssertNil(OnDeviceCuration.tasteLine(OnDeviceCuration.Taste()))
        XCTAssertEqual(OnDeviceCuration.phase(buckets: [(startMinute: 8 * 60, durationMs: 10), (startMinute: 20 * 60, durationMs: 30),
                                                        (startMinute: 21 * 60, durationMs: 5)]), "Evening")
    }

    func testPoolPutsTheRequestFirstThenTheDaysPicks() {
        let songs = [song("1", title: "Harbor", artist: "Luma Vale", genre: "Indie"),
                     song("2", title: "Static", artist: "Hollow Pines", genre: "Rock"),
                     song("3", title: "Glass", artist: "Luma Vale", genre: "Pop"),
                     song("4", title: "Night Swim", artist: "Other", genre: "Jazz")]
        let candidates = [songs[3], songs[1], songs[0]]
        let pool = OnDeviceCuration.pool(request: "some rock songs by luma vale", allSongs: songs, candidates: candidates,
                                         limit: 80)
        XCTAssertEqual(pool.map(\.id), ["2", "1", "3", "4"])
        XCTAssertEqual(OnDeviceCuration.coreRequest("Core request: sunset drive. Mood target: Chill."), "sunset drive")
        XCTAssertEqual(OnDeviceCuration.moodTarget("Core request: x. Mood target: Chill. Era focus: 80s."), "Chill")
        XCTAssertEqual(OnDeviceCuration.coreRequest("gym"), "gym")
        XCTAssertTrue(OnDeviceCuration.hasGenre(song("x", title: "t", genre: "Pop, Rock"), "rock"))
        XCTAssertFalse(OnDeviceCuration.hasGenre(song("x", title: "t", genre: "Rockabilly"), "rock"))
        // A request matching nothing still has the day's picks, and a tiny day still reaches the minimum pool.
        XCTAssertEqual(OnDeviceCuration.pool(request: "zzz", allSongs: songs, candidates: [], limit: 80).count, 4)
    }

    func testBudgetLadderShrinksThePoolUntilItFits() async {
        // 25 tokens per song line: 80 songs fit easily.
        let roomy = await OnDeviceCuration.fittingPoolSize(poolCount: 80, maximum: 30, contextSize: 4096,
                                                           instructionsTokens: 100) { $0 * 25 }
        XCTAssertEqual(roomy, 80)
        // 60 tokens per line: 80 → 60 (3,600 + 100 + 80 + 130 ≤ 4,096).
        let tight = await OnDeviceCuration.fittingPoolSize(poolCount: 80, maximum: 30, contextSize: 4096,
                                                           instructionsTokens: 100) { $0 * 60 }
        XCTAssertEqual(tight, 60)
        // Never below the minimum pool.
        let tiny = await OnDeviceCuration.fittingPoolSize(poolCount: 80, maximum: 30, contextSize: 500,
                                                          instructionsTokens: 100) { $0 * 60 }
        XCTAssertEqual(tiny, OnDeviceCuration.minPool)
        XCTAssertEqual(OnDeviceCuration.outputReserve(maximum: 40), 160)
    }

    func testPicksMapBackDedupedInRangeAndToppedUp() {
        let pool = library(6)
        let mapped = OnDeviceCuration.songs(fromPicks: [3, 3, 9, 0, 1], pool: pool, minimum: 4, maximum: 5)
        XCTAssertEqual(mapped.map(\.title), ["Track 3", "Track 1", "Track 2", "Track 4"])
        XCTAssertEqual(OnDeviceCuration.songs(fromPicks: [6, 5, 4, 3], pool: pool, minimum: 1, maximum: 2).map(\.title),
                       ["Track 6", "Track 5"])
        XCTAssertEqual(OnDeviceCuration.songs(fromPicks: [], pool: [], minimum: 3, maximum: 5), [])
        XCTAssertEqual(OnDeviceCuration.numbers(inJSON: #"{"picks":[4, 2, 7]}"#, key: "picks"), [4, 2, 7])
        XCTAssertEqual(OnDeviceCuration.numbers(inJSON: "not json 3, 12", key: "picks"), [3, 12])
        XCTAssertEqual(OnDeviceCuration.numbers(inText: "12, 4 and 7."), [12, 4, 7])
    }

    // MARK: Curator: end to end with a stand-in model

    private nonisolated final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private func model(calls: Calls, pick: @escaping @Sendable (String, Int, Int, Int) throws -> [Int],
                       plan: OnDeviceCuration.Plan = OnDeviceCuration.Plan(),
                       unavailability: OnDeviceFailure? = nil) -> OnDevicePlaylistCurator.Model {
        OnDevicePlaylistCurator.Model(
            unavailability: { unavailability },
            contextSize: { 4096 },
            tokens: { OnDeviceText.estimatedTokens($0) },
            temperature: { _ in 0.6 },
            pick: { prompt, size, low, high, _ in
                calls.add("pick \(size) \(low)-\(high)")
                return try pick(prompt, size, low, high)
            },
            pickAsText: { _ in
                calls.add("text")
                return "2, 1"
            },
            plan: { _, genres, _ in
                calls.add("plan \(genres.joined(separator: ","))")
                return plan
            })
    }

    private func request(_ songs: [Song], minimum: Int, maximum: Int) -> OnDevicePlaylistCurator.Request {
        OnDevicePlaylistCurator.Request(prompt: "rainy day", minimum: minimum, maximum: maximum, allSongs: songs,
                                        candidates: songs, playCounts: [:], taste: OnDeviceCuration.Taste())
    }

    func testCuratorPicksEveryOtherSongLikeTheScriptedProvider() async throws {
        let songs = library(20)
        let calls = Calls()
        let curator = OnDevicePlaylistCurator(model: model(calls: calls) { _, size, _, high in
            Array(stride(from: 1, through: size, by: 2).prefix(high))
        })
        let result = await curator.curate(request(songs, minimum: 3, maximum: 5))
        XCTAssertEqual(try result.get().map(\.title), ["Track 1", "Track 3", "Track 5", "Track 7", "Track 9"])
        XCTAssertEqual(calls.all, ["pick 20 3-5"])
    }

    func testCuratorRetriesShorterAndAsTextAndReportsUnavailability() async throws {
        let songs = library(40)
        let calls = Calls()
        let shorter = OnDevicePlaylistCurator(model: model(calls: calls) { _, size, _, _ in
            if size > 20 { throw OnDeviceFailure.tooLong }
            return [1, 2]
        })
        let shortened = try await shorter.curate(request(songs, minimum: 2, maximum: 4)).get()
        XCTAssertEqual(shortened.count, 2)
        XCTAssertEqual(calls.all, ["pick 40 2-4", "pick 20 2-4"])

        let blockedCalls = Calls()
        let blocked = OnDevicePlaylistCurator(model: model(calls: blockedCalls) { _, _, _, _ in throw OnDeviceFailure.blocked })
        let asText = try await blocked.curate(request(songs, minimum: 2, maximum: 4)).get()
        XCTAssertEqual(asText.map(\.title), ["Track 2", "Track 1"])
        XCTAssertEqual(blockedCalls.all, ["pick 40 2-4", "text"])

        let off = OnDevicePlaylistCurator(model: model(calls: Calls(), pick: { _, _, _, _ in [] }, unavailability: .intelligenceOff))
        guard case .failure(let failure) = await off.curate(request(songs, minimum: 2, maximum: 4)) else {
            return XCTFail("expected the unavailability message")
        }
        XCTAssertEqual(failure.message, OnDeviceFailure.intelligenceOff.message)
        XCTAssertEqual(OnDeviceFailure.matching(failure.message), .intelligenceOff)
    }

    func testLongPlaylistsArePlannedFilledAndTheirStartOrdered() async throws {
        let songs = library(120)
        let calls = Calls()
        let plan = OnDeviceCuration.Plan(genres: ["Indie"], artists: ["Artist 2"], moods: [], energy: 4, familiar: false)
        let curator = OnDevicePlaylistCurator(model: model(calls: calls, pick: { _, size, _, _ in
            Array((1...size).reversed()) // the model reverses the order
        }, plan: plan))
        let playlist = try await curator.curate(request(songs, minimum: 60, maximum: 80)).get()
        XCTAssertEqual(playlist.count, 80)
        XCTAssertEqual(Set(playlist.map(\.id)).count, 80)
        XCTAssertEqual(calls.all.first, "plan Indie,Rock")
        XCTAssertTrue(calls.all.contains("pick 40 40-40"))
        // The planned artist and genre lead the fill; the model then ordered the first 40.
        let head = Array(playlist.prefix(40))
        XCTAssertTrue(head.allSatisfy { $0.genre == "Indie" || $0.displayArtist == "Artist 2" })
        XCTAssertEqual(head.count { $0.displayArtist == "Artist 2" }, 16)
    }

    func testPlanParsingAndFill() {
        let plan = OnDeviceCuration.Plan(json: #"{"genres":["Rock"],"artists":["Artist 1"],"moods":["calm"],"energy":9,"familiar":false}"#)
        XCTAssertEqual(plan, OnDeviceCuration.Plan(genres: ["Rock"], artists: ["Artist 1"], moods: ["calm"], energy: 5, familiar: false))
        XCTAssertEqual(OnDeviceCuration.Plan(json: "nope"), OnDeviceCuration.Plan())
        let songs = library(30)
        let filled = OnDeviceCuration.fill(plan: plan, matched: [], allSongs: songs, ranked: songs, playCounts: [:], count: 10)
        XCTAssertEqual(filled.count, 10)
        XCTAssertTrue(filled.prefix(3).allSatisfy { $0.genre == "Rock" && $0.displayArtist == "Artist 1" })
        XCTAssertTrue(filled.prefix(6).allSatisfy { $0.displayArtist == "Artist 1" })
        let top = OnDeviceCuration.libraryTop(songs)
        XCTAssertEqual(Set(top.genres), ["Indie", "Rock"])
        XCTAssertEqual(top.artists.count, 5)
    }

    // MARK: Lyric translation

    private func translator(reply: @escaping @Sendable (String) -> String, language: String? = "es",
                            calls: Calls = Calls()) -> OnDeviceLyricsTranslator {
        OnDeviceLyricsTranslator(isActive: { true }, unavailability: { nil }, contextSize: { 4096 },
                                 respond: { _, prompt, _ in
                                     calls.add(prompt)
                                     return reply(prompt)
                                 },
                                 dominantLanguage: { _ in language }, targetLanguageCode: "en")
    }

    func testTranslationKeepsTimestampsAndTranslatesEachLineOnce() async {
        let calls = Calls()
        let lrc = "[00:01.00] Hola\n[00:05.00] Adiós\n[00:09.00] Hola"
        let translate = translator(reply: { _ in "1. Hello\n2. Goodbye" }, calls: calls)
        let outcome = await translate.translate(rawLyrics: lrc, current: nil, targetLanguage: "English")
        guard case .translated(let validated) = outcome else { return XCTFail("\(outcome)") }
        let synced = validated.parsedLyrics.synced ?? []
        XCTAssertEqual(synced.map(\.time), [1000, 5000, 9000])
        XCTAssertEqual(synced.map(\.translation), ["Hello", "Goodbye", "Hello"])
        XCTAssertEqual(calls.all, ["Translate into English:\n1. Hola\n2. Adiós"])
    }

    func testTranslationRecognisesTheTargetLanguageAndPlainLyrics() async {
        let english = translator(reply: { _ in "" }, language: "en")
        let same = await english.translate(rawLyrics: "[00:01.00] Hello", current: nil, targetLanguage: "English")
        XCTAssertEqual(same, .alreadyInTargetLanguage)
        let echo = translator(reply: { _ in "1. Hello" }, language: nil)
        let unchanged = await echo.translate(rawLyrics: "[00:01.00] Hello", current: nil, targetLanguage: "English")
        XCTAssertEqual(unchanged, .alreadyInTargetLanguage)
        let plain = await translator(reply: { _ in "1. x" }).translate(rawLyrics: "just words", current: nil,
                                                                       targetLanguage: "English")
        XCTAssertEqual(plain, .failed(detail: OnDeviceLyricsTranslation.needsTimestampsMessage))
        // Plain stored text, synced lyrics on screen: the screen's lines are translated.
        let shown = Lyrics(synced: [SyncedLine(time: 2000, line: "Hola")])
        let fromScreen = await translator(reply: { _ in "1. Hello" }).translate(rawLyrics: "Hola", current: shown,
                                                                                targetLanguage: "English")
        guard case .translated = fromScreen else { return XCTFail("\(fromScreen)") }
    }

    func testTranslationHelpers() {
        XCTAssertEqual(OnDeviceLyricsTranslation.parse("1. Hello\n2) \"Bye\"\nnoise\n3: Hi\n1. Again"),
                       [1: "Hello", 2: "Bye", 3: "Hi"])
        let chunks = OnDeviceLyricsTranslation.chunks(Array(repeating: "a line of lyrics here", count: 10), budget: 20)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.flatMap { $0 }.count, 10)
        XCTAssertEqual(OnDeviceLyricsTranslation.chunks(["one very long line"], budget: 1), [["one very long line"]])
        XCTAssertEqual(OnDeviceLyricsTranslation.baseCode("zh-Hans"), "zh")
        XCTAssertEqual(OnDeviceLyricsTranslation.chunkBudget(contextSize: 4096), 1581)
        XCTAssertEqual(OnDeviceLyricsTranslation.distinctTexts([SyncedLine(time: 0, line: "a\nb"), SyncedLine(time: 1, line: " "),
                                                                SyncedLine(time: 2, line: "a / b")]), ["a / b"])
        XCTAssertTrue(OnDeviceLyricsTranslation.isUnchanged(["Hola": "hola", "Sí": "Sí"]))
        XCTAssertFalse(OnDeviceLyricsTranslation.isUnchanged([:]))
    }

    // MARK: Taizo

    func testLibraryLookupAnswersFromTheLibrary() {
        let songs = [song("1", title: "Harbor", artist: "Luma Vale", album: "Tides", genre: "Indie"),
                     song("2", title: "Static", artist: "Hollow Pines", album: "Noise", genre: "Rock, Indie", favorite: true),
                     song("3", title: "Glass Harbor", artist: "Luma Vale", album: "Tides", genre: "Indie")]
        let artist = LibraryLookup.summary(query: "luma vale", songs: songs)
        XCTAssertTrue(artist.hasPrefix("Artist Luma Vale: 2 songs in the library; albums: Tides; e.g. \"Harbor\", \"Glass Harbor\"."))
        let genre = LibraryLookup.summary(query: "indie", songs: songs)
        XCTAssertTrue(genre.contains("Genre Indie: 3 songs; artists: Luma Vale, Hollow Pines."))
        let title = LibraryLookup.summary(query: "harbor", songs: songs)
        XCTAssertTrue(title.contains("Songs titled like that: \"Harbor\" by Luma Vale; \"Glass Harbor\" by Luma Vale."))
        XCTAssertTrue(LibraryLookup.summary(query: "radiohead songs", songs: songs)
            .hasPrefix("No artist, album, genre or song in the user's library matches \"radiohead songs\". The library has 3 songs"))
        XCTAssertEqual(LibraryLookup.overview(songs), "The library has 3 songs by 2 artists, 1 liked. Top genres: Indie (3), "
                       + "Rock (1). Top artists: Luma Vale (2), Hollow Pines (1).")
        XCTAssertEqual(LibraryLookup.summary(query: "x", songs: []), "The user's library is empty.")
        XCTAssertLessThanOrEqual(LibraryLookup.summary(query: "", songs: library(400)).count, LibraryLookup.maxCharacters)
    }

    func testTaizoPrompts() {
        XCTAssertFalse(TaizoPrompts.chatInstructions(persona: nil).contains("personality"))
        XCTAssertFalse(TaizoPrompts.chatInstructions(persona: AiPromptEngine.defaultSystemPrompt).contains("personality"))
        XCTAssertTrue(TaizoPrompts.chatInstructions(persona: "Speak like a pirate.").hasSuffix("\nYour personality: Speak like a pirate."))
        XCTAssertTrue(TaizoPrompts.chatInstructions(persona: nil).contains("searchLibrary"))
        XCTAssertLessThan(OnDeviceText.estimatedTokens(TaizoPrompts.chatInstructions(persona: nil)), 200)
        let carried = TaizoPrompts.carryOver("Base.", turns: [TaizoPrompts.Turn(user: "Who?", reply: "Them.")])
        XCTAssertEqual(carried, "Base.\n\nThe conversation so far:\nUser: Who?\nTaizo: Them.")
        XCTAssertEqual(TaizoPrompts.carryOver("Base.", turns: []), "Base.")
        XCTAssertEqual(TaizoPrompts.introPrompt(request: "play indie", count: 4), "Request: play indie\nSongs found: 4")
    }

    private nonisolated struct StubTaizo: TaizoOnDevice {
        var active = true
        func isActive() async -> Bool { active }
        func chat(_ message: String, songs: @escaping @MainActor @Sendable () -> [Song]) async throws -> String {
            let count = await songs().count
            return "On-device answer to \(message) (\(count) songs)"
        }
        func introLine(request: String, count: Int) async throws -> String? { "Here are \(count) songs." }
    }

    private nonisolated struct NoNetwork: HTTPClient {
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            throw HTTPTransportError(message: "no network in tests")
        }
    }

    private nonisolated struct UnusedSettings: AiSettingsProviding {
        func selectedProvider() async -> AiProvider { .onDevice }
        func apiKey(for provider: AiProvider) async -> String { "" }
        func model(for provider: AiProvider) async -> String { "" }
        func setModel(_ model: String, for provider: AiProvider) async {}
        func systemPrompt(for provider: AiProvider) async -> String { "" }
        func baseUrl(for provider: AiProvider) async -> String { "" }
        func generationParameters() async -> AiGenerationParameters { AiGenerationParameters() }
    }

    func testOnDeviceTaizoShowsTheCardFirstThenItsIntroAndRemembersNothingItShouldNot() async {
        let songs = [song("1", title: "Harbor", genre: "Indie"), song("2", title: "Static", genre: "Indie")]
        let orchestrator = AiOrchestrator(http: NoNetwork(), settings: UnusedSettings(), sha256: { @Sendable _ in [] })
        let engine = TaisDjEngine(router: TaisMediaRouter(songs: { songs }, remoteProviders: []), orchestrator: orchestrator,
                                  onDevice: StubTaizo())
        // The media reply comes back without waiting for the intro.
        guard case .media(_, .offline(let found), nil) = await engine.respond("Play some indie songs") else {
            return XCTFail("expected the card without an intro")
        }
        XCTAssertEqual(found.count, 2)
        let intro = await engine.deferredIntro(prompt: "Play some indie songs", result: .offline(found))
        XCTAssertEqual(intro, "Here are 2 songs.")
        let none = await engine.deferredIntro(prompt: "x", result: .noResults)
        XCTAssertNil(none)
        let answer = await engine.respond("Who produced Random Access Memories?")
        XCTAssertEqual(answer, .conversation("On-device answer to Who produced Random Access Memories? (2 songs)"))

        // The chat model fills the intro into the card it already shows.
        let model = TaisChatModel(engine: engine, playback: PlaybackStore(engine: DemoPlaybackEngine()))
        await model.runScript(["Play some indie songs"])
        guard case .djReply(_, _, _, let filled) = model.messages.last else { return XCTFail("\(model.messages)") }
        XCTAssertEqual(filled, "Here are 2 songs.")

        // A cloud selection keeps the orchestrator path (the stand-in isn't asked).
        let cloud = TaisDjEngine(router: TaisMediaRouter(songs: { songs }, remoteProviders: []), orchestrator: orchestrator,
                                 onDevice: StubTaizo(active: false))
        let cloudIntro = await cloud.deferredIntro(prompt: "x", result: .offline(found))
        XCTAssertNil(cloudIntro)
    }

    // MARK: Home greeting (Android HomeGreetingStateHolder)

    func testGreetingPromptsMatchAndroid() {
        let facts = HomeGreetingFacts(hour: 19, topArtist: "Luma Vale", topGenre: "Indie", totalPlays: 340, librarySize: 490)
        XCTAssertEqual(HomeLogic.greetingPrompt(facts), "time_of_day=evening, top_artist=Luma Vale, top_genre=Indie, total_plays=340")
        XCTAssertEqual(HomeLogic.insightPrompt(facts), "time_of_day=evening, top_artist=Luma Vale, top_genre=Indie, "
                       + "total_plays=340, library_size=490. Write 2-3 sentences of listening insight, more detailed than a "
                       + "one-line greeting.")
        XCTAssertEqual(HomeLogic.greetingPrompt(HomeGreetingFacts(hour: 2)), "time_of_day=night, total_plays=0")
        XCTAssertEqual(HomeLogic.cleanGreeting("  \"Evening — a Luma Vale kind of night.\" "), "Evening — a Luma Vale kind of night.")
        XCTAssertNil(HomeLogic.cleanGreeting(" \"\" "))
        XCTAssertEqual(HomeLogic.cleanGreeting(String(repeating: "a", count: 200))?.count, 140)
    }
}
