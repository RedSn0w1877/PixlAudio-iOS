# Local AI, phase 2: the downloadable model (2026-10-07, branch `s18-local-model`)

Plan `local-ai` option C, as decided in DECISIONS.md › Local AI › Phase 2: a free model Hoa can download, **off by
default**, that runs every AI feature on the iPhone through Core ML instead of the system's on-device model. Inference
uses Apple frameworks only (Core ML with an `MLState` key/value cache); the tokenizer and the sampler are our own Swift
in PixlCore. Phase 1 (the system model by default) is `2026-10-07-local-ai.md`; this branch fills the seams it left.

## What changed

- **The model:** Qwen2.5 1.5B Instruct (Apache-2.0, revision `989aa79`), converted on CI by `ci/ml/convert_llm.py`
  (`ml-convert.yml`, input `llm`): a stateful ML Program (float16, 4,096-token context, up to 512 tokens per step),
  weights quantized to int4 per block of 32. Converted on Linux, gated on a macOS runner against transformers fp32
  (run 37714890106: 86 % greedy agreement, the reference token in Core ML's top 5 at 98 % of positions, mean
  |Δ log-prob| 0.19 — gate 85 % / 97 % / 0.6). Published to `models-v1` as
  `qwen2_5_1_5b_instruct_int4_affine_block32.tar` (896 MB) with `qwen2_5.pxbpe` (our tokenizer file) inside;
  `ModelCatalog.llm` pins its size and SHA-256 (`f107c845…`). The existing models-v1 assets were left untouched.
- **PixlCore (`PixlNet/LocalLLM`):** `BytePairTokenizer` (Qwen2's byte-level BPE, pre-tokeniser, added tokens, NFC),
  `ChatMLTemplate` (render + fitting a conversation into a budget, oldest turns first), `TokenSampler` (greedy,
  temperature, top-k, top-p, repetition penalty, seeded), `NumberListConstraint` (song picks: only distinct numbers in
  range, separated by commas), `LocalLLMGenerator` (prefix reuse, chunked prefill, cancellation between steps, NaN
  detection), `LocalPlanText` (a long playlist's five-line plan).
- **App (`App/Services/AI/LocalModel`):** `CoreMLCausalModel` (one stateful prediction per step), `LocalModelRuntime`
  (one serial queue owning tokenizer, model and cache; GPU first, CPU fallback after bad numbers; released after
  3 minutes idle, on a memory warning, in the background, when the switch goes off or the model is deleted),
  `LocalModelAI` (Taizo's chat with memory and a library note instead of a tool, intro lines, Home's greeting, plain
  text for lyric translation, constrained picks, text plans), `LocalModelPrompts` (ChatML prompts sized to a
  3,072-token budget of the 4,096 window).
- **Routing:** with the switch on, every phase-1 seam picks the downloaded model per call (`OnDeviceContext
  .usesDownloadedModel`): AI playlists and the Lab, Daily Mix refine, Taizo chat and intro (longer time-outs), "Translate
  via AI", Home's greeting and insight, Library's "With AI" status. Without the model they say "The downloaded AI model
  isn't on this iPhone yet…" (never "No Internet Connection").
- **Settings › AI features › Assistant:** "Use downloaded AI model" (off by default) and, when it's on or the model is
  on the phone, the model's row: size and Download ("Wi-Fi recommended"), progress with Cancel, "Checking and
  installing…", then its size on the phone, the last answer's speed and Delete (with a confirmation; deleting also
  turns the switch off, so AI features go back to the system model). Turning the switch on offers the download; it
  never starts one by itself.
- **Downloads (this session):** a download now says up front when the iPhone lacks the free space to install
  (2 × the archive + 100 MB, ~1.9 GB for this model), and the archive is deleted as soon as it's unpacked (peak use
  ~1.8 GB instead of ~2.7 GB).
- **Docs:** design.md § Downloadable local AI model, parity.md (new row), test-parity.md, api-notes.md §
  Downloadable local AI model, THIRD_PARTY_NOTICES.md (Qwen2.5).

## Review fixes (adversarial review, 2026-10-08)

- **The switch was in backups and every restore cleared it.** Its key, `ai_use_downloaded_model`, ends in `_model`,
  which the backup catalogue (`AndroidPreferenceCatalog.kind`) treats as a portable per-provider AI key. So a backup
  carried it, and restoring any backup without it (every Android backup) removed it from `UserDefaults` while
  Settings, which a reload didn't sync for this field, still showed it on, and the features (which read
  `UserDefaults`) used the system model. The key is now `ai_downloaded_model_enabled` (nothing has been installed
  yet, so nobody loses a setting), and `AISettings.reload` syncs it. Test: `testTheSwitchStaysOutOfBackups`.
- **A cancelled request kept waiting for the model's queue.** `LocalModelRuntime.run` only noticed the cancellation
  when the queue reached it, and `withTimeout` waits for its child, so a Taizo or Home time-out (or a closed sheet)
  waited behind another request's whole generation or the first model load. A request cancelled while it waits now
  throws `CancellationError` at once and never runs (`PendingRequest`), like phase 1's on-device queue. Test:
  `testACancelledRequestDoesNotWaitForTheQueue`.
- **Delete didn't do what its confirmation said.** The alert promised the system model again, but the switch stayed on
  and every AI feature said the model was missing. Deleting now also turns the switch off.
- **With a cloud assistant on,** the switch said the downloaded model answers and the on-device row said to turn the
  switch off; both now say the cloud assistant answers.
- api-notes said the idle unload was 120 s; it is 180 s.

## How it was verified (no Mac here, nothing on a device)

- **Conversion:** ml-convert run 37714890106 (the gate numbers above). The tokenizer file the run produced has the
  same SHA-256 as PixlCore's fixture, and the parity runner's own `tokenizers` gave the same ids on all 54 fixture
  cases and the chat template.
- **PixlCore:** `LocalLLMTests` (15: tokenizer vs the real tokenizer's fixtures, chat template, sampler, number list)
  and `LocalLLMGeneratorTests` (16: the loop against a scripted model that fails on any unwritten cache row) pass in
  the `core` job.
- **Simulator smoke test (`AppTests/LocalModelTests`, 12 tests):** a tiny random Qwen2-shaped model made by the same
  conversion (`AppTests/Fixtures/local_llm_tiny.tar`, 150 KB, from that run's `llm-candidates`; seed 105, int4) runs
  through `CoreMLCausalModel` + `LocalLLMGenerator` and must give the CI Mac's Core ML greedy tokens
  (`local_llm_tiny.json`) from a fresh cache, from a reused prefix and after a reset; the installer keeps the tokenizer
  beside the compiled model; the runtime answers on its queue, stops an endless request when its task is cancelled,
  and answers a request cancelled while it waits at once; the switch stays out of backups. (The run's own "usable" check wanted a top-1/top-2 margin ≥ 0.25 and none of the four tiny candidates
  reached it — int4 on random weights moves logits a lot — so seed 105, margin 0.18 with CPU and ALL agreeing, was
  picked by hand.)
- **Screenshots:** `SettingsScreenshotTests.testAICategoryLocalModel{Downloading,Ready}{Light,Dark}`,
  `AIScreenshotTests.testAiPlaylistLocalModelMissingLight` — see the CI section below.
- Every changed Swift file passes `ci/parse-check.ps1`; `ci/check-forbidden.sh` is clean.

## CI

- Run 37730107724 on `6eb1e15` (the pin + smoke test, `[shots:SettingsScreenshotTests,AIScreenshotTests]`): green.
  All 270 app unit tests passed, the 10 `LocalModelTests` among them — so the simulator's Core ML reproduced the CI
  Mac's greedy tokens exactly, from a fresh cache, a reused prefix and after a reset. Every shot of both classes was
  taken. Looked at: the AI playlist sheet's "isn't on this iPhone yet" card is right; the Settings shots stopped
  scrolling while the model's row was still under the mini player, so the scroll now goes on until the whole row is
  above it.
- Run 37732899180 on `78f2a19` (free-space check, scroll fix, `[shots:SettingsScreenshotTests]`): green on the
  second attempt. The first attempt's only failure was `SpotifyConnectStoreTests.testTransportGoesToTheRemoteWhileAttached`
  (a 20 ms timing test, not touched here, which passed in the run before) on a runner that also lost its network
  (the artifact upload failed with ENOTFOUND); the re-run passed everything. The Settings shots now show the whole
  model row: "Downloading — 42% of 896.3 MB" with the bar and Cancel, and "Downloaded · 898.7 MB on this iPhone"
  with Delete, light and dark.

## Hoa's iPhone checklist

Settings › AI features, on Wi-Fi, with ~2 GB free:

- [ ] "Use downloaded AI model" is off by default; the on-device model row still says "in use".
- [ ] Turn it on: the row appears with "Not downloaded · 896.3 MB. Wi-Fi recommended." and Download; nothing downloads
      by itself. The system model's row loses its checkmark.
- [ ] Download: the percentage and bar move once per percent; Cancel works; Download again resumes from zero.
- [ ] After it finishes: "Checking and installing…" for a while (the first compile takes time), then "Downloaded ·
      … on this iPhone" and Delete.
- [ ] Daily Mix sparkle "rainy day indie", 10–15 songs: a playlist (the first request also loads the model — note how
      long; Settings then shows "Last answer: … tokens/s").
- [ ] Library › Create playlist › With AI (the Lab), 100 songs: a playlist of 100.
- [ ] Taizo: "what are my top artists?" (uses the library), then a follow-up that needs the previous answer (it
      remembers), then "play some chill songs" (the card, then the intro line).
- [ ] Lyrics › long-press "Translate via AI" on a song in another language.
- [ ] Home: the greeting turns into an AI line; expanding the card writes an insight.
- [ ] Background playback for 10+ minutes after using it (the model unloads in the background; playback must not stop).
- [ ] Delete the model: the confirmation, the space comes back, the switch turns off and AI features use the system
      model again.
- [ ] Send Taizo a question and lock the phone before it answers; unlock after a minute. You should get the answer or
      a clear error, and playback must not stop. (The model is meant for the foreground only; nobody knows yet whether
      Core ML's GPU path errors or falls back to the CPU in the background on a free-signed app.)
- [ ] Make a backup, restore it: "Use downloaded AI model" keeps its value.
- [ ] Answer quality and speed feel acceptable — that is the open question only the phone can answer (CPU on the
      CI Mac took 0.41 s per token with prefill; the A18 Pro GPU should be several times faster).

## Next step

Watch the CI run listed above go green, look at the screenshots, then merge with the batch. If the model is too slow
or its answers too weak on the phone, the cheapest change is the 0.5B model (`llm_model: qwen2.5-0.5b`, same pipeline,
new pin). (Qwen2.5 3B is not Apache-2.0, so it isn't an option.)
