## Foundation and the standard library in PixlCore — additions from stage 3c (PixlNet)

All verified on Windows (swift-corelibs-foundation, Swift 6.4) by the PixlNet tests; macOS by CI `core`.

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `URLSession.dataTask(with:completionHandler:)`, `URLRequest` (`httpMethod`, `addValue(_:forHTTPHeaderField:)`, `httpBody`, `timeoutInterval`), `HTTPURLResponse.statusCode`/`allHeaderFields`, `URLSessionTask.cancel()` | 7 | /documentation/foundation/urlsession/datatask(with:completionhandler:) | `URLSessionHTTPClient` (PixlNet) | Imported via `#if canImport(FoundationNetworking)` off Apple platforms. Completion-handler API (not `data(for:)`) so it builds on corelibs too; cancellation bridged with `withTaskCancellationHandler`. The app may use it directly or inject its own `HTTPClient`. Tests never touch the network. |
| `withCheckedThrowingContinuation(_:)`, `withTaskCancellationHandler(operation:onCancel:)`, `withThrowingTaskGroup`, `withTaskGroup`, `Task.sleep(nanoseconds:)`, `Task.checkCancellation()` | 13 | /documentation/swift/withcheckedthrowingcontinuation(isolation:function:_:) | `URLSessionHTTPClient`, `withTimeout(seconds:_:)`, `LrcLibClient.runStrategiesFast`, retries | Kotlin `withTimeoutOrNull`, `suspendCancellableCoroutine` and the "first non-empty batch wins" channel race. |
| `NSRegularExpression(pattern:options:)`, `firstMatch(in:options:range:)`, `NSTextCheckingResult.range(at:)`, `NSRegularExpression.escapedPattern(for:)`, `NSString.substring(with:)` | 4 | /documentation/foundation/nsregularexpression | `SignatureCipher` (base.js extraction) | Android's patterns used verbatim (ICU and java.util.regex agree on them for ASCII JavaScript; golden vectors pass). UTF-16 ranges, like Kotlin indices. |
| `NSLock` | 2 | /documentation/foundation/nslock | `URLSessionHTTPClient` task box | Only in synchronous helpers (Swift 6 forbids `lock()` in async contexts). |
| `String.decomposedStringWithCompatibilityMapping` | 2 | /documentation/foundation/nsstring/decomposedstringwithcompatibilitymapping | `TrackMatcher.normalize` | Java `Normalizer.normalize(_, NFKD)`. |
| `String.trimmingCharacters(in:)`, `CharacterSet(charactersIn:)`, `String.components(separatedBy:)`, `String.replacingOccurrences(of:with:)`, `String.range(of:options:)` | 2 | /documentation/foundation/nsstring/trimmingcharacters(in:) | org.json number coercion, parsing helpers, AI response cleaner | |

No CryptoKit/os/Combine: SHA-256 (PKCE challenge, synthetic YouTube ids, AI cache keys) and random bytes (PKCE
verifier/state) are injected by the app (`SHA256Function`, `randomBytes`); SHA-1 for SAPISIDHASH is plain Swift
(copied from PixlLyrics). JavaScript (signature/`n` functions) is executed by the app through `JavaScriptEvaluating`
(JavaScriptCore `JSContext` in stage 11).

### Deviations from Android to note in the main ledger / parity
- Gson/kotlinx DTO decoding is lenient: a field of the wrong JSON type reads as absent instead of failing the whole
  response (Spotify, Google OAuth, AI responses). Gemini/OpenAI responses whose required fields are missing are still
  treated as failures, with the same error classes.
- `HTTPResponse` has no reason phrase: provider errors use the standard HTTP/1.1 phrase (`HTTPReason`) as OkHttp's
  `response.message` fallback.
- LRCLIB User-Agent is `PixlAudio/1.0 (iOS; Music Player)` (Android's OkHttp interceptor sent
  `PixelPlayer/1.0 (Android; Music Player)` to every non-YouTube host); AMLL/NetEase send `LyricsHTTP.userAgent`.
- Spotify redirect is `pixlaudio://spotify-callback` (`SpotifyAuth.redirectURI`); Android's is kept as
  `androidRedirectURI`. `SpotifyTrackRecord.toSong()` ids use the iOS `sp:` prefix.
- Formats: `AudioFormatPolicy.iOS` (default for `ChainedYouTubeStreamResolver`) only picks AAC/MP4 (141/140/139) then
  itag 18; Piped picks AAC audio streams by default (`aacOnly`). Android's `pickBestAudio` is kept as `.android`.
- `InnerTubeRequests.nextBody`/`browseBody` are Swift-only builders (Android never called `next`/`browse`).
- The Spotify session keeps a rotated refresh token in memory when persisting it fails (and reports the failure), so the
  next refresh in the same process still uses the newest token.
- User-facing diagnostic strings keep Android's wording (some Spanish, e.g. "respondió HTTP 400", "Refresco de token
  fallido"); the UI stages decide what to show.
