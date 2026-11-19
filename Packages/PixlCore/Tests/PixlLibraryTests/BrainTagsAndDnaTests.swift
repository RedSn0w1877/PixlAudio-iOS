import Foundation
import PixlBackup
import Testing
@testable import PixlLibrary

/// The genre atlas asset, the tag vector (3.4) and the track DNA functions (3.2, 3.3, 3.5), checked by hand-worked cases on
/// the real atlas. Ports of Android's `AtlasTest`, `TagsAndDnaTest` and `TagFeaturesTest`.
@Suite("Brain atlas, tags and DNA")
struct BrainTagsAndDnaTests {
    let atlas = KnowledgeFixtures.atlas

    func id(_ name: String) -> Int {
        let v = atlas.idForName(name)
        #expect(v != GenreAtlas.none, "\(name)")
        return v
    }

    func input(_ source: Int, _ name: String, _ conf: Double = 1.0) -> Tags.Input { Tags.Input(source: source, atlasId: id(name), conf: conf) }

    func vec(_ names: String...) -> Tags.Vector {
        Tags.merge(atlas, names.map { Tags.Input(source: Tags.srcRecording, atlasId: atlas.idForName($0), conf: 1.0) })
    }

    // MARK: AtlasTest

    @Test func theAssetIsAGzipOfAboutTheSizeTheSpecEstimates() throws {
        let gz = [UInt8](try BrainGoldenTests.fixtureData("genre-atlas-v1.json.gz"))
        #expect((100_000...260_000).contains(gz.count), "gzip bytes \(gz.count)")
        #expect(gz[0] == 0x1f && gz[1] == 0x8b)
        // mtime 0 in the header: the build is reproducible byte for byte.
        for i in 4...7 { #expect(gz[i] == 0) }
    }

    @Test func theAppBundlesTheSameBytesAndroidShips() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/genre-atlas-v1.json.gz")
        let bytes = [UInt8](try Data(contentsOf: app))
        #expect(SHA256.hex(bytes) == BrainStage2bGoldenTests.atlasSha256, "App/Resources holds another atlas than the one the golden files read")
    }

    @Test func everyMusicBrainzGenreIsInAndIdsAreUniqueAndSmall() {
        #expect(atlas.size >= 2200)
        #expect((atlas.allIds.last ?? 0) < 32000)
        #expect(Set(atlas.allIds).count == atlas.allIds.count)
        #expect(atlas.families.count == 24)
        #expect((30...50).contains(atlas.moods.count))
    }

    @Test func parentsFormNoLoop() {
        for id in atlas.allIds {
            let up = atlas.ancestors(id)
            #expect(!up.contains(id), "genre \(id) is its own ancestor")
            #expect(Set(up).count == up.count)
        }
    }

    @Test func descriptorsAreInRange() {
        var described = 0
        for id in atlas.allIds {
            guard let g = atlas.genre(id), let d = g.descriptor else { continue }
            described += 1
            for v in [d.energy, d.valence, d.danceability, d.acousticness] { #expect((0...255).contains(v), "genre \(id)") }
            #expect((30...320).contains(d.tempoLo) && d.tempoHi >= d.tempoLo, "genre \(id) tempo")
            #expect(d.moods.count <= 4)
            for m in d.moods { #expect(atlas.moods.indices.contains(m)) }
            #expect(g.depth >= 0)
        }
        #expect(described > 1000, "described \(described)")
    }

    @Test func theSpecsOwnGenresAreThere() {
        for n in ["shoegaze", "k-pop", "v-pop", "vinahouse", "hip hop", "trap", "bedroom pop", "city pop", "nhạc vàng", "vietnamese hip hop"] {
            #expect(atlas.idForName(n) != GenreAtlas.none, "\(n)")
        }
        // Names and aliases fold the same way: case, accents, spacing and hyphens do not matter.
        #expect(atlas.idForName("K-Pop") == atlas.idForName("k pop"))
        #expect(atlas.idForName("Nhạc Vàng") == atlas.idForName("nhac vang"))
        #expect(atlas.idForName("Hip-Hop") == atlas.idForName("hip hop"))
        #expect(atlas.idForName("not a genre at all") == GenreAtlas.none)
        #expect(atlas.idForName("") == GenreAtlas.none)
    }

    @Test func aSourceTableMarksWhatIsNotAGenreAndNeverGuesses() {
        #expect(atlas.idsForSource("deezer", "All")?.count == 0)
        #expect(atlas.idsForSource("itunes", "Holiday")?.count == 0)
        // "Kids" is not a genre however its words look: resolve stays empty.
        #expect(atlas.resolve("deezer", "Kids").isEmpty)
        #expect(atlas.idsForSource("deezer", "zzz") == nil)
        #expect(atlas.resolve("deezer", "zzz").isEmpty)
        #expect(atlas.resolve("deezer", "Rap/Hip Hop") == [atlas.idForName("hip hop")])
        #expect(atlas.resolve("itunes", "R&B/Soul").count == 2)
    }

    @Test func theVietnameseAndKoreanCornerIsCurated() throws {
        let vh = try #require(atlas.genre(atlas.idForName("vietnamese hip hop")))
        #expect(vh.mbid == "")
        #expect(vh.parents.contains(atlas.idForName("hip hop")))
        #expect(atlas.idForName("rap việt") != GenreAtlas.none)
        #expect(atlas.idForName("vietnamese hip hop") == atlas.idForName("viet rap"))
        #expect(atlas.idForName("korean hip hop") == atlas.idForName("k-rap"))
        #expect(atlas.idForName("k-pop") == atlas.idForName("k-pop girl group"))
        #expect(atlas.idForName("v-pop") == atlas.idForName("nhạc trẻ"))
    }

    @Test func aDescendantWithoutItsOwnDescriptorInheritsOne() throws {
        let trap = try #require(atlas.genre(atlas.idForName("trap")))
        #expect(trap.descriptor != nil)
        let inherited = atlas.allIds.filter { atlas.genre($0).map { $0.descriptor != nil && $0.description.isEmpty } ?? false }.count
        #expect(inherited > 500, "inherited \(inherited)")
    }

    @Test func anEmptyAtlasLoadsAndHasNothing() throws {
        let empty = try GenreAtlas.parse(utf8: Array(#"{"v":1,"fam":[],"moods":[],"g":[]}"#.utf8))
        #expect(empty.size == 0)
        #expect(empty.idForName("pop") == GenreAtlas.none)
    }

    @Test func theTextOfASourceTableIsReadInTheOrderOfTheFile() throws {
        // Two names that fold alike: the first of the file keeps the key, as on Android.
        let json = #"{"v":1,"fam":[],"moods":[],"g":[{"i":1,"n":"a"},{"i":2,"n":"b"}],"src":{"x":{"Hip-Hop":[1],"hip hop":[2]}}}"#
        let a = try GenreAtlas.parse(utf8: Array(json.utf8))
        #expect(a.idsForSource("x", "HIP HOP") == [1])
    }

    // MARK: TagsAndDnaTest

    @Test func noClaimsIsUnknownNeverAGuess() {
        #expect(Tags.merge(atlas, []).isEmpty)
        // One weak source alone stays under the 0.25 floor: 0.25 * 0.5 = 0.125.
        #expect(Tags.merge(atlas, [input(Tags.srcAssistant, "pop", 0.5)]).isEmpty)
        // An id the atlas does not have, and a source that does not exist, are ignored.
        #expect(Tags.merge(atlas, [Tags.Input(source: 1, atlasId: 31000, conf: 1.0), Tags.Input(source: 11, atlasId: id("pop"), conf: 1.0)]).isEmpty)
    }

    @Test func agreementRaisesAWeightAndTheVectorIsUnitLengthBeforeQuantising() {
        let one = Tags.merge(atlas, [input(Tags.srcRecording, "shoegaze")])
        #expect(one.top == id("shoegaze"))
        let two = Tags.merge(atlas, [input(Tags.srcRecording, "shoegaze"), input(Tags.srcArtist, "shoegaze"), input(Tags.srcRecording, "dream pop", 0.3)])
        #expect(two.top == id("shoegaze"))
        var sumSq = 0.0
        for t in two.tags { sumSq += (Double(t.q) / 255.0) * (Double(t.q) / 255.0) }
        #expect((0.97...1.03).contains(sumSq), "sum of squares \(sumSq)")
        #expect(two.tags.count <= Tags.maxTags)
    }

    @Test func aParentIsSpreadToAndTheSpecificOneOutweighsTheGeneralOne() throws {
        let v = Tags.merge(atlas, [input(Tags.srcRecording, "dance-pop")])
        let dance = try #require(v.tags.first { $0.atlasId == id("dance-pop") }).q
        let pop = v.tags.first { $0.atlasId == id("pop") }?.q ?? 0
        #expect(pop > 0, "the parent is there")
        #expect(dance > pop, "dance-pop \(dance) vs pop \(pop)")
    }

    @Test func lateSourcesRunOnlyWhenTheFirstOnesAreWeak() {
        // A strong source answers: the related-artists vote is ignored.
        let strong = Tags.merge(atlas, [input(Tags.srcRecording, "trap"), input(Tags.srcRelatedArtists, "drill")])
        #expect(!strong.tags.contains { $0.atlasId == id("drill") })
        // Alone, the late source is allowed and 0.35 clears the floor.
        let weak = Tags.merge(atlas, [input(Tags.srcRelatedArtists, "drill")])
        #expect(weak.top == id("drill"))
    }

    @Test func orderOfTheClaimsAndOfRepeatsDoesNotMatter() {
        let a = [input(1, "k-pop"), input(6, "dance"), input(3, "pop", 0.4), input(4, "dance-pop", 0.7)]
        let b = a.reversed() + [input(1, "k-pop", 0.2)]
        #expect(Tags.merge(atlas, a) == Tags.merge(atlas, Array(b)))
    }

    @Test func aTrackWithoutTagsBorrowsItsArtistsAtZeroPointSeven() {
        let artist = Tags.merge(atlas, [input(Tags.srcArtist, "v-pop"), input(Tags.srcArtist, "vietnamese bolero", 0.5)])
        let track = Tags.fromArtist(artist)
        #expect(artist.tags.count == track.tags.count)
        for (a, t) in zip(artist.tags, track.tags) { #expect(t.q == Int(BrainMath.floorToLong(Double(a.q) * 0.7 + 0.5))) }
        #expect(Tags.fromArtist(.empty).isEmpty)
    }

    @Test func theBlobRoundTrips() {
        let v = Tags.merge(atlas, [input(1, "k-pop"), input(2, "dance"), input(3, "hip hop", 0.5)])
        #expect(Tags.decode(Tags.encode(v)) == v)
        #expect(Tags.decode(nil).isEmpty)
        #expect(Tags.decode([0, 0]).isEmpty)
    }

    @Test func tagdotIsOneForTheSameVectorAndZeroForNoneShared() {
        let a = Tags.merge(atlas, [input(1, "shoegaze")])
        let b = Tags.merge(atlas, [input(1, "techno")])
        #expect((0.97...1.03).contains(Tags.tagdot(a, a)))
        #expect(Tags.tagdot(a, .empty) == 0.0)
        #expect(Tags.tagdot(a, b) < 0.3)
    }

    @Test func rawStringsArePlacedByIdFirstAndASourceTableSecond() {
        let shoegazeMbid = atlas.genre(id("shoegaze"))?.mbid ?? ""
        let ins = Tags.inputs(atlas, source: Tags.srcRecording, table: nil, raws: [
            Tags.Raw("something else", mbid: shoegazeMbid, votes: 10), Tags.Raw("dream pop", votes: 5),
            Tags.Raw("junk words", votes: 1), Tags.Raw("zero", votes: 0)])
        #expect(ins.count == 2)
        #expect(ins[0].conf == 1.0)
        #expect(ins[1].conf == 0.5)
        let dz = Tags.inputs(atlas, source: Tags.srcDeezerAlbum, table: "deezer", raws: [Tags.Raw("All"), Tags.Raw("Pop")])
        #expect(dz.count == 1)
        #expect(dz[0].atlasId == id("pop"))
    }

    @Test func theYearIsTheEarliestBelievableAndNeverDeezerAlone() {
        func y(_ c: (Int, Int)...) -> TrackDna.Year { TrackDna.mergeYear(c.map { TrackDna.YearClaim(source: $0.0, year: $0.1) }, maxYear: 2027) }
        #expect(y((TrackDna.yearMusicBrainz, 1991), (TrackDna.yearDeezer, 2011)).year == 1991)
        #expect(y((TrackDna.yearMusicBrainz, 1991), (TrackDna.yearDeezer, 2011)).source == TrackDna.yearMusicBrainz)
        #expect(y((TrackDna.yearDeezer, 2011)).year == 0)
        #expect(y((TrackDna.yearDeezer, 1999), (TrackDna.yearITunes, 2005)).year == 1999)
        #expect(y((TrackDna.yearMusicBrainz, 1850), (TrackDna.yearITunes, 2300)).year == 0)
        #expect(y((TrackDna.yearSpotify, 2027)).year == 2027)
        #expect(TrackDna.parseYear("1994-05-01") == 1994)
        #expect(TrackDna.parseYear("19940") == 0)
        #expect(TrackDna.parseYear(nil) == 0)
    }

    @Test func popularityFollowsTheSpecsFormulas() {
        #expect(TrackDna.popFromDeezerRank(541_811) == 541)
        #expect(TrackDna.popFromDeezerRank(5_000_000) == 1000)
        #expect(TrackDna.popFromDeezerRank(0) == -1)
        // 47M plays: 1000 * log10(47,000,001) / 9.7 = 791.
        #expect(TrackDna.popFromPlays(47_000_000) == 791)
        #expect(TrackDna.popFromPlays(9_999_999_999) == 1000)
        #expect(TrackDna.popFromPlays(0) == -1)
        #expect(TrackDna.popFromListeners(100_000) == 943)
        #expect(TrackDna.mergePopularity(deezer: 300, youtube: 800, listenBrainz: 100) == 300)
        #expect(TrackDna.mergePopularity(deezer: -1, youtube: 800, listenBrainz: 100) == 800)
        #expect(TrackDna.mergePopularity(deezer: -1, youtube: -1, listenBrainz: -1) == -1)
        #expect(TrackDna.parsePlayCount("47M plays") == 47_000_000)
        #expect(TrackDna.parsePlayCount("1.2B views") == 1_200_000_000)
        #expect(TrackDna.parsePlayCount("12,345 plays") == 12_345)
        #expect(TrackDna.parsePlayCount("3.4K") == 3_400)
        #expect(TrackDna.parsePlayCount("plays") == 0)
    }

    @Test func energyAndValenceAreTheTagWeightedMeanNudgedByLoudness() throws {
        let kpop = Tags.merge(atlas, [input(1, "k-pop")])
        let d = try #require(atlas.descriptor(id("k-pop")))
        let plain = TrackDna.feel(atlas, kpop, gainDbX10: TrackDna.gainUnknown)
        #expect(plain.known)
        #expect(((d.energy - 25)...(d.energy + 25)).contains(plain.energy), "energy \(plain.energy) vs \(d.energy)")
        // A quiet master (-14.0 dB) gets less energy than a loud one (-4.0 dB); -9 dB is the neutral point.
        let quiet = TrackDna.feel(atlas, kpop, gainDbX10: -140).energy
        let neutral = TrackDna.feel(atlas, kpop, gainDbX10: -90).energy
        let loud = TrackDna.feel(atlas, kpop, gainDbX10: -40).energy
        #expect(plain.energy == neutral)
        #expect(quiet < neutral && neutral < loud)
        #expect(quiet == neutral - 20)
        #expect(loud == neutral + 20)
        let none = TrackDna.feel(atlas, .empty, gainDbX10: -40)
        #expect(none.energy == -1)
        #expect(none.valence == -1)
        #expect((1...4).contains(TrackDna.moods(atlas, kpop).count))
    }

    @Test func theLanguageOfATitle() {
        #expect(TrackDna.scriptLang("Chúng Ta Của Hiện Tại", artistCountry: "") == TrackDna.scriptVietnamese)
        #expect(TrackDna.scriptLang("사랑해", artistCountry: "") == TrackDna.scriptKorean)
        #expect(TrackDna.scriptLang("ひまわりの約束", artistCountry: "") == TrackDna.scriptJapanese)
        #expect(TrackDna.scriptLang("夜曲", artistCountry: "") == TrackDna.scriptChinese)
        #expect(TrackDna.scriptLang("Ditto", artistCountry: "US") == TrackDna.scriptLatin)
        #expect(TrackDna.scriptLang("Hanoi", artistCountry: "VN") == TrackDna.scriptVietnamese)
        #expect(TrackDna.scriptLang("1234", artistCountry: "VN") == TrackDna.scriptUnknown)
        #expect(TrackDna.scriptLang("", artistCountry: "") == TrackDna.scriptUnknown)
    }

    // MARK: TagFeaturesTest

    @Test func aSkipPenalisesTheTopTagsASecondSkipOfTheSameGenreCostsThreeTimesAFinishForgives() throws {
        var s = SessionState()
        let trap = vec("trap")
        Session.applyTags(&s, tags: trap, h: 1.0, completed: false)
        let first = try #require(s.tagPen[atlas.idForName("trap")])
        #expect(first > 0.0)
        Session.applyTags(&s, tags: trap, h: 1.0, completed: false)
        #expect(abs(try #require(s.tagPen[atlas.idForName("trap")]) - first * 4.0) < 1e-12, "1 + 3 times")
        // A different top tag in between resets the tripling.
        var s2 = SessionState()
        Session.applyTags(&s2, tags: trap, h: 1.0, completed: false)
        Session.applyTags(&s2, tags: vec("techno"), h: 1.0, completed: false)
        Session.applyTags(&s2, tags: trap, h: 1.0, completed: false)
        #expect(abs(try #require(s2.tagPen[atlas.idForName("trap")]) - first * 2.0) < 1e-12)
        // A play that finished multiplies everything by 0.7.
        let before = try #require(s2.tagPen[atlas.idForName("trap")])
        Session.applyTags(&s2, tags: trap, h: 0.0, completed: true)
        #expect(abs(try #require(s2.tagPen[atlas.idForName("trap")]) - before * 0.7) < 1e-12)
        // A play that was neither a skip nor a finish changes nothing; unknown genres change nothing.
        Session.applyTags(&s2, tags: trap, h: 0.0, completed: false)
        #expect(abs(try #require(s2.tagPen[atlas.idForName("trap")]) - before * 0.7) < 1e-12)
        var s3 = SessionState()
        Session.applyTags(&s3, tags: .empty, h: 1.0, completed: false)
        #expect(s3.tagPen.isEmpty)
    }

    @Test func featureTwentyFourIsCappedAtOneAndFeatureFourIsZeroForAGenreNeverPlayed() {
        var s = SessionState()
        for _ in 0..<5 { Session.applyTags(&s, tags: vec("trap"), h: 1.0, completed: false) }
        #expect(Features.sessTagPen(vec("trap"), s) == 1.0)
        #expect(Features.sessTagPen(vec("shoegaze"), SessionState()) == 0.0)
        var state = Affinity.State()
        #expect(Features.tagAff(vec("trap"), state, nowMs: 1_000, p0: 0.5) == 0.0)
        let key = Int64(atlas.idForName("trap"))
        for k in 0..<6 { Affinity.apply(&state, family: Family.tag, key: key, r: 1.0, c: 1.0, part: 1.0, tMs: 1_000 + Int64(k)) }
        #expect(Features.tagAff(vec("trap"), state, nowMs: 2_000, p0: 0.5) > 0.0, "a genre finished again and again is liked")
    }

    func play(flags: Int32 = 0) -> PlayEvent {
        PlayEvent(eventId: 1, origin: Origin.live, rid: 1, primaryAid: 1, otherAids: [], keyAtWrite: "y:1", startedAtMs: 1,
                  tzOffsetMin: 0, playedMs: 190_000, durationMs: 200_000, startReason: StartReason.autoplay,
                  endReason: EndReason.trackDone, flags: flags, surface: Surface.autoplay, surfaceId: "", recId: 1, slot: 0,
                  arm: Arm.radio, sessionId: 1, posInSession: 0, passiveRun: 0, route: Route.unknown, retrQ: -1, radioRank: -1)
    }

    @Test func aPlayThatIsNeverAudibleOrLeftOutTouchesNoTag() {
        let tags = vec("trap")
        for flags in [EventFlags.neverAudible, EventFlags.learnExcluded] {
            var state = Affinity.State()
            let e = play(flags: flags)
            Affinity.applyTags(&state, e, Reward.grade(e, Reward.Context()), tags: tags, tMs: 5)
            #expect(Features.tagAff(tags, state, nowMs: 10, p0: 0.5) == 0.0)
        }
        var state = Affinity.State()
        let e = play()
        Affinity.applyTags(&state, e, Reward.grade(e, Reward.Context()), tags: tags, tMs: 5)
        #expect(Features.tagAff(tags, state, nowMs: 10, p0: 0.5) > 0.0)
    }
}
