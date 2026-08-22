# 시간제한 테스트 V0

## 목적

개념원리 교재의 검수된 자동채점 문항을 학생앱에서 제한시간 동안 한 방향으로
풀게 하고, 이후 문항 메타데이터 분석에 사용할 수 있는 노출·정오·시간 데이터를
수집한다.

V0는 기존 과제와 학습 이벤트 구조를 확장한다. 별도 시험 문항 테이블을 만들지
않고 다음 안정 키를 그대로 사용한다.

- 과제 스냅샷: `homework_item_problems`
- 시험 세션: `learning_sessions`
- 실제 노출: `learning_exposures`
- 제출 결과와 시간: `learning_attempts`
- 문제은행 연결: `pb_question_uid`

## 확정 정책

- 학생앱에서만 응시한다.
- 과제당 한 번만 응시한다.
- 서버의 `started_at + time_limit_sec`가 절대 마감이다.
- 앱을 나가도 시간은 계속 흐르며 남은 시간이 있으면 재개한다.
- 답 제출 또는 패스 후 이전 문항으로 돌아갈 수 없다.
- 시험 중 정오·정답·해설을 공개하지 않는다.
- 명시적 패스는 원본 이벤트 `skipped`로 보존하되 정확도 분모에서는 오답처럼
  계산한다.
- 시간 종료 당시 노출된 미응답 문항만 `timeout`으로 기록한다.
- 아직 도달하지 않은 문항에는 exposure나 attempt를 만들지 않는다.
- 정확도는 `correct / (correct + wrong + skipped)`이다.
- 자동채점 문항만 출제한다. 자가채점 문항은 제외한다.
- 종료 또는 포기한 single-shot 테스트는 정오와 무관하게 과제 배정을 완료한다.

## 출제 알고리즘

현재 지원 교재는 개념원리다. 선택한 페이지 범위의 자동채점 가능 문항 전체를
스냅샷에 넣고, 앞쪽 노출 순서를 다음 가중 무작위 추출로 만든다.

- 필수유형/대표유형: 40%
- 확인 체크: 30%
- 연습문제: 20%
- 개념원리 익히기: 10%

유형을 강제 블록으로 정렬하지 않는다. 매 위치에서 아직 문항이 남은 유형끼리
가중치를 다시 정규화하고, 선택된 유형 안에서도 무작위로 한 문항을 뽑는
무복원 방식이다. 네 유형을 모두 소진한 뒤 기타 자동채점 문항을 배치한다.

학생 ID, 교재 ID, 과정, 선택 crop 집합으로 결정적 seed를 만든다. 최종 순서는
`homework_item_problems.sort_order`에 고정하며 다음 값을 `crop_snapshot`과
`unitMappings`에 남긴다.

- `recommenderKey`: `wonri_timed_v0`
- `recommenderVersion`
- `recommenderSeed`
- `recommenderWeights`
- 정규화한 유형
- 적격 문항 수와 자가채점 제외 수

관련 순수 함수는 `apps/yggdrasill/lib/utils/wonri_timed_test_v0.dart`에 있다.

## 서버 계약

마이그레이션:

`supabase/migrations/20260823010000_timed_homework_test_v0.sql`

학생 RPC:

- `student_start_or_resume_timed_test_v1(group_id)`
  - 본인 배정과 테스트 여부를 검증한다.
  - 그룹당 non-void `daily_test` 세션 하나만 허용한다.
  - 서버 마감과 결과 요약을 반환한다.
- `student_timed_test_expose_v1(session_id, crop_id, uid, position)`
  - 실제 배정 스냅샷 문항만 노출할 수 있다.
  - 세션의 위치와 문항 기준으로 멱등 처리한다.
- `student_finish_timed_test_v1(session_id, status)`
  - 마감 시 마지막 노출 미응답 문항을 `timeout` 처리한다.
  - 세션과 과제 배정을 같은 트랜잭션에서 완료한다.
- `student_finalize_expired_timed_tests_v1()`
  - 학생 과제 목록을 새로고침할 때 재진입하지 않은 만료 세션도 정리한다.

매니저 RPC:

- `pb_question_timed_test_stats_batch_v1(question_uids[])`
  - 현재 staff membership 범위에서 UID 배열을 한 번에 집계한다.
  - 출제·노출·응답 학생 수는 모두 학생 중복을 제거한다.
  - 응답은 `correct`와 `wrong`만 포함하고 패스·timeout은 제외한다.

정오 판정은 학생이 직접 호출할 수 있는 SQL 인자로 받지 않는다.
`student_textbook_grade` Edge Function이 정답과 제출 답을 비교한 뒤 service role로
`learning_log_attempts`를 호출한다. 시간제한 homework 세션의 attempt는 DB
trigger도 service role 또는 서버 timeout만 허용한다.

Edge Function 시험 action:

- 일반 `grade` + `timed_test` context: 정오를 숨긴 accepted 응답
- `timed_test_pass`: `skipped`
- `timed_test_status`: exposure의 제출 여부
- `timed_test_progress`: 재진입할 다음 위치

## 학생앱 흐름

`HomeworkGroup.isTimedTest`인 디지털 과제는
`TimedTestSolveScreen`으로 진입한다.

1. 제한시간과 1회 응시 안내
2. 서버 세션 시작 또는 재개
3. 이전 attempt를 확인해 다음 미응답 위치 복원
4. 문항 렌더 완료 후 exposure 기록
5. active time과 wall time 측정
6. 자동채점 제출 또는 패스
7. 다음 문항으로 단방향 이동
8. 전 문항 소진 또는 서버 마감 시 세션 종료
9. 정답·오답·패스·timeout·노출·정확도 요약

문항별 `duration_ms`는 앱이 활성 상태였던 시간이며,
`wall_duration_ms`와 `interruption_ms`는 attempt `meta`에 함께 남는다.

## 문제은행 통계

문제은행 문항카드는 현재 보이는 `question_uid[]`를 배치 RPC로 한 번만 조회한다.

- 출제: 테스트 `homework_item_problems`에 포함된 고유 학생 수
- 노출: `test_blueprint` exposure가 있는 고유 학생 수
- 응답: `correct` 또는 `wrong` attempt가 있는 고유 학생 수

비동기 문서 전환 시 이전 통계 응답이 새 문서를 덮지 않도록 request version과
document context를 함께 확인한다.

## V0의 의도적인 제한

- 문항 수 제한 UI는 자리만 잡았으며 비활성 상태다.
- 결과 화면은 집계 요약만 제공한다. 문항별 정답·해설 복기는 아직 없다.
- 학생 답 입력은 단일 텍스트 중심이다.
- 파트별 입력이 필요한 세트형 문항은 V0 출제 대상에서 안전하게 제외해야 한다.
- 자동채점 판별 SQL과 매니저 Dart 안전 필터가 함께 존재한다. SQL 규칙 변경 시
  Dart 필터의 동기화 여부를 검사해야 한다.
- 앱을 다시 열면 만료 세션이 정리된다. 학생이 앱을 영구적으로 다시 열지 않는
  경우를 즉시 정리하는 서버 cron은 V0에 포함하지 않는다.
- V0는 개념원리만 지원한다.

## V1에서 우선할 작업

1. 문항 수 제한을 활성화하고 시간·문항 수의 독립/동시 종료 규칙을 추가한다.
2. 자동채점 가능 여부를 단일 서버 RPC로 통합해 SQL/Dart 판별 중복을 제거한다.
3. 세트형·객관식 선택지·수식 입력을 시험 전용 입력 UI에서 지원한다.
4. 종료 후 문항별 답, 정답, 해설과 시간 복기 화면을 추가한다.
5. 서버 cron으로 방치된 만료 세션을 자동 종료한다.
6. 난이도·학생 수준·최근 노출을 반영한 blueprint를 도입한다.
7. anchor 문항과 버전 고정으로 회차 간 능력 변화를 비교한다.
8. 출제·노출·응답 0 문항 필터와 분석 대시보드를 추가한다.

## V1 AI 분석 시 주의사항

- 오답 하나를 곧바로 능력 결손으로 해석하지 않는다.
- `Question Requirement`와 `Student Observation`을 분리한다.
- 미도달 문항은 오답이 아니다. 속도 신호로만 사용한다.
- `timeout`은 정오 통계에서 제외하고 도달 위치·속도와 함께 해석한다.
- `skipped`는 점수 분모에는 포함되지만 일반 오답과 구분해 보존한다.
- 문항 위치가 뒤로 갈수록 노출이 줄어드는 position bias를 보정한다.
- `recommenderVersion`, seed, 유형 가중치가 다른 회차를 무조건 합치지 않는다.
- 학생별 수준 스냅샷과 시험 감독·장소·중단 시간을 신뢰도 변수로 사용한다.
- K/R/E/R 태그는 문항 요구사항이고, attempt 결과는 학생 관찰이다.
- AI가 제안한 taxonomy나 태그는 사람 검수 전까지 확정 데이터로 승격하지 않는다.

## 배포 순서

1. DB migration 적용
2. `student_textbook_grade` Edge Function 배포
3. 매니저/학습앱 배포
4. 학생앱 배포

학생앱만 먼저 배포하면 RPC가 없어 과제 목록과 시험 진입이 실패할 수 있으므로
순서를 바꾸지 않는다.
