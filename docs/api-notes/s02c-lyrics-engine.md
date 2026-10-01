# API ledger additions — stage 2c (PixlLyrics engine)

No Apple framework API is used: the lyrics engine is pure Swift on Foundation, PixlFoundation and PixlModel.

| API | Min OS | Docs | Used in | Notes |
|---|---|---|---|---|
| `Synchronization.Mutex` (`withLock`) | iOS 18 / macOS 15 (Swift 6 standard library; also on Windows) | https://developer.apple.com/documentation/synchronization/mutex | `LyricsSprings.normal(gapMs:)` | Guards the process-wide normal-spring cache, which mirrors Android's `normalCache` exactly. Not on any per-frame path except a line change. |
| `SIMD4<Float>` | Swift standard library | https://developer.apple.com/documentation/swift/simd4 | `LyricsBackgroundGrade`, `LyricsBackgroundMotion.shaderUniforms` | CPU reference of the background shader's float4 maths and uniforms. |

For the app (stage 9): the engine's intended driver is a `CADisplayLink`
(https://developer.apple.com/documentation/quartzcore/cadisplaylink) calling
`LyricsEngine.step(frameNanos:positionMs:offsetMs:)`, pushing `changedRows` into per-row observable state, then
`clearChanges()` and pausing the link while `needsFrame` is false. `rowBlurSigma` is meant for SwiftUI
`View.blur(radius:opaque:)` (radius treated as σ in points; calibrate against Android screenshots on device).
