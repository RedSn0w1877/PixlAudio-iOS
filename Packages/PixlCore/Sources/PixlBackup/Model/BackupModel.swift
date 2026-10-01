// The `.pxpl` backup model, ported from the Android app's `data/backup/model/` (BackupSection, BackupManifest,
// BackupModels). Keys, labels, descriptions, versions and the validation/restore result shapes are Android's.

import Foundation
import PixlFoundation
import PixlLibrary
import PixlModel

/// One backup module (`BackupSection`); raw value = the module key (also the `<key>.json` entry name).
public enum BackupSection: String, Sendable, Hashable, CaseIterable, Codable {
    case playlists = "playlists"
    case globalSettings = "global_settings"
    case favorites = "favorites"
    case lyrics = "lyrics"
    case searchHistory = "search_history"
    case transitions = "transitions"
    case engagementStats = "engagement_stats"
    case playbackHistory = "playback_history"
    case quickFill = "quick_fill"
    case artistImages = "artist_images"
    case equalizer = "equalizer"
    case aiUsageLogs = "ai_usage_logs"

    public var key: String { rawValue }

    /// Kotlin constant name.
    public var kotlinName: String {
        switch self {
        case .playlists: "PLAYLISTS"
        case .globalSettings: "GLOBAL_SETTINGS"
        case .favorites: "FAVORITES"
        case .lyrics: "LYRICS"
        case .searchHistory: "SEARCH_HISTORY"
        case .transitions: "TRANSITIONS"
        case .engagementStats: "ENGAGEMENT_STATS"
        case .playbackHistory: "PLAYBACK_HISTORY"
        case .quickFill: "QUICK_FILL"
        case .artistImages: "ARTIST_IMAGES"
        case .equalizer: "EQUALIZER"
        case .aiUsageLogs: "AI_USAGE_LOGS"
        }
    }

    /// English label (localised by the app's String Catalog). Also used in Android's error messages.
    public var label: String {
        switch self {
        case .playlists: "Playlists"
        case .globalSettings: "Global Settings"
        case .favorites: "Favorites"
        case .lyrics: "Saved Lyrics"
        case .searchHistory: "Search History"
        case .transitions: "Transition Rules"
        case .engagementStats: "Engagement Stats"
        case .playbackHistory: "Playback History"
        case .quickFill: "QuickFill Genres"
        case .artistImages: "Artist Images"
        case .equalizer: "Equalizer"
        case .aiUsageLogs: "AI Activity Logs"
        }
    }

    public var description: String {
        switch self {
        case .playlists: "Your custom playlists and ordering preferences."
        case .globalSettings: "Themes, behavior, playback, and app preferences."
        case .favorites: "Songs marked as favorite."
        case .lyrics: "Lyrics you've saved or imported."
        case .searchHistory: "Recent search terms in the app."
        case .transitions: "Custom transition settings between songs."
        case .engagementStats: "Play count and listening duration per song."
        case .playbackHistory: "Timeline-based listening history for stats."
        case .quickFill: "Custom genres and their icons."
        case .artistImages: "Cached artist image URLs from Deezer."
        case .equalizer: "Your custom equalizer presets and audio profiles."
        case .aiUsageLogs: "History of AI requests and token consumption."
        }
    }

    /// SF Symbol standing in for the Android drawable (`iconRes`).
    public var systemImage: String {
        switch self {
        case .playlists: "music.note.list"
        case .globalSettings: "gearshape"
        case .favorites: "heart"
        case .lyrics: "quote.bubble"
        case .searchHistory: "magnifyingglass"
        case .transitions: "arrow.left.and.right"
        case .engagementStats: "chart.bar"
        case .playbackHistory: "clock"
        case .quickFill: "square.grid.2x2"
        case .artistImages: "person.crop.circle"
        case .equalizer: "slider.vertical.3"
        case .aiUsageLogs: "chart.bar.doc.horizontal"
        }
    }

    /// Schema version that introduced the module.
    public var sinceVersion: Int {
        switch self {
        case .quickFill, .artistImages, .equalizer: 3
        case .aiUsageLogs: 4
        default: 1
        }
    }

    /// Every module (`defaultSelection`).
    public static let defaultSelection: Set<BackupSection> = Set(allCases)

    /// `fromKey`: exact key match.
    public static func fromKey(_ key: String) -> BackupSection? {
        allCases.first { KotlinText.equals($0.key, key) }
    }
}

/// Per-module manifest record (`BackupModuleInfo`). Gson may leave `checksum` null.
public struct BackupModuleInfo: Sendable, Hashable {
    public var checksum: String?
    public var entryCount: Int32
    public var sizeBytes: Int64

    public init(checksum: String? = "", entryCount: Int32 = 0, sizeBytes: Int64 = 0) {
        self.checksum = checksum
        self.entryCount = entryCount
        self.sizeBytes = sizeBytes
    }
}

/// Device record (`DeviceInfo`). PixlAudio writes the iPhone's model and leaves `androidVersion` 0.
public struct DeviceInfo: Sendable, Hashable {
    public var manufacturer: String?
    public var model: String?
    public var androidVersion: Int32

    public init(manufacturer: String? = "", model: String? = "", androidVersion: Int32 = 0) {
        self.manufacturer = manufacturer
        self.model = model
        self.androidVersion = androidVersion
    }
}

/// `manifest.json` (`BackupManifest`). Fields Gson can set to null stay optional; `modules` keeps file order.
public struct BackupManifest: Sendable, Hashable {
    public static let currentSchemaVersion: Int32 = 3
    public static let minSupportedVersion: Int32 = 1
    public static let manifestFilename = "manifest.json"

    public var schemaVersion: Int32
    public var appVersion: String?
    public var appVersionCode: Int32
    public var createdAt: Int64
    public var deviceInfo: DeviceInfo?
    /// nil only when the file says `"modules": null` (Android then fails on first use).
    public var modules: GsonMap<BackupModuleInfo>?

    public init(schemaVersion: Int32 = currentSchemaVersion, appVersion: String? = "", appVersionCode: Int32 = 0,
                createdAt: Int64 = currentTimeMillis(), deviceInfo: DeviceInfo? = DeviceInfo(),
                modules: GsonMap<BackupModuleInfo>? = GsonMap()) {
        self.schemaVersion = schemaVersion
        self.appVersion = appVersion
        self.appVersionCode = appVersionCode
        self.createdAt = createdAt
        self.deviceInfo = deviceInfo
        self.modules = modules
    }

    /// `manifest.modules[key]` (nil when absent or null).
    public func module(_ key: String) -> BackupModuleInfo? {
        guard let entry = modules?[key] else { return nil }
        return entry
    }

    /// Module keys in file order (empty when `modules` is null).
    public var moduleKeys: [String] { modules?.keys ?? [] }
}

/// `BackupOperationType`.
public enum BackupOperationType: String, Sendable, Hashable {
    case export = "EXPORT"
    case `import` = "IMPORT"
}

/// `BackupTransferProgressUpdate`.
public struct BackupTransferProgressUpdate: Sendable, Hashable {
    public var operation: BackupOperationType
    public var step: Int
    public var totalSteps: Int
    public var title: String
    public var detail: String
    public var section: BackupSection?

    public init(operation: BackupOperationType, step: Int, totalSteps: Int, title: String, detail: String,
                section: BackupSection? = nil) {
        self.operation = operation
        self.step = step
        self.totalSteps = totalSteps
        self.title = title
        self.detail = detail
        self.section = section
    }

    /// `step / totalSteps` clamped to 0…1 (0 when there are no steps).
    public var progress: Float { totalSteps > 0 ? min(max(Float(step) / Float(totalSteps), 0), 1) : 0 }
}

/// `ValidationError` severity.
public enum Severity: String, Sendable, Hashable {
    case error = "ERROR"
    case warning = "WARNING"
}

/// `ValidationError`.
public struct ValidationError: Sendable, Hashable {
    public var code: String
    public var message: String
    public var module: String?
    public var severity: Severity

    public init(code: String, message: String, module: String? = nil, severity: Severity = .error) {
        self.code = code
        self.message = message
        self.module = module
        self.severity = severity
    }
}

/// `BackupValidationResult`.
public enum BackupValidationResult: Sendable, Hashable {
    case valid
    case invalid([ValidationError])

    public var errors: [ValidationError] {
        if case .invalid(let errors) = self { return errors }
        return []
    }

    public var fatalErrors: [ValidationError] { errors.filter { $0.severity == .error } }
    public var warnings: [ValidationError] { errors.filter { $0.severity == .warning } }

    /// Valid, or invalid with warnings only.
    public var isValid: Bool { fatalErrors.isEmpty }

    /// Android's closing rule: any error at all makes the result `Invalid` (warnings too), none makes it `Valid`.
    static func from(_ errors: [ValidationError]) -> BackupValidationResult {
        errors.isEmpty ? .valid : .invalid(errors)
    }
}

/// `ModuleRestoreDetail`.
public struct ModuleRestoreDetail: Sendable, Hashable {
    public var entryCount: Int32
    public var sizeBytes: Int64
    public var willOverwrite: Bool

    public init(entryCount: Int32, sizeBytes: Int64, willOverwrite: Bool = true) {
        self.entryCount = entryCount
        self.sizeBytes = sizeBytes
        self.willOverwrite = willOverwrite
    }
}

/// `RestorePlan`. Module lists keep manifest order (Android's `Set`s are insertion-ordered).
public struct RestorePlan: Sendable, Hashable {
    public var manifest: BackupManifest
    /// A display name or URL of the backup the plan was built from.
    public var backupUri: String
    public var availableModules: [BackupSection]
    public var selectedModules: [BackupSection]
    public var moduleDetails: [BackupSection: ModuleRestoreDetail]
    public var warnings: [String]

    public init(manifest: BackupManifest, backupUri: String, availableModules: [BackupSection],
                selectedModules: [BackupSection], moduleDetails: [BackupSection: ModuleRestoreDetail],
                warnings: [String] = []) {
        self.manifest = manifest
        self.backupUri = backupUri
        self.availableModules = availableModules
        self.selectedModules = selectedModules
        self.moduleDetails = moduleDetails
        self.warnings = warnings
    }

    /// A copy restoring only `sections` (kept in `availableModules` order).
    public func selecting(_ sections: Set<BackupSection>) -> RestorePlan {
        var copy = self
        copy.selectedModules = availableModules.filter(sections.contains)
        return copy
    }
}

/// `RestoreResult`.
public enum RestoreResult: Sendable, Hashable {
    case success
    case partialFailure(succeeded: [BackupSection], failed: [BackupSection: String], rolledBack: Bool)
    case totalFailure(String)
}

/// `BackupHistoryEntry`: a backup the user restored, shown in the Backup screen's history.
public struct BackupHistoryEntry: Sendable, Hashable, Codable {
    public var uri: String
    public var displayName: String
    public var createdAt: Int64
    public var schemaVersion: Int32
    public var modules: [String]
    public var sizeBytes: Int64
    public var appVersion: String

    public init(uri: String, displayName: String, createdAt: Int64, schemaVersion: Int32, modules: [String],
                sizeBytes: Int64, appVersion: String = "") {
        self.uri = uri
        self.displayName = displayName
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
        self.modules = modules
        self.sizeBytes = sizeBytes
        self.appVersion = appVersion
    }
}

/// `BackupHistoryRepository`'s list rules (the app persists the list).
public enum BackupHistory {
    public static let maxEntries = 10

    /// `addEntry`: drop any entry with the same URI, put the new one first, keep at most 10.
    public static func adding(_ entry: BackupHistoryEntry, to history: [BackupHistoryEntry]) -> [BackupHistoryEntry] {
        var updated = history.filter { !KotlinText.equals($0.uri, entry.uri) }
        updated.insert(entry, at: 0)
        return Array(updated.prefix(maxEntries))
    }

    /// `removeEntry`.
    public static func removing(uri: String, from history: [BackupHistoryEntry]) -> [BackupHistoryEntry] {
        history.filter { !KotlinText.equals($0.uri, uri) }
    }
}

/// A backup operation failure carrying the message Android shows (its exception message).
public struct BackupError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) { self.message = message }

    public var description: String { message }
}

/// The user-facing message of any error a backup operation throws.
func backupErrorMessage(_ error: any Error) -> String {
    if let e = error as? BackupError { return e.message }
    if let e = error as? GsonError { return e.message }
    return String(describing: error)
}
