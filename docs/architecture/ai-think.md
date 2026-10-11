# Think (플랫폼 AI) 설계

운영자(슈퍼관리자)가 매니저앱에서 AI와 대화하며 교육철학·원칙·결정을 정리하는 기능.
2026-09-28 에 DB, Edge Function, 매니저앱 화면까지 반영했다.
학습앱의 메모 요약·추출도 같은 서버 경로(`ai_memo_assist`)로 옮겼다.

관련 규칙: [`.cursor/rules/ai-think.mdc`](../../.cursor/rules/ai-think.mdc)
결정 스펙 모음: [`docs/specs/`](../specs/README.md)

---

## 1. 원칙

1. **AI는 판단을 돕고, 결정은 사람이 한다.** AI가 만든 결정은 초안일 뿐이고,
   운영자가 확인해 "승인하고 저장"해야 `active`가 된다.
2. **AI는 DB를 직접 바꾸지 않는다.** AI 도구는 읽기 도구와 "제안" 도구뿐이다. 제안 도구는
   `ai_actions`에 제안 1행을 남길 뿐이고, 실제 실행(코드 요청 보내기, 대화 분류, 삭제)은 사람이 채팅 카드에서
   승인할 때 `ai_action_apply` RPC가 한다([`ai-think-actions.md`](ai-think-actions.md)).
   기억(`ai_memories`)에 쓰는 것은 매니저앱 클라이언트이고, 사람이 버튼을 눌렀을 때만 쓴다. 제안으로 기억·결정을 만들지 않는다.
   raw SQL, 마이그레이션, 스키마 변경을 AI에게 주지 않는다.
3. **OpenAI 키는 Edge Function 비밀값(`OPENAI_API_KEY`)에만 있다.** 앱, DB, Git 어디에도 두지 않는다.
   예전의 `platform_config.openai_api_key` 행은 삭제했고 테이블은 슈퍼관리자 전용으로 잠갔다.
4. **AI가 없어도 앱은 돈다.** 키가 없거나 한도를 넘으면 Think는 안내만 띄우고,
   학습앱 메모 기능은 예전의 정규식 방식으로 돌아간다.
5. **기억 ≠ 대화, 결정 ≠ 대화, 결정 ≠ DB 변경.** 대화 기록은 그대로 두고,
   남길 가치가 있는 결론만 기억으로 옮긴다. 결정이 확정돼도 코드나 데이터는 자동으로 바뀌지 않는다.
   구현이 필요하면 스펙으로 내보내 Cursor에서 작업한다.
6. **교육철학과 AI 비용은 플랫폼 전체 공통이다.** 학원별 과금은 나중 일이다.
   그때를 위해 `ai_runs.academy_id`만 남겨 둔다(메모 요약은 이미 채운다).

---

## 2. 구성

```
매니저앱 Think 화면 ──(SSE, 사용자 JWT)──▶ ai_think ──▶ OpenAI Responses API
      │                                     │  └─ 읽기 도구 (기억·교육과정·개념·행동카드)
      └─(PostgREST, RLS)──▶ ai_* 테이블 ◀────┘  (사용자 JWT로 읽음, 기록은 service role)

학습앱 메모 ──(functions.invoke)──▶ ai_memo_assist ──▶ OpenAI (fast 모델)
성향 리포트 ──────────────────────▶ trait_report_run ─▶ OpenAI (키는 비밀값만 읽음)
```

| 위치 | 역할 |
|------|------|
| `supabase/functions/_shared/ai/` | 공용 모듈. provider 인터페이스(`types.ts`), OpenAI 구현(`openai.ts`), 테스트용 가짜(`fake.ts`), 모델·가격 설정(`config.ts`), 사용량 기록(`usage.ts`), 월 한도(`budget.ts`), 인증(`auth.ts`) |
| `supabase/functions/ai_think/` | Think 대화. `prompts.ts`(프롬프트·버전), `context.ts`(맥락 조립), `tools.ts`(읽기 도구), `chat.ts`(스트리밍 루프), `drafts.ts`(결정 초안·스펙), `store.ts`(DB 접근) |
| `supabase/functions/ai_memo_assist/` | 학습앱 메모 요약·일정/연락처/이름 추출 |
| `apps/yggdrasill_manager/lib/services/think/` | 매니저앱 API·SSE 클라이언트(`think_api.dart`), 상태(`think_controller.dart`), 모델 |
| `apps/yggdrasill_manager/lib/screens/think/` | Think 화면(대화·기억·사용량 탭, 결정 초안·스펙 대화상자) |

매니저앱 메인 화면은 선택하지 않은 메뉴를 트리에서 뺀다. 그래서 대화 상태와 답변 스트림은
화면이 아니라 `ThinkController` 싱글턴에 둔다. 답변을 받는 중에 다른 메뉴에 다녀와도 끊기지 않는다.

---

## 3. 테이블

정의: `supabase/migrations/20260928100000_ai_think_core.sql`, `20260928100100_lock_platform_config.sql`,
`20260929150000_ai_think_tree.sql`

| 테이블 | 역할 | 쓰는 주체 |
|--------|------|-----------|
| `ai_conversations` | 대화 묶음 (제목, 보관 여부, 메시지 수) | ai_think, 매니저앱(이름·보관·삭제) |
| `ai_messages` | 대화 메시지. 첨부·출처·도구 기록·진행 메모·모델. `context_excluded`(답변에서 제외) | ai_think, 매니저앱(제외 전환) |
| `ai_tree_nodes` | 대화 정리 트리. `kind` = folder / conversation(대화 배치) / excerpt(발췌) / document(종합 문서) | 매니저앱(사람) |
| `ai_tree_node_sources` | 발췌 → 원본 메시지 연결 (메시지가 지워지면 함께 지워짐) | 매니저앱 |
| `ai_memories` | 기억. `kind` = identity / principle / decision / note, `status` = draft / active / superseded / archived | 매니저앱(사람의 승인) |
| `ai_memory_revisions` | 기억의 모든 버전 스냅샷 (트리거가 씀) | 트리거 |
| `ai_runs` | AI 호출 1건 = 1행. 모델, 토큰, 비용, 지연, 오류 | Edge Function(service role) |
| `ai_platform_settings` | 한 행짜리 설정. 월 한도(USD), 초과 시 경고/차단, 웹 검색 허용 | 매니저앱 |
| `ai_actions` | AI 작업 제안(코드 조사·수정, 대화 분류, 삭제). `proposed` → `applied` / `rejected` / `undone` | ai_think(제안 RPC), 매니저앱(승인 RPC) |
| `ai_relay_asks` | Cursor가 Think에게 물은 기록(질문 본문은 저장하지 않음, 한도 계산용). §12 | ai_think_relay·ai_code_bridge(service role RPC) |

`ai_conversations.origin`(owner / cursor), `ai_messages.asked_by`(cursor_ide / cursor_worker), `ai_messages.relay`(판정)는
커서 문의용 열이다(§12, `20261010100000_ai_think_relay.sql`).

- RLS: 모두 슈퍼관리자(`public.is_superadmin()`)만. `ai_runs`, `ai_memory_revisions`는 읽기만 허용한다.
- 기억 수정은 낙관적 잠금: `update ... where id = ? and version = ?`. 결과가 비면 다른 곳에서 먼저 고친 것이다.
  `version`은 트리거가 올린다. `active`가 되면 `approved_at`, `approved_by`도 트리거가 채운다.
- 결정이 다른 결정을 대체하면 `supersedes_id`를 채운다. 새 결정이 `active`가 될 때 매니저앱이 옛 결정을 `superseded`로 바꾼다.
- 첨부: 비공개 버킷 `ai-attachments`, 경로 `{user_id}/{yyyyMM}/{uuid}-{파일명}`, 20MB, PNG·JPG·WEBP·GIF·PDF.
  OpenAI에는 900초짜리 서명 URL로 넘긴다.
- RPC: `ai_search_memories(p_terms, p_limit)`(키워드 점수 검색; **승인 후** `20261008210000_ai_search_memories_active_only.sql` 적용 시 `active`만 검색),
  `ai_usage_summary(p_from, p_to)`(KST 일·기능·모델별 합계),
  `ai_month_cost_usd()`(KST 이번 달 비용).
- 시드: identity "교육철학"(`docs/assessment/philosophy.md` 전문), identity "AI의 역할".

### 3.1 대화 정리 트리 (2026-09-29, 2단계까지)

- **트리는 사람이 보는 정리용이다. 답변 맥락에 넣지 않는다.** (2026-09-30 바뀜) 사용자가 분류를 부탁하면
  AI가 `list_tree_folders` 도구로 **폴더 이름·경로와 대화 제목만** 읽는다. 발췌 제목·요약·원문과
  "답변에서 제외"한 문답은 읽지 않는다. 분류는 제안으로만 하고, 승인 전에는 트리에 저장하지 않는다.
- 트리에 대화 노드가 없는 대화는 화면에서 "정리 안 됨"에 모인다. 기존 대화는 옮기지 않았다.
  "정리 안 됨"으로 빼면 대화 노드만 지운다(대화는 그대로).
- 부모는 폴더만 된다. 순환·12단계 초과·다른 대화 메시지로 만든 발췌는 트리거와 RPC가 막는다.
  폴더는 `on delete restrict`라 직접 못 지우고, `ai_tree_delete_folder`가 안의 항목을 폴더 자리로 올린 뒤 지운다.
- RPC: `ai_tree_move(p_node_id, p_parent_id, p_index)`, `ai_tree_place_conversation(p_conversation_id, p_parent_id, p_index)`,
  `ai_tree_delete_folder(p_folder_id)`, `ai_tree_create_excerpt(...)`, `ai_tree_create_document(...)`, `ai_tree_get_document(...)`,
  `ai_tree_update_document(...)`.
  `p_index`는 옮기는 항목을 뺀 형제 기준 자리이고, 숨긴(보관된) 대화 노드도 센다.
- **종합 문서(2026-10-07, 1단계):** 사용자가 선택한 메시지 출처만 대화 시간 순으로 연결한다(앞 맥락 자동 추가 없음).
  `body`는 발췌 `summary`와 구분되는 본문이다. 출처 메시지가 하드 삭제되면 문서 노드 전체를 삭제한다.
  발췌는 출처 연결이 사라져도 노드를 유지한다. `list_tree_folders`·트리 읽기 도구 응답에는 문서 본문·출처 원문을 넣지 않는다.
  **2026-10-10:** 사용자가 대화에 **명시적으로 연결**하고 권한이 확인된 종합 문서 본문만 `buildThinkContext`가 AI에 전달한다(토큰·길이 예산 안). 연결되지 않은 문서·폴더·대화 주제 추정으로 본문을 보내지 않는다.
- 대화를 지우면 그 대화의 배치 노드·발췌·종합 문서도 함께 지워진다(FK cascade). 삭제 확인·삭제 제안 미리보기에 발췌·종합 문서 수를 보여 준다.
- "답변에서 제외"는 질문과 그 답변을 한 문답으로 묶어 함께 바꾼다(`thinkTurnIndices`).
  제외한 메시지는 `store.listMessages`에서 빠지므로 대화 기록·결정 초안·스펙 내보내기 모두에 들어가지 않는다.
  화면과 트리에는 흐리게 남는다.
- AI 정리 제안(대화 분류 미리보기·승인·되돌리기)은 2026-09-30에 채팅 카드로 넣었다([`ai-think-actions.md`](ai-think-actions.md)).
- 아직 없는 것(확인 뒤 진행): 트리 변경 이력, "좋은 답" 별점, AI 요약 초안, 파생 기억을 골라 지우는 영구 삭제.

---

## 4. 맥락 조립 (`ai_think/context.ts`, `access_context.ts`)

요청마다 아래 순서로 조립한다. 앞쪽이 매번 같아야 프롬프트 캐시가 맞으므로 순서를 바꾸지 않는다.

**역할·자료 범위(2026-10-10):** 대화 `think_role_id`(lead/education/product/engineering), 사용자가 고른 추가 참조 부서, 대화에 연결한 승인 active 기억·종합 문서 링크로 `AccessContext`가 판정한다. identity(교육철학)는 역할과 무관하게 유지한다. lead는 허용 범위 안에서 관련도·건수 예산으로 principles·decisions 등을 고른다. `get_memory`·`search_memories`·instructions 주입·`buildThinkContext`·명시 연결 문서 본문 경로가 같은 판정을 쓴다. draft 조회(피드백 편집)는 AI 맥락과 분리한다. 답변마다 `ai_message_context_snapshots`에 당시 역할·실제 전달 자료 id만 남긴다. 기능 `think_roles`는 Edge·DB·앱 버전이 모두 준비됐을 때만 활성화한다. 승인 active가 아닌 기억은 역할과 무관하게 AI에 가지 않는다. 기억 검색은 DB 단계(`ai_search_memories_scoped`)에서 거르고, 역할 프로필 버전(`ROLE_PROFILE_VERSION`)은 `ai_runs.role_profile_version`과 캐시 키에 들어간다. 새 대화의 역할은 요청 `body.role`로 받아 서버가 저장하고, 이어지는 대화는 저장된 역할만 쓴다. 마이그레이션 `20261010160000_ai_think_roles.sql`, 자세한 내용과 예외는 `ai-think-actions.md` §8.

1. `instructions`: 공통 역할 규칙 → (기능 준비 시 역할 프로필) → identity 전문 → principle 요약 → 최근 확정 결정(id 포함) → 대화 범위(scope)
2. 대화 기록: 최근 40개, 최대 6만 자. 오래된 것부터 뺀다. 첨부는 최근 사용자 메시지 2개까지만 다시 보낸다.
   "답변에서 제외"한 메시지(`context_excluded`)는 처음부터 읽지 않는다. 다른 대화와 정리 트리는 넣지 않는다.
   나눠 온 대화면 나눌 때 정한 요약(`split_summary`)을 기록 맨 앞에 사용자 역할의 "참고 자료"로 넣는다(지시가 아님,
   [`ai-think-actions.md`](ai-think-actions.md) §7).
3. 작업 상태 메모(기존 대화만): 이 대화의 최근 제안 10개와 코드 요청 8개의 종류·상태·결과 요약(diff 본문은 넣지 않음).
   AI가 "앞에서 낸 제안이 어떻게 됐는지"를 알고 이어 가게 한다. 없으면 넣지 않는다.
   그 뒤에 "실행 환경 기능 상태" 메모(서버가 이번 요청에서 계산한 기능 상태, [`ai-think-actions.md`](ai-think-actions.md) §7.1)를 넣는다.
4. 관련 기억 메모: 질문에서 뽑은 검색어로 `store.searchMemories`를 불러, 1번에 이미 들어간 것을 빼고 최대 6개.
   Edge는 RPC 결과에서 `active`만 남기며, RPC가 draft를 함께 반환하는 **구버전 배포**에서는 한도(최대 30)까지 여유 있게 가져온 뒤 자른다.
   draft가 슬롯을 차지해 승인 기억이 밀릴 수 있어, 운영 DB에 `20261008210000_ai_search_memories_active_only.sql` 적용 전에는 완전한 한도 보장을 주장하지 않는다.
   `get_memory`·`search_memories` 도구도 `active`만 AI에 노출한다. `store.getMemory`는 draft 조회(피드백 초안·스펙)용으로 그대로 둔다.
5. 이번 사용자 메시지(+첨부)

한도 값은 `CONTEXT_LIMITS`에 모여 있다. 화면 오른쪽 "맥락" 패널에 무엇이 들어갔는지 표시된다.

## 5. 도구 (`ai_think/tools.ts`, `ai_think/actions.ts`)

읽기: `search_memories`, `get_memory`, `get_curriculum_outline`, `search_concepts`, `list_concept_categories`,
`search_behavior_cards`, `list_tree_folders`, `list_conversations`, `list_code_requests`, `get_code_request`.
제안: `propose_code_request`, `propose_folder`, `propose_delete`, `propose_conversation_split`
(대화 나누기 기능 상태가 준비됨일 때만 노출, [`ai-think-actions.md`](ai-think-actions.md) §7).
조율: `start_code_plan` — 코드 수정은 Think가 바로 고치게 하지 않고 Cursor와 계획을 조율한 뒤 조율본을 운영자에게 승인받는다.
읽기 전용이라 승인 없이 시작하지만, 시작 전에 대화로 의도를 확인하게 지시한다
(2026-10-01, `propose_code_change`를 대신함. [`ai-think-actions.md`](ai-think-actions.md) §4.3).
필수 값이 비면 제안하지 않고 `missing_fields`를 돌려주며, 지시문대로 AI가 사용자에게 되묻는다.
모두 사용자 JWT로 읽고 쓰므로 RLS·RPC 권한 검사가 그대로 적용된다.
도구가 실패해도 예외를 던지지 않고 오류 내용을 모델에게 결과로 돌려준다. 결과는 1만 2천 자에서 자른다.
한 답변에서 도구 라운드는 최대 6번이고, 벽시계 시간의 65%가 지나면 도구 없이 답하게 한다.

커서 문의 답변(§12)에서는 제안·조율 도구(`ACTING_TOOL_NAMES`)를 빼고 읽기 도구만 준다. 모델이 그래도 부르면 실행하지 않고 오류를 돌려준다.

도구를 추가할 때: `THINK_TOOLS`에 스키마(strict, `additionalProperties: false`, 선택 값은 null 허용)를 추가하고
`ThinkToolSource`에 읽기 메서드를 만든다. **쓰기 도구는 만들지 않는다.** 실행이 필요한 일은
`ai_actions` 제안 종류를 늘리고 승인 RPC(`ai_action_apply`)에 실행을 넣는다.

---

## 6. `ai_think` 프로토콜

`POST /functions/v1/ai_think` · `Authorization: Bearer <사용자 JWT>` · 슈퍼관리자가 아니면 403

| action | 요청 | 응답 |
|--------|------|------|
| `status` | `{client?{features}}` | `{configured, provider, models{primary,deep,fast}, web_search_enabled, budget{limit_usd,mode,spent_usd,exceeded}, prompt_version, features{conversation_split{state,edge,db,app,permitted}}, features_db_error}` |
| `chat` | `{conversation_id?, message, attachments?[{path,name,mime,size}], options?{deep, web_search}, client?{features}}` | SSE 스트림 (아래) |
| `decision_draft` | `{conversation_id}` | `{draft{title,context,decision,reason,alternatives,conflicts,open_questions,tags}, run_id}` |
| `memory_feedback_draft` | `{conversation_id, assistant_message_id, user_message_ids?, feedback, update_memory_id?}` | `{draft{candidates[], duplicate_warnings[], insufficient_evidence, notes}, run_id, update_baseline?{memory_id, version}}` — 수정 대상을 고른 경우 AI 호출 **전**에 읽은 id·version을 고정한다. 매니저앱은 기존 기억 수정 저장 시 이 version으로 낙관적 잠금한다. |
| `spec_export` | `{memory_id}` (확정된 결정만) | `{markdown, suggested_path, run_id}` |

스트림 전에 나는 오류는 JSON `{ok:false, error, message}`:
400 `message_too_long` · `message_required` · `attachments_*` · `conversation_id_invalid`,
401, 403 `forbidden`, 429 `budget_exceeded`, 503 `ai_not_configured`, 500.

SSE 이벤트 (15초마다 `: ping` 주석):

| event | data |
|-------|------|
| `notice` | `{code: budget_warning \| web_search_disabled}` |
| `conversation` | `{conversation_id, user_message_id, title, created, model, features, split_suggestions, context{identity, principles, decisions, relevant[], history_used, history_dropped, split_summary}}` |
| `message_start` / `message_done` | `{item_id, phase}` — phase는 `message_done`에서 확정된다 (`commentary`면 본문이 아니라 진행 메모) |
| `delta` | `{item_id, text}` |
| `tool` | `{call_id, name, label, status: running \| done, ok?, detail?}` |
| `action` | `{action}` — 제안 도구가 남긴 `ai_actions` 행. 아직 `message_id`가 비어 있다 |
| `title` | `{conversation_id, title}` (새 대화일 때 빠른 모델이 만든 제목) |
| `done` | `{conversation_id, assistant_message_id, run_id, status: complete \| stopped, model, usage, web_search_calls, cost_usd, sources, action_ids}` |
| `error` | `{conversation_id?, assistant_message_id?, code, message, action_ids}` |

- 답변을 저장한 뒤 서버가 `ai_action_attach`로 이번 제안들에 답변 id를 붙인다. 앱은 `action_ids`로 같은 일을 화면에서 한다.

- 사용자 메시지는 AI 호출 전에 저장한다. AI가 실패해도 질문은 남는다.
- 클라이언트가 연결을 끊으면(중지) 서버는 받은 부분까지 `stopped`로 저장한다. 시간 초과는 `error` / `timeout`.
- OpenAI 요청은 `store: false`, 대화 이력은 매 요청 다시 보낸다(상태 없는 호출).
- 운영자가 커서 대화(`origin = 'cursor'`)에 이어 말하면 일반 대화로 답한다. 기록 속 커서 질문에는 "[Cursor가 보낸 질문]" 표시가 붙는다.
  Cursor 쪽 프로토콜은 `ai_think`가 아니라 `ai_think_relay`다(§12).

---

## 7. 모델·비용·한도

| 환경변수 (Edge Function 비밀값) | 기본값 | 뜻 |
|------|------|------|
| `OPENAI_API_KEY` | — | 필수. 없으면 `ai_not_configured` |
| `AI_PROVIDER` | `openai` | `fake`면 가짜 응답 (키 없이 화면 점검용) |
| `AI_MODEL_PRIMARY` | `gpt-6-sol` | 기본 대화, 결정 초안, 스펙 |
| `AI_MODEL_DEEP` | `gpt-6-astra` | "깊게 생각" |
| `AI_MODEL_FAST` | `gpt-6-luna` | 대화 제목, 메모 요약·추출 |
| `AI_REASONING_{PRIMARY,DEEP,FAST}` | medium / high / none | 추론 강도 |
| `AI_MAX_OUTPUT_{PRIMARY,DEEP,FAST}` | 16000 / 32000 / 600 | 출력 토큰 한도(추론 포함) |
| `AI_PRICING_JSON` | 내장 가격표 | `{"모델":{"input":..,"cachedInput":..,"cacheWrite":..,"output":..}}` (USD / 1M 토큰) |
| `AI_THINK_WALL_MS` | 140000 | 한 요청 최대 시간 (최소 30000) |

- 모델을 바꿀 때는 코드를 고치지 않고 `supabase secrets set AI_MODEL_PRIMARY=...`만 한다.
  가격표에 없는 모델은 `cost_usd`가 비고, 사용량 화면 합계에서 빠진다. 이때는 `AI_PRICING_JSON`을 넣는다.
- 비용 = (캐시 안 된 입력 × input + 캐시 입력 × cachedInput + 캐시 쓰기 × cacheWrite + 출력 × output) / 1M + 웹 검색 × $0.01.
  입력이 27만 2천 토큰을 넘으면 장문 가격을 쓴다.
- 월 한도는 KST 달 기준으로 `ai_runs.cost_usd`를 합해 판단한다. `warn`이면 `notice`만 보내고, `block`이면 429로 막는다.
  메모 요약(`ai_memo_assist`)도 `block`일 때 멈춘다. 메모 요약은 사용자당 분당 30회로 제한한다.

---

## 8. 결정 → 스펙 → 구현

1. 대화 → "결정으로 정리" → AI가 초안(충돌 가능성·열린 질문 포함)을 만든다.
2. 운영자가 고쳐서 "승인하고 저장"(active) 또는 "초안으로 저장"(draft). 다음 대화부터 AI가 확정 결정을 기억한다.
3. 기억 탭 → 확정 결정 → "스펙 내보내기" → `docs/specs/YYYYMMDD-제목.md`로 저장.
   저장 경로는 `ai_memories.spec_path`에 남는다.
4. Cursor에서 스펙 파일을 열어 구현을 지시한다. 구현 판단은 스펙과 `AGENTS.md`를 따른다.

---

## 9. 테스트·배포

- Deno: `npx -y deno@2 test supabase/functions/_shared/ai supabase/functions/ai_think supabase/functions/ai_memo_assist`
  가짜 provider(`FakeAiProvider`)를 쓰고, AI 문장을 정확히 비교하지 않는다.
- Flutter: `apps/yggdrasill_manager/test/think_client_test.dart` (SSE 디코더, 오류 변환, 기억 행, 수식 렌더링),
  `think_tree_test.dart`(트리 구성, 끌어 놓기 계획, 문답 묶기), `think_tree_widget_test.dart`(좁은 폭 렌더링),
  `think_code_test.dart`(코드 요청 모델·전체 요청 창), `think_actions_test.dart`(제안 카드, diff 나누기, 적용 상태, 트리 강조),
  `think_connection_test.dart`(프로젝트 ref·migration 경로·상태 JSON), `think_document_test.dart`(종합 문서·답변 타일)
- `memory_feedback_draft`·기억 AI 노출: `supabase/functions/ai_think/memory_feedback_test.ts`, `tools_test.ts`, `context_test.ts`
- `ai_search_memories` active-only: `tools/db_test/test/ai_search_memories_active_only.test.mjs` (마이그레이션 `20261008210000_ai_search_memories_active_only.sql`, 운영 반영은 별도 승인)
- 커서 문의(§12): `ai_think/relay_test.ts`, `ai_think_relay/handler_test.ts`, `ai_code_bridge/handler_test.ts`(ask_think),
  `tools/db_test/test/ai_think_relay.test.mjs`, `tools/think_relay/test`, `tools/code_bridge/test/ask_think.test.mjs`,
  `apps/yggdrasill_manager/test/think_relay_test.dart`
- 배포: `supabase db push` → `supabase functions deploy ai_think ai_memo_assist --use-api` (Docker가 없으면 `--use-api`).
  코드 연동은 `supabase functions deploy ai_code_bridge --no-verify-jwt --use-api`,
  커서 문의는 `supabase functions deploy ai_think_relay --no-verify-jwt --use-api`.
  `trait_report_run`은 survey-web 관리자 페이지 전용이고, 2026-09-28 현재 원격에 배포돼 있지 않다.
- 키 교체: `supabase secrets set OPENAI_API_KEY=<새 키>` 후 OpenAI 대시보드에서 옛 키 폐기.

## 10. 일부러 하지 않은 것

자동 커리큘럼 생성, 전체 학생·문항 자동 분석, AI의 DB 쓰기·스키마 변경·마이그레이션·임의 SQL,
Codex 연동, 멀티 에이전트, 벡터 DB, 복잡한 모델 라우터. 기억 검색은 키워드 점수 방식이다.
멀티 에이전트의 예외로, 코드 조사 연동(Think ↔ Cursor, 조사·제안 전용)을 2026-09-29에 범위에 넣었다.
설계와 구현(운영자 PC 작업자)은 [`ai-code-bridge.md`](ai-code-bridge.md)에 있다. 2026-09-30부터는 "코드 조사" 탭 없이
채팅 카드로 다루고, 코드 수정도 격리 복사본 + diff 확인 + 적용 승인으로 할 수 있다([`ai-think-actions.md`](ai-think-actions.md)).
Cursor에게 셸 명령은 주지 않는다. Cursor 결과로 결정·기억이 확정되지 않는다.
기억이 수백 개를 넘어 검색 품질이 떨어지면 그때 임베딩 검색을 검토한다.

---

## 11. 개인 DB 업무 위임 (후속 설계, 2026-10-08)

운영자 PC·개인 Supabase 등 **개인 DB**에 Think/Cursor가 일을 맡기는 범위는 아직 코드로 열지 않았다.
매니저앱의 **연결 상태·probe·코드 diff의 migrations 안내**는 운영 DB를 바꾸지 않으며,
“RPC가 있다” 수준의 확인만 한다. 조회 성공만으로 생성·수정·운영 반영까지 가능하다고 주장하지 않는다.

### 11.1 허용 데이터의 기본 원칙

- **최소 수집:** 업무에 필요한 테이블·행만, 필요한 기간만.
- **목적 고정:** 조사·계획·승인된 작업과 무관한 테이블은 읽지 않는다.
- **운영 DB와 분리:** 플랫폼 `ai_*`·학습 기록·학생 식별 정보는 개인 DB 위임 대상이 아니다(별도 결정 전).

### 11.2 개인정보 제외

- 자동으로 개인정보를 완전히 제외·마스킹한다고 **보장하지 않는다.**
- 검증 방법(후보): 허용 테이블 화이트리스트, 컬럼 denylist, 샘플링 감사, Edge/작업자 측 읽기 필터.
- 보장할 수 없는 경우: 원문이 개인 DB에 들어간 뒤에는 앱만으로 삭제·법적 범위를 증명하기 어렵다 →
  **쓰기 전 사람 검토**와 **범위가 좁은 읽기**를 전제로 한다.

### 11.3 권한

- **읽기:** 승인된 작업 단위·승인된 테이블 목록에 한함. 서비스 롤 키를 매니저앱에 두지 않는다.
- **쓰기:** 작업(마이그레이션, 배포, 데이터 수정)마다 운영자 명시 승인. AI·Cursor는 승인 없이 쓰지 않는다.
- **철회:** 연결 토큰·API 키 폐기, 작업자 중지, RLS/정책 되돌리기 — 복구 경계는 “승인 시점 백업”까지(미백업 구간은 복구 불가).

### 11.4 감사·복구

- 감사: `ai_runs`, 코드 요청·적용 기록, (개인 DB 연동 시) 읽기/쓰기 로그를 운영자가 볼 수 있게 남긴다.
- 복구: 운영 DB는 `db push` 전 백업·대상 프로젝트 확인을 운영자 책임으로 둔다. 앱은 push/배포 버튼을 제공하지 않는다.

### 11.5 이번에 하지 않은 것

- 개인 DB 연결 코드, 허용 테이블 목록의 임의 확정, 매니저앱에서의 자격 증명 수집 UI.
- 답변 피드백 기억 초안(`memory_feedback_draft`)은 **플랫폼 ai_memories**에만 쓰이며, 운영자가 버튼으로 저장할 때만 반영된다.

---

## 12. 커서 문의 (Cursor → Think, 2026-10-10)

지금까지는 Think가 Cursor에게 일을 맡기는 한 방향이었다. 이제 Cursor도 Think의 기억·대화를 읽고 Think에게 물을 수 있다.
묻는 곳은 두 군데다.

| 묻는 쪽 | 경로 | 범위 |
|---------|------|------|
| 운영자 PC의 Cursor 작업창(IDE) | MCP 서버 `tools/think_relay` → Edge `ai_think_relay` | 읽기 7종 + `ask_think` |
| 코드 작업자 Cursor | 작업자 customTool `ask_think` → Edge `ai_code_bridge`(`action: ask_think`) | 조사·조율 작업에서만, 작업 회차당 3번 |

### 12.1 운영자가 정한 것

- **읽기 범위:** 승인된 기억(active), 대화 제목·목록, 코드 요청 요약(diff 없음), 대화 본문. 대화 본문에서
  "답변에서 제외"한 문답은 빠진다(`store.listMessages`를 그대로 쓴다). 초안·보관 기억은 읽지 못한다.
- **작업자:** 조사·조율(읽기 전용)에서만 묻는다. 수정 작업은 Think가 정한 범위를 따르므로 묻지 않는다.
- **판정은 근거가 있을 때만 확정:** 답마다 서버가 판정을 붙인다.
  - `answered`: 근거로 든 기억 중 하나 이상이 지금 active이고, 운영자에게 물을 질문이 없을 때만.
  - `needs_owner`(사장님 확인 필요): 그 밖의 모든 경우. 판정 블록이 없거나 깨졌거나, 근거가 active가 아니거나,
    확인 질문이 남은 경우도 여기로 떨어진다(fail-closed, `relay_verdict.ts`의 `downgraded`에 이유).
  - Cursor는 `needs_owner` 답을 근거로 진행하지 않는다. IDE는 운영자에게 확인 질문을 전하고, 작업자는 결과의
    `questions_for_owner`(조율) / `questions_for_think`(조사)에 옮겨 적는다.

### 12.2 답이 만들어지는 방식

- `ai_think/relay.ts`의 `runRelayAsk`가 한도를 먼저 잡고(`ai_relay_reserve`) 일반 대화 루프(`runThinkChat`)를
  커서 문의 모드로 돌린 뒤 `ai_relay_finish`로 마감한다.
- 커서 문의 모드: 지시문 끝에 "커서 문의 모드" 규칙(`relayInstructions`)을 붙이고, 도구는 읽기만 준다.
  Think는 답 끝에 ```relay 판정 블록(근거 기억 id, 확인 질문)을 붙이고, 서버가 저장 전에 떼어 내 다시 확인한다.
  판정은 `ai_messages.relay`에, 질문 출처는 `ai_messages.asked_by`에 남는다.
- 대화: IDE 질문은 새 커서 대화(`origin = 'cursor'`)를 만들고, `conversation_id`로 이어 물을 수 있다.
  운영자 대화에는 이어 붙이지 못한다(403 `relay_conversation_not_cursor`). 작업자 질문은 요청마다 대화 하나
  ("작업자 문의: {요청 제목}")를 다시 쓴다. 운영자는 Think 화면에서 이 대화를 보고 직접 이어 말할 수 있다.
- 기록: `ai_runs.feature = 'think_relay'`, `created_by`는 비운다(사람이 아님). 월 한도가 `block`이면 429.

### 12.3 한도·인증

- 하루(KST) 60번(`THINK_RELAY_DAILY_LIMIT`), 작업자는 요청 회차당 3번. `ai_relay_reserve`가 advisory lock 안에서 센다.
  작업자 질문은 요청이 `running`이고 그 작업자가 잡고 있으며 조사·조율일 때만 받는다.
- IDE: 전용 토큰. 서버는 `THINK_RELAY_TOKEN_SHA256`만 갖고, 토큰은 운영자 PC의 `~/.yggdrasill/think_relay.token`
  (또는 환경 변수 `THINK_RELAY_TOKEN`)에만 둔다. 비밀값이 없으면 503.
- 작업자: 기존 작업자 토큰(`CODE_BRIDGE_WORKER_TOKEN_SHA256`) 그대로. 끄려면 작업자 환경 변수 `CODE_BRIDGE_ASK_THINK=off`.
- 작업자에 `ask_think`를 주려면 SDK 도구 목록에 `'mcp'`가 있어야 하고, `'mcp'`는 저장소 `.cursor/mcp.json`의 서버도 켠다.
  그래서 저장소에 `.cursor/mcp.json`이 있으면 작업자는 묻기를 끈다. IDE용 MCP 등록은 사용자 설정
  (`C:\Users\<사용자>\.cursor\mcp.json`)에만 둔다.

### 12.4 `ai_think_relay` 프로토콜

`POST /functions/v1/ai_think_relay` · `Authorization: Bearer <relay 토큰>` · JWT 검증 없음(`--no-verify-jwt`)

| action | 요청 | 응답 |
|--------|------|------|
| `status` | — | `{asker, daily_limit}` |
| `list_memories` | `{kinds?, limit?}` (기본 identity·principle·decision) | `{memories[{id,kind,title,excerpt,updated_at}]}` |
| `search_memories` | `{query, kinds?, limit?}` | 같은 모양, active만 |
| `get_memory` | `{id}` | `{memory}` (active가 아니면 404) |
| `list_conversations` | `{query?, limit?, include_archived?}` | `{conversations[{id,title,status,origin,message_count,last_message_at}]}` |
| `get_conversation` | `{conversation_id, limit?}` | `{conversation, messages[{role,asked_by,content,clipped,attachments}], older_messages_dropped}` (메시지당 8천 자, 합계 15만 자) |
| `list_code_requests` / `get_code_request` | `{query?, limit?}` / `{id}` | 요약·결과(diff 없음) |
| `ask` | `{question, conversation_id?}` | `{ask_id, conversation_id, verdict, answer, basis[], owner_questions[], downgraded}` |

실패는 `{ok:false, error, message}`: 401, 403 `relay_conversation_not_cursor`, 404, 429 `relay_daily_limit`·`budget_exceeded`,
503 `relay_not_configured`·`ai_not_configured`·`db_required`, 504 시간 초과.

### 12.5 하지 않은 것

- Cursor가 기억을 만들거나 고치는 길은 없다. 커서 대화의 답도 운영자가 승인하기 전에는 기억이 아니다.
- 커서 문의 모드에서 제안·코드 요청을 만들지 않는다. Think가 작업을 시작해야 하면 운영자 대화에서 한다.
- 질문 본문은 `ai_relay_asks`에 따로 저장하지 않는다(대화 메시지로만 남는다).
