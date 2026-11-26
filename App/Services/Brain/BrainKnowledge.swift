import Foundation
import PixlBackup
import PixlLibrary
import PixlModel

/// The app's side of the brain's knowledge layer (docs/brain-spec.md, 3.3 to 3.5 and 3.7, stage 2b): the genre atlas read
/// from the bundle, the five open-data sources with their switches, and the DNA lanes the one refresh runs. Every
/// decision is in PixlLibrary (`Knowledge/`); this file only supplies the network, the switches and the asset.
///
/// Nothing here runs at app start: the atlas is read and parsed the first time the refresh or the Brain data screen asks
/// for a genre, off the main actor, and the sources are asked only inside the refresh.

/// `URLSession` with the app's User-Agent: it names the app and its public project page, never the listener. No cookies, no
/// cache, no account.
nonisolated struct KnowledgeURLTransport: KnowledgeTransport {
    /// Made on the first request (a static is initialised on first use), never at app start.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private let userAgent: String

    init(version: String) { userAgent = KnowledgeUserAgent.value(version: version) }

    func send(_ request: KnowledgeRequest) async throws -> KnowledgeReply {
        guard let url = URL(string: request.url) else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        if let body = request.body {
            urlRequest.httpBody = Data(body.utf8)
            if let type = request.contentType { urlRequest.setValue(type, forHTTPHeaderField: "Content-Type") }
        }
        let (data, response) = try await Self.session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
        return KnowledgeReply(code: http.statusCode, body: String(decoding: data, as: UTF8.self), retryAfterSec: retry)
    }
}

/// The owner's off switches of the open-data sources: the local one (Settings › Developer mode › Brain data, default on)
/// AND the remote one (`brain.sources.<key>.enabled` in the saved remote config). Asked before every request, so flipping
/// either stops the very next one.
nonisolated struct BrainSourceSwitch: KnowledgeSwitch {
    func sourceAllowed(_ host: KnowledgeHost) async -> Bool {
        Self.localEnabled(host) && BrainRemoteFlags.sourceAllowed(host.key)
    }

    static func localEnabled(_ host: KnowledgeHost) -> Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.brainSourceEnabled(host.key)) as? Bool ?? true
    }

    static func setLocalEnabled(_ host: KnowledgeHost, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: PreferenceKeys.brainSourceEnabled(host.key))
    }
}

/// The request ledger's small values live in the brain's own `brain_state`.
nonisolated struct BrainStateValueStore: KnowledgeValueStore {
    let engine: BrainEngine
    func value(_ key: String) async -> String? { await engine.storedValue(key) }
    func setValue(_ key: String, _ value: String?) async { await engine.setStoredValue(key, value) }
}

/// The bundled atlas (`genre-atlas-v1.json.gz`, byte for byte the file Android ships): gunzipped with the package's own
/// inflate and parsed once, on whatever background task asks first.
nonisolated enum GenreAtlasAsset {
    static func load() -> GenreAtlas? {
        let started = currentTimeMillis()
        guard let url = Bundle.main.url(forResource: "genre-atlas-v1.json", withExtension: "gz"),
              let data = try? Data(contentsOf: url) else {
            DiagnosticsLog.shared.log("brain", "the genre atlas is not in the app")
            return nil
        }
        do {
            let text = try Gzip.decompress([UInt8](data))
            let atlas = try GenreAtlas.parse(utf8: text)
            // How long the first genre lookup costs on this phone (never at app start).
            DiagnosticsLog.shared.log("brain", "brain_atlas_load \(currentTimeMillis() - started) ms")
            return atlas
        } catch {
            DiagnosticsLog.shared.log("brain", "the genre atlas could not be read")
            return nil
        }
    }
}

/// Everything the knowledge layer owns, built once by `BrainService.configureKnowledge`.
nonisolated final class BrainKnowledge: Sendable {
    let dna: DnaRepository
    let atlas: CachedAtlasProvider
    let ledger: KnowledgeLedger
    let lanes: DnaLanes
    let reader: BrainDataReader
    /// Stage 5: tempo and loudness measured on the phone (`audio_measure.pbl`), read by the DNA assembly and the flow ordering.
    let measures: AudioMeasureRepository

    init(directory: URL, engine: BrainEngine, sources: DnaSources, repository: BrainRepository,
         youTubeToday: @escaping @Sendable () async -> Int, spotifyArtists: @escaping @Sendable () async -> (total: Int, withGenres: Int),
         timing: @escaping @Sendable (String, Int64) -> Void) {
        let dna = DnaRepository(directory: directory)
        let measures = AudioMeasureRepository(directory: directory, dna: dna)
        self.measures = measures
        let atlas = CachedAtlasProvider { GenreAtlasAsset.load() }
        let ledger = KnowledgeLedger(store: BrainStateValueStore(engine: engine))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let http = GatedKnowledgeHttp(transport: KnowledgeURLTransport(version: version), allowed: BrainSourceSwitch(), ledger: ledger)
        self.dna = dna
        self.atlas = atlas
        self.ledger = ledger
        lanes = DnaLanes(targets: DnaTargets(sources: sources, repository: repository, engine: engine, store: dna),
                         enricher: DnaEnricher(http: http, store: dna, atlas: atlas, timing: timing, measures: measures),
                         purge: SpotifyDnaPurge(shapesPicks: sources.spotifyShapesPicks, store: dna, atlas: atlas,
                                                state: StateValues.of(engine)))
        reader = BrainDataReader(
            dna: dna, ledger: ledger, atlas: atlas,
            localEnabled: { BrainSourceSwitch.localEnabled($0) }, remoteAllowed: { BrainRemoteFlags.sourceAllowed($0.key) },
            youTubeToday: youTubeToday, spotifyArtists: spotifyArtists, spotifyShapes: sources.spotifyShapesPicks,
            lastNote: { await engine.storedValue(BrainRefresh.keyLast) })
    }
}
