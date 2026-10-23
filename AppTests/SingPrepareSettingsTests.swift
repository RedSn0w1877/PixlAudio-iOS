import XCTest
@testable import PixlAudio

/// Settings › Sing › Prepare ahead (2026-10-22): the budget slider's steps and snapping, the daily cap's range, and the
/// plain-English texts (the switch, the caption under the budget, the Cloud processing consent line).
@MainActor
final class SingPrepareSettingsTests: XCTestCase {
    private func snapped(_ dollars: Double, ceiling: Int64 = 3_000_000) -> Int64 {
        SingPrepareControls.snappedBudget(dollars: dollars, ceilingMicroUSD: ceiling)
    }

    // MARK: Budget slider

    /// $3.00, or the monthly cap rounded down to a quarter dollar when it is lower, and never less than one step.
    func testBudgetCeilingIsThreeDollarsOrTheCap() {
        XCTAssertEqual(SingPrepareControls.budgetCeiling(capMicroUSD: 3_000_000), 3_000_000)
        XCTAssertEqual(SingPrepareControls.budgetCeiling(capMicroUSD: 25_000_000), 3_000_000, "own keys, a high cap: still $3")
        XCTAssertEqual(SingPrepareControls.budgetCeiling(capMicroUSD: 1_400_000), 1_250_000)
        XCTAssertEqual(SingPrepareControls.budgetCeiling(capMicroUSD: 100_000), 250_000)
        XCTAssertEqual(SingPrepareControls.budgetCeiling(capMicroUSD: -5), 250_000)
    }

    /// `SliderSettingRow` steps by range / (steps + 1): $3.00 with 11 stops is $0.25 a step, on any ceiling.
    func testSliderMovesInQuarterDollars() {
        for ceiling: Int64 in [3_000_000, 2_000_000, 1_250_000, 500_000] {
            let steps = SingPrepareControls.budgetSliderSteps(ceilingMicroUSD: ceiling)
            XCTAssertEqual(SingPrepareControls.dollars(ceiling) / Double(steps + 1), 0.25, accuracy: 1e-9)
        }
        XCTAssertEqual(SingPrepareControls.budgetSliderSteps(ceilingMicroUSD: 3_000_000), 11)
        XCTAssertEqual(SingPrepareControls.budgetSliderSteps(ceilingMicroUSD: 250_000), 0)
    }

    func testSnappedBudgetLandsOnWholeSteps() {
        XCTAssertEqual(snapped(0), 0)
        XCTAssertEqual(snapped(1.0), 1_000_000, "the default")
        XCTAssertEqual(snapped(0.25), 250_000)
        XCTAssertEqual(snapped(0.74), 750_000)
        XCTAssertEqual(snapped(0.12), 0)
        XCTAssertEqual(snapped(0.13), 250_000)
        XCTAssertEqual(snapped(3.0), 3_000_000)
    }

    func testSnappedBudgetStaysInsideTheRange() {
        XCTAssertEqual(snapped(9), 3_000_000)
        XCTAssertEqual(snapped(2.5, ceiling: 1_250_000), 1_250_000)
        XCTAssertEqual(snapped(-1), 0)
        XCTAssertEqual(snapped(.nan), 0)
        XCTAssertEqual(snapped(.infinity), 0)
    }

    // MARK: Daily cap

    func testDailyCapIsOneToThirtyInWholeSongs() {
        let range = SingPrepareControls.dailyCapRange
        XCTAssertEqual(range, 1...30)
        // 29 / (28 + 1) = one song a step.
        XCTAssertEqual(Double(range.upperBound - range.lowerBound) / Double(range.count - 2 + 1), 1, accuracy: 1e-9)
        XCTAssertEqual(SingPrepareControls.dailyCap(fromSlider: 12), 12)
        XCTAssertEqual(SingPrepareControls.dailyCap(fromSlider: 11.6), 12)
        XCTAssertEqual(SingPrepareControls.dailyCap(fromSlider: 0), 1)
        XCTAssertEqual(SingPrepareControls.dailyCap(fromSlider: 99), 30)
        XCTAssertEqual(SingPrepareControls.dailyCap(fromSlider: .nan), 1)
        XCTAssertEqual(SingPrepareControls.clampedDailyCap(-3), 1)
        XCTAssertEqual(SingPrepareControls.clampedDailyCap(31), 30)
    }

    // MARK: Texts

    func testSongsAMonthCaption() {
        XCTAssertEqual(L10n.settingsSingPrepareSongsPerMonth(0), "No songs a month")
        XCTAssertEqual(L10n.settingsSingPrepareSongsPerMonth(-4), "No songs a month")
        XCTAssertEqual(L10n.settingsSingPrepareSongsPerMonth(1), "About 1 song a month")
        XCTAssertEqual(L10n.settingsSingPrepareSongsPerMonth(190), "About 190 songs a month")
    }

    func testSwitchAndConsentTexts() {
        XCTAssertEqual(L10n.settingsSingPrepareTitle, "Prepare songs ahead in the cloud")
        XCTAssertEqual(L10n.settingsSingPrepareSubtitle, "Picks songs you're likely to sing and gets them ready on Wi-Fi.")
        XCTAssertEqual(L10n.settingsSingPrepareBudgetTitle, "Monthly budget")
        XCTAssertEqual(L10n.settingsCloudConsentSubtitle,
                       "Nothing leaves this phone until you tap Process in cloud or Sing, or turn on Prepare songs ahead.")
    }
}
