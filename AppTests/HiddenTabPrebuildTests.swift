import XCTest
@testable import PixlAudio

final class HiddenTabPrebuildTests: XCTestCase {
    func testTheOtherTabsAreBuiltLibraryFirst() {
        XCTAssertEqual(HiddenTabPrebuild.order(selected: .home, built: [.home]), [.library, .search])
        XCTAssertEqual(HiddenTabPrebuild.order(selected: .library, built: [.library]), [.home, .search])
        XCTAssertEqual(HiddenTabPrebuild.order(selected: .search, built: [.search]), [.home, .library])
    }

    func testBuiltAndSelectedTabsAreSkipped() {
        XCTAssertEqual(HiddenTabPrebuild.order(selected: .home, built: [.home, .library]), [.search])
        XCTAssertTrue(HiddenTabPrebuild.order(selected: .home, built: Set(RootTab.allCases)).isEmpty)
        XCTAssertEqual(HiddenTabPrebuild.order(selected: .home, built: []), [.library, .search],
                       "the selected tab never needs building")
    }
}
