// 개념 검수 작업(고정 목록 이어하기) 도구. 작업은 대화에 묶이지 않아 새 대화에서 찾아 이어 간다.
// 이 요청이 작업을 넘겨받으면(임대 gen) 그 뒤 쓰기는 모두 그 gen으로 한다. 다른 실행이 넘겨받으면 이 요청의 쓰기는 DB가 거부한다.
// 판단 초안 저장·카드 제출까지만 하고, 검토 기록은 사용자가 카드에서 승인해야 남는다.
// 설계: docs/architecture/concept-library.md "개념 검수 작업"

import type { AiFunctionTool } from '../_shared/ai/types.ts';
import type { ActionRow, ActionToolContext } from './actions.ts';
import { diagnosisFromReason } from './concept_review_diagnosis.ts';
import type { ToolRunResult } from './tools.ts';

/** compared_ids·to_compare_ids 각각 허용하는 고유 개념 수. DB concept_review_ref_limit() 와 같다. */
export const CONCEPT_REVIEW_REF_LIMIT = 20;

export const JOB_FIND_TOOL_NAME = 'find_concept_review_jobs';
export const JOB_START_TOOL_NAME = 'start_concept_review_job';
export const JOB_READ_TOOL_NAME = 'get_concept_review_job';
export const JOB_SAVE_TOOL_NAME = 'save_concept_review_progress';
export const JOB_SUBMIT_TOOL_NAME = 'submit_concept_review_drafts';
export const JOB_CONTROL_TOOL_NAME = 'control_concept_review_job';

export const REVIEW_JOB_TOOL_NAMES = new Set([
  JOB_FIND_TOOL_NAME,
  JOB_START_TOOL_NAME,
  JOB_READ_TOOL_NAME,
  JOB_SAVE_TOOL_NAME,
  JOB_SUBMIT_TOOL_NAME,
  JOB_CONTROL_TOOL_NAME,
]);
/** 카드를 내거나 대화로 옮기는 도구. 커서 질문(readOnly)에는 주지 않는다. */
export const REVIEW_JOB_ACTING_TOOL_NAMES = new Set([JOB_SUBMIT_TOOL_NAME, JOB_CONTROL_TOOL_NAME, JOB_START_TOOL_NAME, JOB_SAVE_TOOL_NAME]);

export const REVIEW_JOB_TOOL_LABELS: Record<string, string> = {
  [JOB_FIND_TOOL_NAME]: '검수 작업 찾기',
  [JOB_START_TOOL_NAME]: '검수 작업 열기',
  [JOB_READ_TOOL_NAME]: '검수 작업 이어 읽기',
  [JOB_SAVE_TOOL_NAME]: '검수 진행 저장',
  [JOB_SUBMIT_TOOL_NAME]: '검수 카드 제출',
  [JOB_CONTROL_TOOL_NAME]: '검수 작업 관리',
};

export type ReviewJobRpc =
  | 'concept_review_jobs_find'
  | 'concept_review_job_start'
  | 'concept_review_job_claim'
  | 'concept_review_job_status'
  | 'concept_review_job_next'
  | 'concept_review_job_save'
  | 'concept_review_job_submit'
  | 'concept_review_job_cards_here'
  | 'concept_review_job_control'
  | 'concept_review_job_material'
  | 'concept_review_job_batch_begin'
  | 'concept_review_job_batch_log'
  | 'concept_review_job_targets'
  | 'concept_review_job_courses'
  | 'concept_review_job_search'
  | 'concept_review_job_failure_page';

export const REVIEW_JOB_RPCS: ReadonlySet<ReviewJobRpc> = new Set<ReviewJobRpc>([
  'concept_review_job_targets',
  'concept_review_job_courses',
  'concept_review_job_search',
  'concept_review_jobs_find',
  'concept_review_job_start',
  'concept_review_job_claim',
  'concept_review_job_status',
  'concept_review_job_next',
  'concept_review_job_save',
  'concept_review_job_submit',
  'concept_review_job_cards_here',
  'concept_review_job_control',
  'concept_review_job_material',
  'concept_review_job_batch_begin',
  'concept_review_job_batch_log',
  'concept_review_job_failure_page',
]);

export interface ReviewJobToolSource {
  reviewJobRpc?(fn: ReviewJobRpc, args: Record<string, unknown>): Promise<unknown>;
}

export interface ReviewJobToolContext {
  /** 임대를 잡을 때 쓰는 이 실행의 이름(요청마다 다름) */
  holder: string;
  /** 이 요청이 넘겨받은 작업별 gen. 자동 이어하기는 관문이 준 gen을 미리 넣는다. */
  leases: Map<string, number>;
  /** 이 답변에서 낸 검수 카드 수 */
  cards: number;
  /** 자동 이어하기 실행이면 남은 저장 개수와 넘겨받기 금지 */
  itemsLeft?: number | null;
  noTakeover?: boolean;
  /** 이 요청에서 묶음 검수를 이미 돌렸는지(한 답변에 한 번). */
  batchRan?: boolean;
}

/** 한 요청에서 낼 수 있는 검수 카드 수. DB 작업 한도 max_cards_per_request 기본값과 같다. */
export const REVIEW_CARDS_PER_REQUEST = 13;
const CARD_LIMIT = REVIEW_CARDS_PER_REQUEST;
const OUTPUT_CHARS = 14000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const REVIEW_JOB_SCOPES = ['notation', 'meaning', 'classification', 'unit', 'relations', 'foundation', 'placement'];
/** 통합 완료 3조건(표기·의미 / 초등 기초 개념 / 배치)에 드는 범위. 이 범위의 문제 있음에는 고치기 제안이 있어야 한다. */
export const REQUIRED_SCOPES = ['notation', 'meaning', 'foundation', 'placement'];
const SCOPES = REVIEW_JOB_SCOPES;
const OUTCOMES = ['no_issue_found', 'issue_found', 'needs_comparison', 'unverified', 'merge_needed'];

/** 고치기 제안 한 줄. 범위에 따라 쓰는 칸이 다르고 안 쓰는 칸은 null 이다. */
export const FIX_OP_SCHEMA = {
  type: 'object',
  properties: {
    op: { type: 'string', enum: ['edit', 'create', 'place', 'move', 'remove'] },
    name: { type: ['string', 'null'] },
    content: { type: ['string', 'null'] },
    type: { type: ['string', 'null'] },
    folder: { type: ['array', 'null'], items: { type: 'string' } },
    unit_id: { type: ['string', 'null'] },
    placement_id: { type: ['string', 'null'] },
    basis: { type: ['string', 'null'], enum: ['source', 'judgment', null] },
    evidence: { type: ['string', 'null'] },
  },
  required: ['op', 'name', 'content', 'type', 'folder', 'unit_id', 'placement_id', 'basis', 'evidence'],
  additionalProperties: false,
};

type Rec = Record<string, unknown>;

const nullableString = (description: string) => ({ type: ['string', 'null'], description });
const jobId = { type: 'string', description: '검수 작업 id(find_concept_review_jobs·start_concept_review_job 결과)' };

export const REVIEW_JOB_TOOLS: AiFunctionTool[] = [
  {
    name: JOB_FIND_TOOL_NAME,
    description:
      '이어 갈 개념 검수 작업과 최근 순회 목록을 찾는다. 아무것도 만들거나 지우지 않는다. 대화와 상관없이 모든 작업이 보인다. ' +
      '작업이 여러 개면 고르지 말고 사용자에게 어느 작업인지 묻는다. 목록의 deleted_after는 작업이 없는 목록이 지워지는 때다.',
    parameters: { type: 'object', properties: {}, required: [], additionalProperties: false },
  },
  {
    name: JOB_START_TOOL_NAME,
    description:
      '이미 있는 순회 목록(walk_id)으로 검수 작업을 연다. 목록을 새로 만들지 않는다. 같은 목록의 작업이 있으면 그 작업을 돌려준다. ' +
      '작업이 열린 목록은 30일이 지나도 지워지지 않는다. 사용자가 그 목록으로 검수를 이어 가자고 했을 때만 쓴다.',
    parameters: {
      type: 'object',
      properties: {
        walk_id: { type: 'string', description: '순회 목록 id(사용자·기억이 말한 것이나 find 결과의 walk_id)' },
        title: { type: 'string', description: '작업 이름(120자 이내, 예: "배치 개념 514개 검수")' },
      },
      required: ['walk_id', 'title'],
      additionalProperties: false,
    },
  },
  {
    name: JOB_READ_TOOL_NAME,
    description:
      '검수 작업의 진행 상태와 다음 묶음을 읽는다. 이 답변이 작업을 넘겨받는다(앞선 실행이 아직 쓰고 있었다면 그 실행의 이후 쓰기는 거부된다). ' +
      'progress_line(완료 수), counts, 미결 항목(open_items: 위치·이유·다음 할 일·diagnosis), 승인 대기 카드(pending_cards: 다른 대화 것 포함), ' +
      '실패 항목(failures: 저장된 reason과 diagnosis, 한 번에 50개, failure_after 다음부터). ' +
      'next>0이면 다음 묶음(batch: 위치·개념 요약·판)을 준다. 묶음은 저장된 위치 다음부터이며 앞서 내줬지만 저장되지 않은 위치가 먼저 다시 나온다. ' +
      '이미 지금 판과 맞는 승인 기록이 있는 개념·지워진 개념·승인 대기 카드에 든 개념은 서버가 판단 없이 표시하고 건너뛴다(auto_saved). ' +
      'diagnosis.kind가 specific이면 code·scope·field가 저장된 첫 원인이다. generic은 범위·필드가 없는 예전 포괄 오류다. 원인을 만들어 넣지 않는다.',
    parameters: {
      type: 'object',
      properties: {
        job_id: jobId,
        next: { type: ['integer', 'null'], description: '다음 묶음 개수(1~5). 상태만 보려면 0이나 null' },
        failure_after: { type: ['integer', 'null'], description: '저장된 실패를 이 위치 다음부터 읽는다. 처음부터 보려면 0이나 null. next와 작업 임대는 바꾸지 않는다.' },
      },
      required: ['job_id', 'next'],
      additionalProperties: false,
    },
  },
  {
    name: JOB_SAVE_TOOL_NAME,
    description:
      '위치마다 판단 초안이나 미결 상태를 저장한다(10개까지, 위치마다 따로 저장·거부). 저장해야 다음 대화에서 이어진다. ' +
      'drafted: get_concept_for_edit로 다 읽은 뒤(read_complete true) 범위별 판단(reviews)과 읽은 revision. ' +
      'deferred: 지금 판단할 수 없음(reason, next_action 필수). failed: 읽기·판단 실패(reason, next_action 필수). ' +
      '같은 내용을 다시 저장하면 unchanged다. 승인 대기 중인 위치는 저장할 수 없고, 통합 완료(표기·의미·초등 기초 개념·배치 모두 승인)된 위치는 구체적 재확인 사유가 있을 때만 rework true로 다시 저장한다. ' +
      '통합 완료가 아니면 부족한 범위(open_items의 todo)만 판단해 저장한다. ' +
      '거절된 카드와 같은 판단은 다시 저장되지 않는다.',
    parameters: {
      type: 'object',
      properties: {
        job_id: jobId,
        items: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              position: { type: 'integer', description: '목록 위치(batch·open_items의 position)' },
              concept_id: { type: 'string', description: '그 위치의 개념 id' },
              state: { type: 'string', enum: ['drafted', 'deferred', 'failed'] },
              revision: nullableString('drafted: 읽은 판(revision) 그대로'),
              read_complete: { type: 'boolean', description: '본문·서술을 잘림 없이 다 읽었는지' },
              unread: nullableString('다 읽지 못한 부분'),
              reviews: {
                type: ['array', 'null'],
                description: 'drafted: 범위별 판단 1~7개(propose_concept_review 항목과 같은 칸 + fix). 다른 상태면 null',
                items: {
                  type: 'object',
                  properties: {
                    scope: { type: 'string', enum: SCOPES },
                    outcome: { type: 'string', enum: OUTCOMES },
                    checked: { type: 'string' },
                    findings: { type: 'string' },
                    basis: { type: 'string' },
                    unverified: { type: ['string', 'null'] },
                    follow_up: { type: ['string', 'null'] },
                    compared_ids: { type: ['array', 'null'], items: { type: 'string' } },
                    to_compare_ids: { type: ['array', 'null'], items: { type: 'string' } },
                    fix: {
                      type: ['object', 'null'],
                      description:
                        'issue_found 일 때의 고치기 제안(다른 결과면 null). notation·meaning·foundation·placement 의 문제 있음에는 꼭 넣는다. ' +
                        'notation·meaning: library/edit 1개(name·content), classification: library/edit(type·folder), ' +
                        'foundation: library/create 1~3개(name·type·folder·content, 배치하지 않음), ' +
                        'placement: placement/place(unit_id·basis·evidence)·move(placement_id·unit_id·evidence)·remove(placement_id·evidence) 1~5개(이 개념의 배치만)',
                      properties: {
                        kind: { type: 'string', enum: ['library', 'placement'] },
                        ops: { type: 'array', items: FIX_OP_SCHEMA },
                      },
                      required: ['kind', 'ops'],
                      additionalProperties: false,
                    },
                  },
                  required: [
                    'scope', 'outcome', 'checked', 'findings', 'basis', 'unverified', 'follow_up', 'compared_ids', 'to_compare_ids', 'fix',
                  ],
                  additionalProperties: false,
                },
              },
              next_action: nullableString('다음에 할 일(300자 이내)'),
              reason: nullableString('미결·실패 이유(500자 이내)'),
              rework: { type: 'boolean', description: '완료·거절된 위치를 구체적 사유로 다시 판단할 때만 true' },
            },
            required: ['position', 'concept_id', 'state', 'revision', 'read_complete', 'unread', 'reviews', 'next_action', 'reason', 'rework'],
            additionalProperties: false,
          },
        },
      },
      required: ['job_id', 'items'],
      additionalProperties: false,
    },
  },
  {
    name: JOB_SUBMIT_TOOL_NAME,
    description:
      '저장된 판단 초안(drafted)을 위치 순서대로 모아 검토 기록 카드 한 장과, 고치기 제안이 있으면 개념 고치기 카드·과정 배치 카드를 함께 이 대화에 낸다' +
      '(검토 20개·크기 한도 안, 고치기 카드도 장수에 들어 한 요청에 13장, 작업의 승인 대기 15장까지). 고치기 카드가 거부된 위치는 failed(fix_invalid)로 빠진다. ' +
      '같은 초안을 두 번 내도 카드는 하나다. 낼 때 판이 바뀐 위치는 failed로 돌리고(다시 읽기), 같은 범위가 다른 대기 카드에 있으면 빼 둔다(blocked). ' +
      '승인 대기 카드가 작업 한도만큼 있으면 막힌다. 사용자가 승인한 항목만 기록으로 남는다.',
    parameters: {
      type: 'object',
      properties: { job_id: jobId, reason: { type: 'string', description: '카드 이유 한두 문장' } },
      required: ['job_id', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: JOB_CONTROL_TOOL_NAME,
    description:
      'pause(멈춤)·resume(다시 시작)·cancel(그만두기, 기록은 지우지 않음)은 사용자가 요청했을 때만 쓴다. ' +
      'bring_cards: 이 작업의 승인 대기 카드(다른 대화에서 낸 것 포함)를 이 대화로 옮겨 여기서 승인할 수 있게 한다. 카드 내용과 상태는 그대로다. ' +
      '예전에 낸 대기 카드는 항목이 모두 이 목록 개념이면 이어 옮기고, 섞였으면 conflicts로 알리고 건드리지 않는다.',
    parameters: {
      type: 'object',
      properties: { job_id: jobId, action: { type: 'string', enum: ['pause', 'resume', 'cancel', 'bring_cards'] } },
      required: ['job_id', 'action'],
      additionalProperties: false,
    },
  },
];

const ERRORS: Record<string, [string, string]> = {
  concept_review_forbidden: ['권한 없음', '운영자만 쓸 수 있다. 작업이 없다는 뜻이 아니다. 사용자에게 알린다.'],
  concept_review_walk_not_found: [
    '없는 목록',
    '그 목록이 없다(지워졌거나 id가 틀림). 새 목록을 만들지 말고 사용자에게 알린 뒤 어떻게 할지 묻는다.',
  ],
  concept_review_job_not_found: ['없는 작업', 'job_id는 find_concept_review_jobs 결과의 것만 쓴다.'],
  concept_review_job_bad_title: ['이름 오류', 'title은 1~120자다.'],
  concept_review_job_not_active: ['멈춘 작업', '멈췄거나 그만둔 작업이다. 사용자가 다시 시작하자고 할 때만 resume한다.'],
  concept_review_job_busy: ['다른 실행 중', '다른 실행이 이 작업을 쓰고 있다.'],
  concept_review_job_lease_lost: [
    '다른 실행이 넘겨받음',
    '이 답변 뒤 다른 대화·실행이 이 작업을 넘겨받았다. 이 답변에서는 더 저장·제출하지 않고 사용자에게 알린다.',
  ],
  concept_review_job_no_items: ['항목 없음', 'items에 1~10개를 넣는다.'],
  concept_review_job_too_many: ['항목이 많음', '한 번에 10개까지 저장한다.'],
  concept_review_job_pending_full: [
    '승인 대기 카드가 많음',
    '이 작업의 승인 대기 카드가 한도만큼 있다. 사용자에게 먼저 승인·거절해 달라고 하고 더 내지 않는다.',
  ],
  concept_review_job_conflict: ['멱등 충돌', '같은 초안 판으로 다른 내용이 들어왔다. 진행을 멈추고 사용자에게 알린다.'],
  concept_review_job_bad_transition: ['바꿀 수 없는 상태', '지금 상태에서는 그 동작을 할 수 없다. get_concept_review_job으로 상태를 본다.'],
  concept_review_job_bad_action: ['동작 오류', 'action은 pause·resume·cancel·bring_cards 중 하나다.'],
  course_think_reason_required: ['이유 없음', 'reason을 채운다.'],
  conversation_not_found: ['대화 없음', '이 대화를 찾지 못했다. 사용자에게 알린다.'],
};

/** 위치별 저장 오류 → 다음 할 일. */
const ITEM_NEXT: Record<string, string> = {
  concept_review_job_bad_position: 'position은 batch·open_items의 것만 쓴다.',
  concept_review_job_wrong_concept: '그 위치의 개념 id가 아니다. batch의 position과 concept_id를 짝으로 쓴다.',
  concept_review_job_not_served: '아직 받지 않은 위치다. get_concept_review_job으로 받은 위치만 저장한다.',
  concept_review_job_bad_state: 'state는 drafted·deferred·failed 중 하나다.',
  concept_review_job_read_incomplete: '다 읽지 못했으면 drafted가 아니라 deferred로 저장하고 unread·next_action을 쓴다.',
  concept_review_job_bad_reviews: 'drafted는 reviews에 범위 1~7개를 넣는다.',
  concept_review_fix_required: 'notation·meaning·foundation·placement 의 issue_found 에는 fix(고치기 제안)를 넣는다.',
  concept_review_bad_fix: 'fix 형식이 범위와 맞지 않다(범위별 kind·op·칸을 확인). issue_found 가 아니면 fix 는 null 이다.',
  concept_review_fix_not_own: 'placement 고치기는 이 개념의 배치(placement_id)만 옮기거나 뺀다.',
  concept_review_fix_no_place: '새 기초 개념은 배치하지 않는다(교육과정 위치 미확인).',
  course_placement_evidence_required: '배치 고치기에는 evidence(출처·근거)를 쓴다.',
  course_placement_unit_not_found: 'unit_id는 과정 단원 목록의 것만 쓴다.',
  course_placement_bad_basis: 'place의 basis는 source 또는 judgment다.',
  concept_think_unknown_type: '새 개념 type은 있는 유형 이름만 쓴다.',
  concept_think_bad_folder: 'folder는 최상위 폴더부터 2~7칸 경로다.',
  concept_think_unknown_root: 'folder 첫 칸은 있는 최상위 폴더 이름이다.',
  concept_review_job_next_required: 'deferred·failed는 reason과 next_action을 쓴다.',
  concept_review_job_item_pending: '이 위치는 승인 대기 카드에 있다. 승인 결과를 기다린다.',
  concept_review_job_item_done: '이미 완료된 위치다. 구체적 재확인 사유가 없으면 다시 검수하지 않는다.',
  concept_review_job_same_as_rejected: '거절된 카드와 같은 판단이다. 사용자 의견을 듣고 고친 판단만 저장한다.',
  concept_review_stale: '읽은 뒤 그 범위 내용이 바뀌었다(또는 revision을 잘못 옮겼다). 다시 읽고 판단한다.',
  concept_review_revision_required: 'revision에 읽은 판을 그대로 넣는다.',
  concept_review_concept_not_found: '개념이 지워졌다. failed로 저장하고 사용자에게 알린다.',
  concept_review_duplicate: '같은 범위를 두 번 넣지 않는다.',
  concept_review_text_required: 'checked·findings·basis는 비우지 않는다.',
  concept_review_too_long: 'checked·basis·unverified·follow_up은 1000자, findings는 2000자 이내다.',
  concept_review_ref_not_found: '비교 개념은 이 개념이 아닌 실제 개념 id여야 한다. 잘못된 id·자기 참조·없는 개념은 빼지 않고 거절한다.',
  concept_review_bad_refs: 'compared_ids·to_compare_ids는 개념 id 배열이거나 null이다. 문자열이 아닌 값은 빼지 않고 거절한다.',
  concept_review_too_many_refs:
    `compared_ids·to_compare_ids는 각각 고유 ${CONCEPT_REVIEW_REF_LIMIT}개까지다. 같은 id는 하나로 센다. 21개째는 자르지 않고 개수를 줄인다.`,
};

function rec(v: unknown): Rec {
  return v && typeof v === 'object' && !Array.isArray(v) ? v as Rec : {};
}

/** 상태 응답의 1차 검수 집계. 필드가 없거나 형식이 아니면 미집계이며, 여기서 다시 세지 않는다. */
export function firstPassOf(status: Rec): { known: boolean; value: Rec | null; line: string | null } {
  const raw = status.first_pass;
  const line = status.first_pass_line;
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || typeof line !== 'string') {
    return { known: false, value: null, line: null };
  }
  const fp = raw as Rec;
  if (typeof fp.met !== 'number' || typeof fp.total !== 'number' || typeof fp.line !== 'string') {
    return { known: false, value: null, line: null };
  }
  return { known: true, value: fp, line };
}

function str(v: unknown, max: number): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t ? t.slice(0, max) : null;
}

function uuid(v: unknown): string | null {
  const t = str(v, 64);
  return t && UUID_RE.test(t) ? t : null;
}

function out(name: string, value: unknown, summary: string, actions?: ActionRow[]): ToolRunResult {
  const text = JSON.stringify(value);
  const output = text.length <= OUTPUT_CHARS ? text : JSON.stringify({ truncated: true, preview: text.slice(0, OUTPUT_CHARS) });
  return { name, ok: true, output, summary, ...(actions?.length ? { actions } : {}) };
}

function bad(name: string, error: string, summary: string, next: string): ToolRunResult {
  return { name, ok: false, output: JSON.stringify({ error, next }), summary };
}

/** "함수: 코드[:...]" → 코드. */
export function errorCode(e: unknown): string {
  const message = e instanceof Error ? e.message : String(e);
  const tail = message.includes(': ') ? message.slice(message.lastIndexOf(': ') + 2) : message;
  return tail.trim().split(':')[0];
}

export function rpcError(name: string, e: unknown): ToolRunResult {
  const code = errorCode(e);
  const known = ERRORS[code];
  if (!known) throw e;
  return bad(name, code, known[0], known[1]);
}

export async function lease(state: ReviewJobToolContext, src: ReviewJobToolSource, job: string): Promise<number> {
  const held = state.leases.get(job);
  if (held !== undefined) return held;
  if (state.noTakeover) throw new Error('concept_review_job_claim: concept_review_job_lease_lost');
  const r = rec(await src.reviewJobRpc!('concept_review_job_claim', { p_job_id: job, p_holder: state.holder, p_mode: 'take' }));
  const gen = typeof r.gen === 'number' ? r.gen : Number(r.gen);
  if (!Number.isFinite(gen)) throw new Error('concept_review_job_claim: unexpected result');
  state.leases.set(job, gen);
  return gen;
}

function briefOf(raw: unknown): Rec {
  const c = rec(raw);
  return {
    name: c.name,
    type: c.type ?? null,
    folder: Array.isArray(c.folder) ? c.folder.join(' › ') : '',
    excerpt: c.excerpt,
    chars: c.content_chars,
    statements: c.statements,
    sources: c.sources,
    relations: c.relations,
    same_name: c.same_name,
    revision: c.revision,
    review: c.review ?? {},
  };
}

function failureView(page: Rec): Rec {
  const rawItems = Array.isArray(page.items) ? page.items : null;
  if (!rawItems) {
    return { returned: 0, omitted: null, next_after: null, items: [], read_more: null, unavailable: true };
  }
  const items = rawItems.map((raw) => {
    const item = rec(raw);
    const reason = typeof item.reason === 'string' ? item.reason : null;
    return {
      position: item.position ?? null,
      concept_id: typeof item.concept_id === 'string' ? item.concept_id : null,
      name: typeof item.name === 'string' ? item.name : null,
      reason,
      next_action: typeof item.next_action === 'string' ? item.next_action : null,
      diagnosis: diagnosisFromReason(reason),
    };
  });
  const omitted = Number(page.omitted ?? 0);
  const omittedN = Number.isFinite(omitted) ? omitted : 0;
  return {
    returned: items.length,
    omitted: omittedN,
    next_after: page.next_after ?? null,
    items,
    read_more: omittedN > 0 ? 'failure_after에 next_after를 넣어 get_concept_review_job을 다시 부른다.' : null,
    unavailable: false,
  };
}

async function readJob(name: string, args: Rec, src: ReviewJobToolSource, state: ReviewJobToolContext): Promise<ToolRunResult> {
  const job = uuid(args.job_id);
  if (!job) return bad(name, 'invalid_id', 'id 형식 오류', 'job_id는 find_concept_review_jobs 결과의 것을 쓴다.');
  const want = typeof args.next === 'number' ? Math.max(0, Math.min(5, Math.floor(args.next))) : 0;
  const after = typeof args.failure_after === 'number' && Number.isFinite(args.failure_after)
    ? Math.max(0, Math.floor(args.failure_after))
    : 0;
  let status: Rec;
  let batch: Rec | null = null;
  let failurePage: Rec = {};
  try {
    if (want > 0) {
      const gen = await lease(state, src, job);
      batch = rec(await src.reviewJobRpc!('concept_review_job_next', { p_job_id: job, p_gen: gen, p_count: want }));
    }
    status = rec(await src.reviewJobRpc!('concept_review_job_status', { p_job_id: job, p_open_limit: 20 }));
    failurePage = rec(await src.reviewJobRpc!('concept_review_job_failure_page', { p_job_id: job, p_after: after, p_limit: 50 }));
  } catch (e) {
    if (errorCode(e) === 'concept_review_job_lease_lost') state.leases.delete(job);
    return rpcError(name, e);
  }
  if (typeof status.progress_line !== 'string') throw new Error('concept_review_job_status: unexpected result');
  const notes: string[] = [`진행 표시는 "${status.progress_line}" 한 줄로 한다. 조건별 충족 수(condition_line)는 통합 완료 수와 섞지 않는다.`];
  const first = firstPassOf(status);
  if (first.known) {
    notes.push(`1차 검수 3조건 동시 충족은 "${first.line}" 한 줄로 한다. 통합 완료·조건별 충족 수와 섞지 않고, 조건별 수로 이 수를 추산하지 않는다.`);
  } else {
    notes.push('1차 검수 3조건 동시 충족 수는 이 응답에 없다(미집계). 0개로 말하지 말고, 조건별 충족 수로 추산하지 않는다.');
  }
  if (status.total_mismatch === true) notes.push('목록 총수와 작업 총수가 다르거나 지워진 개념이 있다(total_mismatch). 사용자에게 알린다.');
  const pending = Array.isArray(status.pending_cards) ? status.pending_cards : [];
  if (pending.some((c) => rec(c).linked !== true)) {
    notes.push('작업에 이어지지 않은 예전 대기 카드가 있다. bring_cards로 이어 옮기거나 conflicts를 사용자에게 알린다.');
  }
  const value: Rec = {
    job: status.job,
    progress_line: status.progress_line,
    condition_line: status.condition_line ?? null,
    first_pass: first.known ? first.value : null,
    first_pass_line: first.known ? first.line : null,
    first_pass_state: first.known ? 'counted' : 'unaggregated',
    counts: status.counts,
    total_mismatch: status.total_mismatch,
    open_items: (Array.isArray(status.open_items) ? status.open_items : []).map((raw) => {
      const item = rec(raw);
      const reason = typeof item.reason === 'string' ? item.reason : null;
      return { ...item, diagnosis: diagnosisFromReason(reason) };
    }),
    pending_cards: pending,
    failures: failureView(failurePage),
  };
  if (batch) {
    value.batch = (Array.isArray(batch.batch) ? batch.batch : []).map((b) => {
      const r = rec(b);
      return { position: r.position, concept_id: r.concept_id, state: r.state, ...briefOf(r.concept) };
    });
    value.auto_saved = batch.auto_saved;
    value.checkpoint = batch.checkpoint;
    value.reached_end = batch.reached_end;
    notes.push('batch의 개념은 get_concept_for_edit로 다 읽고 판단한 뒤 save_concept_review_progress로 저장한다. 저장하지 않은 판단은 이어지지 않는다.');
  }
  const failures = rec(value.failures);
  if (failures.unavailable === true) {
    notes.push('저장된 실패 목록은 이 응답에 없다. open_items의 reason만 본다.');
  } else if (Number(failures.omitted) > 0) {
    notes.push('실패 목록이 잘렸다. failure_after에 failures.next_after를 넣어 다시 읽는다.');
  }
  const stored = [
    ...(Array.isArray(value.open_items) ? value.open_items : []),
    ...(Array.isArray(failures.items) ? failures.items : []),
  ];
  if (stored.some((item) => rec(rec(item).diagnosis).kind === 'generic')) {
    notes.push('diagnosis.kind가 generic인 항목은 예전 포괄 오류다. 범위와 필드를 만들어 넣지 않는다.');
  }
  value.note = notes.join(' ');
  return out(name, value, String(status.progress_line));
}

async function saveProgress(name: string, args: Rec, src: ReviewJobToolSource, state: ReviewJobToolContext): Promise<ToolRunResult> {
  const job = uuid(args.job_id);
  if (!job) return bad(name, 'invalid_id', 'id 형식 오류', 'job_id는 find_concept_review_jobs 결과의 것을 쓴다.');
  const items = Array.isArray(args.items) ? args.items : [];
  if (items.length === 0 || items.length > 10) return bad(name, 'concept_review_job_no_items', '항목 수 오류', 'items에 1~10개를 넣는다.');
  if (state.itemsLeft != null) {
    if (state.itemsLeft <= 0) return bad(name, 'run_item_limit', '실행 한도', '이번 자동 실행의 저장 한도에 닿았다. 여기서 멈춘다.');
    if (items.length > state.itemsLeft) items.length = state.itemsLeft;
  }
  let data: Rec;
  try {
    const gen = await lease(state, src, job);
    data = rec(await src.reviewJobRpc!('concept_review_job_save', { p_job_id: job, p_gen: gen, p_items: items }));
  } catch (e) {
    if (errorCode(e) === 'concept_review_job_lease_lost') state.leases.delete(job);
    return rpcError(name, e);
  }
  const results = (Array.isArray(data.items) ? data.items : []).map((raw) => {
    const r = rec(raw);
    if (r.status !== 'error') return r;
    const code = errorCode(new Error(String(r.code ?? '')));
    return { position: r.position, status: 'error', code, next: ITEM_NEXT[code] ?? '사용자에게 알린다.' };
  });
  const saved = typeof data.saved === 'number' ? data.saved : 0;
  if (state.itemsLeft != null) state.itemsLeft -= saved;
  return out(name, { items: results, saved, checkpoint: data.checkpoint }, `저장 ${saved}/${items.length}`);
}

async function submitDrafts(
  name: string,
  args: Rec,
  src: ReviewJobToolSource,
  state: ReviewJobToolContext,
  conversationId: string,
): Promise<ToolRunResult> {
  const job = uuid(args.job_id);
  if (!job) return bad(name, 'invalid_id', 'id 형식 오류', 'job_id는 find_concept_review_jobs 결과의 것을 쓴다.');
  if (state.cards >= CARD_LIMIT) {
    return bad(name, 'course_think_card_limit', '카드 수 한도', '한 답변에 낼 수 있는 검수 카드 수를 넘었다. 나머지는 다음 답변에서 낸다.');
  }
  const reason = str(args.reason, 500);
  if (!reason) return bad(name, 'course_think_reason_required', '이유 없음', 'reason을 채운다.');
  let data: Rec;
  try {
    const gen = await lease(state, src, job);
    data = rec(await src.reviewJobRpc!('concept_review_job_submit', {
      p_job_id: job, p_gen: gen, p_conversation_id: conversationId, p_reason: reason, p_max_cards: CARD_LIMIT - state.cards,
    }));
  } catch (e) {
    if (errorCode(e) === 'concept_review_job_lease_lost') state.leases.delete(job);
    return rpcError(name, e);
  }
  const failed = Array.isArray(data.failed) ? data.failed : [];
  const blocked = Array.isArray(data.blocked) ? data.blocked : [];
  if (data.submitted !== true) {
    return out(name, {
      submitted: false, failed, blocked,
      note: '낼 초안이 없다(카드를 내지 않았다). failed 위치는 다시 읽고 판단해 저장하고, blocked 위치는 다른 대기 카드의 승인 결과를 기다린다.',
    }, '낼 초안 없음');
  }
  const action = rec(data.action) as unknown as ActionRow;
  const fixes = (Array.isArray(data.fix_actions) ? data.fix_actions : []).map((a) => rec(a) as unknown as ActionRow);
  const existing = data.existing === true;
  if (!existing) state.cards += 1 + fixes.length;
  return out(
    name,
    {
      ok: true,
      action_id: action.id,
      fix_action_ids: fixes.map((a) => a.id),
      status: action.status,
      existing,
      positions: data.positions,
      failed,
      blocked,
      note: existing
        ? '같은 초안으로 이미 낸 카드다. 새 카드를 만들지 않았다.'
        : '검토 기록 카드(와 고치기 카드)가 사용자에게 보였다. 사용자가 승인한 항목만 기록·변경으로 남는다. 승인 전에는 기록됐다·완료했다·고쳤다고 말하지 않는다.',
    },
    existing ? '이미 낸 카드' : `카드 제출(위치 ${Array.isArray(data.positions) ? data.positions.length : 0}개, 고치기 카드 ${fixes.length}장)`,
    existing ? undefined : [...fixes, action],
  );
}

async function control(
  name: string,
  args: Rec,
  src: ReviewJobToolSource,
  state: ReviewJobToolContext,
  conversationId: string,
): Promise<ToolRunResult> {
  const job = uuid(args.job_id);
  if (!job) return bad(name, 'invalid_id', 'id 형식 오류', 'job_id는 find_concept_review_jobs 결과의 것을 쓴다.');
  const action = args.action;
  try {
    if (action === 'bring_cards') {
      const gen = await lease(state, src, job);
      const data = rec(await src.reviewJobRpc!('concept_review_job_cards_here', { p_job_id: job, p_gen: gen, p_conversation_id: conversationId }));
      const cards = (Array.isArray(data.cards) ? data.cards : []).map((c) => rec(c) as unknown as ActionRow);
      const conflicts = Array.isArray(data.conflicts) ? data.conflicts : [];
      return out(
        name,
        {
          cards: cards.map((c) => c.id),
          conflicts,
          note: cards.length > 0
            ? '승인 대기 카드를 이 대화로 옮겼다. 사용자가 여기서 승인·거절할 수 있다. 카드 내용과 승인 이력은 그대로다.'
            : '옮길 승인 대기 카드가 없다.',
        },
        `카드 ${cards.length}장`,
        cards,
      );
    }
    if (action !== 'pause' && action !== 'resume' && action !== 'cancel') {
      return bad(name, 'concept_review_job_bad_action', '동작 오류', ERRORS.concept_review_job_bad_action[1]);
    }
    const data = rec(await src.reviewJobRpc!('concept_review_job_control', { p_job_id: job, p_action: action }));
    state.leases.delete(job);
    return out(name, data, String(data.status ?? ''));
  } catch (e) {
    if (errorCode(e) === 'concept_review_job_lease_lost') state.leases.delete(job);
    return rpcError(name, e);
  }
}

export async function dispatchReviewJobTool(
  name: string,
  args: Rec,
  src: ReviewJobToolSource,
  ctx: ActionToolContext | undefined,
): Promise<ToolRunResult> {
  const state = ctx?.reviewJobs;
  if (!state || !ctx || !src.reviewJobRpc) {
    return bad(name, 'concept_review_jobs_unavailable', '지금은 쓸 수 없음', '검수 작업 기능이 준비되지 않았다. 이어 간다·저장했다고 말하지 않는다.');
  }
  switch (name) {
    case JOB_FIND_TOOL_NAME: {
      let data: Rec;
      try {
        data = rec(await src.reviewJobRpc('concept_review_jobs_find', {}));
      } catch (e) {
        return rpcError(name, e);
      }
      const jobs = Array.isArray(data.jobs) ? data.jobs : [];
      const note = jobs.length > 1
        ? '작업이 여러 개다. 고르지 말고 사용자에게 어느 작업을 이어 갈지 묻는다.'
        : jobs.length === 0
        ? '열린 작업이 없다(조회는 성공했다). 새 목록을 만들지 말고, 이어 갈 목록이 있는지 사용자에게 묻는다.'
        : '작업이 하나다. 사용자가 말한 작업과 같은지 확인하고 get_concept_review_job으로 이어 간다.';
      return out(name, { ...data, note }, `작업 ${jobs.length}개`);
    }
    case JOB_START_TOOL_NAME: {
      const walk = uuid(args.walk_id);
      if (!walk) return bad(name, 'invalid_id', 'id 형식 오류', 'walk_id는 목록 id를 그대로 쓴다.');
      try {
        const data = rec(await src.reviewJobRpc('concept_review_job_start', { p_walk_id: walk, p_title: str(args.title, 120) ?? '' }));
        return out(name, data, data.existing === true ? '이미 있는 작업' : '작업 열림');
      } catch (e) {
        return rpcError(name, e);
      }
    }
    case JOB_READ_TOOL_NAME:
      return await readJob(name, args, src, state);
    case JOB_SAVE_TOOL_NAME:
      return await saveProgress(name, args, src, state);
    case JOB_SUBMIT_TOOL_NAME:
      return await submitDrafts(name, args, src, state, ctx.conversationId);
    case JOB_CONTROL_TOOL_NAME:
      return await control(name, args, src, state, ctx.conversationId);
    default:
      return bad(name, 'unknown_tool', '알 수 없는 도구', '');
  }
}
