// "Use my Spotify music to shape picks" turned off means Spotify's artist genres and album years are not in the brain's
// picture of the listener any more. A port of Android's `SpotifyDnaPurge.kt`. Rows written while the switch was on carry
// them as stored claims, and a claim nobody replaces is kept for ever (a partial pass never wipes what an earlier one
// learned), so this runs once when the switch is found off: every row with such a claim is assembled again with the switch
// off, which drops the claims and re-merges tags, moods and the year. The islands are then due at once. Switching the
// switch on again clears the mark, so the next switch-off purges again. Files only, no network; the refresh job runs it.
//
// What stays: the Spotify track id and the ISRC (identifiers the app already holds in the library, not Spotify's content).

import Foundation
import PixlModel

public struct SpotifyDnaPurge: Sendable {
    public static let keyPurged = "dna_spotify_purged"

    private let shapesPicks: @Sendable () -> Bool
    private let store: DnaRepository
    private let atlas: any AtlasProvider
    private let state: StateValues
    private let clock: @Sendable () -> Int64

    public init(shapesPicks: @escaping @Sendable () -> Bool, store: DnaRepository, atlas: any AtlasProvider, state: StateValues,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.shapesPicks = shapesPicks
        self.store = store
        self.atlas = atlas
        self.state = state
        self.clock = clock
    }

    /// How many rows were rewritten (0 when the switch is on, the purge was done, or there was nothing to take out).
    /// `markRefit` is called when anything changed, so the islands are fitted again.
    @discardableResult
    public func run(markRefit: @Sendable () async -> Void) async -> Int {
        let on = shapesPicks()
        let done = await state.get(Self.keyPurged) == "1"
        if on {
            if done { await state.set(Self.keyPurged, "0") }
            return 0
        }
        if done { return 0 }
        guard let atlas = await atlas.atlas() else { return 0 }
        let carriers = await store.spotifyCarriers()
        if carriers.tracks.isEmpty && carriers.artists.isEmpty {
            await state.set(Self.keyPurged, "1")
            return 0
        }
        let now = clock()
        let maxYear = DnaEnricher.currentYear(now) + 1
        var changed = 0
        var artistsDone = Set<Int64>()
        let priorArtists = Dictionary(uniqueKeysWithValues: carriers.artists.map { ($0.aid, $0) })
        for row in carriers.tracks {
            if Task.isCancelled { return changed }
            let aid = Int64(row.artistIds.split(separator: ",").first ?? "") ?? 0
            let prior = await store.artists(aid != 0 ? [aid] : []).first
            let target = DnaTarget(
                rid: row.rid, aid: aid, spotifyId: row.spotifyId, isrc: row.isrc, title: row.title,
                artist: prior?.name ?? row.artistDisplay.components(separatedBy: ", ").first ?? row.artistDisplay,
                artistDisplay: row.artistDisplay, durationMs: row.durationMs,
                // A year the YouTube row gave is a fact the app holds, not Spotify's: it stays.
                ytYear: row.yearSource == TrackDna.yearYouTube ? row.firstYear : 0, spotifyOff: true)
            let result = DnaAssembler.assemble(target: target, evidence: DnaEvidence(), prior: row, priorArtist: prior, atlas: atlas,
                                               atlasVersion: atlas.version, nowMs: now, maxYear: maxYear)
            if await store.upsert(track: result.track, artist: result.artist) {
                changed += 1
                if let a = result.artist { artistsDone.insert(a.aid) }
            }
        }
        // Artist rows no track row led to (a track row that was dropped, an artist seen only by the radios).
        for (aid, row) in priorArtists where !artistsDone.contains(aid) {
            if let clean = DnaAssembler.withoutSpotify(row, atlas: atlas, atlasVersion: atlas.version, nowMs: now),
               await store.upsert(artist: clean) {
                changed += 1
            }
        }
        await state.set(Self.keyPurged, "1")
        if changed > 0 { await markRefit() }
        return changed
    }
}
