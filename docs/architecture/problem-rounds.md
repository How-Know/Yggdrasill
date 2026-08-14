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

## 시즌 — 책을 통째로 다시 도는 구간

회차는 문항 단위라 리셋 뒤에도 A는 2차, B는 3차, 처음 만난 문항은 1차로 제각각
이다. 그게 맞다. 다만 "지금 이 책을 몇 번째로 도는 중인가"를 담을 곳이 없어서,
리셋 직후 화면에 지난 회차 숫자만 남았다.

`student_textbook_seasons` — 학생 × 교재(학년).

| 컬럼 | 뜻 |
| --- | --- |
| `season_no` | 이 학생이 이 교재를 도는 n번째 (1부터) |
| `opened_at`, `closed_at`, `close_reason` | 구간의 시작과 끝 |
| `snapshot` | 닫을 때 찍는다. 문항별 회차·통과 여부와 포기 수 |

시즌이 넘어가는 순간은 하나다. **교재 단위 다시 풀기.** 문항 몇 개만 되돌리는
스태프 리셋은 넘기지 않는다. 바인딩만 된 교재는 시즌 1로 본다.

### 시즌은 회차를 잡아먹지 않는다

회차는 여전히 **시도가 있어야** 열린다. 시즌이 열릴 때 교재 문항마다 회차를
예약해 두지 않는다. 예약하면 시도 0인 껍데기 행이 쌓이고, 집계 컬럼이 시도
기록에서 유도되지 않아 백필로 복구할 수 없게 된다.

그래서 시즌 1을 푸는 중에 선생님이 뒷문항 D를 과제로 내주면, **D는 1차**다.
교재에서 먼저 만나든 과제로 먼저 만나든 처음 붙잡은 것이 1차다. 시즌 안에서 한
번도 열지 않은 문항은 닫을 때 스냅샷에 `untouched`(포기)로만 세고, 다음 시즌에
처음 풀면 1차다.

`student_problem_rounds.season_id` 로 "그 회차가 어느 구간에서 열렸는가"를
남긴다. 채번에는 관여하지 않는다. 누적 회차와 별개로 "이번 시즌에 몇 번째"를
보고 싶으면 이 컬럼으로 세면 된다.

## 화면에서

두 앱 모두 문항 옆에 **2회차부터** 배지를 띄운다. 처음 푸는 문항에 "1회차"를
붙이면 배지가 늘 떠 있어 정보가 되지 않는다.

| 앱 | 위치 | 출처 |
| --- | --- | --- |
| 학생앱 | 교재 커버 상단 (시작일 줄 오른쪽) — `시즌 N` | `student_textbook_seasons_v1.season_no` |
| 학생앱 | 교재 문항 행 / 세트형 헤더 | `student_textbook_page_problems_v2.round_no` |
| 학생앱 | 과제 문항 목록 | `student_list_homework_problems_v1.round_no` |
| 매니저앱 | 우측 시트 채점 카드 | `staff_list_problem_rounds_v1` |
| 매니저앱 | 답지 뷰어 채점 그리드 (구석 표기 + 툴팁) | 같음 |

`round_no` 는 **열린 회차가 있으면 그 번호, 없으면 마지막 회차 번호**다. 한 번도
푼 적 없으면 0.

회차별 시도 타임라인 UI 는 아직 없다. 데이터는
`student_problem_round_history_v1(student_id, crop_id)` 로 지금도 볼 수 있다 —
회차마다 시도 목록(결과·답·채점 주체·소요시간·시각)이 JSON 으로 딸려 온다.

## 미수행 — 나가는 것도 검사다

과제 풀이 화면에서 나가면(뒤로가기·시스템 백) 두 가지가 자동으로 돈다.

1. **잔여 답 일괄 채점.** 페이지를 넘어가도 미채점 답은 화면이 들고 다니므로
   (crop_id 키 상태를 페이지 전환 때 지우지 않는다), 나가는 길에 몇 페이지
   분량이든 한 번에 채점된다.
2. **미수행 기록.** 이번 방문에 채점이 한 번이라도 있었다면, 이 배정에서 시도가
   0인 문항에 `result='skipped'` 시도를 남긴다(`scored_by='self'`,
   `meta.exit_flush=true`). 검사를 받은 것과 같고 주체가 학생일 뿐이다.

`skipped` 는 회차의 `attempt_count` 를 올리지만 통과시키지 않는다. 학생앱은
skipped 만 있는 문항을 오답(X)이 아니라 **빈 문항**으로 다시 보여 준다.
매니저앱 과제 카드의 회차 라벨에는 `미수행 N` 이 함께 붙는다
(`staff_list_problem_rounds_v1.last_result`).

## 선생님 채점도 같은 장부에

선생님의 문항별 O/X 는 `homework_test_grading_*` 에 남지만, 학생앱이 읽는 것은
`learning_attempts` 집계다. 그래서 매니저앱이 채점을 확정(완료·확인)할 때
`staff_record_homework_grading_v1` 을 함께 불러 문항별 시도를
`learning_attempts` + 회차 + 답 캐시(`graded_by='teacher'`)에 남긴다.

- 매핑: correct→`correct`, wrong·blank→`wrong`, not_performed→`skipped`,
  abandoned 는 기록하지 않음.
- 마스터리 완료 판정은 하지 않는다 — 검사 흐름의 단계 전환은
  `homework_record_structured_grading` 계열의 몫이다.
- 답 내용은 종이 풀이라 모르므로 답 캐시의 `last_answer` 는 건드리지 않는다.

이 다리 덕에 검사 후 학생앱은 맞은 문항을 통과로, 틀린 문항만 다시 풀 것으로
보여 준다.

## 과거 기록

마이그레이션에서 기존 `learning_attempts` 를 같은 규칙(정답 통과 / 배정 변경)으로
잘라 회차를 매겼다. 그래서 회차 번호가 어느 날 갑자기 1부터 시작하지 않는다.
백필로 만든 회차에는 `meta.backfilled=true` 가 붙는다.

## 관련 파일

- `supabase/migrations/20260813210000_student_problem_rounds.sql` — 테이블·백필
- `supabase/migrations/20260813211000_learning_attempt_rounds_and_free_practice.sql`
- `supabase/migrations/20260813212000_textbook_round_reset.sql`
- `supabase/migrations/20260813213000_expose_problem_rounds.sql`
- `supabase/migrations/20260814030000_student_textbook_seasons.sql` — 시즌
- `supabase/migrations/20260814050000_teacher_grading_to_learning_attempts.sql`
  — 선생님 채점 다리·미수행 노출
