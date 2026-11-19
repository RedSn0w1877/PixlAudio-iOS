// What Settings > Developer mode > Brain data shows (docs/brain-spec.md, 3.7 and 12): what the genre atlas and the track
// facts hold, how many requests each open-data source has had today, each source's own off switch with the terms it is
// used under, and what the Spotify sync returned for artist genres. A port of Android's `BrainDataViewModel.kt`; the
// decisions live here, the screen only draws them. Read when the screen opens: nothing here runs at app start.

import Foundation
import PixlModel

public struct BrainDataReport: Sendable, Equatable {
    public struct SourceRow: Sendable, Equatable {
        public var host: KnowledgeHost
        public var enabled: Bool
        /// False when the remote config switches the source off for every phone.
        public var remoteAllowed: Bool
        public var requestsToday: Int
        public var lastRequestMs: Int64
        public var tracksAnswered: Int

        public init(host: KnowledgeHost, enabled: Bool, remoteAllowed: Bool, requestsToday: Int, lastRequestMs: Int64, tracksAnswered: Int) {
            self.host = host
            self.enabled = enabled
            self.remoteAllowed = remoteAllowed
            self.requestsToday = requestsToday
            self.lastRequestMs = lastRequestMs
            self.tracksAnswered = tracksAnswered
        }

        /// What the switch shows: on only when both the local switch and the remote config allow the source.
        public var switchIsOn: Bool { enabled && remoteAllowed }
    }

    public var atlasLoaded = false
    public var atlasVersion = 0
    public var atlasGenres = 0
    public var atlasDescribed = 0
    public var atlasFamilies = 0
    public var coverage = DnaCoverage()
    public var artistsKnown = 0
    public var artistsWithGenres = 0
    public var activeMisses = 0
    public var sources: [SourceRow] = []
    public var youTubeToday = 0
    public var youTubeLimit = HostBudget.dailyLimit
    public var spotifyArtistSeeds = 0
    public var spotifyArtistSeedsWithGenres = 0
    public var spotifyShapes = true
    public var lastRun: RefreshSchedule.Note?
    public var nowMs: Int64 = 0

    public init() {}
}

/// The words a number of minutes or a stop name becomes, kept out of the view so they are tested.
public enum BrainDataFormat {
    public enum Ago: Sendable, Equatable {
        case now
        case minutes(Int)
        case hours(Int)
        case days(Int)
    }

    /// `part` of `whole` as a whole percent (rounded down); 0 for an empty whole.
    public static func percent(_ part: Int, of whole: Int) -> Int { whole <= 0 ? 0 : Int(Int64(part) * 100 / Int64(whole)) }

    public static func ago(nowMs: Int64, thenMs: Int64) -> Ago {
        let minutes = max(0, (nowMs - thenMs) / 60_000)
        if minutes < 1 { return .now }
        if minutes < 60 { return .minutes(Int(minutes)) }
        if minutes < 60 * 48 { return .hours(Int(minutes / 60)) }
        return .days(Int(minutes / (60 * 24)))
    }

    public enum Stop: Sendable, Equatable {
        case done, off, playing, budget, time
    }

    /// The stop word of a run's note (`none`, `off`, `playing`, `budget`, `time`, `cancelled`; Android writes it in capitals).
    public static func stop(_ word: String) -> Stop {
        switch word.lowercased() {
        case "off": return .off
        case "playing": return .playing
        case "budget": return .budget
        case "time": return .time
        default: return .done
        }
    }
}

/// Reads the report. Every input is a closure, so the reader is tested without the app.
public struct BrainDataReader: Sendable {
    public var dna: DnaRepository
    public var ledger: KnowledgeLedger
    public var atlas: any AtlasProvider
    /// The local switch of a source (default on).
    public var localEnabled: @Sendable (KnowledgeHost) -> Bool
    /// False when the saved remote config switches the source off.
    public var remoteAllowed: @Sendable (KnowledgeHost) -> Bool
    /// YouTube Music's requests in the last 24 hours.
    public var youTubeToday: @Sendable () async -> Int
    /// The listener's top artists the Spotify sync saved, and how many of them came with genres.
    public var spotifyArtists: @Sendable () async -> (total: Int, withGenres: Int)
    public var spotifyShapes: @Sendable () -> Bool
    /// The note of the last refresh run (`brain_state` `refresh_last`).
    public var lastNote: @Sendable () async -> String?
    public var clock: @Sendable () -> Int64

    public init(dna: DnaRepository, ledger: KnowledgeLedger, atlas: any AtlasProvider,
                localEnabled: @escaping @Sendable (KnowledgeHost) -> Bool, remoteAllowed: @escaping @Sendable (KnowledgeHost) -> Bool,
                youTubeToday: @escaping @Sendable () async -> Int,
                spotifyArtists: @escaping @Sendable () async -> (total: Int, withGenres: Int),
                spotifyShapes: @escaping @Sendable () -> Bool, lastNote: @escaping @Sendable () async -> String?,
                clock: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.dna = dna
        self.ledger = ledger
        self.atlas = atlas
        self.localEnabled = localEnabled
        self.remoteAllowed = remoteAllowed
        self.youTubeToday = youTubeToday
        self.spotifyArtists = spotifyArtists
        self.spotifyShapes = spotifyShapes
        self.lastNote = lastNote
        self.clock = clock
    }

    public func read() async -> BrainDataReport {
        var r = BrainDataReport()
        let now = clock()
        r.nowMs = now
        if let a = await atlas.atlas() {
            r.atlasLoaded = true
            r.atlasVersion = a.version
            r.atlasGenres = a.size
            r.atlasFamilies = a.families.count
            r.atlasDescribed = a.allIds.filter { a.descriptor($0) != nil }.count
        }
        r.coverage = await dna.coverage()
        r.artistsKnown = await dna.artistCount()
        r.artistsWithGenres = await dna.artistCountWithTags()
        r.activeMisses = await dna.activeMissCount(nowMs: now)
        let today = await ledger.today()
        for host in KnowledgeHost.allCases {
            r.sources.append(BrainDataReport.SourceRow(
                host: host, enabled: localEnabled(host), remoteAllowed: remoteAllowed(host), requestsToday: today[host] ?? 0,
                lastRequestMs: await ledger.lastRequestMs(host),
                tracksAnswered: await dna.countFetchedBy(DnaSource.bit(of: host))))
        }
        r.youTubeToday = await youTubeToday()
        let seeds = await spotifyArtists()
        r.spotifyArtistSeeds = seeds.total
        r.spotifyArtistSeedsWithGenres = seeds.withGenres
        r.spotifyShapes = spotifyShapes()
        r.lastRun = RefreshSchedule.parseNote(await lastNote())
        return r
    }
}
