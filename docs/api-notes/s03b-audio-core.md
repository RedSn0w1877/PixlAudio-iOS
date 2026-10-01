# Stage 3b — PixlAudioCore (API ledger additions)

Rows for the "Foundation and the standard library in PixlCore (Windows + macOS)" table of `docs/api-notes.md`. No
Apple-only framework is used: PixlAudioCore builds and tests on Windows.

| API | Min iOS | Docs | Used in | Notes |
|---|---|---|---|---|
| `cos`, `sin`, `pow`, `log`, `log10`, `exp`, `tanh` (C math via Foundation) | 2 | (Darwin libm) | `TransitionEnvelope` (S-curve), `ReplayGain.gainDbToVolume`, `BiquadDesigner`, `EqualizerResponse`, `SoftLimiter`, `Fft` twiddles | FFT, envelope and ReplayGain vectors are bit-identical to the JVM on Windows (UCRT libm); tests allow 2 ulps where `cos`/`pow` feed the result. |
| `Mutex` (Synchronization) | 18.0 | /documentation/synchronization/mutex | `Bluestein` plan cache | Already used by PixlLyrics; works on Windows. |
| `Float.init?(_ text: some StringProtocol)` | — (stdlib) | /documentation/swift/float/init(_:) | `KotlinText.toFloatOrNull` (ReplayGain tags) | Correctly rounded; ±∞ / 0 for out-of-range literals, like Java. **On Windows it reads "0X1P-2" as 0** — literals are lower-cased first (lower-case "0x…p…" parses fine). |
| `Unicode.Scalar.Properties.generalCategory` (`.spaceSeparator`, `.lineSeparator`, `.paragraphSeparator`) | — (stdlib) | /documentation/swift/unicode/scalar/properties-swift.struct/generalcategory | `KotlinText.isWhitespace` (Kotlin `trim()`) | |
| `Array.withUnsafeMutableBufferPointer`, `UnsafeMutablePointer<Float>` | — (stdlib) | /documentation/swift/array/withunsafemutablebufferpointer(_:) | `BiquadCascade`, `Fft.Workspace`, per-buffer processors | Per-buffer functions take caller buffers and never allocate (uniquely owned storage). |
| `CancellationError` | 13 (concurrency) | /documentation/swift/cancellationerror | `CtcAlignmentCore.align(checkCancelled:)` callers, tests | The app passes `{ try Task.checkCancellation() }`. |

## Notes for the app stages (playback, EQ screen)
- `BiquadCoefficients.vDSPOrder` is `[b0, b1, b2, a1, a2]` normalised by a0 — the layout `vDSP_biquadm_CreateSetupD`
  / `vDSP_biquadm_SetTargetsDouble` expect (to be ledgered by the playback stage when it first uses them:
  /documentation/accelerate/vdsp_biquadm_createsetupd).
- `CrossfadeRamp.apply` / `ReplayGainStage.process` / `EqualizerProcessor.process` / `MidSideVocal.process` operate in
  place on interleaved (or planar) Float buffers from a processing tap; state structs must be uniquely owned by the tap
  context so array storage is never copied on the render thread.
