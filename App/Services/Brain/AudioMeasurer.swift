import AVFoundation
import Foundation
import Observation
import PixlLibrary
import PixlModel
import Synchronization

/// Music brain stage 5 (docs/brain-spec.md 3.3; Android `AudioMeasurer`): measures tempo and loudness of the song that plays and
/// the next one, from a short window of their decoded audio (40 s from 20% in), with the pure `AudioFeatures.Estimator`. The result
/// goes to `audio_measure.pbl`; the DNA and the flow ordering read it from there.
///
/// Rules (Android's):
///  - One track at a time, on one background-priority task; nothing on the main actor but `onTrackChanged`, `onStall` and the status.
///  - It waits `settleMs` after a track starts (the player's own first buffering, and a skip-through costs nothing), and never decodes
///    while playback is stalled: a stall pauses the decode, and a stall that lasts `stallGiveUpMs` gives the window up without
///    counting a failure.
///  - A track already on the phone (downloaded, a prepared file, a complete stream cache) is decoded from the file, on any network.
///    Otherwise the window is read through the app's own stream loader, on Wi-Fi or Ethernet without Low Data Mode only (about 1 MB).
///  - A track is measured once per estimator version; a failure is retried after a day, and given up for a month after three.
@MainActor
@Observable
final class AudioMeasurer {
    nonisolated enum State: Int, Sendable {
        case waiting, measuring, done, failed, waitingForWifi, off, unknownTrack, gaveUp
    }

    /// What the developer diagnostics row shows for the song that is playing.
    nonisolated struct Status: Sendable, Equatable {
        var mediaId: String
        var state: State
        var result: AudioFeatures.Result? = nil
        /// The tempo the DNA keeps for it and where it came from (`TrackDna.tempo*`), when known.
        var keptTempoX10 = 0
        var keptTempoSource = 0
        var fromFile = false
        var tookMs: Int64 = 0
    }

    /// What the measurer reads from the rest of the app.
    struct Sources {
        /// The new picks engine is on (Developer mode › the brain switch).
        var isOn: () -> Bool
        /// Whether the library has a row for a song id (an engine pick from outside it resolves by its video id).
        var inLibrary: (String) -> Bool
        /// The URL the player would play the song from (the engine's resolver chain): a file when there is a copy on the phone
        /// (downloaded, prepared, or a complete stream cache), its `pixlstream://` URL otherwise; nil when it cannot be played.
        var playableURL: @Sendable (Song) async -> URL?
    }

    static let maxTargets = 2
    static let settleMs: Int64 = 10_000
    static let deadlineMs: Int64 = 60_000
    static let stallGiveUpMs: Int64 = 8_000

    private(set) var status: Status?

    private let brain: BrainService
    private let sources: Sources
    @ObservationIgnored private let stall = StallFlag()
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Created with the first measurement, never at launch (its path monitor starts then).
    @ObservationIgnored private lazy var network = NetworkConditionsMonitor()

    init(brain: BrainService, sources: Sources) {
        self.brain = brain
        self.sources = sources
    }

    /// The song that plays changed; `songs` is it first, then the next one in the queue.
    func onTrackChanged(_ songs: [Song]) {
        worker?.cancel()
        let targets = Array(songs.prefix(Self.maxTargets))
        guard let current = targets.first else {
            status = nil
            return
        }
        status = Status(mediaId: current.id, state: .waiting)
        network.startIfNeeded()
        worker = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.settleMs))
            for (i, song) in targets.enumerated() {
                if Task.isCancelled { return }
                await self?.measure(song, isCurrent: i == 0)
            }
        }
    }

    /// Playback is stalled (buffering while it should play), or no longer.
    func onStall(_ stalled: Bool) { stall.set(stalled) }

    private func publish(_ song: Song, _ isCurrent: Bool, _ s: Status) {
        if Task.isCancelled { return }
        if isCurrent || status?.mediaId == song.id { status = s }
    }

    private func measure(_ song: Song, isCurrent: Bool) async {
        guard sources.isOn(), let measures = brain.audioMeasures else {
            publish(song, isCurrent, Status(mediaId: song.id, state: .off))
            return
        }
        let rid = await brain.recordingId(of: song, inLibrary: sources.inLibrary(song.id))
        if Task.isCancelled { return }
        guard rid != 0 else {
            publish(song, isCurrent, Status(mediaId: song.id, state: .unknownTrack))
            return
        }
        let now = currentTimeMillis()
        if !(await measures.wants(rid, nowMs: now)) {
            let row = await measures.row(rid)
            publish(song, isCurrent, Self.statusOf(song.id, row?.result, row?.result != nil ? .done : .gaveUp))
            return
        }
        // A downloaded or cached song is read from the disk; anything else only on an unmetered network.
        guard let url = await sources.playableURL(song) else {
            publish(song, isCurrent, Status(mediaId: song.id, state: .unknownTrack))
            return
        }
        let file: URL? = url.isFileURL ? url : nil
        if file == nil {
            let c = network.conditions
            let unmetered = (c.network == .wifi || c.network == .wired) && !c.isConstrained && !c.isExpensive
            guard unmetered else {
                publish(song, isCurrent, Status(mediaId: song.id, state: .waitingForWifi))
                return
            }
        }
        if Task.isCancelled { return }
        publish(song, isCurrent, Status(mediaId: song.id, state: .measuring, fromFile: file != nil))
        let asset = AVURLAsset(url: url)
        // A streamed song goes through the app's own resource loader (the same cache and client as playback).
        StreamingResourceLoaderRegistry.shared.attach(to: asset)
        defer { StreamingResourceLoaderRegistry.shared.detach(from: asset) }
        let started = currentTimeMillis()
        var durationMs = song.duration
        if durationMs <= 0, let d = try? await asset.load(.duration), d.isNumeric {
            durationMs = Int64(d.seconds * 1000.0)
        }
        let startMs = AudioFeatures.windowStartMs(durationMs)
        let outcome = await Self.decode(asset, startMs: startMs, stall: stall)
        let took = currentTimeMillis() - started
        if Task.isCancelled { return }
        switch outcome {
        case .stalled:
            publish(song, isCurrent, Status(mediaId: song.id, state: .waiting))
        case .failed:
            await measures.failed(rid, durationMs: durationMs, nowMs: currentTimeMillis())
            publish(song, isCurrent, Status(mediaId: song.id, state: .failed, tookMs: took))
        case .measured(let r):
            if r.analysedMs < AudioFeatures.minLoudnessMs {
                await measures.failed(rid, durationMs: durationMs, nowMs: currentTimeMillis())
                publish(song, isCurrent, Status(mediaId: song.id, state: .failed, tookMs: took))
                return
            }
            await measures.save(AudioMeasureRow(rid: rid, version: r.version, bpmX10: r.bpmX10, tempoConf: r.tempoConf,
                                                lufsX10: r.lufsX10, onsetX1000: r.onsetX1000, analysedMs: r.analysedMs,
                                                windowStartMs: startMs, durationMs: durationMs, measuredAtMs: currentTimeMillis(),
                                                failures: 0))
            DiagnosticsLog.shared.log("brain", "measured \(song.id): bpm x10 \(r.bpmX10) (conf \(r.tempoConf)), LUFS x10 \(r.lufsX10) in \(took) ms")
            publish(song, isCurrent, Self.statusOf(song.id, r, .done, fromFile: file != nil, tookMs: took))
        }
    }

    private static func statusOf(_ mediaId: String, _ r: AudioFeatures.Result?, _ state: State, fromFile: Bool = false,
                                 tookMs: Int64 = 0) -> Status {
        let kept = r.map { AudioFeatures.chooseTempo(0, $0) } ?? (bpmX10: 0, source: 0)
        return Status(mediaId: mediaId, state: state, result: r, keptTempoX10: kept.bpmX10, keptTempoSource: kept.source,
                      fromFile: fromFile, tookMs: tookMs)
    }

    // MARK: Decoding

    nonisolated enum Outcome: Sendable {
        case measured(AudioFeatures.Result)
        case failed
        /// Playback stalled for longer than `stallGiveUpMs` meanwhile: not a failure of the track.
        case stalled
    }

    /// Decodes `AudioFeatures.windowMs` (+ 2 s) from `startMs` to 16-bit interleaved PCM with `AVAssetReader` and runs the
    /// estimator, block by block, on a background-priority task. The sample buffer is reused across blocks.
    nonisolated static func decode(_ asset: AVURLAsset, startMs: Int64, stall: StallFlag) async -> Outcome {
        await Task.detached(priority: .background) { () async -> Outcome in
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let reader = try? AVAssetReader(asset: asset) else { return .failed }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return .failed }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(value: startMs, timescale: 1000),
                                           duration: CMTime(value: Int64(AudioFeatures.windowMs + 2_000), timescale: 1000))
            guard reader.startReading() else { return .failed }
            defer { reader.cancelReading() }
            let deadline = currentTimeMillis() + deadlineMs
            var estimator: AudioFeatures.Estimator?
            var samples: [Int16] = []
            var stallSince: Int64 = 0
            while true {
                if Task.isCancelled { return .failed }
                if currentTimeMillis() > deadline { break }
                if stall.isSet {
                    // The listener's playback comes first: wait it out, and give the window up if it lasts.
                    let now = currentTimeMillis()
                    if stallSince == 0 { stallSince = now }
                    if now - stallSince > stallGiveUpMs { return .stalled }
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                stallSince = 0
                guard let buffer = output.copyNextSampleBuffer() else { break }
                guard let format = CMSampleBufferGetFormatDescription(buffer),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let channels = max(Int(asbd.mChannelsPerFrame), 1)
                if estimator == nil {
                    estimator = AudioFeatures.Estimator(sampleRate: Int(asbd.mSampleRate), channels: channels)
                }
                guard let est = estimator else { break }
                let bytes = CMBlockBufferGetDataLength(block)
                let count = bytes / 2
                if count <= 0 { continue }
                if samples.count < count { samples = [Int16](repeating: 0, count: count) }
                let copied = samples.withUnsafeMutableBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: base) == kCMBlockBufferNoErr
                }
                if !copied { continue }
                samples.withUnsafeBufferPointer { est.feed($0, offset: 0, count: count / channels) }
                if est.full { break }
            }
            // A reader that failed part-way still hands over what it decoded: too little of it reads as a failure above.
            return estimator.map { .measured($0.finish()) } ?? .failed
        }.value
    }
}

/// The stall flag the decode reads between blocks (set on the main actor, read on the measuring task).
nonisolated final class StallFlag: Sendable {
    private let value = Mutex(false)
    func set(_ stalled: Bool) { value.withLock { $0 = stalled } }
    var isSet: Bool { value.withLock { $0 } }
}
