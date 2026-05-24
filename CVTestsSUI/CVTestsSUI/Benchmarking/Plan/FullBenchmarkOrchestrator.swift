//
//  FullBenchmarkOrchestrator.swift
//  CVTestsSUI
//
//  Created by Codex on 23.05.2026.
//

import Foundation
import UIKit
enum FullBenchmarkEvent: Sendable {
    case progress(FullBenchmarkProgress)
    case completed(BenchmarkResultsEnvelope)
}
// swiftlint:disable:next type_body_length
struct FullBenchmarkOrchestrator {
    private let planLoader = BenchmarkPlanLoader()
    private let manifestLoader = ModelsManifestLoader()
    private let validator = BenchmarkPlanValidator()
    private let datasetManager = DatasetManager()
    private let performanceRunner = PipelineBenchmarkService()
    private let accuracyRunner = AccuracyBenchmarkRunner()
    private let logStore = BenchmarkLogStore()

    static func eventStream() -> AsyncThrowingStream<FullBenchmarkEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task(priority: .userInitiated) {
                do {
                    let orchestrator = FullBenchmarkOrchestrator()
                    let envelope = try await orchestrator.runFullPlan { progress in
                        continuation.yield(.progress(progress))
                    }
                    continuation.yield(.completed(envelope))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func readinessSnapshot() -> BenchmarkReadinessSnapshot {
        let manifestFound = manifestLoader.exists()
        let planFound = planLoader.exists()
        let manifest = try? manifestLoader.load()
        let plan = try? planLoader.load()
        let modelErrors = manifest?.models.compactMap { model -> String? in
            guard model.supported else {
                return "\(model.id): unsupported"
            }

            guard BenchmarkModelCatalog.descriptor(withID: model.id) != nil else {
                return "\(model.id): not wired into app catalog"
            }

            guard manifest?.preprocessingProfiles[model.preprocessingProfile] != nil else {
                return "\(model.id): missing preprocessing profile \(model.preprocessingProfile)"
            }

            return nil
        } ?? []

        return BenchmarkReadinessSnapshot(
            manifestFound: manifestFound,
            planFound: planFound,
            modelCount: manifest?.models.count ?? 0,
            experimentCount: plan?.experiments.count ?? 0,
            planId: plan?.planId,
            modelErrors: modelErrors
        )
    }

    // swiftlint:disable:next function_body_length
    func runFullPlan(
        progressHandler: @escaping @Sendable (FullBenchmarkProgress) async -> Void
    ) async throws -> BenchmarkResultsEnvelope {
        let startedAt = Date()
        let thermalStateAtStart = BenchmarkDeviceStateReporter.thermalState(ProcessInfo.processInfo.thermalState)
        let plan = try planLoader.load()
        let manifest = try manifestLoader.load()
        try validator.validate(plan: plan, manifest: manifest)

        let manifestModelsByID = Dictionary(uniqueKeysWithValues: manifest.models.map { ($0.id, $0) })
        var runs: [BenchmarkRunResult] = []
        runs.reserveCapacity(plan.experiments.count)

        for (index, experiment) in plan.experiments.enumerated() {
            try Task.checkCancellation()
            await progressHandler(
                FullBenchmarkProgress(
                    currentExperimentIndex: index + 1,
                    totalExperiments: plan.experiments.count,
                    modelId: experiment.modelId,
                    measurementMode: experiment.measurementMode.rawValue,
                    computeUnits: experiment.computeUnits.reportValue
                )
            )

            guard let manifestModel = manifestModelsByID[experiment.modelId] else {
                runs.append(
                    failedRun(
                        for: experiment,
                        manifestModel: nil,
                        error: BenchmarkPlanValidationError.unknownModelID(experiment.modelId)
                    )
                )
                continue
            }

            do {
                let run = try runExperiment(
                    experiment,
                    plan: plan,
                    manifestModel: manifestModel
                )
                runs.append(run)
            } catch {
                runs.append(failedRun(for: experiment, manifestModel: manifestModel, error: error))
            }
        }

        let finishedAt = Date()
        let failedCount = runs.filter { $0.status == .failed }.count
        let status: FullBenchmarkState = failedCount == 0 ? .completed : .completedWithFailures
        return BenchmarkResultsEnvelope(
            schemaVersion: "1.0",
            benchmarkInfo: BenchmarkInfo(
                benchmarkAppVersion: appVersion(),
                planId: plan.planId,
                startedAt: startedAt.formatted(.iso8601),
                finishedAt: finishedAt.formatted(.iso8601),
                status: status
            ),
            device: BenchmarkDeviceInfo(
                name: UIDevice.current.name,
                modelIdentifier: deviceModelIdentifier(),
                systemName: UIDevice.current.systemName,
                systemVersion: UIDevice.current.systemVersion,
                thermalStateAtStart: thermalStateAtStart,
                thermalStateAtEnd: BenchmarkDeviceStateReporter.thermalState(ProcessInfo.processInfo.thermalState)
            ),
            plan: BenchmarkPlanSummary(
                experimentsTotal: plan.experiments.count,
                experimentsSucceeded: runs.count - failedCount,
                experimentsFailed: failedCount
            ),
            runs: runs
        )
    }

    private func runExperiment(
        _ experiment: BenchmarkPlanExperiment,
        plan: BenchmarkPlan,
        manifestModel: ManifestModel
    ) throws -> BenchmarkRunResult {
        switch experiment.benchmarkType {
        case .performance:
            return try runPerformanceExperiment(experiment, plan: plan, manifestModel: manifestModel)
        case .accuracy:
            return try runAccuracyExperiment(experiment, plan: plan, manifestModel: manifestModel)
        }
    }

    private func runPerformanceExperiment(
        _ experiment: BenchmarkPlanExperiment,
        plan: BenchmarkPlan,
        manifestModel: ManifestModel
    ) throws -> BenchmarkRunResult {
        let datasetID = experiment.datasetId ?? plan.datasetId ?? BenchmarkDefaults.realImageDatasetID
        let dataset = try datasetManager.dataset(withID: datasetID)
        try dataset.validateForPerformance()
        let configuration = BenchmarkRunConfiguration(
            modelID: experiment.modelId,
            inputMode: experiment.inputMode.benchmarkInputMode,
            measurementMode: experiment.measurementMode,
            computeUnits: experiment.computeUnits,
            runs: experiment.measuredRuns ?? BenchmarkDefaults.runs,
            warmup: experiment.warmupRuns ?? BenchmarkDefaults.warmup,
            realImageDatasetID: datasetID
        )
        let output = try performanceRunner.run(configuration: configuration)
        let logURL = try? logStore.writeLog(text: output.reportText, experimentKind: .performance)
        return successfulRun(
            for: experiment,
            manifestModel: manifestModel,
            datasetID: datasetID,
            datasetSummary: datasetSummary(for: dataset, datasetID: datasetID, plan: plan),
            protocolSummary: BenchmarkProtocolSummary(
                warmupRuns: configuration.warmup,
                measuredRuns: configuration.runs,
                warmupImages: nil
            ),
            latency: latencySummary(from: output.records),
            accuracy: nil,
            diagnostics: output.records.first.map {
                BenchmarkRunDiagnostics.from($0.resourceDiagnostics, hasSustainedBenchmark: false)
            } ?? BenchmarkRunDiagnostics.capture(hasSustainedBenchmark: false),
            artifacts: BenchmarkArtifacts(
                legacyTextLogPath: logURL?.path(),
                csvPath: nil,
                mistakesJsonPath: nil
            )
        )
    }

    // swiftlint:disable:next function_body_length
    private func runAccuracyExperiment(
        _ experiment: BenchmarkPlanExperiment,
        plan: BenchmarkPlan,
        manifestModel: ManifestModel
    ) throws -> BenchmarkRunResult {
        let datasetID = experiment.datasetId ?? plan.datasetId ?? AccuracyBenchmarkDefaults.datasetID
        let descriptor = try BenchmarkModelCatalog.requiredDescriptor(withID: experiment.modelId)
        let dataset = try datasetManager.dataset(withID: datasetID)
        try dataset.validateForAccuracy(
            modelID: experiment.modelId,
            outputClassCount: descriptor.outputClassCount
        )
        let configuration = AccuracyBenchmarkRunConfiguration(
            datasetID: datasetID,
            computeUnits: experiment.computeUnits,
            modelID: experiment.modelId,
            warmupImages: experiment.warmupImages ?? AccuracyBenchmarkDefaults.warmupImages
        )
        let output = try accuracyRunner.run(configuration: configuration)
        guard let result = output.results.first else {
            throw AccuracyBenchmarkError.modelEvaluationUnavailable(experiment.modelId)
        }

        let logURL = try? logStore.writeLog(
            text: output.reportText,
            experimentKind: .accuracy,
            date: result.timestamp
        )

        return successfulRun(
            for: experiment,
            manifestModel: manifestModel,
            datasetID: datasetID,
            datasetSummary: datasetSummary(for: dataset, datasetID: datasetID, plan: plan),
            protocolSummary: BenchmarkProtocolSummary(
                warmupRuns: nil,
                measuredRuns: nil,
                warmupImages: configuration.warmupImages
            ),
            latency: BenchmarkLatencySummary(
                meanMs: result.meanLatencyMs,
                medianMs: result.medianLatencyMs,
                p90Ms: result.p90LatencyMs,
                p95Ms: result.p95LatencyMs,
                minMs: result.minLatencyMs,
                maxMs: result.maxLatencyMs,
                stdDevMs: result.stdDevLatencyMs,
                fullPipelineMedianMs: result.medianLatencyMs,
                inferenceMedianMs: nil,
                preprocessingMedianMs: nil,
                postprocessingMedianMs: nil,
                imageLoadingMedianMs: nil
            ),
            accuracy: BenchmarkAccuracySummary(
                top1: result.top1Accuracy,
                top5: result.top5Accuracy,
                restrictedTop1: result.restrictedTop1Accuracy,
                totalImages: result.totalImages,
                correctTop1: result.top1CorrectCount,
                correctTop5: result.top5CorrectCount,
                correctRestrictedTop1: result.correctRestrictedTop1,
                perClassAccuracy: result.perClassResults.map {
                    BenchmarkPerClassAccuracySummary(
                        classId: $0.classID,
                        displayName: $0.classLabel,
                        outputIndex: $0.classIndex,
                        totalImages: $0.totalCount,
                        correctTop1: $0.top1CorrectCount,
                        correctTop5: $0.top5CorrectCount,
                        top1: $0.top1Accuracy,
                        top5: $0.top5Accuracy
                    )
                }
            ),
            diagnostics: BenchmarkRunDiagnostics.from(result.resourceDiagnostics, hasSustainedBenchmark: false),
            artifacts: BenchmarkArtifacts(
                legacyTextLogPath: logURL?.path(),
                csvPath: result.exports.perClassCSVPath,
                mistakesJsonPath: result.exports.detailsJSONPath
            )
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func successfulRun(
        for experiment: BenchmarkPlanExperiment,
        manifestModel: ManifestModel,
        datasetID: String?,
        datasetSummary: BenchmarkDatasetSummary?,
        protocolSummary: BenchmarkProtocolSummary?,
        latency: BenchmarkLatencySummary?,
        accuracy: BenchmarkAccuracySummary?,
        diagnostics: BenchmarkRunDiagnostics?,
        artifacts: BenchmarkArtifacts
    ) -> BenchmarkRunResult {
        BenchmarkRunResult(
            experimentId: experiment.experimentId,
            status: .success,
            modelId: experiment.modelId,
            family: manifestModel.family,
            format: manifestModel.format,
            optimizationType: manifestModel.optimizationType,
            computeUnits: experiment.computeUnits.reportValue,
            measurementMode: experiment.measurementMode.rawValue,
            datasetId: datasetID,
            dataset: datasetSummary,
            modelSizeMb: manifestModel.modelSizeMb,
            protocol: protocolSummary,
            latency: latency,
            accuracy: accuracy,
            diagnostics: diagnostics,
            artifacts: artifacts,
            error: nil
        )
    }

    private func failedRun(
        for experiment: BenchmarkPlanExperiment,
        manifestModel: ManifestModel?,
        error: Error
    ) -> BenchmarkRunResult {
        BenchmarkRunResult(
            experimentId: experiment.experimentId,
            status: .failed,
            modelId: experiment.modelId,
            family: manifestModel?.family ?? "",
            format: manifestModel?.format ?? "",
            optimizationType: manifestModel?.optimizationType ?? "",
            computeUnits: experiment.computeUnits.reportValue,
            measurementMode: experiment.measurementMode.rawValue,
            datasetId: experiment.datasetId,
            dataset: nil,
            modelSizeMb: manifestModel?.modelSizeMb,
            protocol: nil,
            latency: nil,
            accuracy: nil,
            diagnostics: BenchmarkRunDiagnostics.capture(hasSustainedBenchmark: false),
            artifacts: .empty,
            error: BenchmarkRunError(code: errorCode(for: error), message: error.localizedDescription)
        )
    }
}

private extension FullBenchmarkOrchestrator {
    private func latencySummary(from records: [BenchmarkResultRecord]) -> BenchmarkLatencySummary? {
        let total = record(for: .total, in: records)
        let inference = record(for: .inference, in: records)
        let preprocessing = record(for: .preprocessing, in: records)
        let postprocessing = record(for: .postprocessing, in: records)
        let imageLoading = record(for: .imageLoading, in: records)
        let primary = total ?? inference ?? records.first

        guard primary != nil else {
            return nil
        }

        return BenchmarkLatencySummary(
            meanMs: primary?.mean,
            medianMs: primary?.median,
            p90Ms: primary?.p90,
            p95Ms: primary?.p95,
            minMs: primary?.min,
            maxMs: primary?.max,
            stdDevMs: primary?.stdDev,
            fullPipelineMedianMs: total?.median,
            inferenceMedianMs: inference?.median ?? total?.pipelineMetrics?.inference?.medianMs,
            preprocessingMedianMs: preprocessing?.median ?? total?.pipelineMetrics?.preprocessing?.medianMs,
            postprocessingMedianMs: postprocessing?.median ?? total?.pipelineMetrics?.postprocessing?.medianMs,
            imageLoadingMedianMs: imageLoading?.median ?? total?.pipelineMetrics?.imageLoading?.medianMs
        )
    }

    private func record(
        for segment: MeasuredSegment,
        in records: [BenchmarkResultRecord]
    ) -> BenchmarkResultRecord? {
        records.first { $0.measuredSegment == segment && $0.isApplicable }
    }

    private func datasetSummary(
        for dataset: AccuracyDataset,
        datasetID: String,
        plan: BenchmarkPlan
    ) -> BenchmarkDatasetSummary {
        BenchmarkDatasetSummary(
            datasetId: datasetID,
            source: dataset.metadata.source,
            taskType: dataset.metadata.taskType,
            imageCount: dataset.metadata.imageCount,
            classCount: dataset.metadata.classCount,
            hasGroundTruth: dataset.metadata.hasGroundTruth,
            hasOutputIndexMapping: dataset.metadata.hasOutputIndexMapping,
            role: plan.datasets?.role(for: datasetID) ?? .unspecified,
            classes: dataset.metadata.classes.map {
                BenchmarkDatasetClassSummary(
                    classId: $0.classId,
                    displayName: $0.displayName,
                    outputIndex: $0.outputIndex,
                    imageCount: $0.imageCount
                )
            }
        )
    }

    private func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else {
                return
            }
            identifier.append(String(UnicodeScalar(UInt8(value))))
        }
    }

    private func errorCode(for error: Error) -> String {
        switch error {
        case BenchmarkPlanLoadError.configFileMissing(let fileName):
            return "\(fileName)_not_found"
        case BenchmarkPlanValidationError.unknownModelID:
            return "unknown_model_id"
        case BenchmarkPlanValidationError.preprocessingProfileMissing:
            return "preprocessing_profile_not_found"
        case BenchmarkPlanValidationError.missingDatasetID:
            return "dataset_id_missing"
        case PipelineBenchmarkError.modelNotFound:
            return "model_not_found"
        case DatasetManagerError.datasetNotFound:
            return "dataset_not_found"
        case DatasetManagerError.datasetEmpty:
            return "dataset_empty"
        case DatasetManagerError.datasetHasNoClassFolders:
            return "dataset_missing_class_folders"
        case DatasetManagerError.datasetOutputIndexMappingMissing:
            return "dataset_output_index_mapping_missing"
        case DatasetManagerError.datasetOutputIndexOutOfRange:
            return "dataset_output_index_out_of_range"
        case AccuracyBenchmarkError.missingImageFile:
            return "dataset_image_not_found"
        case AccuracyBenchmarkError.imageDecodingFailed:
            return "dataset_image_decode_failed"
        default:
            return "benchmark_runner_error"
        }
    }
}
