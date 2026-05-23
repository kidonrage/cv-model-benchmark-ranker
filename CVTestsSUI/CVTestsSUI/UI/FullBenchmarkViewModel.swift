//
//  FullBenchmarkViewModel.swift
//  CVTestsSUI
//
//  Created by Codex on 23.05.2026.
//

import Foundation
import Observation

@MainActor
@Observable
final class FullBenchmarkViewModel {
    var readiness = BenchmarkReadinessSnapshot(
        manifestFound: false,
        planFound: false,
        modelCount: 0,
        experimentCount: 0,
        planId: nil,
        modelErrors: []
    )
    var state: FullBenchmarkState = .idle
    var progress: FullBenchmarkProgress?
    var lastErrorMessage: String?
    var lastResults: BenchmarkResultsEnvelope?
    var exportedResultsURL: URL?

    var canRunBenchmark: Bool {
        state != .running && state != .validatingPlan && readiness.manifestFound && readiness.planFound
    }

    var canExportResults: Bool {
        guard let lastResults else {
            return false
        }

        return lastResults.plan.experimentsSucceeded > 0 || !lastResults.runs.isEmpty
    }

    func refreshReadiness() {
        readiness = FullBenchmarkOrchestrator().readinessSnapshot()
    }

    func runFullBenchmark() {
        guard state != .running && state != .validatingPlan else {
            return
        }

        state = .validatingPlan
        progress = nil
        lastErrorMessage = nil
        lastResults = nil
        exportedResultsURL = nil

        Task {
            do {
                for try await event in FullBenchmarkOrchestrator.eventStream() {
                    switch event {
                    case .progress(let newProgress):
                        state = .running
                        progress = newProgress
                    case .completed(let envelope):
                        lastResults = envelope
                        state = envelope.benchmarkInfo.status
                        refreshReadiness()
                    }
                }
            } catch {
                state = .failed
                lastErrorMessage = error.localizedDescription
                refreshReadiness()
            }
        }
    }

    func exportResults() throws -> URL {
        guard let lastResults else {
            throw BenchmarkResultsExportError.noResultsAvailable
        }

        let url = try BenchmarkResultsExporter().export(lastResults)
        exportedResultsURL = url
        return url
    }
}

enum BenchmarkResultsExportError: LocalizedError {
    case noResultsAvailable

    var errorDescription: String? {
        switch self {
        case .noResultsAvailable:
            return "No benchmark results are available for export"
        }
    }
}
