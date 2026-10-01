// Port of the Android `utils/LyricsImportSecurity.kt`: validation of imported and sidecar lyrics files — extension
// and MIME allow-lists, size caps, strict text decoding (UTF-8, or UTF-16 with a BOM), control/format-character
// sanitising, and acceptance only when the content parses into synced lyrics.

import Foundation
import PixlFoundation
import PixlModel

/// An accepted import: the sanitised text to store and its parse.
public struct ValidatedLyricsImport: Sendable, Hashable {
    public var sanitizedContent: String
    public var parsedLyrics: Lyrics

    public init(sanitizedContent: String, parsedLyrics: Lyrics) {
        self.sanitizedContent = sanitizedContent
        self.parsedLyrics = parsedLyrics
    }
}

/// Why an import was refused (raw value = the Kotlin constant name).
public enum LyricsImportFailureReason: String, Sendable, Hashable, CaseIterable {
    case unsupportedExtension = "UNSUPPORTED_EXTENSION"
    case unsupportedMimeType = "UNSUPPORTED_MIME_TYPE"
    case fileTooLarge = "FILE_TOO_LARGE"
    case emptyContent = "EMPTY_CONTENT"
    case invalidEncoding = "INVALID_ENCODING"
    case invalidLyricsContent = "INVALID_LYRICS_CONTENT"
}

public enum LyricsImportValidationResult: Sendable, Hashable {
    case valid(ValidatedLyricsImport)
    case invalid(LyricsImportFailureReason)
}

public enum LyricsImportSecurity {
    public static let maxLyricsFileBytes = 256 * 1024
    /// TTML (verbose XML) and PixelPlay JSON documents get a higher ceiling.
    public static let maxTtmlFileBytes = 1024 * 1024
    /// Largest accepted sanitised LRC text, in UTF-16 units.
    public static let maxLyricsTextChars = 50_000

    enum DocumentFormat: CaseIterable {
        case lrc, json, yrc, ttml

        var fileExtension: String {
            switch self {
            case .lrc: return "lrc"
            case .json: return "json"
            case .yrc: return "yrc"
            case .ttml: return "ttml"
            }
        }

        var allowedMimeTypes: [String] {
            switch self {
            case .lrc:
                return ["text/plain", "text/x-lrc", "application/octet-stream", "application/x-subrip", "application/lrc",
                        "application/x-lrc"]
            case .json: return ["application/json", "text/plain", "application/octet-stream"]
            case .yrc: return ["text/plain", "application/octet-stream"]
            case .ttml: return ["application/ttml+xml", "application/xml", "text/xml", "text/plain", "application/octet-stream"]
            }
        }

        var maxFileBytes: Int { self == .ttml || self == .json ? LyricsImportSecurity.maxTtmlFileBytes : LyricsImportSecurity.maxLyricsFileBytes }
    }

    /// Every allowed MIME type, first occurrence order (for a document picker).
    public static func pickerMimeTypes() -> [String] {
        var seen: [String] = []
        for format in DocumentFormat.allCases {
            for mime in format.allowedMimeTypes where !seen.contains(mime) { seen.append(mime) }
        }
        return seen
    }

    /// `lrc`, `json`, `yrc`, `ttml` (sidecar lookup order).
    public static func supportedFileExtensions() -> [String] { DocumentFormat.allCases.map(\.fileExtension) }

    /// The largest file accepted for `fileName`'s format (nil for unsupported extensions); read at most one byte
    /// more than this before calling `validateImportedLyricsFile`.
    public static func maxFileBytes(forFileName fileName: String?) -> Int? { resolveDocumentFormat(fileName)?.maxFileBytes }

    /// Validates an imported file's name, MIME type and bytes (`validateImportedLyricsFile`).
    public static func validateImportedLyricsFile(fileName: String?, mimeType: String?, bytes: [UInt8],
                                                  reportedSizeBytes: Int64? = nil) -> LyricsImportValidationResult {
        guard let format = resolveDocumentFormat(fileName) else { return .invalid(.unsupportedExtension) }
        if !hasSupportedMimeType(format, mimeType) { return .invalid(.unsupportedMimeType) }
        if let reportedSizeBytes, reportedSizeBytes > Int64(format.maxFileBytes) { return .invalid(.fileTooLarge) }
        if bytes.count > format.maxFileBytes + 1 { return .invalid(.fileTooLarge) }
        return validatePayload(bytes, format)
    }

    /// Validates a sidecar file on disk (`validateLocalLyricsFile`).
    public static func validateLocalLyricsFile(at url: URL) -> LyricsImportValidationResult {
        guard let format = resolveDocumentFormat(url.lastPathComponent) else { return .invalid(.unsupportedExtension) }
        let path = url.path
        guard FileManager.default.isReadableFile(atPath: path) else { return .invalid(.emptyContent) }
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
           size.int64Value > Int64(format.maxFileBytes) {
            return .invalid(.fileTooLarge)
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: format.maxFileBytes + 2) ?? Data()
            if data.count > format.maxFileBytes + 1 { return .invalid(.fileTooLarge) }
            return validatePayload([UInt8](data), format)
        } catch {
            return .invalid(.invalidEncoding)
        }
    }

    /// Sanitises raw text and accepts it when it parses into synced lyrics (`validateImportedLrcContent`).
    public static func validateImportedLrcContent(_ rawText: String) -> LyricsImportValidationResult {
        let sanitized = sanitizeImportedLyrics(rawText)
        if ParseKit.isBlank(sanitized) { return .invalid(.emptyContent) }
        let limit = ParseKit.hasPrefix(sanitized.kotlinTrimmedStart(), "{") ? maxTtmlFileBytes : maxLyricsTextChars
        if sanitized.utf16.count > limit { return .invalid(.fileTooLarge) }
        let parsed = LyricsUtils.parseLyrics(sanitized)
        guard let synced = parsed.synced, !synced.isEmpty else { return .invalid(.invalidLyricsContent) }
        return .valid(ValidatedLyricsImport(sanitizedContent: sanitized, parsedLyrics: parsed))
    }

    /// The Android user-facing message for a failure.
    public static func message(for reason: LyricsImportFailureReason) -> String {
        switch reason {
        case .unsupportedExtension: return "Supported lyrics files: .lrc, .ttml, .yrc and PixelPlay .json."
        case .unsupportedMimeType: return "The selected file type is not a supported lyrics file."
        case .fileTooLarge: return "Lyrics file is too large."
        case .emptyContent: return "Lyrics file is empty."
        case .invalidEncoding: return "Lyrics file could not be decoded safely."
        case .invalidLyricsContent: return "File does not contain valid lyrics."
        }
    }

    // MARK: Internals

    static func validatePayload(_ payload: [UInt8], _ format: DocumentFormat) -> LyricsImportValidationResult {
        if payload.isEmpty { return .invalid(.emptyContent) }
        if payload.count > format.maxFileBytes { return .invalid(.fileTooLarge) }
        guard let decoded = decodeText(payload) else { return .invalid(.invalidEncoding) }
        for candidate in normalizationCandidates(decoded, format) {
            let validation = validateImportedLrcContent(candidate)
            if case .valid = validation { return validation }
        }
        return .invalid(.invalidLyricsContent)
    }

    static func normalizationCandidates(_ decoded: String, _ format: DocumentFormat) -> [String] {
        let candidates: [String]
        switch format {
        case .json, .yrc:
            candidates = [sanitizeImportedLyrics(decoded)]
        case .lrc:
            candidates = [sanitizeImportedLyrics(decoded)]
                + [TtmlLyricsParser.parseToEnhancedLrc(decoded).map(sanitizeImportedLyrics)].compactMap { $0 }
        case .ttml:
            candidates = [TtmlLyricsParser.parseToEnhancedLrc(decoded).map(sanitizeImportedLyrics)].compactMap { $0 }
                + [sanitizeImportedLyrics(decoded)]
        }
        var distinct: [String] = []
        for c in candidates where !distinct.contains(where: { $0.isIdentical(to: c) }) { distinct.append(c) }
        return distinct.filter { !ParseKit.isBlank($0) }
    }

    /// The format for the file name's final extension (case-insensitive).
    static func resolveDocumentFormat(_ fileName: String?) -> DocumentFormat? {
        guard let fileName else { return nil }
        let lower = fileName.lowercased()
        let scalars = Array(lower.unicodeScalars)
        guard let dot = scalars.lastIndex(of: ".") else { return nil }
        let ext = ParseKit.string(scalars[(dot + 1)...])
        return DocumentFormat.allCases.first { $0.fileExtension.isIdentical(to: ext) }
    }

    /// An absent/blank MIME type is accepted; parameters (`; charset=…`) and case are ignored.
    static func hasSupportedMimeType(_ format: DocumentFormat, _ mimeType: String?) -> Bool {
        let normalized = ParseKit.trim(ParseKit.substringBefore(mimeType ?? "", ";")).lowercased()
        if ParseKit.isBlank(normalized) { return true }
        return format.allowedMimeTypes.contains { $0.isIdentical(to: normalized) }
    }

    /// Strict decoding: UTF-8 (BOM optional) or UTF-16 LE/BE with a BOM; malformed input fails.
    static func decodeText(_ payload: [UInt8]) -> String? {
        if payload.count >= 3 && payload[0] == 0xEF && payload[1] == 0xBB && payload[2] == 0xBF {
            return String(validating: payload[3...], as: UTF8.self)
        }
        if payload.count >= 2 && payload[0] == 0xFF && payload[1] == 0xFE { return decodeUTF16(payload[2...], littleEndian: true) }
        if payload.count >= 2 && payload[0] == 0xFE && payload[1] == 0xFF { return decodeUTF16(payload[2...], littleEndian: false) }
        return String(validating: payload, as: UTF8.self)
    }

    private static func decodeUTF16(_ bytes: ArraySlice<UInt8>, littleEndian: Bool) -> String? {
        guard bytes.count % 2 == 0 else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let a = UInt16(bytes[index]), b = UInt16(bytes[index + 1])
            units.append(littleEndian ? (b << 8 | a) : (a << 8 | b))
            index += 2
        }
        return String(validating: units, as: UTF16.self)
    }

    /// Line endings unified, per line: trailing BOMs, format characters and control characters (tab kept) removed;
    /// the whole text trimmed.
    static func sanitizeImportedLyrics(_ rawText: String) -> String {
        var text = ParseKit.replacing(rawText, "\r\n", with: "\n")
        text = ParseKit.replacing(text, "\r", with: "\n")
        let lines = ParseKit.lines(text).map { line -> String in
            let withoutBom = ParseKit.trim(line, start: false) { $0.value == 0xFEFF }
            return ParseKit.filterNot(withoutBom) { ParseKit.isFormatChar($0) || (ParseKit.isISOControl($0) && $0 != "\t") }
        }
        return ParseKit.trim(lines.joined(separator: "\n"))
    }
}
