//
//  BenchmarkTypes.swift
//  CVTestsSUI
//
//  Created by Codex on 19.04.2026.
//

import Foundation
import CoreML

enum BenchmarkExperimentKind: String, CaseIterable, Identifiable {
    case performance
    case accuracy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .performance:
            return "Performance"
        case .accuracy:
            return "Accuracy"
        }
    }
}

enum BenchmarkInputMode: String, CaseIterable, Identifiable {
    case synthetic
    case realImage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .synthetic:
            return "Synthetic input"
        case .realImage:
            return "Real image"
        }
    }
}

enum MeasuredSegment: String, CaseIterable, Identifiable {
    case imageLoading = "image_loading"
    case preprocessing
    case inference
    case postprocessing
    case total

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imageLoading:
            return "Image loading"
        case .preprocessing:
            return "Preprocessing"
        case .inference:
            return "Inference"
        case .postprocessing:
            return "Postprocessing"
        case .total:
            return "Total"
        }
    }
}

enum MeasurementMode: String, CaseIterable, Identifiable {
    case inferenceOnly
    case fullPipeline
    case segmented

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inferenceOnly:
            return "Inference only"
        case .fullPipeline:
            return "Full pipeline"
        case .segmented:
            return "Segmented"
        }
    }
}

enum BenchmarkComputeUnits: String, CaseIterable, Identifiable {
    case all
    case cpuOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .cpuOnly:
            return "CPU only"
        }
    }

    var reportValue: String {
        switch self {
        case .all:
            return "ALL"
        case .cpuOnly:
            return "CPU_ONLY"
        }
    }

    var mlComputeUnits: MLComputeUnits {
        switch self {
        case .all:
            return .all
        case .cpuOnly:
            return .cpuOnly
        }
    }
}

enum ModelFamily: String {
    case mobileNetV2 = "MobileNetV2"
    case efficientNetB0 = "EfficientNetB0"
}

enum ModelFormat: String {
    case fp32 = "FP32"
    case fp16 = "FP16"
    case int8 = "INT8"
}

enum BenchmarkTarget: Equatable {
    case allModels
    case model(String)
}

enum BenchmarkPerformanceProtocol: String, CaseIterable, Identifiable {
    case mainBenchmark
    case sustainedEnergyThermal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainBenchmark:
            return "Main benchmark"
        case .sustainedEnergyThermal:
            return "Sustained energy and thermal"
        }
    }

    var description: String {
        switch self {
        case .mainBenchmark:
            return "Short objective run for latency, memory footprint, and model size."
        case .sustainedEnergyThermal:
            return "Long continuous run for thermal drift, sustained throughput, and Instruments capture."
        }
    }

    var recommendedConditions: String {
        switch self {
        case .mainBenchmark:
            return "Use a real device. Start from thermalState=nominal."
        case .sustainedEnergyThermal:
            return "Run on a real unplugged device from thermalState=nominal. Capture Instruments in parallel."
        }
    }

    var inputMode: BenchmarkInputMode { .realImage }

    var measurementMode: MeasurementMode { .fullPipeline }

    var defaultComputeUnits: BenchmarkComputeUnits { .all }

    var runs: Int {
        switch self {
        case .mainBenchmark:
            return 50
        case .sustainedEnergyThermal:
            return 10_000
        }
    }

    var warmup: Int {
        switch self {
        case .mainBenchmark:
            return 10
        case .sustainedEnergyThermal:
            return 100
        }
    }

    var allowsAllModelsTarget: Bool {
        switch self {
        case .mainBenchmark:
            return true
        case .sustainedEnergyThermal:
            return false
        }
    }
}

struct BenchmarkRunConfiguration {
    let performanceProtocol: BenchmarkPerformanceProtocol
    let inputMode: BenchmarkInputMode
    let measurementMode: MeasurementMode
    let computeUnits: BenchmarkComputeUnits
    let target: BenchmarkTarget
    let runs: Int
    let warmup: Int
    let realImageDatasetID: String
}

struct BenchmarkResultRecord: Identifiable {
    let id = UUID()
    let inputMode: BenchmarkInputMode
    let measuredSegment: MeasuredSegment
    let modelName: String
    let modelFormat: ModelFormat
    let computeUnits: BenchmarkComputeUnits
    let runsCount: Int
    let warmupCount: Int
    let median: Double?
    let mean: Double?
    let p90: Double?
    let p95: Double?
    let min: Double?
    let max: Double?
    let stdDev: Double?
    let latencyStats: LatencyStats?
    let pipelineMetrics: PipelineLatencyMetrics?
    let timestamp: Date
    let experimentID: String
    let isApplicable: Bool
    let note: String?
    let resourceDiagnostics: BenchmarkResourceDiagnostics
}

struct PipelineLatencyMetrics {
    let totalMeasured: LatencyStats
    let imageLoading: LatencyStats?
    let preprocessing: LatencyStats?
    let inference: LatencyStats?
    let postprocessing: LatencyStats?
    let sumOfSegmentMediansMs: Double
    let pipelineOverheadMedianMs: Double
}

struct BenchmarkExecutionOutput {
    let records: [BenchmarkResultRecord]
    let reportText: String
}

struct AccuracyBenchmarkRunConfiguration {
    let datasetID: String
    let computeUnits: BenchmarkComputeUnits
    let target: BenchmarkTarget
    let warmupImages: Int
}

struct ClassAccuracyResult: Identifiable, Encodable {
    let classID: String?
    let classIndex: Int
    let classLabel: String?
    let totalCount: Int
    let top1CorrectCount: Int
    let top5CorrectCount: Int
    let top1Accuracy: Double
    let top5Accuracy: Double

    var id: String {
        if let classID {
            return classID
        }

        return String(classIndex)
    }
}

struct PredictionMistakeRecord: Identifiable, Encodable {
    let imageID: String
    let imagePath: String
    let groundTruthIndex: Int
    let groundTruthLabel: String?
    let predictedTop1Index: Int?
    let predictedTop1Label: String?
    let predictedTop1Score: Double?
    let top5Indices: [Int]
    let top5Labels: [String]
    let top5Scores: [Double]
    let isTop5Correct: Bool

    var id: String { imageID }
}

struct AccuracyDebugTop5Record: Identifiable, Encodable {
    let imageID: String
    let imagePath: String
    let groundTruthIndex: Int
    let groundTruthLabel: String?
    let top1Index: Int?
    let top1Label: String?
    let top5Labels: [String]
    let isTop1Correct: Bool
    let isTop5Correct: Bool

    var id: String { imageID }
}

struct PrecisionBaselineComparison: Encodable {
    let modelName: String
    let comparedPrecision: String
    let baselinePrecision: String
    let commonImagesCount: Int
    let sameTop1PredictionCount: Int
    let top1AgreementWithFP32: Double
    let changedTop1PredictionCount: Int
    let improvedVsFP32Count: Int
    let regressedVsFP32Count: Int
    let sameCorrectnessCount: Int
}

struct AccuracyBenchmarkExports: Encodable {
    let directoryPath: String
    let perClassCSVPath: String
    let mistakesCSVPath: String
    let debugTop5CSVPath: String
    let detailsJSONPath: String
}

struct AccuracyBenchmarkResult: Identifiable {
    let id = UUID()
    let experimentID: String
    let timestamp: Date
    let datasetName: String
    let datasetSubsetID: String
    let datasetVersionOrPath: String
    let datasetImagesPerClass: Int
    let datasetSelectionRule: String
    let subsetSize: Int
    let totalImages: Int
    let modelName: String
    let modelFormat: ModelFormat
    let computeUnits: BenchmarkComputeUnits
    let measurementMode: MeasurementMode
    let referenceFormat: ModelFormat?
    let top1CorrectCount: Int
    let top5CorrectCount: Int
    let correctRestrictedTop1: Int
    let top1Accuracy: Double
    let top5Accuracy: Double
    let restrictedTop1Accuracy: Double
    let perClassResults: [ClassAccuracyResult]
    let mistakes: [PredictionMistakeRecord]
    let debugTop5Records: [AccuracyDebugTop5Record]
    let baselineComparison: PrecisionBaselineComparison?
    let exports: AccuracyBenchmarkExports
    let top1AgreementVsFP32: Double?
    let top5AgreementVsFP32: Double?
    let restrictedTop1AgreementVsFP32: Double?
    let top1DisagreementCountVsFP32: Int?
    let top5DisagreementCountVsFP32: Int?
    let restrictedTop1DisagreementCountVsFP32: Int?
    let meanLatencyMs: Double
    let medianLatencyMs: Double
    let p90LatencyMs: Double
    let p95LatencyMs: Double
    let minLatencyMs: Double
    let maxLatencyMs: Double
    let stdDevLatencyMs: Double
    let latencyStats: LatencyStats
    let resourceDiagnostics: BenchmarkResourceDiagnostics
}

struct AccuracyBenchmarkExecutionOutput {
    let results: [AccuracyBenchmarkResult]
    let reportText: String
}

enum BenchmarkDefaults {
    static let runs = 50
    static let warmup = 10
    static let realImageDatasetID = "imagenette2-160-subset-500"
    static let inputShape = [1, 3, 224, 224]
    static let inputWidth = 224
    static let inputHeight = 224
}

enum AccuracyBenchmarkDefaults {
    static let datasetID = "imagenette2-160-subset-500"
    static let warmupImages = 3
}
