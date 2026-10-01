## Stage 3c — PixlNet

Tests in `Packages/PixlCore/Tests/PixlNetTests/` (145 tests in 18 suites, all on Windows; no live network — every
request goes to a scripted `FixtureHTTPClient`). Fixtures in `Tests/PixlNetTests/Fixtures/`: `innertube-player.json`,
`innertube-search.json`, `piped-streams.json`, `spotify-playlist-items.json` (hand-written in the shapes the services
return) and the golden file `net-android-golden.jsonl`.

| Android test (class) | Cases | Swift test | Module | Status | Notes |
|---|---|---|---|---|---|
| `data/youtube/TrackMatcherTest` | 7 of 7 | `TrackMatcherTests` (6 scoring cases) + `AudioFormatSelectionTests.qualityCapNeverPromotesMuxedVideoAboveRealAudio` | PixlNet | ported | `SpotifySongEntity` → `MatchableTrack`; the matcher's search dependency is the `YouTubeMusicSearching` protocol (mockk → a fake). |
| `data/ai/provider/AiProviderSupportTest` | 5 of 5 | `AiProviderTests` | PixlNet | ported | `createException` → `AiProviderSupport.makeError`, `AiProviderException` → `AiProviderError`. |
| `data/tais/dj/TaisIntentParserTest` | 5 of 5 | `TaisIntentParserTests` | PixlNet | ported | `TaisIntentParser` is a stateless enum. |
| `data/spotify/SpotifySnapshotRetentionTest` | 0 of 3 (rules ported) | `SpotifyWebAPITests.snapshotPaginationGuard` | PixlNet | partial | The three cases drive `SpotifyRepository.syncUserPlaylists` against a mocked DAO (pruning, failed first page, failed later page). The DAO/sync loop is the iOS persistence layer's (stage 12); its pure guard `nextSnapshotOffset` (repeated/skipped page, early end, empty continuation, no progress, `offset=` cursor) is ported and tested case by case; `SpotifyLibrary.browsePlaylistId`/`likedSongsPlaylistId` are the ids the sync must never prune. |
| `data/repository/LyricsRepositoryImplTest` (network halves) | — | `LyricsProviderTests` | PixlNet | new | The ranking/matching halves were ported in 2b (PixlLyrics); PixlNet adds the request builders, retries, rate limit, fast parallel strategies, AMLL/NetEase flows and the catalog race. |
| `data/network/lyrics/NeteaseLyricsSourceTest` | (3, parsing in 2b) | `LyricsProviderTests.neteaseMatchesTheRecordingAndReadsYRC` | PixlNet | new | The HTTP side of the same flow (search → matching track → `song/lyric/v1`), incl. the opaque `result` and non-200 `code` cases. |

### Golden vectors from the compiled Android code (new)
`tools/android-reference/NetGen.java` runs the app's compiled classes on JDK 26 (classpath and command in its header:
compileDebugKotlin/classes, kotlin-stdlib 2.4.0, kotlinx-serialization 1.11.0, gson 2.14.0, okhttp 4.12.0 + okio 3.18.1
for the AI clients' constructors, kotlinx-coroutines-core-jvm for `SignatureCipherSolver`'s fields, android.jar 37) and
writes `net-android-golden.jsonl` (612 lines). `NetGoldenTests` compares:

| Function | Vectors | What must match |
|---|---|---|
| `TrackMatcher.normalize` | 69 | Exact strings (NFKD, Java lower case with final sigma, bracket/trailing noise, `\p{L}\p{N}`), CJK/Cyrillic/Arabic/Hangul kept. |
| `TrackMatcher.similarity` | 69 | Float **bit patterns** (UTF-16 Levenshtein). |
| `TrackMatcher.score` | 144 (8 songs × 18 candidates) | Float **bit patterns**: title/artist/duration/album weights, video "Artist - Title" split, " topic"/"vevo" suffixes, variant penalties. |
| `pickBestAudio` | 48 | Chosen itag for 8 format sets × 6 caps (muxed last, cap ignored when it empties the list, Opus tie-break, first maximum kept). |
| `TaisIntentParser.parse` + `isMediaRequest` | 58 prompts | Action, genres, moods, query, media flag. |
| `AiSystemPromptEngine.buildPrompt` | 81 + default persona | **Byte for byte** for every type × 3 personas (incl. the multi-line default) × 3 contexts — Kotlin `trimIndent()` runs after template interpolation, so multi-line personas/contexts keep the template's indentation; reproduced by the generated `AiPromptTemplates.swift` (`tools/android-reference/gen-ai-prompts.js`). |
| `AiResponseCleaner` | 19 inputs × 4 functions | Fences, bracket matching with strings/escapes, first array/object. |
| `AiProviderSupport` | 12 chains, 10 recovery, 14 `createException`, 9 `wrapThrowable`, 3 model filters | Messages, parsed code/type, status inference (`\b[1-5]\d{2}\b`), the four classification flags. |
| Gemini / OpenAI request bodies | 18 + 18 + 1 | kotlinx `encodeToString` of the private `@Serializable` request classes (reached by reflection): defaults omitted, Float settings as `Double.toString`. |
| `SpotifyRepository.unifiedId` | 27 | FNV-1a ids in the song/album/artist bands. |
| `SignatureCipherSolver` | 6 players + 5 iframes | `buildSignatureFunction`/`buildNFunction` output (or null) over synthetic base.js (all name patterns, array indirection, function declarations, braces inside strings/template literals, missing bodies) and the player-id regex. |

### Swift-only tests added in stage 3c
- `InnerTubeTests`: client table (VISIONOS first, cookie flags), endpoints/headers/origins, org.json-exact player body
  (`\/` escaping), search request, authenticated headers, SAPISIDHASH against a known SHA-1 vector, player parsing
  (formats, muxed fallback, ciphers, SABR-only "OK but unusable"), playability statuses, org.json coercions in
  formats, search parsing order/limit/dedup/"not a results page", duration parsing, tree walking, visitorData from
  `responseContext` and from `ytcfg` HTML.
- `InnerTubeClientTests`: the cookie never reaches native clients; visitorData always sent (PoToken → anonymous →
  stored); WEB_REMIX PoToken body; failure reasons; search body/interleave; one failed shelf; `VisitorDataProvider`
  fetches once.
- `AudioFormatSelectionTests`: the iOS AAC-only pick (141 → 140 → 139, caps, itag 18 last, Opus/AC-3 rejected),
  PoToken eligibility.
- `CipherAndStreamTests`: call quoting, cipher parts, `n` rebuild (first value per name, Android re-encoding),
  `pot`, brace matching, `SignatureCipherSolver` (downloads once, deciphers, diagnose report), the strategy chain
  (order by sign-in, VISIONOS wins, fall-through details, probe failures, exclusions, ciphered/PoToken details),
  probe classification, timeout helper.
- `PipedTests`, `GoogleDeviceAuthTests` (form bodies, RFC 8628 poll steps, slow_down, expiry, refresh/invalid_grant),
  `SpotifyAuthTests` (RFC 7636 PKCE vector, authorize URL, callback validation, rotation persisted **before** the token
  is used, concurrent refresh sharing, failed persistence kept in memory, full sign-in), `SpotifyWebAPITests`
  (endpoints incl. the `/items` field filter, call policy, 401/429/403/transport retries, catalog paging + market
  fallback, pagination guard, row mapping, YouTube Music rows, ISO instants, lenient models, id bands),
  `LyricsProviderTests`, `AiProviderTests`/`AiOrchestratorTests`/`AiPlaylistTests` (codecs, clients, provider chain
  with cooldowns, cache, model recovery, on-device client, candidate pool JSON, full prompt indentation, digest, Java
  `%.2f`), `SupportTests` (Android/OkHttp encodings, org.json reader/writer, Java `Double.toString`, Kotlin text and
  `trimIndent`), `CloudStreamSecurityTests`.

### Notes
- Regex classes follow java.util.regex on the JVM (ASCII `\w`/`\s`/`\b`), like the earlier stages; Android's ICU regex
  differs only next to non-ASCII letters (e.g. `"ßhd"` in `TrackMatcher.normalize`), which the vectors include and
  JVM semantics decide.
- Regenerate: `javac -cp "$CP" NetGen.java && java -Duser.language=en -Duser.country=US -XX:+UnlockDiagnosticVMOptions
  -XX:-BytecodeVerificationRemote -cp "$CP;." NetGen <ios repo root>`; prompts: `node tools/android-reference/
  gen-ai-prompts.js <android repo> <ios repo>`. (Integrator: add both to `tools/android-reference/README.md`.)
