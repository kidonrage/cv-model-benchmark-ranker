//
//  AccuracyBenchmarkReportFormatter.swift
//  CVTestsSUI
//
//  Created by Codex on 13.05.2026.
//

import Foundation

enum AccuracyBenchmarkReportFormatter {
    private static let dateFormatter = ISO8601DateFormatter()

    static func format(results: [AccuracyBenchmarkResult]) -> String {
        guard let first = results.first else {
            return "No accuracy benchmark results"
        }

        var lines: [String] = [
            "experiment=\(first.experimentID) timestamp=\(dateFormatter.string(from: first.timestamp))",
            "dataset=\(first.datasetName) subset=\(first.datasetSubsetID) size=\(first.subsetSize) images_per_class=\(first.datasetImagesPerClass) measurement=\(first.measurementMode.rawValue)",
            "note=batteryLevelDelta is a coarse battery diagnostic, not exact energy consumption",
            "selection_rule=\"\(escaped(first.datasetSelectionRule))\"",
            ""
        ]

        if first.computeUnits == .all {
            lines.insert(
                "note=compute=ALL reflects deployment behavior on available accelerators; it is not an isolated arithmetic-precision measurement",
                at: 2
            )
        }

        for result in results {
            lines.append(format(result: result))
        }

        lines.append("")
        lines += results.map(summaryLine)

        return lines.joined(separator: "\n")
    }

    private static func format(result: AccuracyBenchmarkResult) -> String {
        var line = [
            "dataset=\(result.datasetName)",
            "subset=\(result.datasetSubsetID)",
            "version=\(result.datasetVersionOrPath)",
            "model=\(result.modelName)",
            "format=\(result.modelFormat.rawValue)",
            "compute=\(result.computeUnits.reportValue)",
            "total_images=\(result.totalImages)",
            "top1=\(result.top1CorrectCount)/\(result.totalImages)",
            "top1_acc=\(formatted(result.top1Accuracy, precision: 4))",
            "restricted_top1=\(result.correctRestrictedTop1)/\(result.totalImages)",
            "restricted_top1_acc=\(formatted(result.restrictedTop1Accuracy, precision: 4))",
            "top5=\(result.top5CorrectCount)/\(result.totalImages)",
            "top5_acc=\(formatted(result.top5Accuracy, precision: 4))",
            "mean=\(formatted(result.meanLatencyMs))ms",
            "median=\(formatted(result.medianLatencyMs))ms",
            "p90=\(formatted(result.p90LatencyMs))ms",
            "p95=\(formatted(result.p95LatencyMs))ms",
            "stdDev=\(formatted(result.stdDevLatencyMs))ms",
            "min=\(formatted(result.minLatencyMs))ms",
            "max=\(formatted(result.maxLatencyMs))ms",
            resourceFields(for: result.resourceDiagnostics)
        ]
        .joined(separator: " ")

        if let referenceFormat = result.referenceFormat,
           let top1Agreement = result.top1AgreementVsFP32,
           let restrictedTop1Agreement = result.restrictedTop1AgreementVsFP32,
           let top5Agreement = result.top5AgreementVsFP32,
           let top1DisagreementCount = result.top1DisagreementCountVsFP32,
           let restrictedTop1DisagreementCount = result.restrictedTop1DisagreementCountVsFP32,
           let top5DisagreementCount = result.top5DisagreementCountVsFP32,
           let commonImagesCount = result.baselineComparison?.commonImagesCount {
            line += " " + [
                "ref=\(referenceFormat.rawValue)",
                "top1_agree=\(formatted(top1Agreement, precision: 4))",
                "top1_diff=\(top1DisagreementCount)/\(commonImagesCount)",
                "restricted_top1_agree=\(formatted(restrictedTop1Agreement, precision: 4))",
                "restricted_top1_diff=\(restrictedTop1DisagreementCount)/\(commonImagesCount)",
                "top5_agree=\(formatted(top5Agreement, precision: 4))",
                "top5_diff=\(top5DisagreementCount)/\(commonImagesCount)"
            ]
            .joined(separator: " ")
        }

        line += "\n" + [
            "diagnostics",
            "model=\(result.modelName)",
            "format=\(result.modelFormat.rawValue)",
            "per_class=\(result.perClassResults.count)",
            "top1_mistakes=\(result.mistakes.count)",
            "mistakes_csv=\"\(escaped(result.exports.mistakesCSVPath))\"",
            "per_class_csv=\"\(escaped(result.exports.perClassCSVPath))\"",
            "debug_top5_csv=\"\(escaped(result.exports.debugTop5CSVPath))\"",
            "details_json=\"\(escaped(result.exports.detailsJSONPath))\""
        ]
        .joined(separator: " ")

        if let baselineComparison = result.baselineComparison {
            line += "\n" + [
                "baseline_compare",
                "model=\(baselineComparison.modelName)",
                "compared=\(baselineComparison.comparedPrecision)",
                "baseline=\(baselineComparison.baselinePrecision)",
                "common=\(baselineComparison.commonImagesCount)",
                "same_top1=\(baselineComparison.sameTop1PredictionCount)",
                "top1_agree=\(formatted(baselineComparison.top1AgreementWithFP32, precision: 4))",
                "changed_top1=\(baselineComparison.changedTop1PredictionCount)",
                "improved=\(baselineComparison.improvedVsFP32Count)",
                "regressed=\(baselineComparison.regressedVsFP32Count)",
                "same_correctness=\(baselineComparison.sameCorrectnessCount)"
            ]
            .joined(separator: " ")
        }

        return line
    }

    private static func summaryLine(_ result: AccuracyBenchmarkResult) -> String {
        [
            "summary",
            "model=\(result.modelName)",
            "format=\(result.modelFormat.rawValue)",
            "compute=\(result.computeUnits.reportValue)",
            "total_images=\(result.totalImages)",
            "top1=\(result.top1CorrectCount)",
            "top5=\(result.top5CorrectCount)",
            "top1_acc=\(formatted(result.top1Accuracy, precision: 4))",
            "top5_acc=\(formatted(result.top5Accuracy, precision: 4))",
            "median=\(formatted(result.medianLatencyMs))ms",
            "p90=\(formatted(result.p90LatencyMs))ms",
            "p95=\(formatted(result.p95LatencyMs))ms"
        ]
        .joined(separator: " ")
    }

    private static func resourceFields(for diagnostics: BenchmarkResourceDiagnostics) -> String {
        [
            "thermalStateBefore=\(diagnostics.thermalStateBefore)",
            "thermalStateAfter=\(diagnostics.thermalStateAfter)",
            "thermalStateDidChange=\(diagnostics.thermalStateDidChange)",
            "batteryLevelBefore=\(formatted(diagnostics.batteryLevelBefore, precision: 4))",
            "batteryLevelAfter=\(formatted(diagnostics.batteryLevelAfter, precision: 4))",
            "batteryLevelDelta=\(formatted(diagnostics.batteryLevelDelta, precision: 4))",
            "batteryStateBefore=\(diagnostics.batteryStateBefore)",
            "batteryStateAfter=\(diagnostics.batteryStateAfter)",
            "residentMemoryBeforeBytes=\(formatted(diagnostics.residentMemoryBeforeBytes))",
            "residentMemoryAfterBytes=\(formatted(diagnostics.residentMemoryAfterBytes))",
            "residentMemoryDeltaBytes=\(formatted(diagnostics.residentMemoryDeltaBytes))",
            "maxObservedResidentMemoryBytes=\(formatted(diagnostics.maxObservedResidentMemoryBytes))",
            "modelSizeBytes=\(formatted(diagnostics.modelSizeBytes))"
        ]
        .joined(separator: " ")
    }

    private static func formatted(_ value: Double, precision: Int = 2) -> String {
        value.formatted(.number.precision(.fractionLength(precision)))
    }

    private static func formatted(_ value: Float?, precision: Int) -> String {
        guard let value else {
            return "n/a"
        }

        return value.formatted(.number.precision(.fractionLength(precision)))
    }

    private static func formatted(_ value: UInt64?) -> String {
        guard let value else {
            return "n/a"
        }

        return String(value)
    }

    private static func formatted(_ value: Int64?) -> String {
        guard let value else {
            return "n/a"
        }

        return String(value)
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
