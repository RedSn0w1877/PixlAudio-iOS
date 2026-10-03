import PixlAudioCore
import PixlModel
import SwiftUI

// The equalizer's custom controls (Android `EqualizerScreen.kt` `CustomVerticalSlider`, `GraphBandSliders`,
// `HybridBandSliders`, `WavyArcSlider.kt`), drawn with Canvas. Each keeps its finger position locally and reports
// only whole-level changes, so a drag doesn't re-evaluate the screen on every frame.

/// Android `CustomVerticalSlider`: a capsule track (filled from the bottom up to the thumb) and a thumb that spins
/// with the value — an 8-lobed rounded star by default (`RoundedStarShape(sides = 8, curve = 0.1)`). The caller
/// passes the height (from a GeometryReader) for the drag maths.
struct EqualizerVerticalSlider: View {
    let height: CGFloat
    let level: Int
    var range: ClosedRange<Double> = Double(EqualizerBands.minLevel)...Double(EqualizerBands.maxLevel)
    let enabled: Bool
    let activeColor: Color
    let inactiveColor: Color
    let thumbColor: Color
    var trackThickness: CGFloat?
    var thumbSize: CGFloat = 24
    var roundThumb = false
    let onChange: (Int) -> Void

    @State private var dragValue: Double?
    @Environment(\.appTheme) private var theme

    private static let verticalPadding: CGFloat = 4

    var body: some View {
        let value = dragValue ?? Double(level)
        let normalized = min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
        Canvas { context, size in
            let r = thumbSize / 2
            let track = max(size.height - thumbSize - Self.verticalPadding * 2, 1)
            let thumbY = size.height - Self.verticalPadding - r - normalized * track
            let width = trackThickness ?? size.width
            let left = (size.width - width) / 2
            let active = enabled ? activeColor : activeColor.opacity(0.3)
            context.fill(Path(roundedRect: CGRect(x: left, y: 0, width: width, height: size.height),
                              cornerRadius: width / 2), with: .color(inactiveColor))
            context.fill(Path(ellipseIn: CGRect(x: size.width / 2 - width / 2, y: thumbY - width / 2,
                                                width: width, height: width)), with: .color(active))
            let rect = CGRect(x: left, y: thumbY, width: width, height: max(size.height - thumbY, 0))
            context.fill(UnevenRoundedRectangle(bottomLeadingRadius: width / 2, bottomTrailingRadius: width / 2)
                .path(in: rect), with: .color(active))
            var thumb = context
            thumb.translateBy(x: size.width / 2, y: thumbY)
            thumb.rotate(by: .degrees(normalized * 360))
            let shape = roundThumb ? Path(ellipseIn: CGRect(x: -r, y: -r, width: thumbSize, height: thumbSize))
                                   : Self.starPath(radius: r)
            thumb.fill(shape, with: .color(enabled ? thumbColor : theme.onSurfaceVariant))
        }
        .frame(height: height)
        .clipShape(Capsule())
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let value = valueFor(y: gesture.location.y)
                    dragValue = value
                    let rounded = Int(value.rounded())
                    if rounded != level { onChange(rounded) }
                }
                .onEnded { _ in dragValue = nil },
            including: enabled ? .all : .none)
        .pixlHaptic(.selection, trigger: Int(value.rounded()))
        .accessibilityElement()
        .accessibilityValue("\(level) dB")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(level + 1, Int(range.upperBound)))
            case .decrement: onChange(max(level - 1, Int(range.lowerBound)))
            @unknown default: break
            }
        }
    }

    private func valueFor(y: CGFloat) -> Double {
        let r = thumbSize / 2
        let track = max(height - thumbSize - Self.verticalPadding * 2, 1)
        let relative = min(max(y - Self.verticalPadding - r, 0), track)
        return range.lowerBound + (1 - relative / track) * (range.upperBound - range.lowerBound)
    }

    nonisolated static func starPath(radius: CGFloat, lobes: Int = 8, curve: CGFloat = 0.1) -> Path {
        var path = Path()
        let steps = 96
        for i in 0...steps {
            let angle = Double(i) / Double(steps) * 2 * .pi
            let r = radius * (1 - curve + curve * cos(Double(lobes) * angle))
            let point = CGPoint(x: r * cos(angle), y: r * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Android `VerticalBandSlider` (sliders mode): the level in a 38 pt circle, the thick slider (40 pt wide) and the
/// frequency label, in a 56 pt column.
struct EqualizerBandColumn: View {
    let frequency: String
    let level: Int
    let enabled: Bool
    let onChange: (Int) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Text(level >= 0 ? "+\(level)" : "\(level)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(enabled ? theme.onPrimaryContainer : theme.onSurfaceVariant)
                .monospacedDigit()
                .frame(width: 38, height: 38)
                .background(enabled ? theme.primaryContainer : theme.surfaceContainerHighest, in: Circle())
            GeometryReader { proxy in
                EqualizerVerticalSlider(height: proxy.size.height, level: level, enabled: enabled,
                                             activeColor: enabled ? theme.primary : theme.onSurfaceVariant,
                                             inactiveColor: theme.surfaceContainerHighest,
                                             thumbColor: enabled ? theme.onPrimary : theme.onSurfaceVariant,
                                             onChange: onChange)
                    .frame(width: 40)
                    .frame(maxWidth: .infinity)
            }
            Text(frequency)
                .pixlFont(.labelSmall)
                .foregroundStyle(theme.onSurfaceVariant)
        }
        .frame(width: 56)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(frequency)
    }
}

/// Android `GraphBandSliders`: ten thin sliders with round 16 pt thumbs, the curve through the thumbs (Catmull-Rom,
/// tension 0.2) and a fading fill under it.
struct EqualizerGraphSliders: View {
    let levels: [Int]
    let enabled: Bool
    let onChange: (Int, Int) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(levels.indices, id: \.self) { index in
                    let level = levels[index]
                    VStack(spacing: 0) {
                        Text(level > 0 ? "+\(level)" : "\(level)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(enabled ? theme.onSurface : theme.onSurfaceVariant)
                            .monospacedDigit()
                            .frame(height: 20)
                        GeometryReader { proxy in
                            EqualizerVerticalSlider(height: proxy.size.height, level: level, enabled: enabled,
                                                         activeColor: .clear,
                                                         inactiveColor: theme.surfaceContainerHighest.opacity(0.5),
                                                         thumbColor: enabled ? theme.primary : theme.onSurfaceVariant,
                                                         trackThickness: 4, thumbSize: 16, roundThumb: true) {
                                onChange(index, $0)
                            }
                        }
                        Spacer().frame(height: 8)
                        Text(EqualizerPreset.bandFrequencies[index].replacingOccurrences(of: "Hz", with: ""))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.onSurfaceVariant)
                            .lineLimit(1)
                            .frame(height: 16)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if enabled {
                Canvas { context, size in
                    let points = Self.points(levels: levels, size: size, top: 20, bottom: 24, thumb: 16)
                    let curve = Self.spline(points)
                    var fill = curve
                    if let first = points.first, let last = points.last {
                        fill.addLine(to: CGPoint(x: last.x, y: size.height - 24))
                        fill.addLine(to: CGPoint(x: first.x, y: size.height - 24))
                        fill.closeSubpath()
                    }
                    context.fill(fill, with: .linearGradient(
                        Gradient(colors: [theme.primary.opacity(0.3), .clear]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    context.stroke(curve, with: .color(theme.primary),
                                   style: StrokeStyle(lineWidth: 3, lineCap: .round))
                }
                .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 290)
    }

    static func points(levels: [Int], size: CGSize, top: CGFloat, bottom: CGFloat, thumb: CGFloat) -> [CGPoint] {
        guard !levels.isEmpty else { return [] }
        let widthPerBand = size.width / CGFloat(levels.count)
        let available = size.height - top - bottom
        let track = available - thumb - 8
        let topOffset = top + 4 + thumb / 2
        return levels.enumerated().map { index, level in
            let normalized = min(max((Double(level) + 15) / 30, 0), 1)
            return CGPoint(x: widthPerBand * CGFloat(index) + widthPerBand / 2, y: topOffset + (1 - normalized) * track)
        }
    }

    /// Android's Catmull-Rom-like cubic through the points (control points at ±0.2 of the neighbours' span).
    static func spline(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for i in 0..<max(points.count - 1, 0) {
            let p0 = points[max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[min(points.count - 1, i + 2)]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) * 0.2, y: p1.y + (p2.y - p0.y) * 0.2),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) * 0.2, y: p2.y - (p3.y - p1.y) * 0.2))
        }
        return path
    }
}

/// Android `HybridBandSliders`: the frequency-response graph (here the real biquad response of the chain, from
/// PixlAudioCore's `EqualizerResponse`, with the band levels as dots), then tabs and pages of three horizontal sliders.
struct EqualizerHybridSliders: View {
    let levels: [Int]
    let enabled: Bool
    let settings: EqualizerSettings
    let onChange: (Int, Int) -> Void

    @State private var page = 0
    @Environment(\.appTheme) private var theme

    private var tabs: [String] {
        [L10n.equalizerBandBass, L10n.equalizerBandLowMids, L10n.equalizerBandHighMids, L10n.equalizerBandTreble]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                Text(L10n.equalizerFrequencyResponse)
                    .pixlFont(.titleMedium)
                    .foregroundStyle(theme.primary)
                EqualizerResponseGraph(levels: levels, enabled: enabled, settings: settings)
                    .padding(.top, 24)
            }
            .padding(16)
            .frame(height: 220)
            .background(theme.surfaceContainerLow.opacity(0.7), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 4)
            Spacer().frame(height: 12)
            GlassPillRow(items: tabs.indices.map { GlassPillRow<Int>.Item(id: $0, title: tabs[$0]) },
                         selection: $page, uppercase: false, height: 40, accessibilityIdentifierPrefix: "eq.bandPage")
            Spacer().frame(height: 24)
            TabView(selection: $page) {
                ForEach(0..<4, id: \.self) { pageIndex in
                    VStack(spacing: 16) {
                        ForEach(pageIndex * 3..<min(pageIndex * 3 + 3, levels.count), id: \.self) { index in
                            EqualizerHorizontalBandSlider(frequency: EqualizerPreset.bandFrequencies[index],
                                                          level: levels[index], enabled: enabled) {
                                onChange(index, $0)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .tag(pageIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 3 * 52 + 2 * 16)
        }
    }
}

/// Android `HybridHorizontalSlider`: the frequency (bold) over "Hz", a slider, the "+3dB" value.
struct EqualizerHorizontalBandSlider: View {
    let frequency: String
    let level: Int
    let enabled: Bool
    let onChange: (Int) -> Void

    @State private var value: Double = 0
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(frequency.replacingOccurrences(of: "Hz", with: ""))
                    .pixlFont(.titleSmall, weight: .bold)
                    .foregroundStyle(theme.onSurface)
                Text(L10n.equalizerUnitHz).pixlFont(.labelSmall).foregroundStyle(theme.onSurfaceVariant)
            }
            .frame(width: 36, alignment: .leading)
            Slider(value: $value, in: -15...15, step: 1)
                .tint(theme.primary)
                .disabled(!enabled)
                .onChange(of: value) { _, new in
                    let rounded = Int(new.rounded())
                    if rounded != level { onChange(rounded) }
                }
                .pixlHaptic(.selection, trigger: Int(value))
            Text((level > 0 ? "+\(level)" : "\(level)") + "dB")
                .pixlFont(.titleMedium, weight: .bold)
                .foregroundStyle(level != 0 ? theme.primary : theme.onSurface)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .frame(height: 52)
        .onAppear { value = Double(level) }
        .onChange(of: level) { _, new in if Int(value.rounded()) != new { value = Double(new) } }
    }
}

/// The response curve: dashed grid at ±10/±5/0 dB, the chain's magnitude response, the band levels as dots, and the
/// x-axis labels (Android `HybridFrequencyResponseGraph`; ±15 dB over 70 % of the height, 15 % top margin).
struct EqualizerResponseGraph: View {
    let levels: [Int]
    let enabled: Bool
    let settings: EqualizerSettings
    @Environment(\.appTheme) private var theme

    var body: some View {
        let curve = curveSpan(responseSettings)
        ZStack(alignment: .bottom) {
            Canvas { context, size in
                let track = size.height * 0.7
                let top = size.height * 0.15
                func y(_ db: Double) -> CGFloat { top + (1 - min(max((db + 15) / 30, 0), 1)) * track }
                for db in [-10.0, -5, 0, 5, 10] {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y(db)))
                    line.addLine(to: CGPoint(x: size.width, y: y(db)))
                    context.stroke(line, with: .color(theme.onSurfaceVariant.opacity(0.2)),
                                   style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [5, 5]))
                }
                // Band positions on a log axis between the first and last band (the response is drawn over the
                // same span so the dots sit on it).
                let lo = log(EqualizerPreset.bandFrequenciesHz.first ?? 31)
                let hi = log(EqualizerPreset.bandFrequenciesHz.last ?? 16000)
                func x(_ hz: Double) -> CGFloat { (log(hz) - lo) / (hi - lo) * (size.width - 16) + 8 }
                var path = Path()
                for (i, db) in curve.enumerated() {
                    let hz = exp(lo + (hi - lo) * Double(i) / Double(max(curve.count - 1, 1)))
                    let point = CGPoint(x: x(hz), y: y(Double(db)))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(enabled ? theme.primary : theme.primary.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                for (index, level) in levels.enumerated() where index < EqualizerPreset.bandFrequenciesHz.count {
                    let center = CGPoint(x: x(EqualizerPreset.bandFrequenciesHz[index]), y: y(Double(level)))
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
                                 with: .color(.white))
                }
            }
            HStack {
                ForEach(["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"], id: \.self) { label in
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.onSurfaceVariant.opacity(0.5))
                    if label != "16k" { Spacer(minLength: 0) }
                }
            }
            .offset(y: 4)
        }
        .accessibilityHidden(true)
    }

    /// The curve shows the bands even while the equalizer is off (Android draws the levels regardless).
    private var responseSettings: EqualizerSettings {
        var s = settings
        s.isEnabled = true
        s.bandLevels = levels
        s.bassBoostEnabled = false
        s.virtualizerEnabled = false
        return s
    }

    private func curveSpan(_ s: EqualizerSettings) -> [Float] {
        EqualizerResponse.curve(s, points: 96, minHz: EqualizerPreset.bandFrequenciesHz.first ?? 31,
                                maxHz: EqualizerPreset.bandFrequenciesHz.last ?? 16000)
    }
}

/// Android `WavyArcSlider`: a 270° arc from 135°, the active part drawn as a static sine wave (amplitude 3 pt,
/// wavelength 20 pt), the rest a plain stroke, and a 16 pt thumb (1.2× while dragging). Values 0…1000.
struct WavyArcSlider: View {
    let value: Int
    let enabled: Bool
    let activeColor: Color
    let inactiveColor: Color
    let thumbColor: Color
    let onChange: (Int) -> Void

    @State private var dragValue: Double?
    @State private var size: CGSize = .zero

    private let startAngle = 135.0
    private let sweep = 270.0
    private let trackWidth: CGFloat = 4
    private let thumbSize: CGFloat = 16
    private let amplitude: CGFloat = 3
    private let wavelength: CGFloat = 20

    var body: some View {
        let shown = dragValue ?? Double(value)
        let normalized = min(max(shown / 1000, 0), 1)
        Canvas { context, size in
            let radius = (min(size.width, size.height) - thumbSize * 2 - amplitude * 2) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let activeSweep = sweep * normalized
            if activeSweep < sweep {
                var arc = Path()
                arc.addArc(center: center, radius: radius, startAngle: .degrees(startAngle + activeSweep),
                           endAngle: .degrees(startAngle + sweep), clockwise: false)
                context.stroke(arc, with: .color(inactiveColor), style: StrokeStyle(lineWidth: trackWidth, lineCap: .round))
            }
            if activeSweep > 0 {
                var wave = Path()
                let steps = max(Int(activeSweep * 2), 10)
                for i in 0...steps {
                    let angleFromStart = activeSweep * Double(i) / Double(steps)
                    let rad = (startAngle + angleFromStart) * .pi / 180
                    let distance = radius * angleFromStart * .pi / 180
                    let h = enabled ? amplitude * sin(2 * .pi / wavelength * distance) : 0
                    let point = CGPoint(x: center.x + (radius + h) * cos(rad), y: center.y + (radius + h) * sin(rad))
                    if i == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
                }
                context.stroke(wave, with: .color(activeColor), style: StrokeStyle(lineWidth: trackWidth, lineCap: .round))
            }
            let thumbRad = (startAngle + activeSweep) * .pi / 180
            let thumbCenter = CGPoint(x: center.x + radius * cos(thumbRad), y: center.y + radius * sin(thumbRad))
            let d = thumbSize * (dragValue == nil ? 1 : 1.2)
            context.fill(Path(ellipseIn: CGRect(x: thumbCenter.x - d / 2, y: thumbCenter.y - d / 2, width: d, height: d)),
                         with: .color(thumbColor))
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let v = valueFor(gesture.location)
                    dragValue = v
                    let quantized = Int((v / 10).rounded()) * 10
                    if quantized != value { onChange(quantized) }
                }
                .onEnded { _ in dragValue = nil },
            including: enabled ? .all : .none)
        .pixlHaptic(.selection, trigger: Int(shown / 50))
    }

    private func valueFor(_ point: CGPoint) -> Double {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var angle = atan2(point.y - center.y, point.x - center.x) * 180 / .pi
        if angle < 0 { angle += 360 }
        var relative = angle - startAngle
        if relative < 0 { relative += 360 }
        if relative > sweep {
            let halfDead = (360 - sweep) / 2
            relative = relative < sweep + halfDead ? sweep : 0
        }
        return relative / sweep * 1000
    }
}
