import Foundation
import Observation
import PixlLibrary
import PixlModel

/// What the listener does to the music brain by hand (docs/brain-spec.md, 8.1, 8.3, 8.5): "Start station", a card of
/// a "Because you listened to" row, "Not for me" with its Undo, "Less from X", the Familiar / Blend / Discover
/// switch. The port of Android's `StationStateHolder` and `BrainActionsStateHolder`.
///
/// It carries decisions out; every decision is PixlLibrary's (`Station`, `StationRules`, `BrainFeedback`,
/// `BrainNotice`). The only state it publishes is the bar that follows a piece of feedback.
@Observable
final class BrainActions {
    /// The bar that follows "Not for me" and "Less from X" (Undo, and the step to the artist); nil when there is none.
    private(set) var notice: BrainNotice?

    private let brain: BrainService
    private let playback: PlaybackStore
    private let library: LibraryStore
    private let taste: TasteAdjustmentStore
    private let playCounts: PlayCountStore
    /// The real engine and Autoplay; both nil in UI tests, where a station is its seed playing and nothing more.
    @ObservationIgnored private weak var engine: DualDeckEngine?
    @ObservationIgnored private weak var autoplay: AutoplayController?
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var seedTask: Task<Void, Never>?

    init(brain: BrainService, playback: PlaybackStore, library: LibraryStore, taste: TasteAdjustmentStore,
         playCounts: PlayCountStore, engine: DualDeckEngine?, autoplay: AutoplayController?) {
        self.brain = brain
        self.playback = playback
        self.library = library
        self.taste = taste
        self.playCounts = playCounts
        self.engine = engine
        self.autoplay = autoplay
    }

    // MARK: Stations (8.3)

    /// A station from `song`: it plays (or keeps playing), and music like it follows.
    func startSongStation(_ song: Song) {
        let station = Station.song(seedMediaId: song.id, title: song.title,
                                   primaryArtist: StationRules.primaryArtist(of: song), nowMs: currentTimeMillis())
        start(station, seed: song)
    }

    /// A station from an artist: the listener's most-played library track by that artist plays first. `knownSongs`
    /// are the artist's songs when the caller already has them (the artist page); without them the library is
    /// searched, off the main actor.
    func startArtistStation(name: String, knownSongs: [Song] = []) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let songs = knownSongs.isEmpty ? library.songs : knownSongs
        var counts: [String: Int] = [:]
        for entry in playCounts.entries ?? [] where counts[entry.songId] == nil { counts[entry.songId] = entry.stats.playCount }
        let plays = counts
        seedTask?.cancel()
        seedTask = Task { [weak self] in
            let seed = await Task.detached(priority: .userInitiated) {
                StationRules.artistSeed(artistName: name, songs: songs, playCount: { plays[$0] ?? 0 })
            }.value
            guard let self, !Task.isCancelled else { return }
            guard let seed else {
                self.playback.notices.show(BrainStrings.stationNothingToStart(name))
                return
            }
            self.start(Station.artist(seedMediaId: seed.id, artistName: name, nowMs: currentTimeMillis()), seed: seed)
        }
    }

    private func start(_ station: Station, seed: Song) {
        brain.stations.start(station)
        // The seed is already sounding: it keeps playing, and what was queued behind it goes.
        let inPlace = playback.currentSongId == seed.id && (engine?.startStationInPlace(tag: station.seedTag) ?? false)
        if !inPlace {
            // A one-song queue is the listener's explicit choice (it plays even when its artist is blocked). The
            // seed's tag is what makes the queue this station's: any other play replaces it, which ends the station.
            playback.play([seed], source: station.seedTag)
        } else if StationRules.inPlaceStartMustPlay(isPlaying: playback.isPlaying) {
            // "Start station" on a paused track is still a request for music: the seed plays on from where it is.
            playback.resume()
        }
        let state = brain.autoplay
        if state.stationTitle != station.title { state.stationTitle = station.title }
        if state.stationIsArtist != station.isArtist { state.stationIsArtist = station.isArtist }
        autoplay?.stationChanged()
    }

    // MARK: Home rows (8.1)

    /// Plays a card of a "Because you listened to" row, with the row as the queue. The cards are tracks from
    /// outside the library: they are made known first (so they can be shown and saved later), and each carries its
    /// pick into the queue and the event log.
    func play(_ shelf: BrainHomeShelf, startingAt song: Song) {
        brain.register(shelf.row.items.map(\.track))
        // The cards were built off the main actor; here each is pointed at the library's own artist, when it has one.
        let songs = shelf.section.songs.map { brain.linked($0) }
        playback.play(songs.first { $0.id == song.id } ?? song, in: songs, tags: shelf.tags)
    }

    // MARK: Feedback (8.5)

    /// "Not for me": the song is muted in everything the app picks by itself (it shows in Taste changes), skipped
    /// if it is the one playing, and the bar offers Undo and "Less from <artist>". The play is flagged first, so
    /// the skip is logged as what it was.
    func notForMe(_ song: Song) {
        brain.mark([song.id], flag: EventFlags.notForMe)
        if playback.currentSongId == song.id { playback.skipToNext() }
        let artist = BrainFeedback.artistOf(song)
        Task { [weak self] in
            guard let self else { return }
            let outcomes = await self.taste.apply([BrainFeedback.muteChange(for: song)])
            self.serial += 1
            self.show(BrainNotice.afterNotForMe(serial: self.serial, outcome: outcomes.first, artistName: artist))
        }
    }

    /// Undo on the bar: takes the change it names back.
    func undo() {
        guard let id = notice?.adjustmentId else { return }
        taste.remove(id: id)
        serial += 1
        show(BrainNotice(serial: serial, kind: .undone, adjustmentId: nil, artistName: ""))
    }

    /// "Less from X" on the bar after "Not for me".
    func lessFromNoticeArtist() {
        guard let notice, notice.canLessFrom else { return }
        lessFrom(notice.artistName)
    }

    /// "Less from X": the existing reduce on the artist.
    func lessFrom(_ artistName: String) {
        guard let change = BrainFeedback.lessFromChange(artistName: artistName) else { return }
        Task { [weak self] in
            guard let self else { return }
            let outcomes = await self.taste.apply([change])
            self.serial += 1
            self.show(BrainNotice.afterLessFrom(serial: self.serial, outcome: outcomes.first, artistName: artistName))
        }
    }

    func dismissNotice() {
        dismissTask?.cancel()
        dismissTask = nil
        if notice != nil { notice = nil }
    }

    private func show(_ next: BrainNotice) {
        notice = next
        PixlAccessibility.announce(BrainStrings.notice(next))
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(next.visibleMs))
            guard let self, !Task.isCancelled, self.notice?.serial == next.serial else { return }
            self.notice = nil
        }
    }

    // MARK: Familiar / Blend / Discover (8.3)

    /// The switch applies from the next track: the engine's tail is planned again.
    func setNovelty(_ level: Int) {
        guard brain.stations.setNovelty(level) else { return }
        let value = brain.stations.novelty
        if brain.autoplay.novelty != value { brain.autoplay.novelty = value }
        autoplay?.noveltyChanged()
    }
}

/// One "Because you listened to X" row as Home draws it: the row, its cards as songs, and what each card carries
/// into the queue.
nonisolated struct BrainHomeShelf: Sendable, Equatable, Identifiable {
    let row: BrainHomeRow
    let section: HomeMusicSection
    let tags: [String: BrainItemTag]

    var id: String { row.id }

    /// Built off the main actor: twelve songs and their reason lines per row.
    static func make(_ rows: [BrainHomeRow], nowMs: Int64) -> [BrainHomeShelf] {
        rows.map { row in
            var songs: [Song] = []
            var reasons: [(String, String)] = []
            songs.reserveCapacity(row.items.count)
            for item in row.items {
                let song = BrainService.queueSong(for: item.track, nowMs: nowMs)
                songs.append(song)
                if let line = row.cardReason(item) { reasons.append((song.id, BrainStrings.whyLine(line))) }
            }
            let section = HomeMusicSection(id: row.id, title: BrainStrings.homeBecauseListened(row.anchor.title),
                                           subtitle: BrainStrings.homeBecauseListenedSubtitle, songs: songs,
                                           reasons: reasons)
            return BrainHomeShelf(row: row, section: section, tags: row.tags())
        }
    }
}
