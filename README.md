# CV Model Benchmark Ranker

Набор инструментов для сценарно-ориентированного выбора on-device Core ML модели компьютерного зрения для iOS-приложения.

Проект позволяет:
- добавить несколько candidate-конфигураций моделей в формате `.mlpackage`;
- прогнать benchmark на физическом iOS-устройстве;
- экспортировать результаты benchmark в JSON;
- автоматически отранжировать модели с учётом сценария использования: `single_image_analysis`, `camera_stream`, `old_device_or_no_ane`, `disk_size_sensitive` и др.;
- получить итоговый `ranking_report.md` с рекомендованной конфигурацией модели и объяснением выбора.

Основная идея: модель выбирается не только по isolated inference latency, а по совокупности факторов: `fullPipeline latency`, `p90/p95`, accuracy, restricted accuracy, model size, compute units, тип оптимизации и ограничения пользовательского сценария.

---

## Структура проекта

```text
.
├── CVBenchmarkApp/
│   └── ...                       # iOS benchmark-приложение
├── app_logs/
│   └── benchmark_results.json    # JSON-лог после запуска benchmark на iPhone
├── reports/
│   ├── ranking_report.md         # итоговый markdown-отчёт
│   └── ranking.json              # машинно-читаемый результат ранжирования
├── scripts/
│   └── analyze_results.sh        # скрипт анализа benchmark-логов
└── scenario_config.json          # описание сценария и ограничений ранжирования
```

---

## Общий workflow

```text
1. Добавить candidate-модели в iOS benchmark-проект.
2. Запустить benchmark-приложение на физическом iPhone.
3. Экспортировать benchmark_results.json.
4. Описать сценарий использования в scenario_config.json.
5. Запустить analyze_results.sh.
6. Получить ranking_report.md и ranking.json.
```

---

## Шаг 1. Добавить candidate-модели в benchmark-проект

Добавьте `.mlpackage`-файлы в iOS benchmark-проект.

Пример candidate-конфигураций:

```text
MobileNetV2_FP32.mlpackage
MobileNetV2_FP16.mlpackage
MobileNetV2_INT8.mlpackage
EfficientNetB0_FP32.mlpackage
EfficientNetB0_FP16.mlpackage
EfficientNetB0_INT8.mlpackage
```

Важно: candidate-конфигурация — это не только архитектура модели, но и конкретный формат/тип оптимизации. Например:

```text
EfficientNetB0 FP32
EfficientNetB0 FP16
EfficientNetB0 INT8 / palettized weights
```

---

## Шаг 2. Запустить benchmark на физическом iPhone

Откройте iOS benchmark-проект в Xcode и запустите приложение на физическом устройстве.

Benchmark должен собрать по каждой candidate-конфигурации:

- `fullPipelineMedianMs`;
- `p90Ms`;
- `p95Ms`, если доступно;
- `inferenceMedianMs`;
- `preprocessingMedianMs`;
- `top1`;
- `top5`;
- `restrictedTop1`;
- `modelSizeMb`;
- `computeUnits`;
- `thermalState`;
- дополнительные agreement-метрики, если доступны.

После завершения benchmark экспортируйте результат в файл:

```text
app_logs/benchmark_results.json
```

---

## Шаг 3. Подготовить `benchmark_results.json`

Файл `benchmark_results.json` содержит результаты измерений, полученные на устройстве.

Минимальный пример:

```json
{
  "device": {
    "name": "iPhone 14",
    "model": "iPhone14,7",
    "iosVersion": "18.6",
    "computeUnits": "ALL"
  },
  "runs": [
    {
      "modelId": "MobileNetV2_FP16",
      "family": "MobileNetV2",
      "format": "FP16",
      "optimizationType": "float16",
      "computeUnits": "ALL",
      "measurementMode": "fullPipeline",
      "modelSizeMb": 24.8,
      "latency": {
        "fullPipelineMedianMs": 15.76,
        "p90Ms": 16.29,
        "p95Ms": 16.50,
        "inferenceMedianMs": 0.82,
        "preprocessingMedianMs": 11.60
      },
      "accuracy": {
        "top1": 0.668,
        "top5": 0.878,
        "restrictedTop1": 0.976
      },
      "agreement": {
        "top1": 0.980,
        "top5": 0.922,
        "restrictedTop1": 1.0
      },
      "diagnostics": {
        "thermalState": "nominal",
        "residentMemoryMb": 118.0,
        "hasSustainedBenchmark": false
      }
    }
  ]
}
```

### Поля `benchmark_results.json`

| Поле | Описание |
|---|---|
| `device.name` | Название устройства |
| `device.model` | Идентификатор модели устройства |
| `device.iosVersion` | Версия iOS |
| `device.computeUnits` | Общий режим compute units, если он один для всего прогона |
| `runs[]` | Массив результатов по candidate-конфигурациям |
| `runs[].modelId` | Уникальный идентификатор модели |
| `runs[].family` | Семейство модели, например `MobileNetV2` |
| `runs[].format` | Формат: `FP32`, `FP16`, `INT8` |
| `runs[].optimizationType` | Фактический тип оптимизации |
| `runs[].computeUnits` | `ALL`, `CPU_ONLY` и т.д. |
| `runs[].modelSizeMb` | Размер модели в МБ |
| `runs[].latency.fullPipelineMedianMs` | Median latency полного pipeline |
| `runs[].latency.p90Ms` | p90 latency |
| `runs[].latency.p95Ms` | p95 latency |
| `runs[].latency.inferenceMedianMs` | Median latency самого inference |
| `runs[].latency.preprocessingMedianMs` | Median latency preprocessing |
| `runs[].accuracy.top1` | Top-1 accuracy |
| `runs[].accuracy.top5` | Top-5 accuracy |
| `runs[].accuracy.restrictedTop1` | Restricted top-1 accuracy |
| `runs[].agreement.top1` | Совпадение top-1 с FP32 baseline |
| `runs[].agreement.top5` | Совпадение top-5 с FP32 baseline |
| `runs[].diagnostics.thermalState` | Thermal state устройства |
| `runs[].diagnostics.hasSustainedBenchmark` | Был ли выполнен длительный sustained benchmark |

---

## Шаг 4. Подготовить `scenario_config.json`

Файл `scenario_config.json` описывает сценарий использования модели и правила ранжирования.

Пример для balanced-сценария анализа одиночного изображения:

```json
{
  "usageScenario": "single_image_analysis",
  "priorityProfile": "balanced",
  "targetDeviceClass": "modern_iphone_with_ane",
  "latencyBudgetMs": 25,
  "p90LatencyBudgetMs": 35,
  "minTop1Accuracy": 0.65,
  "minRestrictedTop1Accuracy": 0.95,
  "maxModelSizeMb": 100,
  "preferInterpretableOptimization": true,
  "allowPalettizedWeights": true
}
```

### Поля `scenario_config.json`

| Поле | Обязательное | Описание |
|---|---:|---|
| `usageScenario` | Да | Сценарий использования модели |
| `priorityProfile` | Да | Профиль приоритета для ранжирования |
| `targetDeviceClass` | Нет | Целевой класс устройств |
| `latencyBudgetMs` | Нет | Максимальная допустимая median latency |
| `p90LatencyBudgetMs` | Нет | Максимальная допустимая p90 latency |
| `p95LatencyBudgetMs` | Нет | Максимальная допустимая p95 latency |
| `minTop1Accuracy` | Нет | Минимальная top-1 accuracy |
| `minTop5Accuracy` | Нет | Минимальная top-5 accuracy |
| `minRestrictedTop1Accuracy` | Нет | Минимальная restricted top-1 accuracy |
| `maxModelSizeMb` | Нет | Максимальный размер модели |
| `preferInterpretableOptimization` | Нет | При близких результатах предпочитать более интерпретируемые оптимизации |
| `allowPalettizedWeights` | Нет | Разрешить модели с palettized weights |
| `requiredComputeUnits` | Нет | Принудительно использовать только результаты с указанным compute mode |

---

## Поддерживаемые `usageScenario`

### `single_image_analysis`

Для сценариев, где приложение анализирует одно изображение за раз.

Пример: классификация фотографии, анализ изображения из галереи, разовый запуск модели.

Основные метрики:

- `fullPipelineMedianMs`;
- `p90Ms`;
- `top1`;
- `top5`;
- `restrictedTop1`;
- `modelSizeMb`.

---

### `camera_stream`

Для сценариев частого запуска модели на кадрах камеры.

Пример: live camera, AR, near real-time обработка.

Основные метрики:

- `p90Ms`;
- `p95Ms`;
- sustained latency;
- thermal state;
- battery/resource diagnostics;
- preprocessing latency.

Если в `benchmark_results.json` нет sustained benchmark, скрипт добавит warning.

---

### `old_device_or_no_ane`

Для сценариев поддержки старых устройств или устройств без эффективного Neural Engine path.

Основные метрики:

- `CPU_ONLY` latency;
- memory usage;
- model size;
- accuracy.

Если в логе нет `CPU_ONLY` результатов, скрипт добавит warning и выполнит ранжирование по доступным данным.

---

### `disk_size_sensitive`

Для сценариев, где критичен размер приложения или модели.

Основные метрики:

- `modelSizeMb`;
- минимальные пороги accuracy;
- latency budget;
- тип оптимизации.

В этом сценарии `INT8 / palettized` модели могут получить более высокий ranking, если проходят latency/accuracy thresholds.

---

## Поддерживаемые `priorityProfile`

### `balanced`

Компромисс между качеством, задержкой и интерпретируемостью.

Используется по умолчанию для обычного product-сценария.

---

### `latency_first`

Приоритет — минимальная задержка.

Логика:

```text
1. Отфильтровать модели, не проходящие минимальную accuracy.
2. Отсортировать оставшиеся по latency.
3. При близкой latency учитывать model size и интерпретируемость.
```

---

### `accuracy_first`

Приоритет — качество модели.

Логика:

```text
1. Отфильтровать модели, не проходящие latency budget.
2. Отсортировать оставшиеся по top-1/top-5/restricted top-1.
3. При близкой accuracy учитывать latency.
```

---

### `disk_size_first`

Приоритет — минимальный размер модели.

Логика:

```text
1. Отфильтровать модели, не проходящие accuracy и latency thresholds.
2. Отсортировать оставшиеся по model size.
3. Добавить warning для palettized/INT8-like моделей, если они не являются доказанным W8A8 INT8 inference.
```

---

### `conservative_deployment`

Приоритет — предсказуемость и простота интерпретации оптимизации.

Подходит для случаев, когда нежелательно выбирать плохо интерпретируемые low-precision варианты.

---

### `energy_first`

Приоритет — потенциальная энергоэффективность и устойчивость при длительной работе.

Важно: для корректного применения этого профиля желательно иметь sustained benchmark и thermal/battery diagnostics.

---

## Шаг 5. Запустить анализ результатов

Команда:

```bash
./scripts/analyze_results.sh \
  --results ./app_logs/benchmark_results.json \
  --scenario ./scenario_config.json \
  --output-dir ./reports
```

### Параметры команды

| Параметр | Обязательный | Описание |
|---|---:|---|
| `--results` | Да | Путь к JSON-файлу с результатами benchmark |
| `--scenario` | Да | Путь к JSON-файлу со сценарием и ограничениями |
| `--output-dir` | Нет | Папка для сохранения отчётов. По умолчанию `reports` |
| `--help` | Нет | Показать справку |

---

## Шаг 6. Посмотреть результат

После выполнения команды будут сгенерированы файлы:

```text
reports/ranking_report.md
reports/ranking.json
```

### `ranking_report.md`

Markdown-отчёт для человека.

Содержит:

- описание сценария;
- информацию об устройстве;
- предупреждения;
- рекомендованную candidate-конфигурацию;
- объяснение выбора;
- таблицу ранжирования;
- компоненты итогового score.

Пример рекомендации:

```markdown
Recommended configuration: **EfficientNetB0 FP16 [ALL]**

Reasons:

- passes all required scenario constraints;
- median fullPipeline latency: 16.87 ms;
- top-1 accuracy: 0.748;
- restricted top-1 accuracy: 0.984;
- top-5 accuracy: 0.936;
- is 1.11 ms slower than the fastest eligible configuration, but provides a better overall scenario trade-off.
```

### `ranking.json`

Машинно-читаемый результат.

Может использоваться для последующей визуализации, CI или интеграции с другими инструментами.

---

## Примеры сценариев

### Balanced single-image analysis

```json
{
  "usageScenario": "single_image_analysis",
  "priorityProfile": "balanced",
  "targetDeviceClass": "modern_iphone_with_ane",
  "latencyBudgetMs": 25,
  "p90LatencyBudgetMs": 35,
  "minTop1Accuracy": 0.65,
  "minRestrictedTop1Accuracy": 0.95,
  "maxModelSizeMb": 100,
  "preferInterpretableOptimization": true,
  "allowPalettizedWeights": true
}
```

---

### Latency-first

```json
{
  "usageScenario": "single_image_analysis",
  "priorityProfile": "latency_first",
  "latencyBudgetMs": 25,
  "p90LatencyBudgetMs": 35,
  "minTop1Accuracy": 0.65,
  "minRestrictedTop1Accuracy": 0.95,
  "maxModelSizeMb": 100,
  "preferInterpretableOptimization": true,
  "allowPalettizedWeights": true
}
```

---

### Disk-size-first

```json
{
  "usageScenario": "disk_size_sensitive",
  "priorityProfile": "disk_size_first",
  "latencyBudgetMs": 30,
  "p90LatencyBudgetMs": 40,
  "minRestrictedTop1Accuracy": 0.95,
  "maxModelSizeMb": 20,
  "preferInterpretableOptimization": false,
  "allowPalettizedWeights": true
}
```

---

### Camera stream

```json
{
  "usageScenario": "camera_stream",
  "priorityProfile": "latency_first",
  "targetFps": 30,
  "frameBudgetMs": 33.3,
  "latencyBudgetMs": 25,
  "p90LatencyBudgetMs": 25,
  "p95LatencyBudgetMs": 30,
  "minRestrictedTop1Accuracy": 0.95,
  "maxModelSizeMb": 100,
  "preferInterpretableOptimization": true,
  "allowPalettizedWeights": true
}
```

---

### Old device / no ANE

```json
{
  "usageScenario": "old_device_or_no_ane",
  "priorityProfile": "latency_first",
  "targetDeviceClass": "old_iphone_or_no_ane",
  "requiredComputeUnits": "CPU_ONLY",
  "latencyBudgetMs": 40,
  "p90LatencyBudgetMs": 60,
  "minRestrictedTop1Accuracy": 0.95,
  "maxModelSizeMb": 100,
  "preferInterpretableOptimization": true,
  "allowPalettizedWeights": true
}
```

---

## Интерпретация INT8 / palettized моделей

Если модель обозначена как `INT8`, но фактически использует `8-bit palettized weights`, она не считается доказанным полноценным W8A8 INT8 inference.

Скрипт добавляет warning для таких моделей:

```text
INT8-labeled model is interpreted as palettized/weight-compressed, not proven W8A8 integer inference
```

Такие модели могут быть полезны в `disk_size_first` сценариях, но в `balanced` или `conservative_deployment` сценариях FP16 может быть предпочтительнее из-за более простой интерпретации.

---

## Ограничения

Текущий набор инструментов является MVP и имеет ограничения:

- не выполняет benchmark самостоятельно, а анализирует уже экспортированный JSON-лог;
- не определяет автоматически корректный preprocessing для произвольной модели;
- не доказывает наличие полноценного W8A8 INT8 inference;
- для stream-сценариев использует p90/p95 как proxy, если нет sustained benchmark;
- для old-device/no-ANE сценариев требует `CPU_ONLY` результатов или отдельного запуска на целевом устройстве;
- качество ранжирования зависит от полноты и корректности `benchmark_results.json`.

---

## Требования

Для анализа результатов требуется:

```text
bash
python3
```

На macOS обычно достаточно системного `bash` и установленного `python3`.

Проверка:

```bash
python3 --version
```

---

## Быстрый старт

```bash
# 1. Подготовить папки
mkdir -p scripts app_logs reports

# 2. Положить benchmark log
cp benchmark_results.json ./app_logs/benchmark_results.json

# 3. Подготовить scenario_config.json
cat > scenario_config.json <<'JSON'
{
  "usageScenario": "single_image_analysis",
  "priorityProfile": "balanced",
  "targetDeviceClass": "modern_iphone_with_ane",
  "latencyBudgetMs": 25,
  "p90LatencyBudgetMs": 35,
  "minTop1Accuracy": 0.65,
  "minRestrictedTop1Accuracy": 0.95,
  "maxModelSizeMb": 100,
  "preferInterpretableOptimization": true,
  "allowPalettizedWeights": true
}
JSON

# 4. Запустить анализ
./scripts/analyze_results.sh \
  --results ./app_logs/benchmark_results.json \
  --scenario ./scenario_config.json \
  --output-dir ./reports

# 5. Открыть отчёт
open ./reports/ranking_report.md
```

---

## Итог

Этот набор инструментов реализует сценарно-ориентированную методику выбора Core ML модели для iOS-приложения.

На вход подаются:

```text
benchmark_results.json
scenario_config.json
```

На выходе формируются:

```text
ranking_report.md
ranking.json
```

Результат — рекомендованная candidate-конфигурация модели для заданного сценария использования и профиля приоритета.
