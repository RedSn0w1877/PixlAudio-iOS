import Testing
@testable import PixlFoundation

@Suite struct ProgressiveHeroTests {
    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    private func isIncreasing(_ stops: [ProgressiveHero.Stop]) -> Bool {
        zip(stops, stops.dropFirst()).allSatisfy { $0.location < $1.location }
    }

    @Test func smoothstepEasesBetweenTheEdges() {
        #expect(ProgressiveHero.smoothstep(0.4, 0.8, 0.1) == 0)
        #expect(ProgressiveHero.smoothstep(0.4, 0.8, 0.9) == 1)
        #expect(close(ProgressiveHero.smoothstep(0.4, 0.8, 0.6), 0.5))
        // Slower than a straight line near the start, faster through the middle.
        #expect(ProgressiveHero.smoothstep(0, 1, 0.1) < 0.1)
        #expect(ProgressiveHero.smoothstep(0, 1, 0.9) > 0.9)
        // Equal edges step at the edge.
        #expect(ProgressiveHero.smoothstep(0.5, 0.5, 0.49) == 0)
        #expect(ProgressiveHero.smoothstep(0.5, 0.5, 0.5) == 1)
    }

    @Test func blurMaskIsClearAboveAndOpaqueBelowTheBand() {
        let profile = ProgressiveHero.Profile.player
        let stops = ProgressiveHero.blurMask(profile)
        #expect(stops.first == .init(location: 0, opacity: 0))
        #expect(stops.last == .init(location: 1, opacity: 1))
        #expect(isIncreasing(stops))
        // Still clear where the band starts, fully opaque where it ends.
        let start = stops.first { close($0.location, profile.blurStart) }
        let end = stops.first { close($0.location, profile.blurEnd) }
        #expect(start?.opacity == 0)
        #expect(end?.opacity == 1)
        // The opacity only ever rises.
        #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.opacity <= $1.opacity })
    }

    @Test func meltMaskFadesTheHeroOutAtTheBottom() {
        let stops = ProgressiveHero.meltMask(.player)
        #expect(stops.first == .init(location: 0, opacity: 1))
        #expect(stops.last?.location == 1)
        #expect(stops.last?.opacity == 0)
        #expect(isIncreasing(stops))
        #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.opacity >= $1.opacity })
    }

    @Test func veilRisesToItsOpacity() {
        let profile = ProgressiveHero.Profile(blurStart: 0.4, blurEnd: 0.7, meltStart: 0.8, veilOpacity: 0.5)
        let stops = ProgressiveHero.veilMask(profile)
        #expect(stops.first == .init(location: 0, opacity: 0))
        #expect(stops.last == .init(location: 1, opacity: 0.5))
        #expect(stops.allSatisfy { $0.opacity <= 0.5 })
        // An out-of-range veil is clamped.
        let loud = ProgressiveHero.veilMask(.init(blurStart: 0.4, blurEnd: 0.7, meltStart: 0.8, veilOpacity: 3))
        #expect(loud.last?.opacity == 1)
    }

    @Test func rampClampsAndOrdersItsBand() {
        // A band past the edges is clamped to 0…1 and still starts at 0 and ends at 1.
        let wide = ProgressiveHero.ramp(start: -0.5, end: 1.5, samples: 3)
        #expect(wide.map(\.location) == [0, 0.5, 1])
        #expect(wide.first?.opacity == 0 && wide.last?.opacity == 1)
        // An end before the start collapses to a step at the start, with increasing locations.
        let backwards = ProgressiveHero.ramp(start: 0.6, end: 0.2, samples: 4)
        #expect(isIncreasing(backwards))
        #expect(backwards.first == .init(location: 0, opacity: 0))
        #expect(backwards.last == .init(location: 1, opacity: 1))
        // Fewer than two samples still describes the ease with two.
        #expect(ProgressiveHero.ramp(start: 0.2, end: 0.8, samples: 0).count == 4)
    }

    @Test func profilesKeepTheirBandsInOrder() {
        for profile in [ProgressiveHero.Profile.player, .header] {
            #expect(profile.blurStart < profile.blurEnd)
            #expect(profile.blurEnd <= profile.meltStart)
            #expect(profile.meltStart < 1)
            // Sharp for at least the top third.
            #expect(profile.blurStart >= 1.0 / 3)
        }
    }
}

@Suite struct ProgressiveHeroCompositionTests {
    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    @Test func blurredCopyIsClearAtTheTopOpaqueInTheMiddleAndMeltedAtTheBottom() {
        let profile = ProgressiveHero.Profile.player
        let stops = ProgressiveHero.blurMeltMask(profile)
        #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.location < $1.location })
        #expect(ProgressiveHero.value(stops, at: 0) == 0)
        #expect(ProgressiveHero.value(stops, at: profile.blurStart) == 0)
        // Opaque from where the sharp art is cut to where the melt starts: the cut never shows.
        #expect(close(ProgressiveHero.value(stops, at: profile.blurEnd), 1))
        #expect(close(ProgressiveHero.value(stops, at: (profile.blurEnd + profile.meltStart) / 2), 1))
        #expect(close(ProgressiveHero.value(stops, at: profile.meltStart), 1))
        #expect(ProgressiveHero.value(stops, at: 1) == 0)
        #expect(stops.allSatisfy { $0.opacity >= 0 && $0.opacity <= 1 })
    }

    @Test func veilRisesThenMeltsAway() {
        let profile = ProgressiveHero.Profile.player
        let stops = ProgressiveHero.veilMeltMask(profile)
        #expect(ProgressiveHero.value(stops, at: 0) == 0)
        #expect(ProgressiveHero.value(stops, at: 1) == 0)
        #expect(stops.allSatisfy { $0.opacity <= profile.veilOpacity + 0.0001 })
        #expect(ProgressiveHero.value(stops, at: profile.meltStart) > 0.2)
    }

    @Test func productReadsEachMaskBetweenItsStops() {
        let a = [ProgressiveHero.Stop(location: 0, opacity: 0), .init(location: 1, opacity: 1)]
        let b = [ProgressiveHero.Stop(location: 0.5, opacity: 1), .init(location: 1, opacity: 0)]
        let product = ProgressiveHero.product(a, b)
        #expect(product.map(\.location) == [0, 0.5, 1])
        #expect(close(product[1].opacity, 0.5))
        #expect(product.last?.opacity == 0)
        #expect(close(ProgressiveHero.value(a, at: 0.25), 0.25))
        // Held beyond the ends; no stops reads as opaque.
        #expect(ProgressiveHero.value(b, at: 0.1) == 1)
        #expect(ProgressiveHero.value([], at: 0.3) == 1)
    }

    @Test func playerHeroReachesUnderTheTitle() {
        // A 393 × 852 phone; the title starts 340 pt above the bottom edge.
        let layout = ProgressiveHero.playerLayout(width: 393, screenHeight: 852, titleClearance: 340)
        let profile = ProgressiveHero.Profile.player
        // About three quarters of the screen, sharp well past the square cover.
        #expect(layout.heroHeight > 0.7 * 852 && layout.heroHeight < 0.8 * 852)
        #expect(layout.sharpHeight > 393)
        // The blur starts near the middle of the screen and is fully in where the title starts.
        let blurStart = layout.heroHeight * profile.blurStart
        #expect(blurStart > 0.42 * 852 && blurStart < 0.52 * 852)
        #expect(abs(layout.heroHeight * profile.blurEnd - (852 - 340)) <= 1)
        #expect(layout.sharpHeight >= layout.heroHeight * profile.blurEnd)
    }

    @Test func playerHeroStaysBetweenTheWidthAndTheScreen() {
        // A short screen: never shorter than the width.
        let short = ProgressiveHero.playerLayout(width: 375, screenHeight: 500, titleClearance: 400)
        #expect(short.heroHeight == 375)
        // Never taller than the screen.
        let tall = ProgressiveHero.playerLayout(width: 393, screenHeight: 852, titleClearance: 0)
        #expect(tall.heroHeight == 852)
        // Unknown height: 1.6 × the width; unknown width: nothing.
        #expect(ProgressiveHero.playerLayout(width: 400, screenHeight: 0, titleClearance: 340).heroHeight == 640)
        #expect(ProgressiveHero.playerLayout(width: 0, screenHeight: 852, titleClearance: 340)
            == .init(heroHeight: 0, sharpHeight: 0))
    }

    @Test func blurredCopyLinesUpWithTheSharpArt() {
        // A header: the art fills the whole hero, a square at its larger side, centred; nothing to mirror.
        let header = ProgressiveHero.copyLayout(width: 393, sharpHeight: 480, heroHeight: 480)
        #expect(header == .init(side: 480, top: 0, mirrors: false))
        let wide = ProgressiveHero.copyLayout(width: 600, sharpHeight: 400, heroHeight: 400)
        #expect(wide == .init(side: 600, top: -100, mirrors: false))
        // The player: the square ends at the sharp part's bottom, and a mirrored copy runs on to the hero's bottom.
        let player = ProgressiveHero.copyLayout(width: 393, sharpHeight: 512, heroHeight: 624)
        #expect(player == .init(side: 512, top: 0, mirrors: true))
    }
}

@Suite struct ProgressRingTests {
    @Test func tickFollowsHowFastTheArcMoves() {
        // 3 minutes on a 44 pt ring (≈138 pt round): about 1.3 s per point.
        let song = ProgressRing.tickInterval(durationMs: 180_000, diameter: 44)
        #expect(abs(song - 180 / (Double.pi * 44)) < 0.0001)
        // A short clip ticks fast but never faster than the floor; a long mix never slower than the ceiling.
        #expect(ProgressRing.tickInterval(durationMs: 20_000, diameter: 44) == 0.25)
        #expect(ProgressRing.tickInterval(durationMs: 3_600_000, diameter: 44) == 2)
    }

    @Test func unknownDurationTicksAtTheSlowestRate() {
        #expect(ProgressRing.tickInterval(durationMs: 0, diameter: 44) == 2)
        #expect(ProgressRing.tickInterval(durationMs: -5, diameter: 44) == 2)
        #expect(ProgressRing.tickInterval(durationMs: 180_000, diameter: 0) == 2)
        #expect(ProgressRing.tickInterval(durationMs: 180_000, diameter: 44, step: 0) == 2)
    }

    @Test func drawnFractionIsClampedAndSnapped() {
        #expect(ProgressRing.drawnFraction(-1) == 0)
        #expect(ProgressRing.drawnFraction(2) == 1)
        #expect(ProgressRing.drawnFraction(.nan) == 0)
        #expect(ProgressRing.drawnFraction(0.50149, steps: 100) == 0.5)
        #expect(ProgressRing.drawnFraction(0.25, steps: 0) == 0.25)
    }
}
