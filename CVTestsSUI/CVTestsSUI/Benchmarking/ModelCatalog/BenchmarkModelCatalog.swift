//
//  BenchmarkModelCatalog.swift
//  CVTestsSUI
//
//  Created by Codex on 19.04.2026.
//

import Foundation
import CoreML

struct BenchmarkLoadedModel {
    let predict: (MLMultiArray) throws -> MLMultiArray
}

struct BenchmarkModelDescriptor {
    let id: String
    let family: ModelFamily
    let format: ModelFormat
    let expectedInputDataType: MLMultiArrayDataType
    let inputPreprocessing: ImagePreprocessingConfiguration
    let load: (MLModelConfiguration) throws -> BenchmarkLoadedModel

    var displayName: String {
        "\(family.rawValue)_\(format.rawValue)"
    }
}

enum BenchmarkModelCatalog {
    static let all: [BenchmarkModelDescriptor] = [
        BenchmarkModelDescriptor(
            id: "MobileNetV2_FP32",
            family: .mobileNetV2,
            format: .fp32,
            expectedInputDataType: .float32,
            inputPreprocessing: .mobileNetV2Torchvision
        ) { configuration in
            let model = try MobileNetV2_FP32(configuration: configuration)
            return BenchmarkLoadedModel { input in
                try model.prediction(input: input).var_824
            }
        },
        BenchmarkModelDescriptor(
            id: "MobileNetV2_FP16",
            family: .mobileNetV2,
            format: .fp16,
            expectedInputDataType: .float16,
            inputPreprocessing: .mobileNetV2Torchvision
        ) { configuration in
            let model = try MobileNetV2_FP16(configuration: configuration)
            return BenchmarkLoadedModel { input in
                try model.prediction(input: input).var_824
            }
        },
        BenchmarkModelDescriptor(
            id: "MobileNetV2_INT8",
            family: .mobileNetV2,
            format: .int8,
            expectedInputDataType: .float16,
            inputPreprocessing: .mobileNetV2Torchvision
        ) { configuration in
            let model = try MobileNetV2_INT8(configuration: configuration)
            return BenchmarkLoadedModel { input in
                try model.prediction(input: input).var_824
            }
        },
        BenchmarkModelDescriptor(
            id: "EfficientNetB0_FP32",
            family: .efficientNetB0,
            format: .fp32,
            expectedInputDataType: .float32,
            inputPreprocessing: .efficientNetB0Torchvision
        ) { configuration in
            let model = try EfficientNetB0_FP32(configuration: configuration)
            return BenchmarkLoadedModel { input in
                try model.prediction(input: input).var_1150
            }
        },
        BenchmarkModelDescriptor(
            id: "EfficientNetB0_FP16",
            family: .efficientNetB0,
            format: .fp16,
            expectedInputDataType: .float16,
            inputPreprocessing: .efficientNetB0Torchvision
        ) { configuration in
            let model = try EfficientNetB0_FP16(configuration: configuration)
            return BenchmarkLoadedModel { input in
                try model.prediction(input: input).var_1150
            }
        },
        BenchmarkModelDescriptor(
            id: "EfficientNetB0_INT8",
            family: .efficientNetB0,
            format: .int8,
            expectedInputDataType: .float16,
            inputPreprocessing: .efficientNetB0Torchvision
        ) { configuration in
            let model = try EfficientNetB0_INT8(configuration: configuration)
            return BenchmarkLoadedModel { input in
                try model.prediction(input: input).var_1150
            }
        }
    ]

    static func resolve(target: BenchmarkTarget) throws -> [BenchmarkModelDescriptor] {
        switch target {
        case .allModels:
            return all
        case .model(let modelID):
            guard let descriptor = descriptor(withID: modelID) else {
                throw PipelineBenchmarkError.modelNotFound(modelID)
            }
            return [descriptor]
        }
    }

    static func descriptor(withID id: String) -> BenchmarkModelDescriptor? {
        all.first(where: { $0.id == id })
    }

    static func descriptor(family: ModelFamily, format: ModelFormat) -> BenchmarkModelDescriptor? {
        all.first { $0.family == family && $0.format == format }
    }
}
