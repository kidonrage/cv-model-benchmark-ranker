//
//  ContentView.swift
//  CVTestsSUI
//
//  Created by Vlad Eliseev on 17.01.2026.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @State private var viewModel = FullBenchmarkViewModel()
    @State private var activeSheet: ActiveSheet?
    @State private var appAlert: AppAlert?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    planSummary
                    readinessSummary
                    controls
                    progressSummary
                    resultSummary
                    debugSection
                }
                .padding()
            }
            .navigationTitle("CV Benchmark")
            .onAppear {
                viewModel.refreshReadiness()
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .shareItems(let items):
                    ActivityView(activityItems: items)
                }
            }
            .alert(item: $appAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var planSummary: some View {
        GroupBox("Benchmark Plan") {
            VStack(alignment: .leading, spacing: 10) {
                labeledValue("Plan ID", viewModel.readiness.planId ?? "unknown")
                labeledValue("Models in manifest", viewModel.readiness.modelCount.formatted(.number))
                labeledValue("Experiments in plan", viewModel.readiness.experimentCount.formatted(.number))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var readinessSummary: some View {
        GroupBox("Readiness") {
            VStack(alignment: .leading, spacing: 10) {
                readinessRow(title: "Manifest", isReady: viewModel.readiness.manifestFound)
                readinessRow(title: "Benchmark plan", isReady: viewModel.readiness.planFound)
                readinessRow(title: "Models", isReady: viewModel.readiness.modelsReady)

                if !viewModel.readiness.modelErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.readiness.modelErrors, id: \.self) { error in
                            Text(error)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                viewModel.runFullBenchmark()
            } label: {
                Text(viewModel.state == .running ? "Benchmark running..." : "Run full benchmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canRunBenchmark)

            Button {
                exportResults()
            } label: {
                Text("Export results")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!viewModel.canExportResults)
        }
    }

    private var progressSummary: some View {
        GroupBox("Progress") {
            VStack(alignment: .leading, spacing: 10) {
                if let progress = viewModel.progress {
                    ProgressView(
                        value: Double(progress.currentExperimentIndex),
                        total: Double(max(progress.totalExperiments, 1))
                    )
                    labeledValue(
                        "Experiment",
                        [
                            progress.currentExperimentIndex.formatted(.number),
                            progress.totalExperiments.formatted(.number)
                        ].joined(separator: " / ")
                    )
                    labeledValue("Model ID", progress.modelId)
                    labeledValue("Measurement mode", progress.measurementMode)
                    labeledValue("Compute units", progress.computeUnits)
                } else {
                    Text("No benchmark progress yet")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resultSummary: some View {
        GroupBox("Last Result") {
            VStack(alignment: .leading, spacing: 10) {
                labeledValue("Status", viewModel.state.title)

                if let lastResults = viewModel.lastResults {
                    labeledValue("Succeeded", lastResults.plan.experimentsSucceeded.formatted(.number))
                    labeledValue("Failed", lastResults.plan.experimentsFailed.formatted(.number))
                    labeledValue("Schema", lastResults.schemaVersion)
                }

                if let error = viewModel.lastErrorMessage {
                    Text(error)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let exportedURL = viewModel.exportedResultsURL {
                    Text("Exported: \(exportedURL.lastPathComponent)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var debugSection: some View {
        DisclosureGroup("Debug / Advanced") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Manual model selection is no longer the primary path. " +
                    "This build runs experiments from benchmark_plan.json and exports " +
                    "benchmark_results.json for analyze_results.sh."
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Refresh readiness") {
                    viewModel.refreshReadiness()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.body.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func readinessRow(title: String, isReady: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(isReady ? "found" : "not found")
                .font(.body.monospaced())
                .foregroundStyle(isReady ? .green : .red)
        }
    }

    private func exportResults() {
        do {
            let url = try viewModel.exportResults()
            activeSheet = .shareItems([url])
            appAlert = AppAlert(
                title: "Export Ready",
                message: "Share benchmark_results.json and pass it to analyze_results.sh."
            )
        } catch {
            appAlert = AppAlert(
                title: "Export Failed",
                message: error.localizedDescription
            )
        }
    }
}

private struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum ActiveSheet: Identifiable {
    case shareItems([Any])

    var id: String {
        switch self {
        case .shareItems:
            return "shareItems"
        }
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)

        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX,
                y: controller.view.bounds.midY,
                width: 1,
                height: 1
            )
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
