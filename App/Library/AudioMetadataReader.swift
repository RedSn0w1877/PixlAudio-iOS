import AVFoundation
import CoreMedia
import Foundation
import PixlTags

/// Tags and format of one audio file, as the scanner stores them (Android `AudioMetadataReader` + the MediaStore
/// columns).
nonisolated struct AudioFileMetadata: Sendable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var durationMs: Int64 = 0
    /// Bits per second.
    var bitrate: Int?
    var sampleRate: Int?
    var hasEmbeddedArtwork = false
    /// Unsynced embedded lyrics (`USLT` / `LYRICS` / `©lyr`).
    var lyrics: String?
    /// The first ID3v2 `SYLT` frame as LRC text.
    var syncedLyricsLRC: String?
    var replayGainTrackDb: Float?
    var replayGainAlbumDb: Float?
}

/// Reads a file's metadata: PixlTags over the file's tag region (ID3v2/ID3v1, FLAC Vorbis comments + STREAMINFO,
/// MP4 `ilst`, WAV `id3 `) — the Android-exact reader, which also gives SYLT, ReplayGain and lyrics — then
/// `AVURLAsset` for the duration, the audio format and any tag PixlTags could not provide (AIFF, CAF, …).
/// Safe to call concurrently; does all I/O on the calling task (the scanner runs four at a time).
nonisolated enum AudioMetadataReader {
    static func read(url: URL) async -> AudioFileMetadata {
        var m = AudioFileMetadata()
        if let region = TagRegionReader.read(url: url), let tags = try? AudioTagReader.read(region) {
            let mapped = AudioMetadataMapper.metadata(properties: tags.properties, pictures: tags.pictures,
                                                      readArtwork: false)
            m.title = mapped.title
            m.artist = mapped.artist
            m.album = mapped.album
            m.albumArtist = mapped.albumArtist
            m.genre = mapped.genre
            m.trackNumber = mapped.trackNumber
            m.discNumber = mapped.discNumber
            m.year = mapped.year
            m.lyrics = mapped.lyrics
            m.replayGainTrackDb = mapped.replayGainTrackGainDb
            m.replayGainAlbumDb = mapped.replayGainAlbumGainDb
            m.hasEmbeddedArtwork = tags.pictures.contains { !$0.data.isEmpty }
            m.syncedLyricsLRC = tags.syncedLyrics.first?.lrcText()
            if let info = tags.flac?.streamInfo {
                if let duration = info.durationMs { m.durationMs = duration }
                if info.sampleRate > 0 { m.sampleRate = Int(info.sampleRate) }
            }
        }
        await readWithAVFoundation(url: url, into: &m)
        if m.durationMs <= 0, url.pathExtension.lowercased() == "mp3" {
            m.durationMs = MPEGDuration.estimate(url: url) ?? 0
        }
        return m
    }

    private static func readWithAVFoundation(url: URL, into m: inout AudioFileMetadata) async {
        let asset = AVURLAsset(url: url)
        guard let loaded = try? await asset.load(.duration, .commonMetadata) else { return }
        let (duration, common) = loaded
        if m.durationMs <= 0, duration.isNumeric, duration.seconds > 0 {
            m.durationMs = Int64((duration.seconds * 1000).rounded())
        }
        func string(_ identifier: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: identifier).first,
                  let value = try? await item.load(.stringValue) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if m.title == nil { m.title = await string(.commonIdentifierTitle) }
        if m.artist == nil { m.artist = await string(.commonIdentifierArtist) }
        if m.album == nil { m.album = await string(.commonIdentifierAlbumName) }
        if m.genre == nil { m.genre = await string(.commonIdentifierType) }
        if m.year == nil, let date = await string(.commonIdentifierCreationDate) { m.year = Int(date.prefix(4)) }
        if !m.hasEmbeddedArtwork {
            m.hasEmbeddedArtwork = !AVMetadataItem.metadataItems(from: common,
                                                                 filteredByIdentifier: .commonIdentifierArtwork).isEmpty
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let format = try? await track.load(.estimatedDataRate, .formatDescriptions) {
            let (rate, descriptions) = format
            if m.bitrate == nil, rate > 0 { m.bitrate = Int(rate.rounded()) }
            if m.sampleRate == nil, let description = descriptions.first,
               let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description), basic.pointee.mSampleRate > 0 {
                m.sampleRate = Int(basic.pointee.mSampleRate)
            }
        }
    }
}

/// Constant-bitrate duration estimate of an MP3 from its first frame header (fallback when AVFoundation reports
/// no duration): audio bytes × 8 / bitrate. MPEG-1/2/2.5 Layer III only.
nonisolated enum MPEGDuration {
    static func estimate(url: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024), let fileSize = try? handle.seekToEnd() else { return nil }
        var offset = 0
        while let size = ID3v2Tag.totalSize(in: head, at: offset) { offset += size }
        var audioStart = UInt64(offset)
        if offset >= head.count {
            // A large tag: find the first frame right after it.
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let after = try? handle.read(upToCount: 4), after.count == 4 else { return nil }
            return duration(header: [UInt8](after), audioBytes: fileSize - audioStart)
        }
        let bytes = [UInt8](head)
        var i = offset
        while i + 4 <= bytes.count, !(bytes[i] == 0xFF && bytes[i + 1] & 0xE0 == 0xE0) { i += 1 }
        guard i + 4 <= bytes.count else { return nil }
        audioStart = UInt64(i)
        return duration(header: Array(bytes[i..<(i + 4)]), audioBytes: fileSize - audioStart)
    }

    static func duration(header h: [UInt8], audioBytes: UInt64) -> Int64? {
        guard h.count >= 4, h[0] == 0xFF, h[1] & 0xE0 == 0xE0, (h[1] >> 1) & 0x03 == 0x01 else { return nil }
        let version = (h[1] >> 3) & 0x03  // 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5
        let bitrateIndex = Int(h[2] >> 4)
        let mpeg1: [Int] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        let mpeg2: [Int] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        guard version != 1, bitrateIndex > 0, bitrateIndex < 15 else { return nil }
        let kbps = version == 3 ? mpeg1[bitrateIndex] : mpeg2[bitrateIndex]
        return Int64(audioBytes * 8 / UInt64(kbps))
    }
}

/// Reads only the part of a file that holds its tags, so a 40 MB FLAC costs a few kilobytes, not 40 MB:
/// leading ID3v2 tags, the FLAC metadata blocks, an MP4's `ftyp` + `moov` boxes (wherever `moov` sits), a WAV's
/// `id3 ` chunk, and a trailing ID3v1 tag. The result is a file PixlTags' `AudioTagReader` can read.
nonisolated enum TagRegionReader {
    static let headSize = 64 * 1024
    /// Limits against corrupt length fields.
    static let maxTagBytes = 32 * 1024 * 1024

    static func read(url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headSize), head.count >= 12 else { return nil }
        let fileSize = (try? handle.seekToEnd()) ?? UInt64(head.count)

        // MP4: ftyp + moov.
        if head.count >= 8, head[4] == 0x66, head[5] == 0x74, head[6] == 0x79, head[7] == 0x70 {
            return mp4Boxes(handle, fileSize: fileSize)
        }
        // WAV: RIFF header + the id3 chunk.
        if head.starts(with: Array("RIFF".utf8)), head[8] == 0x57, head[9] == 0x41, head[10] == 0x56, head[11] == 0x45 {
            return wavTagChunk(handle, fileSize: fileSize)
        }
        // Leading ID3v2 tag(s).
        var offset = 0
        var data = head
        while true {
            if offset + 10 > data.count {
                guard let more = readRange(handle, from: UInt64(data.count), count: offset + 10 - data.count + headSize)
                else { break }
                data.append(more)
            }
            guard let size = ID3v2Tag.totalSize(in: data, at: offset), offset + size <= maxTagBytes else { break }
            offset += size
            if offset + 4 > data.count {
                guard let more = readRange(handle, from: UInt64(data.count), count: offset + 4 - data.count + headSize)
                else { break }
                data.append(more)
            }
        }
        // FLAC metadata blocks after the ID3 tags.
        if offset + 4 <= data.count, data[offset] == 0x66, data[offset + 1] == 0x4C, data[offset + 2] == 0x61,
           data[offset + 3] == 0x43 {
            return flacMetadata(handle, data: data, flacStart: offset, fileSize: fileSize)
        }
        // MPEG: keep a trailing ID3v1 tag ("TAG" + 125 bytes) when the file has one.
        if fileSize >= 128, let tail = readRange(handle, from: fileSize - 128, count: 128), tail.count == 128,
           tail.starts(with: Array("TAG".utf8)), UInt64(data.count) < fileSize - 128 {
            data.append(tail)
        }
        return data
    }

    private static func readRange(_ handle: FileHandle, from offset: UInt64, count: Int) -> Data? {
        guard count > 0, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), !data.isEmpty else { return nil }
        return data
    }

    private static func flacMetadata(_ handle: FileHandle, data initial: Data, flacStart: Int, fileSize: UInt64) -> Data? {
        var data = initial
        var pos = flacStart + 4
        while true {
            if pos + 4 > data.count {
                guard let more = readRange(handle, from: UInt64(data.count), count: pos + 4 - data.count + headSize)
                else { return data }
                data.append(more)
            }
            let header = data[data.startIndex + pos]
            let length = Int(data[data.startIndex + pos + 1]) << 16 | Int(data[data.startIndex + pos + 2]) << 8
                | Int(data[data.startIndex + pos + 3])
            pos += 4 + length
            guard pos <= maxTagBytes, UInt64(pos) <= fileSize else { return data }
            if pos > data.count {
                guard let more = readRange(handle, from: UInt64(data.count), count: pos - data.count) else { return data }
                data.append(more)
            }
            if header & 0x80 != 0 { return data.prefix(pos) }
        }
    }

    private static func mp4Boxes(_ handle: FileHandle, fileSize: UInt64) -> Data? {
        var offset: UInt64 = 0
        var out = Data()
        var sawMoov = false
        while offset + 8 <= fileSize, !sawMoov {
            guard let header = readRange(handle, from: offset, count: 16), header.count >= 8 else { break }
            var size = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if size == 1, header.count >= 16 {
                size = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            } else if size == 0 {
                size = fileSize - offset
            }
            // A box can't run past the end of the file; checked as a subtraction (the loop condition keeps
            // `fileSize - offset` from underflowing) so a forged 64-bit size can't overflow `offset += size`.
            guard size >= 8, size <= fileSize - offset else { break }
            if type == "ftyp" || type == "moov" {
                guard size <= UInt64(maxTagBytes), let box = readRange(handle, from: offset, count: Int(size)),
                      UInt64(box.count) == size else { break }
                out.append(box)
                sawMoov = type == "moov"
            }
            offset += size
        }
        return sawMoov ? out : nil
    }

    private static func wavTagChunk(_ handle: FileHandle, fileSize: UInt64) -> Data? {
        var offset: UInt64 = 12
        while offset + 8 <= fileSize {
            guard let header = readRange(handle, from: offset, count: 8), header.count == 8 else { break }
            let id = String(decoding: header[0..<4], as: UTF8.self)
            let size = UInt64(header[4]) | UInt64(header[5]) << 8 | UInt64(header[6]) << 16 | UInt64(header[7]) << 24
            if id == "id3 " || id == "ID3 " {
                guard size <= UInt64(maxTagBytes), let chunk = readRange(handle, from: offset, count: Int(8 + size))
                else { return nil }
                var out = Data("RIFF".utf8)
                let total = UInt32(4 + chunk.count)
                withUnsafeBytes(of: total.littleEndian) { out.append(contentsOf: $0) }
                out.append(contentsOf: Array("WAVE".utf8))
                out.append(chunk)
                return out
            }
            offset += 8 + size + (size & 1)
        }
        return nil
    }
}

/// Embedded artwork bytes of an audio file (the `ArtworkPipeline.embeddedArtworkLoader`): the first picture
/// PixlTags finds in the tag region, else the asset's common artwork item (also works for media-library
/// `ipod-library://` URLs).
nonisolated enum EmbeddedArtworkReader {
    static func data(for url: URL) async -> Data? {
        if url.isFileURL, let region = TagRegionReader.read(url: url), let tags = try? AudioTagReader.read(region),
           let picture = tags.pictures.first(where: { !$0.data.isEmpty }) {
            return picture.data
        }
        let asset = AVURLAsset(url: url)
        guard let common = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierArtwork).first
        else { return nil }
        return try? await item.load(.dataValue)
    }
}
