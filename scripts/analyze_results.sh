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
import sys
import math
from pathlib import Path
from datetime import datetime, timezone

results_path = Path(sys.argv[1])
scenario_path = Path(sys.argv[2])
output_dir = Path(sys.argv[3])

with results_path.open("r", encoding="utf-8") as f:
    results = json.load(f)

with scenario_path.open("r", encoding="utf-8") as f:
    scenario = json.load(f)


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


def fmt_num(value, digits=3, suffix=""):
    if value is None:
        return "—"
    return f"{value:.{digits}f}{suffix}"


def fmt_ms(value):
    if value is None:
        return "—"
    return f"{value:.2f} ms"


def fmt_mb(value):
    if value is None:
        return "—"
    return f"{value:.1f} MB"


def is_palettized(candidate):
    text = " ".join([
        str(candidate.get("format") or ""),
        str(candidate.get("optimizationType") or ""),
        str(candidate.get("modelId") or "")
    ]).lower()
    return "palett" in text or "lut" in text


def is_int8_label(candidate):
    text = " ".join([
        str(candidate.get("format") or ""),
        str(candidate.get("optimizationType") or ""),
        str(candidate.get("modelId") or "")
    ]).lower()
    return "int8" in text or "8bit" in text or "8-bit" in text


def interpretability_score(candidate):
    fmt = str(candidate.get("format") or "").upper()
    opt = str(candidate.get("optimizationType") or "").lower()

    if "FP16" in fmt or "float16" in opt:
        return 1.0
    if "FP32" in fmt or "float32" in opt:
        return 0.85
    if "w8a8" in opt or "integer" in opt:
        return 0.80
    if is_palettized(candidate):
        return 0.65
    if is_int8_label(candidate):
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


def norm_higher(value, values):
    if value is None:
        return 0.0
    valid = [v for v in values if v is not None]
    if not valid:
        return 0.0
    lo, hi = min(valid), max(valid)
    if math.isclose(lo, hi):
        return 1.0
    return max(0.0, min(1.0, (value - lo) / (hi - lo)))


def norm_lower(value, values):
    if value is None:
        return 0.0
    valid = [v for v in values if v is not None]
    if not valid:
        return 0.0
    lo, hi = min(valid), max(valid)
    if math.isclose(lo, hi):
        return 1.0
    return max(0.0, min(1.0, (hi - value) / (hi - lo)))


def quality_raw(candidate):
    top1 = candidate.get("top1")
    top5 = candidate.get("top5")
    restricted = candidate.get("restrictedTop1")

    parts = []
    if top1 is not None:
        parts.append((top1, 0.45))
    if restricted is not None:
        parts.append((restricted, 0.35))
    if top5 is not None:
        parts.append((top5, 0.20))

    if not parts:
        return None

    total_weight = sum(w for _, w in parts)
    return sum(v * w for v, w in parts) / total_weight


def usage_is_stream(usage_scenario):
    return usage_scenario in {"camera_stream", "video_stream", "stream", "real_time"}


def weights_for(profile):
    profile = profile.lower()

    if profile == "latency_first":
        return {
            "quality": 0.15,
            "latency": 0.70,
            "size": 0.10,
            "interpretability": 0.05,
            "thermal": 0.00,
        }

    if profile == "accuracy_first":
        return {
            "quality": 0.70,
            "latency": 0.15,
            "size": 0.05,
            "interpretability": 0.10,
            "thermal": 0.00,
        }

    if profile == "disk_size_first":
        return {
            "quality": 0.15,
            "latency": 0.20,
            "size": 0.60,
            "interpretability": 0.05,
            "thermal": 0.00,
        }

    if profile == "conservative_deployment":
        return {
            "quality": 0.35,
            "latency": 0.25,
            "size": 0.10,
            "interpretability": 0.30,
            "thermal": 0.00,
        }

    if profile == "energy_first":
        return {
            "quality": 0.20,
            "latency": 0.30,
            "size": 0.20,
            "interpretability": 0.05,
            "thermal": 0.25,
        }

    if profile in {"old_device_or_no_ane", "old_device", "no_ane"}:
        return {
            "quality": 0.25,
            "latency": 0.55,
            "size": 0.10,
            "interpretability": 0.10,
            "thermal": 0.00,
        }

    return {
        "quality": 0.40,
        "latency": 0.35,
        "size": 0.10,
        "interpretability": 0.15,
        "thermal": 0.00,
    }


root_compute = normalize_compute(pick(results, [
    ("device", "computeUnits"),
    ("runtime", "computeUnits"),
    ("computeUnits",),
], "UNKNOWN"))

runs = (
    results.get("runs")
    or results.get("results")
    or results.get("experiments")
    or []
)

if not isinstance(runs, list) or not runs:
    raise SystemExit("No runs found in benchmark results. Expected key: runs[]")

candidates = []

for index, run in enumerate(runs, start=1):
    model_id = as_str(pick(run, [
        ("modelId",),
        ("id",),
        ("modelName",),
        ("model", "id"),
        ("model", "name"),
    ], f"model_{index}"))

    candidate = {
        "modelId": model_id,
        "family": as_str(pick(run, [
            ("family",),
            ("modelFamily",),
            ("model", "family"),
        ], "")),
        "format": as_str(pick(run, [
            ("format",),
            ("modelFormat",),
            ("model", "format"),
        ], "")),
        "optimizationType": as_str(pick(run, [
            ("optimizationType",),
            ("optimization", "type"),
            ("model", "optimizationType"),
        ], "")),
        "computeUnits": normalize_compute(pick(run, [
            ("computeUnits",),
            ("compute", "units"),
            ("runtime", "computeUnits"),
        ], root_compute)),
        "measurementMode": as_str(pick(run, [
            ("measurementMode",),
            ("measurement", "mode"),
        ], "")),
        "modelSizeMb": as_float(pick(run, [
            ("modelSizeMb",),
            ("sizeMb",),
            ("model", "sizeMb"),
            ("model", "modelSizeMb"),
        ])),
        "medianMs": as_float(pick(run, [
            ("latency", "fullPipelineMedianMs"),
            ("latency", "medianMs"),
            ("metrics", "fullPipelineMedianMs"),
            ("metrics", "medianMs"),
            ("fullPipelineMedianMs",),
            ("medianMs",),
        ])),
        "p90Ms": as_float(pick(run, [
            ("latency", "p90Ms"),
            ("metrics", "p90Ms"),
            ("p90Ms",),
        ])),
        "p95Ms": as_float(pick(run, [
            ("latency", "p95Ms"),
            ("metrics", "p95Ms"),
            ("p95Ms",),
        ])),
        "inferenceMedianMs": as_float(pick(run, [
            ("latency", "inferenceMedianMs"),
            ("segments", "inferenceMedianMs"),
            ("metrics", "inferenceMedianMs"),
            ("inferenceMedianMs",),
        ])),
        "preprocessingMedianMs": as_float(pick(run, [
            ("latency", "preprocessingMedianMs"),
            ("segments", "preprocessingMedianMs"),
            ("metrics", "preprocessingMedianMs"),
            ("preprocessingMedianMs",),
        ])),
        "top1": as_float(pick(run, [
            ("accuracy", "top1"),
            ("metrics", "top1"),
            ("top1",),
        ])),
        "top5": as_float(pick(run, [
            ("accuracy", "top5"),
            ("metrics", "top5"),
            ("top5",),
        ])),
        "restrictedTop1": as_float(pick(run, [
            ("accuracy", "restrictedTop1"),
            ("accuracy", "restricted_top1"),
            ("metrics", "restrictedTop1"),
            ("restrictedTop1",),
        ])),
        "top1Agree": as_float(pick(run, [
            ("agreement", "top1"),
            ("metrics", "top1Agree"),
            ("top1Agree",),
        ])),
        "top5Agree": as_float(pick(run, [
            ("agreement", "top5"),
            ("metrics", "top5Agree"),
            ("top5Agree",),
        ])),
        "restrictedTop1Agree": as_float(pick(run, [
            ("agreement", "restrictedTop1"),
            ("metrics", "restrictedTop1Agree"),
            ("restrictedTop1Agree",),
        ])),
        "thermalState": as_str(pick(run, [
            ("diagnostics", "thermalState"),
            ("thermalState",),
        ], "unknown")),
        "residentMemoryMb": as_float(pick(run, [
            ("diagnostics", "residentMemoryMb"),
            ("residentMemoryMb",),
        ])),
        "hasSustainedBenchmark": bool(pick(run, [
            ("diagnostics", "hasSustainedBenchmark"),
            ("hasSustainedBenchmark",),
        ], False)),
        "raw": run,
    }

    candidate["qualityRaw"] = quality_raw(candidate)
    candidate["interpretabilityScore"] = interpretability_score(candidate)
    candidate["thermalScore"] = thermal_score(candidate)
    candidate["isPalettized"] = is_palettized(candidate)
    candidate["isInt8Label"] = is_int8_label(candidate)

    candidates.append(candidate)


profile = str(
    scenario.get("priorityProfile")
    or scenario.get("profile")
    or "balanced"
).lower()

usage_scenario = str(
    scenario.get("usageScenario")
    or scenario.get("scenario")
    or "single_image_analysis"
).lower()

target_device_class = str(scenario.get("targetDeviceClass") or "").lower()

latency_budget = as_float(scenario.get("latencyBudgetMs"))
p90_budget = as_float(scenario.get("p90LatencyBudgetMs"))
p95_budget = as_float(scenario.get("p95LatencyBudgetMs"))
min_top1 = as_float(scenario.get("minTop1Accuracy"))
min_top5 = as_float(scenario.get("minTop5Accuracy"))
min_restricted = as_float(scenario.get("minRestrictedTop1Accuracy"))
max_model_size = as_float(scenario.get("maxModelSizeMb"))
allow_palettized = bool(scenario.get("allowPalettizedWeights", True))
prefer_interpretable = bool(scenario.get("preferInterpretableOptimization", False))

required_compute = scenario.get("requiredComputeUnits")
required_compute = normalize_compute(required_compute) if required_compute else None

cpu_runs_available = any(c["computeUnits"] == "CPU_ONLY" for c in candidates)

if not required_compute:
    if profile in {"old_device", "old_device_or_no_ane", "no_ane"} or "old" in target_device_class or "no_ane" in target_device_class:
        if cpu_runs_available:
            required_compute = "CPU_ONLY"

global_warnings = []

if (profile in {"old_device", "old_device_or_no_ane", "no_ane"} or "old" in target_device_class or "no_ane" in target_device_class) and not cpu_runs_available:
    global_warnings.append(
        "Selected old-device/no-ANE scenario, but benchmark results do not contain CPU_ONLY runs. Ranking is based on available runs and should be treated as preliminary."
    )

if usage_is_stream(usage_scenario):
    has_any_sustained = any(c["hasSustainedBenchmark"] for c in candidates)
    if not has_any_sustained:
        global_warnings.append(
            "Stream scenario selected, but no sustained benchmark metrics were found. Ranking uses p90/p95 latency as proxy and should be validated with long-run thermal tests."
        )


for c in candidates:
    failures = []
    warnings = []

    if required_compute and c["computeUnits"] != required_compute:
        failures.append(f"requires computeUnits={required_compute}, got {c['computeUnits']}")

    if latency_budget is not None:
        if c["medianMs"] is None:
            failures.append("missing median fullPipeline latency")
        elif c["medianMs"] > latency_budget:
            failures.append(f"median latency {c['medianMs']:.2f} ms > budget {latency_budget:.2f} ms")

    if p90_budget is not None:
        if c["p90Ms"] is None:
            failures.append("missing p90 latency")
        elif c["p90Ms"] > p90_budget:
            failures.append(f"p90 latency {c['p90Ms']:.2f} ms > budget {p90_budget:.2f} ms")

    if p95_budget is not None:
        if c["p95Ms"] is None:
            failures.append("missing p95 latency")
        elif c["p95Ms"] > p95_budget:
            failures.append(f"p95 latency {c['p95Ms']:.2f} ms > budget {p95_budget:.2f} ms")

    if min_top1 is not None:
        if c["top1"] is None:
            failures.append("missing top-1 accuracy")
        elif c["top1"] < min_top1:
            failures.append(f"top-1 accuracy {c['top1']:.3f} < minimum {min_top1:.3f}")

    if min_top5 is not None:
        if c["top5"] is None:
            failures.append("missing top-5 accuracy")
        elif c["top5"] < min_top5:
            failures.append(f"top-5 accuracy {c['top5']:.3f} < minimum {min_top5:.3f}")

    if min_restricted is not None:
        if c["restrictedTop1"] is None:
            failures.append("missing restricted top-1 accuracy")
        elif c["restrictedTop1"] < min_restricted:
            failures.append(f"restricted top-1 accuracy {c['restrictedTop1']:.3f} < minimum {min_restricted:.3f}")

    if max_model_size is not None:
        if c["modelSizeMb"] is None:
            failures.append("missing model size")
        elif c["modelSizeMb"] > max_model_size:
            failures.append(f"model size {c['modelSizeMb']:.1f} MB > maximum {max_model_size:.1f} MB")

    if not allow_palettized and c["isPalettized"]:
        failures.append("palettized weights are not allowed by scenario")

    if c["isInt8Label"] and c["isPalettized"]:
        warnings.append("INT8-labeled model is interpreted as palettized/weight-compressed, not proven W8A8 integer inference")

    if c["top5Agree"] is not None and c["top5Agree"] < 0.80:
        warnings.append(f"low top-5 agreement with FP32 baseline: {c['top5Agree']:.3f}")

    if usage_is_stream(usage_scenario) and not c["hasSustainedBenchmark"]:
        warnings.append("stream scenario uses non-sustained metrics as proxy")

    if prefer_interpretable and c["interpretabilityScore"] < 0.80:
        warnings.append("less interpretable optimization type compared with FP16/FP32")

    thermal_state = str(c["thermalState"] or "").lower()
    if thermal_state in {"serious", "critical"}:
        warnings.append(f"thermal state is {thermal_state}")

    c["failures"] = failures
    c["warnings"] = warnings
    c["eligible"] = len(failures) == 0


eligible = [c for c in candidates if c["eligible"]]

score_base = eligible if eligible else candidates

quality_values = [c["qualityRaw"] for c in score_base]
median_values = [c["medianMs"] for c in score_base]
p90_values = [c["p90Ms"] for c in score_base]
p95_values = [c["p95Ms"] for c in score_base]
size_values = [c["modelSizeMb"] for c in score_base]

weights = weights_for(profile)

for c in candidates:
    quality_score = c["qualityRaw"] if c["qualityRaw"] is not None else 0.0

    if usage_is_stream(usage_scenario):
        latency_parts = []
        if c["p95Ms"] is not None:
            latency_parts.append((norm_lower(c["p95Ms"], p95_values), 0.45))
        if c["p90Ms"] is not None:
            latency_parts.append((norm_lower(c["p90Ms"], p90_values), 0.40))
        if c["medianMs"] is not None:
            latency_parts.append((norm_lower(c["medianMs"], median_values), 0.15))
    else:
        latency_parts = []
        if c["medianMs"] is not None:
            latency_parts.append((norm_lower(c["medianMs"], median_values), 0.65))
        if c["p90Ms"] is not None:
            latency_parts.append((norm_lower(c["p90Ms"], p90_values), 0.35))

    if latency_parts:
        latency_score = sum(v * w for v, w in latency_parts) / sum(w for _, w in latency_parts)
    else:
        latency_score = 0.0

    size_score = norm_lower(c["modelSizeMb"], size_values)
    interp_score = c["interpretabilityScore"]
    therm_score = c["thermalScore"]

    total = (
        quality_score * weights["quality"]
        + latency_score * weights["latency"]
        + size_score * weights["size"]
        + interp_score * weights["interpretability"]
        + therm_score * weights["thermal"]
    )

    if not c["eligible"]:
        total = total - 10.0

    c["scores"] = {
        "quality": quality_score,
        "latency": latency_score,
        "size": size_score,
        "interpretability": interp_score,
        "thermal": therm_score,
        "total": total,
    }


ranked = sorted(
    candidates,
    key=lambda x: (
        x["eligible"],
        x["scores"]["total"],
        -(x["medianMs"] if x["medianMs"] is not None else 10**9)
    ),
    reverse=True
)

recommended = next((c for c in ranked if c["eligible"]), None)


def candidate_name(c):
    family = c["family"] or c["modelId"]
    fmt = c["format"] or ""
    compute = c["computeUnits"] or ""
    if fmt and fmt not in family:
        base = f"{family} {fmt}"
    else:
        base = c["modelId"]
    if compute:
        return f"{base} [{compute}]"
    return base


def recommendation_reasons(rec, ranked_candidates):
    if rec is None:
        return ["No eligible configuration found. Relax scenario constraints or check benchmark data."]

    reasons = []

    reasons.append("passes all required scenario constraints")

    if rec["medianMs"] is not None:
        reasons.append(f"median fullPipeline latency: {rec['medianMs']:.2f} ms")
    if rec["p90Ms"] is not None:
        reasons.append(f"p90 latency: {rec['p90Ms']:.2f} ms")
    if rec["top1"] is not None:
        reasons.append(f"top-1 accuracy: {rec['top1']:.3f}")
    if rec["restrictedTop1"] is not None:
        reasons.append(f"restricted top-1 accuracy: {rec['restrictedTop1']:.3f}")
    if rec["top5"] is not None:
        reasons.append(f"top-5 accuracy: {rec['top5']:.3f}")
    if rec["modelSizeMb"] is not None:
        reasons.append(f"model size: {rec['modelSizeMb']:.1f} MB")

    eligible_candidates = [c for c in ranked_candidates if c["eligible"]]

    if eligible_candidates:
        fastest = min(
            eligible_candidates,
            key=lambda c: c["medianMs"] if c["medianMs"] is not None else 10**9
        )
        best_quality = max(
            eligible_candidates,
            key=lambda c: c["qualityRaw"] if c["qualityRaw"] is not None else -1
        )
        smallest = min(
            eligible_candidates,
            key=lambda c: c["modelSizeMb"] if c["modelSizeMb"] is not None else 10**9
        )

        if fastest["modelId"] == rec["modelId"] and fastest["computeUnits"] == rec["computeUnits"]:
            reasons.append("has the best median latency among eligible configurations")
        elif fastest["medianMs"] is not None and rec["medianMs"] is not None:
            delta = rec["medianMs"] - fastest["medianMs"]
            reasons.append(f"is {delta:.2f} ms slower than the fastest eligible configuration, but provides a better overall scenario trade-off")

        if best_quality["modelId"] == rec["modelId"] and best_quality["computeUnits"] == rec["computeUnits"]:
            reasons.append("has the best quality score among eligible configurations")

        if profile == "disk_size_first" and smallest["modelId"] == rec["modelId"]:
            reasons.append("has the smallest model size among eligible configurations")

    if rec["isPalettized"]:
        reasons.append("warning: selected configuration appears to use palettized/weight-compressed representation")

    if rec["warnings"]:
        reasons.extend([f"warning: {w}" for w in rec["warnings"]])

    return reasons


generated_at = datetime.now(timezone.utc).isoformat()

report_lines = []

report_lines.append("# Ranking report")
report_lines.append("")
report_lines.append(f"Generated at: `{generated_at}`")
report_lines.append("")
report_lines.append("## Scenario")
report_lines.append("")
report_lines.append(f"- Usage scenario: `{usage_scenario}`")
report_lines.append(f"- Priority profile: `{profile}`")
report_lines.append(f"- Target device class: `{target_device_class or 'not specified'}`")
if required_compute:
    report_lines.append(f"- Required compute units for ranking: `{required_compute}`")
if latency_budget is not None:
    report_lines.append(f"- Median latency budget: `{latency_budget:.2f} ms`")
if p90_budget is not None:
    report_lines.append(f"- p90 latency budget: `{p90_budget:.2f} ms`")
if p95_budget is not None:
    report_lines.append(f"- p95 latency budget: `{p95_budget:.2f} ms`")
if min_top1 is not None:
    report_lines.append(f"- Minimum top-1 accuracy: `{min_top1:.3f}`")
if min_top5 is not None:
    report_lines.append(f"- Minimum top-5 accuracy: `{min_top5:.3f}`")
if min_restricted is not None:
    report_lines.append(f"- Minimum restricted top-1 accuracy: `{min_restricted:.3f}`")
if max_model_size is not None:
    report_lines.append(f"- Maximum model size: `{max_model_size:.1f} MB`")

device = results.get("device") or {}
if device:
    report_lines.append("")
    report_lines.append("## Device")
    report_lines.append("")
    for key in ["name", "model", "iosVersion", "computeUnits"]:
        if key in device:
            report_lines.append(f"- {key}: `{device[key]}`")

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
    report_lines.append(f"Recommended configuration: **{candidate_name(recommended)}**")
    report_lines.append("")
    report_lines.append("Reasons:")
    report_lines.append("")
    for reason in recommendation_reasons(recommended, ranked):
        report_lines.append(f"- {reason}")

report_lines.append("")
report_lines.append("## Ranking")
report_lines.append("")
report_lines.append("| Rank | Candidate | Eligible | Score | Median | p90 | Top-1 | Restricted top-1 | Top-5 | Size | Warnings |")
report_lines.append("|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---|")

rank_no = 1
for c in ranked:
    warnings_text = "; ".join(c["warnings"]) if c["warnings"] else ""
    failures_text = "; ".join(c["failures"]) if c["failures"] else ""
    status_text = "yes" if c["eligible"] else f"no: {failures_text}"

    display_rank = str(rank_no) if c["eligible"] else "—"
    if c["eligible"]:
        rank_no += 1

    report_lines.append(
        "| "
        + " | ".join([
            display_rank,
            candidate_name(c),
            status_text,
            fmt_num(c["scores"]["total"], 3),
            fmt_ms(c["medianMs"]),
            fmt_ms(c["p90Ms"]),
            fmt_num(c["top1"], 3),
            fmt_num(c["restrictedTop1"], 3),
            fmt_num(c["top5"], 3),
            fmt_mb(c["modelSizeMb"]),
            warnings_text,
        ])
        + " |"
    )

report_lines.append("")
report_lines.append("## Score components")
report_lines.append("")
report_lines.append("| Candidate | Quality | Latency | Size | Interpretability | Thermal | Total |")
report_lines.append("|---|---:|---:|---:|---:|---:|---:|")
for c in ranked:
    s = c["scores"]
    report_lines.append(
        "| "
        + " | ".join([
            candidate_name(c),
            fmt_num(s["quality"], 3),
            fmt_num(s["latency"], 3),
            fmt_num(s["size"], 3),
            fmt_num(s["interpretability"], 3),
            fmt_num(s["thermal"], 3),
            fmt_num(s["total"], 3),
        ])
        + " |"
    )

report_lines.append("")
report_lines.append("## Notes")
report_lines.append("")
report_lines.append("- Ranking is scenario-dependent. The same benchmark results may produce a different recommendation for another usage scenario or priority profile.")
report_lines.append("- INT8-labeled palettized models are treated as weight-compressed configurations, not as proven W8A8 integer inference.")
report_lines.append("- For stream/video scenarios, p90/p95 and sustained thermal behavior are more important than median latency.")
report_lines.append("- For old-device/no-ANE scenarios, CPU_ONLY results or measurements from the target device class should be used.")

report_md = "\n".join(report_lines)

report_path = output_dir / "ranking_report.md"
report_path.write_text(report_md, encoding="utf-8")


def serializable_candidate(c, rank):
    return {
        "rank": rank,
        "modelId": c["modelId"],
        "name": candidate_name(c),
        "family": c["family"],
        "format": c["format"],
        "optimizationType": c["optimizationType"],
        "computeUnits": c["computeUnits"],
        "eligible": c["eligible"],
        "failures": c["failures"],
        "warnings": c["warnings"],
        "metrics": {
            "medianMs": c["medianMs"],
            "p90Ms": c["p90Ms"],
            "p95Ms": c["p95Ms"],
            "inferenceMedianMs": c["inferenceMedianMs"],
            "preprocessingMedianMs": c["preprocessingMedianMs"],
            "top1": c["top1"],
            "top5": c["top5"],
            "restrictedTop1": c["restrictedTop1"],
            "top1Agree": c["top1Agree"],
            "top5Agree": c["top5Agree"],
            "restrictedTop1Agree": c["restrictedTop1Agree"],
            "modelSizeMb": c["modelSizeMb"],
            "thermalState": c["thermalState"],
            "residentMemoryMb": c["residentMemoryMb"],
        },
        "scores": c["scores"],
    }


ranking_json = {
    "generatedAt": generated_at,
    "scenario": {
        "usageScenario": usage_scenario,
        "priorityProfile": profile,
        "targetDeviceClass": target_device_class,
        "requiredComputeUnits": required_compute,
    },
    "globalWarnings": global_warnings,
    "recommendation": None if recommended is None else {
        "modelId": recommended["modelId"],
        "name": candidate_name(recommended),
        "reasons": recommendation_reasons(recommended, ranked),
    },
    "ranking": [
        serializable_candidate(c, idx if c["eligible"] else None)
        for idx, c in enumerate([c for c in ranked if c["eligible"]], start=1)
    ] + [
        serializable_candidate(c, None)
        for c in ranked
        if not c["eligible"]
    ],
}

ranking_path = output_dir / "ranking.json"
ranking_path.write_text(json.dumps(ranking_json, ensure_ascii=False, indent=2), encoding="utf-8")

print(f"Generated: {report_path}")
print(f"Generated: {ranking_path}")

if recommended:
    print(f"Recommended: {candidate_name(recommended)}")
else:
    print("Recommended: none")
PY
