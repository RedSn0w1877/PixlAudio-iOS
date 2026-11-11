import Foundation
import Testing
@testable import PixlModel

@Suite struct BrokenFeatureTests {
    @Test func everyBrokenFeatureIsLockedAndLabelled() {
        #expect(BrokenFeature.label == "Broken, fix soon")
        for feature in BrokenFeature.allCases { #expect(feature.isLocked) }
        #expect(Set(BrokenFeature.allCases) == [.equalizer, .lyricsAdjustSync])
    }

    @Test func lockedAdjustSyncIgnoresTheStoredOffset() {
        #expect(BrokenFeature.lyricsOffsetMs(stored: 1_500) == 0)
        #expect(BrokenFeature.lyricsOffsetMs(stored: -300) == 0)
        #expect(BrokenFeature.lyricsOffsetMs(stored: 0) == 0)
    }
}
