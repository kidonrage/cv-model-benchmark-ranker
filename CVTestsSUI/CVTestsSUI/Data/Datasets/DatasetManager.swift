//
//  DatasetManager.swift
//  CVTestsSUI
//
//  Created by Codex on 19.04.2026.
//

import Foundation

enum DatasetManagerError: LocalizedError {
    case resourcesDirectoryMissing
    case datasetManifestMissing(String)
    case datasetMetadataMissing(String)
    case datasetRootMissing(URL)
    case datasetImageMissing(String)

    var errorDescription: String? {
        switch self {
        case .resourcesDirectoryMissing:
            return "Dataset resources directory not found in app bundle"
        case .datasetManifestMissing(let datasetID):
            return "Dataset manifest not found for dataset: \(datasetID)"
        case .datasetMetadataMissing(let datasetID):
            return "Dataset metadata not found for dataset: \(datasetID)"
        case .datasetRootMissing(let url):
            return "Dataset root directory does not exist: \(url.path)"
        case .datasetImageMissing(let fileName):
            return "Dataset image not found in app bundle: \(fileName)"
        }
    }
}

struct AccuracyDatasetManifest: Decodable {
    let datasetName: String
    let subsetID: String
    let subsetVersion: String
    let subsetSize: Int
    let imagesPerClass: Int
    let classCount: Int
    let sourceURL: String
    let sourceArchiveName: String
    let selectionRule: String
    let bundleRelativePath: String
    let metadataFileName: String?
    let classMappingFileName: String?
}

struct AccuracyDatasetItem: Decodable, Identifiable {
    let relativePath: String
    let fileName: String
    let expectedLabel: String
    let classFolder: String
    let imagenetIndex: Int

    var id: String { relativePath }
}

struct AccuracyDatasetClassInfo: Decodable {
    let classFolder: String
    let expectedLabel: String?
    let imagenetIndex: Int
    let synset: String?

    var classID: String? {
        synset ?? classFolder
    }
}

struct AccuracyDataset: Identifiable {
    let manifest: AccuracyDatasetManifest
    let items: [AccuracyDatasetItem]
    let rootURL: URL
    let classInfoByIndex: [Int: AccuracyDatasetClassInfo]
    private let fileManager = FileManager.default
    private let bundleFileIndex: [String: URL]

    var id: String { manifest.subsetID }
    var title: String { "\(manifest.datasetName) (\(manifest.subsetSize) images)" }

    init(
        manifest: AccuracyDatasetManifest,
        items: [AccuracyDatasetItem],
        rootURL: URL,
        classInfoByIndex: [Int: AccuracyDatasetClassInfo],
        bundleFileIndex: [String: URL]
    ) {
        self.manifest = manifest
        self.items = items
        self.rootURL = rootURL
        self.classInfoByIndex = classInfoByIndex
        self.bundleFileIndex = bundleFileIndex
    }

    func imageURL(for item: AccuracyDatasetItem) throws -> URL {
        let nestedURL = rootURL.appendingPathComponent(item.relativePath)
        if fileManager.fileExists(atPath: nestedURL.path) {
            return nestedURL
        }

        let flatURL = rootURL.appendingPathComponent(item.fileName)
        if fileManager.fileExists(atPath: flatURL.path) {
            return flatURL
        }

        if let indexedURL = bundleFileIndex[item.fileName] {
            return indexedURL
        }

        throw DatasetManagerError.datasetImageMissing(item.fileName)
    }

    func classInfo(for classIndex: Int) -> AccuracyDatasetClassInfo? {
        classInfoByIndex[classIndex]
    }
}

struct DatasetManager {
    private let fileManager = FileManager.default
    private let decoder = JSONDecoder()
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func availableDatasets() throws -> [AccuracyDataset] {
        let bundleFileIndex = try makeBundleFileIndex()
        let manifestURLs = try findManifestURLs()
        return try manifestURLs
            .map { try loadDataset($0, bundleFileIndex: bundleFileIndex) }
            .sorted { $0.manifest.subsetID < $1.manifest.subsetID }
    }

    func dataset(withID datasetID: String) throws -> AccuracyDataset {
        let bundleFileIndex = try makeBundleFileIndex()
        let manifestURLs = try findManifestURLs()
        for manifestURL in manifestURLs {
            let manifest = try decode(AccuracyDatasetManifest.self, from: manifestURL)
            if manifest.subsetID == datasetID {
                return try loadDataset(manifestURL, bundleFileIndex: bundleFileIndex)
            }
        }

        throw DatasetManagerError.datasetManifestMissing(datasetID)
    }

    private func findManifestURLs() throws -> [URL] {
        guard let resourceRoot = bundle.resourceURL else {
            throw DatasetManagerError.resourcesDirectoryMissing
        }

        let enumerator = fileManager.enumerator(
            at: resourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var manifestURLs: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            let fileName = fileURL.lastPathComponent
            guard fileName == "manifest.json" || fileName.hasSuffix("_manifest.json") else {
                continue
            }
            manifestURLs.append(fileURL)
        }

        return manifestURLs
    }

    private func loadDataset(
        _ manifestURL: URL,
        bundleFileIndex: [String: URL]
    ) throws -> AccuracyDataset {
        let rootURL = manifestURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: rootURL.path) else {
            throw DatasetManagerError.datasetRootMissing(rootURL)
        }

        let manifest = try decode(AccuracyDatasetManifest.self, from: manifestURL)
        let metadataFileName = manifest.metadataFileName ?? "metadata.json"
        let metadataURL = rootURL.appendingPathComponent(metadataFileName)
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw DatasetManagerError.datasetMetadataMissing(manifest.subsetID)
        }

        let items = try decode([AccuracyDatasetItem].self, from: metadataURL)
        let classInfoByIndex = try loadClassInfoIndex(for: manifest, rootURL: rootURL)
        return AccuracyDataset(
            manifest: manifest,
            items: items,
            rootURL: rootURL,
            classInfoByIndex: classInfoByIndex,
            bundleFileIndex: bundleFileIndex
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    private func makeBundleFileIndex() throws -> [String: URL] {
        guard let resourceRoot = bundle.resourceURL else {
            throw DatasetManagerError.resourcesDirectoryMissing
        }

        let enumerator = fileManager.enumerator(
            at: resourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var index: [String: URL] = [:]
        while let fileURL = enumerator?.nextObject() as? URL {
            index[fileURL.lastPathComponent] = fileURL
        }

        return index
    }

    private func loadClassInfoIndex(
        for manifest: AccuracyDatasetManifest,
        rootURL: URL
    ) throws -> [Int: AccuracyDatasetClassInfo] {
        let classMappingFileName = manifest.classMappingFileName ?? "class_mapping.json"
        let classMappingURL = rootURL.appendingPathComponent(classMappingFileName)
        guard fileManager.fileExists(atPath: classMappingURL.path) else {
            return [:]
        }

        let classInfos = try decode([AccuracyDatasetClassInfo].self, from: classMappingURL)
        return Dictionary(uniqueKeysWithValues: classInfos.map { ($0.imagenetIndex, $0) })
    }
}
