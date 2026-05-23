//
//  BenchmarkPlanModels.swift
//  CVTestsSUI
//
//  Created by Codex on 23.05.2026.
//

import Foundation

struct BenchmarkPlan: Decodable, Sendable {
    let planId: String
    let datasetId: String?
    let experiments: [BenchmarkPlanExperiment]
}

struct BenchmarkPlanExperiment: Decodable, Identifiable, Sendable {
    let experimentId: String
    let modelId: String
    let computeUnits: BenchmarkComputeUnits
    let benchmarkType: PlanBenchmarkType
    let measurementMode: MeasurementMode
    let inputMode: PlanInputMode
    let datasetId: String?
    let warmupRuns: Int?
    let measuredRuns: Int?
    let warmupImages: Int?

    var id: String { experimentId }
}

enum PlanBenchmarkType: String, Decodable, Sendable {
    case performance
    case accuracy
}

enum PlanInputMode: String, Decodable, Sendable {
    case synthetic
    case realImage
    case dataset

    var benchmarkInputMode: BenchmarkInputMode {
        switch self {
        case .synthetic:
            return .synthetic
        case .realImage, .dataset:
            return .realImage
        }
    }
}

struct ModelsManifest: Decodable, Sendable {
    let models: [ManifestModel]
    let preprocessingProfiles: [String: ManifestPreprocessingProfile]
}

struct ManifestModel: Decodable, Identifiable, Sendable {
    let id: String
    let family: String
    let format: String
    let optimizationType: String
    let modelSizeMb: Double?
    let supported: Bool
    let preprocessingProfile: String
}

struct ManifestPreprocessingProfile: Decodable, Sendable {
    let resizeShortSide: Int
    let cropSize: Int
    let interpolation: String
    let colorSpace: String
    let channelOrder: String
    let mean: [Double]
    let std: [Double]
}

extension BenchmarkComputeUnits: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "ALL", "all":
            self = .all
        case "CPU_ONLY", "cpuOnly", "cpu_only":
            self = .cpuOnly
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported computeUnits: \(value)"
            )
        }
    }
}

extension MeasurementMode: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "inferenceOnly", "inference_only":
            self = .inferenceOnly
        case "fullPipeline", "full_pipeline":
            self = .fullPipeline
        case "segmented":
            self = .segmented
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported measurementMode: \(value)"
            )
        }
    }
}
