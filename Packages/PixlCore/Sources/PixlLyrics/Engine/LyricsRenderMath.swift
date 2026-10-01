// The pure maths the karaoke renderer needs, taken out of the Android views so the SwiftUI view stays thin:
// - `LyricsRenderMetrics`: `LyricsRenderStyle` in `LyricLineNode.kt` (paddings, alignment, pivots, em sizes) plus the
//   style constants of `LyricsView.kt` (34 pt main size, anchor 25 %, cull margin, row estimate).
// - `LyricRowLayout`: `LyricLineNode.measureText` (where the main, romanisation and translation blocks sit, the row
//   height and the press-highlight box) given the measured block heights.
// - `LyricLineAlphas`: the alpha rules of `LyricLineNode.draw`.
// - `InterludeDotsGeometry`: `InterludeDots.kt` measure + draw positions.
// - `LyricsEdgeFade`: `LyricsView.lyricsEdgeFade` / `LyricsEdgeFadeNode` fade lengths, and the anchor rule.
// All lengths are in the renderer's layout unit (points on iOS; `density` converts the dp constants).

import Foundation
import PixlFoundation

/// Horizontal placement of the lyric lines (the "lyrics alignment" preference).
public enum KaraokeAlignment: String, Sendable, Hashable, CaseIterable {
    case start
    case center
    case end
}

/// Text alignment of a line block.
public enum LyricsTextAlign: Sendable, Hashable {
    case start
    case center
    case end
}

/// Everything a line needs to lay out, shared by every row of one karaoke view (Android `LyricsRenderStyle`).
public struct LyricsRenderMetrics: Sendable, Hashable {
    public static let mainFontSize: Float = 34
    public static let backgroundEm: Float = 0.65
    public static let translationEm: Float = 0.54
    public static let romanizationEm: Float = 0.64
    public static let lineHeightEm: Float = 1.2059
    /// Letter spacing of the main and background lines (translation/romanisation use 0).
    public static let letterSpacingEm: Float = -0.01
    public static let duetInsetFraction: Float = 0.15
    public static let pressRadiusEm: Float = 0.25
    public static let pressInsetHEm: Float = 0.3
    public static let pressInsetVEm: Float = 0.15
    public static let highContrastUnsung: Float = 0.6
    /// The active line's top sits at this fraction of the viewport height.
    public static let anchorFraction: Float = 0.25
    /// Rows further than this fraction of the height outside the viewport are not placed.
    public static let cullMarginFraction: Float = 0.5
    /// The anchor stays at least this far (dp) below the top inset + fade.
    public static let anchorMinGapDp: Float = 16
    /// Main font weight 700, translation/romanisation 600 (SF Pro: `.bold` / `.semibold`).
    public static let mainWeight = 700
    public static let secondaryWeight = 600

    /// Main line font size (1 em).
    public let emPx: Float
    public let density: Float
    public let padVerticalPx: Float
    public let padStartPx: Float
    public let padEndPx: Float
    public let extraGapPx: Float
    public let alignment: KaraokeAlignment
    public let hasDuet: Bool
    /// Increased contrast: no word gradient; unsung words 0.6, sung 1.0.
    public let highContrast: Bool
    /// No lift and no emphasis (activeness still fades).
    public let reducedMotion: Bool
    public let showTranslation: Bool
    public let showRomanization: Bool

    /// - Parameters:
    ///   - textScale: the user's lyrics text-size multiplier (clamped to 0.6…2).
    ///   - density: layout units per dp (1 on iOS, where everything is points).
    public init(textScale: Float = 1, density: Float = 1, alignment: KaraokeAlignment = .start, hasDuet: Bool = false,
                highContrast: Bool = false, reducedMotion: Bool = false, showTranslation: Bool = true,
                showRomanization: Bool = true) {
        emPx = Self.fontSize(textScale: textScale) * density
        self.density = density
        padVerticalPx = 15 * density
        padStartPx = 24 * density
        padEndPx = 44 * density
        extraGapPx = 4 * density
        self.alignment = alignment
        self.hasDuet = hasDuet
        self.highContrast = highContrast
        self.reducedMotion = reducedMotion
        self.showTranslation = showTranslation
        self.showRomanization = showRomanization
    }

    /// `34 × clamp(textScale, 0.6, 2)`.
    public static func fontSize(textScale: Float) -> Float { mainFontSize * textScale.coerced(in: 0.6, 2) }

    public var bgEmPx: Float { emPx * Self.backgroundEm }
    public var translationEmPx: Float { emPx * Self.translationEm }
    public var romanizationEmPx: Float { emPx * Self.romanizationEm }

    /// Font size of a line of this role (background vocals are 0.65 em).
    public func fontSize(role: PreparedVoiceRole) -> Float { role == .background ? bgEmPx : emPx }

    /// Line height of a line of this role.
    public func lineHeight(role: PreparedVoiceRole) -> Float { fontSize(role: role) * Self.lineHeightEm }

    /// §1.1: in duet songs lead lines keep 15 % free on the end side, duet lines on the start side.
    public func startPadding(role: PreparedVoiceRole, width: Float) -> Float {
        if hasDuet && role == .duet { return ComposeBezier.javaMax(padStartPx, width * Self.duetInsetFraction) }
        if hasDuet { return padStartPx }
        switch alignment {
        case .center: return (padStartPx + padEndPx) / 2
        case .end: return padEndPx
        case .start: return padStartPx
        }
    }

    public func endPadding(role: PreparedVoiceRole, width: Float) -> Float {
        if hasDuet && role == .duet { return padStartPx }
        if hasDuet { return ComposeBezier.javaMax(padEndPx, width * Self.duetInsetFraction) }
        switch alignment {
        case .center: return (padStartPx + padEndPx) / 2
        case .end: return padStartPx
        case .start: return padEndPx
        }
    }

    public func textAlign(role: PreparedVoiceRole) -> LyricsTextAlign {
        if hasDuet { return role == .duet ? .end : .start }
        switch alignment {
        case .center: return .center
        case .end: return .end
        case .start: return .start
        }
    }

    /// Scale pivot X (0 = start edge, 1 = end edge): duet, RTL and end-aligned lines pivot on the right.
    public func pivotX(_ line: PreparedLine) -> Float {
        let rtl = Self.isRtlText(line.text)
        if hasDuet && line.role == .duet { return 1 }
        if hasDuet { return rtl ? 1 : 0 }
        switch alignment {
        case .center: return 0.5
        case .end: return 1
        case .start: return rtl ? 1 : 0
        }
    }

    /// Pivot X of an interlude row (`RowsHolder`): right when it leads into a duet line.
    public static func interludePivotX(alignEnd: Bool) -> Float { alignEnd ? 1 : 0 }

    /// Width available to the text blocks: `round(width − start − end)`, at least 1 (`measureText`).
    public func contentWidth(role: PreparedVoiceRole, width: Float) -> Float {
        let w = width - startPadding(role: role, width: width) - endPadding(role: role, width: width)
        return Float(Swift.max(KotlinMath.roundToInt(w), 1))
    }

    /// Height used for rows not measured yet: the mean measured line, or `2·padV + 1 em × line height` (`RowsHolder`).
    public func estimatedRowHeight(meanMeasured: Float?) -> Float {
        meanMeasured ?? (2 * padVerticalPx + emPx * Self.lineHeightEm)
    }

    /// Shaped scripts (Arabic, Indic, Myanmar, Khmer, Tibetan…) draw word pieces clipped from the whole shaped line.
    public static func needsShapedPieces(_ text: String) -> Bool { TextScripts.needsShapedPieces(text) }

    /// The first strong directional character decides the line's direction.
    public static func isRtlText(_ text: String) -> Bool { TextScripts.isRtlText(text) }

    /// Inactive line alpha for an appearance (`inactiveAlphaFor`): 0.55 high contrast, 0.50 bright art, else 0.20.
    public static func inactiveAlpha(brightArt: Bool, highContrast: Bool) -> Float {
        if highContrast { return KaraokeAlpha.inactiveHighContrast }
        if brightArt { return KaraokeAlpha.inactiveBrightArt }
        return KaraokeAlpha.inactive
    }

    /// The anchor (top of the active line) for a viewport: `max(0.25 × height, topInset + topFade + 16 dp)`.
    public func anchor(viewportHeight: Float, topInset: Float, topFadeLength: Float?) -> Float {
        let minAnchor = topInset + Swift.max(topFadeLength ?? -1, 0) + Self.anchorMinGapDp * density
        return ComposeBezier.javaMax(viewportHeight * Self.anchorFraction, minAnchor)
    }
}

/// Where a lyric row's blocks sit (`LyricLineNode.measureText`), from the measured heights of its text blocks.
public struct LyricRowLayout: Sendable, Hashable {
    public var textLeft: Float
    public var textTop: Float
    /// Top of the romanisation block, or nil when it is not shown.
    public var romanizationTop: Float?
    /// Top of the translation block, or nil when it is not shown.
    public var translationTop: Float?
    public var textBottom: Float
    /// Row height, rounded like Android (`roundToInt`).
    public var height: Float
    /// Press-highlight box (radius `0.25 em`, white at `KaraokeAlpha.pressHighlight`).
    public var highlightLeft: Float
    public var highlightTop: Float
    public var highlightRight: Float
    public var highlightBottom: Float

    /// - Parameters:
    ///   - mainHeight / romanizationHeight / translationHeight: measured block heights (nil = block not shown; pass
    ///     nil when the preference hides it or the text is blank).
    ///   - inkMinX / inkMaxX: the leftmost line-left and rightmost line-right over every block, in text coordinates
    ///     (nil when there is no ink).
    public static func compute(metrics: LyricsRenderMetrics, role: PreparedVoiceRole, width: Float, mainHeight: Float,
                               romanizationHeight: Float?, translationHeight: Float?, inkMinX: Float?,
                               inkMaxX: Float?) -> LyricRowLayout {
        let isBg = role == .background
        let padStart = metrics.startPadding(role: role, width: width)
        let padV = isBg ? metrics.padVerticalPx * 0.5 : metrics.padVerticalPx
        let textLeft = padStart
        let textTop = padV
        var y = padV + mainHeight
        var romanTop: Float?
        var transTop: Float?
        if let romanizationHeight {
            y += metrics.extraGapPx
            romanTop = y
            y += romanizationHeight
        }
        if let translationHeight {
            y += metrics.extraGapPx
            transTop = y
            y += translationHeight
        }
        let textBottom = y
        y += padV

        var minX = inkMinX ?? 0
        var maxX = inkMaxX ?? 0
        if minX > maxX {
            minX = 0
            maxX = 0
        }
        let insetH = metrics.emPx * LyricsRenderMetrics.pressInsetHEm
        let insetV = metrics.emPx * LyricsRenderMetrics.pressInsetVEm
        return LyricRowLayout(
            textLeft: textLeft,
            textTop: textTop,
            romanizationTop: romanTop,
            translationTop: transTop,
            textBottom: textBottom,
            height: Float(KotlinMath.roundToInt(y)),
            highlightLeft: (textLeft + minX - insetH).coerced(atLeast: 0),
            highlightTop: (textTop - insetV).coerced(atLeast: 0),
            highlightRight: (textLeft + maxX + insetH).coerced(atMost: width),
            highlightBottom: (textBottom + insetV).coerced(atMost: y)
        )
    }
}

/// The alphas a lyric line draws with this frame (`LyricLineNode.draw`).
public struct LyricLineAlphas: Sendable, Hashable {
    /// Unsung words (and untimed text, romanisation).
    public var unsung: Float
    /// Sung words, or the whole line when it has no word timing.
    public var sung: Float
    /// Translation block.
    public var translation: Float

    /// - Parameters:
    ///   - activeness: the row's `rowActiveness`.
    ///   - inactive: `LyricsRenderMetrics.inactiveAlpha(brightArt:highContrast:)`.
    public static func resolve(activeness a: Float, role: PreparedVoiceRole, highContrast: Bool,
                               inactive: Float) -> LyricLineAlphas {
        let unsung: Float
        let sung: Float
        if role == .background {
            unsung = KaraokeAlpha.backgroundUnsung
            sung = KaraokeAlpha.lerp(KaraokeAlpha.backgroundUnsung, KaraokeAlpha.backgroundSung, a)
        } else if highContrast {
            unsung = KaraokeAlpha.lerp(inactive, LyricsRenderMetrics.highContrastUnsung, a)
            sung = KaraokeAlpha.sung(a, inactive: inactive)
        } else {
            unsung = KaraokeAlpha.unsung(a, inactive: inactive)
            sung = KaraokeAlpha.sung(a, inactive: inactive)
        }
        let active = ComposeBezier.javaMax(KaraokeAlpha.translationActive, inactive + 0.15)
        let inact = ComposeBezier.javaMin(inactive, KaraokeAlpha.translationActive)
        return LyricLineAlphas(unsung: unsung, sung: sung, translation: KaraokeAlpha.lerp(inact, active, a))
    }

    /// Alpha of a line drawn as one block (no word animation this frame): unsung for word-synced lines, sung for
    /// line-synced ones.
    public func wholeLine(hasWordTiming: Bool) -> Float { hasWordTiming ? unsung : sung }

    /// Activeness under which a word-synced line no longer animates its words.
    public static let activenessEpsilon: Float = 0.002

    /// Whether a word-synced line draws its word pieces this frame: hot, or still fading out.
    public static func animatesWords(hasWordTiming: Bool, hot: Bool, activeness: Float) -> Bool {
        hasWordTiming && (hot || activeness > activenessEpsilon)
    }
}

/// Measure and draw geometry of an interlude row (`InterludeDots.kt`).
public struct InterludeDotsGeometry: Sendable, Hashable {
    public var dotDiameter: Float
    public var dotGap: Float
    public var groupWidth: Float
    public var left: Float
    /// Vertical centre of the dots in the row's current (expanding) height.
    public var centerY: Float
    /// Group scale pivot.
    public var pivotX: Float
    public var pivotY: Float
    /// Centre X of each of the three dots.
    public var centersX: [Float]

    /// Full row height: `round(em × (0.3 + 2 × 0.4))`. The engine multiplies it by the expand factor.
    public static func rowHeight(emPx: Float) -> Float {
        Float(KotlinMath.roundToInt(emPx * (InterludeTimeline.dotSizeEm + 2 * InterludeTimeline.rowMarginEm)))
    }

    public static func compute(metrics: LyricsRenderMetrics, width: Float, rowHeight: Float, presence: Float,
                               alignEnd rowAlignEnd: Bool) -> InterludeDotsGeometry {
        let em = metrics.emPx
        let dot = em * InterludeTimeline.dotSizeEm
        let gap = em * InterludeTimeline.dotGapEm
        let count = InterludeTimeline.dotCount
        let groupWidth = dot * Float(count) + gap * Float(count - 1)
        let alignEnd = rowAlignEnd || metrics.alignment == .end
        let centered = metrics.alignment == .center && !metrics.hasDuet
        let left: Float
        if alignEnd {
            left = width - metrics.padStartPx - groupWidth
        } else if centered {
            left = (width - groupWidth) / 2
        } else {
            left = metrics.padStartPx
        }
        let cy = rowHeight * presence / 2
        let pivotX: Float
        if alignEnd {
            pivotX = left + groupWidth
        } else if centered {
            pivotX = left + groupWidth / 2
        } else {
            pivotX = left
        }
        let r = dot / 2
        let centers = (0..<count).map { k in left + r + Float(k) * (dot + gap) }
        return InterludeDotsGeometry(dotDiameter: dot, dotGap: gap, groupWidth: groupWidth, left: left, centerY: cy,
                                     pivotX: pivotX, pivotY: cy, centersX: centers)
    }

    /// The dots are drawn only while the gap is in progress and visibly present.
    public static func isVisible(presence: Float) -> Bool { presence > 0.001 }

    /// Alpha of dot `k`: group alpha × the dot's fill, clamped.
    public static func dotAlpha(tMs: Int64, g0: Int64, g1: Int64, k: Int) -> Float {
        (InterludeTimeline.alpha(tMs: tMs, g0: g0, g1: g1) * InterludeTimeline.dotAlpha(tMs: tMs, g0: g0, g1: g1, k: k))
            .coerced(in: 0, 1)
    }
}

/// The lyrics edge fade (§1.1): a mask over the whole lyrics layer.
///
/// - Top: everything above `topInset` is cleared, then alpha 0 → 1 over `topFade`.
/// - Bottom: everything below `height − bottomInset` is cleared, with alpha 1 → 0 over `bottomFade` above that edge.
public struct LyricsEdgeFade: Sendable, Hashable {
    public static let topFadeFraction: Float = 0.10
    public static let bottomFadeFraction: Float = 0.12
    public static let maxTopFadeFraction: Float = 0.45

    /// Height of whatever overlays the top (the header).
    public var topInset: Float
    /// Fade length below `topInset`; nil keeps the plain fade: `max(10 %, topInset)` from the very top.
    public var topFadeLength: Float?
    /// Fade length above the bottom edge; nil = 12 % of the height.
    public var bottomFadeLength: Float?

    public init(topInset: Float = 0, topFadeLength: Float? = nil, bottomFadeLength: Float? = nil) {
        self.topInset = topInset
        self.topFadeLength = topFadeLength
        self.bottomFadeLength = bottomFadeLength
    }

    /// The resolved mask for a view height and the current bottom inset (which may animate).
    public struct Resolved: Sendable, Hashable {
        /// Alpha is 0 above this y.
        public var topClearEnd: Float
        /// The top gradient runs from `topClearEnd` (alpha 0) to here (alpha 1).
        public var topFadeEnd: Float
        /// The bottom gradient runs from here (alpha 1) to `bottomEdge` (alpha 0).
        public var bottomFadeStart: Float
        /// Alpha is 0 below this y.
        public var bottomEdge: Float

        /// Mask alpha at `y` (what the gradients and clears produce together).
        public func alpha(atY y: Float) -> Float {
            var a: Float = 1
            if y < topClearEnd { return 0 }
            if y < topFadeEnd { a *= (y - topClearEnd) / (topFadeEnd - topClearEnd) }
            if y >= bottomEdge { return 0 }
            if y > bottomFadeStart { a *= (bottomEdge - y) / (bottomEdge - bottomFadeStart) }
            return a.coerced(in: 0, 1)
        }
    }

    public func resolve(height h: Float, bottomInset: Float = 0) -> Resolved {
        // `KaraokeLyricsView` passes the node `topInsetPx` only with a fade length, else a negative "at least" fade.
        let inset: Float = topFadeLength != nil ? topInset : 0
        let topFade: Float
        if let topFadeLength {
            topFade = topFadeLength
        } else {
            topFade = ComposeBezier.javaMax(h * Self.topFadeFraction, ComposeBezier.javaMax(topInset, 1))
                .coerced(atMost: h * Self.maxTopFadeFraction)
        }
        let bottomFade = bottomFadeLength ?? h * Self.bottomFadeFraction
        let edge = (h - bottomInset.coerced(atLeast: 0)).coerced(in: 0, h)
        return Resolved(
            topClearEnd: inset,
            topFadeEnd: inset + topFade.coerced(atLeast: 1),
            bottomFadeStart: edge - bottomFade.coerced(atLeast: 1),
            bottomEdge: edge
        )
    }

    /// Taps above the top inset or below `height − bottomInset` never seek (they are under the chrome).
    public func isUnderChrome(y: Float, height: Float, bottomInset: Float) -> Bool {
        y < topInset || y > height - bottomInset
    }
}
