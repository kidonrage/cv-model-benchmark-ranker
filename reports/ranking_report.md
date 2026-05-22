# Ranking report

Generated at: `2026-05-22T14:19:57.756920+00:00`

## Scenario

- Usage scenario: `single_image_analysis`
- Priority profile: `disk_size_first`
- Target device class: `not specified`
- Median latency budget: `25.00 ms`
- p90 latency budget: `35.00 ms`
- Minimum top-1 accuracy: `0.650`
- Minimum restricted top-1 accuracy: `0.950`
- Maximum model size: `100.0 MB`

## Device

- name: `iPhone 14`
- model: `iPhone14,7`
- iosVersion: `18.6`
- computeUnits: `ALL`

## Recommendation

Recommended configuration: **MobileNetV2 INT8 [ALL]**

Reasons:

- passes all required scenario constraints
- median fullPipeline latency: 15.85 ms
- p90 latency: 16.25 ms
- top-1 accuracy: 0.672
- restricted top-1 accuracy: 0.976
- top-5 accuracy: 0.880
- model size: 8.9 MB
- is 0.09 ms slower than the fastest eligible configuration, but provides a better overall scenario trade-off
- has the smallest model size among eligible configurations
- warning: selected configuration appears to use palettized/weight-compressed representation
- warning: INT8-labeled model is interpreted as palettized/weight-compressed, not proven W8A8 integer inference
- warning: low top-5 agreement with FP32 baseline: 0.786
- warning: less interpretable optimization type compared with FP16/FP32

## Ranking

| Rank | Candidate | Eligible | Score | Median | p90 | Top-1 | Restricted top-1 | Top-5 | Size | Warnings |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | MobileNetV2 INT8 [ALL] | yes | 0.954 | 15.85 ms | 16.25 ms | 0.672 | 0.976 | 0.880 | 8.9 MB | INT8-labeled model is interpreted as palettized/weight-compressed, not proven W8A8 integer inference; low top-5 agreement with FP32 baseline: 0.786; less interpretable optimization type compared with FP16/FP32 |
| 2 | EfficientNetB0 INT8 [ALL] | yes | 0.894 | 16.95 ms | 17.68 ms | 0.750 | 0.984 | 0.930 | 14.1 MB | INT8-labeled model is interpreted as palettized/weight-compressed, not proven W8A8 integer inference; low top-5 agreement with FP32 baseline: 0.660; less interpretable optimization type compared with FP16/FP32 |
| 3 | MobileNetV2 FP16 [ALL] | yes | 0.839 | 15.76 ms | 16.29 ms | 0.668 | 0.976 | 0.878 | 24.8 MB |  |
| 4 | EfficientNetB0 FP16 [ALL] | yes | 0.694 | 16.87 ms | 17.53 ms | 0.748 | 0.984 | 0.936 | 40.2 MB | low top-5 agreement with FP32 baseline: 0.716 |
| 5 | MobileNetV2 FP32 [ALL] | yes | 0.540 | 20.55 ms | 20.83 ms | 0.674 | 0.976 | 0.878 | 48.2 MB |  |
| 6 | EfficientNetB0 FP32 [ALL] | yes | 0.173 | 24.63 ms | 28.73 ms | 0.750 | 0.984 | 0.932 | 80.5 MB |  |

## Score components

| Candidate | Quality | Latency | Size | Interpretability | Thermal | Total |
|---|---:|---:|---:|---:|---:|---:|
| MobileNetV2 INT8 [ALL] | 0.820 | 0.993 | 1.000 | 0.650 | 1.000 | 0.954 |
| EfficientNetB0 INT8 [ALL] | 0.868 | 0.873 | 0.927 | 0.650 | 1.000 | 0.894 |
| MobileNetV2 FP16 [ALL] | 0.818 | 0.999 | 0.778 | 1.000 | 1.000 | 0.839 |
| EfficientNetB0 FP16 [ALL] | 0.868 | 0.883 | 0.563 | 1.000 | 1.000 | 0.694 |
| MobileNetV2 FP32 [ALL] | 0.821 | 0.521 | 0.451 | 0.850 | 1.000 | 0.540 |
| EfficientNetB0 FP32 [ALL] | 0.868 | 0.000 | 0.000 | 0.850 | 1.000 | 0.173 |

## Notes

- Ranking is scenario-dependent. The same benchmark results may produce a different recommendation for another usage scenario or priority profile.
- INT8-labeled palettized models are treated as weight-compressed configurations, not as proven W8A8 integer inference.
- For stream/video scenarios, p90/p95 and sustained thermal behavior are more important than median latency.
- For old-device/no-ANE scenarios, CPU_ONLY results or measurements from the target device class should be used.