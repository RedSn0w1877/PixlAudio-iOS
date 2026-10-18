import Foundation
import PixlTags

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
