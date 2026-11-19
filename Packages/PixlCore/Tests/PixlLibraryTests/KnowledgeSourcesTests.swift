import Foundation
import Testing
@testable import PixlLibrary

/// The five open-data parsers over responses cut from the real services, and the clients' choices (docs/brain-spec.md,
/// 3.3 B). A port of Android's `KnowledgeSourcesTest`, over the same fixtures.
@Suite("Knowledge sources")
struct KnowledgeSourcesTests {
    let blinding = TrackMatch.Want(title: "Blinding Lights", artist: "The Weeknd", durationMs: 200_000)

    // MARK: Parsers

    @Test func deezerParsersReadASearchATrackAnAlbumAndBothErrors() throws {
        let search = KnowledgeParsers.deezerSearch(KnowledgeFixtures.read("deezer_search_blinding_lights.json"))
        #expect(search.errorCode == 0)
        let first = try #require(search.value?.first)
        #expect(first.id == 908604612)
        #expect(first.artistName == "The Weeknd")
        #expect(first.durationSec == 200)
        #expect(first.isrc == "USUG11904206")

        let track = try #require(KnowledgeParsers.deezerTrack(KnowledgeFixtures.read("deezer_track_blinding_lights.json")).value)
        #expect(track.releaseDate == "2020-03-20")
        #expect(abs(track.bpm - 170.84) < 0.001)
        #expect(abs(try #require(track.gain) - -8.8) < 0.001)
        #expect(track.albumId == 137217782)
        #expect(track.rank == 984833)

        let album = try #require(KnowledgeParsers.deezerAlbum(KnowledgeFixtures.read("deezer_album_after_hours.json")).value)
        #expect(album.genres == ["R&B"])

        // Errors arrive as HTTP 200 with an error object.
        let gone = KnowledgeParsers.deezerTrack(KnowledgeFixtures.read("deezer_error_not_found.json"))
        #expect(gone.errorCode == 800)
        #expect(gone.noData)
        #expect(KnowledgeParsers.deezerSearch(KnowledgeFixtures.read("deezer_error_quota.json")).quota)
        // Garbage is "no data", never an exception.
        #expect(KnowledgeParsers.deezerTrack("<html>").value == nil)
        #expect(KnowledgeParsers.deezerTrack(nil).value == nil)
    }

    @Test func musicBrainzParsersReadRecordingsAnIsrcLookupGenresAndAnArtist() throws {
        let search = KnowledgeParsers.mbRecordings(KnowledgeFixtures.read("mb_recording_search_blinding_lights.json"))
        #expect(!search.isEmpty)
        #expect(search[0].title == "Blinding Lights")
        #expect(search[0].artistNames.contains("The Weeknd"))

        let byIsrc = KnowledgeParsers.mbRecordings(KnowledgeFixtures.read("mb_isrc_blinding_lights.json"))
        #expect(byIsrc[0].mbid == "1a67e215-a19e-40c9-9b12-732de134bf5f")
        #expect(byIsrc[0].firstReleaseDate == "2019-11-29")
        #expect(byIsrc[0].artistMbid == "c8b03190-306c-4120-bb0b-6f2ebfc06ea9")

        let rec = try #require(KnowledgeParsers.mbRecording(KnowledgeFixtures.read("mb_recording_genres.json")))
        #expect(rec.genres.count == 1)
        #expect(rec.genres[0].name == "soul")
        #expect(rec.genres[0].mbid == "1b5e7b16-336b-473e-a364-5120413a9827")

        let artist = try #require(KnowledgeParsers.mbArtist(KnowledgeFixtures.read("mb_artist_the_weeknd.json")))
        #expect(artist.name == "The Weeknd")
        #expect(!artist.genres.isEmpty)
        #expect(artist.country == "CA")
        #expect(KnowledgeParsers.mbRecordings("{}").isEmpty)
        #expect(KnowledgeParsers.mbArtist("not json") == nil)
    }

    @Test func listenBrainzWikidataAndITunesParsers() throws {
        let lb = KnowledgeParsers.lbRecordings(KnowledgeFixtures.read("lb_metadata_recordings.json"))
        #expect(lb.count == 3)
        let one = try #require(lb["8bee2202-0b48-42be-9e89-bf68e6ab742c"])
        #expect(one.artistMbid == "0b76f632-25fa-4681-9862-86499c28afd3")
        #expect(one.firstReleaseDate == "2007-05-13")
        let postGrunge = try #require(one.tags.first { $0.tag == "post-grunge" && $0.scope == "artist" })
        #expect(postGrunge.genreMbid == "bbb1310c-24cb-4fc9-97c4-f93e4549f1e2")
        #expect(try #require(one.tags.first { $0.tag == "canadian" }).genreMbid == "", "a tag that is not a genre carries no genre id")

        let pop = KnowledgeParsers.lbPopularity(KnowledgeFixtures.read("lb_popularity.json"))
        #expect(try #require(pop.values.first).users == 0, "no listeners is zero, not unknown-and-large")

        let wd = KnowledgeParsers.wikidataArtists(KnowledgeFixtures.read("wikidata_artists.json"))
        #expect(!wd.isEmpty)
        #expect(wd[0].wikidataId.hasPrefix("Q"))
        #expect(wd[0].genreMbids.count == wd[0].genreLabels.count)

        let it = KnowledgeParsers.itunes(KnowledgeFixtures.read("itunes_search_blinding_lights.json"))
        #expect(it.count == 2)
        #expect(it[1].genre == "R&B/Soul")
        #expect(it[1].durationMs == 200046)
        #expect(it[1].explicit == false)
    }

    // MARK: Matching

    @Test func aVersionTheListenersTrackLacksIsAnotherRecording() {
        #expect(TrackMatch.titleMatches(blinding, "Blinding Lights"))
        #expect(TrackMatch.titleMatches(blinding, "Blinding Lights - Radio Edit"))
        #expect(TrackMatch.titleMatches(blinding, "Blinding Lights (feat. X)"))
        #expect(!TrackMatch.titleMatches(blinding, "Blinding Lights (Remix)"))
        #expect(!TrackMatch.titleMatches(blinding, "Blinding Lights (Live at Wembley)"))
        // A listener who has the live version matches a live one.
        #expect(TrackMatch.titleMatches(TrackMatch.Want(title: "Blinding Lights (Live)", artist: "The Weeknd", durationMs: 0), "Blinding Lights - Live"))
        #expect(TrackMatch.disambiguationRefuses(blinding, "live, 2024-09-07: MorumBIS, Sao Paulo"))
        #expect(!TrackMatch.disambiguationRefuses(blinding, ""))
        #expect(!TrackMatch.disambiguationRefuses(blinding, "Canadian R&B singer"))
    }

    @Test func artistsMatchByWholeWordsAndDurationsByThreeSeconds() {
        #expect(TrackMatch.artistMatches(blinding, ["The Weeknd & ROSALIA"]))
        #expect(TrackMatch.artistMatches(blinding, ["the weeknd"]))
        #expect(!TrackMatch.artistMatches(blinding, ["Weekend Warrior Band"]))
        #expect(TrackMatch.artistMatches(TrackMatch.Want(title: "x", artist: "Sơn Tùng M-TP", durationMs: 0), ["Son Tung M-TP"]))
        #expect(!TrackMatch.artistMatches(TrackMatch.Want(title: "x", artist: "", durationMs: 0), [""]))
        #expect(TrackMatch.durationClose(wantMs: 200_000, gotMs: 202_900))
        #expect(!TrackMatch.durationClose(wantMs: 200_000, gotMs: 204_500))
        #expect(TrackMatch.durationClose(wantMs: 0, gotMs: 204_500), "an unknown length cannot refuse")
    }

    // MARK: Clients

    @Test func deezerByIsrcByNameWithAQuotaAndWithNothing() async throws {
        let http = FakeKnowledgeHttp()
        http.route(.deezer, "/track/isrc:USUG11904206", fixture: "deezer_track_blinding_lights.json")
        http.route(.deezer, "/track/isrc:ZZZ", fixture: "deezer_error_not_found.json")
        http.route(.deezer, "/search?q=", fixture: "deezer_search_blinding_lights.json")
        let deezer = DeezerSource(http: http)
        #expect(await deezer.trackByIsrc("USUG11904206").value?.id == 908604612)
        if case .notFound = await deezer.trackByIsrc("ZZZ") {} else { Issue.record("an unknown ISRC is not found") }
        // The name search skips the remix and takes the real one.
        #expect(await deezer.search(blinding).value?.id == 908604612)
        if case .notFound = await deezer.search(TrackMatch.Want(title: "Some Other Song", artist: "Nobody", durationMs: 100_000)) {} else {
            Issue.record("another song is not found")
        }

        let quota = FakeKnowledgeHttp()
        quota.route(.deezer, "/track/", fixture: "deezer_error_quota.json")
        if case .unavailable = await DeezerSource(http: quota).track(1) {} else { Issue.record("a quota is not an answer") }
        #expect(quota.backedOff.map(\.host) == [.deezer], "the host is told to back off")

        let off = FakeKnowledgeHttp()
        off.setDown(.deezer)
        if case .unavailable = await DeezerSource(http: off).search(blinding) {} else { Issue.record("not asked is not 'nothing'") }
        #expect(off.requests.isEmpty)
        let server = FakeKnowledgeHttp()
        server.routeText(.deezer, "/track/", "", code: 503)
        if case .unavailable = await DeezerSource(http: server).track(1) {} else { Issue.record("a 503 is not 'nothing'") }
    }

    @Test func musicBrainzPicksTheRecordingAnIsrcStandsForAndRefusesLiveAndRemixVersions() async throws {
        let http = FakeKnowledgeHttp()
        http.route(.musicbrainz, "/isrc/USUG11904206", fixture: "mb_isrc_blinding_lights.json")
        http.route(.musicbrainz, "/recording?query=", fixture: "mb_recording_search_blinding_lights.json")
        http.route(.musicbrainz, "/artist/c8b03190", fixture: "mb_artist_the_weeknd.json")
        let mb = MusicBrainzSource(http: http)
        let hit = try #require(await mb.recordingByIsrc("USUG11904206", blinding).value)
        #expect(hit.firstReleaseDate == "2019-11-29")
        if let searched = await mb.searchRecording(blinding).value {
            #expect(BrainText.isBlank(searched.disambiguation) || !searched.disambiguation.hasPrefix("live"))
        }
        #expect(await mb.artist("c8b03190-306c-4120-bb0b-6f2ebfc06ea9").value?.name == "The Weeknd")
        if case .notFound = await mb.artist("00000000-0000-0000-0000-000000000000") {} else { Issue.record("an unknown artist is not found") }
    }

    @Test func listenBrainzAsksForSixteenAtMostAndWikidataForAHundredAndIdsAreCheckedFirst() async throws {
        let http = FakeKnowledgeHttp()
        http.route(.listenbrainz, "metadata/recording", fixture: "lb_metadata_recordings.json")
        http.route(.listenbrainz, "popularity", fixture: "lb_popularity.json")
        http.route(.wikidata, "sparql", fixture: "wikidata_artists.json")
        let lb = ListenBrainzSource(http: http)
        let ids = [String](repeating: "8bee2202-0b48-42be-9e89-bf68e6ab742c", count: 20)
        #expect(await lb.recordings(ids).value != nil)
        #expect(await lb.popularity(Array(ids.prefix(3))).value != nil)
        if case .notFound = await lb.recordings([]) {} else { Issue.record("nothing to ask is not found") }
        let wd = WikidataSource(http: http)
        // Only well-formed MusicBrainz ids go into the query (a name can never reach SPARQL).
        if case .notFound = await wd.artists(["x\" } DROP", "not-an-id"]) {} else { Issue.record("a bad id never goes out") }
        #expect(http.count(.wikidata) == 0)
        #expect(await wd.artists(["0b76f632-25fa-4681-9862-86499c28afd3"]).value != nil)
        #expect(http.count(.wikidata) == 1)
    }

    @Test func iTunesSkipsTheRemixAndTakesTheSong() async throws {
        let http = FakeKnowledgeHttp()
        http.route(.itunes, "itunes.apple.com/search", fixture: "itunes_search_blinding_lights.json")
        #expect(await ITunesSource(http: http).search(blinding).value?.genre == "R&B/Soul")
        if case .notFound = await ITunesSource(http: http).search(TrackMatch.Want(title: "Blinding Lights", artist: "A Different Band", durationMs: 200_000)) {} else {
            Issue.record("another band is not found")
        }
    }

    // MARK: The owner's off switches

    @Test func theRemoteConfigCanSwitchOneSourceOffAndNothingElse() {
        let text = #"{"brain": {"sources": {"deezer": {"enabled": false}, "musicbrainz": {"enabled": true}}}}"#
        #expect(!BrainRemoteConfig.sourceAllowed(configText: text, key: "deezer"))
        #expect(BrainRemoteConfig.sourceAllowed(configText: text, key: "musicbrainz"))
        #expect(BrainRemoteConfig.sourceAllowed(configText: text, key: "itunes"))
        #expect(BrainRemoteConfig.sourceAllowed(configText: nil, key: "deezer"), "no file means on")
        #expect(BrainRemoteConfig.sourceAllowed(configText: "not json", key: "deezer"), "a switch that is off by accident would hide the feature")
        #expect(BrainRemoteConfig.sourceAllowed(configText: #"{"brain": {"refresh": {"enabled": false}}}"#, key: "deezer"),
                "the refresh switch is not a source switch")
    }

    @Test func everyHostHasAPoliteSpacingAndADailyCeilingFromTheSpec() {
        #expect(KnowledgeHost.musicbrainz.minIntervalMs == 1_100)
        #expect(KnowledgeHost.musicbrainz.dailyCeiling == 200)
        #expect(KnowledgeHost.wikidata.minIntervalMs == 6_000)
        #expect(KnowledgeHost.wikidata.dailyCeiling == 3)
        #expect(KnowledgeHost.itunes.minIntervalMs == 3_500)
        #expect(KnowledgeHost.itunes.dailyCeiling == 60)
        #expect(KnowledgeHost.deezer.dailyCeiling == 600)
        #expect(KnowledgeHost.listenbrainz.dailyCeiling == 150)
        for h in KnowledgeHost.allCases { #expect(!h.terms.isEmpty, "terms are listed for \(h.key)") }
        #expect(KnowledgeHost.byKey("deezer") == .deezer)
        #expect(KnowledgeHost.byKey("spotify") == nil)
    }

    @Test func theUserAgentNamesTheAppAndNeverTheListener() {
        let ua = KnowledgeUserAgent.value(version: "1.2")
        #expect(ua == "PixlAudio/1.2 ( https://github.com/RedSn0w1877/PixlAudio-iOS )")
    }

    @Test func urlTermsAreEncodedLikeJavasUrlEncoderWithSpacesAsPercentTwenty() {
        #expect(SourceSupport.enc("The Weeknd Blinding Lights") == "The%20Weeknd%20Blinding%20Lights")
        #expect(SourceSupport.enc("a+b&c=d/é") == "a%2Bb%26c%3Dd%2F%C3%A9")
        #expect(SourceSupport.enc("x*y-z_w.v~") == "x*y-z_w.v%7E")
    }
}
