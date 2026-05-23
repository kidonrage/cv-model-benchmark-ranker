//
//  PipelineBenchmarkService.swift
//  CVTestsSUI
//
//  Created by Codex on 19.04.2026.
//

import Foundation
import CoreML
import ImageIO

enum PipelineBenchmarkError: LocalizedError {
    case modelNotFound(String)
    case realImageDatasetEmpty(String)
    case realImageDecodeFailed(String)
    case failedToCreateImageContext
    case unsupportedInputDataType(MLMultiArrayDataType)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let modelID):
            return "Model not found: \(modelID)"
        case .realImageDatasetEmpty(let datasetID):
            return "Dataset has no images for performance benchmark: \(datasetID)"
        case .realImageDecodeFailed(let description):
            return "Unable to decode benchmark image: \(description)"
        case .failedToCreateImageContext:
            return "Failed to create image preprocessing context"
        case .unsupportedInputDataType(let dataType):
            return "Unsupported input data type: \(dataType.rawValue)"
        }
    }
}

private struct BenchmarkRealImageSource {
    let datasetID: String
    let fileName: String
    let fileURL: URL
    let cgImage: CGImage

    var reportDescription: String {
        "dataset=\(datasetID) file=\(fileName)"
    }
}

private struct PipelineBenchmarkMeasurements {
    let totalMeasured: SegmentBenchmark?
    let segments: [SegmentBenchmark]
    let pipelineMetrics: PipelineLatencyMetrics?

    var allBenchmarks: [SegmentBenchmark] {
        let benchmarks = (totalMeasured.map { [$0] } ?? []) + segments
        var uniqueSegments = Set<MeasuredSegment>()
        return benchmarks.filter { uniqueSegments.insert($0.segment).inserted }
    }
}

struct PipelineBenchmarkService {
    private static let sustainedCacheMaintenanceStride = 100

    private let datasetManager = DatasetManager()
    private let preprocessor = ImagePreprocessor()

    func run(configuration: BenchmarkRunConfiguration) throws -> BenchmarkExecutionOutput {
        let descriptor = try BenchmarkModelCatalog.requiredDescriptor(withID: configuration.modelID)
        let sourceImage = try loadSourceImageIfNeeded(configuration: configuration)

        let experimentID = UUID().uuidString
        let timestamp = Date()
        var records: [BenchmarkResultRecord] = []

        let modelConfiguration = MLModelConfiguration()
        modelConfiguration.computeUnits = configuration.computeUnits.mlComputeUnits
        let resourceMonitor = BenchmarkResourceMonitor(modelDescriptor: descriptor)
        resourceMonitor.begin()
        defer {
            resourceMonitor.restoreBatteryMonitoringIfNeeded()
        }

        let context = try PipelineBenchmarkContext(
            descriptor: descriptor,
            model: descriptor.load(modelConfiguration),
            configuration: configuration,
            sourceImage: sourceImage,
            preprocessor: preprocessor
        )
        let measurements = try measurements(for: context, resourceMonitor: resourceMonitor)
        let resourceDiagnostics = resourceMonitor.finish()
        records = measurements.allBenchmarks.map {
            makeRecord(
                from: $0,
                descriptor: descriptor,
                configuration: configuration,
                experimentID: experimentID,
                timestamp: timestamp,
                resourceDiagnostics: resourceDiagnostics,
                pipelineMetrics: $0.segment == .total ? measurements.pipelineMetrics : nil
            )
        }

        return BenchmarkExecutionOutput(
            records: records,
            reportText: BenchmarkReportFormatter.format(
                records: records,
                configuration: configuration,
                realImageSourceDescription: sourceImage?.reportDescription
            )
        )
    }

    private func loadSourceImageIfNeeded(
        configuration: BenchmarkRunConfiguration
    ) throws -> BenchmarkRealImageSource? {
        guard configuration.inputMode == .realImage else {
            return nil
        }

        let dataset = try datasetManager.dataset(withID: configuration.realImageDatasetID)
        guard let item = dataset.items.first else {
            throw PipelineBenchmarkError.realImageDatasetEmpty(configuration.realImageDatasetID)
        }

        let imageURL = try dataset.imageURL(for: item)
        return BenchmarkRealImageSource(
            datasetID: dataset.id,
            fileName: item.fileName,
            fileURL: imageURL,
            cgImage: try PipelineBenchmarkContext.decodeCGImage(at: imageURL)
        )
    }

    private func measurements(
        for context: PipelineBenchmarkContext,
        resourceMonitor: BenchmarkResourceMonitor
    ) throws -> PipelineBenchmarkMeasurements {
        switch context.configuration.measurementMode {
        case .inferenceOnly:
            let input = try context.makePreparedInput()
            return PipelineBenchmarkMeasurements(
                totalMeasured: nil,
                segments: [try measure(.inference, context: context, resourceMonitor: resourceMonitor) {
                    _ = try context.predict(input)
                }],
                pipelineMetrics: nil
            )
        case .fullPipeline:
            let totalMeasured = try measure(.total, context: context, resourceMonitor: resourceMonitor) {
                try context.runFullPipeline()
            }
            let segmentMeasurements = try collectPipelineSegments(
                context: context,
                resourceMonitor: resourceMonitor
            )
            return PipelineBenchmarkMeasurements(
                totalMeasured: totalMeasured,
                segments: segmentMeasurements,
                pipelineMetrics: makePipelineMetrics(
                    totalMeasured: totalMeasured,
                    segments: segmentMeasurements
                )
            )
        case .segmented:
            let segmentMeasurements = try collectPipelineSegments(
                context: context,
                resourceMonitor: resourceMonitor
            )
            let totalMeasured = segmentMeasurements.first { $0.segment == .total }
            return PipelineBenchmarkMeasurements(
                totalMeasured: totalMeasured,
                segments: segmentMeasurements,
                pipelineMetrics: makePipelineMetrics(
                    totalMeasured: totalMeasured,
                    segments: segmentMeasurements
                )
            )
        }
    }

    private func collectPipelineSegments(
        context: PipelineBenchmarkContext,
        resourceMonitor: BenchmarkResourceMonitor
    ) throws -> [SegmentBenchmark] {
        try MeasuredSegment.allCases.map { segment in
            try measureSegment(segment, context: context, resourceMonitor: resourceMonitor)
        }
    }

    private func measureSegment(
        _ segment: MeasuredSegment,
        context: PipelineBenchmarkContext,
        resourceMonitor: BenchmarkResourceMonitor
    ) throws -> SegmentBenchmark {
        switch segment {
        case .imageLoading where context.configuration.inputMode == .synthetic:
            return .notApplicable(
                segment: segment,
                note: "synthetic input does not require image loading"
            )
        case .preprocessing where context.configuration.inputMode == .synthetic:
            return .notApplicable(
                segment: segment,
                note: "synthetic input does not require preprocessing"
            )
        case .imageLoading:
            return try measure(segment, context: context, resourceMonitor: resourceMonitor) {
                _ = try context.decodeSourceImage()
            }
        case .preprocessing:
            return try measure(segment, context: context, resourceMonitor: resourceMonitor) {
                _ = try context.makePreparedInput()
            }
        case .inference:
            let input = try context.makePreparedInput()
            return try measure(segment, context: context, resourceMonitor: resourceMonitor) {
                _ = try context.predict(input)
            }
        case .postprocessing:
            let output = try context.predict(context.makePreparedInput())
            return try measure(segment, context: context, resourceMonitor: resourceMonitor) {
                try context.decodeTopPredictions(from: output)
            }
        case .total:
            return try measure(segment, context: context, resourceMonitor: resourceMonitor) {
                try context.runFullPipeline()
            }
        }
    }

    private func measure(
        _ segment: MeasuredSegment,
        context: PipelineBenchmarkContext,
        resourceMonitor: BenchmarkResourceMonitor,
        block: () throws -> Void
    ) rethrows -> SegmentBenchmark {
        try benchmarkSegment(
            segment,
            runs: context.configuration.runs,
            warmup: context.configuration.warmup,
            afterWarmup: {
                resourceMonitor.recordCheckpoint()
            },
            afterMeasuredRun: { runIndex, totalRuns in
                if shouldSampleMeasuredRun(runIndex: runIndex, totalRuns: totalRuns) {
                    resourceMonitor.recordCheckpoint()
                }
                if shouldClearCaches(runIndex: runIndex, context: context) {
                    context.clearTransientCaches()
                }
            },
            block: block
        )
    }

    private func makeRecord(
        from measurement: SegmentBenchmark,
        descriptor: BenchmarkModelDescriptor,
        configuration: BenchmarkRunConfiguration,
        experimentID: String,
        timestamp: Date,
        resourceDiagnostics: BenchmarkResourceDiagnostics,
        pipelineMetrics: PipelineLatencyMetrics?
    ) -> BenchmarkResultRecord {
        BenchmarkResultRecord(
            inputMode: configuration.inputMode,
            measuredSegment: measurement.segment,
            modelName: descriptor.family.rawValue,
            modelFormat: descriptor.format,
            computeUnits: configuration.computeUnits,
            runsCount: configuration.runs,
            warmupCount: configuration.warmup,
            median: measurement.stats?.median,
            mean: measurement.stats?.mean,
            p90: measurement.stats?.p90,
            p95: measurement.stats?.p95,
            min: measurement.stats?.min,
            max: measurement.stats?.max,
            stdDev: measurement.stats?.stdDev,
            latencyStats: measurement.stats,
            pipelineMetrics: pipelineMetrics,
            timestamp: timestamp,
            experimentID: experimentID,
            isApplicable: measurement.isApplicable,
            note: measurement.note,
            resourceDiagnostics: resourceDiagnostics
        )
    }

    private func makePipelineMetrics(
        totalMeasured: SegmentBenchmark?,
        segments: [SegmentBenchmark]
    ) -> PipelineLatencyMetrics? {
        guard let totalMeasuredStats = totalMeasured?.stats else {
            return nil
        }

        let imageLoading = stats(for: .imageLoading, in: segments)
        let preprocessing = stats(for: .preprocessing, in: segments)
        let inference = stats(for: .inference, in: segments)
        let postprocessing = stats(for: .postprocessing, in: segments)
        let sumOfSegmentMediansMs = [
            imageLoading?.medianMs,
            preprocessing?.medianMs,
            inference?.medianMs,
            postprocessing?.medianMs
        ]
        .compactMap { $0 }
        .reduce(0, +)

        return PipelineLatencyMetrics(
            totalMeasured: totalMeasuredStats,
            imageLoading: imageLoading,
            preprocessing: preprocessing,
            inference: inference,
            postprocessing: postprocessing,
            sumOfSegmentMediansMs: sumOfSegmentMediansMs,
            pipelineOverheadMedianMs: totalMeasuredStats.medianMs - sumOfSegmentMediansMs
        )
    }

    private func stats(
        for segment: MeasuredSegment,
        in benchmarks: [SegmentBenchmark]
    ) -> LatencyStats? {
        benchmarks.first(where: { $0.segment == segment })?.stats
    }

    private func shouldSampleMeasuredRun(runIndex: Int, totalRuns: Int) -> Bool {
        guard totalRuns > 0 else {
            return false
        }

        let sampleStride = max(1, totalRuns / 5)
        return runIndex == totalRuns || runIndex.isMultiple(of: sampleStride)
    }

    private func shouldClearCaches(runIndex: Int, context: PipelineBenchmarkContext) -> Bool {
        context.configuration.runs >= Self.sustainedCacheMaintenanceStride
            && runIndex.isMultiple(of: Self.sustainedCacheMaintenanceStride)
    }
}

private struct PipelineBenchmarkContext {
    let descriptor: BenchmarkModelDescriptor
    let model: BenchmarkLoadedModel
    let configuration: BenchmarkRunConfiguration
    let sourceImage: BenchmarkRealImageSource?
    let preprocessor: ImagePreprocessor
    let labelResolver: LabelMappingResolver

    init(
        descriptor: BenchmarkModelDescriptor,
        model: BenchmarkLoadedModel,
        configuration: BenchmarkRunConfiguration,
        sourceImage: BenchmarkRealImageSource?,
        preprocessor: ImagePreprocessor
    ) throws {
        self.descriptor = descriptor
        self.model = model
        self.configuration = configuration
        self.sourceImage = sourceImage
        self.preprocessor = preprocessor
        labelResolver = try LabelMappingResolver()
    }

    func decodeSourceImage() throws -> CGImage {
        try Self.decodeCGImage(at: requiredSourceImage().fileURL)
    }

    func makePreparedInput() throws -> MLMultiArray {
        switch configuration.inputMode {
        case .synthetic:
            return try makeSyntheticInput()
        case .realImage:
            return try preprocessor.makeInputMultiArray(
                from: requiredSourceImage().cgImage,
                dataType: descriptor.expectedInputDataType,
                preprocessing: descriptor.inputPreprocessing
            )
        }
    }

    func predict(_ input: MLMultiArray) throws -> MLMultiArray {
        try model.predict(input)
    }

    func decodeTopPredictions(from output: MLMultiArray) throws {
        _ = try labelResolver.topPredictions(from: output, topK: 5)
    }

    func runFullPipeline() throws {
        let input: MLMultiArray
        switch configuration.inputMode {
        case .synthetic:
            input = try makeSyntheticInput()
        case .realImage:
            input = try preprocessor.makeInputMultiArray(
                from: decodeSourceImage(),
                dataType: descriptor.expectedInputDataType,
                preprocessing: descriptor.inputPreprocessing
            )
        }

        try decodeTopPredictions(from: model.predict(input))
    }

    func clearTransientCaches() {
        preprocessor.clearCaches()
    }

    static func decodeCGImage(at url: URL) throws -> CGImage {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw PipelineBenchmarkError.realImageDecodeFailed(url.lastPathComponent)
        }

        return cgImage
    }

    private func makeSyntheticInput() throws -> MLMultiArray {
        let input = try MLMultiArray(
            shape: BenchmarkDefaults.inputShape.map { NSNumber(value: $0) },
            dataType: descriptor.expectedInputDataType
        )
        input.fill(with: 0.5)
        return input
    }

    private func requiredSourceImage() throws -> BenchmarkRealImageSource {
        guard let sourceImage else {
            throw PipelineBenchmarkError.realImageDatasetEmpty(configuration.realImageDatasetID)
        }
        return sourceImage
    }
}
