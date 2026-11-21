import Testing
@testable import PixlLibrary

/// The ring code's rules over time, with a fake scanner: results are handed in, nothing here touches a picture (the Android
/// `RingFlowTest`, test for test).
@Suite("Ring code flow")
struct RingFlowTests {
    private let video = "dQw4w9WgXcQ"
    private let t0: Int64 = 1_763_600_000_000

    private func payload(bucketAgeMin: Int = 0, random: Int = 17, id: String? = nil, now: Int64? = nil) -> RingCodePayload {
        let at = now ?? t0
        let bucket = (RingCodePayloads.bucketOf(nowMs: at) - bucketAgeMin + RingCodePayloads.minuteBuckets) % RingCodePayloads.minuteBuckets
        return RingCodePayload(videoId: id ?? video, minuteBucket: bucket, random: random)
    }

    private func decoded(_ p: RingCodePayload) -> RingScanResult { .decoded(payload: p, corrected: 2, erasures: 0) }
    private let failed = RingScanResult.failed(.noPlate)

    /// Three equal decodes 150 ms apart: what a steady camera gives.
    private func read(_ flow: RingReceiveFlow, _ p: RingCodePayload, from: Int64) -> RingStep {
        var step = RingStep.none
        for i in 0..<3 { step = flow.offer(decoded(p), nowMs: from + Int64(i) * 150) }
        return step
    }

    private func isResolve(_ step: RingStep) -> RingCodePayload? {
        if case .resolve(let p) = step { return p }
        return nil
    }

    @Test func aSteadyFreshCodeIsTakenAfterThreeEqualReadsAndThenLookedUp() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        let p = payload()
        #expect(flow.offer(decoded(p), nowMs: t0 + 100) == .none)
        #expect(flow.offer(decoded(p), nowMs: t0 + 250) == .none)
        let step = flow.offer(decoded(p), nowMs: t0 + 400)
        #expect(isResolve(step) == p)
        #expect(flow.view().stage == .resolving)
        flow.resolved(p, ok: true, nowMs: t0 + 900)
        #expect(flow.view().stage == .idle)
    }

    @Test func twoDifferentCodesInBetweenNeverAddUp() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        #expect(flow.offer(decoded(payload(random: 1)), nowMs: t0 + 100) == .none)
        #expect(flow.offer(decoded(payload(random: 2)), nowMs: t0 + 250) == .none)
        #expect(flow.offer(decoded(payload(random: 1)), nowMs: t0 + 400) == .none)
        #expect(flow.view().stage == .scanning)
    }

    @Test func theQrIsNotOfferedAtFirstAndIsOfferedAfterSixSecondsOfAScanThatReadsNothing() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        var ms: Int64 = 0
        while ms < 5_900 { _ = flow.offer(failed, nowMs: t0 + ms); ms += 130 }
        #expect(!flow.tick(nowMs: t0 + 5_900))
        #expect(!flow.view().qrOffered)
        #expect(flow.tick(nowMs: t0 + 6_000))
        #expect(flow.view().qrOffered)
        #expect(flow.view().stage == .scanning)
        // Offered once, and it stays offered while the scan goes on.
        #expect(!flow.tick(nowMs: t0 + 6_500))
        #expect(flow.view().qrOffered)
    }

    @Test func aScanThatKeepsReadingCodesIsWorkingAndDoesNotOfferTheQrYet() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        // Alternating codes never reach three in a row, but every frame decodes.
        for i in 0..<60 { _ = flow.offer(decoded(payload(random: i % 2)), nowMs: t0 + Int64(i) * 130) }
        #expect(!flow.tick(nowMs: t0 + 7_000))
        #expect(!flow.view().qrOffered)
        // Once the decodes stop for two seconds, it is offered.
        #expect(flow.tick(nowMs: t0 + 10_500))
    }

    @Test func noCameraOffersTheQrAtOnceWithNothingToScan() {
        let flow = RingReceiveFlow()
        let v = flow.start(nowMs: t0, cameraAvailable: false)
        #expect(v.stage == .unavailable)
        #expect(v.qrOffered)
        #expect(flow.offer(decoded(payload()), nowMs: t0 + 10) == .none)
    }

    @Test func aCameraThatFailsWhileScanningOffersTheQr() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        let v = flow.cameraFailed()
        #expect(v.stage == .unavailable)
        #expect(v.qrOffered)
    }

    @Test func aScannerTooSlowForThisPhoneOffersTheQr() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        #expect(flow.scannerTooSlow().qrOffered)
        #expect(flow.view().stage == .scanning)
    }

    @Test func anExpiredTagIsRefusedSaysSoAndOffersTheQr() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        let step = read(flow, payload(bucketAgeMin: 5), from: t0 + 100)
        #expect(step == .rejected(.expired))
        let v = flow.view()
        #expect(v.message == .expired)
        #expect(v.qrOffered)
        #expect(v.stage == .scanning)
    }

    @Test func aTagFromTheFutureIsRefusedAsAClockProblem() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        let step = read(flow, payload(bucketAgeMin: -3), from: t0 + 100)
        #expect(step == .rejected(.future))
        #expect(flow.view().message == .clock)
        #expect(flow.view().qrOffered)
    }

    @Test func aCodeFromTwoMinutesAgoOneMinuteAheadAndThisMinuteAreAllFresh() {
        for age in [0, 1, 2, -1] {
            let flow = RingReceiveFlow()
            flow.start(nowMs: t0, cameraAvailable: true)
            #expect(isResolve(read(flow, payload(bucketAgeMin: age), from: t0 + 100)) != nil, "age \(age)")
        }
    }

    @Test func aWrongTagNeverReachesTheFlowAFailedChecksumIsJustAFrameThatReadNothing() throws {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        for i in 0..<30 {
            #expect(flow.offer(.failed(.badChecksum), nowMs: t0 + Int64(i) * 130) == .none)
        }
        #expect(flow.view().stage == .scanning)
        // A tag whose checksum is wrong cannot even be unpacked.
        var data = try #require(RingCodePayloads.pack(videoId: video, minuteBucket: 5, random: 9))
        data[10] ^= 0x5A
        #expect(RingCodePayloads.unpack(data) == .rejected(.badChecksum))
    }

    @Test func theSameCodeIsTakenOnceAndAReplayOfItIsRefused() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        let p = payload()
        #expect(isResolve(read(flow, p, from: t0 + 100)) != nil)
        flow.resolved(p, ok: true, nowMs: t0 + 800)
        // The listener scans again (or never left the code): the same video and tag again.
        flow.start(nowMs: t0 + 5_000, cameraAvailable: true)
        let step = read(flow, p, from: t0 + 5_100)
        #expect(step == .rejected(.replay))
        #expect(flow.view().message == .replay)
        #expect(!flow.view().qrOffered)
        // A new code for the same song (a new tag) is a different code and is taken.
        #expect(isResolve(read(flow, payload(random: 18), from: t0 + 5_800)) != nil)
    }

    @Test func aLookupThatFailsGoesBackToScanningWithTheQrOnOfferAndTheCodeIsNotForgotten() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        let p = payload()
        #expect(isResolve(read(flow, p, from: t0 + 100)) != nil)
        let v = flow.resolved(p, ok: false, nowMs: t0 + 700)
        #expect(v.stage == .scanning)
        #expect(v.message == .lookupFailed)
        #expect(v.qrOffered)
        // The same code is left alone for three seconds, then may be tried again.
        #expect(read(flow, p, from: t0 + 1_000) == .none)
        #expect(isResolve(read(flow, p, from: t0 + 4_000)) != nil)
    }

    @Test func resultsThatArriveWhileASongIsBeingLookedUpAreIgnored() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        #expect(isResolve(read(flow, payload(), from: t0 + 100)) != nil)
        #expect(read(flow, payload(random: 99), from: t0 + 500) == .none)
        #expect(flow.view().stage == .resolving)
    }

    @Test func stoppingPutsEverythingAway() {
        let flow = RingReceiveFlow()
        flow.start(nowMs: t0, cameraAvailable: true)
        flow.cameraFailed()
        #expect(flow.stop() == .idle)
        #expect(read(flow, payload(), from: t0 + 100) == .none)
    }

    @Test func theGuardKeepsABoundedMemory() {
        let guardian = RingCodeGuard(capacity: 4)
        for i in 0..<10 { guardian.commit(payload(random: i), nowMs: t0 + Int64(i)) }
        // The oldest are gone, the newest remembered.
        #expect(guardian.check(payload(random: 0), nowMs: t0 + 20) == .accept)
        #expect(guardian.check(payload(random: 9), nowMs: t0 + 20) == .replay)
        // And a code is forgotten after the memory window (an old tag is refused as expired first).
        #expect(guardian.check(payload(random: 9), nowMs: t0 + 10 * 60_000) == .expired)
    }

    @Test func onlyASongWithARealVideoIdCanUseTheRingCode() {
        #expect(RingSendRules.canRing(video))
        #expect(!RingSendRules.canRing(nil))
        #expect(!RingSendRules.canRing(""))
        #expect(!RingSendRules.canRing("short"))
        #expect(!RingSendRules.canRing("dQw4w9WgXc!"))
    }

    @Test func theSenderOffersTheQrAfterSixSecondsAndACodeIsMadeAgainEveryMinute() throws {
        #expect(!RingSendRules.qrButtonVisible(shownForMs: 5_999))
        #expect(RingSendRules.qrButtonVisible(shownForMs: 6_000))
        #expect(RingSendRules.codeLifeMs == 60_000)
        // Two codes a minute apart carry different tags for the same song.
        let a = try #require(RingCodePayloads.encodeSlots(videoId: video, minuteBucket: RingCodePayloads.bucketOf(nowMs: t0), random: 10))
        let b = try #require(RingCodePayloads.encodeSlots(videoId: video, minuteBucket: RingCodePayloads.bucketOf(nowMs: t0 + 60_000), random: 200))
        #expect(a != b)
    }

    // MARK: What the sender shows (the decisions the Android state holder makes in showCode)

    @Test func aSongWithAVideoIdGetsTheRingCodeAndOneWithoutGoesStraightToTheQrWithAReason() {
        #expect(RingSendPlan.of(videoId: video, qrPreferred: false) == RingSendPlan(kind: .ring, note: nil))
        #expect(RingSendPlan.of(videoId: nil, qrPreferred: false) == RingSendPlan(kind: .qr, note: .noVideo))
        #expect(RingSendPlan.of(videoId: "nope", qrPreferred: false) == RingSendPlan(kind: .qr, note: .noVideo))
    }

    @Test func aListenerWhoChoseTheQrKeepsItWhenTheCodeIsRebuilt() {
        #expect(RingSendPlan.of(videoId: video, qrPreferred: true) == RingSendPlan(kind: .qr, note: nil))
    }
}
