import Foundation
import Testing
@testable import PixlNet
import PixlModel

@Suite("SpotiFLAC Lossless Resolution & Matching")
struct SpotiFLACTests {

    // Shapes recorded from the live `tracks.monochrome.st` API on 2026-11-11 (trimmed).
    static let oneMoreTimeRow = """
    {"id":"155102871061270528","trackId":"155102871061270528","title":"One More Time",\
    "artistIds":["153542153123926016"],"artistNames":["Daft Punk"],"releaseId":"155102851176075264",\
    "explicit":false,"playable":true,"duration":320357,"isrc":"GBDUW0000053","recordingId":"156636455916015616"}
    """
    static let radioEditRow = """
    {"id":"165741332789653504","trackId":"165741332789653504","title":"One More Time - Radio Edit",\
    "artistNames":["Daft Punk"],"releaseId":"165730834890960896","playable":true,"duration":235466,"isrc":"GBDUW0000054"}
    """

    static func searchBody(_ rows: String...) -> Data {
        Data("{\"tracks\":[\(rows.joined(separator: ","))],\"releases\":[],\"artists\":[],\"users\":[],\"playlists\":[]}".utf8)
    }

    static let oneMoreTime = SpotiFLACTrackQuery(
        spotifyId: "0DiWol3AO6WpXZgp0goxAV",
        title: "One More Time",
        artist: "Daft Punk",
        album: "Discovery",
        durationMs: 320_357,
        isrc: "GBDUW0000053"
    )

    @Test("ISRC normalization strips hyphens and validates 12-char alphanumeric code")
    func isrcNormalization() {
        #expect(SpotiFLACMatcher.normalizeISRC("us-ug1-19-04206") == "USUG11904206")
        #expect(SpotiFLACMatcher.normalizeISRC(" USUG11904206 ") == "USUG11904206")
        #expect(SpotiFLACMatcher.normalizeISRC("SHORT") == nil)
        #expect(SpotiFLACMatcher.normalizeISRC("USUG1190420!") == nil)
        #expect(SpotiFLACMatcher.normalizeISRC(nil) == nil)
    }

    @Test("Exact ISRC match scores 200 and beats metadata-only matches")
    func exactISRCMatchScoring() {
        let query = SpotiFLACTrackQuery(
            spotifyId: "0VjIjW4GlUZAMYd2vXMi3b",
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "After Hours",
            durationMs: 200_040,
            isrc: "USUG11904206"
        )
        let exactCandidate = SpotiFLACCandidate(id: "154014286732070912", provider: .monochrome, title: "Blinding Lights",
                                                artist: "The Weeknd", durationMs: 200_040, isrc: "US-UG1-19-04206")
        let liveCandidate = SpotiFLACCandidate(id: "999", provider: .monochrome, title: "Blinding Lights (Live at SoFi Stadium)",
                                               artist: "The Weeknd", durationMs: 200_040, isrc: nil)
        let wrongDurationCandidate = SpotiFLACCandidate(id: "888", provider: .monochrome, title: "Blinding Lights",
                                                        artist: "The Weeknd", durationMs: 245_000, isrc: nil)

        #expect(SpotiFLACMatcher.scoreCandidate(exactCandidate, target: query) == SpotiFLACMatcher.exactISRCScore)
        #expect(SpotiFLACMatcher.scoreCandidate(liveCandidate, target: query) == 0)
        #expect(SpotiFLACMatcher.scoreCandidate(wrongDurationCandidate, target: query) == 0)
    }

    @Test("Monochrome search parsing reads the live response shape")
    func parseMonochromeSearch() throws {
        let baseURL = try #require(URL(string: "https://tracks.monochrome.st"))
        let luther = """
        {"trackId":"1","title":"luther (with sza)","artistNames":["Kendrick Lamar","SZA"],"duration":177598,"isrc":"USUG12408496","playable":false}
        """
        let candidates = SpotiFLACParsing.parseMonochromeSearchTracks(Self.searchBody(Self.oneMoreTimeRow, luther), baseURL: baseURL)
        #expect(candidates.count == 2)
        let first = try #require(candidates.first)
        #expect(first.id == "155102871061270528")
        #expect(first.releaseId == "155102851176075264")
        #expect(first.artistNames == ["Daft Punk"])
        #expect(first.durationMs == 320_357)
        #expect(first.isrc == "GBDUW0000053")
        #expect(first.playable)
        #expect(first.streamURL?.absoluteString == "https://tracks.monochrome.st/track/155102871061270528")
        #expect(candidates[1].artistNames == ["Kendrick Lamar", "SZA"])
        #expect(candidates[1].playable == false)

        #expect(SpotiFLACParsing.buildMonochromeTrackURL(baseURL: baseURL, trackId: "../admin") == nil)
        #expect(SpotiFLACParsing.parseMonochromeSearchTracks(Data("<!doctype html>Redirecting...".utf8), baseURL: baseURL).isEmpty)
    }

    @Test("Tidal HiFi base64 manifest decoding extracts FLAC stream URL and rejects PREVIEW")
    func parseHiFiStreamManifestAndRejectPreview() throws {
        let innerManifest = """
        {"mimeType":"audio/flac","codecs":"flac","encryptionType":"NONE","urls":["https://sp-pr-cf.audio.tidal.com/mediatracks/CAEaKRIn/0.flac"]}
        """.data(using: .utf8)!.base64EncodedString()

        let fullResponse = """
        {
          "version": "2.0",
          "data": {
            "trackId": 171492468,
            "assetPresentation": "FULL",
            "audioQuality": "LOSSLESS",
            "bitDepth": 16,
            "sampleRate": 44100,
            "trackReplayGain": -9.42,
            "trackPeakAmplitude": 0.988,
            "manifestMimeType": "application/vnd.tidal.bts",
            "manifest": "\(innerManifest)"
          }
        }
        """.data(using: .utf8)!

        let resolved = try #require(
            SpotiFLACParsing.parseHiFiStreamResponse(fullResponse, trackId: "171492468", isrc: "USUG11904206")
        )
        #expect(resolved.url.absoluteString == "https://sp-pr-cf.audio.tidal.com/mediatracks/CAEaKRIn/0.flac")
        #expect(resolved.provider == .tidal)
        #expect(resolved.fileExtension == "flac")
        #expect(resolved.mimeType == "audio/flac")
        #expect(resolved.replayGain?.trackGainDb == -9.42)

        let previewResponse = """
        {
          "data": {
            "trackId": 171492468,
            "assetPresentation": "PREVIEW",
            "manifest": "\(innerManifest)"
          }
        }
        """.data(using: .utf8)!

        #expect(SpotiFLACParsing.parseHiFiStreamResponse(previewResponse, trackId: "171492468") == nil)
    }

    @Test("A known ISRC resolves with one isrc: search request")
    func isrcSearchFirst() async throws {
        let transport = RecordingTransport { req in
            let url = try #require(URLComponents(string: req.url))
            if url.host == "tracks.monochrome.st", url.path == "/search/tracks",
               url.queryItems?.first(where: { $0.name == "q" })?.value == "isrc:GBDUW0000053" {
                return HTTPResponse(statusCode: 200, body: SpotiFLACTests.searchBody(SpotiFLACTests.oneMoreTimeRow))
            }
            return HTTPResponse(statusCode: 404)
        }
        let client = SpotiFLACClient(http: transport)

        let resolved = try #require(await client.resolve(Self.oneMoreTime))
        #expect(resolved.provider == .monochrome)
        #expect(resolved.url.absoluteString == "https://tracks.monochrome.st/track/155102871061270528")
        #expect(resolved.userAgent == "PixlAudio/1.0")
        #expect(transport.count == 1)

        // Cached: no second request.
        #expect(await client.resolve(Self.oneMoreTime) == resolved)
        #expect(transport.count == 1)
    }

    @Test("Without an ISRC the text search picks the right cut")
    func textSearchWithoutISRC() async throws {
        let transport = RecordingTransport { req in
            let url = try #require(URLComponents(string: req.url))
            if url.path == "/search/tracks", url.queryItems?.first(where: { $0.name == "q" })?.value == "Daft Punk One More Time" {
                return HTTPResponse(statusCode: 200, body: SpotiFLACTests.searchBody(SpotiFLACTests.radioEditRow, SpotiFLACTests.oneMoreTimeRow))
            }
            return HTTPResponse(statusCode: 404)
        }
        let client = SpotiFLACClient(http: transport)
        var query = Self.oneMoreTime
        query.isrc = nil
        query.artist = "Daft Punk, Romanthony"

        let resolved = try #require(await client.resolve(query))
        #expect(resolved.trackId == "155102871061270528")
        #expect(transport.count == 1)
    }

    @Test("A configured Tidal HiFi instance is the fallback; untrusted stream hosts are refused")
    func hifiFallbackAndTrustedHosts() async throws {
        func transport(streamURL: String) -> RecordingTransport {
            let manifestB64 = Data("{\"mimeType\":\"audio/flac\",\"urls\":[\"\(streamURL)\"]}".utf8).base64EncodedString()
            return RecordingTransport { req in
                let url = try #require(URLComponents(string: req.url))
                if url.host == "tracks.monochrome.st" { return HTTPResponse(statusCode: 503) }
                if url.path == "/search/" {
                    return HTTPResponse(statusCode: 200, text: """
                    {"data":{"items":[{"id":998877,"title":"One More Time","duration":320,"isrc":"GBDUW0000053","artists":[{"name":"Daft Punk"}]}]}}
                    """)
                }
                if url.path == "/track/" {
                    return HTTPResponse(statusCode: 200, text: """
                    {"data":{"trackId":998877,"assetPresentation":"FULL","manifest":"\(manifestB64)"}}
                    """)
                }
                return HTTPResponse(statusCode: 404)
            }
        }
        let hifi = try #require(URL(string: "https://hifi.example.org"))

        let good = SpotiFLACClient(http: transport(streamURL: "https://sp-pr-cf.audio.tidal.com/mediatracks/omt.flac"),
                                   hifiEndpoints: [hifi])
        let resolved = try #require(await good.resolve(Self.oneMoreTime))
        #expect(resolved.provider == .tidal)
        #expect(resolved.url.absoluteString == "https://sp-pr-cf.audio.tidal.com/mediatracks/omt.flac")

        let evil = SpotiFLACClient(http: transport(streamURL: "https://evil.example.com/a.flac"), hifiEndpoints: [hifi])
        #expect(await evil.resolve(Self.oneMoreTime) == nil)
    }

    @Test("A clean miss is remembered; a miss after errors is not")
    func negativeCacheOnlyForCleanMisses() async throws {
        let now = Clock()
        let hits = Flag()
        let failing = Flag()
        let transport = RecordingTransport { _ in
            if failing.value { return HTTPResponse(statusCode: 503) }
            return HTTPResponse(statusCode: 200, body: hits.value
                ? SpotiFLACTests.searchBody(SpotiFLACTests.oneMoreTimeRow) : SpotiFLACTests.searchBody())
        }
        let client = SpotiFLACClient(http: transport, clock: { now.ms })

        // Clean miss: remembered for 10 minutes.
        #expect(await client.resolve(Self.oneMoreTime) == nil)
        let afterMiss = transport.count
        hits.value = true
        #expect(await client.resolve(Self.oneMoreTime) == nil)
        #expect(transport.count == afterMiss)
        now.ms += 11 * 60 * 1_000
        #expect(await client.resolve(Self.oneMoreTime) != nil)

        // Errors: not remembered (only the minute's host cooldown applies).
        let other = SpotiFLACTrackQuery(spotifyId: "1hgdNibNvgUq9gfV4Ivz1x", title: "Aerodynamic", artist: "Daft Punk",
                                        durationMs: 212_546, isrc: "GBDUW0000057")
        failing.value = true
        #expect(await client.resolve(other) == nil)
        failing.value = false
        hits.value = false
        now.ms += 61 * 1_000
        let beforeRetry = transport.count
        _ = await client.resolve(other)
        #expect(transport.count > beforeRetry)
    }

    @Test("A cancelled lookup leaves no miss and no cooldown behind")
    func cancelledLookupLeavesNothing() async throws {
        let slow = Flag()
        slow.value = true
        let transport = RecordingTransport { _ in
            if slow.value {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return HTTPResponse(statusCode: 200, body: SpotiFLACTests.searchBody(SpotiFLACTests.oneMoreTimeRow))
        }
        let client = SpotiFLACClient(http: transport)

        let lookup = Task { await client.resolve(Self.oneMoreTime) }
        try await Task.sleep(nanoseconds: 100_000_000)
        lookup.cancel()
        #expect(await lookup.value == nil)

        slow.value = false
        let resolved = try #require(await client.resolve(Self.oneMoreTime))
        #expect(resolved.trackId == "155102871061270528")
    }

    /// `fLaC` + a STREAMINFO block laid out as in the FLAC spec.
    static func flacHead(sampleRate: Int, channels: Int, bitDepth: Int) -> Data {
        var head = [UInt8](repeating: 0, count: 42)
        head.replaceSubrange(0..<4, with: Array("fLaC".utf8))
        head[7] = 34
        let packed = (UInt64(sampleRate) << 44) | (UInt64(channels - 1) << 41) | (UInt64(bitDepth - 1) << 36) | 12_345_678
        for i in 0..<8 { head[18 + i] = UInt8(truncatingIfNeeded: packed >> (56 - 8 * UInt64(i))) }
        return Data(head)
    }

    @Test("File heads give the format, and FLAC's rate, bit depth and channels")
    func audioFileFacts() {
        let cd = SpotiFLACParsing.audioFileFacts(Self.flacHead(sampleRate: 44_100, channels: 2, bitDepth: 16))
        #expect(cd == SpotiFLACAudioFileFacts(format: .flac, sampleRate: 44_100, bitDepth: 16, channels: 2))
        #expect(SpotiFLACParsing.audioFileFacts(Self.flacHead(sampleRate: 96_000, channels: 2, bitDepth: 24)).flacSampleRate == 96_000)
        #expect(SpotiFLACParsing.audioFileFacts(Self.flacHead(sampleRate: 176_400, channels: 2, bitDepth: 24)).sampleRate == 176_400)

        let mp4 = SpotiFLACParsing.audioFileFacts(Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8))
        #expect(mp4.format == .mp4)
        #expect(mp4.flacSampleRate == nil)
        #expect(mp4.format.mimeType == "audio/mp4")
        #expect(SpotiFLACParsing.audioFileFacts(Data("ID3".utf8) + Data(count: 10)).format == .mp3)
        #expect(SpotiFLACParsing.audioFileFacts(Data([0xFF, 0xF1, 0x50])).format == .aac)
        #expect(SpotiFLACParsing.audioFileFacts(Data("<!doctype html>".utf8)).format == .unknown)
        #expect(SpotiFLACParsing.audioFileFacts(Data("fLaC".utf8)) == SpotiFLACAudioFileFacts(format: .flac))
    }

    @Test("FLAC magic header detector identifies genuine fLaC streams")
    func flacMagicHeaderDetection() {
        let validFLAC = Data([0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22])
        let invalidHTML = Data("<!DOCTYPE html>".utf8)
        #expect(SpotiFLACParsing.isFLACMagicHeader(validFLAC) == true)
        #expect(SpotiFLACParsing.isFLACMagicHeader(invalidHTML) == false)
    }
}

/// Answers every request with `handler` and counts them.
private final class RecordingTransport: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return sent
    }

    private func noteSent() {
        lock.lock(); sent += 1; lock.unlock()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        noteSent()
        do {
            return try await handler(request)
        } catch is CancellationError {
            // What URLSessionHTTPClient does with a cancelled task.
            throw HTTPTransportError(message: "cancelled")
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 1_800_000_000_000
    var ms: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
