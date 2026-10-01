// Export, inspection and transactional restore, ported from the Android app's `BackupManager`,
// `restore/RestorePlanner` and `restore/RestoreExecutor`. The data itself is the app's business: each module is
// a `BackupModuleHandler` (SwiftData, UserDefaults, the history file …) that exports, snapshots, restores and
// rolls back JSON payloads; `Modules/` has the pure codecs those handlers use.

import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel

/// One module's data access (`BackupModuleHandler`).
public protocol BackupModuleHandler: Sendable {
    var section: BackupSection { get }
    /// Serialises the current data into the module's JSON payload.
    func export() async throws -> String
    /// Number of items `export` would write.
    func countEntries() async throws -> Int
    /// The current state as a payload for rollback.
    func snapshot() async throws -> String
    /// Replaces the module's data with the payload.
    func restore(_ payload: String) async throws
    /// Restores a snapshot taken by `snapshot`.
    func rollback(_ snapshot: String) async throws
}

/// Static information written into the manifest by `BackupManager.export`.
public struct BackupAppInfo: Sendable, Hashable {
    public var appVersion: String
    public var appVersionCode: Int32
    public var deviceInfo: DeviceInfo

    public init(appVersion: String, appVersionCode: Int32, deviceInfo: DeviceInfo = DeviceInfo()) {
        self.appVersion = appVersion
        self.appVersionCode = appVersionCode
        self.deviceInfo = deviceInfo
    }
}

/// `RestorePlanner`.
public enum RestorePlanner {
    /// Reads the manifest and lists the restorable modules (known keys, manifest order) with their sizes.
    public static func buildRestorePlan(reader: BackupReader, backupUri: String) throws(BackupError) -> RestorePlan {
        let manifest = try reader.readManifest()
        guard let modules = manifest.modules else { throw BackupError("Backup manifest has no module list.") }
        var available: [BackupSection] = []
        for key in modules.keys {
            if let section = BackupSection.fromKey(key), !available.contains(section) { available.append(section) }
        }
        var details: [BackupSection: ModuleRestoreDetail] = [:]
        for section in available {
            let info = manifest.module(section.key)
            details[section] = ModuleRestoreDetail(entryCount: info?.entryCount ?? 0, sizeBytes: info?.sizeBytes ?? 0,
                                                   willOverwrite: true)
        }
        var warnings: [String] = []
        if manifest.schemaVersion < 3 {
            warnings.append("This is a legacy backup (v\(manifest.schemaVersion)). Some new modules may not be available.")
        }
        return RestorePlan(manifest: manifest, backupUri: backupUri, availableModules: available,
                           selectedModules: available, moduleDetails: details, warnings: warnings)
    }
}

/// `RestoreExecutor`: snapshot every selected module, then read → validate → restore one module at a time (in
/// key order); on any failure roll back in reverse order, including the module that failed.
public enum RestoreExecutor {
    public static func execute(reader: BackupReader, plan: RestorePlan, handlers: [BackupSection: any BackupModuleHandler],
                               pipeline: ValidationPipeline = ValidationPipeline(),
                               onProgress: (BackupTransferProgressUpdate) -> Void = { _ in }) async -> RestoreResult {
        let selected = plan.selectedModules.sorted { KotlinText.compare($0.key, $1.key) < 0 }
        let totalSteps = selected.count * 2 + 3
        var step = 0
        func report(_ title: String, _ detail: String, _ section: BackupSection? = nil) {
            step += 1
            onProgress(BackupTransferProgressUpdate(operation: .import, step: step, totalSteps: totalSteps, title: title,
                                                    detail: detail, section: section))
        }

        // Phase 1: snapshots.
        report("Creating safety snapshots", "Capturing current state for rollback.")
        var snapshots: [BackupSection: String] = [:]
        do {
            for section in selected {
                if let handler = handlers[section] { snapshots[section] = try await handler.snapshot() }
            }
        } catch {
            return .totalFailure("Failed to capture current state: \(message(of: error))")
        }

        // Phase 2: read, validate, restore.
        report("Preparing restore", "Selected modules will be processed one at a time.")
        var restored: [BackupSection] = []
        var current: BackupSection?
        do {
            for section in selected {
                current = section
                if let info = plan.manifest.module(section.key), info.sizeBytes > Int64(BackupReader.maxModulePayloadBytes) {
                    throw BackupError(
                        "Backup payload for \(section.label) is \(info.sizeBytes / (1024 * 1024))MB, which exceeds the "
                            + "\(BackupReader.maxModulePayloadBytes / (1024 * 1024))MB restore safety limit.")
                }
                let payload = try reader.readModulePayload(section.key)
                let validation = try pipeline.validateModulePayload(section, payload: payload, manifest: plan.manifest)
                if let fatal = validation.fatalErrors.first {
                    throw BackupError("Validation failed for \(section.label): \(fatal.message)")
                }
                report("Validated \(section.label)", section.description, section)
                report("Restoring \(section.label)", section.description, section)
                guard let handler = handlers[section] else { throw BackupError("No handler for module \(section.key)") }
                try await handler.restore(payload)
                restored.append(section)
            }
        } catch {
            var rollbackSucceeded = true
            var order = restored
            if let current, !order.contains(current) { order.append(current) }
            for section in order.reversed() {
                guard let snapshot = snapshots[section] else { continue }
                do {
                    try await handlers[section]?.rollback(snapshot)
                } catch {
                    rollbackSucceeded = false
                }
            }
            let reason = message(of: error)
            if rollbackSucceeded {
                let label = current?.label ?? "unknown module"
                return .totalFailure("Restore failed at \(label): \(reason). All applied changes were rolled back.")
            }
            return .partialFailure(succeeded: restored, failed: current.map { [$0: reason] } ?? [:], rolledBack: false)
        }

        // Phase 3.
        report("Restore complete", "All selected modules were restored successfully.")
        return .success
    }

    static func message(of error: any Error) -> String { backupErrorMessage(error) }
}

/// `BackupManager`: export to a `.pxpl`, inspect a backup into a `RestorePlan`, restore a plan.
public struct BackupManager: Sendable {
    public var pipeline: ValidationPipeline
    public var hasher: SHA256Hasher
    public var now: @Sendable () -> Int64

    public init(pipeline: ValidationPipeline = ValidationPipeline(), hasher: @escaping SHA256Hasher = BackupHashing.pureSwift,
                now: @escaping @Sendable () -> Int64 = { currentTimeMillis() }) {
        self.pipeline = pipeline
        self.hasher = hasher
        self.now = now
    }

    /// Exports the selected modules (in the given order) into `.pxpl` bytes.
    public func export(sections: [BackupSection], handlers: [BackupSection: any BackupModuleHandler], appInfo: BackupAppInfo,
                       onProgress: (BackupTransferProgressUpdate) -> Void = { _ in }) async throws -> [UInt8] {
        let totalSteps = sections.count + 3
        var step = 0
        func report(_ title: String, _ detail: String, _ section: BackupSection? = nil) {
            step += 1
            onProgress(BackupTransferProgressUpdate(operation: .export, step: step, totalSteps: totalSteps, title: title,
                                                    detail: detail, section: section))
        }
        report("Preparing backup", "Building your selected backup sections.")
        var payloads: [(key: String, payload: String)] = []
        for section in sections {
            report("Collecting \(section.label)", section.description, section)
            guard let handler = handlers[section] else { throw BackupError("No handler for module \(section.key)") }
            let payload = try await handler.export()
            payloads.removeAll { $0.key == section.key }
            payloads.append((section.key, payload))
        }
        let manifest = BackupManifest(schemaVersion: BackupManifest.currentSchemaVersion, appVersion: appInfo.appVersion,
                                      appVersionCode: appInfo.appVersionCode, createdAt: now(), deviceInfo: appInfo.deviceInfo)
        report("Packaging backup", "Creating .pxpl archive.")
        let bytes = BackupWriter.write(manifest: manifest, modulePayloads: payloads, hasher: hasher)
        report("Backup complete", "Your PixelPlay backup was created successfully.")
        return bytes
    }

    /// `inspectBackup`: validates the file, plans the restore, validates the manifest and every module (skipping
    /// modules over 16 MB), collecting non-fatal warnings into the plan; the first fatal error is thrown.
    public func inspectBackup(bytes: [UInt8], fileName: String?, fileSize: Int64? = nil,
                              backupUri: String? = nil) throws(BackupError) -> RestorePlan {
        let fileValidation = pipeline.validateFile(bytes: bytes, fileName: fileName, fileSize: fileSize ?? Int64(bytes.count))
        if let fatal = fileValidation.fatalErrors.first { throw BackupError(fatal.message) }
        var warnings = fileValidation.warnings.map(\.message)
        let reader = BackupReader(bytes: bytes, hasher: hasher, now: now)
        let plan = try RestorePlanner.buildRestorePlan(reader: reader, backupUri: backupUri ?? fileName ?? "backup.pxpl")
        let manifestValidation = try pipeline.validateManifest(plan.manifest)
        warnings.append(contentsOf: plan.warnings)
        if let fatal = manifestValidation.fatalErrors.first { throw BackupError(fatal.message) }
        warnings.append(contentsOf: manifestValidation.warnings.map(\.message))
        for section in plan.availableModules.sorted(by: { KotlinText.compare($0.key, $1.key) < 0 }) {
            if let info = plan.manifest.module(section.key), info.sizeBytes > Int64(BackupReader.maxModulePayloadBytes) {
                warnings.append("\(section.label): payload is \(info.sizeBytes / (1024 * 1024))MB, "
                                + "so preview validation was skipped to avoid running out of memory.")
                continue
            }
            let payload = try reader.readModulePayload(section.key)
            let validation = try pipeline.validateModulePayload(section, payload: payload, manifest: plan.manifest)
            if let fatal = validation.fatalErrors.first { throw BackupError("\(section.label): \(fatal.message)") }
            warnings.append(contentsOf: validation.warnings.map { "\(section.label): \($0.message)" })
        }
        var result = plan
        result.warnings = warnings
        return result
    }

    /// Restores the plan's selected modules (see `RestoreExecutor`).
    public func restore(bytes: [UInt8], plan: RestorePlan, handlers: [BackupSection: any BackupModuleHandler],
                        onProgress: (BackupTransferProgressUpdate) -> Void = { _ in }) async -> RestoreResult {
        let reader = BackupReader(bytes: bytes, hasher: hasher, now: now)
        return await RestoreExecutor.execute(reader: reader, plan: plan, handlers: handlers, pipeline: pipeline,
                                             onProgress: onProgress)
    }

    /// The history entry Android records after a successful restore.
    public static func historyEntry(for plan: RestorePlan, uri: String, displayName: String?, sizeBytes: Int64) -> BackupHistoryEntry {
        BackupHistoryEntry(uri: uri, displayName: displayName ?? "backup.pxpl", createdAt: plan.manifest.createdAt,
                           schemaVersion: plan.manifest.schemaVersion, modules: plan.manifest.moduleKeys,
                           sizeBytes: sizeBytes, appVersion: plan.manifest.appVersion ?? "")
    }
}
