# Homework Unit Stats New-Only Rollout

## 정책

- 기존 `homework_items` 데이터는 백필하지 않는다.
- 단원 통계는 `homework_item_units`가 생성된 신규 과제만 집계한다.
- 집계 기준은 소단원 매핑(`homework_item_units`)이며, 대/중단원 선택도 저장 시 소단원으로 분해한다.

## 운영 반영 포인트

- 과제 저장 payload에 `bookId`, `gradeLabel`, `sourceUnitLevel`, `sourceUnitPath`, `unitMappings[]`를 포함한다.
- `HomeworkStore.add(...)` 경로에서 `homework_items`와 `homework_item_units`를 함께 저장한다.
- 통계 조회는 `vw_homework_unit_stats_base` + `homework_unit_stats(...)`만 사용한다.
- 통계 화면/리포트는 신규 집계 정책임을 명시한다(기존 데이터 제외).

## 검증 시나리오 체크리스트

1. **소단원 직접 선택**
   - 소단원 1개를 선택해 과제를 생성한다.
   - `homework_items.book_id/grade_label/source_unit_level='small'` 저장을 확인한다.
   - `homework_item_units`에 1행(`source_scope='direct_small'`) 생성되는지 확인한다.

2. **중단원 선택(분해 저장)**
   - 중단원을 선택해 과제를 생성한다.
   - `homework_items.source_unit_level='mid'` 저장을 확인한다.
   - `homework_item_units`에 하위 소단원 개수만큼 행이 생성되고 `source_scope='expanded_from_mid'`인지 확인한다.

3. **대단원 선택(분해 저장)**
   - 대단원을 선택해 과제를 생성한다.
   - `homework_items.source_unit_level='big'` 저장을 확인한다.
   - `homework_item_units`에 하위 소단원 전체가 저장되고 `source_scope='expanded_from_big'`인지 확인한다.

4. **직접 입력 모드**
   - 페이지 직접 입력으로 과제를 생성한다.
   - `homework_items.source_unit_level='manual'` 저장을 확인한다.
   - `homework_item_units`가 생성되지 않는지 확인한다(단원 통계 제외 대상).

5. **통계 집계**
   - 검사 데이터를 만든 뒤 `homework_unit_stats(...)`를 `big/mid/small` 각각 호출한다.
   - `avg_minutes`, `avg_checks`, `total_checks`가 기대값과 일치하는지 확인한다.
   - 기존(백필 없는) 과제가 결과에 포함되지 않는지 확인한다.

