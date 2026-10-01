// Kotlin's `kotlin.math` Float functions evaluate in Double and round once (`Math.sin(x.toDouble()).toFloat()`), while
// Swift's Float overloads call the C library's single-precision functions, which can differ in the last bit. The
// lyrics maths uses these so Float results match the Android app bit for bit.

import Foundation

enum LyricsKotlinFloat {
    @inline(__always) static func sin(_ x: Float) -> Float { Float(Foundation.sin(Double(x))) }
    @inline(__always) static func cos(_ x: Float) -> Float { Float(Foundation.cos(Double(x))) }
    @inline(__always) static func sqrt(_ x: Float) -> Float { x.squareRoot() } // correctly rounded either way
    @inline(__always) static func pow(_ x: Float, _ y: Float) -> Float { Float(Foundation.pow(Double(x), Double(y))) }
    /// `PI.toFloat()`.
    static let pi = Float(Double.pi)
}
