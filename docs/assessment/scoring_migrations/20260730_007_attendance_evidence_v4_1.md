# 20260730_007_attendance_evidence_v4_1

## 메타

- status: applied
- owner: learning-app
- related_files:
  - `apps/yggdrasill/lib/services/attendance_service.dart`
  - `apps/yggdrasill/lib/services/data_manager.dart`
  - `apps/yggdrasill/lib/screens/student/student_profile_page.dart`
  - `apps/yggdrasill/lib/widgets/attendance_rank_dialog.dart`

## 변경 목적

- 주 1회 학생이 적은 표본만으로 상위권에 고정되는 효과를 완화한다.
- 수업 빈도를 출석 성실도 감점과 섞지 않고 별도 참여량으로 보여준다.

## 변경 내용

- 표본 기준을 단순 이벤트 4건에서 `가중 유효 수업 8회`로 변경한다.
- 8회 미만은 `8 - 가중 유효 수업`만큼 학원 평균 비율을 섞는다.
- 8회 이상은 개인 비율만 사용한다.
- 최근 28일 반영 수업 수를 4로 나눈 `weeklyParticipation`을 별도 표시한다.

## 기대 효과

- 주 1회 학생은 성실하게 출석해도 적은 표본으로 즉시 100점 확정되지 않는다.
- 주 1회 등록 자체를 감점하지 않으며, 참여 빈도는 설명 정보로만 제공한다.
- 충분한 표본이 쌓인 학생은 기존 v4 계산식 그대로 평가한다.

## 검증

- [x] `totalWeight < 8`일 때 학원 평균 보정
- [x] `totalWeight >= 8`일 때 무보정
- [x] 프로필·순위 다이얼로그에 주당 참여량 및 표본 표시

