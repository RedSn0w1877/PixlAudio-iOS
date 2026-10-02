// A streaming reader for uncompressed ustar archives — how the on-device ML models are shipped (an `.mlpackage`
// directory archived by ci/ml/common.py `tar_mlpackage`). iOS has no public tar/zip extraction API and the app uses
// no third-party code, so this is the whole format: 512-byte headers, octal sizes, data padded to 512 bytes.

import Foundation

/// One ustar header block.
public struct UstarHeader: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case file
        case directory
        /// Anything else (links, pax/GNU extensions, devices) — refused by the extractor.
        case other(UInt8)
    }

    /// The member path (`prefix/name`), as stored.
    public var path: String
    public var size: Int64
    public var kind: Kind

    public static let blockSize = 512

    /// Parses a 512-byte block; nil for the all-zero end block. Throws on a damaged header (bad checksum, size).
    public static func parse(_ block: [UInt8]) throws(UstarError) -> UstarHeader? {
        guard block.count == blockSize else { throw .truncated }
        if block.allSatisfy({ $0 == 0 }) { return nil }
        guard let declared = octal(block[148..<156]) else { throw .badHeader }
        var sum: Int64 = 0
        for (i, byte) in block.enumerated() { sum += (148..<156).contains(i) ? 32 : Int64(byte) }
        guard sum == declared else { throw .badChecksum }
        guard let size = octal(block[124..<136]), size >= 0 else { throw .badHeader }
        let name = string(block[0..<100])
        let prefix = string(block[345..<500])
        let isUstar = block[257..<262].elementsEqual(Array("ustar".utf8))
        let path = isUstar && !prefix.isEmpty ? prefix + "/" + name : name
        let kind: Kind = switch block[156] {
        case 0, UInt8(ascii: "0"), UInt8(ascii: "7"): path.hasSuffix("/") ? .directory : .file
        case UInt8(ascii: "5"): .directory
        default: .other(block[156])
        }
        return UstarHeader(path: path, size: size, kind: kind)
    }

    static func octal(_ bytes: ArraySlice<UInt8>) -> Int64? {
        var value: Int64 = 0
        var sawDigit = false
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                value = value * 8 + Int64(byte - UInt8(ascii: "0"))
                sawDigit = true
            case 0, UInt8(ascii: " "):
                if sawDigit { return value }
            default:
                return nil
            }
        }
        return sawDigit ? value : 0
    }

    static func string(_ bytes: ArraySlice<UInt8>) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
    }

    /// Member paths that stay inside the destination: relative, no `..`, no empty components.
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let trimmed = path.hasSuffix("/") ? parts.dropLast() : parts[...]
        return trimmed.allSatisfy { !$0.isEmpty && $0 != ".." && $0 != "." }
    }
}

public enum UstarError: Error, Sendable, Hashable {
    case truncated
    case badHeader
    case badChecksum
    case unsafePath(String)
    case unsupportedEntry(String)
    case io(String)
}

/// Extracts an archive file into a directory, streaming (1 MiB at a time).
public enum UstarExtractor {
    /// Extracts every member of `archive` under `destination` and returns the member paths. `progress(bytesRead)`
    /// may throw to cancel (the partial output is left for the caller to delete).
    @discardableResult
    public static func extract(archive: URL, to destination: URL,
                               progress: (Int64) throws -> Void = { _ in }) throws -> [String] {
        let fm = FileManager.default
        guard let input = FileHandle(forReadingAtPath: archive.path) else { throw UstarError.io("Can't open the archive") }
        defer { try? input.close() }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var members: [String] = []
        var bytesRead: Int64 = 0

        func read(_ count: Int) throws -> [UInt8] {
            do {
                let data = try input.read(upToCount: count) ?? Data()
                bytesRead += Int64(data.count)
                return [UInt8](data)
            } catch {
                throw UstarError.io(error.localizedDescription)
            }
        }

        while true {
            let block = try read(UstarHeader.blockSize)
            if block.isEmpty { break }                       // tolerate a missing end marker
            guard let header = try UstarHeader.parse(block) else { break }
            guard UstarHeader.isSafe(header.path) else { throw UstarError.unsafePath(header.path) }
            let target = destination.appendingPathComponent(header.path)
            switch header.kind {
            case .directory:
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case .file:
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: target.path, contents: nil),
                      let output = FileHandle(forWritingAtPath: target.path) else {
                    throw UstarError.io("Can't write \(header.path)")
                }
                defer { try? output.close() }
                var remaining = header.size
                while remaining > 0 {
                    let chunk = try read(Int(min(remaining, 1 << 20)))
                    guard !chunk.isEmpty else { throw UstarError.truncated }
                    do { try output.write(contentsOf: chunk) } catch { throw UstarError.io(error.localizedDescription) }
                    remaining -= Int64(chunk.count)
                    try progress(bytesRead)
                }
            case .other:
                throw UstarError.unsupportedEntry(header.path)
            }
            let padding = Int((Int64(UstarHeader.blockSize) - header.size % Int64(UstarHeader.blockSize))
                              % Int64(UstarHeader.blockSize))
            if padding > 0, try read(padding).count != padding { throw UstarError.truncated }
            members.append(header.path)
        }
        return members
    }
}
