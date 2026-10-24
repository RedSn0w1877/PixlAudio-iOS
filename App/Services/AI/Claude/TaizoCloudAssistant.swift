import Foundation
import PixlLibrary
import PixlModel
import PixlNet

/// What Ask Taizo needs to talk to Claude (spec A4): the router, the client, the saved conversations, the listening
/// context and "now" block builders, the tools and the usage sink. `TaisChatModel` holds one and runs the turns.
@MainActor
final class TaizoCloudAssistant {
    let route: @Sendable () -> AIRoute
    let client: @Sendable () -> (any ClaudeMessaging)?
    /// Saved conversations (nil in UI tests: nothing is written).
    let store: TaizoConversationStore?
    let context: @MainActor () async -> String
    let now: @MainActor (_ lyricsSentFor: String?) async -> TaizoNow
    let toolbox: @MainActor () -> TaizoToolbox
    let onUsage: @Sendable (ClaudeUsage) async -> Void
    let onFallback: @Sendable (String) async -> Void

    init(route: @escaping @Sendable () -> AIRoute, client: @escaping @Sendable () -> (any ClaudeMessaging)?,
         store: TaizoConversationStore?, context: @escaping @MainActor () async -> String,
         now: @escaping @MainActor (_ lyricsSentFor: String?) async -> TaizoNow,
         toolbox: @escaping @MainActor () -> TaizoToolbox,
         onUsage: @escaping @Sendable (ClaudeUsage) async -> Void,
         onFallback: @escaping @Sendable (String) async -> Void) {
        self.route = route
        self.client = client
        self.store = store
        self.context = context
        self.now = now
        self.toolbox = toolbox
        self.onUsage = onUsage
        self.onFallback = onFallback
    }
}

/// One turn's "now" block, and the song whose lyrics it carries (they aren't sent again while it plays).
nonisolated struct TaizoNow: Sendable {
    var context: TaizoNowContext
    var lyricsSongKey: String?
}

/// The saved conversations: Application Support/taizo-conversations.json (the newest five, `TaizoConversationCodec`),
/// read and written off the main thread. Excluded from iCloud/device backups; stays on the phone.
actor TaizoConversationStore {
    private let url: URL?
    private var records: [TaizoConversationRecord]?

    init(url: URL?) {
        self.url = url
    }

    nonisolated static func defaultURL() -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("taizo-conversations.json", isDirectory: false)
    }

    /// Newest first.
    func load() -> [TaizoConversationRecord] {
        if let records { return records }
        var loaded: [TaizoConversationRecord] = []
        if let url, let data = try? Data(contentsOf: url) {
            loaded = TaizoConversationCodec.decode(String(decoding: data, as: UTF8.self))
        }
        records = loaded
        return loaded
    }

    func save(_ record: TaizoConversationRecord) {
        var all = load().filter { $0.id != record.id }
        all.append(record)
        let pruned = TaizoConversationCodec.pruned(all)
        records = pruned
        write(pruned)
    }

    func delete(id: String) {
        let remaining = load().filter { $0.id != id }
        records = remaining
        write(remaining)
    }

    private func write(_ records: [TaizoConversationRecord]) {
        guard var url = self.url else { return }
        try? Data(TaizoConversationCodec.encode(records).utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// Builds what Taizo always knows (spec A4): the listening context (library, playlists, top artists / genres / songs,
/// recent history — imported Spotify / YouTube Music history included, since it lands in the same history store) and
/// each turn's now block (song, position, ids, instrumental, lyrics, the next 20 in the queue).
@MainActor
enum TaizoContextBuilder {
    static func listeningContext(_ env: AppEnvironment?) async -> String {
        guard let env else { return TaizoListeningContext(librarySongCount: 0, libraryArtistCount: 0).render() }
        await env.home.history.ensureLoaded()
        let songs = env.library.songs
        let artistCount = env.library.snapshot.artists.count
        let playlists = env.library.playlists.sorted { $0.sortOrder < $1.sortOrder }.map(\.name)
        let events = env.home.history.events
        let nowMs = currentTimeMillis()
        var context = await Task.detached(priority: .userInitiated) {
            compute(songs: songs, artistCount: artistCount, playlists: playlists, events: events, nowMs: nowMs)
        }.value
        // The taste digest, built by code from every play (the app's and the imported ones): top artists and genres, the
        // last plays, the artists the user skips, the taste changes in force and how many plays it all rests on.
        let profile = await TaizoTaste.profile(env, period: .sixMonths)
        context.tasteDigest = profile.digestLines()
        if profile.totalPlays > 0 {
            context.periodLabel = profile.periodUsed == .allTime ? "of all time" : "in the last 6 months"
            context.totalListeningHours = nil
            context.topArtists = []
            context.topGenres = []
            context.recentPlays = []
            context.topSongs = profile.topTracks.prefix(TaizoListeningContext.maxTopSongs).map {
                TaizoSongLine(title: $0.title, artist: $0.artist, detail: $0.plays == 1 ? "1 play" : "\($0.plays) plays")
            }
            let imported = profile.spotifyPlays + profile.youTubeMusicPlays
            if imported > 0 {
                context.importedHistory = "\(imported.formatted()) plays imported (\(profile.spotifyPlays.formatted()) Spotify, "
                    + "\(profile.youTubeMusicPlays.formatted()) YouTube Music)"
            }
        }
        return context.render()
    }

    nonisolated static func compute(songs: [Song], artistCount: Int, playlists: [String], events: [PlaybackEvent],
                                    nowMs: Int64) -> TaizoListeningContext {
        var summary = PlaybackStats.buildSummary(range: .month, songs: songs, nowMillis: nowMs, events: events)
        var period = "in the last 30 days"
        if summary.totalPlayCount == 0 {
            summary = PlaybackStats.buildSummary(range: .all, songs: songs, nowMillis: nowMs, events: events)
            period = "of all time"
        }
        let byId = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var recent: [TaizoSongLine] = []
        for event in events.sorted(by: { $0.timestamp > $1.timestamp }) where seen.insert(event.songId).inserted {
            guard let song = byId[event.songId] else { continue }
            recent.append(TaizoSongLine(title: song.title, artist: song.displayArtist))
            if recent.count >= TaizoListeningContext.maxRecent { break }
        }
        return TaizoListeningContext(
            librarySongCount: songs.count, libraryArtistCount: artistCount, playlistNames: playlists, periodLabel: period,
            topArtists: summary.topArtists.map(\.artist), topGenres: summary.topGenres.map(\.genre),
            topSongs: summary.topSongs.map { TaizoSongLine(title: $0.title, artist: $0.artist,
                                                           detail: $0.playCount == 1 ? "1 play" : "\($0.playCount) plays") },
            recentPlays: recent,
            totalListeningHours: Int(summary.totalDurationMs / 3_600_000))
    }

    static func now(_ env: AppEnvironment?, lyricsSentFor previous: String?) async -> TaizoNow {
        let time = timeFormatter.string(from: Date())
        guard let env, let song = env.playback.current else {
            return TaizoNow(context: TaizoNowContext(localTime: time, song: nil), lyricsSongKey: previous)
        }
        let playback = env.playback
        var isrc: String?
        if let spotifyId = song.spotifyId, let record = try? await env.persistence?.spotifySong(spotifyId: spotifyId) {
            isrc = record.isrc
        }
        let duration = playback.durationMs() > 0 ? playback.durationMs() : song.duration
        let current = TaizoCurrentSong(
            id: song.id, title: song.title, artists: song.displayArtist, album: song.album, year: song.year,
            durationMs: duration, positionMs: playback.positionMs(), isPlaying: playback.isPlaying,
            spotifyId: song.spotifyId, isrc: isrc, hasInstrumental: env.tais.instrumental.isAvailable,
            isLiked: env.library.song(id: song.id)?.isFavorite ?? song.isFavorite)
        var lyrics: String?
        if case .loaded(let songId, let loaded, _) = env.lyrics.state, songId == song.id {
            lyrics = plainText(loaded)
        }
        let upNext: [TaizoSongLine]
        if let index = playback.currentIndex, index + 1 < playback.queue.count {
            upNext = playback.queue[(index + 1)...].prefix(TaizoNowContext.maxUpNext)
                .map { TaizoSongLine(title: $0.title, artist: $0.displayArtist) }
        } else {
            upNext = []
        }
        let alreadySent = lyrics != nil && previous == song.id
        return TaizoNow(context: TaizoNowContext(localTime: time, song: current, upNext: upNext, lyrics: lyrics,
                                                 lyricsAlreadySent: alreadySent),
                        lyricsSongKey: lyrics != nil ? song.id : previous)
    }

    /// The lyrics as plain lines (synced lines without their times).
    nonisolated static func plainText(_ lyrics: Lyrics) -> String {
        if let synced = lyrics.synced, !synced.isEmpty {
            return synced.filter { $0.voiceRole != "background" }.map(\.line).joined(separator: "\n")
        }
        return (lyrics.plain ?? []).joined(separator: "\n")
    }

    /// "Fri 23 Oct, 21:05".
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM yyyy, HH:mm"
        return formatter
    }()
}
