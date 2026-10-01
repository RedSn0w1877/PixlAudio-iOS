// The zero-latency "instrumental" fallback, ported from data/service/player/MidSideVocalProcessor.kt: vocals are
// usually mixed dead centre, so attenuating the mid channel (L+R)/2 and rebuilding L' = mid' + side,
// R' = mid' − side reduces them instantly (it also dulls anything else mixed centre — hence a fallback for the
// stem separator). Stereo only; same Float operations as Android, so outputs match bit for bit.

import Foundation
import PixlFoundation

/// Mid/side vocal attenuation for interleaved stereo.
public enum MidSideVocal {
    /// Attenuates the centre of interleaved stereo Float samples in place. `attenuation` 0…1 (clamped; NaN behaves as
    /// on Android, producing NaN). At 0 the audio is left untouched. Output is clamped to −1…1. No allocation.
    @inlinable
    public static func process(_ samples: UnsafeMutablePointer<Float>, frames: Int, attenuation: Float) {
        let a = attenuation.coerced(in: 0, 1)
        if a <= 0 || frames <= 0 { return }
        let midGain = 1 - a
        var i = 0
        for _ in 0..<frames {
            let l = samples[i]
            let r = samples[i + 1]
            let mid = (l + r) * 0.5 * midGain
            let side = (l - r) * 0.5
            samples[i] = (mid + side).coerced(in: -1, 1)
            samples[i + 1] = (mid - side).coerced(in: -1, 1)
            i += 2
        }
    }

    /// The same for interleaved stereo 16-bit PCM (Android's `ENCODING_PCM_16BIT` path): sums in Float, truncates
    /// toward zero and saturates to the Int16 range. In place.
    @inlinable
    public static func process(_ samples: UnsafeMutablePointer<Int16>, frames: Int, attenuation: Float) {
        let a = attenuation.coerced(in: 0, 1)
        if a <= 0 || frames <= 0 { return }
        let midGain = 1 - a
        var i = 0
        for _ in 0..<frames {
            let l = Int32(samples[i])
            let r = Int32(samples[i + 1])
            let mid = Float(l + r) * 0.5 * midGain
            let side = Float(l - r) * 0.5
            samples[i] = saturate(KotlinMath.toInt(mid + side))
            samples[i + 1] = saturate(KotlinMath.toInt(mid - side))
            i += 2
        }
    }

    /// Planar variant (separate left/right buffers, as `AVAudioPCMBuffer.floatChannelData` provides).
    @inlinable
    public static func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int,
                               attenuation: Float) {
        let a = attenuation.coerced(in: 0, 1)
        if a <= 0 || frames <= 0 { return }
        let midGain = 1 - a
        for i in 0..<frames {
            let l = left[i]
            let r = right[i]
            let mid = (l + r) * 0.5 * midGain
            let side = (l - r) * 0.5
            left[i] = (mid + side).coerced(in: -1, 1)
            right[i] = (mid - side).coerced(in: -1, 1)
        }
    }

    @inlinable
    static func saturate(_ v: Int32) -> Int16 { Int16(v.coerced(in: Int32(Int16.min), Int32(Int16.max))) }
}
