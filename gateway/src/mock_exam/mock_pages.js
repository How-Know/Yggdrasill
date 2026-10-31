// 모의고사 문제지·해설 지면 판독: 프롬프트, 응답 정규화, 해설 구간 배정.
//
// 좌표는 교재 크롭과 같은 [ymin, xmin, ymax, xmax] (0~1000) 이다.

export const ELECTIVES = ['probstats', 'calculus', 'geometry'];
export const SECTIONS = ['common', ...ELECTIVES];

export const SECTION_LABELS = {
  common: '공통',
  probstats: '확률과 통계',
  calculus: '미적분',
  geometry: '기하',
};

// 고3 공통은 1~22, 선택은 23~30. 고1·고2 는 1~30 이 모두 공통이다.
export const GRADE3_COMMON_LAST = 22;
export const ITEM_COUNT = 30;

export function sectionFromLabel(label) {
  const text = String(label || '').replace(/\s+/g, '');
  if (!text) return '';
  if (/확률|통계|확통/.test(text)) return 'probstats';
  if (/미적/.test(text)) return 'calculus';
  if (/기하/.test(text)) return 'geometry';
  if (/공통|수학Ⅰ|수학I|수학Ⅱ|수학II/.test(text)) return 'common';
  return '';
}

/// 학년·번호·지면 선택과목으로 문항이 속한 구간을 정한다.
export function sectionForNumber(grade, number, elective) {
  if (Number(grade) !== 3) return 'common';
  if (number <= GRADE3_COMMON_LAST) return 'common';
  return ELECTIVES.includes(elective) ? elective : '';
}

export function expectedNumbers(grade, section) {
  if (Number(grade) !== 3) {
    return section === 'common' ? range(1, ITEM_COUNT) : [];
  }
  return section === 'common'
    ? range(1, GRADE3_COMMON_LAST)
    : range(GRADE3_COMMON_LAST + 1, ITEM_COUNT);
}

function range(from, to) {
  const out = [];
  for (let n = from; n <= to; n += 1) out.push(n);
  return out;
}

export function parseRegion(raw) {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const values = raw.map((v) => Math.round(Number(v)));
  if (values.some((v) => !Number.isFinite(v))) return null;
  const [y1, x1, y2, x2] = values.map((v) => Math.min(1000, Math.max(0, v)));
  if (y2 - y1 < 5 || x2 - x1 < 5) return null;
  return [y1, x1, y2, x2];
}

function parseNumber(raw) {
  const match = String(raw ?? '').match(/\d{1,2}/);
  if (!match) return null;
  const n = Number.parseInt(match[0], 10);
  return n >= 1 && n <= 60 ? n : null;
}

const CIRCLED = ['①', '②', '③', '④', '⑤'];

/// 객관식은 원문자, 단답형은 정수 문자열로 맞춘다.
export function normalizeAnswer(raw) {
  const text = String(raw ?? '').replace(/\s+/g, '').trim();
  if (!text) return null;
  const circled = CIRCLED.find((c) => text.includes(c));
  if (circled) return { kind: 'objective', text: circled };
  const paren = text.match(/^\(?([1-5])\)$/);
  if (paren) return { kind: 'objective', text: CIRCLED[Number(paren[1]) - 1] };
  const number = text.match(/^-?\d{1,4}$/);
  if (number) return { kind: 'subjective', text: number[0] };
  return { kind: 'subjective', text };
}

export function buildProblemPagePrompt({ grade, page }) {
  return [
    '이 이미지는 한국 고등학교 수학 모의고사(교육청 학력평가·평가원 모의평가·수능) 문제지의 한 쪽이다.',
    `학년: 고${grade}. 쪽: ${page}.`,
    '지면은 보통 좌우 2단이다. 이 쪽에 인쇄된 문항을 모두 찾아라.',
    '',
    '규칙',
    '- number: 문항 번호(정수). "1." "23." 처럼 인쇄된 번호다.',
    '- region: 그 문항 하나를 감싸는 사각형 [ymin, xmin, ymax, xmax], 0~1000 좌표.',
    '  번호부터 발문·조건 상자·그림·표·선택지(①~⑤)까지 모두 넣는다.',
    '  아래쪽 끝은 그 문항의 마지막 인쇄 줄(보통 선택지 줄, 단답형은 발문 끝) 바로 아래다.',
    '  문항 아래 풀이용 빈 여백은 넣지 않는다. 다른 단이나 다른 문항을 넣지 않는다.',
    '- 머리글(시험 이름, 교시, "홀수형"), "5지선다형"·"단답형" 같은 구간 이름, 쪽 번호,',
    '  저작권 문구는 문항이 아니다.',
    '- page_title: 지면 맨 위 과목 제목을 그대로 적는다(예: "수학 영역", "수학 영역(확률과 통계)").',
    '- 문항이 없는 쪽(표지, 안내문)이면 items 를 빈 배열로 둔다.',
    '',
    'JSON 만 출력한다.',
    '{"page_title": "...", "items": [{"number": 1, "region": [ymin, xmin, ymax, xmax]}]}',
  ].join('\n');
}

export function normalizeProblemPage(parsed) {
  const out = { pageTitle: '', elective: '', items: [] };
  if (!parsed || typeof parsed !== 'object') return out;
  out.pageTitle = String(parsed.page_title ?? '').trim();
  const titleSection = sectionFromLabel(out.pageTitle.replace(/수학\s*영역/g, ''));
  out.elective = ELECTIVES.includes(titleSection) ? titleSection : '';
  const seen = new Set();
  for (const raw of Array.isArray(parsed.items) ? parsed.items : []) {
    const number = parseNumber(raw?.number);
    const region = parseRegion(raw?.region);
    if (!number || !region || seen.has(number)) continue;
    seen.add(number);
    out.items.push({ number, region });
  }
  out.items.sort((a, b) => a.number - b.number);
  return out;
}

export function buildSolutionPagePrompt({ grade, page }) {
  return [
    '이 이미지는 한국 고등학교 수학 모의고사 "정답 및 해설(풀이)" 지면의 한 쪽이다.',
    `학년: 고${grade}. 쪽: ${page}.`,
    '지면은 보통 좌우 2단이다. 세 가지를 찾아라.',
    '',
    '1) answer_tables: 빠른 정답 상자. "01. ⑤ 02. ④ … 16. 7" 처럼 번호와 정답이 나열된 상자다.',
    '   - label: 상자 머리에 적힌 구간 이름을 그대로 적는다(예: "[공통: 수학Ⅰ·수학Ⅱ]", "[선택: 확률과 통계]").',
    '     머리가 없으면 빈 문자열.',
    '   - region: 상자 전체 [ymin, xmin, ymax, xmax].',
    '   - entries: 상자 안의 모든 번호와 정답. 객관식은 원문자(①~⑤), 단답형은 인쇄된 수 그대로.',
    '2) section_headers: 해설 본문 중간에 새 구간이 시작됨을 알리는 머리(예: "■ [선택: 미적분]",',
    '   "확률과 통계" 큰 제목). 정답 상자 머리는 여기에 다시 적지 않는다.',
    '   - label, region.',
    '3) blocks: 문항별 해설 시작점. 보통 "12. 출제의도 :" 처럼 번호로 시작한다.',
    '   - number: 해설 번호(정수).',
    '   - number_region: 번호 글자만 감싸는 작은 사각형.',
    '   - content_region: 그 번호부터 같은 단에서 다음 해설 번호 바로 위(또는 단의 끝)까지.',
    '     해설이 다음 단이나 다음 쪽으로 이어져도 이 쪽 이 단에 있는 부분만 넣는다.',
    '   - 단 맨 위에서 번호 없이 앞 해설이 이어지는 부분은 블록이 아니다.',
    '- 머리글·꼬리말·쪽 번호·출판사 로고는 무시한다.',
    '',
    'JSON 만 출력한다.',
    '{"answer_tables": [{"label": "", "region": [0,0,0,0], "entries": [{"number": 1, "answer": "⑤"}]}],',
    ' "section_headers": [{"label": "", "region": [0,0,0,0]}],',
    ' "blocks": [{"number": 1, "number_region": [0,0,0,0], "content_region": [0,0,0,0]}]}',
  ].join('\n');
}

export function normalizeSolutionPage(parsed) {
  const out = { answerTables: [], headers: [], blocks: [] };
  if (!parsed || typeof parsed !== 'object') return out;
  for (const raw of arrayOf(parsed.answer_tables)) {
    const entries = [];
    for (const entry of arrayOf(raw?.entries)) {
      const number = parseNumber(entry?.number);
      const answer = normalizeAnswer(entry?.answer);
      if (!number || !answer) continue;
      entries.push({ number, ...answer });
    }
    if (entries.length === 0) continue;
    out.answerTables.push({
      label: String(raw?.label ?? '').trim(),
      region: parseRegion(raw?.region),
      entries,
    });
  }
  for (const raw of arrayOf(parsed.section_headers)) {
    const label = String(raw?.label ?? '').trim();
    const region = parseRegion(raw?.region);
    if (!sectionFromLabel(label) || !region) continue;
    out.headers.push({ label, region });
  }
  for (const raw of arrayOf(parsed.blocks)) {
    const number = parseNumber(raw?.number);
    const numberRegion = parseRegion(raw?.number_region);
    if (!number || !numberRegion) continue;
    out.blocks.push({
      number,
      numberRegion,
      contentRegion: parseRegion(raw?.content_region),
    });
  }
  return out;
}

function arrayOf(value) {
  return Array.isArray(value) ? value : [];
}

function columnOf(region) {
  if (!region) return 0;
  return (region[1] + region[3]) / 2 < 500 ? 0 : 1;
}

/// 해설 지면들을 읽는 차례(왼쪽 단 위→아래, 오른쪽 단 위→아래, 다음 쪽)로
/// 훑으며 각 정답·해설을 구간에 배정한다.
///
/// [pages] 는 `{ page, result }` 목록(result 는 normalizeSolutionPage 결과)이다.
/// 고3 은 번호 22 이하를 공통으로 두고, 23 이상은 마지막으로 본 선택과목 머리나
/// 정답 상자의 구간을 따른다. 머리를 못 봤으면 [paperElective] 로 둔다. 해설에
/// 세 선택과목이 모두 실린 지면도 머리마다 구간이 바뀌므로 셋 다 채워진다.
///
/// 같은 구간·번호가 다시 나오면 처음 것만 남긴다.
export function assignSolutionSections({ grade, paperElective = '', pages }) {
  const answers = new Map();
  const solutions = new Map();
  let currentElective = '';
  const keyOf = (section, number) => `${section}|${number}`;
  const resolve = (number, labelSection) => {
    if (Number(grade) !== 3) return 'common';
    if (number <= GRADE3_COMMON_LAST) return 'common';
    if (ELECTIVES.includes(labelSection)) return labelSection;
    return currentElective || (ELECTIVES.includes(paperElective) ? paperElective : '');
  };

  for (const { page, result } of pages || []) {
    if (!result) continue;
    const events = [];
    for (const table of result.answerTables || []) {
      events.push({ kind: 'table', region: table.region, table });
    }
    for (const header of result.headers || []) {
      events.push({ kind: 'header', region: header.region, header });
    }
    for (const block of result.blocks || []) {
      events.push({ kind: 'block', region: block.numberRegion, block });
    }
    events.sort((a, b) => {
      const col = columnOf(a.region) - columnOf(b.region);
      if (col !== 0) return col;
      return (a.region?.[0] ?? 0) - (b.region?.[0] ?? 0);
    });
    for (const event of events) {
      if (event.kind === 'header') {
        const section = sectionFromLabel(event.header.label);
        if (ELECTIVES.includes(section)) currentElective = section;
        continue;
      }
      if (event.kind === 'table') {
        const labelSection = sectionFromLabel(event.table.label);
        if (ELECTIVES.includes(labelSection)) currentElective = labelSection;
        for (const entry of event.table.entries) {
          const section = resolve(entry.number, labelSection);
          if (!section) continue;
          const key = keyOf(section, entry.number);
          if (answers.has(key)) continue;
          answers.set(key, {
            section,
            number: entry.number,
            kind: entry.kind,
            text: entry.text,
            page,
            region: event.table.region,
          });
        }
        continue;
      }
      const { block } = event;
      const section = resolve(block.number, '');
      if (!section) continue;
      const key = keyOf(section, block.number);
      if (solutions.has(key)) continue;
      solutions.set(key, {
        section,
        number: block.number,
        page,
        numberRegion: block.numberRegion,
        contentRegion: block.contentRegion,
      });
    }
  }
  return { answers, solutions };
}

/// 문제지 판독 결과를 구간별 문항으로 모은다.
///
/// 고3 공통은 첫 문제지에서만 받는다. 나머지 문제지는 선택 문항만 낸다.
export function assignProblemItems({ grade, paperElective, pages, takeCommon }) {
  const out = [];
  for (const { page, result } of pages || []) {
    if (!result) continue;
    const elective = paperElective || result.elective;
    for (const item of result.items) {
      const section = sectionForNumber(grade, item.number, elective);
      if (!section) continue;
      if (section === 'common' && !takeCommon) continue;
      out.push({ section, number: item.number, page, region: item.region });
    }
  }
  const seen = new Set();
  return out.filter((item) => {
    const key = `${item.section}|${item.number}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/// 해설 PDF 텍스트에서 선택과목 해설이 시작하는 쪽을 찾는다(1부터).
/// 텍스트 층이 없거나 못 찾으면 null.
export function electiveStartPageFromText(pageTexts, elective) {
  const label = SECTION_LABELS[elective];
  if (!label) return null;
  const pattern = new RegExp(`선택\\s*[:：]?\\s*${label.replace(/\s+/g, '\\s*')}`);
  for (let i = 0; i < (pageTexts || []).length; i += 1) {
    if (pattern.test(pageTexts[i] || '')) return i + 1;
  }
  return null;
}
