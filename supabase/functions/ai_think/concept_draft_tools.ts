// 개념 초안 검토 대화에서만 주는 제안 도구. 초안 id는 모델이 아니라 서버가 읽은 참고(ActionToolContext)에서 온다.
// 제안 RPC(concept_draft_action_propose)가 검사하고 카드 1행만 남긴다. 반영은 사용자가 승인할 때 한다.
// 설계: docs/architecture/concept-library.md §7.2

import type { AiFunctionTool } from '../_shared/ai/types.ts';
import type { ActionKind, ActionRow, ActionToolContext } from './actions.ts';
import type { ToolRunResult } from './tools.ts';

export const DRAFT_CHANGE_TOOL_NAME = 'propose_concept_draft_change';
export const DRAFT_CRITERION_TOOL_NAME = 'propose_concept_criterion_change';
export const DRAFT_RERUN_TOOL_NAME = 'propose_concept_draft_rerun';
export const CONCEPT_DRAFT_TOOL_NAMES = new Set([DRAFT_CHANGE_TOOL_NAME, DRAFT_CRITERION_TOOL_NAME, DRAFT_RERUN_TOOL_NAME]);

export const CONCEPT_DRAFT_TOOL_LABELS: Record<string, string> = {
  [DRAFT_CHANGE_TOOL_NAME]: '개념 초안 변경 제안',
  [DRAFT_CRITERION_TOOL_NAME]: '정리 기준 고치기 제안',
  [DRAFT_RERUN_TOOL_NAME]: '다시 정리 제안',
};

export interface ConceptDraftToolContext {
  draftId: string;
  reviewSaved: boolean;
  criterionIds: string[];
  proposed: Set<string>;
}

export interface ConceptDraftToolSource {
  proposeConceptDraftAction?(conversationId: string, kind: ActionKind, payload: Record<string, unknown>): Promise<ActionRow>;
}

const nullableString = (description: string) => ({ type: ['string', 'null'], description });
const nullableStrings = (description: string) => ({ type: ['array', 'null'], items: { type: 'string' }, description });

export const CONCEPT_DRAFT_TOOLS: AiFunctionTool[] = [
  {
    name: DRAFT_CHANGE_TOOL_NAME,
    description:
      '지금 검토 중인 개념 초안의 저장된 검토를 바꾸자고 카드로 제안한다. 사용자가 바꾸자고 했거나 근거 블록과 어긋나는 점이 분명할 때만 쓴다. ' +
      '항목은 참고 자료의 key로 가리킨다. 한 카드에 여러 변경(최대 30개)을 순서대로 담는다. 사용자가 승인해야 바뀐다. ' +
      'op별로 쓰는 칸: edit(key, title·content 중 바꿀 것), mark(key, mark), type(key, type), folder(key, folder), ' +
      'new_type(name, description, legacy_sub_type, closest_existing, reason), split(key, parts), merge(keys, into, title, content, type). 안 쓰는 칸은 null.',
    parameters: {
      type: 'object',
      properties: {
        ops: {
          type: 'array',
          description: '차례로 적용할 변경',
          items: {
            type: 'object',
            properties: {
              op: { type: 'string', enum: ['edit', 'mark', 'type', 'folder', 'new_type', 'split', 'merge'] },
              key: nullableString('바꿀 항목 key(c0, c0.1 …)'),
              keys: nullableStrings('merge: 합칠 항목 key 2~6개'),
              into: nullableString('merge: 남길 항목 key(keys 중 하나)'),
              title: nullableString('edit·merge: 새 개념 이름'),
              content: nullableString('edit·merge: 새 내용 전체'),
              mark: { type: ['string', 'null'], enum: ['drop', 'keep', null], description: 'mark: drop(빼기) 또는 keep(되살리기)' },
              type: nullableString('type·merge: 유형 이름(확정 유형 또는 거절하지 않은 새 유형)'),
              folder: nullableStrings('folder: 영역부터 시작하는 폴더 경로(2~7칸)'),
              parts: {
                type: ['array', 'null'],
                description: 'split: 나눈 조각 2~6개. 근거 블록은 원래 항목의 블록에서 나눠 준다.',
                items: {
                  type: 'object',
                  properties: {
                    title: { type: 'string' },
                    content: { type: 'string' },
                    type: { type: 'string' },
                    blocks: { type: 'array', items: { type: 'string' } },
                  },
                  required: ['title', 'content', 'type', 'blocks'],
                  additionalProperties: false,
                },
              },
              name: nullableString('new_type: 새 유형 이름'),
              description: nullableString('new_type: 이 유형이 무엇인지 한 문장'),
              legacy_sub_type: { type: ['string', 'null'], enum: ['정의', '연산', '정리', null], description: 'new_type: 기존 분류' },
              closest_existing: nullableString('new_type: 가장 가까운 확정 유형 이름'),
              reason: nullableString('new_type: 기존 유형으로 안 되는 이유'),
            },
            required: [
              'op', 'key', 'keys', 'into', 'title', 'content', 'mark', 'type', 'folder', 'parts',
              'name', 'description', 'legacy_sub_type', 'closest_existing', 'reason',
            ],
            additionalProperties: false,
          },
        },
        reason: { type: 'string', description: '왜 바꾸는지(사용자 발언이나 근거 블록) 한두 문장' },
      },
      required: ['ops', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: DRAFT_CRITERION_TOOL_NAME,
    description:
      '이 초안을 정리할 때 쓴 정리 기준 하나를 고치자고 카드로 제안한다. 사용자가 기준을 바꾸자고 했을 때만 쓴다. ' +
      '승인하면 그 기준의 초안으로만 저장되고, 확정은 사용자가 정리 기준 화면에서 한다. 바꾼 뒤의 제목·본문 전체를 준다.',
    parameters: {
      type: 'object',
      properties: {
        criterion_id: { type: 'string', description: '참고 자료에 있는 기준 id' },
        title: { type: 'string' },
        body: { type: 'string', description: '바꾼 뒤의 기준 본문 전체' },
        reason: { type: 'string', description: '사용자가 어느 발언에서 이렇게 정했는지 한두 문장' },
      },
      required: ['criterion_id', 'title', 'body', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: DRAFT_RERUN_TOOL_NAME,
    description:
      '같은 쪽을 다시 정리해 새 초안을 만들자고 카드로 제안한다(약 $0.09, 전사는 다시 읽지 않는다). 승인하면 지금 초안은 "다시 정리함"으로 닫힌다. ' +
      '기준을 크게 바꿨거나 사용자가 다시 정리하자고 했을 때만 쓴다. 고칠 곳이 몇 개뿐이면 변경 카드를 쓴다. ' +
      '기준은 확정본과 저장된 기준 초안을 함께 쓴다.',
    parameters: {
      type: 'object',
      properties: {
        criterion_ids: { type: 'array', items: { type: 'string' }, description: '다시 정리할 때 쓸 기준 id(최대 10개). 보통 지금 초안의 기준 그대로' },
        reason: { type: 'string', description: '왜 다시 정리하는지 한두 문장' },
      },
      required: ['criterion_ids', 'reason'],
      additionalProperties: false,
    },
  },
];

const MAX_OUTPUT_CHARS = 12000;

function out(name: string, value: unknown, summary: string, action?: ActionRow): ToolRunResult {
  const text = JSON.stringify(value);
  const output = text.length <= MAX_OUTPUT_CHARS ? text : JSON.stringify({ truncated: true, preview: text.slice(0, MAX_OUTPUT_CHARS) });
  return { name, ok: true, output, summary, action };
}

function bad(name: string, error: string, summary: string, next: string): ToolRunResult {
  return { name, ok: false, output: JSON.stringify({ error, next }), summary };
}

function str(v: unknown, max: number): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t ? t.slice(0, max) : null;
}

function strList(v: unknown, maxItems: number, maxChars: number): string[] | null {
  if (!Array.isArray(v)) return null;
  return v.filter((x) => typeof x === 'string').map((x) => (x as string).trim().slice(0, maxChars)).filter(Boolean).slice(0, maxItems);
}

/** 모델이 준 한 줄에서 그 op가 쓰는 칸만 남긴다(null 칸은 보내지 않는다). */
export function cleanOp(raw: unknown): Record<string, unknown> | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const r = raw as Record<string, unknown>;
  const op = typeof r.op === 'string' ? r.op : '';
  const pick = (...fields: string[]) => {
    const o: Record<string, unknown> = { op };
    for (const f of fields) if (r[f] != null) o[f] = r[f];
    return o;
  };
  switch (op) {
    case 'edit':
      return pick('key', 'title', 'content');
    case 'mark':
      return pick('key', 'mark');
    case 'type':
      return pick('key', 'type');
    case 'folder':
      return pick('key', 'folder');
    case 'new_type':
      return pick('name', 'description', 'legacy_sub_type', 'closest_existing', 'reason');
    case 'split':
      return pick('key', 'parts');
    case 'merge':
      return pick('keys', 'into', 'title', 'content', 'type');
    default:
      return null;
  }
}

/** RPC 오류 코드 → 모델에게 돌려줄 요약과 다음 행동. 모르는 오류는 그대로 올린다(조회 실패로 기록). */
const DRAFT_ERRORS: [code: string, summary: string, next: string][] = [
  ['concept_draft_review_not_saved', '저장된 검토 없음', '사용자에게 검토 창에서 먼저 저장해 달라고 말한다. 제안하지 않았다.'],
  ['concept_draft_closed', '닫힌 초안', '이 초안은 닫혔다. 제안하지 않는다.'],
  ['concept_draft_not_found', '초안 없음', '초안을 찾지 못했다. 사용자에게 알린다.'],
  ['concept_draft_action_reason_required', '이유 없음', 'reason을 채워 다시 제안한다.'],
  ['concept_draft_change_bad_op', '변경 형식 오류', 'op별로 쓰는 칸을 다시 확인해 다시 제안한다(나누기 2~6조각, 합치기 2~6개, 변경 30개까지).'],
  ['concept_draft_change_unknown_item', '없는 항목', '참고 자료의 key만 쓴다. 같은 카드 앞에서 나눈 조각은 c0.1처럼 이어진다.'],
  ['concept_draft_change_bad_type', '쓸 수 없는 유형', '확정된 유형이나 거절하지 않은 새 유형 이름만 쓴다. 새 유형이 필요하면 같은 카드 앞쪽에 new_type을 둔다.'],
  ['concept_draft_change_type_exists', '이미 있는 유형', '이미 있는 유형 이름이다. new_type 없이 type으로 그 유형을 고른다.'],
  ['concept_draft_change_bad_folder', '폴더 오류', '폴더 경로는 라이브러리 영역으로 시작하고 2~7칸이다.'],
  ['concept_draft_change_bad_blocks', '근거 블록 오류', '이 초안의 블록 id만 1~200개 쓴다. 추측한 id를 쓰지 않는다.'],
  ['concept_draft_change_bad_text', '글 길이 오류', '이름은 1~200자, 내용은 1~20000자로 채운다.'],
  ['concept_draft_change_dropped', '뺀 항목', '뺀 항목은 나누거나 합칠 수 없다. 먼저 되살리는 mark keep을 앞에 둔다.'],
  ['concept_draft_too_long', '너무 큼', '변경을 줄여 다시 제안한다.'],
  ['concept_criterion_not_in_draft', '이 초안의 기준이 아님', '이 초안을 정리할 때 쓴 기준만 고칠 수 있다.'],
  ['concept_criterion_change_unchanged', '바뀐 것 없음', '지금 기준과 같다. 제안하지 않는다.'],
  ['concept_criteria_not_found', '기준 없음', '참고 자료에 있는 기준 id만 쓴다.'],
  ['concept_criteria_', '기준 글 오류', '제목과 본문 길이를 확인해 다시 제안한다.'],
  ['concept_draft_too_many_criteria', '기준이 너무 많음', '기준은 10개까지다.'],
];

function draftError(name: string, e: unknown): ToolRunResult {
  const message = e instanceof Error ? e.message : String(e);
  const known = DRAFT_ERRORS.find(([code]) => message.includes(code));
  if (!known) throw e;
  return bad(name, known[0], known[1], known[2]);
}

const UNAVAILABLE = '지금은 이 초안에 제안할 수 없다(검토 창 대화가 아니거나 초안이 닫혔다). 제안하지 않는다.';
const CHANGE_NOTE =
  '초안 변경 카드가 사용자에게 보였다. 아직 바뀌지 않았다. 사용자가 승인해야 저장된 검토에 반영된다. 그사이 사용자가 같은 항목을 고치면 승인이 막힌다.';
const CRITERION_NOTE =
  '기준 고치기 카드가 사용자에게 보였다. 승인해도 기준 초안으로만 저장되고 확정되지 않는다. 지금 초안에 적용하려면 다시 정리가 필요하다.';
const RERUN_NOTE = '다시 정리 카드가 사용자에게 보였다. 사용자가 승인해야 새 초안을 만들고, 그때 지금 초안이 닫힌다.';

export async function dispatchConceptDraftTool(
  name: string,
  args: Record<string, unknown>,
  src: ConceptDraftToolSource,
  ctx: ActionToolContext | undefined,
): Promise<ToolRunResult> {
  const draft = ctx?.conceptDraft;
  if (!ctx || !draft || !src.proposeConceptDraftAction) return bad(name, 'concept_draft_unavailable', '지금은 제안할 수 없음', UNAVAILABLE);
  if (draft.proposed.has(name)) return bad(name, 'concept_draft_already_proposed', '이미 제안함', '한 답변에 같은 종류의 카드는 하나만 낸다. 변경은 한 카드에 모은다.');
  const reason = str(args.reason, 500);
  if (!reason) return bad(name, 'concept_draft_action_reason_required', '이유 없음', 'reason을 채워 다시 제안한다.');

  let kind: ActionKind;
  let payload: Record<string, unknown>;
  let summary: string;
  let note: string;
  if (name === DRAFT_CHANGE_TOOL_NAME) {
    if (!draft.reviewSaved) {
      return bad(name, 'concept_draft_review_not_saved', '저장된 검토 없음', '사용자에게 검토 창에서 먼저 저장해 달라고 말한다. 제안하지 않았다.');
    }
    const raw = Array.isArray(args.ops) ? args.ops : [];
    const ops = raw.map(cleanOp);
    if (ops.length === 0 || ops.length > 30 || ops.some((o) => o === null)) {
      return bad(name, 'concept_draft_change_bad_op', '변경 형식 오류', 'op는 edit·mark·type·folder·new_type·split·merge 중 하나이고, 변경은 1~30개다.');
    }
    kind = 'concept_draft_change';
    payload = { draft_id: draft.draftId, ops, reason };
    summary = `변경 ${ops.length}건`;
    note = CHANGE_NOTE;
  } else if (name === DRAFT_CRITERION_TOOL_NAME) {
    const criterionId = str(args.criterion_id, 64);
    if (!criterionId || !draft.criterionIds.includes(criterionId)) {
      return bad(name, 'concept_criterion_not_in_draft', '이 초안의 기준이 아님', '참고 자료에 있는 이 초안의 기준 id만 쓴다.');
    }
    const title = str(args.title, 200);
    const body = typeof args.body === 'string' ? args.body.trim() : '';
    if (!title || !body) return bad(name, 'missing_fields', '정보 부족', '바꾼 뒤의 제목과 본문 전체를 채운다.');
    kind = 'concept_criterion_change';
    payload = { draft_id: draft.draftId, criterion_id: criterionId, title, body, reason };
    summary = title;
    note = CRITERION_NOTE;
  } else if (name === DRAFT_RERUN_TOOL_NAME) {
    const ids = strList(args.criterion_ids, 10, 64);
    if (ids === null) return bad(name, 'concept_criteria_not_found', '기준 id 오류', '기준 id 목록을 준다(없으면 빈 목록).');
    kind = 'concept_draft_rerun';
    payload = { draft_id: draft.draftId, criterion_ids: [...new Set(ids)], reason };
    summary = `기준 ${ids.length}개`;
    note = RERUN_NOTE;
  } else {
    return bad(name, 'unknown_tool', '알 수 없는 도구', UNAVAILABLE);
  }

  let row: ActionRow;
  try {
    row = await src.proposeConceptDraftAction(ctx.conversationId, kind, payload);
  } catch (e) {
    return draftError(name, e);
  }
  draft.proposed.add(name);
  return out(name, { ok: true, action_id: row.id, status: 'proposed', note }, summary, row);
}
