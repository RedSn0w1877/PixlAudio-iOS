import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlNet

/// Android `data/ai/provider/AiProviderSupportTest` (5 cases) plus the codecs, clients, orchestrator and prompt tools.
@Suite("AI providers")
struct AiProviderTests {
    @Test func providerChainKeepsSelectedProviderFirstAndIncludesAllProviders() {
        let chain = AiProviderSupport.buildProviderChain(.openai)
        #expect(chain.first == .openai)
        #expect(Set(chain) == Set(AiProvider.entries) && chain.count == AiProvider.entries.count)
    }

    @Test func selectRecoveryModelPrefersSupportedDefault() {
        #expect(AiProviderSupport.selectRecoveryModel(currentModel: "llama3-8b-8192", defaultModel: "llama-3.1-8b-instant",
                                                      availableModels: ["llama-3.1-8b-instant", "llama-3.3-70b-versatile"]) == "llama-3.1-8b-instant")
    }

    @Test func selectRecoveryModelFallsBackToFirstAvailableWhenDefaultIsAbsent() {
        #expect(AiProviderSupport.selectRecoveryModel(currentModel: "removed-model", defaultModel: "missing-default",
                                                      availableModels: ["gemini-2.5-flash-lite", "gemini-2.5-flash"]) == "gemini-2.5-flash-lite")
    }

    @Test func providerExceptionDetectsModelAndBillingIssues() {
        let notFound = AiProviderSupport.makeError(providerName: "Groq", statusCode: 404, transportMessage: "Not Found",
                                                   responseBody: #"{"error":{"message":"The model was not found","code":"model_not_found"}}"#,
                                                   requestedModel: "removed-model")
        let billing = AiProviderSupport.makeError(providerName: "Mistral", statusCode: 402, transportMessage: "Payment Required",
                                                  responseBody: #"{"error":{"message":"Insufficient credits"}}"#, requestedModel: "mistral-large-latest")
        #expect(notFound.isModelUnavailable())
        #expect(billing.isBillingIssue())
        #expect(notFound.message == "Groq API error (404) with model 'removed-model': The model was not found")
    }

    @Test func providerExceptionDistinguishesInvalidKeyFromProviderPermissionDenied() {
        let invalidKey = AiProviderSupport.makeError(providerName: "Gemini", statusCode: 400, transportMessage: "Bad Request",
                                                     responseBody: #"{"error":{"message":"API key not valid. Please pass a valid API key."}}"#,
                                                     requestedModel: "gemini-2.5-flash")
        let permissionDenied = AiProviderSupport.makeError(providerName: "Gemini", statusCode: 403, transportMessage: "Forbidden",
                                                           responseBody: #"{"error":{"message":"Generative Language API has not been used in this project."}}"#,
                                                           requestedModel: "gemini-2.5-flash")
        #expect(invalidKey.isApiKeyIssue())
        #expect(!permissionDenied.isApiKeyIssue())
    }

    @Test func providerTable() {
        #expect(AiProvider.entries.map(\.rawValue) == ["GEMINI", "DEEPSEEK", "GROQ", "MISTRAL", "NVIDIA", "KIMI", "GLM", "OPENAI", "OPENROUTER",
                                                       "OLLAMA", "CUSTOM", "ON_DEVICE"])
        #expect(AiProvider.fromString("NOPE") == .gemini && AiProvider.fromString("GROQ") == .groq)
        #expect(!AiProvider.ollama.requiresApiKey && AiProvider.ollama.hasConfigurableUrl && AiProvider.custom.hasConfigurableUrl)
        #expect(AiProvider.kimi.displayName == "Kimi (Moonshot)" && AiProvider.onDevice.displayName == "On-Device (Offline)")
        #expect(AiProvider.groq.openAICompatibleEndpoint == OpenAICompatibleEndpoint(baseUrl: "https://api.groq.com/openai/v1",
                                                                                      defaultModel: "llama-3.1-8b-instant", providerName: "Groq"))
        #expect(AiProvider.kimi.openAICompatibleEndpoint?.providerName == "Moonshot Kimi")
        #expect(AiProvider.gemini.openAICompatibleEndpoint == nil && AiProvider.ollama.openAICompatibleEndpoint == nil)
        #expect(AiProvider.ollama.configurableEndpoint(baseUrl: "http://192.168.1.2:11434/v1//")
                == OpenAICompatibleEndpoint(baseUrl: "http://192.168.1.2:11434/v1", defaultModel: "", providerName: "Ollama"))
    }

    @Test func modelFilters() {
        #expect(UnifiedModelFilter.isModelUsableForChat("gpt-4o"))
        #expect(!UnifiedModelFilter.isModelUsableForChat("text-embedding-3-small") && !UnifiedModelFilter.isModelUsableForChat("Whisper-1"))
        #expect(UnifiedModelFilter.filterChatModels(["a", "tts-1", "b"]) == ["a", "b"])
    }

    @Test func geminiCodecs() {
        let body = #"{"models":[{"name": "models/gemini-3.5-flash"},{"name":"models/embedding-001"},{"name":"models/gemma-4-31b-it"},{"name":"models/imagen-3"},{"name":"tunedModels/x"},{"name":"models/"}]}"#
        #expect(GeminiCodec.chatModels(fromModelsBody: body) == ["gemini-3.1-flash-lite", "gemini-3.1-pro-preview", "gemini-3.5-flash", "gemini-flash-latest", "gemma-4-31b-it"])
        #expect(GeminiCodec.parseGenerateResponse(#"{"candidates":[{"content":{"parts":[{"text":"Hel"},{"text":"lo"}],"role":"model"},"finishReason":"STOP"}]}"#) == .text("Hello"))
        #expect(GeminiCodec.parseGenerateResponse(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#) == .blocked(reason: "SAFETY"))
        #expect(GeminiCodec.parseGenerateResponse(#"{"candidates":[]}"#) == .empty)
        #expect(GeminiCodec.parseGenerateResponse(#"{"candidates":[{"finishReason":"SAFETY"}]}"#) == .empty)
        #expect(GeminiCodec.parseGenerateResponse(#"{"candidates":[{"content":{"parts":[{"text":"  "}]}}]}"#) == .empty)
        #expect(GeminiCodec.parseGenerateResponse(#"{"candidates":[{"content":{"parts":[{"inlineData":{}}]}}]}"#) == .malformed)
        #expect(GeminiCodec.parseGenerateResponse("nope") == .malformed)
        #expect(GeminiCodec.totalTokens(#"{"totalTokens" :  42, "x": 1}"#) == 42 && GeminiCodec.totalTokens("{}") == nil)
        #expect(GeminiCodec.estimatedTokens(systemPrompt: "1234567", prompt: "12345") == 2)
        let request = GeminiCodec.request(model: "gemini-x", apiKey: "K", body: "{}")
        #expect(request.url == "https://generativelanguage.googleapis.com/v1beta/models/gemini-x:generateContent" && request.header("x-goog-api-key") == "K")
        #expect(GeminiModel.displayName(for: "gemini-2.5-flash-lite") == "Gemini 2.5 Flash Lite")
        let models = GeminiModel.models(fromBody: #"{"models":[{"name":"models/gemini-zeta"},{"name":"models/gemini-3.5-flash"},{"name":"models/gemini-alpha-tts"},{"name":"models/gemma-b"}]}"#)
        #expect(models.map(\.name) == ["gemini-3.1-flash-lite", "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-flash-lite-latest", "gemini-flash-latest",
                                       "gemma-4-31b-it", "gemma-4-26b-a4b-it", "gemini-zeta", "gemma-b"])
        #expect(models.first { $0.name == "gemini-3.5-flash" }?.displayName == "Gemini 3.5 Flash")
        #expect(GeminiModel.listRequest(apiKey: "k").url == "https://generativelanguage.googleapis.com/v1beta/models?key=k")
        #expect(GeminiModel.estimateTokens("") == 1)
    }

    @Test func openAICodecs() {
        let endpoint = OpenAICompatibleEndpoint(baseUrl: "https://openrouter.ai/api/v1/", defaultModel: "d", providerName: "OpenRouter")
        let chat = OpenAICodec.chatRequest(endpoint: endpoint, apiKey: "K", body: "{}")
        #expect(chat.url == "https://openrouter.ai/api/v1/chat/completions")
        #expect(chat.headers.map(\.name) == ["Content-Type", "Authorization", "HTTP-Referer", "X-Title"])
        let ollama = OpenAICodec.modelsRequest(endpoint: OpenAICompatibleEndpoint(baseUrl: "http://h:11434/v1", defaultModel: "", providerName: "Ollama"), apiKey: "")
        #expect(ollama.url == "http://h:11434/v1/models" && ollama.headers.isEmpty)
        #expect(OpenAICodec.parseChatContent(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"Hi"}}]}"#) == "Hi")
        #expect(OpenAICodec.parseChatContent(#"{"choices":[]}"#) == nil)
        #expect(OpenAICodec.parseChatContent(#"{"choices":[{"message":{"role":"assistant","content":null}}]}"#) == nil)
        #expect(OpenAICodec.parseModels(#"{"object":"list","data":[{"id":"gpt-4o"},{"id":"whisper-1"}]}"#) == ["gpt-4o"])
        #expect(OpenAICodec.parseModels(#"{"data":[{"name":"x"}]}"#) == nil)
        #expect(OpenAICodec.estimatedTokens(systemPrompt: "12", prompt: "123456") == 2)
    }

    @Test func clientsSurfaceProviderErrors() async throws {
        let http = FixtureHTTPClient { request in
            if request.url.contains("generateContent") { return HTTPResponse(statusCode: 404, text: #"{"error":{"code":404,"message":"models/x is not found","status":"NOT_FOUND"}}"#) }
            if request.url.hasSuffix("/models") { return HTTPResponse(statusCode: 200, text: #"{"models":[{"name":"models/gemini-new"}]}"#) }
            if request.url.contains("countTokens") { return HTTPResponse(statusCode: 200, text: #"{"totalTokens":12}"#) }
            return HTTPResponse(statusCode: 500)
        }
        let gemini = GeminiAiClient(http: http, apiKey: "K")
        do {
            _ = try await gemini.generateContent(model: "x", systemPrompt: "s", prompt: "p", parameters: AiGenerationParameters())
            Issue.record("expected a failure")
        } catch let error as AiProviderError {
            #expect(error.message == "Gemini API error (404) with model 'x': models/x is not found" && error.isModelUnavailable())
        }
        #expect(await gemini.availableModels(apiKey: "K").contains("gemini-new"))
        #expect(await gemini.countTokens(model: "", systemPrompt: "s", prompt: "p") == 12)
        #expect(await gemini.validateApiKey("K"))

        let openai = OpenAICompatibleAiClient(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: #"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#) },
                                              apiKey: "", endpoint: AiProvider.ollama.configurableEndpoint(baseUrl: "http://h/v1"))
        #expect(try await openai.generateContent(model: "llama3", systemPrompt: "", prompt: "hi", parameters: AiGenerationParameters()) == "OK")
        let broken = OpenAICompatibleAiClient(http: FixtureHTTPClient { _ in throw HTTPTransportError(kind: "SocketTimeoutException", message: "timeout") },
                                              apiKey: "k", endpoint: AiProvider.groq.openAICompatibleEndpoint!)
        await #expect(throws: AiProviderError.self) {
            try await broken.generateContent(model: "", systemPrompt: "", prompt: "", parameters: AiGenerationParameters())
        }
        #expect(await broken.availableModels(apiKey: "k") == ["llama-3.1-8b-instant"])
        #expect(throws: AiProviderError.self) { try AiClientFactory.client(for: .groq, apiKey: " ", http: http) }
        #expect(throws: AiProviderError.self) { try AiClientFactory.client(for: .onDevice, apiKey: "", http: http) }
        #expect(try AiClientFactory.client(for: .ollama, apiKey: "", baseUrl: "http://h/", http: http).defaultModel == "")
        #expect(try AiClientFactory.client(for: .gemini, apiKey: "k", http: http).defaultModel == "gemini-3.1-flash-lite")
    }
}

@Suite("AI orchestration (AiHandler)")
struct AiOrchestratorTests {
    actor Settings: AiSettingsProviding {
        var provider: AiProvider = .groq
        var keys: [AiProvider: String] = [:]
        var models: [AiProvider: String] = [:]
        var params = AiGenerationParameters()
        var personas: [AiProvider: String] = [:]
        init(provider: AiProvider, keys: [AiProvider: String]) {
            self.provider = provider
            self.keys = keys
        }
        func selectedProvider() async -> AiProvider { provider }
        func apiKey(for provider: AiProvider) async -> String { keys[provider] ?? "" }
        func model(for provider: AiProvider) async -> String { models[provider] ?? "" }
        func setModel(_ model: String, for provider: AiProvider) async { models[provider] = model }
        func systemPrompt(for provider: AiProvider) async -> String { personas[provider] ?? "" }
        func baseUrl(for provider: AiProvider) async -> String { "http://localhost:11434/v1" }
        func generationParameters() async -> AiGenerationParameters { params }
        func setParams(_ p: AiGenerationParameters) { params = p }
    }

    actor Cache: AiResponseCaching {
        var entries: [String: (String, Int64)] = [:]
        func cachedResponse(hash: String) async -> (response: String, timestampMs: Int64)? { entries[hash].map { ($0.0, $0.1) } }
        func store(hash: String, response: String, timestampMs: Int64) async { entries[hash] = (response, timestampMs) }
        var count: Int { entries.count }
    }

    actor Usage: AiUsageRecording {
        var records: [AiUsageRecord] = []
        func record(_ usage: AiUsageRecord) async { records.append(usage) }
    }

    let sha: SHA256Function = { TestSHA256.hash($0) }

    @Test func cacheKeyIsSha256OfProviderSystemAndPrompt() {
        #expect(AiOrchestrator.cacheKey(provider: .gemini, systemPrompt: "sys", prompt: "prompt", sha256: sha)
                == "e2cfee75d8c3e52a10360b7b1651d3bc515c8d0ac278335cd9e52f29311e8902")
    }

    @Test func temperatureTable() {
        #expect(AiPromptEngine.effectiveTemperature(type: .metadata, setting: 0.7) == 0.1)
        #expect(AiPromptEngine.effectiveTemperature(type: .persona, setting: 0.7) == 0.85)
        #expect(AiPromptEngine.effectiveTemperature(type: .greeting, setting: 0.7) == 0.75)
        #expect(AiPromptEngine.effectiveTemperature(type: .playlist, requested: 0.3, setting: 0.7) == 0.3)
        #expect(AiPromptEngine.effectiveTemperature(type: .playlist, requested: 0.3, setting: 0.9) == 0.9)
    }

    @Test func fallsBackThroughTheChainAndCooldsDownFailingProviders() async throws {
        let settings = Settings(provider: .groq, keys: [.groq: "g", .openai: "o"])
        let http = FixtureHTTPClient { request in
            if request.url.hasPrefix("https://api.groq.com") { return HTTPResponse(statusCode: 503, text: #"{"error":{"message":"overloaded"}}"#) }
            if request.url.hasPrefix("http://localhost:11434") { return HTTPResponse(statusCode: 500, text: "") }
            return HTTPResponse(statusCode: 200, text: #"{"choices":[{"message":{"role":"assistant","content":"[\"a\"]"}}]}"#)
        }
        let cache = Cache(), usage = Usage()
        let clock = Box<Int64>(1_000_000)
        let orchestrator = AiOrchestrator(http: http, settings: settings, cache: cache, usage: usage, sha256: sha, nowMs: { clock.value })
        let reply = try await orchestrator.generateContent(prompt: "make a playlist", type: .playlist)
        #expect(reply == "[\"a\"]")
        let groqBody = try #require(http.requests.first { $0.url.hasPrefix("https://api.groq.com") }?.bodyText)
        #expect(groqBody.contains(#""model":"llama-3.1-8b-instant""#) && groqBody.contains(#""temperature":0.6000000238418579"#))
        let records = await usage.records
        #expect(records.count == 1 && records[0].provider == "OpenAI" && records[0].model == "gpt-4o-mini" && records[0].promptType == "PLAYLIST")
        #expect(records[0].thoughtTokens > 0)
        #expect(await cache.count == 1)

        // Cached for 30 minutes.
        let before = http.requests.count
        #expect(try await orchestrator.generateContent(prompt: "make a playlist", type: .playlist) == "[\"a\"]")
        #expect(http.requests.count == before)

        // Groq is on cooldown now; a new prompt skips it.
        clock.value += 60_000
        _ = try await orchestrator.generateContent(prompt: "another", type: .general)
        #expect(http.requests[before...].allSatisfy { !$0.url.hasPrefix("https://api.groq.com") })
    }

    @Test func noKeysAnywhereGivesTheSettingsHint() async {
        let orchestrator = AiOrchestrator(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 500) },
                                          settings: Settings(provider: .gemini, keys: [:]), sha256: sha)
        do {
            _ = try await orchestrator.generateContent(prompt: "x")
            Issue.record("expected failure")
        } catch let error as AiGenerationError {
            // Ollama needs no key and the on-device provider has no client, so not every failure is "no API key".
            #expect(error.message.hasPrefix("AI generation failed after trying 12 providers:\n• GEMINI: no API key configured"))
            #expect(error.failures.contains("ON_DEVICE: No on-device model available — check Settings > AI > On-Device"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(AiOrchestrator.failureMessage(["A: no API key configured", "B: no API key configured"])
                == "No API key configured. Go to Settings → AI Integration to set up your API key.")
        #expect(AiOrchestrator.failureMessage(["A: on cooldown (3s remaining)"]) == "All AI providers are on cooldown after recent errors. Wait a few minutes and try again.")
        #expect(AiOrchestrator.failureMessage(["A: boom"]) == "AI generation failed: A: boom")
    }

    @Test func recoversFromAVanishedModel() async throws {
        let settings = Settings(provider: .gemini, keys: [.gemini: "k"])
        let http = FixtureHTTPClient { request in
            if request.url.contains("models/old:generateContent") {
                return HTTPResponse(statusCode: 404, text: #"{"error":{"message":"model old not found"}}"#)
            }
            if request.url.hasSuffix("/v1beta/models") { return HTTPResponse(statusCode: 200, text: #"{"models":[{"name":"models/gemini-3.1-flash-lite"}]}"#) }
            return HTTPResponse(statusCode: 200, text: #"{"candidates":[{"content":{"parts":[{"text":"recovered"}]}}]}"#)
        }
        await settings.setModel("old", for: .gemini)
        let orchestrator = AiOrchestrator(http: http, settings: settings, sha256: sha)
        #expect(try await orchestrator.generateContent(prompt: "x", type: .metadata) == "recovered")
        #expect(await settings.model(for: .gemini) == "gemini-3.1-flash-lite")
        let body = try #require(http.requests.first?.bodyText)
        #expect(body.contains(#""temperature":0.10000000149011612"#) && body.contains("<persona>You are 'Vibe-Engine'"))
    }

    @Test func onDeviceClientIsUsedWhenSelected() async throws {
        struct Local: AiClient {
            var defaultModel: String { "local" }
            func generateContent(model: String, systemPrompt: String, prompt: String, parameters: AiGenerationParameters) async throws -> String { "on-device:\(model)" }
            func countTokens(model: String, systemPrompt: String, prompt: String) async -> Int { 0 }
            func availableModels(apiKey: String) async -> [String] { [] }
            func validateApiKey(_ apiKey: String) async -> Bool { true }
        }
        let orchestrator = AiOrchestrator(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 500) },
                                          settings: Settings(provider: .onDevice, keys: [:]), sha256: sha, onDeviceClient: Local())
        #expect(try await orchestrator.generateContent(prompt: "hi", type: .taizoChat) == "on-device:local")
    }
}

@Suite("AI playlist prompt and digest")
struct AiPlaylistTests {
    func song(_ id: String, title: String = "T", artist: String = "A", genre: String? = nil, fav: Bool = false, year: Int = 0) -> Song {
        Song(id: id, title: title, artist: artist, artistId: 1, album: "Album", albumId: 1, path: "", contentUriString: "", albumArtUriString: nil,
             duration: 1000, genre: genre, isFavorite: fav, year: year, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    @Test func candidatePoolJSONMatchesKotlinxShape() {
        let songs = [song("1", title: String(repeating: "x", count: 90), artist: "Quote \"A\"", genre: nil), song("2", genre: "Rock", fav: true, year: 1999)]
        #expect(AiPlaylistPrompt.candidatePoolJSON(songs, playCounts: ["2": 7], includeExtendedFields: false)
                == #"[{"id":"1","t":"\#(String(repeating: "x", count: 80))","a":"Quote \"A\"","g":"unknown","s":0},{"id":"2","t":"T","a":"A","g":"Rock","s":7}]"#)
        #expect(AiPlaylistPrompt.candidatePoolJSON([songs[1]], playCounts: [:], includeExtendedFields: true)
                == #"[{"id":"2","t":"T","a":"A","g":"Rock","s":0,"al":"Album","d":1000,"f":true,"y":1999}]"#)
    }

    @Test func fullPromptKeepsAndroidIndentation() {
        let single = AiPlaylistPrompt.fullPrompt(userDigest: "DIGEST", userPrompt: "chill", minLength: 10, maxLength: 20, candidatePoolJSON: "[]")
        #expect(single == "DIGEST\n<request>\n<query>chill</query>\n<target_length>10-20 tracks</target_length>\n</request>\n<candidate_pool>\n[]\n</candidate_pool>")
        // A multi-line digest has unindented lines, so Kotlin's trimIndent keeps the template's 12-space indentation.
        let multi = AiPlaylistPrompt.fullPrompt(userDigest: "USER_PROFILE\nSTATS: x\n", userPrompt: "q", minLength: 1, maxLength: 2, candidatePoolJSON: "[]")
        #expect(multi.hasPrefix("            USER_PROFILE\nSTATS: x\n\n            <request>"))
    }

    @Test func idExtractionAndMapping() throws {
        let all = [song("a1"), song("b2"), song("c3")]
        #expect(try AiPlaylistPrompt.extractSongIds("```json\n[\"a1\",\"zz\",\"a1\"]\n```") == ["a1", "zz", "a1"])
        #expect(try AiPlaylistPrompt.playlist(fromResponse: "Sure! [\"c3\",\"zz\",\"a1\",\"c3\"]", allSongs: all, samplingPool: [], maxLength: 1).map(\.id) == ["c3"])
        #expect(throws: AiPlaylistPrompt.Failure.invalidFormat) { try AiPlaylistPrompt.extractSongIds("no ids") }
        #expect(throws: AiPlaylistPrompt.Failure.malformedJSON(preview: "[1,2]")) { try AiPlaylistPrompt.extractSongIds("[1,2]") }
        #expect(throws: AiPlaylistPrompt.Failure.noMatchingSongs) { try AiPlaylistPrompt.playlist(fromResponse: "[\"q\"]", allSongs: all, samplingPool: [], maxLength: 5) }
        #expect(AiPlaylistPrompt.samplingPool(allSongs: all, candidateSongs: [], rankedCandidates: []) == all)
        #expect(AiPlaylistPrompt.samplingPool(allSongs: all, candidateSongs: nil, rankedCandidates: [all[2]]) == [all[2]])
        #expect(AiPlaylistPrompt.sample(all, sampleSize: 1, safeTokenLimit: false).count == 2)
    }

    @Test func friendlyErrorMessages() {
        #expect(AiPlaylistPrompt.detailedErrorMessage(message: "Read timed out") == "Request timed out. The AI provider may be slow or overloaded. Try again.")
        #expect(AiPlaylistPrompt.detailedErrorMessage(message: "x", causeMessage: "SocketException: reset")
                == "No Internet Connection. Check your WiFi or mobile data and try again.")
        #expect(AiPlaylistPrompt.detailedErrorMessage(message: "HTTP 401") == "Permission Denied. Your API key might be invalid or restricted.")
        #expect(AiPlaylistPrompt.detailedErrorMessage(message: "Forbidden").hasPrefix("Permission denied by the AI provider."))
        #expect(AiPlaylistPrompt.detailedErrorMessage(message: "blocked by SAFETY") == "Content was blocked by safety filters. Try rephrasing your prompt.")
        #expect(AiPlaylistPrompt.detailedErrorMessage(message: "Model unavailable").hasPrefix("The selected AI model is unavailable."))
        #expect(AiPlaylistPrompt.detailedErrorMessage(message: "weird") == "AI Error: weird")
        #expect(AiPlaylistPrompt.detailedErrorMessage(message: " ", causeMessage: nil, typeName: "Oops") == "AI Error (Oops): An unexpected error occurred. Try again.")
    }

    @Test func digestFollowsTheAndroidLayout() {
        let all = [song("1", title: "Song One", artist: "Artist", fav: true, year: 2001), song("2", title: "Unplayed", genre: "Jazz"), song("3", title: "Other")]
        let summary = AiListeningSummary(totalPlayCount: 8, uniqueSongs: 1, topGenres: ["Pop", "Rock", "Jazz", "Metal"],
                                         topArtists: ["A", "B"], dayBuckets: [.init(startMinute: 60, totalDurationMs: 10),
                                                                             .init(startMinute: 9 * 60, totalDurationMs: 50),
                                                                             .init(startMinute: 23 * 60, totalDurationMs: 45)],
                                         songs: [.init(songId: "1", title: "Song One", artist: "Artist", playCount: 8, totalDurationMs: 600_000)])
        let digest = AiProfileDigest.generate(allSongs: all, summary: summary, playlistNames: ["Mix"], includeExtendedFields: true, shuffle: { $0 })
        #expect(digest == """
        USER_PROFILE
        STATS: plays=8, uniq=1
        GENRES: Pop,Rock,Jazz
        ARTISTS: A,B
        PHASE: Night
        VAR: 0.13
        PL: Mix

        LISTENED: id|p|d|f|meta
        1|8|10|1|Song One-Artist|Album|2001

        DISCOVERY_POOL:
        2|Unplayed-A|Jazz
        3|Other-A|?

        """)
        let empty = AiProfileDigest.generate(allSongs: [], summary: AiListeningSummary(totalPlayCount: 0, uniqueSongs: 0, topGenres: [], topArtists: [],
                                                                                         dayBuckets: nil, songs: []), playlistNames: [])
        #expect(empty == "USER_PROFILE\nSTATS: plays=0, uniq=0\nGENRES: \nARTISTS: \nVAR: 0.00\n\nLISTENED: id|p|d|f|meta\n")
    }

    @Test func javaPercentTwoF() {
        #expect(AiProfileDigest.javaFormat2(0.125) == "0.13")
        #expect(AiProfileDigest.javaFormat2(1.005) == "1.01")
        #expect(AiProfileDigest.javaFormat2(0.004) == "0.00")
        #expect(AiProfileDigest.javaFormat2(0.005) == "0.01")
        #expect(AiProfileDigest.javaFormat2(2.0 / 3.0) == "0.67")
        #expect(AiProfileDigest.javaFormat2(0.0002) == "0.00")
        #expect(AiProfileDigest.javaFormat2(9.999) == "10.00")
        #expect(AiProfileDigest.javaFormat2(1) == "1.00")
        #expect(AiProfileDigest.javaFormat2(12_345_678.9) == "12345678.90")
    }

    @Test func generatorUsesTheOrchestrator() async throws {
        actor Settings: AiSettingsProviding {
            func selectedProvider() async -> AiProvider { .openai }
            func apiKey(for provider: AiProvider) async -> String { provider == .openai ? "k" : "" }
            func model(for provider: AiProvider) async -> String { "" }
            func setModel(_ model: String, for provider: AiProvider) async {}
            func systemPrompt(for provider: AiProvider) async -> String { "" }
            func baseUrl(for provider: AiProvider) async -> String { "" }
            func generationParameters() async -> AiGenerationParameters { AiGenerationParameters() }
        }
        let http = FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: #"{"choices":[{"message":{"role":"assistant","content":"[\"b2\",\"a1\"]"}}]}"#) }
        let generator = AiPlaylistGenerator(orchestrator: AiOrchestrator(http: http, settings: Settings(), sha256: { TestSHA256.hash($0) }))
        let all = [song("a1"), song("b2")]
        let result = await generator.generate(userPrompt: "x", allSongs: all, minLength: 1, maxLength: 5, userDigest: "D")
        #expect(try result.get().map(\.id) == ["b2", "a1"])
        let user = try #require(http.requests.first?.bodyText)
        #expect(user.contains(#"<candidate_pool>\n[{\"id\":\"a1\""#))
        let failing = AiPlaylistGenerator(orchestrator: AiOrchestrator(http: FixtureHTTPClient { _ in HTTPResponse(statusCode: 200, text: #"{"choices":[{"message":{"role":"assistant","content":"nothing"}}]}"#) },
                                                                       settings: Settings(), sha256: { TestSHA256.hash($0) }))
        let failure = await failing.generate(userPrompt: "x", allSongs: all, minLength: 1, maxLength: 5, userDigest: "D")
        #expect(failure == .failure(AiPlaylistGenerationError(message: AiPlaylistPrompt.Failure.invalidFormat.description)))
    }
}

/// Android `data/tais/dj/TaisIntentParserTest` (5 cases).
@Suite("TAIS DJ intent parser")
struct TaisIntentParserTests {
    @Test func questionsContainingMusicGenresAreConversational() {
        #expect(!TaisIntentParser.isMediaRequest("Why is jazz different from blues?"))
        #expect(!TaisIntentParser.isMediaRequest("Tell me about rock music"))
        #expect(!TaisIntentParser.isMediaRequest("What should I know about relaxing music?"))
    }

    @Test func politeQueueCommandKeepsItsAction() {
        let prompt = "Could you please queue some acoustic songs"
        #expect(TaisIntentParser.isMediaRequest(prompt))
        let intent = TaisIntentParser.parse(prompt)
        #expect(intent.action == .queue)
        #expect(intent.genres == ["acoustic"])
    }

    @Test func exactTitlesKeepMoodAndGenreWords() {
        #expect(TaisIntentParser.parse("play The Night We Met").searchQuery == "the night we met")
        #expect(TaisIntentParser.parse("play Love Story by Taylor Swift").searchQuery == "love story taylor swift")
        #expect(TaisIntentParser.parse("play House of Cards").searchQuery == "house of cards")
    }

    @Test func genreRequestAlsoKeepsNamedArtist() {
        let intent = TaisIntentParser.parse("find rock by Muse")
        #expect(intent.action == .find)
        #expect(intent.genres == ["rock"])
        #expect(intent.searchQuery == "muse")
    }

    @Test func playPrefixInsideADifferentWordIsNotACommand() {
        #expect(!TaisIntentParser.isMediaRequest("playlist history"))
    }

    @Test func moodsMapToQueryTerms() {
        let intent = TaisIntentParser.parse("play some relaxing chill jazz")
        #expect(intent.genres == ["jazz"] && intent.moods == ["chill"] && intent.queryTerms == ["jazz", "chill"] && intent.searchQuery.isEmpty)
        #expect(TaisIntentParser.parse("love").moods.isEmpty)
    }
}
