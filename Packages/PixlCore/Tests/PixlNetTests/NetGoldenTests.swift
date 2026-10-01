import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

/// Golden vectors from the compiled Android classes (`tools/android-reference/NetGen.java`,
/// fixture `net-android-golden.jsonl`).
@Suite("PixlNet golden vectors (Android JVM)")
struct NetGoldenTests {
    private func string(_ v: JSONValue?) -> String? { v?.stringValue }

    @Test func trackMatcherNormalizeMatchesAndroid() throws {
        let cases = try Fixtures.golden("normalize")
        #expect(cases.count > 50)
        for c in cases {
            #expect(TrackMatcher.normalize(c.input.stringValue!) == c.output.stringValue!, "normalize(\(c.input))")
        }
    }

    @Test func trackMatcherSimilarityMatchesAndroid() throws {
        for c in try Fixtures.golden("similarity") {
            let pair = c.input.arrayValue!
            let value = TrackMatcher.similarity(pair[0].stringValue!, pair[1].stringValue!)
            #expect(value.bitPattern == floatFromBits(c.output.stringValue!).bitPattern, "similarity(\(pair))")
        }
    }

    @Test func trackMatcherScoreMatchesAndroidBitForBit() throws {
        let cases = try Fixtures.golden("score")
        #expect(cases.count == 8 * 18)
        for c in cases {
            let o = c.input.objectValue!
            let song = MatchableTrack(title: o["title"]!.stringValue!, artist: o["artist"]!.stringValue!,
                                      album: o["album"]!.stringValue!, durationMs: o["durationMs"]!.int64Value!)
            let candidate = YouTubeSearchResult(videoId: "v", title: o["cTitle"]!.stringValue!, artist: o["cArtist"]!.stringValue!,
                                                album: o["cAlbum"]!.stringValue, durationSeconds: Int(o["cSeconds"]!.int64Value!),
                                                isMusicVideo: o["cVideo"]!.boolValue!)
            let score = TrackMatcher.score(song, candidate)
            #expect(score.bitPattern == floatFromBits(c.output.stringValue!).bitPattern, "score(\(o)) = \(score)")
        }
    }

    @Test func pickBestAudioMatchesAndroid() throws {
        func fmt(_ itag: Int, _ mime: String?, _ bitrate: Int, _ muxed: Bool) -> YouTubeAudioFormat {
            YouTubeAudioFormat(itag: itag, mimeType: mime, bitrate: bitrate, url: "u\(itag)", signatureCipher: nil,
                               contentLength: nil, approxDurationMs: nil, isMuxedFallback: muxed)
        }
        let sets: [[YouTubeAudioFormat]] = [
            [fmt(140, "audio/mp4; codecs=\"mp4a.40.2\"", 130000, false), fmt(251, "audio/webm; codecs=\"opus\"", 160000, false),
             fmt(141, "audio/mp4; codecs=\"mp4a.40.2\"", 256000, false)],
            [fmt(18, "video/mp4", 90000, true), fmt(251, "audio/webm; codecs=\"opus\"", 160000, false)],
            [fmt(18, "video/mp4", 500000, true)],
            [fmt(140, "audio/mp4", 128000, false), fmt(250, "audio/webm; codecs=\"opus\"", 128000, false)],
            [fmt(250, "audio/webm; codecs=\"OPUS\"", 128000, false), fmt(140, "audio/mp4", 128000, false)],
            [fmt(139, "audio/mp4", 48000, false), fmt(140, "audio/mp4", 128000, false), fmt(18, "video/mp4", 600000, true)],
            [fmt(140, nil, 128000, false), fmt(141, nil, 256000, false)],
            [],
        ]
        let cases = try Fixtures.golden("pickBestAudio")
        #expect(cases.count == sets.count * 6)
        for c in cases {
            let o = c.input.objectValue!
            let set = sets[Int(o["set"]!.int64Value!)]
            let cap = o["cap"]!.int64Value.map { Int($0) }
            let best = AudioFormatSelection.pickBestAudio(set, maxBitrateKbps: cap)
            #expect(best.map { Int64($0.itag) } == c.output.int64Value, "set \(o)")
        }
    }

    @Test func djIntentParserMatchesAndroid() throws {
        let cases = try Fixtures.golden("dj")
        #expect(cases.count > 50)
        for c in cases {
            let prompt = c.input.stringValue!
            let o = c.output.objectValue!
            let intent = TaisIntentParser.parse(prompt)
            #expect(intent.action.rawValue == o["action"]!.stringValue!, "\(prompt)")
            #expect(intent.genres == o["genres"]!.arrayValue!.map { $0.stringValue! }, "\(prompt)")
            #expect(intent.moods == o["moods"]!.arrayValue!.map { $0.stringValue! }, "\(prompt)")
            #expect(intent.searchQuery == o["query"]!.stringValue!, "\(prompt)")
            #expect(TaisIntentParser.isMediaRequest(prompt) == o["isMedia"]!.boolValue!, "\(prompt)")
        }
    }

    @Test func promptEngineMatchesAndroidByteForByte() throws {
        let cases = try Fixtures.golden("prompt")
        #expect(cases.count == AiSystemPromptType.allCases.count * 9)
        for c in cases {
            let o = c.input.objectValue!
            let type = try #require(AiSystemPromptType(rawValue: o["type"]!.stringValue!))
            let prompt = AiPromptEngine.buildPrompt(basePersona: o["persona"]!.stringValue!, type: type, context: o["context"]!.stringValue!)
            #expect(prompt == c.output.stringValue!, "\(o)")
        }
        let defaultPrompt = try #require(try Fixtures.golden("defaultSystemPrompt").first)
        #expect(AiPromptEngine.defaultSystemPrompt == defaultPrompt.output.stringValue!)
    }

    @Test func responseCleanerMatchesAndroid() throws {
        for c in try Fixtures.golden("cleaner") {
            let input = c.input.stringValue!
            let o = c.output.objectValue!
            #expect(AiResponseCleaner.cleanJsonResponse(input) == o["json"]!.stringValue!, "\(input)")
            #expect(AiResponseCleaner.cleanTextResponse(input) == o["text"]!.stringValue!, "\(input)")
            #expect(AiResponseCleaner.extractJsonArray(input) == o["array"]!.stringValue, "\(input)")
            #expect(AiResponseCleaner.extractJsonObject(input) == o["object"]!.stringValue, "\(input)")
        }
    }

    @Test func providerSupportMatchesAndroid() throws {
        for c in try Fixtures.golden("chain") {
            let chain = AiProviderSupport.buildProviderChain(AiProvider(rawValue: c.input.stringValue!)!)
            #expect(chain.map(\.rawValue) == c.output.arrayValue!.map { $0.stringValue! })
        }
        for c in try Fixtures.golden("recovery") {
            let o = c.input.objectValue!
            let model = AiProviderSupport.selectRecoveryModel(currentModel: o["current"]!.stringValue!, defaultModel: o["default"]!.stringValue!,
                                                              availableModels: o["available"]!.arrayValue!.map { $0.stringValue! })
            #expect(model == c.output.stringValue, "\(o)")
        }
        func check(_ error: AiProviderError, _ expected: JSONObject, _ label: String) {
            #expect(error.message == expected["message"]!.stringValue!, "\(label)")
            #expect(error.providerCode == expected["code"]!.stringValue, "\(label)")
            #expect(error.providerType == expected["type"]!.stringValue, "\(label)")
            #expect(error.statusCode.map(Int64.init) == expected["status"]!.int64Value, "\(label)")
            #expect(error.isModelUnavailable() == expected["modelUnavailable"]!.boolValue!, "\(label)")
            #expect(error.isBillingIssue() == expected["billing"]!.boolValue!, "\(label)")
            #expect(error.isApiKeyIssue() == expected["apiKey"]!.boolValue!, "\(label)")
            #expect(error.shouldCooldown() == expected["cooldown"]!.boolValue!, "\(label)")
        }
        for c in try Fixtures.golden("createException") {
            let o = c.input.objectValue!
            let error = AiProviderSupport.makeError(providerName: o["provider"]!.stringValue!, statusCode: o["status"]!.int64Value.map { Int($0) },
                                                    transportMessage: o["transport"]!.stringValue, responseBody: o["body"]!.stringValue,
                                                    requestedModel: o["model"]!.stringValue)
            check(error, c.output.objectValue!, "\(o)")
        }
        for c in try Fixtures.golden("wrapThrowable") {
            let message = c.input.stringValue!
            // A blank message falls back to the exception's simple class name ("IOException" = the transport kind).
            let error = AiProviderSupport.wrap(providerName: "Groq", error: HTTPTransportError(message: message), requestedModel: "model-x")
            check(error, c.output.objectValue!, message)
        }
        for c in try Fixtures.golden("modelFilter") {
            let o = c.input.objectValue!
            let result = UnifiedModelFilter.filterChatModelsWithDefaults(apiModels: o["api"]!.arrayValue!.map { $0.stringValue! },
                                                                         defaultModels: o["defaults"]!.arrayValue!.map { $0.stringValue! })
            #expect(result == c.output.arrayValue!.map { $0.stringValue! })
        }
    }

    @Test func aiRequestBodiesMatchKotlinx() throws {
        for c in try Fixtures.golden("geminiBody") {
            let o = c.input.objectValue!
            let p = AiGenerationParameters(temperature: Float(o["temperature"]!.doubleValue!), topP: Float(o["topP"]!.doubleValue!),
                                           topK: Int(o["topK"]!.int64Value!), maxTokens: Int(o["maxTokens"]!.int64Value!),
                                           presencePenalty: Float(o["presence"]!.doubleValue!), frequencyPenalty: Float(o["frequency"]!.doubleValue!))
            let body = GeminiCodec.generateBody(systemPrompt: o["system"]!.stringValue!, prompt: o["prompt"]!.stringValue!, parameters: p)
            #expect(body == c.output.stringValue!, "\(o)")
        }
        for c in try Fixtures.golden("openAIBody") {
            let o = c.input.objectValue!
            let p = AiGenerationParameters(temperature: Float(o["temperature"]!.doubleValue!), topP: Float(o["topP"]!.doubleValue!),
                                           topK: Int(o["topK"]!.int64Value!), maxTokens: Int(o["maxTokens"]!.int64Value!),
                                           presencePenalty: Float(o["presence"]!.doubleValue!), frequencyPenalty: Float(o["frequency"]!.doubleValue!))
            let body = OpenAICodec.chatBody(model: "model-x", systemPrompt: o["system"]!.stringValue!, prompt: o["prompt"]!.stringValue!, parameters: p)
            #expect(body == c.output.stringValue!, "\(o)")
        }
        let count = try #require(try Fixtures.golden("geminiCountBody").first)
        #expect(GeminiCodec.countTokensBody(systemPrompt: "s", prompt: "p") == count.output.stringValue!)
    }

    @Test func unifiedIdsMatchAndroid() throws {
        let cases = try Fixtures.golden("unifiedId")
        #expect(cases.count == 27)
        for c in cases {
            let o = c.input.objectValue!
            #expect(SpotifyLibrary.unifiedId(offset: o["offset"]!.int64Value!, key: o["key"]!.stringValue!) == c.output.int64Value!)
        }
    }

    @Test func cipherExtractionMatchesAndroid() throws {
        for c in try Fixtures.golden("cipher") {
            let js = c.input.stringValue!
            let o = c.output.objectValue!
            #expect(SignatureCipher.signatureFunction(baseJs: js) == o["sig"]!.stringValue, "\(js)")
            #expect(SignatureCipher.nFunction(baseJs: js) == o["n"]!.stringValue, "\(js)")
        }
        for c in try Fixtures.golden("playerId") {
            #expect(SignatureCipher.playerId(iframeApi: c.input.stringValue!) == c.output.stringValue, "\(c.input)")
        }
    }
}
