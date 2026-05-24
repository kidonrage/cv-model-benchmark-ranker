//
//  BenchmarkPlanValidator.swift
//  CVTestsSUI
//
//  Created by Codex on 23.05.2026.
//

import Foundation

enum BenchmarkPlanValidationError: LocalizedError, Sendable {
    case unknownModelID(String)
    case unsupportedModel(String)
    case modelMissingFromCatalog(String)
    case preprocessingProfileMissing(modelID: String, profileID: String)
    case emptyPlan
    case missingDatasetID(String)

    var errorDescription: String? {
        switch self {
        case .unknownModelID(let modelID):
            return "Experiment references unknown modelId: \(modelID)"
        case .unsupportedModel(let modelID):
            return "Model is marked unsupported in manifest: \(modelID)"
        case .modelMissingFromCatalog(let modelID):
            return "Model exists in manifest but is not wired into app catalog: \(modelID)"
        case .preprocessingProfileMissing(let modelID, let profileID):
            return "Preprocessing profile \(profileID) not found for model \(modelID)"
        case .emptyPlan:
            return "benchmark_plan.json contains no experiments"
        case .missingDatasetID(let experimentID):
            return "Experiment must declare datasetId explicitly: \(experimentID)"
        }
    }
}

struct BenchmarkPlanValidator {
    func validate(plan: BenchmarkPlan, manifest: ModelsManifest) throws {
        guard !plan.experiments.isEmpty else {
            throw BenchmarkPlanValidationError.emptyPlan
        }

        let manifestModelsByID = Dictionary(uniqueKeysWithValues: manifest.models.map { ($0.id, $0) })

        for experiment in plan.experiments {
            guard experiment.datasetId != nil else {
                throw BenchmarkPlanValidationError.missingDatasetID(experiment.experimentId)
            }

            guard let manifestModel = manifestModelsByID[experiment.modelId] else {
                throw BenchmarkPlanValidationError.unknownModelID(experiment.modelId)
            }

            guard manifestModel.supported else {
                throw BenchmarkPlanValidationError.unsupportedModel(experiment.modelId)
            }

            guard BenchmarkModelCatalog.descriptor(withID: experiment.modelId) != nil else {
                throw BenchmarkPlanValidationError.modelMissingFromCatalog(experiment.modelId)
            }

            guard manifest.preprocessingProfiles[manifestModel.preprocessingProfile] != nil else {
                throw BenchmarkPlanValidationError.preprocessingProfileMissing(
                    modelID: experiment.modelId,
                    profileID: manifestModel.preprocessingProfile
                )
            }
        }
    }
}
