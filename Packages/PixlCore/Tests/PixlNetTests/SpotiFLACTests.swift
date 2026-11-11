import Foundation
import Testing
@testable import PixlNet
import PixlModel

@Suite("SpotiFLAC Lossless Resolution & Matching")
struct SpotiFLACTests {

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

        let exactCandidate = SpotiFLACCandidate(
            id: "154014286732070912",
            provider: .monochrome,
            title: "Blinding Lights",
            artist: "The Weeknd",
            durationMs: 200_040,
            isrc: "US-UG1-19-04206"
        )

        let liveCandidate = SpotiFLACCandidate(
            id: "999",
            provider: .monochrome,
            title: "Blinding Lights (Live at SoFi Stadium)",
            artist: "The Weeknd",
            durationMs: 200_040,
            isrc: nil
        )

        let wrongDurationCandidate = SpotiFLACCandidate(
            id: "888",
            provider: .monochrome,
            title: "Blinding Lights",
            artist: "The Weeknd",
            durationMs: 245_000,
            isrc: nil
        )

        #expect(SpotiFLACMatcher.scoreCandidate(exactCandidate, target: query) == SpotiFLACMatcher.exactISRCScore)
        #expect(SpotiFLACMatcher.scoreCandidate(liveCandidate, target: query) == 0)
        #expect(SpotiFLACMatcher.scoreCandidate(wrongDurationCandidate, target: query) == 0)
    }

    @Test("Monochrome search and release JSON parsing extracts trackId, ISRC, duration, and stream URL")
    func parseMonochromeSearchAndRelease() throws {
        let baseURL = try #require(URL(string: "https://tracks.monochrome.st"))
        let searchJSON = """
        {
          "tracks": [
            {
              "trackId": "154014286732070912",
              "title": "Blinding Lights",
              "artistNames": ["The Weeknd"],
              "releaseId": "154010323538415616",
              "releaseTitle": "After Hours"
            }
          ]
        }
        """.data(using: .utf8)!

        let searchCandidates = SpotiFLACParsing.parseMonochromeSearchTracks(searchJSON, baseURL: baseURL)
        #expect(searchCandidates.count == 1)
        #expect(searchCandidates[0].id == "154014286732070912")
        #expect(searchCandidates[0].releaseId == "154010323538415616")
        #expect(searchCandidates[0].streamURL?.absoluteString == "https://tracks.monochrome.st/track/154014286732070912")

        let releaseJSON = """
        {
          "releaseId": "154010323538415616",
          "title": "After Hours",
          "artistNames": ["The Weeknd"],
          "tracks": [
            {
              "trackId": "154014286732070912",
              "title": "Blinding Lights",
              "artistNames": ["The Weeknd"],
              "duration": 200040,
              "isrc": "USUG11904206",
              "playable": true
            }
          ]
        }
        """.data(using: .utf8)!

        let releaseCandidates = SpotiFLACParsing.parseMonochromeReleaseTracks(releaseJSON, baseURL: baseURL)
        #expect(releaseCandidates.count == 1)
        #expect(releaseCandidates[0].isrc == "USUG11904206")
        #expect(releaseCandidates[0].durationMs == 200_040)
        #expect(releaseCandidates[0].playable == true)
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

    @Test("SpotiFLACClient resolves via Monochrome primary and falls back to Tidal HiFi when primary fails")
    func clientFallbackChain() async throws {
        let query = SpotiFLACTrackQuery(
            spotifyId: "0VjIjW4GlUZAMYd2vXMi3b",
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "After Hours",
            durationMs: 200_040,
            isrc: "USUG11904206"
        )

        // Case 1: Monochrome primary succeeds
        let primaryTransport = MockSpotiFLACTransport { req in
            let url = URL(string: req.url)
            if url?.host == "tracks.monochrome.st" && url?.path == "/search/tracks" {
                let body = """
                {"tracks":[{"trackId":"154014286732070912","title":"Blinding Lights","artistNames":["The Weeknd"],"releaseId":"154010323538415616"}]}
                """.data(using: .utf8)!
                return HTTPResponse(statusCode: 200, headers: [], body: body)
            }
            if url?.host == "tracks.monochrome.st" && url?.path == "/releases/154010323538415616" {
                let body = """
                {"releaseId":"154010323538415616","tracks":[{"trackId":"154014286732070912","title":"Blinding Lights","artistNames":["The Weeknd"],"duration":200040,"isrc":"USUG11904206","playable":true}]}
                """.data(using: .utf8)!
                return HTTPResponse(statusCode: 200, headers: [], body: body)
            }
            return HTTPResponse(statusCode: 404, headers: [], body: Data())
        }

        let primaryClient = SpotiFLACClient(http: primaryTransport)
        let primaryResolved = try #require(await primaryClient.resolve(query))
        #expect(primaryResolved.provider == .monochrome)
        #expect(primaryResolved.url.absoluteString == "https://tracks.monochrome.st/track/154014286732070912")
        #expect(primaryResolved.isrc == "USUG11904206")

        // Case 2: Monochrome returns 503 -> falls back to Tidal HiFi instance
        let innerManifest = """
        {"mimeType":"audio/flac","codecs":"flac","urls":["https://sp-pr-cf.audio.tidal.com/mediatracks/fallback.flac"]}
        """.data(using: .utf8)!.base64EncodedString()

        let fallbackTransport = MockSpotiFLACTransport { req in
            let url = URL(string: req.url)
            if url?.host == "tracks.monochrome.st" {
                return HTTPResponse(statusCode: 503, headers: [], body: Data())
            }
            if url?.host == "api.monochrome.tf" && (url?.path == "/search" || url?.path == "/search/") {
                let body = """
                {"data":{"items":[{"id":171492468,"title":"Blinding Lights","duration":200,"isrc":"USUG11904206","allowStreaming":true,"artists":[{"name":"The Weeknd"}]}]}}
                """.data(using: .utf8)!
                return HTTPResponse(statusCode: 200, headers: [], body: body)
            }
            if url?.host == "api.monochrome.tf" && (url?.path == "/track" || url?.path == "/track/") {
                let body = """
                {"data":{"trackId":171492468,"assetPresentation":"FULL","manifest":"\(innerManifest)"}}
                """.data(using: .utf8)!
                return HTTPResponse(statusCode: 200, headers: [], body: body)
            }
            return HTTPResponse(statusCode: 404, headers: [], body: Data())
        }

        let fallbackClient = SpotiFLACClient(http: fallbackTransport)
        let fallbackResolved = try #require(await fallbackClient.resolve(query))
        #expect(fallbackResolved.provider == .tidal)
        #expect(fallbackResolved.url.absoluteString == "https://sp-pr-cf.audio.tidal.com/mediatracks/fallback.flac")
    }

    @Test("FLAC magic header detector identifies genuine fLaC streams")
    func flacMagicHeaderDetection() {
        let validFLAC = Data([0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22])
        let invalidHTML = Data("<!DOCTYPE html>".utf8)
        #expect(SpotiFLACParsing.isFLACMagicHeader(validFLAC) == true)
        #expect(SpotiFLACParsing.isFLACMagicHeader(invalidHTML) == false)
    }
}

private struct MockSpotiFLACTransport: HTTPClient {
    let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await handler(request)
    }
}
