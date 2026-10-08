// Builds the `/run` body for one job (design §1 step 3, §2.3): every worker URL is presigned at the moment of
// submission, valid for `ttl + executionTimeout + 1 h`, so an expired worker URL always means a job that never ran.
// The phone's own upload PUT is signed separately (24 h, `uploadURL`).

import Foundation

/// Signs one object URL: (method, key, seconds valid) → URL. `CloudObjectStoring.presignedURL` in the app.
public typealias CloudPresign = @Sendable (_ method: HTTPMethod, _ key: String, _ expiresSeconds: Int) -> String?

public enum CloudJobBuilder {
    /// The `output.put` slots a job needs: its tasks' audio slots, `lyrics` when lyrics were asked for, and always
    /// `manifest`.
    public static func outputSlots(tasks: [CloudTask]) -> [String] {
        var slots: [String] = []
        for task in tasks {
            for slot in task.outputSlots where !slots.contains(slot) { slots.append(slot) }
        }
        slots.append("manifest")
        return slots
    }

    /// `out/<jobKey>/<slot>.<ext>`: audio slots in the output codec's extension, `lyrics` and `manifest` as JSON.
    public static func outputKey(jobKey: String, slot: String, codec: CloudOutputCodec) -> String {
        let ext = (slot == "lyrics" || slot == "manifest") ? "json" : codec.fileExtension
        return CloudKeys.output(jobKey: jobKey, slot: slot, ext: ext)
    }

    /// The upload PUT the phone uses itself (24 h; re-signed when it expires before the upload finished).
    public static func uploadURL(jobKey: String, ext: String, presign: CloudPresign) -> String? {
        presign(.put, CloudKeys.input(jobKey: jobKey, ext: ext), CloudTiming.uploadPresignSeconds)
    }

    /// `input.lyrics` for a job: the known lines (when the job aligns), the language hint and whether the line
    /// times can be trusted. A job set to align whose lyrics disappeared since selection asks for `auto`.
    public static func lyricsRequest(mode: CloudLyricsMode, lines: [CloudLyricsInputLine]?, hasLineTimes: Bool,
                                     language: String?, lyricsReferenceDurationMs: Int64?,
                                     audioDurationMs: Int64) -> CloudLyricsRequest {
        let known = (lines ?? []).isEmpty ? nil : lines
        let effectiveMode: CloudLyricsMode = mode == .align && known == nil ? .auto : mode
        let synced = known != nil && CloudSelector.syncedHint(hasLineTimes: hasLineTimes,
                                                              lyricsReferenceDurationMs: lyricsReferenceDurationMs,
                                                              audioDurationMs: audioDurationMs)
        return CloudLyricsRequest(mode: effectiveMode,
                                  language: normalizedLanguage(language),
                                  synced: synced,
                                  lines: effectiveMode == .transcribe ? nil : known)
    }

    /// The language hint as the worker's schema wants it (`^[a-z]{2,3}([-_][A-Za-z0-9]{2,8})*$`): the primary subtag
    /// lower-cased, the rest kept; nil for anything else ("und", empty, malformed).
    public static func normalizedLanguage(_ language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var parts = raw.split(separator: "-", omittingEmptySubsequences: false).flatMap {
            $0.split(separator: "_", omittingEmptySubsequences: false)
        }.map(String.init)
        guard let first = parts.first else { return nil }
        let primary = first.lowercased()
        guard (2...3).contains(primary.count), primary.unicodeScalars.allSatisfy({ $0 >= "a" && $0 <= "z" }),
              primary != "und" else { return nil }
        parts[0] = primary
        for part in parts.dropFirst() {
            guard (2...8).contains(part.count), part.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else {
                return primary
            }
        }
        return parts.joined(separator: "-")
    }

    /// The whole `/run` body for a prepared and uploaded job, or nil when its input isn't known or a URL can't be
    /// signed. `lyrics` is required when the job has the lyrics task. `lastInBatch` marks the last job of a submit
    /// burst (`CloudSubmitBurst`; `CloudJobRequest.markingLastInBatch` sets it on a body built earlier).
    public static func request(for record: CloudJobRecord, build: String, lyrics: CloudLyricsRequest?,
                               lastInBatch: Bool = false, presign: CloudPresign) -> CloudJobRequest? {
        guard CloudKeys.isValidJobKey(record.jobKey), let ext = record.inputExt, let inputKey = record.inputKey,
              let sha = record.sha256, let bytes = record.bytes, let durationMs = record.durationMs else { return nil }
        let seconds = CloudTiming.workerPresignSeconds
        let jobKey = record.jobKey
        guard let get = presign(.get, inputKey, seconds), let delete = presign(.delete, inputKey, seconds) else { return nil }
        var put: [String: String] = [:]
        for slot in outputSlots(tasks: record.tasks) {
            guard let url = presign(.put, outputKey(jobKey: jobKey, slot: slot, codec: record.outputCodec), seconds) else {
                return nil
            }
            put[slot] = url
        }
        let manifestKey = CloudKeys.manifest(jobKey: jobKey), attemptKey = CloudKeys.attempt(jobKey: jobKey)
        guard let manifestGet = presign(.get, manifestKey, seconds), let attemptGet = presign(.get, attemptKey, seconds),
              let attemptPut = presign(.put, attemptKey, seconds) else { return nil }
        let wantsLyrics = record.tasks.contains(.lyrics)
        if wantsLyrics && lyrics == nil { return nil }
        let quality = CloudSelector.quality(record.quality, durationMs: durationMs)
        let input = CloudJobInput(
            jobKey: jobKey,
            client: CloudClientInfo(build: build),
            storage: CloudStorageMode.presigned.rawValue,
            audio: CloudAudioInput(get: get, delete: delete, ext: ext, bytes: bytes, sha256: sha.lowercased(),
                                   durationMs: durationMs),
            tasks: record.tasks.map(\.rawValue),
            // Lyrics alone still separate first (the aligner listens to the isolated vocals).
            separation: CloudSeparation(quality: quality),
            lyrics: wantsLyrics ? lyrics : nil,
            output: CloudOutputRequest(codec: record.outputCodec,
                                       kbps: record.outputCodec == .aac ? CloudLimits.outputKbps : nil, put: put),
            guard: CloudJobGuard(manifestGet: manifestGet, attemptGet: attemptGet, attemptPut: attemptPut))
        return CloudJobRequest(input: input, policy: CloudJobPolicy(ttl: CloudTiming.ttlMs,
                                                                    executionTimeout: CloudTiming.executionTimeoutMs))
            .markingLastInBatch(lastInBatch)
    }

    /// Every object a job may leave in the bucket (deleted after import or on cancel): its input and outputs, the
    /// lyrics, the manifest and the guard's attempt marker.
    public static func objectKeys(for record: CloudJobRecord) -> [String] {
        var keys: [String] = []
        if let input = record.inputKey { keys.append(input) }
        for slot in outputSlots(tasks: record.tasks) {
            keys.append(outputKey(jobKey: record.jobKey, slot: slot, codec: record.outputCodec))
        }
        // Keys a manifest named count only inside this job's own folder.
        let prefix = CloudKeys.outputPrefix(jobKey: record.jobKey)
        for file in (record.outputs ?? [:]).values.sorted(by: { $0.key < $1.key })
        where file.key.hasPrefix(prefix) && !file.key.contains("..") && !keys.contains(file.key) {
            keys.append(file.key)
        }
        if let lyrics = record.lyricsKey, lyrics.hasPrefix(prefix), !lyrics.contains(".."), !keys.contains(lyrics) {
            keys.append(lyrics)
        }
        keys.append(CloudKeys.attempt(jobKey: record.jobKey))
        return keys
    }
}

extension CloudJobRequest {
    /// The same body with `input.policy.last_in_batch` set (true) or left out (false: the worker's default, so the
    /// jobs before a burst's last send exactly what they sent before the flag existed).
    public func markingLastInBatch(_ last: Bool) -> CloudJobRequest {
        var copy = self
        copy.input.policy = last ? CloudJobInputPolicy(lastInBatch: true) : nil
        return copy
    }
}
