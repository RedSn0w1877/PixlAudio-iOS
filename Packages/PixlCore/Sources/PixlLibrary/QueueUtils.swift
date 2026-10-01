// Port of `utils/QueueUtils.kt`: Fisher–Yates shuffles that keep the current song anchored. With a seeded
// `KotlinRandom` the orders match Android exactly (`QueueUtilsGoldenTests`).

import Foundation

public enum QueueUtils {
    /// The suspending variants yield every this many steps so huge queues never block their caller.
    static let shuffleYieldBatch = 512

    /// `fisherYatesCopy`: a shuffled copy.
    public static func fisherYatesCopy<T, R: ShuffleRandom>(_ source: [T], random: inout R) -> [T] {
        if source.count <= 1 { return source }
        var items = source
        var i = items.count - 1
        while i >= 1 {
            let j = random.nextInt(until: i + 1)
            if i != j { items.swapAt(i, j) }
            i -= 1
        }
        return items
    }

    public static func fisherYatesCopy<T>(_ source: [T]) -> [T] {
        var random = SystemShuffleRandom()
        return fisherYatesCopy(source, random: &random)
    }

    /// `buildAnchoredShuffleQueue`: shuffles everything except the item at `anchorIndex` (clamped), which keeps
    /// its position so playback is not redirected.
    public static func buildAnchoredShuffleQueue<T, R: ShuffleRandom>(_ queue: [T], anchorIndex: Int, random: inout R) -> [T] {
        if queue.count <= 1 { return queue }
        return shuffleOrder(size: queue.count, anchorIndex: anchorIndex, random: &random).map { queue[$0] }
    }

    public static func buildAnchoredShuffleQueue<T>(_ queue: [T], anchorIndex: Int) -> [T] {
        var random = SystemShuffleRandom()
        return buildAnchoredShuffleQueue(queue, anchorIndex: anchorIndex, random: &random)
    }

    /// `buildAnchoredShuffleQueueSuspending`: the same, yielding cooperatively for large queues. With
    /// `startAtZero` the anchor moves to the front, followed by the shuffled rest.
    public static func buildAnchoredShuffleQueue<T: Sendable, R: ShuffleRandom>(
        _ queue: [T], anchorIndex: Int, startAtZero: Bool, random: inout R
    ) async -> [T] {
        if queue.count <= 1 { return queue }
        let size = queue.count
        let anchor = anchorIndex.coerced(in: 0, size - 1)
        var pool = [Int](repeating: 0, count: size - 1)
        var cursor = 0
        var work = 0
        for i in 0..<size {
            if i != anchor {
                pool[cursor] = i
                cursor += 1
            }
            work += 1
            if work >= shuffleYieldBatch { work = 0; await Task.yield() }
        }
        var i = pool.count - 1
        while i >= 1 {
            let swapIndex = random.nextInt(until: i + 1)
            if i != swapIndex { pool.swapAt(i, swapIndex) }
            work += 1
            if work >= shuffleYieldBatch { work = 0; await Task.yield() }
            i -= 1
        }
        var order = [Int](repeating: 0, count: size)
        if startAtZero {
            order[0] = anchor
            for (k, index) in pool.enumerated() {
                order[k + 1] = index
                work += 1
                if work >= shuffleYieldBatch { work = 0; await Task.yield() }
            }
        } else {
            var poolIndex = 0
            for k in 0..<size {
                if k == anchor {
                    order[k] = anchor
                } else {
                    order[k] = pool[poolIndex]
                    poolIndex += 1
                }
                work += 1
                if work >= shuffleYieldBatch { work = 0; await Task.yield() }
            }
        }
        return order.map { queue[$0] }
    }

    public static func buildAnchoredShuffleQueue<T: Sendable>(_ queue: [T], anchorIndex: Int, startAtZero: Bool) async -> [T] {
        var random = SystemShuffleRandom()
        return await buildAnchoredShuffleQueue(queue, anchorIndex: anchorIndex, startAtZero: startAtZero, random: &random)
    }

    static func shuffleOrder<R: ShuffleRandom>(size: Int, anchorIndex: Int, random: inout R) -> [Int] {
        if size <= 1 { return Array(0..<size) }
        let anchor = anchorIndex.coerced(in: 0, size - 1)
        var pool = (0..<size).filter { $0 != anchor }
        var i = pool.count - 1
        while i >= 1 {
            let swapIndex = random.nextInt(until: i + 1)
            if i != swapIndex { pool.swapAt(i, swapIndex) }
            i -= 1
        }
        var order = [Int](repeating: 0, count: size)
        var poolIndex = 0
        for k in 0..<size {
            if k == anchor {
                order[k] = anchor
            } else {
                order[k] = pool[poolIndex]
                poolIndex += 1
            }
        }
        return order
    }
}
