// Container detection by magic bytes: a port of `SongMetadataEditor.detectContainerFormat` /
// `detectOggContainer` and of the extension routing in `editSongMetadata`.

import Foundation

/// Android's `DetectedContainer`.
public enum AudioContainer: String, Sendable, Hashable, CaseIterable {
    case mp3, mp4, flac, oggOpus, oggVorbis, ogg, wav, unknown

    /// The extension Android routes a container to (`canonicalExtension`).
    public var canonicalExtension: String {
        switch self {
        case .mp3: return "mp3"
        case .mp4: return "m4a"
        case .flac: return "flac"
        case .oggOpus: return "opus"
        case .oggVorbis, .ogg: return "ogg"
        case .wav: return "wav"
        case .unknown: return ""
        }
    }

    /// Android `detectContainerFormat` over the first 512 bytes: `ID3` or an MPEG frame sync → MP3, `ftyp` at 4 →
    /// MP4, `fLaC`, `OggS` (Opus/Vorbis by the first packet), `RIFF…WAVE`. Note that a FLAC file with a leading
    /// ID3v2 tag is reported as MP3, exactly like Android; `AudioTagReader` looks past the tag instead.
    public static func detect(_ data: Data) -> AudioContainer {
        let h = data.bytes(0..<min(512, data.count))
        let n = h.count
        guard n >= 4 else { return .unknown }
        if h[0] == 0x49 && h[1] == 0x44 && h[2] == 0x33 { return .mp3 }
        if h[0] == 0xFF && h[1] & 0xE0 == 0xE0 { return .mp3 }
        if n >= 8 && ByteIO.matches(h, 4, Array("ftyp".utf8)) { return .mp4 }
        if ByteIO.matches(h, 0, Array("fLaC".utf8)) { return .flac }
        if ByteIO.matches(h, 0, Array("OggS".utf8)) { return detectOgg(h) }
        if n >= 12 && ByteIO.matches(h, 0, Array("RIFF".utf8)) && ByteIO.matches(h, 8, Array("WAVE".utf8)) { return .wav }
        return .unknown
    }

    /// Android `detectOggContainer`.
    static func detectOgg(_ h: [UInt8]) -> AudioContainer {
        guard h.count >= 28 else { return .ogg }
        let bodyOffset = 27 + Int(h[26])
        guard bodyOffset < h.count else { return .ogg }
        if ByteIO.matches(h, bodyOffset, Array("OpusHead".utf8)) { return .oggOpus }
        if h[bodyOffset] == 0x01 && ByteIO.matches(h, bodyOffset + 1, Array("vorbis".utf8)) { return .oggVorbis }
        return .ogg
    }

    /// The extension `editSongMetadata` writes as: Ogg Opus always as `opus`; a detected container whose extension
    /// differs from the file's wins; otherwise the file's extension (lower-cased).
    public static func effectiveExtension(fileExtension: String, detected: AudioContainer) -> String {
        let ext = fileExtension.lowercased()
        if detected == .oggOpus { return detected.canonicalExtension }
        if detected != .unknown && detected.canonicalExtension != ext { return detected.canonicalExtension }
        return ext
    }
}
