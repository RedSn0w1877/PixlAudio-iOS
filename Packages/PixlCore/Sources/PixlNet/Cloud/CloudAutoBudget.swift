// Smart auto-prepare's money and manners (Settings › Sing › "Prepare songs ahead in the cloud"). Pure rules, tested
// here; the app keeps the ledger in `CloudSettings` and gathers the phone's facts.
//
// Two budgets apply to every auto job: the auto-prepare budget below (default $1 a month, at most N songs a day) AND
// the shared monthly cap (`CloudBudget`, $3 with the built-in keys), so the cap stays the hard ceiling. The auto budget
// is kept in its own ledger and is NOT derived from the job list: "Clear finished" removes records, never spending.

import Foundation

/// What auto jobs have spent this month and how many went out today.
public struct CloudAutoLedger: Codable, Sendable, Equatable {
    public var monthStartMs: Int64
    public var spentMicroUSD: Int64
    public var dayStartMs: Int64
    public var dayCount: Int

    public init(monthStartMs: Int64 = 0, spentMicroUSD: Int64 = 0, dayStartMs: Int64 = 0, dayCount: Int = 0) {
        self.monthStartMs = monthStartMs
        self.spentMicroUSD = spentMicroUSD
        self.dayStartMs = dayStartMs
        self.dayCount = dayCount
    }

    /// A new month starts the spending from zero, a new day the count (the starts are the local calendar's).
    public mutating func roll(monthStartMs: Int64, dayStartMs: Int64) {
        if self.monthStartMs != monthStartMs {
            self.monthStartMs = monthStartMs
            spentMicroUSD = 0
        }
        if self.dayStartMs != dayStartMs {
            self.dayStartMs = dayStartMs
            dayCount = 0
        }
    }

    /// A job goes to RunPod: its estimate is spent until the real cost replaces it, and it counts for today.
    public mutating func reserve(_ estimateMicroUSD: Int64) {
        spentMicroUSD = min(spentMicroUSD + max(estimateMicroUSD, 0), 1_000_000_000_000)
        dayCount += 1
    }

    /// The real cost replaces what was reserved.
    public mutating func settle(reservedMicroUSD: Int64, actualMicroUSD: Int64) {
        spentMicroUSD = max(spentMicroUSD - max(reservedMicroUSD, 0) + max(actualMicroUSD, 0), 0)
    }

    /// A job stopped before the worker had it: what was reserved is free again (it still counts for today).
    public mutating func refund(_ reservedMicroUSD: Int64) {
        spentMicroUSD = max(spentMicroUSD - max(reservedMicroUSD, 0), 0)
    }
}

public enum CloudAutoBudget {
    /// $1 a month.
    public static let defaultMonthlyMicroUSD: Int64 = 1_000_000
    /// $0.25 steps (the slider).
    public static let budgetStepMicroUSD: Int64 = 250_000
    public static let defaultDailyCap = 12
    public static let dailyCapRange = 1...30
    /// Auto jobs go out in batches of at most this many, and at most this many are outstanding at once.
    public static let maxBatchSongs = 3
    public static let maxOutstanding = 3

    /// Both the auto budget and the shared cap must have room, and today's count must be under the daily cap.
    /// `committedMicroUSD` is the month's committed spend for the shared cap (`CloudBudget.committedMicroUSD`).
    public static func allows(estimateMicroUSD: Int64, ledger: CloudAutoLedger, budgetMicroUSD: Int64, dailyCap: Int,
                              committedMicroUSD: Int64, totalCapMicroUSD: Int64) -> Bool {
        guard ledger.dayCount < dailyCap else { return false }
        guard ledger.spentMicroUSD + max(estimateMicroUSD, 0) <= budgetMicroUSD else { return false }
        return CloudBudget.allows(estimateMicroUSD: estimateMicroUSD, capMicroUSD: totalCapMicroUSD,
                                  spentMicroUSD: committedMicroUSD)
    }

    /// How many of `estimates`, in order, can go out together: the longest start of the list that `allows` each one
    /// after the ones before it.
    public static func affordableCount(estimates: [Int64], ledger: CloudAutoLedger, budgetMicroUSD: Int64, dailyCap: Int,
                                       committedMicroUSD: Int64, totalCapMicroUSD: Int64) -> Int {
        var projected = ledger
        var committed = committedMicroUSD
        var count = 0
        for estimate in estimates {
            guard allows(estimateMicroUSD: estimate, ledger: projected, budgetMicroUSD: budgetMicroUSD, dailyCap: dailyCap,
                         committedMicroUSD: committed, totalCapMicroUSD: totalCapMicroUSD) else { break }
            projected.reserve(estimate)
            committed += max(estimate, 0)
            count += 1
        }
        return count
    }

    /// "About N songs a month" for a budget: a typical 4-minute song, with a cold start shared by a batch of
    /// `maxBatchSongs`, at the default GPU price.
    public static func songsPerMonth(budgetMicroUSD: Int64) -> Int {
        let seconds = CloudCost.warmSecondsStandard + CloudCost.coldStartSeconds / Int64(maxBatchSongs)
        let perSong = seconds * CloudCost.defaultPricePerSecondMicroUSD
        guard perSong > 0, budgetMicroUSD > 0 else { return 0 }
        return Int(budgetMicroUSD / perSong)
    }
}

/// The phone's state when auto-prepare wants to start work: it only runs while nothing else needs the phone.
public struct CloudAutoConditions: Sendable, Equatable {
    public static let minBatteryPercent = 40
    public static let minFreeBytes: Int64 = 1_073_741_824

    public var network: StreamPrefetchPolicy.Network
    /// A metered path (cellular, or a Wi-Fi personal hotspot).
    public var isExpensive: Bool
    /// Low Data Mode.
    public var isConstrained: Bool
    public var lowPowerMode: Bool
    /// Thermal state serious or worse.
    public var isHot: Bool
    /// 0…100, or -1 when the phone doesn't say.
    public var batteryPercent: Int
    public var isCharging: Bool
    public var freeBytes: Int64
    /// Lyric sync, a separation or a model install holds the heavy lane.
    public var heavyLaneBusy: Bool
    /// Safe mode or an Emergency stop is not holding automatic work back.
    public var launchWorkAllowed: Bool

    public init(network: StreamPrefetchPolicy.Network, isExpensive: Bool = false, isConstrained: Bool = false,
                lowPowerMode: Bool = false, isHot: Bool = false, batteryPercent: Int = 100, isCharging: Bool = false,
                freeBytes: Int64 = Int64.max, heavyLaneBusy: Bool = false, launchWorkAllowed: Bool = true) {
        self.network = network
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.lowPowerMode = lowPowerMode
        self.isHot = isHot
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.freeBytes = freeBytes
        self.heavyLaneBusy = heavyLaneBusy
        self.launchWorkAllowed = launchWorkAllowed
    }

    /// Wi-Fi or Ethernet that isn't metered and isn't in Low Data Mode.
    public var isUnmetered: Bool {
        (network == .wifi || network == .wired) && !isExpensive && !isConstrained
    }

    /// Why auto-prepare must wait now, in plain words, or nil when it may go.
    public var blockedReason: String? {
        if !isUnmetered { return "Waiting for Wi-Fi" }
        if lowPowerMode { return "Paused while the phone is saving power" }
        if isHot { return "Waiting for the phone to cool down" }
        if !launchWorkAllowed { return "Paused while PixlAudio recovers from an unexpected close" }
        if !isCharging && batteryPercent < Self.minBatteryPercent { return "Waiting for the phone to charge" }
        if freeBytes < Self.minFreeBytes { return "Waiting for more free space" }
        if heavyLaneBusy { return "Waiting for another job to finish" }
        return nil
    }
}
