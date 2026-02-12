# 20260212_001_attendance_score_v1

## 메타

- status: applied
- owner: manager-app
- related_files:
  - `apps/yggdrasill/lib/services/attendance_service.dart`
  - `apps/yggdrasill/lib/services/data_manager.dart`
  - `apps/yggdrasill/lib/screens/student/student_profile_page.dart`

## 변경 목적

- 출석 점수를 개입 가능 변수에 1단계로 도입한다.
- 과거 이벤트 영향 감쇠, 수업량 편향 완화, 신규 학생 급변 완화를 동시에 달성한다.

## 변경 전

- 스탯 탭에서 출석 점수 계산/표시가 없었다.
- 개입 가능 변수 섹션에 점수 카드가 없었다.

## 변경 후

- 서비스 계산식 `calculateAttendanceScore(studentId)` 추가.
- 스탯 탭 `개입 가능 변수`에 출석 점수 카드 추가.

### 계산식

- 이벤트 점수:
  - 출석: `1.0`
  - 지각: `0.6`
  - 결석: `0.0`
- 지각 판정: `lateness_threshold`(학생 결제정보) 재사용
- 시간 감쇠(최근 가중):
  - `w = exp(-ln(2) * daysAgo / halfLifeDays)`
  - `halfLifeDays = 28`
- 비율 점수:
  - `raw = sum(w * eventScore) / sum(w)`
- 스무딩:
  - `smoothed = (sum(w) * raw + k * prior) / (sum(w) + k)`
  - `prior = 0.9`, `k = 8`
- 최종 점수:
  - `score100 = clamp(smoothed, 0, 1) * 100`

### 포함/제외 규칙

- 포함:
  - 실제 출석/지각 이벤트
  - 명시 결석 이벤트
- 제외:
  - 미래 수업
  - 순수 planned 미처리 이벤트(미기록 예정 수업)

## 영향 범위

- 서비스 계산식: 추가됨
- UI 표기: 추가됨(출석/지각/결석 가중 기여치 포함)
- DB 저장: 없음
- 총점 반영: 없음
- 자동 트리거 파이프라인: 없음

## 검증 체크리스트

- [x] 수업량 편향 완화: 비율 점수 구조로 과대/과소 누적 완화
- [x] 재원기간 편향 완화: 시간 감쇠 + 스무딩으로 완화
- [x] 과거 이벤트 감쇠: 반감기 28일 반영
- [x] 린트/렌더링 확인: 수정 파일 lint error 없음

## 롤백 기준

- 점수 변동이 과도하거나 해석성이 낮다고 판단되면 본 마이그레이션을 롤백한다.
- 롤백 시 제거 대상:
  - `calculateAttendanceScore` 호출 및 UI 카드 연결
  - 본 문서 상태를 `rolled_back`으로 변경
