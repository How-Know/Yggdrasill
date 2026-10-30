// 과정 탐색도·개념 배치·개념 라이브러리를 읽고, 바꿀 일은 카드로 제안하는 도구.
// 제안 RPC(course_think_action_propose)가 검사(탐색도는 실제로 저장해 본 뒤 되돌림)하고 카드 1행만 남긴다.
// 반영은 사용자가 카드에서 승인할 때 course_think_action_apply가 한다.
// 설계: docs/architecture/course-map.md §Think

import type { AiFunctionTool } from '../_shared/ai/types.ts';
import type { ActionKind, ActionRow, ActionToolContext } from './actions.ts';
import type { ToolRunResult } from './tools.ts';
import { CONCEPT_REVIEW_REF_LIMIT } from './concept_review_job_tools.ts';

export const COURSE_MAPS_TOOL_NAME = 'get_course_maps';
export const CANDIDATES_TOOL_NAME = 'list_placement_candidates';
export const CONCEPT_EDIT_READ_TOOL_NAME = 'get_concept_for_edit';
export const MAP_CHANGE_TOOL_NAME = 'propose_course_map_change';
export const COURSE_CREATE_TOOL_NAME = 'propose_course_create';
export const PLACEMENT_TOOL_NAME = 'propose_concept_placement';
export const CONCEPT_CHANGE_TOOL_NAME = 'propose_concept_change';
export const REVIEW_LIST_TOOL_NAME = 'list_concepts_for_review';
export const REVIEW_STATUS_TOOL_NAME = 'get_concept_review_status';
export const REVIEW_PROPOSE_TOOL_NAME = 'propose_concept_review';
export const RELATION_READ_TOOL_NAME = 'get_concept_relations';
export const RELATION_PROPOSE_TOOL_NAME = 'propose_concept_relation_change';

/** 개념 검토 목록·기록 도구. 기능 concept_review 가 준비된 요청에만 준다(ctx.courseMap.review). */
export const CONCEPT_REVIEW_TOOL_NAMES = new Set([REVIEW_LIST_TOOL_NAME, REVIEW_STATUS_TOOL_NAME, REVIEW_PROPOSE_TOOL_NAME]);
/** 개념 관계 읽기·관계 카드 도구. 기능 concept_relation_change 가 준비된 요청에만 준다(ctx.courseMap.relations). */
export const CONCEPT_RELATION_TOOL_NAMES = new Set([RELATION_READ_TOOL_NAME, RELATION_PROPOSE_TOOL_NAME]);

export const COURSE_MAP_PROPOSE_TOOL_NAMES = new Set([
  MAP_CHANGE_TOOL_NAME,
  COURSE_CREATE_TOOL_NAME,
  PLACEMENT_TOOL_NAME,
  CONCEPT_CHANGE_TOOL_NAME,
  REVIEW_PROPOSE_TOOL_NAME,
  RELATION_PROPOSE_TOOL_NAME,
]);
export const COURSE_MAP_TOOL_NAMES = new Set([
  COURSE_MAPS_TOOL_NAME,
  CANDIDATES_TOOL_NAME,
  CONCEPT_EDIT_READ_TOOL_NAME,
  ...CONCEPT_REVIEW_TOOL_NAMES,
  ...CONCEPT_RELATION_TOOL_NAMES,
  ...COURSE_MAP_PROPOSE_TOOL_NAMES,
]);

export const COURSE_MAP_TOOL_LABELS: Record<string, string> = {
  [COURSE_MAPS_TOOL_NAME]: '과정 탐색도 조회',
  [CANDIDATES_TOOL_NAME]: '배치 후보 조회',
  [CONCEPT_EDIT_READ_TOOL_NAME]: '개념 읽기',
  [MAP_CHANGE_TOOL_NAME]: '과정 탐색도 고치기 제안',
  [COURSE_CREATE_TOOL_NAME]: '새 과정 제안',
  [PLACEMENT_TOOL_NAME]: '개념 배치 제안',
  [CONCEPT_CHANGE_TOOL_NAME]: '개념 고치기 제안',
  [REVIEW_LIST_TOOL_NAME]: '개념 검토 목록 조회',
  [REVIEW_STATUS_TOOL_NAME]: '개념 검토 기록 조회',
  [REVIEW_PROPOSE_TOOL_NAME]: '개념 검토 기록 제안',
  [RELATION_READ_TOOL_NAME]: '개념 관계 조회',
  [RELATION_PROPOSE_TOOL_NAME]: '개념 관계 고치기 제안',
};

/** 한 답변에 낼 수 있는 카드 수. 배치는 과정마다 카드가 따로라 넉넉히 둔다. */
const CARD_LIMITS: Record<string, number> = {
  [MAP_CHANGE_TOOL_NAME]: 1,
  [COURSE_CREATE_TOOL_NAME]: 1,
  [PLACEMENT_TOOL_NAME]: 4,
  [CONCEPT_CHANGE_TOOL_NAME]: 1,
  [REVIEW_PROPOSE_TOOL_NAME]: 2,
  [RELATION_PROPOSE_TOOL_NAME]: 2,
};

export interface CourseMapToolContext {
  /** 이번 답변에서 도구별로 낸 카드 수 */
  proposed: Map<string, number>;
  /** 개념 검토 목록·기록(concept_review)이 DB·앱 모두 준비됐는지 */
  review?: boolean;
  /** 개념 관계 읽기·관계 카드(concept_relation_change)가 DB·앱 모두 준비됐는지 */
  relations?: boolean;
}

export type CourseMapReadFn =
  | 'course_maps_list'
  | 'concept_placement_overview'
  | 'course_map_get'
  | 'course_map_placements'
  | 'concept_placement_candidates'
  | 'concept_think_detail'
  | 'concept_review_walk'
  | 'concept_review_source_walk'
  | 'concept_review_status'
  | 'concept_relation_list';

export const REVIEW_SCOPES = ['notation', 'meaning', 'classification', 'unit', 'relations', 'foundation', 'placement'] as const;
export const REVIEW_OUTCOMES = ['no_issue_found', 'issue_found', 'needs_comparison', 'unverified', 'merge_needed'] as const;

/** 관계 유형. 모두 "출발(concept_id) → 기준(related_id)"으로 읽는다. derived_from·depends_on 은 맥락이 있어야 한다. */
export const RELATION_KINDS = ['kind_of', 'part_of', 'derived_from', 'depends_on', 'extends', 'special_case'] as const;
export const RELATION_KIND_LABELS: Record<string, string> = {
  kind_of: '종류·특수화',
  part_of: '구성·부분',
  derived_from: '근거·유도',
  depends_on: '학습 의존',
  extends: '확장',
  special_case: '특수한 경우',
};
const RELATION_ORIGIN_LABELS: Record<string, string> = {
  draft: '교재 초안 확정 때 생김',
  review: '같은 개념 검토 판단 때 생김',
  manual: '운영자가 직접 넣음',
  think: 'Think 카드 승인으로 생김',
};
const RELATION_DECISION_LABELS: Record<string, string> = {
  draft: '교재 초안 확정에서 운영자가 고름',
  review: '같은 개념 검토에서 운영자가 판단',
  manual: '운영자가 직접 저장',
  think: 'Think 카드를 운영자가 승인',
};

/** 관계 한 줄의 뜻. 맥락이 있으면 그 맥락 안에서만 성립한다고 적는다. */
export function relationMeaning(kind: string, from: string, to: string, context: string | null): string {
  const a = `'${from}'`;
  const b = `'${to}'`;
  const within = context ? ` (맥락: ${context})` : '';
  switch (kind) {
    case 'kind_of':
      return `${a}은(는) ${b}의 한 종류다${within}`;
    case 'part_of':
      return `${a}은(는) ${b}을(를) 이루는 요소다${within}`;
    case 'derived_from':
      return `${a}은(는) ${b}을(를) 근거로 유도·증명된다${context ? within : ' (맥락 없음: 어떤 유도인지 모른다)'}`;
    case 'depends_on':
      return context
        ? `${a}을(를) "${context}"(으)로 배우거나 쓰려면 ${b}이(가) 필요하다. 이 맥락 밖의 선수 관계가 아니다`
        : `${a}을(를) 어떤 목표·방법으로 배울 때 ${b}이(가) 필요한지 기록이 없다`;
    case 'extends':
      return `${a}은(는) ${b}의 정의·범위를 넓힌 개념이다${within}`;
    case 'special_case':
      return `${a}은(는) ${b}의 특수한 경우다${within}`;
    default:
      return `${a} → ${b} (${kind})`;
  }
}

export interface ConceptTypeRow {
  name: string;
  description: string;
}

export interface CourseMapToolSource {
  courseMapRead?(fn: CourseMapReadFn, args: Record<string, unknown>): Promise<unknown>;
  listConceptTypes?(): Promise<ConceptTypeRow[]>;
  proposeCourseThinkAction?(conversationId: string, kind: ActionKind, payload: Record<string, unknown>): Promise<ActionRow>;
}

const CURRICULUM_CODES = ['legacy_1to6', 'k7_1997', 'k7_2007', 'rev_2009', 'rev_2015', 'rev_2022'];

const nullableString = (description: string) => ({ type: ['string', 'null'], description });
const nullableStrings = (description: string) => ({ type: ['array', 'null'], items: { type: 'string' }, description });
const nullableEnum = (values: string[], description: string) => ({ type: ['string', 'null'], enum: [...values, null], description });

export const COURSE_MAP_TOOLS: AiFunctionTool[] = [
  {
    name: COURSE_MAPS_TOOL_NAME,
    description:
      '과정 탐색도를 읽는다. course_id가 null이면 과정 목록(단원 수, 놓인 개념 수)과 전체 개념 중 놓인 수를 준다. ' +
      'course_id를 주면 그 과정의 단원(번호·깊이·이름·놓인 개념 수)을 위에서 아래 순서로 준다. ' +
      'with_concepts가 true면 단원마다 놓인 개념(placement_id, concept_id, 이름, 유형, 놓은 쪽)도 준다. 많으면 unit_id로 대단원 하나만 읽는다.',
    parameters: {
      type: 'object',
      properties: {
        course_id: nullableString('과정 id. 목록이면 null'),
        unit_id: nullableString('이 단원과 그 아래 단원만 읽을 때 단원 id. 전체면 null'),
        with_concepts: { type: 'boolean', description: '단원마다 놓인 개념까지 읽을지' },
      },
      required: ['course_id', 'unit_id', 'with_concepts'],
      additionalProperties: false,
    },
  },
  {
    name: CANDIDATES_TOOL_NAME,
    description:
      '한 과정에 놓을 개념 후보를 30개씩 읽는다. 후보마다 유형·폴더·본문 앞부분·출처(책, 학년, 그 학년이 읽히는 과정 키, 책 단원, 쪽)·지금 놓인 자리가 있다. ' +
      'mode: course_sources(출처 학년이 이 과정으로 읽히는데 이 과정에 아직 안 놓인 개념), unplaced(어디에도 안 놓인 개념), ' +
      'no_source(출처가 없고 어디에도 안 놓인 개념), search(이름 검색, query 필수).',
    parameters: {
      type: 'object',
      properties: {
        course_id: { type: 'string', description: '과정 id' },
        mode: { type: 'string', enum: ['course_sources', 'unplaced', 'no_source', 'search'] },
        query: nullableString('search: 이름에 들어간 말. 다른 mode에서 주면 그 안에서 거른다'),
        offset: { type: ['integer', 'null'], description: '건너뛸 개수. 처음이면 null' },
      },
      required: ['course_id', 'mode', 'query', 'offset'],
      additionalProperties: false,
    },
  },
  {
    name: CONCEPT_EDIT_READ_TOOL_NAME,
    description:
      '개념 하나를 읽는다(part가 null이면 개요): 이름·유형·폴더·본문·서술(id, 역할, 판, 초안 유무, 내용)·출처·교육과정 등장 위치·놓인 자리·' +
      '관계(나가는 쪽 out, 들어오는 쪽 in)·같은 개념 검토·붙은 것 개수, 지울 수 있는지(deletable)와 막는 것(delete_blocked_by), ' +
      '판(revision)·범위별 검토 상태(review), 쓸 수 있는 유형 이름 목록. ' +
      '길어서 다 싣지 못한 글·출처는 truncated에 어디서 끊겼고 어떻게 이어 읽는지 적는다. ' +
      'part로 그 부분만 이어 읽는다: content(본문), statement(서술 statement_id의 칸 field), sources(출처 30개씩). offset은 이어 읽을 자리. ' +
      'truncated가 남아 있으면 그 개념을 다 읽은 것이 아니다. 개념 고치기·지우기·검토 기록을 제안하기 전에 반드시 읽는다.',
    parameters: {
      type: 'object',
      properties: {
        concept_id: { type: 'string', description: '개념 id' },
        part: nullableEnum(['content', 'statement', 'sources'], '한 부분만 이어 읽을 때. 개요면 null'),
        statement_id: nullableString('part statement: 서술 id'),
        field: nullableString('part statement: 칸 이름(예: body, conditions)'),
        offset: { type: ['integer', 'null'], description: '이어 읽을 자리(글은 글자 수, 출처는 개수). 처음이면 null' },
      },
      required: ['concept_id', 'part', 'statement_id', 'field', 'offset'],
      additionalProperties: false,
    },
  },
  {
    name: REVIEW_LIST_TOOL_NAME,
    description:
      '개념 라이브러리를 정해진 순서로 끝까지 훑는 목록을 읽는다. 본문 전체는 싣지 않는다. ' +
      '새로 시작할 때는 walk_id를 null로 둔다. source_course_id와 source_scope가 둘 다 null이면 폴더·유형·이름·배치·검토 조건으로 고정한다. ' +
      '둘 다 주면 그 과정 출처로 고정한다. source_scope all은 그 과정 출처가 있는 개념 전체(이미 배치된 개념 포함)이고, ' +
      'course_unplaced는 그 과정에는 아직 안 놓인 개념만이다(다른 과정에만 놓인 개념은 포함한다). 전체 미배치로 대신하지 않는다. ' +
      '출처 조건은 folder·type·name·placed·review·review_scope와 섞지 않는다. 둘 중 하나만 주면 목록을 만들지 않는다. ' +
      '이어 읽을 때는 같은 walk_id와 next_offset만 준다(출처·폴더 등 다른 조건은 무시한다). ' +
      '고정한 뒤에는 출처·이름·배치가 바뀌거나 개념이 새로 생겨도 id와 순서를 다시 계산하지 않는다. ' +
      '시작 뒤 생긴 개념은 목록에 없고 created_after 개수로만 알린다. 이 수는 출처 조건의 신규 후보 수가 아니라 그 시각 이후 생긴 개념 전체 수다. ' +
      '그사이 지워진 개념은 missing으로 보인다. ' +
      '줄마다 id·이름·유형·폴더·본문 앞 120자(excerpt)와 글자 수(chars)·서술·출처·관계·배치 수·같은 이름 개념 수(same_name)·' +
      '열린 같은 개념 검토 수·판(revision)·범위별 검토 상태(review: 기록 있는 범위만, stale이면 내용이 바뀌어 다시 검토 필요)가 있다. ' +
      '배치 후보 목록과 달리 all 목록에는 배치된 개념과 안 된 개념이 모두 든다. 결과 filter에 과정과 source_scope가 남는다.',
    parameters: {
      type: 'object',
      properties: {
        walk_id: nullableString('이어 읽을 목록 id. 새로 시작하면 null'),
        folder_id: nullableString('이 폴더와 그 아래 폴더만(list_concept_categories의 id). 전체면 null'),
        type: nullableString("이 유형 이름만. 유형 없는 개념만이면 '유형 없음'. 전체면 null"),
        name: nullableString('이름에 이 말이 든 개념만(80자 이내). 전체면 null'),
        placed: nullableEnum(['placed', 'unplaced'], '기준 단원 배치 여부. 전체면 null'),
        review: nullableEnum(
          ['unreviewed', 'stale', 'not_current', 'has_issue', 'merge_needed'],
          'unreviewed(기록 없음)·stale(내용이 바뀌어 다시 검토 필요)·not_current(둘 중 하나)·has_issue(문제 있음·비교 필요·확인 못 함·병합 필요)·merge_needed. 전체면 null',
        ),
        review_scope: nullableEnum([...REVIEW_SCOPES], 'review 조건을 볼 범위(foundation: 초등 기초 개념, placement: 교육과정 배치). null이면 일곱 범위 중 하나라도'),
        source_course_id: nullableString('출처로 고정할 과정 id(get_course_maps). 기존 조건 목록이면 null'),
        source_scope: nullableEnum(
          ['all', 'course_unplaced'],
          'all: 그 과정 출처가 있는 개념 전체. course_unplaced: 그 과정에는 아직 안 놓인 개념(다른 과정에만 놓인 개념 포함). 기존 조건 목록이면 null',
        ),
        offset: { type: ['integer', 'null'], description: '이어 읽을 자리(next_offset). 처음이면 null' },
      },
      required: ['walk_id', 'folder_id', 'type', 'name', 'placed', 'review', 'review_scope', 'source_course_id', 'source_scope', 'offset'],
      additionalProperties: false,
    },
  },
  {
    name: REVIEW_STATUS_TOOL_NAME,
    description:
      '개념 1~20개의 범위별 검토 기록을 읽는다. 범위마다 가장 최근 기록 전체(확인한 것 checked·찾은 것 findings·근거 basis·확인 못 한 것·더 할 일·' +
      '판단에 쓴 개념과 그 뒤 바뀌었는지·더 비교할 개념·검토한 판·지금 내용과 달라졌는지 stale)와 앞선 기록 요약(earlier), ' +
      '승인을 기다리는 검토 카드(pending). 기록이 없는 범위는 null이다. 검토 카드를 내기 전에 같은 범위의 앞선 기록을 본다.',
    parameters: {
      type: 'object',
      properties: { concept_ids: { type: 'array', items: { type: 'string' }, description: '개념 id 1~20개' } },
      required: ['concept_ids'],
      additionalProperties: false,
    },
  },
  {
    name: REVIEW_PROPOSE_TOOL_NAME,
    description:
      '개념을 검토한 결과를 범위별 기록으로 남기자고 카드로 제안한다(항목 20개까지). 사용자가 승인한 항목만 남는다. ' +
      '개념 본문·폴더·유형·관계는 바뀌지 않는다. 항목 하나는 개념 하나의 범위 하나다. ' +
      'scope: notation(오타·표기)·meaning(수학적 의미·조건·범위)·classification(유형·폴더)·unit(중복·개념 단위)·relations(개념 관계). ' +
      'outcome: no_issue_found(이번에 확인한 범위에서 문제를 찾지 못함. 검증 완료가 아니다)·issue_found(문제 있음)·' +
      'needs_comparison(다른 개념·출처와 더 비교해야 판단)·unverified(확인하지 못함)·merge_needed(unit만. 다른 개념과 합쳐야 함, 지우기 보류). ' +
      'revision은 그 개념을 읽은 도구 결과의 revision을 그대로 쓴다. 그 범위 내용이 그 뒤 바뀌었으면 제안이 막히고, 승인 전에 바뀌면 그 항목은 남지 않는다.',
    parameters: {
      type: 'object',
      properties: {
        items: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              concept_id: { type: 'string', description: '개념 id' },
              revision: { type: 'string', description: '읽은 판(revision) 그대로' },
              scope: { type: 'string', enum: [...REVIEW_SCOPES] },
              outcome: { type: 'string', enum: [...REVIEW_OUTCOMES] },
              checked: { type: 'string', description: '이번에 무엇을 확인했는지(읽은 칸·범위, 1000자 이내)' },
              findings: { type: 'string', description: '찾은 문제. 없으면 무엇을 찾지 못했는지(2000자 이내)' },
              basis: { type: 'string', description: '판단 근거: 읽은 글·비교한 개념·출처(1000자 이내)' },
              unverified: nullableString('확인하지 못한 것(1000자 이내). 없으면 null'),
              follow_up: nullableString('더 할 일(1000자 이내). 없으면 null'),
              compared_ids: nullableStrings(`판단에 쓴 다른 개념 id(고유 ${CONCEPT_REVIEW_REF_LIMIT}개까지, 같은 id는 하나). 21개째는 자르지 않고 거절한다. 승인 전에 그 개념이 바뀌면 이 항목은 남지 않는다`),
              to_compare_ids: nullableStrings(`더 비교해야 할 개념 id(고유 ${CONCEPT_REVIEW_REF_LIMIT}개까지, 같은 id는 하나). 이미 비교한 id를 여기로 옮기지 않는다`),
            },
            required: [
              'concept_id', 'revision', 'scope', 'outcome', 'checked', 'findings', 'basis', 'unverified', 'follow_up', 'compared_ids',
              'to_compare_ids',
            ],
            additionalProperties: false,
          },
        },
        reason: { type: 'string', description: '이 검토를 왜 남기는지(사용자 요청·검토 범위) 한두 문장' },
      },
      required: ['items', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: RELATION_READ_TOOL_NAME,
    description:
      '개념 하나의 관계를 모두 읽는다(40개씩). 줄마다 relation_id·rev, 출발(from)·기준(to) 개념의 id·이름·글 판(text_revision), ' +
      '유형과 뜻(meaning: "출발 → 기준"으로 읽은 문장), 맥락(context)·근거(basis)·메모, 어디서 생겼는지(origin), ' +
      '누가 어떻게 결정했는지(decision, 기록이 없으면 "결정 기록 없음"), 판단 뒤 두 개념의 글이 바뀌었는지(rereview), 승인을 기다리는 카드 항목이 있다. ' +
      '개념의 관계 범위 검토 기록 상태(relations_review)와 최근 관계 이력(events)도 준다. 관계를 고치자고 하기 전에 반드시 읽는다.',
    parameters: {
      type: 'object',
      properties: {
        concept_id: { type: 'string', description: '개념 id' },
        direction: nullableEnum(['out', 'in'], 'out(이 개념이 출발)·in(이 개념이 기준)만. 둘 다면 null'),
        offset: { type: ['integer', 'null'], description: '이어 읽을 자리(next_offset). 처음이면 null' },
      },
      required: ['concept_id', 'direction', 'offset'],
      additionalProperties: false,
    },
  },
  {
    name: RELATION_PROPOSE_TOOL_NAME,
    description:
      '개념 관계를 넣거나(add)·고치거나(change)·빼자고(remove) 카드로 제안한다(항목 20개까지). 사용자가 고른 항목만 반영되고 거절하면 아무것도 바뀌지 않는다. ' +
      '관계는 "concept_id(출발, 이 개념) → related_id(기준 개념)"로 읽는다. ' +
      'kind: kind_of(출발은 기준의 한 종류)·part_of(출발은 기준을 이루는 요소)·derived_from(출발은 기준을 근거로 유도·증명된다, context 필수)·' +
      'depends_on(출발을 context의 목표·방법으로 배우거나 쓰려면 기준이 필요, context 필수)·extends(출발은 기준의 정의·범위를 넓힌 개념)·' +
      'special_case(출발은 기준의 특수한 경우). ' +
      'op별로 쓰는 칸: add(concept_id, related_id, kind, context, basis, note), change(relation_id, relation_rev, 바꿀 kind·context·basis·note만. null은 그대로, 빈 글은 비움), ' +
      'remove(relation_id, relation_rev). 방향을 바꾸려면 빼고 새로 넣는다. ' +
      '모든 항목에 두 개념의 글 판(concept_revision·related_revision: get_concept_relations의 text_revision이나 get_concept_for_edit의 revision 그대로)과 이유(reason)를 준다. ' +
      '그 뒤 두 개념의 글이나 그 관계가 바뀌면 제안이 막히고, 승인 전에 바뀌면 그 항목은 반영되지 않는다. 빼기는 관계만 빼고 개념은 지우지 않는다.',
    parameters: {
      type: 'object',
      properties: {
        items: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              op: { type: 'string', enum: ['add', 'change', 'remove'] },
              relation_id: nullableString('change·remove: get_concept_relations의 relation_id'),
              relation_rev: { type: ['integer', 'null'], description: 'change·remove: 그 관계의 rev 그대로' },
              concept_id: nullableString('add: 출발(이 개념) id'),
              related_id: nullableString('add: 기준 개념 id'),
              kind: nullableEnum([...RELATION_KINDS], 'add: 유형. change: 바꿀 때만'),
              context: nullableString('관계가 성립하는 맥락(300자 이내). derived_from: 어떤 유도·증명인지, depends_on: 어떤 목표·방법인지'),
              basis: nullableString('판단 근거: 읽은 본문·서술·출처(1000자 이내)'),
              note: nullableString('메모(500자 이내)'),
              concept_revision: { type: 'string', description: '출발(또는 고치는 관계의 출발) 개념의 글 판 그대로' },
              related_revision: { type: 'string', description: '기준(또는 고치는 관계의 기준) 개념의 글 판 그대로' },
              uncertainty: nullableString('확신하지 못하는 점(500자 이내). 없으면 null'),
              reason: { type: 'string', description: '이 항목을 왜 제안하는지(500자 이내)' },
            },
            required: [
              'op', 'relation_id', 'relation_rev', 'concept_id', 'related_id', 'kind', 'context', 'basis', 'note', 'concept_revision',
              'related_revision', 'uncertainty', 'reason',
            ],
            additionalProperties: false,
          },
        },
        reason: { type: 'string', description: '이 카드 전체의 이유(사용자 요청·정리 범위) 한두 문장' },
      },
      required: ['items', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: MAP_CHANGE_TOOL_NAME,
    description:
      '과정 하나의 단원 틀을 바꾸자고 카드로 제안한다. 사용자가 승인해야 바뀐다. 같은 과정의 기다리는 카드는 새 카드로 대체된다. ' +
      '바꾸기(ops)는 차례로 적용한다(최대 60개). op별로 쓰는 칸: add(key, parent, position, after, name), rename(unit, name), ' +
      'move(unit, parent, position, after), archive(unit), course(name, school_level, curriculum_code 중 바꿀 것). 안 쓰는 칸은 null. ' +
      '과정을 통째로 보관하거나 되살릴 때는 ops를 null로 두고 course_action만 준다.',
    parameters: {
      type: 'object',
      properties: {
        course_id: { type: 'string', description: '과정 id' },
        course_action: nullableEnum(['archive', 'restore'], '과정 보관·되살리기. 단원을 바꿀 때는 null'),
        ops: {
          type: ['array', 'null'],
          description: '차례로 적용할 바꾸기',
          items: {
            type: 'object',
            properties: {
              op: { type: 'string', enum: ['add', 'rename', 'move', 'archive', 'course'] },
              key: nullableString('add: 이 카드 안에서 새 단원을 가리킬 짧은 이름(예: n1)'),
              unit: nullableString('rename·move·archive: 단원 id 또는 같은 카드 앞쪽 add의 key'),
              parent: nullableString(
                "add·move: 위 단원 id 또는 key. 'top'은 맨 위(대단원). add에서 null이면 맨 위, move에서 null이면 지금 위 단원 그대로",
              ),
              position: nullableEnum(['first', 'last', 'after'], 'add·move: 형제 사이 자리. null이면 after가 있을 때 그 뒤, 없으면 맨 끝'),
              after: nullableString('add·move: 바로 앞에 올 형제 단원 id 또는 key'),
              name: nullableString('add·rename: 단원 이름. course: 새 과정 이름(안 바꾸면 null)'),
              school_level: nullableEnum(['초', '중', '고'], 'course: 학교급(안 바꾸면 null)'),
              curriculum_code: nullableEnum([...CURRICULUM_CODES, ''], "course: 교육과정 코드. ''이면 비우고 null이면 그대로"),
            },
            required: ['op', 'key', 'unit', 'parent', 'position', 'after', 'name', 'school_level', 'curriculum_code'],
            additionalProperties: false,
          },
        },
        reason: { type: 'string', description: '왜 바꾸는지(사용자 발언이나 근거) 한두 문장' },
      },
      required: ['course_id', 'course_action', 'ops', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: COURSE_CREATE_TOOL_NAME,
    description:
      '새 과정을 단원과 함께 만들자고 카드로 제안한다. 사용자가 승인해야 생긴다. 단원은 위에서 아래 순서로, 위 단원을 parent_key로 가리킨다(대·중·소 3단계까지, 300개까지).',
    parameters: {
      type: 'object',
      properties: {
        name: { type: 'string', description: '과정 이름(예: 수학Ⅰ)' },
        school_level: { type: 'string', enum: ['초', '중', '고'] },
        curriculum_code: nullableEnum(CURRICULUM_CODES, '교육과정 코드. 모르면 null'),
        units: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              key: { type: 'string', description: '이 카드 안에서 단원을 가리킬 짧은 이름' },
              parent_key: nullableString('위 단원의 key. 대단원이면 null'),
              name: { type: 'string' },
            },
            required: ['key', 'parent_key', 'name'],
            additionalProperties: false,
          },
        },
        reason: { type: 'string', description: '왜 만드는지 한두 문장' },
      },
      required: ['name', 'school_level', 'curriculum_code', 'units', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: PLACEMENT_TOOL_NAME,
    description:
      '한 과정의 단원에 개념을 놓거나(place), 놓인 개념을 옮기거나(move), 빼거나(remove), 단원 안 순서를 바꾸자고(reorder) 카드로 제안한다. ' +
      '한 카드에 한 과정, 항목 50개까지. 사용자가 항목을 빼거나 단원을 바꿔 승인할 수 있다. ' +
      'place는 basis와 evidence가 필수다: 출처 학년·책 단원으로 정하면 source, 출처 없이 개념 내용으로 정하면 judgment. ' +
      'op별로 쓰는 칸: place(concept_id, unit_id, basis, evidence), move(placement_id, unit_id, evidence), remove(placement_id, evidence), ' +
      'reorder(unit_id, placement_ids). 안 쓰는 칸은 null.',
    parameters: {
      type: 'object',
      properties: {
        course_id: { type: 'string', description: '과정 id' },
        items: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              op: { type: 'string', enum: ['place', 'move', 'remove', 'reorder'] },
              concept_id: nullableString('place: 개념 id'),
              placement_id: nullableString('move·remove: get_course_maps의 placement_id'),
              unit_id: nullableString('place·move: 놓을 단원 id. reorder: 순서를 바꿀 단원 id'),
              basis: nullableEnum(['source', 'judgment'], 'place: source(출처 근거) 또는 judgment(출처 없이 판단)'),
              evidence: nullableString('place: 근거(필수, 300자 이내). move·remove: 이유(선택)'),
              placement_ids: nullableStrings('reorder: 그 단원에 지금 놓인 placement_id 전체를 원하는 순서로'),
            },
            required: ['op', 'concept_id', 'placement_id', 'unit_id', 'basis', 'evidence', 'placement_ids'],
            additionalProperties: false,
          },
        },
        reason: { type: 'string', description: '이 카드 전체의 이유 한두 문장' },
      },
      required: ['course_id', 'items', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: CONCEPT_CHANGE_TOOL_NAME,
    description:
      '개념 라이브러리를 바꾸자고 카드로 제안한다(최대 20개). 사용자가 승인하면 바로 확정되고 고친 기록에 "Think 카드 승인"과 이유가 남는다. ' +
      'op별로 쓰는 칸: create(name, type, folder, content, place_unit_id, evidence), edit(concept_id, name·content·type·folder 중 바꿀 것), ' +
      'statement(statement_id, statement_fields), delete(concept_id). 안 쓰는 칸은 null. ' +
      'edit의 content는 바꾼 뒤 본문 전체다. statement_fields는 바꿀 칸만 채우고 나머지는 null(그대로), 빈 글은 그 칸을 비운다. ' +
      '지우기는 붙은 것(유형 연결·본문 고친 기록 포함)이 하나도 없는 개념만 된다. get_concept_for_edit의 deletable이 true일 때만 낸다.',
    parameters: {
      type: 'object',
      properties: {
        items: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              op: { type: 'string', enum: ['create', 'edit', 'statement', 'delete'] },
              concept_id: nullableString('edit·delete: 개념 id'),
              statement_id: nullableString('statement: get_concept_for_edit의 서술 id'),
              name: nullableString('create·edit: 개념 이름(120자 이내)'),
              type: nullableString('create·edit: 유형 이름(get_concept_for_edit의 types)'),
              folder: nullableStrings('create·edit: 맨 위 폴더부터 시작하는 폴더 경로(2~7칸). 없는 아래 폴더는 승인 때 만든다'),
              content: nullableString('create·edit: 본문 전체'),
              place_unit_id: nullableString('create: 만들면서 놓을 단원 id(선택)'),
              evidence: nullableString('create: place_unit_id를 줄 때 근거(300자 이내)'),
              statement_fields: {
                type: ['object', 'null'],
                description: 'statement: 바꿀 칸. 기본 서술(core)은 meaning·scope·conditions만 쓴다',
                properties: {
                  title: nullableString('서술 제목'),
                  body: nullableString('서술 본문'),
                  approach: nullableString('접근 방식(60자 이내)'),
                  conditions: nullableString('조건'),
                  terms: nullableStrings('용어(30개까지)'),
                  basis: nullableEnum(['organized'], '원문이던 서술의 글을 바꿀 때 organized'),
                  supplement_note: nullableString('보충 메모'),
                  unverified_note: nullableString('확인 안 된 점 메모'),
                  meaning: nullableString('core: 뜻'),
                  scope: nullableString('core: 범위'),
                },
                required: [
                  'title', 'body', 'approach', 'conditions', 'terms', 'basis', 'supplement_note', 'unverified_note', 'meaning', 'scope',
                ],
                additionalProperties: false,
              },
            },
            required: [
              'op', 'concept_id', 'statement_id', 'name', 'type', 'folder', 'content', 'place_unit_id', 'evidence', 'statement_fields',
            ],
            additionalProperties: false,
          },
        },
        reason: { type: 'string', description: '왜 바꾸는지(사용자 발언이나 근거) 한두 문장' },
      },
      required: ['items', 'reason'],
      additionalProperties: false,
    },
  },
];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const LIST_OUTPUT_CHARS = 24000;
const DETAIL_OUTPUT_CHARS = 30000;
const DETAIL_CONTENT_CHARS = 16000;
const DETAIL_STATEMENT_CHARS = 4000;

type Rec = Record<string, unknown>;

function rec(v: unknown): Rec {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Rec) : {};
}

function list(v: unknown): Rec[] {
  return Array.isArray(v) ? v.filter((x) => x && typeof x === 'object' && !Array.isArray(x)) as Rec[] : [];
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

function out(name: string, value: unknown, summary: string, max: number, action?: ActionRow): ToolRunResult {
  const text = JSON.stringify(value);
  const output = text.length <= max ? text : JSON.stringify({ truncated: true, preview: text.slice(0, max) });
  return { name, ok: true, output, summary, action };
}

function bad(name: string, error: string, summary: string, next: string, extra: Rec = {}): ToolRunResult {
  return { name, ok: false, output: JSON.stringify({ error, ...extra, next }), summary };
}

const path = (v: unknown) => (Array.isArray(v) ? v.filter((x) => typeof x === 'string').join(' › ') : '');

// ---------------------------------------------------------------------------
// 읽기
// ---------------------------------------------------------------------------

async function readCourseMaps(name: string, args: Rec, src: CourseMapToolSource): Promise<ToolRunResult> {
  const read = src.courseMapRead!.bind(src);
  if (args.course_id == null) {
    let courses: unknown;
    let overview: unknown;
    try {
      [courses, overview] = await Promise.all([read('course_maps_list', {}), read('concept_placement_overview', {})]);
    } catch (e) {
      return proposeError(name, e);
    }
    const ov = rec(overview);
    const placed = rec(ov.courses);
    const rows = list(courses).map((c) => ({
      id: c.id,
      name: c.name,
      school_level: c.school_level,
      curriculum_code: c.curriculum_code ?? null,
      course_key: c.course_key ?? null,
      archived: c.archived_at != null,
      version: c.version,
      units: c.counts,
      placed: typeof placed[String(c.id)] === 'number' ? placed[String(c.id)] : 0,
    }));
    return out(
      name,
      { concepts_total: ov.concepts ?? null, concepts_placed: ov.placed ?? null, courses: rows },
      `과정 ${rows.length}개`,
      LIST_OUTPUT_CHARS,
    );
  }
  const courseId = uuid(args.course_id);
  if (!courseId) return bad(name, 'invalid_id', 'id 형식 오류', 'course_id는 get_course_maps 목록의 id를 쓴다.');
  const unitId = args.unit_id == null ? null : uuid(args.unit_id);
  if (args.unit_id != null && !unitId) return bad(name, 'invalid_id', 'id 형식 오류', 'unit_id는 이 과정 단원의 id를 쓴다.');
  const withConcepts = args.with_concepts === true;

  let map: unknown;
  let placements: unknown;
  try {
    [map, placements] = await Promise.all([
      read('course_map_get', { p_course_id: courseId }),
      read('course_map_placements', { p_course_id: courseId }),
    ]);
  } catch (e) {
    return proposeError(name, e);
  }
  const m = rec(map);
  const course = rec(m.course);
  const units = list(m.units);
  const byUnit = new Map<string, Rec[]>();
  const all = list(placements);
  for (const p of all) {
    const k = String(p.unit_id);
    byUnit.set(k, [...(byUnit.get(k) ?? []), p]);
  }

  const counters = [0, 0, 0];
  const numbered = units.map((u) => {
    const depth = Math.max(1, Math.min(3, Number(u.depth) || 1));
    counters[depth - 1] += 1;
    for (let d = depth; d < 3; d++) counters[d] = 0;
    return { u, depth, no: counters.slice(0, depth).join('.') };
  });
  let focus = numbered;
  if (unitId) {
    const at = numbered.findIndex((x) => x.u.id === unitId);
    if (at < 0) {
      return bad(name, 'course_placement_unit_not_found', '없는 단원', '이 과정의 살아 있는 단원 id만 쓴다. unit_id 없이 다시 읽는다.');
    }
    let end = at + 1;
    while (end < numbered.length && numbered[end].depth > numbered[at].depth) end++;
    focus = numbered.slice(at, end);
  }

  const build = (concepts: boolean) => ({
    course: {
      id: course.id,
      name: course.name,
      school_level: course.school_level,
      curriculum_code: course.curriculum_code ?? null,
      course_key: course.course_key ?? null,
      version: course.version,
      archived: course.archived_at != null,
    },
    placed_total: all.length,
    archived_units: list(m.archived).length,
    units: focus.map(({ u, depth, no }) => {
      const ps = byUnit.get(String(u.id)) ?? [];
      const row: Rec = { id: u.id, no, depth, name: u.name, placed: ps.length };
      if (concepts) {
        row.concepts = ps.map((p) => ({
          placement_id: p.id,
          concept_id: p.concept_id,
          name: p.name,
          type: p.type ?? null,
          by: p.origin === 'ai' ? 'think' : 'owner',
          sources: p.sources,
        }));
      }
      return row;
    }),
  });
  let value: Rec = build(withConcepts);
  if (withConcepts && JSON.stringify(value).length > LIST_OUTPUT_CHARS) {
    value = { ...build(false), note: '놓인 개념이 많아 단원별 개수만 보냈다. unit_id로 대단원 하나를 골라 다시 읽는다.' };
  }
  return out(name, value, `${String(course.name ?? '')} 단원 ${focus.length}개`, LIST_OUTPUT_CHARS);
}

async function readCandidates(name: string, args: Rec, src: CourseMapToolSource): Promise<ToolRunResult> {
  const courseId = uuid(args.course_id);
  if (!courseId) return bad(name, 'invalid_id', 'id 형식 오류', 'course_id는 get_course_maps 목록의 id를 쓴다.');
  const mode = typeof args.mode === 'string' ? args.mode : '';
  const query = str(args.query, 80);
  const offset = typeof args.offset === 'number' && Number.isFinite(args.offset) ? Math.max(0, Math.floor(args.offset)) : 0;
  let data: unknown;
  try {
    data = await src.courseMapRead!('concept_placement_candidates', {
      p_course_id: courseId,
      p_mode: mode,
      p_query: query,
      p_offset: offset,
      p_limit: 30,
    });
  } catch (e) {
    return proposeError(name, e);
  }
  const d = rec(data);
  const items = list(d.items).map((c) => ({
    id: c.id,
    name: c.name,
    type: c.type ?? null,
    folder: path(c.folder),
    excerpt: c.excerpt,
    source_count: c.source_count,
    sources: list(c.sources).map((s) => ({
      book: s.book ?? null,
      grade: s.grade ?? null,
      course_key: s.course_key ?? null,
      unit: path(s.unit_path),
      page: s.page ?? null,
    })),
    placed: list(c.placements).map((p) => p.path),
  }));
  const total = typeof d.total === 'number' ? d.total : items.length;
  const next = offset + items.length < total ? offset + items.length : null;
  return out(
    name,
    { course_name: d.course_name, course_key: d.course_key ?? null, mode, query, total, offset, next_offset: next, items },
    `${mode} ${items.length}/${total}`,
    LIST_OUTPUT_CHARS,
  );
}

/** concept_attachments 키 → 이름. 앱 카드(kConceptAttachedLabels)와 같다. */
export const CONCEPT_ATTACHED_LABELS: Record<string, string> = {
  sources: '출처',
  statements: '서술',
  appearances: '등장 위치',
  placements: '기준 단원 자리',
  relations: '관계',
  reviews: '같은 개념 검토',
  quality_reviews: '범위별 검토 기록',
  criteria: '정리 기준 연결',
  anchors: '주제 묶음',
  content_draft: '수정안',
  type_link: '유형 연결',
  content_revisions: '본문 고친 기록',
  draft_refs: '열린 교재 초안 검토의 대상',
  shortcuts: '바로가기',
  operation_prompts: '운영 지시문',
  other: '기타 연결',
};

/** 붙은 것 개수로 지울 수 있는지 정한다. 개수를 못 읽었으면 null(지울 수 있다고 보지 않는다). */
export function deleteCheckOf(attached: unknown): { deletable: boolean | null; delete_blocked_by: string[] } {
  const a = rec(attached);
  if (typeof a.total !== 'number') return { deletable: null, delete_blocked_by: [] };
  const blocked = Object.entries(a)
    .filter(([k, n]) => k !== 'total' && typeof n === 'number' && n > 0)
    .map(([k, n]) => `${CONCEPT_ATTACHED_LABELS[k] ?? k} ${n}`);
  return { deletable: a.total === 0, delete_blocked_by: blocked };
}

function count(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null;
}

function offsetOf(v: unknown): number {
  return typeof v === 'number' && Number.isFinite(v) ? Math.max(0, Math.floor(v)) : 0;
}

/** 범위별 검토 상태(DB) → 기록 있는 범위는 결과(내용이 바뀌었으면 ", stale"), 없는 범위는 unreviewed. 못 읽었으면 null. */
export function reviewSummaryOf(v: unknown): { review: Rec; unreviewed: string[] } | null {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  const r = v as Rec;
  const review: Rec = {};
  const unreviewed: string[] = [];
  for (const s of REVIEW_SCOPES) {
    const x = rec(r[s]);
    if (typeof x.outcome !== 'string') {
      unreviewed.push(s);
      continue;
    }
    review[s] = x.stale === true ? `${x.outcome}, stale` : x.outcome;
  }
  return { review, unreviewed };
}

const sourceRow = (s: Rec) => ({
  book: s.book ?? null,
  grade: s.grade ?? null,
  course_key: s.course_key ?? null,
  unit: path(s.unit_path),
  page: s.page ?? null,
  statement_id: s.statement_id ?? null,
});

const PART_TEXT_CHARS = 12000;
const SOURCE_PAGE = 30;
/** 개요가 출력 한도를 넘으면 차례로 줄여 싣는다: [본문 글자, 서술 칸 글자, 출처 개수]. */
const DETAIL_TIERS: [number, number, number][] = [
  [DETAIL_CONTENT_CHARS, DETAIL_STATEMENT_CHARS, SOURCE_PAGE],
  [8000, 2000, 15],
  [4000, 1000, 10],
  [2000, 500, 5],
];

function conceptOverview(d: Rec, types: ConceptTypeRow[], [contentMax, fieldMax, sourceMax]: [number, number, number]): Rec {
  const cut: string[] = [];
  const more: Rec[] = [];
  const content = typeof d.content === 'string' ? d.content : '';
  if (content.length > contentMax) {
    cut.push('본문');
    more.push({ what: '본문', shown: contentMax, total: content.length, part: 'content', offset: contentMax });
  }
  const statements = list(d.statements).map((s) => {
    const c = rec(s.content);
    const shown: Rec = {};
    for (const [k, v] of Object.entries(c)) {
      if (typeof v === 'string' && v.length > fieldMax) {
        cut.push(`서술 ${String(s.id)}의 ${k}`);
        more.push({
          what: `서술 ${String(s.id)}의 ${k}`, shown: fieldMax, total: v.length, part: 'statement', statement_id: s.id, field: k,
          offset: fieldMax,
        });
        shown[k] = v.slice(0, fieldMax);
      } else {
        shown[k] = v;
      }
    }
    return { id: s.id, role: s.role, version: s.version, has_draft: s.has_draft === true, content: shown };
  });
  const sources = list(d.sources);
  const sourceTotal = count(d.source_count) ?? sources.length;
  const sourceShown = Math.min(sources.length, sourceMax);
  if (sourceTotal > sourceShown) {
    cut.push('출처');
    more.push(
      sources.length > sourceShown
        ? { what: '출처', shown: sourceShown, total: sourceTotal, part: 'sources', offset: sourceShown }
        : { what: '출처', shown: sourceShown, total: sourceTotal, part: null, note: `나머지 ${sourceTotal - sourceShown}개는 지금 읽을 수 없다` },
    );
  }

  const unavailable: string[] = [];
  const optional = (v: unknown, label: string, map: (r: Rec) => Rec) => {
    if (!Array.isArray(v)) {
      unavailable.push(label);
      return null;
    }
    return list(v).map(map);
  };
  const summary = reviewSummaryOf(d.review);
  if (!summary || typeof d.revision !== 'string') unavailable.push('판·범위별 검토 상태');

  const value: Rec = {
    id: d.id,
    name: d.name,
    type: d.type ?? null,
    folder: d.folder,
    revision: typeof d.revision === 'string' ? d.revision : null,
    review: summary ? d.review : null,
    unreviewed: summary ? summary.unreviewed : null,
    content: content.slice(0, contentMax),
    content_chars: content.length,
    content_draft_pending: d.content_draft_pending === true,
    statements,
    source_count: sourceTotal,
    sources: sources.slice(0, sourceShown).map(sourceRow),
    appearances: optional(d.appearances, '교육과정 등장 위치', (a) => ({
      curriculum_code: a.curriculum_code ?? null,
      school_level: a.school_level ?? null,
      course_label: a.course_label ?? null,
      unit: path(a.unit_path),
      statement_id: a.statement_id ?? null,
      note: a.note ?? null,
    })),
    placed: list(d.placements).map((p) => ({ placement_id: p.id, course_id: p.course_id, unit_id: p.unit_id, path: p.path })),
    relations: optional(d.relations, '관계', (r) => ({
      id: r.id, direction: r.direction, kind: r.kind, other_id: r.other_id, other_name: r.other_name, origin: r.origin,
      context: r.context ?? null, note: r.note ?? null,
    })),
    same_concept_reviews: optional(d.same_concept_reviews, '같은 개념 검토', (r) => ({
      id: r.id, other_id: r.other_id ?? null, other_name: r.other_name ?? null, reason: r.reason, status: r.status,
      resolution: r.resolution ?? null, note: r.note ?? null, resolution_note: r.resolution_note ?? null,
    })),
    same_concept_review_count: count(d.same_concept_review_count),
    attached: d.attached,
    ...deleteCheckOf(d.attached),
    types: types.map((t) => ({ name: t.name, description: t.description })),
  };
  if (value.deletable === null) {
    value.delete_note = '붙은 것을 읽지 못해 지울 수 있는지 모른다. 지우기를 제안하지 않는다.';
  }
  if (unavailable.length > 0) {
    value.unavailable = unavailable;
    value.unavailable_note = '이 칸은 읽지 못했다(서버가 아직 준비되지 않았을 수 있다). 없다고 말하지 않고, 검토 기록을 제안하지 않는다.';
  }
  if (cut.length > 0) {
    value.truncated = cut;
    value.read_more = more;
    value.note =
      '다 싣지 못한 글·출처가 있다. read_more대로 part를 읽기 전에는 그 개념을 다 읽었다고 하지 않는다. ' +
      '잘린 본문은 edit의 content로 고치지 않는다(전체를 줘야 해서 뒷부분이 사라진다).';
  }
  return value;
}

function readConceptPart(name: string, d: Rec, part: string, args: Rec): ToolRunResult {
  const offset = offsetOf(args.offset);
  const base = { id: d.id, name: d.name, revision: typeof d.revision === 'string' ? d.revision : null, part };
  if (part === 'sources') {
    const sources = list(d.sources);
    const total = count(d.source_count) ?? sources.length;
    const page = sources.slice(offset, offset + SOURCE_PAGE).map(sourceRow);
    const to = offset + page.length;
    const value: Rec = { ...base, from: offset, to, total, next_offset: to < sources.length ? to : null, sources: page };
    if (to >= sources.length && sources.length < total) {
      value.note = `출처 ${total}개 중 ${sources.length}개까지만 읽을 수 있다. 나머지 ${total - sources.length}개는 지금 읽을 수 없다.`;
    }
    return out(name, value, `${String(d.name ?? '')} 출처 ${offset + 1}~${to}/${total}`, DETAIL_OUTPUT_CHARS);
  }
  let text: string;
  let extra: Rec = {};
  if (part === 'content') {
    text = typeof d.content === 'string' ? d.content : '';
  } else {
    const statementId = uuid(args.statement_id);
    const s = list(d.statements).find((x) => x.id === statementId);
    if (!s) return bad(name, 'concept_statement_not_found', '없는 서술', 'statement_id는 개요(part null)의 서술 id만 쓴다.');
    const c = rec(s.content);
    const field = str(args.field, 60);
    const v = field ? c[field] : undefined;
    if (!field || v == null) {
      return bad(name, 'unknown_field', '없는 칸', 'field는 그 서술 content에 있는 칸 이름만 쓴다.', { fields: Object.keys(c) });
    }
    text = typeof v === 'string' ? v : JSON.stringify(v);
    extra = { statement_id: s.id, field, statement_version: s.version };
  }
  const to = Math.min(text.length, offset + PART_TEXT_CHARS);
  const from = Math.min(offset, to);
  const value = {
    ...base, ...extra, from, to, total: text.length, next_offset: to < text.length ? to : null,
    complete: from === 0 && to === text.length, text: text.slice(from, to),
  };
  return out(name, value, `${String(d.name ?? '')} ${from}~${to}/${text.length}자`, DETAIL_OUTPUT_CHARS);
}

async function readConceptForEdit(name: string, args: Rec, src: CourseMapToolSource): Promise<ToolRunResult> {
  const conceptId = uuid(args.concept_id);
  if (!conceptId) return bad(name, 'invalid_id', 'id 형식 오류', 'concept_id는 후보·검색 결과의 id를 쓴다.');
  const part = args.part === 'content' || args.part === 'statement' || args.part === 'sources' ? args.part : null;
  let detail: unknown;
  let types: ConceptTypeRow[];
  try {
    [detail, types] = await Promise.all([
      src.courseMapRead!('concept_think_detail', { p_concept_id: conceptId }),
      part === null && src.listConceptTypes ? src.listConceptTypes() : Promise.resolve([]),
    ]);
  } catch (e) {
    return proposeError(name, e);
  }
  const d = rec(detail);
  if (part) return readConceptPart(name, d, part, args);
  let value: Rec = {};
  for (const tier of DETAIL_TIERS) {
    value = conceptOverview(d, types, tier);
    if (JSON.stringify(value).length <= DETAIL_OUTPUT_CHARS) break;
  }
  return out(name, value, String(d.name ?? ''), DETAIL_OUTPUT_CHARS);
}

const REVIEW_LIST_LIMIT = 40;
const SOURCE_SCOPES = new Set(['all', 'course_unplaced']);

function textOrNull(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t ? t : null;
}

/** 출처 목록과 섞으면 안 되는 기존 목록 조건이 하나라도 있는지. */
function reviewListFilterPresent(args: Rec): boolean {
  return textOrNull(args.folder_id) != null
    || textOrNull(args.type) != null
    || textOrNull(args.name) != null
    || textOrNull(args.placed) != null
    || textOrNull(args.review) != null
    || textOrNull(args.review_scope) != null;
}

async function readReviewList(name: string, args: Rec, src: CourseMapToolSource): Promise<ToolRunResult> {
  const walkId = args.walk_id == null ? null : uuid(args.walk_id);
  if (args.walk_id != null && !walkId) return bad(name, 'invalid_id', 'id 형식 오류', 'walk_id는 앞선 결과의 walk_id를 그대로 쓴다.');
  const offset = offsetOf(args.offset);
  const courseText = textOrNull(args.source_course_id);
  const scopeText = textOrNull(args.source_scope);
  let data: unknown;
  try {
    if (walkId) {
      data = await src.courseMapRead!('concept_review_walk', {
        p_walk_id: walkId, p_filter: null, p_offset: offset, p_limit: REVIEW_LIST_LIMIT,
      });
    } else if (courseText || scopeText) {
      if (reviewListFilterPresent(args)) {
        const mixed = ERRORS.concept_review_source_mixed;
        return bad(name, 'concept_review_source_mixed', mixed[0], mixed[1]);
      }
      const courseId = courseText ? uuid(courseText) : null;
      if (courseText && !courseId) {
        return bad(name, 'invalid_id', 'id 형식 오류', 'source_course_id는 get_course_maps의 과정 id를 쓴다.');
      }
      if (!courseId || !scopeText || !SOURCE_SCOPES.has(scopeText)) {
        if (scopeText && !SOURCE_SCOPES.has(scopeText)) {
          const badScope = ERRORS.concept_review_bad_source_scope;
          return bad(name, 'concept_review_bad_source_scope', badScope[0], badScope[1]);
        }
        const incomplete = ERRORS.concept_review_source_incomplete;
        return bad(name, 'concept_review_source_incomplete', incomplete[0], incomplete[1]);
      }
      data = await src.courseMapRead!('concept_review_source_walk', {
        p_source_course_id: courseId, p_source_scope: scopeText, p_offset: offset, p_limit: REVIEW_LIST_LIMIT,
      });
    } else {
      const folderId = args.folder_id == null ? null : uuid(args.folder_id);
      if (args.folder_id != null && !folderId) {
        return bad(name, 'invalid_id', 'id 형식 오류', 'folder_id는 list_concept_categories의 id를 쓴다.');
      }
      data = await src.courseMapRead!('concept_review_walk', {
        p_walk_id: null,
        p_filter: {
          folder_id: folderId,
          type: str(args.type, 40),
          name: str(args.name, 80),
          placed: args.placed ?? null,
          review: args.review ?? null,
          review_scope: args.review_scope ?? null,
        },
        p_offset: offset,
        p_limit: REVIEW_LIST_LIMIT,
      });
    }
  } catch (e) {
    return proposeError(name, e);
  }
  const d = rec(data);
  const total = count(d.total);
  if (total === null || typeof d.walk_id !== 'string') throw new Error('concept_review_walk: unexpected result');
  const rows = (Array.isArray(d.items) ? d.items : []).map((raw) => {
    const c = rec(raw);
    if (c.missing === true) return { id: c.id, missing: true };
    return {
      id: c.id,
      name: c.name,
      type: c.type ?? null,
      folder: path(c.folder),
      excerpt: c.excerpt,
      chars: c.content_chars,
      statements: c.statements,
      sources: c.sources,
      relations: c.relations,
      placed: c.placed,
      same_name: c.same_name,
      open_same_concept_reviews: c.open_same_concept_reviews,
      revision: c.revision,
      review: reviewSummaryOf(c.review)?.review ?? null,
    };
  });
  const build = (n: number) => {
    const shown = rows.slice(0, n);
    const to = offset + shown.length;
    const value: Rec = {
      walk_id: d.walk_id,
      started_at: d.started_at,
      filter: d.filter,
      total,
      from: offset,
      to,
      next_offset: to < total ? to : null,
      done: to >= total,
      remaining: Math.max(0, total - to),
      created_after: count(d.created_after),
      items: shown,
    };
    const missing = shown.filter((x) => 'missing' in x).length;
    const notes: string[] = [];
    if (missing > 0) notes.push(`missing ${missing}개는 목록을 만든 뒤 지워진 개념이다.`);
    if ((count(d.created_after) ?? 0) > 0) {
      const filter = rec(d.filter);
      const sourceList = filter.source_course_id != null || filter.source_scope != null;
      notes.push(
        `목록을 시작한 뒤 생긴 개념 ${String(d.created_after)}개는 이 목록에 없다. 다 훑은 뒤 사용자에게 알리고 새 목록으로 따로 본다.` +
          (sourceList ? ' 이 수는 출처 조건에 새로 든 후보 수가 아니라, 목록을 만든 뒤 생긴 개념 전체 수다.' : ''),
      );
    }
    if (total === 0) notes.push('조건에 맞는 개념이 없다(조회는 성공했다).');
    if (notes.length > 0) value.note = notes.join(' ');
    return value;
  };
  let n = rows.length;
  let value = build(n);
  while (n > 1 && JSON.stringify(value).length > LIST_OUTPUT_CHARS) value = build(--n);
  return out(name, value, total === 0 ? '조건에 맞는 개념 없음' : `${offset + 1}~${offset + n}/${total}`, LIST_OUTPUT_CHARS);
}

async function readReviewStatus(name: string, args: Rec, src: CourseMapToolSource): Promise<ToolRunResult> {
  const raw = Array.isArray(args.concept_ids) ? args.concept_ids : [];
  const ids = [...new Set(raw.map(uuid).filter((x): x is string => x !== null))];
  if (ids.length === 0 || ids.length > 20 || ids.length !== raw.length) {
    return bad(name, 'concept_review_bad_ids', 'id 오류', 'concept_ids에는 도구 결과에 나온 개념 id를 1~20개, 겹치지 않게 준다.');
  }
  let data: unknown;
  try {
    data = await src.courseMapRead!('concept_review_status', { p_concept_ids: ids });
  } catch (e) {
    return proposeError(name, e);
  }
  if (!Array.isArray(data)) throw new Error('concept_review_status: unexpected result');
  const full = { concepts: data };
  if (JSON.stringify(full).length <= DETAIL_OUTPUT_CHARS) return out(name, full, `개념 ${data.length}개`, DETAIL_OUTPUT_CHARS);
  const brief = list(data).map((c) => {
    if (c.missing === true) return c;
    const scopes: Rec = {};
    for (const [k, v] of Object.entries(rec(c.scopes))) {
      const latest = rec(rec(v).latest);
      scopes[k] = v == null ? null : {
        outcome: latest.outcome, stale: latest.stale, reviewed_at: latest.reviewed_at, records: rec(v).records,
      };
    }
    return { id: c.id, name: c.name, revision: c.revision, scopes, pending: c.pending };
  });
  return out(
    name,
    { concepts: brief, note: '기록 글이 길어 결과·판만 보냈다. 기록 내용은 concept_ids를 줄여(1~3개) 다시 읽는다.' },
    `개념 ${data.length}개(요약)`,
    DETAIL_OUTPUT_CHARS,
  );
}

const RELATION_PAGE = 40;

function rereviewLabel(r: Rec): string {
  const j = rec(r.judged);
  if (r.rereview == null || j.recorded !== true) return '판단 때 두 개념의 글 판 기록 없음(다시 검토할지 모른다)';
  if (r.rereview !== true) return '판단 뒤 두 개념의 글이 그대로다';
  const which = [j.from_changed === true ? '출발' : null, j.to_changed === true ? '기준' : null].filter(Boolean).join('·');
  return `판단 뒤 ${which} 개념의 글이 바뀌었다. 다시 검토할 관계다`;
}

function relationRow(r: Rec, pending: Rec[]): Rec {
  const from = rec(r.from);
  const to = rec(r.to);
  const kind = String(r.kind ?? '');
  const context = typeof r.context === 'string' ? r.context : null;
  const decision = rec(r.decision);
  const mine = pending.filter((p) => p.relation_id === r.id).map((p) => ({ action_id: p.action_id, item: p.item, op: p.op }));
  return {
    relation_id: r.id,
    rev: r.rev,
    direction: r.direction,
    from: { id: from.id, name: from.name, text_revision: from.text_rev },
    to: { id: to.id, name: to.name, text_revision: to.text_rev },
    kind,
    kind_label: RELATION_KIND_LABELS[kind] ?? kind,
    meaning: relationMeaning(kind, String(from.name ?? ''), String(to.name ?? ''), context),
    context,
    basis: r.basis ?? null,
    note: r.note ?? null,
    origin: RELATION_ORIGIN_LABELS[String(r.origin)] ?? r.origin,
    decision: decision.recorded === true
      ? { label: RELATION_DECISION_LABELS[String(decision.via)] ?? decision.via, at: decision.at ?? null, action_id: decision.action_id ?? null }
      : { label: '결정 기록 없음(이 기능 전에 생긴 관계)' },
    rereview: r.rereview ?? null,
    rereview_label: rereviewLabel(r),
    ...(mine.length > 0 ? { pending: mine } : {}),
  };
}

async function readRelations(name: string, args: Rec, src: CourseMapToolSource): Promise<ToolRunResult> {
  const conceptId = uuid(args.concept_id);
  if (!conceptId) return bad(name, 'invalid_id', 'id 형식 오류', 'concept_id는 도구 결과에 나온 개념 id를 쓴다.');
  const direction = args.direction === 'out' || args.direction === 'in' ? args.direction : null;
  const offset = offsetOf(args.offset);
  let data: unknown;
  try {
    data = await src.courseMapRead!('concept_relation_list', { p_concept: conceptId });
  } catch (e) {
    return proposeError(name, e);
  }
  const d = rec(data);
  if (!Array.isArray(d.relations)) throw new Error('concept_relation_list: unexpected result');
  const pending = list(d.pending);
  const all = list(d.relations).filter((r) => direction === null || r.direction === direction);
  const page = all.slice(offset, offset + RELATION_PAGE);
  const to = offset + page.length;
  const review = rec(d.relations_review);
  const ids = new Set(all.map((r) => r.id));
  const value: Rec = {
    concept: { id: d.id, name: d.name, text_revision: d.text_rev, revision: d.revision },
    direction: direction ?? 'both',
    total: all.length,
    from: offset,
    to,
    next_offset: to < all.length ? to : null,
    relations: page.map((r) => relationRow(r, pending)),
    pending_adds: pending.filter((p) => p.op === 'add' || !ids.has(p.relation_id)).map((p) => ({
      action_id: p.action_id, item: p.item, op: p.op, concept_id: p.concept_id, related_id: p.related_id, kind: p.kind,
    })),
    relations_review: typeof review.outcome === 'string'
      ? { outcome: review.outcome, stale: review.stale === true, reviewed_at: review.reviewed_at ?? null }
      : null,
    events: list(d.events).map((e) => ({
      event: e.event,
      relation_id: e.relation_id,
      from: e.concept_name,
      to: e.related_name,
      before: e.before ?? null,
      after: e.after ?? null,
      via: RELATION_DECISION_LABELS[String(e.via)] ?? e.via,
      reason: e.reason ?? null,
      at: e.at,
    })),
    event_count: count(d.event_count),
  };
  const notes: string[] = [];
  if (all.length === 0) notes.push('관계가 없다(조회는 성공했다).');
  notes.push(
    '"결정 기록 없음"은 승인되지 않았다는 뜻이 아니라 기록이 없다는 뜻이다. 맥락이 있는 관계는 그 맥락 안에서만 성립한다고 말한다.',
  );
  value.note = notes.join(' ');
  if (JSON.stringify(value).length > DETAIL_OUTPUT_CHARS) {
    value.events = [];
    value.note = `${String(value.note)} 이력이 길어 빼고 보냈다.`;
  }
  return out(name, value, `${String(d.name ?? '')} 관계 ${page.length}/${all.length}`, DETAIL_OUTPUT_CHARS);
}

// ---------------------------------------------------------------------------
// 제안
// ---------------------------------------------------------------------------

/** 모델이 준 한 줄에서 그 op가 쓰는 칸만 남긴다(null 칸은 보내지 않는다). */
function pick(raw: unknown, fields: Record<string, string[]>): Rec | null {
  const r = rec(raw);
  const op = typeof r.op === 'string' ? r.op : '';
  const keep = fields[op];
  if (!keep) return null;
  const o: Rec = { op };
  for (const f of keep) if (r[f] != null) o[f] = r[f];
  return o;
}

const MAP_OP_FIELDS: Record<string, string[]> = {
  add: ['key', 'parent', 'position', 'after', 'name'],
  rename: ['unit', 'name'],
  move: ['unit', 'parent', 'position', 'after'],
  archive: ['unit'],
  course: ['name', 'school_level', 'curriculum_code'],
};

const PLACEMENT_FIELDS: Record<string, string[]> = {
  place: ['concept_id', 'unit_id', 'basis', 'evidence'],
  move: ['placement_id', 'unit_id', 'evidence'],
  remove: ['placement_id', 'evidence'],
  reorder: ['unit_id', 'placement_ids'],
};

const LIBRARY_FIELDS: Record<string, string[]> = {
  create: ['name', 'type', 'folder', 'content', 'place_unit_id', 'evidence'],
  edit: ['concept_id', 'name', 'content', 'type', 'folder'],
  statement: ['statement_id', 'statement_fields'],
  delete: ['concept_id'],
};

export function cleanLibraryItem(raw: unknown): Rec | null {
  const o = pick(raw, LIBRARY_FIELDS);
  if (!o || o.op !== 'statement') return o;
  const fields = rec(o.statement_fields);
  const content: Rec = {};
  for (const [k, v] of Object.entries(fields)) if (v != null) content[k] = v;
  delete o.statement_fields;
  o.content = content;
  return o;
}

export function cleanMapOp(raw: unknown): Rec | null {
  return pick(raw, MAP_OP_FIELDS);
}

export function cleanPlacementItem(raw: unknown): Rec | null {
  return pick(raw, PLACEMENT_FIELDS);
}

/** RPC 오류 코드 → 요약과 다음 행동. 모르는 코드는 그대로 올린다(조회 실패로 기록). */
const ERRORS: Record<string, [summary: string, next: string]> = {
  forbidden: ['권한 없음', '운영자만 할 수 있다. 제안하지 않았다. 사용자에게 알린다.'],
  conversation_not_found: ['대화 없음', '대화를 찾지 못했다. 제안하지 않았다.'],
  action_kind_not_appliable: ['알 수 없는 카드', '제안하지 않았다.'],
  course_think_reason_required: ['이유 없음', 'reason을 채워 다시 제안한다.'],
  course_think_too_long: ['카드가 너무 큼', '항목을 줄여 카드를 나눠 제안한다.'],
  course_map_not_found: ['없는 과정', 'get_course_maps 목록의 과정 id를 쓴다.'],
  course_map_archived: ['보관한 과정', '보관한 과정은 바꿀 수 없다. 되살리기(course_action restore)를 먼저 제안하거나 다른 과정을 고른다.'],
  course_map_not_archived: ['보관하지 않은 과정', '이미 살아 있는 과정이다. 제안하지 않는다.'],
  course_map_stale: ['그사이 바뀐 과정', 'get_course_maps로 다시 읽고 제안한다.'],
  course_map_bad_name: ['과정 이름 오류', '과정 이름은 비우지 않고 짧게 쓴다.'],
  course_map_bad_level: ['학교급 오류', '학교급은 초·중·고 중 하나다.'],
  course_map_bad_curriculum: ['교육과정 오류', '교육과정 코드는 정해진 값이나 null만 쓴다.'],
  course_map_too_deep: ['너무 깊음', '단원은 대·중·소 3단계까지다.'],
  course_map_cycle: ['단원 고리', '단원을 자기 아래 단원 밑으로 옮길 수 없다.'],
  course_map_too_many: ['단원이 너무 많음', '한 과정의 단원 수 한도를 넘는다. 줄여서 제안한다.'],
  course_map_bad_units: ['단원 형식 오류', '단원 구조를 다시 확인해 제안한다.'],
  course_map_bad_parent: ['위 단원 오류', '위 단원은 같은 과정의 살아 있는 단원이어야 한다.'],
  course_think_mixed: ['섞인 카드', '과정 보관·되살리기는 단원 바꾸기와 다른 카드로 낸다(ops는 null).'],
  course_think_bad_ops: ['바꾸기 없음', 'ops에 바꾸기를 1개 이상 넣는다. 새 과정은 단원 목록을 배열로 준다.'],
  course_think_too_many: ['너무 많음', '바꾸기는 60개, 새 과정 단원은 300개까지다. 나눠서 제안한다.'],
  course_think_bad_key: ['key 오류', 'add·새 단원의 key는 이 카드 안에서 겹치지 않는 40자 이내의 짧은 이름이다.'],
  course_think_bad_op: [
    '바꾸기 형식 오류',
    'op별로 쓰는 칸을 확인한다. archive는 같은 카드에서 더한 단원에 쓸 수 없고, course는 바꿀 값이 하나는 있어야 한다.',
  ],
  course_think_unit_not_found: [
    '없는 단원',
    "unit·parent·after에는 get_course_maps의 단원 id, 같은 카드 앞쪽 add의 key, 'top'(맨 위)만 쓴다. 같은 카드에서 보관한 단원은 가리킬 수 없다.",
  ],
  course_think_bad_name: ['단원 이름 오류', '단원 이름은 비우지 않고 짧게 쓴다.'],
  course_think_cycle: ['단원 고리', '단원을 자기 아래 단원 밑으로 옮길 수 없다.'],
  course_think_too_deep: ['너무 깊음', '단원은 대·중·소 3단계까지다. 옮기는 단원 아래 단원 깊이도 센다.'],
  course_think_bad_after: ['after 오류', 'after는 같은 위 단원 아래의 다른 단원이어야 한다.'],
  course_think_bad_position: ['position 오류', 'position은 first·last·after 중 하나다.'],
  course_think_course_exists: ['같은 이름 과정', '같은 이름의 과정이 이미 있다. 새로 만들지 말고 그 과정을 고치는 카드를 쓴다.'],
  course_think_course_archived_exists: ['같은 이름 보관 과정', '같은 이름의 보관한 과정이 있다. 되살리기를 제안하거나 다른 이름을 사용자에게 묻는다.'],
  course_placement_no_items: ['항목 없음', '항목을 1~50개 넣는다.'],
  course_placement_too_many: ['항목이 너무 많음', '한 카드에 50개까지다. 카드를 나눈다.'],
  course_placement_bad_op: ['항목 형식 오류', 'op별로 쓰는 칸을 확인한다.'],
  course_placement_concept_not_found: ['없는 개념', 'concept_id는 후보·검색 결과의 id만 쓴다.'],
  course_placement_unit_not_found: ['없는 단원', 'unit_id는 get_course_maps의 살아 있는 단원 id만 쓴다.'],
  course_placement_unit_foreign: ['다른 과정 단원', '이 카드 과정의 단원만 쓴다. 다른 과정은 카드를 따로 낸다.'],
  course_placement_exists: ['이미 놓임', '그 단원에 이미 놓인 개념이다(같은 카드 안 중복 포함). 그 항목을 뺀다.'],
  course_placement_bad_basis: ['근거 종류 오류', 'basis는 source 또는 judgment다.'],
  course_placement_evidence_required: ['근거 없음', '놓는 항목마다 evidence에 어느 출처(책·학년·책 단원)인지, 또는 판단 이유를 쓴다.'],
  course_placement_evidence_too_long: ['근거가 김', 'evidence는 300자 이내로 줄인다.'],
  course_placement_no_source: [
    '출처 근거 없음',
    '이 개념에는 이 과정으로 읽히는 출처가 없다. 개념 내용으로 판단했다면 basis를 judgment로 바꾸고 판단 이유를 쓴다.',
  ],
  course_placement_not_found: ['없는 배치', 'placement_id는 get_course_maps(with_concepts)의 placement_id만 쓴다.'],
  course_placement_same_unit: ['같은 단원', '이미 그 단원에 있다. 그 항목을 뺀다.'],
  course_placement_duplicate: ['중복 항목', '같은 배치나 같은 단원 순서 바꾸기를 한 카드에 두 번 넣지 않는다.'],
  course_placement_stale: ['순서 목록 어긋남', 'reorder의 placement_ids는 그 단원에 지금 놓인 배치 전체다. get_course_maps로 다시 읽는다.'],
  course_placement_reorder_mixed: ['순서와 다른 바꾸기 섞임', '순서를 바꾸는 단원에 놓기·옮기기·빼기를 같은 카드에 섞지 않는다. 카드를 나눈다.'],
  course_placement_bad_mode: ['mode 오류', 'mode는 course_sources·unplaced·no_source·search 중 하나다.'],
  course_placement_bad_query: ['검색어 오류', 'search에는 80자 이내의 query가 필요하다.'],
  concept_think_no_items: ['항목 없음', '항목을 1~20개 넣는다.'],
  concept_think_too_many: ['항목이 너무 많음', '한 카드에 20개까지다. 먼저 사용자와 범위를 정한다.'],
  concept_think_bad_op: ['항목 형식 오류', 'op별로 쓰는 칸을 확인한다.'],
  concept_think_bad_name: ['이름 오류', '개념 이름은 1~120자다.'],
  concept_think_content_required: ['본문 없음', 'content를 채운다.'],
  concept_think_too_long: ['본문이 김', '본문은 40000자 이내다.'],
  concept_think_unknown_type: ['없는 유형', 'type은 get_concept_for_edit의 types 이름만 쓴다.'],
  concept_think_bad_folder: ['폴더 오류', 'folder는 맨 위 폴더부터 2~7칸이다.'],
  concept_think_unknown_root: ['없는 맨 위 폴더', '맨 위 폴더는 이미 있는 것만 쓴다(list_concept_categories로 확인).'],
  concept_think_concept_not_found: ['없는 개념', 'concept_id는 후보·검색 결과의 id만 쓴다.'],
  concept_think_duplicate: ['중복 항목', '같은 개념·서술을 한 카드에 두 번 넣지 않는다.'],
  concept_think_unchanged: ['바뀐 것 없음', '지금과 같다. 그 항목을 뺀다.'],
  concept_think_verbatim: ['원문 표시 불가', '네가 쓴 글을 원문으로 표시하지 않는다. 원문이던 서술의 글을 바꾸면 basis를 organized로 함께 준다.'],
  concept_think_source_field: ['출처 칸', '인용·원문 조건 칸은 사람이 교재를 보고 적는다. 그 칸은 바꾸지 않는다.'],
  concept_content_draft_pending: ['본문 수정안 있음', '사용자가 저장해 둔 본문 수정안이 있어 본문은 고칠 수 없다. 사용자에게 먼저 수정안을 정리해 달라고 한다.'],
  concept_statement_not_found: ['없는 서술', 'statement_id는 get_concept_for_edit의 서술 id만 쓴다.'],
  concept_statement_has_draft: ['서술 초안 있음', '이 서술에 저장된 초안이 있다. 사용자가 먼저 초안을 확정하거나 버려야 한다.'],
  concept_statement_unknown_field: ['서술 칸 오류', '기본 서술(core)은 meaning·scope·conditions만, 다른 서술은 그 밖의 칸만 쓴다.'],
  concept_statement_bad_content: ['서술 형식 오류', 'statement_fields 칸 형식을 확인한다.'],
  concept_statement_too_long: ['서술이 김', '서술 칸 길이를 줄인다.'],
  concept_statement_meaning_required: ['뜻 없음', '기본 서술의 meaning은 비울 수 없다.'],
  course_map_forbidden: ['권한 없음', '운영자만 읽을 수 있다. 결과가 없다는 뜻이 아니다. 사용자에게 알린다.'],
  concept_review_forbidden: ['권한 없음', '운영자만 읽을 수 있다. 결과가 없다는 뜻이 아니다. 사용자에게 알린다.'],
  concept_review_walk_not_found: [
    '없는 목록',
    '목록이 30일이 지나 지워졌거나 walk_id가 틀렸다. 어디까지 봤는지 사용자에게 알리고, walk_id를 null로 새 목록을 시작한다.',
  ],
  concept_review_bad_source_scope: [
    '출처 범위 오류',
    'source_scope는 all 또는 course_unplaced만 쓴다. 출처 목록은 source_course_id와 함께 주고, 실패했다고 폴더 조건 없는 전체 목록으로 바꾸지 않는다.',
  ],
  concept_review_source_incomplete: [
    '출처 조건 불완전',
    'source_course_id와 source_scope를 둘 다 주거나 둘 다 null로 둔다. 하나만 주면 목록을 만들지 않는다.',
  ],
  concept_review_source_mixed: [
    '출처 조건과 다른 조건이 섞임',
    '출처 과정 목록은 folder_id·type·name·placed·review·review_scope와 함께 만들지 않는다. 출처만 주거나, 출처 없이 기존 조건을 쓴다.',
  ],
  concept_review_empty_course_key: [
    '과정 키 없음',
    '이 과정에는 course_key가 없다. get_course_maps에서 course_key가 있는 과정을 고른다. 목록은 만들지 않았다.',
  ],
  concept_review_bad_filter: ['조건 오류', '조건 칸 값을 도구 설명의 값으로 고친다. name은 80자 이내다.'],
  concept_review_folder_not_found: ['없는 폴더', 'folder_id는 list_concept_categories의 id만 쓴다.'],
  concept_review_unknown_type: ['없는 유형', "type은 get_concept_for_edit의 types 이름이나 '유형 없음'만 쓴다."],
  concept_review_bad_ids: ['id 오류', 'concept_ids에는 개념 id를 1~20개 준다.'],
  concept_review_no_items: ['항목 없음', '항목을 1~20개 넣는다.'],
  concept_review_too_many: ['항목이 너무 많음', '한 카드에 20개까지다. 먼저 사용자와 범위를 나눈다.'],
  concept_review_bad_op: ['항목 형식 오류', '항목마다 도구 설명의 칸을 모두 채운다.'],
  concept_review_concept_not_found: ['없는 개념', 'concept_id는 도구 결과에 나온 개념 id만 쓴다. 그사이 지워졌을 수 있다.'],
  concept_review_bad_scope: ['범위 오류', 'scope는 notation·meaning·classification·unit·relations 중 하나다.'],
  concept_review_bad_outcome: ['결과 오류', 'outcome은 no_issue_found·issue_found·needs_comparison·unverified·merge_needed 중 하나다.'],
  concept_review_merge_scope: ['병합 필요는 unit만', 'merge_needed는 scope unit(중복·개념 단위)에서만 쓴다.'],
  concept_review_duplicate: ['중복 항목', '같은 개념의 같은 범위를 한 카드에 두 번 넣지 않는다.'],
  concept_review_revision_required: ['판 없음', 'revision에 그 개념을 읽은 도구 결과의 revision을 그대로 넣는다.'],
  concept_review_stale: [
    '그사이 바뀐 개념',
    '읽은 뒤 그 범위 내용이 바뀌었다(또는 revision을 잘못 옮겼다). get_concept_for_edit로 다시 읽고 다시 검토한 뒤 제안한다.',
  ],
  concept_review_text_required: ['빈 칸', 'checked·findings·basis는 비우지 않는다. 문제를 못 찾았으면 무엇을 찾지 못했는지 쓴다.'],
  concept_review_too_long: ['글이 김', 'checked·basis·unverified·follow_up은 1000자, findings는 2000자 이내다.'],
  concept_review_bad_refs: ['비교 개념 형식 오류', 'compared_ids·to_compare_ids는 개념 id 배열이거나 null이다. 문자열이 아닌 값은 빼지 않고 거절한다.'],
  concept_review_too_many_refs: [
    '비교 개념이 많음',
    `compared_ids·to_compare_ids는 각각 고유 ${CONCEPT_REVIEW_REF_LIMIT}개까지다. 같은 id는 하나로 센다. 21개째는 자르지 않고 개수를 줄인다.`,
  ],
  concept_review_ref_not_found: ['없는 비교 개념', '비교 개념은 이 개념이 아닌 실제 개념 id여야 한다. 잘못된 id·자기 참조·없는 개념은 빼지 않고 거절한다.'],
  concept_relation_forbidden: ['권한 없음', '운영자만 읽을 수 있다. 관계가 없다는 뜻이 아니다. 사용자에게 알린다.'],
  concept_relation_not_found: [
    '없는 관계·개념',
    'id는 도구 결과에 나온 것만 쓴다. 그사이 빠지거나 지워졌을 수 있으니 get_concept_relations로 다시 읽는다.',
  ],
  concept_relation_no_items: ['항목 없음', '항목을 1~20개 넣는다.'],
  concept_relation_too_many: ['항목이 너무 많음', '한 카드에 20개까지다. 먼저 사용자와 범위를 나눈다.'],
  concept_relation_bad_op: ['항목 형식 오류', 'op는 add·change·remove 중 하나이고, op별로 쓰는 칸을 확인한다.'],
  concept_relation_bad_kind: ['유형 오류', 'kind는 kind_of·part_of·derived_from·depends_on·extends·special_case 중 하나다.'],
  concept_relation_bad_request: ['같은 개념', '출발과 기준이 같은 개념이다. 관계는 서로 다른 두 개념 사이에만 둔다.'],
  concept_relation_text_required: ['이유 없음', '항목마다 reason에 왜 제안하는지 쓴다.'],
  concept_relation_too_long: ['글이 김', 'context는 300자, basis는 1000자, note·reason·uncertainty는 500자 이내다.'],
  concept_relation_context_required: [
    '맥락 없음',
    'derived_from은 어떤 유도·증명인지, depends_on은 어떤 목표·방법으로 배우거나 쓸 때인지 context에 쓴다. 모르면 사용자에게 묻는다.',
  ],
  concept_relation_concept_not_found: ['없는 개념', 'concept_id·related_id는 도구 결과에 나온 개념 id만 쓴다. 그사이 지워졌을 수 있다.'],
  concept_relation_rev_required: ['판 없음', 'change·remove는 relation_rev에 get_concept_relations의 rev를 그대로 넣는다.'],
  concept_relation_stale: ['그사이 바뀐 관계', '읽은 뒤 그 관계가 바뀌었다. get_concept_relations로 다시 읽고 다시 판단한다.'],
  concept_relation_unchanged: ['바뀐 것 없음', '지금과 같다. 그 항목을 뺀다.'],
  concept_relation_revision_required: [
    '글 판 없음',
    'concept_revision·related_revision에 두 개념을 읽은 결과의 text_revision(또는 revision)을 그대로 넣는다.',
  ],
  concept_relation_concept_stale: [
    '그사이 바뀐 개념',
    '읽은 뒤 두 개념 중 하나의 이름·본문·서술이 바뀌었다(또는 판을 잘못 옮겼다). 다시 읽고 판단한 뒤 제안한다.',
  ],
  concept_relation_exists: ['이미 있는 관계', '같은 방향·유형·맥락의 관계가 이미 있다(확장·특수한 경우는 한 방향에 하나). 그 항목을 빼거나 change로 고친다.'],
  concept_relation_reverse_exists: [
    '반대 방향 관계 있음',
    '반대 방향 관계가 이미 있다. 종류·특수화·구성·부분이 서로 반대로 성립해 보이면 같은 개념인지 검토할 일이니 관계 카드로 풀지 말고 사용자에게 알린다. ' +
    '확장·특수한 경우는 한 쌍에 한 방향뿐이다.',
  ],
  concept_relation_duplicate: ['중복 항목', '같은 관계나 같은 넣기를 한 카드에 두 번 넣지 않는다.'],
};

const ITEM_ERROR_PREFIXES = new Set([
  'course_placement_bad_item',
  'concept_think_bad_item',
  'concept_review_bad_item',
  'concept_relation_bad_item',
]);

/** 저장소 오류 문구("함수: 코드[:번호[:코드[:번호]]]")에서 코드와 항목·바꾸기 번호를 읽는다. */
export function parseProposeError(message: string): { code: string; item: number | null; op: number | null } {
  const tail = message.includes(': ') ? message.slice(message.lastIndexOf(': ') + 2) : message;
  const parts = tail.trim().split(':');
  if (
    ITEM_ERROR_PREFIXES.has(parts[0]) &&
    parts.length >= 3
  ) {
    return { code: parts[2], item: Number(parts[1]) || null, op: parts[3] ? Number(parts[3]) || null : null };
  }
  return { code: parts[0], item: null, op: parts[1] ? Number(parts[1]) || null : null };
}

function proposeError(name: string, e: unknown): ToolRunResult {
  const message = e instanceof Error ? e.message : String(e);
  const { code, item, op } = parseProposeError(message);
  const known = ERRORS[code];
  if (!known) throw e;
  const extra: Rec = {};
  if (item != null) extra.item = item;
  if (op != null) extra.op = op;
  const where = item != null ? `${item}번 항목: ` : op != null ? `${op}번 바꾸기: ` : '';
  return bad(name, code, `${where}${known[0]}`, known[1], extra);
}

const NOTES: Record<string, string> = {
  [MAP_CHANGE_TOOL_NAME]:
    '과정 탐색도 카드가 사용자에게 보였다. 아직 바뀌지 않았다. 사용자가 승인해야 반영된다. 같은 과정의 카드를 새로 내면 이 카드는 대체된다. ' +
    '그사이 과정이 바뀌면 승인이 막힌다.',
  [COURSE_CREATE_TOOL_NAME]: '새 과정 카드가 사용자에게 보였다. 사용자가 승인해야 과정과 단원이 생긴다.',
  [PLACEMENT_TOOL_NAME]:
    '개념 배치 카드가 사용자에게 보였다. 아직 놓지 않았다. 사용자가 항목을 빼거나 단원을 바꿔 승인할 수 있고, 항목마다 결과가 따로 남는다.',
  [CONCEPT_CHANGE_TOOL_NAME]:
    '개념 카드가 사용자에게 보였다. 사용자가 승인하면 바로 확정되고 고친 기록에 "Think 카드 승인"과 이유가 남는다. ' +
    '붙은 것이 있는 지우기 항목(blocked)은 승인해도 지워지지 않는다.',
  [REVIEW_PROPOSE_TOOL_NAME]:
    '검토 기록 카드가 사용자에게 보였다. 아직 아무것도 남지 않았다. 사용자가 항목을 빼고 승인할 수 있고, 승인한 항목만 기록으로 남는다. ' +
    '승인 전에 그 범위 내용이나 판단에 쓴 개념이 바뀌면 그 항목은 남지 않는다. 개념 본문·폴더·관계는 바뀌지 않는다. ' +
    '승인 전에는 검토가 기록됐다고 말하지 않는다.',
  [RELATION_PROPOSE_TOOL_NAME]:
    '관계 카드가 사용자에게 보였다. 아직 아무 관계도 바뀌지 않았다. 사용자가 항목을 빼고 승인할 수 있고, 승인한 항목만 반영된다. ' +
    '승인 전에 두 개념의 글이나 그 관계가 바뀌면 그 항목은 반영되지 않는다. 빼기는 관계만 빼고 개념은 지우지 않는다. ' +
    '승인 전에는 관계를 넣었다·고쳤다·뺐다고 말하지 않는다.',
};

const KINDS: Record<string, ActionKind> = {
  [MAP_CHANGE_TOOL_NAME]: 'course_map_change',
  [COURSE_CREATE_TOOL_NAME]: 'course_map_create',
  [PLACEMENT_TOOL_NAME]: 'concept_placement_change',
  [CONCEPT_CHANGE_TOOL_NAME]: 'concept_library_change',
  [REVIEW_PROPOSE_TOOL_NAME]: 'concept_review_record',
  [RELATION_PROPOSE_TOOL_NAME]: 'concept_relation_change',
};

const UNAVAILABLE = '지금은 과정 탐색도·개념 카드를 낼 수 없다(기능이 준비되지 않았다). 제안하지 않는다.';
const REVIEW_UNAVAILABLE =
  '지금은 개념 검토 목록·검토 기록을 쓸 수 없다(서버나 앱이 준비되지 않았다). 검토 기록을 남겼다고 말하지 않는다.';
const RELATION_UNAVAILABLE =
  '지금은 개념 관계 읽기·관계 카드를 쓸 수 없다(서버나 앱이 준비되지 않았다). 관계를 바꿨다고 말하지 않는다.';

const REVIEW_TEXT_FIELDS = ['checked', 'findings', 'basis', 'unverified', 'follow_up'];

export function cleanReviewItem(raw: unknown): Rec | null {
  const r = rec(raw);
  if (typeof r.concept_id !== 'string' || typeof r.scope !== 'string' || typeof r.outcome !== 'string') return null;
  const o: Rec = { concept_id: r.concept_id, revision: typeof r.revision === 'string' ? r.revision : null, scope: r.scope, outcome: r.outcome };
  for (const f of REVIEW_TEXT_FIELDS) o[f] = typeof r[f] === 'string' ? r[f] : null;
  o.compared_ids = Array.isArray(r.compared_ids) ? r.compared_ids : [];
  o.to_compare_ids = Array.isArray(r.to_compare_ids) ? r.to_compare_ids : [];
  return o;
}

const RELATION_COMMON = ['concept_revision', 'related_revision', 'uncertainty', 'reason'];
const RELATION_FIELDS: Record<string, string[]> = {
  add: ['concept_id', 'related_id', 'kind', 'context', 'basis', 'note', ...RELATION_COMMON],
  change: ['relation_id', 'rev', 'kind', 'context', 'basis', 'note', ...RELATION_COMMON],
  remove: ['relation_id', 'rev', ...RELATION_COMMON],
};

/** 관계 카드 한 항목에서 그 op가 쓰는 칸만 남긴다. relation_rev 는 DB 칸 이름 rev 로 보낸다. */
export function cleanRelationItem(raw: unknown): Rec | null {
  const r = rec(raw);
  return pick({ ...r, rev: r.relation_rev ?? null }, RELATION_FIELDS);
}

function buildPayload(name: string, args: Rec, reason: string): { payload: Rec; summary: string } | ToolRunResult {
  if (name === MAP_CHANGE_TOOL_NAME) {
    const courseId = uuid(args.course_id);
    if (!courseId) return bad(name, 'course_map_not_found', '없는 과정', 'get_course_maps 목록의 과정 id를 쓴다.');
    const action = args.course_action === 'archive' || args.course_action === 'restore' ? args.course_action : null;
    const rawOps = Array.isArray(args.ops) ? args.ops : null;
    const ops = rawOps ? rawOps.map(cleanMapOp) : null;
    const badAt = ops ? ops.findIndex((o) => o === null) : -1;
    if (badAt >= 0) {
      return bad(name, 'course_think_bad_op', `${badAt + 1}번 바꾸기: 형식 오류`, ERRORS.course_think_bad_op[1], { op: badAt + 1 });
    }
    return {
      payload: { course_id: courseId, course_action: action, ops: action ? null : ops, reason },
      summary: action === 'archive' ? '과정 보관' : action === 'restore' ? '과정 되살리기' : `바꾸기 ${ops?.length ?? 0}건`,
    };
  }
  if (name === COURSE_CREATE_TOOL_NAME) {
    const units = (Array.isArray(args.units) ? args.units : []).map((u) => {
      const r = rec(u);
      return { key: r.key, parent_key: r.parent_key ?? null, name: r.name };
    });
    return {
      payload: {
        name: args.name,
        school_level: args.school_level,
        curriculum_code: args.curriculum_code ?? null,
        units,
        reason,
      },
      summary: `${String(args.name ?? '')} 단원 ${units.length}개`,
    };
  }
  if (name === PLACEMENT_TOOL_NAME) {
    const courseId = uuid(args.course_id);
    if (!courseId) return bad(name, 'course_map_not_found', '없는 과정', 'get_course_maps 목록의 과정 id를 쓴다.');
    const items = (Array.isArray(args.items) ? args.items : []).map(cleanPlacementItem);
    const badAt = items.findIndex((o) => o === null);
    if (badAt >= 0) {
      return bad(name, 'course_placement_bad_op', `${badAt + 1}번 항목: 형식 오류`, ERRORS.course_placement_bad_op[1], { item: badAt + 1 });
    }
    return { payload: { course_id: courseId, items, reason }, summary: `항목 ${items.length}개` };
  }
  if (name === REVIEW_PROPOSE_TOOL_NAME) {
    const items = (Array.isArray(args.items) ? args.items : []).map(cleanReviewItem);
    const badAt = items.findIndex((o) => o === null);
    if (badAt >= 0) {
      return bad(name, 'concept_review_bad_op', `${badAt + 1}번 항목: 형식 오류`, ERRORS.concept_review_bad_op[1], { item: badAt + 1 });
    }
    return { payload: { items, reason }, summary: `검토 ${items.length}개` };
  }
  if (name === RELATION_PROPOSE_TOOL_NAME) {
    const items = (Array.isArray(args.items) ? args.items : []).map(cleanRelationItem);
    const badAt = items.findIndex((o) => o === null);
    if (badAt >= 0) {
      return bad(name, 'concept_relation_bad_op', `${badAt + 1}번 항목: 형식 오류`, ERRORS.concept_relation_bad_op[1], { item: badAt + 1 });
    }
    return { payload: { items, reason }, summary: `관계 ${items.length}개` };
  }
  const items = (Array.isArray(args.items) ? args.items : []).map(cleanLibraryItem);
  const badAt = items.findIndex((o) => o === null);
  if (badAt >= 0) {
    return bad(name, 'concept_think_bad_op', `${badAt + 1}번 항목: 형식 오류`, ERRORS.concept_think_bad_op[1], { item: badAt + 1 });
  }
  return { payload: { items, reason }, summary: `항목 ${items.length}개` };
}

/** 카드 결과에 덧붙일 미리보기 요약(사용자에게 무엇이 보이는지 모델이 알도록). */
function previewFacts(kind: ActionKind, preview: Rec): Rec {
  switch (kind) {
    case 'course_map_change':
      return { lines: list(preview.lines).length, archived_placements: preview.archived_placements ?? 0 };
    case 'course_map_create':
      return { counts: preview.counts ?? null };
    case 'concept_placement_change':
      return { counts: preview.counts ?? null, judgment: preview.judgment ?? 0 };
    case 'concept_library_change':
      return { counts: preview.counts ?? null, blocked: preview.blocked ?? 0 };
    case 'concept_review_record':
      return {
        counts: preview.counts ?? null,
        already_pending: list(preview.items).filter((i) => (count(i.pending_elsewhere) ?? 0) > 0).length,
      };
    case 'concept_relation_change':
      return {
        counts: preview.counts ?? null,
        already_pending: list(preview.items).filter((i) => (count(i.pending_elsewhere) ?? 0) > 0).length,
        open_same_concept_review: list(preview.items).filter((i) => i.open_same_concept_review === true).length,
      };
    default:
      return {};
  }
}

async function propose(name: string, args: Rec, src: CourseMapToolSource, ctx: ActionToolContext): Promise<ToolRunResult> {
  const state = ctx.courseMap!;
  const used = state.proposed.get(name) ?? 0;
  if (used >= (CARD_LIMITS[name] ?? 1)) {
    return bad(name, 'course_think_card_limit', '카드 수 한도', '한 답변에 낼 수 있는 카드 수를 넘었다. 나머지는 다음 답변에서 사용자와 확인한 뒤 낸다.');
  }
  const reason = str(args.reason, 500);
  if (!reason) return bad(name, 'course_think_reason_required', '이유 없음', 'reason을 채워 다시 제안한다.');
  const built = buildPayload(name, args, reason);
  if ('ok' in built) return built;
  const kind = KINDS[name];
  let row: ActionRow;
  try {
    row = await src.proposeCourseThinkAction!(ctx.conversationId, kind, built.payload);
  } catch (e) {
    return proposeError(name, e);
  }
  state.proposed.set(name, used + 1);
  return out(
    name,
    { ok: true, action_id: row.id, status: 'proposed', note: NOTES[name], ...previewFacts(kind, rec(row.preview)) },
    built.summary,
    LIST_OUTPUT_CHARS,
    row,
  );
}

export async function dispatchCourseMapTool(
  name: string,
  args: Record<string, unknown>,
  src: CourseMapToolSource,
  ctx: ActionToolContext | undefined,
): Promise<ToolRunResult> {
  if (!ctx?.courseMap || !src.courseMapRead || !src.proposeCourseThinkAction) {
    return bad(name, 'course_map_unavailable', '지금은 쓸 수 없음', UNAVAILABLE);
  }
  if (CONCEPT_REVIEW_TOOL_NAMES.has(name) && ctx.courseMap.review !== true) {
    return bad(name, 'concept_review_unavailable', '지금은 쓸 수 없음', REVIEW_UNAVAILABLE);
  }
  if (CONCEPT_RELATION_TOOL_NAMES.has(name) && ctx.courseMap.relations !== true) {
    return bad(name, 'concept_relation_unavailable', '지금은 쓸 수 없음', RELATION_UNAVAILABLE);
  }
  switch (name) {
    case COURSE_MAPS_TOOL_NAME:
      return await readCourseMaps(name, args, src);
    case CANDIDATES_TOOL_NAME:
      return await readCandidates(name, args, src);
    case CONCEPT_EDIT_READ_TOOL_NAME:
      return await readConceptForEdit(name, args, src);
    case REVIEW_LIST_TOOL_NAME:
      return await readReviewList(name, args, src);
    case REVIEW_STATUS_TOOL_NAME:
      return await readReviewStatus(name, args, src);
    case RELATION_READ_TOOL_NAME:
      return await readRelations(name, args, src);
    default:
      if (COURSE_MAP_PROPOSE_TOOL_NAMES.has(name)) return await propose(name, args, src, ctx);
      return bad(name, 'unknown_tool', '알 수 없는 도구', UNAVAILABLE);
  }
}
