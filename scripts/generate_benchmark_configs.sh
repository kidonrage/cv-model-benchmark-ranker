#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PROJECT_NAME="CVTestsSUI"

PROJECT_NAME="$DEFAULT_PROJECT_NAME"
PROJECT_ROOT=""
INPUT_MODELS_DIR=""
INPUT_DATASETS_DIR=""
PROJECT_MODELS_DIR=""
PROJECT_DATASETS_DIR=""
PROFILES_FILE=""
SCENARIO_FILE=""
OUTPUT_DIR=""

ALLOW_UNKNOWN="false"
CLEAN_MODELS="true"
CLEAN_DATASETS="true"
OPEN_PROJECT="false"

usage() {
  cat <<EOF
Usage:
  ./scripts/generate_benchmark_configs.sh [options]

Options:
  --project-name <name>
      Xcode/iOS project name. Default: ${DEFAULT_PROJECT_NAME}

  --project-root <path>
      Path to project root. Default: ./<project-name>

  --input-models <path>
      Directory with input .mlpackage/.mlmodel/.mlmodelc files.
      Default: ./input_models

  --input-datasets <path>
      Directory with filesystem-driven datasets:
      <dataset_id>/<output_index>_<class_name>/*.{jpg,jpeg,png}
      Default: ./input_datasets

  --project-models-dir <path>
      Directory inside iOS project where models will be copied.
      Default: ./<project-name>/<project-name>/Resources/ModelsRaw

  --project-datasets-dir <path>
      Directory inside iOS project where datasets will be copied.
      Default: ./<project-name>/<project-name>/Resources/Datasets

  --profiles <path>
      Path to model_profiles.json.
      Default: ./<project-name>/<project-name>/Resources/Configs/model_profiles.json

  --scenario <path>
      Path to scenario_config.json.
      Default: ./scenario_config.json

  --output-dir <path>
      Directory where models_manifest.json and benchmark_plan.json will be generated.
      Default: ./<project-name>/<project-name>/Resources/Configs

  --allow-unknown
      Do not fail on unknown model families. Unknown models will be written to manifest,
      but excluded from benchmark_plan.json because preprocessing/output contract is unknown.

  --no-clean-models
      Do not clean project models directory before copying new models.

  --no-clean-datasets
      Do not clean project datasets directory before copying new datasets.

  --open
      Open ./<project-name>/<project-name>.xcodeproj after successful generation.

  -h, --help
      Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --project-root)
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --input-models)
      INPUT_MODELS_DIR="$2"
      shift 2
      ;;
    --input-datasets)
      INPUT_DATASETS_DIR="$2"
      shift 2
      ;;
    --project-models-dir)
      PROJECT_MODELS_DIR="$2"
      shift 2
      ;;
    --project-datasets-dir)
      PROJECT_DATASETS_DIR="$2"
      shift 2
      ;;
    --profiles)
      PROFILES_FILE="$2"
      shift 2
      ;;
    --scenario)
      SCENARIO_FILE="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --allow-unknown)
      ALLOW_UNKNOWN="true"
      shift 1
      ;;
    --no-clean-models)
      CLEAN_MODELS="false"
      shift 1
      ;;
    --no-clean-datasets)
      CLEAN_DATASETS="false"
      shift 1
      ;;
    --open)
      OPEN_PROJECT="true"
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

PROJECT_ROOT="${PROJECT_ROOT:-./${PROJECT_NAME}}"
APP_ROOT="${PROJECT_ROOT}/${PROJECT_NAME}"

INPUT_MODELS_DIR="${INPUT_MODELS_DIR:-./input_models}"
INPUT_DATASETS_DIR="${INPUT_DATASETS_DIR:-./input_datasets}"
PROJECT_MODELS_DIR="${PROJECT_MODELS_DIR:-${APP_ROOT}/Resources/ModelsRaw}"
PROJECT_DATASETS_DIR="${PROJECT_DATASETS_DIR:-${APP_ROOT}/Resources/Datasets}"
OUTPUT_DIR="${OUTPUT_DIR:-${APP_ROOT}/Resources/Configs}"
PROFILES_FILE="${PROFILES_FILE:-${OUTPUT_DIR}/model_profiles.json}"
SCENARIO_FILE="${SCENARIO_FILE:-./scenario_config.json}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required"
  exit 1
fi

python3 - \
  "$PROJECT_NAME" \
  "$PROJECT_ROOT" \
  "$INPUT_MODELS_DIR" \
  "$INPUT_DATASETS_DIR" \
  "$PROJECT_MODELS_DIR" \
  "$PROJECT_DATASETS_DIR" \
  "$PROFILES_FILE" \
  "$SCENARIO_FILE" \
  "$OUTPUT_DIR" \
  "$ALLOW_UNKNOWN" \
  "$CLEAN_MODELS" \
  "$CLEAN_DATASETS" <<'PY'
import json
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

project_name = sys.argv[1]
project_root = Path(sys.argv[2])
input_models_dir = Path(sys.argv[3])
input_datasets_dir = Path(sys.argv[4])
project_models_dir = Path(sys.argv[5])
project_datasets_dir = Path(sys.argv[6])
profiles_file = Path(sys.argv[7])
scenario_file = Path(sys.argv[8])
output_dir = Path(sys.argv[9])
allow_unknown = sys.argv[10].lower() == "true"
clean_models = sys.argv[11].lower() == "true"
clean_datasets = sys.argv[12].lower() == "true"

SUPPORTED_MODEL_EXTENSIONS = {".mlpackage", ".mlmodel", ".mlmodelc"}
SUPPORTED_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png"}


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def read_json(path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def normalize_compute_units(value):
    if value is None:
        return None

    raw = str(value).strip().lower().replace("-", "_")
    if raw in {"all", "all_units", "all_compute_units"}:
        return "ALL"
    if raw in {"cpu", "cpu_only", "cpuonly"}:
        return "CPU_ONLY"
    if raw in {"cpu_and_gpu", "cpu_gpu"}:
        return "CPU_AND_GPU"
    if raw in {"cpu_and_neural_engine", "cpu_and_ne", "cpu_neural_engine"}:
        return "CPU_AND_NEURAL_ENGINE"
    return str(value).strip()


def normalize_dataset_id(value):
    return str(value).strip().replace("-", "_")


def slugify(value):
    lowered = str(value).strip().lower()
    lowered = re.sub(r"[^a-z0-9]+", "_", lowered)
    lowered = re.sub(r"_+", "_", lowered)
    return lowered.strip("_") or "class"


def default_profiles():
    return {
        "families": [
            {
                "family": "MobileNetV2",
                "match": ["mobilenetv2", "mobile_net_v2", "mobile-net-v2"],
                "preprocessingProfile": "mobilenetv2_imagenet",
                "input": {
                    "type": "multiArray",
                    "shape": [1, 3, 224, 224],
                    "channelOrder": "CHW",
                },
                "output": {
                    "name": "var_824",
                    "labelMapping": "imagenet_labels.json",
                    "classCount": 1000,
                },
            },
            {
                "family": "EfficientNetB0",
                "match": ["efficientnetb0", "efficientnet_b0", "efficient-net-b0"],
                "preprocessingProfile": "efficientnetb0_imagenet",
                "input": {
                    "type": "multiArray",
                    "shape": [1, 3, 224, 224],
                    "channelOrder": "CHW",
                },
                "output": {
                    "name": "var_1150",
                    "labelMapping": "imagenet_labels.json",
                    "classCount": 1000,
                },
            },
        ],
        "preprocessingProfiles": {
            "mobilenetv2_imagenet": {
                "resizeShortSide": 232,
                "cropSize": 224,
                "interpolation": "bilinear",
                "colorSpace": "RGB",
                "channelOrder": "CHW",
                "mean": [0.485, 0.456, 0.406],
                "std": [0.229, 0.224, 0.225],
            },
            "efficientnetb0_imagenet": {
                "resizeShortSide": 256,
                "cropSize": 224,
                "interpolation": "bicubic",
                "colorSpace": "RGB",
                "channelOrder": "CHW",
                "mean": [0.485, 0.456, 0.406],
                "std": [0.229, 0.224, 0.225],
            },
        },
    }


def default_scenario():
    return {
        "usageScenario": "single_image_analysis",
        "priorityProfile": "balanced",
        "targetDeviceClass": "modern_iphone_with_ane",
        "datasets": {
            "primaryDatasetId": "imagenette2_160_subset_500",
            "validationDatasetIds": ["imagenet_hard_50_subset_2500"],
            "hardDatasetIds": ["imagenet_hard_50_subset_2500"],
            "smokeDatasetId": None,
        },
        "qualityThresholds": {
            "primary": {
                "minTop1": 0.70,
                "minRestrictedTop1": 0.95,
            },
            "validation": {
                "maxAccuracyDropPp": 10,
                "minTop1": 0.65,
            },
            "hard": {
                "maxAccuracyDropPp": 15,
                "minTop1": 0.60,
            },
        },
        "latencyBudgetMs": 25,
        "p90LatencyBudgetMs": 35,
        "maxModelSizeMb": 100,
        "preferInterpretableOptimization": True,
        "allowPalettizedWeights": True,
        "includeCpuOnlyReference": False,
        "enableAccuracyBenchmark": True,
        "enableSegmentedBenchmark": True,
        "enableSustainedBenchmark": False,
        "warmupRuns": 10,
        "measuredRuns": 50,
        "accuracyWarmupImages": 10,
        "sustainedWarmupRuns": 100,
        "sustainedMeasuredRuns": 10000,
    }


def ensure_default_files():
    created = []
    if not profiles_file.exists():
        write_json(profiles_file, default_profiles())
        created.append(str(profiles_file))
    if not scenario_file.exists():
        write_json(scenario_file, default_scenario())
        created.append(str(scenario_file))
    return created


def is_model_package(path):
    return (path.is_file() or path.is_dir()) and path.suffix in SUPPORTED_MODEL_EXTENSIONS


def discover_model_packages(directory):
    if not directory.exists():
        return []
    return [
        item
        for item in sorted(directory.iterdir(), key=lambda value: value.name.lower())
        if not item.name.startswith(".") and is_model_package(item)
    ]


def copy_model_package(src, dst_dir):
    dst = dst_dir / src.name
    if dst.exists():
        if dst.is_dir():
            shutil.rmtree(dst)
        else:
            dst.unlink()
    if src.is_dir():
        shutil.copytree(src, dst)
    else:
        shutil.copy2(src, dst)
    return dst


def safe_same_path(a, b):
    try:
        return a.resolve() == b.resolve()
    except FileNotFoundError:
        return False


def copy_input_models_to_project():
    project_models_dir.mkdir(parents=True, exist_ok=True)
    input_models = discover_model_packages(input_models_dir)
    if not input_models:
        existing = discover_model_packages(project_models_dir)
        if existing:
            print(f"No input models found in {input_models_dir}. Using existing models from {project_models_dir}.")
            return existing
        raise SystemExit(
            f"No model files found. Put .mlpackage/.mlmodel/.mlmodelc files into {input_models_dir} "
            f"or pass --input-models <path>."
        )
    if safe_same_path(input_models_dir, project_models_dir):
        return input_models
    if clean_models and project_models_dir.exists():
        for item in project_models_dir.iterdir():
            if item.name.startswith("."):
                continue
            if is_model_package(item):
                if item.is_dir():
                    shutil.rmtree(item)
                else:
                    item.unlink()
    copied = []
    for model in input_models:
        copied.append(copy_model_package(model, project_models_dir))
    return copied


def parse_class_folder(folder_name):
    parts = folder_name.split("_", 1)
    if len(parts) != 2:
        return {
            "classId": folder_name,
            "displayName": folder_name,
            "outputIndex": None,
        }
    output_prefix, class_tail = parts
    try:
        output_index = int(output_prefix)
    except ValueError:
        output_index = None
        class_tail = class_tail or folder_name
    return {
        "classId": class_tail or folder_name,
        "displayName": class_tail or folder_name,
        "outputIndex": output_index,
    }


def discover_dataset_directory(dataset_dir):
    if not dataset_dir.exists() or not dataset_dir.is_dir():
        raise SystemExit(f"Dataset directory not found: {dataset_dir}")

    classes = []
    image_count = 0
    has_mapping = True

    for class_dir in sorted(dataset_dir.iterdir(), key=lambda value: value.name.lower()):
        if class_dir.name.startswith(".") or not class_dir.is_dir():
            continue
        parsed = parse_class_folder(class_dir.name)
        image_files = [
            image
            for image in sorted(class_dir.iterdir(), key=lambda value: value.name.lower())
            if image.is_file() and image.suffix.lower() in SUPPORTED_IMAGE_EXTENSIONS
        ]
        if not image_files:
            continue
        image_count += len(image_files)
        if parsed["outputIndex"] is None:
            has_mapping = False
        classes.append(
            {
                "classId": parsed["classId"],
                "displayName": parsed["displayName"],
                "outputIndex": parsed["outputIndex"],
                "imageCount": len(image_files),
            }
        )

    return {
        "datasetId": normalize_dataset_id(dataset_dir.name),
        "sourceDir": dataset_dir,
        "imageCount": image_count,
        "classCount": len(classes),
        "hasGroundTruth": bool(classes),
        "hasOutputIndexMapping": bool(classes) and has_mapping,
        "classes": classes,
        "maxOutputIndex": max((item["outputIndex"] for item in classes if item["outputIndex"] is not None), default=None),
    }


def discover_datasets(directory):
    if not directory.exists():
        return []
    datasets = []
    for item in sorted(directory.iterdir(), key=lambda value: value.name.lower()):
        if item.name.startswith(".") or not item.is_dir():
            continue
        datasets.append(discover_dataset_directory(item))
    return datasets


def clear_directory_contents(directory, preserve_filter):
    if not directory.exists():
        return
    for item in directory.iterdir():
        if preserve_filter(item):
            continue
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()


def copy_input_datasets_to_project():
    project_datasets_dir.mkdir(parents=True, exist_ok=True)
    input_datasets = discover_datasets(input_datasets_dir)

    if not input_datasets:
        existing = discover_datasets(project_datasets_dir)
        if existing:
            print(f"No input datasets found in {input_datasets_dir}. Using existing datasets from {project_datasets_dir}.")
            return existing
        raise SystemExit(
            f"No datasets found. Put datasets into {input_datasets_dir} using "
            f"<dataset_id>/<output_index>_<class_name>/*.{'{jpg,jpeg,png}'} layout."
        )

    if not safe_same_path(input_datasets_dir, project_datasets_dir):
        if clean_datasets:
            clear_directory_contents(project_datasets_dir, preserve_filter=lambda item: item.name.startswith("."))

        for dataset in input_datasets:
            dst = project_datasets_dir / dataset["datasetId"]
            if dst.exists():
                shutil.rmtree(dst)
            shutil.copytree(dataset["sourceDir"], dst)

    return discover_datasets(project_datasets_dir)


def model_package_size_mb(path):
    if path.is_file():
        return path.stat().st_size / 1024 / 1024
    total = 0
    for child in path.rglob("*"):
        if child.is_file():
            total += child.stat().st_size
    return total / 1024 / 1024


def infer_format_and_optimization(model_id):
    raw = model_id.lower()
    if "fp32" in raw or "float32" in raw:
        return "FP32", "float32"
    if "fp16" in raw or "float16" in raw:
        return "FP16", "float16"
    if "int8" in raw:
        if "palett" in raw or "lut" in raw:
            return "INT8", "8-bit palettized weights"
        return "INT8", "unknown_int8_or_weight_compression"
    if "palett" in raw or "lut" in raw:
        return "INT8", "8-bit palettized weights"
    return "UNKNOWN", "unknown"


def find_family_profile(model_id, profiles):
    raw = model_id.lower()
    for family in profiles.get("families", []):
        family_name = str(family.get("family", ""))
        if family_name and family_name.lower() in raw:
            return family
        for token in family.get("match", []):
            if str(token).lower() in raw:
                return family
    return None


def compute_units_for_plan(scenario):
    explicit = scenario.get("benchmarkComputeUnits")
    if isinstance(explicit, list) and explicit:
        return [normalize_compute_units(value) for value in explicit]

    required = scenario.get("requiredComputeUnits")
    if required:
        return [normalize_compute_units(required)]

    usage = str(scenario.get("usageScenario", "")).lower()
    target = str(scenario.get("targetDeviceClass", "")).lower()
    if usage == "old_device_or_no_ane" or "old" in target or "no_ane" in target:
        return ["CPU_ONLY"]
    if scenario.get("includeCpuOnlyReference", False):
        return ["ALL", "CPU_ONLY"]
    return ["ALL"]


def benchmark_types_for_scenario(scenario):
    usage = str(scenario.get("usageScenario", "single_image_analysis")).lower()
    enable_accuracy = bool(scenario.get("enableAccuracyBenchmark", True))
    enable_segmented = bool(scenario.get("enableSegmentedBenchmark", True))
    enable_sustained = bool(scenario.get("enableSustainedBenchmark", False))

    benchmark_types = [
        {
            "benchmarkType": "performance",
            "measurementMode": "fullPipeline",
            "inputMode": "realImage",
        }
    ]

    if enable_segmented:
        benchmark_types.append(
            {
                "benchmarkType": "performance",
                "measurementMode": "segmented",
                "inputMode": "realImage",
            }
        )

    if enable_accuracy:
        benchmark_types.append(
            {
                "benchmarkType": "accuracy",
                "measurementMode": "fullPipeline",
                "inputMode": "dataset",
            }
        )

    if usage in {"camera_stream", "video_stream", "stream", "real_time"} and enable_sustained:
        benchmark_types.append(
            {
                "benchmarkType": "sustained",
                "measurementMode": "fullPipeline",
                "inputMode": "realImage",
            }
        )
    return benchmark_types


def normalize_scenario(scenario):
    datasets = scenario.get("datasets") or {}
    if not datasets:
        legacy_dataset_id = normalize_dataset_id(scenario.get("datasetId", "imagenette2_160_subset_500"))
        datasets = {
            "primaryDatasetId": legacy_dataset_id,
            "validationDatasetIds": [],
            "hardDatasetIds": [],
            "smokeDatasetId": None,
        }
        scenario["datasets"] = datasets
    else:
        datasets["primaryDatasetId"] = normalize_dataset_id(datasets["primaryDatasetId"])
        datasets["validationDatasetIds"] = [normalize_dataset_id(value) for value in datasets.get("validationDatasetIds", [])]
        datasets["hardDatasetIds"] = [normalize_dataset_id(value) for value in datasets.get("hardDatasetIds", [])]
        if datasets.get("smokeDatasetId") is not None:
            datasets["smokeDatasetId"] = normalize_dataset_id(datasets["smokeDatasetId"])

    scenario["qualityThresholds"] = scenario.get("qualityThresholds") or {
        "primary": {
            "minTop1": scenario.get("minTop1Accuracy"),
            "minRestrictedTop1": scenario.get("minRestrictedTop1Accuracy"),
        }
    }
    return scenario


created_files = ensure_default_files()
profiles = read_json(profiles_file)
scenario = normalize_scenario(read_json(scenario_file))

copy_input_models_to_project()
project_model_paths = discover_model_packages(project_models_dir)
project_datasets = copy_input_datasets_to_project()
datasets_by_id = {item["datasetId"]: item for item in project_datasets}

models = []
errors = []
warnings = []

for path in project_model_paths:
    model_id = path.stem
    model_format, optimization_type = infer_format_and_optimization(model_id)
    family_profile = find_family_profile(model_id, profiles)

    if family_profile is None:
        message = (
            f"Unknown model family for '{model_id}'. "
            f"Add a family profile to {profiles_file} or run with --allow-unknown."
        )
        if allow_unknown:
            warnings.append(message)
            models.append(
                {
                    "id": model_id,
                    "sourceFile": path.name,
                    "compiledResourceName": model_id,
                    "compiledExtension": "mlmodelc",
                    "family": "UNKNOWN",
                    "format": model_format,
                    "optimizationType": optimization_type,
                    "modelSizeMb": round(model_package_size_mb(path), 3),
                    "supported": False,
                    "preprocessingProfile": None,
                    "input": None,
                    "output": None,
                    "warnings": [message],
                }
            )
            continue
        errors.append(message)
        continue

    model_warnings = []
    if model_format == "INT8" and "palettized" in optimization_type:
        model_warnings.append(
            "INT8-labeled model is interpreted as palettized weights, not proven W8A8 integer inference."
        )
    if model_format == "INT8" and optimization_type == "unknown_int8_or_weight_compression":
        model_warnings.append(
            "INT8-labeled model has unknown actual optimization type. Verify .mlpackage structure before interpreting it as INT8."
        )

    models.append(
        {
            "id": model_id,
            "sourceFile": path.name,
            "compiledResourceName": model_id,
            "compiledExtension": "mlmodelc",
            "family": family_profile.get("family"),
            "format": model_format,
            "optimizationType": optimization_type,
            "modelSizeMb": round(model_package_size_mb(path), 3),
            "supported": True,
            "preprocessingProfile": family_profile.get("preprocessingProfile"),
            "input": family_profile.get("input"),
            "output": family_profile.get("output"),
            "warnings": model_warnings,
        }
    )

if errors:
    print("Failed to generate benchmark configs:")
    for error in errors:
        print(f"- {error}")
    raise SystemExit(1)

manifest = {
    "generatedAt": now_iso(),
    "projectName": project_name,
    "projectRoot": str(project_root),
    "modelsDir": str(project_models_dir),
    "models": models,
    "preprocessingProfiles": profiles.get("preprocessingProfiles", {}),
}
models_manifest_path = output_dir / "models_manifest.json"
write_json(models_manifest_path, manifest)

usage_scenario = scenario.get("usageScenario", "single_image_analysis")
priority_profile = scenario.get("priorityProfile", scenario.get("profile", "balanced"))
dataset_config = scenario["datasets"]
dataset_ids = [dataset_config["primaryDatasetId"]]
dataset_ids.extend(dataset_config.get("validationDatasetIds", []))
dataset_ids.extend(dataset_config.get("hardDatasetIds", []))
if dataset_config.get("smokeDatasetId"):
    dataset_ids.append(dataset_config["smokeDatasetId"])

seen = set()
dataset_ids = [dataset_id for dataset_id in dataset_ids if not (dataset_id in seen or seen.add(dataset_id))]

missing_datasets = [dataset_id for dataset_id in dataset_ids if dataset_id not in datasets_by_id]
if missing_datasets:
    raise SystemExit(
        "Scenario references datasets that are not present in the copied bundle datasets: "
        + ", ".join(sorted(missing_datasets))
    )

warmup_runs = int(scenario.get("warmupRuns", 10))
measured_runs = int(scenario.get("measuredRuns", 50))
accuracy_warmup_images = int(scenario.get("accuracyWarmupImages", 10))
sustained_warmup_runs = int(scenario.get("sustainedWarmupRuns", 100))
sustained_measured_runs = int(scenario.get("sustainedMeasuredRuns", 10000))

compute_units = compute_units_for_plan(scenario)
benchmark_types = benchmark_types_for_scenario(scenario)
experiments = []

for model in models:
    if not model.get("supported", False):
        continue
    for dataset_id in dataset_ids:
        for compute in compute_units:
            for benchmark in benchmark_types:
                benchmark_type = benchmark["benchmarkType"]
                measurement_mode = benchmark["measurementMode"]
                experiment_id = f"{model['id']}__{dataset_id}__{compute}__{benchmark_type}__{measurement_mode}"
                experiment = {
                    "experimentId": experiment_id,
                    "modelId": model["id"],
                    "computeUnits": compute,
                    "benchmarkType": benchmark_type,
                    "measurementMode": measurement_mode,
                    "inputMode": benchmark["inputMode"],
                    "datasetId": dataset_id,
                }
                if benchmark_type == "performance":
                    experiment["warmupRuns"] = warmup_runs
                    experiment["measuredRuns"] = measured_runs
                elif benchmark_type == "accuracy":
                    experiment["warmupImages"] = accuracy_warmup_images
                elif benchmark_type == "sustained":
                    experiment["warmupRuns"] = sustained_warmup_runs
                    experiment["measuredRuns"] = sustained_measured_runs
                experiments.append(experiment)

plan = {
    "generatedAt": now_iso(),
    "projectName": project_name,
    "planId": scenario.get("planId", f"{usage_scenario}_{priority_profile}_generated"),
    "usageScenario": usage_scenario,
    "priorityProfile": priority_profile,
    "datasetId": dataset_config["primaryDatasetId"],
    "datasets": dataset_config,
    "qualityThresholds": scenario.get("qualityThresholds", {}),
    "computeUnits": compute_units,
    "experiments": experiments,
    "warnings": warnings,
}
benchmark_plan_path = output_dir / "benchmark_plan.json"
write_json(benchmark_plan_path, plan)

dataset_summary = []
for dataset_id in dataset_ids:
    dataset = datasets_by_id[dataset_id]
    dataset_summary.append(
        {
            "datasetId": dataset_id,
            "imageCount": dataset["imageCount"],
            "classCount": dataset["classCount"],
            "hasGroundTruth": dataset["hasGroundTruth"],
            "hasOutputIndexMapping": dataset["hasOutputIndexMapping"],
        }
    )
    if not dataset["hasOutputIndexMapping"]:
        warnings.append(
            f"Dataset {dataset_id} does not have valid output index mapping. Accuracy experiments will fail fast on device, but performance runs can still execute."
        )

print("")
print("Benchmark configs generated successfully.")
print("")
print(f"Project name:              {project_name}")
print(f"Project root:              {project_root}")
print(f"Input models dir:          {input_models_dir}")
print(f"Input datasets dir:        {input_datasets_dir}")
print(f"Project models dir:        {project_models_dir}")
print(f"Project datasets dir:      {project_datasets_dir}")
print(f"Profiles file:             {profiles_file}")
print(f"Scenario file:             {scenario_file}")
print(f"Output dir:                {output_dir}")
print("")
print(f"Models discovered:         {len(project_model_paths)}")
print(f"Datasets discovered:       {len(project_datasets)}")
print(f"Experiments generated:     {len(experiments)}")
print("")
for item in dataset_summary:
    print(
        f"Dataset:                   {item['datasetId']} "
        f"(images={item['imageCount']}, classes={item['classCount']}, "
        f"groundTruth={item['hasGroundTruth']}, outputIndexMapping={item['hasOutputIndexMapping']})"
    )
print("")
print(f"Generated:                 {models_manifest_path}")
print(f"Generated:                 {benchmark_plan_path}")

if created_files:
    print("")
    print("Default files created:")
    for path in created_files:
        print(f"- {path}")

all_warnings = warnings[:]
for model in models:
    all_warnings.extend(model.get("warnings", []))

if all_warnings:
    print("")
    print("Warnings:")
    for warning in all_warnings:
        print(f"- {warning}")

print("")
print("Next step:")
print("Build the iOS app on a physical iPhone, run the full benchmark plan, then export benchmark_results.json.")
PY

if [[ "$OPEN_PROJECT" == "true" ]]; then
  XCODE_PROJECT_PATH="${PROJECT_ROOT}/${PROJECT_NAME}.xcodeproj"

  if [[ ! -d "$XCODE_PROJECT_PATH" ]]; then
    echo "Error: Xcode project not found: $XCODE_PROJECT_PATH"
    exit 1
  fi

  if ! command -v open >/dev/null 2>&1; then
    echo "Error: 'open' command is not available on this system"
    exit 1
  fi

  echo ""
  echo "Opening Xcode project: $XCODE_PROJECT_PATH"
  open "$XCODE_PROJECT_PATH"
fi
