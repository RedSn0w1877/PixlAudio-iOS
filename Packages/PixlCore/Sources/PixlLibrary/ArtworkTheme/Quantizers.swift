// The Celebi quantizer (Wu boxes refined by weighted k-means in L*a*b*): a line-for-line Swift port of Google's colour
// utilities (Apache-2.0; `quantize/QuantizerCelebi`, `QuantizerWu`, `QuantizerWsmeans`, `QuantizerMap`,
// `PointProviderLab`), the version Android ships in com.google.android.material:material 1.14.0. See
// THIRD_PARTY_NOTICES.md.
//
// Kept on purpose, because the result depends on them:
// - Java `int` arithmetic wraps (`&+`, `&*` on Int32), then converts to double, exactly where upstream does it;
// - `LinkedHashMap` iteration order (first-seen order) for histograms and results;
// - `java.util.Random(0x42688)` for the initial cluster assignment;
// - upstream's k-means keeps one sorted distance row per cluster and overwrites it *by position* on later
//   iterations (the rows are not re-indexed after sorting); this port does the same, with a stable sort like
//   `Arrays.sort(Object[])`.

import Foundation

/// An insertion-ordered colour → population list (Java `LinkedHashMap<Integer, Integer>`).
struct ColorPopulation: Sendable, Equatable {
    var colors: [ARGB] = []
    var counts: [Int] = []

    var isEmpty: Bool { colors.isEmpty }
    var count: Int { colors.count }
}

enum QuantizerCelebi {
    /// Upstream `QuantizerCelebi.quantize`. Nil where upstream would throw (it never does for real images).
    static func quantize(_ pixels: [ARGB], maxColors: Int) -> ColorPopulation? {
        let wu = QuantizerWu.quantize(pixels, colorCount: maxColors)
        return QuantizerWsmeans.quantize(pixels, startingClusters: wu, maxColors: maxColors)
    }
}

// MARK: - Wu

enum QuantizerWu {
    private static let indexBits = 5
    private static let indexCount = 33
    private static let totalSize = 35937

    private struct Box {
        var r0 = 0, r1 = 0, g0 = 0, g1 = 0, b0 = 0, b1 = 0, vol = 0
    }

    private enum Direction { case red, green, blue }

    @inline(__always) private static func index(_ r: Int, _ g: Int, _ b: Int) -> Int {
        (r << (indexBits * 2)) + (r << (indexBits + 1)) + r + (g << indexBits) + g + b
    }

    /// Distinct pixels in first-seen order with their counts (upstream `QuantizerMap`).
    static func histogram(_ pixels: [ARGB]) -> ColorPopulation {
        var position = [ARGB: Int]()
        position.reserveCapacity(pixels.count)
        var result = ColorPopulation()
        for pixel in pixels {
            if let i = position[pixel] {
                result.counts[i] += 1
            } else {
                position[pixel] = result.colors.count
                result.colors.append(pixel)
                result.counts.append(1)
            }
        }
        return result
    }

    /// Upstream `QuantizerWu.quantize`: the box colours in order, duplicates dropped (first kept).
    static func quantize(_ pixels: [ARGB], colorCount: Int) -> [ARGB] {
        var state = State()
        state.constructHistogram(histogram(pixels))
        state.createMoments()
        let resultCount = state.createBoxes(colorCount)
        var seen = Set<ARGB>()
        var out = [ARGB]()
        for color in state.createResult(resultCount) where seen.insert(color).inserted {
            out.append(color)
        }
        return out
    }

    private struct State {
        var weights = [Int32](repeating: 0, count: totalSize)
        var momentsR = [Int32](repeating: 0, count: totalSize)
        var momentsG = [Int32](repeating: 0, count: totalSize)
        var momentsB = [Int32](repeating: 0, count: totalSize)
        var moments = [Double](repeating: 0, count: totalSize)
        var cubes: [Box] = []

        mutating func constructHistogram(_ pixels: ColorPopulation) {
            for (pixel, countInt) in zip(pixels.colors, pixels.counts) {
                let count = Int32(truncatingIfNeeded: countInt)
                let red = Int32(ColorUtils.red(pixel)), green = Int32(ColorUtils.green(pixel))
                let blue = Int32(ColorUtils.blue(pixel))
                let bitsToRemove = Int32(8 - indexBits)
                let iR = Int((red >> bitsToRemove) + 1)
                let iG = Int((green >> bitsToRemove) + 1)
                let iB = Int((blue >> bitsToRemove) + 1)
                let i = index(iR, iG, iB)
                weights[i] &+= count
                momentsR[i] &+= red &* count
                momentsG[i] &+= green &* count
                momentsB[i] &+= blue &* count
                moments[i] += Double(count &* (red &* red &+ green &* green &+ blue &* blue))
            }
        }

        mutating func createMoments() {
            for r in 1..<indexCount {
                var area = [Int32](repeating: 0, count: indexCount)
                var areaR = [Int32](repeating: 0, count: indexCount)
                var areaG = [Int32](repeating: 0, count: indexCount)
                var areaB = [Int32](repeating: 0, count: indexCount)
                var area2 = [Double](repeating: 0, count: indexCount)
                for g in 1..<indexCount {
                    var line: Int32 = 0, lineR: Int32 = 0, lineG: Int32 = 0, lineB: Int32 = 0
                    var line2 = 0.0
                    for b in 1..<indexCount {
                        let i = index(r, g, b)
                        line &+= weights[i]
                        lineR &+= momentsR[i]
                        lineG &+= momentsG[i]
                        lineB &+= momentsB[i]
                        line2 += moments[i]
                        area[b] &+= line
                        areaR[b] &+= lineR
                        areaG[b] &+= lineG
                        areaB[b] &+= lineB
                        area2[b] += line2
                        let p = index(r - 1, g, b)
                        weights[i] = weights[p] &+ area[b]
                        momentsR[i] = momentsR[p] &+ areaR[b]
                        momentsG[i] = momentsG[p] &+ areaG[b]
                        momentsB[i] = momentsB[p] &+ areaB[b]
                        moments[i] = moments[p] + area2[b]
                    }
                }
            }
        }

        mutating func createBoxes(_ maxColorCount: Int) -> Int {
            cubes = [Box](repeating: Box(), count: maxColorCount)
            var volumeVariance = [Double](repeating: 0, count: maxColorCount)
            cubes[0].r1 = indexCount - 1
            cubes[0].g1 = indexCount - 1
            cubes[0].b1 = indexCount - 1
            var generatedColorCount = maxColorCount
            var next = 0
            var i = 1
            while i < maxColorCount {
                if cut(next, i) {
                    volumeVariance[next] = cubes[next].vol > 1 ? variance(cubes[next]) : 0.0
                    volumeVariance[i] = cubes[i].vol > 1 ? variance(cubes[i]) : 0.0
                } else {
                    volumeVariance[next] = 0.0
                    i -= 1
                }
                next = 0
                var temp = volumeVariance[0]
                var j = 1
                while j <= i {
                    if volumeVariance[j] > temp {
                        temp = volumeVariance[j]
                        next = j
                    }
                    j += 1
                }
                if temp <= 0.0 {
                    generatedColorCount = i + 1
                    break
                }
                i += 1
            }
            return generatedColorCount
        }

        func createResult(_ colorCount: Int) -> [ARGB] {
            var colors = [ARGB]()
            for i in 0..<colorCount {
                let cube = cubes[i]
                let weight = volume(cube, weights)
                if weight > 0 {
                    let r = volume(cube, momentsR) / weight
                    let g = volume(cube, momentsG) / weight
                    let b = volume(cube, momentsB) / weight
                    let color = UInt32(bitPattern: (255 << 24) | ((r & 0x0FF) << 16) | ((g & 0x0FF) << 8) | (b & 0x0FF))
                    colors.append(color)
                }
            }
            return colors
        }

        func variance(_ cube: Box) -> Double {
            let dr = volume(cube, momentsR), dg = volume(cube, momentsG), db = volume(cube, momentsB)
            let xx = moments[index(cube.r1, cube.g1, cube.b1)]
                - moments[index(cube.r1, cube.g1, cube.b0)]
                - moments[index(cube.r1, cube.g0, cube.b1)]
                + moments[index(cube.r1, cube.g0, cube.b0)]
                - moments[index(cube.r0, cube.g1, cube.b1)]
                + moments[index(cube.r0, cube.g1, cube.b0)]
                + moments[index(cube.r0, cube.g0, cube.b1)]
                - moments[index(cube.r0, cube.g0, cube.b0)]
            let hypotenuse = dr &* dr &+ dg &* dg &+ db &* db
            let vol = volume(cube, weights)
            return xx - Double(hypotenuse) / Double(vol)
        }

        mutating func cut(_ oneIndex: Int, _ twoIndex: Int) -> Bool {
            var one = cubes[oneIndex]
            var two = cubes[twoIndex]
            let wholeR = volume(one, momentsR), wholeG = volume(one, momentsG)
            let wholeB = volume(one, momentsB), wholeW = volume(one, weights)
            let maxR = maximize(one, .red, one.r0 + 1, one.r1, wholeR, wholeG, wholeB, wholeW)
            let maxG = maximize(one, .green, one.g0 + 1, one.g1, wholeR, wholeG, wholeB, wholeW)
            let maxB = maximize(one, .blue, one.b0 + 1, one.b1, wholeR, wholeG, wholeB, wholeW)
            let direction: Direction
            if maxR.maximum >= maxG.maximum && maxR.maximum >= maxB.maximum {
                if maxR.cut < 0 { return false }
                direction = .red
            } else if maxG.maximum >= maxR.maximum && maxG.maximum >= maxB.maximum {
                direction = .green
            } else {
                direction = .blue
            }
            two.r1 = one.r1
            two.g1 = one.g1
            two.b1 = one.b1
            switch direction {
            case .red:
                one.r1 = maxR.cut
                two.r0 = one.r1; two.g0 = one.g0; two.b0 = one.b0
            case .green:
                one.g1 = maxG.cut
                two.r0 = one.r0; two.g0 = one.g1; two.b0 = one.b0
            case .blue:
                one.b1 = maxB.cut
                two.r0 = one.r0; two.g0 = one.g0; two.b0 = one.b1
            }
            one.vol = (one.r1 - one.r0) * (one.g1 - one.g0) * (one.b1 - one.b0)
            two.vol = (two.r1 - two.r0) * (two.g1 - two.g0) * (two.b1 - two.b0)
            cubes[oneIndex] = one
            cubes[twoIndex] = two
            return true
        }

        func maximize(_ cube: Box, _ direction: Direction, _ first: Int, _ last: Int, _ wholeR: Int32,
                      _ wholeG: Int32, _ wholeB: Int32, _ wholeW: Int32) -> (cut: Int, maximum: Double) {
            let bottomR = bottom(cube, direction, momentsR), bottomG = bottom(cube, direction, momentsG)
            let bottomB = bottom(cube, direction, momentsB), bottomW = bottom(cube, direction, weights)
            var maxValue = 0.0
            var cutAt = -1
            var i = first
            while i < last {
                var halfR = bottomR &+ top(cube, direction, i, momentsR)
                var halfG = bottomG &+ top(cube, direction, i, momentsG)
                var halfB = bottomB &+ top(cube, direction, i, momentsB)
                var halfW = bottomW &+ top(cube, direction, i, weights)
                if halfW == 0 { i += 1; continue }
                var numerator = Double(halfR &* halfR &+ halfG &* halfG &+ halfB &* halfB)
                var temp = numerator / Double(halfW)
                halfR = wholeR &- halfR
                halfG = wholeG &- halfG
                halfB = wholeB &- halfB
                halfW = wholeW &- halfW
                if halfW == 0 { i += 1; continue }
                numerator = Double(halfR &* halfR &+ halfG &* halfG &+ halfB &* halfB)
                temp += numerator / Double(halfW)
                if temp > maxValue {
                    maxValue = temp
                    cutAt = i
                }
                i += 1
            }
            return (cutAt, maxValue)
        }

        func volume(_ c: Box, _ m: [Int32]) -> Int32 {
            m[index(c.r1, c.g1, c.b1)] &- m[index(c.r1, c.g1, c.b0)] &- m[index(c.r1, c.g0, c.b1)]
                &+ m[index(c.r1, c.g0, c.b0)] &- m[index(c.r0, c.g1, c.b1)] &+ m[index(c.r0, c.g1, c.b0)]
                &+ m[index(c.r0, c.g0, c.b1)] &- m[index(c.r0, c.g0, c.b0)]
        }

        func bottom(_ c: Box, _ direction: Direction, _ m: [Int32]) -> Int32 {
            switch direction {
            case .red:
                return 0 &- m[index(c.r0, c.g1, c.b1)] &+ m[index(c.r0, c.g1, c.b0)]
                    &+ m[index(c.r0, c.g0, c.b1)] &- m[index(c.r0, c.g0, c.b0)]
            case .green:
                return 0 &- m[index(c.r1, c.g0, c.b1)] &+ m[index(c.r1, c.g0, c.b0)]
                    &+ m[index(c.r0, c.g0, c.b1)] &- m[index(c.r0, c.g0, c.b0)]
            case .blue:
                return 0 &- m[index(c.r1, c.g1, c.b0)] &+ m[index(c.r1, c.g0, c.b0)]
                    &+ m[index(c.r0, c.g1, c.b0)] &- m[index(c.r0, c.g0, c.b0)]
            }
        }

        func top(_ c: Box, _ direction: Direction, _ position: Int, _ m: [Int32]) -> Int32 {
            switch direction {
            case .red:
                return m[index(position, c.g1, c.b1)] &- m[index(position, c.g1, c.b0)]
                    &- m[index(position, c.g0, c.b1)] &+ m[index(position, c.g0, c.b0)]
            case .green:
                return m[index(c.r1, position, c.b1)] &- m[index(c.r1, position, c.b0)]
                    &- m[index(c.r0, position, c.b1)] &+ m[index(c.r0, position, c.b0)]
            case .blue:
                return m[index(c.r1, c.g1, position)] &- m[index(c.r1, c.g0, position)]
                    &- m[index(c.r0, c.g1, position)] &+ m[index(c.r0, c.g0, position)]
            }
        }
    }
}

// MARK: - Weighted k-means

enum QuantizerWsmeans {
    private static let maxIterations = 10
    private static let minMovementDistance = 3.0

    private struct Distance {
        var index = -1
        var distance = -1.0
    }

    typealias Lab = (Double, Double, Double)

    @inline(__always) static func labDistance(_ a: Lab, _ b: Lab) -> Double {
        let dL = a.0 - b.0, dA = a.1 - b.1, dB = a.2 - b.2
        return dL * dL + dA * dA + dB * dB
    }

    /// Upstream `QuantizerWsmeans.quantize`. Nil where upstream would index past its cluster array.
    static func quantize(_ inputPixels: [ARGB], startingClusters: [ARGB], maxColors: Int) -> ColorPopulation? {
        var random = JavaRandom(seed: 0x42688)
        let histogram = QuantizerWu.histogram(inputPixels)
        let pointCount = histogram.count
        let points: [Lab] = histogram.colors.map { ColorUtils.labFromArgb($0) }
        let counts = histogram.counts

        var clusterCount = min(maxColors, pointCount)
        if !startingClusters.isEmpty {
            clusterCount = min(clusterCount, startingClusters.count)
        }
        guard startingClusters.count <= clusterCount else { return nil }
        var clusters = [Lab](repeating: (0, 0, 0), count: clusterCount)
        for (i, argb) in startingClusters.enumerated() {
            clusters[i] = ColorUtils.labFromArgb(argb)
        }
        guard clusterCount > 0 else { return ColorPopulation() }

        var clusterIndices = [Int](repeating: 0, count: pointCount)
        for i in 0..<pointCount {
            clusterIndices[i] = Int(random.nextInt(Int32(clusterCount)))
        }
        var distanceRows = [[Distance]](repeating: [Distance](repeating: Distance(), count: clusterCount),
                                        count: clusterCount)
        var pixelCountSums = [Int](repeating: 0, count: clusterCount)

        for iteration in 0..<maxIterations {
            for i in 0..<clusterCount {
                for j in (i + 1)..<max(i + 1, clusterCount) {
                    let distance = labDistance(clusters[i], clusters[j])
                    distanceRows[j][i].distance = distance
                    distanceRows[j][i].index = i
                    distanceRows[i][j].distance = distance
                    distanceRows[i][j].index = j
                }
                stableSortByDistance(&distanceRows[i])
            }

            var pointsMoved = 0
            for i in 0..<pointCount {
                let point = points[i]
                let previousClusterIndex = clusterIndices[i]
                let previousDistance = labDistance(point, clusters[previousClusterIndex])
                var minimumDistance = previousDistance
                var newClusterIndex = -1
                for j in 0..<clusterCount {
                    if distanceRows[previousClusterIndex][j].distance >= 4 * previousDistance { continue }
                    let distance = labDistance(point, clusters[j])
                    if distance < minimumDistance {
                        minimumDistance = distance
                        newClusterIndex = j
                    }
                }
                if newClusterIndex != -1 {
                    let distanceChange = abs(minimumDistance.squareRoot() - previousDistance.squareRoot())
                    if distanceChange > minMovementDistance {
                        pointsMoved += 1
                        clusterIndices[i] = newClusterIndex
                    }
                }
            }
            if pointsMoved == 0 && iteration != 0 { break }

            var aSums = [Double](repeating: 0, count: clusterCount)
            var bSums = [Double](repeating: 0, count: clusterCount)
            var cSums = [Double](repeating: 0, count: clusterCount)
            for k in 0..<clusterCount { pixelCountSums[k] = 0 }
            for i in 0..<pointCount {
                let clusterIndex = clusterIndices[i]
                let point = points[i]
                let count = counts[i]
                pixelCountSums[clusterIndex] += count
                aSums[clusterIndex] += point.0 * Double(count)
                bSums[clusterIndex] += point.1 * Double(count)
                cSums[clusterIndex] += point.2 * Double(count)
            }
            for i in 0..<clusterCount {
                let count = pixelCountSums[i]
                if count == 0 {
                    clusters[i] = (0, 0, 0)
                    continue
                }
                clusters[i] = (aSums[i] / Double(count), bSums[i] / Double(count), cSums[i] / Double(count))
            }
        }

        var result = ColorPopulation()
        var seen = Set<ARGB>()
        for i in 0..<clusterCount {
            let count = pixelCountSums[i]
            if count == 0 { continue }
            let argb = ColorUtils.argbFromLab(clusters[i].0, clusters[i].1, clusters[i].2)
            if !seen.insert(argb).inserted { continue }
            result.colors.append(argb)
            result.counts.append(count)
        }
        return result
    }

    /// Stable merge sort by `distance` (Java `Arrays.sort(Object[])` with `Double.compareTo`; distances here are
    /// never NaN and never −0).
    private static func stableSortByDistance(_ row: inout [Distance]) {
        let n = row.count
        if n < 2 { return }
        var src = row
        var dst = row
        var width = 1
        while width < n {
            var start = 0
            while start < n {
                let mid = min(start + width, n)
                let end = min(start + 2 * width, n)
                var i = start, j = mid, k = start
                while i < mid && j < end {
                    if src[j].distance < src[i].distance {
                        dst[k] = src[j]; j += 1
                    } else {
                        dst[k] = src[i]; i += 1
                    }
                    k += 1
                }
                while i < mid { dst[k] = src[i]; i += 1; k += 1 }
                while j < end { dst[k] = src[j]; j += 1; k += 1 }
                start += 2 * width
            }
            swap(&src, &dst)
            width *= 2
        }
        row = src
    }
}
