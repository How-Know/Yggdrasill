// 모의고사 검수에서 코드로 맞추는 표기(AI 없음). 2026-11-20 사장님 결정.
//   1) 해설 첫 줄의 출제의도 머리 표기를 '[출제의도]' 로 통일한다.
//   2) 점 이름과 이름표(상자 A, 과목 B) 대문자를 원본처럼 곧은 글자로 찍히게 감싼다.
//      조판 엔진은 한글이 아닌 글자를 모두 수식(기울인 글자)으로 찍고, \text{…}·\mathrm{…} 안만 곧게 찍는다.
//   3) 수식 뒤에 띄어 쓴 조사·단위를 붙여 쓴다('16 명' → '16명', 'A 와' → 'A와').
//      시험지 PDF 에서 글을 뽑을 때 수식과 글 사이가 띄어져 들어온 것이다.
// 정합성 점검(textbook_consistency.ts)이 모의고사 문항에만 쓴다. 교재·내신 문항에는 쓰지 않는다.
// 설계: docs/architecture/mock-exam.md

const INTENT_HEAD = /^(?:[\[<〈《【(]\s*출제\s*의도\s*[\]>〉》】)]\s*[:：]?|출제\s*의도\s*[:：])[ \t]*/;

/** 해설 첫머리의 출제의도 표기('출제의도 :', '<출제의도>' …)를 '[출제의도] ' 로 맞춘다. 다른 글은 그대로 둔다. */
export function unifyIntentMark(text: unknown): string {
  const s = String(text ?? '');
  const lead = s.match(/^\s*/)?.[0] ?? '';
  const body = s.slice(lead.length);
  const m = body.match(INTENT_HEAD);
  if (!m) return s;
  const rest = body.slice(m[0].length);
  return `${lead}[출제의도]${rest === '' || rest.startsWith('\n') ? '' : ' '}${rest}`;
}

/** 수식에 붙여 쓰는 조사. 낱말 전체가 이 가운데 하나일 때만 조사로 본다('가로', '도형', '이차' 는 아니다). */
const ATTACH_JOSA = [
  '은', '는', '이', '가', '을', '를', '와', '과', '의', '에', '로', '도', '만', '씩',
  '에서', '에게', '으로', '부터', '까지', '보다', '마다', '처럼',
  '에서의', '에서는', '에서도', '에는', '에도', '에만', '와의', '과의', '와는', '과는',
  '로의', '로는', '로도', '으로의', '으로는', '으로도', '로부터', '으로부터',
  '까지의', '까지는', '부터의', '만을', '만이', '만의', '에게는', '에게도', '보다는',
];
/** 수식에 붙여 쓰는 '이다' 꼴: a=1 일 때, k 인 실수, 3 이므로, A 라 하자 */
const ATTACH_COPULA = [
  '이다', '이고', '이며', '이면', '이면서', '이므로', '이라', '이라고', '이라는', '이라면', '이란',
  '이어야', '이거나', '이지만', '이기', '이나', '인', '일', '임', '임을', '인지',
  '라', '라고', '라는', '라면', '란', '여야',
];
/**
 * 수·문자 뒤에 붙여 쓰는 단위와 말. 뒤에 조사가 이어질 수 있다: 16 명을, 8 개의, 4 번, x 축에, y 절편은
 * '개수', '배수', '좌표평면' 처럼 다른 낱말로 이어지면 붙이지 않는다.
 */
const ATTACH_UNIT = '(?:명|개|번째|번|장|회|가지|쌍|배|축|좌표|절편)';
const longestFirst = (words: string[]) => [...words].sort((a, b) => b.length - a.length).join('|');
const ATTACH_TAIL = `(?:${longestFirst([...ATTACH_JOSA, ...ATTACH_COPULA])})`;
/** 붙여 쓸 낱말. 낱말이 끝나야(띄어쓰기·문장부호·줄 끝) 조사로 본다. */
const ATTACH_WORD = `(?:${ATTACH_UNIT}${ATTACH_TAIL}?|${ATTACH_TAIL})(?=[ \\t.,?!)\\]]|$)`;
/** 수식이 끝나는 글자 뒤의 띄어쓰기(같은 줄). 본문·선지는 $ 없이 적으므로 글자로 수식 끝을 안다. */
const PROBLEM_GAP_RE = new RegExp(`([0-9A-Za-zα-ωΑ-Ω)}\\]'′″|%°])[ \\t]+(?=${ATTACH_WORD})`, 'gm');
/** 해설은 수식을 $…$ 로 적는다. 닫는 $ 뒤의 띄어쓰기만 본다. */
const SOLUTION_GAP_RE = new RegExp(`\\$[ \\t]+(?=${ATTACH_WORD})`, 'gm');

/** `]` 가 '[그림]', '[문단]' 같은 한글 표시를 닫는지. 구간 [0, 1] 은 수식이다. */
function closesKoreanMarker(text: string, close: number): boolean {
  const open = text.lastIndexOf('[', close);
  return open < 0 || /[가-힣]/.test(text.slice(open, close));
}

/**
 * 수식 뒤에 띄어 쓴 조사·단위를 붙여 쓴다: '16 명을' → '16명을', '\text{A} 와' → '\text{A}와', '$x$ 의' → '$x$의'.
 * 띄어쓰기만 지우고 다른 글자는 바꾸지 않는다. 바꿀 것이 없으면 원문을 그대로 돌려준다.
 */
export function attachParticles(text: unknown, mode: NameMode): string {
  const src = String(text ?? '');
  if (!/[ \t][가-힣]/.test(src)) return src;
  if (mode === 'solution') {
    const math = mathMap(src);
    if (!math) return src;
    // 닫는 $ 는 수식 안에서 만난다. 여는 $ 뒤의 띄어쓰기는 건드리지 않는다.
    return src.replace(SOLUTION_GAP_RE, (gap: string, at: number) => (math[at] ? '$' : gap));
  }
  return src.replace(PROBLEM_GAP_RE, (gap: string, last: string, at: number) =>
    last === ']' && closesKoreanMarker(src, at) ? gap : last);
}

/** 한 문항에서 곧게 찍을 이름 글자(점·이름표)와 기울여 찍을 이름 글자(원 O, 구 S, 사건 A …). */
export interface NameSets {
  upright: Set<string>;
  italic: Set<string>;
}

/** problem: 본문·공통 발문·선지($ 없이 \text{…}). solution: 해설($…$ 안은 \mathrm{…}, 밖은 $\mathrm{…}$). */
export type NameMode = 'problem' | 'solution';

const UPRIGHT_COMMANDS = new Set(['text', 'mathrm', 'textrm', 'textup']);
const OPAQUE_COMMANDS = new Set([
  ...UPRIGHT_COMMANDS,
  'textbf', 'mathbf', 'mathbb', 'mathcal', 'mathit', 'mathsf', 'mathtt', 'textit', 'textsf', 'texttt',
  'operatorname', 'boldsymbol', 'bm', 'begin', 'end', 'label', 'tag', 'hspace', 'vspace',
  'phantom', 'hphantom', 'vphantom', 'color', 'textcolor',
]);
/** 인자({…})가 통째로 점 이름 묶음인 명령: \overline{AB}, \overrightarrow{AB} … */
const RUN_COMMANDS = new Set(['overline', 'overrightarrow', 'overleftarrow', 'overleftrightarrow', 'vec', 'widehat', 'overarc', 'wideparen']);
/** 뒤에 점 이름 묶음이 오는 명령: \angle ABC, \triangle ABC … */
const PREFIX_COMMANDS = new Set(['angle', 'measuredangle', 'triangle', 'bigtriangleup', 'square', 'Box']);
const PREFIX_SYMBOLS = new Set(['∠', '△', '□', '▱']);
/** 크기·간격만 바꾸는 명령. 앞뒤 글을 볼 때 없는 것으로 친다. */
const SPACE_COMMANDS = new Set([
  'left', 'right', 'quad', 'qquad', 'displaystyle', 'textstyle', 'big', 'Big', 'bigg', 'Bigg',
  'bigl', 'bigr', 'Bigl', 'Bigr', 'limits', 'nolimits',
]);

const PRIME = "['′″]{0,2}";
const SUB = '(?:_\\{[^{}]{1,8}\\}|_[0-9A-Za-z]|[₀-₉]{1,2})?';
/** 감싸지 않은 이름 하나: 대문자 + 프라임 + 아래첨자 */
const BARE_UNIT = `[A-Z]${PRIME}${SUB}${PRIME}`;
/** 이미 곧게 감싼 이름(가린 글에서는 § 로 보인다) + 프라임·아래첨자 */
const UP_UNIT = `§+${PRIME}${SUB}${PRIME}`;
const NAME = `(?:${BARE_UNIT}|${UP_UNIT})`;
const RUN = `${NAME}+`;
const BRIDGE = '(?:들)?(?:[을를은는이가])?\\s*(?:각각|차례로|차례대로|모두|중)?\\s*';
/** 이름 뒤 좌표: P(3, 0). 괄호는 한 겹까지 본다. */
const COORD = '(?:\\s*\\((?:[^()\\n]|\\([^()\\n]*\\))*\\))?';
const NAME_LIST = `${NAME}${COORD}(?:\\s*,\\s*${NAME}${COORD})*`;

const POINT_HEAD = '(?:(?<![득배총평관학결감가승벌채타만영])점|중심|외심|내심|수심|방심|수선의 발)';
/** 뒤에 점 이름 묶음이 오는 도형 말: 선분 AB, 삼각형 ABC, 평면 ABC */
const SHAPE_HEAD = '(?:평행사변형|직사각형|정사각형|삼각형|사각형|오각형|육각형|팔각형|다각형|마름모|사다리꼴|' +
  '반직선|선분|직선|평면|부채꼴|활꼴|모서리|대각선|벡터|호|현|변|각|면)';
/** 입체는 꼭짓점 묶음을 '-' 로 잇기도 한다: 사각뿔 A-BCDE, 사각뿔대 ABCD-EFGH */
const SOLID_HEAD = '(?:사면체|육면체|팔면체|각뿔대|각뿔|뿔대|각기둥)';
/** 원본이 곧은 글자로 찍는 이름표. 원본에서 확인한 것만 넣는다. */
const LABEL_HEAD = '(?:상자|주머니|과목|학생|사람|팀)';
/** 원본이 기울인 글자로 찍는 이름: 원 O, 구 S, 곡선 C, 사건 A, 넓이 A, 최댓값 M … */
const ITALIC_HEAD = '(?:원(?!점)|구|곡선|포물선|도형|집합|사건|함수|확률변수|넓이|부피|길이|영역|값|합|수열|개수|거리|확률)';
/** 이름 하나로 끝나는 이름(뒤에 다른 이름 글자가 붙지 않는다) */
const SINGLE = `${NAME}(?![A-Z§])`;

const POINT_RE = new RegExp(`${POINT_HEAD}${BRIDGE}(${NAME_LIST})`, 'g');
const LABEL_RE = new RegExp(`${LABEL_HEAD}${BRIDGE}(${SINGLE}(?:\\s*,\\s*${SINGLE})*)`, 'g');
const ITALIC_RE = new RegExp(`${ITALIC_HEAD}${BRIDGE}(${SINGLE}(?:\\s*,\\s*${SINGLE})*)`, 'g');
/** (단, O는 원점이다.) 'S는 원점 O를 중심으로 하는 원' 은 원점 이름이 아니므로 맺는 말까지 본다. */
const ORIGIN_RE = new RegExp(`(${SINGLE})\\s*[는은]\\s*(?:좌표평면의\\s*|좌표공간의\\s*)?원점(?:이다|이고|이며|\\s*\\))`, 'g');
const SPOT_RE = new RegExp(`(${SINGLE})\\s*지점`, 'g');
const SHAPE_RE = new RegExp(`${SHAPE_HEAD}\\s*(${RUN})`, 'g');
const SOLID_RE = new RegExp(`${SOLID_HEAD}\\s*(${RUN})(?:\\s*-\\s*(${RUN}))?`, 'g');
const SHAPE_MORE_RE = new RegExp(`^\\s*,\\s*(${RUN})`);
const RUN_RE = new RegExp(RUN, 'g');
const NAME_RE = new RegExp(NAME, 'g');
const RUN_ONLY_RE = new RegExp(`^(?:${NAME}|\\s)+$`);
const LEADING_RUN_RE = new RegExp(`^\\s*(${RUN})`);
const BARE_UNIT_RE = new RegExp(`([A-Z])(${PRIME})(${SUB})(${PRIME})`, 'g');
/** 묶음을 이미 감싼 조각(1)과 감싸지 않은 조각(2)으로 나눈다. */
const PIECE_RE = new RegExp(`(${UP_UNIT})|((?:${BARE_UNIT})+)`, 'g');

interface Span {
  start: number;
  end: number;
}

interface Analysis {
  /** 원문과 길이가 같은 가린 글. 명령·보호 구간은 ¤, 이미 곧게 감싼 이름은 §, 간격 명령·$ 는 빈칸 */
  masked: string;
  /** 이미 곧게 감싼 이름 구간의 시작 → 그 안의 글자들 */
  uprightAt: Map<number, string>;
  /** 머리말(점·선분·상자 …)이나 명령(\overline …)이 붙어 곧게 찍을 구간 */
  uprightSpans: Span[];
  /** 머리말(원·구·사건 …)이 붙어 기울여 찍을 구간 */
  italicSpans: Span[];
  sets: NameSets;
}

/** 가린 글의 구간에 든 이름 글자(감싸지 않은 대문자 + 이미 감싼 글자). 아래첨자 안의 글자(A_B, A_{BC})는 세지 않는다. */
function lettersIn(masked: string, uprightAt: Map<number, string>, start: number, end: number): string {
  let letters = '';
  for (let k = start; k < end; k += 1) {
    const c = masked[k];
    if (c === '_') {
      if (masked[k + 1] === '{') {
        const close = masked.indexOf('}', k);
        k = close < 0 ? end : close;
      } else {
        k += 1;
      }
      continue;
    }
    if (c >= 'A' && c <= 'Z') letters += c;
    else if (c === '§') letters += uprightAt.get(k) ?? '';
  }
  return letters;
}

function matchingBrace(text: string, open: number): number {
  let depth = 0;
  for (let i = open; i < text.length; i += 1) {
    const ch = text[i];
    if (ch === '\\') {
      i += 1;
      continue;
    }
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function analyze(text: string): Analysis {
  const out = text.split('');
  const uprightAt = new Map<number, string>();
  const runArgs: Span[] = [];
  const prefixEnds: number[] = [];
  const fill = (from: number, to: number, ch: string) => {
    for (let i = from; i < to; i += 1) out[i] = ch;
  };
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (ch === '[' && text[i + 1] === '[') {
      const close = text.indexOf(']]', i + 2);
      const end = close < 0 ? text.length : close + 2;
      fill(i, end, '¤');
      i = end;
      continue;
    }
    if (ch === '$' || ch === '~') {
      out[i] = ' ';
      i += 1;
      continue;
    }
    if (PREFIX_SYMBOLS.has(ch)) {
      out[i] = '¤';
      prefixEnds.push(i + 1);
      i += 1;
      continue;
    }
    if (ch !== '\\') {
      i += 1;
      continue;
    }
    const cmd = /^[A-Za-z]+/.exec(text.slice(i + 1))?.[0];
    if (!cmd) {
      // \, \; \! \: \(빈칸) 은 간격, 나머지(\\ \{ \$ …)는 기호
      fill(i, Math.min(text.length, i + 2), ',;!: '.includes(text[i + 1] ?? '') ? ' ' : '¤');
      i += 2;
      continue;
    }
    const nameEnd = i + 1 + cmd.length;
    let arg = nameEnd;
    while (arg < text.length && text[arg] === ' ') arg += 1;
    const close = text[arg] === '{' ? matchingBrace(text, arg) : -1;
    if (OPAQUE_COMMANDS.has(cmd) && close > 0) {
      const inner = text.slice(arg + 1, close);
      if (UPRIGHT_COMMANDS.has(cmd) && /^[A-Z](?:[A-Z]|['′″])*$/.test(inner)) {
        fill(i, close + 1, '§');
        uprightAt.set(i, inner.replace(/[^A-Z]/g, ''));
      } else {
        fill(i, close + 1, '¤');
      }
      i = close + 1;
      continue;
    }
    fill(i, nameEnd, SPACE_COMMANDS.has(cmd) ? ' ' : '¤');
    if (RUN_COMMANDS.has(cmd) && close > 0) runArgs.push({ start: arg + 1, end: close });
    if (PREFIX_COMMANDS.has(cmd)) prefixEnds.push(nameEnd);
    i = nameEnd;
  }
  const masked = out.join('');
  const lettersOf = (start: number, end: number) => lettersIn(masked, uprightAt, start, end);

  const sets: NameSets = { upright: new Set(), italic: new Set() };
  const uprightSpans: Span[] = [];
  const italicSpans: Span[] = [];
  const addUpright = (start: number, end: number) => {
    uprightSpans.push({ start, end });
    for (const c of lettersOf(start, end)) sets.upright.add(c);
  };
  /** 이름 목록(좌표는 뺀다)의 이름마다 구간을 낸다. */
  const namesIn = (start: number, end: number): Span[] => {
    const spans: Span[] = [];
    let depth = 0;
    let k = start;
    while (k < end) {
      const c = masked[k];
      if (c === '(') depth += 1;
      else if (c === ')') depth = Math.max(0, depth - 1);
      else if (depth === 0) {
        NAME_RE.lastIndex = k;
        const m = NAME_RE.exec(masked);
        if (m && m.index === k && k + m[0].length <= end) {
          spans.push({ start: k, end: k + m[0].length });
          k += m[0].length;
          continue;
        }
      }
      k += 1;
    }
    return spans;
  };

  // \overline{AB}, \overrightarrow{AB}: 글자가 둘 이상일 때만(\overline{X} 는 표본평균)
  for (const a of runArgs) {
    const inner = masked.slice(a.start, a.end);
    if (RUN_ONLY_RE.test(inner) && lettersOf(a.start, a.end).length >= 2) addUpright(a.start, a.end);
  }
  // \angle ABC, △ABC: 글자가 둘 이상일 때만(\angle A 는 각의 크기일 수 있다)
  for (const p of prefixEnds) {
    const m = LEADING_RUN_RE.exec(masked.slice(p));
    if (!m) continue;
    const start = p + m[0].length - m[1].length;
    if (lettersOf(start, start + m[1].length).length >= 2) addUpright(start, start + m[1].length);
  }
  for (const m of masked.matchAll(POINT_RE)) {
    const start = m.index! + m[0].length - m[1].length;
    for (const s of namesIn(start, start + m[1].length)) addUpright(s.start, s.end);
  }
  for (const m of masked.matchAll(LABEL_RE)) {
    const start = m.index! + m[0].length - m[1].length;
    for (const s of namesIn(start, start + m[1].length)) addUpright(s.start, s.end);
  }
  for (const re of [ORIGIN_RE, SPOT_RE]) {
    for (const m of masked.matchAll(re)) addUpright(m.index!, m.index! + m[1].length);
  }
  // 선분 AB, 삼각형 ABC: 글자가 둘 이상일 때만(직선 l, 평면 α 처럼 한 글자 이름은 점 이름이 아니다)
  for (const re of [SHAPE_RE, SOLID_RE]) {
    for (const m of masked.matchAll(re)) {
      const runStart = m.index! + m[0].search(/[A-Z§]/);
      const end = m.index! + m[0].length;
      if (lettersOf(runStart, end).length < 2) continue;
      addUpright(runStart, runStart + m[1].length);
      if (m[2]) addUpright(end - m[2].length, end);
      // 쉼표로 이어진 묶음: 정사각형 ABCD, EFGH
      let at = end;
      for (;;) {
        const more = SHAPE_MORE_RE.exec(masked.slice(at));
        if (!more) break;
        const moreStart = at + more[0].search(/[A-Z§]/);
        const moreEnd = at + more[0].length;
        if (lettersOf(moreStart, moreEnd).length < 2) break;
        addUpright(moreStart, moreEnd);
        at = moreEnd;
      }
    }
  }
  for (const m of masked.matchAll(ITALIC_RE)) {
    const start = m.index! + m[0].length - m[1].length;
    for (const s of namesIn(start, start + m[1].length)) {
      if (uprightSpans.some((u) => u.start < s.end && s.start < u.end)) continue;
      italicSpans.push(s);
      for (const c of lettersOf(s.start, s.end)) sets.italic.add(c);
    }
  }
  return { masked, uprightAt, uprightSpans, italicSpans, sets };
}

/** 글들에서 곧게 찍을 이름 글자와 기울여 찍을 이름 글자를 모은다. */
export function collectNameSets(texts: unknown[]): NameSets {
  const sets: NameSets = { upright: new Set(), italic: new Set() };
  for (const t of texts) {
    const a = analyze(String(t ?? ''));
    for (const c of a.sets.upright) sets.upright.add(c);
    for (const c of a.sets.italic) sets.italic.add(c);
  }
  return sets;
}

export function mergeNameSets(a: NameSets, b: NameSets): NameSets {
  return { upright: new Set([...a.upright, ...b.upright]), italic: new Set([...a.italic, ...b.italic]) };
}

export interface MockSolutionFormat {
  text: string;
  /** 출제의도 머리 표기를 바꿨다 */
  intentChanged: boolean;
  /** 이름 글자를 곧게 감쌌다 */
  namesChanged: boolean;
  /** 수식 뒤에 띄어 쓴 조사를 붙였다 */
  spacingChanged: boolean;
}

/**
 * 모의고사 해설 글의 표기를 맞춘다: 출제의도 머리 → '[출제의도]', 점 이름 → 곧은 글자, 수식 뒤 조사 → 붙여 쓰기.
 * [problemSets] 는 그 문항의 본문·선지에서 모은 이름 글자다. 해설에서 새로 나온 이름은 해설 글에서 더 모은다.
 */
export function formatMockSolution(text: unknown, problemSets: NameSets): MockSolutionFormat {
  const src = String(text ?? '');
  const marked = unifyIntentMark(src);
  const named = uprightNames(marked, mergeNameSets(problemSets, collectNameSets([marked])), 'solution');
  // 이름을 감싸면 '점 A 에서' 가 '점 $\mathrm{A}$ 에서' 가 되므로 붙여 쓰기는 그 뒤에 한다.
  const attached = attachParticles(named, 'solution');
  return {
    text: attached,
    intentChanged: marked !== src,
    namesChanged: named !== marked,
    spacingChanged: attached !== named,
  };
}

/** 수식 구분자 안인지($…$, $$…$$, \(…\), \[…\]). 짝이 맞지 않으면 null. */
function mathMap(text: string): boolean[] | null {
  const map = new Array<boolean>(text.length + 1).fill(false);
  let dollar = false;
  let paren = 0;
  let i = 0;
  while (i < text.length) {
    const inside = dollar || paren > 0;
    const ch = text[i];
    if (ch === '\\') {
      const next = text[i + 1];
      map[i] = inside;
      map[i + 1] = inside;
      if (next === '(' || next === '[') paren += 1;
      else if (next === ')' || next === ']') paren = Math.max(0, paren - 1);
      i += 2;
      continue;
    }
    if (ch === '$') {
      const two = text[i + 1] === '$';
      map[i] = inside;
      if (two) map[i + 1] = inside;
      dollar = !dollar;
      i += two ? 2 : 1;
      continue;
    }
    map[i] = inside;
    i += 1;
  }
  map[text.length] = dollar || paren > 0;
  return dollar || paren > 0 ? null : map;
}

const SUBSCRIPT_DIGITS = '₀₁₂₃₄₅₆₇₈₉';
const primes = (s: string) => s.replace(/′/g, "'").replace(/″/g, "''");
const subscript = (s: string) =>
  /^[₀-₉]+$/.test(s) ? `_{${[...s].map((c) => SUBSCRIPT_DIGITS.indexOf(c)).join('')}}` : s;

/** 감싸지 않은 이름 묶음(AB, OH_1, P′H₂Q)을 곧은 글자 명령으로 감싼다. 프라임·아래첨자는 명령 밖에 둔다. */
function wrapBare(segment: string, command: string): string {
  let out = '';
  let letters = '';
  const flush = () => {
    if (letters) out += `\\${command}{${letters}}`;
    letters = '';
  };
  let last = 0;
  for (const m of segment.matchAll(BARE_UNIT_RE)) {
    if (m.index! !== last) return segment;
    last = m.index! + m[0].length;
    letters += m[1];
    if (m[2] || m[3] || m[4]) {
      flush();
      out += primes(m[2]) + subscript(m[3]) + primes(m[4]);
    }
  }
  if (last !== segment.length) return segment;
  flush();
  return out;
}

const isKorean = (ch: string) => ch >= '가' && ch <= '힣';

/** 감싼 것을 벗기면 원문과 같은지 볼 때 쓰는 모습. 다르면 바꾸지 않는다. */
function skeleton(text: string): string {
  return primes(text)
    .replace(/\\(?:text|mathrm)\s*\{([A-Z]+)\}/g, '$1')
    .replace(/\$/g, '')
    .replace(/[₀-₉]+/g, (d) => subscript(d));
}

/**
 * 글 안의 점 이름·이름표 대문자를 곧은 글자로 감싼다. 바꿀 것이 없으면 원문을 그대로 돌려준다.
 * 곧게 찍는 곳:
 *  - 머리말이 붙은 이름: 점 A, 두 점 P, Q, 중심이 O, 수선의 발을 H, 선분 AB, 삼각형 ABC, 상자 A, A 지점, O는 원점
 *  - 명령 안의 이름 묶음: \overline{AB}, \overrightarrow{AB}, \angle ABC (글자가 둘 이상일 때)
 *  - 그 밖의 곳: 글자가 모두 [sets].upright 에 든 묶음(둘 이상), 그리고 글 속에 홀로 선 한 글자(앞뒤가 한글·쉼표·괄호,
 *    조건 번호 `(가)` 바로 뒤)
 * 그대로 두는 곳: 원 O, 구 S, 사건 A 처럼 기울여 찍는 이름, \sin A, A=2B 처럼 식 안에 홀로 선 글자, 이미 감싼 글자.
 */
export function uprightNames(text: unknown, sets: NameSets, mode: NameMode): string {
  const src = String(text ?? '');
  if (!/[A-Z]/.test(src)) return src;
  const math = mode === 'solution' ? mathMap(src) : null;
  if (mode === 'solution' && !math) return src;
  const a = analyze(src);
  const m = a.masked;
  const covered = (spans: Span[], start: number, end: number) => spans.some((s) => s.start <= start && end <= s.end);
  const lettersOf = (start: number, end: number) => lettersIn(m, a.uprightAt, start, end);
  const prevChar = (at: number) => {
    let k = at - 1;
    while (k >= 0 && m[k] === ' ') k -= 1;
    return k < 0 ? '' : m[k];
  };
  const nextChar = (at: number) => {
    let k = at;
    while (k < m.length && m[k] === ' ') k += 1;
    return k >= m.length ? '' : m[k];
  };
  /** 조건 번호 `(가)`, `(나)`, `(ㄱ)` 을 닫는 괄호 바로 뒤인지. 식 `f(x)`, `(x+1)` 을 닫는 괄호 뒤는 아니다. */
  const afterItemMarker = (at: number) => {
    let k = at - 1;
    while (k >= 0 && m[k] === ' ') k -= 1;
    return k >= 2 && m[k] === ')' && /[가-힣ㄱ-ㅎ]/.test(m[k - 1]) && m[k - 2] === '(';
  };
  /** 좌표 꼴 P(3, 0): 괄호 안 맨 바깥에 쉼표가 있다. */
  const coordinateAfter = (at: number) => {
    let k = at;
    while (k < m.length && m[k] === ' ') k += 1;
    if (m[k] !== '(') return false;
    let depth = 0;
    for (; k < m.length && m[k] !== '\n'; k += 1) {
      if (m[k] === '(') depth += 1;
      else if (m[k] === ')') {
        depth -= 1;
        if (depth === 0) return false;
      } else if (m[k] === ',' && depth === 1) return true;
    }
    return false;
  };

  const targets: Span[] = [];
  RUN_RE.lastIndex = 0;
  for (const run of m.matchAll(RUN_RE)) {
    const start = run.index!;
    const end = start + run[0].length;
    if (!/[A-Z]/.test(run[0])) continue;
    if (covered(a.uprightSpans, start, end)) {
      targets.push({ start, end });
      continue;
    }
    const before = start > 0 ? m[start - 1] : '';
    const after = end < m.length ? m[end] : '';
    // 다른 글자·숫자에 붙었거나 첨자 안에 든 대문자(kAB, 2B, Ax, A^C, x_{AB})는 이름으로 보지 않는다.
    const scripted = before === '_' || before === '^' || (before === '{' && (m[start - 2] === '_' || m[start - 2] === '^'));
    if (/[a-z0-9]/.test(before) || /[a-z]/.test(after) || scripted) continue;
    // 머리말이 묶음의 일부만 덮은 경우(사각뿔 A-BCDE 의 A)는 덮인 이름만 바꾼다.
    const partial = a.uprightSpans.filter((s) => start <= s.start && s.end <= end);
    if (partial.length > 0) {
      for (const s of partial) targets.push(s);
      continue;
    }
    if (a.italicSpans.some((s) => s.start < end && start < s.end)) continue;
    const letters = lettersOf(start, end);
    if (letters.length === 0 || ![...letters].every((c) => sets.upright.has(c))) continue;
    if (letters.length >= 2) {
      targets.push({ start, end });
      continue;
    }
    if (sets.italic.has(letters)) continue;
    const prev = prevChar(start);
    const next = nextChar(end);
    const prevOk = prev === '' || prev === '\n' || isKorean(prev) || ',(.]'.includes(prev) || afterItemMarker(start);
    const nextOk = next === '' || next === '\n' || isKorean(next) || ',).['.includes(next) || coordinateAfter(end);
    if (prevOk && nextOk) targets.push({ start, end });
  }
  if (targets.length === 0) return src;

  const command = mode === 'solution' ? 'mathrm' : 'text';
  targets.sort((x, y) => x.start - y.start);
  let out = '';
  let cursor = 0;
  for (const t of targets) {
    if (t.start < cursor) continue;
    // 묶음 안에서 감싸지 않은 조각만 바꾼다(이미 감싼 조각은 그대로).
    let piece = '';
    let done = t.start;
    for (const p of m.slice(t.start, t.end).matchAll(PIECE_RE)) {
      const from = t.start + p.index!;
      const to = from + p[0].length;
      piece += src.slice(done, from) + (p[2] ? wrapBare(src.slice(from, to), command) : src.slice(from, to));
      done = to;
    }
    piece += src.slice(done, t.end);
    if (piece === src.slice(t.start, t.end)) continue;
    let from = t.start;
    let to = t.end;
    if (math && !math[t.start]) {
      // 수식 밖의 이름은 $…$ 로 감싼다. 바로 옆에 수식이 붙어 있으면 그 수식에 잇는다($$ 를 만들지 않는다).
      const joinsPrev = src[from - 1] === '$' && src[from - 2] !== '$' && math[from - 1] && from - 1 >= cursor;
      const joinsNext = src[to] === '$' && src[to + 1] !== '$' && !math[to];
      if (joinsPrev) from -= 1;
      if (joinsNext) to += 1;
      piece = `${joinsPrev ? '' : '$'}${piece}${joinsNext ? '' : '$'}`;
    }
    out += src.slice(cursor, from) + piece;
    cursor = to;
  }
  out += src.slice(cursor);
  return skeleton(out) === skeleton(src) ? out : src;
}
