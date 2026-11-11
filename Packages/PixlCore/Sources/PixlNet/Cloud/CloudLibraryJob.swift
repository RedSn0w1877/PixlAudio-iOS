// Spatial audio's library jobs (cloud audio spec of 2026-11-10, sections 3, 4 and 6.2): the `library` block a job
// sends, the `library` block its result carries, what the phone remembers of such a job (`CloudLibraryJobInfo`, on the
// record), and the pure rules around them: the canonical keys every URL is signed for, the stream the audio came from,
// and the checks a render must pass before it is stored. The orchestrator (`CloudStudio`) only sequences the I/O.
//
// Like the rest of the schema, enum-like fields stay `String` on the wire (an unknown value from a newer worker must
// not fail the whole manifest), with typed views next to them.

import Foundation
import PixlModel

// MARK: - The job's `library` block

/// `input.library`: the video whose renders are wanted, the stream its audio came from (recorded only), and one entry
/// per profile with the presigned URLs of its canonical library keys.
public struct CloudLibraryJobRequest: Codable, Sendable, Hashable {
    /// `LIB_V` (`CloudLibrary.version`): the worker refuses any other (`UNSUPPORTED_VERSION`, "library.v").
    public var v: Int
    public var videoId: String
    /// The STREAM the uploaded audio came from (its itag and codec), not the uploaded FLAC. Optional, recorded only.
    public var source: CloudLibrarySource?
    /// One to six entries, profiles unique.
    public var renders: [CloudLibraryRenderRequest]

    public init(v: Int = CloudLibrary.version, videoId: String, source: CloudLibrarySource?,
                renders: [CloudLibraryRenderRequest]) {
        self.v = v
        self.videoId = videoId
        self.source = source
        self.renders = renders
    }
}

/// `input.library.source`.
public struct CloudLibrarySource: Codable, Sendable, Hashable {
    public var itag: Int?
    /// At most 16 characters (`aac`, `opus`).
    public var codec: String?

    public init(itag: Int?, codec: String?) {
        self.itag = itag
        self.codec = codec
    }

    /// Nil when nothing is known (the block then has no `source`).
    public static func known(itag: Int?, codec: String?) -> CloudLibrarySource? {
        let trimmed = codec.map { String($0.prefix(16)) }.flatMap { $0.isEmpty ? nil : $0 }
        guard itag != nil || trimmed != nil else { return nil }
        return CloudLibrarySource(itag: itag, codec: trimmed)
    }
}

/// One entry of `input.library.renders`: the profile, and presigned URLs for its canonical keys.
public struct CloudLibraryRenderRequest: Codable, Sendable, Hashable {
    public var profile: String
    /// PUT `lib/v1/<videoId>/sp-<profile>.flac`.
    public var audioPut: String
    /// PUT `lib/v1/<videoId>/sp-<profile>.json` (written last by the worker).
    public var manifestPut: String
    /// GET of the same manifest: the worker's "already there" check. Optional.
    public var manifestGet: String?

    public init(profile: String, audioPut: String, manifestPut: String, manifestGet: String?) {
        self.profile = profile
        self.audioPut = audioPut
        self.manifestPut = manifestPut
        self.manifestGet = manifestGet
    }
}

// MARK: - The result's `library` block

/// What the worker did with one requested render.
public enum CloudLibraryRenderState: String, Sendable, Hashable, CaseIterable, Codable {
    /// Made by this job.
    case ok
    /// Already in the library (the worker's `manifestGet` found a valid manifest): nothing was rendered.
    case exists
    /// Not made (the job is then `partial`, or an error when nothing was made).
    case failed

    /// There is a render to fetch from the library.
    public var hasRender: Bool { self == .ok || self == .exists }
}

/// `library` of a job manifest: `{"videoId": …, "libV": 1, "renders": {"studio": "ok"}, "stemMode": "stems6"}`.
public struct CloudLibraryResult: Codable, Sendable, Hashable {
    public var videoId: String?
    public var libV: Int?
    /// Profile id → `ok`, `exists` or `failed`.
    public var renders: [String: String]?
    /// `stems6`, `stems4`, `mix`; null when nothing was rendered.
    public var stemMode: String?

    public init(videoId: String?, libV: Int?, renders: [String: String]?, stemMode: String?) {
        self.videoId = videoId
        self.libV = libV
        self.renders = renders
        self.stemMode = stemMode
    }

    /// The typed state of one profile's render; an unknown state reads as `failed` (it is never imported), a profile
    /// the result does not name as nil.
    public func state(of profile: SpatialProfile) -> CloudLibraryRenderState? {
        guard let raw = renders?[profile.rawValue] else { return nil }
        return CloudLibraryRenderState(rawValue: raw) ?? .failed
    }
}

// MARK: - What the phone remembers

/// A Spatial audio library job as the phone remembers it (`CloudJobRecord.library`): spec 6.2 steps 2 to 4 for one
/// video. The job first looks in the shared library (a hit needs no upload and no GPU), then renders what is missing,
/// then fetches every render from its `lib/` key, verifies it and stores it on the phone.
///
/// Every field but `videoId` and `profiles` is optional: the job list is one Codable file, and a field older stored
/// lists lack must never make it unreadable.
public struct CloudLibraryJobInfo: Codable, Sendable, Hashable {
    public var videoId: String
    /// Profile ids asked for (one per job today). Strings, so an unknown one never breaks the list.
    public var profiles: [String]
    /// Sent by the background queue (spec 6.4): Wi-Fi only, quiet, counts for the day's `cloudAudio.dailyAhead`.
    public var ahead: Bool?
    /// The stream the audio came from (`library.source`), once the audio is on the phone.
    public var sourceItag: Int?
    public var sourceCodec: String?
    /// The shared library already had every render asked for (spec 6.2 step 2): nothing went up, no GPU ran.
    public var foundInLibrary: Bool?
    /// The month's cap for library jobs held it back before its audio was prepared (status `capReached`).
    public var heldByCap: Bool?
    /// Per profile: `ok`, `exists` or `failed` (from the job manifest, or `exists` from the lookup).
    public var renders: [String: String]?
    public var stemMode: String?
    /// The render manifests read before each download, stored beside the audio once it is verified.
    public var manifests: [String: CloudLibraryManifest]?
    /// The profile whose render is coming down now.
    public var downloading: String?
    /// Profiles verified and stored on the phone.
    public var imported: [String]?
    /// Profiles whose render did not pass the phone's checks (never stored).
    public var rejected: [String]?

    public init(videoId: String, profiles: [SpatialProfile], ahead: Bool = false) {
        self.videoId = videoId
        self.profiles = profiles.map(\.rawValue)
        self.ahead = ahead ? true : nil
    }

    /// The profiles asked for that this app knows, in order, without repeats.
    public var typedProfiles: [SpatialProfile] {
        var seen = Set<SpatialProfile>()
        return profiles.compactMap(SpatialProfile.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    /// The renditions this job is about.
    public var keys: [RenditionKey] { typedProfiles.map { RenditionKey(videoId: videoId, profile: $0) } }

    public var isAhead: Bool { ahead == true }

    public func covers(_ key: RenditionKey) -> Bool {
        videoId == key.videoId && profiles.contains(key.profile.rawValue)
    }

    /// The worker's (or the lookup's) answer for one profile; an unknown text reads as `failed`.
    public func state(of profile: SpatialProfile) -> CloudLibraryRenderState? {
        guard let raw = renders?[profile.rawValue] else { return nil }
        return CloudLibraryRenderState(rawValue: raw) ?? .failed
    }

    public func isImported(_ profile: SpatialProfile) -> Bool { imported?.contains(profile.rawValue) == true }
    public func isRejected(_ profile: SpatialProfile) -> Bool { rejected?.contains(profile.rawValue) == true }

    /// The next render to fetch: one the worker made or found that is neither stored nor rejected yet.
    public var nextToFetch: SpatialProfile? {
        typedProfiles.first { profile in
            (state(of: profile)?.hasRender ?? false) && !isImported(profile) && !isRejected(profile)
        }
    }

    /// Every profile asked for has an outcome on the phone: stored, rejected, or not made by the worker (failed, or
    /// missing from its answer). False while there is no answer at all.
    public var isSettled: Bool {
        guard renders != nil else { return false }
        return typedProfiles.allSatisfy { profile in
            isImported(profile) || isRejected(profile) || !(state(of: profile)?.hasRender ?? false)
        }
    }

    /// Something was stored on the phone.
    public var hasImports: Bool { !(imported ?? []).isEmpty }

    /// An answer that names no profile at all (a worker that wrote no `library` block): every profile counts as not made.
    public mutating func settleUnanswered() {
        guard renders == nil else { return }
        renders = Dictionary(profiles.map { ($0, CloudLibraryRenderState.failed.rawValue) }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether this profile's render ended up unusable for this job: not made, or rejected by the phone.
    public func didFail(_ profile: SpatialProfile) -> Bool {
        if isRejected(profile) { return true }
        guard let state = state(of: profile) else { return false }
        return !state.hasRender
    }

    /// One profile's answer (the lookup's `exists`, or the phone's own finding).
    public mutating func setState(_ state: CloudLibraryRenderState, for profile: SpatialProfile) {
        var states = renders ?? [:]
        states[profile.rawValue] = state.rawValue
        renders = states
    }

    public mutating func markImported(_ profile: SpatialProfile) {
        var list = imported ?? []
        if !list.contains(profile.rawValue) { list.append(profile.rawValue) }
        imported = list
        if downloading == profile.rawValue { downloading = nil }
    }

    public mutating func markRejected(_ profile: SpatialProfile) {
        var list = rejected ?? []
        if !list.contains(profile.rawValue) { list.append(profile.rawValue) }
        rejected = list
        if downloading == profile.rawValue { downloading = nil }
    }

    /// The job manifest's `library` block (and nothing else of it) is taken over: the per-profile states and the stem
    /// mode. A result for another video or library version names nothing of this job.
    public mutating func take(_ result: CloudLibraryResult?) {
        guard let result else { return }
        if let video = result.videoId, video != videoId { return }
        if let libV = result.libV, libV != CloudLibrary.version { return }
        var states = renders ?? [:]
        for (profile, state) in result.renders ?? [:] where profiles.contains(profile) { states[profile] = state }
        renders = states
        if let mode = result.stemMode { stemMode = mode }
    }

    /// Everything a new attempt starts without (a retry, a re-upload): what was found, held, fetched or rejected.
    public mutating func resetOutcome() {
        foundInLibrary = nil
        heldByCap = nil
        renders = nil
        stemMode = nil
        manifests = nil
        downloading = nil
        imported = nil
        rejected = nil
    }
}

// MARK: - Building

public enum CloudLibraryJobBuilder {
    /// `input.library` for a job: every URL presigned for its canonical key (`CloudLibrary.audioKey` / `manifestKey`),
    /// valid `seconds`. Nil when the video id or a profile is not one the library accepts, when there is no profile, or
    /// when a URL can't be signed.
    public static func block(for info: CloudLibraryJobInfo, seconds: Int, presign: CloudPresign) -> CloudLibraryJobRequest? {
        guard CloudLibrary.isValidVideoId(info.videoId) else { return nil }
        let profiles = info.typedProfiles
        guard !profiles.isEmpty, profiles.count <= SpatialProfile.allCases.count,
              profiles.count == info.profiles.count else { return nil }
        var renders: [CloudLibraryRenderRequest] = []
        for profile in profiles {
            let key = RenditionKey(videoId: info.videoId, profile: profile)
            guard let audioKey = CloudLibrary.audioKey(key), let manifestKey = CloudLibrary.manifestKey(key),
                  let audioPut = presign(.put, audioKey, seconds), let manifestPut = presign(.put, manifestKey, seconds),
                  let manifestGet = presign(.get, manifestKey, seconds) else { return nil }
            renders.append(CloudLibraryRenderRequest(profile: profile.rawValue, audioPut: audioPut,
                                                     manifestPut: manifestPut, manifestGet: manifestGet))
        }
        return CloudLibraryJobRequest(videoId: info.videoId,
                                      source: CloudLibrarySource.known(itag: info.sourceItag, codec: info.sourceCodec),
                                      renders: renders)
    }
}

// MARK: - The stream the audio came from

/// `library.source` names the STREAM the phone played (spec 6.2 step 3), which the stream cache records as an itag and
/// a content type.
public enum CloudLibrarySourceFormat {
    /// The itag as a number (the cache keeps it as text).
    public static func itag(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        guard let value = Int(text), value > 0, value < 100_000 else { return nil }
        return value
    }

    /// The audio codec of a YouTube stream: from its itag when it is a known audio one, else from its content type
    /// (`audio/webm` is Opus, `audio/mp4` AAC). Nil when neither says.
    public static func codec(itag: Int?, contentType: String?) -> String? {
        switch itag {
        case 249?, 250?, 251?, 338?, 774?: return "opus"
        case 139?, 140?, 141?, 256?, 258?, 18?, 22?: return "aac"
        default: break
        }
        guard let type = contentType?.lowercased() else { return nil }
        if type.contains("opus") || type.contains("webm") { return "opus" }
        if type.contains("mp4a") || type.contains("mp4") || type.contains("aac") { return "aac" }
        return nil
    }
}

// MARK: - Checks before a render is stored

public enum CloudLibraryImportCheck {
    /// A render fetched from the shared library may come from another phone's upload at another rate, so it is lined
    /// up by media time only (spec 6.2 step 3), never by frame count. What is checked is that it is the whole song: a
    /// render made from a cut-off upload (a stream that stopped early) must not be stored. True when the song's length
    /// is not known.
    public static func sharedRenderCoversSong(renderDurationMs: Int64?, songDurationMs: Int64?) -> Bool {
        guard let song = songDurationMs, song > 0 else { return true }
        guard let render = renderDurationMs, render > 0 else { return false }
        let slack = max(10_000, song / 10)
        return render + slack >= song
    }

    /// A render this phone's own job made keeps the uploaded file's timeline (spec 3): its frame count is the phone's
    /// own decode of the upload, within one AAC frame, compared at the worker's 44.1 kHz. True when either side is not
    /// known (the shared-library check then stands in).
    public static func ownRenderLinesUp(decodedFrames: Int64?, decodedSampleRate: Double?, manifest: CloudLibraryManifest) -> Bool {
        guard let frames = decodedFrames, frames > 0, let rate = decodedSampleRate, rate > 0,
              let samples = manifest.audio?.samples, samples > 0, let renderRate = manifest.audio?.sampleRate,
              renderRate > 0 else { return true }
        return CloudImportCheck.samplesMatch(sourceFrames: frames, sourceSampleRate: rate, resultFrames: samples,
                                             resultSampleRate: Double(renderRate))
    }

    /// The job manifest's output for a render names its canonical library key, and (when it says) the same file as
    /// the render's own manifest.
    public static func outputAgrees(_ output: CloudOutputFile?, with audio: CloudLibraryManifest.Audio, key: RenditionKey) -> Bool {
        guard let canonical = CloudLibrary.audioKey(key), audio.key == canonical else { return false }
        guard let output else { return true }
        return output.key == canonical && output.bytes == audio.bytes
            && output.sha256.lowercased() == audio.sha256.lowercased()
    }
}

extension CloudOutputFile {
    /// The output a render manifest describes (a hit in the shared library has no job manifest to name it).
    public init(render audio: CloudLibraryManifest.Audio) {
        self.init(key: audio.key, bytes: audio.bytes, sha256: audio.sha256, codec: audio.codec, kbps: nil,
                  sampleRate: audio.sampleRate, samples: audio.samples)
    }
}
