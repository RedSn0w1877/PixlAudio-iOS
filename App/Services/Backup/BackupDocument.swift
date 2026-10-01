import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A PixlAudio / PixelPlay backup (`.pxpl`), exported in Info.plist as `io.github.redsn0w1877.pixlaudio.backup`.
    nonisolated static let pixlBackup = UTType(exportedAs: "io.github.redsn0w1877.pixlaudio.backup", conformingTo: .data)

    /// What "Browse for file" accepts: `.pxpl` (v2/v3), Android's legacy v1 `.json` / `.json.gz`, and anything else
    /// (Android opens `*/*`; the reader detects the format from the bytes, not the name).
    nonisolated static let backupImportTypes: [UTType] = [.pixlBackup, .gzip, .json, .data]
}

/// The bytes of an exported backup, handed to `fileExporter` (Android `CreateDocument` → `BackupManager.export`).
nonisolated struct BackupFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pixlBackup]
    static let writableContentTypes: [UTType] = [.pixlBackup]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
