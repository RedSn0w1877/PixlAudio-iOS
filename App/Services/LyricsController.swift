import Foundation
import Observation
import PixlLyrics
import PixlModel

/// The main-actor side of lyrics (Android `LyricsStateHolder` + the lyrics parts of `PlayerViewModel`): loads the
/// current song's lyrics through `LyricsService` into `LyricsStore`, builds the render-ready `PreparedLyrics` off the
/// main thread, keeps the per-song sync offset, and runs the fetch dialog's search flow. UI tests get the demo lyrics
/// (`-lyricsDemo`) and never touch the network.
@Observable
final class LyricsController {
    /// The fetch dialog (Android `LyricsSearchUiState`).
    nonisolated enum SearchState: Equatable, Sendable {
        case idle
        case loading
        case pickResult([LyricsSearchResult])
        case notFound(String)
        case error(String)
        case success
    }

    let store: LyricsStore
    let preferences: LyricsViewPreferences
    /// The karaoke model of `store`'s lyrics (nil while building, for plain lyrics, or with no lyrics).
    private(set) var prepared: PreparedLyrics?
    /// The song `prepared` belongs to.
    private(set) var preparedSongId: String?
    var searchState: SearchState = .idle
    /// A short message for the user (import refused, saved, translated…), shown briefly by the lyrics screen.
    var message: String?

    @ObservationIgnored private let service: LyricsService?
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let isUITest: Bool
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private(set) var loadedSongId: String?

    init(store: LyricsStore, settings: SettingsStore, persistence: PersistenceActor?, isUITest: Bool) {
        self.store = store
        self.settings = settings
        self.isUITest = isUITest
        preferences = LyricsViewPreferences.make(isUITest: isUITest)
        service = isUITest ? nil : LyricsService(persistence: persistence)
    }

    // MARK: Loading

    /// Loads `song`'s lyrics unless they are already loaded (call on every song change while lyrics matter).
    func ensureLoaded(for song: Song?) {
        guard let song else {
            loadTask?.cancel()
            loadedSongId = nil
            store.set(.idle)
            setLyrics(nil, songId: nil)
            return
        }
        if loadedSongId == song.id { return }
        load(song, forceRefresh: false)
    }

    func load(_ song: Song, forceRefresh: Bool) {
        loadTask?.cancel()
        loadedSongId = song.id
        store.offsetMs = preferences.offset(for: song.id)
        if isUITest {
            if let demo = LyricsDemoContent.lyrics(LyricsLaunchOptions.current.demo) {
                apply(LoadedLyrics(lyrics: demo, source: "demo"), songId: song.id)
            } else {
                store.set(.notFound(songId: song.id))
                setLyrics(nil, songId: song.id)
            }
            return
        }
        store.set(.loading(songId: song.id))
        guard let service else { return }
        let preference = LyricsSourcePreference(rawValue: settings.lyrics.sourcePreference) ?? .embeddedFirst
        let online = settings.lyrics.automaticLyrics
        loadTask = Task { [weak self] in
            let loaded = await service.lyrics(for: song, preference: preference, allowOnline: online,
                                              forceRefresh: forceRefresh)
            guard !Task.isCancelled, let self, self.loadedSongId == song.id else { return }
            if let loaded {
                self.apply(loaded, songId: song.id)
            } else {
                self.store.set(.notFound(songId: song.id))
                self.setLyrics(nil, songId: song.id)
            }
        }
    }

    private func apply(_ loaded: LoadedLyrics, songId: String) {
        store.set(.loaded(songId: songId, lyrics: loaded.lyrics, source: loaded.source))
        setLyrics(loaded.lyrics, songId: songId)
    }

    /// Builds the karaoke model off the main thread (Android `LyricsStateHolder.preparedLyrics`).
    private func setLyrics(_ lyrics: Lyrics?, songId: String?) {
        buildTask?.cancel()
        guard let lyrics, !(lyrics.synced ?? []).isEmpty || lyrics.document != nil else {
            prepared = nil
            preparedSongId = songId
            return
        }
        buildTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { PreparedLyricsBuilder.build(lyrics) }.value
            guard !Task.isCancelled, let self, self.loadedSongId == songId else { return }
            self.prepared = built
            self.preparedSongId = songId
        }
    }

    // MARK: Offset

    func setOffset(_ ms: Int, songId: String) {
        store.offsetMs = ms
        preferences.setOffset(ms, for: songId)
    }

    // MARK: Fetch dialog

    /// "Search": with `forcePick`, always show the picker; otherwise apply the best match.
    func searchOnline(song: Song, forcePick: Bool) {
        guard let service else {
            searchState = .notFound("\(song.title) \(song.displayArtist)")
            return
        }
        searchState = .loading
        Task { [weak self] in
            if forcePick {
                let result = await service.searchCandidates(song: song)
                guard let self else { return }
                switch result {
                case .success(let results): self.searchState = .pickResult(results)
                case .failure(let failure): self.searchState = Self.state(for: failure)
                }
            } else {
                let result = await service.fetchFromRemote(song: song)
                guard let self else { return }
                switch result {
                case .success(let loaded):
                    let saved = await service.saveOnline(song: song, lyrics: loaded.lyrics, source: loaded.source)
                    self.apply(saved ?? loaded, songId: song.id)
                    self.searchState = .success
                case .failure(let failure):
                    self.searchState = Self.state(for: failure)
                }
            }
        }
    }

    func manualSearch(title: String, artist: String?) {
        guard let service else { return }
        searchState = .loading
        Task { [weak self] in
            let result = await service.searchManual(title: title, artist: artist)
            guard let self else { return }
            switch result {
            case .success(let results): self.searchState = .pickResult(results)
            case .failure(let failure): self.searchState = Self.state(for: failure)
            }
        }
    }

    func pick(_ result: LyricsSearchResult, song: Song) {
        guard let service else { return }
        Task { [weak self] in
            let saved = await service.save(song: song, rawContent: result.rawLyrics, source: LyricsRepositoryLogic.lrclibSourceName,
                                           areFromRemote: true)
            guard let self else { return }
            if let saved, self.loadedSongId == song.id { self.apply(saved, songId: song.id) }
            self.searchState = .success
        }
    }

    func dismissSearch() { searchState = .idle }

    private static func state(for failure: LyricsSearchFailure) -> SearchState {
        switch failure {
        case .notFound(let query): return .notFound(query)
        case .network: return .error("Network error. Please check your internet connection.")
        }
    }

    // MARK: Import, reset, save

    func importFile(_ url: URL, song: Song) {
        guard let service else { return }
        Task { [weak self] in
            let result = await service.importFile(url, for: song)
            guard let self else { return }
            switch result {
            case .success(let loaded):
                if self.loadedSongId == song.id { self.apply(loaded, songId: song.id) }
                self.searchState = .success
            case .failure(let error):
                self.message = LyricsImportSecurity.message(for: error.reason)
            }
        }
    }

    /// "Reset imported lyrics": forget everything stored, then look again (sources only).
    func reset(song: Song) {
        guard let service else {
            store.set(.notFound(songId: song.id))
            setLyrics(nil, songId: song.id)
            return
        }
        Task { [weak self] in
            await service.reset(song: song)
            self?.load(song, forceRefresh: true)
        }
    }

    /// Whether the current lyrics carry translations / need romanisation (the More sheet's switches).
    var hasTranslatedLyrics: Bool {
        store.currentLyrics?.synced?.contains { !($0.translation ?? "").trimmingCharacters(in: .whitespaces).isEmpty } ?? false
    }

    var hasRomanizedLyrics: Bool {
        guard let lyrics = store.currentLyrics else { return false }
        let synced = lyrics.synced?.contains { !($0.romanization ?? "").trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        let plain = lyrics.plain?.contains { MultiLangRomanizer.isScriptThatNeedsRomanization($0) } ?? false
        return synced || plain
    }

    // MARK: Translation

    /// Attaches translations (index into `synced` → text) to the current lyrics and keeps them: line-synced lyrics are
    /// stored as LRC with a duplicate timestamp per translation (how Android pairs translations); word-synced and
    /// document lyrics keep them for this session.
    func applyTranslations(_ translations: [Int: String], song: Song) {
        guard var lyrics = store.currentLyrics, var synced = lyrics.synced, !translations.isEmpty else { return }
        for (index, text) in translations where synced.indices.contains(index) {
            synced[index].translation = text
        }
        lyrics.synced = synced
        let source = store.currentSource
        store.set(.loaded(songId: song.id, lyrics: lyrics, source: source))
        setLyrics(lyrics, songId: song.id)
        message = "Lyrics translated successfully!"
        guard let service, lyrics.document == nil, !synced.contains(where: { !($0.words ?? []).isEmpty }) else { return }
        var raw = ""
        for line in synced {
            let stamp = "[\(LyricsRepositoryLogic.formatTimestamp(line.time))]"
            raw += stamp + line.line + "\n"
            if let t = line.translation, !t.isEmpty { raw += stamp + t + "\n" }
        }
        Task { await service.save(song: song, rawContent: raw, source: source ?? "manual") }
    }
}
