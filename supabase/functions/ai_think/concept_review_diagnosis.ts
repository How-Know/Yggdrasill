// 개념 검수 형식 실패의 첫 원인. 저장은 기존 reason 문자열 하나다.
// 모델이 쓴 문장, 개념 본문, 근거 문장, 잘못된 id는 넣지 않는다.

export interface Diagnosis {
  stage: 'stage1' | 'foundation';
  code: string;
  scope: string | null;
  field: string;
  expected: string;
  actual_type: string;
}

export interface StoredDiagnosis {
  kind: 'specific' | 'generic' | 'other';
  code: string | null;
  stage: 'stage1' | 'foundation' | null;
  scope: string | null;
  field: string | null;
  expected: string | null;
  actual_type: string | null;
}

const CODES = new Set([
  'scope_not_allowed',
  'outcome_not_allowed',
  'merge_needed_scope',
  'checked_missing',
  'findings_missing',
  'basis_missing',
  'refs_not_array',
  'ref_element_type',
  'ref_uuid',
  'ref_self',
  'ref_outside_allow_list',
  'fix_ops_missing',
  'fix_ops_too_many',
  'fix_op_mismatch',
  'fix_text_missing',
  'fix_evidence_empty',
  'fix_unit_mismatch',
  'fix_placement_mismatch',
  'fix_basis_mismatch',
  'duplicate_scope',
  'empty_reviews',
  'reviews_not_array',
]);

const TOKEN = /^[a-z][a-z0-9_]{0,40}$/;
const FIELD = /^[a-z][a-z0-9_.\[\]]{0,160}$/;

const token = (v: string | null | undefined): string | null => (v && TOKEN.test(v) ? v : null);

/** reason 500자 안에 코드·범위·필드가 앞에 오도록 고정한다. */
export function judgeInvalidReason(d: Diagnosis): string {
  const code = token(d.code) ?? '-';
  const scope = token(d.scope) ?? '-';
  const field = d.field && FIELD.test(d.field) ? d.field : '-';
  const expected = token(d.expected) ?? '-';
  const actual = token(d.actual_type) ?? '-';
  return `judge_invalid:${code}:${scope}:${field}:${expected}:${actual}`.slice(0, 500);
}

/** 저장된 reason을 진단으로 읽는다. 예전 포괄 문장에는 범위·필드를 만들지 않는다. */
export function diagnosisFromReason(reason: string | null | undefined): StoredDiagnosis {
  const other = (code: string | null): StoredDiagnosis => ({
    kind: 'other', code, stage: null, scope: null, field: null, expected: null, actual_type: null,
  });
  if (!reason) return other(null);
  const parts = reason.split(':');
  const head = parts[0]?.trim() ?? '';
  if (head !== 'judge_invalid') return other(TOKEN.test(head) ? head : null);
  const code = parts[1] ?? '';
  const field = parts[3] ?? '';
  if (
    parts.length >= 6 && CODES.has(code) && (field === '-' || FIELD.test(field)) &&
    token(parts[4]) && token(parts[5])
  ) {
    const scope = parts[2] === '-' ? null : token(parts[2]);
    const path = field === '-' ? null : field;
    const stage = path?.startsWith('needs') || scope === 'foundation' ? 'foundation' : 'stage1';
    return {
      kind: 'specific',
      code,
      stage,
      scope,
      field: path,
      expected: token(parts[4]),
      actual_type: token(parts[5]),
    };
  }
  return {
    kind: 'generic', code: 'judge_invalid', stage: null, scope: null, field: null, expected: null, actual_type: null,
  };
}

export function failureCodeOf(reason: string | null | undefined): string {
  const d = diagnosisFromReason(reason);
  if (d.kind === 'specific' && d.code) return d.code;
  if (d.kind === 'generic') return 'judge_invalid';
  return d.code ?? 'unknown';
}

type Rec = Record<string, unknown>;

/** 이번 실행의 실패를 최대 50개까지 돌려준다. 합계는 잘리기 전의 전체다. */
export function failureReport(rows: Rec[], limit = 50): Rec {
  const cap = Math.max(0, Math.min(50, limit));
  const byCode: Record<string, number> = {};
  for (const row of rows) {
    const code = failureCodeOf(typeof row.reason === 'string' ? row.reason : null);
    byCode[code] = (byCode[code] ?? 0) + 1;
  }
  const items = rows.slice(0, cap).map((row) => {
    const reason = typeof row.reason === 'string' ? row.reason : null;
    return {
      position: row.position ?? null,
      concept_id: typeof row.concept_id === 'string' ? row.concept_id : null,
      name: typeof row.name === 'string' ? row.name : null,
      reason,
      diagnosis: diagnosisFromReason(reason),
    };
  });
  const omitted = Math.max(0, rows.length - items.length);
  return {
    count: rows.length,
    by_code: byCode,
    items,
    returned: items.length,
    omitted,
    read_rest: omitted > 0
      ? 'get_concept_review_job의 failures를 읽는다. failure_after에 마지막 position을 넣으면 그 다음 실패가 나온다.'
      : null,
  };
}
