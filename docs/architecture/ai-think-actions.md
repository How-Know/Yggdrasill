# Think 작업 도구: 제안 → 승인 → 실행 (단일 작업 화면)

Think 채팅 한 화면에서 코드 조사, 코드 수정, 대화 분류, 삭제를 요청하고 결과까지 본다.
AI는 **제안만** 하고, 실제 변경은 사용자가 채팅 안 카드에서 승인한 뒤에만 일어난다.

**상태: 2026-09-30 배포. Think ↔ Cursor 조율(§4.3)은 2026-10-01 배포. 조율본 질문은 2026-10-02 구현.** 관련: [`ai-think.md`](ai-think.md), [`ai-code-bridge.md`](ai-code-bridge.md)

구현 위치: 마이그레이션 `20260930100000_ai_think_actions.sql`, `ai_think/actions.ts`, `ai_code_bridge/code_review.ts`,
`tools/code_bridge/src/git_ops.mjs`, 앱 `screens/think/think_action_cards.dart`·`think_code_views.dart`·`think_code_requests_dialog.dart`.

2026-09-30 운영자 결정:

| 항목 | 결정 |
|------|------|
| 조사 결과 뒤 | Think가 자동으로 검토·정리해 같은 대화에 답을 붙인다 (결과 1건당 OpenAI 호출 추가) |
| 코드 수정 | 이번에 함께 구현. 분리된 복사본에서 수정 → 변경 내용(diff) 확인 → 승인하면 작업 폴더에 적용 |
| 적용 방식 | 작업 폴더에 바로 적용. 충돌이 하나라도 있으면 아무것도 바꾸지 않는다. 적용 전 상태를 되돌리기용으로 보관 |
| 수정 출발점 | 지금 작업 폴더 상태(커밋 안 된 변경·새 파일 포함) 스냅샷. 실제 작업 폴더와 git 인덱스는 건드리지 않는다 |
| 명령 실행 | Cursor에게 셸 명령을 주지 않는다. 읽기·편집·삭제 도구만 |
| 코드 조사 탭 | 없앤다. 채팅으로 합친다 |
| 트리 읽기 | AI가 폴더 이름·경로와 대화 제목만 읽는다. 발췌 내용과 "답변에서 제외"한 문답은 읽지 않는다 |
| 삭제 제안 대상 | 코드 조사 요청, 트리 폴더(안의 항목은 위로 올림), 대화 |
| 진행 | A(채팅 통합)와 B(코드 수정)를 한 번에 구현한 뒤 배포 |

2026-10-01 운영자 결정 (Think ↔ Cursor 조율, §4.3):

| 항목 | 결정 |
|------|------|
| 역할 | Think는 방향·아이디어를 내는 개인 비서, Cursor는 코드를 아는 실무자. 둘이 먼저 조율하고 운영자는 조율본을 승인한다 |
| 조율 시작 | 승인 없이 바로 시작(읽기 전용, 하루 요청 한도 안). Think는 시작 전에 대화로 의도를 확인한다 |
| 주고받는 횟수 | 최대 3회(Cursor 검토 3번) |
| 승인 | 조율본 승인(구현 시작)과 diff 적용 승인, 두 번 그대로 |
| 수정 작업 시간 | 30분. 시간이 넘어도 만든 변경은 버리지 않고 "확인 필요"로 남긴다(적용은 안 됨) |

2026-10-02 운영자 결정 (조율본 질문, §4.3):

| 항목 | 결정 |
|------|------|
| 남은 쟁점 | 운영자만 정할 것과 끝까지 갈린 의견을 글이 아니라 객관식 질문(보기 2~4개, 보기마다 자세한 설명, 추천 보기 맨 앞에 "추천")으로 묻는다. 직접 입력 칸도 둔다 |
| 갈린 의견 | 질문으로 바꾼다(Think 안 / Cursor 안 / 절충안) |
| 답한 뒤 | Cursor가 고른 답을 코드에 비춰 한 번 더 확인하고 Think가 새 조율본을 올린다(하루 요청 1건 사용) |
| 일부만 답함 | 모든 질문에 답해야 반영 버튼이 켜진다 |
| 범위 | 이번에는 조율본에만. 평소 대화에는 쓰지 않는다 |

---

## 1. 원칙

1. **AI 도구는 DB를 바꾸지 않는다.** 쓰기처럼 보이는 도구는 `ai_actions`에 "제안" 1행을 남길 뿐이다.
   제안은 대화에 AI가 쓴 메시지와 같은 성격이다(AI 자신의 출력 기록).
2. **실행은 승인 RPC 하나로만 한다.** `ai_action_apply(p_id)`가 슈퍼관리자 확인 → 상태 `proposed` 확인 →
   대상 다시 검증 → 실행 → 결과 기록을 한 트랜잭션으로 한다. 한 제안은 한 번만 실행된다.
3. **미리보기 없이 실행하지 않는다.** 카드에 무엇이 바뀌는지(폴더 경로, 지워질 메시지·발췌 수, 코드 diff)를 먼저 보인다.
4. **코드 수정은 두 번 승인한다.** 수정 시작(조율본 승인 또는 요청 보내기)과 적용. 적용 전에는 실제 작업 폴더가 바뀌지 않는다.
   유일한 예외는 조율 시작(`code_plan`)이다. 읽기 전용이고 하루 한도 안이라 승인 없이 시작하며, 기록은 `applied` 제안 1행으로 남는다.
5. **정보가 부족하면 묻는다.** 도구가 필수 값 누락을 오류로 돌려주면 AI가 대화로 되묻고, 다음 턴에 같은 제안을 채워 다시 낸다.
6. 기존 원칙 유지: 키 위치, 기억은 사람만 확정, 결정은 "결정으로 정리" 경로로만.

---

## 2. 제안(`ai_actions`)

| 열 | 뜻 |
|------|------|
| `id`, `conversation_id` (대화 삭제 시 함께 삭제), `message_id` (제안한 답변, 지워지면 비움) | 어느 대화의 어느 답변이 냈는지 |
| `kind` | `code_request` / `code_change` / `code_plan` / `place_conversation` / `delete_code_request` / `delete_folder` / `delete_conversation` |
| `status` | `proposed` → `applied` / `rejected` / `failed` (`place_conversation`은 `applied` → `undone` 가능) |
| `payload` (jsonb) | 제안 내용. 서버가 검증·정리한 값만 들어간다 |
| `preview` (jsonb) | 카드에 보일 요약(폴더 경로, 지워질 수 등). 제안 시점에 서버가 계산 |
| `result` (jsonb) | 실행 결과(만든 폴더·요청 id, 되돌리기 정보) |
| `error`, `decided_at`, `decided_by`, `created_at` | |

- RLS: 슈퍼관리자만 읽는다. 앱은 직접 쓰지 않는다. `ai_think`가 사용자 JWT로 `ai_action_propose`를 불러 넣는다.
- 앱용 RPC: `ai_action_apply(p_id, p_overrides)`, `ai_action_reject(p_id)`, `ai_action_undo(p_id)`.
  `p_overrides`는 사용자가 카드에서 고친 값(다른 폴더 선택, 요청 문구 수정)만 받는다.
- 같은 대화에 같은 종류의 `proposed`가 새로 오면 이전 것은 `rejected`(대체됨)로 바꾼다. 카드는 최신 것만 버튼을 보인다.

### 종류별 실행

| kind | 미리보기 | 승인 시 실행 | 되돌리기 |
|------|------|------|------|
| `code_request` | 요청 제목·목표·질문·폴더 | `ai_code_requests` 생성 + 보내기(하루 한도 검사) | 취소는 요청 카드에서 |
| `code_change` | 수정 지시·대상 폴더 (조율본이면 회차·갈린 점·정할 것) | `ai_code_requests`(`mode = 'change'`) 생성 + 보내기 | — (적용은 따로 승인) |
| `code_plan` | 제목·목표 | 승인 없음. `ai_code_plan_start`가 `mode = 'plan'` 요청을 만들어 보내고 `applied`로 남긴다 | 취소는 요청 카드에서 |
| `place_conversation` | 폴더 경로(새 폴더면 "새 폴더: 경로"), 현재 위치 | 새 폴더면 만들고(`created_via = 'ai'`) 현재 대화를 그 폴더 끝에 놓는다 | 이전 위치로 되돌리고, AI가 만든 빈 폴더는 지운다 |
| `delete_code_request` | 제목·상태 | 삭제(끝난 요청·초안만) | 없음 |
| `delete_folder` | 폴더 경로, 안의 항목 수("위로 올라감") | `ai_tree_delete_folder` | 없음 |
| `delete_conversation` | 제목, 메시지 수, 발췌 수, 연결된 조사 요청 수 | 대화 삭제(메시지·배치·발췌 함께) | 없음 |

---

## 3. Think 도구 추가 (`ai_think/tools.ts`)

읽기(바로 실행):

- `list_tree_folders`: 폴더 id·경로·항목 수, 현재 대화의 위치
- `list_conversations(query)`: 대화 id·제목·최근 시각 (최대 20)
- `list_code_requests(query)`: 코드 요청 id·제목·상태·모드
- `get_code_request(id)`: 요청 내용과 마지막 결과(정리된 결과, 원문은 앞부분만, diff 통계)

제안(행 1개만 남김):

- `propose_code_request(title, goal, questions, focus_paths, constraints, do_not, background)`
- `start_code_plan(title, goal, instructions, questions, focus_paths, constraints, do_not, background, based_on_request_id)`:
  코드 수정이 필요하면 이 도구로 Cursor와 조율을 시작한다(§4.3). 제안이 아니라 바로 시작한다.
  하루 한도에 걸리면 `daily_limit` 오류를 돌려준다. (2026-10-01에 `propose_code_change`를 대신함)
- `propose_folder(folder_id | new_folder_title + new_folder_parent_id, reason)`
- `propose_delete(target_kind, target_id, reason)`

제안 도구는 필수 값이 없거나 대상이 없으면 `{ error, missing }`을 돌려준다. 지시문에 "그럴 땐 사용자에게 물어라"를 넣는다.
제안이 만들어지면 SSE `action` 이벤트로 바로 카드가 뜬다.

### 맥락

- 대화 기록 뒤, 이번 메시지 앞에 **"이 대화의 작업 상태"** 블록을 넣는다. 최근 제안 10개의 종류·상태·핵심 결과
  (예: "코드 조사 #3 결과 도착: 가능, 제안 2개" / "폴더 제안: 사용자가 거절").
  앞쪽(지시문·기록)이 바뀌지 않으므로 프롬프트 캐시가 유지된다.
- 코드 요청을 제안할 때 지시문에 들어 있는 원칙·결정의 id·버전·요약을 `memory_refs`로 함께 넣는다(최대 8개).

---

## 4. 코드 조사·수정 흐름

```
채팅 → propose_code_request → [카드: 보내기]          (조사)
채팅 → start_code_plan → 조율(§4.3) → [조율본 카드: 이대로 구현]  (수정)
  → ai_action_apply → ai_code_requests (queued)
  → PC 작업자 (조사: 읽기 전용 / 수정: 분리된 복사본에서 편집)
  → ai_code_bridge complete
  → (서버, 자동) Think 검토 → 필요하면 2회차 질문(최대 2회) → 같은 대화에 답변 메시지
  → 수정이면 [카드: diff 보기 · 적용] → ai_code_request_apply → 작업자가 작업 폴더에 적용
```

### 4.1 자동 검토 (`ai_code_bridge` → `code_review.ts`)

- 작업자 `complete` 직후 `EdgeRuntime.waitUntil`로 돌린다. 작업자 응답은 기다리지 않는다.
- 입력: 원칙·결정(지시문과 같은 것), 대화 최근 기록(제외 문답 빼고), 요청 내용, Cursor 결과(정리 + 원문 앞부분, 수정이면 diff 통계와 앞부분).
- 출력(JSON): `answer`(대화에 붙일 마크다운), `followup_questions`(최대 3개), `conflicts`(원칙과 어긋나는 점).
  추가 질문이 있고 회차가 2 미만이면 `followup_queued`로 돌려 한 번 더 조사한다. 아니면 답을 대화에 붙인다.
- 기록: `ai_runs.feature = 'code_review'`. 월 한도가 차단 모드로 넘었으면 검토를 건너뛰고 카드에 "검토 안 함"을 표시한다.
- 요청에 `review_status`(`pending`/`done`/`skipped`/`error`)와 `review_message_id`를 둔다. 앱은 이것으로 새 메시지를 불러온다.

### 4.2 코드 수정 (작업자 `mode = 'change'`)

1. **스냅샷**: 임시 인덱스(`GIT_INDEX_FILE`)에 작업 폴더 전체를 담아(`git add -A`, `.gitignore` 준수)
   `write-tree` → `commit-tree`로 커밋 S를 만든다. 실제 인덱스·작업 폴더·브랜치는 그대로다.
   비밀 경로(`.env*`, `env.local.json`, `*.pem`, `*.key`, `supabase/.temp/`)는 임시 인덱스에서 뺀다.
   S는 `refs/code-bridge/<요청 id>/base`로 붙잡아 둔다.
2. **복사본**: `git worktree add --detach <임시 폴더> S`.
3. **Cursor 실행**: `mode: "agent"`, 도구 `read, grep, glob, ls, edit, delete`(셸 없음), `cwd` = 복사본.
   훅이 환경 변수 `CODE_BRIDGE_WRITE_ROOT` 밖의 모든 경로를 막는다(읽기 포함). 복사본 안이라도
   `.git`과 `.cursor/hooks*`에는 쓰지 못한다. 훅은 작업자 프로세스의 환경 변수를 물려받는다(실제 SDK로 확인).
4. **diff**: 복사본에서 `git add -A` → `git diff --binary S`. 비밀 경로를 건드렸으면 실패 처리.
   diff는 400KB 이하만 올린다. 파일 수·추가·삭제 줄 수를 함께 올린다.
5. **적용(승인 뒤)**: `ai_code_request_apply` → 상태 `apply_queued` → 작업자가 가져간다.
   - 적용 전 작업 폴더를 1번과 같은 방법으로 스냅샷해 `refs/code-bridge/<id>/before-apply`에 보관한다.
   - `git apply --check`로 먼저 검사. 실패하면 아무것도 바꾸지 않고 `apply_failed`(충돌 파일 목록).
   - 통과하면 `git apply`. 결과 `applied`.
   - 되돌리기: `git apply -R --check` 후 `git apply -R`. 적용 뒤 사용자가 같은 줄을 또 고쳤으면 충돌로 멈춘다.
6. **정리**: 수정 실행이 끝나면(성공·실패·취소 모두) 바로 복사본을 지운다(`git worktree remove --force`).
   적용·되돌리기는 저장된 diff로 한다. 참조(ref)는 30일 지나면 작업자가 시작할 때 지운다.
7. 적용 중 작업자가 멈춰 임대가 끝나면 `apply_failed`(`last_error = 'lease_expired_state_unknown'`)로 바꾼다.
   작업 폴더 상태를 알 수 없으므로 카드가 `git status`로 확인하라고 안내한다.

diff에는 코드가 들어 있고 Supabase DB에 저장된다(조사 결과도 코드 일부를 담는 것과 같은 수준).

수정 실행은 30분(`CODE_BRIDGE_CHANGE_TIMEOUT_MS`, 1~90분)까지 돌린다. 시간이 넘었을 때 바뀐 파일이 있으면
그때까지의 diff를 형식 불일치(`parse_ok = false`)로 올려 `needs_review`가 된다. 이 상태는 적용할 수 없고 확인만 한다.
작업자는 실행 중 1분마다 경과 시간·도구 사용 횟수·바뀐 파일 수를 터미널에 찍는다.

### 4.3 Think ↔ Cursor 조율 (`mode = 'plan'`, 2026-10-01)

```
Think: 대화로 의도 확인 → start_code_plan (승인 없이 시작, code_plan 제안 1행 applied)
  → 작업자: Cursor가 계획 초안을 코드에 비춰 검토 (읽기 전용, mode plan)
  → code_review: Think가 검토를 읽고 질문·반론 → 다음 회차 (최대 3회)
  → 마지막: 대화에 조율 결과 메시지 + 조율본 카드(code_change 제안, payload.plan_request_id)
  → 운영자: [이대로 구현 / 고쳐서 구현 / 거절]
  → 수정 요청(change) → diff → [작업 폴더에 적용] (기존 §4.2)
```

- 마이그레이션 `20261001120000_ai_code_plan.sql`: `mode`에 `plan`, `ai_actions.kind`에 `code_plan`,
  `ai_code_plan_start`(앱 사용자 JWT, 슈퍼관리자), `ai_code_bridge_propose_plan`(서비스 역할만).
  `ai_code_bridge_followup`은 질문 목록(`p_questions`)도 받아 `ai_code_requests.followup_questions`에 두고,
  다음 회차가 시작될 때 트리거가 `ai_code_request_rounds.think_questions`로 옮긴다. 카드는 회차마다 "Think가 보낸 질문·반론"을 보인다.
- Cursor 검토 결과(JSON): `summary`, `feasibility`, `findings`, `issues[{step, problem, suggestion}]`, `suggested_steps`,
  `risks`, `questions_for_think`, `questions_for_owner`.
- Think 조율 출력(JSON, `code_plan_review`): `answer`, `followup_questions`, `plan{title, goal, instructions, focus_paths,
  constraints, do_not}`, `decisions[{kind: owner|disagreement, question, context, options[{label, detail, recommended}]}]`.
  마지막 회차에는 질문을 더 하지 않고 조율본을 낸다. (2026-10-01판의 `disagreements`·`owner_questions`는 `decisions`로 바뀌었다.
  앱은 예전 조율본도 그대로 보여 준다)
- 서버(`parseDecisions`)가 질문을 정리한다: 최대 5개, 보기 2~4개(모자라면 버림), 추천은 하나만 남겨 맨 앞으로, id는 `q1`·`q1_1` 순서.
- 조율본 `spec`에는 `based_on_plan{id, title, rounds, summary}`, `decisions`, `owner_answers`가 붙는다.
  같은 대화의 대기 중 `code_change`는 새 조율본으로 대체된다.
- 계획 지시(`instructions`)도 질문(`decisions`)도 없으면 조율본 카드를 만들지 않고 결과 메시지만 남긴다.

#### 조율본 질문에 답하기 (2026-10-02, 마이그레이션 `20261002100000_ai_code_plan_revise.sql`)

```
조율본 카드(decisions 있음): 질문마다 보기 하나 또는 직접 입력 → 모두 답하면 [답변 반영해 다시 조율]
  → ai_code_plan_revise(action_id, answers)  (앱 사용자 JWT, 슈퍼관리자)
     - 모든 질문에 답했는지, 보기 id가 맞는지 확인
     - 답을 spec.owner_answers에 쌓고, constraints에 "운영자 결정 — 질문: 답" 줄을 붙인다
     - 새 plan 요청(max_rounds 1)을 만들어 보내고(하루 한도), 같은 답변 메시지에 code_plan 행(applied)을 남긴다
     - 이전 조율본은 rejected·superseded, result에 고른 답과 새 요청 id
  → Cursor가 고른 답을 코드에 비춰 확인 → Think가 새 조율본(질문이 또 남으면 다시 질문 카드)
```

- 질문이 남아 있는 동안 조율본 카드는 "이대로 구현"·"고쳐서 구현"을 보이지 않는다. 구현은 질문이 없는 조율본을 승인해야 시작한다.
- Think는 `owner_answers`와 "운영자 결정 — " 제약을 다시 묻지 않는다. 새 조율본을 만들 때 서버가 "운영자 결정 — " 줄을 지우지 않고 남긴다.
  수정 실행에도 이 제약이 그대로 들어간다(작업자 변경 없음).

### 4.4 요청 상태 추가

`ai_code_requests.mode`: `investigate`(기본) / `change` / `plan`.
수정 요청의 추가 상태: `ready`(diff 도착) → `apply_queued` → `applying` → `applied` / `apply_failed`,
`applied` → `revert_queued` → `reverted` / `revert_failed`. diff는 `ai_code_request_rounds.result.diff`에 있다.

---

## 5. 화면

- **탭**: 대화 · 기억 · 사용량. "코드 조사" 탭은 없앤다.
- **채팅 카드** (답변 아래, 제안한 메시지에 붙는다)
  - 코드 조사/수정 카드: 제안 → 보내기/고쳐서 보내기/거절 → 대기·조사 중(작업자 상태, 취소) → 결과 요약(가능 여부, 제안, 근거 파일) → 수정이면 diff(파일별 접기) + 적용/거절 → 적용됨/되돌리기
  - 조율 카드("Cursor와 조율"): 회차(N/3), 진행 문구, "주고받은 내용"에 계획 초안과 회차별 Cursor 검토·Think 질문
  - 조율본 카드: 계획(할 일·범위·하지 말 것) → 이대로 구현/고쳐서 구현/거절
  - 조율본 질문(질문이 있을 때 위 버튼 대신): 질문마다 보기 목록(라디오, 추천 배지, 설명)과 직접 입력 → "n/m개 답함" → 답변 반영해 다시 조율/거절.
    반영된 조율본은 "고른 답 n개로 다시 조율함" 한 줄로 줄인다
  - 분류 카드: "이 대화를 ‘경로’에 넣을까요?" 넣기 / 다른 폴더 / 거절. 넣은 뒤 되돌리기
  - 삭제 카드: 지워질 것 요약 + 빨간 삭제 버튼 → 확인 창 한 번 더. 되돌릴 수 없음을 적는다
  - 적용 확인 창: 파일 목록, `git apply --check` 선검사, 백업 ref, 커밋·스테이징 안 함을 적는다
  - 거절·대체된 제안은 한 줄로 줄인다
- **트리 하이라이트**: 대기 중인 분류 제안이 있으면 그 폴더를 강조(초록 테두리 + "제안")하고 조상 폴더를 펼친다.
  새 폴더 제안은 흐린 테두리의 가상 행("새 폴더 제안")으로 상위 폴더 맨 아래에 끼운다. 확정 전에는 아무것도 저장하지 않는다.
- **맥락 패널**: 작업자 켜짐/꺼짐, 오늘 보낸 요청 수/한도, 진행 중 건수, "전체 코드 요청" 창(대화 연결이 없는 요청·지난 요청, 판단 남기기).
- 대화의 🔍 버튼(수동 요청 창)은 그대로 둔다. 수동으로 보낸 요청도 출처 답변 아래 카드로 보인다.
- 앱은 대화 탭이 보이는 동안 요청 상태를 30초마다, 진행 중이거나 검토 대기인 요청이 있으면 5초마다 읽는다.
  `review_message_id`가 새로 생기면 열린 대화의 메시지와 제안을 다시 불러온다.
- 스트리밍 중 온 제안은 답변 맨 아래에 먼저 보이고, `done.action_ids`로 답변 id가 붙는다.

---

## 6. 하지 않는 것

AI의 자동 실행(읽기 전용 조율 시작만 예외), 셸 명령, 커밋·푸시·PR, 작업 폴더 외 경로 수정, 여러 요청 동시 처리,
Cursor IDE 채팅창 조작, 삭제 되돌리기(휴지통).
