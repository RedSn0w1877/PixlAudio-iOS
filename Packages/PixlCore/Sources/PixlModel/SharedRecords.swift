// Small records shared by several PixlCore modules. They live here so the app, which imports every module, sees
// one type per Android entity instead of two same-named ones (an unqualified use would be ambiguous).

import Foundation

/// Track and album gain read from one file's tags (Android `ReplayGainManager.ReplayGainValues`). Produced by
/// PixlTags (`ReplayGainTags`) and consumed by PixlAudioCore (`ReplayGain`, `ReplayGainVolumeController`).
public struct ReplayGainValues: Sendable, Hashable, Codable {
    public var trackGainDb: Float?
    public var albumGainDb: Float?

    public init(trackGainDb: Float? = nil, albumGainDb: Float? = nil) {
        self.trackGainDb = trackGainDb
        self.albumGainDb = albumGainDb
    }
}

/// One AI request (Android `AiUsageEntity`). Recorded by PixlNet (`AiOrchestrator` → `AiUsageRecording`) and
/// backed up / restored by PixlBackup (`AiUsageModule`). `id` is the Room row id (0 = not stored yet).
public struct AiUsageRecord: Sendable, Hashable, Codable {
    public var id: Int64
    public var timestamp: Int64
    public var provider: String
    public var model: String
    public var promptType: String
    public var promptTokens: Int
    public var outputTokens: Int
    public var thoughtTokens: Int

    public init(id: Int64 = 0, timestamp: Int64, provider: String, model: String, promptType: String, promptTokens: Int,
                outputTokens: Int, thoughtTokens: Int) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.promptType = promptType
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
    }
}
