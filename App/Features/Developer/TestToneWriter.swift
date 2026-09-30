import Foundation

/// Writes a seamlessly looping test tone as a 16-bit mono PCM WAV file (for the Diagnostics screen).
///
/// Frequencies are chosen so every partial completes a whole number of cycles in `seconds`, so the
/// file loops without a click.
nonisolated enum TestToneWriter {
    static let sampleRate = 44_100

    /// Returns the WAV bytes: A4 (440 Hz) with a quieter E5 (660 Hz), amplitude ~0.2, gently pulsing.
    static func makeWAV(seconds: Int = 8) -> Data {
        let frameCount = seconds * sampleRate
        var data = Data(capacity: 44 + frameCount * 2)

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        let byteRate = sampleRate * 2
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(UInt32(36 + frameCount * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(UInt32(16))          // PCM chunk size
        appendLE(UInt16(1))           // PCM format
        appendLE(UInt16(1))           // mono
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(byteRate))
        appendLE(UInt16(2))           // block align
        appendLE(UInt16(16))          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendLE(UInt32(frameCount * 2))

        let twoPi = 2.0 * Double.pi
        let rate = Double(sampleRate)
        var samples = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let t = Double(i) / rate
            // 0.5 Hz pulse (4 full cycles in 8 s) keeps the loop seamless.
            let pulse = 0.75 + 0.25 * sin(twoPi * 0.5 * t)
            let value = (0.14 * sin(twoPi * 440 * t) + 0.06 * sin(twoPi * 660 * t)) * pulse
            samples[i] = Int16(max(-1, min(1, value)) * Double(Int16.max))
        }
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer { appendLE(sample) }
        }
        return data
    }

    /// Writes the tone to `url` (atomically).
    static func write(to url: URL, seconds: Int = 8) throws {
        try makeWAV(seconds: seconds).write(to: url, options: .atomic)
    }
}
