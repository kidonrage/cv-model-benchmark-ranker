//
//  DatasetManager.swift
//  CVTestsSUI
//
//  Created by Codex on 19.04.2026.
//

import Foundation

enum DatasetTaskType: String, Encodable, Decodable, Sendable {
    case classification
}

enum DatasetRole: String, Encodable, Decodable, Sendable {
    case primary
    case validation
    case hard
    case smoke
    case unspecified
}

enum DatasetManagerError: LocalizedError {
    case resourcesDirectoryMissing
    case datasetsDirectoryMissing
    case datasetNotFound(String)
    case datasetRootMissing(URL)
    case datasetEmpty(String)
    case datasetHasNoClassFolders(String)
    case datasetOutputIndexMappingMissing(String)
    case datasetOutputIndexOutOfRange(datasetID: String, modelID: String, maxOutputIndex: Int, outputClassCount: Int)
    case datasetImageMissing(String)

    var errorDescription: String? {
        switch self {
        case .resourcesDirectoryMissing:
            return "Dataset resources directory not found in app bundle"
        case .datasetsDirectoryMissing:
            return "Datasets directory not found in app bundle"
        case .datasetNotFound(let datasetID):
            return "Dataset not found in app bundle: \(datasetID)"
        case .datasetRootMissing(let url):
            return "Dataset root directory does not exist: \(url.path)"
        case .datasetEmpty(let datasetID):
            return "Dataset has no images: \(datasetID)"
        case .datasetHasNoClassFolders(let datasetID):
            return "Dataset has no class folders: \(datasetID)"
        case .datasetOutputIndexMappingMissing(let datasetID):
            return "Dataset has no valid output index mapping for accuracy: \(datasetID)"
        case .datasetOutputIndexOutOfRange(let datasetID, let modelID, let maxOutputIndex, let outputClassCount):
            return "Dataset \(datasetID) requires output index \(maxOutputIndex), but model \(modelID) exposes only \(outputClassCount) outputs"
        case .datasetImageMissing(let fileName):
            return "Dataset image not found in app bundle: \(fileName)"
        }
    }
}

struct DatasetClassMetadata: Encodable, Sendable {
    let classId: String
    let displayName: String
    let outputIndex: Int?
    let imageCount: Int
}

struct DatasetMetadata: Encodable, Sendable {
    let datasetId: String
    let source: String
    let taskType: DatasetTaskType
    let imageCount: Int
    let classCount: Int
    let hasGroundTruth: Bool
    let hasOutputIndexMapping: Bool
    let classes: [DatasetClassMetadata]

    var maxOutputIndex: Int? {
        classes.compactMap(\.outputIndex).max()
    }
}

struct AccuracyDatasetItem: Identifiable, Sendable {
    let relativePath: String
    let fileName: String
    let classId: String
    let displayName: String
    let outputIndex: Int?

    var id: String { relativePath }
}

struct AccuracyDataset: Identifiable, Sendable {
    let metadata: DatasetMetadata
    let items: [AccuracyDatasetItem]
    let rootURL: URL
    private let fileManager = FileManager.default

    var id: String { metadata.datasetId }
    var title: String { "\(metadata.datasetId) (\(metadata.imageCount) images)" }

    func imageURL(for item: AccuracyDatasetItem) throws -> URL {
        let nestedURL = rootURL.appendingPathComponent(item.relativePath)
        if fileManager.fileExists(atPath: nestedURL.path) {
            return nestedURL
        }

        throw DatasetManagerError.datasetImageMissing(item.fileName)
    }

    func classInfo(for outputIndex: Int) -> DatasetClassMetadata? {
        metadata.classes.first { $0.outputIndex == outputIndex }
    }

    func validateForPerformance() throws {
        guard !items.isEmpty else {
            throw DatasetManagerError.datasetEmpty(metadata.datasetId)
        }
    }

    func validateForAccuracy(modelID: String, outputClassCount: Int) throws {
        try validateForPerformance()

        guard metadata.classCount > 0 else {
            throw DatasetManagerError.datasetHasNoClassFolders(metadata.datasetId)
        }

        guard metadata.hasOutputIndexMapping,
              items.allSatisfy({ $0.outputIndex != nil }) else {
            throw DatasetManagerError.datasetOutputIndexMappingMissing(metadata.datasetId)
        }

        if let maxOutputIndex = metadata.maxOutputIndex,
           maxOutputIndex >= outputClassCount {
            throw DatasetManagerError.datasetOutputIndexOutOfRange(
                datasetID: metadata.datasetId,
                modelID: modelID,
                maxOutputIndex: maxOutputIndex,
                outputClassCount: outputClassCount
            )
        }
    }
}

struct DatasetManager {
    private let fileManager = FileManager.default
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func availableDatasets() throws -> [AccuracyDataset] {
        let rootURL = try datasetsRootURL()
        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { isDirectory($0) }
        .map { try loadDataset(at: $0) }
        .sorted { $0.metadata.datasetId < $1.metadata.datasetId }
    }

    func dataset(withID datasetID: String) throws -> AccuracyDataset {
        guard let dataset = try availableDatasets().first(where: { $0.metadata.datasetId == datasetID }) else {
            throw DatasetManagerError.datasetNotFound(datasetID)
        }

        return dataset
    }

    private func datasetsRootURL() throws -> URL {
        guard let resourceRoot = bundle.resourceURL else {
            throw DatasetManagerError.resourcesDirectoryMissing
        }

        let directURL = resourceRoot.appendingPathComponent("Datasets", isDirectory: true)
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        guard let enumerator = fileManager.enumerator(
            at: resourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DatasetManagerError.datasetsDirectoryMissing
        }

        while let candidate = enumerator.nextObject() as? URL {
            if candidate.lastPathComponent == "Datasets", isDirectory(candidate) {
                return candidate
            }
        }

        throw DatasetManagerError.datasetsDirectoryMissing
    }

    private func loadDataset(at rootURL: URL) throws -> AccuracyDataset {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            throw DatasetManagerError.datasetRootMissing(rootURL)
        }

        let datasetID = rootURL.lastPathComponent
        let classDirectories = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { isDirectory($0) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var classes: [DatasetClassMetadata] = []
        var items: [AccuracyDatasetItem] = []

        for classURL in classDirectories {
            let parsed = parseClassFolderName(classURL.lastPathComponent)
            let imageURLs = try fileManager.contentsOfDirectory(
                at: classURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { isSupportedImageFile($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

            guard !imageURLs.isEmpty else {
                continue
            }

            classes.append(
                DatasetClassMetadata(
                    classId: parsed.classId,
                    displayName: parsed.displayName,
                    outputIndex: parsed.outputIndex,
                    imageCount: imageURLs.count
                )
            )

            for imageURL in imageURLs {
                items.append(
                    AccuracyDatasetItem(
                        relativePath: classURL.lastPathComponent + "/" + imageURL.lastPathComponent,
                        fileName: imageURL.lastPathComponent,
                        classId: parsed.classId,
                        displayName: parsed.displayName,
                        outputIndex: parsed.outputIndex
                    )
                )
            }
        }

        let hasOutputIndexMapping = !classes.isEmpty && classes.allSatisfy { $0.outputIndex != nil }
        let metadata = DatasetMetadata(
            datasetId: datasetID,
            source: "filesystem",
            taskType: .classification,
            imageCount: items.count,
            classCount: classes.count,
            hasGroundTruth: !classes.isEmpty,
            hasOutputIndexMapping: hasOutputIndexMapping,
            classes: classes
        )

        return AccuracyDataset(
            metadata: metadata,
            items: items,
            rootURL: rootURL
        )
    }

    private func parseClassFolderName(_ name: String) -> (classId: String, displayName: String, outputIndex: Int?) {
        let components = name.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else {
            return (name, name, nil)
        }

        let rawIndex = String(components[0])
        let rawClassValue = String(components[1]).isEmpty ? name : String(components[1])
        guard let outputIndex = Int(rawIndex) else {
            return (rawClassValue, rawClassValue, nil)
        }

        return (rawClassValue, rawClassValue, outputIndex)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func isSupportedImageFile(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false else {
            return false
        }

        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png":
            return true
        default:
            return false
        }
    }
}
