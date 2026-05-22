//
//  ContentView.swift
//  CVTestsSUI
//
//  Created by Vlad Eliseev on 17.01.2026.
//

import SwiftUI
import UIKit

struct ContentView: View {
    private static let allModelsTargetID = "__all_models__"

    @AppStorage("shareLogCount") private var shareLogCount = 5
    @State private var statusText = "Ready to run benchmark"
    @State private var lastLogFileURL: URL?
    @State private var availableLogCount = 0
    @State private var activeSheet: ActiveSheet?
    @State private var appAlert: AppAlert?
    @State private var experimentKind: BenchmarkExperimentKind = .performance
    @State private var performanceProtocol: BenchmarkPerformanceProtocol = .mainBenchmark
    @State private var computeUnits: BenchmarkComputeUnits = BenchmarkPerformanceProtocol.mainBenchmark.defaultComputeUnits
    @State private var selectedTargetID = ContentView.allModelsTargetID
    @State private var availableDatasets: [AccuracyDataset] = []
    @State private var selectedDatasetID = AccuracyBenchmarkDefaults.datasetID
    @State private var isRunning = false

    private let benchmarkService = PipelineBenchmarkService()
    private let accuracyBenchmarkRunner = AccuracyBenchmarkRunner()
    private let datasetManager = DatasetManager()
    private let logStore = BenchmarkLogStore()

    var body: some View {
        NavigationStack {
            VStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox("Configuration") {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("Experiment", selection: $experimentKind) {
                                    ForEach(BenchmarkExperimentKind.allCases) { kind in
                                        Text(kind.title).tag(kind)
                                    }
                                }
                                
                                if experimentKind == .performance {
                                    performanceConfiguration
                                } else {
                                    accuracyConfiguration
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                        GroupBox("Status") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(statusText)
                                    .font(.body.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                
                                if let lastLogFileURL {
                                    Text("Last log: \(lastLogFileURL.lastPathComponent)")
                                        .font(.footnote.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                }
                Button(isRunning ? "Benchmark running..." : "Run measurements") {
                    runMeasurements()
                }
                .disabled(isRunning)
            }
            .navigationTitle("CV Benchmark")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Logs") {
                        refreshLogCount()
                        activeSheet = .sharingSettings
                    }
                }
            }
            .onAppear {
                loadDatasets()
                refreshLogCount()
                applyPerformanceProtocolDefaults()
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .sharingSettings:
                    SharingSettingsView(
                        shareLogCount: $shareLogCount,
                        appAlert: $appAlert,
                        availableLogCount: $availableLogCount,
                        isRunning: isRunning,
                        refreshLogCount: refreshLogCount,
                        openLogsFolder: openLogsFolder,
                        shareLatestLogs: shareLatestLogs
                    )
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

    private var performanceConfiguration: some View {
        Group {
            Picker("Protocol", selection: $performanceProtocol) {
                ForEach(BenchmarkPerformanceProtocol.allCases) { protocolPreset in
                    Text(protocolPreset.title).tag(protocolPreset)
                }
            }
            .onChange(of: performanceProtocol) {
                applyPerformanceProtocolDefaults()
            }

            Picker("Compute units", selection: $computeUnits) {
                ForEach(BenchmarkComputeUnits.allCases) { units in
                    Text(units.title).tag(units)
                }
            }

            Picker("Model", selection: $selectedTargetID) {
                if performanceProtocol.allowsAllModelsTarget {
                    Text("All models").tag(ContentView.allModelsTargetID)
                }

                ForEach(BenchmarkModelCatalog.all, id: \.id) { descriptor in
                    Text(descriptor.displayName).tag(descriptor.id)
                }
            }

            Text(performanceProtocol.description)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(performanceProtocol.recommendedConditions)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Input: \(performanceProtocol.inputMode.title)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Measurement: \(performanceProtocol.measurementMode.title)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Real image source: dataset sample from \(BenchmarkDefaults.realImageDatasetID)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("runs=\(performanceProtocol.runs) warmup=\(performanceProtocol.warmup)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var accuracyConfiguration: some View {
        Group {
            Picker("Dataset", selection: $selectedDatasetID) {
                ForEach(availableDatasets, id: \.id) { dataset in
                    Text(dataset.title).tag(dataset.id)
                }
            }

            Picker("Compute units", selection: $computeUnits) {
                ForEach(BenchmarkComputeUnits.allCases) { units in
                    Text(units.title).tag(units)
                }
            }

            Picker("Model", selection: $selectedTargetID) {
                Text("All models").tag(ContentView.allModelsTargetID)

                ForEach(BenchmarkModelCatalog.all, id: \.id) { descriptor in
                    Text(descriptor.displayName).tag(descriptor.id)
                }
            }

            Text("Measurement: \(MeasurementMode.fullPipeline.title)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Warmup images: \(AccuracyBenchmarkDefaults.warmupImages)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func runMeasurements() {
        if experimentKind == .accuracy {
            runAccuracyBenchmark()
            return
        }

        if performanceProtocol == .sustainedEnergyThermal,
           selectedTargetID == ContentView.allModelsTargetID {
            appAlert = AppAlert(
                title: "Select One Model",
                message: "Sustained energy and thermal protocol must run one model at a time."
            )
            return
        }

        let configuration = BenchmarkRunConfiguration(
            performanceProtocol: performanceProtocol,
            inputMode: performanceProtocol.inputMode,
            measurementMode: performanceProtocol.measurementMode,
            computeUnits: computeUnits,
            target: benchmarkTarget,
            runs: performanceProtocol.runs,
            warmup: performanceProtocol.warmup,
            realImageDatasetID: BenchmarkDefaults.realImageDatasetID
        )

        isRunning = true
        statusText = "\(performanceProtocol.title) running..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try benchmarkService.run(configuration: configuration)
                let logURL = try logStore.writeLog(
                    text: output.reportText,
                    experimentKind: .performance
                )

                DispatchQueue.main.async {
                    lastLogFileURL = logURL
                    refreshLogCount()
                    statusText = "\(performanceProtocol.title) finished. Result saved to \(logURL.lastPathComponent)"
                    isRunning = false
                }
            } catch {
                let errorLogURL = try? logStore.writeLog(
                    text: "Error: \(error.localizedDescription)",
                    experimentKind: .performance
                )

                DispatchQueue.main.async {
                    lastLogFileURL = errorLogURL
                    refreshLogCount()
                    statusText = "\(performanceProtocol.title) failed: \(error.localizedDescription)"
                    isRunning = false
                }
            }
        }
    }

    private var benchmarkTarget: BenchmarkTarget {
        if selectedTargetID == ContentView.allModelsTargetID {
            return .allModels
        }

        return .model(selectedTargetID)
    }

    private func applyPerformanceProtocolDefaults() {
        computeUnits = performanceProtocol.defaultComputeUnits

        if performanceProtocol.allowsAllModelsTarget {
            selectedTargetID = ContentView.allModelsTargetID
            return
        }

        if selectedTargetID == ContentView.allModelsTargetID,
           let firstModelID = BenchmarkModelCatalog.all.first?.id {
            selectedTargetID = firstModelID
        }
    }

    private func runAccuracyBenchmark() {
        let configuration = AccuracyBenchmarkRunConfiguration(
            datasetID: selectedDatasetID,
            computeUnits: computeUnits,
            target: benchmarkTarget,
            warmupImages: AccuracyBenchmarkDefaults.warmupImages
        )

        isRunning = true
        statusText = "Accuracy benchmark running..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let output = try accuracyBenchmarkRunner.run(configuration: configuration)
                let runDate = output.results.first?.timestamp ?? Date()
                let logURL = try logStore.writeLog(
                    text: output.reportText,
                    experimentKind: .accuracy,
                    date: runDate
                )
                let artifactURLs = output.results.flatMap { result in
                    [
                        URL(fileURLWithPath: result.exports.perClassCSVPath),
                        URL(fileURLWithPath: result.exports.mistakesCSVPath),
                        URL(fileURLWithPath: result.exports.debugTop5CSVPath),
                        URL(fileURLWithPath: result.exports.detailsJSONPath)
                    ]
                }
                _ = try? logStore.writeRunArchive(
                    files: [logURL] + artifactURLs,
                    experimentKind: .accuracy,
                    date: runDate
                )

                DispatchQueue.main.async {
                    lastLogFileURL = logURL
                    refreshLogCount()
                    statusText = "Accuracy benchmark finished. Result saved to \(logURL.lastPathComponent)"
                    isRunning = false
                }
            } catch {
                let errorLogURL = try? logStore.writeLog(
                    text: "Error: \(error.localizedDescription)",
                    experimentKind: .accuracy
                )

                DispatchQueue.main.async {
                    lastLogFileURL = errorLogURL
                    refreshLogCount()
                    statusText = "Accuracy benchmark failed: \(error.localizedDescription)"
                    isRunning = false
                }
            }
        }
    }

    private func loadDatasets() {
        do {
            availableDatasets = try datasetManager.availableDatasets()
            if availableDatasets.isEmpty {
                appAlert = AppAlert(
                    title: "Dataset Resources Missing",
                    message: "Dataset resources were not found in the app bundle."
                )
            } else if !availableDatasets.contains(where: { $0.id == selectedDatasetID }) {
                selectedDatasetID = availableDatasets[0].id
            }
        } catch {
            availableDatasets = []
            appAlert = AppAlert(
                title: "Dataset Load Error",
                message: error.localizedDescription
            )
        }
    }

    private func openLogsFolder() {
        do {
            try logStore.removeDocumentExportDirectory()
            let directory = try logStore.logsDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            activeSheet = nil
            guard let bundleID = Bundle.main.bundleIdentifier,
                  let filesURL = URL(string: "shareddocuments://\(bundleID)") else {
                presentLogFolderShareFallback(directory)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                UIApplication.shared.open(filesURL) { opened in
                    if !opened {
                        presentLogFolderShareFallback(directory)
                    }
                }
            }
        } catch {
            appAlert = AppAlert(
                title: "Unable to Open Logs Folder",
                message: error.localizedDescription
            )
        }
    }

    private func presentLogFolderShareFallback(_ directory: URL) {
        activeSheet = nil
        appAlert = AppAlert(
            title: "Unable to Open Files",
            message: "Files did not accept the direct folder request. Open the CVTestsSUI folder manually in Files."
        )
    }

    private func shareLatestLogs() {
        do {
            refreshLogCount()
            shareLogCount = clampedShareLogCount()
            let archiveURL = try logStore.makeArchiveOfLatestLogs(limit: shareLogCount)
            activeSheet = nil

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                activeSheet = .shareItems([archiveURL])
            }
        } catch {
            appAlert = AppAlert(
                title: "Unable to Create ZIP Archive",
                message: error.localizedDescription
            )
        }
    }

    private func refreshLogCount() {
        availableLogCount = (try? logStore.logFileCount()) ?? 0
        shareLogCount = clampedShareLogCount()
    }

    private func clampedShareLogCount() -> Int {
        guard availableLogCount > 0 else {
            return 1
        }

        return min(max(shareLogCount, 1), availableLogCount)
    }
}

private struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private enum ActiveSheet: Identifiable {
    case sharingSettings
    case shareItems([Any])

    var id: String {
        switch self {
        case .sharingSettings:
            return "sharingSettings"
        case .shareItems:
            return "shareItems"
        }
    }
}

private struct SharingSettingsView: View {
    @Binding var shareLogCount: Int
    @Binding var appAlert: AppAlert?
    @Binding var availableLogCount: Int

    let isRunning: Bool
    let refreshLogCount: () -> Void
    let openLogsFolder: () -> Void
    let shareLatestLogs: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var maximumShareCount: Int {
        max(availableLogCount, 1)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sharing") {
                    Text("Available logs: \(availableLogCount)")
                        .foregroundStyle(.secondary)

                    Stepper("Files to share: \(shareLogCount)", value: $shareLogCount, in: 1...maximumShareCount)
                        .disabled(availableLogCount == 0)

                    Button("Open Logs Folder") {
                        openLogsFolder()
                    }

                    Button("Share Last Logs as ZIP") {
                        shareLatestLogs()
                    }
                    .disabled(isRunning || availableLogCount == 0)
                }
            }
            .navigationTitle("Logs")
            .onAppear {
                refreshLogCount()
                clampShareLogCount()
            }
            .onChange(of: availableLogCount) {
                clampShareLogCount()
            }
            .alert(item: $appAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func clampShareLogCount() {
        guard availableLogCount > 0 else {
            shareLogCount = 1
            return
        }

        shareLogCount = min(max(shareLogCount, 1), availableLogCount)
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
