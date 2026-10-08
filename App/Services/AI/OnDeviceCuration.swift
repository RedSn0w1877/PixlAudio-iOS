import Foundation
import PixlLibrary
import PixlModel
import PixlNet

/// The on-device playlist curator (2026-10-07; plan local-ai option A): the AI playlist sheet, the AI Playlist Lab
/// and Daily Mix refinement, when the on-device model is the selected provider.
///
/// PixlNet's cloud prompt (the listening digest, a JSON pool of 40-80 songs and their path ids) doesn't fit the
/// on-device model's 4,096-token window, and a 3B model can't copy 40-70-character ids reliably. So:
/// 1. **Request-aware pool:** songs the request names (genre words, artists it mentions, a title or text search)
///    first, then the day's personalised picks — at most 80.
/// 2. **Compact prompt:** a two-line taste summary and one numbered line per song (`12. Title — Artist · genre ·
///    liked · 5 plays`). The numbers are aliases: no id ever reaches the model.
/// 3. **Guided output:** a dynamic schema only allows `min…max` numbers in `1…pool size` (`OnDeviceAI.pickNumbers`).
/// 4. **Budget ladder:** the pool shrinks by a quarter until instructions, prompt, schema and answer fit the window;
///    a "too long" answer retries once with half the pool; a guardrail stop retries once as plain text.
/// 5. **Map back:** numbers → songs, duplicates and out-of-range numbers dropped, topped up from the pool.
/// 6. **Long playlists** (the Lab allows 150): the model plans — genres and artists from the library's own top values,
///    moods, energy, familiar or not — the app fills the playlist from the library, and the model orders the first 40.
nonisolated struct OnDevicePlaylistCurator: Sendable {
    /// The model calls, injectable for tests (`live` runs them on `OnDeviceAI`).
    nonisolated struct Model: Sendable {
        var unavailability: @Sendable () -> OnDeviceFailure?
        var contextSize: @Sendable () -> Int
        var tokens: @Sendable (String) async -> Int
        var temperature: @Sendable (AiSystemPromptType) async -> Double?
        /// Numbers from a numbered list: prompt, pool size, minimum, maximum, temperature.
        var pick: @Sendable (String, Int, Int, Int, Double?) async throws -> [Int]
        /// The same as plain text (the guardrail fallback).
        var pickAsText: @Sendable (String) async throws -> String
        /// A long playlist's plan: prompt, allowed genres, allowed artists.
        var plan: @Sendable (String, [String], [String]) async throws -> OnDeviceCuration.Plan
    }

    nonisolated struct Request: Sendable {
        var prompt: String
        var minimum: Int
        var maximum: Int
        var allSongs: [Song]
        /// The day's personalised picks (`DailyMix.personalizedPicks`), else the AI ranking.
        var candidates: [Song]
        var playCounts: [String: Int]
        var taste: OnDeviceCuration.Taste
        var type: AiSystemPromptType = .playlist
    }

    let model: Model

    /// Curates `request` off the main actor. Failures carry `OnDeviceFailure` messages.
    @concurrent
    func curate(_ request: Request) async -> Result<[Song], AiPlaylistGenerationError> {
        if let issue = model.unavailability() { return .failure(AiPlaylistGenerationError(message: issue.message)) }
        let maximum = max(1, request.maximum)
        let minimum = min(max(1, request.minimum), maximum)
        let pool = OnDeviceCuration.pool(request: request.prompt, allSongs: request.allSongs,
                                         candidates: request.candidates, limit: OnDeviceCuration.maxPool)
        guard !pool.isEmpty else { return .success([]) }
        let temperature = await model.temperature(request.type)
        do {
            if maximum > OnDeviceCuration.directLimit {
                return .success(try await curateLong(request, pool: pool, minimum: minimum, maximum: maximum,
                                                     temperature: temperature))
            }
            return .success(try await pick(from: pool, request: request, minimum: minimum, maximum: maximum,
                                           temperature: temperature))
        } catch is CancellationError {
            return .success([])
        } catch {
            let failure = (error as? OnDeviceFailure) ?? .other(error.localizedDescription)
            return .failure(AiPlaylistGenerationError(message: failure.message))
        }
    }

    /// Steps 2-5: the largest pool that fits, the model's numbers, mapped back.
    func pick(from base: [Song], request: Request, minimum: Int, maximum: Int, temperature: Double?,
              instruction: String? = nil) async throws -> [Song] {
        let instructionsTokens = await model.tokens(OnDeviceCuration.instructions)
        let model = self.model
        var size = await OnDeviceCuration.fittingPoolSize(
            poolCount: base.count, maximum: maximum, contextSize: model.contextSize(),
            instructionsTokens: instructionsTokens) { size in
                await model.tokens(OnDeviceCuration.prompt(request: request.prompt, taste: request.taste,
                                                           lines: OnDeviceCuration.lines(Array(base.prefix(size)), playCounts: request.playCounts),
                                                           minimum: minimum, maximum: maximum, instruction: instruction))
            }
        var retriedShorter = false
        while true {
            let pool = Array(base.prefix(size))
            let low = min(minimum, pool.count)
            let high = min(maximum, pool.count)
            let prompt = OnDeviceCuration.prompt(request: request.prompt, taste: request.taste,
                                                 lines: OnDeviceCuration.lines(pool, playCounts: request.playCounts),
                                                 minimum: low, maximum: high, instruction: instruction)
            do {
                let picks = try await model.pick(prompt, pool.count, low, high, temperature)
                return OnDeviceCuration.songs(fromPicks: picks, pool: pool, minimum: minimum, maximum: maximum)
            } catch let failure as OnDeviceFailure where failure == .tooLong && !retriedShorter && size > OnDeviceCuration.minPool {
                retriedShorter = true
                size = max(OnDeviceCuration.minPool, size / 2)
            } catch let failure as OnDeviceFailure where failure == .blocked {
                let text = try await model.pickAsText(prompt + "\n" + OnDeviceCuration.textAnswerLine)
                let picks = OnDeviceCuration.numbers(inText: text)
                return OnDeviceCuration.songs(fromPicks: picks, pool: pool, minimum: minimum, maximum: maximum)
            }
        }
    }

    /// Step 6: plan, fill from the library, order the first 40.
    private func curateLong(_ request: Request, pool: [Song], minimum: Int, maximum: Int,
                            temperature: Double?) async throws -> [Song] {
        let top = OnDeviceCuration.libraryTop(request.allSongs)
        let plan: OnDeviceCuration.Plan
        do {
            plan = try await model.plan(OnDeviceCuration.planPrompt(request: request.prompt, taste: request.taste),
                                        top.genres, top.artists)
        } catch let failure as OnDeviceFailure where failure.stopsCuration {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A plan the model wouldn't give: the request-aware pool and the day's picks alone.
            plan = OnDeviceCuration.Plan()
        }
        let filled = OnDeviceCuration.fill(plan: plan, matched: pool, allSongs: request.allSongs,
                                           ranked: request.candidates, playCounts: request.playCounts, count: maximum)
        guard filled.count > 1 else { return filled }
        let head = Array(filled.prefix(OnDeviceCuration.directLimit))
        let ordered = (try? await pick(from: head, request: request, minimum: head.count, maximum: head.count,
                                       temperature: temperature, instruction: OnDeviceCuration.orderInstruction)) ?? head
        // `pick` may have trimmed the head to fit: whatever it left out keeps its place after the ordered songs.
        let orderedIds = Set(ordered.map(\.id))
        return ordered + filled.filter { !orderedIds.contains($0.id) }
    }
}

extension OnDeviceFailure {
    /// The model can't answer at all: no point falling back to a plan-less fill that also needs it.
    nonisolated var stopsCuration: Bool {
        switch self {
        case .deviceNotEligible, .intelligenceOff, .notReady, .language, .localModelMissing: true
        default: false
        }
    }
}

/// The curator's pure parts: prompts, the pool, the budget ladder, parsing and mapping back, the plan and its fill.
nonisolated enum OnDeviceCuration {
    /// The pick session's instructions (static, so the session can be prewarmed while the sheet opens).
    static let instructions = """
        You are a music curator. Choose songs from the numbered list that fit the listener's request, in a good \
        play order: open gently, build up, finish strong, and avoid the same artist twice in a row. Answer only with \
        song numbers from the list. Do not call tools.
        """

    static let planInstructions = """
        You plan playlists from a listener's request. From the allowed values, pick the genres and artists that fit \
        the request best (none when nothing fits), up to three mood words, an energy level from 1 (calm) to 5 \
        (intense), and whether the listener's familiar favorites suit it. Do not call tools.
        """

    /// The last line of the ordering request (long playlists).
    static let orderInstruction = "Put every song of the list in a good play order. Use each number once."
    /// The guardrail fallback's answer format.
    static let textAnswerLine = "Answer with the song numbers only, separated by commas."

    /// Playlists up to this long are picked directly; longer ones are planned.
    static let directLimit = 40
    static let maxPool = 80
    static let minPool = 12
    /// The schema's share of the window (the framework sends it with the prompt).
    static let schemaReserve = 80

    /// Tokens kept for the answer: about three per number in `{"picks":[…]}`.
    static func outputReserve(maximum: Int) -> Int { maximum * 3 + 40 }

    // MARK: Taste

    /// What the listener plays most (no ids): from the all-time listening summary.
    nonisolated struct Taste: Sendable, Equatable {
        var genres: [String] = []
        var artists: [String] = []
        /// Morning, Afternoon, Evening or Night (the digest's PHASE).
        var phase: String?
    }

    /// The digest's PHASE: the part of the day with the most listening (Android `UserProfileDigestGenerator`).
    static func phase(buckets: [(startMinute: Int, durationMs: Int64)]) -> String? {
        var order: [String] = []
        var sums: [String: Int64] = [:]
        for bucket in buckets {
            let name: String
            switch bucket.startMinute / 60 {
            case 5...10: name = "Morning"
            case 11...16: name = "Afternoon"
            case 17...22: name = "Evening"
            default: name = "Night"
            }
            if sums[name] == nil { order.append(name) }
            sums[name, default: 0] += bucket.durationMs
        }
        var best: String?
        for name in order where best == nil || sums[name, default: 0] > sums[best ?? "", default: 0] { best = name }
        return best
    }

    static func tasteLine(_ taste: Taste) -> String? {
        var parts: [String] = []
        if !taste.genres.isEmpty { parts.append("plays mostly \(taste.genres.prefix(3).joined(separator: ", "))") }
        if !taste.artists.isEmpty { parts.append("top artists \(taste.artists.prefix(3).joined(separator: ", "))") }
        if let phase = taste.phase { parts.append("listens most in the \(phase.lowercased())") }
        return parts.isEmpty ? nil : "Listener: " + parts.joined(separator: "; ") + "."
    }

    // MARK: Prompt

    /// `12. Title — Artist · genre · liked · 5 plays` (title ≤ 40, artist ≤ 24, genre ≤ 18 characters).
    static func line(index: Int, song: Song, plays: Int) -> String {
        var text = "\(index). \(String(song.title.prefix(40))) — \(String(song.displayArtist.prefix(24)))"
        if let genre = song.genre?.trimmingCharacters(in: .whitespaces), !genre.isEmpty {
            text += " · \(String(genre.prefix(18)))"
        }
        if song.isFavorite { text += " · liked" }
        if plays > 0 { text += plays == 1 ? " · 1 play" : " · \(plays) plays" }
        return text
    }

    static func lines(_ pool: [Song], playCounts: [String: Int]) -> [String] {
        pool.enumerated().map { line(index: $0.offset + 1, song: $0.element, plays: playCounts[$0.element.id] ?? 0) }
    }

    static func prompt(request: String, taste: Taste, lines: [String], minimum: Int, maximum: Int,
                       instruction: String? = nil) -> String {
        var text = "Request: \(String(request.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))\n"
        if let taste = tasteLine(taste) { text += taste + "\n" }
        text += "Songs:\n" + lines.joined(separator: "\n") + "\n"
        if let instruction {
            text += instruction
        } else {
            text += minimum == maximum ? "Choose \(maximum) songs for the request, in play order."
                : "Choose \(minimum) to \(maximum) songs for the request, in play order."
        }
        return text
    }

    // MARK: Pool

    /// The Lab's "Core request: …." (the free text), else the whole prompt.
    static func coreRequest(_ prompt: String) -> String {
        guard let range = prompt.range(of: #"(?i)core request:\s*[^.]*"#, options: .regularExpression) else { return prompt }
        let core = prompt[range].replacingOccurrences(of: #"(?i)^core request:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return core.isEmpty ? prompt : core
    }

    /// The Lab's "Mood target: …." when set.
    static func moodTarget(_ prompt: String) -> String? {
        guard let range = prompt.range(of: #"(?i)mood target:\s*[^.]*"#, options: .regularExpression) else { return nil }
        let mood = prompt[range].replacingOccurrences(of: #"(?i)^mood target:\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return mood.isEmpty ? nil : mood
    }

    /// Songs the request names — genre words (Taizo's parser), artists it mentions, a title or text search — then
    /// the candidates, without duplicates, at most `limit`. The request's own matches take at most two thirds.
    static func pool(request: String, allSongs: [Song], candidates: [Song], limit: Int) -> [Song] {
        let core = coreRequest(request)
        let text = [core, moodTarget(request)].compactMap { $0 }.joined(separator: " ")
        let intent = TaisIntentParser.parse(text)
        var matched: [Song] = []
        for genre in intent.genres { matched += allSongs.filter { hasGenre($0, genre) } }
        matched += songsByMentionedArtists(core, allSongs: allSongs)
        let query = intent.searchQuery.trimmingCharacters(in: .whitespaces)
        if query.count >= 3 { matched += SearchIndex(songs: allSongs).searchSongs(query, limit: limit) }
        var seen = Set<String>()
        var result: [Song] = []
        for song in matched where seen.insert(song.id).inserted {
            result.append(song)
            if result.count >= limit * 2 / 3 { break }
        }
        for song in candidates where result.count < limit && seen.insert(song.id).inserted { result.append(song) }
        if result.count < min(limit, minPool) {
            for song in allSongs where result.count < min(limit, minPool) && seen.insert(song.id).inserted { result.append(song) }
        }
        return result
    }

    /// The genre tag equals `genre` or lists it (comma-separated), case-insensitively.
    static func hasGenre(_ song: Song, _ genre: String) -> Bool {
        let target = LibraryLookup.normalized(genre)
        return (song.genre ?? "").split(separator: ",").contains { LibraryLookup.normalized(String($0)) == target }
    }

    /// Songs by library artists (3+ letters) whose name appears in the request.
    static func songsByMentionedArtists(_ request: String, allSongs: [Song]) -> [Song] {
        let text = " " + LibraryLookup.normalized(request) + " "
        let mentioned = LibraryLookup.groups(allSongs, key: { $0.displayArtist }).filter { group in
            let name = LibraryLookup.normalized(group.name)
            return name.count >= 3 && text.contains(name)
        }
        return mentioned.prefix(4).flatMap(\.songs)
    }

    // MARK: Budget

    /// The largest pool (shrinking by a quarter, never under `minPool`) whose prompt fits the window with the
    /// instructions, the schema and the answer's reserve.
    static func fittingPoolSize(poolCount: Int, maximum: Int, contextSize: Int, instructionsTokens: Int,
                                promptTokens: (Int) async -> Int) async -> Int {
        var size = poolCount
        let reserve = schemaReserve + outputReserve(maximum: maximum)
        while size > minPool {
            let total = instructionsTokens + (await promptTokens(size)) + reserve
            if total <= contextSize { return size }
            size = max(minPool, Int(Double(size) * 0.75))
        }
        return min(size, poolCount)
    }

    // MARK: Answers

    /// Numbers → songs: 1-based, out of range and repeats dropped, at most `maximum`, then topped up in pool order
    /// to `minimum`.
    static func songs(fromPicks picks: [Int], pool: [Song], minimum: Int, maximum: Int) -> [Song] {
        guard !pool.isEmpty else { return [] }
        var used = Set<Int>()
        var result: [Song] = []
        for pick in picks where (1...pool.count).contains(pick) && used.insert(pick).inserted {
            result.append(pool[pick - 1])
            if result.count >= maximum { return result }
        }
        for index in pool.indices where result.count < min(minimum, maximum) && used.insert(index + 1).inserted {
            result.append(pool[index])
        }
        return result
    }

    /// The integers of `key` in a JSON object (`{"picks":[3,1]}`), else every integer in the text.
    static func numbers(inJSON json: String, key: String) -> [Int] {
        if let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let values = object[key] as? [Any] {
            return values.compactMap { ($0 as? Int) ?? ($0 as? Double).map { Int($0) } ?? ($0 as? String).flatMap { Int($0) } }
        }
        return numbers(inText: json)
    }

    /// Every integer in `text`, in order.
    static func numbers(inText text: String) -> [Int] {
        var result: [Int] = []
        var current = ""
        for character in text {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                if let value = Int(current) { result.append(value) }
                current = ""
            }
        }
        if let value = Int(current) { result.append(value) }
        return result
    }

    // MARK: Long playlists

    /// A long playlist's plan. Energy and moods are kept for the prompt and for title/genre matches; songs carry no
    /// audio features to sort by energy.
    nonisolated struct Plan: Sendable, Equatable {
        var genres: [String] = []
        var artists: [String] = []
        var moods: [String] = []
        var energy = 3
        var familiar = true

        init(genres: [String] = [], artists: [String] = [], moods: [String] = [], energy: Int = 3, familiar: Bool = true) {
            self.genres = genres
            self.artists = artists
            self.moods = moods
            self.energy = energy
            self.familiar = familiar
        }

        /// The model's `GeneratedContent` JSON (`{"genres":[…],"artists":[…],"moods":[…],"energy":3,"familiar":true}`).
        init(json: String) {
            self.init()
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            genres = (object["genres"] as? [Any])?.compactMap { $0 as? String } ?? []
            artists = (object["artists"] as? [Any])?.compactMap { $0 as? String } ?? []
            moods = (object["moods"] as? [Any])?.compactMap { $0 as? String } ?? []
            if let value = (object["energy"] as? Int) ?? (object["energy"] as? Double).map({ Int($0) }) {
                energy = min(max(value, 1), 5)
            }
            if let value = object["familiar"] as? Bool { familiar = value }
        }
    }

    static func planPrompt(request: String, taste: Taste) -> String {
        var text = "Request: \(String(request.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))"
        if let taste = tasteLine(taste) { text += "\n" + taste }
        return text
    }

    /// The library's 20 biggest genres and 30 biggest artists: the values the plan may name.
    static func libraryTop(_ songs: [Song]) -> (genres: [String], artists: [String]) {
        (LibraryLookup.genreGroups(songs).prefix(20).map(\.name),
         LibraryLookup.groups(songs, key: { $0.displayArtist }).prefix(30).map(\.name))
    }

    /// The playlist a plan describes, `count` songs: the request's own matches, the plan's artists and genres and
    /// mood words in titles or genres score highest; familiar plans lean on liked and played songs, the others on
    /// unplayed ones; the day's ranking breaks ties. At most a fifth of the list per artist the plan didn't name.
    static func fill(plan: Plan, matched: [Song], allSongs: [Song], ranked: [Song], playCounts: [String: Int],
                     count: Int) -> [Song] {
        let artists = Set(plan.artists.map(LibraryLookup.normalized))
        let genres = Set(plan.genres.map(LibraryLookup.normalized))
        let moods = plan.moods.map(LibraryLookup.normalized).filter { $0.count >= 3 }
        let matchedIds = Set(matched.map(\.id))
        var rank: [String: Int] = [:]
        for (index, song) in ranked.enumerated() where rank[song.id] == nil { rank[song.id] = index }
        let rankCount = Double(max(ranked.count, 1))

        func score(_ song: Song) -> Double {
            var value = 0.0
            if matchedIds.contains(song.id) { value += 4 }
            if artists.contains(LibraryLookup.normalized(song.displayArtist)) { value += 3 }
            let songGenres = Set((song.genre ?? "").split(separator: ",").map { LibraryLookup.normalized(String($0)) })
            if !songGenres.isDisjoint(with: genres) { value += 2 }
            if !moods.isEmpty {
                let words = LibraryLookup.normalized(song.title + " " + (song.genre ?? ""))
                if moods.contains(where: { words.contains($0) }) { value += 1 }
            }
            let plays = playCounts[song.id] ?? 0
            if plan.familiar {
                if song.isFavorite { value += 1 }
                value += Double(min(plays, 20)) / 20
            } else if plays == 0 {
                value += 1
            }
            if let position = rank[song.id] { value += 0.5 * (1 - Double(position) / rankCount) }
            return value
        }

        let scored = allSongs.map { (song: $0, score: score($0)) }.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let ra = rank[a.song.id] ?? Int.max, rb = rank[b.song.id] ?? Int.max
            if ra != rb { return ra < rb }
            return a.song.id < b.song.id
        }
        let perArtist = max(3, count / 5)
        var seen = Set<String>()
        var byArtist: [String: Int] = [:]
        var result: [Song] = []
        var overflow: [Song] = []
        for entry in scored where seen.insert(entry.song.id).inserted {
            let artist = LibraryLookup.normalized(entry.song.displayArtist)
            if !artists.contains(artist), byArtist[artist, default: 0] >= perArtist {
                overflow.append(entry.song)
                continue
            }
            byArtist[artist, default: 0] += 1
            result.append(entry.song)
            if result.count >= count { return result }
        }
        return Array((result + overflow).prefix(count))
    }
}
