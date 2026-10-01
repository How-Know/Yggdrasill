# 코드 조사 연동 (Think ↔ Cursor) 설계

Think 대화에서 "앱을 이렇게 바꾸고 싶다"는 이야기가 나오면, Think가 구조화된 조사 요청을 만들고
Cursor 에이전트가 실제 코드를 읽어 답한다. 둘이 최대 2번 주고받은 뒤 정리한 결과를 운영자에게 보여 주고,
결정은 운영자가 한다.

**상태: 2단계 구현, 배포 전 (2026-09-30).** Think가 채팅에서 요청을 제안하고(사람이 카드에서 승인),
결과가 오면 Think가 자동으로 검토해 필요하면 2회차 질문을 보내고, 같은 대화에 답을 붙인다.
코드 수정 모드(격리 복사본 → diff → 적용 승인 → 되돌리기)도 들어갔다. 바뀐 흐름과 화면은
[`ai-think-actions.md`](ai-think-actions.md)가 기준이고, 이 문서의 4.2절 "2단계 (예정)"과 1단계 설명은 기록으로 남긴다.
"코드 조사" 탭은 없어지고 채팅 카드 + "전체 코드 요청" 창으로 바뀌었다. 2026-09-29 운영자 결정:

| 항목 | 결정 |
|------|------|
| 범위 | 새로 연다. 단, 1단계는 조사와 수정 제안까지만. 코드는 고치지 않는다 |
| 실행 위치 | 운영자 PC의 로컬 작업자 (Cursor SDK 로컬 실행) |
| 자동 왕복 | 최대 2회. 그 뒤 정리해서 제시 (2단계) |
| Cursor 키 | 운영자 개인 Cursor API 키. 사용자 환경 변수 `CURSOR_API_KEY`에 넣음 (2026-09-29) |
| 작업자 켜기 | 필요할 때 수동으로 켠다 (`npm start`). 자동 시작은 하지 않는다 |
| Cursor 사용 제한 | 하루 요청 수 (한국 시간 기준). 기본 10건, 사용량 탭에서 0~100 사이로 바꾼다 |
| 조사 범위 기본값 | 저장소 전체. 요청마다 "우선 볼 폴더"를 적을 수 있다 |
| 화면 | Preview 없이 매니저앱 Think에 바로 넣는다. 대화의 Think 답변 머리에 "코드 조사 요청" 버튼 |

관련 문서: [`ai-think.md`](ai-think.md) (Think 본체)

---

## 1. 원칙

1. **Think가 주인이고, Cursor 에이전트는 조사 담당이다.** 기준(교육철학·원칙·결정)은 DB의 Think 기억 하나뿐이다.
   Cursor 에이전트는 코드에 대한 사실과 변경안을 내고, 그것을 기준과 맞춰 보고 정리하는 것은 Think다.
2. **1단계에서는 코드를 한 줄도 고치지 않는다.** Cursor 에이전트에게 읽기·검색 도구만 준다.
   편집, 셸, MCP, 웹, 하위 에이전트, PR 생성은 주지 않는다.
3. **사람의 승인은 두 번이다.** 요청을 보낼 때(초안 확인 후 승인), 결과를 받아들일 때(최종 결정).
   중간의 자동 왕복(최대 2회)은 읽기 전용이라 승인 없이 진행한다.
4. **결정은 기존 경로로만 확정된다.** 조사 결과가 좋아도 바로 결정이 되지 않는다.
   운영자가 "결정으로 정리"를 눌러 기존 결정 초안 → 승인 흐름을 탄다.
5. **키는 각자 자리에만 둔다.** OpenAI 키는 Edge Function 비밀값, Cursor 키는 운영자 PC 환경 변수에만 둔다.
   작업자 토큰은 Edge Function 비밀값(해시)과 운영자 PC 환경 변수에만 둔다. 앱, DB, Git에는 어떤 키도 두지 않는다.
6. **공식 경로만 쓴다.** Cursor SDK(`@cursor/sdk`, 공개 베타)만 쓴다. IDE 화면 자동 클릭이나 비공식 내부 API는 쓰지 않는다.
   따라서 상대는 운영자가 쓰는 Cursor 채팅창이 아니라, SDK로 따로 띄우는 Cursor 에이전트다.

---

## 2. Think와의 일관성

두 AI를 쓰면 판단 기준이 둘로 갈라질 수 있다. 아래 규칙으로 기준을 하나로 묶는다.

| 어긋날 수 있는 곳 | 막는 방법 |
|------|------|
| 판단 기준 | 요청에 관련 결정·원칙을 id·버전과 함께 넣어 보낸다. Cursor 에이전트는 이것과 저장소 규칙(`AGENTS.md`, `.cursor/rules`, `docs/architecture`)만 따른다 |
| Cursor 쪽 기억 | 요청마다 새 에이전트를 만든다. 요청 사이에 맥락을 넘기지 않는다. `settingSources`는 `["project"]`만 켠다. 다만 0단계 시험에서 개인 스킬(21개)과 "한국어로 답하기" 같은 개인 규칙은 이 설정과 상관없이 들어왔다. 판단 기준은 요청 안의 결정·원칙 스냅샷으로 명시한다 |
| 최종 판단 | Cursor 결과는 "근거 자료"다. 결정·원칙과 대조하고, 맞지 않는 부분을 표시하고, 정리하는 것은 Think(OpenAI, `ai_think`)가 한다 |
| 의견 차이 | 숨기지 않는다. 정리 결과에 "합의된 제안 / 남은 쟁점 / 운영자가 정할 것"을 따로 둔다 |
| 조사 중 기준 변경 | 요청에 넣은 결정 버전과 정리 시점의 버전이 다르면 "기준이 바뀌었음" 경고를 붙인다 |
| 대화 흐름 | 최종 정리는 원래 Think 대화에 메시지로 붙는다. 그래서 이후 Think 답변도 그 결과를 안다 |
| 비용 | Cursor 사용량도 `ai_runs`에 기록해 사용량 탭 한 곳에서 본다 (원칙 6: 비용은 플랫폼 공통) |

---

## 3. 구성

```
매니저앱 Think ──▶ ai_think ─────────────────────────▶ OpenAI
   │ (요청 초안 확인·승인)   code_request_draft / code_review / code_summary
   ▼
ai_code_requests, ai_code_request_rounds  (슈퍼관리자 RLS)
   ▲
   │ claim / heartbeat / complete / fail   (작업자 토큰)
ai_code_bridge  (Edge Function, 네 가지 동작만)
   ▲
   │ HTTPS 폴링 (나가는 연결만)
운영자 PC 작업자 (Node 22 + @cursor/sdk, 로컬 실행)
   └─▶ Cursor 에이전트: mode "plan", 읽기 도구만, cwd = 저장소
```

- 작업자는 PC에서 밖으로만 연결한다. PC에 포트를 열지 않는다.
- 로컬 실행이라 커밋·push하지 않은 코드도 조사한다. 대신 PC와 작업자가 켜져 있어야 한다.
- 모델 추론은 로컬 실행이어도 Cursor 서버에서 돈다. 조사한 코드 일부가 Cursor로 전송된다.
  Think가 결과를 검토할 때 그 코드 일부가 OpenAI로도 전송된다.

---

## 4. 흐름

### 4.1 지금(1단계)

1. **요청 쓰기**: 코드 조사 탭의 "새 요청", 또는 Think 답변 머리의 "코드 조사 요청" 버튼.
   버튼으로 열면 그 문답의 질문이 목표, Think 답변이 배경으로 채워지고 대화 id·메시지 id가 붙는다.
   칸: 제목, 목표(필수), 확인할 질문, 우선 볼 폴더, 지켜야 할 제약, 제안하지 말 것, 배경. 목록 칸은 한 줄에 하나.
2. **초안 저장 / 보내기**: 보내면 `ai_code_request_submit`이 하루 한도를 확인하고 `queued`로 바꾼다.
3. **조사**: 작업자가 가져가 Cursor 에이전트를 띄운다. 요청문(`buildPrompt`, `code_bridge.v1`)은 수정 금지와 답 형식을 명시한다.
   답 끝의 JSON 블록(`summary`, `feasibility`, `answers`, `findings[evidence]`, `proposals[risk]`, `risks`, `questions_for_think`)을 작업자가 읽는다.
4. **결과**: 형식이 맞으면 `ready`, 아니면 `needs_review`(원문만). 앱은 5초마다 새로 읽어 보여 준다.
5. **판단**: 운영자가 채택·반려·보류와 메모를 남긴다. 기록일 뿐 결정 기억은 바뀌지 않는다.
   결정으로 남기려면 대화에서 기존 "결정으로 정리"를 쓴다. "다시 요청"은 같은 내용으로 새 초안을 만든다.

### 4.2 2단계 (예정)

1. **요청 초안**: Think 대화에서 "코드 조사 요청"을 누른다. `ai_think`의 `code_request_draft`가 대화를 읽어 초안을 만든다.
   초안에는 목표, 확인할 질문, 관련 결정·원칙(id·버전), 제약, 하지 말 것, 조사 범위(폴더)가 들어간다.
2. **승인**: 운영자가 초안을 고치고 "보내기"를 누른다. 상태가 `queued`가 된다.
3. **1회차 조사**: 작업자가 요청을 가져가 Cursor 에이전트를 띄운다. 에이전트는 정해진 형식으로 답한다.
   형식은 발견 사항(파일·줄 근거), 가능 여부, 수정 제안(적용하지 않은 변경 설명), 위험, 되묻는 질문이다.
4. **Think 검토** (`code_review`): 결과를 결정·원칙과 대조한다. 충분하면 5로 가고,
   부족하면 추가 질문(최대 3개)을 만든다. 추가 질문이 있고 회차가 2 미만이면 `followup_queued`가 된다.
5. **2회차 조사**: 작업자가 같은 에이전트에 이어서 묻는다(`agent.send`). 앞 회차 맥락이 유지된다.
6. **정리** (`code_summary`): Think가 최종 정리를 만들고 원래 대화에 메시지로 붙인다. 상태는 `ready`가 된다.
7. **결정**: 운영자가 채택하면 기존 "결정으로 정리"로 이어진다. 반려·보류도 기록한다.
   실제 구현은 지금처럼 스펙을 내보내 Cursor에서 따로 진행한다.

Think 검토와 정리는 `ai_code_bridge`가 작업자 결과를 받은 직후 서버에서 부른다. 그래서 OpenAI 키는 서버를 떠나지 않는다.

### 4.1 1단계에서 실제로 되는 것

1. Think 대화의 답변 머리 "코드 조사 요청"(돋보기 아이콘) 또는 "코드 조사" 탭의 "새 요청"으로 창을 연다.
   대화에서 열면 그 문답의 질문이 "목표", Think 답변이 "배경"으로 채워지고 `conversation_id`·`source_message_ids`가 붙는다.
2. 제목, 목표, 확인할 질문, 우선 볼 폴더, 지켜야 할 제약, 제안하지 말 것, 배경을 고쳐 "초안 저장" 또는 "보내기".
   보내기는 `ai_code_request_submit`이 목표·하루 한도를 확인하고 `queued`로 바꾼다.
3. 작업자가 가져가 Cursor 에이전트를 1회 돌린다. 답 끝의 JSON 블록을 읽으면 `ready`, 못 읽으면 원문만 두고 `needs_review`.
4. "코드 조사" 탭에서 결과(가능 여부, 요약, 질문별 답, 찾은 것과 파일·줄 근거, 수정 제안과 위험도, 위험, 되묻는 질문, 원문)와
   실행 정보(모델, 토큰, 도구 호출 수, 걸린 시간, 저장소 브랜치·커밋·커밋 안 된 파일 수)를 본다.
5. 운영자가 채택·반려·보류와 메모를 남긴다. 기록일 뿐이며 결정 기억을 바꾸지 않는다.
   결정으로 남기려면 "대화로 가기"로 돌아가 기존 "결정으로 정리"를 쓴다.

회차 열(`round`, `max_rounds`, `followup_queued`)과 이어 묻기(`followup_prompt`)는 2단계를 위해 미리 만들어 두었다.
1단계에서는 1회차만 쓴다.

---

## 5. 테이블

마이그레이션: `supabase/migrations/20260929160000_ai_code_bridge.sql`

`ai_code_requests` — 요청 1건

| 열 | 뜻 |
|------|------|
| `id`, `conversation_id`, `source_message_ids` | 어느 대화의 어느 문답에서 나왔는지 (대화를 지우면 `conversation_id`만 비운다) |
| `status` | `draft` → `queued` → `running` → (`followup_queued` → `running`) → `ready` / `needs_review` / `failed` / `cancelled` |
| `request` (jsonb, 50KB 이하) | `goal`, `background`, `questions`, `focus_paths`, `constraints`, `do_not` (2단계에서 `memory_refs` 추가) |
| `summary` (jsonb) | 2단계의 최종 정리: 합의된 제안, 남은 쟁점, 정할 것, 기준 변경 경고 |
| `outcome`, `outcome_note`, `decided_at` | 운영자 판단: `adopted` / `rejected` / `deferred` / null |
| `round`, `max_rounds` | 현재 회차, 최대 2 |
| `attempts`, `last_error` | 같은 회차 시도 횟수(최대 3), 마지막 오류 |
| `worker_id`, `lease_expires_at`, `heartbeat_at` | 누가 가져갔는지, 점유 만료 시각, 마지막 진행 신호 |
| `cursor_agent_id` | 마지막으로 쓴 Cursor 에이전트 id (기록용) |
| `cancel_requested` | 실행 중에 앱에서 취소를 눌렀는지 |

`ai_code_request_rounds` — 회차별 기록: 보낸 요청문, 답 원문(가림 처리), 정리된 결과, 형식 일치 여부,
Cursor 실행 id, 모델, 소요 시간, 토큰, 도구별 호출 수, 저장소 상태(브랜치·HEAD·커밋 안 된 파일 수), 오류.

`ai_code_workers` — 작업자별 마지막 신호, 버전, 모델, 처리 중인 요청. 앱의 "작업자 켜짐/꺼짐" 표시에 쓴다.

`ai_platform_settings.code_request_daily_limit` — 하루 보낼 수 있는 요청 수 (기본 10, 0~100).

권한:

- 세 테이블 모두 RLS로 슈퍼관리자만 읽는다. anon은 아무것도 못 한다.
- 앱이 직접 쓸 수 있는 것: 요청 초안 만들기(`title`, `request`, `conversation_id`, `source_message_ids` 열만),
  초안일 때만 `title`·`request` 고치기, 초안·끝난 요청 지우기. 열 단위 권한과 RLS로 막는다.
- 상태 전이는 security definer RPC로만 한다. 앱용(슈퍼관리자 확인): `ai_code_request_submit`, `ai_code_request_cancel`, `ai_code_request_decide`.
  작업자용(service role만): `ai_code_bridge_claim`, `_heartbeat`, `_complete`, `_fail`.
- 가져가기는 `for update skip locked`로 한 건을 한 작업자만 잡는다. 점유(120초)가 만료된 요청은 다음 가져가기 때 되돌린다.
- 하루 한도는 설정 행을 잠근 뒤 센다. 동시에 두 번 눌러도 한도를 넘지 않는다.

---

## 6. 인증

| 누가 → 어디 | 방법 |
|------|------|
| 매니저앱 → `ai_think`, 테이블 | 지금처럼 사용자 JWT, 슈퍼관리자 확인 |
| 작업자 → `ai_code_bridge` | 작업자 토큰(`Authorization: Bearer`, PC 환경 변수 `CODE_BRIDGE_WORKER_TOKEN`). 서버는 SHA-256을 비밀값 `CODE_BRIDGE_WORKER_TOKEN_SHA256`과 일정 시간 비교한다. 함수는 `verify_jwt = false`. 서비스 역할 키는 작업자에게 주지 않는다 |
| 작업자 → Cursor | 운영자 PC 환경 변수 `CURSOR_API_KEY` (개인 키, 개인 요금제 청구) |
| `ai_code_bridge` → DB | 함수 안에서만 service role. 밖으로는 네 가지 동작만 노출한다 |

- 키는 Windows "시스템 환경 변수 편집" 창에서 운영자가 직접 넣는다. 터미널에 붙여 넣지 않는다(기록이 남는다).
- 작업자 토큰이 새면 비밀값만 바꾸면 된다. 할 수 있는 일이 대기열 네 가지 동작뿐이라 피해 범위가 좁다.

---

## 7. 작업자

위치: `tools/code_bridge/` (Node 22.13 이상. 운영자 PC는 22.20). 처음 한 번 `npm install`.

켜기: PowerShell에서 `cd tools/code_bridge` → `npm start`. 끄기: Ctrl+C 한 번이면 진행 중인 조사를 멈추고
대기열로 돌려놓은 뒤 끝난다. 두 번 누르면 바로 끝난다. 시험: `npm test`.

환경 변수 (Windows 사용자 환경 변수. 터미널에 붙여 넣지 않는다):

| 이름 | 필수 | 뜻 |
|------|------|------|
| `CURSOR_API_KEY` | 예 | 운영자 개인 Cursor API 키 |
| `CODE_BRIDGE_WORKER_TOKEN` | 예 | 작업자 토큰. 서버에는 해시만 있다 |
| `CODE_BRIDGE_MODEL` | | Cursor 모델 id. 기본 `composer-2.5` |
| `CODE_BRIDGE_WORKER_ID` | | 기본 `pc-<컴퓨터 이름>` |
| `CODE_BRIDGE_REPO` | | 조사할 저장소. 기본은 이 저장소 |
| `CODE_BRIDGE_URL`, `CODE_BRIDGE_ANON_KEY` | | 함수 주소(기본 운영 프로젝트), 게이트웨이가 요구할 때만 anon 키 |
| `CODE_BRIDGE_POLL_MS`, `CODE_BRIDGE_ROUND_TIMEOUT_MS` | | 대기열 확인 간격(기본 10초), 한 회차 제한(기본 15분) |

- 비밀 파일 차단 훅(`.cursor/hooks.json`, `deny-secrets.mjs`)이 없으면 시작하지 않는다.
- 10초마다 `claim`을 부른다. 한 번에 한 건만 처리한다. 인증 실패·함수 미설정이면 1분 쉬고 다시 본다.
- 점유는 2분이고 30초마다 `heartbeat`로 늘린다. 이때 취소 요청이 있으면 `run.cancel()`을 부른다.
  점유를 잃었다는 답이 오면 결과를 올리지 않는다.
- Cursor 에이전트 설정 (1단계는 시도마다 새 에이전트):

```typescript
Agent.create({
  apiKey: cfg.apiKey,
  model: { id: cfg.model },       // 코드에 박지 않는다. 환경 변수 CODE_BRIDGE_MODEL
  mode: "plan",
  tools: ["read", "grep", "glob", "ls"],
  local: { cwd: cfg.repo, settingSources: ["project"] },
});
```

- 결과를 올리기 전에 키처럼 보이는 문자열(`sk-`, `eyJ`, 긴 16진수 등)을 가린다.
- 끝나면 `run.wait()` 결과의 토큰 수(`usage`), 도구별 호출 수, 저장소 상태를 함께 올리고 에이전트를 정리(`close`)한다.
  `agent.getUsage()`(달러 비용)는 운영자 계정에서 `feature_unavailable`이라 쓸 수 없다.

---

## 8. 권한 범위 (2단계, 2026-09-30)

| 주체 | 할 수 있음 | 할 수 없음 |
|------|------|------|
| Cursor 에이전트 (조사) | 저장소 파일 읽기·검색, 변경안 설명 (`mode: "plan"`) | 파일 편집, 셸, 네트워크 도구, MCP, 하위 에이전트, PR, 비밀 파일 읽기 |
| Cursor 에이전트 (수정) | 격리 복사본 안에서만 읽기·편집·삭제 (`mode: "agent"`, `read, grep, glob, ls, edit, delete`) | 셸, 복사본 밖 경로(읽기 포함), `.git`·`.cursor/hooks*` 쓰기, 비밀 파일 |
| 작업자 | 대기열 동작(claim·heartbeat·complete·fail·apply_done), 스냅샷·복사본·diff, 승인된 diff 적용·되돌리기 | 커밋·푸시·스테이징, 다른 대화·기억 읽기, DB 직접 접근 |
| Think (`ai_think`) | 요청 제안(카드), 결과 자동 검토·2회차 질문·대화 답변(`ai_code_bridge` 안의 `code_review`) | DB 직접 변경, 요청 자동 전송, 적용 자동 실행, 결정 자동 확정 |
| 매니저앱 | 제안 승인·고쳐서 보내기·거절, 취소, 적용·되돌리기 승인, 판단 기록 | — |

수정 모드의 경로 제한: 작업자가 수정 실행 동안만 `CODE_BRIDGE_WRITE_ROOT`를 복사본 경로로 둔다. 훅은 이 값이 있으면
그 밖의 모든 경로를 막고(상대 경로는 이 폴더 기준, `..`가 든 검색 패턴도 막음), 쓰기 도구(`Write`·`Delete`·`Edit`…)가
`.git`·`.cursor/hooks*`를 가리키면 막는다. 이 값이 없는 IDE 에이전트는 예전처럼 비밀 경로만 막는다.
실제 SDK 확인(2026-09-30): 수정은 `Write`(`tool_input.file_path`, `content`), 삭제는 `Delete`로 오고, glob 검색도
`Grep`으로 온다. 훅 프로세스는 작업자의 환경 변수를 물려받는다. 제한이 없으면 에이전트가 저장소 밖 파일을 읽었다.
그래서 `.cursor/hooks.json`의 `preToolUse` matcher를 `Read|Grep|Glob|Write|Delete`로 넓혔다.

비밀 파일(`.env*`, `env.local.json`, `*.pem`, `*.key`, `supabase/.temp/`)은 도구 목록만으로는 막히지 않는다.
`read` 도구가 경로를 가리지 않기 때문이다(0단계에서 미끼 값이 그대로 읽혔다). 그래서 `.cursor/hooks.json`의 `preToolUse` 훅으로 막는다.

- 훅 입력: `tool_name`(`Read`, `Grep`, `Glob` …)과 `tool_input.file_path`. `Grep`은 `pattern`, `file_path`, `glob`, `output_mode`
- **Windows에서는 훅 입력 앞에 BOM이 붙는다.** 이를 벗기지 않으면 JSON 해석이 실패하고, 실패를 허용으로 처리하는 훅은 모두 통과시킨다.
  그래서 BOM을 벗기고, 해석에 실패하면 거부한다(`failClosed: true`, 종료 코드 2)
- **한국어 Windows에서는 입력이 CP949로 한 번 잘못 읽힌다** (2026-09-29 확인). 바이트 수가 홀수인 한글 뒤에 따옴표가 오면
  따옴표가 사라져 JSON이 깨진다(예: 검색어 "전"은 깨지고 "전전"은 멀쩡하다). 그대로 거부하면 한글 검색이 모두 막힌다.
  그래서 JSON이 깨지면 경로 칸(`path`, `file`, `dir`, `glob`, `target`이 든 키)의 값만 골라 더 넓은 규칙으로 보고,
  경로 칸을 하나도 못 찾으면 거부한다. 파일 내용이 든 입력(`beforeReadFile`)은 내용이 아니라 경로로만 판단한다
- `tool_input`의 모든 문자열을 비밀 경로 규칙과 대조한다. `Grep`에 비밀 파일 경로를 직접 넣는 우회도 이것으로 막는다
- 폴더 전체 검색은 `.gitignore`를 따른다. 비밀 파일은 반드시 `.gitignore`에 있어야 한다(현재 `.env*`는 있음)
- 이 훅은 같은 저장소의 IDE 에이전트에도 적용되는데, 어차피 지키는 규칙이라 문제없다

---

## 9. 실패 처리

| 상황 | 처리 |
|------|------|
| 시작 실패 (`CursorSdkError`) | `isRetryable`이면 대기열로 되돌린다(같은 회차 최대 3회). 아니면 `failed` |
| 실행 결과 `status: "error"` | 재시도하지 않는다. 사유를 남기고 `failed` |
| 형식에 맞지 않는 답 | 원문을 저장하고 `needs_review`. 운영자가 원문을 보고 판단한다 |
| 한 회차 15분 초과 | 실행을 취소하고 `failed` (`timeout`) |
| 앱에서 취소 | 대기 중이면 바로 `cancelled`. 실행 중이면 다음 진행 신호 때 실행을 취소하고 `cancelled` |
| 작업자를 끔 (Ctrl+C) | 실행을 멈추고 대기열로 되돌린다. 다음에 켜면 처음부터 다시 조사한다 |
| 작업자가 죽음 | 점유(120초)가 만료되면 다음 가져가기 때 되돌린다. 시도가 3회를 넘으면 `failed`, 취소 요청이 있었으면 `cancelled` |
| 작업자가 꺼져 있음 | 요청은 대기열에 남는다. 앱은 마지막 신호가 2분 넘게 없으면 "작업자 꺼짐"을 표시한다 |
| Think 검토 실패 (2단계) | Cursor 결과는 보존한다. 검토 없이 `needs_review`로 두고 다시 검토할 수 있게 한다 |
| 하루 한도 초과 | 보내기를 막는다 (`code_request_daily_limit`). 초안은 남는다 |

---

## 10. 비용

- Cursor 비용은 운영자 개인 Cursor 요금제로 청구된다. Cursor 사용량 화면에는 SDK 항목으로 표시된다.
- 작업자가 받은 토큰 수를 `ai_runs`에 `provider = 'cursor'`, `feature = 'code_request'`로 기록한다.
  SDK로 달러 비용을 받을 수 없어서 `cost_usd`는 비어 있다. 금액은 Cursor 사용량 화면에서 확인한다.
  그래서 Cursor 몫은 Think 월 한도 합계에 넣지 못하고, 대신 하루 보낸 요청 수로 제한한다(기본 10건).
  사용량 탭의 기능별 표에는 "코드 조사 (Cursor)"로 토큰만 보인다.
- 요청 1건 = Cursor 실행 최대 2회 + OpenAI 호출 최대 3회(초안, 검토, 정리).

---

## 11. 단계

0. **확인** (2026-09-29 완료, 결과는 11.1): Cursor 키, SDK 설치, Windows 로컬 실행, 읽기 전용 제한, 비밀 파일 차단 훅, 비용 조회
1. **대기열 + 작업자 + 1회 조사** (2026-09-29 구현): 테이블·RPC, `ai_code_bridge`, 작업자, 매니저앱 "코드 조사" 탭.
   요청은 수동 작성(대화 버튼으로 미리 채우기), 결과는 정리된 형태 + 원문. 요청 목록·상태, 작업자 상태, 판단 기록 포함
2. **Think 연결 + 코드 수정** (2026-09-30 구현): 채팅 제안(`propose_code_request`·`propose_code_change`),
   자동 검토 `code_review`(초안·정리를 한 번에 대신한다), 2회 왕복, 대화에 답 붙이기, 수정 모드(격리 복사본·diff·적용·되돌리기).
   작업자 `PROMPT_VERSION = 'code_bridge.v2'`, 검토 `REVIEW_PROMPT_VERSION = 'code-review-2026-09-30'`
3. **화면 다듬기**: 채택 → 결정 초안 연결

별도 브랜치·커밋·PR로 올리는 것은 여전히 범위 밖이다. 적용은 작업 폴더에만 하고 커밋은 사람이 한다.

### 11.1 0단계 결과 (2026-09-29)

`@cursor/sdk` 1.0.32, Node 22.20, Windows. 실제 저장소가 아닌 임시 폴더의 가짜 저장소에 미끼 비밀 파일을 두고 시험했다.
모델은 `composer-2.5`. 키로 쓸 수 있는 모델은 43개였다(`Cursor.models.list()`).

| 시험 | 결과 |
|------|------|
| plan 모드 + 읽기 도구만: 파일 만들기·셸 실행 요청 | 통과. 둘 다 실행되지 않았고 에이전트도 그렇게 보고했다 |
| agent 모드 + 읽기 도구만: 같은 요청 | 통과. 편집·셸 도구가 아예 없어 실행할 수 없었다. 도구 제한만으로도 막힌다 |
| 비밀 파일 직접 읽기 (훅이 BOM을 벗기지 않았을 때) | **실패**. 훅이 입력을 해석하지 못하고 통과시켜 미끼 값이 읽혔다 |
| 비밀 파일 직접 읽기 (BOM 제거 + 해석 실패 시 거부) | 통과. `Read` 두 건 모두 거부됐다 |
| 검색으로 우회 (폴더 전체 grep) | 통과. `.gitignore`에 있는 파일은 검색 결과에 나오지 않았다 |
| 달러 비용 조회 (`getUsage`) | 사용 불가 (`feature_unavailable`) |

응답 시간은 한 번에 20~30초였다.

---

## 12. 하지 않는 것

승인 없는 코드 수정·적용, 커밋·PR 자동 생성, 셸 명령, 클라우드 에이전트, IDE 채팅창 조작, 비공식 API,
작업자에게 service role 키 주기, Cursor 결과로 결정·기억 자동 확정, 요청 사이 맥락 넘기기.

## 13. 코드 위치

| 무엇 | 어디 |
|------|------|
| 테이블·RPC | `supabase/migrations/20260929160000_ai_code_bridge.sql`, `20260930100000_ai_think_actions.sql`(수정 모드·적용·검토·제안) |
| 작업자용 함수 | `supabase/functions/ai_code_bridge/` (`handler.ts`, `validate.ts`, `code_review.ts`, `review_store.ts`, 시험 `handler_test.ts`, `code_review_test.ts`) |
| 작업자 | `tools/code_bridge/` (`src/worker.mjs`, `src/lib.mjs`, `src/git_ops.mjs`, `src/bridge_client.mjs`, 시험 `test/`) |
| 비밀 파일·경로 차단 훅 | `.cursor/hooks.json`, `.cursor/hooks/deny-secrets.mjs` |
| 매니저앱 | `services/think/think_code_models.dart`, `think_code_controller.dart`, `think_action_models.dart`, `think_api.dart`의 코드·제안 부분, `screens/think/think_action_cards.dart`(채팅 카드), `think_code_views.dart`(결과·diff), `think_code_requests_dialog.dart`(전체 요청 창), `think_code_request_dialog.dart`, 시험 `test/think_code_test.dart`, `test/think_actions_test.dart` |

열린 질문은 없다. 2단계(Think 자동 검토·2회 왕복)는 1단계를 실제로 몇 번 써 본 뒤 시작한다.
