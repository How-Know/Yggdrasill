# 20260730_005_attendance_past_planned_absent_v3

## 메타

- status: applied
- owner: learning-app
- related_files:
  - `apps/yggdrasill/lib/services/attendance_service.dart`
  - `apps/yggdrasill/lib/screens/student/student_profile_page.dart`
  - `apps/yggdrasill/lib/widgets/attendance_rank_dialog.dart`

## 변경 목적

- UI에서 결석으로 보이는 **오늘 이전 순수 planned 미기록**이 점수에서 제외되어
  거의 안 오는 학생이 고득점·상위 순위가 되는 왜곡을 제거한다.
- `judgeAttendanceResult`의 과거 planned=결석 판정과 점수 포함 규칙을 맞춘다.

## 변경 전

- 포함: 실제 출석/지각, 명시 결석(`is_planned=false`)
- 제외: 모든 순수 planned 미처리 (과거 포함) → `pendingIgnoredCount`
- 결과: 미기록 결석이 많은 학생은 prior(0.9)+가끔 출석만으로 점수가 높게 유지됨

## 변경 후

- 포함:
  - 실제 출석/지각
  - 명시 결석
  - **오늘 이전 순수 planned 미기록** (결석 0.0으로 반영)
- 제외:
  - 오늘·미래 순수 planned 미처리
- 추가 반환 키: `pastPlannedAbsentCount`

## 영향 범위

- 서비스 계산식: `calculateAttendanceScore` (순위/다이얼로그/스탯 카드 공통)
- UI 표기: 스탯 카드에 과거 미기록→결석 건수 표시
- DB 저장: 없음

## 검증 체크리스트

- [x] 과거 planned 미기록이 `absentCount` / `weightedAbsent`에 포함
- [x] 오늘·미래 planned는 계속 `pendingIgnoredCount`
- [x] 김재헌·지예준·이준서처럼 미기록이 많은 학생 순위가 하위로 내려가는지 핫리스타트 후 확인

## 롤백 기준

- 과거 planned를 다시 제외하려면 v1 분기의 `else { pendingIgnoredCount += 1 }` 로 되돌린다.
- 본 문서 status를 `rolled_back`로 변경한다.
