// 개념 출처의 원본 쪽을 다시 읽는 도구(읽기 전용). 개념·검토 기록·관계를 바꾸지 않는다.
// 쪽은 출처의 PDF 쪽(raw_page)으로만 고르고, 앞뒤는 2쪽까지만 읽는다. 인쇄 쪽은 기록이 있을 때만 따로 보인다.
// 원본 쪽 이미지는 게이트웨이가 만든 PNG를 도구 결과와 함께 모델 입력에 넣는다. 넣지 못했으면 결과에 그렇게 적는다.
// 설계: docs/architecture/concept-library.md §4.7

import type { AiFunctionTool, AiToolImage } from '../_shared/ai/types.ts';
import type { ActionToolContext } from './actions.ts';
import type { ToolRunResult } from './tools.ts';

export const SOURCE_LIST_TOOL_NAME = 'get_concept_sources';
export const SOURCE_PAGE_TOOL_NAME = 'read_concept_source_page';
export const CONCEPT_SOURCE_TOOL_NAMES = new Set([SOURCE_LIST_TOOL_NAME, SOURCE_PAGE_TOOL_NAME]);
export const CONCEPT_SOURCE_TOOL_LABELS: Record<string, string> = {
  [SOURCE_LIST_TOOL_NAME]: '개념 출처 목록 조회',
  [SOURCE_PAGE_TOOL_NAME]: '개념 출처 원본 읽기',
};

/** 한 답변에 모델 입력으로 넣는 원본 쪽 이미지 수와 앞뒤 쪽 읽기 수. */
export const SOURCE_IMAGE_LIMIT = 6;
export const SOURCE_ADJACENT_LIMIT = 4;
/** 쪽 읽기 도구 실행 한도. 이미지 기다림(IMAGE_WAIT_MS)보다 길어야 한다. */
export const SOURCE_PAGE_TOOL_TIMEOUT_MS = 50_000;
const IMAGE_WAIT_MS = 35_000;
const IMAGE_POLL_MS = 1_500;
/** OpenAI 이미지 입력 상한(파일당 크기)보다 작게 둔다. 게이트웨이는 7MB 아래로 만든다. */
const IMAGE_MAX_BYTES = 8 * 1024 * 1024;

export type ConceptSourceReadFn = 'concept_source_list' | 'concept_source_page_context' | 'concept_source_page_image';

export interface ConceptSourceToolSource {
  conceptSourceRead?(fn: ConceptSourceReadFn, args: Record<string, unknown>): Promise<unknown>;
  /** 원본 쪽 이미지(PNG)를 사용자 권한으로 내려받는다. */
  readConceptSourcePageImage?(key: string): Promise<Uint8Array>;
}

export interface ConceptSourceToolContext {
  imagesLeft: number;
  adjacentLeft: number;
  /** 이 시각(ms)을 넘겨 이미지를 기다리지 않는다. */
  deadline: number;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
}

export const CONCEPT_SOURCE_TOOLS: AiFunctionTool[] = [
  {
    name: SOURCE_LIST_TOOL_NAME,
    description:
      '개념의 교재 출처 목록. 출처마다 source_id, 책·학년·책 단원, pdf_page(PDF 파일 안의 쪽 번호)와 print_page(책에 인쇄된 쪽 번호, ' +
      '기록이 없으면 null)를 따로 준다. 두 번호가 다른 것은 정상일 수 있다. 추출 글·원본 PDF 연결·쪽 이미지 상태도 함께 준다. ' +
      '원본을 다시 읽을 때 read_concept_source_page에 source_id를 준다.',
    parameters: {
      type: 'object',
      properties: {
        concept_id: { type: 'string', description: '개념 id (get_concept_for_edit·검색 결과의 id)' },
        offset: { type: ['integer', 'null'], description: '이어 볼 자리(next_offset). 처음이면 null.' },
      },
      required: ['concept_id', 'offset'],
      additionalProperties: false,
    },
  },
  {
    name: SOURCE_PAGE_TOOL_NAME,
    description:
      '출처 하나의 원본 쪽을 다시 읽는다(읽기 전용, 아무것도 바꾸지 않음). page_offset 0은 출처의 PDF 쪽, -2~2는 같은 PDF의 앞뒤 쪽이다. ' +
      '편집 본문(0일 때만), 추출 글(AI가 읽어 옮긴 블록), 그림 설명문(AI가 쓴 글), 가림 영역, 원본 이미지 상태를 따로 준다. ' +
      'with_image가 true면 실제 PDF 쪽 이미지를 이 결과 바로 뒤에 붙인다. original_image.attached가 true일 때만 원본을 봤다고 말한다.',
    parameters: {
      type: 'object',
      properties: {
        source_id: { type: 'string', description: 'get_concept_sources의 source_id' },
        page_offset: { type: ['integer', 'null'], description: '출처 쪽 기준 앞뒤(-2~2). 출처 쪽이면 null 또는 0.' },
        with_image: { type: 'boolean', description: '실제 원본 쪽 이미지를 볼지. 그림·수식·문맥 확인이 필요할 때 true.' },
      },
      required: ['source_id', 'page_offset', 'with_image'],
      additionalProperties: false,
    },
  },
];

type Rec = Record<string, unknown>;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const LIST_PAGE = 40;
const LIST_OUTPUT_CHARS = 24000;
const PAGE_OUTPUT_CHARS = 24000;
const BLOCK_TEXT_CHARS = 1500;
const EDITED_TEXT_CHARS = 4000;
const PAGE_BLOCK_LIMIT = 40;

function rec(v: unknown): Rec {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Rec) : {};
}

function list(v: unknown): Rec[] {
  return Array.isArray(v) ? v.filter((x) => x && typeof x === 'object' && !Array.isArray(x)) as Rec[] : [];
}

function strs(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : [];
}

function uuid(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return UUID_RE.test(t) ? t : null;
}

function int(v: unknown): number | null {
  return typeof v === 'number' && Number.isInteger(v) ? v : null;
}

function text(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

function clip(v: string, max: number): { text: string; truncated: boolean } {
  return v.length <= max ? { text: v, truncated: false } : { text: v.slice(0, max), truncated: true };
}

const unitPath = (v: unknown) => strs(v).join(' › ');

function out(name: string, value: unknown, summary: string, max: number, images?: AiToolImage[]): ToolRunResult {
  const s = JSON.stringify(value);
  const output = s.length <= max ? s : JSON.stringify({ truncated: true, preview: s.slice(0, max) });
  return { name, ok: true, output, summary, ...(images && images.length > 0 ? { images } : {}) };
}

function bad(name: string, error: string, summary: string, next: string): ToolRunResult {
  return { name, ok: false, output: JSON.stringify({ error, next }), summary };
}

const ERRORS: Record<string, [summary: string, next: string]> = {
  concept_statement_forbidden: ['접근 실패', '운영자 권한으로만 읽을 수 있다. 원본을 읽지 못했다고 알린다.'],
  concept_source_concept_not_found: ['없는 개념', 'concept_id는 get_concept_for_edit·검색 결과의 id만 쓴다.'],
  concept_source_not_found: ['없는 출처', 'source_id는 get_concept_sources 결과의 것만 쓴다. 추측하지 않는다.'],
  concept_source_page_bad_offset: ['쪽 범위 오류', 'page_offset은 -2~2만 쓴다. 더 먼 쪽은 읽지 않는다.'],
};

function readError(name: string, e: unknown): ToolRunResult {
  const message = e instanceof Error ? e.message : String(e);
  for (const [code, [summary, next]] of Object.entries(ERRORS)) {
    if (message.includes(code)) return bad(name, code, summary, next);
  }
  throw e;
}

const PAGE_NOTE =
  'pdf_page는 PDF 파일 안의 쪽 번호, print_page는 책에 인쇄된 쪽 번호다. 둘은 다를 수 있다. print_page가 null이면 기록이 없는 것이다(추정하지 않는다). ' +
  'get_concept_for_edit 출처의 page는 인쇄 쪽 기록이 있으면 인쇄 쪽, 없으면 PDF 쪽이라 원본 위치로 쓰지 않는다.';

const LINK_LABELS: Record<string, string> = {
  ok: '원본 PDF 연결됨',
  link_missing: '연결 끊김: 이 책·학년의 본문 PDF 연결이 없다',
  link_ambiguous: '연결 끊김: 본문 PDF 연결이 여러 개라 고르지 않았다',
  link_legacy: '연결 끊김: 원본이 저장소로 옮겨지지 않은 옛 연결이다',
};

const IMAGE_STATE_LABELS: Record<string, string> = {
  not_requested: '아직 만든 적 없음',
  queued: '준비 중',
  working: '준비 중',
  ready: '준비됨',
  failed: '실패',
  stale: '원본 파일이 바뀌어 다시 만들어야 함',
};

const FAILURE_LABELS: Record<string, string> = {
  link_missing: '연결 끊김: 본문 PDF 연결이 없다',
  link_mismatch: '연결 끊김: 연결된 PDF가 이 책·학년의 본문이 아니다',
  link_legacy: '연결 끊김: 옛 연결이라 원본을 받을 수 없다',
  source_changed: '원본 파일이 바뀌었다(다시 요청하면 새로 만든다)',
  source_download_failed: '접근 실패: 원본 PDF를 받지 못했다',
  page_out_of_range: '자료 없음: PDF에 이 쪽이 없다',
  render_failed: '원본 쪽을 그리지 못했다',
  image_too_large: '이미지가 너무 커서 넣지 않았다',
  upload_failed: '접근 실패: 만든 이미지를 저장하지 못했다',
};

function sourceListRow(s: Rec): Rec {
  const reads = int(s.transcript_reads) ?? 0;
  const draft = text(s.draft);
  const image = rec(s.image);
  const imageStatus = text(image.status) || 'not_requested';
  const row: Rec = {
    source_id: s.id,
    book: s.book_name ?? null,
    grade: s.grade_label ?? null,
    unit: unitPath(s.unit_path),
    pdf_page: s.raw_page ?? null,
    print_page: s.display_page ?? null,
    statement_id: s.statement_id ?? null,
    statement_title: s.statement_title ?? null,
    evidence_scope: s.evidence_scope ?? null,
    linked_blocks: int(s.block_count) ?? 0,
    extracted_text: draft === 'found'
      ? (s.draft_covers_page === true ? '초안 블록 있음' : '초안에 이 쪽이 없음')
      : draft === 'missing'
      ? '연결 끊김: 근거 초안 기록이 없다'
      : '초안 연결 없음',
    transcript: reads > 0 ? `전사 ${reads}회` : '전사 없음',
    original_pdf: LINK_LABELS[text(s.link)] ?? '확인 불가',
    page_image: LINK_LABELS[imageStatus]
      ? '연결 끊김'
      : imageStatus === 'failed'
      ? `실패: ${FAILURE_LABELS[text(image.error)] ?? text(image.error)}`
      : IMAGE_STATE_LABELS[imageStatus] ?? '확인 불가',
  };
  if (s.member === false) row.image_access = '접근 실패: 이 학원 소속이 아니라 원본 이미지를 볼 수 없다';
  return row;
}

async function readSources(name: string, args: Rec, src: ConceptSourceToolSource): Promise<ToolRunResult> {
  const conceptId = uuid(args.concept_id);
  if (!conceptId) return bad(name, 'invalid_id', 'id 형식 오류', 'concept_id는 get_concept_for_edit·검색 결과의 id를 쓴다.');
  const offset = Math.max(0, int(args.offset) ?? 0);
  let data: unknown;
  try {
    data = await src.conceptSourceRead!('concept_source_list', { p_concept_id: conceptId });
  } catch (e) {
    return readError(name, e);
  }
  const d = rec(data);
  const all = list(d.sources);
  const total = int(d.total) ?? all.length;
  const rows = all.slice(offset, offset + LIST_PAGE).map(sourceListRow);
  const to = offset + rows.length;
  const value: Rec = {
    concept_id: d.concept_id ?? conceptId,
    concept_name: d.name ?? null,
    total,
    from: offset,
    to,
    next_offset: to < all.length ? to : null,
    page_note: PAGE_NOTE,
    sources: rows,
  };
  if (total === 0) value.note = '자료 없음: 이 개념에 저장된 교재 출처가 없다. 출처를 추정해 만들지 않는다.';
  else if (to >= all.length && all.length < total) {
    value.note = `일부만 조회됨: 출처 ${total}개 중 ${all.length}개까지만 읽을 수 있다.`;
  }
  return out(name, value, `${text(d.name)} 출처 ${rows.length}/${total}개`, LIST_OUTPUT_CHARS);
}

// ---------------------------------------------------------------------------
// 원본 쪽 이미지
// ---------------------------------------------------------------------------

interface ImageOutcome {
  view: Rec;
  /** 이미지를 넣지 못한 까닭의 분류(missing 목록에 쓴다). 넣었으면 null. */
  missing: string | null;
  image?: AiToolImage;
}

function pngSize(bytes: Uint8Array): { width: number; height: number } | null {
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (bytes.length < 24 || sig.some((b, i) => bytes[i] !== b)) return null;
  if (String.fromCharCode(bytes[12], bytes[13], bytes[14], bytes[15]) !== 'IHDR') return null;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { width: view.getUint32(16), height: view.getUint32(20) };
}

function base64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

function notAttached(missing: string, label: string, extra: Rec = {}): ImageOutcome {
  return {
    missing,
    view: { attached: false, status: missing, label, note: '원본 이미지를 보지 못했다. 원본을 봤다고 말하지 않는다.', ...extra },
  };
}

async function pageImage(
  src: ConceptSourceToolSource,
  sourceId: string,
  offset: number,
  expectedPage: number,
  state: ConceptSourceToolContext,
): Promise<ImageOutcome> {
  if (state.imagesLeft <= 0) {
    return notAttached('한도 초과', `이번 답변의 원본 이미지 한도(${SOURCE_IMAGE_LIMIT}장)를 넘어 넣지 않았다`);
  }
  const now = state.now ?? Date.now;
  const sleep = state.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const read = (request: boolean) =>
    src.conceptSourceRead!('concept_source_page_image', { p_source_id: sourceId, p_offset: offset, p_request: request });
  let r: Rec;
  try {
    r = rec(await read(true));
    const until = Math.min(now() + IMAGE_WAIT_MS, state.deadline);
    while ((r.status === 'queued' || r.status === 'working') && r.worker_alive === true && now() + IMAGE_POLL_MS < until) {
      await sleep(IMAGE_POLL_MS);
      r = rec(await read(false));
    }
  } catch {
    return notAttached('접근 실패', '접근 실패: 원본 이미지 상태를 읽지 못했다');
  }
  const status = text(r.status);
  if (status === 'queued' || status === 'working') {
    return r.worker_alive === true
      ? notAttached('준비 중', '준비 중: 원본 쪽 이미지를 만드는 중이다(책의 첫 쪽이면 원본 PDF를 받느라 오래 걸린다). 잠시 뒤 다시 읽을 수 있다')
      : notAttached('원본 준비 서버 응답 없음', '원본 준비 서버 응답 없음: 쪽 이미지를 만드는 서버가 꺼져 있거나 응답하지 않는다');
  }
  if (status === 'failed') {
    const code = text(r.error);
    const label = FAILURE_LABELS[code] ?? '원본 쪽을 만들지 못했다';
    const missing = code.startsWith('link_') ? '연결 끊김' : code === 'page_out_of_range' ? '자료 없음' : '접근 실패';
    return notAttached(missing, `실패: ${label}`, { error: code || null });
  }
  if (LINK_LABELS[status]) return notAttached('연결 끊김', LINK_LABELS[status]);
  if (status === 'forbidden') return notAttached('접근 실패', '접근 실패: 이 학원 소속이 아니라 원본 이미지를 볼 수 없다');
  if (status === 'no_page') return notAttached('자료 없음', '자료 없음: PDF 1쪽보다 앞이다');
  if (status !== 'ready') return notAttached('접근 실패', '접근 실패: 원본 이미지 상태를 알 수 없다');

  const key = text(r.image_key);
  const width = int(r.width);
  const height = int(r.height);
  if (int(r.raw_page) !== expectedPage || !key.endsWith(`_p${expectedPage}.png`) || !src.readConceptSourcePageImage) {
    return notAttached('접근 실패', '접근 실패: 원본 이미지가 이 쪽의 것인지 확인하지 못했다');
  }
  let bytes: Uint8Array;
  try {
    bytes = await src.readConceptSourcePageImage(key);
  } catch {
    return notAttached('접근 실패', '접근 실패: 저장된 원본 이미지를 내려받지 못했다');
  }
  const size = pngSize(bytes);
  if (!size || bytes.length > IMAGE_MAX_BYTES || size.width !== width || size.height !== height) {
    return notAttached('접근 실패', '접근 실패: 내려받은 이미지가 기록과 맞지 않아 넣지 않았다');
  }
  state.imagesLeft -= 1;
  return {
    missing: null,
    view: {
      attached: true,
      status: '모델 입력에 포함됨',
      label: `이 결과 바로 뒤에 PDF ${expectedPage}쪽 원본 이미지(${size.width}×${size.height})를 붙였다. 가리지 않은 원본이다.`,
      width: size.width,
      height: size.height,
    },
    image: { url: `data:image/png;base64,${base64(bytes)}`, detail: 'high' },
  };
}

// ---------------------------------------------------------------------------
// 쪽 읽기
// ---------------------------------------------------------------------------

const BASIS_LABELS: Record<string, string> = {
  base: '개념 본문(기본 서술)',
  confirmed: '확정된 서술',
  draft: '저장된 서술 초안(확정 전)',
};

const DISPLAY_FROM_LABELS: Record<string, string> = {
  source: '출처 기록',
  draft: '초안의 쪽 정보',
  transcript: '쪽 전사 기록',
};

async function readPage(
  name: string,
  args: Rec,
  src: ConceptSourceToolSource,
  state: ConceptSourceToolContext,
): Promise<ToolRunResult> {
  const sourceId = uuid(args.source_id);
  if (!sourceId) return bad(name, 'invalid_id', 'id 형식 오류', 'source_id는 get_concept_sources 결과의 것만 쓴다.');
  const offset = args.page_offset == null ? 0 : int(args.page_offset);
  if (offset === null || offset < -2 || offset > 2) {
    return bad(name, 'concept_source_page_bad_offset', ...ERRORS.concept_source_page_bad_offset);
  }
  if (offset !== 0) {
    if (state.adjacentLeft <= 0) {
      return bad(
        name,
        'adjacent_limit',
        '앞뒤 쪽 한도',
        `한 답변에서 앞뒤 쪽은 ${SOURCE_ADJACENT_LIMIT}번까지 읽는다. 더 필요하면 어느 쪽이 왜 필요한지 사용자에게 알린다.`,
      );
    }
    state.adjacentLeft -= 1;
  }
  let data: unknown;
  try {
    data = await src.conceptSourceRead!('concept_source_page_context', { p_source_id: sourceId, p_offset: offset });
  } catch (e) {
    return readError(name, e);
  }
  const d = rec(data);
  const source = rec(d.source);
  const page = rec(d.page);
  const rawPage = int(page.raw_page) ?? 0;
  const missing: Rec[] = [];

  let editedText: Rec | null = null;
  if (offset === 0) {
    const basis = d.basis == null ? null : rec(d.basis);
    if (basis) {
      const c = clip(text(basis.text), EDITED_TEXT_CHARS);
      editedText = {
        what: '편집 본문: 운영자가 다듬은 라이브러리 글이다. 교재 원문이 아니다.',
        kind: BASIS_LABELS[text(basis.kind)] ?? text(basis.kind),
        text: c.text,
        ...(c.truncated ? { truncated: true, total_chars: text(basis.text).length } : {}),
      };
    } else {
      missing.push({ what: '편집 본문', state: '자료 없음', note: '근거 서술을 찾지 못했다' });
    }
  }

  const blocks = list(d.blocks);
  const blocksFrom = text(d.blocks_from);
  let anyBlockCut = false;
  const shown = blocks.slice(0, PAGE_BLOCK_LIMIT).map((b) => {
    const c = clip(text(b.text), BLOCK_TEXT_CHARS);
    if (c.truncated) anyBlockCut = true;
    return {
      block_id: b.id ?? null,
      linked: b.linked === true,
      kind: b.kind ?? null,
      title: b.title ?? null,
      text: c.text,
      ...(c.truncated ? { truncated: true } : {}),
      uncertain: b.uncertain === true,
    };
  });
  const extractedText = blocks.length === 0 ? null : {
    what: blocksFrom === 'draft'
      ? '추출 글: 교재 쪽 이미지를 AI가 읽어 옮긴 초안 블록이다. 원문 그대로라는 보장이 없다.'
      : '추출 글: 교재 쪽 이미지를 AI가 읽어 옮긴 쪽 전사다(초안 블록이 없는 쪽). 원문 그대로라는 보장이 없다.',
    from: blocksFrom === 'draft' ? 'draft' : 'transcript',
    blocks: shown,
  };
  if (blocks.length === 0) {
    missing.push({ what: '추출 글', state: '자료 없음', note: `PDF ${rawPage}쪽을 읽어 옮긴 기록이 없다. 다른 쪽 글로 대신하지 않는다.` });
  } else if (blocks.length > shown.length || anyBlockCut) {
    missing.push({ what: '추출 글', state: '일부만 조회됨', note: `블록 ${blocks.length}개 중 ${shown.length}개, 긴 글은 앞부분만 실었다` });
  }

  const linkedMissing = strs(d.linked_missing);
  if (linkedMissing.length > 0) {
    missing.push({
      what: '근거 블록',
      state: '연결 끊김',
      note: source.draft_found === false
        ? '근거 초안 기록이 없어 연결된 블록을 찾지 못했다'
        : `연결된 블록 ${linkedMissing.length}개를 초안 기록에서 찾지 못했다`,
      block_ids: linkedMissing,
    });
  }

  const figures = blocks
    .filter((b) => text(b.figure_description).trim())
    .map((b) => ({ block_id: b.id ?? null, text: clip(text(b.figure_description), BLOCK_TEXT_CHARS).text }));

  const masks = d.masks;
  const maskedRegions = masks == null
    ? { known: false, note: '이 쪽의 전사 기록이 없어 가린 영역을 모른다.' }
    : list(masks).length === 0
    ? { known: true, masked: false, note: '전사할 때 가린 영역이 없었다.' }
    : {
      known: true,
      masked: true,
      note: '전사할 때 문항 등을 가리고 읽었다. 가린 부분은 추출 글에 없다. 원본 이미지는 가리지 않은 PDF 쪽이다.',
      regions: list(masks).map((m) => ({ label: m.label ?? null, problem_number: m.problem_number ?? null, bbox_1k: m.bbox_1k ?? null })),
    };

  let image: ImageOutcome;
  if (args.with_image === true) {
    image = rawPage >= 1
      ? await pageImage(src, sourceId, offset, rawPage, state)
      : notAttached('자료 없음', '자료 없음: PDF 1쪽보다 앞이다');
  } else {
    image = notAttached('요청 안 함', '요청하지 않았다(with_image false)');
  }
  if (image.missing && image.missing !== '요청 안 함') {
    missing.push({ what: '원본 이미지', state: image.missing, note: text(image.view.label) });
  }

  const retrieved = editedText !== null || extractedText !== null || image.image !== undefined;
  const states = missing.map((m) => text(m.state));
  const status = !retrieved
    ? (states.includes('접근 실패') ? '접근 실패' : states.includes('연결 끊김') ? '연결 끊김' : '자료 없음')
    : missing.length > 0
    ? '일부만 조회됨'
    : '조회됨';

  const disagreements = list(d.disagreements).map((x) => ({ block_id: x.id ?? null, type: x.type ?? null }));
  const value: Rec = {
    status,
    source: {
      source_id: source.id ?? sourceId,
      concept: source.concept_name ?? null,
      book: source.book_name ?? null,
      grade: source.grade_label ?? null,
      unit: unitPath(source.unit_path),
      statement_id: source.statement_id ?? null,
      linked_block_ids: strs(source.block_ids),
    },
    page: {
      pdf_page: rawPage,
      print_page: page.display_page ?? null,
      print_page_from: DISPLAY_FROM_LABELS[text(page.display_from)] ?? '기록 없음(추정하지 않음)',
      offset,
    },
    page_note: PAGE_NOTE,
    materials: {
      edited_text: editedText,
      extracted_text: extractedText,
      figure_descriptions: figures.length > 0
        ? { what: '그림 설명문: AI가 쓴 글이다. 원본 그림이 아니다.', items: figures }
        : null,
      masked_regions: maskedRegions,
      original_image: image.view,
    },
    missing,
  };
  if (disagreements.length > 0) {
    value.read_disagreements = {
      note: '두 번 읽기가 서로 달랐던 블록이다. 원본 이미지로 확인할 거리다.',
      items: disagreements,
    };
  }
  const printPage = page.display_page != null ? `(인쇄 ${String(page.display_page)}쪽)` : '';
  const summary = `${text(source.book_name)} ${text(source.grade_label)} PDF ${rawPage}쪽${printPage} · ${status}` +
    (image.image ? ' · 원본 이미지 포함' : '');
  return out(name, value, summary.trim(), PAGE_OUTPUT_CHARS, image.image ? [image.image] : undefined);
}

export async function dispatchConceptSourceTool(
  name: string,
  args: Record<string, unknown>,
  src: ConceptSourceToolSource,
  ctx: ActionToolContext | undefined,
): Promise<ToolRunResult> {
  const state = ctx?.conceptSources;
  if (!state || !src.conceptSourceRead) {
    return bad(name, 'concept_source_unavailable', '지금은 쓸 수 없음', '지금은 출처 원본을 읽을 수 없다(기능이 준비되지 않았다). 원본을 봤다고 말하지 않는다.');
  }
  if (name === SOURCE_LIST_TOOL_NAME) return await readSources(name, args, src);
  if (name === SOURCE_PAGE_TOOL_NAME) return await readPage(name, args, src, state);
  return bad(name, 'unknown_tool', '알 수 없는 도구', '이 도구는 없다.');
}
