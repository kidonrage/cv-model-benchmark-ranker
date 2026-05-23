//
//  BenchmarkPlanLoading.swift
//  CVTestsSUI
//
//  Created by Codex on 23.05.2026.
//

import Foundation

enum BenchmarkPlanLoadError: LocalizedError, Sendable {
    case configFileMissing(String)

    var errorDescription: String? {
        switch self {
        case .configFileMissing(let fileName):
            return "\(fileName).json not found in app bundle"
        }
    }
}

struct BenchmarkPlanLoader: Sendable {
    private let bundle: Bundle
    private let decoder: JSONDecoder

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        self.decoder = JSONDecoder()
    }

    func load() throws -> BenchmarkPlan {
        let url = try BundleConfigLocator.configURL(named: "benchmark_plan", bundle: bundle)
        return try decoder.decode(BenchmarkPlan.self, from: Data(contentsOf: url))
    }

    func exists() -> Bool {
        BundleConfigLocator.findConfigURL(named: "benchmark_plan", bundle: bundle) != nil
    }
}

struct ModelsManifestLoader: Sendable {
    private let bundle: Bundle
    private let decoder: JSONDecoder

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        self.decoder = JSONDecoder()
    }

    func load() throws -> ModelsManifest {
        let url = try BundleConfigLocator.configURL(named: "models_manifest", bundle: bundle)
        return try decoder.decode(ModelsManifest.self, from: Data(contentsOf: url))
    }

    func exists() -> Bool {
        BundleConfigLocator.findConfigURL(named: "models_manifest", bundle: bundle) != nil
    }
}

enum BundleConfigLocator {
    static func configURL(named name: String, bundle: Bundle) throws -> URL {
        guard let url = findConfigURL(named: name, bundle: bundle) else {
            throw BenchmarkPlanLoadError.configFileMissing(name)
        }

        return url
    }

    static func findConfigURL(named name: String, bundle: Bundle) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: "json") {
            return url
        }

        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Configs") {
            return url
        }

        if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources/Configs") {
            return url
        }

        guard let resourceRoot = bundle.resourceURL else {
            return nil
        }

        let expectedFileName = "\(name).json"
        let enumerator = FileManager.default.enumerator(
            at: resourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let candidateURL = enumerator?.nextObject() as? URL {
            guard candidateURL.lastPathComponent == expectedFileName else {
                continue
            }

            return candidateURL
        }

        return nil
    }
}
