# Think 작업 도구: 제안 → 승인 → 실행 (단일 작업 화면)

Think 채팅 한 화면에서 코드 조사, 코드 수정, 대화 분류, 삭제를 요청하고 결과까지 본다.
AI는 **제안만** 하고, 실제 변경은 사용자가 채팅 안 카드에서 승인한 뒤에만 일어난다.

**상태: 2026-09-30 배포. Think ↔ Cursor 조율(§4.3)은 2026-10-01 배포. 조율본 질문은 2026-10-02 구현. 자동 검사·자동 시작·자동 재수정(§4.5·§4.6)은 2026-10-07 구현. 앞 수정 이어받기(§4.7)는 2026-10-08 구현. 자동 정리 제안·정리 패널(§11)은 2026-10-12 구현. 과정 탐색도·개념 배치·개념 고치기 카드는 2026-10-23 구현·배포([`course-map.md`](course-map.md) §7).** 관련: [`ai-think.md`](ai-think.md), [`ai-code-bridge.md`](ai-code-bridge.md)

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

2026-10-07 운영자 결정 (역할 구조, §4.5·§4.6):

| 항목 | 결정 |
|------|------|
| 구조 | 운영자가 최종 소유자, Think가 그 아래 CEO, Cursor가 직원. Think가 조사·조율·수정·검사·재수정을 전반한다 |
| 운영자 승인 | 작업 폴더 적용과 운영 DB 반영·배포 두 가지만 운영자가 승인한다 |
| 자동 시작 | 정해 주실 것(질문)이 없는 조율본은 승인 카드 없이 바로 수정 요청을 보낸다(하루 한도 1건) |
| 자동 검사 | 작업자가 수정 뒤 복사본에서 analyze/test·Deno·작업자 시험·DB 시험(PGlite, 운영 DB 아님)을 돌려 카드에 통과/실패/미실행으로 남긴다 |
| 자동 재수정 | 검사가 실패하면 최대 2번까지 Think가 Cursor에게 다시 고치게 한다(1번에 하루 한도 1건). 그래도 실패하면 쉬운 말로 보고한다 |
| 적용 버튼 | 실패·미실행·검사 기록 없음이면 확인 창에서 경고한다. 막지는 않는다 |

---

## 1. 원칙

1. **AI 도구는 DB를 바꾸지 않는다.** 쓰기처럼 보이는 도구는 `ai_actions`에 "제안" 1행을 남길 뿐이다.
   제안은 대화에 AI가 쓴 메시지와 같은 성격이다(AI 자신의 출력 기록).
2. **실행은 승인 RPC 하나로만 한다.** `ai_action_apply(p_id)`가 슈퍼관리자 확인 → 상태 `proposed` 확인 →
   대상 다시 검증 → 실행 → 결과 기록을 한 트랜잭션으로 한다. 한 제안은 한 번만 실행된다.
3. **미리보기 없이 실행하지 않는다.** 카드에 무엇이 바뀌는지(폴더 경로, 지워질 메시지·발췌 수, 코드 diff)를 먼저 보인다.
4. **작업 폴더 적용은 운영자만 승인한다.** 적용 전에는 실제 작업 폴더가 바뀌지 않는다. 2026-10-07부터 수정 시작은
   질문 없는 조율본이면 자동(§4.6)이고, 질문이 있으면 운영자가 답해야 시작한다. 조율 시작(`code_plan`)·자동 수정 시작·
   자동 재수정은 승인 없이 하루 한도 안에서 하며, 기록은 `applied` 제안 1행으로 남는다. 운영 DB 반영·배포는 앱에 없다(따로 승인).
5. **정보가 부족하면 묻는다.** 도구가 필수 값 누락을 오류로 돌려주면 AI가 대화로 되묻고, 다음 턴에 같은 제안을 채워 다시 낸다.
6. 기존 원칙 유지: 키 위치, 기억은 사람만 확정. 결정·원칙은 "결정으로 정리"·피드백 경로와, 2026-10-11부터 Think의
   기억 저장 카드(§9, 사용자가 승인해야 저장)로 남긴다.

---

## 2. 제안(`ai_actions`)

| 열 | 뜻 |
|------|------|
| `id`, `conversation_id` (대화 삭제 시 함께 삭제), `message_id` (제안한 답변, 지워지면 비움) | 어느 대화의 어느 답변이 냈는지 |
| `kind` | `code_request` / `code_change` / `code_plan` / `place_conversation` / `delete_code_request` / `delete_folder` / `delete_conversation` / `split_conversation` / `save_memory` / `memory_card_change` / `handover_department` / `exclude_context` / `mark_important` / `progress_summary` / `department_criteria_change` / `concept_draft_change` / `concept_criterion_change` / `concept_draft_rerun` / `course_map_change` / `course_map_create` / `concept_placement_change` / `concept_library_change` / `concept_review_record` / `concept_relation_change` |
| `status` | `proposed` → `applied` / `rejected` / `failed` (`place_conversation`·`exclude_context`·`mark_important`은 `applied` → `undone` 가능, `split_conversation`은 대화가 이어지면 `expired`) |
| `payload` (jsonb) | 제안 내용. 서버가 검증·정리한 값만 들어간다 |
| `preview` (jsonb) | 카드에 보일 요약(폴더 경로, 지워질 수 등). 제안 시점에 서버가 계산 |
| `result` (jsonb) | 실행 결과(만든 폴더·요청 id, 되돌리기 정보) |
| `error`, `decided_at`, `decided_by`, `created_at` | |

- RLS: 슈퍼관리자만 읽는다. 앱은 직접 쓰지 않는다. `ai_think`가 사용자 JWT로 `ai_action_propose`를 불러 넣는다.
- 앱용 RPC: `ai_action_apply(p_id, p_overrides)`, `ai_action_reject(p_id)`, `ai_action_undo(p_id)`,
  `ai_action_apply_batch(p_items)`(정리 패널의 일괄 승인, §11).
  `p_overrides`는 사용자가 카드에서 고친 값(다른 폴더 선택, 요청 문구 수정)만 받는다.
- 같은 대화에 같은 종류의 `proposed`가 새로 오면 이전 것은 `rejected`(대체됨)로 바꾼다. 카드는 최신 것만 버튼을 보인다.
  기억 카드(`save_memory`·`memory_card_change`)는 예외로, 서로 대체하지 않고 사용자가 처리할 때까지 대기한다(§9).

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
| `split_conversation` | 새 대화 제목, 이유, 시작 메시지 앞부분, 폴더 경로(없으면 미분류), 다섯 칸 요약 | 새 대화 + 이번 문답 2개 복사 + 요약·폴더 배치(§7) | 없음(원본은 그대로) |
| `save_memory` | 종류·제목·내용·배경·이유·대안, 제안 이유, 범위 제안, 대체할 기억 제목 | 확정 기억(`active`) 저장, 대체 대상은 `superseded`(§9) | 없음(기억 탭에서 고친다) |
| `memory_card_change` | 수정·대체·삭제, 대상 카드 제목, 새 내용 | 대기 카드 수정 / 닫고 새 카드 / 닫기(§9) | 없음 |
| `handover_department` | 지금 부서 → 받을 부서, 이유 | 대화 역할을 받을 부서로 바꾸고 그 부서 미분류로 옮긴다(§10) | 없음(트리에서 다시 옮긴다) |
| `exclude_context` | 대상 메시지(역할·발췌), 이유, 이후 답변 영향, 연결된 문서·기억, 승인된 요약 여부 | 고른 메시지의 `context_excluded`를 켠다. 메시지는 지우지 않는다(§11) | 이번에 새로 뺀 메시지만 다시 넣는다 |
| `mark_important` | 대상 메시지(역할·발췌), 이유 | 고른 메시지의 `marked_important`를 켠다(화면 표시만, §11) | 이번에 새로 표시한 메시지만 지운다 |
| `progress_summary` | 목적·확정·미결·지금 상태·다음 행동, 제안 때의 승인된 요약 | 대화의 `progress_summary`를 바꾼다. 그사이 요약이 바뀌었으면 충돌(§11) | 없음(새 요약을 받는다) |
| `department_criteria_change` | 부서, 질문·위험·우선 기억의 전후, 판 | 그 부서 기준을 바꾸고 판을 올린다. 판이 다르면 충돌(§11) | 없음(기준 창에서 고친다) |
| `concept_draft_change` | 초안, 바꿀 것(고치기·빼기·되살리기·종류·새 종류·폴더·나누기·합치기, 30건까지), 건드린 항목의 전·후, 새 종류 | `concept_draft_action_apply`: 저장된 검토에 반영. 제안 뒤 그 항목이 바뀌었으면 `concept_draft_change_stale` | 없음(검토 창에서 고친다) |
| `concept_criterion_change` | 초안, 기준의 지금 내용(확정본/저장된 초안)과 바꿀 내용 | `concept_draft_action_apply`: 그 기준의 **초안으로만** 저장(판·초안 시각이 제안 때와 같아야 함). 확정은 정리 기준 화면 | 없음 |
| `concept_draft_rerun` | 초안, 쓸 기준(판·저장된 초안 여부) | `ai_action_apply`가 아니라 `concept_draft_organize` task `rerun`이 새 초안을 만들고 `concept_draft_rerun_finish`가 앞 초안을 `replaced`로 닫으며 `applied`로 남긴다 | 없음(앞 초안은 목록에 남는다) |

개념 초안 카드 세 가지는 `concept_draft_action_propose(p_conversation_id, p_kind, p_payload)`로만 들어간다(사용자 JWT, 초안이 열려 있어야 함).
같은 대화의 같은 기준 고치기·같은 초안 다시 정리는 새 제안이 앞 제안을 대체한다. 초안 변경은 서로 대체하지 않는다. 규칙은 `concept-library.md` §7.2.

과정 탐색도·개념 카드 다섯 가지(2026-10-23)는 `course_think_action_propose(p_conversation_id, p_kind, p_payload)`로 들어가고
`ai_action_apply`가 아니라 `course_think_action_apply(p_id, p_overrides)`로 승인한다(`ai_action_reject`는 같다).

| kind | 미리보기 | 승인 시 실행 |
|------|------|------|
| `course_map_change` | 과정·판, 바꿀 것 줄(더하기·이름·옮기기·보관·과정 정보) 또는 과정 보관·되살리기, 빠지는 배치 수 | `course_map_save`와 같은 검사로 통째로 저장. 판이 다르면 `course_map_stale` |
| `course_map_create` | 이름·학교급·교육과정, 단원 나무와 수 | 과정을 목록 끝에 만들고 단원 저장 |
| `concept_placement_change` | 과정, 항목(놓기·옮기기·빼기·순서, 50개까지)마다 경로·근거·`basis`, 고를 단원 목록 | 고른 항목만 항목마다 따로. `p_overrides {skip, units}` |
| `concept_library_change` | 항목(만들기·고치기·서술 고치기·지우기, 20개까지)마다 전·후, 붙은 것, 같은 이름 | 고른 항목만 항목마다 따로 확정. `p_overrides {skip}`. 붙은 것이 있는 지우기는 막힘(`concept-library.md` §4.4, DB 트리거가 승인 때 다시 셈) |
| `concept_review_record` | 항목(개념·범위·결과, 20개까지)마다 확인한 것·찾은 것·근거·확인 못 한 것·더 할 일, 비교한 개념, 앞선 기록, 다른 대기 카드 수, 결과별 개수 | 고른 항목만 `concept_quality_reviews`에 항목마다 따로 기록. `p_overrides {skip}`. 그 범위 지문이 바뀌었거나 비교한 개념이 바뀐 항목은 남기지 않음. 개념 본문·폴더·관계는 그대로(`concept-library.md` §4.5) |
| `concept_relation_change` | 항목(넣기·바꾸기·빼기, 20개까지)마다 두 개념(이름·폴더·id), 지금 상태(생긴 곳·결정 기록 여부)와 바꾼 뒤(유형·맥락·근거·메모), 불확실한 점·이유, 열린 같은 개념 검토, 다른 대기 카드 항목 수, 종류별 개수 | 고른 항목만 빼기 → 바꾸기 → 넣기 순서로 항목마다 따로. `p_overrides {skip}`. 두 개념의 글이 제안 때와 다르거나 관계 판이 다르면 그 항목은 반영하지 않음. 빼기는 관계만 지우고 개념은 그대로. 결정은 `think`·카드 id로 남고 이력에 이유가 남음(`concept-library.md` §4.6) |

같은 대화에서 같은 과정의 `course_map_change`만 새 제안이 앞 제안을 대체하고, 나머지 다섯 가지는 쌓인다. 되돌리기는 없다
(탐색도·배치는 화면에서, 개념·관계는 개념 화면에서 고친다. 검토 기록은 고치거나 지우지 않는다). 규칙과 카드 화면은 `course-map.md` §7.

검수 작업이 낸 `concept_review_record` 카드(`concept-library.md` §4.8)는 `concept_review_job_cards`로 작업에 이어진다. 승인 대기 카드는
`bring_cards`로 다른 대화에 옮길 수 있다: `conversation_id`만 바꾸고 `message_id`를 비우며, 내용·상태·승인 이력은 그대로다.
앱은 카드 상태를 받은 `conversation_id`로 넣으므로 옮긴 대화에서 그대로 승인·거절한다.

---

## 3. Think 도구 추가 (`ai_think/tools.ts`)

읽기(바로 실행):

- `list_tree_folders`: 폴더 id·경로·항목 수, 현재 대화의 위치
- `list_conversations(query)`: 대화 id·제목·최근 시각 (최대 20)
- `list_code_requests(query)`: 코드 요청 id·제목·상태·모드
- `get_code_request(id, section, offset)`: section이 null이면 **항상 짧은 구조화 요약**(9,000자 이하, `ai_think/code_brief.ts`):
  상태·수정이면 `state{code, checks, needs_owner_check, apply}`, 결과 요약, 바뀐 파일, 검사(`checks`: 판정·항목별 명령·폴더·종료 코드·시간,
  작업자 실행 기록에서만), 확인할 것, 막힌 이유, 적용에 필요한 행동, 최종 지시 검사, 구간별 시간(`timings_ms`), 요청 요약,
  `not_included`(빠진 원문과 읽는 법). 긴 원문은 `section`(`request`·`result`·`result_text`·`check_logs`·`diff`) + `offset`으로
  7,000자씩 읽는다(`next_offset`). Cursor용 relay(`think_get_code_request`)도 같은 모양이다. (2026-10-13, 이전에는 긴 요청이
  응답 앞을 차지해 12,000자에서 결과가 잘렸다)

제안(행 1개만 남김):

- `propose_code_request(title, goal, questions, focus_paths, constraints, do_not, background)`
- `start_code_plan(title, goal, instructions, questions, focus_paths, constraints, do_not, background, checks, based_on_request_id)`:
  코드 수정이 필요하면 이 도구로 Cursor와 조율을 시작한다(§4.3). 제안이 아니라 바로 시작한다.
  `checks[{cwd, command, why}]`는 사용자가 명시했거나 자동 검사 범위 밖이라 꼭 돌릴 검사다(§4.5). 조율본으로 그대로 이어진다.
  하루 한도에 걸리면 `daily_limit` 오류를 돌려준다. (2026-10-01에 `propose_code_change`를 대신함)
- 두 코드 도구 모두 `effort`(`medium`·`high`·`xhigh`, 애매하면 `high`)와 `effort_reason`(한 줄)을 받는다.
  운영자는 카드에서 승인 전에 강도를 바꿀 수 있다. (2026-10-10, [`ai-code-bridge.md`](ai-code-bridge.md) §7.1)
- `propose_folder(folder_id | new_folder_title + new_folder_parent_id, reason)`
- `propose_delete(target_kind, target_id, reason)`
- `propose_conversation_split(title, reason, summary, folder_id)`: 대화 나누기 기능이 준비됐을 때만 노출한다.
  메시지 id는 받지 않는다(§7). (2026-10-09)
- 과정 탐색도(2026-10-23, `ai_think/course_map_tools.ts`, 기능 `course_map_actions`가 준비되고 커서 문의가 아닐 때만):
  읽기 `get_course_maps`·`list_placement_candidates`·`get_concept_for_edit`, 제안 `propose_course_map_change`·`propose_course_create`·
  `propose_concept_placement`(한 답변 4장)·`propose_concept_change`(1장). 도구는 사용자가 맡겼을 때만 쓰게 지침에 적는다(`think-2026-10-23`).

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

Cursor가 답을 끝냈는데(턴 종료) 실행이 1분 안에 닫히지 않으면 작업자가 실행을 닫고 받아 둔 답과 diff로 정상 완료한다
([`ai-code-bridge.md`](ai-code-bridge.md) 실패 처리 표).

끝나지 못한 수정(`needs_review`·`failed`·`cancelled`)은 카드의 "같은 내용으로 다시 수정"으로 다시 보낸다(2026-10-05,
마이그레이션 `20261005100000_ai_code_change_retry.sql`). `ai_code_change_retry(request_id)`는 같은 지시로 새 수정 요청을
만들어 보내고(하루 한도 1건), 이전 요청과 diff는 그대로 둔다. 조율·승인을 다시 거치지 않는 것은 이미 승인한 같은 지시이기 때문이다.

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

#### 운영자 답 뒤 최종 지시 하나 (2026-10-13, 마이그레이션 `20261013100000_ai_code_plan_answers.sql`, 프롬프트 `code-review-2026-10-13`)

예전에는 답한 뒤에도 거절한 분기·"답변 대기" 조건이 지시에 남고, 회차마다 질문 id가 `q1`부터 다시 시작해 두 번째 답이 첫 답과 겹쳤다.

- 질문 보기마다 `instructions`(그 보기를 고르면 붙을 단계), 질문마다 `holds`(답이 나올 때까지만 지킬 조건)를 둔다.
  조율본 `instructions`·`constraints`에는 조건문·분기·대기 조건을 쓰지 않는다(스키마 설명과 지침).
- 질문 id는 요청·회차 범위로 만든다: `p<조율 요청 id 앞 8자>r<회차>_q1`(`decisionScope`). 앱은 id를 그대로 돌려보낸다.
- `ai_code_plan_revise`: 고른 보기의 단계만 지시에 붙이고(중복 제외), 고르지 않은 보기의 단계와 holds는 지시·제약에서 지워
  `spec.discarded_branches[{kind: option|hold, plan_request_id, decision_id, question, label|holds, instructions}]`에 이력으로 남긴다.
  `owner_answers`에는 `plan_request_id`·`answer_round`가 붙어 같은 id(`q1`)의 두 답도 둘 다 남는다. "운영자 결정 — " 줄은 중복을 넣지 않는다.
- Think 입력: 조율본 JSON에서 `owner_answers`·`discarded_branches`를 빼고 "[운영자가 고른 답 (다시 묻지 않는다)]"·"[버린 분기]" 칸으로 따로 준다.
  답한 항목과 실제로 충돌하는 새 사실은 다시 묻지 않고 "새로 발견된 충돌: "로 시작하는 질문으로 따로 보고한다(Cursor는 `owner_decision_conflicts`).
- `planSpec`: Think가 쓴 "운영자 결정 — " 줄은 버리고 서버 줄만 남긴다. 버린 분기와 같은 줄은 지운다. `checks`는 원래 요청 것을 먼저 두고 Think가 더한 것을 뒤에 붙인다.
- 최종 지시 검사(`finalPlanIssues`): 조율을 끝내고 수정을 시작하기 직전, 지시·제약에 버린 분기와 같은 줄이나 대기·분기 문구
  (`UNRESOLVED_PATTERNS`)가 남았으면 Think에게 한 번만 고치게 한다. 고친 답을 쓰고 `spec.final_check{flagged, retried, remaining}`에 남긴다.

### 4.4 요청 상태 추가

`ai_code_requests.mode`: `investigate`(기본) / `change` / `plan`.
수정 요청의 추가 상태: `ready`(diff 도착) → `apply_queued` → `applying` → `applied` / `apply_failed`,
`applied` → `revert_queued` → `reverted` / `revert_failed`. diff는 `ai_code_request_rounds.result.diff`에 있다.

### 4.5 자동 검사 (2026-10-07, 작업자 `checks.mjs`)

수정 실행이 끝나 diff를 모은 뒤, `complete` 전에 작업자가 **같은 복사본**에서 검사를 돌린다. 운영 DB에는 연결하지 않는다.
결과는 `ai_code_request_rounds.result.verification`에 남고 카드 "자동 검사" 칸에 보인다.

| 바뀐 경로 | 검사 |
|-----------|------|
| `apps/<앱>/**.dart` (pubspec 있음) | `flutter pub get` → 바뀐 dart 파일 `flutter analyze --no-fatal-infos` → `test/`가 있으면 `flutter test --no-pub` |
| `supabase/functions/<함수>/**` | `deno check index.ts`(`_shared`가 바뀌면 전부), `*_test.ts`가 있으면 `deno test --allow-env .` |
| `tools/code_bridge/**` | `node --test test/*.test.mjs` |
| `supabase/migrations/**` | 번호 검사(기존 파일 수정·삭제, 이름 형식, 번호 중복, 기존 최대 번호 이하이면 실패) + AI 마이그레이션이면 `tools/db_test`(PGlite, 메모리 DB) |
| node 폴더(가장 가까운 `package.json`, 없으면 `test/`가 있는 폴더. 저장소 루트는 아님) | 그 폴더의 `*.test.js|mjs|cjs`(`_test`·`-test`도) 파일 목록으로 `node --test`. 시험이 없으면 바뀐 JS 파일 `node --check` + "시험 없음" 미실행 (2026-10-13) |
| 그 밖의 코드 | 검사 없음 → "미실행" 1줄 (`docs/`, `.cursor/rules/`, `.md`·`.mdc`·`.txt`는 빼고) |

**요청한 필수 검사 (2026-10-13, `CHECKS_VERSION = 2`).** 조율본 `spec.checks[{cwd, command, why}]`(Think `start_code_plan.checks`·조율 `plan.checks`)를
작업자가 `request:N` 항목으로 먼저 돌린다. 받는 명령은 `node --test <저장소 안 상대 경로·glob>`뿐이다(옵션·`..`·따옴표 불가 → 미실행).
Node 22의 `node --test <폴더>`는 폴더를 찾아 들어가지 않으므로 작업자가 시험 파일 목록으로 펼친다. 해당 파일이 없으면 실패(수정이 만들어야 한다).
자동 node 검사는 요청 검사가 덮지 않은 파일만 돈다.

- **의존성**: 복사본에는 무시 파일인 `node_modules`가 없다. `package.json`에 의존성이 있으면 작업 폴더의 `node_modules`를
  `%TEMP%/ygg-code-bridge/deps/<폴더>-<lock 해시>`에 한 번 복사해 두고 복사본에 junction으로 연결한다. 검사가 끝나면 연결만 지운다.
  작업 폴더에 `node_modules`가 없으면 미실행 + `env: true`(작업 폴더에서 `npm ci`가 필요하다는 이유). 시험이 패키지를 못 찾아
  불러오지 못하는데 바꾸기 전에도 같으면 "원래도 실패"가 아니라 환경 문제 미실행이다.
- **사전 점검**: 수정 시작 전에 요청 검사의 명령 모양·폴더·의존성을 확인해(`preflightChecks`) 터미널과 결과(`result.preflight`)에 남기고 수정 프롬프트에 넣는다.
- **기록**: 항목마다 `command`·`cwd`·`exit_code`·`duration_ms`·`scope`(`required` | `followup`)·`source`(`auto` | `request`)·`env`,
  전체에 `verdict`·`patch_sha256`(검사한 diff의 sha256)·`base_commit`·`checked_at`. 결과에 `timings{prepare_ms, agent_ms, checks_ms}`.
- **판정**(`verdict`, 작업자·`_shared/code_verification.ts`·앱 같은 규칙): 필수 항목에 실패가 있으면 `failed`, 미실행이 있거나 중간에 멈췄으면 `not_run`,
  필수 항목이 있고 모두 통과(원래도 실패 포함)면 `passed`(원래도 실패가 있으면 문구에 "N개 제외"), 필수 항목이 없으면 `none`.
  `db-test-other`는 `followup`(실데이터 확인 성격)이라 판정에 넣지 않는다. 재수정은 필수 항목 실패만 부른다. `env` 미실행은 재수정하지 않고 환경 조치를 알린다.
- 중첩 `node --test`가 상위의 `NODE_TEST_CONTEXT`를 물려받으면 실패해도 종료 코드 0이 된다. 작업자는 검사 환경에서 이 변수를 지운다.

- 상태: `passed`(통과) · `failed`(실패) · `skipped`(미실행) · `preexisting`(원래도 실패). **미실행은 통과가 아니다.**
- 실패한 검사는 수정 전 커밋(`<id>-baseline` 복사본)에서 한 번 더 돌린다. 거기서도 실패하면 "원래도 실패"다.
  analyze는 줄 번호를 뺀 문제 목록을 비교해 **새로 생긴 문제**만 실패로 센다.
- 도구가 없으면(deno·flutter를 못 찾음) 그 검사는 미실행. 앞 검사(pub get)가 실패하면 뒤 검사도 미실행.
- 시간: 전체 25분(`CODE_BRIDGE_CHECKS_TIMEOUT_MS`), 검사 1개 10분. 취소·임대 만료면 남은 검사는 미실행.
- 끄기: `CODE_BRIDGE_CHECKS=off`(검사 항목 없음 + 이유가 남는다). 출력은 끝 3000자만, 비밀 값은 가린다.
- 검사는 AI가 쓴 코드(시험 포함)를 이 PC에서 실행한다. 환경 변수의 키·토큰(`KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL`,
  `CODE_BRIDGE_*`, `CURSOR_*`, `SUPABASE_*`)은 빼고 넘긴다. 네트워크·절대 경로 접근까지 막지는 못한다.
- `env.local.json`처럼 스냅샷에서 뺀 비밀 asset은 검사용으로 `{}` 빈 파일을 만든다.
- 마이그레이션은 **작업 폴더에 적용해도 운영 DB에 반영되지 않는다.** 반영(`supabase db push`)은 운영자가 따로 승인한다.

적용 RPC(`20261007090000_ai_code_request_apply_patch_guard.sql`)는 형식만 막는다: 완료 회차 없음(`code_request_no_round`),
`parse_ok = false`(`code_request_parse_not_ok`), diff 없음(`code_request_diff_missing`). 검사 실패는 막지 않고 앱이 경고한다.

자동 검사 전에 만든 diff나 손으로 받은 `.patch`는 `npm run verify-patch -- --request-id <uuid> --patch <file.patch>`로
격리 worktree에 얹어 볼 수 있다(검사는 돌리지 않는 수동 보조 도구).

### 4.6 자동 수정 시작·자동 재수정 (2026-10-07, 마이그레이션 `20261007100000_ai_code_ceo_flow.sql`)

```
조율 마지막 회차 → code_review: 질문(decisions) 없음 + 할 일(instructions) 있음
  → ai_code_bridge_start_change(plan, message, title, spec)   (서비스 역할만)
     - 수정 요청(change, max_rounds 1, created_by 복사) + code_change 행(applied, preview.auto = true)
     - 같은 대화의 대기 중 code_change는 대체. 이미 시작했으면 already_started
     - 하루 한도가 차면 아무것도 만들지 않고 code_request_daily_limit → 예전처럼 조율본 카드(proposePlan) + 안내
수정 complete → code_review(change): verification에 실패 항목 + 재수정 0~1회 + 상태 ready/needs_review
  → ai_code_bridge_fix(request, message, spec)                (서비스 역할만)
     - spec = 원래 spec + fix_of{request_id, root_id, attempt, max: 2, failed[]}
     - 새 수정 요청 + code_change 행(applied). 오류: not_fixable, fix_limit, already_fixing, no_diff, 하루 한도
  → 작업자 claim: fix = ai_code_bridge_fix_source(앞 요청) = {diff, base_commit}
     - 앞 요청의 base에 앞 diff를 얹은 복사본에서 시작(createFixWorktree). 새 diff는 원래 base 기준 누적 diff
```

- Think 검토문은 CEO 역할로 쓴다: 결론 먼저, 쉬운 말, 숫자는 그대로, 미실행은 통과가 아님, 마이그레이션은 적용 버튼으로 DB에 안 들어감.
- 완료 상태를 나눈다(2026-10-13): 코드 작성 완료 / 필수 검사 통과·실패·실행 불가 / 사용자 확인 필요 / 작업 폴더 적용 대기·완료.
  수정 결과 답 끝에 서버가 실행 기록으로 만든 "**작업 상태**" 줄(`changeStatusLine`)을 붙이고, 카드도 같은 네 줄(`ThinkChangeStateView`)을 보인다.
  수정의 `ready`는 목록에서 "코드 작성 완료"로 보이며 검증됐다는 뜻이 아니다. 검사 결과는 작업자 기록으로만 말한다(모델이 "검사 통과"라고 써도 근거가 아니다).
- 재수정이 시작되면 앞 카드는 적용 버튼을 숨기고 "새 카드의 결과를 보세요"라고 안내한다. 새 요청이 실패·취소·확인 필요로 끝나면 앞 카드의 적용 버튼이 돌아온다.
- 2번 재수정해도 실패하면 Think가 무엇이 실패했는지와 다음 선택지를 쉬운 말로 보고한다. 더 고칠지는 운영자가 정한다.

### 4.7 앞 수정 이어받기 (2026-10-08, 마이그레이션 `20261008180000_ai_code_patch_source.sql`)

작업 폴더에 아직 적용하지 않은 수정 요청 위에서 이어 고치는 길. 2026-10-08 전에는 재수정(`fix_of`) 말고는 앞 diff를 받을 길이 없었다.
그래서 요청 글에 앞 요청 id를 적어도 Cursor는 지금 작업 폴더만 보고, 저장된 diff는 읽지 못했다(Cursor·작업자 모두 DB 직접 접근이 없다).

```
Think: start_code_plan(continue_from_request_id = 앞 수정 요청의 전체 id)
  - 앞 요청이 없으면 continue_from_not_found, 수정 요청이 아니면 continue_from_not_change
  - spec.continue_from = {request_id, title}. 조율본 → 수정 요청(planSpec), 재수정(fixSpec), 다시 조율, 같은 내용으로 다시 수정에 그대로 이어진다
작업자 claim (job = run, fix_of 없음, continue_from 있음)
  → ai_code_bridge_patch_source(앞 요청)          (서비스 역할만)
     - 끝난 수정(ready·apply_failed·applied·reverted·revert_failed)의 마지막 회차만. 그 밖이면 not_final(+status)
     - 마지막 회차가 형식 확인 실패·기준 커밋 없음·통계 없음이면 incomplete. 앞 회차로 내려가지 않는다
     - 살아 있는 재수정(실패·취소·확인 필요 아님)이 있으면 superseded(+superseded_by: 최종 요청 id)
     - 그 밖: {ok, request_id, title, status, round, diff, diff_stats, base_commit}
  → claim 응답 base_patch. 실패면 이유만 싣고 패치 본문은 싣지 않는다
작업자: 지금 작업 폴더 스냅샷 S → 복사본 → 패치 얹기(createContinueWorktree)
     - 본문을 git apply --numstat으로 다시 세어 diff_stats와 다르면(잘림·다른 회차) 쓰지 않는다
     - 이미 들어 있으면 already_present, 그대로 얹히면 applied, 안 되면 3-way로 merged
     - 그래도 충돌하면 복사본을 지우고 충돌 파일과 함께 실패. 작업 폴더는 그대로
     - 조사·조율도 이 복사본에서 읽는다(쓰기 차단 훅 범위는 복사본)
     - 새 diff는 S 기준이라 앞 수정이 함께 담긴다. 회차 result.continued_from{request_id, title, round, files, additions, deletions, applied}
```

- 프롬프트에는 앞 요청 id·회차·파일 목록만 넣는다(`code_bridge.v5`). 패치 본문·토큰은 로그·오류·응답에 넣지 않는다.
- Think 검토 입력과 작업 상태 메모에 "이어받은 앞 수정 패치"를 적는다. 수정이면 "적용하면 앞 수정도 함께 들어간다"고 알린다.
- 이어받기가 실패하면(not_final, superseded, 충돌 등) 그 요청은 실패로 끝나고, 이유가 카드와 Think 작업 상태에 남는다. 운영자에게 diff를 손으로 복사하라고 하지 않는다.

#### 4.7.1 시간 제한으로 멈춘 미완성 패치 이어받기 (2026-10-10, 마이그레이션 `20261010150000_ai_code_partial_continue.sql`)

큰 수정이 작업자 시간 제한(기본 30분, `CODE_BRIDGE_CHANGE_TIMEOUT_MS`)에 걸리면 고친 데까지를 `needs_review`(형식 확인 필요)로 남긴다.
전에는 이 패치를 이어받을 수 없어 매번 처음부터 다시 했다. 운영자 결정(Think 결정문 5항):

```
미완성 패치 식별: 확인 필요(needs_review)의 마지막 회차 중
  - result.partial = 'timeout'                                  (작업자가 시간 초과 때 남긴다)
  - 표시 없는 예전 행은 요약이 "30분 안에 끝나지 않아 멈췄습니다"로 시작할 때만 후보
  - 그 밖의 확인 필요(형식 오류 등)·실패·취소·재수정으로 대체됨·마지막 회차 아님은 거절(not_final / superseded)
ai_code_bridge_patch_source → {ok, …, partial: 'timeout'}       (형식 확인 실패여도 기준 커밋·통계·본문이 있어야 함)
작업자 createContinueWorktree (partial일 때 추가)
  - 기준 커밋(40자)이 이 PC에 있고, 패치가 그 커밋에 그대로 적용돼야 한다(임시 인덱스 apply --cached --check)
  - 그다음 기존과 같이 통계 일치 → 지금 스냅샷에 얹기(그대로·3-way·충돌이면 실패)
  - 회차 result.continued_from.partial = 'timeout'
```

- 작업자 요청문(`code_bridge.v7`): 앞 작업은 중간에 멈췄고 검사된 적이 없다. 남은 일을 끝내고 앞 변경도 검토해 고친다. 자동 검사는 앞 변경까지 포함한 최종 diff 전체에 돈다.
- Think 검토 입력(`continuedText`)과 작업 상태 메모: "미완성 패치(검사 안 됨)". 앞 변경을 검증된 것으로 보지 않는다.
- 미완성 패치 자체는 작업 폴더에 적용할 수 없다(확인 필요라 적용 버튼이 없다). 이어받은 요청이 준비됨(`ready`)이 된 뒤 그 최종 diff만 평소처럼 승인받아 적용한다.
- 화면: 이어받은 요청 카드 머리에 "미완성 패치에서 시작" 경고(검사된 적 없음, 최종 diff 전체로 판단), 회차 칸 제목도 "미완성 패치에서 시작"이고 요약은 "n회차 미완성 패치".
- Think 지침(`think-2026-10-10c`): 위 규칙, 조사 작업자는 운영 DB를 읽지 못한다는 점, 큰 수정은 독립적으로 검사할 수 있는 결과물 단위로 나눌지 검토. 60분은 나눌지 생각해 볼 신호이지 고정 한도가 아니다. 작업 강도와 나누기는 따로 판단한다.

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
  - 나누기 카드(§7): 제목·이유·"여기부터 나눕니다"(시작 메시지)·들어갈 폴더·다섯 칸 요약(빈 칸은 "없음") →
    나눠서 이어가기 / 고쳐서 나누기 / 여기서 계속하기. 나눈 뒤에는 "새 대화로 가기"와 이 대화에만 남은 것의 수
  - 적용 확인 창: 파일 목록, `git apply --check` 선검사, 백업 ref, 커밋·스테이징 안 함을 적는다.
    검사 실패·미실행·원래도 실패·멈춤·검사 기록 없음과 "DB 함수 파일은 운영 DB에 반영되지 않음"을 맨 위에 경고한다. 실패가 있으면 제목과 버튼이 "그래도 적용"(빨간색)
  - 자동 검사 칸(수정 카드): "통과 n · 실패 n · 미실행 n · 원래도 실패 n" 한 줄과 항목별 줄(아이콘·이름·상태·이유·걸린 시간).
    실패 항목은 펼쳐서 명령과 출력 끝부분을 보인다. 준비됨 안내 문구도 검사 결과에 따라 바뀐다(모두 통과 초록 / 실패 빨강 / 그 밖 파랑)
  - 재수정 요청 카드 머리에 "검사 실패로 다시 고침 n회째"
  - 이어받기 요청: 요청 내용에 "이어받는 앞 수정", 회차 칸에 "이어받은 패치: 요청 … n회차 최종 패치 · 파일 n개 · 얹은 방식"(§4.7).
    시간 제한으로 멈춘 패치에서 시작했으면 카드 머리 경고와 회차 칸 제목이 "미완성 패치에서 시작"(§4.7.1)
  - 수정 diff: **diff 복사**, `parse_ok`가 true일 때만 **작업 폴더에 적용**. Cursor가 적은 `checks`는 "사람이 확인할 점"으로 보인다
  - 과정 탐색도·배치·개념 카드(`think_course_map_cards.dart`): 항목 체크·단원 바꾸기 → "고른 것 승인 (n)"/거절.
    승인 뒤 반영·못 함·뺌 수와 못 한 항목의 이유 한 줄씩(`course-map.md` §7.2)
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

AI의 자동 실행(조율 시작, 질문 없는 조율본의 수정 시작, 검사 실패 재수정 최대 2회만 예외), 작업 폴더 자동 적용,
운영 DB 반영·배포, Cursor 에이전트의 셸 명령(검사는 작업자가 정해진 명령만 돌린다), 커밋·푸시·PR, 작업 폴더 외 경로 수정,
여러 요청 동시 처리, Cursor IDE 채팅창 조작, 삭제 되돌리기(휴지통).
대화 나누기에서는 임의 범위·여러 턴 복사, 나누면서 폴더 만들기, 나누기 되돌리기, 요약의 기억 자동 저장을 하지 않는다.
기억 저장 제안에서는 승인 없는 저장, 대기 카드의 자동 삭제·대체, 한 답변에 카드 여러 장, 메모(note)·교육철학(identity) 제안을 하지 않는다.

---

## 7. 대화 나누기와 기능 상태 (2026-10-09, 마이그레이션 `20261009100000_ai_think_conversation_split.sql`)

한 대화에서 주제가 바뀌면 Think가 새 대화로 나누자는 카드를 낸다. 사용자가 승인하면 서버가 새 대화를 한 번에 만들고,
앱은 새 대화로 넘어간다. 원본 대화는 그대로 남는다.

```
ai_think: 이번 사용자 메시지 저장 → 모델이 답하면서 propose_conversation_split(title, reason, summary, folder_id)
  → ai_conversation_split_propose(대화, 이번 턴 사용자 메시지 id, payload, preview, user_requested)   (사용자 JWT)
     - 메시지 id는 ai_think가 넣는다. 모델이 고르지 않는다
     - 대화 행 잠금 → 시작 메시지가 이 대화의 사용자 메시지인지(split_range_invalid), 그 뒤 사용자 메시지가 없는지(split_expired),
       앞 대화가 있는지(split_nothing_before), 거절한 대화인지(split_suppressed, 사용자가 직접 요청했으면 통과)
     - 제목·목적 필수(split_title_required, split_summary_required). 폴더는 있는 폴더만(tree_folder_not_found), 없으면 미분류
     - 같은 대화의 대기 중 나누기 제안은 대체됨. ai_actions 1행만 남기고 대화·복사·폴더·기억은 만들지 않는다
  → 답변 저장 뒤 ai_action_attach가 답변 id(message_id)를 붙인다
사용자: 나눠서 이어가기 / 고쳐서 나누기(제목·폴더·요약) / 여기서 계속하기(거절)
  → ai_action_apply → ai_conversation_split_apply(p_id, {title, summary, folder_id})   (folder_id 키가 null이면 미분류)
     - 원본 대화 → 제안 순서로 잠근다. 이미 applied면 그 행을 그대로 돌려준다(여러 번 눌러도 새 대화는 하나)
     - expired → split_expired, 답변 id 없음 → split_answer_pending, 답변이 complete가 아님 → split_answer_incomplete
     - 새 대화(제목·split_summary·split_from_conversation_id·split_from_action_id) + 시작 사용자 메시지와 그 답변 2개 복사
       + 폴더 배치 + 결과 기록. 한 트랜잭션이라 하나라도 실패하면 모두 되돌리고 제안은 대기로 남는다
     - result: {conversation_id, title, folder_id, copied_message_ids, edited,
                not_copied{actions, code_requests, tree_nodes, other_messages}}
```

- **범위**: 제안한 턴의 사용자 메시지와 그 턴의 완료된 답변뿐이다. 도구 스키마에 메시지 id가 없다. 나누기 제안은 전용 RPC로만 만든다
  (`ai_action_propose`에 `split_conversation`을 넘기면 `split_use_dedicated_rpc`).
- **복사**: 원래 시각·상태·첨부·출처·`context_excluded`를 그대로 두고 `source_message_id`에 원본 메시지를 적는다.
  실행 기록(`run_id`)은 원본에만 있다. `message_count`는 저장 트리거가 센다(복사 2개).
  제안 카드·코드 요청·트리 발췌·문서와 시작 메시지 뒤의 다른 메시지(예: 코드 조사 검토 답변)는 원본에만 남고, 그 수를 `not_copied`로 카드에 보인다.
  복사본에는 카드가 붙지 않아 다시 실행되지 않는다.
- **첨부**: 복사본은 원본과 같은 저장소 경로를 가리킨다. 읽기 권한은 넓어지지 않는다(같은 슈퍼관리자 범위). 앱이 대화를 지울 때는
  `ai_attachment_paths_in_use`로 다른 대화가 아직 가리키는 파일을 남긴다. 이 RPC가 없으면(마이그레이션 전) 예전처럼 모두 지우고,
  그 밖의 오류면 파일을 지우지 않는다.
- **만료·동시성**: 제안 뒤 같은 대화에 사용자 메시지가 저장되면 메시지 저장 트리거(`ai_messages_after_insert`)가 대기 중 나누기 제안을
  `expired`(`error = 'conversation_continued'`)로 바꾼다. 트리거·승인·거절 모두 대화 행을 먼저 잠그므로 한 줄로 선다.
  승인이 먼저면 새 메시지는 원본에만 남고, 메시지가 먼저면 승인이 `split_expired`로 실패한다. 복사 메시지는 만료를 일으키지 않는다.
- **거절**: 그 대화의 `auto_split_suggestions`를 끈다. 그 뒤로는 도구를 노출하지 않다가, 사용자가 이번 메시지에서 직접 나누자고 하면
  (`features.ts` `isSplitRequest` 문구 규칙, 완벽하지 않음) 다시 노출한다. 맥락 패널 "이 대화에서 나누기 제안 받기"로 다시 켤 수 있다.
- **요약**: 목적·이어받을 배경·확정한 것·정하지 않은 것·다음 할 일(`ai_split_summary_clean`이 다섯 칸만 남긴다)을 새 대화 행에만 둔다.
  기억이 아니다(`ai_memories`에 쓰지 않는다). 새 대화의 맥락에는 대화 기록 맨 앞에 사용자 역할의 "참고 자료"로 넣는다.
  지시문·개발자 메시지에는 넣지 않는다. 대화 안에서 바뀌지 않으므로 프롬프트 캐시를 깨지 않는다.
- **주제 감지**는 모델 판단이다. 결정적 규칙이 아니어서 놓치거나 필요 없는 제안을 낼 수 있다. 거절하면 그 대화에서는 더 내지 않는다.

### 7.1 기능 상태 (`ai_think/features.ts`)

- 서버가 요청(`status`, `chat`)마다 계산하고 캐시하지 않는다. Edge 버전(`EDGE_FEATURES`), DB 버전(`ai_think_db_features()`),
  앱 버전(요청 본문 `client.features`)을 비교한다.
- `ai_think_db_features()`는 읽기 전용이다(함수·열이 있는지만 본다). 존재하지 않는 RPC를 쓰기 요청으로 시험하지 않는다.
  함수가 없으면(PGRST202·42883) DB 0, 그 밖의 오류는 `unknown`이다. 확인 실패를 사용 가능으로 보지 않는다.
- 상태: `ready` 준비됨 / `db_required` DB 반영 필요 / `app_update_required` 앱 업데이트 필요 / `unknown` 확인 불가.
  앱 화면이 바뀌지 않는 기능(`APP_FREE_FEATURES`, 지금 `concept_source_pages`)은 앱 버전을 보지 않아 `app_update_required`가 되지 않는다.
  `ready`이고 앞 대화가 있을 때만 `propose_conversation_split`을 노출한다. 모델에게는 "실행 환경 기능 상태" 메모로 알린다.
  사용자 메시지나 기억으로 바꿀 수 없다.
- 결과는 `status` 응답 `features`·`features_db_error`, SSE `conversation` 이벤트 `features`·`split_suggestions`, `ai_runs.features`(그 호출의
  계산 결과)에 남는다. `ai_runs.features` 열이 없는 DB에서는 그 값을 빼고 다시 기록한다.
- 앱은 `ThinkApi.clientFeatures`(`{conversation_split: 1, think_roles: 1, memory_proposals: 1, department_work: 1, auto_organize: 1, course_map_actions: 1}`)를 보낸다. 상태 창 "기능 상태"와 맥락 패널 "대화 나누기"에 사용 가능/준비 필요/확인 불가와
  이유를 보인다. 기능 상태를 보내지 않는 이전 Edge면 "확인 불가 · Edge 배포 필요"로 보인다.

배포 순서가 어긋났을 때:

| 조합 | 동작 |
|------|------|
| 새 Edge + 이전 DB | `db_required`, 도구 숨김, `ai_runs.features` 없이 기록 |
| 새 Edge + 이전 앱 | `app_update_required`, 도구 숨김 |
| 새 앱 + 이전 DB | 메시지·대화 상세는 전체 열로 읽어 없는 열은 기본값. 첨부 확인 RPC가 없으면 예전 삭제. 제안 받기 토글 숨김 |
| 새 앱 + 이전 Edge | 기능 상태 없음 → "확인 불가 · Edge 배포 필요". 나누기 카드가 생기지 않는다 |

## 8. 역할·자료 범위 (2026-10-10, 마이그레이션 `20261010160000_ai_think_roles.sql`)

- 대화 `think_role_id`: `lead` · `education` · `product` · `engineering`. `ai_conversations.scope_type`은 학생·문제 등 대화 범위용이며 역할과 별개다.
- `extra_ref_departments`: 사용자가 명시적으로 고른 추가 참조 부서(`education`/`product`/`engineering`).
- 기억 `memory_scope`: `legacy_unscoped`(기존 행·재분류 없음) · `common` · `department`(+ `scope_department`). 승인 `active`만 AI 맥락·도구에 노출.
- `ai_conversation_memory_links` · `ai_conversation_document_links`: 링크 시·읽기 시 승인·권한 재검증. 종합 문서 본문은 **명시 연결 + `buildThinkContext` 전용 경로**에서만 AI에 전달.
- `ai_message_context_snapshots`: 답변별 당시 역할·`role_profile_version`·실제 전달·조회 자료 id. 검색 후보·도구 요약만으로 UI에 표시하지 않는다.
- `ai_runs.role_profile_version`: 공통 `prompt_version`과 별도로 역할 프로필 변경을 구분.
- 기능 `think_roles`: Edge·DB(`ai_think_db_features`)·앱(`client.features.think_roles`)이 모두 1 이상일 때만 역할 UI·범위 API를 켠다. 하나라도 미준비면 구버전 총괄 안전 동작(부서 범위 기억·명시 연결 문서를 레거시 전체처럼 노출하지 않음).
- 대화 나누기 승인(`ai_conversation_split_apply`): 원본 역할·추가 참조·**승인 active 기억·접근 가능한 종합 문서 링크만** 새 대화로 승계.
- 역할 저장은 `ai_conversation_set_think_role`(관리자만, 역할·부서 값 검증)로만 한다. 새 대화는 앱이 `ai_think` 요청 `body.role`
  (`{think_role_id, extra_ref_departments}`)로 보내고, 서버가 대화를 만든 뒤 맥락을 짓기 전에 저장한다. 이어지는 대화에서는
  `body.role`을 무시하고 DB에 저장된 역할만 쓴다(앱 자기 신고를 권한으로 쓰지 않는다). 저장이 실패하면 총괄로 답하고 SSE
  `notice{code:'role_not_applied'}`를 보낸다.
- SSE `conversation` 이벤트 `think_role`: `{id, extra_ref_departments, profile_version}`. 기능이 준비되지 않았으면 `null`.
- 기억 검색은 `ai_search_memories_scoped`(mode `legacy` · `all` · 역할 id, 추가 참조, 연결 기억 id)로 DB 단계에서 거른다. 함수가
  없는 DB에서는 예전 `ai_search_memories` 결과에 같은 범위 검사를 앱 서버 쪽에서 적용한다. `get_memory`도 범위 밖이면 `not_found`.
- 범위 예외: 커서 문의 읽기 도구(`ai_think_relay` 기억 검색)는 운영자 대행 조회라 `all`. 결정 초안·스펙 내보내기·코드 검토는 그 대화에
  저장된 역할로 거른다. 기억 피드백의 중복 경고는 운영자 화면 용도라 전체 기억과 비교한다.
- 앱(매니저 Think): 대화 위 역할 머리(아바타 4종·역할 칩·다른 부서 참조, 720px 미만은 아바타만), 답변별 "이 답변에 쓴 자료 보기"와
  맥락 패널 자료 칸(선택한 답변의 실제 전달 자료, 스냅샷이 없으면 "기록 없음", 연결 기억·문서 추가/해제), 기억 편집·피드백·결정 저장의
  범위 선택(역할은 제안만, "적용"을 눌러야 바뀜). 답하는 중에는 역할·연결을 바꿀 수 없다. 아바타는 §10의 부서 캐릭터이며 모션 감소 설정이면 움직이지 않는다.

## 9. 기억 저장 제안 (2026-10-11, 마이그레이션 `20261011100000_ai_think_memory_proposals.sql`)

결정 기억 "Think의 자발적 기억 저장 제안 허용"(`5ede3fa1`)을 구현한다. Think가 대화에서 사용자가 분명히 확정한 결론(decision)·원칙
(principle)을 카드로 제안하고, 사용자가 승인해야 확정 기억이 된다. "결정으로 정리"·피드백 경로는 그대로다.

```
ai_think: 모델이 propose_memory({memory, reason}) → ai_action_propose('save_memory')   (사용자 JWT)
  - ai_memory_proposal_clean: kind decision|principle, 제목·내용 필수, 범위 common|department(+부서), 길이 제한,
    supersedes_id는 지금 active인 기억만(memory_supersede_not_active)
  - ai_memory_proposal_guard: 같은 제목(공백 제거·소문자)의 active 기억 → memory_duplicate_active:<기억 id>
    (대체 대상은 제외), 같은 제목이거나 같은 기억을 대체하려는 대기 카드 → memory_proposal_pending:<카드 id>
  - 기억 카드는 서로 대체하지 않는다. 기억은 만들지 않는다
모델이 propose_memory_card_change({target_action_id, op: revise|replace|withdraw, memory, reason})
  → 대상은 대기 중인 save_memory만(memory_card_not_pending), 대상당 대기 변경 카드 하나(memory_card_change_pending:<id>)
사용자: 승인하고 저장 / 고쳐서 승인(내용·종류·범위) / 거절
  → ai_action_apply → ai_memory_action_apply(p_id, {memory})
     save_memory: 다시 clean·guard → ai_memories(active, source_conversation_id, 범위) 저장, 대체 대상은 superseded
                  result {memory_id, superseded_id, edited}
     memory_card_change: 대상 카드 잠금 →
       withdraw: 대상 rejected(result.withdrawn_by_action_id)
       revise:   대상 payload.memory·preview 갱신(revised: true), 대상은 계속 대기
       replace:  대상 rejected·superseded(result.replaced_by_action_id) + 새 대기 save_memory, result.new_action_id
```

- **비교 근거(2026-10-27, `20261027180000_ai_memory_compare.sql`, `20261027210000_ai_memory_flow.sql`):** 제안은 이번 요청에서 서버가 기록한 검색과, 모델에게 끝까지 전달된 원문 id·version만 카드 `payload.basis`에 남긴다. 검색 발췌와 클라이언트가 적은 version은 근거가 아니다. 승인 때 그 판이 아니면 새 기억도 승인 표시도 남지 않는다. 근거가 없는 기존 대기 카드는 채우거나 지우지 않고 승인만 거절한다. 생성·내용 수정·보관(삭제)은 Think 카드 승인으로만 반영한다. 보관은 행을 지우지 않는다. 서로 기대는 변경은 `payload.flow`의 단계 순서대로만 승인되고, 독립 카드의 일괄 승인 부분 성공은 그대로다. 기억 편집·피드백·결정으로 정리 화면은 바로 저장하지 않는다.
- **답변당 1장**: 저장·변경 카드를 합쳐 한 답변에 하나만 낸다. Edge(`MemoryToolContext.proposed`)가 막는다. DB 오류로 실패한
  제안은 세지 않으므로, 대기 중복을 만나면 같은 답변에서 변경 카드를 낼 수 있다.
- **중복**: 중복 판정은 정규화한 제목 기준이다. 내용이 같은데 제목이 다르면 서버가 잡지 못하므로, 지침에서 제안 전에 `search_memories`를
  하게 한다. 승인 때도 guard를 다시 돌려 그 사이 생긴 중복을 막는다.
- **대기 카드**: 기한 없이 남는다. Think는 "이 대화의 작업 상태" 메모에서 대기 카드 id를 보고, 중복이면 사용자에게 알리고 변경 카드를
  낸다. 자동으로 지우거나 바꾸지 않는다. 다른 대화의 대기 카드는 도구 오류의 `pending_action_id`로 알게 된다.
- **범위**: `memory_scope`·`scope_department`는 Think의 제안이다. 역할 기능(`think_roles`)이 준비됐으면 카드에서 범위 선택이 보이고,
  바꾸면 `overrides.memory`로 보낸다. 준비되지 않았으면 "범위 제안"을 글로만 보인다.
- **노출 조건**: 기능 `memory_proposals`(Edge·DB·앱 모두 1)가 `ready`이고 커서 문의(relay)가 아닐 때만 두 도구를 주고 지침에
  "기억 저장 제안" 절을 넣는다. 준비되지 않으면 예전 문장("결정·원칙·기억은 제안 도구로 만들지 않는다")을 그대로 쓴다.
- **앱**: 카드(`think_memory_proposal_views.dart`, `ThinkActionCard`), 승인 뒤 기억 목록 새로고침, 변경 카드 승인 뒤 대상 대화의 카드
  다시 읽기, 상태 창 "기억 저장 제안" 줄.

## 10. 부서 트리·부서 협의·부서 넘기기 (2026-10-12, 마이그레이션 `20261012100000_ai_think_departments.sql`)

사장님 결정(2026-10-12): 왼쪽 트리를 4부서(총괄·교육·문제 풀이·개발)로 먼저 나누고, 부서마다 캐릭터로 진행 상태를 보인다.
Think는 답변 중 다른 부서에 자동으로 협의하고, 대화를 다른 부서로 넘기자고 제안할 수 있다.

- **이름**: 내부 id `product`는 그대로, 이름만 "문제 풀이". 관점은 문제 은행·문항 제작·난이도, 채점·오답 분석·문제 통계,
  교재·목차·유형 분류. 학생이 문제를 푸는 과정과 풀이 화면은 맡지 않는다(`ROLE_PROFILE_VERSION think-role-2026-10-12`).
- **폴더 부서**: `ai_tree_nodes.department`(폴더만, 4값). 하위 폴더는 상위 폴더 부서를 트리거가 강제하고, 최상위 폴더 부서를
  바꾸면 하위 폴더로 내려간다. 기존 폴더는 안 대화들의 최다 역할로 정했다(동률·빈 폴더는 총괄). 기존 대화 역할은 바꾸지 않았다.
- **대화의 칸**: 폴더 안 대화는 최상위 폴더의 부서 칸, 폴더 밖 대화·미분류는 대화 역할의 칸에 보인다. 폴더 부서와 역할이 다른
  대화는 "X 관점" 표시만 하고 고치지 않는다.
- **부서 사이 옮기기**(사람): `ai_tree_move_department`(노드·미분류 대화를 다른 부서 폴더/최상위로, 안의 대화 역할을 모두 그 부서로,
  `roles_changed` 반환), `ai_conversation_move_department`(대화를 그 부서 미분류로). 앱은 역할이 바뀌는 대화가 있으면 확인 창
  ("다음 답변부터 X 관점")을 먼저 띄우고, 답하는 중인 대화는 옮기지 않는다. 역할 칩으로 역할을 바꾸면
  (`ai_conversation_set_think_role`) 폴더 부서와 달라질 때 그 대화를 새 부서 미분류로 뺀다.
- **부서 넘기기**(Think 제안): 도구 `propose_department_handover({to_department, reason})` → `ai_department_handover_propose`
  (`handover_department` 제안, 대화당 대기 1장, 새 제안은 앞 제안을 대체). 승인하면 `ai_action_apply`가 같은 부서인지 다시 보고
  `ai_conversation_change_department(…, unfile=true)`: 역할을 바꾸고 그 부서 미분류로 옮긴다. 대화는 나누지 않는다. 답변당 1장.
- **부서 협의**(Think 자동): 도구 `consult_department({department, question, background})`(`ai_think/consult.ts`). 승인 없이 답변당
  최대 2회. 질문받은 부서는 **질문·배경 + 자기 부서·공통 기억만** 보고(사장님 대화 기록·다른 부서 기억은 보지 않음), 도구 없이
  primary 모델로 답한다. 남은 시간이 15초 미만이면 하지 않는다. 기록: `ai_runs`(feature `think_consult`, `features.consult {from,to}`),
  그 답변의 도구 기록(질문·답 요약, 공개). SSE `consult {call_id, status: running|done, from, to}`로 앱 트리 캐릭터가
  "↔ X과 협의 중"을 보인다. 협의 결과는 Think가 답변에 반영하며 기억으로 저장하지 않는다.
- **같은 부서 폴더**: 기능이 켜지면 `propose_folder`(대화 분류)는 대화 부서와 같은 부서 폴더만 고를 수 있다
  (`folder_other_department`). 새 폴더는 대화 부서로 만든다. `list_tree_folders`가 폴더 부서와 이 대화 부서를 함께 준다.
- **노출 조건**: 기능 `department_work`(Edge·DB·앱 모두 1) + `think_roles` 준비 + 커서 문의(relay) 아님. 준비되지 않으면 예전 트리,
  두 도구 없음, 지침에 "## 부서" 절 없음.
- **캐릭터 상태**(앱만 계산, 서버 저장 없음): 협의 중 > 답하는 중 > Cursor 작업(그 부서 대화의 진행 중 코드 요청) > 승인 대기(그 부서
  대화의 대기 제안 수, `pendingActionCounts`) > 쉬는 중. 14×14 픽셀 캐릭터(`think_avatars.dart`)가 모든 역할 아바타를 대신한다.
  일하는 상태만 움직이고, 모션 감소 설정이면 멈춘다.

| 조합 | 동작 |
|------|------|
| 새 Edge + 이전 DB | `department_work` `db_required` → 예전 트리, 협의·넘기기 도구 없음 |
| 새 Edge + 이전 앱 | `app_update_required` → 도구 없음 |
| 새 앱 + 이전 DB | 트리 `department` 열이 없으면 빼고 다시 읽음, 예전 트리 |
| 새 앱 + 이전 Edge | 기능 상태 없음 → 예전 트리 |

## 11. 자동 정리 제안과 정리 패널 (2026-10-12, 마이그레이션 `20261012120000_ai_think_auto_organize.sql`)

Think 상담 스펙 "자동 정리 제안과 승인 중심 운영"을 구현한다. Think가 대화 중에 분류·나누기·기억·부서 넘기기·맥락 제외·중요 표시·
진행 요약·부서 기준 변경을 먼저 제안하고, 운영자는 고르고 고쳐서 승인만 한다. 승인 전에는 아무것도 바뀌지 않는다.

2026-10-12 운영자 결정:

| 항목 | 결정 |
|------|------|
| 중요 표시 | 메시지 표시(`ai_messages.marked_important`). 화면 표시일 뿐 원칙·지시의 권한이 아니다. 점수 체계는 만들지 않는다 |
| 진행 요약 단위 | 대화마다 하나(`ai_conversations.progress_summary`) |
| 화면 | 답변 아래 정리 카드는 "정리 제안 N건" 한 줄로 접고, 오른쪽 정리 패널(좁으면 바텀시트)에서 골라 한 번에 승인한다. 코드·삭제 카드는 그대로 |
| Preview 화면 | 만들지 않고 실제 화면에 바로 반영 |
| 부서 기준 | 이번에 함께(`ai_department_criteria`) |
| 범위 | 지금 대화만. 다른 대화·폴더·기간 정리는 아직 하지 않는다 |

```
ai_think: 기능 auto_organize(Edge·DB·앱 모두 1) 준비 + 커서 문의 아님
  - 자동 제안 설정(ai_platform_settings.auto_organize_enabled, 기본 켜짐)이 꺼져 있으면 사용자가 이번 메시지에서 정리를 직접
    요청할 때만 분류·나누기·기억·넘기기·정리 도구를 준다. 설정을 읽지 못하면 꺼진 것으로 본다
  - 도구: list_conversation_messages(맥락에 들어가는 메시지 id·역할·발췌) →
          propose_context_exclusion / propose_importance_mark / propose_progress_summary /
          propose_department_criteria_change(역할이 적용된 대화에서만)
    → 전용 제안 RPC가 ai_actions에 제안 1행(같은 종류의 앞 대기 제안은 대체). 한 답변에 종류마다 하나
사용자: 답변 아래 "정리 제안 N건" → 정리 패널 → 항목 고르기·고치기·이번에는 거절 → "선택한 항목 승인"
  → ai_action_apply_batch([{id, overrides}]) : 슈퍼관리자, 1~20개, 같은 id는 한 번
     실행 순서: 부서 넘기기 → 분류 → 맥락 제외 → 중요 표시 → 나누기 → 기억 → 기억 카드 → 진행 요약 → 부서 기준
     항목마다 savepoint로 기존 ai_action_apply를 따로 실행 → [{id, ok, already?, code?, message?, action}]
     이미 승인된 항목은 다시 실행하지 않고 ok+already, 실패한 항목은 대기 상태로 남는다
```

- **맥락 제외**: 승인하면 고른 메시지의 `context_excluded`만 켠다. 메시지·문서·기억은 지우지 않는다. 대상 메시지에서 만든 발췌·종합
  문서와 그 답변에서 저장한 확정 기억은 "따로 판단"으로 경고만 하고 바꾸지 않는다. 승인된 진행 요약이 있으면 내용이 남을 수
  있다고 알린다. 비판·실패·의견 차이를 감추려고 제안하지 않고, 무엇이 정정·폐기됐는지 이유를 구체적으로 적게 한다(지침).
  되돌리기는 이번에 새로 뺀 메시지(`result.excluded_ids`)만 다시 넣는다. 대화 삭제는 정리 제안이 아니다.
- **중요 표시**: 승인하면 `marked_important`를 켠다. 운영자는 답변 머리의 깃발·질문 옆 깃발로 직접 켜고 끌 수도 있다.
  AI 맥락에서 원칙보다 앞서지 않는다(지침). 되돌리기는 이번에 새로 표시한 메시지만 지운다.
- **진행 요약**: 목적·확정(사용자가 정한 것만)·미결·지금 상태·다음 행동(무엇, 담당·선행 조건·완료 기준은 사용자가 말한 것만).
  제안 때 승인돼 있던 요약을 `payload.base_action_id`로 남기고, 승인 때 지금 요약이 다른 제안에서 왔으면 `progress_summary_changed`로
  멈춘다. 승인된 요약은 다음 답변부터 지난 대화 뒤에 참고 자료로 들어간다(지시·권한 아님, 요약 뒤 새 질문 수와 그 뒤 맥락 제외를
  함께 알린다). 승인해도 코드 작업·배포·DB 변경은 시작되지 않는다.
- **부서 기준**: 부서마다 먼저 확인할 질문(8개)·놓치면 안 되는 위험(8개)·우선 참고할 승인 기억(8개, 그 부서가 볼 수 있는 active만).
  접근 권한과 별개다. 바꿀 때마다 `version`이 오르고 `ai_department_criteria_revisions`에 남는다. 제안 때의 판(`payload.base_version`)과
  다르면 `criteria_changed`로 멈춘다. 운영자는 맥락 패널 "부서 기준" 창에서 직접 고칠 수 있다(`ai_department_criteria_save`, 판 검사).
  역할이 적용된 대화의 지시문에 그 부서 기준이 들어간다(교육철학·원칙보다 앞서지 않음).
- **분류의 부서 확인**: 승인 때 폴더 부서가 지금 대화 부서와 다르면 `place_department_mismatch`로 멈춘다. 그래서 자동 정리 기능이
  켜진 요청에서만, 같은 답변에서 넘기기를 제안한 부서의 폴더로 분류를 함께 제안할 수 있다(`preview.after_handover`). 일괄 승인은
  넘기기를 먼저 실행한다. 옛 DB에서는 넘기기가 승인된 뒤 그 부서에서 다시 분류를 제안한다.
- **거절**: "사용자가 거절함"은 작업 상태 메모로 Think에게 알리고, 같은 내용을 다시 내지 않게 한다(지침). 거절된 맥락 제외·중요 표시
  제안이 이번 대상 메시지를 모두 담고 있으면, 사용자가 이번 메시지에서 직접 요청한 경우가 아니면 서버가 받지 않는다
  (`organize_rejected_before`).
- **앱**(`think_organize_panel.dart`):
  - 답변 아래 "정리 제안 N건 · 종류" 줄(처리 못 한 건수), 대화 머리 "정리 제안 N" 배지. 넓은 화면(1180px 이상)은 맥락 패널 자리에
    정리 패널, 좁으면 바텀시트로 띄운다.
  - 항목마다 무엇을 바꾸는지, 왜 지금인지, 근거(제안한 답변·대상 메시지 원문 보기), 전후·범위, 고치기, "이번에는 거절".
    처음에는 아무것도 고르지 않는다. 답하는 중에는 승인하지 않는다.
  - 결과는 "기억 1건 저장 · 분류 완료"처럼 보이고, 실패·충돌 항목만 이유와 함께 남긴다. 성공 항목은 다시 승인하라고 하지 않는다.
    나눈 대화로는 자동으로 넘어가지 않고 "나눈 대화 열기"를 보인다.
  - 패널에 들어가는 것: 대기 중인 새 종류 네 개는 늘, 분류·나누기·기억·기억 카드·넘기기는 일괄 승인을 쓸 수 있을 때(`auto_organize`
    준비)만. 코드·삭제 제안은 답변 아래 카드 그대로다. 처리된 제안은 답변 아래에 결과 한 줄로 남는다(되돌리기 포함).
  - 맥락 패널: 승인된 진행 요약, 정리 제안(자동 제안 켜기·끄기, 대기 수, 정리 패널·부서 기준 버튼), 이번 답변에 진행 요약·부서
    기준을 썼는지. 상태 창 "자동 정리 제안" 줄과 같은 켜기·끄기.

| 조합 | 동작 |
|------|------|
| 새 Edge + 이전 DB | `auto_organize` `db_required` → 정리 도구·설정·요약·부서 기준 없음, 예전 카드 |
| 새 Edge + 이전 앱 | `app_update_required` → 정리 도구 없음, 분류·나누기·기억은 예전처럼 |
| 새 앱 + 이전 DB | 기능이 준비되지 않아 정리 패널을 쓰지 않고 예전 카드. 맥락 패널 "정리 제안"은 준비 필요와 이유만 보이고, 중요 표시 깃발·자동 제안 토글·부서 기준 버튼은 숨김 |
| 새 앱 + 이전 Edge | 기능 상태 없음 → 예전 카드 |
