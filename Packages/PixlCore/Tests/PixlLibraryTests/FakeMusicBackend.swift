import Foundation
import PixlLibrary

/// A `MusicBackend` that holds only what a test puts in it. Nothing is invented here: a track that is not in `catalog` is not found, a mix
/// is built from `mixTracks` in order, and every call is recorded so a test can say what the tools asked the engine for.
final class FakeMusicBackend: MusicBackend, @unchecked Sendable {
    var catalog: [String: AssistantTrack] = [:]
    var skipAfter = Int.max
    var mixTracks: [AssistantTrack] = []
    var unsupported: [String] = []
    var coldStart = false
    var explanation: AssistantTrackExplanation?
    var taste = AssistantTasteExplanation(scope: "summary", lines: [], unknown: [])
    var genre = AssistantGenreLookup()
    var similar = AssistantSimilarArtists(artists: [])
    var releases = AssistantReleaseList(releases: [])
    var stationOutcome = AssistantStationOutcome(started: false, firstTrack: nil, reason: "no")
    var steerOutcome = AssistantSteerOutcome(applied: false, tailChanged: 0, note: "no")

    var resolveCalls: [[(title: String, artist: String)]] = []
    var recommendQueries: [AssistantRules.Query] = []
    var mixQueries: [AssistantRules.Query] = []
    var stationCalls: [[String]] = []
    var steerCalls: [[String]] = []
    private var looked = 0

    private func key(_ title: String, _ artist: String) -> String {
        title.trimmingCharacters(in: .whitespaces).lowercased() + "|" + artist.trimmingCharacters(in: .whitespaces).lowercased()
    }

    @discardableResult
    func add(_ ref: String, _ title: String, _ artist: String, year: Int = 0, inLibrary: Bool = false) -> AssistantTrack {
        let t = AssistantTrack(ref: ref, title: title, artist: artist, year: year, inLibrary: inLibrary)
        catalog[key(title, artist)] = t
        return t
    }

    func resolve(_ items: [(title: String, artist: String)]) async -> [AssistantLookup] {
        resolveCalls.append(items)
        return items.map { item in
            defer { looked += 1 }
            if looked >= skipAfter { return AssistantLookup(track: nil, skipped: true) }
            return AssistantLookup(track: catalog[key(item.title, item.artist)])
        }
    }

    func recommend(_ query: AssistantRules.Query) async -> AssistantRecommendation {
        recommendQueries.append(query)
        return AssistantRecommendation(
            picks: mixTracks.prefix(query.count).map { AssistantPick(track: $0, whyKey: "radio_fans", whyArgs: ["Sabrina Carpenter"]) },
            unsupportedFilters: unsupported, coldStart: coldStart)
    }

    func buildMix(_ query: AssistantRules.Query) async -> AssistantMix? {
        mixQueries.append(query)
        builtQueries["m1"] = query
        if mixTracks.isEmpty { return nil }
        return AssistantMix(mixId: "m1", title: query.title.isEmpty ? "Made for you" : query.title,
                            tracks: mixTracks.prefix(query.count).map { AssistantPick(track: $0, whyKey: "asked") },
                            unsupportedFilters: unsupported, query: query)
    }

    var builtQueries: [String: AssistantRules.Query] = [:]
    var adjustCalls: [String] = []

    /// A chip is a delta on the stored request: the same list source, the new request, a new id.
    func adjustMix(mixId: String, chip: AssistantRules.Chip) async -> AssistantMix? {
        guard let stored = builtQueries[mixId] else { return nil }
        let next = AssistantRules.applyChip(stored, chip)
        adjustCalls.append(mixId)
        let id = "m(adjustCalls.count + 1)"
        builtQueries[id] = next
        return AssistantMix(mixId: id, title: next.title, tracks: mixTracks.prefix(next.count).map { AssistantPick(track: $0, whyKey: "asked") },
                            unsupportedFilters: unsupported, query: next)
    }

    func startStation(seedRef: String, seedKind: String, mode: String) async -> AssistantStationOutcome {
        stationCalls.append([seedRef, seedKind, mode])
        return stationOutcome
    }

    func steer(change: String, target: String, scope: String) async -> AssistantSteerOutcome {
        steerCalls.append([change, target, scope])
        return steerOutcome
    }

    func explainTrack(ref: String) async -> AssistantTrackExplanation? { explanation }
    func explainTaste(scope: String) async -> AssistantTasteExplanation { taste }
    func lookupGenre(_ query: String) async -> AssistantGenreLookup { genre }
    func similarArtists(artist: String, count: Int, onlyUnplayed: Bool) async -> AssistantSimilarArtists { similar }
    func newReleases(scope: String, count: Int) async -> AssistantReleaseList { releases }
}
