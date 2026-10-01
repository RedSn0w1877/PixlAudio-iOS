import SwiftUI
import UniformTypeIdentifiers

/// Developer screen for the library import (stage 6): add / remove music folders, the music-library source,
/// manual rescans and the scan's progress. The real folder-management screen is stage 7d's; this one only exists
/// so the import can be exercised on the phone. Native `Form`, like Diagnostics.
struct LibraryImportDebugView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var folders: [FolderSource] = []
    @State private var roots: [FolderRoot] = []
    @State private var status = "Idle"
    @State private var isImporterPresented = false
    @State private var isScanning = false
    @State private var includeMediaLibrary = UserDefaults.standard.bool(
        LibraryImportPreferenceKeys.includeMediaLibrary, default: true)

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Songs", value: "\(environment.library.songs.count)")
                LabeledContent("Albums", value: "\(environment.library.albums.count)")
                LabeledContent("Artists", value: "\(environment.library.artists.count)")
                if let progress = environment.library.lastImportProgress {
                    LabeledContent(progress.phase, value: progress.total > 0
                                   ? "\(progress.completed) / \(progress.total)" : "…")
                    if progress.total > 0 { ProgressView(value: progress.fraction) }
                }
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Button("Rescan (incremental)", systemImage: "arrow.clockwise") { rescan(.incremental) }
                    .disabled(isScanning)
                Button("Rescan everything", systemImage: "arrow.triangle.2.circlepath") { rescan(.full) }
                    .disabled(isScanning)
            }

            Section {
                ForEach(roots) { root in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(root.displayName)
                        Text(root.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                ForEach(folders.filter { !$0.isEnabled }) { folder in
                    Text("\(folder.displayName) (off)").foregroundStyle(.secondary)
                }
                Button("Add Folder…", systemImage: "folder.badge.plus") { isImporterPresented = true }
                ForEach(folders) { folder in
                    Button("Remove “\(folder.displayName)”", systemImage: "trash", role: .destructive) {
                        remove(folder)
                    }
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("The app's own folder (Files › On My iPhone › PixlAudio) is always included.")
            }

            Section {
                Toggle("Include music library", isOn: $includeMediaLibrary)
                    .onChange(of: includeMediaLibrary) { _, isOn in
                        UserDefaults.standard.set(isOn, forKey: LibraryImportPreferenceKeys.includeMediaLibrary)
                    }
                LabeledContent("Access", value: MediaLibraryImporter.isAuthorized ? "Granted" : "Not granted")
                if MediaLibraryImporter.canRequestAccess {
                    Button("Allow Access…", systemImage: "music.note.list") { requestMediaLibraryAccess() }
                }
            } header: {
                Text("Music Library")
            } footer: {
                Text("Only downloaded songs without copy protection can be played.")
            }
        }
        .navigationTitle("Library Import")
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.folder],
                      allowsMultipleSelection: true) { result in
            addFolders(result)
        }
        .task { await reloadFolders() }
        .accessibilityIdentifier("screen.libraryImportDebug")
    }

    private func reloadFolders() async {
        guard let importer = environment.libraryImporter else {
            status = "No importer (UI-test launch)"
            return
        }
        folders = (try? await importer.folderSources()) ?? []
        roots = (try? await importer.currentRoots()) ?? []
    }

    private func rescan(_ mode: LibraryImportMode) {
        isScanning = true
        status = "Scanning…"
        Task {
            let started = Date()
            do {
                try await environment.library.refresh(mode: mode)
                status = String(format: "Scan finished in %.1f s", Date().timeIntervalSince(started))
            } catch {
                status = "Scan failed: \(error.localizedDescription)"
            }
            isScanning = false
            await reloadFolders()
        }
    }

    private func addFolders(_ result: Result<[URL], any Error>) {
        guard let importer = environment.libraryImporter else { return }
        switch result {
        case .failure(let error):
            status = "Picker failed: \(error.localizedDescription)"
        case .success(let urls):
            Task {
                var added: [String] = []
                for url in urls {
                    do {
                        added.append(try await importer.addFolder(url).displayName)
                    } catch {
                        status = error.localizedDescription
                    }
                }
                if !added.isEmpty { status = "Added \(added.joined(separator: ", "))" }
                await reloadFolders()
                if !added.isEmpty { rescan(.incremental) }
            }
        }
    }

    private func remove(_ folder: FolderSource) {
        guard let importer = environment.libraryImporter else { return }
        Task {
            try? await importer.removeFolder(id: folder.id)
            await reloadFolders()
            rescan(.incremental)
        }
    }

    private func requestMediaLibraryAccess() {
        Task {
            let granted = await MediaLibraryImporter.requestAccess()
            environment.libraryAccessChanged()
            status = granted ? "Music library access granted" : "Music library access denied"
            if granted { rescan(.incremental) }
        }
    }
}
