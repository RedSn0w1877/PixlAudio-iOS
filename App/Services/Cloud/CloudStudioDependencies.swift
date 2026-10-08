import Foundation
import PixlAudioCore
import PixlLyrics
import PixlModel
import PixlNet

// The seams of Cloud Studio's orchestrator (design §7.1, §7.6 "AppTests for the orchestrator with fakes"): the
// background transfer session, the upload preparer, file checks, and the app (library, lyrics store, Stems/). The live
// implementations are below; AppTests and UI tests use fakes, so nothing here ever touches the network in a test.

/// The background transfer session (`CloudTransfers`).
nonisolated protocol CloudTransferring: AnyObject, Sendable {
    var onEvent: (@Sendable (CloudTransferEvent) -> Void)? { get set }
    var onProgress: (@Sendable (_ jobKey: String, _ slot: String, _ fraction: Double) -> Void)? { get set }
    var allowsCellular: Bool { get set }
    func upload(fileURL: URL, to url: URL, jobKey: String, contentType: String)
    func download(from url: URL, jobKey: String, slot: String)
    func cancel(jobKey: String) async
    /// `"<jobKey>|<slot>"` of every transfer still running or waiting.
    func pendingTaskDescriptions() async -> [String]
}

nonisolated extension CloudTransfers: CloudTransferring {}

/// Prepares a song's audio for upload (`CloudAudioPreparer`).
nonisolated protocol CloudAudioPreparing: Sendable {
    /// `forceDecode`: decode to FLAC even when the source could go up as it is (streamed songs, design §7.3).
    func prepare(source: URL, jobKey: String, forceDecode: Bool) async throws -> CloudPreparedAudio
    func removeUpload(jobKey: String)
    /// The prepared file of a job, if it is still on disk (an upload restarted after a relaunch).
    func uploadFile(jobKey: String, ext: String) -> URL?
}

nonisolated struct LiveCloudAudioPreparer: CloudAudioPreparing {
    func prepare(source: URL, jobKey: String, forceDecode: Bool) async throws -> CloudPreparedAudio {
        try await CloudAudioPreparer.prepare(source: source, jobKey: jobKey, forceDecode: forceDecode)
    }

    func removeUpload(jobKey: String) { CloudAudioPreparer.removeUpload(jobKey: jobKey) }

    func uploadFile(jobKey: String, ext: String) -> URL? {
        guard let url = try? CloudAudioPreparer.uploadURL(jobKey: jobKey, ext: ext),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// Size, SHA-256 and decoded length of a downloaded result (the import checks, design §7.5 step 1).
nonisolated protocol CloudFileInspecting: Sendable {
    func digest(_ url: URL) throws -> (sha256: String, bytes: Int64)
    /// Decoded sample frames per channel at 44.1 kHz (the worker's rate).
    func frames(_ url: URL) async throws -> Int64
    func sha256Hex(_ data: Data) -> String
}

nonisolated struct LiveCloudFileInspector: CloudFileInspecting {
    func digest(_ url: URL) throws -> (sha256: String, bytes: Int64) { try CloudPlatform.fileDigest(url) }

    func frames(_ url: URL) async throws -> Int64 { try await CloudAudioPreparer.countFrames(of: url) }

    func sha256Hex(_ data: Data) -> String { CloudPlatform.sha256Hex(data) }
}

/// What the library knows about a song's lyrics, for selection and for the request's `lyrics` block.
nonisolated struct CloudLyricsFacts: Sendable, Equatable {
    var state: CloudLyricsState
    var lines: [CloudLyricsInputLine]?
    var hasLineTimes: Bool
    /// The lyrics' own idea of the song's length (a catalog's duration), when known.
    var referenceDurationMs: Int64?
    var language: String?

    static let none = CloudLyricsFacts(state: .none, lines: nil, hasLineTimes: false, referenceDurationMs: nil,
                                       language: nil)
}

/// What became of a lyrics import.
nonisolated enum CloudLyricsSaveOutcome: Sendable, Equatable {
    case saved
    /// The stored lyrics are as good or better (catalog word timing arrived meanwhile).
    case keptBetter
    /// The person synced this song themselves and didn't ask to replace it.
    case keptUserSynced
    case unusable
}

/// The app around the orchestrator: songs, their audio, the lyrics store and `Stems/`.
@MainActor
protocol CloudStudioHost: AnyObject {
    func song(id: String) -> Song?
    /// The playing song (the queue's "Add › Current song").
    var currentSong: Song? { get }
    /// Every song in the library (the queue's "Add" filters).
    var librarySongs: [Song] { get }
    /// A decodable URL for the song: a local file or library item; a streamed song is downloaded permanently first.
    func audioSource(for song: Song) async throws -> URL
    /// The YouTube video a streamed song plays (a Spotify song's match), nil for local songs. Re-checked on import.
    func streamIdentity(for song: Song) async -> String?
    func lyricsFacts(for song: Song) async -> CloudLyricsFacts
    func hasInstrumental(songId: String) async -> Bool
    /// Moves a verified result into `Stems/` atomically (and drops the other cloud variant).
    func installInstrumental(from staged: URL, songId: String, flac: Bool) throws
    func saveLyrics(_ doc: LyricsDoc, for song: Song, replaceUserSynced: Bool) async -> CloudLyricsSaveOutcome
    func instrumentalImported(songId: String)
    func lyricsImported(song: Song)
}

/// The live host: the library, TAIS's audio source, the lyrics service and `Stems/`.
@MainActor
final class LiveCloudStudioHost: CloudStudioHost {
    private let library: LibraryStore
    private let playback: PlaybackStore
    private let lyricsService: LyricsService?
    private let studio: TaisStudio
    private let source: (Song) async throws -> URL
    private let videoIdForSpotify: (String) async -> String?

    init(library: LibraryStore, playback: PlaybackStore, lyricsService: LyricsService?, studio: TaisStudio,
         audioSource: @escaping (Song) async throws -> URL, videoIdForSpotify: @escaping (String) async -> String?) {
        self.library = library
        self.playback = playback
        self.lyricsService = lyricsService
        self.studio = studio
        source = audioSource
        self.videoIdForSpotify = videoIdForSpotify
    }

    func song(id: String) -> Song? { library.song(id: id) }
    var currentSong: Song? { playback.current }
    var librarySongs: [Song] { library.songs }

    func audioSource(for song: Song) async throws -> URL { try await source(song) }

    func streamIdentity(for song: Song) async -> String? {
        if let videoId = YouTubeSongIdentity.videoId(for: song) { return videoId }
        guard let spotifyId = SpotifyPlayableURLResolver.spotifyId(of: song) else { return nil }
        return await videoIdForSpotify(spotifyId)
    }

    func lyricsFacts(for song: Song) async -> CloudLyricsFacts {
        guard let service = lyricsService else { return .none }
        let stored = await service.storedLyricsAsync(for: song)
        let userSynced = await service.isUserSyncedStored(song)
        return Self.facts(lyrics: stored?.lyrics, userSynced: userSynced)
    }

    /// The facts of stored lyrics (pure; unit-tested).
    nonisolated static func facts(lyrics: Lyrics?, userSynced: Bool) -> CloudLyricsFacts {
        let level = CloudLyrics.level(of: lyrics)
        let state: CloudLyricsState
        if userSynced && level != .none {
            state = .userSynced
        } else {
            switch level {
            case .none: state = .none
            case .plain, .lineSynced: state = .textOrLineSynced
            case .wordSynced: state = .wordSynced
            }
        }
        let request = CloudLyrics.requestLines(lyrics)
        var reference: Int64?
        if let duration = lyrics?.document?.metadata.durationMs, duration > 0 { reference = duration }
        return CloudLyricsFacts(state: state, lines: request?.lines, hasLineTimes: request?.hasLineTimes ?? false,
                                referenceDurationMs: reference, language: nil)
    }

    func hasInstrumental(songId: String) async -> Bool {
        await Task.detached(priority: .utility) { InstrumentalFiles.bestAvailable(songId: songId) != nil }.value
    }

    func installInstrumental(from staged: URL, songId: String, flac: Bool) throws {
        try InstrumentalFiles.prepareDirectory()
        guard let destination = InstrumentalFiles.cloudURL(songId: songId, flac: flac),
              let other = InstrumentalFiles.cloudURL(songId: songId, flac: !flac) else {
            throw CloudStudio.Failure("No storage for instrumentals")
        }
        try CloudStudio.moveAtomically(staged, to: destination)
        try? FileManager.default.removeItem(at: other)
    }

    func saveLyrics(_ doc: LyricsDoc, for song: Song, replaceUserSynced: Bool) async -> CloudLyricsSaveOutcome {
        guard let service = lyricsService else { return .unusable }
        // Right before writing (design §7.5 step 3): the person's own sync, and catalog lyrics that arrived since.
        let userSynced = await service.isUserSyncedStored(song)
        let stored = await service.storedLyricsAsync(for: song)
        let storedLevel = CloudLyrics.level(of: stored?.lyrics)
        let incoming = CloudLyrics.level(of: doc)
        guard CloudLyrics.isUsable(doc) else { return .unusable }
        guard CloudLyrics.shouldImport(stored: storedLevel, incoming: incoming, storedIsUserSynced: userSynced,
                                       replaceUserSynced: replaceUserSynced) else {
            return userSynced && !replaceUserSynced ? .keptUserSynced : .keptBetter
        }
        let saved = await service.save(song: song, rawContent: LyricsDocCodec.encode(doc),
                                       source: doc.metadata.source ?? CloudLyrics.source)
        return saved == nil ? .unusable : .saved
    }

    func instrumentalImported(songId: String) { studio.noteInstrumentalImported() }

    func lyricsImported(song: Song) { studio.noteLyricsImported(song: song) }
}
