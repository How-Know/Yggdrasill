# 학습 기록 설계 (노출 · 시도 · 신뢰도)

문항이 학생에게 **언제 왜 보여졌고**, **어떻게 풀렸고**, **그 기록을 얼마나 믿을 수 있는지**를
남기기 위한 스키마. 2026-07-25 에 스키마와 쓰기 API 까지 서버에 반영했고,
**기록을 쓰는 주체는 아직 없다. 아이패드 학생앱 작업이 트리거다.**

관련 문서: [`problem-analytics.md`](./problem-analytics.md) (과제 출제 스냅샷 방향)

---

## 1. 왜 이 모양인가

원래 요구는 네 가지였다.

1. 왜 보여줬는지 — 추천 / 선생님 지시 / 스스로 선택
2. 어떻게 풀었는지 — 힌트 / 선생님 도움 / 스스로
3. 어떤 양식이었는지 — 숙제 / 테스트(재시도 가능) / 테스트(단판)
4. 시간이 얼마나 걸렸는지

이걸 한 테이블에 넣지 않고 셋으로 나눴다. 이유는 아래 세 가지다.

**노출과 시도는 다른 사건이다.** "봤지만 못 푼 문항"은 시간 부족 신호이고,
제한시간 테스트에서 어디까지 갔는지는 노출 기록이 있어야만 알 수 있다.
시도만 저장하면 이 정보가 통째로 사라진다.

**"어떤 양식이었는지"는 하나의 enum 이 아니다.** 감독 여부, 정답 접근 가능 여부,
채점 주체, 시간 측정 정밀도가 각각 독립적으로 움직인다. enum 하나로 굳히면
나중에 "무감독인데 자동채점" 같은 조합을 표현할 수 없다. 그래서 축별 사실을
세션에 저장하고, 신뢰도 점수는 거기서 **파생**한다.

**시간은 실측과 추정이 섞인다.** 학원 종이 풀이는 구간 시간만 있고,
아이패드는 문항별 실측이 된다. 두 값을 같은 컬럼에 넣되 출처를 반드시 구분한다.

---

## 2. 테이블

| 테이블 | 역할 | 대응 축 |
|--------|------|---------|
| `learning_sessions` | 한 번의 풀이 자리. 신뢰도를 결정하는 사실 | 3번 |
| `learning_exposures` | 문항이 보여진 사건 | 1번 |
| `learning_attempts` | 실제 풀이 시도 | 2번, 4번 |
| `learning_range_timings` | 종이 풀이의 구간 시간 원자료 | 4번 |
| `learning_exam_templates` | 테스트 유형 정의 | 3번 |
| `learning_reliability_weights` | 신뢰도 축별 가중치 (버전 관리) | — |

정의 위치:
- `supabase/migrations/20260725173000_learning_records_core.sql`
- `supabase/migrations/20260725173500_learning_reliability.sql`
- `supabase/migrations/20260725174000_learning_exam_templates.sql`
- `supabase/migrations/20260725174500_learning_records_api.sql`
- `supabase/migrations/20260725180000_learning_records_homework_link.sql`

### learning_sessions

신뢰도 축(전부 `text` + check 제약):

- `supervision` — `proctored` / `staff_present` / `unsupervised` / `unknown`
- `answer_access` — `blocked` / `available` / `unknown`
- `scored_by` — `auto` / `teacher` / `self` / `mixed` / `unknown`
- `timing_source` — `per_item` / `per_range` / `per_session` / `none`
- `platform` — `student_app` / `kiosk` / `web` / `paper` / `teacher_input` / `unknown`
- `location_kind` — `academy` / `home` / `school` / `other` / `unknown`
- `material_kind` — `db_textbook` / `commercial_textbook` / `problem_bank` / `mixed` / `unknown`
- `time_limit_sec` + `time_limit_enforced` → `strict` / `loose` / `none` 으로 파생

그 외 `retry_policy`(`none` / `single_shot` / `until_correct` / `post_session_retry`),
`session_kind`, `template_id`, 과제·플로우·교재 링크, `elapsed_sec`, `interrupted_sec`.

`reliability_score` / `reliability_tier` / `reliability_version` 은 트리거가 채운다.
직접 쓰지 말 것.

### learning_exposures

`exposure_reason` 이 1번 축이다: `teacher_assigned`, `recommendation`, `self_selected`,
`test_blueprint`, `retry`, `retention_review`, `anchor`, `prerequisite`, `diagnostic`, `unknown`.

핵심 필드:
- `attempted` — 시도로 이어졌는가. 시도 insert 시 트리거가 true 로 바꾼다.
- `is_anchor` — 회차 난이도 보정용 고정 문항인가. (§5 참고)
- `exposure_seq` — 이 학생이 이 문항을 본 n번째. **서버 트리거가 센다.**
- `recommender_key` — 추천 알고리즘 식별자 + 버전. 나중에 추천 성능 평가에 쓴다.
- `homework_item_problem_id` — 과제로 낸 문항 스냅샷 링크. 낸 것 대비 푼 것을 맞출 때.

### learning_attempts

`assist_level` 이 2번 축이다: `none`, `hint`, `solution_peek`, `peer`, `teacher`, `unknown`.

핵심 필드:
- `result` — `correct` / `wrong` / `partial` / `skipped` / `timeout` / `ungraded` / `void`
- `confidence` — `sure` / `unsure` / `guess`. 찍어서 맞춘 것을 걸러내는 용도.
- `duration_ms` + `duration_source`(`measured` / `derived_from_range` / `estimated` / `unknown`)
- `attempt_no` — 학생×문항 누적 회차. **서버 트리거가 센다.**
- `student_level_snapshot` — 시도 시점의 학생 레벨. 문항별 집계에 필수라 사후 조인 불가.
- `reliability_score` / `reliability_tier` — 세션에서 복사한 스냅샷.

### learning_range_timings

학원 종이 풀이용. "10~15p 40분"을 회차별로 받는다.
페이지 범위와 함께 **그 안의 문항 집합(`crop_ids`)** 을 반드시 저장한다.

---

## 3. 신뢰도

점수를 컬럼에 박지 않는다. `learning_reliability_weights` 에 축별 가중치를 두고
**기하평균**으로 파생한다. 축이 하나 나빠도 전체가 붕괴하지 않고,
여러 축이 동시에 나쁘면 확실히 낮아진다.

```sql
-- 가중치를 고친 뒤 과거 데이터까지 재평가
select public.learning_reliability_recompute();
```

v1 가중치로 계산한 실제 값(2026-07-25 검산):

| 상황 | 점수 |
|------|------|
| 집에서 종이 숙제 (무감독 · 정답접근 · 자가채점) | 0.619 |
| 학원 종이, 시중 교재 | 0.835 |
| 학원 종이, DB 편집 교재 | 0.852 |
| 집 아이패드 자유 풀이 | 0.859 |
| 학원 아이패드 데일리 30분 | 0.967 |
| 월간 감독 시험 | 0.987 |

`reliability_tier` 구간: `high` ≥ 0.90, `medium` ≥ 0.78, `low` ≥ 0.65, 그 외 `very_low`.

**낮은 신뢰도 데이터도 버리지 않는다.** 실력 추정에서 제외할 뿐,
학습량·성실도·문항 노출 표본으로는 그대로 쓴다.

---

## 4. 테스트 유형

`learning_exam_templates` 에 학원별로 시드된다. 새 학원 생성 시 트리거가 자동 생성.

| code | 용도 | 규칙 |
|------|------|------|
| `DAILY30` | 매일 30분 가벼운 테스트 | 1800초 강제, 종료 후 오답 재도전 |
| `MONTHLY` | 월간 실전 시험 | 4800초 강제, 30문항, 감독, 단판 |
| `FREEPLAY` | 자유 풀이 | 제한 없음, 맞출 때까지 |
| `RETRYCLINIC` | 지연 오답 재도전 | 3일 뒤 |
| `RETENTION` | 파지 확인 | 14 / 28 / 56일 뒤 |
| `PREREQ` | 선수지식 점검 | 300초, 5문항 |
| `POWER` | 시간 무제한 대조 테스트 | 제한 없음 |
| `DIAG` | 진단 · 배치 | 900초, 적응형 |
| `ACADEMY_PAPER` | 학원 종이 풀이 | `timing_source = per_range` |
| `HOME_PAPER` | 집 종이 숙제 | 학습량 전용 (`volume_only`) |

`blueprint` 는 문항 구성 비율이다. `DAILY30` 기본값:

```json
{"new": 0.6, "retention": 0.2, "prerequisite": 0.1, "anchor": 0.1}
```

**시험 종류를 늘리기보다 이 비율로 흡수하는 것이 원칙이다.**
매일 30분 + 월간 + 자유 + 숙제면 학생 부담이 이미 적지 않다.
파지·선수지식·난이도 보정은 전부 데일리 구성 안에 자리가 있다.

---

## 5. 측정할 때 조심할 것

합의된 판단들이다. 이 영역을 고칠 때 다시 뒤집지 말 것.

**앵커 문항은 소급 생성이 불가능하다.** 데일리가 매번 다른 문항으로 구성되면
점수가 올랐을 때 실력이 는 건지 그날 문제가 쉬웠던 건지 구분할 수 없다.
이미 통계가 쌓인 공통 문항을 매 회차 고정으로 섞고 `is_anchor = true` 로 표시한다.
월간 시험에도 같은 장치를 넣어야 월별 비교가 의미를 갖는다.

**자유 풀이(`FREEPLAY`)는 실력 추정에 쓰지 않는다.** 학생이 시작 시점·단원·중단
시점을 모두 스스로 정하므로 자기선택 편향이 크고 정답률이 과대추정된다.
학습량 지표와 문항 통계 표본 확대로만 쓴다. 대신 중단 지점을 기록하면
"어느 문항에서 포기하는가"라는 난이도 신호를 얻는다.

**구간 시간 균등 분배는 표본이지 정답이 아니다.**
`learning_distribute_range_timing()` 은 (경과 − 중단) ÷ 문항수로 나눠
`duration_source = 'derived_from_range'` 를 붙인다. 정밀도를 올리려면
구간을 잘게 끊고(10~15p 한 덩어리보다 10~11, 12~13), 중단 시간을 반드시 기록한다.
구간이 회차마다 달라지면 나중에 최소제곱으로 문항별 시간을 역산할 수 있다.
그래서 `crop_ids` 원자료를 버리지 않는다.

**속도와 정확도는 교환된다.** 제한시간 테스트만 있으면 "시간이 부족한 것"과
"몰라서 못 푸는 것"이 섞인다. `POWER`(무제한) 세션을 가끔 돌려 대조군을 만든다.

**당일 재시도와 지연 재시도는 다른 것을 잰다.** 당일은 단기 기억 확인(학습용),
3일 뒤 재시도가 이해 확인(측정용)에 가깝다. `RETRYCLINIC` 의 `delay_days` 참고.

---

## 6. 쓰기 API

클라이언트는 테이블에 직접 쓰지 않는다. 회차 채번, 신뢰도 스냅샷, 교재·단원
비정규화가 전부 서버 트리거에서 채워져야 하기 때문이다. 아래 RPC 만 호출한다.

```
learning_start_session(student_id, template_code, session_kind, overrides jsonb) -> uuid
learning_log_exposures(session_id, items jsonb) -> jsonb   -- exposure_id 매핑 반환
learning_log_attempts(session_id, items jsonb)  -> jsonb
learning_finish_session(session_id, status, elapsed_sec, interrupted_sec) -> jsonb
learning_record_range_timing(...) -> uuid
learning_distribute_range_timing(range_id, overwrite) -> int
```

예시:

```sql
select public.learning_start_session(
  '<student_id>', 'DAILY30', null,
  '{"location_kind":"academy","book_id":"<book>","grade_label":"확률과 통계"}'::jsonb
);

select public.learning_log_exposures('<session_id>', '[
  {"crop_id":"<crop>","exposure_reason":"recommendation","recommender_key":"weakness_v1"},
  {"crop_id":"<crop2>","exposure_reason":"anchor","is_anchor":true}
]'::jsonb);

select public.learning_log_attempts('<session_id>', '[
  {"crop_id":"<crop>","result":"correct","assist_level":"none",
   "confidence":"sure","duration_ms":45000}
]'::jsonb);
```

권한: 학원 스태프(`memberships`) 또는 본인 학생 계정(`student_app_accounts`).
RLS 는 스태프 전체 + 학생 본인 읽기만 허용하고, 쓰기는 `security definer` RPC 를 거친다.

**출제한 문항은 풀지 않았더라도 전부 `learning_log_exposures` 로 남긴다.**
이걸 빼면 노출 대비 시도 비율이 계산되지 않는다.

---

## 7. 분석 뷰

| 뷰 | 내용 |
|----|------|
| `learning_item_stats` | 문항별. 노출 사유 분포, 첫 시도 정답률, 신뢰 구간 정답률, 중앙 소요시간, 평균 학생 수준 |
| `learning_student_item_stats` | 학생×문항. 몇 번 보고 몇 번 풀고 몇 번째에 맞췄는가 |
| `learning_student_unit_stats` | 학생×단원. 취약점 자동 추천의 입력 |
| `learning_session_summary` | 세션. 노출 대비 시도(제한시간 안에 어디까지 갔는지) |

모두 `security_invoker = true` 라 RLS 가 그대로 적용된다.

앱 화면에서 원시 로그를 스캔하지 말 것. 뷰가 느려지면 요약 테이블이나 배치로 옮긴다
(`problem-analytics.md` 의 운영 원칙과 동일).

---

## 8. 아직 안 한 것

- **기록 주체 없음.** 학생앱/학습앱/매니저앱 어디서도 아직 RPC 를 부르지 않는다.
- **백필 안 함.** `student_textbook_answer_records` 는 문항별 최종 상태만 있고
  회차별 이력이 없다. 여기서 이벤트를 만들면 가짜 세션이 생기므로 두 테이블을
  당분간 공존시킨다. 새 기록이 쌓인 뒤 읽기 경로를 옮긴다.
- **추천 알고리즘 없음.** `exposure_reason = 'recommendation'` 과 `recommender_key`
  자리는 있으나 추천 엔진 자체는 미구현.
- **파지·앵커 선별 로직 없음.** `blueprint` 비율만 정의돼 있고, 실제로 어떤 문항을
  뽑을지는 미구현.
- **가중치 재보정 안 함.** v1 은 손으로 정한 값이다. 실측이 쌓이면 다시 맞춘다.

---

## 9. 마스터리 루프 (교재 묶음 반복 과제)

학원에서 가장 흔한 과제 형태. "교재 10~15p 풀어와"를 내고, 묶음 안 문항을 전부
통과할 때까지 회차를 반복한다. 학원에서 다 못 하면 집 숙제로 넘어간다.

기존 방식은 페이지 단위였다. `homework_assignments.progress`(0~150 퍼센트)를
선생님이 눈으로 어림해 넣고, `homework_items.check_count` 로 검사 횟수를 셌다.
마이그레이션 교재는 `homework_item_problems` 에 문항 스냅샷이 있으므로
문항 단위로 전환한다.

가장 큰 이득은 진행률 정확도가 아니라 **오답만 재출제할 수 있게 되는 것**이다.
회차마다 반복 분량이 줄어든다.

### 확정된 규칙 (2026-07-26)

- **적용 범위는 마이그레이션 교재뿐.** 비마이그레이션 교재는 기존 퍼센트 방식을
  그대로 두고 이 기능을 켜지 않는다. 두 방식을 억지로 통일하지 않는다.
- **1회차는 전원 자력 풀이가 학원 정책이다.** 답안 미입력은 오답 처리.
- **통과 = 정답.** 2회차 이후 도움 여부는 통과 판정에 반영하지 않는다.
- **재출제는 오답만이 기본**, 전체 재출제도 선택 가능.
- **집 자가채점은 잠정 통과**, 학원 검사에서 확정. 통계 신뢰도는 낮게 반영
  (`HOME_PAPER` 세션, 0.619).
- **탈출구(자동 면제)는 두지 않는다.** 통과할 때까지 반복한다. 학원 과제는
  결국 도움을 받아서든 혼자서든 종료되므로 실제 무한 루프는 생기지 않는다.
- **원본 묶음은 불변.** 회차는 그 부분집합이다. 현재 재출제 로직이 같은
  `homework_item` 에 새 `homework_assignments` 행을 달고 `repeat_index` 만
  올리므로 이 성질은 이미 성립한다.

### 주의

**미입력과 오답을 원자료에서 구분한다.** 정책상 둘 다 미통과지만
"안 풀었다"(`skipped`)와 "풀었는데 틀렸다"(`wrong`)는 완전히 다른 신호다.
합쳐 저장하면 되살릴 수 없다. 통과 판정 단계에서만 둘 다 미통과로 취급한다.

**1회차 첫 시도는 정책상 무보조다.** 따라서
`learning_item_stats.first_attempt_correct_rate` 가 문항 난이도의 정직한
추정치가 된다. 단 1회차 검사 전까지 정답·해설이 차단돼 있어야 성립하므로
(`answer_access = 'blocked'`), 집에서 해오는 경우는 이 보장이 깨진다.

**`assist_level` 은 당분간 `unknown` 이다.** 검사하는 사람과 도움을 주는 사람이
달라서 검사자는 알 수 없다. 검사 UI 에 노출하지 않는다. 나중에 워치로 기록해
사후에 채우고 조회만 가능하게 한다. **절대 `none` 으로 기본값을 채우지 말 것.**
모르면 `unknown` 이다. 워치 이벤트를 나중에 시도에 매칭하려면 세션의
`started_at` / `ended_at` 이 정확해야 한다.

**채점 확정은 append-only 규칙의 예외다.** 집에서 자가채점한 결과를 학원 검사에서
확정하는 흐름은 같은 시도의 결과를 나중에 채우는 것이지 재시도가 아니다.
같은 `learning_attempts` 행을 UPDATE 하고 `scored_by` / `scored_at` 을 갱신한다.
새 행을 만들면 시도 횟수가 부풀어 문항 통계가 망가진다.
**재시도는 새 행, 채점은 같은 행.**

**`progress` 는 계속 채운다.** 점수 서비스, 워치, 그룹 요약이 이미
`homework_assignments.progress` 를 읽는다. 문항 기반으로 바꾸더라도 통과율에서
자동 계산해 넣어야 기존 화면이 깨지지 않는다.

**남은 문항은 개수보다 구성을 보여준다.** 24문항 중 4개가 남았을 때 그게 전부
최고난도면 사실상 끝난 것이고, 기초 문항이면 심각한 신호다. crop 의 `label`
(상/중/하)로 난이도 분포를 함께 보여준다.

### 1차 구현 (2026-07-26)

**출제.** 과제 다이얼로그의 "단계"(원본/1~3단계)가 이제 저장된다.
`homework_item_problems.source_stage` 에 문항 단위로 들어간다 — 한 과제 안에
원본과 변형이 섞일 수 있기 때문이다. 값은 `unitMappings[].problemStage` 로
흘러가므로 `HomeworkStore` 에 새 배선을 넣지 않았다. 변형 문항 파이프라인이
아직 없어 1~3단계는 UI 에서 비활성화해 뒀다.

**통과 경로는 두 가지뿐이다.**

1. **선생님 검사** — 채점 모드의 완료 버튼. 기존 흐름 그대로다
   (`pending_complete` → `homework_confirm` → 사이클 4→1 에서 `homework_complete`).
   조건 검사를 붙이지 않았다. 선생님 재량이 우선이다.
2. **학생앱 전원 정답** — `student_complete_homework_group_if_mastered`.
   배정 문항을 전부 맞혔을 때만 완료시키고, 아니면 아무것도 바꾸지 않고 사유만
   돌려준다. 판정은 전적으로 서버가 한다.

**통과 판정 근거는 `learning_attempts` 다.** `student_textbook_answer_records` 는
`(student_id, crop_id)` 유일키라 과제와 회차를 구분하지 못한다. 최신 상태 캐시로만
쓰고 마스터리 판정에는 절대 쓰지 않는다.

**자가표시(`self`)도 통과로 인정한다.** 그림·서술형처럼 자동 채점이 불가능한
문항이 몇 개 안 되고, 엔진이 좋아지면서 줄어들 예정이다. 대신 자동채점과 **세션을
분리**한다 — 신뢰도가 세션 단위로 계산되므로 한 세션에 섞으면 자동채점 기록까지
같이 깎인다. 분리해 두면 `trusted_*` 집계에서 자가표시만 빠지고, 나중에 그림 문항을
따로 모아 테스트할 때 그 기록만 골라낼 수 있다.

**오답만 재출제**는 학생앱 진입 시점에 적용된다. 통과한 문항은 스코프에서 빠지고
`rawPages` 도 그에 맞춰 좁혀진다.

관련 함수: `student_list_homework_problems_v1`,
`student_homework_group_mastery_v1`, `learning_log_homework_attempt`.
Edge Function `student_textbook_grade` 에 `homework_group_id` 를 함께 보내면
배정 문항으로 인식해 기록한다.

### 아직 정하지 않은 것

- ~~회차별 출제 부분집합을 어디에 담을지.~~ → 2026-10-22 결정. 아래 "숙제 배정 문항".
  선생님이 묶음을 손으로 조정하는 UI 는 아직 없다.
  문항 하나를 여러 시기에 다시 푸는 것 자체는 `student_problem_rounds` 로
  갈라 놓았다 — `docs/architecture/problem-rounds.md`.
- **통과 판정을 뷰로 둘지 캐시 테이블로 둘지.** 지금은 함수에서 매번 계산한다.
  느려지면 요약 테이블로 옮긴다. 어느 쪽이든 원자료에서 재계산 가능해야 한다
  (기준이 바뀔 게 거의 확실하다).
- **묶음 통과 후 파지 확인.** `RETENTION` 템플릿으로 2주 뒤 표본 몇 문항만
  다시 내는 안. 아직 미결.
- **집 종이 자가채점의 잠정 통과 확정 흐름.** 학생앱 채점은 위 규칙으로 정리됐지만,
  종이로 풀고 집에서 채점한 경우를 학원 검사에서 확정하는 UI 는 아직 없다.

### 숙제 배정 문항 (2026-10-22)

`homework_assignments` 행 하나가 숙제 한 번이다. 그 배정에 나간 문항을
`homework_assignment_problems` 에 고정한다. 문항별 통계("이 문항이 숙제로 몇 번
나갔나", "그날 어떤 문항이 나갔나")의 원자료다.

- **기준**: 배정 시각까지 그 과제 문항(`homework_item_problems`, 제외 문항 빼고)에
  정답 기록이 없는 문항. 학생앱 오답만 재출제와 같은 기준이다. 100문항 중 60문항을
  맞힌 뒤 나간 숙제는 40문항으로 기록된다.
- **쓰기**: `homework_assignments` AFTER INSERT 트리거
  (`_homework_assignment_sync_problems`). 배정을 만드는 경로가 앱·여러 RPC 로 흩어져
  있어 트리거 하나로 모두 잡는다. 앱은 쓰지 않는다.
- **스냅샷 재생성**: 과제를 고치면 `homework_item_problems` 를 지우고 다시 만든다
  (문항 id 가 바뀐다). 그래서 `crop_id` 를 함께 저장하고, 문항 id 는 `on delete set null` 이다.
  새 스냅샷이 들어오면 **아직 한 번도 검사하지 않은**(`status = 'assigned'`) 배정만
  다시 맞춘다. 검사가 끝난 배정은 당시 묶음을 그대로 둔다.
- **도입 전 배정**: 도입 시점에 검사 전이던 배정만 배정 시각 기준으로 채웠다
  (`source = 'backfill'`). 이미 검사한 배정은 채우지 않는다.
- **노출 기록과의 관계**: `learning_exposures`(`teacher_assigned`)는 채점 세션에서
  남는 "보여 줬다" 기록이고 세션이 필수다. 배정 기록은 이 테이블이 맡는다.

- **알림장 숙제 리스트**: 하원 전 미리보기에는 아직 배정이 없으므로
  `staff_homework_open_problem_counts_v1` 로 같은 기준의 남은 문항 수를 받아 찍는다.
  예상시간은 과제별 추천 시간 × 남은 문항 비율이다. 문항 스냅샷이 없는 과제는 예전처럼
  전체 분량을 쓴다.

정의: `supabase/migrations/20261022100000_homework_assignment_problems.sql`,
`20261022110000_homework_open_problem_counts.sql`

---

## 10. 이 영역을 고칠 때

1. **이벤트 테이블은 append-only 로 다룬다.** 재시도는 UPDATE 가 아니라 새 행이고
   `attempt_no` 로 구분된다. **단 채점 확정은 예외다** — 이미 기록된 시도의 결과를
   나중에 확정하거나(자가채점 → 교사 확정) `assist_level` 을 사후에 채우는 것은
   같은 행을 고친다. 재시도는 새 행, 채점은 같은 행.
2. **회차·신뢰도 컬럼을 클라이언트가 계산하지 않는다.** 반드시 트리거에 맡긴다.
3. **축을 enum 하나로 합치자는 제안은 거절한다.** §1 의 이유가 그대로 유효하다.
4. **신뢰도 점수를 하드코딩하지 않는다.** 가중치 테이블 + 버전으로만 바꾼다.
5. 새 테스트 유형이 필요하면 먼저 `DAILY30` 의 `blueprint` 로 흡수할 수 없는지 본다.
6. 광범위한 변경 전에는 사용자에게 2~3개 선택지를 제시한다. 방향은 바뀔 수 있다.

---

## 11. 쌓이는 기록: 퇴원 삭제와 장기 보관

학습 기록은 한 학원 기준으로 월 수만 행씩 늘어난다(2026-09: `learning_attempts`
월 5.2만, `homework_test_grading_attempt_items` 월 7.4만). 오래 다닌 학생일수록
기록이 많고, 퇴원 시 한 번에 지우면 요청 시간 제한(8초)을 넘는다.

### 퇴원은 두 단계다 (2026-09-29)

1. **`withdraw_student`** — 아카이브를 만들고 `students.withdrawn_at` 을 찍는다.
   `students` RLS 가 퇴원 학생을 숨기므로 모든 스태프 화면에서 즉시 사라진다.
   화면을 움직이는 행(시간표, 보강, 오늘 이후 예정 출석, M5 연결, 학생앱 로그인)은
   이때 바로 지운다.
2. **정리(purge)** — `_purge_withdrawn_student_step` 이 말단 테이블부터 학생 기준으로
   500행씩 지우고, 마지막에 `students` 행을 지운다. 앱이 퇴원 직후 한 번 돌리고
   (`purge_withdrawn_student`), 남은 분량은 cron `purge-withdrawn-students` 가 매분
   마무리한다. 결과는 예전 한 번 삭제와 같다(`homework_items` 는 `student_id` 만 null).

정의: `supabase/migrations/20260929100100_student_withdraw_and_purge.sql`

### 새 테이블을 만들 때 지킬 것

나중에 기록 테이블을 기간별로 나눠 저장(월 단위 파티션)할 수 있게 미리 지키는 규칙이다.
**파티션은 아직 하지 않는다.** `learning_attempts` 가 수백만 행이 되거나 학생별 조회가
느려질 때 `learning_attempts`, `learning_exposures`,
`homework_test_grading_attempt_items` 부터 검토한다.

1. **학생 기준 기록 테이블은 `student_id`(not null, `on delete cascade`),
   `academy_id`, 기록 시각(not null)을 둔다.** 삭제는 학생 기준, 파티션은 시각 기준이다.
2. **기록 행을 id 하나로 가리키는 FK 를 새로 만들지 않는다.** 파티션 테이블의 기본키는
   (id, 시각)이 되므로 id 단독 FK 를 걸 수 없다. 필요하면 FK 없이 id 만 저장한다.
   기존 예외: `learning_attempts.exposure_id`, `learning_attempts.round_id`,
   `learning_exposures.round_id`, `learning_*.session_id`. 파티션할 때 같이 정리한다.
3. **FK 컬럼마다 그 컬럼으로 시작하는 index 를 만든다.** 선택 컬럼이면
   `where col is not null` 부분 index 로 충분하다. `academy_id` 로 시작하는 복합
   index 나 다른 조건의 부분 index 로는 삭제 시 역참조를 못 찾아 테이블 전체를 훑는다
   (2026-09 실측: `learning_attempts.exposure_id` 하나로 학생 1명 삭제에 39초).
4. **학생 기준으로 큰 테이블을 추가하면 퇴원 정리 목록에 넣는다.**
   `_purge_withdrawn_student_step` 의 `v_tables` 에 말단부터 순서를 맞춰 추가한다.
5. **쓰기는 서버 함수로만 한다(§6).** 저장 구조를 바꿔도 앱을 고치지 않게 하기 위해서다.
6. **화면은 원시 기록을 훑지 않는다(§7).** 통계 화면이 생기면 요약 테이블을 먼저 만든다.

---

## 12. 수업 기록 요약 (알림장 "오늘의 학습 기록")

수업 한 번(출결 1행)에 대해 숫자만 낸다. 정상/확인/주의 같은 판정은 숫자가 충분히
정확해진 뒤 따로 정한다. 지금은 만들지 않는다.

### 저장 위치

새 수업 테이블을 만들지 않는다. 하원 때 출결마다 생기는
`student_class_session_snapshots` 에 요약 컬럼을 붙이고, Flow별 진도만 자식 테이블
`student_class_session_snapshot_flows` 에 둔다.

- 기존 수행률 컬럼(`performance_rate`, `plan_details`, `completed_problem_count` 등)은
  하원 시점 값으로 고정된다. 이름이 비슷해도 `completed_problem_count` 는 "수업 중
  선생님이 완료 처리한 수"라서 아래 숫자와 뜻이 다르다.
- 요약 컬럼과 Flow 행은 원자료에서 **다시 계산할 수 있다**. 하원 트리거, 하원 뒤
  알림장 출력, `staff_refresh_lesson_record_v1` 에서 갱신된다.
- 하원 전에는 스냅샷이 없으므로 `staff_lesson_record_v1` 이 같은 계산을 저장 없이 돌려준다.
- 과거 알림장 재열람은 계산 원자료를 다시 조합하지 않는다. 정상 하원 확정 뒤
  `student_class_session_todo_sheet_snapshots` 에 당시 렌더링 의미 데이터(JSON)를
  회차당 한 번 저장한다. 미리보기는 저장하지 않고, 최초 확정본은 이후 과제 완료·수정이나
  계산식 변경으로 덮어쓰지 않는다. PDF와 로고 바이너리는 저장하지 않는다.

계산 원본은 `_lesson_record_compute` 하나다. 앱에서 다시 계산하지 않는다.
정의: `supabase/migrations/20261004120000_lesson_record_summary.sql`

### 시간 범위

수업 시간 = 등원(`arrival_time`, 없으면 `class_date_time`) ~ 하원(`departure_time`,
하원 전이면 지금). 수업일은 `class_date_time` 의 한국 날짜다.

### 숫자 정의

| 컬럼 | 뜻 |
|------|-----|
| `assignment_total` / `assignment_completed` | 오늘 수업 과제 그룹 수 / 그중 모든 과제가 완료된 그룹 수 |
| `homework_total` / `homework_completed` | 오늘 검사 대상 숙제 그룹 수 / 그중 진행률 100% 이상 |
| `solved_problem_count` | 오늘 푼 문항 수 |
| `first_try_correct_count` | 푼 문항 중 회차 첫 채점이 수업 시간 안이고 정답인 수(바로 맞힘). 알림장은 푼 문항 대비 정답률로 보인다 |
| `passed_problem_count` / `avg_tries_to_pass` | 푼 문항 중 하원까지 정답이 나온 수 / 그 문항의 회차 첫 채점부터 정답까지 채점 수 평균(미수행 제외, 이전 수업 포함) |
| `correction_required_count` / `correction_success_count` | 오늘 채점한 오답 문항 수 / 그중 하원까지 고친 수. 알림장 큰 숫자는 앞의 수, 수정률은 둘의 비율 |
| `max_correction_tries` | 오늘 고친 문항의 회차 첫 채점부터 정답까지 채점 수 중 최댓값 |
| `homework_problem_total` / `homework_problem_solved` | 오늘 첫 검사한 숙제 배정(등원 전 배정)에 고정된 문항 수 / 그중 배정 뒤 첫 기록이 맞음·틀림·부분인 수. 알림장 "숙제로 푼 문항" |
| Flow 행 | 오늘 수업 계획이 있으면 그 과제, 계획이 없으면 이번 수업 시간에 손댄 과제(수행 시간·완료·채점)가 걸린 Flow·교재별 진도 |

- **과제 분모**: 목표 제시 스냅샷(`attendance_records.homework_plan_snapshot_groups`)이
  있으면 그 그룹들이다. 완료 시각이 스냅샷 이후~하원 사이여야 한다. 없으면 수업별 과제
  계획의 오늘(`in_class`) 과제를 쓴다. 하원 때 오늘 과제는 숙제로 이월되어 계획 행이
  바뀌므로, 하원 뒤에는 스냅샷의 `plan_details` 를 읽는다. 근거는 `assignment_basis`.
- **숙제**: 알림장 검사내역과 같은 포함 기준과 진행률 계산을 쓴다. 포함 기준은 오늘
  마감, 오늘 검사가 그 배정의 **첫 검사**(결석분 등), 미리 해온 그룹 과제다. 이미 검사한
  배정을 오늘 다시 채점한 과제는 숙제가 아니다. 자발 추가검사만 있는 그룹은 분모에서
  뺀다. **확인 검사 없이 오늘 완료된 과제는 100%로 본다**(알림장 검사내역 Dart 코드도
  같은 기준). 완료되어 보관된 그룹도 한 그룹으로 센다. 활성 그룹만 묶으면 하위과제마다
  한 건이 된다.
- **숙제로 푼 문항**: 분모는 `homework_assignment_problems` 에서 온다. 미수행(`skipped`)은
  풀지 않은 것이고, 미풀이(blank)는 `wrong` 으로 저장되므로 푼 것으로 셈한다.
  숙제 안 함·남김 검사는 검사 뒤 채점이 수업 풀이이므로 검사 전 기록(학생앱 등)만 본다.
  문항 기록이 있는 배정이 하나도 없으면 null("기록 없음"), 오늘 숙제가 없으면 "없음".
  (2026-10-22 v5)
- **알림장 문항 당 진행속도**: 머문 시간(등원~하원) ÷ 완료 문항. 완료 문항은
  `passed_problem_count`다. 오늘 고친 문항은 이 완료 문항에 이미 들어 있어 다시
  더하지 않는다. 저장 컬럼은 아니고 알림장에서만 나눈다.
- **푼 문항**: 숙제 검사는 숙제로 배정된 뒤 처음 하는 검사만 뜻이 있다.
  - 여기서 숙제는 **등원 전에 이미 배정된 과제**다. 수업 중 과제를 채점하면서
    `homework_assignments`/검사 행이 생겨도 숙제 첫 검사로 보지 않고 첫 채점부터 센다.
  - 수업 과제 문항, 그리고 숙제도 수업 계획도 아니지만 수업 시간에 채점한 과제 문항은
    수업 시간에 채점된 것을 모두 센다.
  - 오늘 숙제 검사를 한 과제의 문항은 오늘 첫 선생님 채점(집에서 푼 것 확인)을 빼고,
    그 뒤 다시 채점한 것만 센다. 예전 오답·미수행 기록은 보지 않는다. 숙제 안 함·남김
    검사는 문항 기록이 없으므로 그 뒤 채점은 수업 풀이로 센다.
  - 채점 저장은 시트 전체를 다시 기록한다. 같은 배정 문항에서 직전 기록도 정답이었던
    정답 기록은 다시 저장한 것으로 보고 세지 않는다. 오답을 그대로 다시 저장한 것은
    구분할 수 없어 센다.
  - 맞음/틀림/부분만 센다. 미풀이(blank)는 `wrong`, 미수행은 `skipped` 로 저장된다.
  (2026-10-05 v3, `20261005180000_lesson_record_homework_check_rule.sql`)
- **수정한 문제 / 수정률** (2026-10-27 v6): 오늘 등원~하원 사이에 채점이 있는 오답
  문항이다. 이번 수업에서 처음 틀린 문항과, 지난 수업에서 틀리고 이번 수업 시작 전까지
  정답이 없던 문항을 함께 센다. 지난 수업에 이미 정답으로 끝난 문항은 오늘 다시
  채점해도 세지 않는다. 숙제 검사에서 틀린 문항도 포함한다. 큰 숫자는 이 문항 수고,
  수정률은 그중 하원까지 정답이 나온 비율이다. 빈칸은 `wrong` 이라 오답에 들어가고,
  미수행(`skipped`)은 빠진다.
- **최대 수정 횟수**: 오늘 고친 문항마다 회차 첫 채점부터 정답까지 채점 수(미수행 제외,
  이전 수업 포함, 정답 채점 포함)를 세고 그 최댓값을 낸다. 한 번 틀리고 바로 고치면 2회다.
  평균 수정 횟수는 그대로 오늘 정답으로 끝낸 문항 전체의 평균이다.
- **문항 기록 범위**(`problem_record_coverage`): 대상 과제 중 문항 단위 기록
  (`homework_item_problems`)이 있는 비율이다. 마이그레이션되지 않은 교재만 있으면
  `none` 이고, 문항 숫자 네 개는 모두 null 이다. 0 이 아니라 "기록 없음"이다.
- **Flow 진도 %**: 행 단위는 (Flow, 교재)다. 오늘 수업 계획이 있으면 그 과제만 넣고,
  계획이 없으면 등원~하원 사이에 수행 시간이 겹치거나 완료·채점이 있는 과제를 넣는다.
  지금 켜져 있는 대기 과제 전체는 넣지 않는다. 교재는
  `homework_items.book_id` 이고, 문항 단위로 마이그레이션된 교재만 % 를 낸다. 완료 기준은
  학생앱 교재 카드와 같다(정답 기록 또는 선생님 완료 처리). 등원 전 완료
  (`textbook_completed_before`)와 하원까지 완료(`textbook_completed_problems`)를 따로 두어
  "오늘 늘어난 만큼"을 구분한다. 완료 시각은 정답의 `first_correct_at`, 선생님 완료의
  `completed_at`(없으면 `confirmed_at`)이며, 시각이 없는 옛 기록은 등원 전 완료로 본다.
  (2026-10-04 v2, `20261004150000_lesson_record_flow_books.sql`)

### 지키는 것

- 없는 데이터를 추정하지 않는다. 계산할 수 없으면 null 이고, 화면은 "기록 없음"으로 보인다.
- 판정 기준을 넣을 때는 이 절의 숫자를 바꾸지 말고 판정 컬럼이나 뷰를 따로 더한다.

## 결정 로그

- **2026-07-25** — 초안 설계 확정 및 서버 반영. 노출/시도 분리, 신뢰도 파생 모델,
  템플릿 10종 시드, 쓰기 RPC, 분석 뷰 4종. 기록 시작은 아이패드 학생앱 작업 시점으로 유예.
- **2026-07-26** — 마스터리 루프(§9) 규칙 확정. 마이그레이션 교재 한정, 오답만
  재출제 기본, 자동 면제 없음, 집 자가채점은 잠정 통과. `assist_level` 은 워치
  연동 전까지 `unknown` 유지. 채점 확정을 append-only 예외로 명시.
- **2026-07-26** — 마스터리 루프 1차 구현·배포. `source_stage` 추가, 학생용 문항
  조회/통과 RPC, `learning_log_homework_attempt`, 학생앱 과제 스코프 풀이 진입.
  통과 경로를 선생님 검사와 학생앱 전원 정답 두 가지로 제한. 자가표시는 통과로
  인정하되 세션을 분리해 통계에서 걸러지게 함.
- **2026-09-29** — 퇴원을 두 단계(퇴원 표시 → 나눠 삭제 + cron)로 분리하고, 학생 삭제
  경로의 FK index 를 보강. 월 단위 파티션은 보류하고 §11 의 새 테이블 규칙만 확정.
- **2026-10-04** — 수업 기록 요약(§12) 1단계. 새 수업 테이블 대신 하원 스냅샷을 확장하고
  Flow 자식 테이블을 추가. 요약 숫자는 다시 계산 가능, 기존 수행률은 고정. 과제 분모는
  목표 제시 스냅샷 우선, 수정 대상은 오늘 처음 틀린 문항만. 확인 없이 오늘 완료한 숙제는
  100%(알림장 검사내역도 같이 변경). 판정 기준은 보류. 화면(2단계)은 아직 없음.
- **2026-10-05** — "푼 문항"과 숙제 분모를 "숙제였는지"로 가름(v3). 숙제 검사는 배정 뒤
  첫 검사만이고, 이미 검사한 배정을 다시 채점한 과제는 수업 과제처럼 센다. 다시 낸 오답
  숙제도 첫 검사는 세지 않는다(이전 "숙제 오답 다시 풀기" 규칙 대체). 다시 저장한 정답은
  세지 않는다. 알림장 검사내역의 "오늘 검사" 포함도 첫 검사로 좁힘. 알림장의 "정상 완료"를
  정답률(바로 맞힘 ÷ 푼 문항)로 바꾸고, 완료 문항의 평균 시도(회차 전체 기준)를 더함
  (`20261005193000_lesson_record_tries_and_accuracy.sql`).
- **2026-10-05** — 학습 Flow는 오늘 수업 계획이 있으면 그 과제만 본다. 계획이 없으면
  이번 수업 시간에 손댄 과제(수행 시간, 완료, 채점)를 본다. 대기 중인 과제 전체는
  넣지 않는다 (`20261005223000_lesson_record_flow_completed_in_window.sql`).
- **2026-10-10** — 숙제 첫 검사를 등원 전에 이미 생성된 배정의 검사로 한정. 수업 중
  과제 채점으로 생성된 배정·검사 행은 첫 채점부터 오늘 푼 문항으로 센다
  (`20261010140000_lesson_record_preclass_homework.sql`).
- **2026-10-17** — 알림장 숙제 수는 보관된 그룹도 한 건으로 센다. 활성 그룹만 묶으면
  완료된 그룹이 하위과제마다 갈라진다
  (`20261017150000_lesson_record_homework_archived_groups.sql`).
  알림장 문항 당 진행속도는 머문 시간 ÷ 완료 문항(`passed_problem_count`)이다.
- **2026-10-22** — 하원 확정 뒤 알림장 의미 payload를 회차당 최초 한 번 고정한다
  (`20261022002000_todo_sheet_snapshots.sql`). 미리보기는 저장하지 않으며, 과제 현황에서
  저장된 payload로 과거 알림장을 다시 렌더링한다. 적용 전 회차는 백필하지 않는다.
- **2026-10-22** — 숙제 배정을 문항 단위로 기록한다(§9 "숙제 배정 문항",
  `20261022100000_homework_assignment_problems.sql`). 배정 트리거가 정답 없는 문항을
  고정하고, 검사 전 배정만 스냅샷 변경을 따라간다. 알림장 학습 기록에
  "숙제로 푼 문항"(`homework_problem_total`/`homework_problem_solved`, v5)을 더했다.
  새 기록 테이블과 알림장 확정본을 퇴원 정리 목록에 넣었다.
- **2026-10-27** — 알림장 "수정한 문제"는 오늘 채점한 오답 문항 수다. 지난 수업에서 틀리고
  아직 정답이 없던 문항도 오늘 채점이 있으면 센다. 수정률은 그중 하원까지 고친 비율이고,
  최대 수정 횟수는 오늘 고친 문항의 정답까지 채점 수 최댓값이다
  (`20261027170000_lesson_record_correction_pool.sql`, v6).
