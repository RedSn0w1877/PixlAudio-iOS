import Foundation
import Testing
@testable import PixlLibrary

/// The same seeded stream the Android tests use (SplitMix64; `int(bound)` = `(next >>> 1) % bound`), so a seed gives the same
/// numbers on both platforms. Also used by the image-side tests.
struct RingRng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }

    mutating func nextLong() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ bound: Int) -> Int { Int((nextLong() >> 1) % UInt64(bound)) }
    mutating func signedLong() -> Int64 { Int64(bitPattern: nextLong()) }
    /// A random byte the way the Kotlin tests take one: `(nextLong() ushr shift).toInt().toByte()`.
    mutating func byte(shift: UInt64 = 8) -> UInt8 { UInt8(truncatingIfNeeded: nextLong() >> shift) }
}

/// Hand-written tests of the ring code's pure core (the Android `RingCoreTest.kt` in Swift Testing). The golden files cover the
/// same functions with Android's numbers (`RingGoldenTests`); these state the rules. The big fuzz loops run fewer rounds than
/// Android's (Swift Testing runs in debug on the CI), the rest is the same.
@Suite("Pixl ring code core")
struct RingCoreTests {
    // MARK: Layout

    @Test func twoHundredSlotsInFiveRingsTwentyFiveBytesOfEightSlots() {
        #expect(RingCodeLayout.ringSlots.reduce(0, +) == 200)
        #expect(RingCodeLayout.slots == RingCodeLayout.bytes * 8)
        var first = 0
        for r in 0..<5 {
            #expect(RingCodeLayout.ringFirstSlot[r] == first)
            first += RingCodeLayout.ringSlots[r]
            #expect(RingCodeLayout.ringSlots[r] % 8 == 0, "a byte never straddles two rings")
        }
    }

    @Test func everySlotHasOneRingOneIndexOneByteBit() {
        var seen = Set<Int>()
        for slot in 0..<200 {
            let ring = RingCodeLayout.ringOf(slot)
            let index = RingCodeLayout.indexInRing(slot)
            #expect(RingCodeLayout.slotOf(ring: ring, index: index) == slot)
            #expect(seen.insert(RingCodeLayout.byteOfSlot(slot) * 8 + RingCodeLayout.bitOfSlot(slot)).inserted)
            // The eight slots of a byte are neighbours on one ring.
            if slot % 8 > 0 { #expect(RingCodeLayout.ringOf(slot - 1) == ring) }
        }
        #expect(seen.count == 200)
    }

    @Test func slotZeroOfEveryRingIsAtTwelveOClockAndAnglesRunClockwise() {
        for r in 0..<5 {
            #expect(RingCodeLayout.angleMicroTurns(RingCodeLayout.slotOf(ring: r, index: 0)) == 0)
            let n = RingCodeLayout.ringSlots[r]
            #expect(RingCodeLayout.angleMicroTurns(RingCodeLayout.slotOf(ring: r, index: n / 2)) == 500_000)
            #expect(RingCodeLayout.angleMicroTurns(RingCodeLayout.slotOf(ring: r, index: n - 1)) < 1_000_000)
        }
    }

    @Test func geometryNeverOverlaps() {
        // dots neither touch each other along a ring nor across rings, with a margin for blur
        for r in 0..<5 {
            let arc = 2 * 314_159 * RingCodeLayout.ringRadius[r] / 100_000 / RingCodeLayout.ringSlots[r] // ~ 2*pi*R/N
            #expect(arc - 2 * RingCodeLayout.bigRadius >= 20, "ring \(r) gap \(arc - 2 * RingCodeLayout.bigRadius)")
        }
        for r in 1..<5 { #expect(RingCodeLayout.ringRadius[r] - RingCodeLayout.ringRadius[r - 1] - 2 * RingCodeLayout.bigRadius >= 25) }
        #expect(RingCodeLayout.ringRadius[0] - RingCodeLayout.bigRadius - RingCodeLayout.bezelOuter >= 50)
        #expect(RingCodeLayout.markerRadiusAt - RingCodeLayout.markerRadius - (RingCodeLayout.ringRadius[4] + RingCodeLayout.bigRadius) >= 10)
        #expect(RingCodeLayout.markerRadiusAt + RingCodeLayout.markerRadius <= 960)
        #expect(2 * RingCodeLayout.smallRadius == RingCodeLayout.bigRadius)
    }

    @Test func codewordAndSlotsRoundTrip() {
        var rng = RingRng(1)
        for _ in 0..<200 {
            let w = (0..<25).map { _ in rng.byte(shift: 9) }
            #expect(RingCodeLayout.slotsToCodeword(RingCodeLayout.codewordToSlots(w)) == w)
        }
    }

    /// The spec's map spreads a neighbouring smudge over every byte; the grouped map keeps it to a few.
    @Test func aSmudgeOfNeighbouringSlotsTouchesFewBytesWithTheGroupedMap() {
        var worstGrouped = 0
        var worstSpec = 0
        for ring in 0..<5 {
            let n = RingCodeLayout.ringSlots[ring]
            let smudge = n / 5 // 20 percent of the ring
            for start in 0..<n {
                let first = RingCodeLayout.slotOf(ring: ring, index: start)
                worstGrouped = max(worstGrouped, RingCodeLayout.bytesTouched(first: first, count: smudge, byteOf: RingCodeLayout.byteOfSlot))
                worstSpec = max(worstSpec, RingCodeLayout.bytesTouched(first: first, count: smudge, byteOf: RingCodeLayout.specByteOfSlot))
            }
        }
        // 20 percent of the outer ring is 11 slots: at most 3 bytes grouped, 11 bytes with the spec's map.
        #expect(worstGrouped <= 3, "grouped \(worstGrouped)")
        #expect(worstSpec >= 11, "spec \(worstSpec)")
        // A smudge over 20 percent of the whole code (40 neighbouring slots across rings) stays under 14 bytes grouped.
        var worstWedge = 0
        for start in 0..<56 { worstWedge = max(worstWedge, wedgeBytes(startOuter: start, widthMicroTurns: 72_000, byteOf: RingCodeLayout.byteOfSlot)) }
        #expect(worstWedge <= 14, "a 72 degree wedge touches \(worstWedge) bytes")
    }

    /// Bytes touched by the slots whose angle falls in a wedge of `widthMicroTurns`/1e6 of a turn starting at outer slot `startOuter`.
    private func wedgeBytes(startOuter: Int, widthMicroTurns: Int, byteOf: (Int) -> Int) -> Int {
        let begin = startOuter * 1_000_000 / 56
        var seen = [Bool](repeating: false, count: 25)
        for slot in 0..<200 {
            let a = RingCodeLayout.angleMicroTurns(slot)
            let d = ((a - begin) % 1_000_000 + 1_000_000) % 1_000_000
            if d < widthMicroTurns { seen[byteOf(slot)] = true }
        }
        return seen.filter { $0 }.count
    }

    // MARK: Reed-Solomon

    private func randomData(_ rng: inout RingRng) -> [UInt8] { (0..<11).map { _ in rng.byte(shift: 7) } }

    private func positions(_ n: Int, _ rng: inout RingRng) -> [Int] {
        var out: [Int] = []
        while out.count < n {
            let p = rng.int(25)
            if !out.contains(p) { out.append(p) }
        }
        return out
    }

    @Test func fieldBasics() {
        #expect(Gf256.mul(1, 1) == 1)
        #expect(Gf256.mul(0x80, 2) == 0x1D)
        for a in 1...255 { #expect(Gf256.mul(a, Gf256.inv(a)) == 1) }
        for a in 1...255 { for b in [1, 2, 3, 0x1D, 0xFF] { #expect(Gf256.div(Gf256.mul(a, b), b) == a) } }
        #expect(Gf256.alphaPow(3) == Gf256.alphaPow(3 + 255))
        #expect(Gf256.mul(Gf256.alphaPow(-7), Gf256.alphaPow(7)) == 1)
    }

    @Test func encodeIsSystematicAndGivesACodeword() {
        var rng = RingRng(0xC0DE)
        for _ in 0..<200 {
            let data = randomData(&rng)
            let w = ReedSolomon.encode(data)
            #expect(w.count == 25)
            #expect(Array(w[0..<11]) == data)
            #expect(ReedSolomon.isCodeword(w))
        }
    }

    @Test func correctsEveryPatternOfUpToSevenByteErrors() {
        var rng = RingRng(0xC0DE)
        var trials = 0
        for errors in 0...7 {
            for _ in 0..<300 {
                let w = ReedSolomon.encode(randomData(&rng))
                var bad = w
                for p in positions(errors, &rng) { bad[p] ^= UInt8(1 + rng.int(255)) }
                let r = ReedSolomon.decode(bad)
                #expect(r.ok, "errors=\(errors)")
                #expect(r.codeword == w)
                #expect(r.corrected == errors)
                trials += 1
            }
        }
        #expect(trials == 2400)
    }

    @Test func correctsUpToFourteenErasuresAndAnyMixWithTwoEPlusSAtMostFourteen() {
        var rng = RingRng(0xC0DE &+ 1)
        for s in 0...14 {
            for _ in 0..<60 {
                let w = ReedSolomon.encode(randomData(&rng))
                let er = positions(s, &rng)
                var bad = w
                for p in er { bad[p] = rng.byte(shift: 5) }
                let r = ReedSolomon.decode(bad, erasures: er)
                #expect(r.ok, "erasures=\(s)")
                #expect(r.codeword == w)
            }
        }
        for e in 1...7 {
            for s in 0...(14 - 2 * e) {
                for _ in 0..<20 {
                    let w = ReedSolomon.encode(randomData(&rng))
                    let all = positions(e + s, &rng)
                    var bad = w
                    for i in 0..<e { bad[all[i]] ^= UInt8(1 + rng.int(255)) }
                    let er = Array(all[e...])
                    for p in er { bad[p] = rng.byte(shift: 5) }
                    let r = ReedSolomon.decode(bad, erasures: er)
                    #expect(r.ok, "e=\(e) s=\(s)")
                    #expect(r.codeword == w)
                }
            }
        }
    }

    @Test func anErasureWhoseValueHappensToBeRightCostsNothing() {
        var rng = RingRng(7)
        let w = ReedSolomon.encode(randomData(&rng))
        let r = ReedSolomon.decode(w, erasures: [0, 5, 24])
        #expect(r.ok)
        #expect(r.codeword == w)
    }

    /// Beyond capacity the decoder may fail or (very rarely) land on another codeword; it must never crash and never return a non-codeword.
    @Test func fuzzBeyondCapacityNeverCrashesAndNeverReturnsANonCodeword() {
        var rng = RingRng(0xC0DE &+ 2)
        var failed = 0
        var miscorrected = 0
        let n = 3000
        for _ in 0..<n {
            let w = ReedSolomon.encode(randomData(&rng))
            var bad = w
            let errors = 8 + rng.int(18)
            for p in positions(errors, &rng) { bad[p] ^= UInt8(1 + rng.int(255)) }
            let r = ReedSolomon.decode(bad)
            if !r.ok { failed += 1 } else {
                #expect(ReedSolomon.isCodeword(r.codeword ?? []))
                if r.codeword != w { miscorrected += 1 }
            }
        }
        #expect(failed > n * 9 / 10, "failed \(failed) of \(n)")
        #expect(miscorrected <= 3, "miscorrected \(miscorrected)")
    }

    @Test func garbageAndOddInputNeverCrash() {
        var rng = RingRng(0xC0DE &+ 3)
        for _ in 0..<2000 {
            let junk = (0..<25).map { _ in rng.byte(shift: 3) }
            let s = rng.int(17)
            let er = (0..<s).map { _ in rng.int(27) - 1 } // may be out of range or duplicated
            _ = ReedSolomon.decode(junk, erasures: er)
            _ = ReedSolomon.decode(junk)
        }
        #expect(!ReedSolomon.decode([UInt8](repeating: 0, count: 24)).ok)
        #expect(!ReedSolomon.decode([UInt8](repeating: 0, count: 26)).ok)
        #expect(!ReedSolomon.decode([UInt8](repeating: 0, count: 25), erasures: Array(0..<15)).ok)
        #expect(!ReedSolomon.decode([UInt8](repeating: 0, count: 25), erasures: [3, 3]).ok)
        #expect(!ReedSolomon.decode([UInt8](repeating: 0, count: 25), erasures: [25]).ok)
        #expect(ReedSolomon.decode([UInt8](repeating: 0, count: 25)).ok) // all zeros is the zero codeword
    }

    // MARK: Payload

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    private func randomId(_ rng: inout RingRng) -> String { String((0..<11).map { _ in Self.alphabet[rng.int(64)] }) }

    @Test func packAndUnpackRoundTripForRandomIdsAndTags() {
        var rng = RingRng(0xFACE)
        for _ in 0..<2000 {
            let id = randomId(&rng)
            let bucket = rng.int(64)
            let random = rng.int(256)
            let packed = RingCodePayloads.pack(videoId: id, minuteBucket: bucket, random: random)
            #expect(packed?.count == 11)
            guard let packed else { continue }
            #expect(RingCodePayloads.unpack(packed) == .ok(RingCodePayload(videoId: id, minuteBucket: bucket, random: random)))
        }
    }

    @Test func everyAlphabetCharacterSurvives() {
        let id = String(Self.alphabet[0..<11])
        #expect(RingCodePayloads.unpack(RingCodePayloads.pack(videoId: id, minuteBucket: 5, random: 5) ?? []) == .ok(RingCodePayload(videoId: id, minuteBucket: 5, random: 5)))
        for c in Self.alphabet {
            let one = String(repeating: String(c), count: 11)
            let r = RingCodePayloads.unpack(RingCodePayloads.pack(videoId: one, minuteBucket: 0, random: 0) ?? [])
            #expect(r == .ok(RingCodePayload(videoId: one, minuteBucket: 0, random: 0)))
        }
    }

    @Test func invalidInputIsRefused() {
        #expect(RingCodePayloads.pack(videoId: "short", minuteBucket: 1, random: 1) == nil)
        #expect(RingCodePayloads.pack(videoId: "dQw4w9WgXcQQ", minuteBucket: 1, random: 1) == nil)
        #expect(RingCodePayloads.pack(videoId: "dQw4w9WgX.Q", minuteBucket: 1, random: 1) == nil)
        #expect(RingCodePayloads.pack(videoId: "dQw4w9WgXcQ", minuteBucket: 64, random: 1) == nil)
        #expect(RingCodePayloads.pack(videoId: "dQw4w9WgXcQ", minuteBucket: -1, random: 1) == nil)
        #expect(RingCodePayloads.pack(videoId: "dQw4w9WgXcQ", minuteBucket: 1, random: 256) == nil)
        #expect(RingCodePayloads.pack(videoId: "dQw4w9WgXcQ", minuteBucket: 1, random: -1) == nil)
        #expect(RingCodePayloads.pack(videoId: "dQw4w9WgXcQ", minuteBucket: 63, random: 255) != nil)
        #expect(RingCodePayloads.unpack([UInt8](repeating: 0, count: 10)) == .rejected(.badLength))
        #expect(RingCodePayloads.unpack([UInt8](repeating: 0, count: 12)) == .rejected(.badLength))
    }

    @Test func anySingleBitFlipIsCaughtByTheChecksum() {
        // 88 bits: the first 80 are covered by the checksum, so every flip there is rejected.
        let packed = RingCodePayloads.pack(videoId: "dQw4w9WgXcQ", minuteBucket: 17, random: 99) ?? []
        for bit in 0..<88 {
            var f = packed
            f[bit / 8] ^= UInt8(0x80) >> UInt8(bit % 8)
            if case .ok = RingCodePayloads.unpack(f) { Issue.record("bit \(bit) was not rejected") }
        }
    }

    @Test func fuzzRandomElevenByteWordsAreRejectedAbout255TimesIn256() {
        var rng = RingRng(0xFACE &+ 1)
        var ok = 0
        let n = 40_000
        for _ in 0..<n {
            let junk = (0..<11).map { _ in rng.byte(shift: 11) }
            if case .ok = RingCodePayloads.unpack(junk) { ok += 1 }
        }
        // expectation n/256 = 156
        #expect(ok >= 90 && ok <= 240, "accepted \(ok) of \(n)")
    }

    @Test func bucketsFollowTheClock() {
        #expect(RingCodePayloads.bucketOf(nowMs: 0) == 0)
        #expect(RingCodePayloads.bucketOf(nowMs: 59_999) == 0)
        #expect(RingCodePayloads.bucketOf(nowMs: 60_000) == 1)
        #expect(RingCodePayloads.bucketOf(nowMs: 63 * 60_000) == 63)
        #expect(RingCodePayloads.bucketOf(nowMs: 64 * 60_000) == 0)
        #expect(RingCodePayloads.bucketOf(nowMs: -1) == 63)
    }

    @Test func freshnessWindowAndClockSkew() {
        let base: Int64 = 1_763_600_000_000
        let bucket = RingCodePayloads.bucketOf(nowMs: base)
        func at(_ minutes: Int64, _ secondsIn: Int64 = 0) -> Int64 { base - base % 60_000 + minutes * 60_000 + secondsIn * 1000 }
        // The receiver's clock, in minutes after the code's minute.
        #expect(RingCodePayloads.freshness(bucket: bucket, nowMs: at(-2)) == .future)
        #expect(RingCodePayloads.freshness(bucket: bucket, nowMs: at(-1)) == .fresh) // receiver one minute behind
        #expect(RingCodePayloads.freshness(bucket: bucket, nowMs: at(0)) == .fresh)
        #expect(RingCodePayloads.freshness(bucket: bucket, nowMs: at(1)) == .fresh)
        #expect(RingCodePayloads.freshness(bucket: bucket, nowMs: at(2, 59)) == .fresh)
        #expect(RingCodePayloads.freshness(bucket: bucket, nowMs: at(3)) == .expired)
        #expect(RingCodePayloads.freshness(bucket: bucket, nowMs: at(30)) == .expired)
        // A code made at the very end of a minute lives just over two minutes.
        let madeAt = at(0, 59)
        let madeBucket = RingCodePayloads.bucketOf(nowMs: madeAt)
        #expect(RingCodePayloads.freshness(bucket: madeBucket, nowMs: madeAt + 120_000) == .fresh)
        #expect(RingCodePayloads.freshness(bucket: madeBucket, nowMs: madeAt + 180_000) == .expired)
        // Bucket arithmetic wraps at 64.
        #expect(RingCodePayloads.freshness(bucket: 63, nowMs: 64 * 60_000 + 1_000) == .fresh)
        #expect(RingCodePayloads.freshness(bucket: 0, nowMs: 63 * 60_000 + 1_000) == .fresh)
    }

    @Test func theWholeWordRoundTripsThroughSlotsAndADamagedCopy() {
        var rng = RingRng(0xFACE &+ 2)
        for _ in 0..<150 {
            let id = randomId(&rng)
            let bucket = rng.int(64)
            let random = rng.int(256)
            guard var damaged = RingCodePayloads.encodeSlots(videoId: id, minuteBucket: bucket, random: random) else {
                Issue.record("no slots for \(id)")
                continue
            }
            // flip up to 7 isolated slots, each inside a different byte
            var bytes = Array(0..<25)
            for i in 0..<7 { bytes.swapAt(i, i + rng.int(25 - i)) }
            for b in bytes.prefix(7) {
                let slot = b * 8 + rng.int(8)
                damaged[slot] = 1 - damaged[slot]
            }
            let rs = ReedSolomon.decode(RingCodeLayout.slotsToCodeword(damaged))
            #expect(rs.ok)
            #expect(RingCodePayloads.fromCodeword(rs.codeword ?? []) == .ok(RingCodePayload(videoId: id, minuteBucket: bucket, random: random)))
        }
    }

    /// A decode that leans on erasures can accept a wrong word; the checksum is what catches it. The scanner uses at most 10.
    @Test func erasureHeavyDecodesOfAWrongWordAreCaught() {
        var rng = RingRng(0xFACE &+ 3)
        var wrongByRs = 0
        var wrongPassing10 = 0
        let n = 3000
        for _ in 0..<n {
            let id = randomId(&rng)
            guard let word = RingCodePayloads.encodeCodeword(videoId: id, minuteBucket: rng.int(64), random: rng.int(256)),
                  case .ok(let original) = RingCodePayloads.unpack(Array(word[0..<11])) else { continue }
            var order = Array(0..<25)
            for i in 0..<24 { order.swapAt(i, i + rng.int(25 - i)) }
            // 14 erasures plus one wrong byte among the 11 that remain: RS cannot see it, the checksum must
            var bad = word
            bad[order[14]] ^= UInt8(1 + rng.int(255))
            let r14 = ReedSolomon.decode(bad, erasures: Array(order[0..<14]))
            if r14.ok && r14.codeword != word { wrongByRs += 1 }
            // 10 erasures plus three wrong bytes: beyond 2e + s <= 14 (the scanner never flags more than 10)
            var bad10 = word
            for k in 10...12 { bad10[order[k]] ^= UInt8(1 + rng.int(255)) }
            let r10 = ReedSolomon.decode(bad10, erasures: Array(order[0..<10]))
            if r10.ok, let cw = r10.codeword, cw != word, case .ok(let u) = RingCodePayloads.fromCodeword(cw), u != original { wrongPassing10 += 1 }
        }
        #expect(wrongByRs > n / 2)
        #expect(wrongPassing10 <= 1, "\(wrongPassing10) wrong words passed")
    }

    /// The scanner's whole decision chain on a heavily damaged word: never a wrong id without a flag.
    @Test func fuzzDamagedCodesDecodeToTheRightPayloadOrAreRefused() {
        var rng = RingRng(0xFACE &+ 4)
        var right = 0
        var refused = 0
        let n = 8000
        for _ in 0..<n {
            let id = randomId(&rng)
            let bucket = rng.int(64)
            let random = rng.int(256)
            guard let word = RingCodePayloads.encodeCodeword(videoId: id, minuteBucket: bucket, random: random) else { continue }
            var bad = word
            let errors = 8 + rng.int(10)
            var seen = Set<Int>()
            while seen.count < errors { seen.insert(rng.int(25)) }
            for p in seen.sorted() { bad[p] ^= UInt8(1 + rng.int(255)) }
            let rs = ReedSolomon.decode(bad)
            guard rs.ok, let cw = rs.codeword else { refused += 1; continue }
            switch RingCodePayloads.fromCodeword(cw) {
            case .rejected: refused += 1
            case .ok(let got):
                #expect(got == RingCodePayload(videoId: id, minuteBucket: bucket, random: random), "a damaged code was taken for a different song")
                right += 1
            }
        }
        #expect(right + refused == n)
    }

    // MARK: Timeline

    private func frame(_ t: Int64, _ a: Int64 = RingCodeTimeline.none, _ ae: Int64 = RingCodeTimeline.none,
                       _ b: Int64 = RingCodeTimeline.none, reduced: Bool = false) -> RingFrameBuffer {
        RingCodeTimeline.frame(tMs: t, approachStartMs: a, approachEndMs: ae, beamStartMs: b, reducedMotion: reduced)
    }

    @Test func idleSwaysBreathesAndNeverLeavesItsRange() {
        var maxAngle = 0
        var t: Int64 = 0
        while t < 48_000 {
            let f = frame(t)
            #expect(f.codeScale == 1000)
            #expect(f.glow == 0)
            #expect(f.plateAlpha == 1000)
            #expect(f.artScale >= 990 && f.artScale <= 1010, "breath \(f.artScale)")
            #expect(Int64(abs(f.codeAngle)) <= RingCodeTimeline.swayAmplitudeMicroRad)
            maxAngle = max(maxAngle, abs(f.codeAngle))
            t += 37
        }
        #expect(maxAngle > 1_300_000)
        #expect(frame(0).codeAngle == 0)
        #expect(frame(RingCodeTimeline.swayPeriodMs).codeAngle == 0)
        #expect(frame(5_000).codeAngle == frame(5_000 + RingCodeTimeline.swayPeriodMs).codeAngle)
        // continuous: neighbouring milliseconds differ by little (speed under 0.5 rad/s)
        var t2: Int64 = 0
        while t2 < 24_000 {
            #expect(abs(frame(t2 + 1).codeAngle - frame(t2).codeAngle) < 400)
            t2 += 13
        }
    }

    @Test func approachTightensByEightPercentAndGlowsThenRelaxes() {
        #expect(frame(1800, 1800).codeScale == 1000)
        let full = frame(1800 + 800, 1800)
        #expect(full.codeScale == 920)
        #expect(full.glow == 700)
        #expect(full.phase == 1)
        let mid = frame(1800 + 400, 1800)
        #expect(mid.codeScale >= 921 && mid.codeScale <= 999)
        let gone = frame(2600 + 400, 1800, 2600)
        #expect(gone.codeScale == 1000)
        #expect(gone.glow == 0)
        #expect(gone.phase == 0)
        var last = 1001
        var t: Int64 = 1800
        while t <= 2600 {
            let s = frame(t, 1800).codeScale
            #expect(s <= last)
            last = s
            t += 20
        }
    }

    @Test func theBeamPeelsTheOuterRingFirstAndEverythingLands() {
        let start: Int64 = 3400
        #expect(RingCodeTimeline.slotStartMs(ring: 4, index: 0) < RingCodeTimeline.slotStartMs(ring: 3, index: 0) + 70)
        for ring in 0..<4 {
            let outerMax = (0..<RingCodeLayout.ringSlots[ring + 1]).map { RingCodeTimeline.slotStartMs(ring: ring + 1, index: $0) }.max() ?? 0
            let innerMin = (0..<RingCodeLayout.ringSlots[ring]).map { RingCodeTimeline.slotStartMs(ring: ring, index: $0) }.min() ?? 0
            #expect(RingCodeTimeline.slotStartMs(ring: ring + 1, index: 0) < RingCodeTimeline.slotStartMs(ring: ring, index: 0), "ring order")
            #expect(Int64(outerMax) < Int64(innerMin) + RingCodeTimeline.ringStaggerMs + RingCodeTimeline.inRingSpreadMs)
        }
        var lastStart = 0
        for ring in 0..<5 {
            for i in 0..<RingCodeLayout.ringSlots[ring] {
                let s = RingCodeTimeline.slotStartMs(ring: ring, index: i)
                lastStart = max(lastStart, s)
                #expect(RingCodeTimeline.slotProgress(ring: ring, index: i, beamMs: s) == 0)
                #expect(RingCodeTimeline.slotProgress(ring: ring, index: i, beamMs: s + 800) == 1000)
            }
        }
        #expect(lastStart + 800 < 1300, "all dots are in before the art lifts")
        let f0 = frame(start, 1800, RingCodeTimeline.none, start)
        #expect(f0.phase == 2)
        #expect(f0.plateAlpha == 1000)
        let f1 = frame(start + 1000, 1800, RingCodeTimeline.none, start)
        #expect(f1.plateAlpha == 0)
        #expect(f1.glow < f0.glow + 700)
        // the art pulses 10 percent, then flies off the top at 0.38
        var peak = 0
        var dt: Int64 = 600
        while dt <= 1400 {
            peak = max(peak, frame(start + dt, 1800, RingCodeTimeline.none, start).artScale)
            dt += 10
        }
        #expect(peak == 1100)
        let end = frame(start + 2000, 1800, RingCodeTimeline.none, start)
        #expect(end.artScale == 380)
        #expect(end.artTranslateY == -1100)
        #expect(end.artAlpha == 0)
        let done = frame(start + 2150, 1800, RingCodeTimeline.none, start)
        #expect(done.pillAlpha == 1000)
        #expect(done.phase == 3)
        #expect(frame(start + 1000, RingCodeTimeline.none, RingCodeTimeline.none, start).pillAlpha == 0)
    }

    @Test func reduceMotionOnlyCrossFades() {
        let b: Int64 = 1000
        var t: Int64 = 0
        while t <= 3000 {
            let f = frame(t, 100, RingCodeTimeline.none, b, reduced: true)
            #expect(f.codeAngle == 0)
            #expect(f.codeScale == 1000)
            #expect(f.glow == 0)
            #expect(f.artScale == 1000)
            #expect(f.artTranslateY == 0)
            #expect(f.codeAlpha + f.pillAlpha == 1000, "cross-fade at \(t)")
            t += 25
        }
        #expect(frame(1000, RingCodeTimeline.none, RingCodeTimeline.none, 1000, reduced: true).pillAlpha == 0)
        #expect(frame(1150, RingCodeTimeline.none, RingCodeTimeline.none, 1000, reduced: true).pillAlpha == 1000)
        #expect(RingCodeTimeline.beamTotal(reducedMotion: true) == 150)
        #expect(RingCodeTimeline.beamTotal(reducedMotion: false) == 2150)
    }

    @Test func framesArePureAndFillTheBufferWithoutLeftovers() {
        var buf = RingFrameBuffer()
        RingCodeTimeline.frameInto(tMs: 5000, approachStartMs: 1800, approachEndMs: RingCodeTimeline.none, beamStartMs: 3400, reducedMotion: false, out: &buf)
        let first = buf.describe()
        RingCodeTimeline.frameInto(tMs: 10, approachStartMs: RingCodeTimeline.none, approachEndMs: RingCodeTimeline.none, beamStartMs: RingCodeTimeline.none, reducedMotion: false, out: &buf)
        RingCodeTimeline.frameInto(tMs: 5000, approachStartMs: 1800, approachEndMs: RingCodeTimeline.none, beamStartMs: 3400, reducedMotion: false, out: &buf)
        #expect(buf.describe() == first)
    }
}
