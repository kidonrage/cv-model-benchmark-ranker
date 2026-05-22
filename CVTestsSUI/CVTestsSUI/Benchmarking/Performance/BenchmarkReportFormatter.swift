//
//  BenchmarkReportFormatter.swift
//  CVTestsSUI
//
//  Created by Codex on 13.05.2026.
//

import Foundation

enum BenchmarkReportFormatter {
    private static let dateFormatter = ISO8601DateFormatter()

    static func format(
        records: [BenchmarkResultRecord],
        configuration: BenchmarkRunConfiguration,
        realImageSourceDescription: String?
    ) -> String {
        guard let firstRecord = records.first else {
            return "No benchmark results"
        }

        var lines: [String] = [
            "experiment=\(firstRecord.experimentID) timestamp=\(dateFormatter.string(from: firstRecord.timestamp))",
            "protocol=\(configuration.performanceProtocol.rawValue)",
            "runs=\(configuration.runs) warmup=\(configuration.warmup) input=\(configuration.inputMode.rawValue) measurement=\(configuration.measurementMode.rawValue) compute=\(configuration.computeUnits.reportValue)",
            "note=batteryLevelDelta is a coarse battery diagnostic, not exact energy consumption",
            configuration.inputMode == .realImage
                ? "imageSource=\(realImageSourceDescription ?? "n/a")"
                : "imageSource=n/a"
        ]

        if configuration.inputMode == .realImage && records.contains(where: {
            $0.measuredSegment == .imageLoading
                || $0.measuredSegment == .preprocessing
                || $0.measuredSegment == .postprocessing
        }) {
            lines.append("segmentDetails=image_loading(file decode) preprocessing(cgimage_to_tensor) inference(model.predict) postprocessing(top5 decode) total(end_to_end)")
        }

        lines.append("")

        for record in records {
            lines.append(format(record: record))
        }

        let summaries = summaryLines(for: records)
        if !summaries.isEmpty {
            lines.append("")
            lines += summaries
        }

        return lines.joined(separator: "\n")
    }

    private static func format(record: BenchmarkResultRecord) -> String {
        let commonPrefix = "input=\(record.inputMode.rawValue) segment=\(record.measuredSegment.rawValue) model=\(record.modelName) format=\(record.modelFormat.rawValue) compute=\(record.computeUnits.reportValue) runs=\(record.runsCount) warmup=\(record.warmupCount)"

        guard record.isApplicable else {
            let note = record.note ?? "n/a"
            return "\(commonPrefix) median=n/a mean=n/a p90=n/a p95=n/a stdDev=n/a min=n/a max=n/a note=\(note) \(resourceFields(for: record.resourceDiagnostics))"
        }

        var metrics = [
            "median=\(formatted(record.median ?? .zero))",
            "mean=\(formatted(record.mean ?? .zero))",
            "p90=\(formatted(record.p90 ?? .zero))",
            "p95=\(formatted(record.p95 ?? .zero))",
            "stdDev=\(formatted(record.stdDev ?? .zero))",
            "min=\(formatted(record.min ?? .zero))",
            "max=\(formatted(record.max ?? .zero))",
        ]

        if let pipelineMetrics = record.pipelineMetrics {
            metrics += [
                "totalMeasuredMedian=\(formatted(pipelineMetrics.totalMeasured.medianMs))",
                "sumOfSegmentMedians=\(formatted(pipelineMetrics.sumOfSegmentMediansMs))",
                "pipelineOverheadMedian=\(formatted(pipelineMetrics.pipelineOverheadMedianMs))"
            ]
        }

        metrics.append(resourceFields(for: record.resourceDiagnostics))
        return ([commonPrefix] + metrics).joined(separator: " ")
    }

    private static func summaryLines(for records: [BenchmarkResultRecord]) -> [String] {
        let groupedRecords = Dictionary(grouping: records.filter(\.isApplicable)) {
            "\($0.modelName)|\($0.modelFormat.rawValue)|\($0.computeUnits.reportValue)"
        }

        return groupedRecords.values.compactMap { group in
            let record = group.first(where: { $0.measuredSegment == .total })
                ?? group.first(where: { $0.measuredSegment == .inference })

            guard let record else {
                return nil
            }

            var fields = [
                "summary",
                "model=\(record.modelName)",
                "format=\(record.modelFormat.rawValue)",
                "compute=\(record.computeUnits.reportValue)",
                "segment=\(record.measuredSegment.rawValue)",
                "median=\(formatted(record.median))ms",
                "p90=\(formatted(record.p90))ms",
                "p95=\(formatted(record.p95))ms"
            ]

            if let pipelineMetrics = record.pipelineMetrics {
                fields += [
                    "totalMeasuredMedian=\(formatted(pipelineMetrics.totalMeasured.medianMs))ms",
                    "preprocessingMedian=\(formatted(pipelineMetrics.preprocessing?.medianMs))ms",
                    "inferenceMedian=\(formatted(pipelineMetrics.inference?.medianMs))ms",
                    "overheadMedian=\(formatted(pipelineMetrics.pipelineOverheadMedianMs))ms"
                ]
            }

            return fields.joined(separator: " ")
        }
    }

    private static func resourceFields(for diagnostics: BenchmarkResourceDiagnostics) -> String {
        [
            "thermalStateBefore=\(diagnostics.thermalStateBefore)",
            "thermalStateAfter=\(diagnostics.thermalStateAfter)",
            "thermalStateDidChange=\(diagnostics.thermalStateDidChange)",
            "batteryLevelBefore=\(formatted(diagnostics.batteryLevelBefore))",
            "batteryLevelAfter=\(formatted(diagnostics.batteryLevelAfter))",
            "batteryLevelDelta=\(formatted(diagnostics.batteryLevelDelta))",
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

    private static func formatted(_ value: Double?) -> String {
        guard let value else {
            return "n/a"
        }

        return value.formatted(.number.precision(.fractionLength(2)))
    }

    private static func formatted(_ value: Float?) -> String {
        guard let value else {
            return "n/a"
        }

        return value.formatted(.number.precision(.fractionLength(4)))
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
}
