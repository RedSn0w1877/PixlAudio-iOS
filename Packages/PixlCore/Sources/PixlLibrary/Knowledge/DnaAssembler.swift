// Evidence to a track's DNA row and its artist's row (docs/brain-spec.md, 3.2 to 3.5). A port of Android's
// `DnaAssembler.kt`. Pure: no network, no clock, no database; the enricher gathers the evidence and stores the result.
// A source that answered replaces what it said before; one that did not keeps its old claims, so a partial run never
// loses what an earlier run learned.
//
// What is cut, and written in the handoff: Discogs (source 5), the related-artists vote (7), the shared-playlist vote (9)
// and the assistant (10) are not gathered, and `emb` waits for the embeddings.

import Foundation

/// One recording the enrichment is about, with everything the app already knows about it before any request goes out.
public struct DnaTarget: Sendable {
    public var rid: Int64
    /// The primary artist's id; 0 when unknown.
    public var aid: Int64
    public var spotifyId: String?
    public var isrc: String?
    public var title: String
    public var artist: String
    public var artistDisplay: String
    public var durationMs: Int
    public var albumName: String?
    public var spotifyArtistIds: [String]
    public var spotifyReleaseDate: String?
    public var spotifyExplicit: Bool?
    /// The listener's own Spotify artist genres already synced: no request needed.
    public var spotifyGenres: [String]
    /// Genre chips of the track's own radio (3.4 source 4).
    public var chipGenres: [String]
    /// What the track's cached YouTube Music row says: year, play count, explicit.
    public var ytYear: Int
    public var ytPlays: Int64
    public var ytExplicit: Bool?
    public var videoId: String?
    /// "Use my Spotify music to shape picks" is off: Spotify's artist genres and album year are taken out of the stored
    /// rows, not only left out of new ones (a claim nobody replaces is otherwise kept for ever).
    public var spotifyOff: Bool

    public init(rid: Int64, aid: Int64, spotifyId: String? = nil, isrc: String? = nil, title: String, artist: String,
                artistDisplay: String? = nil, durationMs: Int, albumName: String? = nil, spotifyArtistIds: [String] = [],
                spotifyReleaseDate: String? = nil, spotifyExplicit: Bool? = nil, spotifyGenres: [String] = [],
                chipGenres: [String] = [], ytYear: Int = 0, ytPlays: Int64 = 0, ytExplicit: Bool? = nil, videoId: String? = nil, spotifyOff: Bool = false) {
        self.rid = rid
        self.aid = aid
        self.spotifyId = spotifyId
        self.isrc = isrc
        self.title = title
        self.artist = artist
        self.artistDisplay = artistDisplay ?? artist
        self.durationMs = durationMs
        self.albumName = albumName
        self.spotifyArtistIds = spotifyArtistIds
        self.spotifyReleaseDate = spotifyReleaseDate
        self.spotifyExplicit = spotifyExplicit
        self.spotifyGenres = spotifyGenres
        self.chipGenres = chipGenres
        self.ytYear = ytYear
        self.ytPlays = ytPlays
        self.ytExplicit = ytExplicit
        self.videoId = videoId
        self.spotifyOff = spotifyOff
    }
}

/// What the sources returned for one target in one pass. A nil is "not asked or no answer"; `tried` says which sources
/// answered at all.
public struct DnaEvidence: Sendable {
    public var deezerTrack: DeezerTrack?
    public var deezerAlbum: DeezerAlbum?
    public var mb: MbRecordingHit?
    public var mbArtist: MbArtist?
    public var lb: LbRecording?
    public var lbPopularity: LbPopularity?
    public var wd: WdArtist?
    public var itunes: ITunesSong?
    /// `DnaSource` bits: the sources that answered (found or "nothing") and so replace what they said before.
    public var tried: Int

    public init(deezerTrack: DeezerTrack? = nil, deezerAlbum: DeezerAlbum? = nil, mb: MbRecordingHit? = nil,
                mbArtist: MbArtist? = nil, lb: LbRecording? = nil, lbPopularity: LbPopularity? = nil, wd: WdArtist? = nil,
                itunes: ITunesSong? = nil, tried: Int = 0) {
        self.deezerTrack = deezerTrack
        self.deezerAlbum = deezerAlbum
        self.mb = mb
        self.mbArtist = mbArtist
        self.lb = lb
        self.lbPopularity = lbPopularity
        self.wd = wd
        self.itunes = itunes
        self.tried = tried
    }
}

public enum DnaAssembler {
    // The providers a stored claim can come from. Several map to one spec source number (3.4).
    public static let pLbRecording = 1
    public static let pMbArtist = 2
    public static let pSpotify = 3
    public static let pChip = 4
    public static let pITunes = 6
    public static let pDeezerAlbum = 8
    public static let pLbArtist = 12
    public static let pWdArtist = 13
    /// The optional assistant tagging job (tag source 10, stage 4): constrained to a shortlist of atlas ids, trust 0.25, used only when the
    /// other sources are weak. Android `P_ASSISTANT`.
    public static let pAssistant = 10

    public static func sourceOf(_ provider: Int) -> Int {
        switch provider {
        case pLbRecording: return Tags.srcRecording
        case pMbArtist, pLbArtist, pWdArtist: return Tags.srcArtist
        case pSpotify: return Tags.srcSpotify
        case pChip: return Tags.srcChip
        case pITunes: return Tags.srcITunes
        case pDeezerAlbum: return Tags.srcDeezerAlbum
        case pAssistant: return Tags.srcAssistant
        default: return 0
        }
    }

    /// True for the providers that describe the artist, not the track.
    public static func isArtistLevel(_ provider: Int) -> Bool {
        provider == pMbArtist || provider == pLbArtist || provider == pWdArtist || provider == pSpotify
    }

    /// Which stored providers this pass's evidence replaces: a provider is replaced only when it came back with
    /// something, so an answer that was reused from the artist's stored row, or a response that failed, never wipes what
    /// was known.
    private static func replacedBy(_ target: DnaTarget, _ e: DnaEvidence) -> Set<Int> {
        var out: Set<Int> = []
        if e.deezerAlbum != nil { out.insert(pDeezerAlbum) }
        if e.mbArtist != nil { out.insert(pMbArtist) }
        if e.lb != nil { out.insert(pLbRecording); out.insert(pLbArtist) }
        if e.wd != nil { out.insert(pWdArtist) }
        if e.itunes != nil { out.insert(pITunes) }
        if !target.spotifyGenres.isEmpty || target.spotifyOff { out.insert(pSpotify) }
        if !target.chipGenres.isEmpty { out.insert(pChip) }
        return out
    }

    /// One stored claim: who said it, which atlas node, how sure (0...255).
    public struct Claim: Sendable, Equatable {
        public var provider: Int
        public var atlasId: Int
        public var conf: Int
        public init(provider: Int, atlasId: Int, conf: Int) {
            self.provider = provider
            self.atlasId = atlasId
            self.conf = conf
        }
    }

    public static func encodeClaims(_ claims: [Claim]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: claims.count * 4)
        for (i, c) in claims.enumerated() {
            out[i * 4] = UInt8(truncatingIfNeeded: c.provider)
            out[i * 4 + 1] = UInt8(truncatingIfNeeded: c.atlasId >> 8)
            out[i * 4 + 2] = UInt8(truncatingIfNeeded: c.atlasId)
            out[i * 4 + 3] = UInt8(truncatingIfNeeded: c.conf)
        }
        return out
    }

    public static func decodeClaims(_ bytes: [UInt8]?) -> [Claim] {
        guard let bytes, bytes.count >= 4 else { return [] }
        return (0..<(bytes.count / 4)).map { i in
            Claim(provider: Int(bytes[i * 4]), atlasId: (Int(bytes[i * 4 + 1]) << 8) | Int(bytes[i * 4 + 2]), conf: Int(bytes[i * 4 + 3]))
        }
    }

    private static func claimsFor(_ atlas: GenreAtlas, _ provider: Int, _ source: Int, _ table: String?, _ raws: [Tags.Raw]) -> [Claim] {
        Tags.inputs(atlas, source: source, table: table, raws: raws).map {
            let c = Int($0.conf * 255.0 + 0.5)
            return Claim(provider: provider, atlasId: $0.atlasId, conf: c < 0 ? 0 : (c > 255 ? 255 : c))
        }
    }

    /// The claims this pass's evidence makes, by provider.
    public static func claimsOf(_ target: DnaTarget, _ e: DnaEvidence, _ atlas: GenreAtlas) -> [Claim] {
        var out: [Claim] = []
        if let lb = e.lb {
            out += claimsFor(atlas, pLbRecording, Tags.srcRecording, nil,
                             lb.tags.filter { $0.scope == "recording" }.map { Tags.Raw($0.tag, mbid: $0.genreMbid, votes: $0.count) })
            out += claimsFor(atlas, pLbArtist, Tags.srcArtist, nil,
                             lb.tags.filter { $0.scope == "artist" }.map { Tags.Raw($0.tag, mbid: $0.genreMbid, votes: $0.count) })
        }
        if let a = e.mbArtist {
            out += claimsFor(atlas, pMbArtist, Tags.srcArtist, nil, a.genres.map { Tags.Raw($0.name, mbid: $0.mbid, votes: $0.count) })
        }
        if let w = e.wd {
            let raws = w.genreMbids.enumerated().map { i, id in Tags.Raw(i < w.genreLabels.count ? w.genreLabels[i] : "", mbid: id) }
            out += claimsFor(atlas, pWdArtist, Tags.srcArtist, nil, raws)
        }
        if !target.spotifyGenres.isEmpty, !target.spotifyOff {
            out += claimsFor(atlas, pSpotify, Tags.srcSpotify, nil, target.spotifyGenres.map { Tags.Raw($0) })
        }
        if !target.chipGenres.isEmpty {
            out += claimsFor(atlas, pChip, Tags.srcChip, "chip", target.chipGenres.map { Tags.Raw($0) })
        }
        if let it = e.itunes, !BrainText.isBlank(it.genre) {
            out += claimsFor(atlas, pITunes, Tags.srcITunes, "itunes", [Tags.Raw(it.genre)])
        }
        if let a = e.deezerAlbum {
            out += claimsFor(atlas, pDeezerAlbum, Tags.srcDeezerAlbum, "deezer", a.genres.map { Tags.Raw($0) })
        }
        return out
    }

    private static func merged(_ atlas: GenreAtlas, _ claims: [Claim], artistLevelOnly: Bool) -> Tags.Vector {
        Tags.merge(atlas, claims.filter { !artistLevelOnly || isArtistLevel($0.provider) }
            .map { Tags.Input(source: sourceOf($0.provider), atlasId: $0.atlasId, conf: Double($0.conf) / 255.0) })
    }

    /// Prior claims with the providers that answered now replaced by the fresh ones.
    private static func replaceClaims(_ prior: [Claim], _ fresh: [Claim], _ drop: Set<Int>) -> [Claim] {
        prior.filter { !drop.contains($0.provider) } + fresh
    }

    /// `a:b,c:d` to pairs; anything else is skipped.
    private static func parseClaims(_ text: String) -> [(Int, Int)] {
        text.split(separator: ",", omittingEmptySubsequences: true).compactMap { piece in
            guard let i = piece.firstIndex(of: ":"), i != piece.startIndex,
                  let a = Int(piece[piece.startIndex..<i]), let b = Int(piece[piece.index(after: i)...]) else { return nil }
            return (a, b)
        }
    }

    private static func yearSourcesOf(_ tried: Int) -> Set<Int> {
        var out: Set<Int> = []
        if tried & DnaSource.musicbrainz != 0 { out.insert(TrackDna.yearMusicBrainz) }
        if tried & DnaSource.itunes != 0 { out.insert(TrackDna.yearITunes) }
        if tried & DnaSource.deezer != 0 { out.insert(TrackDna.yearDeezer) }
        return out
    }

    /// True when a stored track row still carries something Spotify said: an artist-genre claim or the album year.
    public static func carriesSpotify(_ row: TrackDnaRow) -> Bool {
        row.yearSource == TrackDna.yearSpotify || decodeClaims([UInt8](row.tagInputs)).contains { $0.provider == pSpotify }
    }

    public static func carriesSpotify(_ row: ArtistDnaRow) -> Bool {
        decodeClaims([UInt8](row.tagInputs)).contains { $0.provider == pSpotify }
    }

    /// The tag vector of a track row as its claims make it WITHOUT anything Spotify said. The island fit reads this and not the
    /// stored vector: Spotify content is never used to fit a model (owner decision), so a genre only Spotify gave is not a
    /// feature of any island. A row written with another atlas has unreadable claims and gives no tags (unknown, not guessed).
    public static func tagVectorWithoutSpotify(_ row: TrackDnaRow, atlas: GenreAtlas, atlasVersion: Int) -> Tags.Vector {
        guard row.atlasVersion == atlasVersion else { return .empty }
        let claims = decodeClaims([UInt8](row.tagInputs))
        if !claims.contains(where: { $0.provider == pSpotify }) { return row.tagVector }
        return merged(atlas, claims.filter { $0.provider != pSpotify }, artistLevelOnly: false)
    }

    /// An artist row without its Spotify claims, its tags merged again from what is left. Nil when it carries none, or was
    /// written with another atlas (its claims cannot be read; the next refresh rebuilds it).
    public static func withoutSpotify(_ row: ArtistDnaRow, atlas: GenreAtlas, atlasVersion: Int, nowMs: Int64) -> ArtistDnaRow? {
        guard row.atlasVersion == atlasVersion else { return nil }
        let claims = decodeClaims([UInt8](row.tagInputs))
        if !claims.contains(where: { $0.provider == pSpotify }) { return nil }
        let kept = claims.filter { $0.provider != pSpotify }
        var out = row
        out.tagInputs = Data(encodeClaims(kept))
        out.tags = Data(Tags.encode(merged(atlas, kept, artistLevelOnly: true)))
        out.fetchedMask &= ~DnaSource.spotifyGenres
        out.updatedAtMs = nowMs
        return out
    }

    public struct Result: Sendable {
        public var track: TrackDnaRow
        public var artist: ArtistDnaRow?
    }

    private static let artistSources = DnaSource.musicbrainz | DnaSource.listenbrainz | DnaSource.wikidata | DnaSource.spotifyGenres

    /// Builds the stored rows. `prior` and `priorArtist` are what is on disk (nil on a first run); `nowMs` stamps the
    /// parts that were refreshed; `maxYear` is the current year plus one.
    public static func assemble(target: DnaTarget, evidence: DnaEvidence, prior: TrackDnaRow?, priorArtist: ArtistDnaRow?,
                                atlas: GenreAtlas, atlasVersion: Int, nowMs: Int64, maxYear: Int,
                                measured: AudioFeatures.Result? = nil) -> Result {
        var tried = evidence.tried
        if !target.spotifyGenres.isEmpty, !target.spotifyOff { tried |= DnaSource.spotifyGenres }
        if !target.chipGenres.isEmpty { tried |= DnaSource.youtubeChips }
        let fresh = claimsOf(target, evidence, atlas)
        let priorClaims = prior.flatMap { $0.atlasVersion == atlasVersion ? decodeClaims([UInt8]($0.tagInputs)) : nil } ?? []
        // The artist: only the artist-level claims, kept per artist so a track with no tags of its own can borrow them
        // (3.4), and so a second track by the same artist does not ask again for what the first one learned.
        let priorArtistClaims = priorArtist.flatMap { $0.atlasVersion == atlasVersion ? decodeClaims([UInt8]($0.tagInputs)) : nil } ?? []
        let drop = replacedBy(target, evidence)
        let artistClaims = replaceClaims(priorArtistClaims, fresh.filter { isArtistLevel($0.provider) }, drop)
            .filter { isArtistLevel($0.provider) }
        let ownClaims = replaceClaims(priorClaims, fresh, drop)
        let have = Set(ownClaims.map(\.provider))
        let claims = ownClaims + artistClaims.filter { !have.contains($0.provider) }
        let ownTags = merged(atlas, claims, artistLevelOnly: false)
        let artistTags = merged(atlas, artistClaims, artistLevelOnly: true)
        let tags = ownTags.isEmpty ? Tags.fromArtist(artistTags) : ownTags

        // Year: every source's claim, the earliest believable wins; a source that answered replaces its old claim.
        let answered = yearSourcesOf(tried)
        let oldYear = parseClaims(prior?.yearClaims ?? "").filter { !answered.contains($0.0) }
        var newYear: [(Int, Int)] = []
        if let d = evidence.mb?.firstReleaseDate { let y = TrackDna.parseYear(d); if y > 0 { newYear.append((TrackDna.yearMusicBrainz, y)) } }
        if let lb = evidence.lb { let y = TrackDna.parseYear(lb.firstReleaseDate); if y > 0 { newYear.append((TrackDna.yearMusicBrainz, y)) } }
        if let d = evidence.itunes?.releaseDate { let y = TrackDna.parseYear(d); if y > 0 { newYear.append((TrackDna.yearITunes, y)) } }
        if let d = evidence.deezerTrack?.releaseDate { let y = TrackDna.parseYear(d); if y > 0 { newYear.append((TrackDna.yearDeezer, y)) } }
        // Spotify's album date and the YouTube row's year are facts the app already holds: they are claims on every pass.
        var own: [(Int, Int)] = []
        let spotifyYear = target.spotifyOff ? 0 : TrackDna.parseYear(target.spotifyReleaseDate)
        if spotifyYear > 0 { own.append((TrackDna.yearSpotify, spotifyYear)) }
        if target.ytYear > 0 { own.append((TrackDna.yearYouTube, target.ytYear)) }
        let kept = oldYear.filter { $0.0 != TrackDna.yearSpotify && $0.0 != TrackDna.yearYouTube }
        let yearClaims = kept + newYear + own
        let year = TrackDna.mergeYear(yearClaims.map { TrackDna.YearClaim(source: $0.0, year: $0.1) }, maxYear: maxYear)

        // Popularity: Deezer's rank, the YouTube play count, ListenBrainz's listeners.
        let oldPop: [String] = (prior?.popClaims ?? "").split(separator: ",").map(String.init).filter {
            let u = Array($0.utf8)
            return u.count > 2 && u[1] == 0x3A
        }
        func oldClaim(_ prefix: Character) -> Int {
            for s in oldPop where s.first == prefix { return Int(s.dropFirst(2)) ?? -1 }
            return -1
        }
        let dz = evidence.deezerTrack.map { TrackDna.popFromDeezerRank($0.rank) } ?? oldClaim("d")
        let yt = target.ytPlays > 0 ? TrackDna.popFromPlays(target.ytPlays) : oldClaim("y")
        let lbPop = evidence.lbPopularity.map { TrackDna.popFromListeners($0.users) } ?? oldClaim("l")
        let pop = TrackDna.mergePopularity(deezer: dz, youtube: yt, listenBrainz: lbPop)
        var popParts: [String] = []
        if dz >= 0 { popParts.append("d:\(dz)") }
        if yt >= 0 { popParts.append("y:\(yt)") }
        if lbPop >= 0 { popParts.append("l:\(lbPop)") }
        let popRefreshed = evidence.deezerTrack != nil || evidence.lbPopularity != nil || target.ytPlays > 0

        // Tempo and loudness (3.3, stage 5): a trusted on-device measurement (`measured`), then Deezer, then a weak measurement;
        // Deezer's gain, then the measured loudness. A tempo another source left in the row (AcousticBrainz) stays while nothing
        // better is known.
        var bpm: Int?
        if let b = evidence.deezerTrack?.bpm, b > 0.0 { bpm = Int(b * 10.0 + 0.5) }
        let deezerBpm = bpm ?? ((prior?.tempoSource == TrackDna.tempoDeezer) ? (prior?.tempoBpmX10 ?? 0) : 0)
        let chosen = AudioFeatures.chooseTempo(deezerBpm, measured)
        let keptOther: TrackDnaRow? = (prior?.tempoSource == TrackDna.tempoAcousticBrainz && (prior?.tempoBpmX10 ?? 0) > 0) ? prior : nil
        let tempo = chosen.source != TrackDna.tempoUnknown ? chosen.bpmX10 : (keptOther?.tempoBpmX10 ?? 0)
        let tempoSource = chosen.source != TrackDna.tempoUnknown ? chosen.source : (keptOther?.tempoSource ?? TrackDna.tempoUnknown)
        let deezerGain: Int
        if let g = evidence.deezerTrack?.gain { deezerGain = Int(BrainMath.floorToLong(g * 10.0 + 0.5)) } else { deezerGain = prior?.gainDbX10 ?? TrackDna.gainUnknown }
        let gain = AudioFeatures.chooseGain(deezerGain, measured).gainDbX10

        let feel = TrackDna.feel(atlas, tags, gainDbX10: gain, tempoBpmX10: tempo)
        let moods = TrackDna.moods(atlas, tags)
        let flags = Int(BrainText.cleanTitle(target.title).versionFlags)

        let explicitFlag: Bool? = target.spotifyExplicit ?? evidence.deezerTrack?.explicit ?? evidence.itunes?.explicit ?? target.ytExplicit
        let explicit: Int
        switch explicitFlag {
        case true?: explicit = 1
        case false?: explicit = 0
        case nil: explicit = prior?.explicit ?? -1
        }

        let sources = Set(claims.map { sourceOf($0.provider) }.filter { $0 != 0 }).count
        let confidence = tags.isEmpty ? 0 : min(255, sources * 64)
        // The tags' clock moves only when a source that carries genres answered: a weekly popularity refresh must not
        // keep them young.
        let tagsRefreshed = evidence.deezerAlbum != nil || evidence.mbArtist != nil || evidence.lb != nil || evidence.wd != nil
            || evidence.itunes != nil

        let artistIds = target.aid != 0 ? String(target.aid) : (prior?.artistIds ?? "")
        var albumKey = prior?.albumKey
        if let album = target.albumName, !BrainText.isBlank(album) { albumKey = BrainHash.id(BrainHash.fnv1a64(BrainText.fold(album))) }
        var videoIds: [String] = []
        for id in (target.videoId.map { [$0] } ?? []) + (prior?.ytAudioIds ?? "").split(separator: ",").map(String.init) {
            if BrainText.isBlank(id) || videoIds.contains(id) { continue }
            videoIds.append(id)
        }
        let artistCountry = (priorArtist?.country ?? "").isEmpty ? (evidence.mbArtist?.country ?? "") : (priorArtist?.country ?? "")

        let track = TrackDnaRow(
            rid: target.rid,
            spotifyId: target.spotifyId ?? prior?.spotifyId,
            isrc: target.isrc ?? evidence.deezerTrack?.isrc ?? evidence.mb?.isrcs.first ?? prior?.isrc,
            deezerId: evidence.deezerTrack?.id ?? prior?.deezerId,
            mbRecordingId: evidence.mb?.mbid ?? prior?.mbRecordingId,
            ytAudioIds: videoIds.prefix(6).joined(separator: ","),
            artistIds: artistIds,
            albumKey: albumKey,
            title: target.title,
            artistDisplay: target.artistDisplay,
            versionFlags: flags,
            firstYear: year.year,
            yearSource: year.source,
            durationMs: target.durationMs > 0 ? target.durationMs : (prior?.durationMs ?? 0),
            explicit: explicit,
            popPermille: pop,
            tempoBpmX10: tempo,
            tempoSource: tempoSource,
            gainDbX10: gain,
            scriptLang: TrackDna.scriptLang(target.title, artistCountry: artistCountry),
            tags: Data(Tags.encode(tags)),
            moods: Data(moods.map { UInt8(truncatingIfNeeded: $0) }),
            energy: feel.energy,
            valence: feel.valence,
            embVersion: prior?.embVersion ?? 0,
            confidence: confidence,
            fetchedMask: ((prior?.fetchedMask ?? 0) | tried) & ~(target.spotifyOff ? DnaSource.spotifyGenres : 0),
            updatedAtMs: nowMs,
            tagsAtMs: tagsRefreshed ? nowMs : (prior?.tagsAtMs ?? 0),
            popAtMs: popRefreshed ? nowMs : (prior?.popAtMs ?? 0),
            atlasVersion: atlasVersion,
            tagInputs: Data(encodeClaims(claims)),
            yearClaims: (kept + newYear).map { "\($0.0):\($0.1)" }.joined(separator: ","),
            popClaims: popParts.joined(separator: ","))

        var artist: ArtistDnaRow?
        if target.aid != 0 {
            var deezerArtist = priorArtist?.deezerId
            if let d = evidence.deezerTrack?.artistId, d != 0 { deezerArtist = d }
            artist = ArtistDnaRow(
                aid: target.aid,
                spotifyId: target.spotifyArtistIds.first ?? priorArtist?.spotifyId,
                ytChannelId: priorArtist?.ytChannelId,
                deezerId: deezerArtist,
                mbid: evidence.mb?.artistMbid ?? evidence.mbArtist?.mbid ?? priorArtist?.mbid,
                wikidataId: evidence.wd?.wikidataId ?? priorArtist?.wikidataId,
                name: target.artist,
                country: {
                    if let c = evidence.mbArtist?.country, !BrainText.isBlank(c) { return c }
                    return priorArtist?.country ?? ""
                }(),
                tags: Data(Tags.encode(artistTags)),
                popPermille: priorArtist?.popPermille ?? -1,
                releaseIds: priorArtist?.releaseIds ?? "",
                fetchedMask: ((priorArtist?.fetchedMask ?? 0) | (tried & artistSources)) & ~(target.spotifyOff ? DnaSource.spotifyGenres : 0),
                updatedAtMs: nowMs,
                tagsAtMs: (evidence.mbArtist != nil || evidence.lb != nil || evidence.wd != nil) ? nowMs : (priorArtist?.tagsAtMs ?? 0),
                atlasVersion: atlasVersion,
                tagInputs: Data(encodeClaims(artistClaims)))
        }
        return Result(track: track, artist: artist)
    }
}

extension DnaAssembler {
    /// `row` with its assistant claims replaced by `claims` (none removes them): the stored claims of every other source are kept and the
    /// tags are merged again, so the weakest source speaks only while the others are weak (3.4) and takes nothing away when they are not.
    /// Used by the optional tagging job (`AssistantHelp`) and by its undo when the switch is turned off. A port of Android's
    /// `DnaAssembler.withAssistantClaims`.
    public static func withAssistantClaims(_ row: TrackDnaRow, claims: [Claim], atlas: GenreAtlas, atlasVersion: Int, nowMs: Int64) -> TrackDnaRow {
        let prior = row.atlasVersion == atlasVersion ? decodeClaims([UInt8](row.tagInputs)) : []
        let all = prior.filter { $0.provider != pAssistant } + claims.filter { $0.provider == pAssistant }
        let tags = merged(atlas, all, artistLevelOnly: false)
        let feel = TrackDna.feel(atlas, tags, gainDbX10: row.gainDbX10)
        let moods = TrackDna.moods(atlas, tags)
        let sources = Set(all.map { sourceOf($0.provider) }.filter { $0 != 0 }).count
        var out = row
        out.tags = Data(Tags.encode(tags))
        out.moods = Data(moods.map { UInt8(truncatingIfNeeded: $0) })
        out.energy = feel.energy
        out.valence = feel.valence
        out.confidence = tags.isEmpty ? 0 : min(255, sources * 64)
        out.updatedAtMs = nowMs
        out.atlasVersion = atlasVersion
        out.tagInputs = Data(encodeClaims(all))
        return out
    }
}
