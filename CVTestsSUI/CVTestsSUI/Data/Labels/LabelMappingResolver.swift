//
//  LabelMappingResolver.swift
//  CVTestsSUI
//
//  Created by Codex on 19.04.2026.
//

import Foundation
import CoreML

enum LabelMappingResolverError: LocalizedError {
    case labelsFileMissing
    case invalidLabelsCount(Int)
    case invalidClassIndex(Int)
    case invalidLogitsCount(Int)
    case emptyCandidateClassSet

    var errorDescription: String? {
        switch self {
        case .labelsFileMissing:
            return "ImageNet labels mapping file not found in app bundle"
        case .invalidLabelsCount(let count):
            return "Expected 1000 ImageNet labels, got \(count)"
        case .invalidClassIndex(let index):
            return "ImageNet class index out of range: \(index)"
        case .invalidLogitsCount(let count):
            return "Expected logits count 1000, got \(count)"
        case .emptyCandidateClassSet:
            return "Restricted evaluation requires at least one candidate class"
        }
    }
}

struct RankedPrediction: Identifiable {
    let index: Int
    let label: String
    let score: Double

    var id: Int { index }
}

struct LabelMappingResolver {
    private let labels: [String]

    init(bundle: Bundle = .main) throws {
        guard let labelsURL = Self.findLabelsURL(in: bundle) else {
            throw LabelMappingResolverError.labelsFileMissing
        }

        let loadedLabels = try String(contentsOf: labelsURL, encoding: .utf8)
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard loadedLabels.count == 1000 else {
            throw LabelMappingResolverError.invalidLabelsCount(loadedLabels.count)
        }

        labels = loadedLabels
    }

    func label(for index: Int) throws -> String {
        guard labels.indices.contains(index) else {
            throw LabelMappingResolverError.invalidClassIndex(index)
        }

        return labels[index]
    }

    func topPredictions(from logits: MLMultiArray, topK: Int) throws -> [RankedPrediction] {
        let values = try flatten(logits: logits)
        guard values.count == labels.count else {
            throw LabelMappingResolverError.invalidLogitsCount(values.count)
        }

        let rankedPairs = values.enumerated()
            .sorted { lhs, rhs in
                if lhs.element == rhs.element {
                    return lhs.offset < rhs.offset
                }
                return lhs.element > rhs.element
            }
            .prefix(topK)

        return try rankedPairs.map { pair in
            RankedPrediction(
                index: pair.offset,
                label: try label(for: pair.offset),
                score: pair.element
            )
        }
    }

    func bestPredictionIndex(
        from logits: MLMultiArray,
        constrainedTo candidateIndices: [Int]
    ) throws -> Int {
        let values = try flatten(logits: logits)
        guard values.count == labels.count else {
            throw LabelMappingResolverError.invalidLogitsCount(values.count)
        }

        guard let bestIndex = candidateIndices.max(by: { values[$0] < values[$1] }) else {
            throw LabelMappingResolverError.emptyCandidateClassSet
        }

        guard labels.indices.contains(bestIndex) else {
            throw LabelMappingResolverError.invalidClassIndex(bestIndex)
        }

        return bestIndex
    }

    private func flatten(logits: MLMultiArray) throws -> [Double] {
        switch logits.dataType {
        case .float32:
            let pointer = logits.dataPointer.bindMemory(to: Float.self, capacity: logits.count)
            return (0..<logits.count).map { Double(pointer[$0]) }
        case .float16:
            let pointer = logits.dataPointer.bindMemory(to: Float16.self, capacity: logits.count)
            return (0..<logits.count).map { Double(pointer[$0]) }
        case .double:
            let pointer = logits.dataPointer.bindMemory(to: Double.self, capacity: logits.count)
            return (0..<logits.count).map { pointer[$0] }
        default:
            return (0..<logits.count).map { logits[$0].doubleValue }
        }
    }

    private static func findLabelsURL(in bundle: Bundle) -> URL? {
        guard let resourceRoot = bundle.resourceURL else {
            return nil
        }

        let enumerator = FileManager.default.enumerator(
            at: resourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.lastPathComponent == "imagenet1k_torchvision_labels.txt" {
                return fileURL
            }
        }

        return nil
    }
}
