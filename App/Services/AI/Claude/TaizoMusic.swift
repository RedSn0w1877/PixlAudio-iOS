import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel
import PixlNet

/// The ten music tools of Ask Taizo (docs/brain-spec.md, 9.3) on the app: the grounding record of one conversation and, once a music tool is
/// first used, the engine behind them (`BrainAssistantEngine`, PixlLibrary) wired to the stores. Every decision is PixlLibrary's; this
/// file only connects it to the app's network search, its player and its taste store.
@MainActor
final class TaizoMusic {
    /// What this conversation's tools returned and the listener said (`TaizoGrounding`).
    nonisolated let grounding = TaizoGrounding()

    nonisolated struct Prepared: Sendable {
        let runner: MusicToolRunner
        let playable: any AssistantPlayable
    }

    private var prepared: Prepared?

    nonisolated init() {}

    /// The runner and the playable side, made on first use from the brain's stores; nil while the brain is off (UI tests) or not ready.
    func prepare(_ environment: @escaping @MainActor @Sendable () -> AppEnvironment?) -> Prepared? {
        if let prepared { return prepared }
        guard let env = environment(), let engine = env.brain.engine, let repository = env.brain.repository,
              let mixes = env.brain.mixes else { return nil }
        let host = TaizoAssistantHost(environment: environment)
        let backend = BrainAssistantEngine(
            mixes: mixes, engine: engine, repository: repository, parts: env.brain.stage2b?.parts, yourSound: env.brain.yourSound,
            host: host, library: { await MainActor.run { environment()?.library.songs ?? [] } })
        let made = Prepared(runner: MusicToolRunner(backend: backend, grounding: grounding), playable: backend)
        prepared = made
        return made
    }

    /// A new turn: the lookups it may start are counted again.
    func beginTurn() async {
        await prepared?.runner.beginTurn()
    }
}

/// What the engine asks of the app: the YouTube Music search, stations, lasting taste changes and the queue.
nonisolated struct TaizoAssistantHost: AssistantHost {
    let environment: @MainActor @Sendable () -> AppEnvironment?

    func searchSong(title: String, artist: String) async -> AssistantSearch {
        let parts = await MainActor.run { () -> (client: InnerTubeClient, budget: HostBudget)? in
            guard let env = environment(), let client = env.youtube.service?.client, let budget = env.youtube.radioBudget else { return nil }
            return (client, budget)
        }
        guard let parts else { return .notFound }
        let query = [title, artist].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
        // Under the day's request budget (the one autoplay and the radios share): nil is "spent", an empty list is "nothing came".
        let found: [YouTubeSearchResult]? = await parts.budget.withPermit { () async -> [YouTubeSearchResult]? in
            (try? await parts.client.searchSongs(query, limit: 5)) ?? []
        }
        guard let results = found else { return .skipped }
        let wanted = MatchableTrack(title: title, artist: artist, album: "", durationMs: 0)
        let wantedTitle = BrainText.cleanTitle(title).title
        var best: YouTubeSearchResult?
        var bestScore: Float = 0
        for r in results {
            // With no artist given only a near-exact title counts: the matcher needs an artist to vouch for a candidate.
            let score: Float = BrainText.isBlank(artist)
                ? (!wantedTitle.isEmpty && wantedTitle == BrainText.cleanTitle(r.title).title && !r.isMusicVideo ? TrackMatcher.minAcceptScore : 0)
                : TrackMatcher.score(wanted, r)
            if score > bestScore {
                best = r
                bestScore = score
            }
        }
        guard let hit = best, bestScore >= TrackMatcher.minAcceptScore else { return .notFound }
        let row = RadioRow(videoId: hit.videoId, title: hit.title, artists: [RadioArtistRef(name: hit.artist, channelId: nil)], album: hit.album,
                           durationSec: hit.durationSeconds ?? 0, thumbnailUrl: hit.thumbnailUrl, kind: .atv)
        return .found(row)
    }

    func register(_ tracks: [EngineTrack]) async {
        _ = await MainActor.run { environment()?.brain.register(tracks) }
    }

    func nowPlaying() async -> Song? {
        await MainActor.run { environment()?.playback.current }
    }

    func queueNext(_ songs: [Song], tags: [String: BrainItemTag]) async -> Int {
        await MainActor.run {
            guard let env = environment(), !songs.isEmpty else { return 0 }
            if env.playback.hasItem {
                env.playback.playNext(songs)
            } else {
                env.playback.play(songs, startIndex: 0, source: .assistant, tags: tags)
            }
            return songs.count
        }
    }

    func startStation(seedRef: String, seedKind: String, mode: String, song: Song?) async -> AssistantStationOutcome {
        // The switch is global (deviation 217): `mode` sets Familiar / Blend / Discover before the station starts.
        let level: Int = mode == "familiar" ? Novelty.familiar : (mode == "discover" ? Novelty.discover : Novelty.blend)
        let genreName: String? = seedKind == "genre" ? await atlasGenreName(of: seedRef) : nil
        return await MainActor.run { () -> AssistantStationOutcome in
            guard let env = environment() else { return AssistantStationOutcome(started: false, reason: "PixlAudio isn't ready yet. Try again in a moment.") }
            let actions = env.brainActions
            switch seedKind {
            case "song":
                guard let song else { return AssistantStationOutcome(started: false, reason: "That song could not be found.") }
                actions.setNovelty(level)
                actions.startSongStation(song)
                return AssistantStationOutcome(started: true, firstTrack: nil)
            case "artist":
                actions.setNovelty(level)
                actions.startArtistStation(name: seedRef)
                return AssistantStationOutcome(started: true)
            case "genre":
                guard let id = Int(seedRef.trimmingCharacters(in: .whitespaces)), let name = genreName else {
                    return AssistantStationOutcome(started: false, reason: "The genre is not known: use an id from lookup_genre.")
                }
                actions.setNovelty(level)
                actions.startGenreStation(kind: StationCard.kindGenre, atlasId: id, name: name)
                return AssistantStationOutcome(started: true)
            case "album":
                let key = BrainText.fold(seedRef)
                let songs = env.library.songs.filter { BrainText.fold($0.album) == key }
                guard !songs.isEmpty else { return AssistantStationOutcome(started: false, reason: "No album with that name is in the library.") }
                actions.setNovelty(level)
                actions.startAlbumStation(name: seedRef, songs: songs)
                return AssistantStationOutcome(started: true)
            case "playlist":
                let key = BrainText.fold(seedRef)
                guard let playlist = env.library.playlists.first(where: { BrainText.fold($0.name) == key }) else {
                    return AssistantStationOutcome(started: false, reason: "No playlist with that name is in the library.")
                }
                let byId = Dictionary(env.library.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let songs = playlist.songIds.compactMap { byId[$0] }
                guard !songs.isEmpty else { return AssistantStationOutcome(started: false, reason: "That playlist has no songs the library knows.") }
                actions.setNovelty(level)
                actions.startPlaylistStation(name: playlist.name, songs: songs)
                return AssistantStationOutcome(started: true)
            default:
                return AssistantStationOutcome(started: false, reason: "Unknown seed kind.")
            }
        }
    }

    private func atlasGenreName(of seedRef: String) async -> String? {
        guard let id = Int(seedRef.trimmingCharacters(in: .whitespaces)) else { return nil }
        let atlas = await MainActor.run { environment()?.brain.stage2b?.parts.atlas }
        return await atlas?.atlas()?.genre(id)?.name
    }

    @MainActor
    private func adjustGenre(_ genre: String, more: Bool) async -> Bool {
        guard let env = environment() else { return false }
        return await env.brainActions.adjustGenre(genre, more: more)
    }

    func steer(change: String, target: String, scope: String, song: Song?) async -> AssistantSteerOutcome {
        let genre: String? = change.hasSuffix("_genre") ? await atlasGenreName(of: target) : nil
        let more = change.hasPrefix("more_")
        var changed: Bool?
        if let genre, change == "more_genre" || change == "less_genre" { changed = await adjustGenre(genre, more: more) }
        let adjusted = changed
        return await MainActor.run { () -> AssistantSteerOutcome in
            guard let env = environment() else { return AssistantSteerOutcome(applied: false, note: "PixlAudio isn't ready yet.") }
            let actions = env.brainActions
            switch change {
            case "more_familiar":
                actions.setNovelty(Novelty.familiar)
                return AssistantSteerOutcome(applied: true, note: "From now on PixlAudio leans on music the listener knows. The switch is in the player.")
            case "more_new":
                actions.setNovelty(Novelty.discover)
                return AssistantSteerOutcome(applied: true, note: "From now on PixlAudio leans on new music. The switch is in the player.")
            case "less_artist":
                guard !BrainText.isBlank(target) else { return AssistantSteerOutcome(applied: false, note: "Say which artist.") }
                actions.lessFrom(target)
                return AssistantSteerOutcome(applied: true, note: "PixlAudio will play less of \(target). It can be undone in Settings.")
            case "more_artist":
                let seed = song ?? env.library.songs.first { BrainText.fold(BrainLibraryIndex.primaryArtistName($0)) == BrainText.fold(target) }
                guard let seed else { return AssistantSteerOutcome(applied: false, note: "No song by that artist is in the library to base it on.") }
                actions.moreLike(seed)
                return AssistantSteerOutcome(applied: true, note: "PixlAudio will play more like \(target). It can be undone in Settings.")
            case "more_genre", "less_genre":
                guard let genre else { return AssistantSteerOutcome(applied: false, note: "The genre is not known: use an id from lookup_genre.") }
                return adjusted == true
                    ? AssistantSteerOutcome(applied: true, note: "PixlAudio will play \(more ? "more" : "less") \(genre). It can be undone in Settings.")
                    : AssistantSteerOutcome(applied: false, note: "The change could not be stored.")
            default:
                return AssistantSteerOutcome(applied: false, note: "Energy has no lasting setting, so nothing was changed.")
            }
        }
    }
}
