import SwiftUI
import Synchronization

/// A tiny registry of what keeps running while the app is open: repeating animations, `TimelineView(.animation)`s,
/// display links, polling tasks. Printed in Diagnostics' status block, so a log shows what was alive when the app felt
/// slow. Names are fixed strings; a count per name. Only calls at start and stop, never per tick.
nonisolated final class LongRunning: Sendable {
    static let shared = LongRunning()

    private let counts = Mutex<[String: Int]>([:])

    func begin(_ name: String) {
        counts.withLock { $0[name, default: 0] += 1 }
    }

    func end(_ name: String) {
        counts.withLock { counts in
            guard let count = counts[name] else { return }
            if count <= 1 { counts[name] = nil } else { counts[name] = count - 1 }
        }
    }

    func summary() -> String {
        let all = counts.withLock { $0 }
        guard !all.isEmpty else { return "none" }
        return all.sorted { $0.key < $1.key }.map { $0.value > 1 ? "\($0.key) x\($0.value)" : $0.key }.joined(separator: "; ")
    }

    func isRunning(_ name: String) -> Bool { counts.withLock { $0[name] != nil } }
}

extension View {
    /// Registers this view's animation or timeline as long-running while it is on screen and `active`.
    func longRunning(_ name: String, active: Bool = true) -> some View {
        modifier(LongRunningTracker(name: name, active: active))
    }
}

private struct LongRunningTracker: ViewModifier {
    let name: String
    let active: Bool
    @State private var registered = false

    func body(content: Content) -> some View {
        content
            .onAppear { sync(visible: true) }
            .onDisappear { sync(visible: false) }
            .onChange(of: active) { sync(visible: true) }
    }

    private func sync(visible: Bool) {
        let want = visible && active
        guard want != registered else { return }
        registered = want
        if want { LongRunning.shared.begin(name) } else { LongRunning.shared.end(name) }
    }
}
