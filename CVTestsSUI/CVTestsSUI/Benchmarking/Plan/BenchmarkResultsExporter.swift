//
//  BenchmarkResultsExporter.swift
//  CVTestsSUI
//
//  Created by Codex on 23.05.2026.
//

import Foundation

struct BenchmarkResultsExporter {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func export(_ envelope: BenchmarkResultsEnvelope) throws -> URL {
        let directory = fileManager.temporaryDirectory.appending(path: "BenchmarkResults", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appending(
            path: fileName(planId: envelope.benchmarkInfo.planId),
            directoryHint: .notDirectory
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func fileName(planId: String, date: Date = Date()) -> String {
        let safePlanId = sanitize(planId)
        let timestamp = sanitize(date.formatted(.iso8601))
        return "benchmark_results_\(safePlanId)_\(timestamp).json"
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacing(":", with: "")
            .replacing("/", with: "-")
            .replacing(" ", with: "_")
    }
}
