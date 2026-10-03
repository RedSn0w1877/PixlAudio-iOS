import Foundation
import PixlLyrics
import PixlModel
import PixlNet
import PixlTags

/// Where a song's lyrics came from (the More sheet's debug info and the "Lyrics: …" footer).
nonisolated struct LoadedLyrics: Sendable, Equatable {
    var lyrics: Lyrics
    /// "user", "BiniLyrics", "AMLL TTML", "NetEase YRC", "LRCLIB", "embedded", "local", "cache", …
    var source: String
    /// The catalog's own text, stored instead of the parsed lyrics: a BiniLyrics TTML keeps the translations and
    /// romanisations the lyrics JSON has no place for.
    var rawContent: String? = nil
}

/// Why an online search failed (Android `LyricsSearchUiState.NotFound/Error` messages).
nonisolated enum LyricsSearchFailure: Error, Sendable, Equatable {
    case notFound(query: String)
    case network(String)
}

/// Why an import was refused (`LyricsImportSecurity`'s reason).
nonisolated struct LyricsImportError: Error, Sendable, Equatable {
    let reason: LyricsImportFailureReason
}

/// Port of Android's `LyricsRepositoryImpl` on iOS: stored lyrics (the `lyrics` table, then the JSON disk cache,
/// then the song's own embedded text), then the sources in the user's order (embedded tags, online catalogs, a local
/// `.lrc` next to the file), the JSON cache of online results, the user-synced protection, imports, resets and the
/// manual search. All work happens on this actor or the network; nothing touches the main thread.
actor LyricsService {
    private let persistence: PersistenceActor?
    private let catalogs: LyricsCatalogSearch
    private let lrclib: LrcLibClient
    private let cacheDirectory: URL?
    private let romanization: any CJKRomanizationProvider
    /// Picks among a BiniLyrics document's translations.
    private let preferredLanguages: [String]
    /// Android keeps an in-memory `LruCache` of parsed lyrics.
    private var memory: [String: LoadedLyrics] = [:]
    private var memoryOrder: [String] = []
    private static let memoryLimit = 64

    /// `biniLyricsHTTP` must not follow redirects by itself (`BiniLyricsClient` checks every hop).
    init(persistence: PersistenceActor?, http: any HTTPClient = URLSessionHTTPClient(),
         biniLyricsHTTP: any HTTPClient = LyricsNetwork.biniLyricsHTTPClient(),
         cacheDirectory: URL? = LyricsService.defaultCacheDirectory(),
         romanization: any CJKRomanizationProvider = AppleCJKRomanization(),
         preferredLanguages: [String] = Locale.preferredLanguages) {
        self.persistence = persistence
        self.romanization = romanization
        self.preferredLanguages = preferredLanguages
        let lrclib = LrcLibClient(http: http, romanization: romanization)
        self.lrclib = lrclib
        catalogs = LyricsCatalogSearch(bini: BiniLyricsClient(http: biniLyricsHTTP, romanization: romanization,
                                                              preferredLanguages: preferredLanguages),
                                       amll: AmllLyricsClient(http: http, romanization: romanization),
                                       netease: NeteaseLyricsClient(http: http), lrclib: lrclib)
        self.cacheDirectory = cacheDirectory
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    /// Application Support/lyrics (Android `filesDir/lyrics/<songId>.json`).
    nonisolated static func defaultCacheDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("lyrics", isDirectory: true)
    }

    // MARK: Loading

    /// `getLyrics`: memory, stored, then the sources in `preference` order. `allowOnline` false skips the catalogs
    /// (the "automatic lyrics" setting is off). `remember` false is a probe (`AutomaticStudioRunner` checking songs):
    /// it reads the memory cache but never adds to it, so it neither evicts the lyrics the person opened nor leaves an
    /// offline-only result there for a later online load to return.
    func lyrics(for song: Song, preference: LyricsSourcePreference, allowOnline: Bool,
                forceRefresh: Bool = false, remember shouldRemember: Bool = true) async -> LoadedLyrics? {
        if !forceRefresh, let hit = memory[song.id] { return hit }
        if !forceRefresh, let stored = await storedLyricsAsync(for: song) {
            if shouldRemember { remember(stored, for: song.id) }
            return stored
        }
        let order: [LyricsSourceKind] = LyricsRepositoryLogic.sourceOrder(for: preference)
        for kind in order {
            if Task.isCancelled { return nil }
            let found: LoadedLyrics?
            switch kind {
            case .embedded: found = embeddedLyrics(for: song)
            case .local: found = localLyricsFile(for: song)
            case .api: found = allowOnline ? await onlineLyrics(for: song) : nil
            }
            if let found, LyricsRepositoryLogic.isUsable(found.lyrics) {
                if shouldRemember { remember(found, for: song.id) }
                if kind == .api && !isUserSynced(song) {
                    writeJSONCache(found.lyrics, rawContent: found.rawContent, songId: song.id)
                }
                return found
            }
        }
        return nil
    }

    // MARK: Sources

    /// Stored text → lyrics. A BiniLyrics TTML is read with `TtmlDocumentParser` (background vocals, duets,
    /// translations); everything else with `LyricsUtils.parseLyrics`, as on Android.
    private func parse(_ raw: String) -> (lyrics: Lyrics, isBiniLyrics: Bool) {
        if BiniLyricsMatching.isBiniLyricsDocument(raw),
           let rich = TtmlDocumentParser.parse(raw, metadata: LyricsMetadata(source: BiniLyricsMatching.sourceName),
                                               preferredLanguages: preferredLanguages, romanization: romanization) {
            return (rich, true)
        }
        return (LyricsUtils.parseLyrics(raw, romanization: romanization), false)
    }

    private func parseStored(_ raw: String, source: String) -> LoadedLyrics? {
        let read = parse(raw), isBiniLyrics = read.isBiniLyrics
        var parsed = read.lyrics
        guard LyricsRepositoryLogic.isUsable(parsed) else { return nil }
        parsed.areFromRemote = false
        let fallback = isBiniLyrics ? BiniLyricsMatching.sourceName : source
        return LoadedLyrics(lyrics: parsed, source: parsed.document?.metadata.source ?? fallback,
                            rawContent: isBiniLyrics ? raw : nil)
    }

    private func embeddedLyrics(for song: Song) -> LoadedLyrics? {
        if let url = Self.fileURL(for: song), let region = TagRegionReader.read(url: url),
           let tags = try? AudioTagReader.read(region) {
            if let lrc = tags.syncedLyrics.first?.lrcText(), let parsed = parseStored(lrc, source: "embedded"),
               !(parsed.lyrics.synced ?? []).isEmpty {
                return parsed
            }
            if let best = LyricsRepositoryLogic.parseBestEmbeddedLyricsField(tags.properties.dictionary,
                                                                             romanization: romanization) {
                return LoadedLyrics(lyrics: best, source: "embedded")
            }
        }
        if let text = song.lyrics, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return parseStored(text, source: "embedded")
        }
        return nil
    }

    /// `findLocalLyricsFile`: `<file name>.<ext>` next to the audio, then `<Artist>_<Title>.<ext>`.
    private func localLyricsFile(for song: Song) -> LoadedLyrics? {
        guard let url = Self.fileURL(for: song), url.isFileURL else { return nil }
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        func clean(_ s: String) -> String {
            String(s.unicodeScalars.map { scalar -> Character in
                let v = scalar.value
                let alnum = (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
                return alnum ? Character(scalar) : "_"
            })
        }
        let alternative = "\(clean(song.displayArtist))_\(clean(song.title))"
        for name in [base, alternative] {
            for ext in LyricsImportSecurity.supportedFileExtensions() {
                let candidate = directory.appendingPathComponent("\(name).\(ext)")
                guard FileManager.default.isReadableFile(atPath: candidate.path) else { continue }
                if case .valid(let validated) = LyricsImportSecurity.validateLocalLyricsFile(at: candidate) {
                    var lyrics = validated.parsedLyrics
                    lyrics.areFromRemote = false
                    return LoadedLyrics(lyrics: lyrics, source: "local")
                }
            }
        }
        return nil
    }

    /// `fetchLyricsFromAPI`: the JSON disk cache, then BiniLyrics, AMLL, NetEase and LRCLIB in parallel (word-synced
    /// first, BiniLyrics first among equals).
    private func onlineLyrics(for song: Song) async -> LoadedLyrics? {
        if let cached = readJSONCache(songId: song.id) { return cached }
        let isrc = await songISRC(for: song)
        guard let found = await catalogs.find(song: song, isrc: isrc, syncedOnly: false) else { return nil }
        return Self.loaded(found)
    }

    private static func loaded(_ found: OnlineSyncedLyrics) -> LoadedLyrics {
        var lyrics = found.lyrics
        lyrics.areFromRemote = true
        return LoadedLyrics(lyrics: lyrics, source: found.source, rawContent: found.rawContent)
    }

    /// The song's ISRC, for BiniLyrics' direct lookup: a Spotify track's (from its synced record), else a local
    /// file's tag (ID3 `TSRC`, MP4 `----:com.apple.iTunes:ISRC` or Vorbis `ISRC`, all mapped to `ISRC`).
    private func songISRC(for song: Song) async -> String? {
        if let spotifyId = song.spotifyId, let record = try? await persistence?.spotifySong(spotifyId: spotifyId),
           let isrc = BiniLyricsMatching.normalizedISRC(record.isrc) {
            return isrc
        }
        guard let url = Self.fileURL(for: song), let region = TagRegionReader.read(url: url),
              let tags = try? AudioTagReader.read(region) else { return nil }
        return tags.properties.dictionary["ISRC"]?.lazy.compactMap(BiniLyricsMatching.normalizedISRC).first
    }

    // MARK: Manual search (the fetch dialog)

    /// `searchRemote`: candidate-ranked LRCLIB results for the song.
    func searchCandidates(song: Song) async -> Result<[LyricsSearchResult], LyricsSearchFailure> {
        let (query, results) = await lrclib.searchCandidates(song: song)
        return results.isEmpty ? .failure(.notFound(query: query)) : .success(results)
    }

    /// `searchRemoteByQuery`.
    func searchManual(title: String, artist: String?) async -> Result<[LyricsSearchResult], LyricsSearchFailure> {
        let (query, results) = await lrclib.searchManual(title: title, artist: artist)
        return results.isEmpty ? .failure(.notFound(query: query)) : .success(results)
    }

    /// `fetchFromRemote` (the dialog's "Search" with auto-apply): catalogs first, then the best LRCLIB candidate.
    func fetchFromRemote(song: Song) async -> Result<LoadedLyrics, LyricsSearchFailure> {
        if let found = await catalogs.find(song: song, isrc: await songISRC(for: song), syncedOnly: false) {
            return .success(Self.loaded(found))
        }
        do {
            if let result = try await lrclib.fetchFromRemote(song: song) {
                var lyrics = result.lyrics
                lyrics.areFromRemote = true
                return .success(LoadedLyrics(lyrics: lyrics, source: LyricsRepositoryLogic.lrclibSourceName))
            }
            return .failure(.notFound(query: "\(song.title) \(song.displayArtist)"))
        } catch {
            return .failure(.network(String(describing: error)))
        }
    }

    // MARK: Writing

    /// `updateLyrics(song, content, source)`: the table, the JSON cache and memory. Returns the parsed lyrics, or nil
    /// when the content holds nothing usable.
    @discardableResult
    func save(song: Song, rawContent: String, source: String, areFromRemote: Bool = false) async -> LoadedLyrics? {
        let read = parse(rawContent), isBiniLyrics = read.isBiniLyrics
        var parsed = read.lyrics
        guard LyricsRepositoryLogic.isUsable(parsed) else { return nil }
        parsed.areFromRemote = areFromRemote
        let isSynced = !(parsed.synced ?? []).isEmpty
        try? await persistence?.saveLyrics(songId: song.id, content: rawContent, isSynced: isSynced, source: source,
                                           updatedAt: Int64(Date().timeIntervalSince1970 * 1000))
        writeJSONCache(parsed, rawContent: isBiniLyrics ? rawContent : nil, songId: song.id)
        let loaded = LoadedLyrics(lyrics: parsed, source: parsed.document?.metadata.source ?? source,
                                  rawContent: isBiniLyrics ? rawContent : nil)
        remember(loaded, for: song.id)
        return loaded
    }

    /// Saves lyrics chosen from a search result or the catalogs (never over the user's own sync unless asked).
    /// `rawContent` (a catalog's own text, e.g. a BiniLyrics TTML) is stored instead of the parsed lyrics.
    @discardableResult
    func saveOnline(song: Song, lyrics: Lyrics, source: String, rawContent: String? = nil,
                    overrideUser: Bool = true) async -> LoadedLyrics? {
        if !overrideUser, await isUserSyncedStored(song) { return nil }
        guard let raw = rawContent ?? LyricsRepositoryLogic.lyricsToRawContent(lyrics) else { return nil }
        return await save(song: song, rawContent: raw, source: source, areFromRemote: true)
    }

    /// `resetLyrics`: drops the stored row, the JSON cache and memory.
    func reset(song: Song) async {
        try? await persistence?.deleteLyrics(songId: song.id)
        if let url = jsonCacheURL(songId: song.id) { try? FileManager.default.removeItem(at: url) }
        memory[song.id] = nil
        memoryOrder.removeAll { $0 == song.id }
    }

    /// Imports a lyrics file the user picked (`LyricsImportSecurity` checks size, type and content).
    func importFile(_ url: URL, for song: Song) async -> Result<LoadedLyrics, LyricsImportError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return .failure(LyricsImportError(reason: .emptyContent)) }
        let result = LyricsImportSecurity.validateImportedLyricsFile(fileName: url.lastPathComponent, mimeType: nil,
                                                                    bytes: [UInt8](data))
        switch result {
        case .valid(let validated):
            if let saved = await save(song: song, rawContent: validated.sanitizedContent, source: "import") {
                return .success(saved)
            }
            return .failure(LyricsImportError(reason: .invalidLyricsContent))
        case .invalid(let reason):
            return .failure(LyricsImportError(reason: reason))
        }
    }

    /// Whether the user synced this song themselves (`isUserSynced`): the stored row decides, else the JSON cache.
    func isUserSyncedStored(_ song: Song) async -> Bool {
        if let row = try? await persistence?.storedLyrics(songId: song.id) {
            return row.source == LyricsRepositoryLogic.userSource
                || LyricsRepositoryLogic.documentIsUserSynced(row.content)
        }
        return isUserSynced(song)
    }

    private func isUserSynced(_ song: Song) -> Bool {
        guard let document = readJSONCacheData(songId: song.id)?.lyricsDocument else { return false }
        return LyricsRepositoryLogic.documentIsUserSynced(document)
    }

    // MARK: Stored lookup

    /// `getStoredLyrics`: the `lyrics` table, the JSON cache, then the song's scanned text.
    func storedLyricsAsync(for song: Song) async -> LoadedLyrics? {
        if let row = try? await persistence?.storedLyrics(songId: song.id),
           let parsed = parseStored(row.content, source: row.source ?? "manual") {
            return parsed
        }
        if let data = readJSONCacheData(songId: song.id), let raw = data.preferredRawLyrics,
           let parsed = parseStored(raw, source: "cache") {
            return parsed
        }
        if let text = song.lyrics, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let parsed = parseStored(text, source: "embedded") {
            return parsed
        }
        return nil
    }

    // MARK: JSON cache (Android `LyricsData` files)

    private func jsonCacheURL(songId: String) -> URL? {
        let safe = String(songId.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "." ? Character(scalar) : "_"
        })
        return cacheDirectory?.appendingPathComponent("\(safe).json")
    }

    private func readJSONCacheData(songId: String) -> LyricsCacheData? {
        guard let url = jsonCacheURL(songId: songId), let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return LyricsCacheData.decode(json)
    }

    private func readJSONCache(songId: String) -> LoadedLyrics? {
        guard let data = readJSONCacheData(songId: songId), data.hasLyrics, let raw = data.preferredRawLyrics else {
            return nil
        }
        guard var loaded = parseStored(raw, source: "cache") else { return nil }
        loaded.lyrics.areFromRemote = true
        return loaded
    }

    /// `rawContent` (a BiniLyrics TTML) takes the record's richest slot, so a reload reads it back with its
    /// translations; the plain and LRC slots still hold the parsed text.
    private func writeJSONCache(_ lyrics: Lyrics, rawContent: String? = nil, songId: String) {
        guard let url = jsonCacheURL(songId: songId) else { return }
        var record = LyricsCacheData(lyrics: lyrics)
        if let rawContent { record.lyricsDocument = rawContent }
        let json = record.encodedJSON()
        try? Data(json.utf8).write(to: url, options: [.atomic])
    }

    // MARK: Helpers

    private func remember(_ loaded: LoadedLyrics, for songId: String) {
        if memory[songId] == nil { memoryOrder.append(songId) }
        memory[songId] = loaded
        if memoryOrder.count > Self.memoryLimit {
            let evicted = memoryOrder.removeFirst()
            memory[evicted] = nil
        }
    }

    /// The song's audio file, when it is a local file.
    nonisolated static func fileURL(for song: Song) -> URL? {
        guard let url = DefaultPlayableURLResolver.url(for: song), url.isFileURL else { return nil }
        return url
    }
}
