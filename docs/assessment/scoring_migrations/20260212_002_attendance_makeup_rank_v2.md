# 20260212_002_attendance_makeup_rank_v2

## 메타

- status: applied
- owner: manager-app
- related_files:
  - `apps/yggdrasill/lib/services/attendance_service.dart`
  - `apps/yggdrasill/lib/services/data_manager.dart`
  - `apps/yggdrasill/lib/screens/student/student_profile_page.dart`

## 변경 목적

- 출석 점수에 보강 패턴을 반영해 성실도 해석력을 높인다.
- 학생별 출석 점수의 상대 위치를 재원생 코호트 내 순위/상위 퍼센트로 제공한다.

## 변경 전

- 출석/지각/결석 기반 감쇠+스무딩 점수만 제공했다.
- 보강 횟수/비율은 출석 점수에 반영되지 않았다.
- 스탯 탭에 코호트 순위가 없었다.

## 변경 후

### 보강 반영 규칙

- 보강 이벤트:
  - `override_type=replace`
  - `reason=makeup`
  - `status=completed`
- 월 보강 횟수:
  - `replacement_class_datetime` 기준 연/월 집계
- 월 수업 수:
  - 동일 월의 유효 수업 이벤트(미래 planned 제외)
- 보강 비율:
  - `r = makeup_count / max(month_class_count, 1)`

### 페널티 정책

- `makeup_count <= 1` -> `penalty = 0`
- `makeup_count >= 2 && r < 0.5` -> 완만 페널티 구간(최대 0.08)
- `r >= 0.5` -> 강한 페널티 구간(0.08~0.25)
- 최종:
  - `final_ratio = clamp(smoothed_ratio - penalty, 0, 1)`
  - `score100 = final_ratio * 100`

### 순위/상위 퍼센트

- 코호트:
  - 현재 재원생(`students`) 기준
- 정렬:
  - 출석 점수 내림차순
- 상위 퍼센트:
  - `top_percent = rank / cohort_size * 100`
- 동점:
  - 허용 오차 내 동일 점수는 공동 순위

## 영향 범위

- 서비스 계산식: 확장
- UI 표기: 확장(보강 영향, 순위/상위 퍼센트)
- DB 스키마/저장: 변경 없음
- 총점/자동 트리거: 변경 없음

## 검증 체크리스트

- [x] 월 보강 1회에서 감점 없음
- [x] 월 보강 2회 이상에서 점진 감점 발생
- [x] 월 보강 비율 50% 이상에서 강한 감점 발생
- [x] 순위/상위 퍼센트가 점수 정렬과 일치
- [x] 린트 에러 없음

## 롤백 기준

- 감점 체감이 과도하거나 해석 혼선을 유발하면 롤백한다.
- 롤백 대상:
  - 보강 페널티 계산 단계
  - 코호트 순위 계산/표시
  - 본 문서 상태를 `rolled_back`으로 갱신
