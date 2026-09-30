import SwiftUI

/// Settings (placeholder): a native `Form` — no custom glass. Categories arrive in stage 7d.
struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                Label("Library", systemImage: "music.note.house")
                Label("Appearance", systemImage: "paintbrush")
                Label("Playback", systemImage: "play.circle")
                Label("Equalizer", systemImage: "slider.vertical.3")
                Label("Lyrics", systemImage: "quote.bubble")
                Label("Accounts", systemImage: "person.crop.circle")
                Label("Backup & Restore", systemImage: "externaldrive")
            } footer: {
                Text("Settings pages arrive in a later stage.")
            }
            .foregroundStyle(.secondary)

            Section("Developer") {
                NavigationLink(value: Route.diagnostics) {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
                .accessibilityIdentifier("settings.diagnostics")
            }

            Section("About") {
                LabeledContent("Version", value: AppInfo.versionString)
            }
        }
        .navigationTitle("Settings")
        .accessibilityIdentifier("screen.settings")
    }
}

/// Bundle version info, read once.
nonisolated enum AppInfo {
    static let versionString: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }()
}
