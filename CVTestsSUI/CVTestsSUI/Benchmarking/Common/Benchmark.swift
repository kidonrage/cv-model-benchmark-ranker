//
//  Benchmark.swift
//  CVTestsSUI
//
//  Created by Vlad Eliseev on 17.01.2026.
//

import Foundation

struct LatencyStats {
    let count: Int
    let minMs: Double
    let maxMs: Double
    let meanMs: Double
    let medianMs: Double
    let p90Ms: Double
    let p95Ms: Double
    let stdDevMs: Double

    var min: Double { minMs }
    var max: Double { maxMs }
    var mean: Double { meanMs }
    var median: Double { medianMs }
    var p90: Double { p90Ms }
    var p95: Double { p95Ms }
    var stdDev: Double { stdDevMs }

    static func make(from samples: [Double]) -> LatencyStats {
        precondition(!samples.isEmpty, "samples must not be empty")

        let sorted = samples.sorted()
        let count = samples.count
        let mean = samples.reduce(0, +) / Double(count)
        let variance = samples.reduce(into: 0.0) { partialResult, sample in
            let delta = sample - mean
            partialResult += delta * delta
        } / Double(count)

        return LatencyStats(
            count: count,
            minMs: sorted[0],
            maxMs: sorted[count - 1],
            meanMs: mean,
            medianMs: percentile(0.5, in: sorted),
            p90Ms: percentile(0.9, in: sorted),
            p95Ms: percentile(0.95, in: sorted),
            stdDevMs: variance.squareRoot()
        )
    }

    private static func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
        precondition(!sorted.isEmpty, "sorted must not be empty")
        precondition((0...1).contains(percentile), "percentile must be inside 0...1")

        guard sorted.count > 1 else {
            return sorted[0]
        }

        let position = percentile * Double(sorted.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))

        guard lowerIndex != upperIndex else {
            return sorted[lowerIndex]
        }

        let lowerValue = sorted[lowerIndex]
        let upperValue = sorted[upperIndex]
        let fraction = position - Double(lowerIndex)
        return lowerValue + (upperValue - lowerValue) * fraction
    }
}

typealias BenchStats = LatencyStats

struct SegmentBenchmark {
    let segment: MeasuredSegment
    let stats: LatencyStats?
    let note: String?

    var isApplicable: Bool {
        stats != nil
    }

    static func notApplicable(segment: MeasuredSegment, note: String) -> SegmentBenchmark {
        SegmentBenchmark(segment: segment, stats: nil, note: note)
    }
}

func measureMilliseconds(block: () throws -> Void) rethrows -> Double {
    let start = CFAbsoluteTimeGetCurrent()
    try block()
    let end = CFAbsoluteTimeGetCurrent()
    return (end - start) * 1000.0
}

func benchmark(
    runs: Int = 50,
    warmup: Int = 10,
    afterWarmup: (() -> Void)? = nil,
    afterMeasuredRun: ((Int, Int) -> Void)? = nil,
    block: () throws -> Void
) rethrows -> BenchStats {
    precondition(runs > 0, "runs must be greater than zero")
    precondition(warmup >= 0, "warmup must not be negative")

    for _ in 0..<warmup {
        try autoreleasepool {
            try block()
        }
    }
    afterWarmup?()

    var times: [Double] = []
    times.reserveCapacity(runs)

    for runIndex in 0..<runs {
        let duration = try autoreleasepool {
            try measureMilliseconds(block: block)
        }
        times.append(duration)
        afterMeasuredRun?(runIndex + 1, runs)
    }

    return BenchStats.make(from: times)
}

func benchmarkSegment(
    _ segment: MeasuredSegment,
    runs: Int = 50,
    warmup: Int = 10,
    afterWarmup: (() -> Void)? = nil,
    afterMeasuredRun: ((Int, Int) -> Void)? = nil,
    block: () throws -> Void
) rethrows -> SegmentBenchmark {
    let stats = try benchmark(
        runs: runs,
        warmup: warmup,
        afterWarmup: afterWarmup,
        afterMeasuredRun: afterMeasuredRun,
        block: block
    )
    return SegmentBenchmark(segment: segment, stats: stats, note: nil)
}
