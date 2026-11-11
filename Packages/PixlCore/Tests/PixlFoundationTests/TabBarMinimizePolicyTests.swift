import Testing
@testable import PixlFoundation

@Suite struct TabBarMinimizePolicyTests {
    /// Feeds offsets, applying each flip like the router does; returns the final state.
    private func run(_ offsets: [Double], from policy: TabBarMinimizePolicy = .init(), minimized start: Bool = false)
        -> (state: Bool, policy: TabBarMinimizePolicy) {
        var policy = policy
        var state = start
        for offset in offsets {
            if let next = policy.update(offset: offset, minimized: state) { state = next }
        }
        return (state, policy)
    }

    @Test func minimizesAfterThresholdOfDownTravel() {
        #expect(run([0, 10, 30, 40]).state == false)
        #expect(run([0, 10, 30, 50]).state == true)
    }

    @Test func staysFullInsideTopZone() {
        #expect(run([0, 5, 12, 20, 24]).state == false)
    }

    @Test func restoresAfterThresholdOfUpTravel() {
        let down = run([0, 40, 80, 200])
        #expect(down.state == true)
        var policy = down.policy
        #expect(policy.update(offset: 180, minimized: true) == nil)
        #expect(policy.update(offset: 150, minimized: true) == false)
    }

    @Test func smallUpWobbleKeepsItMinimized() {
        #expect(run([0, 40, 80, 200, 190, 205, 195]).state == true)
    }

    @Test func scrollingBackToTheTopRestores() {
        #expect(run([0, 40, 80, 200, 100, 30, 0]).state == false)
    }

    // The new behaviour: a minimized bar survives a tab switch / push / pop, where the next page sits at the top.
    @Test func openingAPageAtTheTopDoesNotRestore() {
        // A fresh scroll view (anchor 0) reports offset 0 and a few zero frames while it lays out.
        #expect(run([0, 0, 0], minimized: true).state == true)
    }

    @Test func firstDownDragOnAFreshPageStaysMinimized() {
        #expect(run([0, 4, 10, 20, 30, 60], minimized: true).state == true)
    }

    @Test func upwardDragOnAFreshPageAfterScrollingDownRestoresNearTheTop() {
        #expect(run([0, 20, 10, 3], minimized: true).state == false)
    }

    @Test func switchingToAScrolledPageKeepsItMinimized() {
        var policy = TabBarMinimizePolicy()
        policy.reset(to: 500)
        #expect(run([500, 510], from: policy, minimized: true).state == true)
    }
}
