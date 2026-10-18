import Foundation
import Observation
import PixlLibrary
import PixlModel

/// Blocked artists (iOS-first, owner request 2026-10-18). A song with a blocked artist among its credits is never
/// played by itself: skipped in the queue, left out of shuffles, mixes and Home; in playlists and albums it stays
/// visible, dimmed with a "Blocked" badge, and tapping it offers "Play anyway".
///
/// The list lives in `UserDefaults` as one JSON string under `blocked_artists_json` (like `HiddenSongs` and the other
/// small lists; a SwiftData model here would need a `SchemaV2` and a migration stage that cannot be tried without a
/// phone, and a failed migration would lose the whole library). The key is an iOS-only portable key, so the settings
/// backup carries the list. Pure matching is `BlockedArtistMatcher` (PixlLibrary).
@Observable
final class BlockedArtistsStore {
    /// The current list as a matcher (a value; cheap to hand to the playback side and to background work).
    private(set) var matcher: BlockedArtistMatcher
    /// Bumped on every change (Home keys its recomputation on it).
    private(set) var revision = 0
    /// "Play anyway?": a tap on a blocked song waits here for the answer (the shell shows the dialog).
    var pendingPlay: PendingBlockedPlay?

    @ObservationIgnored private let defaults: UserDefaults
    /// Told after every change, on the main actor: the playback engine, Home.
    @ObservationIgnored var onChange: ((BlockedArtistMatcher) -> Void)?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        matcher = BlockedArtistMatcher(entries: BlockedArtistCodec.decode(defaults.string(forKey: PreferenceKeys.blockedArtists)))
    }

    var entries: [BlockedArtist] { matcher.entries }
    var count: Int { matcher.count }
    var isEmpty: Bool { matcher.isEmpty }

    func isBlocked(_ song: Song) -> Bool { matcher.isBlocked(song) }
    func isBlocked(artistId: Int64, name: String) -> Bool { matcher.isBlocked(artistId: artistId, name: name) }

    /// The blocked credit of `song` to name in "Blocked: X" captions.
    func blockedArtistNames(of song: Song) -> [String] { matcher.blockedArtists(of: song).map(\.name) }

    func block(artistId: Int64, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        apply(matcher.adding(BlockedArtist(artistId: artistId, name: trimmed, blockedAt: now)))
    }

    func unblock(artistId: Int64, name: String) {
        apply(matcher.removing(artistId: artistId, name: name))
    }

    func unblockAll() {
        apply(.empty)
    }

    /// Re-reads the list after a backup restore wrote it.
    func reloadFromDefaults() {
        let fresh = BlockedArtistMatcher(entries: BlockedArtistCodec.decode(defaults.string(forKey: PreferenceKeys.blockedArtists)))
        if fresh != matcher { publish(fresh, persist: false) }
    }

    private func apply(_ next: BlockedArtistMatcher) {
        guard next != matcher else { return }
        publish(next, persist: true)
    }

    private func publish(_ next: BlockedArtistMatcher, persist: Bool) {
        matcher = next
        revision &+= 1
        if persist {
            if next.isEmpty {
                defaults.removeObject(forKey: PreferenceKeys.blockedArtists)
            } else {
                defaults.set(BlockedArtistCodec.encode(next.entries), forKey: PreferenceKeys.blockedArtists)
            }
        }
        onChange?(next)
    }

    // MARK: Tapping a blocked song

    /// A tap on a song row: plays within `songs`, or asks "Play anyway?" when the song is blocked.
    func playTapped(_ song: Song, in songs: [Song], using playback: PlaybackStore) {
        if matcher.isBlocked(song) {
            pendingPlay = PendingBlockedPlay(song: song, list: songs)
        } else {
            playback.play(song, in: songs)
        }
    }

    /// The answer "Play anyway" (takes the request the dialog was shown for: the dialog clears the pending one
    /// itself as it goes away, possibly before this runs).
    func confirmPlay(_ pending: PendingBlockedPlay, using playback: PlaybackStore) {
        pendingPlay = nil
        playback.play(pending.song, in: pending.list, allowsBlockedStart: true)
    }

    func cancelPendingPlay() { pendingPlay = nil }
}

/// A blocked song the person tapped, waiting for "Play anyway".
struct PendingBlockedPlay: Identifiable, Equatable {
    let song: Song
    let list: [Song]
    var id: String { song.id }

    static func == (lhs: PendingBlockedPlay, rhs: PendingBlockedPlay) -> Bool { lhs.song.id == rhs.song.id }
}
