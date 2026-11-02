import { type AuthContext, errorResponse, jsonResponse, safetyIdentifier } from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { estimateCostUsd, modelFor, reasoningFor, thinkWallClockMs } from '../_shared/ai/config.ts';
import { createAiProvider } from '../_shared/ai/provider.ts';
import { type AiContentPart, addUsage, emptyUsage, finalText } from '../_shared/ai/types.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import { uuidOrNull } from './validate.ts';

type Rec = Record<string, unknown>;

export const TEXTBOOK_REVIEW_PROMPT_VERSION = 'textbook-problem-review-2026-11-02c';

/** 품질 이상의 원인 분류. data=문항 데이터(본문·선지) 오류, engine=조판 엔진 문제, figure=도형 자산 문제 */
export type IssueKind = 'none' | 'data' | 'engine' | 'figure';

export function normalizeIssueKind(v: unknown, hasIssue: boolean): IssueKind {
  if (!hasIssue) return 'none';
  return v === 'engine' || v === 'figure' || v === 'data' ? v : 'data';
}

/** 모델이 낸 선지 수정안을 {label,text}[] 로 정리한다. 형식이 맞지 않으면 null. */
export function normalizeProposedChoices(v: unknown): Array<{ label: string; text: string }> | null {
  if (!Array.isArray(v) || v.length === 0) return null;
  const out: Array<{ label: string; text: string }> = [];
  for (const c of v as unknown[]) {
    if (!c || typeof c !== 'object') return null;
    const r = c as Rec;
    const label = String(r.label ?? '').trim();
    const text = String(r.text ?? '').trim();
    if (!label) return null;
    out.push({ label, text });
  }
  return out;
}

/** 매니저앱이 묶음마다 함께 보내는 이미지. 해설 크롭은 해설 PDF 좌표 영역을 앱에서 잘라 base64로, V2 렌더는 서명 URL로 온다. */
export interface ReviewImageInput {
  solutionImageDataUrl: string | null;
  v2ProblemUrl: string | null;
}

const MAX_SOLUTION_IMAGE_CHARS = 4_000_000; // base64 약 3MB

export function parseReviewImages(raw: unknown): Map<string, ReviewImageInput> {
  const out = new Map<string, ReviewImageInput>();
  if (!raw || typeof raw !== 'object') return out;
  for (const [cropId, v] of Object.entries(raw as Rec)) {
    if (!uuidOrNull(cropId) || !v || typeof v !== 'object') continue;
    const r = v as Rec;
    const b64 = typeof r.solution_image_base64 === 'string' ? r.solution_image_base64.trim() : '';
    const mime = typeof r.solution_image_mime === 'string' && /^image\/(png|jpeg|webp)$/.test(r.solution_image_mime)
      ? r.solution_image_mime
      : 'image/png';
    const url = typeof r.v2_problem_url === 'string' ? r.v2_problem_url.trim() : '';
    out.set(cropId, {
      solutionImageDataUrl: b64 && b64.length <= MAX_SOLUTION_IMAGE_CHARS && /^[A-Za-z0-9+/=]+$/.test(b64)
        ? `data:${mime};base64,${b64}`
        : null,
      v2ProblemUrl: /^https:\/\//.test(url) ? url : null,
    });
  }
  return out;
}

/** 세트 문항은 공통 지시문과 개별 문항을 합쳐 읽는다. */
export function combineStem(commonStem: unknown, stem: unknown): string {
  const c = String(commonStem ?? '').trim();
  const s = String(stem ?? '').trim();
  if (c && !s.includes(c)) return `[공통 지시문] ${c}\n[문항] ${s}`;
  return s;
}

/**
 * 공통 발문(common_stem)이 개별 발문(stem) 앞머리에 그대로 들어 있으면(공백·[문단] 차이는 무시)
 * 공통 부분을 떼어낸 개별 본문을 돌려준다. 중복이 없거나 떼어내면 본문이 비는 경우 null.
 * 학생 화면은 공통 발문 + 개별 발문을 이어 그리므로 이 중복은 지시문이 두 번 보이는 데이터 오류다.
 */
export function stripCommonStem(commonStem: unknown, stem: unknown): string | null {
  const c = String(commonStem ?? '').replace(/\s+/g, '');
  const s = String(stem ?? '');
  if (!c || !s.trim()) return null;
  const para = '[문단]';
  let i = 0;
  let j = 0;
  while (i < s.length && j < c.length) {
    const ch = s[i];
    if (/\s/.test(ch)) {
      i++;
      continue;
    }
    if (s.startsWith(para, i) && !c.startsWith(para, j)) {
      i += para.length;
      continue;
    }
    if (ch !== c[j]) break;
    i++;
    j++;
  }
  let rest: string | null = null;
  if (j >= c.length) {
    rest = s.slice(i);
  } else {
    // 앞머리가 아니면 정확히 같은 문자열이 들어 있는 경우만 제거한다.
    const exact = String(commonStem ?? '').trim();
    const at = exact ? s.indexOf(exact) : -1;
    if (at < 0) return null;
    rest = s.slice(0, at) + s.slice(at + exact.length);
  }
  rest = rest.replace(/^(\s|\[문단\])+/, '').replace(/(\s|\[문단\])+$/, '');
  return rest.trim() ? rest : null;
}

const SOLUTION_TRANSCRIBE_SCHEMA: Rec = {
  type: 'object',
  additionalProperties: false,
  required: ['problems'],
  properties: {
    problems: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['crop_id', 'found', 'solution_transcribed', 'solution_answer', 'confidence', 'note'],
        properties: {
          crop_id: { type: 'string' },
          found: { type: 'boolean' },
          solution_transcribed: { type: 'string' },
          solution_answer: { type: ['string', 'null'] },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
          note: { type: ['string', 'null'] },
        },
      },
    },
  },
};

const BLIND_SOLVE_SCHEMA: Rec = {
  type: 'object',
  additionalProperties: false,
  required: ['problems'],
  properties: {
    problems: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: [
          'crop_id',
          'ai_solution',
          'ai_answer',
          'arithmetic_ops',
          'visual_tags',
          'judged_from_v2_image',
          'stem_ok',
          'choices_ok',
          'figure_ok',
          'latex_v2_ok',
          'fidelity_ok',
          'quality_issue_title',
          'quality_issue_detail',
          'issue_kind',
          'proposed_stem',
          'proposed_choices',
          'fix_reason',
        ],
        properties: {
          crop_id: { type: 'string' },
          ai_solution: { type: 'string' },
          ai_answer: { type: 'string' },
          arithmetic_ops: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['code', 'count'],
              properties: {
                code: { type: 'string' },
                count: { type: 'integer' },
              },
            },
          },
          visual_tags: { type: 'array', items: { type: 'string' } },
          judged_from_v2_image: { type: 'boolean' },
          stem_ok: { type: 'boolean' },
          choices_ok: { type: 'boolean' },
          figure_ok: { type: 'boolean' },
          latex_v2_ok: { type: 'boolean' },
          fidelity_ok: { type: 'boolean' },
          quality_issue_title: { type: ['string', 'null'] },
          quality_issue_detail: { type: ['string', 'null'] },
          issue_kind: { type: 'string', enum: ['none', 'data', 'engine', 'figure'] },
          proposed_stem: { type: ['string', 'null'] },
          proposed_choices: {
            type: ['array', 'null'],
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['label', 'text'],
              properties: { label: { type: 'string' }, text: { type: 'string' } },
            },
          },
          fix_reason: { type: ['string', 'null'] },
        },
      },
    },
  },
};

const COMPARE_ANALYZE_SCHEMA: Rec = {
  type: 'object',
  additionalProperties: false,
  required: ['problems'],
  properties: {
    problems: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: [
          'crop_id',
          'answer_matched',
          'mismatch_reason',
          'proposed_answer',
          'concept_ids',
          'thinking_codes',
          'draft_proposals',
        ],
        properties: {
          crop_id: { type: 'string' },
          answer_matched: { type: 'boolean' },
          mismatch_reason: { type: ['string', 'null'] },
          proposed_answer: { type: ['string', 'null'] },
          concept_ids: { type: 'array', items: { type: 'string' } },
          thinking_codes: { type: 'array', items: { type: 'string' } },
          draft_proposals: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: [
                'code',
                'target',
                'thinking_kind',
                'category',
                'title',
                'criteria',
                'trigger_cond',
                'action_steps',
                'trap_note',
                'example_expr',
                'unit_score',
              ],
              properties: {
                code: { type: 'string' },
                target: { type: 'string', enum: ['thinking', 'arithmetic'] },
                thinking_kind: { type: 'string', enum: ['frame', 'algorithm'] },
                category: { type: 'string' },
                title: { type: 'string' },
                criteria: { type: 'string' },
                trigger_cond: { type: 'string' },
                action_steps: { type: 'string' },
                trap_note: { type: 'string' },
                example_expr: { type: 'string' },
                unit_score: { type: 'number' },
              },
            },
          },
        },
      },
    },
  },
};

const RENDER_CHECK_SCHEMA: Rec = {
  type: 'object',
  additionalProperties: false,
  required: ['problems'],
  properties: {
    problems: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['crop_id', 'problem_ok', 'answer_ok', 'solution_ok', 'issue_title', 'issue_detail', 'issue_kind', 'engine_symptom'],
        properties: {
          crop_id: { type: 'string' },
          problem_ok: { type: 'boolean' },
          answer_ok: { type: 'boolean' },
          solution_ok: { type: 'boolean' },
          issue_title: { type: ['string', 'null'] },
          issue_detail: { type: ['string', 'null'] },
          issue_kind: { type: 'string', enum: ['none', 'data', 'engine', 'figure'] },
          engine_symptom: { type: ['string', 'null'] },
        },
      },
    },
  },
};

const SOLUTION_TRANSCRIBE_INSTRUCTIONS = `당신은 Yggdrasill 수학 문항 검수 엔진의 [1단계: 원본 해설 전사] 담당입니다.
각 문항마다 교재 해설지(또는 본문)에서 그 문항의 풀이가 인쇄된 영역을 잘라낸 이미지가 주어집니다. 이미지에 인쇄된 해설을 그대로 옮겨 적으세요.

[수행 원칙]
1. 전사(solution_transcribed)는 "원본 그대로"가 기준입니다. 풀지 말고, 고치지 말고, 요약하지 마세요. 인쇄된 풀이 단계·문장·수식을 순서대로 한글+LaTeX($...$)로 옮깁니다. 줄바꿈은 \\n으로 구분합니다.
   - 분수는 \\frac{a}{b}, 근호는 \\sqrt{}, 거듭제곱은 ^{}, 원문자 선지는 ①~⑤ 그대로 적습니다.
   - 해설에 "답 ③", "따라서 x=4" 처럼 최종 답이 적혀 있으면 그 답을 solution_answer에 적습니다(객관식은 번호, 주관식은 값/식). 답이 명시되지 않았으면 마지막 결론 값을 적고 note에 "답 표기 없음, 결론 값 사용"이라고 적습니다.
2. 잘린 영역에 해당 문항 번호의 풀이가 보이지 않거나(다른 문항의 풀이만 보임, 번호만 있고 내용이 잘림 등) 읽을 수 없으면 found=false 로 두고 solution_transcribed는 읽은 만큼만, solution_answer는 null, note에 원인을 적습니다.
3. 영역 안에 다른 문항의 풀이 일부가 함께 보이면 그 부분은 제외하고 요청된 문항 번호의 풀이만 전사합니다.
4. confidence: 글자·수식이 선명하고 완결되면 high, 일부 흐리거나 잘려 추정이 섞이면 medium, 대부분 추정이면 low.`;

const BLIND_SOLVE_INSTRUCTIONS = `당신은 Yggdrasill 수학 문항 검수 엔진의 [2단계: 블라인드 독립 풀이 · 연산 측정 · 품질 검수(학생 시점 V2 렌더 기준)] 담당입니다.
각 문항마다 (가) 문항 데이터 텍스트(공통 발문 common_stem, 개별 발문 stem, 선지 choices, 수식 equations, 도형 figure_refs)와
(나) 학생이 실제로 보게 되는 화면인 "V2 렌더링 이미지"(우리 조판 엔진이 PDF로 찍어낸 카드), (다) 교재 원본을 잘라낸 "원본 크롭 이미지"가 주어질 수 있습니다.
기존 정답은 모르는 상태에서 직접 풀고, 품질은 반드시 V2 렌더링 이미지(학생 시점)를 기준으로 판정하세요.

[수행 원칙]
1. 세트형 문항 공통 발문 결합:
   - common_stem이 비어 있지 않으면 반드시 [공통 지시문(common_stem)] + [개별 문항(stem)]을 하나로 합쳐 읽고 푸세요.
   - common_stem이 "다음 수의 약수를 모두 구하여라."이고 stem이 "7"이면 "7의 약수를 모두 구하는 문제"입니다. 발문 누락이나 판단불가로 판정하지 마세요.
   - 발문 안의 예시 설명 상자([박스시작] ... [박스끝])가 있어도 본래 질문에 대한 답을 구하세요.
2. 블라인드 독립 풀이(ai_solution, ai_answer):
   - 처음부터 끝까지 스스로 풀어 LaTeX 수식($...$)을 포함한 단계별 풀이를 ai_solution에 작성하고, 최종 답을 ai_answer에 적으세요(객관식이고 선지가 있으면 선지 번호 ①~⑤, 주관식이면 기약분수/수식).
   - V2 렌더 이미지나 원본 크롭이 있으면 그 이미지도 함께 보고 푸세요(텍스트에 도형 정보가 없어도 이미지에 도형이 있으면 그것을 근거로 풉니다).
   - 텍스트와 이미지를 모두 합쳐도 발문 절단·보기 누락·도형 누락 때문에 전혀 풀 수 없을 때만 ai_answer는 "판단불가"로 적고 quality_issue에 원인을 적으세요.
3. 연산 복잡도 카운트(arithmetic_ops):
   - 당신이 작성한 ai_solution의 각 계산 단계에서 실제로 수행한 세부 연산 코드(제공된 arithmetic_primitives 목록의 code)와 등장 횟수(count >= 1)를 정확히 세어 기록하세요.
4. 품질 검수 — 학생 시점(V2 렌더링 이미지) 기준:
   - judged_from_v2_image: V2 렌더 이미지를 실제로 보고 판정했으면 true, 이미지가 없어서 텍스트만으로 판정했으면 false.
   - stem_ok: 렌더 화면에서 발문이 온전하게 읽히는지(문장 절단, 글자 겹침, 빈칸 표식([공백], box 등)이 그대로 노출됨, 문단이 사라짐 등이 없는지). 독립형 세트에서 stem에 숫자/식만 있는 것은 정상입니다.
   - choices_ok: 객관식 선지 ①~⑤ 또는 <보기> ㄱ,ㄴ,ㄷ 가 화면에 모두 보이고 순서·내용이 맞는지.
   - figure_ok: 도형/그래프/표가 필요한 문항에서 화면에 도형이 있고 잘림·겹침·크기 이상이 없는지. 도형이 필요 없는 문항은 true.
   - latex_v2_ok: 화면에서 수식이 수학 기호로 제대로 조판됐는지(\\frac, \\sqrt, ^, _ 같은 LaTeX 원문이 글자로 노출되거나, $ 기호가 보이거나, ?? 또는 깨진 글자가 보이면 false).
   - fidelity_ok: 원본 크롭 이미지가 주어졌을 때, V2 렌더(또는 텍스트)의 내용이 원본과 같은지(숫자·부호·조건·선지 내용이 바뀌거나 빠지지 않았는지). 원본 크롭이 없으면 true.
   - 이상이 하나라도 있으면 quality_issue_title과 quality_issue_detail에 학생 입장에서 무엇이 어떻게 보이는지(예: "②번 선지가 화면에 없음", "분수가 \\frac{1}{2} 글자로 노출됨")를 한글로 명확히 적고, 이상이 없으면 둘 다 null로 두세요.
4-1. 이상의 원인 분류(issue_kind) — 운영자가 어디를 고칠지 정하는 기준입니다:
   - "data": 문항 데이터 자체가 틀렸다. 발문·선지 글자가 원본과 다르거나 빠짐, 선지 개수 부족, 수식의 LaTeX 문법이 깨져 있음(괄호 짝이 안 맞음, $ 짝이 안 맞음 등), 마크업 오타. → 데이터를 고치면 해결된다.
   - "engine": 데이터 텍스트는 맞는데 우리 조판 엔진이 잘못 그린다. 올바른 LaTeX인데 겹침·잘림·간격 이상·기호 누락, 줄바꿈이 엉킴, 표/상자 마크업이 그려지지 않음. → 엔진(템플릿)을 고쳐야 하며 같은 표기를 쓰는 다른 문항에도 반복된다.
   - "figure": 도형·그래프 자산이 없거나 잘림(텍스트·LaTeX 문제가 아님).
   - 이상이 없으면 "none".
4-2. 데이터 수정 제안(proposed_stem, proposed_choices, fix_reason) — issue_kind 가 "data"일 때만:
   - 화면에 같은 지시문이 두 번 보이면(공통 지시문이 stem_raw 에도 들어 있는 경우) issue_kind 는 "data" 이고, proposed_stem 은 stem_raw 에서 공통 지시문 부분을 뺀 개별 문항 본문만 적으세요.
   - proposed_stem: stem_raw(개별 발문 원문, 공통 지시문 제외)를 최소한으로 고친 전체 본문. 마크업([문단], [박스시작]/[박스끝], [표시작]/[표끝], [[공백:n]], $...$ 수식)은 원문 형식을 그대로 유지하고, 틀린 부분만 바꾸세요. 원본 크롭 이미지가 있으면 그것을 기준으로 맞추세요. 고칠 것이 없으면 null.
   - proposed_choices: 선지를 고쳐야 할 때만 전체 선지 배열 [{label:"①", text:"..."}, ...]을 적고, 아니면 null. label 은 원문 그대로(①~⑤ 또는 ㄱ,ㄴ,ㄷ).
   - fix_reason: 무엇을 왜 고쳤는지 한 줄. 제안이 없으면 null.
   - "engine"·"figure"·"none" 이면 proposed_stem, proposed_choices, fix_reason 모두 null.
5. 시각 요소 태그(visual_tags):
   - 문항에 도형·그래프·표 등 시각 요소가 있거나 언급되면 아래 표준 태그 중 해당하는 것을 모두 넣으세요(없으면 빈 배열 []):
     ["수직선", "좌표평면", "일차함수(직선)", "이차함수(포물선)", "삼차·사차함수", "유리·무리함수", "지수·로그함수", "삼각함수", "각·평행선", "삼각형", "직각삼각형", "이등변·정삼각형", "사각형", "다각형", "원·부채꼴·접선", "합동·닮음", "입체도형·회전체", "전개도·겨냥도", "표(Table)", "조건상자(보기)", "통계그래프(히스토그램·상자그림)", "수형도·경로망"]`;

const COMPARE_ANALYZE_INSTRUCTIONS = `당신은 Yggdrasill 수학 문항 검수 엔진의 [3단계: 정답 대조 · 개념/사고 3축 분석] 담당입니다.
각 문항의 [기존 추출 정답(existing_answer)], [1단계 원본 해설 전사(solution_transcribed)와 해설 정답(solution_answer)], [2단계 AI 독립 풀이(ai_solution, ai_answer)]를 대조하고, 사용된 개념과 사고를 태깅하세요.

[수행 원칙]
1. 정답 대조(answer_matched, mismatch_reason, proposed_answer):
   - 표기만 다른 동일 정답(예: "3" vs "③"에서 3번 선지 값이 같음, "1/2" vs "\\frac{1}{2}" vs "0.5", "x=4" vs "4", 순서만 다른 집합)은 일치입니다.
   - 해설 정답(solution_answer)이 있으면 3자 대조입니다: 기존 정답·해설 정답·AI 정답이 모두 실질적으로 같을 때만 answer_matched = true.
   - 해설 정답이 없으면(null) 2자 대조입니다: 기존 정답과 AI 정답이 같을 때 true.
   - 기존 정답이 비어 있거나 어느 하나라도 다르면 false 로 두고, mismatch_reason에 어느 쪽이 왜 다른지(기존 정답 오타 / 해설 전사 오류 / 문항 전사 오류로 인한 오답 / AI 풀이 재검토 결과 등)를 적고 가장 신뢰할 수 있는 정답을 proposed_answer에 적으세요. 해설 정답과 AI 정답이 같고 기존 정답만 다르면 그 값을 제안합니다.
   - 원본 해설 전사가 있으면 AI 풀이와 풀이 방향이 다른지도 살펴 mismatch_reason에 짧게 덧붙이세요(정답이 같으면 answer_matched는 true 유지).
2. 개념 태그(concept_ids):
   - 제공된 candidate_concepts 목록에서 이 문항을 푸는 데 직접 쓰인 개념 ID(UUID)만 1~4개 고르세요. 목록에 없는 UUID를 지어내지 마세요.
3. 사고 태그(thinking_codes) 및 새 초안 제안(draft_proposals):
   - 제공된 thinking_primitives(범용 사고틀 frame + 실전 알고리즘 algorithm)에서 이 문항 풀이에 쓰인 사고 code를 1~5개 고르세요.
   - 기존 사전에 꼭 필요한 실전 알고리즘이나 세부 연산이 빠져 있다면 draft_proposals에 최대 1~2개만 제안하세요(점수는 연산 0.10~1.50, 범용 사고틀 3.5~7.5, 실전 알고리즘 5.0~9.5). 충분하면 빈 배열 []로 두세요.`;

const RENDER_CHECK_INSTRUCTIONS = `당신은 Yggdrasill 수학 문항 검수 엔진의 [V2 렌더링 학생 시점 검수] 담당입니다.
각 문항마다 우리 조판 엔진(V2, XeLaTeX)이 실제로 찍어낸 카드 이미지가 주어집니다: (1) 문항 카드, (2) 정답+해설 카드(원본 해설 또는 AI 풀이). 학생이 이 화면을 보고 공부한다고 생각하고, 보이는 그대로 판단하세요. 수학적으로 맞는지는 여기서 판단하지 않습니다.

[판정 기준 — 하나라도 해당하면 해당 항목 false]
- 수식이 기호로 조판되지 않고 LaTeX 원문(\\frac, \\sqrt, ^, _, \\, $)이나 ??, 깨진 글자, 빈 네모(□ 외의 깨짐)로 보인다.
- 문장·수식·선지가 카드 가장자리에서 잘렸거나 겹쳐서 읽을 수 없다.
- 객관식 선지(①~⑤)나 <보기>(ㄱ,ㄴ,ㄷ)가 일부 빠져 있다.
- 도형·그래프·표가 있어야 할 자리에 없거나, 잘리거나, 너무 작아 읽을 수 없다.
- 줄바꿈이 엉켜 풀이 단계의 순서를 따라갈 수 없다.
- 정답 카드에 정답이 보이지 않는다(비어 있음), 또는 해설이 중간에서 끊긴다.
- 원문 마크업([문단], [박스시작], [표시작], [[공백:1]] 등)이 그대로 글자로 노출된다.

[출력]
- problem_ok: 문항 카드가 학생이 읽기에 온전한가.
- answer_ok: 정답 표기가 보이고 읽히는가(정답 카드가 없으면 true).
- solution_ok: 해설/풀이 카드가 끝까지 읽히는가(해설 카드가 없으면 true).
- 이상이 있으면 issue_title(한 줄)과 issue_detail(어느 카드의 어디가 어떻게 보이는지)을 한글로 적고, 없으면 둘 다 null.
- issue_kind: 이상의 원인 분류. 운영자가 어디를 고칠지 정하는 기준입니다.
  - "engine": 내용은 맞아 보이는데 조판이 잘못됐다 — 수식·글자 겹침, 가장자리 잘림, 간격 이상, 기호가 빠짐, 줄바꿈이 엉킴, 표/상자가 그려지지 않음, 마크업이 글자로 노출됨. 같은 표기를 쓰는 다른 문항에서도 반복될 문제.
  - "data": 내용 자체의 문제 — 선지가 빠짐, 정답이 비어 있음, 해설이 중간에서 끝남, 글자·수식 오타, LaTeX 원문이 그대로 노출될 만큼 문법이 깨짐.
  - "figure": 도형·그래프가 없거나 잘림.
  - "none": 이상 없음.
- engine_symptom: issue_kind 가 "engine"일 때 증상을 짧은 명사구로(예: "분수 세로 겹침", "루트 기호 누락", "표 테두리 미출력"). 같은 증상끼리 묶어 엔진 수정 목록을 만드는 데 씁니다. 아니면 null.`;

async function loadDictionaries(auth: AuthContext, bookId: string, gradeLabel: string) {
  const [arithRes, thinkRes, sourceConceptsRes] = await Promise.all([
    auth.admin
      .from('arithmetic_primitives')
      .select('code,category,title,unit_score')
      .eq('is_active', true)
      .order('sort_order')
      .limit(200),
    auth.admin
      .from('thinking_primitives')
      .select('id,code,kind,category,title,unit_score')
      .eq('is_active', true)
      .order('sort_order')
      .limit(200),
    auth.admin
      .from('concept_sources')
      .select('concept_id,concepts(id,name)')
      .eq('book_id', bookId)
      .eq('grade_label', gradeLabel)
      .limit(250),
  ]);

  const arithList = (arithRes.data ?? []) as Rec[];
  const thinkList = (thinkRes.data ?? []) as Rec[];
  const conceptMap = new Map<string, { id: string; name: string }>();
  for (const row of (sourceConceptsRes.data ?? []) as Rec[]) {
    const c = row.concepts as Rec | null;
    if (c && typeof c.id === 'string' && typeof c.name === 'string') {
      conceptMap.set(c.id, { id: c.id, name: c.name });
    }
  }
  if (conceptMap.size < 30) {
    const { data: fallbackConcepts } = await auth.admin.from('concepts').select('id,name').limit(80);
    for (const c of (fallbackConcepts ?? []) as Rec[]) {
      if (typeof c.id === 'string' && typeof c.name === 'string' && !conceptMap.has(c.id)) {
        conceptMap.set(c.id, { id: c.id, name: c.name });
      }
    }
  }
  return { arithList, thinkList, conceptMap };
}

/** 원본 교재 크롭(textbook-crops 버킷)의 서명 URL. 실패하면 null — 원본 대조만 건너뛴다. */
async function signCropImage(auth: AuthContext, bucket: unknown, key: unknown): Promise<string | null> {
  const b = String(bucket ?? '').trim();
  const k = String(key ?? '').trim();
  if (!b || !k) return null;
  // Db 타입은 from/rpc 만 노출한다. 실제 supabase-js 클라이언트에는 storage 가 있다(테스트 메모리 구현은 없음).
  const storage = (auth.admin as unknown as { storage?: { from(b: string): { createSignedUrl(k: string, s: number): Promise<{ data: { signedUrl?: string } | null }> } } }).storage;
  if (!storage) return null;
  const { data } = await storage.from(b).createSignedUrl(k, 60 * 20).catch(() => ({ data: null }));
  return data?.signedUrl ?? null;
}

/** 같은 crop_id·check_key 의 열린 항목이 있으면 갱신, 없으면 새로 만든다(부분 유니크 인덱스라 upsert 추론이 안 된다). */
async function upsertOpenFinding(auth: AuthContext, row: Rec): Promise<void> {
  const cropId = String(row.crop_id);
  const checkKey = String(row.check_key ?? '');
  if (checkKey) {
    const { data } = await auth.admin
      .from('textbook_review_findings')
      .select('id')
      .eq('crop_id', cropId)
      .eq('check_key', checkKey)
      .in('status', ['open', 'held'])
      .limit(1);
    const existing = (data ?? [])[0] as Rec | undefined;
    if (existing?.id) {
      await auth.admin.from('textbook_review_findings').update({ ...row, status: row.status ?? 'open' }).eq('id', existing.id);
      return;
    }
  }
  await auth.admin.from('textbook_review_findings').insert(row);
}

async function resolveOpenFinding(auth: AuthContext, cropId: string, checkKey: string): Promise<void> {
  await auth.admin
    .from('textbook_review_findings')
    .update({ status: 'resolved', resolution: 'auto_cleared', resolved_at: new Date().toISOString() })
    .eq('crop_id', cropId)
    .eq('check_key', checkKey)
    .in('status', ['open', 'held']);
}

function parseProblems(text: string): Map<string, Rec> {
  const out = new Map<string, Rec>();
  let parsed: { problems?: Rec[] } = {};
  try {
    parsed = JSON.parse(text || '{"problems":[]}');
  } catch {
    parsed = {};
  }
  for (const p of parsed.problems ?? []) {
    if (p && typeof p.crop_id === 'string') out.set(p.crop_id, p);
  }
  return out;
}

export async function handleTextbookProblemReview(
  req: Request,
  auth: AuthContext,
  body: Rec,
): Promise<Response> {
  const academyId = uuidOrNull(body.academy_id);
  const bookId = uuidOrNull(body.book_id);
  const gradeLabel = typeof body.grade_label === 'string' ? body.grade_label.trim() : '';
  const bigOrder = Number(body.big_order);
  const midOrder = Number(body.mid_order);
  const chunkSize = Math.max(1, Math.min(10, Number(body.chunk_size) || 6));
  const forceRerun = body.force_rerun === true;
  const requestedCropIds = Array.isArray(body.crop_ids)
    ? (body.crop_ids as unknown[]).map((x) => uuidOrNull(x)).filter((x): x is string => !!x)
    : [];
  const images = parseReviewImages(body.images);

  if (!academyId || !bookId || !gradeLabel || !Number.isInteger(bigOrder) || !Number.isInteger(midOrder)) {
    return errorResponse(400, 'invalid_scope', '학원, 교재, 학년, 중단원 정보가 필요합니다.');
  }

  const wallClockMs = thinkWallClockMs();
  const provider = createAiProvider({ timeoutMs: wallClockMs + 5000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') {
    return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');
  }

  // 0단계: 시스템 적재 검사 갱신
  await auth.userClient.rpc('textbook_review_refresh_load_checks', {
    p_academy_id: academyId,
    p_book_id: bookId,
    p_grade_label: gradeLabel,
    p_big_order: bigOrder,
    p_mid_order: midOrder,
  });

  const overviewRes = await auth.userClient.rpc('textbook_review_unit_overview', {
    p_academy_id: academyId,
    p_book_id: bookId,
    p_grade_label: gradeLabel,
    p_big_order: bigOrder,
    p_mid_order: midOrder,
  });
  if (overviewRes.error) {
    return errorResponse(502, 'overview_failed', overviewRes.error.message);
  }
  const allItems = (((overviewRes.data as Rec | null)?.items ?? []) as unknown[]).map((x) => (x ?? {}) as Rec);
  const todoItems = allItems.filter((it) => isReviewTodo(it, forceRerun));

  if (todoItems.length === 0) {
    return jsonResponse({ ok: true, processed: 0, remaining: 0, total: allItems.length, done: true });
  }

  // 매니저앱이 이미지와 함께 지정한 문항이 있으면 그 묶음을 우선한다(이미지는 그 문항들에 대해 준비돼 있다).
  const requested = new Set(requestedCropIds);
  const batchItems = requested.size > 0
    ? todoItems.filter((it) => requested.has(String(it.crop_id))).slice(0, chunkSize)
    : todoItems.slice(0, chunkSize);
  if (batchItems.length === 0) {
    return jsonResponse({ ok: true, processed: 0, remaining: todoItems.length, total: allItems.length, done: false });
  }

  const { arithList, thinkList, conceptMap } = await loadDictionaries(auth, bookId, gradeLabel);
  const arithCodes = new Set(arithList.map((a) => String(a.code)));
  const thinkByCode = new Map<string, string>();
  for (const t of thinkList) thinkByCode.set(String(t.code), String(t.id));
  const candidateConcepts = [...conceptMap.values()].slice(0, 120);

  const startedAt = Date.now();
  const model = modelFor('primary');
  const safetyId = await safetyIdentifier(auth.userId);
  const signal = AbortSignal.any([req.signal, AbortSignal.timeout(wallClockMs)]);
  let usage = emptyUsage();

  // 원본 크롭 서명 URL(원본 대조용)
  const cropUrlByCrop = new Map<string, string>();
  await Promise.all(batchItems.map(async (it) => {
    const url = await signCropImage(auth, it.storage_bucket, it.storage_key);
    if (url) cropUrlByCrop.set(String(it.crop_id), url);
  }));

  // ── 1단계: 원본 해설 전사(Vision). 해설 크롭 이미지가 온 문항만.
  const solutionTargets = batchItems.filter((it) => images.get(String(it.crop_id))?.solutionImageDataUrl);
  const solutionCall = solutionTargets.length === 0 ? Promise.resolve(null) : (() => {
    const parts: AiContentPart[] = [{
      type: 'text',
      text: JSON.stringify({
        problems: solutionTargets.map((it) => ({
          crop_id: it.crop_id,
          problem_number: it.problem_number,
          question_type: it.question_type,
          stem_preview: combineStem(it.common_stem, it.stem).slice(0, 400),
          source_kind: it.solution_source_kind ?? 'sol',
        })),
      }),
    }];
    for (const it of solutionTargets) {
      parts.push({ type: 'text', text: `[crop_id=${it.crop_id} · ${it.problem_number}번 해설 영역 이미지]` });
      parts.push({ type: 'image', url: images.get(String(it.crop_id))!.solutionImageDataUrl!, detail: 'high' });
    }
    return provider.complete(
      {
        model,
        instructions: SOLUTION_TRANSCRIBE_INSTRUCTIONS,
        input: [{ kind: 'message', role: 'user', parts }],
        jsonSchema: { name: 'textbook_solution_transcribe', schema: SOLUTION_TRANSCRIBE_SCHEMA },
        reasoningEffort: 'low',
        maxOutputTokens: 12000,
        safetyId,
      },
      signal,
    );
  })();

  // ── 2단계: 블라인드 독립 풀이 + 연산 카운트 + 학생 시점(V2 렌더) 품질 검사 + 원본 대조
  const blindParts: AiContentPart[] = [{
    type: 'text',
    text: JSON.stringify({
      arithmetic_primitives: arithList.map((a) => ({ code: a.code, cat: a.category, title: a.title })),
      problems: batchItems.map((it) => ({
        crop_id: it.crop_id,
        problem_number: it.problem_number,
        set_type: it.set_type ?? '',
        set_header_number: it.set_header_number ?? '',
        common_stem: String(it.common_stem ?? '').trim(),
        item_name: it.item_name,
        label: it.label,
        question_type: it.question_type,
        stem: combineStem(it.common_stem, it.stem).slice(0, 2800),
        stem_raw: String(it.stem ?? '').slice(0, 2800),
        choices: it.choices,
        objective_choices: it.objective_choices,
        figure_refs: it.figure_refs,
        equations: it.equations,
        has_v2_image: !!images.get(String(it.crop_id))?.v2ProblemUrl,
        has_original_crop: cropUrlByCrop.has(String(it.crop_id)),
      })),
    }),
  }];
  for (const it of batchItems) {
    const cid = String(it.crop_id);
    const v2 = images.get(cid)?.v2ProblemUrl;
    if (v2) {
      blindParts.push({ type: 'text', text: `[crop_id=${cid} · ${it.problem_number}번 V2 렌더링 화면(학생이 보는 화면)]` });
      blindParts.push({ type: 'image', url: v2, detail: 'high' });
    }
    const orig = cropUrlByCrop.get(cid);
    if (orig) {
      blindParts.push({ type: 'text', text: `[crop_id=${cid} · ${it.problem_number}번 교재 원본 크롭]` });
      blindParts.push({ type: 'image', url: orig, detail: 'auto' });
    }
  }
  const blindCall = provider.complete(
    {
      model,
      instructions: BLIND_SOLVE_INSTRUCTIONS,
      input: [{ kind: 'message', role: 'user', parts: blindParts }],
      jsonSchema: { name: 'textbook_problem_blind_solve', schema: BLIND_SOLVE_SCHEMA },
      reasoningEffort: reasoningFor('primary'),
      maxOutputTokens: 14000,
      safetyId,
    },
    signal,
  );

  const [solutionRes, blindRes] = await Promise.all([solutionCall, blindCall]);
  if (solutionRes) usage = addUsage(usage, solutionRes.usage);
  usage = addUsage(usage, blindRes.usage);
  const solutionByCrop = solutionRes ? parseProblems(finalText(solutionRes)) : new Map<string, Rec>();
  const blindByCrop = parseProblems(finalText(blindRes));

  // ── 3단계: 정답 대조(3자/2자) + 개념/사고 태깅 + 초안 제안
  const comparePayload = {
    candidate_concepts: candidateConcepts,
    thinking_primitives: thinkList.map((t) => ({ code: t.code, kind: t.kind, cat: t.category, title: t.title })),
    problems: batchItems.map((it) => {
      const cid = String(it.crop_id);
      const b = blindByCrop.get(cid) ?? {};
      const s = solutionByCrop.get(cid);
      const solutionFound = s?.found === true;
      return {
        crop_id: it.crop_id,
        problem_number: it.problem_number,
        common_stem: String(it.common_stem ?? '').trim(),
        stem: combineStem(it.common_stem, it.stem).slice(0, 2200),
        choices: it.choices,
        existing_answer: it.existing_answer,
        solution_transcribed: solutionFound ? String(s!.solution_transcribed ?? '').slice(0, 3000) : null,
        solution_answer: solutionFound && typeof s!.solution_answer === 'string' ? s!.solution_answer : null,
        ai_solution: b.ai_solution ?? '',
        ai_answer: b.ai_answer ?? '',
      };
    }),
  };

  const compareRes = await provider.complete(
    {
      model,
      instructions: COMPARE_ANALYZE_INSTRUCTIONS,
      input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: JSON.stringify(comparePayload) }] }],
      jsonSchema: { name: 'textbook_problem_compare_analyze', schema: COMPARE_ANALYZE_SCHEMA },
      reasoningEffort: reasoningFor('primary'),
      maxOutputTokens: 12000,
      safetyId,
    },
    signal,
  );
  usage = addUsage(usage, compareRes.usage);
  const compareByCrop = parseProblems(finalText(compareRes));

  const costUsd = estimateCostUsd(model, usage, 0);
  const aiRunId = await recordAiRun(auth.admin, {
    feature: 'textbook_problem_review',
    provider: provider.name,
    model,
    promptVersion: TEXTBOOK_REVIEW_PROMPT_VERSION,
    status: 'ok',
    error: null,
    usage,
    webSearchCalls: 0,
    toolCalls: 0,
    costUsd,
    latencyMs: Date.now() - startedAt,
    conversationId: null,
    createdBy: auth.userId,
    features: {
      book_id: bookId,
      grade_label: gradeLabel,
      big_order: bigOrder,
      mid_order: midOrder,
      count: batchItems.length,
      solution_images: solutionTargets.length,
      v2_images: batchItems.filter((it) => images.get(String(it.crop_id))?.v2ProblemUrl).length,
    },
  });

  const nowIso = new Date().toISOString();
  let processed = 0;
  for (const it of batchItems) {
    const cropId = String(it.crop_id);
    const b = blindByCrop.get(cropId) ?? {};
    const c = compareByCrop.get(cropId) ?? {};
    const s = solutionByCrop.get(cropId);

    const arithCounts: Record<string, number> = {};
    for (const op of (Array.isArray(b.arithmetic_ops) ? b.arithmetic_ops : []) as Rec[]) {
      const code = String(op.code ?? '').trim();
      const cnt = Number(op.count) || 0;
      if (arithCodes.has(code) && cnt > 0) arithCounts[code] = (arithCounts[code] ?? 0) + cnt;
    }

    const validConceptIds = ((Array.isArray(c.concept_ids) ? c.concept_ids : []) as unknown[])
      .map((x) => String(x).trim())
      .filter((id) => conceptMap.has(id));
    const validThinkingIds = ((Array.isArray(c.thinking_codes) ? c.thinking_codes : []) as unknown[])
      .map((code) => thinkByCode.get(String(code).trim()))
      .filter((id): id is string => typeof id === 'string' && id.length > 0);
    const visualTags = ((Array.isArray(b.visual_tags) ? b.visual_tags : []) as unknown[])
      .map((x) => String(x).trim())
      .filter((x) => x.length > 0);

    // 공통 발문이 개별 발문에 그대로 들어 있으면 학생 화면에 지시문이 두 번 보인다. 모델 판정과 무관하게 데이터 오류로 잡는다.
    const dupStripped = stripCommonStem(it.common_stem, it.stem);
    const stemOk = b.stem_ok !== false && dupStripped === null;
    const choicesOk = b.choices_ok !== false;
    const figureOk = b.figure_ok !== false;
    const latexOk = b.latex_v2_ok !== false;
    const fidelityOk = b.fidelity_ok !== false;
    const issueTitle: string | null = typeof b.quality_issue_title === 'string' && b.quality_issue_title.trim()
      ? b.quality_issue_title
      : dupStripped !== null
      ? '공통 발문 중복 표시 (개별 발문에 공통 지시문이 다시 들어 있음)'
      : null;
    const issueDetail: string | null = typeof b.quality_issue_detail === 'string' && b.quality_issue_detail.trim()
      ? b.quality_issue_detail
      : dupStripped !== null
      ? 'common_stem과 stem 에 같은 지시문이 들어 있어 학생 화면에 두 번 표시됩니다. 개별 발문에서 공통 부분을 제거하면 해결됩니다.'
      : null;
    const qualityOk = stemOk && choicesOk && figureOk && latexOk && fidelityOk && !issueTitle;

    const solutionFound = s?.found === true && typeof s?.solution_transcribed === 'string' && s.solution_transcribed.trim().length > 0;
    const answerMatched = c.answer_matched === true;
    const matchMode = solutionFound || it.has_solution_ref === true ? '3way' : '2way';
    const drafts = Array.isArray(c.draft_proposals) ? c.draft_proposals : [];

    const existing = await auth.admin
      .from('textbook_problem_analyses')
      .select('solution_transcribed,solution_answer,solution_source,render_checks,quality_status,fix_proposal')
      .eq('crop_id', cropId)
      .maybeSingle();
    const prev = (existing.data ?? {}) as Rec;
    // 운영자가 직접 고친 원본 해설은 Vision 결과로 덮지 않는다.
    const keepManual = prev.solution_source === 'manual' && typeof prev.solution_transcribed === 'string';
    // 엔진 보류 중인 문항은 재검수해도 보류를 유지한다(엔진 목록에서 따로 관리).
    const keepHeld = prev.quality_status === 'held';

    // 데이터 수정 제안: 원문과 실제로 다를 때만 남긴다. 이미 적용된 제안은 비운다.
    const issueKind: IssueKind = dupStripped !== null ? 'data' : normalizeIssueKind(b.issue_kind, !qualityOk);
    // 공통 발문 중복은 규칙으로 바로 고친 본문을 제안한다(모델 제안보다 우선).
    const proposedStem = dupStripped !== null
      ? dupStripped
      : issueKind === 'data' && typeof b.proposed_stem === 'string' && b.proposed_stem.trim() &&
          b.proposed_stem.trim() !== String(it.stem ?? '').trim()
      ? b.proposed_stem.trim()
      : null;
    const proposedChoices = issueKind === 'data' ? normalizeProposedChoices(b.proposed_choices) : null;
    const choicesDiffer = proposedChoices !== null && JSON.stringify(proposedChoices) !== JSON.stringify(it.choices ?? []);
    const fixReason = dupStripped !== null
      ? '공통 발문(common_stem)이 개별 발문에도 들어 있어 공통 부분을 제거했습니다.'
      : typeof b.fix_reason === 'string'
      ? b.fix_reason
      : null;
    const fixProposal: Rec = proposedStem || choicesDiffer
      ? {
        kind: issueKind,
        stem: proposedStem,
        choices: choicesDiffer ? proposedChoices : null,
        reason: fixReason,
        reason_code: dupStripped !== null ? 'common_stem_duplicate' : null,
        source: dupStripped !== null ? 'system' : 'stage2',
        created_at: nowIso,
      }
      : {};

    await auth.admin.from('textbook_problem_analyses').upsert({
      crop_id: cropId,
      academy_id: academyId,
      solution_transcribed: keepManual
        ? prev.solution_transcribed
        : solutionFound
        ? String(s!.solution_transcribed).trim()
        : (prev.solution_source === 'textbook_vision' ? prev.solution_transcribed ?? null : null),
      solution_answer: keepManual
        ? prev.solution_answer ?? null
        : solutionFound
        ? (typeof s!.solution_answer === 'string' ? s!.solution_answer : null)
        : (prev.solution_source === 'textbook_vision' ? prev.solution_answer ?? null : null),
      solution_source: keepManual ? 'manual' : solutionFound ? 'textbook_vision' : (prev.solution_source ?? null),
      solution_extracted_at: solutionFound ? nowIso : undefined,
      ai_solution: typeof b.ai_solution === 'string' ? b.ai_solution : null,
      ai_answer: typeof b.ai_answer === 'string' ? b.ai_answer : null,
      arithmetic_counts: arithCounts,
      visual_tags: visualTags,
      quality_checks: {
        judged_from_v2_image: b.judged_from_v2_image === true,
        stem_ok: stemOk,
        choices_ok: choicesOk,
        figure_ok: figureOk,
        latex_v2_ok: latexOk,
        fidelity_ok: fidelityOk,
        issue_title: issueTitle,
        issue_detail: issueDetail,
        issue_kind: issueKind,
        solution_vision: s
          ? { found: s.found === true, confidence: s.confidence ?? null, note: s.note ?? null }
          : null,
      },
      fix_proposal: fixProposal,
      // 문항 본문이 다시 풀렸으니 이전 V2 렌더 판정은 비운다(해설·정답 카드가 바뀐다).
      render_checks: {},
      render_checked_at: null,
      solved_at: nowIso,
      match_mode: matchMode,
      answer_matched: answerMatched,
      mismatch_reason: typeof c.mismatch_reason === 'string' ? c.mismatch_reason : null,
      concept_ids: [...new Set(validConceptIds)],
      thinking_ids: [...new Set(validThinkingIds)],
      draft_proposals: drafts,
      analyzed_at: nowIso,
      math_status: answerMatched ? 'clean' : 'issue',
      quality_status: keepHeld ? 'held' : (qualityOk ? 'clean' : 'issue'),
      updated_at: nowIso,
    });

    await auth.userClient.rpc('textbook_problem_recalc_scores', { p_crop_id: cropId });

    if (!answerMatched) {
      const proposedAns = typeof c.proposed_answer === 'string' && c.proposed_answer.trim()
        ? c.proposed_answer.trim()
        : String(b.ai_answer ?? '');
      await upsertOpenFinding(auth, {
        academy_id: academyId,
        crop_id: cropId,
        stage: 'compare',
        axis: 'validity',
        error_type: 'answer_mismatch',
        severity: 'blocker',
        source: 'ai',
        check_key: 'ai_answer_compare',
        title: `정답 불일치 (기존: ${it.existing_answer ?? '없음'} / 해설: ${
          solutionFound ? (s!.solution_answer ?? '없음') : '없음'
        } / AI: ${b.ai_answer ?? '없음'})`,
        detail: String(c.mismatch_reason ?? '기존 정답과 AI 독립 풀이 정답이 일치하지 않습니다.'),
        evidence: {
          existing_answer: it.existing_answer,
          ai_answer: b.ai_answer,
          solution_answer: solutionFound ? s!.solution_answer : null,
        },
        proposal: proposedAns
          ? {
            target: 'answer',
            after: { kind: 'text', value: proposedAns },
            reason: String(c.mismatch_reason ?? 'AI 독립 풀이 및 원본 해설 대조 결과'),
            keeps: '문항 본문과 해설 위치는 그대로 유지합니다.',
          }
          : null,
        status: 'open',
        ai_run_id: aiRunId,
      }).catch(() => null);
    } else {
      await resolveOpenFinding(auth, cropId, 'ai_answer_compare').catch(() => null);
    }

    if (!qualityOk) {
      await upsertOpenFinding(auth, {
        academy_id: academyId,
        crop_id: cropId,
        stage: 'render',
        axis: !fidelityOk ? 'fidelity' : (!latexOk || !figureOk ? 'output' : 'fidelity'),
        error_type: !fidelityOk ? 'problem_transcription' : (!latexOk ? 'render_item' : 'problem_transcription'),
        severity: 'warning',
        source: 'ai',
        check_key: 'ai_quality_v2_student_view',
        title: issueTitle ?? '학생 시점 V2 렌더 품질 확인 필요',
        detail: issueDetail ?? 'V2 렌더링 화면에서 발문·선지·도형·수식 표시를 확인해야 합니다.',
        evidence: {
          judged_from_v2_image: b.judged_from_v2_image === true,
          stem_ok: stemOk,
          choices_ok: choicesOk,
          figure_ok: figureOk,
          latex_v2_ok: latexOk,
          fidelity_ok: fidelityOk,
          issue_kind: issueKind,
        },
        proposal: proposedStem || choicesDiffer
          ? {
            target: 'problem',
            after: { stem: proposedStem, choices: choicesDiffer ? proposedChoices : null },
            reason: fixReason ?? '원본과 대조한 데이터 수정 제안',
            keeps: '정답·해설 위치는 그대로 유지합니다.',
          }
          : null,
        status: 'open',
        ai_run_id: aiRunId,
      }).catch(() => null);
    } else {
      await resolveOpenFinding(auth, cropId, 'ai_quality_v2_student_view').catch(() => null);
    }

    // 해설 좌표는 있는데 전사에 실패한 경우 알려 둔다(운영자가 좌표를 고치거나 직접 입력).
    if (it.has_solution_ref === true && images.get(cropId)?.solutionImageDataUrl && !solutionFound) {
      await upsertOpenFinding(auth, {
        academy_id: academyId,
        crop_id: cropId,
        stage: 'solution_text',
        axis: 'fidelity',
        error_type: 'solution_transcription',
        severity: 'warning',
        source: 'ai',
        check_key: 'ai_solution_vision',
        title: '원본 해설 전사 실패',
        detail: String(s?.note ?? '해설 좌표 영역 이미지에서 이 문항의 풀이를 읽지 못했습니다. 해설 좌표를 확인하거나 직접 입력하세요.'),
        evidence: { solution_raw_page: it.solution_raw_page, region_1k: it.solution_region_1k },
        status: 'open',
        ai_run_id: aiRunId,
      }).catch(() => null);
    } else if (solutionFound) {
      await resolveOpenFinding(auth, cropId, 'ai_solution_vision').catch(() => null);
    }

    processed += 1;
  }

  const remaining = Math.max(0, todoItems.length - processed);
  return jsonResponse({
    ok: true,
    processed,
    remaining,
    total: allItems.length,
    done: remaining === 0,
    cost_usd: costUsd,
  });
}

/**
 * 재검수 대상: 미검수, 풀이 없음, 또는 해설 좌표가 있는데 원본 해설 전사를 아직 시도하지 않은 문항(승인된 것은 제외).
 * Vision 전사를 시도했다가 못 읽은 문항(quality_checks.solution_vision 기록 있음)은 다시 대상이 되지 않는다 — 운영자가 좌표를 고치거나 직접 입력한다.
 */
export function isReviewTodo(it: Rec, forceRerun: boolean): boolean {
  if (forceRerun) return true;
  const mathStatus = String(it.math_status ?? 'pending');
  if (mathStatus === 'pending' || !it.ai_solution) return true;
  if (mathStatus === 'approved') return false;
  const qc = (it.quality_checks ?? {}) as Rec;
  const visionTried = qc.solution_vision !== null && qc.solution_vision !== undefined;
  return it.has_solution_ref === true && !it.solution_transcribed && !visionTried;
}

/**
 * V2 렌더링 학생 시점 검수. 매니저앱이 문항 카드·정답+해설 카드를 V2로 찍어 서명 URL을 보내면
 * 모델이 학생 시점에서 읽히는지 판정하고 render_checks·quality_status·findings 에 반영한다.
 *   body: { academy_id, items: [{ crop_id, problem_url?, answer_solution_url?, solution_kind?: 'textbook'|'ai' }] }
 */
export async function handleTextbookProblemRenderCheck(
  req: Request,
  auth: AuthContext,
  body: Rec,
): Promise<Response> {
  const academyId = uuidOrNull(body.academy_id);
  if (!academyId) return errorResponse(400, 'invalid_scope', '학원 정보가 필요합니다.');
  const rawItems = Array.isArray(body.items) ? (body.items as unknown[]) : [];
  const items = rawItems
    .map((x) => (x ?? {}) as Rec)
    .map((r) => ({
      cropId: uuidOrNull(r.crop_id),
      problemUrl: typeof r.problem_url === 'string' && /^https:\/\//.test(r.problem_url) ? r.problem_url : null,
      answerSolutionUrl: typeof r.answer_solution_url === 'string' && /^https:\/\//.test(r.answer_solution_url)
        ? r.answer_solution_url
        : null,
      solutionKind: r.solution_kind === 'ai' ? 'ai' : 'textbook',
    }))
    .filter((x): x is { cropId: string; problemUrl: string | null; answerSolutionUrl: string | null; solutionKind: string } =>
      !!x.cropId && (!!x.problemUrl || !!x.answerSolutionUrl)
    )
    .slice(0, 8);
  if (items.length === 0) return jsonResponse({ ok: true, processed: 0 });

  const wallClockMs = thinkWallClockMs();
  const provider = createAiProvider({ timeoutMs: wallClockMs + 5000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') {
    return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');
  }

  const cropIds = items.map((x) => x.cropId);
  const { data: analyses } = await auth.admin
    .from('textbook_problem_analyses')
    .select('crop_id,academy_id,quality_status,quality_checks,textbook_problem_crops(problem_number,label)')
    .in('crop_id', cropIds);
  const analysisByCrop = new Map<string, Rec>();
  for (const a of (analyses ?? []) as Rec[]) {
    if (String(a.academy_id) === academyId) analysisByCrop.set(String(a.crop_id), a);
  }
  const targets = items.filter((x) => analysisByCrop.has(x.cropId));
  if (targets.length === 0) return jsonResponse({ ok: true, processed: 0 });

  const startedAt = Date.now();
  const model = modelFor('primary');
  const safetyId = await safetyIdentifier(auth.userId);
  const signal = AbortSignal.any([req.signal, AbortSignal.timeout(wallClockMs)]);

  const parts: AiContentPart[] = [{
    type: 'text',
    text: JSON.stringify({
      problems: targets.map((x) => {
        const a = analysisByCrop.get(x.cropId)!;
        const crop = (a.textbook_problem_crops ?? {}) as Rec;
        return {
          crop_id: x.cropId,
          problem_number: crop.problem_number ?? '',
          label: crop.label ?? '',
          has_problem_card: !!x.problemUrl,
          has_answer_solution_card: !!x.answerSolutionUrl,
          solution_kind: x.solutionKind,
        };
      }),
    }),
  }];
  for (const x of targets) {
    if (x.problemUrl) {
      parts.push({ type: 'text', text: `[crop_id=${x.cropId} · 문항 카드(V2)]` });
      parts.push({ type: 'image', url: x.problemUrl, detail: 'high' });
    }
    if (x.answerSolutionUrl) {
      parts.push({
        type: 'text',
        text: `[crop_id=${x.cropId} · 정답+해설 카드(V2 · ${x.solutionKind === 'ai' ? 'AI 풀이' : '원본 해설'})]`,
      });
      parts.push({ type: 'image', url: x.answerSolutionUrl, detail: 'high' });
    }
  }

  const res = await provider.complete(
    {
      model,
      instructions: RENDER_CHECK_INSTRUCTIONS,
      input: [{ kind: 'message', role: 'user', parts }],
      jsonSchema: { name: 'textbook_problem_render_check', schema: RENDER_CHECK_SCHEMA },
      reasoningEffort: 'low',
      maxOutputTokens: 6000,
      safetyId,
    },
    signal,
  );
  const byCrop = parseProblems(finalText(res));
  const costUsd = estimateCostUsd(model, res.usage, 0);
  const aiRunId = await recordAiRun(auth.admin, {
    feature: 'textbook_problem_render_check',
    provider: provider.name,
    model,
    promptVersion: TEXTBOOK_REVIEW_PROMPT_VERSION,
    status: 'ok',
    error: null,
    usage: res.usage,
    webSearchCalls: 0,
    toolCalls: 0,
    costUsd,
    latencyMs: Date.now() - startedAt,
    conversationId: null,
    createdBy: auth.userId,
    features: { count: targets.length },
  });

  const nowIso = new Date().toISOString();
  let processed = 0;
  const results: Rec[] = [];
  for (const x of targets) {
    const r = byCrop.get(x.cropId);
    if (!r) continue;
    const a = analysisByCrop.get(x.cropId)!;
    const problemOk = r.problem_ok !== false;
    const answerOk = r.answer_ok !== false;
    const solutionOk = r.solution_ok !== false;
    const renderOk = problemOk && answerOk && solutionOk;
    const qc = (a.quality_checks ?? {}) as Rec;
    const stage2Ok = qc.stem_ok !== false && qc.choices_ok !== false && qc.figure_ok !== false &&
      qc.latex_v2_ok !== false && qc.fidelity_ok !== false && !qc.issue_title;
    const prevStatus = String(a.quality_status ?? 'pending');
    // 승인·엔진 보류는 재검수로 바꾸지 않는다. 보류 문항은 엔진 목록에서 재렌더 결과를 보고 운영자가 승인한다.
    const nextStatus = prevStatus === 'approved' || prevStatus === 'held'
      ? prevStatus
      : (renderOk && stage2Ok ? 'clean' : 'issue');
    const issueKind = normalizeIssueKind(r.issue_kind, !renderOk);

    await auth.admin.from('textbook_problem_analyses').update({
      render_checks: {
        problem_ok: problemOk,
        answer_ok: answerOk,
        solution_ok: solutionOk,
        issue_title: r.issue_title ?? null,
        issue_detail: r.issue_detail ?? null,
        issue_kind: issueKind,
        engine_symptom: issueKind === 'engine' && typeof r.engine_symptom === 'string' ? r.engine_symptom : null,
        solution_kind: x.solutionKind,
        checked_problem: !!x.problemUrl,
        checked_answer_solution: !!x.answerSolutionUrl,
        model,
      },
      render_checked_at: nowIso,
      quality_status: nextStatus,
      updated_at: nowIso,
    }).eq('crop_id', x.cropId);

    if (!renderOk) {
      await upsertOpenFinding(auth, {
        academy_id: academyId,
        crop_id: x.cropId,
        stage: 'render',
        axis: 'output',
        error_type: 'render_item',
        severity: 'warning',
        source: 'ai',
        check_key: 'ai_v2_render_student_view',
        title: String(r.issue_title ?? 'V2 렌더 카드 읽기 문제'),
        detail: String(r.issue_detail ?? '학생 시점에서 문항·정답·해설 카드 중 읽히지 않는 부분이 있습니다.'),
        evidence: {
          problem_ok: problemOk,
          answer_ok: answerOk,
          solution_ok: solutionOk,
          solution_kind: x.solutionKind,
          issue_kind: issueKind,
          engine_symptom: issueKind === 'engine' ? r.engine_symptom ?? null : null,
        },
        status: prevStatus === 'held' ? 'held' : 'open',
        ai_run_id: aiRunId,
      }).catch(() => null);
    } else {
      await resolveOpenFinding(auth, x.cropId, 'ai_v2_render_student_view').catch(() => null);
    }
    results.push({ crop_id: x.cropId, problem_ok: problemOk, answer_ok: answerOk, solution_ok: solutionOk, issue_kind: issueKind });
    processed += 1;
  }

  return jsonResponse({ ok: true, processed, results, cost_usd: costUsd });
}
