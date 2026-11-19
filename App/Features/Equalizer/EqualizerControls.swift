import PixlAudioCore
import PixlModel
import SwiftUI

// The equalizer's custom controls (Android `EqualizerScreen.kt` `CustomVerticalSlider`, `GraphBandSliders`,
// `HybridBandSliders`), drawn with Canvas. Each keeps its finger position locally and reports
// only whole-level changes, so a drag doesn't re-evaluate the screen on every frame.

/// Android `CustomVerticalSlider`: a capsule track (filled from the bottom up to the thumb) and a thumb that spins
/// with the value — an 8-lobed rounded star by default (`RoundedStarShape(sides = 8, curve = 0.1)`). The caller
/// passes the height (from a GeometryReader) for the drag maths.
struct EqualizerVerticalSlider: View {
    let height: CGFloat
    let level: Int
    var range: ClosedRange<Double> = Double(EqualizerBands.minLevel)...Double(EqualizerBands.maxLevel)
    let activeColor: Color
    let inactiveColor: Color
    let thumbColor: Color
    var trackThickness: CGFloat?
    var thumbSize: CGFloat = 24
    var roundThumb = false
    let onChange: (Int) -> Void

    @State private var dragValue: Double?
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
            context.fill(Path(roundedRect: CGRect(x: left, y: 0, width: width, height: size.height),
                              cornerRadius: width / 2), with: .color(inactiveColor))
            context.fill(Path(ellipseIn: CGRect(x: size.width / 2 - width / 2, y: thumbY - width / 2,
                                                width: width, height: width)), with: .color(activeColor))
            let rect = CGRect(x: left, y: thumbY, width: width, height: max(size.height - thumbY, 0))
            context.fill(UnevenRoundedRectangle(bottomLeadingRadius: width / 2, bottomTrailingRadius: width / 2)
                .path(in: rect), with: .color(activeColor))
            var thumb = context
            thumb.translateBy(x: size.width / 2, y: thumbY)
            thumb.rotate(by: .degrees(normalized * 360))
            let shape = roundThumb ? Path(ellipseIn: CGRect(x: -r, y: -r, width: thumbSize, height: thumbSize))
                                   : Self.starPath(radius: r)
            thumb.fill(shape, with: .color(thumbColor))
        }
        .frame(height: height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let value = valueFor(y: gesture.location.y)
                    dragValue = value
                    let rounded = Int(value.rounded())
                    if rounded != level { onChange(rounded) }
                }
                .onEnded { _ in dragValue = nil })
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
    let onChange: (Int) -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Text(level >= 0 ? "+\(level)" : "\(level)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.onPrimaryContainer)
                .monospacedDigit()
                .frame(width: 38, height: 38)
                .background(theme.primaryContainer, in: Circle())
            GeometryReader { proxy in
                EqualizerVerticalSlider(height: proxy.size.height, level: level,
                                        activeColor: theme.primary, inactiveColor: theme.surfaceContainerHighest,
                                        thumbColor: theme.onPrimary, trackThickness: 40, onChange: onChange)
                    .accessibilityLabel(frequency)
                    .frame(width: 44)
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
                            .foregroundStyle(theme.onSurface)
                            .monospacedDigit()
                            .frame(height: 20)
                        GeometryReader { proxy in
                            EqualizerVerticalSlider(height: proxy.size.height, level: level,
                                                    activeColor: .clear, inactiveColor: theme.surfaceContainerHighest.opacity(0.5),
                                                    thumbColor: theme.primary, trackThickness: 4, thumbSize: 16, roundThumb: true) {
                                onChange(index, $0)
                            }
                            .accessibilityLabel(EqualizerPreset.bandFrequencies[index])
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
    let onChange: (Int, Int) -> Void

    @State private var page = 0
    @Environment(\.appTheme) private var theme

    private var tabs: [String] {
        [L10n.equalizerBandBass, L10n.equalizerBandLowMids, L10n.equalizerBandHighMids, L10n.equalizerBandTreble]
    }

    var body: some View {
        VStack(spacing: 0) {
            EqualizerResponseGraph(levels: levels)
                .frame(height: 150)
                .padding(.horizontal, 16)
            Picker(L10n.equalizerFrequencyResponse, selection: $page) {
                ForEach(tabs.indices, id: \.self) { index in
                    Text(tabs[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .padding(16)
            TabView(selection: $page) {
                ForEach(0..<4, id: \.self) { pageIndex in
                    VStack(spacing: 16) {
                        ForEach(pageIndex * 3..<min(pageIndex * 3 + 3, levels.count), id: \.self) { index in
                            EqualizerHorizontalBandSlider(frequency: EqualizerPreset.bandFrequencies[index],
                                                          level: levels[index]) {
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
    let onChange: (Int) -> Void

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
            Slider(value: Binding(get: { Double(level) }, set: { onChange(Int($0.rounded())) }),
                   in: -15...15, step: 1)
                .accessibilityLabel(frequency)
                .accessibilityValue("\(level) dB")
                .tint(theme.primary)
                .pixlHaptic(.selection, trigger: level)
            Text((level > 0 ? "+\(level)" : "\(level)") + "dB")
                .pixlFont(.titleMedium, weight: .bold)
                .foregroundStyle(level != 0 ? theme.primary : theme.onSurface)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .frame(height: 52)
    }
}

/// The response curve: dashed grid at ±10/±5/0 dB, the chain's magnitude response, the band levels as dots, and the
/// x-axis labels (Android `HybridFrequencyResponseGraph`; ±15 dB over 70 % of the height, 15 % top margin).
struct EqualizerResponseGraph: View {
    let levels: [Int]
    @State private var curve: [Float] = []
    @Environment(\.appTheme) private var theme

    var body: some View {
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
                context.stroke(path, with: .color(theme.primary),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                for (index, level) in levels.enumerated() where index < EqualizerPreset.bandFrequenciesHz.count {
                    let center = CGPoint(x: x(EqualizerPreset.bandFrequenciesHz[index]), y: y(Double(level)))
                    context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
                                 with: .color(theme.onSurface))
                }
            }
            HStack {
                ForEach(["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"], id: \.self) { label in
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.onSurfaceVariant)
                    if label != "16k" { Spacer(minLength: 0) }
                }
            }
            .offset(y: 4)
        }
        .accessibilityHidden(true)
        .task(id: levels) {
            let result = await Self.response(for: levels)
            if !Task.isCancelled { curve = result }
        }
    }

    @concurrent
    private static func response(for levels: [Int]) async -> [Float] {
        var settings = EqualizerSettings()
        settings.isEnabled = true
        settings.bandLevels = levels
        return EqualizerResponse.curve(settings, points: 96, minHz: EqualizerPreset.bandFrequenciesHz.first ?? 31,
                                       maxHz: EqualizerPreset.bandFrequenciesHz.last ?? 16000)
    }
}
