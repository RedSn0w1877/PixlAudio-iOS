import Foundation
import PixlLibrary
import PixlModel

/// Progress phases (Android `SyncProgress.SyncPhase`, in user-facing words).
nonisolated enum LibraryImportPhase {
    static let fetching = "Looking for music"
    static let processing = "Reading files"
    static let mediaLibrary = "Reading music library"
    static let saving = "Saving library"
    static let completing = "Done"
}

/// Errors of the folder operations.
nonisolated enum LibraryImportError: Error, Equatable, LocalizedError {
    case folderAlreadyAdded(String)
    case songNotFound

    var errorDescription: String? {
        switch self {
        case .folderAlreadyAdded(let name): "“\(name)” is already in your library."
        case .songNotFound: "That song isn't in your library any more."
        }
    }
}

/// Builds the library from local files and the device music library (stage 6, architecture §2 "Library import").
///
/// Sources: the app's Documents folder (always), folders the user picked (`FolderSourceRecord`, security-scoped
/// bookmarks, stale ones refreshed, scope kept open per root), and the DRM-free part of the music library once
/// access is granted. A scan enumerates every root with modification time / size / type, diffs by relative path
/// against the last scan (`ScanState`), reads only new and changed files (PixlTags + AVFoundation, four at a time),
/// re-applies tag overrides, splits artists and groups albums with PixlLibrary using the user's delimiter settings,
/// and writes the result as a diff through `PersistenceActor`. `LibraryStore.refresh` then reloads the snapshot
/// (and rewrites the snapshot cache).
///
/// Ported from Android `SyncWorker` / `MediaStoreSongRepository`: the minimum duration, the allow/block directory
/// rules, `.nomedia` folders, untagged-file defaults, deleted-file removal, and stable artist / album ids across
/// incremental scans.
actor LocalLibraryImporter: LibraryImporting {
    nonisolated struct Configuration: Sendable {
        var includeDocumentsFolder = true
        /// False in tests: never touch the device music library.
        var allowsMediaLibrary = true
        /// Scan state file; nil keeps it in memory only.
        var stateURL: URL? = ScanState.defaultURL()
        /// Fixed roots instead of Documents + bookmarks (tests).
        var fixedRoots: [FolderRoot]?
        /// Concurrent file reads (Android `SyncWorker` uses a semaphore of 4).
        var readConcurrency = 4
    }

    let persistence: PersistenceActor
    private let configuration: Configuration
    private let options: @Sendable () -> LibraryScanOptions
    private var running: (token: UUID, task: Task<LibraryImportSummary, any Error>)?
    private var memoryState: ScanState?
    /// Songs whose state was invalidated while a scan ran (applied when it saves).
    private var pendingInvalidations = Set<String>()

    init(persistence: PersistenceActor, configuration: Configuration = Configuration(),
         options: @escaping @Sendable () -> LibraryScanOptions = { LibraryScanOptions.current() }) {
        self.persistence = persistence
        self.configuration = configuration
        self.options = options
    }

    /// Installs the embedded-artwork reader into `ArtworkPipeline` (once, at launch).
    nonisolated static func installArtworkLoader() {
        ArtworkPipeline.embeddedArtworkLoader = { url in await EmbeddedArtworkReader.data(for: url) }
    }

    // MARK: LibraryImporting

    func importLibrary(mode: LibraryImportMode,
                       progress: @escaping @Sendable (LibraryImportProgress) -> Void) async throws -> LibraryImportSummary {
        if let current = running {
            if mode == .incremental { return try await current.task.value }
            // A full scan waits for the running one, then reads everything again.
            _ = try? await current.task.value
        }
        let token = UUID()
        let task = Task { try await self.scan(mode: mode, progress: progress) }
        running = (token, task)
        defer { if running?.token == token { running = nil } }
        return try await task.value
    }

    // MARK: Folder sources

    func folderSources() async throws -> [FolderSource] { try await persistence.folderSources() }

    /// The roots a scan walks right now (Documents first). Opens their security scopes.
    func currentRoots() async throws -> [FolderRoot] { try await resolveRoots().roots }

    /// Adds a folder picked with `fileImporter` (bookmark saved; scanned on the next refresh).
    func addFolder(_ url: URL) async throws -> FolderSource {
        let bookmark = try FolderBookmarks.makeBookmark(for: url)
        let existing = try await persistence.folderSources()
        for source in existing {
            if let resolved = try? FolderBookmarks.resolve(source.bookmark),
               resolved.url.standardizedFileURL == url.standardizedFileURL {
                throw LibraryImportError.folderAlreadyAdded(source.displayName)
            }
        }
        var taken = Set(existing.map { $0.displayName.lowercased() })
        if configuration.includeDocumentsFolder { taken.insert(FolderRoot.documentsDisplayName.lowercased()) }
        let base = url.lastPathComponent.isEmpty ? "Folder" : url.lastPathComponent
        var name = base
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        let source = try await persistence.addFolderSource(displayName: name, bookmark: bookmark, addedAt: Self.nowMs())
        FolderAccessRegistry.shared.open(id: source.id, url: url)
        return source
    }

    /// Removes a folder; its songs leave the library on the next scan.
    func removeFolder(id: String) async throws {
        try await persistence.removeFolderSource(id: id)
        FolderAccessRegistry.shared.release(id: id)
    }

    func setFolderEnabled(id: String, isEnabled: Bool) async throws {
        try await persistence.updateFolderSource(id: id, isEnabled: isEnabled)
        if !isEnabled { FolderAccessRegistry.shared.release(id: id) }
    }

    // MARK: Tag edits

    /// Saves a tag edit as an override (nil clears it); with `writeToFile`, also rewrites a folder song's file
    /// (MP3/FLAC/M4A) and keeps only what the format couldn't store as the override. Takes effect on the next scan.
    func editTags(songId: String, fields: TagOverrideFields?, writeToFile: Bool = false,
                  extras: TagWriteExtras = TagWriteExtras()) async throws {
        var remaining = fields
        if writeToFile, let fields, !fields.isEmpty, songId.hasPrefix(LibraryIdentity.filePrefix) {
            let snapshot = try await persistence.loadLibrarySnapshot()
            guard let song = snapshot.songs.first(where: { $0.id == songId }),
                  let url = URL(string: song.contentUriString) else { throw LibraryImportError.songNotFound }
            remaining = try await TagWriteBack.write(fields, to: url, current: song, extras: extras)
        }
        try await persistence.setTagOverride(songId: songId, fields: remaining, updatedAt: Self.nowMs())
        invalidate(songId)
    }

    private func invalidate(_ songId: String) {
        pendingInvalidations.insert(songId)
        var state = loadState()
        state.invalidate(songId)
        saveState(state)
    }

    // MARK: Scan

    private func scan(mode: LibraryImportMode,
                      progress: @escaping @Sendable (LibraryImportProgress) -> Void) async throws -> LibraryImportSummary {
        progress(LibraryImportProgress(phase: LibraryImportPhase.fetching, completed: 0, total: 0))
        pendingInvalidations.removeAll()
        let options = self.options()
        let previous = loadState()
        let fullRescan = mode == .full || previous.filterFingerprint != options.filterFingerprint
        let (roots, unresolved) = try await resolveRoots()

        // Walk every root once: the "nothing changed" test and the diff below both read these listings.
        let rules = DirectoryRuleResolver(allowed: options.allowedDirectories, blocked: options.blockedDirectories)
        var listings: [String: FolderListing] = [:]
        var allowedFiles: [String: [ScannedFileEntry]] = [:]
        for root in roots {
            try Task.checkCancellation()
            let listing = AudioFileEnumerator.list(root: root.url)
            listings[root.id] = listing
            allowedFiles[root.id] = listing.files.filter { entry in
                let path = LibraryIdentity.libraryPath(root: root, relativePath: entry.relativePath)
                return !rules.isBlocked(LibraryIdentity.parentDirectory(ofLibraryPath: path))
            }
        }

        // Everything besides the files that this scan's result depends on (`ScanFingerprint`), read once: the hidden
        // songs below are the ones the fingerprint was made from.
        let hidden = HiddenSongs.ids()
        let usesMediaLibrary = configuration.allowsMediaLibrary && options.includeMediaLibrary
            && MediaLibraryImporter.isAuthorized
        let overridesSignature = try await persistence.tagOverridesSignature()
        let inputs = ScanFingerprint.make(
            options: options, roots: roots, unresolved: unresolved, hidden: hidden, overrides: overridesSignature,
            media: ScanFingerprint.mediaLibrarySignature(
                takesPart: usesMediaLibrary, lastModified: usesMediaLibrary ? MediaLibraryImporter.lastModified : nil))

        // Nothing to do: same inputs, every file as the last scan left it, the song table as that scan left it. The
        // snapshot is not read, nothing is built or written (a scan like this ran on every launch and foreground).
        if mode == .incremental, !fullRescan, previous.inputsFingerprint == inputs, let rows = previous.songRowCount,
           Self.filesAreUnchanged(roots: roots, unresolved: unresolved, allowedFiles: allowedFiles, state: previous),
           try await persistence.librarySongRowCount() == rows {
            let scannedAt = Self.nowMs()
            for root in roots where root.id != FolderRoot.documentsID && configuration.fixedRoots == nil {
                try? await persistence.updateFolderSource(id: root.id, lastScanAt: scannedAt)
            }
            progress(LibraryImportProgress(phase: LibraryImportPhase.completing, completed: rows, total: rows))
            return LibraryImportSummary(added: 0, updated: 0, removed: 0)
        }

        let existing = try await persistence.loadLibrarySnapshot()
        let overrides = try await persistence.tagOverrides()

        var storedById: [String: Song] = [:]
        var storedIdsByRoot: [String: Set<String>] = [:]
        for song in existing.songs where LibraryIdentity.isManaged(song.id) {
            storedById[song.id] = song
            if let root = LibraryIdentity.rootID(ofFileSongID: song.id) { storedIdsByRoot[root, default: []].insert(song.id) }
        }

        var state = ScanState()
        state.filterFingerprint = options.filterFingerprint
        var tracks: [ScannedTrack] = []
        var jobs: [ReadJob] = []
        for root in roots {
            try Task.checkCancellation()
            guard let listing = listings[root.id], let files = allowedFiles[root.id] else { continue }
            let plan = FolderScanPlan.make(rootID: root.id, files: files, state: previous,
                                           storedSongIDs: storedIdsByRoot[root.id] ?? [], fullRescan: fullRescan)
            for entry in plan.unchanged {
                let id = LibraryIdentity.fileSongID(rootID: root.id, relativePath: entry.relativePath)
                guard let stored = storedById[id] else { continue }
                tracks.append(.stored(stored, root: root, entry: entry))
                state.stamps[id] = entry.stamp
            }
            for entry in plan.placeholders {
                let id = LibraryIdentity.fileSongID(rootID: root.id, relativePath: entry.relativePath)
                guard let stored = storedById[id] else { continue }
                tracks.append(.stored(stored, root: root, entry: entry))
                state.stamps[id] = previous.stamps[id]
            }
            for entry in plan.stillRejected {
                state.rejected[LibraryIdentity.fileSongID(rootID: root.id, relativePath: entry.relativePath)] = entry.stamp
            }
            for entry in plan.toRead {
                let directory = (entry.relativePath as NSString).deletingLastPathComponent
                jobs.append(ReadJob(root: root, entry: entry,
                                    id: LibraryIdentity.fileSongID(rootID: root.id, relativePath: entry.relativePath),
                                    coverImage: listing.coverImages[directory]))
            }
        }
        // A folder whose bookmark didn't resolve this time (drive away, provider not ready) keeps its songs.
        for (rootID, ids) in storedIdsByRoot where unresolved.contains(rootID) {
            for id in ids {
                guard let song = storedById[id] else { continue }
                tracks.append(.kept(song))
                state.stamps[id] = previous.stamps[id]
            }
        }

        // Read new and changed files, four at a time.
        progress(LibraryImportProgress(phase: LibraryImportPhase.processing, completed: 0, total: jobs.count))
        let minDuration = Int64(options.minSongDurationMs)
        for result in try await read(jobs, progress: progress) {
            if let track = result.track, track.durationMs >= minDuration, !track.title.isEmpty {
                tracks.append(track)
                state.stamps[result.id] = result.stamp
            } else {
                state.rejected[result.id] = result.stamp
            }
        }

        // The device music library.
        if configuration.allowsMediaLibrary, options.includeMediaLibrary, MediaLibraryImporter.isAuthorized {
            progress(LibraryImportProgress(phase: LibraryImportPhase.mediaLibrary, completed: 0, total: 0))
            tracks += MediaLibraryImporter.tracks().filter { $0.durationMs >= minDuration }
        }

        // Songs the user deleted that have no file to delete (music-library items) or whose file couldn't be
        // deleted stay out of the library (`HiddenSongs`, read before the fingerprint was made).
        if !hidden.isEmpty { tracks.removeAll { hidden.contains($0.id) } }

        for index in tracks.indices {
            let id = tracks[index].id
            if let override = overrides[id] { override.apply(to: &tracks[index]) }
        }

        try Task.checkCancellation()
        progress(LibraryImportProgress(phase: LibraryImportPhase.saving, completed: 0, total: tracks.count))
        let built = LibraryBuilder.build(tracks: tracks, existing: existing, options: options)
        let summary = try await persistence.applyLibraryScan(built)

        for id in pendingInvalidations { state.invalidate(id) }
        pendingInvalidations.removeAll()
        state.inputsFingerprint = inputs
        state.songRowCount = try? await persistence.librarySongRowCount()
        saveState(state)
        let scannedAt = Self.nowMs()
        for root in roots where root.id != FolderRoot.documentsID && configuration.fixedRoots == nil {
            try? await persistence.updateFolderSource(id: root.id, lastScanAt: scannedAt)
        }
        progress(LibraryImportProgress(phase: LibraryImportPhase.completing, completed: tracks.count, total: tracks.count))
        return summary
    }

    /// Every resolved root lists exactly what the last scan left behind (`ScanFingerprint.rootIsUnchanged`), and the
    /// last scan knew no root but these (or a folder that could not be opened, whose songs stay).
    private nonisolated static func filesAreUnchanged(roots: [FolderRoot], unresolved: Set<String>,
                                                      allowedFiles: [String: [ScannedFileEntry]],
                                                      state: ScanState) -> Bool {
        let stampedByRoot = ScanFingerprint.idsByRoot(state.stamps.keys)
        let rejectedByRoot = ScanFingerprint.idsByRoot(state.rejected.keys)
        let known = Set(roots.map(\.id)).union(unresolved)
        guard stampedByRoot.keys.allSatisfy(known.contains) else { return false }
        for root in roots {
            guard ScanFingerprint.rootIsUnchanged(
                rootID: root.id, files: allowedFiles[root.id] ?? [], state: state,
                stampedIDs: stampedByRoot[root.id] ?? [], rejectedIDs: rejectedByRoot[root.id] ?? []) else { return false }
        }
        return true
    }

    nonisolated struct ReadJob: Sendable {
        var root: FolderRoot
        var entry: ScannedFileEntry
        var id: String
        var coverImage: URL?
    }

    nonisolated struct ReadResult: Sendable {
        var id: String
        var stamp: FileStamp
        var track: ScannedTrack?
    }

    private func read(_ jobs: [ReadJob],
                      progress: @escaping @Sendable (LibraryImportProgress) -> Void) async throws -> [ReadResult] {
        guard !jobs.isEmpty else { return [] }
        let width = max(1, configuration.readConcurrency)
        return try await withThrowingTaskGroup(of: ReadResult.self) { group in
            var next = 0
            var results: [ReadResult] = []
            results.reserveCapacity(jobs.count)
            while next < min(width, jobs.count) {
                let job = jobs[next]
                group.addTask { await Self.readOne(job) }
                next += 1
            }
            while let result = try await group.next() {
                results.append(result)
                if results.count % 25 == 0 || results.count == jobs.count {
                    progress(LibraryImportProgress(phase: LibraryImportPhase.processing, completed: results.count,
                                                   total: jobs.count))
                }
                try Task.checkCancellation()
                if next < jobs.count {
                    let job = jobs[next]
                    group.addTask { await Self.readOne(job) }
                    next += 1
                }
            }
            return results
        }
    }

    private nonisolated static func readOne(_ job: ReadJob) async -> ReadResult {
        let metadata = await AudioMetadataReader.read(url: job.entry.url)
        let track = metadata.durationMs > 0
            ? ScannedTrack.file(id: job.id, root: job.root, entry: job.entry, metadata: metadata,
                                coverImage: job.coverImage)
            : nil
        return ReadResult(id: job.id, stamp: job.entry.stamp, track: track)
    }

    // MARK: Roots

    private func resolveRoots() async throws -> (roots: [FolderRoot], unresolved: Set<String>) {
        if let fixed = configuration.fixedRoots { return (fixed, []) }
        var roots: [FolderRoot] = []
        if configuration.includeDocumentsFolder,
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(FolderRoot(id: FolderRoot.documentsID, displayName: FolderRoot.documentsDisplayName,
                                    url: documents))
        }
        var unresolved = Set<String>()
        for source in try await persistence.folderSources() where source.isEnabled {
            do {
                let resolved = try FolderBookmarks.resolve(source.bookmark)
                if let refreshed = resolved.refreshedBookmark {
                    try? await persistence.updateFolderSource(id: source.id, bookmark: refreshed)
                }
                FolderAccessRegistry.shared.open(id: source.id, url: resolved.url)
                roots.append(FolderRoot(id: source.id, displayName: source.displayName, url: resolved.url))
            } catch {
                unresolved.insert(source.id)
            }
        }
        return (roots, unresolved)
    }

    // MARK: State

    private func loadState() -> ScanState {
        if let url = configuration.stateURL { return ScanState.load(from: url) }
        return memoryState ?? ScanState()
    }

    private func saveState(_ state: ScanState) {
        if let url = configuration.stateURL { state.save(to: url) } else { memoryState = state }
    }

    private static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

nonisolated extension ScannedTrack {
    /// A stored song kept as it is (its folder couldn't be resolved this time).
    static func kept(_ song: Song) -> ScannedTrack {
        ScannedTrack(
            id: song.id, title: song.title, artist: song.artist, album: song.album, albumArtist: song.albumArtist,
            genre: song.genre, trackNumber: song.trackNumber, discNumber: song.discNumber, year: song.year,
            durationMs: song.duration, mimeType: song.mimeType, bitrate: song.bitrate, sampleRate: song.sampleRate,
            contentUri: song.contentUriString, artworkUri: song.albumArtUriString, path: song.path,
            parentDirectory: LibraryIdentity.parentDirectory(ofLibraryPath: song.path), dateAdded: song.dateAdded,
            dateModified: song.dateModified, fallbackAlbumId: nil)
    }
}
