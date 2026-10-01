import Foundation
import Testing
import PixlModel
@testable import PixlLyrics

/// Port of the Android `utils/LyricsImportSecurityTest` (all 12 cases), plus Swift checks.
@Suite("Parsing — LyricsImportSecurity")
struct ParsingImportSecurityTests {

    static func valid(_ result: LyricsImportValidationResult) throws -> ValidatedLyricsImport {
        guard case .valid(let value) = result else {
            Issue.record("Expected a valid import, got \(result)")
            throw CancellationError()
        }
        return value
    }

    @Test func acceptsSyncedLrcAndSanitizesControlCharacters() throws {
        let raw = "\u{FEFF}[00:01.00]\u{202E}Hello world"
        let result = LyricsImportSecurity.validateImportedLyricsFile(fileName: "track.lrc", mimeType: "text/plain",
                                                                     bytes: Array(raw.utf8), reportedSizeBytes: Int64(raw.utf8.count))
        let value = try Self.valid(result)
        #expect(value.sanitizedContent == "[00:01.00]Hello world")
        #expect(value.parsedLyrics.synced?.count == 1)
    }

    @Test func rejectsUnsupportedExtensions() {
        let result = LyricsImportSecurity.validateImportedLyricsFile(fileName: "track.txt", mimeType: "text/plain",
                                                                     bytes: Array("[00:01.00]Hello".utf8))
        #expect(result == .invalid(.unsupportedExtension))
    }

    @Test func rejectsUnsyncedLrcContent() {
        let result = LyricsImportSecurity.validateImportedLyricsFile(fileName: "track.lrc", mimeType: "text/plain",
                                                                     bytes: Array("just plain text".utf8))
        #expect(result == .invalid(.invalidLyricsContent))
    }

    @Test func rejectsOversizedPayloadEvenWithoutReportedSize() {
        let chunk = "[00:01.00]hello world\n"
        var oversized = ""
        while oversized.utf16.count <= LyricsImportSecurity.maxLyricsFileBytes { oversized += chunk }
        let result = LyricsImportSecurity.validateImportedLyricsFile(fileName: "track.lrc", mimeType: "text/plain",
                                                                     bytes: Array(oversized.utf8), reportedSizeBytes: nil)
        #expect(result == .invalid(.fileTooLarge))
    }

    @Test func validateLocalLyricsFileRejectsBinaryPayload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-security-\(UUID().uuidString).lrc")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LyricsImportSecurity.validateLocalLyricsFile(at: url) == .invalid(.invalidEncoding))
    }

    @Test func acceptsUtf16BomPayload() throws {
        let lyrics = "[00:01.00]Hola mundo"
        var payload: [UInt8] = [0xFF, 0xFE]
        for unit in lyrics.utf16 { payload.append(UInt8(unit & 0xFF)); payload.append(UInt8(unit >> 8)) }
        let value = try Self.valid(LyricsImportSecurity.validateImportedLyricsFile(
            fileName: "track.lrc", mimeType: "application/octet-stream", bytes: payload, reportedSizeBytes: Int64(payload.count)))
        #expect(value.sanitizedContent == lyrics)
        #expect(value.parsedLyrics.synced?.count == 1)
    }

    @Test func acceptsAppleTtmlLineByLine() throws {
        let ttml = """
            <tt xmlns="http://www.w3.org/ns/ttml">
              <body>
                <div>
                  <p begin="00:01.000" end="00:03.000">Hello world</p>
                  <p begin="00:04.000" end="00:06.000">Second line</p>
                </div>
              </body>
            </tt>
            """
        let value = try Self.valid(LyricsImportSecurity.validateImportedLyricsFile(
            fileName: "track.ttml", mimeType: "application/ttml+xml", bytes: Array(ttml.utf8)))
        #expect(value.sanitizedContent.contains("[00:01.00]Hello world"))
        #expect(value.parsedLyrics.synced?.count == 2)
    }

    @Test func acceptsTtmlPayloadAboveLrcByteLimit() throws {
        let padding = String(repeating: " ", count: LyricsImportSecurity.maxLyricsFileBytes)
        let ttml = """
            <tt xmlns="http://www.w3.org/ns/ttml">
              <head>
                <metadata>\(padding)</metadata>
              </head>
              <body>
                <div>
                  <p begin="00:01.000" end="00:03.000">Hello world</p>
                </div>
              </body>
            </tt>
            """
        let bytes = Array(ttml.utf8)
        #expect(bytes.count > LyricsImportSecurity.maxLyricsFileBytes)
        #expect(bytes.count <= LyricsImportSecurity.maxTtmlFileBytes)
        let result = LyricsImportSecurity.validateImportedLyricsFile(fileName: "track.ttml", mimeType: "application/ttml+xml",
                                                                     bytes: bytes, reportedSizeBytes: Int64(bytes.count))
        _ = try Self.valid(result)
    }

    @Test func acceptsAppleTtmlWordByWord() throws {
        let ttml = """
            <tt xmlns="http://www.w3.org/ns/ttml">
              <body>
                <div>
                  <p begin="00:14.780" end="00:18.750">
                    <span begin="00:14.780" end="00:15.100">When </span>
                    <span begin="00:15.100" end="00:15.300">I </span>
                    <span begin="00:15.300" end="00:15.700">talk</span>
                  </p>
                </div>
              </body>
            </tt>
            """
        let value = try Self.valid(LyricsImportSecurity.validateImportedLyricsFile(
            fileName: "track.ttml", mimeType: "application/xml", bytes: Array(ttml.utf8)))
        #expect(value.parsedLyrics.synced?.count == 1)
        #expect(value.parsedLyrics.synced?.first?.line == "When I talk")
        #expect(value.parsedLyrics.synced?.first?.words?.count == 3)
    }

    @Test func acceptsAppleTtmlWithXmlDeclarationAndNamespaces() throws {
        let value = try Self.valid(LyricsImportSecurity.validateImportedLyricsFile(
            fileName: "track.ttml", mimeType: "application/ttml+xml", bytes: Array(ParsingLyricsUtilsTests.chaseAtlanticTtml.utf8)))
        #expect(value.sanitizedContent == "[00:07.53]<00:07.53>Yeah, <00:09.20>I <00:09.44>bet")
        #expect(value.parsedLyrics.synced?.count == 1)
        #expect(value.parsedLyrics.synced?.first?.line == "Yeah, I bet")
    }

    @Test func rejectsTtmlWithDoctype() {
        let malicious = """
            <!DOCTYPE tt [
              <!ENTITY xxe SYSTEM "file:///etc/passwd">
            ]>
            <tt xmlns="http://www.w3.org/ns/ttml">
              <body>
                <div>
                  <p begin="00:01.000">&xxe;</p>
                </div>
              </body>
            </tt>
            """
        let result = LyricsImportSecurity.validateImportedLyricsFile(fileName: "track.ttml", mimeType: "application/ttml+xml",
                                                                     bytes: Array(malicious.utf8))
        #expect(result == .invalid(.invalidLyricsContent))
    }

    @Test func acceptsTtmlExtensionWithLrcPayload() throws {
        let value = try Self.valid(LyricsImportSecurity.validateImportedLyricsFile(
            fileName: "track.ttml", mimeType: "text/plain", bytes: Array("[00:01.00]v1: <00:01.00>Hello <00:01.50>world".utf8)))
        #expect(value.parsedLyrics.synced?.count == 1)
        #expect(value.parsedLyrics.synced?.first?.line == "v1: Hello world")
    }

    // MARK: Swift-only

    @Test func mimeAndExtensionTables() {
        #expect(LyricsImportSecurity.supportedFileExtensions() == ["lrc", "json", "yrc", "ttml"])
        #expect(LyricsImportSecurity.pickerMimeTypes() == ["text/plain", "text/x-lrc", "application/octet-stream",
                                                           "application/x-subrip", "application/lrc", "application/x-lrc",
                                                           "application/json", "application/ttml+xml", "application/xml", "text/xml"])
        #expect(LyricsImportSecurity.maxFileBytes(forFileName: "a.TTML") == 1_048_576)
        #expect(LyricsImportSecurity.maxFileBytes(forFileName: "a.lrc") == 262_144)
        #expect(LyricsImportSecurity.maxFileBytes(forFileName: "a.txt") == nil)
        #expect(LyricsImportSecurity.validateImportedLyricsFile(fileName: "a.lrc", mimeType: "Text/Plain; charset=UTF-8",
                                                                bytes: Array("[00:01.00]x".utf8)) != .invalid(.unsupportedMimeType))
        #expect(LyricsImportSecurity.validateImportedLyricsFile(fileName: "a.yrc", mimeType: "application/json",
                                                                bytes: Array("[00:01.00]x".utf8)) == .invalid(.unsupportedMimeType))
    }

    @Test func emptyMissingAndMalformedPayloads() throws {
        #expect(LyricsImportSecurity.validateImportedLyricsFile(fileName: "a.lrc", mimeType: nil, bytes: []) == .invalid(.emptyContent))
        #expect(LyricsImportSecurity.validateImportedLyricsFile(fileName: "a.lrc", mimeType: nil, bytes: [0x5B, 0xC3, 0x28])
                == .invalid(.invalidEncoding))
        #expect(LyricsImportSecurity.validateImportedLyricsFile(fileName: "a.lrc", mimeType: nil, bytes: [0xFF, 0xFE, 0x5B])
                == .invalid(.invalidEncoding))
        #expect(LyricsImportSecurity.validateImportedLyricsFile(fileName: "a.lrc", mimeType: nil, bytes: Array(" \n\t".utf8))
                == .invalid(.invalidLyricsContent))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).lrc")
        #expect(LyricsImportSecurity.validateLocalLyricsFile(at: missing) == .invalid(.emptyContent))
        #expect(LyricsImportSecurity.validateImportedLrcContent("\t\n") == .invalid(.emptyContent))
    }

    @Test func localFileIsReadAndSanitised() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-ok-\(UUID().uuidString).lrc")
        try Data("\u{FEFF}[00:01.00]One\r\n[00:02.00]Two\u{0007}\r\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let value = try Self.valid(LyricsImportSecurity.validateLocalLyricsFile(at: url))
        #expect(value.sanitizedContent == "[00:01.00]One\n[00:02.00]Two")
    }

    @Test func messagesMatchAndroid() {
        #expect(LyricsImportSecurity.message(for: .unsupportedExtension) == "Supported lyrics files: .lrc, .ttml, .yrc and PixelPlay .json.")
        #expect(LyricsImportSecurity.message(for: .invalidLyricsContent) == "File does not contain valid lyrics.")
        #expect(LyricsImportFailureReason.allCases.map(\.rawValue) == ["UNSUPPORTED_EXTENSION", "UNSUPPORTED_MIME_TYPE",
                                                                       "FILE_TOO_LARGE", "EMPTY_CONTENT", "INVALID_ENCODING",
                                                                       "INVALID_LYRICS_CONTENT"])
    }
}
