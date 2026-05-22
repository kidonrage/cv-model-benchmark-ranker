//
//  ImagePreprocessor.swift
//  CVTestsSUI
//
//  Created by Codex on 19.04.2026.
//

import Foundation
import CoreGraphics
import CoreImage
import CoreML

enum ImageResizeInterpolation {
    case bilinear
    case bicubic
}

struct ImagePreprocessingConfiguration {
    let resizeShortSide: Int
    let cropWidth: Int
    let cropHeight: Int
    let interpolation: ImageResizeInterpolation
    let normalization: ImageNormalization?
}

struct ImageNormalization {
    let mean: [Float]
    let standardDeviation: [Float]

    static let imageNetTorchvision = ImageNormalization(
        mean: [0.485, 0.456, 0.406],
        standardDeviation: [0.229, 0.224, 0.225]
    )
}

extension ImagePreprocessingConfiguration {
    static let mobileNetV2Torchvision = ImagePreprocessingConfiguration(
        resizeShortSide: 232,
        cropWidth: BenchmarkDefaults.inputWidth,
        cropHeight: BenchmarkDefaults.inputHeight,
        interpolation: .bilinear,
        normalization: .imageNetTorchvision
    )

    static let efficientNetB0Torchvision = ImagePreprocessingConfiguration(
        resizeShortSide: 256,
        cropWidth: BenchmarkDefaults.inputWidth,
        cropHeight: BenchmarkDefaults.inputHeight,
        interpolation: .bicubic,
        normalization: .imageNetTorchvision
    )
}

struct ImagePreprocessor {
    private let ciContext = CIContext(options: nil)

    func clearCaches() {
        ciContext.clearCaches()
    }

    func makeInputMultiArray(
        from image: CGImage,
        dataType: MLMultiArrayDataType,
        preprocessing: ImagePreprocessingConfiguration
    ) throws -> MLMultiArray {
        let rgbaBytes = try resizedRGBABytes(
            from: image,
            width: preprocessing.cropWidth,
            height: preprocessing.cropHeight,
            resizeShortSide: preprocessing.resizeShortSide,
            interpolation: preprocessing.interpolation
        )

        let array = try MLMultiArray(
            shape: BenchmarkDefaults.inputShape.map { NSNumber(value: $0) },
            dataType: dataType
        )

        let strides = array.strides.map(\.intValue)
        let channelStride = strides[1]
        let rowStride = strides[2]
        let columnStride = strides[3]

        switch dataType {
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            fill(
                pointer: pointer,
                rgbaBytes: rgbaBytes,
                channelStride: channelStride,
                rowStride: rowStride,
                columnStride: columnStride,
                normalization: preprocessing.normalization
            )
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            fill(
                pointer: pointer,
                rgbaBytes: rgbaBytes,
                channelStride: channelStride,
                rowStride: rowStride,
                columnStride: columnStride,
                normalization: preprocessing.normalization
            )
        default:
            throw PipelineBenchmarkError.unsupportedInputDataType(dataType)
        }

        return array
    }

    private func resizedRGBABytes(
        from image: CGImage,
        width: Int,
        height: Int,
        resizeShortSide: Int,
        interpolation: ImageResizeInterpolation
    ) throws -> [UInt8] {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let scale = CGFloat(resizeShortSide) / CGFloat(min(image.width, image.height))
        let scaledWidth = CGFloat(image.width) * scale
        let scaledHeight = CGFloat(image.height) * scale
        let cropRect = CGRect(
            x: (scaledWidth - CGFloat(width)) / 2.0,
            y: (scaledHeight - CGFloat(height)) / 2.0,
            width: CGFloat(width),
            height: CGFloat(height)
        )
        let ciImage = CIImage(cgImage: image)
        let scaledImage = try scaledCIImage(
            from: ciImage,
            scale: scale,
            interpolation: interpolation
        )
        let croppedImage = scaledImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        let rendered = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else {
                return false
            }

            ciContext.render(
                croppedImage,
                toBitmap: baseAddress,
                rowBytes: bytesPerRow,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            return true
        }

        guard rendered else {
            throw PipelineBenchmarkError.failedToCreateImageContext
        }

        return bytes
    }

    private func scaledCIImage(
        from image: CIImage,
        scale: CGFloat,
        interpolation: ImageResizeInterpolation
    ) throws -> CIImage {
        switch interpolation {
        case .bilinear:
            return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        case .bicubic:
            guard let filter = CIFilter(name: "CIBicubicScaleTransform") else {
                throw PipelineBenchmarkError.failedToCreateImageContext
            }
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(scale, forKey: kCIInputScaleKey)
            filter.setValue(1.0, forKey: kCIInputAspectRatioKey)

            guard let outputImage = filter.outputImage else {
                throw PipelineBenchmarkError.failedToCreateImageContext
            }

            return outputImage
        }
    }

    private func fill<T: BinaryFloatingPoint>(
        pointer: UnsafeMutablePointer<T>,
        rgbaBytes: [UInt8],
        channelStride: Int,
        rowStride: Int,
        columnStride: Int,
        normalization: ImageNormalization?
    ) {
        let width = BenchmarkDefaults.inputWidth
        let height = BenchmarkDefaults.inputHeight
        let mean = normalization?.mean ?? [0.0, 0.0, 0.0]
        let standardDeviation = normalization?.standardDeviation ?? [1.0, 1.0, 1.0]

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                let red = normalizedChannelValue(
                    Float(rgbaBytes[pixelIndex]) / 255.0,
                    mean: mean[0],
                    standardDeviation: standardDeviation[0]
                )
                let green = normalizedChannelValue(
                    Float(rgbaBytes[pixelIndex + 1]) / 255.0,
                    mean: mean[1],
                    standardDeviation: standardDeviation[1]
                )
                let blue = normalizedChannelValue(
                    Float(rgbaBytes[pixelIndex + 2]) / 255.0,
                    mean: mean[2],
                    standardDeviation: standardDeviation[2]
                )
                let baseOffset = y * rowStride + x * columnStride

                pointer[baseOffset] = T(red)
                pointer[channelStride + baseOffset] = T(green)
                pointer[channelStride * 2 + baseOffset] = T(blue)
            }
        }
    }

    private func normalizedChannelValue(
        _ channelValue: Float,
        mean: Float,
        standardDeviation: Float
    ) -> Float {
        (channelValue - mean) / standardDeviation
    }
}
