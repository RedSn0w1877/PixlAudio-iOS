import SwiftUI

/// EXPERIMENT ONLY: what the full player's fades last evaluated, for the blank-player probe.
enum SheetProbe {
    static var fullEffect: CGFloat = -1
    static var sections: [Double: CGFloat] = [:]
    static var log: [String] = []

    static func markFullEffect(_ v: CGFloat) { fullEffect = v }
    static func markSection(_ start: CGFloat, _ v: CGFloat) { sections[Double(start)] = v }
    static func note(_ text: String) { log.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + text) }

    static var noPrewarm: Bool { ProcessInfo.processInfo.arguments.contains("-probeNoPrewarm") }

    static func summary(_ env: AppEnvironment) -> String {
        let sheet = env.playerSheet
        let sectionsMin = sections.values.min() ?? -1
        let settledExpanded = sheet.isExpanded && sheet.expansion == 1 && !sheet.isDragging
        let bad = settledExpanded && (fullEffect < 0.99 || sectionsMin < 0.99)
        let detail = sections.keys.sorted().map { String(format: "%.2f:%.3f", $0, Double(sections[$0] ?? -1)) }
        return (bad ? "BAD" : "OK") + " exp=\(sheet.expansion) isExpanded=\(sheet.isExpanded) built=\(sheet.hasBuiltFullPlayer)"
            + String(format: " fullEffect=%.3f sectionsMin=%.3f ", Double(fullEffect), Double(sectionsMin))
            + detail.joined(separator: ",") + " log: " + log.joined(separator: " | ")
    }
}

/// EXPERIMENT ONLY: the probe's state as an accessibility label, refreshed twice a second.
struct SheetProbeLabel: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text("probe")
                .font(.system(size: 2))
                .opacity(0.01)
                .accessibilityIdentifier("debug.sheet")
                .accessibilityLabel(SheetProbe.summary(env))
        }
        .allowsHitTesting(false)
    }
}
