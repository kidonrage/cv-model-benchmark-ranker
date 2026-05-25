#!/usr/bin/env bash
set -euo pipefail

RESULTS_FILE=""
SCENARIO_FILE=""
OUTPUT_DIR="reports"

usage() {
  cat <<EOF
Usage:
  ./scripts/analyze_results.sh --results <benchmark_results.json> --scenario <scenario_config.json> [--output-dir reports]

Example:
  ./scripts/analyze_results.sh \\
    --results ./app_logs/benchmark_results.json \\
    --scenario ./scenario_config.json \\
    --output-dir ./reports
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --results)
      RESULTS_FILE="$2"
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

if [[ -z "$RESULTS_FILE" || -z "$SCENARIO_FILE" ]]; then
  echo "Error: --results and --scenario are required"
  usage
  exit 1
fi

if [[ ! -f "$RESULTS_FILE" ]]; then
  echo "Error: results file not found: $RESULTS_FILE"
  exit 1
fi

if [[ ! -f "$SCENARIO_FILE" ]]; then
  echo "Error: scenario file not found: $SCENARIO_FILE"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

python3 - "$RESULTS_FILE" "$SCENARIO_FILE" "$OUTPUT_DIR" <<'PY'
import json
import math
import sys
from datetime import datetime, timezone
from pathlib import Path

results_path = Path(sys.argv[1])
scenario_path = Path(sys.argv[2])
output_dir = Path(sys.argv[3])

with results_path.open("r", encoding="utf-8") as handle:
    results = json.load(handle)

with scenario_path.open("r", encoding="utf-8") as handle:
    scenario = json.load(handle)


def nested_get(obj, path):
    current = obj
    for key in path:
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def pick(obj, paths, default=None):
    for path in paths:
        if isinstance(path, str):
            path = (path,)
        value = nested_get(obj, path)
        if value is not None:
            return value
    return default


def as_float(value):
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def as_int(value):
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def as_str(value):
    if value is None:
        return None
    return str(value)


def normalize_compute(value):
    if value is None:
        return "UNKNOWN"
    raw = str(value).strip().lower().replace("-", "_")
    if raw in {"all", "all_units", "allcomputeunits", "all_compute_units"}:
        return "ALL"
    if raw in {"cpu", "cpu_only", "cpuonly"}:
        return "CPU_ONLY"
    if raw in {"cpu_and_gpu", "cpu_gpu"}:
        return "CPU_AND_GPU"
    if raw in {"cpu_and_ne", "cpu_and_neural_engine", "cpu_neural_engine"}:
        return "CPU_AND_NEURAL_ENGINE"
    return str(value).strip()


def normalize_dataset_id(value):
    return str(value).strip().replace("-", "_")


def fmt_num(value, digits=3, suffix=""):
    if value is None:
        return "—"
    return f"{value:.{digits}f}{suffix}"


def fmt_ms(value):
    if value is None:
        return "—"
    return f"{value:.2f} ms"


def fmt_pp(value):
    if value is None:
        return "—"
    return f"{value:.2f} pp"


def fmt_mb(value):
    if value is None:
        return "—"
    return f"{value:.1f} MB"


def quality_raw(metrics):
    parts = []
    if metrics.get("top1") is not None:
        parts.append((metrics["top1"], 0.45))
    if metrics.get("restrictedTop1") is not None:
        parts.append((metrics["restrictedTop1"], 0.35))
    if metrics.get("top5") is not None:
        parts.append((metrics["top5"], 0.20))
    if not parts:
        return None
    total_weight = sum(weight for _, weight in parts)
    return sum(value * weight for value, weight in parts) / total_weight


def norm_lower(value, values):
    if value is None:
        return 0.0
    valid = [entry for entry in values if entry is not None]
    if not valid:
        return 0.0
    lo, hi = min(valid), max(valid)
    if math.isclose(lo, hi):
        return 1.0
    return max(0.0, min(1.0, (hi - value) / (hi - lo)))


def interpretability_score(candidate):
    fmt = str(candidate.get("format") or "").upper()
    opt = str(candidate.get("optimizationType") or "").lower()
    if "FP16" in fmt or "float16" in opt:
        return 1.0
    if "FP32" in fmt or "float32" in opt:
        return 0.85
    if "w8a8" in opt or "integer" in opt:
        return 0.80
    if "palett" in opt or "lut" in opt:
        return 0.65
    if "int8" in fmt or "int8" in opt:
        return 0.55
    return 0.70


def thermal_score(candidate):
    state = str(candidate.get("thermalState") or "").lower()
    if state in {"", "unknown"}:
        return 0.80
    if state in {"nominal", "fair"}:
        return 1.00
    if state == "serious":
        return 0.35
    if state == "critical":
        return 0.10
    return 0.70


def weights_for(profile):
    if profile == "latency_first":
        return {"quality": 0.15, "latency": 0.70, "size": 0.10, "interpretability": 0.05, "thermal": 0.00}
    if profile == "accuracy_first":
        return {"quality": 0.70, "latency": 0.15, "size": 0.05, "interpretability": 0.10, "thermal": 0.00}
    if profile == "disk_size_first":
        return {"quality": 0.15, "latency": 0.20, "size": 0.60, "interpretability": 0.05, "thermal": 0.00}
    if profile == "conservative_deployment":
        return {"quality": 0.35, "latency": 0.25, "size": 0.10, "interpretability": 0.30, "thermal": 0.00}
    if profile == "energy_first":
        return {"quality": 0.20, "latency": 0.30, "size": 0.20, "interpretability": 0.05, "thermal": 0.25}
    if profile in {"old_device_or_no_ane", "old_device", "no_ane"}:
        return {"quality": 0.25, "latency": 0.55, "size": 0.10, "interpretability": 0.10, "thermal": 0.00}
    return {"quality": 0.40, "latency": 0.35, "size": 0.10, "interpretability": 0.15, "thermal": 0.00}


def normalize_scenario(data):
    datasets = data.get("datasets") or {}
    if not datasets:
        primary = normalize_dataset_id(data.get("datasetId", "imagenette2_160_subset_500"))
        datasets = {
            "primaryDatasetId": primary,
            "validationDatasetIds": [],
            "hardDatasetIds": [],
            "smokeDatasetId": None,
        }
    else:
        datasets = {
            "primaryDatasetId": normalize_dataset_id(datasets["primaryDatasetId"]),
            "validationDatasetIds": [normalize_dataset_id(value) for value in datasets.get("validationDatasetIds", [])],
            "hardDatasetIds": [normalize_dataset_id(value) for value in datasets.get("hardDatasetIds", [])],
            "smokeDatasetId": normalize_dataset_id(datasets["smokeDatasetId"]) if datasets.get("smokeDatasetId") else None,
        }

    quality_thresholds = data.get("qualityThresholds") or {
        "primary": {
            "minTop1": data.get("minTop1Accuracy"),
            "minRestrictedTop1": data.get("minRestrictedTop1Accuracy"),
        }
    }
    return {
        "usageScenario": str(data.get("usageScenario") or "single_image_analysis").lower(),
        "priorityProfile": str(data.get("priorityProfile") or data.get("profile") or "balanced").lower(),
        "targetDeviceClass": str(data.get("targetDeviceClass") or "").lower(),
        "requiredComputeUnits": normalize_compute(data["requiredComputeUnits"]) if data.get("requiredComputeUnits") else None,
        "latencyBudgetMs": as_float(data.get("latencyBudgetMs")),
        "p90LatencyBudgetMs": as_float(data.get("p90LatencyBudgetMs")),
        "p95LatencyBudgetMs": as_float(data.get("p95LatencyBudgetMs")),
        "maxModelSizeMb": as_float(data.get("maxModelSizeMb")),
        "preferInterpretableOptimization": bool(data.get("preferInterpretableOptimization", False)),
        "allowPalettizedWeights": bool(data.get("allowPalettizedWeights", True)),
        "datasets": datasets,
        "qualityThresholds": quality_thresholds,
    }


def build_role_map(config):
    roles = {}
    datasets = config["datasets"]
    roles[datasets["primaryDatasetId"]] = "primary"
    for dataset_id in datasets["validationDatasetIds"]:
        roles.setdefault(dataset_id, "validation")
    for dataset_id in datasets["hardDatasetIds"]:
        roles.setdefault(dataset_id, "hard")
    if datasets["smokeDatasetId"]:
        roles.setdefault(datasets["smokeDatasetId"], "smoke")
    return roles


scenario_cfg = normalize_scenario(scenario)
role_map = build_role_map(scenario_cfg)
primary_dataset_id = scenario_cfg["datasets"]["primaryDatasetId"]
validation_dataset_ids = scenario_cfg["datasets"]["validationDatasetIds"]
hard_dataset_ids = scenario_cfg["datasets"]["hardDatasetIds"]

runs = results.get("runs") or results.get("results") or []
if not isinstance(runs, list) or not runs:
    raise SystemExit("No runs found in benchmark results. Expected key: runs[]")


def empty_dataset_metrics():
    return {
        "datasetId": None,
        "role": "unspecified",
        "dataset": None,
        "latency": {},
        "accuracy": {},
        "statuses": [],
        "errors": [],
    }


candidates = {}

for run in runs:
    model_id = as_str(run.get("modelId") or run.get("id") or "unknown_model")
    compute_units = normalize_compute(run.get("computeUnits"))
    dataset_id = normalize_dataset_id(run.get("datasetId") or pick(run, [("dataset", "datasetId")], "unspecified"))
    candidate_key = (model_id, compute_units)
    candidate = candidates.setdefault(
        candidate_key,
        {
            "modelId": model_id,
            "family": as_str(run.get("family") or ""),
            "format": as_str(run.get("format") or ""),
            "optimizationType": as_str(run.get("optimizationType") or ""),
            "computeUnits": compute_units,
            "modelSizeMb": as_float(run.get("modelSizeMb")),
            "thermalState": as_str(pick(run, [("diagnostics", "thermalState"), ("thermalState",)], "unknown")),
            "residentMemoryMb": as_float(pick(run, [("diagnostics", "residentMemoryMb"), ("residentMemoryMb",)])),
            "datasets": {},
        },
    )

    dataset_metrics = candidate["datasets"].setdefault(dataset_id, empty_dataset_metrics())
    dataset_metrics["datasetId"] = dataset_id
    dataset_metrics["role"] = pick(run, [("dataset", "role")], role_map.get(dataset_id, "unspecified"))
    dataset_metrics["dataset"] = run.get("dataset") or dataset_metrics["dataset"]
    dataset_metrics["statuses"].append(as_str(run.get("status") or "unknown"))

    if run.get("status") == "failed":
        error = run.get("error") or {}
        dataset_metrics["errors"].append(
            {
                "code": as_str(error.get("code") or "run_failed"),
                "message": as_str(error.get("message") or "experiment failed"),
                "experimentId": as_str(run.get("experimentId")),
            }
        )
        continue

    latency = run.get("latency") or {}
    accuracy = run.get("accuracy") or {}

    if latency:
        dataset_metrics["latency"].update(
            {
                "medianMs": as_float(latency.get("fullPipelineMedianMs") or latency.get("medianMs")),
                "p90Ms": as_float(latency.get("p90Ms")),
                "p95Ms": as_float(latency.get("p95Ms")),
                "inferenceMedianMs": as_float(latency.get("inferenceMedianMs")),
                "preprocessingMedianMs": as_float(latency.get("preprocessingMedianMs")),
                "postprocessingMedianMs": as_float(latency.get("postprocessingMedianMs")),
                "imageLoadingMedianMs": as_float(latency.get("imageLoadingMedianMs")),
            }
        )

    if accuracy:
        dataset_metrics["accuracy"].update(
            {
                "top1": as_float(accuracy.get("top1")),
                "top5": as_float(accuracy.get("top5")),
                "restrictedTop1": as_float(accuracy.get("restrictedTop1")),
                "totalImages": as_int(accuracy.get("totalImages")),
                "correctTop1": as_int(accuracy.get("correctTop1")),
                "correctTop5": as_int(accuracy.get("correctTop5")),
                "correctRestrictedTop1": as_int(accuracy.get("correctRestrictedTop1")),
                "perClassAccuracy": accuracy.get("perClassAccuracy"),
            }
        )


if not candidates:
    raise SystemExit("No model candidates could be built from benchmark results.")

profile = scenario_cfg["priorityProfile"]
weights = weights_for(profile)
global_warnings = []

score_base = []
for candidate in candidates.values():
    primary_metrics = candidate["datasets"].get(primary_dataset_id)
    if primary_metrics:
        score_base.append(
            {
                "quality": quality_raw(primary_metrics["accuracy"]),
                "medianMs": primary_metrics["latency"].get("medianMs"),
                "modelSizeMb": candidate["modelSizeMb"],
            }
        )

quality_values = [entry["quality"] for entry in score_base if entry["quality"] is not None]
median_values = [entry["medianMs"] for entry in score_base if entry["medianMs"] is not None]
size_values = [entry["modelSizeMb"] for entry in score_base if entry["modelSizeMb"] is not None]

primary_thresholds = scenario_cfg["qualityThresholds"].get("primary", {})
validation_thresholds = scenario_cfg["qualityThresholds"].get("validation", {})
hard_thresholds = scenario_cfg["qualityThresholds"].get("hard", {})


def pp_drop(primary_value, other_value):
    if primary_value is None or other_value is None:
        return None
    return (primary_value - other_value) * 100.0


def evaluate_robustness(candidate, dataset_ids, thresholds, role_name):
    entries = []
    total_penalty = 0.0
    warnings = []
    primary_metrics = candidate["datasets"].get(primary_dataset_id, {})
    primary_accuracy = primary_metrics.get("accuracy", {})

    for dataset_id in dataset_ids:
        metrics = candidate["datasets"].get(dataset_id)
        if not metrics:
            message = f"missing {role_name} dataset run: {dataset_id}"
            warnings.append(message)
            entries.append({"datasetId": dataset_id, "status": "missing", "warnings": [message]})
            continue

        dataset_accuracy = metrics.get("accuracy", {})
        top1_drop = pp_drop(primary_accuracy.get("top1"), dataset_accuracy.get("top1"))
        top5_drop = pp_drop(primary_accuracy.get("top5"), dataset_accuracy.get("top5"))
        restricted_drop = pp_drop(primary_accuracy.get("restrictedTop1"), dataset_accuracy.get("restrictedTop1"))

        dataset_warnings = []
        status = "passed"
        max_drop = as_float(thresholds.get("maxAccuracyDropPp"))
        min_top1 = as_float(thresholds.get("minTop1"))

        if metrics.get("errors"):
            status = "failed"
            dataset_warnings.extend(error["message"] for error in metrics["errors"])

        if max_drop is not None and top1_drop is not None and top1_drop > max_drop:
            status = "warning"
            dataset_warnings.append(
                f"{role_name} top-1 drop {top1_drop:.2f} pp exceeds threshold {max_drop:.2f} pp"
            )
            if profile in {"balanced", "conservative_deployment"}:
                total_penalty += 0.20 if role_name == "hard" else 0.12
            elif profile == "latency_first" and top1_drop > max_drop + 10:
                total_penalty += 0.05

        if min_top1 is not None and dataset_accuracy.get("top1") is not None and dataset_accuracy["top1"] < min_top1:
            status = "warning"
            dataset_warnings.append(
                f"{role_name} top-1 {dataset_accuracy['top1']:.3f} is below minimum {min_top1:.3f}"
            )
            if profile in {"balanced", "conservative_deployment"}:
                total_penalty += 0.18 if role_name == "hard" else 0.10
            elif profile == "latency_first" and dataset_accuracy["top1"] < min_top1 - 0.05:
                total_penalty += 0.05

        entries.append(
            {
                "datasetId": dataset_id,
                "status": status,
                "warnings": dataset_warnings,
                "metrics": metrics,
                "drops": {
                    "top1DropPp": top1_drop,
                    "top5DropPp": top5_drop,
                    "restrictedTop1DropPp": restricted_drop,
                },
            }
        )
        warnings.extend(dataset_warnings)
    return entries, warnings, total_penalty


ranked = []

for candidate in candidates.values():
    primary_metrics = candidate["datasets"].get(primary_dataset_id)
    failures = []
    warnings = []

    if not primary_metrics:
        failures.append(f"missing primary dataset run: {primary_dataset_id}")
        primary_accuracy = {}
        primary_latency = {}
    else:
        primary_accuracy = primary_metrics.get("accuracy", {})
        primary_latency = primary_metrics.get("latency", {})
        if primary_metrics.get("errors"):
            failures.extend(error["message"] for error in primary_metrics["errors"])

    required_compute = scenario_cfg["requiredComputeUnits"]
    if required_compute and candidate["computeUnits"] != required_compute:
        failures.append(f"requires computeUnits={required_compute}, got {candidate['computeUnits']}")

    latency_budget = scenario_cfg["latencyBudgetMs"]
    p90_budget = scenario_cfg["p90LatencyBudgetMs"]
    p95_budget = scenario_cfg["p95LatencyBudgetMs"]
    max_model_size = scenario_cfg["maxModelSizeMb"]

    if latency_budget is not None:
        median = primary_latency.get("medianMs")
        if median is None:
            failures.append("missing primary median fullPipeline latency")
        elif median > latency_budget:
            failures.append(f"primary median latency {median:.2f} ms > budget {latency_budget:.2f} ms")

    if p90_budget is not None:
        p90 = primary_latency.get("p90Ms")
        if p90 is None:
            failures.append("missing primary p90 latency")
        elif p90 > p90_budget:
            failures.append(f"primary p90 latency {p90:.2f} ms > budget {p90_budget:.2f} ms")

    if p95_budget is not None:
        p95 = primary_latency.get("p95Ms")
        if p95 is None:
            failures.append("missing primary p95 latency")
        elif p95 > p95_budget:
            failures.append(f"primary p95 latency {p95:.2f} ms > budget {p95_budget:.2f} ms")

    min_primary_top1 = as_float(primary_thresholds.get("minTop1"))
    min_primary_restricted = as_float(primary_thresholds.get("minRestrictedTop1"))

    if min_primary_top1 is not None:
        if primary_accuracy.get("top1") is None:
            failures.append("missing primary top-1 accuracy")
        elif primary_accuracy["top1"] < min_primary_top1:
            failures.append(
                f"primary top-1 accuracy {primary_accuracy['top1']:.3f} < minimum {min_primary_top1:.3f}"
            )

    if min_primary_restricted is not None:
        if primary_accuracy.get("restrictedTop1") is None:
            failures.append("missing primary restricted top-1 accuracy")
        elif primary_accuracy["restrictedTop1"] < min_primary_restricted:
            failures.append(
                f"primary restricted top-1 {primary_accuracy['restrictedTop1']:.3f} < minimum {min_primary_restricted:.3f}"
            )

    if max_model_size is not None:
        size = candidate["modelSizeMb"]
        if size is None:
            failures.append("missing model size")
        elif size > max_model_size:
            failures.append(f"model size {size:.1f} MB > maximum {max_model_size:.1f} MB")

    if not scenario_cfg["allowPalettizedWeights"] and "palett" in str(candidate["optimizationType"]).lower():
        failures.append("palettized weights are not allowed by scenario")

    if scenario_cfg["preferInterpretableOptimization"] and interpretability_score(candidate) < 0.80:
        warnings.append("less interpretable optimization type compared with FP16/FP32")

    validation_entries, validation_warnings, validation_penalty = evaluate_robustness(
        candidate,
        validation_dataset_ids,
        validation_thresholds,
        "validation",
    )
    hard_entries, hard_warnings, hard_penalty = evaluate_robustness(
        candidate,
        hard_dataset_ids,
        hard_thresholds,
        "hard",
    )

    warnings.extend(validation_warnings)
    warnings.extend(hard_warnings)

    quality_score = quality_raw(primary_accuracy) or 0.0
    latency_score = norm_lower(primary_latency.get("medianMs"), median_values)
    size_score = norm_lower(candidate["modelSizeMb"], size_values)
    interp_score = interpretability_score(candidate)
    therm_score = thermal_score(candidate)

    total_score = (
        quality_score * weights["quality"]
        + latency_score * weights["latency"]
        + size_score * weights["size"]
        + interp_score * weights["interpretability"]
        + therm_score * weights["thermal"]
        - validation_penalty
        - hard_penalty
    )

    eligible = not failures
    if not eligible:
        total_score -= 10.0

    candidate.update(
        {
            "primaryMetrics": primary_metrics,
            "validationChecks": validation_entries,
            "hardChecks": hard_entries,
            "failures": failures,
            "warnings": warnings,
            "eligible": eligible,
            "scores": {
                "quality": quality_score,
                "latency": latency_score,
                "size": size_score,
                "interpretability": interp_score,
                "thermal": therm_score,
                "validationPenalty": validation_penalty,
                "hardPenalty": hard_penalty,
                "total": total_score,
            },
        }
    )
    ranked.append(candidate)

ranked.sort(
    key=lambda entry: (
        entry["eligible"],
        entry["scores"]["total"],
        -(((entry.get("primaryMetrics") or {}).get("latency") or {}).get("medianMs") or 10**9),
    ),
    reverse=True,
)

recommended = next((entry for entry in ranked if entry["eligible"]), None)


def candidate_name(candidate):
    family = candidate["family"] or candidate["modelId"]
    fmt = candidate["format"] or ""
    compute = candidate["computeUnits"] or ""
    base = f"{family}_{fmt}" if fmt and fmt not in family else candidate["modelId"]
    return f"{base} [{compute}]"


def recommendation_reasons(candidate):
    if candidate is None:
        return ["No eligible configuration found. Relax scenario constraints or inspect failed dataset runs."]

    reasons = []
    primary = candidate["primaryMetrics"]
    latency = primary.get("latency", {})
    accuracy = primary.get("accuracy", {})
    reasons.append("best primary dataset quality-latency trade-off under current scenario")
    if accuracy.get("top1") is not None:
        reasons.append(f"primary top-1: {accuracy['top1']:.3f}")
    if accuracy.get("restrictedTop1") is not None:
        reasons.append(f"primary restricted top-1: {accuracy['restrictedTop1']:.3f}")
    if latency.get("medianMs") is not None:
        reasons.append(f"primary median latency: {latency['medianMs']:.2f} ms")
    if candidate["hardChecks"]:
        critical_hard = [entry for entry in candidate["hardChecks"] if entry.get("warnings")]
        if critical_hard:
            reasons.append("hard dataset has warnings but remained acceptable after profile penalties")
        else:
            reasons.append("no critical degradation on hard datasets")
    return reasons


generated_at = datetime.now(timezone.utc).isoformat()
report_lines = []
report_lines.append("# Ranking report")
report_lines.append("")
report_lines.append(f"Generated at: `{generated_at}`")
report_lines.append("")
report_lines.append("## Scenario")
report_lines.append("")
report_lines.append(f"- Usage scenario: `{scenario_cfg['usageScenario']}`")
report_lines.append(f"- Priority profile: `{profile}`")
report_lines.append(f"- Primary dataset: `{primary_dataset_id}`")
if validation_dataset_ids:
    report_lines.append(f"- Validation datasets: `{', '.join(validation_dataset_ids)}`")
if hard_dataset_ids:
    report_lines.append(f"- Hard datasets: `{', '.join(hard_dataset_ids)}`")

if global_warnings:
    report_lines.append("")
    report_lines.append("## Global warnings")
    report_lines.append("")
    for warning in global_warnings:
        report_lines.append(f"- {warning}")

report_lines.append("")
report_lines.append("## Recommendation")
report_lines.append("")

if recommended is None:
    report_lines.append("No eligible configuration found.")
else:
    report_lines.append(f"Recommended: **{candidate_name(recommended)}**")
    report_lines.append("")
    report_lines.append("Primary dataset:")
    recommended_primary_accuracy = (recommended.get("primaryMetrics") or {}).get("accuracy") or {}
    recommended_primary_latency = (recommended.get("primaryMetrics") or {}).get("latency") or {}
    report_lines.append(f"- top1: {fmt_num(recommended_primary_accuracy.get('top1'))}")
    report_lines.append(f"- restrictedTop1: {fmt_num(recommended_primary_accuracy.get('restrictedTop1'))}")
    report_lines.append(f"- median latency: {fmt_ms(recommended_primary_latency.get('medianMs'))}")

    if recommended["validationChecks"]:
        report_lines.append("")
        report_lines.append("Validation datasets:")
        for entry in recommended["validationChecks"]:
            metrics = entry.get("metrics", {})
            accuracy = metrics.get("accuracy", {})
            report_lines.append(
                f"- {entry['datasetId']}: top1={fmt_num(accuracy.get('top1'))}, "
                f"top1 drop={fmt_pp(entry.get('drops', {}).get('top1DropPp'))}, status={entry['status']}"
            )

    if recommended["hardChecks"]:
        report_lines.append("")
        report_lines.append("Hard datasets:")
        for entry in recommended["hardChecks"]:
            metrics = entry.get("metrics", {})
            accuracy = metrics.get("accuracy", {})
            report_lines.append(
                f"- {entry['datasetId']}: top1={fmt_num(accuracy.get('top1'))}, "
                f"top1 drop={fmt_pp(entry.get('drops', {}).get('top1DropPp'))}, status={entry['status']}"
            )

    report_lines.append("")
    report_lines.append("Decision:")
    for reason in recommendation_reasons(recommended):
        report_lines.append(f"- {reason}")

report_lines.append("")
report_lines.append("## Ranking")
report_lines.append("")
report_lines.append("| Rank | Candidate | Eligible | Primary top-1 | Primary restricted top-1 | Primary median | Validation/hard warnings | Total score |")
report_lines.append("|---:|---|---:|---:|---:|---:|---|---:|")

display_rank = 1
for entry in ranked:
    primary_accuracy = (entry.get("primaryMetrics") or {}).get("accuracy") or {}
    primary_latency = (entry.get("primaryMetrics") or {}).get("latency") or {}
    warning_text = "; ".join(entry["warnings"]) if entry["warnings"] else ""
    failure_text = "; ".join(entry["failures"]) if entry["failures"] else "yes"
    rank_value = str(display_rank) if entry["eligible"] else "—"
    if entry["eligible"]:
        display_rank += 1
    report_lines.append(
        "| "
        + " | ".join(
            [
                rank_value,
                candidate_name(entry),
                failure_text,
                fmt_num(primary_accuracy.get("top1")),
                fmt_num(primary_accuracy.get("restrictedTop1")),
                fmt_ms(primary_latency.get("medianMs")),
                warning_text,
                fmt_num(entry["scores"]["total"]),
            ]
        )
        + " |"
    )

report_lines.append("")
report_lines.append("## Notes")
report_lines.append("")
report_lines.append("- Ranking is built only from the primary dataset. Validation and hard datasets contribute warnings or penalties, but are never averaged into the primary score.")
report_lines.append("- Positive drop in percentage points means degradation versus the primary dataset.")
report_lines.append("- `latency_first` keeps validation/hard checks mostly as warnings unless degradation becomes severe.")

report_path = output_dir / "ranking_report.md"
report_path.write_text("\n".join(report_lines), encoding="utf-8")


def serializable_entry(entry, rank):
    return {
        "rank": rank,
        "modelId": entry["modelId"],
        "name": candidate_name(entry),
        "family": entry["family"],
        "format": entry["format"],
        "optimizationType": entry["optimizationType"],
        "computeUnits": entry["computeUnits"],
        "eligible": entry["eligible"],
        "failures": entry["failures"],
        "warnings": entry["warnings"],
        "primaryDatasetId": primary_dataset_id,
        "primaryMetrics": entry["primaryMetrics"],
        "validationChecks": entry["validationChecks"],
        "hardChecks": entry["hardChecks"],
        "scores": entry["scores"],
    }


ranking_json = {
    "generatedAt": generated_at,
    "scenario": scenario_cfg,
    "recommendation": None if recommended is None else {
        "modelId": recommended["modelId"],
        "name": candidate_name(recommended),
        "reasons": recommendation_reasons(recommended),
    },
    "ranking": [],
}

eligible_entries = [entry for entry in ranked if entry["eligible"]]
for rank_index, entry in enumerate(eligible_entries, start=1):
    ranking_json["ranking"].append(serializable_entry(entry, rank_index))
for entry in ranked:
    if not entry["eligible"]:
        ranking_json["ranking"].append(serializable_entry(entry, None))

ranking_path = output_dir / "ranking.json"
ranking_path.write_text(json.dumps(ranking_json, ensure_ascii=False, indent=2), encoding="utf-8")

print(f"Generated: {report_path}")
print(f"Generated: {ranking_path}")
if recommended:
    print(f"Recommended: {candidate_name(recommended)}")
else:
    print("Recommended: none")
PY
