# 문항 풀이 회차

같은 문항을 여러 번 푼다. 처음 과제로 만나서 세 번 고쳐 풀어 맞히고, 몇 주 뒤
교재를 다시 풀어 보고 싶어 리셋하고 두 번 고쳐 풀고, 선생님이 다시 과제로 내줘서
또 네 번 고쳐 푼다. 이 셋은 **다른 사건**이다. 시도 수를 통으로 세면 "아홉 번
틀린 아이"가 되지만, 실제로는 세 번의 라운드를 각각 통과한 아이다.

회차는 이 세 사건을 가르는 단위다.

## 왜 새 테이블인가

`learning_attempts` 는 이미 append-only 라 시도는 전부 남아 있었다. 부족한 건
묶음이었다. 후보는 셋이었다.

- **배정(`homework_item_problems`) 을 회차로 본다.** 선생님이 새로 내주면 새 배정
  행이 생기니 자연스럽다. 하지만 리셋 후 혼자 다시 푼 것은 배정이 없어 갈리지
  않는다.
- **`learning_attempts` 에 `round_no` 정수만 붙인다.** 가볍지만 "왜 이 회차가
  열렸는지", "언제 닫혔는지", "통과했는지"를 담을 곳이 없다.
- **회차 테이블을 만든다.** 채택.

## 테이블

`student_problem_rounds` — 학생 × 문항 × 회차.

| 컬럼 | 뜻 |
| --- | --- |
| `round_no` | 이 학생이 이 문항을 푼 n번째 (1부터) |
| `origin` | `homework` / `free_practice` / `reset` |
| `homework_group_id`, `homework_item_problem_id` | 과제로 푼 회차면 그 맥락 |
| `opened_at`, `closed_at`, `close_reason` | 회차의 시작과 끝 |
| `attempt_count`, `correct_count`, `passed`, `first_correct_at` | 회차 안 집계 |

`learning_attempts.round_id`, `learning_exposures.round_id` 로 연결한다. 집계
컬럼은 시도 기록에서 언제든 다시 계산할 수 있다 — 조회를 위한 캐시다.

## 회차가 넘어가는 순간

셋뿐이다. 규칙을 늘리면 회차가 잘게 쪼개져 세는 의미가 없어진다.

1. **정답으로 통과** (`close_reason='passed'`). 통과한 순간 회차가 닫힌다. 다음에
   같은 문항을 다시 풀면 새 회차가 열린다.
2. **새 과제 배정** (`reassigned`). 열린 회차의 배정과 다른 배정으로 풀면 앞
   회차를 닫고 넘어간다.
3. **리셋** (`reset`). 아래 참조.

자유 풀이로 시작한 회차가 도중에 과제에 자동 연결되는 경우는 **쪼개지 않는다**.
같은 문항을 이어서 푸는 중이므로 맥락만 채워 넣는다.

## 자유 풀이도 기록한다

예전에는 배정된 과제가 없으면 `learning_log_homework_attempt` 가
`not_assigned` 로 끝나 `learning_attempts` 에 아무것도 남지 않았다. 남는 건 답
캐시 한 줄뿐이라 "리셋하고 혼자 다시 푼 회차"가 통째로 사라졌다.

지금은 배정이 없으면 `session_kind='free_practice'` 세션을 열어 노출·시도를
남긴다. 과제 링크는 비고 `meta.free_practice=true` 가 붙는다. 마스터리 판정은
과제가 있을 때만 돈다.

## 리셋 — 지우지 않는다

`student_reset_textbook_v1` (학생, 교재+학년 단위)과
`staff_reset_student_problems_v1` (스태프, 문항 단위까지)이 하는 일은 두 가지다.

1. 열린 회차를 `reset` 으로 닫는다.
2. 답 캐시(`student_textbook_answer_records`)의 답·정오·시도수를 비운다.

`learning_attempts` 와 `student_problem_rounds` 는 건드리지 않는다. 화면만
비어 보이고 기록은 남는다. 답 캐시 행 자체는 지우지 않는데,
`first_attempt_correct`("이 문항을 처음 만났을 때 맞혔는가")는 다시 풀기로
바뀌면 안 되는 값이기 때문이다.

선생님이 검사 중(제출·확인 단계)인 교재는 거절한다(`under_review`). 검사하던
화면과 어긋난다.

학생 진입점은 「교재 풀기」 탭에서 교재 커버를 **길게 누르면** 나오는 메뉴다.
평소에는 보이지 않아 실수로 누르기 어렵고, 실행 전 한 번 더 확인을 받는다.

기존 `unbind_student_textbook` 은 그대로 남는다. 그건 교재 바인딩 자체를 없애는
파괴적 작업이고, 여기서 말하는 다시 풀기와는 목적이 다르다.

## 화면에서

두 앱 모두 문항 옆에 **2회차부터** 배지를 띄운다. 처음 푸는 문항에 "1회차"를
붙이면 배지가 늘 떠 있어 정보가 되지 않는다.

| 앱 | 위치 | 출처 |
| --- | --- | --- |
| 학생앱 | 교재 문항 행 / 세트형 헤더 | `student_textbook_page_problems_v2.round_no` |
| 학생앱 | 과제 문항 목록 | `student_list_homework_problems_v1.round_no` |
| 매니저앱 | 우측 시트 채점 카드 | `staff_list_problem_rounds_v1` |
| 매니저앱 | 답지 뷰어 채점 그리드 (구석 표기 + 툴팁) | 같음 |

`round_no` 는 **열린 회차가 있으면 그 번호, 없으면 마지막 회차 번호**다. 한 번도
푼 적 없으면 0.

회차별 시도 타임라인 UI 는 아직 없다. 데이터는
`student_problem_round_history_v1(student_id, crop_id)` 로 지금도 볼 수 있다 —
회차마다 시도 목록(결과·답·채점 주체·소요시간·시각)이 JSON 으로 딸려 온다.

## 과거 기록

마이그레이션에서 기존 `learning_attempts` 를 같은 규칙(정답 통과 / 배정 변경)으로
잘라 회차를 매겼다. 그래서 회차 번호가 어느 날 갑자기 1부터 시작하지 않는다.
백필로 만든 회차에는 `meta.backfilled=true` 가 붙는다.

## 관련 파일

- `supabase/migrations/20260813210000_student_problem_rounds.sql` — 테이블·백필
- `supabase/migrations/20260813211000_learning_attempt_rounds_and_free_practice.sql`
- `supabase/migrations/20260813212000_textbook_round_reset.sql`
- `supabase/migrations/20260813213000_expose_problem_rounds.sql`
