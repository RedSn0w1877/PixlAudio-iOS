import Testing
@testable import PixlLibrary

/// The camera side of the ring scanner without a camera: a picture from the core's own renderer is laid out the way a phone's planes are
/// (padded luma rows, chroma at half size, separate or interleaved), turned back into a frame by `RingFrameBuilder` and read by the real
/// scanner (the Android `RingFrameBuilderTest`), plus the pacer.
@Suite("Ring code camera glue")
struct RingCodeCameraTests {
    private let video = "dQw4w9WgXcQ"

    private struct Planes {
        var y: [UInt8]
        var u: [UInt8]
        var v: [UInt8]
        var yStride: Int
        var uvStride: Int
        var uvPixel: Int
        var width: Int
        var height: Int
    }

    /// Planes for `rendered`: luma with `pad` junk bytes at the end of every row, chroma at half size (the start dot's colour where the
    /// render says "orange").
    private func planes(_ rendered: Rendered, pad: Int, uvPixel: Int) -> Planes {
        let img = rendered.image
        let w = img.width, h = img.height
        let yStride = w + pad
        var y = [UInt8](repeating: 0x77, count: yStride * h)
        for row in 0..<h { for x in 0..<w { y[row * yStride + x] = img.luma[row * w + x] } }
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        let uvStride = cw * uvPixel + 6
        var u = [UInt8](repeating: 0x7F, count: uvStride * ch)
        var v = [UInt8](repeating: 0x7F, count: uvStride * ch)
        for cy in 0..<ch {
            for cx in 0..<cw {
                let orange = Int(img.orange[min(cy * 2, h - 1) * w + min(cx * 2, w - 1)]) > 128
                u[cy * uvStride + cx * uvPixel] = orange ? 75 : 128
                v[cy * uvStride + cx * uvPixel] = orange ? 205 : 128
            }
        }
        return Planes(y: y, u: u, v: v, yStride: yStride, uvStride: uvStride, uvPixel: uvPixel, width: w, height: h)
    }

    private func build(_ builder: RingFrameBuilder, _ p: Planes) -> RingFrame {
        p.y.withUnsafeBytes { yb in
            p.u.withUnsafeBytes { ub in
                p.v.withUnsafeBytes { vb in
                    builder.build(width: p.width, height: p.height, y: yb, yRowStride: p.yStride, u: ub, v: vb,
                                  uvRowStride: p.uvStride, uvPixelStride: p.uvPixel)
                }
            }
        }
    }

    private func render(rotation: Double, bucket: Int = 12, random: Int = 77) throws -> (Rendered, [UInt8]) {
        let bits = try #require(RingCodePayloads.encodeSlots(videoId: video, minuteBucket: bucket, random: random))
        var params = RenderParams()
        params.rotationRad = rotation
        return (RingCodeRenderer.render(bits, params), bits)
    }

    @Test func aPictureLaidOutLikeAPhonesPlanesWithPaddedRowsAndInterleavedChromaIsRead() throws {
        let (rendered, _) = try render(rotation: 0.7)
        let frame = build(RingFrameBuilder(), planes(rendered, pad: 24, uvPixel: 2))
        let result = RingScanner().scan(frame)
        guard case .decoded(let payload, _, _) = result else { Issue.record("not decoded: \(result)"); return }
        #expect(payload.videoId == video)
        #expect(payload.minuteBucket == 12)
        #expect(payload.random == 77)
    }

    @Test func unpaddedRowsAndSeparateChromaPlanesAreReadToo() throws {
        let scanner = RingScanner()
        for rotation in [0.0, 2.1, 4.4] {
            let (rendered, _) = try render(rotation: rotation)
            let result = scanner.scan(build(RingFrameBuilder(), planes(rendered, pad: 0, uvPixel: 1)))
            #expect(result.isDecoded, "rotation \(rotation)")
        }
    }

    @Test func aBiplanarBufferWithInterleavedCbCrIsReadThroughTheAppsEntryPoint() throws {
        let (rendered, _) = try render(rotation: 1.3)
        let img = rendered.image
        let w = img.width, h = img.height
        let lumaStride = w + 64
        var luma = [UInt8](repeating: 0x55, count: lumaStride * h)
        for row in 0..<h { for x in 0..<w { luma[row * lumaStride + x] = img.luma[row * w + x] } }
        let cw = (w + 1) / 2, ch = (h + 1) / 2
        let chromaStride = cw * 2 + 32
        var chroma = [UInt8](repeating: 128, count: chromaStride * ch)
        for cy in 0..<ch {
            for cx in 0..<cw {
                let orange = Int(img.orange[min(cy * 2, h - 1) * w + min(cx * 2, w - 1)]) > 128
                chroma[cy * chromaStride + cx * 2] = orange ? 75 : 128
                chroma[cy * chromaStride + cx * 2 + 1] = orange ? 205 : 128
            }
        }
        let frame = luma.withUnsafeBytes { lb in
            chroma.withUnsafeBytes { cb in
                RingFrameBuilder().buildBiplanar(width: w, height: h, luma: lb, lumaRowStride: lumaStride, chroma: cb, chromaRowStride: chromaStride)
            }
        }
        #expect(frame.hue != nil)
        #expect(frame.hueWidth == cw && frame.hueHeight == ch)
        #expect(RingScanner().scan(frame).payload?.videoId == video)
    }

    @Test func theHueMapMarksTheStartDotAndAlmostNothingElse() throws {
        let (rendered, _) = try render(rotation: 0, bucket: 3, random: 5)
        let frame = build(RingFrameBuilder(), planes(rendered, pad: 0, uvPixel: 2))
        let hue = try #require(frame.hue)
        var strong = 0
        for i in 0..<(frame.hueWidth * frame.hueHeight) where hue[i] > 100 { strong += 1 }
        // The start dot is 42 permille of 130 px = about 5 px across: a handful of chroma samples, not hundreds.
        #expect(strong > 0)
        #expect(strong < 60)
    }

    @Test func noChromaPlanesGivesAFrameWithoutAHueMap() {
        let frame = [UInt8](repeating: 0, count: 64 * 64).withUnsafeBytes {
            RingFrameBuilder().build(width: 64, height: 64, y: $0, yRowStride: 64, u: nil, v: nil, uvRowStride: 0, uvPixelStride: 0)
        }
        #expect(frame.hue == nil)
        #expect(frame.luma.count >= 64 * 64)
    }

    @Test func theFrameChangesSizeWithThePicture() {
        let builder = RingFrameBuilder()
        let a = [UInt8](repeating: 1, count: 128 * 96).withUnsafeBytes {
            builder.build(width: 128, height: 96, y: $0, yRowStride: 128, u: nil, v: nil, uvRowStride: 0, uvPixelStride: 0)
        }
        #expect(a.luma.count == 128 * 96)
        let b = [UInt8](repeating: 2, count: 256 * 192).withUnsafeBytes {
            builder.build(width: 256, height: 192, y: $0, yRowStride: 256, u: nil, v: nil, uvRowStride: 0, uvPixelStride: 0)
        }
        #expect(b.luma.count == 256 * 192)
        #expect(b.luma.allSatisfy { $0 == 2 })
    }

    @Test func aChromaPlaneShorterThanItsGridIsReadAsNotOrangeNeverOutOfBounds() {
        let w = 64, h = 64
        let frame = [UInt8](repeating: 0, count: w * h).withUnsafeBytes { yb in
            [UInt8](repeating: 0, count: 10).withUnsafeBytes { ub in
                [UInt8](repeating: 0, count: 10).withUnsafeBytes { vb in
                    RingFrameBuilder().build(width: w, height: h, y: yb, yRowStride: w, u: ub, v: vb, uvRowStride: 32, uvPixelStride: 1)
                }
            }
        }
        #expect(frame.hue != nil)
    }

    @Test func aLumaPlaneShorterThanItsRowsIsCopiedAsFarAsItGoesNeverOutOfBounds() {
        let frame = [UInt8](repeating: 9, count: 100).withUnsafeBytes {
            RingFrameBuilder().build(width: 64, height: 64, y: $0, yRowStride: 80, u: nil, v: nil, uvRowStride: 0, uvPixelStride: 0)
        }
        #expect(frame.luma.count == 64 * 64)
        #expect(frame.luma[0] == 9)
    }

    // MARK: The pacer

    @Test func thePacerKeepsAGapWaitsLongerAfterASlowScanAndCallsASlowPhoneSlow() {
        var pacer = RingScanPacer(minGapMs: 100, load: 2, tooSlowMs: 450, window: 4)
        #expect(pacer.shouldScan(nowMs: 0))
        pacer.recordScan(micros: 20_000, nowMs: 1_000) // 20 ms
        #expect(!pacer.shouldScan(nowMs: 1_050))
        #expect(pacer.shouldScan(nowMs: 1_100))
        pacer.recordScan(micros: 200_000, nowMs: 2_000) // 200 ms: wait twice that
        #expect(!pacer.shouldScan(nowMs: 2_300))
        #expect(pacer.shouldScan(nowMs: 2_400))
        #expect(!pacer.tooSlow())
        for i in 0..<4 { pacer.recordScan(micros: 600_000, nowMs: 3_000 + Int64(i) * 2_000) }
        #expect(pacer.averageMs() == 600)
        #expect(pacer.tooSlow())
        pacer.reset()
        #expect(!pacer.tooSlow())
        #expect(pacer.shouldScan(nowMs: 0))
    }
}
