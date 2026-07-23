// 교재 풀기 자동 채점 엔진 (순수 로직 — 네트워크/DB 접근 없음).
//
// 파이프라인 (주관식):
//   1) LaTeX/선형 표기 정규화 → 정규화 문자열이 같으면 정답
//   2) ','/'또는' 목록 분해 → 원소별 수학 동치(수치 평가) 비교
//   3) 숫자+단위 해석 → 숫자만 맞으면 정답 (+단위 힌트/주의 플래그)
//      단위 환산(10m ↔ 1000cm)으로 같은 양이면 정답 후보 → AI에 "발문이
//      단위를 지정했는지" 판정 위임 (needsUnitAi)
//   4) 한글 서술 답 → 압축 문자열 비교, 불일치 시 AI 동치 판정 위임
//
// SQL 쪽 분류 함수(_student_grading_mode)와 동일한 self/auto 분류 로직을
// gradingMode()로 유지한다. 규칙 변경 시 양쪽을 함께 수정할 것.

export interface GradeOutcome {
  correct: boolean;
  flags: string[]; // unit_hint | unit_caution | form_differs
  needsUnitAi: boolean; // 단위 환산 동치 — 발문 단위 지정 여부를 AI로 확인
  needsEquivAi: boolean; // 한글 표현 동치 — AI로 확인
}

const outcome = (
  correct: boolean,
  flags: string[] = [],
  extra: Partial<GradeOutcome> = {},
): GradeOutcome => ({
  correct,
  flags,
  needsUnitAi: false,
  needsEquivAi: false,
  ...extra,
});

// ---------------------------------------------------------------------------
// self / auto 분류 (SQL _student_grading_mode 미러)
// ---------------------------------------------------------------------------
export function gradingMode(kind: string, text: string | null): 'auto' | 'self' {
  if (kind === 'objective') return 'auto';
  if (kind === 'image') return 'self';
  const t = replaceGreek((text ?? '').trim());
  if (!t) return 'self';
  if (/(^|\s)\(\s*\d\s*\)\s*\S/.test(t)) return 'self'; // 세트형 (1)(2)
  if (/\((가|나|다|라|마|바|사)\)/.test(t)) return 'self'; // 빈칸 채우기
  if (t.includes('\\begin')) return 'self'; // 연립/행렬
  if (/풀이\s*\d+\s*쪽/.test(t)) return 'self'; // 풀이 참조
  const labels = new Set<string>();
  const re = /(?:^|[,;\s(])\s*([A-Za-zα-ω가-힣][A-Za-z0-9α-ω가-힣의 ]{0,15}?)\s*[:=]/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(t)) !== null) {
    const label = m[1].trim();
    if (!/^\d+$/.test(label)) labels.add(label);
  }
  if (labels.size >= 2) return 'self';
  return 'auto';
}

// ---------------------------------------------------------------------------
// 세트형 정답 파트 분리 (SQL _split_set_answer_parts 미러 — 규칙 변경 시 함께)
// ---------------------------------------------------------------------------
// 규칙:
//   * 마커는 (1)부터 1씩 증가하는 것만 인정 (다음 기대 번호만 탐색)
//     → "(2)번 답이 (1)"처럼 내용에 등장하는 번호는 마커로 오인하지 않음
//   * 마커는 문자열 시작 또는 공백 뒤에서만 인정
//   * 파트 내용이 비면 그 마커 후보는 내용으로 간주하고 건너뜀
//   * 파트 2개 미만, 마지막 내용 공백, 8파트 초과 → null (세트형 아님/파싱 포기)
export interface SetAnswerPart {
  key: string; // '(1)'
  text: string;
}

export function splitSetAnswerParts(
  raw: string | null,
): SetAnswerPart[] | null {
  const t = (raw ?? '').trim();
  if (!t) return null;
  const markerRe = /^[(（]\s*(\d{1,2})\s*[)）]/;
  const parts: SetAnswerPart[] = [];
  let i = 0;
  let expected = 1;
  let contentStart = -1;
  while (i < t.length) {
    const m = markerRe.exec(t.slice(i));
    if (m !== null && Number(m[1]) === expected) {
      const prev = i === 0 ? ' ' : t[i - 1];
      if (/\s/.test(prev)) {
        if (expected === 1) {
          if (t.slice(0, i).trim() === '') {
            contentStart = i + m[0].length;
            expected = 2;
            i += m[0].length;
            continue;
          }
        } else {
          const partText = t.slice(contentStart, i).trim();
          if (partText !== '') {
            parts.push({ key: `(${expected - 1})`, text: partText });
            contentStart = i + m[0].length;
            expected += 1;
            i += m[0].length;
            continue;
          }
        }
      }
    }
    i += 1;
  }
  if (expected < 3) return null;
  const last = t.slice(contentStart).trim();
  if (last === '') return null;
  parts.push({ key: `(${expected - 1})`, text: last });
  // 개념원리 '확인 체크'류는 (1)~(10)까지 있어 상한을 12로 둔다 (SQL과 동일).
  if (parts.length > 12) return null;
  return parts;
}

// ---------------------------------------------------------------------------
// 정규화: LaTeX → 선형 표기
// ---------------------------------------------------------------------------

/** `\frac{a}{b}` → `(a)/(b)` (중첩 지원 — 중괄호 짝 맞춰 재귀 치환). */
function replaceLatexCommand(
  input: string,
  command: string,
  argCount: number,
  build: (args: string[]) => string,
): string {
  let s = input;
  let idx = s.indexOf(command);
  let guard = 0;
  while (idx >= 0 && guard < 200) {
    guard += 1;
    let pos = idx + command.length;
    const args: string[] = [];
    let ok = true;
    for (let a = 0; a < argCount; a += 1) {
      while (pos < s.length && s[pos] === ' ') pos += 1;
      if (s[pos] !== '{') {
        // `\sqrt5` 처럼 중괄호 없는 단일 토큰 인자 허용
        if (pos < s.length && /[0-9A-Za-z]/.test(s[pos])) {
          args.push(s[pos]);
          pos += 1;
          continue;
        }
        ok = false;
        break;
      }
      let depth = 0;
      let end = -1;
      for (let i = pos; i < s.length; i += 1) {
        if (s[i] === '{') depth += 1;
        else if (s[i] === '}') {
          depth -= 1;
          if (depth === 0) {
            end = i;
            break;
          }
        }
      }
      if (end < 0) {
        ok = false;
        break;
      }
      args.push(s.slice(pos + 1, end));
      pos = end + 1;
    }
    if (!ok) break;
    s = s.slice(0, idx) + build(args) + s.slice(pos);
    idx = s.indexOf(command);
  }
  return s;
}

const GREEK: Record<string, string> = {
  alpha: 'α', beta: 'β', gamma: 'γ', delta: 'δ',
  theta: 'θ', lambda: 'λ', mu: 'μ', omega: 'ω',
};

function replaceGreek(s: string): string {
  return s.replace(
    /\\(alpha|beta|gamma|delta|theta|lambda|mu|omega)\b/g,
    (_, name: string) => GREEK[name],
  );
}

export function normalizeMathLinear(raw: string | null): string {
  let s = (raw ?? '').trim();
  if (!s) return '';
  s = replaceGreek(s);
  s = s.replace(/\$/g, '');
  s = s.replace(/\\left|\\right/g, '');
  s = s.replace(/\\(?:dfrac|tfrac)/g, '\\frac');
  s = s.replace(/\\text(?:rm|style)?\s*\{([^{}]*)\}/g, '$1');
  s = s.replace(/\\mathrm\s*\{([^{}]*)\}/g, '$1');
  s = replaceLatexCommand(s, '\\frac', 2, ([a, b]) => `(${a})/(${b})`);
  // n제곱근: \sqrt[3]{x} → √[3](x)  (√[n]( 형태가 표준 선형 표기)
  s = s.replace(/\\sqrt\s*\[\s*(\d+)\s*\]/g, '\\nthroot$1');
  for (const deg of new Set(
    [...s.matchAll(/\\nthroot(\d+)/g)].map((m) => m[1]),
  )) {
    s = replaceLatexCommand(s, `\\nthroot${deg}`, 1, ([a]) => `√[${deg}](${a})`);
  }
  s = replaceLatexCommand(s, '\\sqrt', 1, ([a]) => `√(${a})`);
  s = s.replace(/∛/g, '√[3]');
  s = s.replace(/∜/g, '√[4]');
  s = replaceLatexCommand(s, '\\dot', 1, ([a]) => `${a}\u0307`); // 순환소수 점
  s = s.replace(/\\pi/g, 'π');
  s = s.replace(/\\pm/g, '±');
  s = s.replace(/\\neg/g, 'ㄱ'); // VLM이 보기 'ㄱ'을 \neg로 추출한 데이터 보정
  s = s.replace(/\\sqsubset/g, 'ㄷ');
  s = s.replace(/\\alpha/g, 'α');
  s = s.replace(/\\beta/g, 'β');
  s = s.replace(/\\gamma/g, 'γ');
  s = s.replace(/\\delta/g, 'δ');
  s = s.replace(/\\leq(?![a-zA-Z])|\\le(?![a-zA-Z])/g, '≤');
  s = s.replace(/\\geq(?![a-zA-Z])|\\ge(?![a-zA-Z])/g, '≥');
  s = s.replace(/\\neq(?![a-zA-Z])|\\ne(?![a-zA-Z])/g, '≠');
  s = s.replace(/\\%/g, '%');
  s = s.replace(/\\cdots/g, '…');
  s = s.replace(/\\cdot|\\times/g, '*');
  s = s.replace(/\\div/g, '/');
  s = s.replace(/×/g, '*');
  s = s.replace(/÷/g, '/');
  s = s.replace(/\\bigcirc|[○◯〇]/g, 'Ⓞ');
  s = s.replace(/\\textdegree|\\circ/g, '°');
  s = s.replace(/\^\{([^{}]*)\}/g, '^($1)');
  s = s.replace(/_\{([^{}]*)\}/g, '_($1)');
  s = s.replace(/\\[,;! ]/g, '');
  s = s.replace(/[{}]/g, '');
  s = s.replace(/−/g, '-'); // U+2212
  // 보기 항목 표기 통일: ㉠/㈀/(ㄱ) → ㄱ
  const circledJamo = '㉠ㄱ㉡ㄴ㉢ㄷ㉣ㄹ㉤ㅁ㉥ㅂ㉦ㅅ㉧ㅇ㉨ㅈ㉩ㅊ㉪ㅋ㉫ㅌ㉬ㅍ㉭ㅎ' +
    '㈀ㄱ㈁ㄴ㈂ㄷ㈃ㄹ㈄ㅁ㈅ㅂ㈆ㅅ㈇ㅇ㈈ㅈ';
  for (let i = 0; i < circledJamo.length; i += 2) {
    s = s.split(circledJamo[i]).join(circledJamo[i + 1]);
  }
  s = s.replace(/\(([ㄱ-ㅎ])\)/g, '$1');
  return s.trim();
}

// 공백 제거 + 문장 끝 마침표 제거 (소수점은 보존: 숫자가 뒤따르는 '.'만 유지)
const compact = (s: string) =>
  s.replace(/\s+/g, '').replace(/\.(?!\d)/g, '').toLowerCase();

// ---------------------------------------------------------------------------
// 수치 평가기 (토크나이저 + 션팅야드)
// ---------------------------------------------------------------------------

type Tok =
  | { t: 'num'; v: number }
  | { t: 'var'; name: string }
  | { t: 'op'; op: string }
  | { t: 'lp' }
  | { t: 'rp' }
  | { t: 'sqrt'; deg: number };

function tokenize(input: string): Tok[] | null {
  const toks: Tok[] = [];
  let i = 0;
  const s = input.replace(/\s+/g, '');
  while (i < s.length) {
    const c = s[i];
    if (/[0-9.]/.test(c)) {
      let j = i;
      while (j < s.length && /[0-9.]/.test(s[j])) j += 1;
      const numStr = s.slice(i, j);
      if ((numStr.match(/\./g) ?? []).length > 1) return null;
      toks.push({ t: 'num', v: Number(numStr) });
      i = j;
      continue;
    }
    if (c === 'π') {
      toks.push({ t: 'num', v: Math.PI });
      i += 1;
      continue;
    }
    if (/[a-zA-Zα-ω]/.test(c)) {
      toks.push({ t: 'var', name: c });
      i += 1;
      continue;
    }
    if (c === '√') {
      // `√[3](8)` → 세제곱근. 인덱스 없으면 제곱근.
      const m = s.slice(i + 1).match(/^\[(\d+)\]/);
      if (m) {
        toks.push({ t: 'sqrt', deg: Number(m[1]) });
        i += 1 + m[0].length;
      } else {
        toks.push({ t: 'sqrt', deg: 2 });
        i += 1;
      }
      continue;
    }
    if (c === '(') {
      toks.push({ t: 'lp' });
      i += 1;
      continue;
    }
    if (c === ')') {
      toks.push({ t: 'rp' });
      i += 1;
      continue;
    }
    if ('+-*/^'.includes(c)) {
      toks.push({ t: 'op', op: c });
      i += 1;
      continue;
    }
    return null; // 알 수 없는 문자 → 평가 불가
  }
  return toks;
}

/** 암시적 곱셈 삽입: `2√3` `3π` `2(1+x)` `(a)(b)` `2x` `x2`? (x2는 제외) */
function insertImplicitMul(toks: Tok[]): Tok[] {
  const out: Tok[] = [];
  const endsValue = (t: Tok) => t.t === 'num' || t.t === 'var' || t.t === 'rp';
  const startsValue = (t: Tok) =>
    t.t === 'num' || t.t === 'var' || t.t === 'lp' || t.t === 'sqrt';
  for (const t of toks) {
    if (out.length > 0 && endsValue(out[out.length - 1]) && startsValue(t)) {
      // `x2` (변수 뒤 숫자)는 첨자 표기일 수 있어 곱으로 보지 않고 평가 포기
      if (out[out.length - 1].t === 'var' && t.t === 'num') return [];
      out.push({ t: 'op', op: '*' });
    }
    out.push(t);
  }
  return out;
}

function evalTokens(toks: Tok[], scope: Map<string, number>): number | null {
  // 션팅야드 → RPN → 평가. 단항 마이너스/√ 지원.
  const outQ: (Tok | { t: 'neg' })[] = [];
  const ops: (Tok | { t: 'neg' })[] = [];
  const prec = (o: Tok | { t: 'neg' }): number => {
    if (o.t === 'neg' || o.t === 'sqrt') return 4;
    if (o.t === 'op') {
      if (o.op === '^') return 3;
      if (o.op === '*' || o.op === '/') return 2;
      return 1;
    }
    return 0;
  };
  let prev: Tok | null = null;
  for (const t of toks) {
    if (t.t === 'num' || t.t === 'var') {
      outQ.push(t);
    } else if (t.t === 'sqrt') {
      ops.push(t);
    } else if (t.t === 'op') {
      const unaryMinus =
        t.op === '-' &&
        (prev === null || prev.t === 'lp' || prev.t === 'op' || prev.t === 'sqrt');
      if (unaryMinus) {
        ops.push({ t: 'neg' });
      } else {
        while (
          ops.length > 0 &&
          ops[ops.length - 1].t !== 'lp' &&
          (prec(ops[ops.length - 1]) > prec(t) ||
            (prec(ops[ops.length - 1]) === prec(t) && t.op !== '^'))
        ) {
          outQ.push(ops.pop()!);
        }
        ops.push(t);
      }
    } else if (t.t === 'lp') {
      ops.push(t);
    } else if (t.t === 'rp') {
      while (ops.length > 0 && ops[ops.length - 1].t !== 'lp') {
        outQ.push(ops.pop()!);
      }
      if (ops.length === 0) return null;
      ops.pop();
      if (ops.length > 0 && ops[ops.length - 1].t === 'sqrt') {
        outQ.push(ops.pop()!);
      }
    }
    prev = t;
  }
  while (ops.length > 0) {
    const o = ops.pop()!;
    if (o.t === 'lp') return null;
    outQ.push(o);
  }

  const st: number[] = [];
  for (const t of outQ) {
    if (t.t === 'num') st.push(t.v);
    else if (t.t === 'var') {
      const v = scope.get(t.name);
      if (v === undefined) return null;
      st.push(v);
    } else if (t.t === 'neg') {
      if (st.length < 1) return null;
      st.push(-st.pop()!);
    } else if (t.t === 'sqrt') {
      if (st.length < 1) return null;
      const v = st.pop()!;
      const deg = t.deg;
      if (v < 0) {
        // 홀수 제곱근은 음수 허용: ∛(-8) = -2
        st.push(deg % 2 === 1 ? -Math.pow(-v, 1 / deg) : NaN);
      } else {
        st.push(deg === 2 ? Math.sqrt(v) : Math.pow(v, 1 / deg));
      }
    } else if (t.t === 'op') {
      if (st.length < 2) return null;
      const b = st.pop()!;
      const a = st.pop()!;
      switch (t.op) {
        case '+': st.push(a + b); break;
        case '-': st.push(a - b); break;
        case '*': st.push(a * b); break;
        case '/': st.push(b === 0 ? NaN : a / b); break;
        case '^': st.push(Math.pow(a, b)); break;
        default: return null;
      }
    }
  }
  if (st.length !== 1 || !Number.isFinite(st[0])) return null;
  return st[0];
}

interface Parsed {
  toks: Tok[];
  vars: string[];
}

function parseExpr(linear: string): Parsed | null {
  // 순환소수 점(결합 문자)이 있으면 수치 표현이 아님 → 구조 비교로만
  if (linear.includes('\u0307') || linear.includes('Ⓞ')) return null;
  const raw = tokenize(linear);
  if (raw === null || raw.length === 0) return null;
  const toks = insertImplicitMul(raw);
  if (toks.length === 0) return null;
  const vars = [...new Set(
    toks.filter((t): t is Tok & { t: 'var' } => t.t === 'var').map((t) => t.name),
  )].sort();
  return { toks, vars };
}

/** ± 전개: `3±√2` → [`3+√2`, `3-√2`] (최초 1개만). */
function expandPm(linear: string): string[] {
  const idx = linear.indexOf('±');
  if (idx < 0) return [linear];
  const plus = linear.slice(0, idx) + '+' + linear.slice(idx + 1);
  const minus = linear.slice(0, idx) + '-' + linear.slice(idx + 1);
  return [...expandPm(plus), ...expandPm(minus)];
}

const SAMPLE_BASES = [2.137, -1.618, 0.739];

/** 수치(변수 샘플링 포함) 동치 비교. 판단 불가 시 null. */
export function numericEquals(aLin: string, bLin: string): boolean | null {
  const aVariants = expandPm(aLin);
  const bVariants = expandPm(bLin);
  if (aVariants.length > 1 || bVariants.length > 1) {
    // ± 답: 전개 집합끼리 다중집합 매칭
    if (aVariants.length !== bVariants.length) return null;
    const used = new Array(bVariants.length).fill(false);
    for (const av of aVariants) {
      let matched = false;
      for (let i = 0; i < bVariants.length; i += 1) {
        if (used[i]) continue;
        if (numericEquals(av, bVariants[i]) === true) {
          used[i] = true;
          matched = true;
          break;
        }
      }
      if (!matched) return false;
    }
    return true;
  }

  const pa = parseExpr(aLin);
  const pb = parseExpr(bLin);
  if (pa === null || pb === null) return null;
  if (pa.vars.join(',') !== pb.vars.join(',')) return false;

  for (let round = 0; round < 3; round += 1) {
    const scope = new Map<string, number>();
    pa.vars.forEach((name, i) => {
      scope.set(name, SAMPLE_BASES[(i + round) % SAMPLE_BASES.length] + round * 0.311);
    });
    const va = evalTokens(pa.toks, scope);
    const vb = evalTokens(pb.toks, scope);
    if (va === null || vb === null) return null;
    const tol = Math.max(1e-9, Math.abs(va) * 1e-9);
    if (Math.abs(va - vb) > tol) return false;
    if (pa.vars.length === 0) return true; // 상수식은 1회로 충분
  }
  return true;
}

// ---------------------------------------------------------------------------
// 단위
// ---------------------------------------------------------------------------

interface UnitInfo {
  dim: string;
  factor: number; // 같은 dim 내 기준 단위 대비 배율. 0 = 환산 불가(개수 단위)
}

const UNIT_TABLE: Record<string, UnitInfo> = {
  'mm': { dim: 'len', factor: 1 },
  'cm': { dim: 'len', factor: 10 },
  'm': { dim: 'len', factor: 1000 },
  'km': { dim: 'len', factor: 1e6 },
  'mm^(2)': { dim: 'area', factor: 1 },
  'cm^(2)': { dim: 'area', factor: 100 },
  'm^(2)': { dim: 'area', factor: 1e6 },
  'km^(2)': { dim: 'area', factor: 1e12 },
  'cm^(3)': { dim: 'vol', factor: 1 },
  'm^(3)': { dim: 'vol', factor: 1e6 },
  'ml': { dim: 'vol', factor: 1 },
  'l': { dim: 'vol', factor: 1000 },
  'mg': { dim: 'mass', factor: 1 },
  'g': { dim: 'mass', factor: 1000 },
  'kg': { dim: 'mass', factor: 1e6 },
  't': { dim: 'mass', factor: 1e9 },
  '초': { dim: 'time', factor: 1 },
  '분': { dim: 'time', factor: 60 },
  '시간': { dim: 'time', factor: 3600 },
  '°': { dim: 'angle', factor: 1 },
  '도': { dim: 'angle', factor: 1 },
  '%': { dim: 'pct', factor: 1 },
  '원': { dim: 'krw', factor: 1 },
};

// 환산 불가 개수 단위 (dim = count:<단위>)
const COUNT_UNITS = [
  '개', '명', '마리', '살', '세', '번', '송이', '가지', '장', '곡', '배',
  '권', '자루', '켤레', '판', '줄', '쪽', '문제', '회', '점', '쌍', 'kcal',
  'kwh', '가구', '그루', '병', '봉지', '상자', '박스', '조각', '칸', '통',
];

export interface Quantity {
  value: number;
  unit: string | null; // 정규화된 단위 키 (null = 단위 없음)
  dim: string | null;
  factor: number;
}

const unitKeysDesc = [
  ...Object.keys(UNIT_TABLE),
  ...COUNT_UNITS,
].sort((a, b) => b.length - a.length);

/** 끝의 알려진 단위 접미사 분리. `(2x+1)시간` → {core:'(2x+1)', unit:'시간'} */
export function stripUnitSuffix(
  linear: string,
): { core: string; unit: string | null } {
  const s = linear.replace(/\s+/g, '');
  const lower = s.toLowerCase();
  for (const key of unitKeysDesc) {
    if (!lower.endsWith(key.toLowerCase())) continue;
    const core = s.slice(0, s.length - key.length);
    if (!core) continue;
    // 단위 앞이 숫자/닫는 괄호/변수일 때만 단위로 인정 (한글 문장 오탐 방지)
    if (!/[0-9)a-zA-Zπ]$/.test(core)) continue;
    return { core, unit: key };
  }
  return { core: s, unit: null };
}

/** `240m` `12분` `55°` `1000 cm^(2)` → 수치+단위. 해석 불가 시 null. */
export function parseQuantity(linear: string): Quantity | null {
  const { core, unit } = stripUnitSuffix(linear);
  if (!core) return null;
  const parsed = parseExpr(core);
  if (parsed === null || parsed.vars.length > 0) return null;
  const v = evalTokens(parsed.toks, new Map());
  if (v === null) return null;
  if (unit === null) return { value: v, unit: null, dim: null, factor: 1 };
  const info = UNIT_TABLE[unit];
  return info
    ? { value: v, unit, dim: info.dim, factor: info.factor }
    : { value: v, unit, dim: `count:${unit}`, factor: 0 };
}

// ---------------------------------------------------------------------------
// 목록 분해 (최상위 ',' / '또는' — 괄호 안은 무시)
// ---------------------------------------------------------------------------
export function splitList(linear: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let cur = '';
  const pushCur = () => {
    const t = cur.trim();
    if (t) parts.push(t);
    cur = '';
  };
  let i = 0;
  while (i < linear.length) {
    const c = linear[i];
    if (c === '(') depth += 1;
    if (c === ')') depth = Math.max(0, depth - 1);
    if (depth === 0 && c === ',') {
      pushCur();
      i += 1;
      continue;
    }
    if (depth === 0 && linear.startsWith('또는', i)) {
      pushCur();
      i += 2;
      continue;
    }
    cur += c;
    i += 1;
  }
  pushCur();
  return parts;
}

// ---------------------------------------------------------------------------
// 원소 단위 비교 (수치 → 부등식 구조 → 압축 문자열)
// ---------------------------------------------------------------------------

const REL_OPS = /[≤≥<>≠=]/;

function canonicalSegment(seg: string): string {
  const parsed = parseExpr(seg);
  if (parsed !== null && parsed.vars.length === 0) {
    const v = evalTokens(parsed.toks, new Map());
    if (v !== null) return `#${Number(v.toPrecision(12))}`;
  }
  return compact(seg);
}

function relationalEquals(a: string, b: string): boolean | null {
  if (!REL_OPS.test(a) || !REL_OPS.test(b)) return null;
  const split = (s: string) => {
    const segs: string[] = [];
    const ops: string[] = [];
    let cur = '';
    for (const ch of s) {
      if (/[≤≥<>≠=]/.test(ch)) {
        segs.push(cur);
        ops.push(ch);
        cur = '';
      } else {
        cur += ch;
      }
    }
    segs.push(cur);
    return { segs: segs.map(canonicalSegment), ops };
  };
  const A = split(a);
  const B = split(b);
  const same = (x: typeof A, y: typeof B) =>
    x.ops.join('') === y.ops.join('') &&
    x.segs.length === y.segs.length &&
    x.segs.every((s, i) => s === y.segs[i]);
  if (same(A, B)) return true;
  // 거울 표기: `1<x` ↔ `x>1`
  const flip = (op: string) =>
    op === '<' ? '>' : op === '>' ? '<' : op === '≤' ? '≥' : op === '≥' ? '≤' : op;
  const mirrored = {
    segs: [...B.segs].reverse(),
    ops: [...B.ops].reverse().map(flip),
  };
  if (same(A, mirrored)) return true;
  return false;
}

/** 단일 원소 동치 비교. */
function elementEquals(a: string, b: string): { eq: boolean; numeric: boolean } {
  if (compact(a) === compact(b)) return { eq: true, numeric: false };

  // `x=3` ↔ `3`, `|+3|=3` ↔ `3`: '='의 우변만 비교 (부등호가 없을 때)
  const stripLabel = (s: string) => {
    if (/[≤≥<>≠]/.test(s)) return s;
    const idx = s.lastIndexOf('=');
    if (idx <= 0 || idx === s.length - 1) return s;
    return s.slice(idx + 1);
  };
  const a2 = stripLabel(a);
  const b2 = stripLabel(b);
  if (a2 !== a || b2 !== b) {
    if (compact(a2) === compact(b2)) return { eq: true, numeric: false };
  }

  const rel = relationalEquals(a, b);
  if (rel !== null) return { eq: rel, numeric: false };

  const num = numericEquals(a2, b2);
  if (num !== null) return { eq: num, numeric: true };

  return { eq: false, numeric: false };
}

// ---------------------------------------------------------------------------
// 객관식
// ---------------------------------------------------------------------------
const CIRCLED: Record<string, string> = {
  '①': '1', '②': '2', '③': '3', '④': '4', '⑤': '5',
  '⑥': '6', '⑦': '7', '⑧': '8', '⑨': '9', '⑩': '10',
};

export function normalizeObjective(raw: string | null): string {
  let s = raw ?? '';
  for (const [k, v] of Object.entries(CIRCLED)) {
    s = s.split(k).join(` ${v} `);
  }
  const nums = [...new Set((s.match(/\d+/g) ?? []).map(Number))].sort(
    (x, y) => x - y,
  );
  return nums.join(',');
}

// ---------------------------------------------------------------------------
// 메인 비교
// ---------------------------------------------------------------------------
const hasKorean = (s: string) => /[가-힣]/.test(s);

export function compareAnswers(
  kind: string,
  correctRaw: string,
  studentRaw: string,
): GradeOutcome {
  if (kind === 'objective') {
    const a = normalizeObjective(correctRaw);
    const b = normalizeObjective(studentRaw);
    return outcome(a !== '' && a === b);
  }

  const a = normalizeMathLinear(correctRaw);
  const b = normalizeMathLinear(studentRaw);
  if (!a || !b) return outcome(false);

  // 1) 정규화 문자열 완전 일치
  if (compact(a) === compact(b)) return outcome(true);

  // 2) 목록 비교 (다중집합 — 순서 무관)
  const listA = splitList(a);
  const listB = splitList(b);
  if (listA.length > 1 || listB.length > 1) {
    if (listA.length !== listB.length) return outcome(false);
    const used = new Array(listB.length).fill(false);
    let anyNumeric = false;
    for (const ea of listA) {
      let matched = false;
      for (let i = 0; i < listB.length; i += 1) {
        if (used[i]) continue;
        const r = elementEquals(ea, listB[i]);
        if (r.eq) {
          used[i] = true;
          matched = true;
          anyNumeric = anyNumeric || r.numeric;
          break;
        }
      }
      if (!matched) return outcome(false);
    }
    return outcome(true, anyNumeric ? ['form_differs'] : []);
  }

  // 3) 단일 원소 수학 비교
  const el = elementEquals(a, b);
  if (el.eq) return outcome(true, el.numeric ? ['form_differs'] : []);

  // 4) 단위 접미사 해석 (수치식뿐 아니라 `(2x+1)시간` 같은 식+단위도 지원)
  const ua = stripUnitSuffix(a);
  const ub = stripUnitSuffix(b);
  if (ua.unit !== null || ub.unit !== null) {
    // 학생이 단위 생략 → 나머지가 맞으면 정답 + 단위 힌트
    if (ua.unit !== null && ub.unit === null) {
      const r = elementEquals(ua.core, ub.core);
      if (r.eq) {
        return outcome(true, r.numeric ? ['unit_hint', 'form_differs'] : ['unit_hint']);
      }
      return outcome(false);
    }
    // 정답에 없는 단위를 학생이 붙임 → 나머지가 맞으면 정답 + 단위 주의
    if (ua.unit === null && ub.unit !== null) {
      const r = elementEquals(ua.core, ub.core);
      return r.eq ? outcome(true, ['unit_caution']) : outcome(false);
    }
    // 같은 단위 → 본문끼리 비교
    if (ua.unit === ub.unit) {
      const r = elementEquals(ua.core, ub.core);
      return outcome(r.eq, r.eq && r.numeric ? ['form_differs'] : []);
    }
    // 다른 단위, 같은 차원 → 환산 동치면 정답 (발문 단위 지정 여부는 AI 판정)
    const qa = parseQuantity(a);
    const qb = parseQuantity(b);
    if (
      qa !== null && qb !== null &&
      qa.dim === qb.dim && qa.factor > 0 && qb.factor > 0
    ) {
      const base = qa.value * qa.factor;
      const other = qb.value * qb.factor;
      if (Math.abs(base - other) <= tolOf(base)) {
        return outcome(true, [], { needsUnitAi: true });
      }
    }
    // 다른 단위인데 본문 숫자/식은 동일 (10m vs 10cm, 54마리 vs 54개)
    //   → "숫자만 맞으면 정답" 규칙 + 단위 주의
    const r = elementEquals(ua.core, ub.core);
    if (r.eq) return outcome(true, ['unit_caution']);
    return outcome(false);
  }

  // 5) 한글 서술 답 → 압축 비교는 이미 실패 → AI 동치 판정 위임
  if (hasKorean(a) || hasKorean(b)) {
    return outcome(false, [], { needsEquivAi: true });
  }

  return outcome(false);
}

const tolOf = (v: number) => Math.max(1e-9, Math.abs(v) * 1e-9);
