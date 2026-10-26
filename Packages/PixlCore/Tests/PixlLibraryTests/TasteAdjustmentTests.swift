import Foundation
import PixlFoundation
import PixlModel
import Testing
@testable import PixlLibrary

private typealias Engine = MusicRecommendationEngine
private typealias Signal = MusicRecommendationEngine.Signal
private typealias History = MusicRecommendationEngine.History

private let now: Int64 = 1_800_000_000_000
private let day: Int64 = 86_400_000

/// Ask Taizo's taste changes: the adjustment math, the list's rules, and the engine reading them.
@Suite struct TasteAdjustmentTests {
    // MARK: Fixtures

    /// Four artists with three songs each; "Aria" and "Beat" are played, "Cove" a little, "Dune" never.
    private func library() -> [Song] {
        let artists = [("Aria", "Pop"), ("Beat", "Hip-Hop"), ("Cove", "Rock; Indie"), ("Dune", "Jazz")]
        var songs: [Song] = []
        for (index, entry) in artists.enumerated() {
            for n in 1...3 {
                var s = testSong("\(entry.0.lowercased())\(n)", title: "\(entry.0) Song \(n)", artist: entry.0, genre: entry.1,
                                 album: "\(entry.0) Album", year: 1990 + index * 10 + n)
                s.artistId = Int64(index + 1)
                songs.append(s)
            }
        }
        return songs
    }

    private func history(_ songs: [Song]) -> [String: History] {
        var out: [String: History] = [:]
        for song in songs {
            switch song.artist {
            case "Aria": out[song.id] = History(plays: 20, listenedMs: 3_600_000, lastPlayedMs: now - 2 * day)
            case "Beat": out[song.id] = History(plays: 12, listenedMs: 2_000_000, lastPlayedMs: now - 3 * day)
            case "Cove": out[song.id] = History(plays: 2, listenedMs: 200_000, lastPlayedMs: now - 10 * day)
            default: break
            }
        }
        return out
    }

    private func rank(_ songs: [Song], adjustments: TasteAdjustmentSet = .empty) -> [Engine.Pick] {
        Engine.rank(songs: songs, favorites: [], signals: [:], history: history(songs), nowMs: now, seed: 7,
                    adjustments: adjustments)
    }

    private func change(_ action: TasteAction, _ type: TasteTargetType, _ target: String, strength: Int = 2,
                        days: Int? = nil, source: TasteAdjustmentSource = .taizo) -> TasteChange {
        TasteChange(action: action, targetType: type, key: type == .song ? target : TasteKey.of(target), label: target,
                    strength: strength, reason: "test", expiresDays: days, source: source)
    }

    private func set(_ changes: [TasteChange]) -> TasteAdjustmentSet {
        var list = TasteAdjustmentList()
        for c in changes { list.apply(c, nowMs: now) }
        return list.set(nowMs: now)
    }

    private func position(of artist: String, in picks: [Engine.Pick]) -> Int {
        picks.firstIndex { $0.song.artist == artist } ?? Int.max
    }

    // MARK: Zero adjustments change nothing

    @Test func noAdjustmentsGiveBitIdenticalRankings() {
        let songs = library()
        let plain = Engine.rank(songs: songs, favorites: [], signals: [:], history: history(songs), nowMs: now, seed: 7)
        let withEmpty = rank(songs)
        let expired = TasteAdjustmentSet(adjustments: [TasteAdjustment(kind: .block, strength: 0, targetType: .artist, key: "aria",
                                                                       label: "Aria", reason: "", source: .taizo,
                                                                       createdMs: now - 10 * day, expiresMs: now - day)], nowMs: now)
        #expect(expired.isEmpty)
        let withExpired = rank(songs, adjustments: expired)
        #expect(plain.map(\.song.id) == withEmpty.map(\.song.id))
        #expect(plain.map(\.score) == withEmpty.map(\.score))
        #expect(plain.map(\.score) == withExpired.map(\.score))
        #expect(plain.map(\.reason) == withExpired.map(\.reason))
    }

    @Test func anAdjustmentOnNothingTheLibraryHasChangesNothing() {
        let songs = library()
        let plain = rank(songs)
        let other = rank(songs, adjustments: set([change(.boost, .artist, "Nobody At All")]))
        #expect(plain.map(\.score) == other.map(\.score))
        #expect(plain.map(\.song.id) == other.map(\.song.id))
    }

    @Test func dailyMixAndPlannerAreUntouchedByAnEmptySet() {
        let songs = library()
        let engagements = Dictionary(uniqueKeysWithValues: history(songs).map {
            ($0.key, EngagementStats(playCount: $0.value.plays, totalPlayDurationMs: $0.value.listenedMs, lastPlayedTimestamp: $0.value.lastPlayedMs))
        })
        let a = DailyMix.personalizedPicks(allSongs: songs, favoriteSongIds: [], engagements: engagements, storedSignals: [:],
                                           nowMs: now, limit: 8, seed: 3)
        let b = DailyMix.personalizedPicks(allSongs: songs, favoriteSongIds: [], engagements: engagements, storedSignals: [:],
                                           nowMs: now, limit: 8, seed: 3, adjustments: .empty)
        #expect(a.map(\.song.id) == b.map(\.song.id) && a.map(\.score) == b.map(\.score))
        let planA = HomeRecommendationPlanner.plan(library: songs, favorites: [], signals: [:], history: history(songs), nowMs: now, seed: 5)
        let planB = HomeRecommendationPlanner.plan(library: songs, favorites: [], signals: [:], history: history(songs), nowMs: now, seed: 5,
                                                   adjustments: .empty)
        #expect(planA.shelves.map(\.songs).map { $0.map(\.id) } == planB.shelves.map(\.songs).map { $0.map(\.id) })
        #expect(planA.mixes.map(\.songs).map { $0.map(\.id) } == planB.mixes.map(\.songs).map { $0.map(\.id) })
    }

    // MARK: The ranking moves the right way

    @Test func boostMovesAnArtistUpAndReduceMovesItDown() {
        let songs = library()
        let base = rank(songs)
        let boosted = rank(songs, adjustments: set([change(.boost, .artist, "Dune", strength: 3), change(.boost, .genre, "Jazz")]))
        let reduced = rank(songs, adjustments: set([change(.reduce, .artist, "Aria")]))
        #expect(position(of: "Dune", in: boosted) < position(of: "Dune", in: base))
        #expect(position(of: "Aria", in: reduced) > position(of: "Aria", in: base))
        func score(_ id: String, _ picks: [Engine.Pick]) -> Double { picks.first { $0.song.id == id }!.score }
        #expect(score("dune1", boosted) > score("dune1", base))
        #expect(score("aria1", reduced) < score("aria1", base))
        #expect(boosted.first { $0.song.id == "dune1" }!.reason == "A boost you asked for")
        #expect(reduced.first { $0.song.id == "aria1" }!.reason.hasPrefix(Engine.reasonPrefixDemoted))
    }

    @Test func strongerStrengthsMoveFurther() {
        let songs = library()
        func score(_ strength: Int) -> Double {
            rank(songs, adjustments: set([change(.boost, .artist, "Cove", strength: strength)])).first { $0.song.id == "cove1" }!.score
        }
        #expect(score(1) < score(2) && score(2) < score(3))
        func down(_ strength: Int) -> Double {
            rank(songs, adjustments: set([change(.reduce, .artist, "Cove", strength: strength)])).first { $0.song.id == "cove1" }!.score
        }
        #expect(down(1) > down(2) && down(2) > down(3))
    }

    @Test func genreAlbumAndSongTargetsWork() {
        let songs = library()
        let base = rank(songs)
        func score(_ id: String, _ picks: [Engine.Pick]) -> Double { picks.first { $0.song.id == id }!.score }
        // "hip hop" finds "Hip-Hop"; "Rock; Indie" answers to both parts.
        let genre = rank(songs, adjustments: set([change(.boost, .genre, "hip hop")]))
        #expect(score("beat1", genre) > score("beat1", base) && score("aria1", genre) == score("aria1", base))
        let indie = rank(songs, adjustments: set([change(.boost, .genre, "Indie")]))
        #expect(score("cove2", indie) > score("cove2", base))
        let album = rank(songs, adjustments: set([change(.reduce, .album, "Beat Album")]))
        #expect(score("beat3", album) < score("beat3", base) && score("aria3", album) == score("aria3", base))
        let key = TasteKey.recording(songs.first { $0.id == "dune2" }!)
        let one = rank(songs, adjustments: set([change(.boost, .song, key)]))
        #expect(score("dune2", one) > score("dune2", base) && score("dune1", one) == score("dune1", base))
    }

    @Test func factorsMultiplyButStayInsideTheCap() {
        let songs = library()
        let many = set([change(.boost, .artist, "Dune", strength: 3), change(.boost, .genre, "Jazz", strength: 3),
                        change(.boost, .album, "Dune Album", strength: 3), change(.boost, .song, TasteKey.recording(songs.last!), strength: 3)])
        let evaluation = many.evaluate(songs.last!)
        #expect(evaluation.factor == TasteAdjustmentMath.maxFactor)
        let down = set([change(.reduce, .artist, "Dune", strength: 3), change(.reduce, .genre, "Jazz", strength: 3),
                        change(.reduce, .album, "Dune Album", strength: 3)])
        #expect(down.evaluate(songs.last!).factor == TasteAdjustmentMath.minFactor)
        // One adjustment alone never reaches the cap.
        #expect(TasteAdjustmentMath.factor(strength: 3) < TasteAdjustmentMath.maxFactor)
        #expect(1.0 / TasteAdjustmentMath.factor(strength: 3) > TasteAdjustmentMath.minFactor)
        #expect(TasteAdjustmentMath.strengthFactors == [1.25, 1.6, 2.2])
    }

    @Test func adjustedTasteIsStrictlyMonotoneInTheFactor() {
        for taste in stride(from: -1.0, through: 1.0, by: 0.25) {
            var previous = -Double.infinity
            for factor in [0.4, 0.5, 0.625, 0.8, 1.0, 1.25, 1.6, 2.2, 2.5] {
                let value = TasteAdjustmentMath.adjustedTaste(taste, factor: factor)
                #expect(value > previous)
                previous = value
            }
        }
        #expect(TasteAdjustmentMath.adjustedTaste(0.3, factor: 1.0) == 0.3)
    }

    @Test func muteAndBlockLeaveTheAutomaticPicksButNotTheLibrary() {
        let songs = library()
        let muted = rank(songs, adjustments: set([change(.mute, .artist, "Aria")]))
        #expect(!muted.contains { $0.song.artist == "Aria" } && muted.count == 9)
        let blocked = rank(songs, adjustments: set([change(.block, .genre, "Jazz")]))
        #expect(!blocked.contains { $0.song.artist == "Dune" } && blocked.count == 9)
        let adjustments = set([change(.mute, .artist, "Aria"), change(.block, .song, TasteKey.recording(songs.first { $0.id == "beat1" }!))])
        #expect(adjustments.isExcluded(songs.first { $0.id == "aria2" }!))
        #expect(!adjustments.isBlocked(songs.first { $0.id == "aria2" }!), "a mute is not a block")
        #expect(adjustments.isBlocked(songs.first { $0.id == "beat1" }!))
        #expect(adjustments.allowed(songs).count == 8)
        // The ranking is still a ranking: the others keep their relative order.
        let base = rank(songs).filter { $0.song.artist != "Aria" }
        #expect(muted.map(\.song.id) == base.map(\.song.id) && muted.map(\.score) == base.map(\.score))
        // The library itself is never touched.
        #expect(songs.count == 12)
    }

    @Test func mixesShelvesAndPoolsHonourMuteAndBlock() {
        let songs = library()
        let engagements = Dictionary(uniqueKeysWithValues: history(songs).map {
            ($0.key, EngagementStats(playCount: $0.value.plays, totalPlayDurationMs: $0.value.listenedMs, lastPlayedTimestamp: $0.value.lastPlayedMs))
        })
        let adjustments = set([change(.mute, .artist, "Aria"), change(.block, .artist, "Beat")])
        let picks = DailyMix.personalizedPicks(allSongs: songs, favoriteSongIds: [], engagements: engagements, storedSignals: [:],
                                               nowMs: now, limit: 12, seed: 3, adjustments: adjustments)
        #expect(picks.count == 6 && !picks.contains { $0.song.artist == "Aria" || $0.song.artist == "Beat" })
        let plan = HomeRecommendationPlanner.plan(library: songs, favorites: [], signals: [:], history: history(songs), nowMs: now, seed: 5,
                                                  adjustments: adjustments)
        let all = (plan.mixes + plan.shelves).flatMap(\.songs)
        #expect(!all.isEmpty && !all.contains { $0.artist == "Aria" || $0.artist == "Beat" })
        let smart = PremiumSmartPlaylistEngine.build(.discover, songs: songs, nowMs: now, seed: 1, limit: 12, adjustments: adjustments)
        #expect(!smart.songs.contains { $0.artist == "Aria" || $0.artist == "Beat" })
        let plus = Muselle2.select(songs: songs, favorites: [], signals: [:], history: history(songs), nowMs: now, seed: 1, limit: 12,
                                   adjustments: adjustments)
        #expect(!plus.contains { $0.artist == "Aria" || $0.artist == "Beat" })
    }

    @Test func prepareAheadSkipsMutedSongsAndFollowsBoosts() {
        var songs = library().map { song -> Song in
            var s = song
            s.dateAdded = now - 3 * day
            return s
        }
        songs[0].isFavorite = true
        let base = SingPrepareRanker.rank(SingPrepareInputs(songs: songs, nowMs: now), limit: 20)
        #expect(base.count == 12)
        let muted = TasteAdjustmentSet(adjustments: [TasteAdjustment(kind: .mute, strength: 0, targetType: .artist, key: "dune", label: "Dune",
                                                                     reason: "", source: .taizo, createdMs: now)], nowMs: now)
        let withMute = SingPrepareRanker.rank(SingPrepareInputs(songs: songs, adjustments: muted, nowMs: now), limit: 20)
        #expect(withMute.count == 9 && !withMute.contains { $0.song.artist == "Dune" })
        let boost = TasteAdjustmentSet(adjustments: [TasteAdjustment(kind: .boost, strength: 3, targetType: .artist, key: "dune", label: "Dune",
                                                                     reason: "", source: .taizo, createdMs: now)], nowMs: now)
        let withBoost = SingPrepareRanker.rank(SingPrepareInputs(songs: songs, adjustments: boost, nowMs: now), limit: 20)
        let before = base.first { $0.song.id == "dune1" }!.score, after = withBoost.first { $0.song.id == "dune1" }!.score
        #expect(after > before)
        #expect(SingPrepareRanker.rank(SingPrepareInputs(songs: songs, adjustments: .empty, nowMs: now), limit: 20).map(\.score) == base.map(\.score))
    }

    // MARK: The list

    @Test func theListReplacesPerTargetAndChannelAndExpires() {
        var list = TasteAdjustmentList()
        guard case .set(let first, let replaced) = list.apply(change(.boost, .artist, "Aria", strength: 1), nowMs: now) else {
            Issue.record("expected a set")
            return
        }
        #expect(replaced == nil && first.strength == 1 && first.kind == .boost && first.source == .taizo)
        // A reduce replaces the boost (same channel); a mute sits next to it (other channel).
        guard case .set(let second, let was) = list.apply(change(.reduce, .artist, "aria", strength: 3), nowMs: now) else {
            Issue.record("expected a set")
            return
        }
        #expect(was?.kind == .boost && second.kind == .reduce && second.id == first.id)
        list.apply(change(.mute, .artist, "ARIA"), nowMs: now)
        #expect(list.items.count == 2)
        // Mute → block replaces; unmute does nothing to a block.
        list.apply(change(.block, .artist, "Aria"), nowMs: now)
        #expect(list.items.count == 2 && list.items.contains { $0.kind == .block })
        #expect(list.apply(change(.unmute, .artist, "Aria"), nowMs: now) == .nothingToRemove)
        if case .removed(let gone) = list.apply(change(.unblock, .artist, "Aria"), nowMs: now) { #expect(gone.kind == .block) } else { Issue.record("expected removal") }
        #expect(list.items.count == 1)
        // Expiry.
        list.apply(change(.boost, .genre, "Jazz", days: 3), nowMs: now)
        #expect(list.active(nowMs: now + 2 * day).count == 2)
        #expect(list.active(nowMs: now + 4 * day).count == 1)
        #expect(list.set(nowMs: now + 4 * day).evaluate(library().last!).factor == 1.0)
        #expect(list.prune(nowMs: now + 4 * day) && list.items.count == 1)
        // Days are clamped to a year; strengths to 1…3; reasons are cleaned.
        var clamped = TasteAdjustmentList()
        guard case .set(let item, _) = clamped.apply(TasteChange(action: .boost, targetType: .genre, key: "pop", label: "Pop", strength: 9,
                                                                 reason: "  too\n many   spaces " + String(repeating: "x", count: 400),
                                                                 expiresDays: 9_999), nowMs: now) else {
            Issue.record("expected a set")
            return
        }
        #expect(item.strength == 3 && item.expiresMs == now + 365 * day)
        #expect(item.reason.count == TasteAdjustmentMath.maxReasonLength && item.reason.hasPrefix("too many spaces"))
    }

    @Test func removeAndClearAndTheListLimit() {
        var list = TasteAdjustmentList()
        for index in 0..<TasteAdjustmentList.maxItems { list.apply(change(.boost, .artist, "Artist \(index)"), nowMs: now) }
        #expect(list.items.count == TasteAdjustmentList.maxItems)
        #expect(list.apply(change(.boost, .artist, "One More"), nowMs: now) == .listFull)
        // Changing an existing one still works when full.
        if case .set = list.apply(change(.reduce, .artist, "Artist 3"), nowMs: now) {} else { Issue.record("an existing target can change") }
        let id = list.items[5].id
        #expect(list.remove(id: id) && !list.remove(id: id))
        #expect(list.removeAll() == TasteAdjustmentList.maxItems - 1 && list.items.isEmpty)
    }

    @Test func theListSurvivesTheCodec() {
        var list = TasteAdjustmentList()
        list.apply(change(.boost, .artist, "Daft Punk", strength: 3, days: 30), nowMs: now)
        list.apply(change(.mute, .genre, "Jazz", source: .user), nowMs: now)
        let decoded = TasteAdjustmentList.decode(list.encoded())
        #expect(decoded == list)
        #expect(TasteAdjustmentList.decode(Data("not json".utf8)).items.isEmpty)
    }

    // MARK: Keys and resolving

    @Test func keysFoldCaseDiacriticsAndPunctuation() {
        #expect(TasteKey.of("AC/DC") == "acdc" && TasteKey.of("Beyoncé") == "beyonce" && TasteKey.of(" Hip-Hop ") == "hiphop")
        #expect(TasteKey.of("") == "")
        var song = testSong("x", title: "Get Lucky", artist: "Daft Punk feat. Pharrell Williams")
        song.genre = "R&B/Soul"
        #expect(TasteKey.artists(song).contains("daftpunk") && TasteKey.artists(song).contains("pharrellwilliams"))
        #expect(TasteKey.genres(song).contains("rbsoul") && TasteKey.genres(song).contains("rb") && TasteKey.genres(song).contains("soul"))
        #expect(TasteKey.recording(song) == "daftpunkfeatpharrellwilliams|getlucky")
    }

    @Test func resolverFindsIdsNamesAndExplainsMisses() {
        let songs = library()
        func resolved(_ type: TasteTargetType, _ target: String) -> TasteTargetResolver.Resolved? {
            if case .success(let r) = TasteTargetResolver.resolve(type: type, target: target, songs: songs) { return r }
            return nil
        }
        #expect(resolved(.artist, "aria")?.key == "aria" && resolved(.artist, "aria")?.songCount == 3)
        #expect(resolved(.artist, "aria1")?.label == "Aria", "a song id names its artist")
        #expect(resolved(.artist, "Someone Outside")?.inLibrary == false, "artists from outside the library are allowed")
        #expect(resolved(.song, "dune2")?.key == "dune|dunesong2")
        #expect(resolved(.song, "Dune Song 3")?.key == "dune|dunesong3")
        #expect(resolved(.genre, "hip hop")?.label == "Hip-Hop")
        #expect(resolved(.genre, "rock")?.label == "Rock; Indie", "a part of a multi-genre tag")
        #expect(resolved(.album, "cove album")?.songCount == 3)
        if case .failure(let failure) = TasteTargetResolver.resolve(type: .genre, target: "polka", songs: songs) {
            #expect(failure.message.contains("Pop") && failure.message.contains("polka"))
        } else { Issue.record("polka is not in the library") }
        if case .failure(let failure) = TasteTargetResolver.resolve(type: .song, target: "Song", songs: songs) {
            #expect(failure.message.contains("several"))
        } else { Issue.record("\"Song\" is ambiguous") }
        if case .failure(let failure) = TasteTargetResolver.resolve(type: .album, target: "Nope", songs: songs) {
            #expect(failure == .noSuchAlbum("Nope"))
        } else { Issue.record("no such album") }
        if case .failure(.empty) = TasteTargetResolver.resolve(type: .artist, target: "  ", songs: songs) {} else { Issue.record("empty") }
    }
}
