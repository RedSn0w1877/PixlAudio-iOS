// The bars of the Endless Listening introduction: five bars scaled by one value, the time. The numbers live here so the screen only draws
// them (and a test can say they stay in range). A bar is never below `minScale` of its full height and never above 1; with Reduce Motion
// the bars stand at `stillScales`.

import Foundation

public enum EndlessIntro {
    /// The pages of the introduction.
    public static let pageCount = 3
    public static let barCount = 5
    public static let minScale = 0.28

    /// Where each bar stands when nothing moves (Reduce Motion, UI tests, off screen).
    public static let stillScales: [Double] = [0.55, 0.85, 1.0, 0.7, 0.4]

    /// The height of `bar` (0..<`barCount`) as a share of the full height, `seconds` into the loop. Each bar has its own speed and
    /// offset, so they never move together.
    public static func scale(bar: Int, seconds: Double) -> Double {
        let speed = 1.1 + 0.37 * Double(bar)
        let offset = 0.9 * Double(bar)
        let wave = 0.5 + 0.5 * sin(seconds * speed + offset)
        return minScale + (1.0 - minScale) * wave
    }
}
