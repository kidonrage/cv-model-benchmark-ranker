//
//  AccuracyBenchmarkRunner.swift
//  CVTestsSUI
//
//  Created by Codex on 19.04.2026.
//

import Foundation
import CoreML
import ImageIO

enum AccuracyBenchmarkError: LocalizedError {
    case imageDecodingFailed(URL)
    case missingImageFile(URL)
    case evaluationUnavailable(String)
    case modelEvaluationUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .imageDecodingFailed(let url):
            return "Failed to decode dataset image: \(url.lastPathComponent)"
        case .missingImageFile(let url):
            return "Dataset image file not found: \(url.path)"
        case .evaluationUnavailable(let fileName):
            return "Evaluation data missing for image: \(fileName)"
        case .modelEvaluationUnavailable(let modelName):
            return "Benchmark data missing for model: \(modelName)"
        }
    }
}

private struct AccuracyImageEvaluation {
    let top1Prediction: RankedPrediction?
    let top5Predictions: [RankedPrediction]
    let restrictedTop1Index: Int
    let isTop1Correct: Bool
    let isTop5Correct: Bool
    let isRestrictedTop1Correct: Bool
}

private struct AccuracySampleMeasurement: Identifiable {
    let imageID: String
    let imagePath: String
    let groundTruthIndex: Int
    let groundTruthLabel: String?
    let groundTruthClassID: String?
    let latencyMs: Double
    let top1Prediction: RankedPrediction?
    let top5Predictions: [RankedPrediction]
    let restrictedTop1Index: Int
    let isTop1Correct: Bool
    let isTop5Correct: Bool
    let isRestrictedTop1Correct: Bool

    var id: String { imageID }
}

private struct AccuracyModelMeasurements {
    let descriptor: BenchmarkModelDescriptor
    let samples: [AccuracySampleMeasurement]
    let resourceDiagnostics: BenchmarkResourceDiagnostics

    var correctTop1: Int {
        samples.reduce(into: 0) { partialResult, sample in
            if sample.isTop1Correct {
                partialResult += 1
            }
        }
    }

    var correctTop5: Int {
        samples.reduce(into: 0) { partialResult, sample in
            if sample.isTop5Correct {
                partialResult += 1
            }
        }
    }

    var correctRestrictedTop1: Int {
        samples.reduce(into: 0) { partialResult, sample in
            if sample.isRestrictedTop1Correct {
                partialResult += 1
            }
        }
    }

    var latencies: [Double] {
        samples.map(\.latencyMs)
    }
}

private struct AccuracyEvaluationPlan {
    let requestedDescriptors: [BenchmarkModelDescriptor]
    let evaluatedDescriptors: [BenchmarkModelDescriptor]
}

struct AccuracyBenchmarkRunner {
    private static let cacheClearInterval = 64
    private static let debugTop5SampleCount = 30

    private let datasetManager = DatasetManager()
    private let preprocessor = ImagePreprocessor()
    private let exporter = AccuracyBenchmarkExporter()
    private let logStore = BenchmarkLogStore()

    func run(configuration: AccuracyBenchmarkRunConfiguration) throws -> AccuracyBenchmarkExecutionOutput {
        let dataset = try datasetManager.dataset(withID: configuration.datasetID)
        let requestedDescriptors = [
            try BenchmarkModelCatalog.requiredDescriptor(withID: configuration.modelID)
        ]
        try dataset.validateForAccuracy(
            modelID: configuration.modelID,
            outputClassCount: requestedDescriptors[0].outputClassCount
        )
        let evaluationPlan = makeEvaluationPlan(requestedDescriptors: requestedDescriptors)
        let labelResolver = try LabelMappingResolver()
        let timestamp = Date()
        let experimentID = UUID().uuidString

        var measurementsByID: [String: AccuracyModelMeasurements] = [:]
        measurementsByID.reserveCapacity(evaluationPlan.evaluatedDescriptors.count)

        for descriptor in evaluationPlan.evaluatedDescriptors {
            let modelConfiguration = MLModelConfiguration()
            modelConfiguration.computeUnits = configuration.computeUnits.mlComputeUnits
            let resourceMonitor = BenchmarkResourceMonitor(modelDescriptor: descriptor)
            resourceMonitor.begin()
            defer {
                resourceMonitor.restoreBatteryMonitoringIfNeeded()
            }
            let model = try descriptor.load(modelConfiguration)
            let measurements = try runAccuracyBenchmark(
                for: descriptor,
                model: model,
                dataset: dataset,
                labelResolver: labelResolver,
                configuration: configuration,
                resourceMonitor: resourceMonitor
            )
            measurementsByID[descriptor.id] = measurements
        }

        var results: [AccuracyBenchmarkResult] = []
        results.reserveCapacity(evaluationPlan.requestedDescriptors.count)

        for descriptor in evaluationPlan.requestedDescriptors {
            guard let measurements = measurementsByID[descriptor.id] else {
                throw AccuracyBenchmarkError.modelEvaluationUnavailable(descriptor.displayName)
            }

            let referenceMeasurements = referenceMeasurements(
                for: descriptor,
                measurementsByID: measurementsByID
            )
            let result = try makeResult(
                from: measurements,
                referenceMeasurements: referenceMeasurements,
                dataset: dataset,
                configuration: configuration,
                experimentID: experimentID,
                timestamp: timestamp
            )
            results.append(result)
        }

        return AccuracyBenchmarkExecutionOutput(
            results: results,
            reportText: AccuracyBenchmarkReportFormatter.format(results: results)
        )
    }

    private func runAccuracyBenchmark(
        for descriptor: BenchmarkModelDescriptor,
        model: BenchmarkLoadedModel,
        dataset: AccuracyDataset,
        labelResolver: LabelMappingResolver,
        configuration: AccuracyBenchmarkRunConfiguration,
        resourceMonitor: BenchmarkResourceMonitor
    ) throws -> AccuracyModelMeasurements {
        try warmup(
            dataset: dataset,
            descriptor: descriptor,
            model: model,
            warmupImages: configuration.warmupImages
        )
        resourceMonitor.recordCheckpoint()

        var samples: [AccuracySampleMeasurement] = []
        samples.reserveCapacity(dataset.items.count)
        let restrictedClassIndices = restrictedClassIndices(for: dataset)

        for (index, item) in dataset.items.enumerated() {
            let sample = try evaluateSample(
                dataset: dataset,
                item: item,
                descriptor: descriptor,
                model: model,
                labelResolver: labelResolver,
                restrictedClassIndices: restrictedClassIndices
            )
            samples.append(sample)

            if (index + 1).isMultiple(of: Self.cacheClearInterval) {
                preprocessor.clearCaches()
                resourceMonitor.recordCheckpoint()
            }
        }

        resourceMonitor.recordCheckpoint()

        return AccuracyModelMeasurements(
            descriptor: descriptor,
            samples: samples,
            resourceDiagnostics: resourceMonitor.finish()
        )
    }

    private func warmup(
        dataset: AccuracyDataset,
        descriptor: BenchmarkModelDescriptor,
        model: BenchmarkLoadedModel,
        warmupImages: Int
    ) throws {
        for (index, item) in dataset.items.prefix(max(0, warmupImages)).enumerated() {
            let result = autoreleasepool { () -> Result<Void, Error> in
                do {
                    let cgImage = try loadImage(at: dataset.imageURL(for: item))
                    let input = try preprocessor.makeInputMultiArray(
                        from: cgImage,
                        dataType: descriptor.expectedInputDataType,
                        preprocessing: descriptor.inputPreprocessing
                    )
                    _ = try model.predict(input)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }

            switch result {
            case .success:
                break
            case .failure(let error):
                throw error
            }

            if (index + 1).isMultiple(of: Self.cacheClearInterval) {
                preprocessor.clearCaches()
            }
        }

        preprocessor.clearCaches()
    }

    private func evaluateSample(
        dataset: AccuracyDataset,
        item: AccuracyDatasetItem,
        descriptor: BenchmarkModelDescriptor,
        model: BenchmarkLoadedModel,
        labelResolver: LabelMappingResolver,
        restrictedClassIndices: [Int]
    ) throws -> AccuracySampleMeasurement {
        let result = autoreleasepool {
            () -> Result<AccuracySampleMeasurement, Error> in
            do {
                let imageURL = try dataset.imageURL(for: item)
                let cgImage = try loadImage(at: imageURL)
                var evaluation: AccuracyImageEvaluation?

                let latency = try measureMilliseconds {
                    evaluation = try evaluateImage(
                        cgImage,
                        item: item,
                        descriptor: descriptor,
                        model: model,
                        labelResolver: labelResolver,
                        restrictedClassIndices: restrictedClassIndices
                    )
                }

                guard let evaluation else {
                    throw AccuracyBenchmarkError.evaluationUnavailable(item.fileName)
                }

                guard let outputIndex = item.outputIndex else {
                    throw DatasetManagerError.datasetOutputIndexMappingMissing(dataset.id)
                }

                let classInfo = dataset.classInfo(for: outputIndex)
                return .success(
                    AccuracySampleMeasurement(
                        imageID: item.id,
                        imagePath: imageURL.path(),
                        groundTruthIndex: outputIndex,
                        groundTruthLabel: nonEmptyLabel(item.displayName) ?? classInfo?.displayName,
                        groundTruthClassID: classInfo?.classId ?? nonEmptyLabel(item.classId),
                        latencyMs: latency,
                        top1Prediction: evaluation.top1Prediction,
                        top5Predictions: evaluation.top5Predictions,
                        restrictedTop1Index: evaluation.restrictedTop1Index,
                        isTop1Correct: evaluation.isTop1Correct,
                        isTop5Correct: evaluation.isTop5Correct,
                        isRestrictedTop1Correct: evaluation.isRestrictedTop1Correct
                    )
                )
            } catch {
                return .failure(error)
            }
        }

        switch result {
        case .success(let sample):
            return sample
        case .failure(let error):
            throw error
        }
    }

    private func evaluateImage(
        _ image: CGImage,
        item: AccuracyDatasetItem,
        descriptor: BenchmarkModelDescriptor,
        model: BenchmarkLoadedModel,
        labelResolver: LabelMappingResolver,
        restrictedClassIndices: [Int]
    ) throws -> AccuracyImageEvaluation {
        let input = try preprocessor.makeInputMultiArray(
            from: image,
            dataType: descriptor.expectedInputDataType,
            preprocessing: descriptor.inputPreprocessing
        )
        let logits = try model.predict(input)
        let predictions = try labelResolver.topPredictions(from: logits, topK: 5)
        let restrictedTop1Index = try labelResolver.bestPredictionIndex(
            from: logits,
            constrainedTo: restrictedClassIndices
        )
        guard let outputIndex = item.outputIndex else {
            throw DatasetManagerError.datasetOutputIndexMappingMissing(item.classId)
        }

        return AccuracyImageEvaluation(
            top1Prediction: predictions.first,
            top5Predictions: predictions,
            restrictedTop1Index: restrictedTop1Index,
            isTop1Correct: predictions.first?.index == outputIndex,
            isTop5Correct: predictions.contains(where: { $0.index == outputIndex }),
            isRestrictedTop1Correct: restrictedTop1Index == outputIndex
        )
    }

    private func makeEvaluationPlan(
        requestedDescriptors: [BenchmarkModelDescriptor]
    ) -> AccuracyEvaluationPlan {
        var evaluatedDescriptors = requestedDescriptors
        var seenIDs = Set(requestedDescriptors.map(\.id))

        for descriptor in requestedDescriptors where descriptor.format != .fp32 {
            guard let referenceDescriptor = BenchmarkModelCatalog.descriptor(
                family: descriptor.family,
                format: .fp32
            ) else {
                continue
            }

            if seenIDs.insert(referenceDescriptor.id).inserted {
                evaluatedDescriptors.append(referenceDescriptor)
            }
        }

        return AccuracyEvaluationPlan(
            requestedDescriptors: requestedDescriptors,
            evaluatedDescriptors: evaluatedDescriptors
        )
    }

    private func referenceMeasurements(
        for descriptor: BenchmarkModelDescriptor,
        measurementsByID: [String: AccuracyModelMeasurements]
    ) -> AccuracyModelMeasurements? {
        guard descriptor.format != .fp32,
              let referenceDescriptor = BenchmarkModelCatalog.descriptor(
                  family: descriptor.family,
                  format: .fp32
              ) else {
            return nil
        }

        return measurementsByID[referenceDescriptor.id]
    }

    private func makeResult(
        from measurements: AccuracyModelMeasurements,
        referenceMeasurements: AccuracyModelMeasurements?,
        dataset: AccuracyDataset,
        configuration: AccuracyBenchmarkRunConfiguration,
        experimentID: String,
        timestamp: Date
    ) throws -> AccuracyBenchmarkResult {
        let latencyStats = BenchStats.make(from: measurements.latencies)
        let perClassResults = makePerClassResults(from: measurements.samples)
        let mistakes = makeMistakeRecords(from: measurements.samples)
        let debugTop5Records = makeDebugTop5Records(from: measurements.samples)
        let baselineComparison = makeBaselineComparison(
            from: measurements,
            referenceMeasurements: referenceMeasurements
        )
        let top1DisagreementCount = disagreementCount(
            lhs: measurements.samples,
            rhs: referenceMeasurements?.samples
        ) { $0.top1Prediction?.index == $1.top1Prediction?.index }
        let top5DisagreementCount = disagreementCount(
            lhs: measurements.samples,
            rhs: referenceMeasurements?.samples
        ) { lhs, rhs in
            lhs.top5Predictions.map(\.index).sorted() == rhs.top5Predictions.map(\.index).sorted()
        }
        let restrictedTop1DisagreementCount = disagreementCount(
            lhs: measurements.samples,
            rhs: referenceMeasurements?.samples
        ) { $0.restrictedTop1Index == $1.restrictedTop1Index }
        let commonImagesCount = commonImageCount(
            lhs: measurements.samples,
            rhs: referenceMeasurements?.samples
        )
        let exports = try exporter.export(
            experimentID: experimentID,
            timestamp: timestamp,
            modelName: measurements.descriptor.family.rawValue,
            modelFormat: measurements.descriptor.format,
            outputDirectory: try logStore.logsDirectory,
            perClassResults: perClassResults,
            mistakes: mistakes,
            debugTop5Records: debugTop5Records,
            baselineComparison: baselineComparison
        )
        let totalImages = measurements.samples.count

        return AccuracyBenchmarkResult(
            experimentID: experimentID,
            timestamp: timestamp,
            datasetName: dataset.metadata.datasetId,
            datasetSubsetID: dataset.metadata.datasetId,
            datasetVersionOrPath: dataset.rootURL.path(),
            datasetImagesPerClass: dataset.metadata.classCount > 0 ? totalImages / max(dataset.metadata.classCount, 1) : 0,
            datasetSelectionRule: "filesystem_discovery",
            subsetSize: totalImages,
            totalImages: totalImages,
            modelName: measurements.descriptor.family.rawValue,
            modelFormat: measurements.descriptor.format,
            computeUnits: configuration.computeUnits,
            measurementMode: .fullPipeline,
            referenceFormat: baselineComparison == nil ? nil : .fp32,
            top1CorrectCount: measurements.correctTop1,
            top5CorrectCount: measurements.correctTop5,
            correctRestrictedTop1: measurements.correctRestrictedTop1,
            top1Accuracy: accuracy(correctCount: measurements.correctTop1, totalCount: totalImages),
            top5Accuracy: accuracy(correctCount: measurements.correctTop5, totalCount: totalImages),
            restrictedTop1Accuracy: accuracy(correctCount: measurements.correctRestrictedTop1, totalCount: totalImages),
            perClassResults: perClassResults,
            mistakes: mistakes,
            debugTop5Records: debugTop5Records,
            baselineComparison: baselineComparison,
            exports: exports,
            top1AgreementVsFP32: baselineComparison?.top1AgreementWithFP32,
            top5AgreementVsFP32: agreementRate(
                disagreementCount: top5DisagreementCount,
                totalCount: commonImagesCount
            ),
            restrictedTop1AgreementVsFP32: agreementRate(
                disagreementCount: restrictedTop1DisagreementCount,
                totalCount: commonImagesCount
            ),
            top1DisagreementCountVsFP32: top1DisagreementCount,
            top5DisagreementCountVsFP32: top5DisagreementCount,
            restrictedTop1DisagreementCountVsFP32: restrictedTop1DisagreementCount,
            meanLatencyMs: latencyStats.mean,
            medianLatencyMs: latencyStats.median,
            p90LatencyMs: latencyStats.p90,
            p95LatencyMs: latencyStats.p95,
            minLatencyMs: latencyStats.min,
            maxLatencyMs: latencyStats.max,
            stdDevLatencyMs: latencyStats.stdDev,
            latencyStats: latencyStats,
            resourceDiagnostics: measurements.resourceDiagnostics
        )
    }

    private func makePerClassResults(
        from samples: [AccuracySampleMeasurement]
    ) -> [ClassAccuracyResult] {
        Dictionary(grouping: samples, by: \.groundTruthIndex)
            .map { classIndex, classSamples in
                let top1CorrectCount = classSamples.reduce(into: 0) { partialResult, sample in
                    if sample.isTop1Correct {
                        partialResult += 1
                    }
                }
                let top5CorrectCount = classSamples.reduce(into: 0) { partialResult, sample in
                    if sample.isTop5Correct {
                        partialResult += 1
                    }
                }
                let representative = classSamples[0]

                return ClassAccuracyResult(
                    classID: representative.groundTruthClassID,
                    classIndex: classIndex,
                    classLabel: representative.groundTruthLabel,
                    totalCount: classSamples.count,
                    top1CorrectCount: top1CorrectCount,
                    top5CorrectCount: top5CorrectCount,
                    top1Accuracy: accuracy(correctCount: top1CorrectCount, totalCount: classSamples.count),
                    top5Accuracy: accuracy(correctCount: top5CorrectCount, totalCount: classSamples.count)
                )
            }
            .sorted { lhs, rhs in
                if lhs.classIndex == rhs.classIndex {
                    return (lhs.classLabel ?? "") < (rhs.classLabel ?? "")
                }
                return lhs.classIndex < rhs.classIndex
            }
    }

    private func makeMistakeRecords(
        from samples: [AccuracySampleMeasurement]
    ) -> [PredictionMistakeRecord] {
        samples.compactMap { sample in
            guard !sample.isTop1Correct else {
                return nil
            }

            return PredictionMistakeRecord(
                imageID: sample.imageID,
                imagePath: sample.imagePath,
                groundTruthIndex: sample.groundTruthIndex,
                groundTruthLabel: sample.groundTruthLabel,
                predictedTop1Index: sample.top1Prediction?.index,
                predictedTop1Label: sample.top1Prediction?.label,
                predictedTop1Score: sample.top1Prediction?.score,
                top5Indices: sample.top5Predictions.map(\.index),
                top5Labels: sample.top5Predictions.map(\.label),
                top5Scores: sample.top5Predictions.map(\.score),
                isTop5Correct: sample.isTop5Correct
            )
        }
    }

    private func makeDebugTop5Records(
        from samples: [AccuracySampleMeasurement]
    ) -> [AccuracyDebugTop5Record] {
        samples.prefix(Self.debugTop5SampleCount).map { sample in
            AccuracyDebugTop5Record(
                imageID: sample.imageID,
                imagePath: sample.imagePath,
                groundTruthIndex: sample.groundTruthIndex,
                groundTruthLabel: sample.groundTruthLabel,
                top1Index: sample.top1Prediction?.index,
                top1Label: sample.top1Prediction?.label,
                top5Labels: sample.top5Predictions.map(\.label),
                isTop1Correct: sample.isTop1Correct,
                isTop5Correct: sample.isTop5Correct
            )
        }
    }

    private func makeBaselineComparison(
        from measurements: AccuracyModelMeasurements,
        referenceMeasurements: AccuracyModelMeasurements?
    ) -> PrecisionBaselineComparison? {
        guard let referenceMeasurements else {
            return nil
        }

        let samplePairs = commonImagePairs(
            lhs: measurements.samples,
            rhs: referenceMeasurements.samples
        )
        guard !samplePairs.isEmpty else {
            return nil
        }

        var sameTop1PredictionCount = 0
        var improvedVsFP32Count = 0
        var regressedVsFP32Count = 0
        var sameCorrectnessCount = 0

        for pair in samplePairs {
            if pair.lhs.top1Prediction?.index == pair.rhs.top1Prediction?.index {
                sameTop1PredictionCount += 1
            }
            if pair.lhs.isTop1Correct == pair.rhs.isTop1Correct {
                sameCorrectnessCount += 1
            }
            if !pair.rhs.isTop1Correct && pair.lhs.isTop1Correct {
                improvedVsFP32Count += 1
            }
            if pair.rhs.isTop1Correct && !pair.lhs.isTop1Correct {
                regressedVsFP32Count += 1
            }
        }

        let commonImagesCount = samplePairs.count
        return PrecisionBaselineComparison(
            modelName: measurements.descriptor.family.rawValue,
            comparedPrecision: measurements.descriptor.format.rawValue,
            baselinePrecision: ModelFormat.fp32.rawValue,
            commonImagesCount: commonImagesCount,
            sameTop1PredictionCount: sameTop1PredictionCount,
            top1AgreementWithFP32: accuracy(correctCount: sameTop1PredictionCount, totalCount: commonImagesCount),
            changedTop1PredictionCount: commonImagesCount - sameTop1PredictionCount,
            improvedVsFP32Count: improvedVsFP32Count,
            regressedVsFP32Count: regressedVsFP32Count,
            sameCorrectnessCount: sameCorrectnessCount
        )
    }

    private func commonImagePairs(
        lhs: [AccuracySampleMeasurement],
        rhs: [AccuracySampleMeasurement]
    ) -> [(lhs: AccuracySampleMeasurement, rhs: AccuracySampleMeasurement)] {
        let rhsByImageID = Dictionary(uniqueKeysWithValues: rhs.map { ($0.imageID, $0) })
        return lhs.compactMap { lhsSample in
            guard let rhsSample = rhsByImageID[lhsSample.imageID] else {
                return nil
            }

            return (lhs: lhsSample, rhs: rhsSample)
        }
    }

    private func commonImageCount(
        lhs: [AccuracySampleMeasurement],
        rhs: [AccuracySampleMeasurement]?
    ) -> Int {
        guard let rhs else {
            return 0
        }

        return commonImagePairs(lhs: lhs, rhs: rhs).count
    }

    private func disagreementCount(
        lhs: [AccuracySampleMeasurement],
        rhs: [AccuracySampleMeasurement]?,
        compare: (AccuracySampleMeasurement, AccuracySampleMeasurement) -> Bool
    ) -> Int? {
        guard let rhs else {
            return nil
        }

        return commonImagePairs(lhs: lhs, rhs: rhs).reduce(into: 0) { partialResult, pair in
            if !compare(pair.lhs, pair.rhs) {
                partialResult += 1
            }
        }
    }

    private func restrictedClassIndices(for dataset: AccuracyDataset) -> [Int] {
        Array(Set(dataset.items.compactMap(\.outputIndex))).sorted()
    }

    private func accuracy(correctCount: Int, totalCount: Int) -> Double {
        precondition(totalCount > 0, "accuracy benchmark dataset must not be empty")
        return Double(correctCount) / Double(totalCount)
    }

    private func agreementRate(
        disagreementCount: Int?,
        totalCount: Int
    ) -> Double? {
        guard let disagreementCount, totalCount > 0 else {
            return nil
        }

        return Double(totalCount - disagreementCount) / Double(totalCount)
    }

    private func nonEmptyLabel(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }

        return value
    }

    private func loadImage(at url: URL) throws -> CGImage {
        guard FileManager.default.fileExists(atPath: url.path()) else {
            throw AccuracyBenchmarkError.missingImageFile(url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AccuracyBenchmarkError.imageDecodingFailed(url)
        }

        return image
    }
}
