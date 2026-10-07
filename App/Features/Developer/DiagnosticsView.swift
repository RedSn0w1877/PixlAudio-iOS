import PixlAudioCore
import PixlBackup
import PixlFoundation
import PixlLibrary
import PixlLyrics
import PixlModel
import PixlNet
import PixlTags
import SwiftUI
import UniformTypeIdentifiers

/// Diagnostics: the owner's optional one-time phone check (background audio, Now Playing, Keychain,
/// folder bookmarks, ProMotion, on-device model) plus build info. Native `Form`, no custom glass.
struct DiagnosticsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model = DiagnosticsModel()

    private static let coreModules: [String] = [
        PixlFoundationModule.name, PixlModelModule.name, PixlLyricsModule.name, PixlLibraryModule.name,
        PixlAudioCoreModule.name, PixlTagsModule.name, PixlNetModule.name, PixlBackupModule.name,
    ]

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await model.toggleTone() }
                } label: {
                    Label(
                        model.isTonePlaying ? "Stop Test Tone" : "Play Test Tone",
                        systemImage: model.isTonePlaying ? "stop.circle.fill" : "play.circle.fill"
                    )
                }
                .disabled(environment.launch.isUITest)
                .accessibilityIdentifier("diagnostics.tone")
                Text(model.toneStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Background Audio")
            } footer: {
                Text("Plays a generated tone with the audio background mode, Now Playing info and remote commands.")
            }

            Section("Keychain") {
                Button("Run Write/Read Round Trip", systemImage: "key.fill") {
                    model.runKeychainRoundTrip()
                }
                .accessibilityIdentifier("diagnostics.keychain")
                Text(model.keychainStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Choose Folder…", systemImage: "folder.badge.plus") {
                    model.isFolderImporterPresented = true
                }
                Button("Resolve Saved Folder", systemImage: "arrow.triangle.2.circlepath") {
                    model.resolveSavedFolder()
                }
                Button("Forget Saved Folder", systemImage: "trash", role: .destructive) {
                    model.forgetSavedFolder()
                }
                Text(model.folderStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Folder Access")
            } footer: {
                Text("Saves a security-scoped bookmark. Relaunch the app and resolve it to confirm access persists.")
            }

            Section("Library") {
                NavigationLink {
                    LibraryImportDebugView()
                } label: {
                    Label("Library Import", systemImage: "music.note.house")
                }
                .accessibilityIdentifier("diagnostics.libraryImport")
            }

            Section {
                Text(model.lastStreamStart ?? "No start measured yet. Play a song, then come back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("diagnostics.lastStart")
            } header: {
                Text("Last Song Start")
            } footer: {
                Text("How long the last song took to start, step by step. Every recent start: Developer › Test playback › Stream start timings.")
            }

            ConnectVolumeButtonsSection(buttons: environment.spotifyConnect.volumeButtons)

            Section("Device") {
                LabeledContent("Maximum refresh rate", value: model.maxRefreshRate.map { "\($0) Hz" } ?? "—")
                LabeledContent("ProMotion enabled", value: model.proMotionKeyPresent ? "Yes" : "No")
                LabeledContent("On-device model", value: model.onDeviceModelStatus)
                LabeledContent("iOS", value: model.systemVersion)
                LabeledContent("iOS 27 features", value: Compat27.isRunningOnIOS27OrLater ? "Available" : "Not available")
            }

            Section("Build") {
                LabeledContent("Version", value: AppInfo.versionString)
                LabeledContent("Core modules", value: "\(Self.coreModules.count) linked")
                Text(Self.coreModules.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Diagnostics")
        .fileImporter(
            isPresented: $model.isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            model.handleFolderImport(result)
        }
        .onAppear { model.refreshDisplayInfo() }
        .accessibilityIdentifier("screen.diagnostics")
    }
}

/// Whether the volume buttons drive the Spotify Connect device on this phone, and how (`SpotifyConnectVolumeButtons`):
/// the re-centre trick is undocumented, so Hoa reads the mode here instead of guessing from the feel.
private struct ConnectVolumeButtonsSection: View {
    let buttons: SpotifyConnectVolumeButtons?

    var body: some View {
        let status = buttons?.status ?? SpotifyConnectVolumeButtons.Status()
        Section {
            LabeledContent("Mode", value: Self.label(status.mode))
                .accessibilityIdentifier("diagnostics.volumeButtons.mode")
            LabeledContent("Presses counted", value: "\(status.presses)")
            LabeledContent("Last change", value: status.lastDelta.map { String(format: "%+.4f", Double($0)) } ?? "—")
            if let note = status.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Volume Buttons (Spotify Connect)")
        } footer: {
            Text("Play on a Spotify Connect speaker, press the volume buttons, then come back here. \"Re-centre\" means presses work at any phone volume; \"Relative\" means they stop at full or silent.")
        }
    }

    private static func label(_ mode: SpotifyConnectVolumeButtons.Mode) -> String {
        switch mode {
        case .off: "Off"
        case .recentre: "Re-centre"
        case .relative: "Relative"
        }
    }
}
