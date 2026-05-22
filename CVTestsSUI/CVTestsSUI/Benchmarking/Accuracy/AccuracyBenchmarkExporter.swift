//
//  AccuracyBenchmarkExporter.swift
//  CVTestsSUI
//
//  Created by Codex on 19.05.2026.
//

import Foundation

struct AccuracyBenchmarkExporter {
    private struct DetailsPayload: Encodable {
        let experimentID: String
        let timestamp: Date
        let modelName: String
        let modelFormat: String
        let perClassResults: [ClassAccuracyResult]
        let mistakes: [PredictionMistakeRecord]
        let debugTop5Records: [AccuracyDebugTop5Record]
        let baselineComparison: PrecisionBaselineComparison?
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func export(
        experimentID: String,
        timestamp: Date,
        modelName: String,
        modelFormat: ModelFormat,
        outputDirectory: URL,
        perClassResults: [ClassAccuracyResult],
        mistakes: [PredictionMistakeRecord],
        debugTop5Records: [AccuracyDebugTop5Record],
        baselineComparison: PrecisionBaselineComparison?
    ) throws -> AccuracyBenchmarkExports {
        let exportDirectory = outputDirectory
        let artifactPrefix = makeArtifactPrefix(
            experimentID: experimentID,
            timestamp: timestamp,
            modelName: modelName,
            modelFormat: modelFormat
        )
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let perClassCSVURL = exportDirectory.appending(path: "\(artifactPrefix)-accuracy_per_class.csv")
        let mistakesCSVURL = exportDirectory.appending(path: "\(artifactPrefix)-accuracy_mistakes.csv")
        let debugTop5CSVURL = exportDirectory.appending(path: "\(artifactPrefix)-accuracy_debug_top5.csv")
        let detailsJSONURL = exportDirectory.appending(path: "\(artifactPrefix)-accuracy_details.json")

        try makePerClassCSV(from: perClassResults).write(to: perClassCSVURL, atomically: true, encoding: .utf8)
        try makeMistakesCSV(from: mistakes).write(to: mistakesCSVURL, atomically: true, encoding: .utf8)
        try makeDebugTop5CSV(from: debugTop5Records).write(to: debugTop5CSVURL, atomically: true, encoding: .utf8)
        try makeDetailsJSON(
            experimentID: experimentID,
            timestamp: timestamp,
            modelName: modelName,
            modelFormat: modelFormat,
            perClassResults: perClassResults,
            mistakes: mistakes,
            debugTop5Records: debugTop5Records,
            baselineComparison: baselineComparison
        )
        .write(to: detailsJSONURL, options: .atomic)

        return AccuracyBenchmarkExports(
            directoryPath: exportDirectory.path(),
            perClassCSVPath: perClassCSVURL.path(),
            mistakesCSVPath: mistakesCSVURL.path(),
            debugTop5CSVPath: debugTop5CSVURL.path(),
            detailsJSONPath: detailsJSONURL.path()
        )
    }

    private func makePerClassCSV(from results: [ClassAccuracyResult]) -> String {
        let rows = results.map { result in
            csvRow([
                result.classID ?? "",
                String(result.classIndex),
                result.classLabel ?? "",
                String(result.totalCount),
                String(result.top1CorrectCount),
                String(result.top5CorrectCount),
                decimal(result.top1Accuracy),
                decimal(result.top5Accuracy)
            ])
        }

        return ([csvRow([
            "classId",
            "classIndex",
            "classLabel",
            "totalCount",
            "top1CorrectCount",
            "top5CorrectCount",
            "top1Accuracy",
            "top5Accuracy"
        ])] + rows).joined(separator: "\n")
    }

    private func makeMistakesCSV(from records: [PredictionMistakeRecord]) -> String {
        let rows = records.map { record in
            csvRow([
                record.imagePath,
                record.imageID,
                String(record.groundTruthIndex),
                record.groundTruthLabel ?? "",
                record.predictedTop1Index.map(String.init) ?? "",
                record.predictedTop1Label ?? "",
                record.predictedTop1Score.map(decimal) ?? "",
                join(record.top5Indices.map(String.init)),
                join(record.top5Labels),
                join(record.top5Scores.map(decimal)),
                String(record.isTop5Correct)
            ])
        }

        return ([csvRow([
            "imagePath",
            "imageId",
            "groundTruthIndex",
            "groundTruthLabel",
            "predictedTop1Index",
            "predictedTop1Label",
            "predictedTop1Score",
            "top5Indices",
            "top5Labels",
            "top5Scores",
            "isTop5Correct"
        ])] + rows).joined(separator: "\n")
    }

    private func makeDebugTop5CSV(from records: [AccuracyDebugTop5Record]) -> String {
        let rows = records.map { record in
            csvRow([
                record.imagePath,
                record.imageID,
                String(record.groundTruthIndex),
                record.groundTruthLabel ?? "",
                record.top1Index.map(String.init) ?? "",
                record.top1Label ?? "",
                join(record.top5Labels),
                String(record.isTop1Correct),
                String(record.isTop5Correct)
            ])
        }

        return ([csvRow([
            "imagePath",
            "imageId",
            "groundTruthIndex",
            "groundTruthLabel",
            "top1Index",
            "top1Label",
            "top5Labels",
            "isTop1Correct",
            "isTop5Correct"
        ])] + rows).joined(separator: "\n")
    }

    private func makeDetailsJSON(
        experimentID: String,
        timestamp: Date,
        modelName: String,
        modelFormat: ModelFormat,
        perClassResults: [ClassAccuracyResult],
        mistakes: [PredictionMistakeRecord],
        debugTop5Records: [AccuracyDebugTop5Record],
        baselineComparison: PrecisionBaselineComparison?
    ) throws -> Data {
        let payload = DetailsPayload(
            experimentID: experimentID,
            timestamp: timestamp,
            modelName: modelName,
            modelFormat: modelFormat.rawValue,
            perClassResults: perClassResults,
            mistakes: mistakes,
            debugTop5Records: debugTop5Records,
            baselineComparison: baselineComparison
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private func makeArtifactPrefix(
        experimentID: String,
        timestamp: Date,
        modelName: String,
        modelFormat: ModelFormat
    ) -> String {
        let safeModelName = sanitize(modelName)
        return "benchmark-accuracy-\(Self.fileTimestampFormatter.string(from: timestamp))-\(safeModelName)-\(modelFormat.rawValue)-\(experimentID.prefix(8))"
    }

    private func csvRow(_ values: [String]) -> String {
        values.map(csvField).joined(separator: ",")
    }

    private func csvField(_ value: String) -> String {
        let escaped = value.replacing("\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func join(_ values: [String]) -> String {
        values.joined(separator: "|")
    }

    private func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(6)))
    }

    private func sanitize(_ value: String) -> String {
        value.replacing(" ", with: "_")
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
