import Foundation
import PixlModel
import PixlNet

/// The automatic half of listening-history import (spec B1): on app start (at most every 6 hours per source), after
/// connecting Spotify, and inside Spotify's existing background refresh. Spotify first — recent plays, top lists,
/// followed artists — then YouTube Music's history page when signed in to YouTube. Failures are silent: they just
/// mean less data this time.
final class ListeningHistorySync {
    static let minimumIntervalMs: Int64 = 6 * 3_600_000

    private let store: ImportedHistoryStore
    private let spotify: SpotifyService
    private let youtube: YouTubeServices
    private var task: Task<Void, Never>?

    init(store: ImportedHistoryStore, spotify: SpotifyService, youtube: YouTubeServices) {
        self.store = store
        self.spotify = spotify
        self.youtube = youtube
    }

    /// Hooks the Spotify service (connect, background refresh). Call once at launch.
    func attach() {
        spotify.onConnected = { [weak self] in
            self?.store.setNeedsSpotifyReconnect(false)
            self?.syncIfDue(force: true)
        }
        spotify.onBackgroundRefresh = { [weak self] in await self?.run(force: false) }
    }

    /// Starts a sync unless one runs or every source synced within 6 hours (`force`: ignore the interval).
    func syncIfDue(force: Bool = false) {
        guard task == nil, !spotify.isDemo, !youtube.isDemo else { return }
        task = Task(priority: .utility) { [weak self] in
            await self?.run(force: force)
            self?.task = nil
        }
    }

    private func isDue(_ source: ImportedPlaySource, now: Int64, force: Bool) -> Bool {
        force || now - store.lastSync(source) >= Self.minimumIntervalMs
    }

    private func run(force: Bool) async {
        await store.ensureLoaded()
        let now = store.clock.nowMs()
        let wantsSpotify = store.spotifyEnabled && spotify.isLoggedIn && isDue(.spotifyAPI, now: now, force: force)
        let wantsYouTube = store.youTubeEnabled && isDue(.ytmusic, now: now, force: force)
        guard wantsSpotify || wantsYouTube else { return }
        store.setSyncing(true)
        defer { store.setSyncing(false) }

        if wantsSpotify, let result = await spotify.fetchListeningHistory(nowMs: now) {
            store.setNeedsSpotifyReconnect(result.needsReconnect)
            // A fetch that threw, or that Spotify never answered (offline), is not a sync: `addSynced` would stamp the
            // time and nothing would be tried again for 6 hours, losing plays that fall out of the last 50 meanwhile.
            if let fetch = result.fetch, fetch.anyResponded {
                let added = await store.addSynced(fetch.plays, taste: fetch.taste, source: .spotifyAPI)
                DiagnosticsLog.shared.log("history", "Spotify sync: \(added) new plays"
                                          + (result.needsReconnect ? ", reconnect needed" : ""))
            } else {
                DiagnosticsLog.shared.log("history", "Spotify sync: no answer, trying again later")
            }
        }
        if wantsYouTube, let plays = await youtube.fetchMusicHistory(nowMs: now, timeZone: store.clock.timeZone) {
            let added = await store.addSynced(plays, source: .ytmusic)
            DiagnosticsLog.shared.log("history", "YouTube Music sync: \(plays.count) entries, \(added) new")
        }
    }
}
