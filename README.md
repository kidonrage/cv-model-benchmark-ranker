# CV Model Benchmark Ranker

Набор инструментов для сценарно-ориентированного выбора on-device Core ML модели для iOS-приложения.

Проект позволяет:

- добавить candidate-модели в формате `.mlpackage`, `.mlmodel` или `.mlmodelc`;
- автоматически скопировать модели в iOS benchmark-проект;
- сгенерировать `models_manifest.json` и `benchmark_plan.json`;
- прогнать benchmark на физическом iPhone;
- экспортировать `benchmark_results.json`;
- отранжировать модели с учётом сценария использования и профиля приоритета;
- получить `ranking_report.md` с рекомендованной конфигурацией и объяснением выбора.

Модель выбирается не по одной latency-метрике, а по совокупности факторов: `fullPipeline latency`, `p90/p95`, accuracy, restricted accuracy, model size, compute units, тип оптимизации и сценарий использования.

---

## 1. Общий workflow

```text
1. Положить candidate-модели в input_models/
2. Запустить generate_benchmark_configs.sh
3. Скрипт скопирует модели в iOS-проект
4. Скрипт сгенерирует models_manifest.json и benchmark_plan.json
5. Открыть CVTestsSUI в Xcode
6. Запустить benchmark app на физическом iPhone
7. Экспортировать benchmark_results.json
8. Запустить analyze_results.sh
9. Получить ranking_report.md и ranking.json
```

---

## 2. Структура проекта

```text
.
├── README.md
├── scenario_config.json
│
├── input_models/
│   ├── MobileNetV2_FP16.mlpackage
│   └── EfficientNetB0_FP16.mlpackage
│
├── scripts/
│   ├── generate_benchmark_configs.sh
│   └── analyze_results.sh
│
├── CVTestsSUI/
│   ├── CVTestsSUI.xcodeproj
│   └── CVTestsSUI/
│       ├── Resources/
│       │   ├── ModelsRaw/
│       │   ├── Configs/
│       │   │   ├── model_profiles.json
│       │   │   ├── models_manifest.json
│       │   │   └── benchmark_plan.json
│       │   ├── Labels/
│       │   └── Datasets/
│       └── ...
│
├── app_logs/
│   └── benchmark_results.json
│
└── reports/
    ├── ranking_report.md
    └── ranking.json
```

---

## 3. Подготовка моделей

Положите `.mlpackage`, `.mlmodel` или `.mlmodelc` файлы в папку:

```text
input_models/
```

Пример:

```text
input_models/
├── MobileNetV2_FP32.mlpackage
├── MobileNetV2_FP16.mlpackage
├── MobileNetV2_INT8.mlpackage
├── EfficientNetB0_FP32.mlpackage
├── EfficientNetB0_FP16.mlpackage
└── EfficientNetB0_INT8.mlpackage
```

Candidate-конфигурация — это конкретная пара «модель + формат/оптимизация», например:

```text
MobileNetV2 FP16
EfficientNetB0 FP16
EfficientNetB0 INT8 / palettized weights
```

---

## 4. Настройка сценария

Файл:

```text
scenario_config.json
```

описывает сценарий использования модели и правила ранжирования.

Если файла нет, `generate_benchmark_configs.sh` создаст дефолтный `scenario_config.json`.

Пример:

```json
{
  "usageScenario": "single_image_analysis",
  "priorityProfile": "balanced",
  "targetDeviceClass": "modern_iphone_with_ane",

  "datasetId": "imagenette2-160-subset-500",

  "latencyBudgetMs": 25,
  "p90LatencyBudgetMs": 35,
  "minTop1Accuracy": 0.65,
  "minRestrictedTop1Accuracy": 0.95,
  "maxModelSizeMb": 100,

  "preferInterpretableOptimization": true,
  "allowPalettizedWeights": true,

  "includeCpuOnlyReference": false,

  "enableAccuracyBenchmark": true,
  "enableSegmentedBenchmark": true,
  "enableSustainedBenchmark": false,

  "warmupRuns": 10,
  "measuredRuns": 50,
  "accuracyWarmupImages": 10,
  "sustainedWarmupRuns": 100,
  "sustainedMeasuredRuns": 10000
}
```

### Поля `scenario_config.json`

| Поле                              | Описание                                                                |
| --------------------------------- | ----------------------------------------------------------------------- |
| `usageScenario`                   | Сценарий использования модели                                           |
| `priorityProfile`                 | Профиль приоритета для ранжирования                                     |
| `targetDeviceClass`               | Целевой класс устройств                                                 |
| `datasetId`                       | Dataset для benchmark                                                   |
| `latencyBudgetMs`                 | Максимальная median latency                                             |
| `p90LatencyBudgetMs`              | Максимальная p90 latency                                                |
| `p95LatencyBudgetMs`              | Максимальная p95 latency                                                |
| `minTop1Accuracy`                 | Минимальная top-1 accuracy                                              |
| `minTop5Accuracy`                 | Минимальная top-5 accuracy                                              |
| `minRestrictedTop1Accuracy`       | Минимальная restricted top-1 accuracy                                   |
| `maxModelSizeMb`                  | Максимальный размер модели                                              |
| `preferInterpretableOptimization` | При близких результатах предпочитать более интерпретируемые оптимизации |
| `allowPalettizedWeights`          | Разрешить модели с palettized weights                                   |
| `requiredComputeUnits`            | Использовать только результаты с указанным compute mode                 |
| `includeCpuOnlyReference`         | Добавить CPU-only benchmark как reference                               |
| `enableAccuracyBenchmark`         | Включить accuracy benchmark                                             |
| `enableSegmentedBenchmark`        | Включить segmented benchmark                                            |
| `enableSustainedBenchmark`        | Включить длительный sustained benchmark                                 |
| `warmupRuns`                      | Warmup-запуски для performance benchmark                                |
| `measuredRuns`                    | Measured-запуски для performance benchmark                              |
| `accuracyWarmupImages`            | Warmup-изображения для accuracy benchmark                               |
| `sustainedWarmupRuns`             | Warmup-запуски для sustained benchmark                                  |
| `sustainedMeasuredRuns`           | Measured-запуски для sustained benchmark                                |

---

## 5. Настройка профилей моделей

Файл:

```text
CVTestsSUI/CVTestsSUI/Resources/Configs/model_profiles.json
```

описывает известные семейства моделей, их input/output contract и preprocessing profile.

Если файла нет, `generate_benchmark_configs.sh` создаст дефолтный `model_profiles.json` для `MobileNetV2` и `EfficientNetB0`.

Пример:

```json
{
  "families": [
    {
      "family": "MobileNetV2",
      "match": ["mobilenetv2", "mobile_net_v2", "mobile-net-v2"],
      "preprocessingProfile": "mobilenetv2_imagenet",
      "input": {
        "type": "multiArray",
        "shape": [1, 3, 224, 224],
        "channelOrder": "CHW"
      },
      "output": {
        "name": "var_824",
        "labelMapping": "imagenet_labels.json"
      }
    },
    {
      "family": "EfficientNetB0",
      "match": ["efficientnetb0", "efficientnet_b0", "efficient-net-b0"],
      "preprocessingProfile": "efficientnetb0_imagenet",
      "input": {
        "type": "multiArray",
        "shape": [1, 3, 224, 224],
        "channelOrder": "CHW"
      },
      "output": {
        "name": "var_1150",
        "labelMapping": "imagenet_labels.json"
      }
    }
  ],
  "preprocessingProfiles": {
    "mobilenetv2_imagenet": {
      "resizeShortSide": 232,
      "cropSize": 224,
      "interpolation": "bilinear",
      "colorSpace": "RGB",
      "channelOrder": "CHW",
      "mean": [0.485, 0.456, 0.406],
      "std": [0.229, 0.224, 0.225]
    },
    "efficientnetb0_imagenet": {
      "resizeShortSide": 256,
      "cropSize": 224,
      "interpolation": "bicubic",
      "colorSpace": "RGB",
      "channelOrder": "CHW",
      "mean": [0.485, 0.456, 0.406],
      "std": [0.229, 0.224, 0.225]
    }
  }
}
```

Preprocessing нельзя безопасно угадать только по `.mlpackage`, поэтому для новой архитектуры нужно один раз добавить family profile.

Если модель неизвестна, скрипт остановится с ошибкой:

```text
Unknown model family for 'ResNet50_FP16'.
Add a family profile to model_profiles.json or run with --allow-unknown.
```

---

## 6. Генерация benchmark-конфигов

Основной скрипт:

```text
scripts/generate_benchmark_configs.sh
```

Он:

```text
1. Берёт модели из input_models/
2. Копирует их в CVTestsSUI/CVTestsSUI/Resources/ModelsRaw/
3. Создаёт model_profiles.json, если его нет
4. Создаёт scenario_config.json, если его нет
5. Генерирует models_manifest.json
6. Генерирует benchmark_plan.json
```

### Запуск без параметров

```bash
./scripts/generate_benchmark_configs.sh
```

Чтобы после генерации сразу открыть Xcode-проект:

```bash
./scripts/generate_benchmark_configs.sh --open
```

Дефолтные пути:

| Сущность           | Путь                                                            |
| ------------------ | --------------------------------------------------------------- |
| input models       | `./input_models`                                                |
| iOS project        | `./CVTestsSUI`                                                  |
| project models dir | `./CVTestsSUI/CVTestsSUI/Resources/ModelsRaw`                   |
| configs output dir | `./CVTestsSUI/CVTestsSUI/Resources/Configs`                     |
| profiles           | `./CVTestsSUI/CVTestsSUI/Resources/Configs/model_profiles.json` |
| scenario           | `./scenario_config.json`                                        |

### Запуск с параметрами

```bash
./scripts/generate_benchmark_configs.sh \
  --project-name CVTestsSUI \
  --input-models ./input_models \
  --project-models-dir ./CVTestsSUI/CVTestsSUI/Resources/ModelsRaw \
  --profiles ./CVTestsSUI/CVTestsSUI/Resources/Configs/model_profiles.json \
  --scenario ./scenario_config.json \
  --output-dir ./CVTestsSUI/CVTestsSUI/Resources/Configs
```

### Параметры

| Параметр               | Значение по умолчанию                                                   | Описание                                  |
| ---------------------- | ----------------------------------------------------------------------- | ----------------------------------------- |
| `--project-name`       | `CVTestsSUI`                                                            | Имя iOS/Xcode проекта                     |
| `--project-root`       | `./<project-name>`                                                      | Корневая папка проекта                    |
| `--input-models`       | `./input_models`                                                        | Папка с исходными моделями                |
| `--project-models-dir` | `./<project-name>/<project-name>/Resources/ModelsRaw`                   | Папка, куда копируются модели             |
| `--profiles`           | `./<project-name>/<project-name>/Resources/Configs/model_profiles.json` | Путь к model profiles                     |
| `--scenario`           | `./scenario_config.json`                                                | Путь к scenario config                    |
| `--output-dir`         | `./<project-name>/<project-name>/Resources/Configs`                     | Папка для генерации конфигов              |
| `--allow-unknown`      | `false`                                                                 | Не падать на неизвестных моделях          |
| `--no-clean-models`    | `false`                                                                 | Не очищать `ModelsRaw` перед копированием |
| `--no-clean-datasets`  | `false`                                                                 | Не очищать `Datasets` перед копированием  |
| `--open`               | `false`                                                                 | Открыть `./<project-name>/<project-name>.xcodeproj` после генерации |
| `--help`               | —                                                                       | Показать справку                          |

---

## 7. Сгенерированные файлы

### `models_manifest.json`

Путь:

```text
CVTestsSUI/CVTestsSUI/Resources/Configs/models_manifest.json
```

Описывает модели, которые есть в benchmark:

```json
{
  "generatedAt": "2026-05-23T12:00:00Z",
  "projectName": "CVTestsSUI",
  "modelsDir": "CVTestsSUI/CVTestsSUI/Resources/ModelsRaw",
  "models": [
    {
      "id": "MobileNetV2_FP16",
      "sourceFile": "MobileNetV2_FP16.mlpackage",
      "compiledResourceName": "MobileNetV2_FP16",
      "compiledExtension": "mlmodelc",
      "family": "MobileNetV2",
      "format": "FP16",
      "optimizationType": "float16",
      "modelSizeMb": 24.8,
      "supported": true,
      "preprocessingProfile": "mobilenetv2_imagenet",
      "input": {
        "type": "multiArray",
        "shape": [1, 3, 224, 224],
        "channelOrder": "CHW"
      },
      "output": {
        "name": "var_824",
        "labelMapping": "imagenet_labels.json"
      },
      "warnings": []
    }
  ],
  "preprocessingProfiles": {}
}
```

iOS-приложение использует этот файл, чтобы понять, какие модели есть в benchmark и какой preprocessing применять.

### `benchmark_plan.json`

Путь:

```text
CVTestsSUI/CVTestsSUI/Resources/Configs/benchmark_plan.json
```

Описывает, какие эксперименты должно выполнить iOS benchmark-приложение:

```json
{
  "planId": "single_image_analysis_balanced_generated",
  "usageScenario": "single_image_analysis",
  "priorityProfile": "balanced",
  "datasetId": "imagenette2-160-subset-500",
  "computeUnits": ["ALL"],
  "experiments": [
    {
      "experimentId": "MobileNetV2_FP16__ALL__performance__fullPipeline",
      "modelId": "MobileNetV2_FP16",
      "computeUnits": "ALL",
      "benchmarkType": "performance",
      "measurementMode": "fullPipeline",
      "inputMode": "realImage",
      "datasetId": "imagenette2-160-subset-500",
      "warmupRuns": 10,
      "measuredRuns": 50
    }
  ]
}
```

В новой логике приложение не требует ручного выбора модели, режима и compute units. Оно читает `benchmark_plan.json` и выполняет весь plan.

---

## 8. Настройка Xcode для моделей

Скрипт копирует модели в:

```text
CVTestsSUI/CVTestsSUI/Resources/ModelsRaw
```

Но он **не редактирует `.xcodeproj`**.

Чтобы приложение увидело модели, нужно один раз настроить Xcode-проект: добавить Build Phase, который компилирует все модели из `Resources/ModelsRaw` в app bundle.

Пример build phase script:

```bash
MODELS_DIR="${SRCROOT}/CVTestsSUI/Resources/ModelsRaw"
OUTPUT_DIR="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

if [ -d "$MODELS_DIR" ]; then
  find "$MODELS_DIR" -maxdepth 1 \( -name "*.mlpackage" -o -name "*.mlmodel" \) -print0 | while IFS= read -r -d '' MODEL_PATH; do
    echo "Compiling Core ML model: $MODEL_PATH"
    xcrun coremlcompiler compile "$MODEL_PATH" "$OUTPUT_DIR"
  done
fi
```

После этого новые модели можно добавлять без ручного изменения `.xcodeproj`.

---

## 9. Запуск benchmark на iPhone

Откройте проект:

```text
CVTestsSUI/CVTestsSUI.xcodeproj
```

Запустите приложение на физическом iPhone.

Приложение должно:

```text
1. Прочитать models_manifest.json
2. Прочитать benchmark_plan.json
3. Выполнить все experiments из benchmark_plan.json
4. Собрать latency/accuracy/resource diagnostics
5. Экспортировать benchmark_results.json
```

Ожидаемый результат:

```text
app_logs/benchmark_results.json
```

---

## 10. Формат `benchmark_results.json`

Актуальный фрагмент результата апробации для `single_image_analysis_balanced_generated`:

```json
{
  "benchmarkInfo": {
    "benchmarkAppVersion": "1.0",
    "finishedAt": "2026-05-24T17:51:51Z",
    "planId": "single_image_analysis_balanced_generated",
    "startedAt": "2026-05-24T17:39:26Z",
    "status": "completed"
  },
  "device": {
    "name": "iPhone",
    "modelIdentifier": "iPhone14,7",
    "systemName": "iOS",
    "systemVersion": "26.4.2",
    "thermalStateAtStart": "nominal",
    "thermalStateAtEnd": "serious"
  },
  "runs": [
    {
      "experimentId": "EfficientNetB0_FP16__imagenette2_160_subset_500__ALL__accuracy__fullPipeline",
      "modelId": "EfficientNetB0_FP16",
      "family": "EfficientNetB0",
      "format": "FP16",
      "optimizationType": "float16",
      "computeUnits": "ALL",
      "measurementMode": "fullPipeline",
      "datasetId": "imagenette2_160_subset_500",
      "modelSizeMb": 10.182,
      "latency": {
        "fullPipelineMedianMs": 14.348983764648438,
        "medianMs": 14.348983764648438,
        "p90Ms": 14.496183395385742,
        "p95Ms": 14.560335874557495
      },
      "accuracy": {
        "top1": 0.75,
        "top5": 0.936,
        "restrictedTop1": 0.984,
        "totalImages": 500
      },
      "diagnostics": {
        "thermalState": "nominal",
        "residentMemoryMb": 148.5,
        "hasSustainedBenchmark": false
      }
    },
    {
      "experimentId": "EfficientNetB0_INT8__imagenette2_160_subset_500__ALL__accuracy__fullPipeline",
      "modelId": "EfficientNetB0_INT8",
      "family": "EfficientNetB0",
      "format": "INT8",
      "optimizationType": "unknown_int8_or_weight_compression",
      "computeUnits": "ALL",
      "measurementMode": "fullPipeline",
      "datasetId": "imagenette2_160_subset_500",
      "modelSizeMb": 5.245,
      "latency": {
        "fullPipelineMedianMs": 15.174031257629395,
        "medianMs": 15.174031257629395,
        "p90Ms": 15.835344791412354,
        "p95Ms": 15.972977876663208
      },
      "accuracy": {
        "top1": 0.748,
        "top5": 0.934,
        "restrictedTop1": 0.984,
        "totalImages": 500
      },
      "diagnostics": {
        "thermalState": "nominal",
        "residentMemoryMb": 180.84375,
        "hasSustainedBenchmark": false
      }
    },
    {
      "experimentId": "EfficientNetB0_FP32__imagenette2_160_subset_500__ALL__accuracy__fullPipeline",
      "modelId": "EfficientNetB0_FP32",
      "family": "EfficientNetB0",
      "format": "FP32",
      "optimizationType": "float32",
      "computeUnits": "ALL",
      "measurementMode": "fullPipeline",
      "datasetId": "imagenette2_160_subset_500",
      "modelSizeMb": 20.219,
      "latency": {
        "fullPipelineMedianMs": 24.11198616027832,
        "medianMs": 24.11198616027832,
        "p90Ms": 26.362884044647217,
        "p95Ms": 26.612192392349243
      },
      "accuracy": {
        "top1": 0.75,
        "top5": 0.934,
        "restrictedTop1": 0.984,
        "totalImages": 500
      },
      "diagnostics": {
        "thermalState": "nominal",
        "residentMemoryMb": 185.8125,
        "hasSustainedBenchmark": false
      }
    }
  ]
}
```

Этот фрагмент является источником для итогового ranking. Старый формат `benchmarkAppVersion=0.1.0`, `planId=single_image_balanced_v1`, iOS `18.6` и размеры моделей около `48.2 MB` / `40.2 MB` относится к ранним демонстрационным артефактам и не используется в финальной апробации.

---

## 11. Анализ результатов

После экспорта `benchmark_results.json` запустите:

```bash
./scripts/analyze_results.sh \
  --results ./app_logs/benchmark_results.json \
  --scenario ./scenario_config.json \
  --output-dir ./reports
```

На выходе будут созданы:

```text
reports/ranking_report.md
reports/ranking.json
```

Итоговый ranking для актуального прогона:

| Rank | Candidate | Eligible | Primary top-1 | Primary restricted top-1 | Primary median | Total score |
|---:|---|---:|---:|---:|---:|---:|
| 1 | EfficientNetB0_FP16 [ALL] | yes | 0.750 | 0.984 | 14.35 ms | 0.908 |
| 2 | EfficientNetB0_INT8 [ALL] | yes | 0.748 | 0.984 | 15.17 ms | 0.839 |
| 3 | EfficientNetB0_FP32 [ALL] | yes | 0.750 | 0.984 | 24.11 ms | 0.475 |

Все три конфигурации EfficientNetB0 проходят thresholds для primary dataset. `EfficientNetB0_FP32 [ALL]` не исключается по latency budget: его median latency равна `24.11 ms`, то есть ниже лимита `25 ms`. Он занимает третье место не из-за нарушения порога, а из-за худшего сочетания latency, размера модели и итогового score по сравнению с FP16 и INT8.

При интерпретации latency нужно учитывать, что полный прогон начался при `thermalStateAtStart=nominal`, а завершился при `thermalStateAtEnd=serious`. Это не ломает вывод о пригодности `EfficientNetB0_FP16`, потому что рекомендация опирается не только на разницу latency `14.35 ms` против `15.17 ms`, но и на качество, размер, интерпретируемый тип оптимизации FP16 и отсутствие warning. Однако точный latency-ranking между FP16 и INT8 желательно подтвердить повторным прогоном с охлаждением устройства и рандомизацией порядка experiments.

### Параметры `analyze_results.sh`

| Параметр       | Описание                                             |
| -------------- | ---------------------------------------------------- |
| `--results`    | Путь к JSON-файлу с результатами benchmark           |
| `--scenario`   | Путь к JSON-файлу со сценарием и ограничениями       |
| `--output-dir` | Папка для сохранения отчётов. По умолчанию `reports` |
| `--help`       | Показать справку                                     |

---

## 12. Сценарии и профили ранжирования

### `usageScenario`

| Сценарий                | Когда использовать                          | Основные метрики                                                      |
| ----------------------- | ------------------------------------------- | --------------------------------------------------------------------- |
| `single_image_analysis` | Разовый анализ изображения                  | median/p90 fullPipeline latency, top-1, top-5, restricted top-1, size |
| `camera_stream`         | Live camera, AR, частый inference           | p90/p95, sustained latency, thermal state, preprocessing latency      |
| `old_device_or_no_ane`  | Старые iPhone или слабый Neural Engine path | CPU-only latency, memory, size, accuracy                              |
| `disk_size_sensitive`   | Критичен размер приложения/модели           | model size, accuracy thresholds, latency budget, optimization type    |

### `priorityProfile`

| Профиль                   | Приоритет                                      | Логика                                                       |
| ------------------------- | ---------------------------------------------- | ------------------------------------------------------------ |
| `balanced`                | Баланс качества, задержки и интерпретируемости | Выбирает лучший quality-latency trade-off                    |
| `latency_first`           | Минимальная задержка                           | Сначала фильтр по accuracy, затем сортировка по latency      |
| `accuracy_first`          | Максимальное качество                          | Сначала фильтр по latency, затем сортировка по accuracy      |
| `disk_size_first`         | Минимальный размер                             | Сначала фильтр по latency/accuracy, затем сортировка по size |
| `conservative_deployment` | Предсказуемость                                | Штрафует плохо интерпретируемые low-precision варианты       |
| `energy_first`            | Долгая работа без перегрева                    | Желателен sustained benchmark и thermal/battery diagnostics  |

---

## 13. Интерпретация INT8 / palettized моделей

Если модель обозначена как `INT8`, но фактически использует `8-bit palettized weights`, она не считается доказанным полноценным W8A8 INT8 inference.

Анализатор добавляет warning:

```text
INT8-labeled model is interpreted as palettized/weight-compressed, not proven W8A8 integer inference
```

Такие модели могут быть полезны в `disk_size_first` сценариях, но в `balanced` или `conservative_deployment` сценариях FP16 может быть предпочтительнее из-за более простой интерпретации.

---

## 14. Быстрый старт

```bash
# 1. Подготовить папки
mkdir -p input_models scripts reports app_logs

# 2. Положить модели в input_models/
# Например:
# input_models/MobileNetV2_FP16.mlpackage
# input_models/EfficientNetB0_FP16.mlpackage

# 3. Сгенерировать конфиги benchmark и сразу открыть Xcode-проект
./scripts/generate_benchmark_configs.sh --open

# 4. Запустить benchmark на физическом iPhone
# После завершения экспортировать benchmark_results.json в app_logs/

# 5. Проанализировать результаты
./scripts/analyze_results.sh \
  --results ./app_logs/benchmark_results.json \
  --scenario ./scenario_config.json \
  --output-dir ./reports

# 7. Открыть отчёт
open ./reports/ranking_report.md
```

---

## 15. Ограничения MVP

Текущая версия:

- не редактирует `.xcodeproj`;
- не определяет автоматически корректный preprocessing для произвольной модели;
- требует family profile для новой архитектуры;
- не доказывает наличие полноценного W8A8 INT8 inference;
- для stream-сценариев использует p90/p95 как proxy, если нет sustained benchmark;
- для old-device/no-ANE сценариев требует `CPU_ONLY` результатов или отдельного запуска на целевом устройстве;
- качество ранжирования зависит от полноты и корректности `benchmark_results.json`.

---

## 16. Требования

Для генерации конфигов и анализа результатов:

```text
bash
python3
```

Для запуска benchmark-приложения:

```text
Xcode
физическое iOS-устройство
Core ML-compatible модели
```

Проверка Python:

```bash
python3 --version
```

---

## 17. Итог

На вход подаются:

```text
input_models/
scenario_config.json
model_profiles.json
```

Генерируются:

```text
models_manifest.json
benchmark_plan.json
```

После запуска benchmark на устройстве получается:

```text
benchmark_results.json
```

После анализа формируются:

```text
ranking_report.md
ranking.json
```

Итоговый результат — рекомендованная candidate-конфигурация Core ML модели для заданного сценария использования и профиля приоритета.
