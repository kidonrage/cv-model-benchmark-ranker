//
//  BenchmarkResultsModels.swift
//  CVTestsSUI
//
//  Created by Codex on 23.05.2026.
//

import Foundation
import UIKit
import Darwin.Mach

enum FullBenchmarkState: String, Encodable, Sendable {
    case idle
    case validatingPlan
    case running
    case completed
    case completedWithFailures
    case failed

    var title: String {
        switch self {
        case .idle:
            return "not started"
        case .validatingPlan:
            return "validating plan"
        case .running:
            return "running"
        case .completed:
            return "completed"
        case .completedWithFailures:
            return "completed with failures"
        case .failed:
            return "failed"
        }
    }
}

enum BenchmarkRunStatus: String, Encodable, Sendable {
    case success
    case failed
}

struct FullBenchmarkProgress: Sendable {
    let currentExperimentIndex: Int
    let totalExperiments: Int
    let modelId: String
    let measurementMode: String
    let computeUnits: String
}

struct BenchmarkReadinessSnapshot: Sendable {
    let manifestFound: Bool
    let planFound: Bool
    let modelCount: Int
    let experimentCount: Int
    let planId: String?
    let modelErrors: [String]

    var modelsReady: Bool {
        modelErrors.isEmpty && modelCount > 0
    }
}

struct BenchmarkResultsEnvelope: Encodable, Sendable {
    let schemaVersion: String
    let benchmarkInfo: BenchmarkInfo
    let device: BenchmarkDeviceInfo
    let plan: BenchmarkPlanSummary
    let runs: [BenchmarkRunResult]
}

struct BenchmarkInfo: Encodable, Sendable {
    let benchmarkAppVersion: String
    let planId: String
    let startedAt: String
    let finishedAt: String
    let status: FullBenchmarkState
}

struct BenchmarkDeviceInfo: Encodable, Sendable {
    let name: String
    let modelIdentifier: String
    let systemName: String
    let systemVersion: String
    let thermalStateAtStart: String
    let thermalStateAtEnd: String
}

struct BenchmarkPlanSummary: Encodable, Sendable {
    let experimentsTotal: Int
    let experimentsSucceeded: Int
    let experimentsFailed: Int
}

struct BenchmarkRunResult: Encodable, Sendable {
    let experimentId: String
    let status: BenchmarkRunStatus
    let modelId: String
    let family: String
    let format: String
    let optimizationType: String
    let computeUnits: String
    let measurementMode: String
    let datasetId: String?
    let dataset: BenchmarkDatasetSummary?
    let modelSizeMb: Double?
    let `protocol`: BenchmarkProtocolSummary?
    let latency: BenchmarkLatencySummary?
    let accuracy: BenchmarkAccuracySummary?
    let diagnostics: BenchmarkRunDiagnostics?
    let artifacts: BenchmarkArtifacts
    let error: BenchmarkRunError?
}

struct BenchmarkDatasetSummary: Encodable, Sendable {
    let datasetId: String
    let source: String
    let taskType: DatasetTaskType
    let imageCount: Int
    let classCount: Int
    let hasGroundTruth: Bool
    let hasOutputIndexMapping: Bool
    let role: DatasetRole
    let classes: [BenchmarkDatasetClassSummary]
}

struct BenchmarkDatasetClassSummary: Encodable, Sendable {
    let classId: String
    let displayName: String
    let outputIndex: Int?
    let imageCount: Int
}

struct BenchmarkProtocolSummary: Encodable, Sendable {
    let warmupRuns: Int?
    let measuredRuns: Int?
    let warmupImages: Int?
}

struct BenchmarkLatencySummary: Encodable, Sendable {
    let meanMs: Double?
    let medianMs: Double?
    let p90Ms: Double?
    let p95Ms: Double?
    let minMs: Double?
    let maxMs: Double?
    let stdDevMs: Double?
    let fullPipelineMedianMs: Double?
    let inferenceMedianMs: Double?
    let preprocessingMedianMs: Double?
    let postprocessingMedianMs: Double?
    let imageLoadingMedianMs: Double?
}

struct BenchmarkAccuracySummary: Encodable, Sendable {
    let top1: Double
    let top5: Double?
    let restrictedTop1: Double?
    let totalImages: Int
    let correctTop1: Int
    let correctTop5: Int?
    let correctRestrictedTop1: Int?
    let perClassAccuracy: [BenchmarkPerClassAccuracySummary]?
}

struct BenchmarkPerClassAccuracySummary: Encodable, Sendable {
    let classId: String?
    let displayName: String?
    let outputIndex: Int
    let totalImages: Int
    let correctTop1: Int
    let correctTop5: Int?
    let top1: Double
    let top5: Double?
}

struct BenchmarkRunDiagnostics: Encodable, Sendable {
    let thermalState: String
    let batteryState: String
    let batteryLevel: Float?
    let residentMemoryMb: Double?
    let hasSustainedBenchmark: Bool

    static func capture(hasSustainedBenchmark: Bool) -> BenchmarkRunDiagnostics {
        UIDevice.current.isBatteryMonitoringEnabled = true
        return BenchmarkRunDiagnostics(
            thermalState: BenchmarkDeviceStateReporter.thermalState(ProcessInfo.processInfo.thermalState),
            batteryState: BenchmarkDeviceStateReporter.batteryState(UIDevice.current.batteryState),
            batteryLevel: UIDevice.current.batteryLevel >= 0 ? UIDevice.current.batteryLevel : nil,
            residentMemoryMb: currentResidentMemoryBytes().map(bytesToMegabytes),
            hasSustainedBenchmark: hasSustainedBenchmark
        )
    }

    static func from(
        _ diagnostics: BenchmarkResourceDiagnostics,
        hasSustainedBenchmark: Bool
    ) -> BenchmarkRunDiagnostics {
        BenchmarkRunDiagnostics(
            thermalState: diagnostics.thermalStateAfter,
            batteryState: diagnostics.batteryStateAfter,
            batteryLevel: diagnostics.batteryLevelAfter,
            residentMemoryMb: diagnostics.maxObservedResidentMemoryBytes.map(bytesToMegabytes),
            hasSustainedBenchmark: hasSustainedBenchmark
        )
    }

    private static func bytesToMegabytes(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_048_576.0
    }

    private static func currentResidentMemoryBytes() -> UInt64? {
        var taskInfo = mach_task_basic_info()
        var taskInfoCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )

        let kernReturn: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) { taskInfoPointer in
            taskInfoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(taskInfoCount)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &taskInfoCount
                )
            }
        }

        guard kernReturn == KERN_SUCCESS else {
            return nil
        }

        return UInt64(taskInfo.resident_size)
    }
}

struct BenchmarkArtifacts: Encodable, Sendable {
    let legacyTextLogPath: String?
    let csvPath: String?
    let mistakesJsonPath: String?

    static let empty = BenchmarkArtifacts(
        legacyTextLogPath: nil,
        csvPath: nil,
        mistakesJsonPath: nil
    )
}

struct BenchmarkRunError: Encodable, Sendable {
    let code: String
    let message: String
}

enum BenchmarkDeviceStateReporter {
    static func thermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    static func batteryState(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .unplugged:
            return "unplugged"
        case .charging:
            return "charging"
        case .full:
            return "full"
        @unknown default:
            return "unknown"
        }
    }
}
