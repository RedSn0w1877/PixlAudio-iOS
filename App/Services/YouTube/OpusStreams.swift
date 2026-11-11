import AVFoundation
import CoreMedia
import Foundation
import PixlModel
import PixlNet

// iPhones play YouTube's Opus stream (itag 251, full band) instead of the AAC one (itag 140, cut at about 16 kHz)
// when a checked Opus file is already on disk. AVPlayer does not read WebM, so the whole file is downloaded ahead of
// time (the prefetcher's next song, then the playing song for its next play), repackaged into MP4 by PixlNet's
// `OpusRemuxer` (no re-encoding), and decoded once by the system decoder before anything may play it. A song that
// starts cold keeps playing AAC: nothing here sits on the path to first audio. Any failure means AAC for that video,
// remembered in `OpusFailureLedger`. Design and status: docs/handoff/2026-11-11-ios-opus.md.

/// What one preparation did.
nonisolated enum OpusPreparationOutcome: Sendable, Equatable {
    case ready(OpusStreamStore.ReadyInfo)
    /// Not attempted or cancelled (nothing remembered).
    case skipped(String)
    case failed(OpusFailureKind, String)
}

// MARK: - Store

/// `Library/Caches/YouTube/opus/<videoId>.mp4` (Settings › Offline storage measures and clears it with the other
/// caches) and `state.json` (the failure ledger and what each ready file is). A file is only ever renamed into place
/// after the system decoder accepted it, so the resolver's whole question is "is the file there".
actor OpusStreamStore {
    nonisolated struct ReadyInfo: Codable, Sendable, Equatable {
        var itag: Int?
        var durationMs: Double
        var bytes: Int64
        var preparedAt: Double
    }

    nonisolated struct State: Codable, Sendable {
        var ledger = OpusFailureLedger()
        var ready: [String: ReadyInfo] = [:]
    }

    nonisolated let directory: URL
    nonisolated static let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    private var state: State?
    private var inFlight: Set<String> = []

    init(directory: URL = YouTubeNetwork.cachesDirectory("opus")) {
        self.directory = directory
    }

    nonisolated func fileURL(videoId: String) -> URL { directory.appendingPathComponent("\(videoId).mp4") }
    /// Where a new file waits for its check (never played from there).
    nonisolated func candidateURL(videoId: String) -> URL { directory.appendingPathComponent("\(videoId).check.mp4") }
    nonisolated var stateURL: URL { directory.appendingPathComponent("state.json") }

    /// The checked file of `videoId` when there is one; marks it used (eviction keeps recently used files).
    nonisolated func readyFile(videoId: String) -> URL? {
        let url = fileURL(videoId: videoId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// The video id when `url` is one of the prepared files (the id is the file name, map section 4.2).
    nonisolated func videoId(ofFile url: URL) -> String? {
        guard url.isFileURL, url.pathExtension.lowercased() == "mp4",
              url.deletingLastPathComponent().resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path
        else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        return CloudStreamSecurity.validateYouTubeVideoId(id) ? id : nil
    }

    // MARK: Preparation bookkeeping

    /// Claims `videoId` for a preparation: false when its file is ready, it is already being prepared, a failure is
    /// remembered for it, or attempts are paused.
    func begin(videoId: String) -> Bool {
        let now = Date().timeIntervalSince1970
        let ledger = loaded().ledger
        guard !inFlight.contains(videoId),
              !FileManager.default.fileExists(atPath: fileURL(videoId: videoId).path),
              ledger.failure(videoId: videoId, now: now) == nil,
              ledger.pauseReason(os: Self.osVersion, now: now) == nil else { return false }
        inFlight.insert(videoId)
        return true
    }

    /// Whether any preparation may start (the pause and the decoder switch), for the prefetcher's cheap check.
    func isPaused() -> Bool {
        loaded().ledger.pauseReason(os: Self.osVersion, now: Date().timeIntervalSince1970) != nil
    }

    func noteResolution(found: Bool) {
        var s = loaded()
        s.ledger.recordResolution(found: found, now: Date().timeIntervalSince1970)
        save(s)
    }

    func finish(videoId: String, outcome: OpusPreparationOutcome) {
        inFlight.remove(videoId)
        var s = loaded()
        switch outcome {
        case .ready(let info):
            s.ledger.recordSuccess(videoId: videoId, os: Self.osVersion)
            s.ready[videoId] = info
        case .failed(let kind, let detail):
            s.ledger.record(kind, detail: detail, videoId: videoId, now: Date().timeIntervalSince1970, os: Self.osVersion)
            s.ready[videoId] = nil
        case .skipped:
            return
        }
        save(s)
        if case .ready = outcome { evictIfNeeded() }
    }

    /// The player could not open a prepared file: it goes, and the video plays AAC from now on.
    func playerRefused(videoId: String) {
        try? FileManager.default.removeItem(at: fileURL(videoId: videoId))
        var s = loaded()
        s.ready[videoId] = nil
        s.ledger.record(.playerRefused, detail: "the player could not open the file", videoId: videoId,
                        now: Date().timeIntervalSince1970, os: Self.osVersion)
        save(s)
    }

    /// Least recently used files go above `OpusStreamPolicy.cacheMaxBytes`; never one used in the last ten minutes.
    /// Leftover check files (an interrupted preparation) go too.
    func evictIfNeeded() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let now = Date()
        var entries: [(url: URL, size: Int64, used: Date)] = []
        var total: Int64 = 0
        for file in files where file.pathExtension == "mp4" {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let used = values?.contentModificationDate ?? .distantPast
            if file.lastPathComponent.hasSuffix(".check.mp4") {
                if now.timeIntervalSince(used) > 3600, !inFlight.contains(String(file.lastPathComponent.dropLast(10))) {
                    try? fm.removeItem(at: file)
                }
                continue
            }
            let size = Int64(values?.fileSize ?? 0)
            total += size
            entries.append((file, size, used))
        }
        guard total > OpusStreamPolicy.cacheMaxBytes else { return }
        var s = loaded()
        for entry in entries.sorted(by: { $0.used < $1.used })
        where now.timeIntervalSince(entry.used) > OpusStreamPolicy.recentlyUsedSeconds {
            try? fm.removeItem(at: entry.url)
            s.ready[entry.url.deletingPathExtension().lastPathComponent] = nil
            total -= entry.size
            if total <= OpusStreamPolicy.cacheMaxBytes { break }
        }
        save(s)
    }

    // MARK: Diagnostics

    /// The Test playback report's Opus line for `videoId` (`playingURL`: the engine's current item).
    func statusLine(videoId: String, playingURL: URL?, cache: StreamCache?) async -> String {
        let s = loaded()
        let now = Date().timeIntervalSince1970
        var lines: [String] = []
        if let playingURL { lines.append("Playing now: " + (await Self.describe(itemURL: playingURL, store: self, cache: cache))) }
        if FileManager.default.fileExists(atPath: fileURL(videoId: videoId).path) {
            var detail = ""
            if let info = s.ready[videoId] {
                let itag = info.itag.map { "\($0)" } ?? "?"
                detail = " (itag \(itag), \(Self.megabytes(info.bytes)))"
            }
            lines.append("Opus file ready\(detail): this song plays Opus from its next start.")
        } else if inFlight.contains(videoId) {
            lines.append("The Opus file is being prepared now.")
        } else if let failure = s.ledger.failure(videoId: videoId, now: now) {
            lines.append("AAC for this song: \(Self.describe(failure.kind)) (\(failure.detail)).")
        } else if let paused = s.ledger.pauseReason(os: Self.osVersion, now: now) {
            lines.append("Opus is paused: \(paused).")
        } else {
            lines.append("No Opus file yet: one is prepared on Wi-Fi for the next song in the queue, and for a song that has played 30 s.")
        }
        return lines.joined(separator: "\n")
    }

    /// One line about the item that plays: codec and itag.
    nonisolated static func describe(itemURL url: URL, store: OpusStreamStore, cache: StreamCache?) async -> String {
        if let videoId = store.videoId(ofFile: url) {
            let itag = await store.readyInfo(videoId: videoId)?.itag.map { "\($0)" } ?? "?"
            return "Opus 48 kHz (itag \(itag)), prepared file"
        }
        if let videoId = YouTubeSongIdentity.videoId(from: url) {
            let meta = await cache?.meta(videoId)
            return "AAC (itag \(meta?.itag ?? "?")), streaming"
        }
        guard url.isFileURL else { return url.scheme ?? "unknown" }
        let id = url.deletingPathExtension().lastPathComponent
        if let cache, url.deletingLastPathComponent().resolvingSymlinksInPath().path
            == cache.directory.resolvingSymlinksInPath().path {
            let meta = await cache.meta(id)
            return "AAC (itag \(meta?.itag ?? "?")), stream cache file"
        }
        if url.deletingLastPathComponent().resolvingSymlinksInPath().path
            == DownloadFiles.directory.resolvingSymlinksInPath().path {
            return "AAC, downloaded file"
        }
        return "local file (.\(url.pathExtension))"
    }

    func readyInfo(videoId: String) -> ReadyInfo? { loaded().ready[videoId] }

    nonisolated static func describe(_ kind: OpusFailureKind) -> String {
        switch kind {
        case .noOpusOffered: "no client offered a better Opus stream"
        case .network: "the download failed"
        case .tooLarge: "the file is too large"
        case .remux: "the WebM file could not be repackaged"
        case .durationMismatch: "the Opus and AAC streams differ in length"
        case .verify: "the system decoder refused the file"
        case .playerRefused: "the player could not open the file"
        }
    }

    nonisolated static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    // MARK: State file

    private func loaded() -> State {
        if let state { return state }
        var loaded = State()
        if let data = try? Data(contentsOf: stateURL), let decoded = try? JSONDecoder().decode(State.self, from: data) {
            loaded = decoded
        }
        state = loaded
        return loaded
    }

    private func save(_ new: State) {
        state = new
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(new) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}

// MARK: - Preparation

/// Resolve → download the WebM → remux → check with the system decoder → publish. Runs off the caller's actor.
nonisolated struct OpusPreparer: Sendable {
    let store: OpusStreamStore
    let service: InnerTubeService
    let session: URLSession

    @concurrent
    func prepare(videoId: String) async -> OpusPreparationOutcome {
        guard CloudStreamSecurity.validateYouTubeVideoId(videoId) else { return .skipped("invalid video id") }
        guard await store.begin(videoId: videoId) else { return .skipped("ready, running, remembered or paused") }
        var outcome = await run(videoId: videoId)
        if case .failed = outcome, Task.isCancelled { outcome = .skipped("cancelled") }
        try? FileManager.default.removeItem(at: store.candidateURL(videoId: videoId))
        await store.finish(videoId: videoId, outcome: outcome)
        return outcome
    }

    private func run(videoId: String) async -> OpusPreparationOutcome {
        // 1. Which stream: a better Opus stream than the AAC pick, from the same `player` response when possible.
        guard let resolution = await service.resolveOpus(videoId: videoId) else {
            if Task.isCancelled { return .skipped("cancelled") }
            await store.noteResolution(found: false)
            let attempts = await service.lastOpusAttempts
            return .failed(.noOpusOffered, attempts.isEmpty ? "no client answered" : attempts.joined(separator: "; "))
        }
        await store.noteResolution(found: true)
        if let length = resolution.contentLength, length > OpusStreamPolicy.maxWebMBytes {
            return .failed(.tooLarge, "\(OpusStreamStore.megabytes(length))")
        }
        guard OpusStreamPolicy.durationsAgree(resolution.opusDurationMs, resolution.aacDurationMs) else {
            return .failed(.durationMismatch, "YouTube says Opus \(Self.ms(resolution.opusDurationMs)), AAC \(Self.ms(resolution.aacDurationMs))")
        }
        // 2. The whole WebM.
        let webm: Data
        do {
            webm = try await OpusDownloader(service: service, session: session).download(videoId: videoId, resolution: resolution)
        } catch is CancellationError {
            return .skipped("cancelled")
        } catch OpusDownloader.Failure.tooLarge {
            return .failed(.tooLarge, "over \(OpusStreamStore.megabytes(OpusStreamPolicy.maxWebMBytes))")
        } catch {
            return .failed(.network, error.localizedDescription)
        }
        guard !Task.isCancelled else { return .skipped("cancelled") }
        // 3. Repackage.
        let output: OpusRemuxer.Output
        do {
            output = try OpusRemuxer.remux(webm: webm)
        } catch {
            return .failed(.remux, String(describing: error))
        }
        guard OpusStreamPolicy.durationsAgree(output.summary.durationMs, resolution.aacDurationMs) else {
            return .failed(.durationMismatch, "Opus file \(Self.ms(output.summary.durationMs)), AAC \(Self.ms(resolution.aacDurationMs))")
        }
        // 4. The system decoder's check, then the atomic rename that makes it playable.
        let candidate = store.candidateURL(videoId: videoId)
        do {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try output.mp4.write(to: candidate, options: .atomic)
        } catch {
            return .failed(.network, "could not write the file: \(error.localizedDescription)")
        }
        do {
            _ = try await OpusPlaybackCheck.verify(fileURL: candidate, summary: output.summary)
        } catch is CancellationError {
            return .skipped("cancelled")
        } catch {
            return .failed(.verify, error.localizedDescription)
        }
        let destination = store.fileURL(videoId: videoId)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: candidate)
            } else {
                try FileManager.default.moveItem(at: candidate, to: destination)
            }
        } catch {
            return .failed(.network, "could not keep the file: \(error.localizedDescription)")
        }
        return .ready(OpusStreamStore.ReadyInfo(itag: resolution.itag, durationMs: output.summary.durationMs,
                                                bytes: Int64(output.mp4.count),
                                                preparedAt: Date().timeIntervalSince1970))
    }

    static func ms(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) ms" } ?? "unknown" }
}

// MARK: - Download

/// The whole WebM in ranged GETs with the resolving client's User-Agent and the streaming layer's checks (safe host,
/// audio content type, sane and expected length). Never on cellular, a hotspot or Low Data Mode, even if the
/// network changes half way. One re-resolution when googlevideo refuses the URL.
nonisolated struct OpusDownloader: Sendable {
    nonisolated enum Failure: Error, LocalizedError, Equatable {
        case unsafeURL
        case http(Int)
        case badResponse(String)
        case tooLarge
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unsafeURL: "the stream address was refused"
            case .http(let code): "HTTP \(code)"
            case .badResponse(let why): why
            case .tooLarge: "file too large"
            case .timedOut: "the download took too long"
            }
        }
    }

    let service: InnerTubeService
    let session: URLSession

    func download(videoId: String, resolution: OpusStreamResolution) async throws -> Data {
        var stream = resolution.stream
        var total = resolution.contentLength
        var data = Data()
        var refreshed = false
        let started = ContinuousClock.now
        while total.map({ Int64(data.count) < $0 }) ?? true {
            try Task.checkCancellation()
            guard started.duration(to: .now) < .seconds(OpusStreamPolicy.downloadTimeoutSeconds) else { throw Failure.timedOut }
            let allowed = await service.allowedHosts()
            guard CloudStreamSecurity.isSafeRemoteStreamURL(stream.url, allowedHostSuffixes: allowed),
                  let url = URL(string: stream.url) else { throw Failure.unsafeURL }
            let start = Int64(data.count)
            var end = start + OpusStreamPolicy.downloadChunkBytes
            if let total { end = min(end, total) }
            var request = URLRequest(url: url)
            request.allowsConstrainedNetworkAccess = false
            request.allowsExpensiveNetworkAccess = false
            if URLCoding.host(stream.url)?.lowercased().hasSuffix(".googlevideo.com") == true {
                request.assumesHTTP3Capable = true
            }
            request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(ContentRange.requestHeader(start..<end), forHTTPHeaderField: "Range")
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.badResponse("no HTTP response") }
            if [401, 403, 404, 410].contains(http.statusCode) {
                // Expired or bound elsewhere: resolve once more, the same file (itag and size) or nothing.
                guard !refreshed, let fresh = await service.resolveOpus(videoId: videoId, fresh: true),
                      fresh.itag == resolution.itag,
                      fresh.contentLength == nil || total == nil || fresh.contentLength == total else {
                    throw Failure.http(http.statusCode)
                }
                refreshed = true
                stream = fresh.stream
                continue
            }
            guard http.statusCode == 206 || http.statusCode == 200 else { throw Failure.http(http.statusCode) }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")
            guard CloudStreamSecurity.isSupportedAudioContentType(contentType),
                  contentType?.lowercased().contains("webm") == true else {
                throw Failure.badResponse("the server sent \(contentType ?? "?"), not WebM audio")
            }
            guard !body.isEmpty else { throw Failure.badResponse("an empty response") }
            if http.statusCode == 200 {
                data = body
                total = Int64(body.count)
            } else {
                guard let range = ContentRange.parse(http.value(forHTTPHeaderField: "Content-Range")),
                      range.start == start, let length = range.total else {
                    throw Failure.badResponse("the server sent the wrong range")
                }
                guard total == nil || total == length else { throw Failure.badResponse("the file changed size") }
                total = length
                data.append(body)
            }
            guard let total, total <= OpusStreamPolicy.maxWebMBytes else { throw Failure.tooLarge }
            guard Int64(data.count) <= total else { throw Failure.badResponse("more bytes than the file has") }
        }
        return data
    }
}

// MARK: - The system decoder's check

/// Opens a repackaged file the way the player will (`AVURLAsset`) and decodes all of it with `AVAssetReader`, the
/// decoder the player, Sing's preparer and the on-device models use. It must be one Opus track at 48 kHz with the
/// expected channels, playable, exactly as long as the valid samples, decode to that many frames, and not be silent.
nonisolated enum OpusPlaybackCheck {
    nonisolated struct Report: Sendable, Equatable {
        var decodedFrames: Int64
        var durationSeconds: Double
        var peak: Int16
    }

    nonisolated enum Failure: Error, LocalizedError, Equatable {
        case noAudioTrack
        case notPlayable
        case notOpus(String)
        case wrongFormat(String)
        case wrongDuration(expected: Double, actual: Double)
        case readerFailed(String)
        case wrongFrameCount(expected: Int64, actual: Int64)
        case silent

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "no audio track"
            case .notPlayable: "not playable"
            case .notOpus(let format): "read as \(format), not Opus"
            case .wrongFormat(let what): what
            case .wrongDuration(let expected, let actual): String(format: "duration %.4f s, expected %.4f s", actual, expected)
            case .readerFailed(let why): "decode failed: \(why)"
            case .wrongFrameCount(let expected, let actual): "decoded \(actual) frames, expected \(expected)"
            case .silent: "decoded to silence"
            }
        }
    }

    @concurrent
    static func verify(fileURL: URL, summary: OpusRemuxer.Summary) async throws -> Report {
        let asset = AVURLAsset(url: fileURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, let track = tracks.first else { throw Failure.noAudioTrack }
        guard try await asset.load(.isPlayable) else { throw Failure.notPlayable }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else { throw Failure.wrongFormat("no format description") }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        guard subtype == kAudioFormatOpus else { throw Failure.notOpus(fourCharacterCode(subtype)) }
        guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              basic.mSampleRate == 48_000, Int(basic.mChannelsPerFrame) == summary.channels else {
            throw Failure.wrongFormat("not 48 kHz with \(summary.channels) channels")
        }
        let expectedSeconds = Double(summary.validSamples) / 48_000
        let duration = try await asset.load(.duration)
        let seconds = duration.isNumeric ? duration.seconds : 0
        guard abs(seconds - expectedSeconds) <= OpusStreamPolicy.maxAssetDurationDifferenceSeconds else {
            throw Failure.wrongDuration(expected: expectedSeconds, actual: seconds)
        }
        try Task.checkCancellation()
        let (frames, peak) = try decodeAll(asset: asset, track: track)
        let expected = Int64(summary.validSamples)
        guard abs(frames - expected) <= OpusStreamPolicy.maxDecodedFrameDifference else {
            throw Failure.wrongFrameCount(expected: expected, actual: frames)
        }
        guard peak > 32 else { throw Failure.silent }
        return Report(decodedFrames: frames, durationSeconds: seconds, peak: peak)
    }

    /// Frame count and peak of the whole decode (16-bit interleaved PCM at the file's own rate).
    private static func decodeAll(asset: AVURLAsset, track: AVAssetTrack) throws -> (Int64, Int16) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure.readerFailed(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.readerFailed("cannot add the track output") }
        reader.add(output)
        guard reader.startReading() else { throw Failure.readerFailed(reader.error?.localizedDescription ?? "did not start") }
        var frames: Int64 = 0
        var peak: Int16 = 0
        var scratch = [Int16](repeating: 0, count: 16_384)
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            frames += Int64(CMSampleBufferGetNumSamples(buffer))
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            if scratch.count * 2 < length { scratch = [Int16](repeating: 0, count: length / 2 + 1) }
            let copied = scratch.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            guard copied == kCMBlockBufferNoErr else { continue }
            for index in 0..<(length / 2) {
                let value = scratch[index]
                let magnitude = value == Int16.min ? Int16.max : abs(value)
                if magnitude > peak { peak = magnitude }
            }
        }
        guard reader.status == .completed else {
            throw Failure.readerFailed(reader.error?.localizedDescription ?? "status \(reader.status.rawValue)")
        }
        return (frames, peak)
    }

    static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }
}
