# 20260213_004_homework_score_v1

## 메타

- status: applied
- owner: manager-app
- related_files:
  - `apps/yggdrasill/lib/services/homework_score_service.dart`
  - `apps/yggdrasill/lib/services/data_manager.dart`
  - `apps/yggdrasill/lib/screens/student/student_profile_page.dart`
  - `docs/assessment/scoring.md`

## 변경 목적

- 과제 수행을 단기 상태가 아닌 누적 성실도로 읽을 수 있도록 `EXP형` 점수를 도입한다.
- 출석 점수와 동일하게 코호트 내 상대 위치(등수/상위%)를 함께 제공한다.
- 추후 과정/난이도별 가중치를 쉽게 추가할 수 있도록 가중치 훅 구조를 선반영한다.

## 변경 전

- 스탯 탭 개입 가능 변수에는 출석 점수만 있었다.
- 과제 점수 계산식/순위/표시 카드가 없었다.

## 변경 후

### 점수 모델

- 데이터 소스:
  - `homework_items`
  - `homework_assignments`
  - `homework_assignment_checks`
- 이벤트 타입:
  - 배정(`assigned`)
  - 검사(`checked`)
  - 완료(`completed`)
- 시간 감쇠:
  - `w = exp(-ln(2) * daysAgo / halfLifeDays)`
  - 과제 점수는 장기 누적 특성을 위해 긴 반감기 사용
- 누적 EXP:
  - `expRaw = Σ(eventXp)`
  - `expDecayed = Σ(eventXp * w)`
- 점수화:
  - `score100 = 100 * (1 - exp(-expDecayed / scaleK))`
  - 최종 점수는 `0~100` clamp

### 기본 파라미터(v1)

- `halfLifeDays = 180`
- `scaleK = 240`
- 배정 기본 XP: `0.45` (+progress/status 보정)
- 검사 기본 XP: `0.95` (+progress 보정)
- 완료 기본 XP: `3.80` (+누적시간/checkCount 보정)

### 확장 훅

- `HomeworkEventWeightModifier`를 통해 이벤트별 가중치 커스터마이징 가능
- 현재 기본값은 `1.0`
- 추후 `flowId/bookId/difficulty` 기반 가중치 정책을 동일 인터페이스로 확장

### 순위

- 코호트: 현재 재원생 목록(`students`)
- 정렬: 과제 점수 내림차순, 동점 시 학생 id 오름차순
- 상위 퍼센트:
  - `top_percent = rank / cohort_size * 100`

## 영향 범위

- 서비스 계산식: 신규(`homework_score_service.dart`)
- DataManager: 비동기 계산/순위 API 추가
- UI 표기: 스탯 탭 개입 가능 변수에 `과제 점수(EXP)` 카드 추가
- 데이터 저장/스냅샷: 이번 변경은 계산/표시 단계(별도 스냅샷 저장 로직은 후속 단계)

## 검증 체크리스트

- [x] 과제 이벤트가 누적될수록 점수가 증가
- [x] 오래된 이벤트는 완만히 희석(급락 없음)
- [x] 재원생 순위/상위 퍼센트 표시
- [x] 스탯 탭에서 출석 점수 아래 카드 렌더링
- [x] IDE lint 확인
- [ ] `dart analyze` 명령은 환경 hang로 완료 로그 미수집(후속 수동 확인 필요)

## 롤백 기준

- 점수 상승 속도가 과도하거나 과제 성실도와 체감이 크게 어긋날 때 롤백
- 롤백 대상:
  - `homework_score_service.dart`
  - `data_manager.dart` 과제 점수 API
  - `student_profile_page.dart` 과제 점수 카드
  - 본 문서 status를 `rolled_back`으로 갱신
