import Foundation
import Observation
import PixlLibrary
import PixlModel

// What Home shows when the music brain owns it (docs/brain-spec.md, 8.1): the hero, Jump back in and the shelves of the saved
// plan, in the plan's order. Every decision is made in PixlLibrary (`HomePlanBuilder`, `HomePlanner`); this file only turns the
// plan into what the views draw. A port of Android's `HomePlanStateHolder`.

/// A made-for-you list as Home draws it.
nonisolated struct MixCardUi: Identifiable, Equatable, Sendable {
    let mixId: String
    let kind: Int32
    /// 1..K for a Daily Mix of an island; 0 otherwise.
    let number: Int
    let title: String
    let subtitle: String
    let count: Int
    let covers: [String]
    var id: String { mixId }
}

nonisolated struct StationCardUi: Identifiable, Equatable, Sendable {
    let kind: Int
    let atlasId: Int
    let name: String
    let count: Int
    let covers: [String]
    var id: String { "\(kind):\(atlasId)" }
}

/// One thing on the page, in the order the plan gives.
nonisolated enum HomeShelfUi: Identifiable, Equatable, Sendable {
    /// A shelf of songs: drawn by the existing shelf component.
    case tracks(BrainHomeShelf)
    /// "Made for you": the lists as cards.
    case mixes(id: String, title: String, subtitle: String, cards: [MixCardUi])
    case stations(id: String, title: String, subtitle: String, cards: [StationCardUi])

    var id: String {
        switch self {
        case .tracks(let shelf): shelf.id
        case .mixes(let id, _, _, _): id
        case .stations(let id, _, _, _): id
        }
    }
}

nonisolated struct HeroUi: Equatable, Sendable {
    let kind: Int32
    let title: String
    let subtitle: String
    let art: String?
    let mixId: String
    /// For a release: the one-song shelf it plays.
    let release: BrainHomeShelf?
}

/// A "Jump back in" tile: a place the listener played from (8.1).
nonisolated struct TileUi: Identifiable, Equatable, Sendable {
    let key: String
    let title: String
    let art: String?
    let kind: Int
    let mixId: String
    let songIds: [String]
    var id: String { key }
}

/// What Home shows. `owned` is false until a plan is read or built; Home never shows a spinner or an empty state for it: without
/// a plan it shows Jump back in and the library rows (8.1, 8.10).
nonisolated struct HomePlanUi: Equatable, Sendable {
    var owned = false
    var dateLine = ""
    var hero: HeroUi?
    var shelves: [HomeShelfUi] = []
    var tiles: [TileUi] = []
    /// Every made-for-you card, for the "Mixes" chip.
    var allMixes: [MixCardUi] = []
    /// The "New" chip: just dropped, First Listen and the releases.
    var newShelves: [HomeShelfUi] = []
    /// "Getting to know your music · done of total" (8.10); total 0 hides the strip.
    var knowingDone = 0
    var knowingTotal = 0
    /// A thin library with no picked artists yet: Home offers "Pick three artists you love".
    var offerPicker = false
}

@MainActor @Observable
final class HomePlanState {
    private(set) var ui = HomePlanUi()

    /// Whether the brain engine switch is on, read at the moment it matters.
    @ObservationIgnored var engineIsOn: () -> Bool = { true }
    @ObservationIgnored var librarySongs: ([String]) -> [String: Song] = { _ in [:] }
    @ObservationIgnored var librarySongCount: () -> Int = { 0 }
    /// Makes tracks from outside the library known to the app before a play (7.2).
    @ObservationIgnored var register: ([EngineTrack]) -> Void = { _ in }
    /// Waits out the app's first seconds: the brain is touched after it (12.1).
    @ObservationIgnored var quiet: () async -> Void = {}
    @ObservationIgnored var store: HomePlanStore?
    @ObservationIgnored var builder: HomePlanBuilder?
    @ObservationIgnored var mixes: BrainMixes?
    @ObservationIgnored var recent: RecentContexts?
    @ObservationIgnored var coldStart: ColdStart?
    @ObservationIgnored var picked: PickedArtists?

    @ObservationIgnored private var current: HomePlan?
    @ObservationIgnored private var pending: HomePlan?
    @ObservationIgnored private var readOnce = false
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var coldTask: Task<Void, Never>?

    /// A library with fewer songs than this is "thin": it gets the artist picker (8.10).
    static let thinLibrary = 30
    static let tileCount = 6

    /// True when the brain owns Home: the engine is on and a plan is saved. Reads the saved plan if it was not read yet (one small
    /// file); never loads the brain.
    func ownsHome() async -> Bool {
        guard engineIsOn(), let store else { return false }
        if !readOnce {
            readOnce = true
            current = await store.read()
        }
        return current != nil
    }

    /// Home appeared. Reads the saved plan the first time (one small file) and shows it; on a later appearance shows the plan that
    /// was built meanwhile. Then, once the first seconds have passed, plans again if the day, the daypart or the taste changed.
    func onHomeShown() {
        guard let store else { return }
        Task { [weak self] in
            guard let self else { return }
            guard self.engineIsOn() else {
                if self.ui.owned { self.ui.owned = false }
                return
            }
            if !self.readOnce {
                self.readOnce = true
                self.current = await store.read()
            } else if let next = self.pending {
                self.current = next
                self.pending = nil
            }
            await self.publish(self.current)
            self.scheduleBuild()
            self.scheduleColdStart()
        }
    }

    /// Taste changed (a boost, a mute, "Not for me"): plan again at the next quiet moment.
    func invalidate() { scheduleBuild(force: true) }

    /// The listener picked artists: build from them now.
    func onArtistsPicked() {
        ui.offerPicker = false
        scheduleBuild(force: true)
    }

    private func scheduleBuild(force: Bool = false) {
        guard buildTask == nil, let builder, let mixes else { return }
        buildTask = Task { [weak self] in
            // No brain work in the first seconds of the process (12.1): Home has already painted from the file.
            await self?.quiet()
            let now = currentTimeMillis()
            let taste = await mixes.tasteSignature()
            guard let self else { return }
            let saved = self.pending ?? self.current
            let due = await builder.isDue(saved, nowMs: now, taste: taste)
            if force || due, let built = await builder.build() {
                if self.current == nil {
                    // Nothing on screen to change under the thumb: show it at once.
                    self.current = built
                    await self.publish(built)
                } else {
                    self.pending = built
                }
            }
            self.buildTask = nil
        }
    }

    /// The first minute of a new listener (8.10): with no plan yet, eight radios for the day's seeds, then a plan. Only with the
    /// engine on and a library to read, once the first seconds have passed. A thin library is offered the artist picker instead
    /// of waiting.
    private func scheduleColdStart() {
        guard coldTask == nil, current == nil, let coldStart else { return }
        coldTask = Task { [weak self] in
            await self?.quiet()
            guard let self, self.engineIsOn() else { self?.coldTask = nil; return }
            let songs = self.librarySongCount()
            let hasPicks = await self.picked?.hasPicks() ?? false
            self.ui.offerPicker = songs < Self.thinLibrary && !hasPicks
            if songs > 0 {
                await coldStart.run { [weak self] progress in
                    Task { @MainActor in
                        self?.ui.knowingDone = progress?.done ?? 0
                        self?.ui.knowingTotal = progress?.total ?? 0
                    }
                }
            }
            // Whatever came back is the first thing a plan can be made from.
            self.coldTask = nil
            self.scheduleBuild(force: true)
        }
    }

    /// A queue was started: a made-for-you list is a place to jump back to (8.1). The file is written off the main actor.
    func noteQueue(songs: [Song], source: BrainItemTag?, tags: [String: BrainItemTag]) {
        guard let recent, engineIsOn() else { return }
        let tag = source ?? songs.first.flatMap { tags[$0.id] }
        guard let surface = tag?.surface, let surfaceId = tag?.surfaceId, !surfaceId.isEmpty,
              surface == Surface.nameOf(Surface.dailyMix) || surface == Surface.nameOf(Surface.yourMix)
                || surface == Surface.nameOf(Surface.namedMix),
              let spec = MixSpec.of(surfaceId: surfaceId) else { return }
        let title = ui.allMixes.first(where: { $0.mixId == surfaceId })?.title ?? Self.title(of: spec)
        let ids = songs.map { $0.id }.filter { !$0.hasPrefix(EngineTrack.songIdPrefix) }
        let art = songs.first(where: { !($0.albumArtUriString ?? "").isEmpty })?.albumArtUriString
        guard let context = RecentContexts.contextOf(queueName: title, playlistId: nil, surface: surface, surfaceId: surfaceId,
                                                     songIds: ids, art: art, nowMs: currentTimeMillis()) else { return }
        Task { await recent.note(context) }
    }

    nonisolated static func title(of spec: MixSpec) -> String {
        switch spec.kind {
        case MixKinds.daily: BrainStrings.mixDaily
        case MixKinds.your: BrainStrings.mixYour
        case MixKinds.firstListen: BrainStrings.mixFirstListen
        case MixKinds.justDropped: BrainStrings.mixJustDropped
        case MixKinds.onRepeat: BrainStrings.mixOnRepeat
        default: BrainStrings.mixRediscover
        }
    }

    // MARK: The plan as the screen draws it

    private func publish(_ plan: HomePlan?) async {
        let tiles = await tiles()
        guard let plan else {
            // Without a plan: Jump back in and the library rows. The brain owns Home only once there is one.
            var next = ui
            next.owned = false
            next.tiles = tiles
            if next != ui { ui = next }
            return
        }
        var ids = Set<String>()
        for shelf in plan.shelves { for item in shelf.items { if let id = item.songId { ids.insert(id) } } }
        if let id = plan.hero?.item?.songId { ids.insert(id) }
        let songs = librarySongs(Array(ids))
        let now = currentTimeMillis()
        let rendered = await Self.render(plan, tiles: tiles, library: songs, nowMs: now)
        var next = ui
        next.owned = true
        next.dateLine = rendered.dateLine
        next.hero = rendered.hero
        next.shelves = rendered.shelves
        next.tiles = rendered.tiles
        next.allMixes = rendered.allMixes
        next.newShelves = rendered.newShelves
        if next != ui { ui = next }
        let outside = rendered.shelves.compactMap { shelf -> [EngineTrack]? in
            if case .tracks(let s) = shelf { return s.tracks }
            return nil
        }.flatMap { $0 }
        if !outside.isEmpty { register(outside) }
        if let release = rendered.hero?.release { register(release.tracks) }
    }

    private func tiles() async -> [TileUi] {
        guard let recent else { return [] }
        return await recent.tiles(count: Self.tileCount).map {
            TileUi(key: $0.key, title: $0.title, art: $0.art, kind: $0.kind, mixId: $0.mixId, songIds: $0.songIds)
        }
    }

    struct Rendered: Sendable {
        var dateLine: String
        var hero: HeroUi?
        var shelves: [HomeShelfUi]
        var tiles: [TileUi]
        var allMixes: [MixCardUi]
        var newShelves: [HomeShelfUi]
    }

    @concurrent
    nonisolated static func render(_ plan: HomePlan, tiles: [TileUi], library: [String: Song], nowMs: Int64) async -> Rendered {
        var shelves: [HomeShelfUi] = []
        for shelf in plan.shelves {
            if !shelf.mixes.isEmpty {
                shelves.append(.mixes(id: shelf.id, title: text(shelf.titleKey, shelf.titleArg), subtitle: text(shelf.subtitleKey, ""),
                                      cards: shelf.mixes.map(mixCard)))
            } else if !shelf.stations.isEmpty {
                shelves.append(.stations(id: shelf.id, title: text(shelf.titleKey, shelf.titleArg),
                                         subtitle: text(shelf.subtitleKey, shelf.titleArg),
                                         cards: shelf.stations.map { StationCardUi(kind: $0.kind, atlasId: $0.atlasId, name: $0.name, count: $0.count, covers: $0.covers) }))
            } else {
                var songs: [Song] = []
                var reasons: [(String, String)] = []
                var tags: [String: BrainItemTag] = [:]
                var tracks: [EngineTrack] = []
                for item in shelf.items {
                    let song: Song
                    if let id = item.songId {
                        guard let found = library[id] else { continue }
                        song = found
                    } else if let row = item.row {
                        let track = EngineTrack(row: row.row, rid: row.rid)
                        tracks.append(track)
                        song = BrainService.queueSong(for: track, nowMs: nowMs)
                    } else {
                        continue
                    }
                    songs.append(song)
                    if let line = reason(item) { reasons.append((song.id, line)) }
                    tags[song.id] = tag(shelf, item)
                }
                if songs.isEmpty { continue }
                let section = HomeMusicSection(id: shelf.id, title: text(shelf.titleKey, shelf.titleArg),
                                               subtitle: text(shelf.subtitleKey, shelf.titleArg), songs: songs, reasons: reasons)
                shelves.append(.tracks(BrainHomeShelf(id: shelf.id, tracks: tracks, section: section, tags: tags)))
            }
        }
        let cards = plan.mixes.map(mixCard)
        var hero: HeroUi?
        if let h = plan.hero { hero = Self.hero(h, plan: plan, library: library, nowMs: nowMs) }
        let newShelves: [HomeShelfUi] = shelves.compactMap { shelf in
            switch shelf {
            case .tracks(let s): return s.id.hasPrefix("new_from_loved") || s.id == BrainReleaseRow.id ? shelf : nil
            case .mixes(let id, let title, let subtitle, let cards):
                let fresh = cards.filter { $0.kind == MixKinds.firstListen || $0.kind == MixKinds.justDropped }
                return fresh.isEmpty ? nil : .mixes(id: id, title: title, subtitle: subtitle, cards: fresh)
            case .stations: return nil
            }
        }
        return Rendered(dateLine: dateLine(plan), hero: hero, shelves: shelves, tiles: tiles, allMixes: cards, newShelves: newShelves)
    }

    nonisolated static func dateLine(_ plan: HomePlan) -> String {
        let symbols = Calendar.current.weekdaySymbols
        let day = symbols[(Int(plan.weekday) + 1) % 7]
        return "\(day) \(BrainStrings.daypart(plan.daypart))"
    }

    nonisolated private static func hero(_ h: PlanHero, plan: HomePlan, library: [String: Song], nowMs: Int64) -> HeroUi? {
        switch h.kind {
        case HomePlanner.heroFirstListen, HomePlanner.heroDaily:
            guard let m = plan.mixes.first(where: { $0.mixId == h.mixId }) else { return nil }
            let card = mixCard(m)
            return HeroUi(kind: h.kind, title: card.title, subtitle: card.subtitle, art: card.covers.first, mixId: m.mixId, release: nil)
        case HomePlanner.heroRelease:
            guard let item = h.item else { return nil }
            var tracks: [EngineTrack] = []
            let song: Song
            if let row = item.row {
                let track = EngineTrack(row: row.row, rid: row.rid)
                tracks.append(track)
                song = BrainService.queueSong(for: track, nowMs: nowMs)
            } else if let id = item.songId, let found = library[id] {
                song = found
            } else {
                return nil
            }
            let artist = h.artistName.isEmpty ? song.artist : h.artistName
            let section = HomeMusicSection(id: "hero_release", title: song.title, subtitle: "", songs: [song], reasons: [])
            let shelf = BrainHomeShelf(id: "hero_release", tracks: tracks, section: section,
                                       tags: [song.id: tag(PlanShelf(type: HomePlanner.newFromLoved, id: "hero_release", titleKey: ""), item)])
            return HeroUi(kind: h.kind, title: song.title, subtitle: BrainStrings.whyLine(.newRelease(artist)), art: song.albumArtUriString,
                          mixId: "", release: shelf)
        default:
            return nil
        }
    }

    nonisolated private static func mixCard(_ m: PlanMix) -> MixCardUi {
        let title: String
        switch m.kind {
        case MixKinds.daily: title = m.number > 0 ? BrainStrings.mixDailyNumber(m.number) : BrainStrings.mixDaily
        case MixKinds.your: title = BrainStrings.mixYour
        case MixKinds.firstListen: title = BrainStrings.mixFirstListen
        case MixKinds.justDropped: title = BrainStrings.mixJustDropped
        case MixKinds.onRepeat: title = BrainStrings.mixOnRepeat
        default: title = BrainStrings.mixRediscover
        }
        let subtitle: String
        if m.kind == MixKinds.firstListen {
            subtitle = BrainStrings.mixFirstListenWeek(weekOf(m.builtAtMs))
        } else if !m.subtitle.isEmpty {
            subtitle = m.subtitle
        } else if m.kind == MixKinds.your {
            subtitle = BrainStrings.mixYourSubtitle
        } else if m.kind == MixKinds.justDropped {
            subtitle = BrainStrings.mixJustDroppedSubtitle
        } else {
            subtitle = ""
        }
        return MixCardUi(mixId: m.mixId, kind: m.kind, number: m.number, title: title, subtitle: subtitle, count: m.count, covers: m.covers)
    }

    /// "16 Nov": the Monday of the week the list was built in (it is fixed all week, 8.2).
    nonisolated private static func weekOf(_ builtAtMs: Int64) -> String {
        let calendar = Calendar.current
        let built = Date(timeIntervalSince1970: TimeInterval(builtAtMs - 4 * 3_600_000) / 1000)
        let weekday = calendar.component(.weekday, from: built) // Sunday is 1
        let sinceMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -sinceMonday, to: built) ?? built
        return monday.formatted(.dateTime.day().month(.abbreviated))
    }

    nonisolated private static func text(_ key: String, _ arg: String) -> String {
        switch key {
        case "": ""
        case "made_for_you": BrainStrings.homeMadeForYou
        case "because_listened": BrainStrings.homeBecauseListened(arg)
        case "because_listened_subtitle": BrainStrings.homeBecauseListenedSubtitle
        case "new_from_loved": BrainStrings.homeNewFromLoved
        case "new_from_loved_subtitle": BrainStrings.homeNewFromLovedSubtitle
        case "on_repeat": BrainStrings.mixOnRepeat
        case "on_repeat_subtitle": BrainStrings.homeOnRepeatSubtitle
        case "rediscover": BrainStrings.mixRediscover
        case "rediscover_subtitle": BrainStrings.homeRediscoverSubtitle
        case "stations": BrainStrings.homeStations
        case "stations_subtitle": BrainStrings.homeStationsSubtitle
        case "step_sideways": BrainStrings.homeStepSideways
        case "step_sideways_subtitle": BrainStrings.homeStepSidewaysSubtitle(arg)
        case "more_like_album": BrainStrings.homeMoreLikeAlbum(arg)
        case "more_like_album_subtitle": BrainStrings.homeMoreLikeAlbumSubtitle
        default: ""
        }
    }

    nonisolated private static func reason(_ item: PlanItem) -> String? {
        let name = item.whyName
        switch item.whyKey {
        case WhyLine.radioFans: return name.isEmpty ? nil : BrainStrings.whyLine(.radioFans(name))
        case WhyLine.artistMore: return name.isEmpty ? nil : BrainStrings.whyLine(.artistMore(name))
        case WhyLine.newRelease: return name.isEmpty ? nil : BrainStrings.whyLine(.newRelease(name))
        case WhyLine.adjacentGenre: return BrainStrings.whyAdjacentGenre
        default: return nil
        }
    }

    nonisolated private static func tag(_ shelf: PlanShelf, _ item: PlanItem) -> BrainItemTag {
        BrainItemTag(surface: Surface.nameOf(Surface.homeShelf), surfaceId: shelf.id, recId: shelf.recId, slot: item.slot,
                     arm: Arm.nameOf(item.arm), whyArg: item.whyName.isEmpty ? nil : item.whyName,
                     whyKey: item.whyKey != WhyLine.none ? WhyLine.nameOf(item.whyKey) : nil,
                     primaryArtist: item.row?.row.artists.first?.name,
                     // The listener chose to play the shelf: its tracks are theirs, like a playlist's.
                     chosen: true)
    }
}
