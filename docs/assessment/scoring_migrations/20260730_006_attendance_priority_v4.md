# 20260730_006_attendance_priority_v4

## 메타

- status: applied
- owner: learning-app
- related_files:
  - `apps/yggdrasill/lib/services/attendance_service.dart`
  - `apps/yggdrasill/lib/services/data_manager.dart`
  - `apps/yggdrasill/lib/screens/student/student_profile_page.dart`
  - `apps/yggdrasill/lib/widgets/attendance_rank_dialog.dart`

## 변경 목적

- 출석 평가의 우선순위를 `결석 > 보강 > 지각`으로 명확히 고정한다.
- 결석이 많은 학생은 보강·지각 상태와 관계없이 하위 결석 구간으로 배치한다.
- 고정 prior 90점이 기록이 적은 학생을 과도하게 보호하던 현상을 줄인다.

## 계산식

- 모든 비율은 28일 반감기 가중치를 사용한다.
- `결석률 = weighted_absent / weighted_total`
- `보강률 = weighted_makeup / weighted_total`
- `지각률 = weighted_late / (weighted_present + weighted_late)`
- `결석 감점 = min(결석률 × 140, 70)`
- `보강 감점 = min(보강률 × 40, 20)`
- `지각 감점 = min(지각률 × 10, 10)`
- `점수 = clamp(100 - 결석 감점 - 보강 감점 - 지각 감점, 0, 100)`

## 순위

1. 결석 구간 오름차순
2. 점수 내림차순
3. 보강률 오름차순
4. 지각률 오름차순

결석 구간:

- A: 0% 이상 5% 미만
- B: 5% 이상 10% 미만
- C: 10% 이상 20% 미만
- D: 20% 이상 30% 미만
- E: 30% 이상

## 표본 부족

- 반영 이벤트가 4회 미만이면 `insufficientEvidence=true`로 표시한다.
- 순위 계산에서는 학원 코호트 평균 2회분을 섞어 신규 학생의 100점 쏠림을 완화한다.
- 4회 이상부터는 개인 비율만 사용한다.

## 검증

- [x] 과거 planned 미기록은 결석에 포함
- [x] 결석 감점 최대 70, 보강 최대 20, 지각 최대 10
- [x] 결석 구간이 다른 학생끼리는 보강·지각으로 순서가 뒤집히지 않음
- [x] 변경 파일 정적 분석에서 신규 error 없음

