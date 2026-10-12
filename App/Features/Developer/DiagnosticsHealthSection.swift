import PixlModel
import SwiftUI
import UIKit

/// The top of Settings › Developer › Diagnostics (docs/handoff/2026-10-10-crash-diagnostics.md): which build is
/// installed, the live status (memory, thermal state, Low Power Mode, heavy jobs, safe mode), the Safe mode switch,
/// Share logs (one text file with the build identity, status, the event log and MetricKit payloads) and Emergency stop.
/// Native `Form` rows, no custom glass.
struct DiagnosticsHealthSection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var confirmsStop = false
    @State private var shared: SharedReport?
    @State private var stopNote: String?

    var body: some View {
        let health = environment.health
        Section {
            Text(BuildIdentity.summary)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("diagnostics.build")
        } header: {
            Text("This build")
        } footer: {
            Text("Which build is installed on this iPhone. It is also the first line of every exported log.")
        }

        Section("Live status") {
            // Re-read every two seconds while the screen is up; nothing ticks otherwise.
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let counts = environment.heavyJobCounts()
                VStack(spacing: 0) {
                    ForEach(Array(health.statusRows(running: counts.running, waiting: counts.waiting).enumerated()), id: \.offset) { _, row in
                        LabeledContent(row.0, value: row.1)
                            .padding(.vertical, 4)
                    }
                    LabeledContent("Safe mode", value: health.safeModeDescription)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("diagnostics.safeModeStatus")
                }
            }
        }

        Section {
            Toggle("Safe mode", isOn: Binding(get: { health.safeMode.isActive }, set: { health.setSafeMode($0) }))
                .accessibilityIdentifier("diagnostics.safeMode")
        } footer: {
            Text("When PixlAudio closes unexpectedly while it works, safe mode keeps heavy jobs (lyric sync, vocal removal, model installs, library rescans, Cloud preparing, Spotify matching) from starting by themselves. After two such endings in a row it stays on until you turn it off here.")
        }

        Section {
            Button {
                let counts = environment.heavyJobCounts()
                if let url = health.reportFile(running: counts.running, waiting: counts.waiting) {
                    shared = SharedReport(url: url)
                }
            } label: {
                Label("Share logs", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("diagnostics.shareLogs")
            .sheet(item: $shared) { report in
                ActivitySheet(items: [report.url])
                    .presentationDetents([.medium, .large])
            }

            Button(role: .destructive) {
                confirmsStop = true
            } label: {
                Label("Emergency stop", systemImage: "exclamationmark.octagon.fill")
            }
            .accessibilityIdentifier("diagnostics.emergencyStop")
            .alert("Stop everything?", isPresented: $confirmsStop) {
                Button("Stop everything", role: .destructive) {
                    environment.activeJobs.emergencyStop()
                    stopNote = "Stopped. Nothing is running; automatic work stays off for ten minutes."
                }
                Button("Keep working", role: .cancel) {}
            } message: {
                Text("Lyric sync, vocal removal, library scans, imports, downloads, the model install, the automatic studio, Spotify matching and Cloud Studio all stop. Finished, failed and interrupted records are cleared and model memory is freed. Finished work stays.")
            }
            if let stopNote {
                Text(stopNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("diagnostics.emergencyStop.note")
            }
        } header: {
            Text("Logs and emergency")
        } footer: {
            Text("Share logs writes one text file (no song titles, paths or addresses) that you can send. Emergency stop cancels everything that runs or waits and forgets finished, failed and interrupted jobs.")
        }
    }
}

/// The exported report's file (the share sheet's item).
private struct SharedReport: Identifiable {
    let url: URL
    var id: URL { url }
}

/// UIKit's share sheet (a `ShareLink` needs its file when the screen is built; the report is written on tap).
private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
