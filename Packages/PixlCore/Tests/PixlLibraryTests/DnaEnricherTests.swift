import Foundation
import Testing
@testable import PixlLibrary

/// The DNA lanes' work (docs/brain-spec.md, 3.2 to 3.4, 3.7) over fixtures cut from real responses: what a track's row says
/// after the sources answered, that fresh rows are not asked again, that a source with nothing is remembered for 14 days
/// and one that could not be asked is not, and that a stopped run still keeps what it gathered. A port of Android's
/// `DnaEnricherTest`, over a real `DnaRepository` in a temporary directory.
@Suite("Track DNA enrichment")
struct DnaEnricherTests {
    let atlas = KnowledgeFixtures.atlas
    let clock = KnowledgeClock()
    let directory = makeTempDirectory()
    let store: DnaRepository

    init() { store = DnaRepository(directory: directory) }

    func http() -> FakeKnowledgeHttp {
        let h = FakeKnowledgeHttp()
        h.route(.deezer, "/track/isrc:USUG11904206", fixture: "deezer_track_blinding_lights.json")
        h.route(.deezer, "/album/137217782", fixture: "deezer_album_after_hours.json")
        h.route(.musicbrainz, "/isrc/USUG11904206", fixture: "mb_isrc_blinding_lights.json")
        h.route(.musicbrainz, "/artist/c8b03190", fixture: "mb_artist_the_weeknd.json")
        h.route(.itunes, "itunes.apple.com/search", fixture: "itunes_search_blinding_lights.json")
        h.route(.listenbrainz, "metadata/recording", fixture: "lb_metadata_recordings.json")
        h.route(.wikidata, "sparql", fixture: "wikidata_artists.json")
        return h
    }

    func enricher(_ h: FakeKnowledgeHttp, store: DnaRepository? = nil) -> DnaEnricher {
        DnaEnricher(http: h, store: store ?? self.store, atlas: FixtureAtlas(), clock: clock.read)
    }

    func target(_ rid: Int64 = 11, isrc: String? = "USUG11904206") -> DnaTarget {
        DnaTarget(rid: rid, aid: 77, spotifyId: "sp\(rid)", isrc: isrc, title: "Blinding Lights", artist: "The Weeknd",
                  durationMs: 200_000, albumName: "After Hours", spotifyReleaseDate: "2020")
    }

    @Test func oneTrackBecomesARowWithAnIdAYearAPopularityATempoAndGenresFromSeveralSources() async throws {
        let h = http()
        let report = await enricher(h).enrich([target()]) { true }
        #expect(report.tracks == 1)
        let row = try #require(await store.track(11))
        #expect(row.deezerId == 908604612)
        #expect(row.mbRecordingId == "1a67e215-a19e-40c9-9b12-732de134bf5f")
        #expect(row.firstYear == 2019, "MusicBrainz's first release beats Deezer's re-release date")
        #expect(row.yearSource == TrackDna.yearMusicBrainz)
        #expect(row.popPermille == TrackDna.popFromDeezerRank(984_833))
        #expect(row.tempoBpmX10 == 1708)
        #expect(row.gainDbX10 == -88)
        #expect(row.explicit == 0)
        #expect((0...255).contains(row.energy) && (0...255).contains(row.valence))
        let tags = row.tagVector
        #expect(!tags.isEmpty, "R&B from Deezer's album and iTunes, and the artist's genres from MusicBrainz")
        #expect(tags.tags.count <= Tags.maxTags)
        let names = tags.tags.compactMap { atlas.genre($0.atlasId)?.name }
        #expect(names.contains { ["r&b", "contemporary r&b", "synth-pop", "pop", "dance-pop"].contains($0) }, "tags were \(names)")
        let asked = DnaSource.deezer | DnaSource.musicbrainz | DnaSource.itunes
        #expect(row.fetchedMask & asked == asked)
        #expect(row.tagsAtMs == clock.now)
        // The artist row was written with the artist-level facts.
        let artist = try #require(await store.artists([77]).first)
        #expect(artist.mbid == "c8b03190-306c-4120-bb0b-6f2ebfc06ea9")
        #expect(artist.country == "CA")
        #expect(artist.deezerId == 4050205)
    }

    @Test func aFreshRowIsNotAskedAgainAndAnExpiredPopularityAsksOnlyForWhatExpired() async throws {
        let h = http()
        _ = await enricher(h).enrich([target()]) { true }
        let first = h.requests.count
        #expect(first > 0)
        clock.advance(3 * 24 * 60 * 60 * 1000)
        _ = await enricher(h).enrich([target()]) { true }
        #expect(h.requests.count == first, "three days later nothing has expired")
        clock.advance(5 * 24 * 60 * 60 * 1000)
        h.clearRequests()
        _ = await enricher(h).enrich([target()]) { true }
        #expect(!h.requests.isEmpty, "a week old popularity is asked for again")
        #expect(h.count(.musicbrainz) == 0, "ids, year and the artist's genres are not asked for again")
        #expect(h.count(.itunes) == 0)
        #expect(try #require(await store.track(11)).firstYear == 2019, "what was known before is kept")
    }

    @Test func aSourceWithNothingIsRememberedForFourteenDaysDoublingAndOneThatCouldNotBeAskedIsNot() async throws {
        let h = http()
        h.removeRoutes(of: .deezer)
        h.routeText(.deezer, "/track/isrc:", #"{"error":{"type":"DataException","message":"no data","code":800}}"#)
        h.routeText(.deezer, "/search", #"{"data":[]}"#)
        let start = clock.now
        _ = await enricher(h).enrich([target()]) { true }
        let blocked = await store.blocked(source: DnaSource.numberOf(DnaSource.deezer), nowMs: start, entities: ["t:11"])
        #expect(blocked == ["t:11"])
        #expect(await store.misses(entity: "t:11", source: DnaSource.numberOf(DnaSource.deezer)) == 1)
        let row = try #require(await store.track(11))
        #expect(row.fetchedMask & DnaSource.deezer != 0, "it was tried")
        // The miss stands for 14 days, not 15.
        #expect(await store.blocked(source: DnaSource.numberOf(DnaSource.deezer), nowMs: start + 14 * 86_400_000 - 1, entities: ["t:11"]).count == 1)
        #expect(await store.blocked(source: DnaSource.numberOf(DnaSource.deezer), nowMs: start + 14 * 86_400_000 + 1, entities: ["t:11"]).isEmpty)
        // Not asked again while the miss stands.
        let deezerAsked = h.count(.deezer)
        clock.advance(8 * 24 * 60 * 60 * 1000) // popularity would be due, the miss still stands
        _ = await enricher(h).enrich([target()]) { true }
        #expect(h.count(.deezer) == deezerAsked)

        // A source that is off or out of budget answers "not asked": no miss, no bit, no empty row for it.
        let off = http()
        for host in [KnowledgeHost.deezer, .musicbrainz, .itunes] { off.setDown(host) }
        let fresh = DnaRepository(directory: makeTempDirectory())
        let r = await enricher(off, store: fresh).enrich(
            [DnaTarget(rid: 5, aid: 0, spotifyId: "sp5", isrc: "ISRC", title: "Nothing Known", artist: "Nobody", durationMs: 100_000)]) { true }
        #expect(r.tracks == 0, "nothing was learned and nothing was known: no row")
        #expect(await fresh.count() == 0)

        // A track that already has a row is saved again when nothing could be asked, so lane 5 moves on to the next one.
        let early = try #require(await store.track(11))
        clock.advance(9 * 24 * 60 * 60 * 1000)
        _ = await enricher(off).enrich([target()]) { true }
        let later = try #require(await store.track(11))
        #expect(later.updatedAtMs == clock.now, "it moved to the back of lane 5's order")
        #expect(later.firstYear == early.firstYear, "nothing known was lost")
        #expect(later.popPermille == early.popPermille)
    }

    @Test func whatTheAppAlreadyKnowsIsSavedEvenWhenNoSourceCanBeAsked() async throws {
        let off = http()
        for host in KnowledgeHost.allCases { off.setDown(host) }
        let t = DnaTarget(rid: 9, aid: 3, spotifyId: "sp9", isrc: nil, title: "Ditto", artist: "NewJeans", durationMs: 185_000,
                          spotifyReleaseDate: "2022-12-19", spotifyGenres: ["k-pop", "k-pop girl group"])
        #expect(await enricher(off).enrich([t]) { true }.tracks == 1)
        let row = try #require(await store.track(9))
        #expect(row.firstYear == 2022)
        #expect(row.yearSource == TrackDna.yearSpotify)
        #expect(row.tagVector.top == atlas.idForName("k-pop"), "Spotify's genre string is placed through the atlas")
        #expect(row.fetchedMask == DnaSource.spotifyGenres)
        #expect(await store.activeMissCount(nowMs: clock.now) == 0)
    }

    @Test func unknownGenresStayAbsent() async throws {
        let off = http()
        for host in KnowledgeHost.allCases { off.setDown(host) }
        let t = DnaTarget(rid: 12, aid: 4, spotifyId: "sp12", isrc: nil, title: "Song", artist: "Someone", durationMs: 1,
                          spotifyGenres: ["zzz not a genre", "pov: indie moonbeam"], chipGenres: ["popular", "2010s"])
        _ = await enricher(off).enrich([t]) { true }
        let row = try #require(await store.track(12))
        #expect(row.tags.isEmpty, "no tag means no genre shown")
        #expect(row.energy == -1)
        #expect(row.valence == -1)
    }

    @Test func aGateThatClosesStopsTheRunAndWhatWasGatheredIsKept() async throws {
        let h = http()
        let calls = KnowledgeCounter()
        let second = DnaTarget(rid: 12, aid: 78, spotifyId: "sp12", title: "Other", artist: "Nobody", durationMs: 1)
        let report = await enricher(h).enrich([target(11), second]) { calls.next() < 3 }
        #expect(report.stopped)
        #expect(await store.track(11) != nil, "the first track finished before the gate closed")
    }

    @Test func aYearOnlyDeezerGaveIsNotBelieved() async throws {
        let h = http()
        h.removeRoutes(of: .musicbrainz)
        h.removeRoutes(of: .itunes)
        let t = DnaTarget(rid: 21, aid: 5, spotifyId: "sp21", isrc: "USUG11904206", title: "Blinding Lights", artist: "The Weeknd", durationMs: 200_000)
        _ = await enricher(h).enrich([t]) { true }
        let row = try #require(await store.track(21))
        #expect(row.firstYear == 0, "Deezer's date alone is not a year")
        #expect(row.yearSource == TrackDna.yearNone)
    }

    @Test func noAtlasMeansNoWorkAndNoRow() async {
        let h = http()
        let e = DnaEnricher(http: h, store: store, atlas: FixtureAtlas(value: nil), clock: clock.read)
        let r = await e.enrich([target()]) { true }
        #expect(r.noAtlas)
        #expect(r.tracks == 0)
        #expect(h.requests.isEmpty)
    }

    @Test func theCurrentYearIsReadFromTheClock() {
        #expect(DnaEnricher.currentYear(1_795_000_000_000) == 2026)
        #expect(DnaEnricher.currentYear(0) == 1970)
        #expect(DnaEnricher.currentYear(951_782_400_000) == 2000)
        #expect(DnaEnricher.currentYear(-1) == 1969)
    }
}
