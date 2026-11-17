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

    @Test func smootherstepHasNoVisibleEnds() {
        #expect(ProgressiveHero.smootherstep(0.4, 0.8, 0.1) == 0)
        #expect(ProgressiveHero.smootherstep(0.4, 0.8, 0.9) == 1)
        #expect(close(ProgressiveHero.smootherstep(0.4, 0.8, 0.6), 0.5))
        // Flatter than smoothstep at both ends: no slope (and no curvature) where a fade starts or stops.
        #expect(ProgressiveHero.smootherstep(0, 1, 0.01) < 1e-5)
        #expect(ProgressiveHero.smootherstep(0, 1, 0.99) > 1 - 1e-5)
        #expect(ProgressiveHero.smootherstep(0, 1, 0.1) < ProgressiveHero.smoothstep(0, 1, 0.1))
        #expect(ProgressiveHero.smootherstep(0.5, 0.5, 0.49) == 0)
        #expect(ProgressiveHero.smootherstep(0.5, 0.5, 0.5) == 1)
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
        // Full where the melt starts, so with the melt folded in it only falls from there.
        #expect(ProgressiveHero.value(stops, at: profile.meltStart) == 0.5)
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
            // Strictly: the sharp art is cut at `blurEnd` (rounded up a point), where the copy must still be opaque.
            #expect(profile.blurEnd < profile.meltStart)
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
        // Most of the screen, sharp well past the square cover, and running on well below the title (to the
        // transport) so the melt is gentle.
        #expect(layout.heroHeight > 0.8 * 852 && layout.heroHeight < 0.9 * 852)
        #expect(layout.heroHeight - (852 - 340) >= 180)
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
        // Unknown height: 1.8 × the width; unknown width: nothing.
        #expect(ProgressiveHero.playerLayout(width: 400, screenHeight: 0, titleClearance: 340).heroHeight == 720)
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

/// The hero as drawn: every layer at every point, on real screens, checked for seams. A "screen" is the player on a
/// phone (390 × 844 with a notch, 402 × 874 and 440 × 956 with the island, 375 × 667 with a home button) or a header
/// page (its hero is its own frame, the sharp art cut at `blurEnd`).
@Suite struct ProgressiveHeroSeamTests {
    private struct Hero {
        let name: String
        let profile: ProgressiveHero.Profile
        let layout: ProgressiveHero.Layout
        let width: Double
    }

    private static func player(_ width: Double, _ height: Double, bottomSafeArea: Double) -> Hero {
        // NowPlayingView: the title's top is 320 pt plus the bottom safe area above the screen's bottom edge.
        Hero(name: "player \(Int(width))×\(Int(height))", profile: .player,
             layout: ProgressiveHero.playerLayout(width: width, screenHeight: height,
                                                  titleClearance: 320 + bottomSafeArea),
             width: width)
    }

    private static func header(_ width: Double, _ height: Double) -> Hero {
        // ProgressiveBlurHero: the sharp art is cut at ceil(height × blurEnd).
        let profile = ProgressiveHero.Profile.header
        return Hero(name: "header \(Int(width))×\(Int(height))", profile: profile,
                    layout: .init(heroHeight: height, sharpHeight: (height * profile.blurEnd).rounded(.up)),
                    width: width)
    }

    private static let heroes: [Hero] = [
        player(390, 844, bottomSafeArea: 34), player(402, 874, bottomSafeArea: 34),
        player(440, 956, bottomSafeArea: 34), player(375, 667, bottomSafeArea: 0),
        header(390, 424), header(440, 478),
    ]

    @Test func everyLayerIsClearAtTheHerosBottomEdge() {
        for profile in [ProgressiveHero.Profile.player, .header] {
            let copy = ProgressiveHero.blurMeltMask(profile)
            let veil = ProgressiveHero.veilMeltMask(profile)
            // The gradients end on a stop at exactly the bottom edge, at exactly 0 (nothing held past it).
            #expect(copy.last == .init(location: 1, opacity: 0))
            #expect(veil.last == .init(location: 1, opacity: 0))
            // The page-colour fallback for a missing copy draws under the copy's own mask: the same 0.
            #expect(ProgressiveHero.value(copy, at: 1) == 0)
            #expect(ProgressiveHero.value(veil, at: 1) == 0)
        }
        // The top scrim fades to exactly 0 at its own bottom edge too.
        let scrim = ProgressiveHero.topScrimMask(opacity: 0.32)
        #expect(scrim.first == .init(location: 0, opacity: 0.32))
        #expect(scrim.last == .init(location: 1, opacity: 0))
        // And the scrim ends over the sharp art, well above where the blur starts (top bar: safe area + 72 pt).
        for hero in Self.heroes where hero.profile == .player {
            #expect(62 + 72 < hero.layout.heroHeight * hero.profile.blurStart)
        }
    }

    @Test func sharpArtIsCutOnlyWhereTheCopyIsOpaque() {
        for hero in Self.heroes {
            let copy = ProgressiveHero.blurMeltMask(hero.profile)
            let clip = hero.layout.clip
            #expect(clip >= hero.profile.blurEnd, "\(hero.name)")
            #expect(clip < hero.profile.meltStart, "\(hero.name)")
            // Opaque from `blurEnd` (the cut rounds up to the next point) through the cut and a point below it, so
            // the cut can't show; above `blurEnd` the sharp art is still there under the rising copy.
            let point = 1 / hero.layout.heroHeight
            for location in [hero.profile.blurEnd, clip, clip + point] {
                #expect(ProgressiveHero.value(copy, at: location) > 1 - 1e-9, "\(hero.name) at \(location)")
            }
        }
    }

    @Test func compositeHasNoSeamAnywhere() {
        // Each layer painted in its own value, with or without the blurred copy (without it, the page-colour fallback
        // takes the copy's mask), over a background unlike all of them (whatever ambient style is on). Sampled every
        // fifth of a point from above the hero to well below its frame; adjacent samples may differ only by a small
        // epsilon (the old player cut its copies at the sharp part's bottom: a jump of about a third of the range there).
        for hero in Self.heroes {
            let copyStops = ProgressiveHero.blurMeltMask(hero.profile)
            let veilStops = ProgressiveHero.veilMeltMask(hero.profile)
            let height = hero.layout.heroHeight
            for copyValue in [0.7, 0.3] {
                var previous: Double?
                var worst = 0.0
                var worstAt = 0.0
                let steps = Int(height * 1.2 * 5)
                for i in 0 ... steps {
                    let points = Double(i) / 5
                    let layers = ProgressiveHero.layers(at: points / height, clip: hero.layout.clip,
                                                        copy: copyStops, veil: veilStops)
                    let value = layers.composite(sharpValue: 1, copyValue: copyValue, veilValue: 0.3, background: 0)
                    if let previous, abs(value - previous) > worst {
                        worst = abs(value - previous)
                        worstAt = points
                    }
                    previous = value
                }
                #expect(worst < 0.01, "\(hero.name): a step of \(worst) at \(worstAt) pt")
            }
        }
    }

    @Test func aCopyCutAtTheSharpPartIsASeam() {
        // The 2026-11-16 bug, as the owner's screenshot measured it (390 × 844: hero 598 pt, sharp part 491 pt, the
        // red channel falling from 142 to 117 across one point): the copy rode below a page only as tall as the sharp
        // part and was cut there, so below the cut only the veil was left over the background.
        let profile = ProgressiveHero.Profile(blurStart: 0.62, blurEnd: 0.82, meltStart: 0.86, veilOpacity: 0.6)
        let layout = ProgressiveHero.Layout(heroHeight: 598, sharpHeight: 491)
        let copyStops = ProgressiveHero.blurMeltMask(profile)
        let veilStops = ProgressiveHero.veilMeltMask(profile)
        func drawn(_ points: Double) -> Double {
            var layers = ProgressiveHero.layers(at: points / layout.heroHeight, clip: layout.clip,
                                                copy: copyStops, veil: veilStops)
            if points >= layout.sharpHeight { layers.copy = 0 }
            return layers.composite(sharpValue: 1, copyValue: 0.7, veilValue: 0.3, background: 0)
        }
        // The seam check catches it: a jump of a large part of the range within a fifth of a point.
        #expect(abs(drawn(491) - drawn(490.8)) > 0.25)
    }

    @Test func heroDissolvesCompletelyAndMonotonicallyAtTheBottom() {
        for hero in Self.heroes {
            let copyStops = ProgressiveHero.blurMeltMask(hero.profile)
            let veilStops = ProgressiveHero.veilMeltMask(hero.profile)
            let clip = hero.layout.clip
            let at = { (location: Double) in
                ProgressiveHero.layers(at: location, clip: clip, copy: copyStops, veil: veilStops)
            }
            // Nothing left at the frame's bottom edge, nor past it.
            #expect(at(1).coverage == 0, "\(hero.name)")
            #expect(at(1.01).coverage == 0, "\(hero.name)")
            // Fully covered down to where the melt starts, then only ever fading — every layer, and the whole.
            #expect(at(hero.profile.meltStart).coverage > 1 - 1e-9, "\(hero.name)")
            var previous = at(hero.profile.meltStart)
            for i in 1 ... 400 {
                let location = hero.profile.meltStart + (1 - hero.profile.meltStart) * Double(i) / 400
                let layers = at(location)
                #expect(layers.copy <= previous.copy + 1e-12, "\(hero.name) copy at \(location)")
                #expect(layers.veil <= previous.veil + 1e-12, "\(hero.name) veil at \(location)")
                #expect(layers.coverage <= previous.coverage + 1e-12, "\(hero.name) at \(location)")
                previous = layers
            }
            // The fade lands softly: by the last 2 % of the hero almost nothing is left to remove.
            #expect(at(0.98).coverage < 0.02, "\(hero.name)")
        }
    }

    @Test func playerMeltIsLongEnoughToBeGentle() {
        for hero in Self.heroes where hero.profile == .player {
            let melt = hero.layout.heroHeight * (1 - hero.profile.meltStart)
            #expect(melt >= 120, "\(hero.name): melts over \(melt) pt")
            // The title's top (where the copy is fully in) sits above the melt, so the melt runs under the title and
            // the controls, which are drawn over it.
            #expect(hero.layout.sharpHeight <= hero.layout.heroHeight * hero.profile.meltStart, "\(hero.name)")
        }
    }

    @Test func blurredCopyCoversTheWholeHero() {
        // The copy square plus its mirror reach from the hero's top to its bottom, whatever the screen.
        for hero in Self.heroes {
            let copy = ProgressiveHero.copyLayout(width: hero.width, sharpHeight: hero.layout.sharpHeight,
                                                  heroHeight: hero.layout.heroHeight)
            #expect(copy.top <= 0, "\(hero.name)")
            #expect(copy.top + copy.side * (copy.mirrors ? 2 : 1) >= hero.layout.heroHeight, "\(hero.name)")
            // Lined up with the sharp art (a square at the larger side, centred on the sharp part).
            #expect(copy.side == max(hero.width, hero.layout.sharpHeight))
        }
    }

    @Test func compositeModelMatchesTheStack() {
        let layers = ProgressiveHero.Layers(sharp: 0, copy: 0.5, veil: 0.5)
        #expect(layers.coverage == 0.75)
        #expect(layers.composite(sharpValue: 1, copyValue: 1, veilValue: 0, background: 0) == 0.25)
        // Outside the frame nothing is drawn.
        let stops = [ProgressiveHero.Stop(location: 0, opacity: 1), .init(location: 1, opacity: 1)]
        #expect(ProgressiveHero.layers(at: 1.2, clip: 0.5, copy: stops, veil: stops).coverage == 0)
        #expect(ProgressiveHero.layers(at: 0.4, clip: 0.5, copy: stops, veil: stops).sharp == 1)
        #expect(ProgressiveHero.layers(at: 0.5, clip: 0.5, copy: stops, veil: stops).sharp == 0)
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
