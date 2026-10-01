import Foundation
import Testing
@testable import PixlAudioCore

/// Port of `data/tais/dsp/FftWorkspaceTest` (all 7 cases) plus Swift-only checks.
@Suite("Fft")
struct FftTests {
    static func signal(_ size: Int, _ seed: Int) -> [Float] {
        (0..<size).map { (index: Int) -> Float in
            let a: Double = Double((index + 1) * (seed + 1)) * 0.017
            let b: Double = Double((index + 3) * (seed + 2)) * 0.031
            let value: Double = sin(a) * 0.65 + cos(b) * 0.2
            return Float(value)
        }
    }

    /// Independent double-precision definition, deliberately not another FFT implementation.
    static func directDft(_ re: [Float], _ im: [Float], inverse: Bool) -> ([Float], [Float]) {
        let size = re.count
        var outRe = [Float](repeating: 0, count: size)
        var outIm = [Float](repeating: 0, count: size)
        for frequency in 0..<size {
            var real = 0.0
            var imaginary = 0.0
            for sample in 0..<size {
                let angle = (inverse ? 2.0 : -2.0) * Double.pi * Double(frequency) * Double(sample) / Double(size)
                real += Double(re[sample]) * cos(angle) - Double(im[sample]) * sin(angle)
                imaginary += Double(re[sample]) * sin(angle) + Double(im[sample]) * cos(angle)
            }
            outRe[frequency] = Float(real / (inverse ? Double(size) : 1))
            outIm[frequency] = Float(imaginary / (inverse ? Double(size) : 1))
        }
        return (outRe, outIm)
    }

    static func bits(_ a: [Float]) -> [UInt32] { a.map(\.bitPattern) }

    static func close(_ a: [Float], _ b: [Float], _ tolerance: Float) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    // `reused workspace matches direct complex DFT in both directions`
    @Test func reusedWorkspaceMatchesDirectComplexDftInBothDirections() throws {
        for size in [1, 2, 6, 7, 15, 64] {
            var workspace = try Fft.Workspace(size: size)
            for frame in 0...2 {
                for inverse in [false, true] {
                    var re = Self.signal(size, frame)
                    var im = Self.signal(size, frame + 3)
                    let expected = Self.directDft(re, im, inverse: inverse)
                    try workspace.transform(re: &re, im: &im, inverse: inverse)
                    #expect(Self.close(re, expected.0, 0.0002), "size \(size) frame \(frame) inverse \(inverse)")
                    #expect(Self.close(im, expected.1, 0.0002), "size \(size) frame \(frame) inverse \(inverse)")
                }
            }
        }
    }

    // `production size reuse is bit exact against fresh scratch across frames`
    @Test func productionSizeReuseIsBitExactAgainstFreshScratchAcrossFrames() throws {
        let size = 6144
        var workspace = try Fft.Workspace(size: size)
        for frame in 0...4 {
            for inverse in [false, true] {
                var re: [Float]
                switch frame {
                case 1: re = [Float](repeating: 0, count: size)
                case 3:
                    re = [Float](repeating: 0, count: size)
                    re[size - 1] = 1
                default: re = Self.signal(size, frame)
                }
                var im = frame == 1 ? [Float](repeating: 0, count: size) : Self.signal(size, frame + 5)
                var expectedRe = re
                var expectedIm = im
                Fft.transform(re: &expectedRe, im: &expectedIm, inverse: inverse)
                try workspace.transform(re: &re, im: &im, inverse: inverse)
                #expect(Self.bits(expectedRe) == Self.bits(re))
                #expect(Self.bits(expectedIm) == Self.bits(im))
            }
        }
    }

    // `production size forward inverse roundtrip preserves stereo frame samples`
    @Test func productionSizeForwardInverseRoundtripPreservesSamples() throws {
        var workspace = try Fft.Workspace(size: 6144)
        for frame in 0..<4 {
            let expectedRe = Self.signal(6144, frame)
            let expectedIm = Self.signal(6144, frame + 7)
            var re = expectedRe
            var im = expectedIm
            try workspace.transform(re: &re, im: &im, inverse: false)
            try workspace.transform(re: &re, im: &im, inverse: true)
            // The Float radix-2 convolution accumulates rounding over 16K points.
            #expect(Self.close(expectedRe, re, 0.004))
            #expect(Self.close(expectedIm, im, 0.004))
        }
    }

    // `silence after dense frame leaves no previous convolution data`
    @Test func silenceAfterDenseFrameLeavesNoPreviousConvolutionData() throws {
        var workspace = try Fft.Workspace(size: 6144)
        var dRe = Self.signal(6144, 3), dIm = Self.signal(6144, 4)
        try workspace.transform(re: &dRe, im: &dIm, inverse: false)
        for inverse in [false, true] {
            var re = [Float](repeating: 0, count: 6144)
            var im = [Float](repeating: 0, count: 6144)
            try workspace.transform(re: &re, im: &im, inverse: inverse)
            #expect(re.allSatisfy { $0 == 0 })
            #expect(im.allSatisfy { $0 == 0 })
        }
    }

    // `parallel renders have independent scratch and safely initialize plans`
    @Test func parallelRendersHaveIndependentScratchAndSafelyInitializePlans() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (worker, size) in [6144, 93, 186, 6144].enumerated() {
                group.addTask {
                    var workspace = try Fft.Workspace(size: size)
                    for frame in 0..<3 {
                        var re = Self.signal(size, worker + frame)
                        var im = Self.signal(size, worker + frame + 9)
                        var expectedRe = re
                        var expectedIm = im
                        Fft.transform(re: &expectedRe, im: &expectedIm, inverse: frame % 2 == 0)
                        try workspace.transform(re: &re, im: &im, inverse: frame % 2 == 0)
                        #expect(Self.bits(expectedRe) == Self.bits(re))
                        #expect(Self.bits(expectedIm) == Self.bits(im))
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    // `accidentally shared workspace serializes concurrent transforms`: Swift workspaces are values, so "sharing"
    // one hands every task its own copy; the copies must not interfere and must stay bit-exact.
    @Test func copiedWorkspaceUsedConcurrentlyStaysBitExact() async throws {
        let shared = try Fft.Workspace(size: 6144)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for frame in 0...7 {
                group.addTask {
                    var workspace = shared
                    var re = Self.signal(6144, frame)
                    var im = Self.signal(6144, frame + 2)
                    var expectedRe = re
                    var expectedIm = im
                    Fft.transform(re: &expectedRe, im: &expectedIm, inverse: frame % 2 == 0)
                    try workspace.transform(re: &re, im: &im, inverse: frame % 2 == 0)
                    #expect(Self.bits(expectedRe) == Self.bits(re))
                    #expect(Self.bits(expectedIm) == Self.bits(im))
                }
            }
            try await group.waitForAll()
        }
    }

    // `wrong workspace sizes fail before touching input`
    @Test func wrongWorkspaceSizesFailBeforeTouchingInput() throws {
        #expect(throws: FftError.nonPositiveSize(0)) { try Fft.Workspace(size: 0) }
        var workspace = try Fft.Workspace(size: 6)
        var re = Self.signal(6, 0)
        var im = Self.signal(5, 1)
        let expectedRe = re
        let expectedIm = im
        #expect(throws: FftError.sizeMismatch(expected: 6, re: 6, im: 5)) {
            try workspace.transform(re: &re, im: &im, inverse: true)
        }
        #expect(Self.bits(expectedRe) == Self.bits(re))
        #expect(Self.bits(expectedIm) == Self.bits(im))
    }

    // Swift-only.

    @Test func radix2HandlesAnImpulseAndADcSignal() {
        var re: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        var im = [Float](repeating: 0, count: 8)
        Fft.transform(re: &re, im: &im, inverse: false)
        #expect(re.allSatisfy { $0 == 1 } && im.allSatisfy { $0 == 0 })
        var dc = [Float](repeating: 1, count: 16)
        var dcIm = [Float](repeating: 0, count: 16)
        Fft.transform(re: &dc, im: &dcIm, inverse: false)
        #expect(dc[0] == 16)
        #expect(dc.dropFirst().allSatisfy { abs($0) < 1e-5 })
    }

    @Test func bluesteinRoundTripsOddLengths() throws {
        for size in [3, 5, 9, 93, 1000] {
            var workspace = try Fft.Workspace(size: size)
            let original = Self.signal(size, 11)
            var re = original
            var im = [Float](repeating: 0, count: size)
            try workspace.transform(re: &re, im: &im, inverse: false)
            try workspace.transform(re: &re, im: &im, inverse: true)
            #expect(Self.close(re, original, 0.0005), "size \(size)")
            #expect(im.allSatisfy { abs($0) < 0.0005 })
        }
    }

    @Test func emptyInputIsANoOp() {
        var re: [Float] = []
        var im: [Float] = []
        Fft.transform(re: &re, im: &im, inverse: false)
        #expect(re.isEmpty && im.isEmpty)
    }
}
