// "Pick three artists you love" (docs/brain-spec.md, 8.10), for a thin or empty library. A port of Android's `PickedArtists.kt`.
// A pick starts that artist's own radio (the artist page's button, the same call an artist station makes), whose songs and
// radio are cached as the artist's list, and the pick is kept as a seed: the mixes then have something of the listener's
// own to build from, so Your Mix and a Daily Mix exist before any play. One network round per pick, under the YouTube budget.
// The picks are one `brain_state` value (`picked_artists`), a line of JSON.

import Foundation
import PixlModel

/// An artist the listener said they love at the start, with the track their artist station starts from.
public struct PickedArtist: Codable, Sendable, Equatable {
    public var name: String
    public var seed: StoredRadioRow
    public var channelId: String

    public init(name: String, seed: StoredRadioRow, channelId: String) {
        self.name = name
        self.seed = seed
        self.channelId = channelId
    }
}

public actor PickedArtists {
    public static let key = "picked_artists"
    public static let picks = 3

    private let state: StateValues
    private let repository: BrainRepository
    private let clock: @Sendable () -> Int64
    private var busy = false

    public init(state: StateValues, repository: BrainRepository, clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.state = state
        self.repository = repository
        self.clock = clock
    }

    public func all() async -> [PickedArtist] {
        guard let text = await state.get(Self.key), let data = text.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([PickedArtist].self, from: data)) ?? []
    }

    public func hasPicks() async -> Bool { !(await all()).isEmpty }

    /// Starts the picked artists' radios. Returns the names that worked; the listener is told about the rest.
    public func pick(_ names: [String]) async -> [String] {
        while busy { await Task.yield() }
        busy = true
        defer { busy = false }
        var kept = await all()
        var worked: [String] = []
        var seen = Set<BrainKey>()
        for raw in names {
            let name = BrainText.trim(raw)
            if name.isEmpty || !seen.insert(BrainKey(name)).inserted { continue }
            guard let start = await repository.beginArtistStation(artistName: name) else { continue }
            let stored = StoredRadioRow(row: start.seedRow, rid: start.seedRid)
            await repository.registerPlayable([EngineTrack(row: start.seedRow, rid: start.seedRid)], nowMs: clock())
            kept.removeAll { BrainKey.sameBytes($0.name, name) }
            kept.append(PickedArtist(name: name, seed: stored, channelId: start.channelId))
            worked.append(name)
        }
        if !worked.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(kept) { await state.set(Self.key, String(decoding: data, as: UTF8.self)) }
        }
        return worked
    }
}
