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
    /// Private session (8.5): plays are not counted in the picks while it is on. Off at every app start.
    private(set) var isPrivate = false

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
            if let seed {
                self.start(Station.artist(seedMediaId: seed.id, artistName: name, nowMs: currentTimeMillis()), seed: seed)
                return
            }
            // An artist with no song in the library: the artist page's own radio button starts it (8.3). One search, one
            // page and one radio before sound, off the main actor, under the YouTube budget.
            guard let started = await self.brain.repository?.beginArtistStation(artistName: name), !Task.isCancelled else {
                self.playback.notices.show(BrainStrings.stationNothingFound(name))
                return
            }
            let track = EngineTrack(row: started.seedRow, rid: started.seedRid)
            // The track must be known to the app BEFORE its queue item reaches the player (7.2).
            self.brain.register([track])
            let song = self.brain.linked(BrainService.queueSong(for: track))
            self.start(Station.artist(seedMediaId: song.id, artistName: name, nowMs: currentTimeMillis()), seed: song)
        }
    }

    /// A station from an album: three of its songs seed it, and none of its own songs lead (6.2).
    func startAlbumStation(name: String, songs: [Song]) {
        startStation(from: songs, name: name, source: Station.sourceAlbum, maxSeeds: StationSeeds.albumSeeds)
    }

    /// A station from a playlist: five of its songs seed it (6.2).
    func startPlaylistStation(name: String, songs: [Song]) {
        startStation(from: songs, name: name, source: Station.sourcePlaylist, maxSeeds: StationSeeds.playlistSeeds)
    }

    /// A station from a genre or a mood of the atlas (8.3, stage 2b): the listener's most played songs under the node seed it.
    /// With none of their songs under it nothing starts. A card says so in a notice; a Search tile has `onNothing` instead (its live
    /// search), and says nothing, so the person is not told "nothing started" and shown a new screen at the same time.
    func startGenreStation(kind: Int, atlasId: Int, name: String, onNothing: (@MainActor () -> Void)? = nil) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, let genre = brain.stage2b?.genre else {
            onNothing?()
            return
        }
        Task { [weak self] in
            let songs = await genre.songsFor(kind: kind, atlasId: atlasId, nowMs: currentTimeMillis())
            guard let self else { return }
            if songs.isEmpty {
                if let onNothing { onNothing() } else { self.playback.notices.show(BrainStrings.stationGenreNothing(name)) }
                return
            }
            let source = kind == StationCard.kindMood ? Station.sourceMood : Station.sourceGenre
            self.startStation(from: songs, name: name, source: source, maxSeeds: StationSeeds.genreSeeds)
        }
    }

    /// A Search tile: a station when the atlas knows the genre and the listener has songs under it, else `fallback`.
    func startGenreStationByName(_ name: String, fallback: @escaping @MainActor () -> Void) {
        guard let genre = brain.stage2b?.genre else {
            fallback()
            return
        }
        Task { [weak self] in
            let id = await genre.idForName(name)
            guard let self else { return }
            if id == GenreAtlas.none {
                fallback()
            } else {
                self.startGenreStation(kind: StationCard.kindGenre, atlasId: id, name: name, onNothing: fallback)
            }
        }
    }

    /// The Search tiles the atlas knows (8.10): a genre the atlas lacks gets no tile. Nil while it is not known yet.
    func knownGenreTiles(_ names: [String]) async -> Set<String>? {
        guard let genre = brain.stage2b?.genre else { return nil }
        return await genre.knownNames(names)
    }

    private func startStation(from songs: [Song], name: String, source: Int, maxSeeds: Int) {
        guard !songs.isEmpty, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var counts: [String: Int] = [:]
        for entry in playCounts.entries ?? [] where counts[entry.songId] == nil { counts[entry.songId] = entry.stats.playCount }
        let plays = counts
        seedTask?.cancel()
        seedTask = Task { [weak self] in
            let seeds = await Task.detached(priority: .userInitiated) {
                StationSeeds.pick(songs: songs, plays: plays, max: maxSeeds)
            }.value
            guard let self, !Task.isCancelled else { return }
            guard let first = seeds.first else {
                self.playback.notices.show(BrainStrings.stationNothingFound(name))
                return
            }
            let station = Station.fromSource(source, seedMediaIds: seeds.map(\.id), title: name, nowMs: currentTimeMillis())
            self.start(station, seed: first, sourceIds: Set(songs.map(\.id)))
        }
    }

    private func start(_ station: Station, seed: Song, sourceIds: Set<String> = []) {
        brain.stations.start(station, sourceIds: sourceIds)
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
        if state.stationSource != station.source { state.stationSource = station.source }
        autoplay?.stationChanged()
    }

    // MARK: Home rows (8.1)

    /// Plays a card of a "Because you listened to" row, with the row as the queue. The cards are tracks from
    /// outside the library: they are made known first (so they can be shown and saved later), and each carries its
    /// pick into the queue and the event log.
    func play(_ shelf: BrainHomeShelf, startingAt song: Song) {
        brain.register(shelf.tracks)
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

    /// Undo on the bar: takes the change it names back, or counts the plays "Don't count this" left out again.
    func undo() {
        if let excluded = notice?.excluded {
            Task { [weak self] in
                guard let self else { return }
                await self.brain.undoExclusion(excluded)
                self.serial += 1
                self.show(BrainNotice(serial: self.serial, kind: .undone, adjustmentId: nil, artistName: ""))
            }
            return
        }
        guard let id = notice?.adjustmentId else { return }
        taste.remove(id: id)
        serial += 1
        show(BrainNotice(serial: serial, kind: .undone, adjustmentId: nil, artistName: ""))
    }

    /// "More like this" (8.5): the track's artist is boosted for two weeks, so the next batch leans that way. It shows
    /// in Taste changes and is undone there or from the bar.
    func moreLike(_ song: Song) {
        guard let change = BrainFeedback.moreLikeChange(for: song) else { return }
        let artist = BrainFeedback.artistOf(song)
        Task { [weak self] in
            guard let self else { return }
            let outcomes = await self.taste.apply([change])
            self.serial += 1
            self.show(BrainNotice.afterMoreLike(serial: self.serial, outcome: outcomes.first, artistName: artist))
        }
    }

    /// "More of this" / "Less of this" on a genre (8.7): the boost or reduce on the genre (no end date), and one replay is asked for so
    /// the pseudo-count on the genre's tag reaches the picks soon. False when the change could not be stored.
    func adjustGenre(_ name: String, more: Bool) async -> Bool {
        guard let change = BrainFeedback.genreChange(name: name, more: more) else { return false }
        let outcomes = await taste.apply([change])
        guard BrainFeedback.adjustmentId(of: outcomes.first) != nil else { return false }
        await brain.engine?.requestRebuild(force: true)
        return true
    }

    /// The one tap "Less trap" under an Ask Taizo explanation (docs/brain-spec.md, 9.3): the existing reduce on a genre or an artist, no bar
    /// and no model call. The taste change's id when it was stored (Undo takes it back with `undoTasteChange`), else nil.
    func lessLikeThis(kind: Int, name: String) async -> String? {
        let isGenre = kind == AssistantCards.namedGenre
        guard let change = isGenre ? BrainFeedback.genreChange(name: name, more: false) : BrainFeedback.lessFromChange(artistName: name) else {
            return nil
        }
        let outcomes = await taste.apply([change])
        guard let id = BrainFeedback.adjustmentId(of: outcomes.first) else { return nil }
        if isGenre { await brain.engine?.requestRebuild(force: true) }
        return id
    }

    /// Undo for `lessLikeThis`.
    func undoTasteChange(id: String) {
        taste.remove(id: id)
    }

    /// "Don't count this" (8.5): the song's plays leave what the picks are based on, now; the bar offers Undo.
    func dontCount(_ song: Song) {
        Task { [weak self] in
            guard let self else { return }
            let excluded = await self.brain.excludeSong(song)
            self.serial += 1
            self.show(BrainNotice.afterDontCount(serial: self.serial, excluded: excluded))
        }
    }

    /// "Don't count the last hour" (8.5).
    func dontCountLastHour() {
        let playing = playback.currentSongId
        Task { [weak self] in
            guard let self else { return }
            let excluded = await self.brain.excludeLastHour(playingSongId: playing)
            self.serial += 1
            self.show(BrainNotice.afterDontCount(serial: self.serial, excluded: excluded))
        }
    }

    /// Private session on or off (8.5). Off at every app start; the "Private" pill shows while it is on.
    func setPrivate(_ on: Bool) {
        guard on != isPrivate else { return }
        isPrivate = on
        brain.setPrivate(on)
        if on { PixlAccessibility.announce(BrainStrings.privatePillDescription) }
    }

    /// "Refresh picks" on the Autoplay line (8.4): the engine's upcoming picks are replaced by the next best ones.
    func refreshPicks() { autoplay?.refreshPicks() }

    /// "Mute X" on the bar after a "Less from X" (and after a second one): the artist leaves the picks.
    func muteNoticeArtist() {
        guard let notice, notice.canMute, let change = BrainFeedback.muteArtistChange(artistName: notice.artistName) else { return }
        let artist = notice.artistName
        Task { [weak self] in
            guard let self else { return }
            let outcomes = await self.taste.apply([change])
            self.serial += 1
            self.show(BrainNotice.afterMute(serial: self.serial, outcome: outcomes.first, artistName: artist))
        }
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
            // A second tap: the artist already is reduced, so nothing is stored and the bar offers to mute them.
            await self.taste.ensureLoaded()
            if BrainFeedback.isReduced(artistName: artistName, in: self.taste.activeAdjustments(nowMs: currentTimeMillis())) {
                self.serial += 1
                self.show(BrainNotice.alreadyReduced(serial: self.serial, artistName: artistName))
                return
            }
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
    let id: String
    /// The cards' tracks, in order: made known to the app before a play (`BrainService.register`).
    let tracks: [EngineTrack]
    let section: HomeMusicSection
    let tags: [String: BrainItemTag]

    /// "New from artists you play" (6.3): up to twelve fresh releases, each card with "New from <artist>" under it.
    static func make(release row: BrainReleaseRow, nowMs: Int64) -> BrainHomeShelf {
        var songs: [Song] = []
        var reasons: [(String, String)] = []
        songs.reserveCapacity(row.items.count)
        for item in row.items {
            let song = BrainService.queueSong(for: item.track, nowMs: nowMs)
            songs.append(song)
            if let line = row.cardReason(item) { reasons.append((song.id, BrainStrings.whyLine(line))) }
        }
        let section = HomeMusicSection(id: row.id, title: BrainStrings.homeNewReleases,
                                       subtitle: BrainStrings.homeNewReleasesSubtitle, songs: songs, reasons: reasons)
        return BrainHomeShelf(id: row.id, tracks: row.items.map(\.track), section: section, tags: row.tags())
    }

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
            return BrainHomeShelf(id: row.id, tracks: row.items.map(\.track), section: section, tags: row.tags())
        }
    }
}
