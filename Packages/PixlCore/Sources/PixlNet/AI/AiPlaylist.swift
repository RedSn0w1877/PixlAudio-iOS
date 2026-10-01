// Ports of `data/ai/AiPlaylistGenerator.kt` (candidate pool, prompt, id extraction, error messages) and
// `UserProfileDigestGenerator.kt` (the listening-profile digest). The library ranking (`DailyMixManager`) and the
// stats summary live in PixlLibrary; the app passes their results in as plain values.

import Foundation
import PixlFoundation
import PixlModel

// MARK: - Digest

/// The parts of `PlaybackStatsSummary` the digest reads.
public struct AiListeningSummary: Sendable, Hashable {
    public struct SongStat: Sendable, Hashable {
        public var songId: String
        public var title: String
        public var artist: String
        public var playCount: Int
        public var totalDurationMs: Int64

        public init(songId: String, title: String, artist: String, playCount: Int, totalDurationMs: Int64) {
            self.songId = songId
            self.title = title
            self.artist = artist
            self.playCount = playCount
            self.totalDurationMs = totalDurationMs
        }
    }

    /// One bucket of the day-listening distribution.
    public struct DayBucket: Sendable, Hashable {
        public var startMinute: Int
        public var totalDurationMs: Int64

        public init(startMinute: Int, totalDurationMs: Int64) {
            self.startMinute = startMinute
            self.totalDurationMs = totalDurationMs
        }
    }

    public var totalPlayCount: Int
    public var uniqueSongs: Int
    /// Top genres, most played first.
    public var topGenres: [String]
    /// Top artists, most played first.
    public var topArtists: [String]
    /// nil when there is no distribution (no PHASE line).
    public var dayBuckets: [DayBucket]?
    /// Played songs, most played first.
    public var songs: [SongStat]

    public init(totalPlayCount: Int, uniqueSongs: Int, topGenres: [String], topArtists: [String], dayBuckets: [DayBucket]?, songs: [SongStat]) {
        self.totalPlayCount = totalPlayCount
        self.uniqueSongs = uniqueSongs
        self.topGenres = topGenres
        self.topArtists = topArtists
        self.dayBuckets = dayBuckets
        self.songs = songs
    }
}

/// `UserProfileDigestGenerator`.
public enum AiProfileDigest {
    static let safeTargetCharLimit = 4000
    static let maxTargetCharLimit = 32000
    static let safeListenedLimit = 15
    static let safeDiscoveryLimit = 30
    static let fullListenedLimit = 60
    static let fullDiscoveryLimit = 120

    /// `generateDigest(allSongs, isSafeLimit)`. `digestMode` "full" overrides the safe limit; `shuffle` replaces
    /// Kotlin's unseeded `shuffled()` for the discovery pool.
    public static func generate(allSongs: [Song], summary: AiListeningSummary, playlistNames: [String],
                                isSafeLimit: Bool = true, digestMode: String = "safe", includeExtendedFields: Bool = false,
                                shuffle: ([Song]) -> [Song] = { $0.shuffled() }) -> String {
        let isSafe = digestMode == "full" ? false : isSafeLimit
        let targetLimit = isSafe ? safeTargetCharLimit : maxTargetCharLimit
        let listenedLimit = isSafe ? safeListenedLimit : fullListenedLimit
        let discoveryLimit = isSafe ? safeDiscoveryLimit : fullDiscoveryLimit

        var sb = ""
        sb += "USER_PROFILE\n"
        sb += "STATS: plays=\(summary.totalPlayCount), uniq=\(summary.uniqueSongs)\n"
        sb += "GENRES: \(summary.topGenres.prefix(3).joined(separator: ","))\n"
        sb += "ARTISTS: \(summary.topArtists.prefix(5).joined(separator: ","))\n"
        if let buckets = summary.dayBuckets {
            var order: [String] = []
            var sums: [String: Int64] = [:]
            for bucket in buckets {
                let hour = bucket.startMinute / 60
                let phase: String
                switch hour {
                case 5...10: phase = "Morning"
                case 11...16: phase = "Afternoon"
                case 17...22: phase = "Evening"
                default: phase = "Night"
                }
                if sums[phase] == nil { order.append(phase) }
                sums[phase, default: 0] += bucket.totalDurationMs
            }
            var best: String?
            for phase in order where best == nil || sums[phase]! > sums[best!]! { best = phase }
            sb += "PHASE: \(best ?? "Unknown")\n"
        }
        let variety = summary.totalPlayCount > 0 ? Double(summary.uniqueSongs) / Double(summary.totalPlayCount) : 0
        sb += "VAR: \(javaFormat2(variety))\n"
        let playlistLimit = isSafe ? 5 : 20
        if !playlistNames.isEmpty {
            sb += "PL: \(playlistNames.prefix(playlistLimit).joined(separator: ","))\n"
        }
        sb += "\nLISTENED: id|p|d|f|meta\n"

        var songMap: [String: Song] = [:]
        for song in allSongs { songMap[song.id] = song }
        for s in summary.songs.prefix(listenedLimit) {
            if NetText.length(sb) >= Int(Double(targetLimit) * 0.6) { continue }
            let song = songMap[s.songId]
            let fav = song?.isFavorite == true ? "1" : "0"
            let mins = s.totalDurationMs / 60000
            let title = NetText.take(s.title, 30)
            let artist = NetText.take(s.artist, 20)
            if includeExtendedFields {
                let album = song.map { NetText.take($0.album, 20) } ?? "?"
                let year = song.map { NetText.take(String($0.year), 4) } ?? "?"
                sb += "\(s.songId)|\(s.playCount)|\(mins)|\(fav)|\(title)-\(artist)|\(album)|\(year)\n"
            } else {
                sb += "\(s.songId)|\(s.playCount)|\(mins)|\(fav)|\(title)-\(artist)\n"
            }
        }

        let playedIds = Set(summary.songs.map(\.songId))
        let unplayed = Array(shuffle(allSongs.filter { !playedIds.contains($0.id) }).prefix(discoveryLimit))
        if !unplayed.isEmpty {
            sb += "\nDISCOVERY_POOL:\n"
            for s in unplayed {
                if NetText.length(sb) >= targetLimit { continue }
                let title = NetText.take(s.title, 30)
                let artist = NetText.take(s.displayArtist, 20)
                if includeExtendedFields {
                    let genre = s.genre.map { NetText.take($0, 15) } ?? "?"
                    sb += "\(s.id)|\(title)-\(artist)|\(genre)\n"
                } else {
                    sb += "\(s.id)|\(title)-\(artist)\n"
                }
            }
        }
        return sb
    }

    /// Java `"%.2f".format(x)` (Locale.US digits): HALF_UP rounding of the shortest decimal representation.
    static func javaFormat2(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
        let negative = x < 0 || (x == 0 && x.sign == .minus)
        let text = NetText.javaDoubleString(abs(x))
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(of: "E") {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        let pieces = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        var digits = Array(pieces[0] + (pieces.count > 1 ? pieces[1] : "")).map { Int($0.asciiValue! - 48) }
        var point = pieces[0].count + exponent
        // Normalise so that `digits` has at least point+3 entries and point ≥ 0.
        while point <= 0 { digits.insert(0, at: 0); point += 1 }
        while digits.count < point + 3 { digits.append(0) }
        var kept = Array(digits[0..<(point + 2)])
        if digits[point + 2] >= 5 {
            var i = kept.count - 1
            while i >= 0 {
                if kept[i] == 9 { kept[i] = 0; i -= 1 } else { kept[i] += 1; break }
            }
            if i < 0 { kept.insert(1, at: 0); point += 1 }
        }
        let intPart = kept[0..<point].map(String.init).joined()
        let fracPart = kept[point...].map(String.init).joined()
        let trimmedInt = String(intPart.drop { $0 == "0" })
        return (negative ? "-" : "") + (trimmedInt.isEmpty ? "0" : trimmedInt) + "." + fracPart
    }
}

// MARK: - Playlist generation

/// `AiPlaylistGenerator`.
public enum AiPlaylistPrompt {
    /// `aiSampleSize` default.
    public static let defaultSampleSize = 40

    /// The songs the model may choose from: `candidateSongs` when given, else the ranked top-100 (the app's
    /// `DailyMixManager.getTopCandidatesForAi`), else the whole library; then the first `sampleSize` (doubled when the
    /// safe token limit is off).
    public static func samplingPool(allSongs: [Song], candidateSongs: [Song]?, rankedCandidates: [Song]) -> [Song] {
        if let candidateSongs, !candidateSongs.isEmpty { return candidateSongs }
        return rankedCandidates.isEmpty ? allSongs : rankedCandidates
    }

    public static func sample(_ pool: [Song], sampleSize: Int = defaultSampleSize, safeTokenLimit: Bool = true) -> [Song] {
        Array(pool.prefix(max(0, safeTokenLimit ? sampleSize : sampleSize * 2)))
    }

    /// The candidate pool JSON (kotlinx `JsonArray.toString()`): id, t(80), a(60), g, s and, with extended fields,
    /// al(60), d, f, y.
    public static func candidatePoolJSON(_ songs: [Song], playCounts: [String: Int], includeExtendedFields: Bool) -> String {
        let items: [JSONValue] = songs.map { song in
            var o = JSONObject()
            o.append("id", .string(song.id))
            o.append("t", .string(NetText.take(song.title, 80)))
            o.append("a", .string(NetText.take(song.displayArtist, 60)))
            o.append("g", .string(song.genre ?? "unknown"))
            o.append("s", .integer(playCounts[song.id] ?? 0))
            if includeExtendedFields {
                o.append("al", .string(NetText.take(song.album, 60)))
                o.append("d", .integer(song.duration))
                o.append("f", .bool(song.isFavorite))
                o.append("y", .integer(song.year))
            }
            return .object(o)
        }
        return JSONWriter.write(.array(items))
    }

    /// The user prompt (digest, request, candidate pool) exactly as Android's raw string + `trimIndent()` builds it.
    public static func fullPrompt(userDigest: String, userPrompt: String, minLength: Int, maxLength: Int, candidatePoolJSON: String) -> String {
        let pad = String(repeating: " ", count: 12)
        let raw = "\n" + pad + userDigest + "\n"
            + pad + "<request>\n"
            + pad + "<query>" + userPrompt + "</query>\n"
            + pad + "<target_length>\(minLength)-\(maxLength) tracks</target_length>\n"
            + pad + "</request>\n"
            + pad + "<candidate_pool>\n"
            + pad + candidatePoolJSON + "\n"
            + pad + "</candidate_pool>\n"
            + pad
        return KotlinIndent.trimIndent(raw)
    }

    /// Failures of `generate` (their messages are Android's).
    public enum Failure: Error, Sendable, Hashable, CustomStringConvertible {
        case invalidFormat
        case malformedJSON(preview: String)
        case noMatchingSongs

        public var description: String {
            switch self {
            case .invalidFormat:
                return "AI returned an invalid response format. Expected a JSON array of song IDs but got something else. "
                    + "This usually happens with smaller models. Try selecting a more capable model in AI Settings."
            case .malformedJSON(let preview):
                return "AI returned malformed JSON. Expected a string array but got: \(preview)"
            case .noMatchingSongs:
                return "AI returned song IDs that don't match your library. Try again or adjust your prompt."
            }
        }
    }

    /// `extractPlaylistSongIds`.
    public static func extractSongIds(_ rawResponse: String) throws(Failure) -> [String] {
        let cleaned = AiResponseCleaner.cleanJsonResponse(rawResponse)
        guard let array = AiResponseCleaner.extractJsonArray(cleaned) else { throw .invalidFormat }
        guard let parsed = (try? JSONParser(mode: .kotlinx).parse(array))?.arrayValue else {
            throw .malformedJSON(preview: NetText.take(array, 100))
        }
        var ids: [String] = []
        for item in parsed {
            guard case .string(let s) = item else { throw .malformedJSON(preview: NetText.take(array, 100)) }
            ids.append(s)
        }
        return ids
    }

    /// The playlist from the model's ids: distinct ids that exist in the library or the pool, at most `maxLength`
    /// (at least 1). Throws when none match.
    public static func playlist(fromResponse rawResponse: String, allSongs: [Song], samplingPool: [Song], maxLength: Int) throws(Failure) -> [Song] {
        let ids = try extractSongIds(rawResponse)
        var songMap: [String: Song] = [:]
        for song in allSongs + samplingPool { songMap[song.id] = song }
        var seen = Set<String>()
        let songs = ids.filter { seen.insert($0).inserted }.compactMap { songMap[$0] }.prefix(max(maxLength, 1))
        if songs.isEmpty { throw .noMatchingSongs }
        return Array(songs)
    }

    /// `buildDetailedErrorMessage`: a friendly message from an error's message and its cause's.
    public static func detailedErrorMessage(message: String?, causeMessage: String? = nil, typeName: String = "Unknown") -> String {
        let root = message.flatMap { NetText.isBlank($0) ? nil : $0 }
        let cause = causeMessage.flatMap { NetText.isBlank($0) ? nil : $0 }
        let combined = [root, cause].compactMap { $0 }.joined(separator: " → ")
        func has(_ s: String) -> Bool { NetText.containsIgnoreCase(combined, s) }
        if has("timeout") || has("timed out") { return "Request timed out. The AI provider may be slow or overloaded. Try again." }
        if has("network") || has("connect") || has("SocketException") || has("no internet") || has("offline") || has("wifi") {
            return "No Internet Connection. Check your WiFi or mobile data and try again."
        }
        if has("airplane") { return "Airplane mode is active. Please turn it off to use AI." }
        if has("401") || has("unauthorized") { return "Permission Denied. Your API key might be invalid or restricted." }
        if has("403") || has("permission") || has("denied") || has("forbidden") {
            return "Permission denied by the AI provider. Check that this API key has access to the selected model and that the provider API is enabled."
        }
        if has("safety") || has("blocked") { return "Content was blocked by safety filters. Try rephrasing your prompt." }
        if has("model") && (has("not found") || has("unavailable")) {
            return "The selected AI model is unavailable. Try selecting a different model in AI Settings."
        }
        if let root { return "AI Error: \(root)" }
        if let cause { return "AI Error: \(cause)" }
        return "AI Error (\(typeName)): An unexpected error occurred. Try again."
    }
}

/// `AiPlaylistGenerator.generate`: builds the prompt, asks the orchestrator, maps the ids back to songs. Errors
/// arrive as friendly messages (`AiPlaylistPrompt.Failure` texts, else `detailedErrorMessage`).
public struct AiPlaylistGenerator: Sendable {
    public struct Settings: Sendable, Hashable {
        public var safeTokenLimit: Bool
        public var sampleSize: Int
        public var includeExtendedFields: Bool

        public init(safeTokenLimit: Bool = true, sampleSize: Int = AiPlaylistPrompt.defaultSampleSize, includeExtendedFields: Bool = false) {
            self.safeTokenLimit = safeTokenLimit
            self.sampleSize = sampleSize
            self.includeExtendedFields = includeExtendedFields
        }
    }

    public let orchestrator: AiOrchestrator

    public init(orchestrator: AiOrchestrator) {
        self.orchestrator = orchestrator
    }

    public func generate(userPrompt: String, allSongs: [Song], minLength: Int, maxLength: Int, candidateSongs: [Song]? = nil,
                         rankedCandidates: [Song] = [], playCounts: [String: Int] = [:], userDigest: String,
                         settings: Settings = Settings(), type: AiSystemPromptType = .playlist) async -> Result<[Song], AiPlaylistGenerationError> {
        let pool = AiPlaylistPrompt.samplingPool(allSongs: allSongs, candidateSongs: candidateSongs, rankedCandidates: rankedCandidates)
        let sample = AiPlaylistPrompt.sample(pool, sampleSize: settings.sampleSize, safeTokenLimit: settings.safeTokenLimit)
        let poolJSON = AiPlaylistPrompt.candidatePoolJSON(sample, playCounts: playCounts, includeExtendedFields: settings.includeExtendedFields)
        let prompt = AiPlaylistPrompt.fullPrompt(userDigest: userDigest, userPrompt: userPrompt, minLength: minLength,
                                                 maxLength: maxLength, candidatePoolJSON: poolJSON)
        do {
            let response = try await orchestrator.generateContent(prompt: prompt, type: type)
            return .success(try AiPlaylistPrompt.playlist(fromResponse: response, allSongs: allSongs, samplingPool: pool, maxLength: maxLength))
        } catch let failure as AiPlaylistPrompt.Failure {
            return .failure(AiPlaylistGenerationError(message: failure.description))
        } catch {
            let message: String
            if let generation = error as? AiGenerationError { message = generation.message } else { message = String(describing: error) }
            return .failure(AiPlaylistGenerationError(message: AiPlaylistPrompt.detailedErrorMessage(message: message, typeName: String(describing: Swift.type(of: error)))))
        }
    }
}

/// A playlist generation failure with its user-facing message.
public struct AiPlaylistGenerationError: Error, Sendable, Hashable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
