import Foundation

/// Pure-Swift JSON & binary header parsers for SpotiFLAC providers (Monochrome, Tidal HiFi / OpenAPI, Deezer, Odesli).
public enum SpotiFLACParsing {
    /// Checks whether the initial bytes of an audio stream begin with the 4-byte ASCII `"fLaC"` magic header (`0x66 0x4C 0x61 0x43`).
    public static func isFLACMagicHeader(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let start = data.startIndex
        return data[start] == 0x66
            && data[data.index(start, offsetBy: 1)] == 0x4C
            && data[data.index(start, offsetBy: 2)] == 0x61
            && data[data.index(start, offsetBy: 3)] == 0x43
    }

    /// What a file's first bytes say it is (Android `AudioFileFacts.parse`): the container, and for FLAC the sample
    /// rate, bit depth and channels from STREAMINFO (always the first block: its header at 4–7, block and frame
    /// sizes, then 20 bits of rate, 3 of channels − 1 and 5 of bits − 1 from byte 18).
    public static func audioFileFacts(_ head: Data) -> SpotiFLACAudioFileFacts {
        let bytes = [UInt8](head.prefix(SpotiFLACAudioFileFacts.headBytes))
        func ascii(_ at: Int, _ text: String) -> Bool {
            let wanted = Array(text.utf8)
            return bytes.count >= at + wanted.count && Array(bytes[at..<(at + wanted.count)]) == wanted
        }
        if ascii(0, "fLaC") {
            guard bytes.count >= 22, bytes[4] & 0x7F == 0 else { return SpotiFLACAudioFileFacts(format: .flac) }
            let rate = (Int(bytes[18]) << 12) | (Int(bytes[19]) << 4) | (Int(bytes[20]) >> 4)
            let channels = ((Int(bytes[20]) >> 1) & 0x07) + 1
            let bitDepth = (((Int(bytes[20]) & 0x01) << 4) | (Int(bytes[21]) >> 4)) + 1
            return SpotiFLACAudioFileFacts(format: .flac, sampleRate: rate > 0 ? rate : nil, bitDepth: bitDepth,
                                           channels: channels)
        }
        if ascii(4, "ftyp") { return SpotiFLACAudioFileFacts(format: .mp4) }
        if ascii(0, "ID3") { return SpotiFLACAudioFileFacts(format: .mp3) }
        if ascii(0, "OggS") { return SpotiFLACAudioFileFacts(format: .ogg) }
        if bytes.count >= 4, bytes[0] == 0x1A, bytes[1] == 0x45, bytes[2] == 0xDF, bytes[3] == 0xA3 {
            return SpotiFLACAudioFileFacts(format: .webm)
        }
        if bytes.count >= 2, bytes[0] == 0xFF {
            if bytes[1] & 0xF6 == 0xF0 { return SpotiFLACAudioFileFacts(format: .aac) } // ADTS
            if bytes[1] & 0xE0 == 0xE0 { return SpotiFLACAudioFileFacts(format: .mp3) } // frame sync
        }
        return SpotiFLACAudioFileFacts(format: .unknown)
    }

    // MARK: - Monochrome Track Streamer (`https://tracks.monochrome.st`)

    /// Parses `GET /search/tracks?q=...` from a Monochrome track server (the same rows come back for an
    /// `isrc:<ISRC>` query). Live response (2026-11-11, trimmed):
    /// ```json
    /// {"tracks":[{"id":"155102871061270528","trackId":"155102871061270528","title":"One More Time",
    ///   "artistNames":["Daft Punk"],"releaseId":"155102851176075264","playable":true,"duration":320357,
    ///   "isrc":"GBDUW0000053"}],"releases":[],"artists":[],"topResults":[],"users":[],"playlists":[]}
    /// ```
    /// `duration` is in milliseconds.
    public static func parseMonochromeSearchTracks(
        _ data: Data,
        baseURL: URL
    ) -> [SpotiFLACCandidate] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        let tracksArray: [[String: Any]]
        if let tracks = root["tracks"] as? [[String: Any]] {
            tracksArray = tracks
        } else if let dataObj = root["data"] as? [String: Any],
                  let tracks = dataObj["tracks"] as? [[String: Any]] {
            tracksArray = tracks
        } else {
            return []
        }

        var results: [SpotiFLACCandidate] = []
        results.reserveCapacity(tracksArray.count)
        for item in tracksArray {
            if let candidate = parseMonochromeTrackObject(item, baseURL: baseURL) {
                results.append(candidate)
            }
        }
        return results
    }

    private static func parseMonochromeTrackObject(
        _ item: [String: Any],
        baseURL: URL
    ) -> SpotiFLACCandidate? {
        guard let trackId = stringValue(item["trackId"]) ?? stringValue(item["id"]),
              !trackId.isEmpty,
              let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }

        let artistNames = parseArtistNames(from: item)
        let primaryArtist = artistNames.first ?? ""
        let releaseId = stringValue(item["releaseId"])
        let album = (item["releaseTitle"] as? String) ?? (item["albumTitle"] as? String)
        let durationMs = intValue(item["duration"]) ?? intValue(item["durationMs"])
        let isrc = item["isrc"] as? String
        let playable = (item["playable"] as? Bool) ?? true

        let streamURL = buildMonochromeTrackURL(baseURL: baseURL, trackId: trackId)
        return SpotiFLACCandidate(
            id: trackId,
            provider: .monochrome,
            title: title,
            artist: primaryArtist,
            artistNames: artistNames,
            album: album,
            releaseId: releaseId,
            durationMs: durationMs,
            isrc: isrc,
            playable: playable,
            streamURL: streamURL,
            mimeType: "audio/flac",
            codec: "flac",
            bitDepth: intValue(item["bitDepth"]) ?? 16,
            sampleRate: intValue(item["sampleRate"]) ?? 44_100
        )
    }

    /// `<base>/track/<trackId>`; `nil` for an id that isn't plain letters, digits, `-` or `_` (no path tricks).
    public static func buildMonochromeTrackURL(baseURL: URL, trackId: String) -> URL? {
        guard !trackId.isEmpty, trackId.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }) else {
            return nil
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedId = trackId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trackId
        components?.path = basePath.isEmpty ? "/track/\(encodedId)" : "/\(basePath)/track/\(encodedId)"
        components?.query = nil
        return components?.url
    }

    // MARK: - Tidal HiFi / OpenAPI v2 Search & Stream Manifests

    /// Parses candidate tracks from a Tidal HiFi `/search/?s=...`, `/search/?i=...`, or OpenAPI v2 `/v2/tracks` response.
    public static func parseHiFiSearchResponse(_ data: Data) -> [SpotiFLACCandidate] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        if let array = json as? [[String: Any]] {
            return array.compactMap(parseHiFiTrackObject)
        }

        guard let root = json as? [String: Any] else {
            return []
        }

        // OpenAPI v2 JSON:API shape: { "data": [ { "id": "171492468", "type": "tracks", "attributes": { ... } } ], "included": [ ... ] }
        if let dataArray = root["data"] as? [[String: Any]],
           dataArray.first?["attributes"] is [String: Any] {
            return parseOpenAPITracks(dataArray: dataArray, included: root["included"] as? [[String: Any]] ?? [])
        }

        // HiFi API shapes:
        // 1. { "data": { "items": [ ... ] } } or { "data": { "tracks": { "items": [ ... ] } } }
        // 2. { "items": [ ... ] } or { "tracks": { "items": [ ... ] } }
        // 3. Single track object: { "id": 171492468, "title": "...", ... }
        if let items = extractHiFiItems(from: root) {
            return items.compactMap(parseHiFiTrackObject)
        }

        if let dataDict = root["data"] as? [String: Any] {
            if let items = extractHiFiItems(from: dataDict) {
                return items.compactMap(parseHiFiTrackObject)
            }
            if let single = parseHiFiTrackObject(dataDict) {
                return [single]
            }
        }

        if let single = parseHiFiTrackObject(root) {
            return [single]
        }

        return []
    }

    private static func extractHiFiItems(from dict: [String: Any]) -> [[String: Any]]? {
        if let items = dict["items"] as? [[String: Any]] {
            return items
        }
        if let tracksDict = dict["tracks"] as? [String: Any],
           let items = tracksDict["items"] as? [[String: Any]] {
            return items
        }
        if let tracksArray = dict["tracks"] as? [[String: Any]] {
            return tracksArray
        }
        return nil
    }

    private static func parseHiFiTrackObject(_ item: [String: Any]) -> SpotiFLACCandidate? {
        let unwrapped = (item["item"] as? [String: Any]) ?? item
        guard let id = stringValue(unwrapped["id"]) ?? stringValue(unwrapped["trackId"]),
              !id.isEmpty,
              let title = (unwrapped["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }

        var fullTitle = title
        if let version = (unwrapped["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !version.isEmpty,
           !fullTitle.lowercased().contains(version.lowercased()) {
            fullTitle += " (\(version))"
        }

        let artistNames = parseArtistNames(from: unwrapped)
        let primaryArtist = artistNames.first ?? ""
        let albumTitle = (unwrapped["album"] as? [String: Any])?["title"] as? String
        let isrc = unwrapped["isrc"] as? String
        let allowStreaming = (unwrapped["allowStreaming"] as? Bool) ?? (unwrapped["streamReady"] as? Bool) ?? true

        // Tidal HiFi `duration` is in seconds (e.g. 200), whereas `durationMs` is in milliseconds.
        let durationMs: Int?
        if let ms = intValue(unwrapped["durationMs"]) {
            durationMs = ms
        } else if let rawDuration = intValue(unwrapped["duration"]) {
            durationMs = rawDuration < 10_000 ? rawDuration * 1_000 : rawDuration
        } else {
            durationMs = nil
        }

        let replayGain = parseReplayGain(from: unwrapped)

        return SpotiFLACCandidate(
            id: id,
            provider: .tidal,
            title: fullTitle,
            artist: primaryArtist,
            artistNames: artistNames,
            album: albumTitle,
            durationMs: durationMs,
            isrc: isrc,
            playable: allowStreaming,
            streamURL: nil,
            mimeType: "audio/flac",
            codec: "flac",
            bitDepth: 16,
            sampleRate: 44_100,
            replayGain: replayGain
        )
    }

    private static func parseOpenAPITracks(
        dataArray: [[String: Any]],
        included: [[String: Any]]
    ) -> [SpotiFLACCandidate] {
        var artistLookup: [String: String] = [:]
        var albumLookup: [String: String] = [:]
        for inc in included {
            guard let id = stringValue(inc["id"]),
                  let type = inc["type"] as? String,
                  let attrs = inc["attributes"] as? [String: Any] else { continue }
            if type == "artists", let name = attrs["name"] as? String {
                artistLookup[id] = name
            } else if type == "albums", let title = attrs["title"] as? String {
                albumLookup[id] = title
            }
        }

        var results: [SpotiFLACCandidate] = []
        for entry in dataArray {
            guard let id = stringValue(entry["id"]),
                  let attrs = entry["attributes"] as? [String: Any],
                  let title = attrs["title"] as? String else { continue }

            var fullTitle = title
            if let version = (attrs["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !version.isEmpty,
               !fullTitle.lowercased().contains(version.lowercased()) {
                fullTitle += " (\(version))"
            }

            var artistNames: [String] = []
            var albumTitle: String?
            if let rels = entry["relationships"] as? [String: Any] {
                if let artistsRel = rels["artists"] as? [String: Any],
                   let relData = artistsRel["data"] as? [[String: Any]] {
                    for relItem in relData {
                        if let artistId = stringValue(relItem["id"]),
                           let name = artistLookup[artistId] {
                            artistNames.append(name)
                        }
                    }
                }
                if let albumsRel = rels["albums"] as? [String: Any],
                   let relData = albumsRel["data"] as? [[String: Any]],
                   let firstAlbumId = stringValue(relData.first?["id"]) {
                    albumTitle = albumLookup[firstAlbumId]
                }
            }

            let isrc = attrs["isrc"] as? String
            let durationMs = parseISO8601DurationMs(attrs["duration"] as? String)
            let mediaTags = (attrs["mediaTags"] as? [String]) ?? []
            let isLossless = mediaTags.isEmpty || mediaTags.contains("LOSSLESS") || mediaTags.contains("HIRES_LOSSLESS")

            results.append(
                SpotiFLACCandidate(
                    id: id,
                    provider: .tidal,
                    title: fullTitle,
                    artist: artistNames.first ?? "",
                    artistNames: artistNames,
                    album: albumTitle,
                    durationMs: durationMs,
                    isrc: isrc,
                    playable: isLossless,
                    streamURL: nil,
                    mimeType: "audio/flac",
                    codec: "flac"
                )
            )
        }
        return results
    }

    /// Parses a Tidal HiFi `/track/?id=<id>&quality=LOSSLESS` or `/v1/tracks/<id>/playbackinfo` response.
    ///
    /// Supports:
    /// - `OriginalTrackUrl` direct FLAC URL objects
    /// - Base64-encoded `application/vnd.tidal.bts` `manifest` JSON containing `urls[0]`, `mimeType`, `codecs`
    /// - Nested `data` envelope (`{ "version": "2.0", "data": { "manifest": "...", "assetPresentation": "FULL" } }`)
    /// - Rejects `assetPresentation == "PREVIEW"` so 30-second previews are never treated as full tracks.
    public static func parseHiFiStreamResponse(
        _ data: Data,
        trackId: String,
        isrc: String? = nil
    ) -> SpotiFLACResolvedStream? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let dictsToInspect: [[String: Any]]
        if let array = json as? [[String: Any]] {
            dictsToInspect = array
        } else if let root = json as? [String: Any] {
            if let dataDict = root["data"] as? [String: Any] {
                dictsToInspect = [dataDict, root]
            } else if let dataArray = root["data"] as? [[String: Any]] {
                dictsToInspect = dataArray + [root]
            } else {
                dictsToInspect = [root]
            }
        } else {
            return nil
        }

        for dict in dictsToInspect {
            if let presentation = (dict["assetPresentation"] as? String)?.uppercased(),
               presentation == "PREVIEW" {
                return nil
            }

            let replayGain = parseReplayGain(from: dict)
            let bitDepth = intValue(dict["bitDepth"]) ?? 16
            let sampleRate = intValue(dict["sampleRate"]) ?? 44_100
            let resolvedTrackId = stringValue(dict["trackId"]) ?? stringValue(dict["id"]) ?? trackId

            // 1. Direct OriginalTrackUrl / url / streamUrl field
            for key in ["OriginalTrackUrl", "originalTrackUrl", "streamUrl", "url"] {
                if let urlString = dict[key] as? String,
                   let url = URL(string: urlString),
                   CloudStreamSecurity.isSafeRemoteStreamURL(urlString) {
                    return SpotiFLACResolvedStream(
                        url: url,
                        provider: .tidal,
                        trackId: resolvedTrackId,
                        isrc: isrc,
                        mimeType: "audio/flac",
                        codec: "flac",
                        fileExtension: "flac",
                        bitDepth: bitDepth,
                        sampleRate: sampleRate,
                        replayGain: replayGain
                    )
                }
            }

            // 2. Base64-encoded manifest (`application/vnd.tidal.bts`)
            if let manifestB64 = dict["manifest"] as? String,
               let manifestData = decodeBase64Flexible(manifestB64),
               let manifestJSON = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any] {
                let manifestMime = (manifestJSON["mimeType"] as? String)?.lowercased() ?? "audio/flac"
                let codecs = (manifestJSON["codecs"] as? String)?.lowercased() ?? "flac"

                // Reject AAC/MP4 preview or lossy streams when resolving lossless FLAC
                guard codecs.contains("flac") || manifestMime.contains("flac") else {
                    continue
                }

                if let urls = manifestJSON["urls"] as? [String],
                   let firstURLString = urls.first,
                   let url = URL(string: firstURLString),
                   CloudStreamSecurity.isSafeRemoteStreamURL(firstURLString) {
                    return SpotiFLACResolvedStream(
                        url: url,
                        provider: .tidal,
                        trackId: resolvedTrackId,
                        isrc: isrc,
                        mimeType: "audio/flac",
                        codec: "flac",
                        fileExtension: "flac",
                        bitDepth: bitDepth,
                        sampleRate: sampleRate,
                        replayGain: replayGain
                    )
                }
            }
        }

        return nil
    }

    // MARK: - Deezer Public API (`https://api.deezer.com/2.0/track/isrc:<ISRC>`)

    /// Parses a Deezer track object (`GET /2.0/track/isrc:<ISRC>` or search item).
    public static func parseDeezerTrack(_ data: Data) -> SpotiFLACCandidate? {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if dict["error"] != nil {
            return nil
        }
        guard let id = stringValue(dict["id"]),
              !id.isEmpty,
              let title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }

        let artistNames = parseArtistNames(from: dict)
        let albumTitle = (dict["album"] as? [String: Any])?["title"] as? String
        let isrc = dict["isrc"] as? String
        let readable = (dict["readable"] as? Bool) ?? true
        let durationSec = intValue(dict["duration"])
        let durationMs = durationSec.map { $0 < 10_000 ? $0 * 1_000 : $0 }
        let gain = doubleValue(dict["gain"])
        let replayGain = gain.map { SpotiFLACReplayGain(trackGainDb: $0) }

        return SpotiFLACCandidate(
            id: id,
            provider: .deezer,
            title: title,
            artist: artistNames.first ?? "",
            artistNames: artistNames,
            album: albumTitle,
            durationMs: durationMs,
            isrc: isrc,
            playable: readable,
            streamURL: nil,
            mimeType: "audio/flac",
            codec: "flac",
            bitDepth: 16,
            sampleRate: 44_100,
            replayGain: replayGain
        )
    }

    /// Parses a Deezer search response (`GET /2.0/search/track?q=...`).
    public static func parseDeezerSearchTracks(_ data: Data) -> [SpotiFLACCandidate] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataArray = root["data"] as? [[String: Any]] else {
            return []
        }
        var results: [SpotiFLACCandidate] = []
        for item in dataArray {
            if let itemData = try? JSONSerialization.data(withJSONObject: item),
               let candidate = parseDeezerTrack(itemData) {
                results.append(candidate)
            }
        }
        return results
    }

    // MARK: - Odesli / Song.link Cross-Platform IDs

    /// Extracts platform track IDs (`tidal`, `deezer`, `qobuz`) from an Odesli `/v1-alpha.1/links` JSON payload.
    public static func parseOdesliLinks(_ data: Data) -> [SpotiFLACProvider: String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        var out: [SpotiFLACProvider: String] = [:]

        if let linksByPlatform = root["linksByPlatform"] as? [String: Any] {
            if let tidal = linksByPlatform["tidal"] as? [String: Any],
               let uniqueId = tidal["entityUniqueId"] as? String,
               let id = uniqueId.split(separator: ":").last {
                out[.tidal] = String(id)
            }
            if let deezer = linksByPlatform["deezer"] as? [String: Any],
               let uniqueId = deezer["entityUniqueId"] as? String,
               let id = uniqueId.split(separator: ":").last {
                out[.deezer] = String(id)
            }
        }

        if let entities = root["entitiesByUniqueId"] as? [String: Any] {
            for (_, value) in entities {
                guard let entity = value as? [String: Any],
                      let id = stringValue(entity["id"]),
                      let providers = entity["platforms"] as? [String] else { continue }
                if providers.contains("tidal") && out[.tidal] == nil {
                    out[.tidal] = id
                }
                if providers.contains("deezer") && out[.deezer] == nil {
                    out[.deezer] = id
                }
                if providers.contains("qobuz") && out[.qobuz] == nil {
                    out[.qobuz] = id
                }
            }
        }

        return out
    }

    // MARK: - Helpers

    private static func parseArtistNames(from dict: [String: Any]) -> [String] {
        var names: [String] = []
        if let arr = dict["artistNames"] as? [String] {
            for name in arr {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !names.contains(trimmed) {
                    names.append(trimmed)
                }
            }
        }
        if let artists = dict["artists"] as? [[String: Any]] {
            for artist in artists {
                if let name = (artist["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty,
                   !names.contains(name) {
                    names.append(name)
                }
            }
        }
        if let artistObj = dict["artist"] as? [String: Any],
           let name = (artistObj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           !names.contains(name) {
            names.append(name)
        }
        if let artistStr = (dict["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !artistStr.isEmpty,
           !names.contains(artistStr) {
            names.append(artistStr)
        }
        if let contributors = dict["contributors"] as? [[String: Any]] {
            for contributor in contributors {
                if let name = (contributor["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty,
                   !names.contains(name) {
                    names.append(name)
                }
            }
        }
        return names
    }

    private static func parseReplayGain(from dict: [String: Any]) -> SpotiFLACReplayGain? {
        let trackGain = doubleValue(dict["trackReplayGain"]) ?? doubleValue(dict["replayGain"])
        let trackPeak = doubleValue(dict["trackPeakAmplitude"]) ?? doubleValue(dict["peak"])
        let albumGain = doubleValue(dict["albumReplayGain"])
        let albumPeak = doubleValue(dict["albumPeakAmplitude"])
        if trackGain == nil && trackPeak == nil && albumGain == nil && albumPeak == nil {
            return nil
        }
        return SpotiFLACReplayGain(
            trackGainDb: trackGain,
            trackPeak: trackPeak,
            albumGainDb: albumGain,
            albumPeak: albumPeak
        )
    }

    /// Parses an ISO-8601 duration string such as `"PT3M20S"` or `"PT200.04S"` into milliseconds.
    public static func parseISO8601DurationMs(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              raw.hasPrefix("PT") else { return nil }
        let body = raw.dropFirst(2)
        var hours = 0.0
        var minutes = 0.0
        var seconds = 0.0
        var numberBuffer = ""
        for ch in body {
            if ch.isNumber || ch == "." {
                numberBuffer.append(ch)
            } else if ch == "H", let val = Double(numberBuffer) {
                hours = val
                numberBuffer = ""
            } else if ch == "M", let val = Double(numberBuffer) {
                minutes = val
                numberBuffer = ""
            } else if ch == "S", let val = Double(numberBuffer) {
                seconds = val
                numberBuffer = ""
            }
        }
        let totalMs = Int(((hours * 3600.0) + (minutes * 60.0) + seconds) * 1000.0)
        return totalMs > 0 ? totalMs : nil
    }

    private static func decodeBase64Flexible(_ raw: String) -> Data? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]) {
            return d
        }
        var urlSafe = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = urlSafe.count % 4
        if remainder > 0 {
            urlSafe += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: urlSafe, options: [.ignoreUnknownCharacters])
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let n = any as? NSNumber {
            return n.stringValue
        }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d.rounded()) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}
