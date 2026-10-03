import Foundation
import PixlModel
import PixlNet
import SwiftData

/// Artist pictures (Android `ArtistImageRepository`): after the library loads or rescans, every artist without a
/// picture or a custom image is looked up on Deezer — three at a time, with Android's three attempts from 500 ms —
/// and the picture is stored on the artist (`ArtistRecord.imageUrl`), where Library › Artists, Search and the artist
/// page show it. A custom image the user picks on the artist page wins over it (`Artist.effectiveImageUrl`).
///
/// Android remembers failed lookups for the session; here a name Deezer doesn't know is also skipped for a week
/// across launches (no request per artist on every launch). UI tests never run it.
@MainActor
final class ArtistImageService {
    private let library: LibraryStore
    private let persistence: PersistenceActor?
    private let http: any HTTPClient
    private let defaults: UserDefaults
    private var running: Task<Void, Never>?
    /// Names already looked up (or being looked up) in this process.
    private var attempted = Set<String>()

    /// Normalised name → when Deezer last had no picture for it (ms since 1970).
    private static let missesKey = "artist_image_misses_v1"
    private static let missRetryMs: Int64 = 7 * 24 * 60 * 60 * 1000
    /// Lookups per batch: each batch's pictures land in the library together.
    private static let batchSize = 60

    init(library: LibraryStore, persistence: PersistenceActor?, http: any HTTPClient = URLSessionHTTPClient(),
         defaults: UserDefaults = .standard) {
        self.library = library
        self.persistence = persistence
        self.http = http
        self.defaults = defaults
    }

    /// Looks up the artists that have no picture yet (Android `prefetchArtistImages` after each artists emission).
    /// Cheap when there is nothing to do; one run at a time.
    func prefetchMissing() {
        guard running == nil, persistence != nil else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let misses = defaults.dictionary(forKey: Self.missesKey) as? [String: Double] ?? [:]
        var names: [String] = []
        var seen = Set<String>()
        for artist in library.snapshot.artists {
            guard (artist.imageUrl ?? "").isEmpty, (artist.customImageUri ?? "").isEmpty else { continue }
            let key = DeezerArtistImages.normalizedName(artist.name)
            guard !key.isEmpty, !Self.isPlaceholder(key), !attempted.contains(key), seen.insert(key).inserted else {
                continue
            }
            if let missedAt = misses[key], now - Int64(missedAt) < Self.missRetryMs { continue }
            names.append(artist.name)
        }
        guard !names.isEmpty else { return }
        attempted.formUnion(seen)
        running = Task { [weak self] in
            var start = 0
            while start < names.count, !Task.isCancelled {
                let batch = Array(names[start..<min(start + Self.batchSize, names.count)])
                start += Self.batchSize
                guard let self else { return }
                let outcomes = await Self.lookUp(batch, http: self.http)
                await self.apply(outcomes, now: now)
            }
            self?.running = nil
        }
    }

    /// "Unknown Artist" and friends have no picture to find.
    private static func isPlaceholder(_ key: String) -> Bool {
        key == "unknown artist" || key == "<unknown>" || key == "various artists" || key == "unknown"
    }

    /// Stores what a batch found: pictures on the artists (store and library), misses in the skip list.
    private func apply(_ outcomes: [(name: String, outcome: DeezerArtistImages.Outcome)], now: Int64) async {
        var pictures: [String: String] = [:]
        var misses = defaults.dictionary(forKey: Self.missesKey) as? [String: Double] ?? [:]
        for (name, outcome) in outcomes {
            switch outcome {
            case .picture(let url): pictures[name.lowercased()] = url
            case .noMatch: misses[DeezerArtistImages.normalizedName(name)] = Double(now)
            case .failed: break // a later launch tries again
            }
        }
        defaults.set(misses, forKey: Self.missesKey)
        guard !pictures.isEmpty, let persistence else { return }
        let images = pictures.map { StoredArtistImage(name: $0.key, imageUrl: $0.value, customImageUri: nil) }
        _ = try? await persistence.restoreArtistImages(images)
        var updated: [Artist] = []
        for artist in library.snapshot.artists {
            guard let url = pictures[artist.name.lowercased()], artist.imageUrl != url else { continue }
            var artist = artist
            artist.imageUrl = url
            updated.append(artist)
        }
        library.updateArtists(updated)
        library.writeSnapshotCache()
    }

    /// Runs the lookups off the main actor, `prefetchConcurrency` at a time.
    @concurrent
    private nonisolated static func lookUp(_ names: [String],
                                           http: any HTTPClient) async -> [(name: String, outcome: DeezerArtistImages.Outcome)] {
        await withTaskGroup(of: (String, DeezerArtistImages.Outcome).self) { group in
            var results: [(name: String, outcome: DeezerArtistImages.Outcome)] = []
            var next = 0
            while next < min(DeezerArtistImages.prefetchConcurrency, names.count) {
                let name = names[next]
                group.addTask { (name, await lookUp(name, http: http)) }
                next += 1
            }
            while let result = await group.next() {
                results.append((name: result.0, outcome: result.1))
                if next < names.count, !Task.isCancelled {
                    let name = names[next]
                    group.addTask { (name, await lookUp(name, http: http)) }
                    next += 1
                }
            }
            return results
        }
    }

    /// One artist, with Android's retry (`withNetworkRetry`: 3 attempts, 500 ms doubling) on transport errors and
    /// error answers. Spaced a little so three workers stay under Deezer's request quota.
    private nonisolated static func lookUp(_ name: String, http: any HTTPClient) async -> DeezerArtistImages.Outcome {
        var delayMs = DeezerArtistImages.retryInitialDelayMs
        for attempt in 1...DeezerArtistImages.retryAttempts {
            if Task.isCancelled { return .failed }
            var outcome = DeezerArtistImages.Outcome.failed
            if let response = try? await http.send(DeezerArtistImages.searchRequest(artistName: name)) {
                outcome = DeezerArtistImages.outcome(statusCode: response.statusCode, body: response.body)
            }
            if outcome != .failed {
                try? await Task.sleep(for: .milliseconds(250))
                return outcome
            }
            if attempt < DeezerArtistImages.retryAttempts {
                try? await Task.sleep(for: .milliseconds(delayMs))
                delayMs *= 2
            }
        }
        return .failed
    }
}

extension PersistenceActor {
    /// Sets the image fields of artists by id (a custom image picked or cleared on the artist page).
    func setArtistImages(_ artists: [Artist]) throws {
        let ids = artists.map(\.id)
        let byId = Dictionary(artists.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for record in try modelContext.fetch(FetchDescriptor<ArtistRecord>(predicate: #Predicate { ids.contains($0.id) })) {
            guard let artist = byId[record.id] else { continue }
            record.imageUrl = artist.imageUrl
            record.customImageUri = artist.customImageUri
        }
        try modelContext.save()
    }
}
