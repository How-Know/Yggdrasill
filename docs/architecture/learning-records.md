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

- **회차별 출제 부분집합을 어디에 담을지.** 지금은 "정답 시도가 없는 문항"으로
  그때그때 파생한다(테이블 불필요). 선생님이 손으로 조정하게 하려면
  `assignment × homework_item_problem` 연결 테이블이 필요하다.
  문항 하나를 여러 시기에 다시 푸는 것 자체는 `student_problem_rounds` 로
  갈라 놓았다 — `docs/architecture/problem-rounds.md`.
- **통과 판정을 뷰로 둘지 캐시 테이블로 둘지.** 지금은 함수에서 매번 계산한다.
  느려지면 요약 테이블로 옮긴다. 어느 쪽이든 원자료에서 재계산 가능해야 한다
  (기준이 바뀔 게 거의 확실하다).
- **묶음 통과 후 파지 확인.** `RETENTION` 템플릿으로 2주 뒤 표본 몇 문항만
  다시 내는 안. 아직 미결.
- **집 종이 자가채점의 잠정 통과 확정 흐름.** 학생앱 채점은 위 규칙으로 정리됐지만,
  종이로 풀고 집에서 채점한 경우를 학원 검사에서 확정하는 UI 는 아직 없다.

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
