# 성향조사 v1.0 스냅샷 파이프라인

1차(round_no=1) 데이터를 CSV로 받아, 기준선(v1.0)을 고정하는 Python 분석 도구입니다.
숫자형 주관식(`question_type='text'`)은 기준선과 분리된 보조지표로 함께 산출합니다.

## 목적

- `scale_stats_snapshot_v1.xlsx`
- `student_standard_scores_v1.xlsx`
- `snapshot_metadata.json`

를 생성하고, 이후 피드백에서 동일 기준(mean, SD, alpha)을 재사용할 수 있도록 합니다.

핵심 원칙:

- `core_scale`: 기준선 통계(평균/SD/alpha/z/백분위/유형분류)에 사용
- `supplementary_numeric`: 숫자형 주관식 보조 통계로만 사용(기준선 불개입)

## 입력 파일

### 1) `raw_answers.csv`

필수 컬럼:

- `student_id`
- `item_id`
- `question_type`
- `round_no`
- `raw_score`
- `response_ms`
- `answered_at`
- `reverse_item`
- `min_score`
- `max_score`
- `weight`
- `current_level_grade`
- `current_math_percentile`

권장 컬럼:

- `response_id`
- `item_text`
- `trait`
- `round_label`

### 2) `scale_map.csv`

필수 컬럼:

- `question_id`
- `scale_name`
- `include_in_alpha` (0/1)
- `axis_tag` (`efficacy`, `growth_mindset`, `anxiety`, `emotional_stability` 등)

선택 컬럼:

- `analysis_group` (`core_scale` | `supplementary_numeric`)
  - 미입력 시 기본값: `core_scale`
  - `question_type='text'` 문항은 자동으로 `supplementary_numeric`로 보정됩니다.

`axis_tag`는 4분면 분류에 사용됩니다.  
필수축(`efficacy`, `growth_mindset`, `anxiety|emotional_stability`)이 누락되면 실행이 실패합니다.

샘플 파일: [examples/scale_map.sample.csv](examples/scale_map.sample.csv)

## 실행 방법

권장 의존성 설치:

```bash
pip install -r tools/trait_snapshot_v1/requirements.txt
```

```bash
python tools/trait_snapshot_v1/snapshot_v1.py ^
  --raw raw_answers.csv ^
  --scale-map scale_map.csv ^
  --out ./out/v1 ^
  --survey-slug trait_v1 ^
  --snapshot-cutoff-at "2026-02-13T23:59:59+09:00"
```

PowerShell 줄바꿈 예시:

```powershell
python tools/trait_snapshot_v1/snapshot_v1.py `
  --raw raw_answers.csv `
  --scale-map scale_map.csv `
  --out ./out/v1 `
  --survey-slug trait_v1 `
  --snapshot-cutoff-at "2026-02-13T23:59:59+09:00"
```

## 주요 옵션

- `--round-no` (기본: `1`)
- `--logic-version` (기본: `v1.0.0`)
- `--snapshot-version` (기본: `v1.0`)
- `--range-error-threshold` (기본: `0.01`)
- `--freeze-format` (`csv` 또는 `parquet`, 기본: `csv`)
- `--force` (기본 비활성, v1.0 덮어쓰기 허용)

## 불변성 정책

- 기본 정책: 동일 출력 경로에 v1.0 산출물이 이미 있으면 실행 실패
- 예외: `--force` 사용 시 덮어쓰기 가능

## 산출물 구성

### `scale_stats_snapshot_v1.xlsx`

- `Scale_Stats`
- `Scale_Items`
- `By_Current_Level`
- `Subjective_Numeric_Items`

### `student_standard_scores_v1.xlsx`

- `Student_Standard_Scores`
- `Student_Type`
- `Student_Subjective`

### `snapshot_metadata.json`

포함 항목:

- version, snapshot_date, total_N
- survey_slug, snapshot_cutoff_at, round_no
- fixed_scale_stats
- core_item_ids, supplementary_item_ids
- subjective_in_core (항상 false)
- level_distribution
- current_math_percentile_summary
- logic_version
- data_hash, scale_map_hash
- warnings
- type_level_validation_summary

권장 산출물:

- `student_item_matrix_v1.xlsx`
- `snapshot_input_frozen.csv` (또는 parquet)
- `type_level_validation_v1.xlsx`
- `type_level_validation_summary_v1.json`

### `type_level_validation_v1.xlsx` (권장)

- `Type_Level_Stats`
  - 유형별 등급 평균/분산/중앙값/IQR/N
- `Group_Difference_Tests`
  - Kruskal-Wallis + pairwise Mann-Whitney(U) + Holm 보정 + 효과크기
- `Ordinal_Regression`
  - 감정/신념/상호작용 순서형 로지스틱 계수
- `Interaction_Test`
  - base vs interaction 모델 비교(LR test, pseudo R2)
- `Mismatch_Patterns`
  - 실력 높음+유형 낮음 / 실력 낮음+유형 높음 패턴 요약
- `Cross_Validation`
  - KFold 기반 MAE/QWK/within-one-rate

### `type_level_validation_summary_v1.json` (권장)

- 핵심 검정 p-value/효과크기
- 상호작용 유의성
- 교차검증 성능 요약
- 해석 프레임 문구(인과 단정 금지)

## 실패/경고 기준

### 실패(중단)

- `core_scale` 대상 문항의 `scale_map.csv` 누락 question_id 존재
- 필수 axis_tag 누락
- `raw_score` 범위 이탈 비율이 임계치 초과

### 경고(진행)

- total_N < 30
- alpha 계산 불가 스케일
- 수준 컬럼 결측 비율 높음
- statsmodels/scikit-learn 미설치로 고급 검증 스킵

## 해석 원칙 (중요)

- 유형을 실력의 **원인**으로 단정하지 않습니다.
- 상관과 인과를 구분하고, p-value 단독보다 효과크기와 신뢰구간을 우선합니다.
- 성장 가능성은 단면(1차)에서 확정하지 않고, 후속 라운드 추적으로 검증합니다.

## raw CSV 추출 SQL

SQL 템플릿은 [sql/raw_answers_round1.sql](sql/raw_answers_round1.sql) 파일을 사용하세요.
