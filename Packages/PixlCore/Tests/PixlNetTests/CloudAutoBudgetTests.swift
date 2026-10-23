import Foundation
import Testing
@testable import PixlNet

/// Smart auto-prepare's money: the auto budget, the daily count and the shared cap, and when the phone is ready.
@Suite struct CloudAutoBudgetTests {
    // MARK: The ledger

    @Test func theLedgerStartsAgainWithEachMonthAndEachDay() {
        var ledger = CloudAutoLedger(monthStartMs: 100, spentMicroUSD: 500_000, dayStartMs: 900, dayCount: 4)
        ledger.roll(monthStartMs: 100, dayStartMs: 900)
        #expect(ledger == CloudAutoLedger(monthStartMs: 100, spentMicroUSD: 500_000, dayStartMs: 900, dayCount: 4))
        // A new day: the count starts over, the month's spending stays.
        ledger.roll(monthStartMs: 100, dayStartMs: 1_000)
        #expect(ledger.dayCount == 0 && ledger.dayStartMs == 1_000 && ledger.spentMicroUSD == 500_000)
        // A new month: the spending starts over.
        ledger.dayCount = 3
        ledger.roll(monthStartMs: 200, dayStartMs: 1_000)
        #expect(ledger.spentMicroUSD == 0 && ledger.monthStartMs == 200 && ledger.dayCount == 3)
    }

    @Test func aReservationIsReplacedByTheRealCost() {
        var ledger = CloudAutoLedger()
        ledger.reserve(7_296)
        ledger.reserve(7_296)
        #expect(ledger.spentMicroUSD == 14_592 && ledger.dayCount == 2)
        // The first job cost less than reserved, the second more.
        ledger.settle(reservedMicroUSD: 7_296, actualMicroUSD: 5_000)
        #expect(ledger.spentMicroUSD == 12_296)
        ledger.settle(reservedMicroUSD: 7_296, actualMicroUSD: 9_000)
        #expect(ledger.spentMicroUSD == 14_000)
        // A job stopped before the worker had it gives its reservation back, but still counted for the day.
        ledger.refund(7_296)
        #expect(ledger.spentMicroUSD == 6_704 && ledger.dayCount == 2)
        ledger.refund(1_000_000)
        #expect(ledger.spentMicroUSD == 0, "never below zero")
    }

    @Test func theLedgerSurvivesBeingSavedAndRead() throws {
        let ledger = CloudAutoLedger(monthStartMs: 1, spentMicroUSD: 2, dayStartMs: 3, dayCount: 4)
        let data = try JSONEncoder().encode(ledger)
        #expect(try JSONDecoder().decode(CloudAutoLedger.self, from: data) == ledger)
    }

    // MARK: The budget

    private func allows(_ estimate: Int64, spent: Int64 = 0, day: Int = 0, budget: Int64 = 1_000_000, dailyCap: Int = 12,
                        committed: Int64 = 0, cap: Int64 = 3_000_000) -> Bool {
        CloudAutoBudget.allows(estimateMicroUSD: estimate, ledger: CloudAutoLedger(spentMicroUSD: spent, dayCount: day),
                               budgetMicroUSD: budget, dailyCap: dailyCap, committedMicroUSD: committed,
                               totalCapMicroUSD: cap)
    }

    @Test func aJobNeedsRoomInTheAutoBudgetAndInTheSharedCap() {
        #expect(allows(100_000, spent: 900_000))
        #expect(!allows(100_001, spent: 900_000), "over the auto budget")
        #expect(allows(60_000, committed: 2_940_000))
        #expect(!allows(60_001, committed: 2_940_000), "over the shared cap, though the auto budget has room")
        #expect(!allows(1, spent: 1_000_000))
        #expect(allows(0, spent: 1_000_000), "nothing to pay")
    }

    @Test func todaysCountStopsAtTheDailyCap() {
        #expect(allows(10_000, day: 11))
        #expect(!allows(10_000, day: 12))
        #expect(!allows(10_000, day: 3, dailyCap: 3))
    }

    @Test func aBatchIsCutWhereTheBudgetEnds() {
        let estimates: [Int64] = [400_000, 400_000, 400_000]
        func count(spent: Int64 = 0, day: Int = 0, dailyCap: Int = 12, committed: Int64 = 0) -> Int {
            CloudAutoBudget.affordableCount(estimates: estimates, ledger: CloudAutoLedger(spentMicroUSD: spent, dayCount: day),
                                            budgetMicroUSD: 1_000_000, dailyCap: dailyCap, committedMicroUSD: committed,
                                            totalCapMicroUSD: 3_000_000)
        }
        #expect(count() == 2, "the third would pass $1.00")
        #expect(count(spent: 600_000) == 1)
        #expect(count(spent: 700_000) == 0)
        #expect(count(day: 10, dailyCap: 12) == 2)
        #expect(count(day: 11, dailyCap: 12) == 1)
        #expect(count(committed: 2_300_000) == 1, "the shared cap has room for one")
        #expect(CloudAutoBudget.affordableCount(estimates: [], ledger: CloudAutoLedger(), budgetMicroUSD: 1, dailyCap: 1,
                                                committedMicroUSD: 0, totalCapMicroUSD: 1) == 0)
    }

    @Test func songsAMonthComesFromTheCostModel() {
        // A 4-minute song: 38 s of GPU plus a third of a 15 s cold start (batches of three), at $0.000192 a second.
        #expect(CloudAutoBudget.songsPerMonth(budgetMicroUSD: 1_000_000) == 121)
        #expect(CloudAutoBudget.songsPerMonth(budgetMicroUSD: 250_000) == 30)
        #expect(CloudAutoBudget.songsPerMonth(budgetMicroUSD: 3_000_000) == 363)
        #expect(CloudAutoBudget.songsPerMonth(budgetMicroUSD: 8_255) == 0)
        #expect(CloudAutoBudget.songsPerMonth(budgetMicroUSD: 8_256) == 1)
        #expect(CloudAutoBudget.songsPerMonth(budgetMicroUSD: 0) == 0)
        #expect(CloudAutoBudget.songsPerMonth(budgetMicroUSD: -5) == 0)
    }

    @Test func theDefaultsAreAnAffordableDozenADay() {
        #expect(CloudAutoBudget.defaultMonthlyMicroUSD == 1_000_000)
        #expect(CloudAutoBudget.defaultDailyCap == 12)
        #expect(CloudAutoBudget.dailyCapRange == 1...30)
        #expect(CloudAutoBudget.maxBatchSongs == 3 && CloudAutoBudget.maxOutstanding == 3)
    }

    // MARK: The phone

    @Test func autoPrepareWaitsForWiFiAndAHealthyPhone() {
        func reason(_ change: (inout CloudAutoConditions) -> Void) -> String? {
            var conditions = CloudAutoConditions(network: .wifi, batteryPercent: 80)
            change(&conditions)
            return conditions.blockedReason
        }
        #expect(reason { _ in } == nil)
        #expect(reason { $0.network = .wired } == nil)
        #expect(reason { $0.network = .cellular } == "Waiting for Wi-Fi")
        #expect(reason { $0.network = .offline } == "Waiting for Wi-Fi")
        #expect(reason { $0.network = .unknown } == "Waiting for Wi-Fi")
        #expect(reason { $0.isExpensive = true } == "Waiting for Wi-Fi", "a personal hotspot is metered")
        #expect(reason { $0.isConstrained = true } == "Waiting for Wi-Fi", "Low Data Mode")
        #expect(reason { $0.lowPowerMode = true } == "Paused while the phone is saving power")
        #expect(reason { $0.isHot = true } == "Waiting for the phone to cool down")
        #expect(reason { $0.launchWorkAllowed = false } != nil)
        #expect(reason { $0.batteryPercent = 39 } == "Waiting for the phone to charge")
        #expect(reason { $0.batteryPercent = 40 } == nil)
        #expect(reason { $0.batteryPercent = 5; $0.isCharging = true } == nil)
        #expect(reason { $0.batteryPercent = -1 } == "Waiting for the phone to charge")
        #expect(reason { $0.freeBytes = CloudAutoConditions.minFreeBytes - 1 } == "Waiting for more free space")
        #expect(reason { $0.freeBytes = CloudAutoConditions.minFreeBytes } == nil)
        #expect(reason { $0.heavyLaneBusy = true } == "Waiting for another job to finish")
        #expect(CloudAutoConditions(network: .wifi, isExpensive: false).isUnmetered)
        #expect(!CloudAutoConditions(network: .cellular).isUnmetered)
    }
}
