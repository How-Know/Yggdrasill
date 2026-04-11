# 테스트 채점 결과 저장 설계 (고정안)

이 문서는 우측 시트 테스트 채점(`RightSideSheetTestGradingSession`) 결과를
다음 구현 단계에서 DB에 저장하기 위한 기준안이다.

## 1) 저장 원칙

- 저장 단위는 **채점 시도(회차) 이력**이다. (덮어쓰기 금지)
- 저장 시점은 채점 탭의 `onAction` 호출 시점이다.
  - `complete`, `confirm` 모두 저장
- 시간값은 **학생 풀이시간**(`homework_items.accumulated_ms`) 기준이다.
- 점수는 문항별 배점(`scoreByQuestionKey`)을 기준으로 계산한다.

## 2) 제안 스키마

## 2-1) `homework_test_grading_attempts` (헤더)

- `id uuid pk`
- `academy_id uuid not null`
- `student_id uuid not null`
- `homework_item_id uuid not null`
- `assignment_code_snapshot text null`
- `group_homework_title_snapshot text null`
- `graded_at timestamptz not null default now()`
- `graded_by uuid null`
- `action text not null` (`complete` | `confirm`)
- `solve_elapsed_ms integer not null default 0`
- `score_correct numeric(10,2) not null default 0`
- `score_total numeric(10,2) not null default 0`
- `wrong_count integer not null default 0`
- `unsolved_count integer not null default 0`
- `payload_version integer not null default 1`
- `created_at/updated_at`, `created_by/updated_by`, `version`

권장 인덱스:
- `(academy_id, student_id, graded_at desc)`
- `(academy_id, homework_item_id, graded_at desc)`

## 2-2) `homework_test_grading_attempt_items` (문항별)

- `id uuid pk`
- `attempt_id uuid not null` (FK -> attempts.id, cascade delete)
- `academy_id uuid not null`
- `student_id uuid not null`
- `homework_item_id uuid not null`
- `question_key text not null`
- `question_uid text null`
- `page_number integer not null`
- `question_index integer not null`
- `correct_answer_snapshot text null`
- `state text not null` (`correct` | `wrong` | `unsolved`)
- `point_value numeric(10,2) not null default 1`
- `earned_point numeric(10,2) not null default 0`
- `reserved_elapsed_ms integer null` (향후 문항별 시간 기록용)
- `created_at/updated_at`, `created_by/updated_by`, `version`

권장 인덱스:
- `(academy_id, question_uid, created_at desc)`
- `(academy_id, question_key, created_at desc)`
- `(attempt_id, page_number, question_index)`

## 3) 저장 파이프라인 기준

1. `RightSideSheetTestGradingSession.onAction(action, states)` 진입
2. 현재 세션의 `gradingPages`, `scoreByQuestionKey`, `states`를 DTO로 정규화
3. 헤더(`attempts`) 1건 insert
4. 문항(`attempt_items`) N건 bulk insert
5. 실패 시 헤더/문항 모두 롤백

## 4) 조회 요구사항 대응

- 학생별 최근 채점 이력 조회
- 과제별(또는 그룹 과제별) 채점 이력 조회
- 문항별 오답률 집계
  - 분모: `state in (correct, wrong, unsolved)` 또는 정책상 유효 응답
  - 분자: `state = wrong`
- 문항별 시간 집계는 `reserved_elapsed_ms` 도입 후 활성화

## 5) 구현 시 주의

- `question_key`는 현재 채점 세션 키 규칙(`<hwId>|<page>|<index>|<uid>`)을 그대로 저장
- 점수 합계는 UI 표기값과 동일 로직(`scoreByQuestionKey` 우선, 없으면 1점) 사용
- 저장 실패는 사용자에게 스낵바로 표시하되, 채점 화면 상태는 유지
