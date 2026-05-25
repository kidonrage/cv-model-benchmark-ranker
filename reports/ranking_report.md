# Ranking report

Generated at: `2026-05-25T16:19:38.057643+00:00`

## Scenario

- Usage scenario: `single_image_analysis`
- Priority profile: `balanced`
- Primary dataset: `imagenette2_160_subset_500`
- Validation datasets: `imagenet_hard_50_subset_2500`
- Hard datasets: `imagenet_hard_50_subset_2500`

## Recommendation

Recommended: **EfficientNetB0_FP16 [ALL]**

Primary dataset:
- top1: 0.750
- restrictedTop1: 0.984
- median latency: 14.35 ms

Validation datasets:
- imagenet_hard_50_subset_2500: top1=0.825, top1 drop=-7.52 pp, status=passed

Hard datasets:
- imagenet_hard_50_subset_2500: top1=0.825, top1 drop=-7.52 pp, status=passed

Decision:
- best primary dataset quality-latency trade-off under current scenario
- primary top-1: 0.750
- primary restricted top-1: 0.984
- primary median latency: 14.35 ms
- recommendation is not based on latency alone: FP16 also keeps high quality, moderate size, interpretable optimization type, and no validation/hard warning
- no critical degradation on hard datasets

## Ranking

| Rank | Candidate | Eligible | Primary top-1 | Primary restricted top-1 | Primary median | Validation/hard warnings | Total score |
|---:|---|---:|---:|---:|---:|---|---:|
| 1 | EfficientNetB0_FP16 [ALL] | yes | 0.750 | 0.984 | 14.35 ms |  | 0.908 |
| 2 | EfficientNetB0_INT8 [ALL] | yes | 0.748 | 0.984 | 15.17 ms | less interpretable optimization type compared with FP16/FP32 | 0.839 |
| 3 | EfficientNetB0_FP32 [ALL] | yes | 0.750 | 0.984 | 24.11 ms |  | 0.475 |
| — | MobileNetV2_FP16 [ALL] | primary top-1 accuracy 0.676 < minimum 0.700 | 0.676 | 0.974 | 16.12 ms |  | -9.155 |
| — | MobileNetV2_INT8 [ALL] | primary top-1 accuracy 0.676 < minimum 0.700 | 0.676 | 0.974 | 17.06 ms | less interpretable optimization type compared with FP16/FP32 | -9.236 |
| — | MobileNetV2_FP32 [ALL] | primary top-1 accuracy 0.676 < minimum 0.700 | 0.676 | 0.974 | 21.10 ms |  | -9.395 |

## Notes

- Ranking is built only from the primary dataset. Validation and hard datasets contribute warnings or penalties, but are never averaged into the primary score.
- Positive drop in percentage points means degradation versus the primary dataset.
- `latency_first` keeps validation/hard checks mostly as warnings unless degradation becomes severe.
- `EfficientNetB0_FP32 [ALL]` is eligible: its primary median latency is 24.11 ms and stays below the 25 ms latency budget. It ranks third because FP16 and INT8 have better latency/size trade-offs and higher total score.
- The full benchmark run changed device thermal state from `nominal` to `serious`. This weakens exact latency ordering when candidates differ by less than 1 ms, so the FP16-vs-INT8 latency gap should be confirmed by a cooled rerun with randomized experiment order.
