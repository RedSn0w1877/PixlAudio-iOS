// The render manifest of the shared library (cloud audio spec of 2026-11-10, section 3.1): `sp-<profile>.json`, the
// phone's copy of what the worker's `library.py` writes. One manifest per render, written last, never updated in
// place.
//
// Like the Cloud Studio schema, enum-like fields stay `String` here (an unknown value from a newer worker must not
// fail the whole manifest), typed views sit next to them, unknown members are ignored, and everything the acceptance
// rule does not need is optional. Acceptance is `check(for:)` and, after the download, `audioMatches`.

import Foundation

public struct CloudLibraryManifest: Codable, Sendable, Hashable {
    public static let schemaName = "pixl.library.render"
    public static let schemaVersion = 1

    public var schema: String
    public var v: Int
    public var libV: Int
    public var videoId: String
    /// Always `spatial` (`RenditionKey.manifestKind`).
    public var kind: String
    /// The profile id.
    public var profile: String?
    /// The audio file.
    public var audio: Audio?
    public var loudness: Loudness?
    public var source: Source?
    public var render: Render?
    public var worker: Worker?
    /// ISO 8601, UTC (`2026-11-10T19:02:11Z`).
    public var createdAt: String?

    public struct Audio: Codable, Sendable, Hashable {
        /// The object key: always the canonical `lib/` key of this render.
        public var key: String
        public var bytes: Int64
        /// Lower-case hex of the file.
        public var sha256: String
        /// `flac`.
        public var codec: String?
        public var bits: Int?
        /// The uploaded file's rate (44100 from an iPhone, the stream's own rate from Android), which may differ from
        /// the rate of the stream this phone plays.
        public var sampleRate: Int?
        /// Sample frames per channel: the uploaded file's frame count (the render keeps its timeline).
        public var samples: Int64?
        public var durationMs: Int64?

        public init(key: String, bytes: Int64, sha256: String, codec: String? = "flac", bits: Int? = 16,
                    sampleRate: Int? = nil, samples: Int64? = nil, durationMs: Int64? = nil) {
            self.key = key
            self.bytes = bytes
            self.sha256 = sha256
            self.codec = codec
            self.bits = bits
            self.sampleRate = sampleRate
            self.samples = samples
            self.durationMs = durationMs
        }
    }

    public struct Loudness: Codable, Sendable, Hashable {
        public var integratedLufs: Double?
        public var sourceLufs: Double?
        /// How far under the source's loudness the render sits (4.0).
        public var headroomDb: Double?
        public var truePeakDb: Double?
        public var limiterMaxDb: Double?

        public init(integratedLufs: Double? = nil, sourceLufs: Double? = nil, headroomDb: Double? = nil,
                    truePeakDb: Double? = nil, limiterMaxDb: Double? = nil) {
            self.integratedLufs = integratedLufs
            self.sourceLufs = sourceLufs
            self.headroomDb = headroomDb
            self.truePeakDb = truePeakDb
            self.limiterMaxDb = limiterMaxDb
        }
    }

    /// The audio the render was made from (recorded, for diagnostics): `itag` and `codec` name the stream the phone
    /// played, the rest describes the file it uploaded.
    public struct Source: Codable, Sendable, Hashable {
        public var itag: Int?
        public var codec: String?
        public var sampleRate: Int?
        public var decodedSamples: Int64?
        /// SHA-256 of the uploaded file.
        public var sha256: String?

        public init(itag: Int? = nil, codec: String? = nil, sampleRate: Int? = nil, decodedSamples: Int64? = nil,
                    sha256: String? = nil) {
            self.itag = itag
            self.codec = codec
            self.sampleRate = sampleRate
            self.decodedSamples = decodedSamples
            self.sha256 = sha256
        }
    }

    public struct Render: Codable, Sendable, Hashable {
        /// `pixl-spatial-1`.
        public var engine: String?
        /// Whatever produced the stems (`open-cascade-6`; the separator is a replaceable part).
        public var stems: String?
        /// `stems6`, `stems4` or `mix`.
        public var stemMode: String?

        public init(engine: String? = nil, stems: String? = nil, stemMode: String? = nil) {
            self.engine = engine
            self.stems = stems
            self.stemMode = stemMode
        }
    }

    public struct Worker: Codable, Sendable, Hashable {
        public var version: String?
        public var gitSha: String?

        public init(version: String? = nil, gitSha: String? = nil) {
            self.version = version
            self.gitSha = gitSha
        }
    }

    public init(schema: String = CloudLibraryManifest.schemaName, v: Int = CloudLibraryManifest.schemaVersion,
                libV: Int = CloudLibrary.version, videoId: String, kind: String = RenditionKey.manifestKind,
                profile: String?, audio: Audio?, loudness: Loudness? = nil, source: Source? = nil,
                render: Render? = nil, worker: Worker? = nil, createdAt: String? = nil) {
        self.schema = schema
        self.v = v
        self.libV = libV
        self.videoId = videoId
        self.kind = kind
        self.profile = profile
        self.audio = audio
        self.loudness = loudness
        self.source = source
        self.render = render
        self.worker = worker
        self.createdAt = createdAt
    }

    /// Decodes a manifest's bytes (unknown members are ignored).
    public static func decode(_ data: Data) throws -> CloudLibraryManifest {
        try JSONDecoder().decode(CloudLibraryManifest.self, from: data)
    }

    /// Encodes with sorted keys, as the local store writes the manifest beside the audio.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// `render.stemMode`: what the spatial render was made from.
public enum CloudStemMode: String, Sendable, Hashable, CaseIterable {
    /// Six stems (vocals, drums, bass, guitar, piano, other).
    case stems6
    /// Four stems (the fallback separator).
    case stems4
    /// No usable stems: the stem-free render.
    case mix
}

/// Why a manifest is not accepted for the rendition that was asked for.
public enum CloudLibraryManifestProblem: Error, Sendable, Hashable {
    case wrongSchema(String)
    case wrongSchemaVersion(Int)
    case wrongLibraryVersion(Int)
    case wrongVideoId(String)
    case wrongKind(String)
    case wrongProfile(String?)
    /// The manifest names no audio.
    case audioMissing
    /// `audio.key` is not this render's canonical library key.
    case wrongAudioKey(String)
    /// Not FLAC.
    case wrongAudioCodec(String)
    /// The size or the SHA-256 is not usable (zero bytes, not 64 hex digits).
    case badAudioFacts
}

extension CloudLibraryManifest {
    public var stemMode: CloudStemMode? { render?.stemMode.flatMap(CloudStemMode.init(rawValue:)) }

    /// The headroom the app gives back while this render plays (`SpatialLevel.playbackGain`): the manifest's own,
    /// else today's 4 dB.
    public var headroomDb: Double {
        if let value = loudness?.headroomDb, value.isFinite { return value }
        return SpatialLevel.defaultHeadroomDb
    }

    /// The acceptance rule of spec 3.1: `schema`, `v`, `libV`, `videoId`, `kind` and `profile` are what was asked
    /// for. An accepted manifest also names its audio at the canonical key (the phone fetches only from there), as
    /// FLAC, with a size and a SHA-256 that can be verified. The answer is the audio to fetch and verify.
    public func check(for key: RenditionKey) -> Result<Audio, CloudLibraryManifestProblem> {
        guard schema == Self.schemaName else { return .failure(.wrongSchema(schema)) }
        guard v == Self.schemaVersion else { return .failure(.wrongSchemaVersion(v)) }
        guard libV == CloudLibrary.version else { return .failure(.wrongLibraryVersion(libV)) }
        guard CloudLibrary.isValidVideoId(key.videoId), videoId == key.videoId else { return .failure(.wrongVideoId(videoId)) }
        guard kind == RenditionKey.manifestKind else { return .failure(.wrongKind(kind)) }
        guard profile == key.profile.rawValue else { return .failure(.wrongProfile(profile)) }
        guard let audio else { return .failure(.audioMissing) }
        guard audio.key == CloudLibrary.audioKey(key) else { return .failure(.wrongAudioKey(audio.key)) }
        if let codec = audio.codec, codec.lowercased() != CloudLibrary.audioExtension {
            return .failure(.wrongAudioCodec(codec))
        }
        guard audio.bytes > 0, Self.isSHA256Hex(audio.sha256) else { return .failure(.badAudioFacts) }
        return .success(audio)
    }

    /// True when the manifest is accepted for `key` (`check(for:)` without the reason).
    public func isAccepted(for key: RenditionKey) -> Bool {
        if case .success = check(for: key) { return true }
        return false
    }

    /// After the download: the file's size and SHA-256 are the manifest's (hex compared without regard to case).
    /// False when the manifest names no audio.
    public func audioMatches(bytes: Int64, sha256: String) -> Bool {
        guard let audio else { return false }
        return audio.bytes == bytes && audio.sha256.lowercased() == sha256.lowercased()
    }

    /// The render keeps the uploaded file's timeline (same rate, same frame count), as far as the manifest says. Nil
    /// when it does not say (one side is missing).
    public var keepsSourceTimeline: Bool? {
        guard let rate = audio?.sampleRate, let samples = audio?.samples, let sourceRate = source?.sampleRate,
              let sourceSamples = source?.decodedSamples else { return nil }
        return rate == sourceRate && samples == sourceSamples
    }

    static func isSHA256Hex(_ text: String) -> Bool {
        let bytes = text.utf8
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66) || (byte >= 0x41 && byte <= 0x46)
        }
    }
}
