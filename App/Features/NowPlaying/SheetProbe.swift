import SwiftUI

/// EXPERIMENT ONLY: what the sheet's layers last evaluated, for the blank-player probe.
enum SheetProbe {
    static var entries: [String] = []
    static var fullRead: (value: CGFloat, count: Int, time: Double) = (-1, 0, 0)
    static var fullEffect: (value: CGFloat, count: Int, time: Double) = (-1, 0, 0)
    static var miniRead: (value: CGFloat, count: Int, time: Double) = (-1, 0, 0)
    static var miniEffect: (value: CGFloat, count: Int, time: Double) = (-1, 0, 0)
    static var morph: (value: CGFloat, count: Int, time: Double) = (-1, 0, 0)
    static var nowPlaying: (isPlaying: Bool, count: Int, time: Double) = (false, 0, 0)
    static var fullLayer: (isShown: Bool, count: Int, time: Double) = (false, 0, 0)

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    static func markMorph(_ v: CGFloat) { morph = (v, morph.count + 1, now) }
    static func markFullRead(_ v: CGFloat) { fullRead = (v, fullRead.count + 1, now) }
    static func markFullEffect(_ v: CGFloat) { fullEffect = (v, fullEffect.count + 1, now) }
    static func markMiniRead(_ v: CGFloat) { miniRead = (v, miniRead.count + 1, now) }
    static func markMiniEffect(_ v: CGFloat) { miniEffect = (v, miniEffect.count + 1, now) }
    static func markNowPlaying(_ playing: Bool) { nowPlaying = (playing, nowPlaying.count + 1, now) }
    static func markFullLayer(_ shown: Bool) { fullLayer = (shown, fullLayer.count + 1, now) }

    static func log(_ text: String) {
        entries.append(String(format: "%.3f ", now) + text)
    }

    static func summary(_ env: AppEnvironment, _ playback: PlaybackStore) -> String {
        let sheet = env.playerSheet
        func f(_ v: (value: CGFloat, count: Int, time: Double)) -> String {
            String(format: "%.3f n=%d t=%.3f", Double(v.value), v.count, v.time)
        }
        return [
            String(format: "now=%.3f", now),
            "model exp=\(sheet.expansion) isExpanded=\(sheet.isExpanded) built=\(sheet.hasBuiltFullPlayer) "
                + "dragging=\(sheet.isDragging) hasItem=\(playback.hasItem) isPlaying=\(playback.isPlaying)",
            "morph " + f(morph),
            "fullRead " + f(fullRead), "fullEffect " + f(fullEffect),
            "miniRead " + f(miniRead), "miniEffect " + f(miniEffect),
            String(format: "nowPlaying isPlaying=%@ n=%d t=%.3f", nowPlaying.isPlaying ? "Y" : "N", nowPlaying.count,
                   nowPlaying.time),
            String(format: "fullLayer isShown=%@ n=%d t=%.3f", fullLayer.isShown ? "Y" : "N", fullLayer.count,
                   fullLayer.time),
            "log: " + entries.joined(separator: " | "),
        ].joined(separator: "\n")
    }
}

/// EXPERIMENT ONLY: the probe's state as an accessibility label (read by BlankPlayerProbeTests), refreshed twice a
/// second.
struct SheetProbeLabel: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(PlaybackStore.self) private var playback

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text("probe")
                .font(.system(size: 2))
                .opacity(0.01)
                .accessibilityIdentifier("debug.sheet")
                .accessibilityLabel(SheetProbe.summary(env, playback))
        }
        .allowsHitTesting(false)
    }
}
