// The settings of Spatial audio and Enhanced audio (cloud audio spec of 2026-11-10, section 6.1): the keys, the
// defaults and the clamps, as plain values, so both the rules and the storage round trip are tested without an app.
// The app reads the eight keys into `CloudAudioStoredSettings`, resolves them here, and writes a key only when the
// person changes it (a value that was never set keeps following its default).

import Foundation

/// The storage keys, exactly as the spec names the settings.
public enum CloudAudioSettingsKey {
    /// `off` or a profile id.
    public static let spatialProfile = "spatial.profile"
    /// `headphones` or `always`.
    public static let spatialRoute = "spatial.route"
    /// Ask the cloud for the real render (a Boolean).
    public static let spatialCloud = "spatial.cloud"
    /// Prepare favourites and most-played songs ahead (a Boolean).
    public static let spatialPrepareAhead = "spatial.prepareAhead"
    /// Use the Enhanced version of band-limited songs (a Boolean).
    public static let enhancedEnabled = "enhanced.enabled"
    /// The local budget for downloaded renders, in MB (an integer).
    public static let storageMB = "cloudAudio.storageMB"
    /// The month's cap for library jobs, in US dollars (a number; negative = no limit).
    public static let monthlyCapUSD = "cloudAudio.monthlyCapUSD"
    /// Songs a day the background queue may send (an integer).
    public static let dailyAhead = "cloudAudio.dailyAhead"

    public static let all: [String] = [spatialProfile, spatialRoute, spatialCloud, spatialPrepareAhead, enhancedEnabled,
                                       storageMB, monthlyCapUSD, dailyAhead]
}

/// The eight values as they are stored: nil means the person never set it, so its default applies.
public struct CloudAudioStoredSettings: Sendable, Hashable {
    public var profile: String?
    public var route: String?
    public var cloud: Bool?
    public var prepareAhead: Bool?
    public var enhancedEnabled: Bool?
    public var storageMB: Int?
    public var monthlyCapUSD: Double?
    public var dailyAhead: Int?

    public init(profile: String? = nil, route: String? = nil, cloud: Bool? = nil, prepareAhead: Bool? = nil,
                enhancedEnabled: Bool? = nil, storageMB: Int? = nil, monthlyCapUSD: Double? = nil,
                dailyAhead: Int? = nil) {
        self.profile = profile
        self.route = route
        self.cloud = cloud
        self.prepareAhead = prepareAhead
        self.enhancedEnabled = enhancedEnabled
        self.storageMB = storageMB
        self.monthlyCapUSD = monthlyCapUSD
        self.dailyAhead = dailyAhead
    }
}

/// The settings in force: every value resolved (defaults applied, numbers inside their ranges).
public struct CloudAudioSettings: Sendable, Hashable {
    /// `spatial.profile`. Default off.
    public var profile: SpatialSelection
    /// `spatial.route`. Default headphones.
    public var route: SpatialRouteMode
    /// `spatial.cloud`. Default: on exactly when this build has built-in cloud keys.
    public var cloud: Bool
    /// `spatial.prepareAhead`. Default on (it still needs `cloud`, Wi-Fi and a battery that is not low).
    public var prepareAhead: Bool
    /// `enhanced.enabled`. Default on.
    public var enhancedEnabled: Bool
    /// `cloudAudio.storageMB`. Default 3072.
    public var storageMB: Int
    /// `cloudAudio.monthlyCapUSD`. Default 30; nil is "No limit" (Developer mode).
    public var monthlyCapUSD: Double?
    /// `cloudAudio.dailyAhead`. Default 25.
    public var dailyAhead: Int

    public static let defaultStorageMB = 3072
    /// Not in the spec: what a stored storage budget is kept inside (256 MB … 64 GB).
    public static let storageMBRange: ClosedRange<Int> = 256...65_536
    public static let defaultMonthlyCapUSD: Double = 30
    /// The highest cap Developer mode offers before "No limit".
    public static let maxMonthlyCapUSD: Double = 200
    /// How "No limit" is stored under `cloudAudio.monthlyCapUSD` (any negative number reads as no limit).
    public static let noLimitStoredValue: Double = -1
    public static let defaultDailyAhead = 25
    /// Not in the spec: what a stored daily count is kept inside.
    public static let dailyAheadRange: ClosedRange<Int> = 1...100

    /// The defaults. `builtInCloudKeys`: this build carries PixlAudio's own cloud keys (and they are usable).
    public init(builtInCloudKeys: Bool) {
        profile = .off
        route = .headphones
        cloud = builtInCloudKeys
        prepareAhead = true
        enhancedEnabled = true
        storageMB = Self.defaultStorageMB
        monthlyCapUSD = Self.defaultMonthlyCapUSD
        dailyAhead = Self.defaultDailyAhead
    }

    /// The stored values with the defaults filled in and every number brought inside its range.
    public init(stored: CloudAudioStoredSettings, builtInCloudKeys: Bool) {
        self.init(builtInCloudKeys: builtInCloudKeys)
        if let value = stored.profile { profile = SpatialSelection(storageValue: value) }
        if let value = stored.route { route = SpatialRouteMode(storageValue: value) }
        if let value = stored.cloud { cloud = value }
        if let value = stored.prepareAhead { prepareAhead = value }
        if let value = stored.enhancedEnabled { enhancedEnabled = value }
        if let value = stored.storageMB { storageMB = Self.clampedStorageMB(value) }
        if let value = stored.monthlyCapUSD { monthlyCapUSD = Self.monthlyCap(fromStored: value) }
        if let value = stored.dailyAhead { dailyAhead = Self.clampedDailyAhead(value) }
    }

    /// Every value as it would be stored (used by tests and by a full write; the app normally writes one key).
    public var stored: CloudAudioStoredSettings {
        CloudAudioStoredSettings(profile: profile.storageValue, route: route.rawValue, cloud: cloud,
                                 prepareAhead: prepareAhead, enhancedEnabled: enhancedEnabled, storageMB: storageMB,
                                 monthlyCapUSD: Self.storedMonthlyCap(monthlyCapUSD), dailyAhead: dailyAhead)
    }

    public static func clampedStorageMB(_ value: Int) -> Int {
        min(max(value, storageMBRange.lowerBound), storageMBRange.upperBound)
    }

    public static func clampedDailyAhead(_ value: Int) -> Int {
        min(max(value, dailyAheadRange.lowerBound), dailyAheadRange.upperBound)
    }

    /// A stored cap as the cap in force: negative (or not a number) is no limit, else 0 … 200 dollars.
    public static func monthlyCap(fromStored value: Double) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        return min(value, maxMonthlyCapUSD)
    }

    /// A cap as it is stored (nil, "No limit", is `noLimitStoredValue`).
    public static func storedMonthlyCap(_ cap: Double?) -> Double {
        guard let cap else { return noLimitStoredValue }
        return min(max(cap, 0), maxMonthlyCapUSD)
    }

    /// The local budget in bytes.
    public var storageBytes: Int64 { Int64(storageMB) * 1_048_576 }

    /// The month's cap in millionths of a dollar (the unit Cloud Studio's money guards use); nil is no limit.
    public var monthlyCapMicroUSD: Int64? {
        monthlyCapUSD.map { Int64(($0 * 1_000_000).rounded()) }
    }
}
