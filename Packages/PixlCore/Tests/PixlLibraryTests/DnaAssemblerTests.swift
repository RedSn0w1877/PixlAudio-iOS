import Foundation
import Testing
@testable import PixlLibrary

/// Evidence to a stored row (docs/brain-spec.md, 3.2 to 3.5), without any network or database. A port of Android's
/// `DnaAssemblerTest`.
@Suite("Track DNA assembly")
struct DnaAssemblerTests {
    let atlas = KnowledgeFixtures.atlas
    let now: Int64 = 1_795_000_000_000

    func id(_ name: String) -> Int {
        let v = atlas.idForName(name)
        #expect(v >= 0, "\(name) is not in the atlas")
        return v
    }

    func target(_ rid: Int64 = 1, aid: Int64 = 5) -> DnaTarget {
        DnaTarget(rid: rid, aid: aid, spotifyId: "sp\(rid)", title: "Song \(rid)", artist: "Band", durationMs: 180_000)
    }

    func vote(_ name: String, _ count: Int) -> MbGenreVote { MbGenreVote(name: name, mbid: atlas.genre(id(name))?.mbid ?? "", count: count) }

    func assemble(_ t: DnaTarget, _ e: DnaEvidence, prior: TrackDnaRow? = nil, priorArtist: ArtistDnaRow? = nil, version: Int = 1,
                  at: Int64? = nil) -> DnaAssembler.Result {
        DnaAssembler.assemble(target: t, evidence: e, prior: prior, priorArtist: priorArtist, atlas: atlas, atlasVersion: version,
                              nowMs: at ?? now, maxYear: 2027)
    }

    @Test func claimsSurviveARoundTripThroughTheirFourBytes() {
        let claims = [DnaAssembler.Claim(provider: DnaAssembler.pMbArtist, atlasId: 1500, conf: 255),
                      DnaAssembler.Claim(provider: DnaAssembler.pITunes, atlasId: 2200, conf: 3)]
        let back = DnaAssembler.decodeClaims(DnaAssembler.encodeClaims(claims))
        #expect(back == claims)
        #expect(DnaAssembler.decodeClaims(nil).isEmpty)
        #expect(DnaAssembler.decodeClaims([0, 0, 0]).isEmpty)
    }

    @Test func aSourceThatAnswersReplacesItsOwnClaimsAndLeavesTheOthers() {
        let first = assemble(target(), DnaEvidence(
            mbArtist: MbArtist(mbid: "m1", name: "Band", country: "GB", genres: [vote("shoegaze", 10)]),
            itunes: ITunesSong(trackName: "Song 1", artistName: "Band", durationMs: 180_000, genre: "Alternative",
                               releaseDate: "1991-01-01T00:00:00Z", explicit: false),
            tried: DnaSource.musicbrainz | DnaSource.itunes))
        #expect(first.track.tagVector.top == id("shoegaze"))
        // Later MusicBrainz says something else; iTunes is not asked again and keeps its claim.
        let second = assemble(target(), DnaEvidence(mbArtist: MbArtist(mbid: "m1", name: "Band", country: "GB", genres: [vote("techno", 10)]),
                                                    tried: DnaSource.musicbrainz),
                              prior: first.track, priorArtist: first.artist, at: now + 1)
        let ids = second.track.tagVector.tags.map(\.atlasId)
        #expect(ids.contains(id("techno")))
        #expect(!ids.contains(id("shoegaze")), "the artist's old genres were replaced")
        #expect(ids.contains(id("alternative rock")), "iTunes' claim stayed")
    }

    @Test func aSecondTrackByTheSameArtistInheritsTheArtistsGenresWithNoRequest() throws {
        let a = assemble(target(1), DnaEvidence(mbArtist: MbArtist(mbid: "m1", name: "Band", country: "GB", genres: [vote("shoegaze", 4)]),
                                                tried: DnaSource.musicbrainz))
        let b = assemble(target(2), DnaEvidence(tried: DnaSource.musicbrainz), priorArtist: a.artist)
        #expect(b.track.tagVector.top == id("shoegaze"))
        let artistA = try #require(a.artist), artistB = try #require(b.artist)
        #expect(Tags.decode([UInt8](artistA.tags)).top == Tags.decode([UInt8](artistB.tags)).top)
    }

    @Test func anAtlasThatChangedVersionIsNotMergedWithOldIds() {
        let a = assemble(target(), DnaEvidence(mbArtist: MbArtist(mbid: "m1", name: "Band", country: "GB", genres: [vote("shoegaze", 4)]),
                                               tried: DnaSource.musicbrainz))
        let b = assemble(target(), DnaEvidence(), prior: a.track, priorArtist: a.artist, version: 2)
        #expect(b.track.tags.isEmpty, "the old claims used ids of another atlas: they are dropped, not guessed")
        #expect(b.track.atlasVersion == 2)
    }

    @Test func energyAndValenceFollowTheTagsAndAreUnknownWithoutThem() {
        let none = assemble(target(), DnaEvidence())
        #expect(none.track.energy == -1)
        #expect(none.track.popPermille == -1)
        #expect(none.track.firstYear == 0)
        let dance = assemble(target(), DnaEvidence(itunes: ITunesSong(trackName: "Song 1", genre: "Dance"), tried: DnaSource.itunes))
        #expect(dance.track.energy > 150, "dance music is energetic: \(dance.track.energy)")
        let ambient = assemble(target(), DnaEvidence(itunes: ITunesSong(trackName: "Song 1", genre: "Ambient"), tried: DnaSource.itunes))
        #expect(ambient.track.energy < 100, "ambient is calm: \(ambient.track.energy)")
    }

    @Test func theTitlesOwnVersionFlagsAndTheYearTheAppAlreadyKnowsAreKept() {
        let t = DnaTarget(rid: 3, aid: 0, spotifyId: "sp3", title: "Song (Live)", artist: "Band", durationMs: 1,
                          spotifyReleaseDate: "1999-05-05", spotifyExplicit: true, ytYear: 1997, ytPlays: 47_000_000)
        let r = assemble(t, DnaEvidence())
        #expect(r.track.versionFlags & 1 == 1, "live")
        #expect(r.track.firstYear == 1997)
        #expect(r.track.yearSource == TrackDna.yearYouTube)
        #expect(r.track.popPermille == 791)
        #expect(r.track.explicit == 1)
        #expect(r.artist == nil, "no artist id, no artist row")
    }

    @Test func aYearOnlyDeezerGaveIsNotBelievedAndUnknownGenresStayAbsent() {
        let deezer = DnaEvidence(deezerTrack: DeezerTrack(id: 1, rank: 984_833, releaseDate: "2020-03-20"), tried: DnaSource.deezer)
        let r = assemble(target(), deezer)
        #expect(r.track.firstYear == 0)
        #expect(r.track.popPermille == TrackDna.popFromDeezerRank(984_833))
        let unknown = DnaTarget(rid: 4, aid: 0, spotifyId: "sp4", title: "S", artist: "A", durationMs: 1,
                                spotifyGenres: ["zzz not a genre", "pov: indie moonbeam"], chipGenres: ["popular", "2010s"])
        let u = assemble(unknown, DnaEvidence())
        #expect(u.track.tags.isEmpty, "no tag means no genre shown")
        #expect(u.track.energy == -1 && u.track.valence == -1)
        #expect(u.track.confidence == 0)
    }

    @Test func tempoLoudnessAndTheTagsClockMoveOnlyWhenTheirSourceAnswered() {
        let first = assemble(target(), DnaEvidence(deezerTrack: DeezerTrack(id: 9, rank: 500_000, bpm: 170.84, gain: -8.8),
                                                   itunes: ITunesSong(trackName: "Song 1", genre: "Pop"),
                                                   tried: DnaSource.deezer | DnaSource.itunes))
        #expect(first.track.tempoBpmX10 == 1708)
        #expect(first.track.gainDbX10 == -88)
        #expect(first.track.tagsAtMs == now)
        // A weekly popularity refresh leaves the tags' clock alone and keeps the tempo.
        let later = assemble(target(), DnaEvidence(deezerTrack: DeezerTrack(id: 9, rank: 600_000), tried: DnaSource.deezer),
                             prior: first.track, priorArtist: first.artist, at: now + 7 * 86_400_000)
        #expect(later.track.tagsAtMs == now)
        #expect(later.track.popAtMs == now + 7 * 86_400_000)
        #expect(later.track.popPermille == 600)
        #expect(later.track.tempoBpmX10 == 1708 && later.track.gainDbX10 == -88, "a missing tempo keeps the old one")
    }
}
