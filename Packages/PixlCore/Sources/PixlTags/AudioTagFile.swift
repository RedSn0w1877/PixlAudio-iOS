// The format-independent entry points: read every tag of a file into TagLib's property map + pictures (what
// Android's `TagLib.getMetadata` / `getPictures` return), and write property/picture/SYLT changes back
// (`savePropertyMap` / `savePictures`) for MP3 (ID3v2 + ID3v1) and FLAC.

import Foundation

/// How a file's tags are stored.
public enum TagContainer: String, Sendable, Hashable {
    /// MPEG audio (or ADTS) with ID3v2 at the start and/or ID3v1 at the end.
    case mpeg
    case flac
    case mp4
    /// RIFF/WAVE with an `id3 ` chunk (read only).
    case wav
}

/// Everything read from a file's tags.
public struct AudioTags: Sendable, Hashable {
    public var container: TagContainer
    /// TagLib's property map for the file (its first non-empty tag, like TagLib's tag union).
    public var properties: TagProperties
    /// TagLib's `PICTURE` complex property: ID3v2 `APIC`, FLAC `PICTURE` blocks or MP4 `covr`.
    public var pictures: [TagPicture]
    public var id3v2: ID3v2Tag?
    public var id3v1: ID3v1Tag?
    public var flac: FLACFile?
    public var mp4: MP4Tag?

    /// ID3v2 `SYLT` frames (synced lyrics), if any.
    public var syncedLyrics: [ID3v2SyncedLyrics] { id3v2?.syncedLyrics ?? [] }
}

public enum AudioTagReader {
    /// Reads the tags of a complete file. Throws `TagError.unsupported` for containers without a reader here (Ogg,
    /// unknown data) and `TagError.invalid`/`.truncated` for broken FLAC/MP4 structures.
    public static func read(_ data: Data) throws -> AudioTags {
        guard data.count >= 4 else { throw TagError.unsupported("too short") }
        var offset = 0
        while let size = ID3v2Tag.totalSize(in: data, at: offset) { offset += size }
        if offset + 4 <= data.count && data.bytes(offset..<(offset + 4)) == Array("fLaC".utf8) {
            let flac = try FLACFile.parse(data)
            return AudioTags(container: .flac, properties: flac.properties, pictures: flac.pictures, id3v2: flac.id3v2,
                             id3v1: flac.id3v1, flac: flac, mp4: nil)
        }
        if offset > 0 {
            return readMPEG(data)
        }
        let head = data.bytes(0..<min(12, data.count))
        if MP4Tag.isMP4(data) {
            let mp4 = try MP4Tag.parse(data)
            return AudioTags(container: .mp4, properties: mp4.properties, pictures: mp4.pictures, id3v2: nil, id3v1: nil,
                             flac: nil, mp4: mp4)
        }
        if head.count >= 12 && ByteIO.matches(head, 0, Array("RIFF".utf8)) && ByteIO.matches(head, 8, Array("WAVE".utf8)) {
            let tag = wavID3v2(data)
            return AudioTags(container: .wav, properties: tag.map { $0.properties } ?? TagProperties(),
                             pictures: tag?.pictures ?? [], id3v2: tag, id3v1: nil, flac: nil, mp4: nil)
        }
        if ByteIO.matches(head, 0, Array("OggS".utf8)) { throw TagError.unsupported("Ogg") }
        if (head[0] == 0xFF && head[1] & 0xE0 == 0xE0) || ID3v1Tag.isPresent(in: data) {
            return readMPEG(data)
        }
        throw TagError.unsupported("unknown container")
    }

    static func readMPEG(_ data: Data) -> AudioTags {
        let v2 = ID3v2Tag.parse(data, at: 0)
        let v1 = ID3v1Tag.parse(fileData: data)
        var properties = TagProperties()
        if let v2, !v2.frames.isEmpty { properties = v2.properties } else if let v1 { properties = v1.properties }
        return AudioTags(container: .mpeg, properties: properties, pictures: v2?.pictures ?? [], id3v2: v2, id3v1: v1,
                         flac: nil, mp4: nil)
    }

    /// The ID3v2 tag in a RIFF/WAVE `id3 ` (or `ID3 `) chunk.
    static func wavID3v2(_ data: Data) -> ID3v2Tag? {
        var pos = 12
        while pos + 8 <= data.count {
            let header = data.bytes(pos..<(pos + 8))
            let id = String(decoding: header[0..<4], as: UTF8.self)
            let size = Int(ByteIO.uint32LE(header, 4))
            if id == "id3 " || id == "ID3 " {
                return ID3v2Tag.parse(data.subdata(offsets: (pos + 8)..<min(data.count, pos + 8 + size)))
            }
            pos += 8 + size + (size & 1)
        }
        return nil
    }
}

/// Tag changes to write. `nil` fields are left as they are.
public struct TagChanges: Sendable, Hashable {
    /// New property map, applied with TagLib's `setProperties` semantics (keys not in the map are removed).
    public var properties: TagProperties?
    /// New pictures (an empty list removes them all).
    public var pictures: [TagPicture]?
    /// ID3v2 only: `.some(nil)` removes the SYLT frames, `.some(x)` replaces them.
    public var syncedLyrics: ID3v2SyncedLyrics??
    /// ID3v2 version to write: 4 (TagLib's default, also the default here), 3, or nil to keep the existing tag's
    /// version (new tags are 2.4).
    public var id3v2Version: UInt8?

    public init(properties: TagProperties? = nil, pictures: [TagPicture]? = nil,
                syncedLyrics: ID3v2SyncedLyrics?? = nil, id3v2Version: UInt8? = 4) {
        self.properties = properties
        self.pictures = pictures
        self.syncedLyrics = syncedLyrics
        self.id3v2Version = id3v2Version
    }
}

public enum AudioTagWriter {
    /// Writes `changes` into a complete MP3 or FLAC file and returns the new file. MP4 and Ogg are not written here
    /// (`TagError.unsupported`).
    ///
    /// MP3, like TagLib's `MPEG::File`: the ID3v2 tag at the start is replaced (created when missing, removed when it
    /// ends up without frames), reusing its space when the frames fit; an existing ID3v1 tag is updated with the
    /// same properties. Unlike TagLib's `save()`, an ID3v1 tag is never added to a file that has none.
    /// FLAC, like TagLib's `FLAC::File`: properties go to the Vorbis comment, pictures to `PICTURE` blocks; leading
    /// ID3v2 and trailing ID3v1 tags are kept byte for byte.
    public static func write(_ changes: TagChanges, to data: Data) throws -> TagWriteResult {
        var offset = 0
        while let size = ID3v2Tag.totalSize(in: data, at: offset) { offset += size }
        if offset + 4 <= data.count && data.bytes(offset..<(offset + 4)) == Array("fLaC".utf8) {
            var flac = try FLACFile.parse(data)
            if let p = changes.properties { flac.setProperties(p) }
            if let pictures = changes.pictures { flac.setPictures(pictures) }
            return flac.render(into: data)
        }
        if MP4Tag.isMP4(data) && offset == 0 { throw TagError.unsupported("MP4 writing") }
        let head = data.bytes(0..<min(4, data.count))
        if ByteIO.matches(head, 0, Array("OggS".utf8)) { throw TagError.unsupported("Ogg writing") }
        if head.count >= 4 && ByteIO.matches(head, 0, Array("RIFF".utf8)) { throw TagError.unsupported("WAV writing") }
        return writeMPEG(changes, to: data)
    }

    static func writeMPEG(_ changes: TagChanges, to data: Data) -> TagWriteResult {
        let existingSize = ID3v2Tag.totalSize(in: data, at: 0) ?? 0
        var tag = ID3v2Tag.parse(data, at: 0) ?? ID3v2Tag(version: 4)
        if existingSize > 0 && tag.originalSize == 0 {
            // An ID3v2 tag of an unsupported version: replace it with a fresh one.
            tag = ID3v2Tag(version: 4)
        }
        var v1 = ID3v1Tag.parse(fileData: data)
        if let p = changes.properties {
            tag.setProperties(p)
            v1?.setProperties(p)
        }
        if let pictures = changes.pictures { tag.setPictures(pictures) }
        if let sylt = changes.syncedLyrics { tag.setSyncedLyrics(sylt) }
        let version = changes.id3v2Version ?? (tag.version == 3 ? 3 : 4)
        var patches: [TagPatch] = []
        let rendered = tag.frames.isEmpty ? Data() : tag.render(version: version, fileLength: data.count)
        if existingSize > 0 || !rendered.isEmpty {
            patches.append(TagPatch(range: 0..<min(existingSize, data.count), bytes: rendered))
        }
        if let v1, data.count - ID3v1Tag.size >= existingSize {
            patches.append(TagPatch(range: (data.count - ID3v1Tag.size)..<data.count, bytes: v1.render()))
        }
        return TagWriteResult(original: data, patches: patches)
    }
}
