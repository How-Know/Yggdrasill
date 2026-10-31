// 개념+유형(개념플러스유형) 답지·해설 전용 검산 및 기대 문항 해석.
//
// 이 교재의 답지와 해설은 코너 박스 여러 개로 나뉘고, 박스 오른쪽 위에
// "P.8" 또는 "P.12~13" 같은 본문 페이지 배지가 붙는다. 코너마다, 그리고
// 소단원마다 번호가 1번부터 다시 시작하므로 같은 "1" 이 한 중단원 안에서
// 여러 번 등장한다. 실제로 1-1 교재 중단원 1에는 번호 "1" 인 문항이
// 필수 문제(소단원 2개)·쏙쏙(블록 2개)·탄탄까지 다섯 개 있었다.
//
// 그래서 이 모듈은 두 가지 일을 한다.
//
//   1. 기대 문항을 "번호키 → 후보 여러 개" 로 색인한다. 번호당 하나만
//      남기면 나머지 코너의 문항은 영원히 빈 칸으로 남는다.
//   2. 모델이 스스로 밝힌 출처(source_corner / source_page*)로 후보 하나를
//      특정한다. 특정되면 그 기대 항목의 위치(index)를 돌려주고, 어느 후보와도
//      맞지 않으면 버린다.
//
// 실제로 났던 사고: 필수 문제 1~5 를 찾던 모델이 옆에 있던 "쏙쏙 P.112"
// 박스의 1~5 답을 필수 문제 것인 양 올렸다. 틀린 정답이 조용히 저장되는 쪽이
// 비는 것보다 나쁘므로 출처가 어긋나면 버린다.
//
// 반대 방향 실수도 조심해야 한다. 배지는 "P.12~13" 처럼 여러 쪽을 덮기도
// 하는데, 이를 한 쪽으로만 비교하면 13쪽 문항이 통째로 버려진다. 그래서
// 페이지는 **범위 포함**으로 판정한다.

// 코너 이름 표기가 조금씩 흔들려도("STEP1 쏙쏙 개념 익히기" / "쏙쏙" /
// "STEP 1 쏙쏙") 같은 코너로 보기 위한 대표 키워드.
const CORNER_KEYWORDS = [
  ['concept_check', ['개념확인', '개념체크', '개념CHECK']],
  ['extra_practice', ['한번더', '한번더연습']],
  ['essential_problem', ['필수문제', '필수']],
  ['step_drill', ['쏙쏙']],
  ['unit_drill', ['탄탄']],
  ['descriptive', ['쓱쓱', '서술형']],
  // 수력충전. 소단원 블록에는 코너 이름이 없고 본문 페이지 배지만 있어서
  // 코너로 갈리는 것은 단원 마무리 평가 하나뿐이다.
  ['unit_review', ['단원마무리', '마무리평가']],
  // 고쟁이. 본문(A~D)은 세 자리 번호("054"), 워크북(E·F)은 묶음마다 01 부터
  // 다시 시작하는 두 자리다. 체계가 달라도 번호키는 앞자리 0 을 떼므로 본문
  // "005" 와 워크북 "05" 가 키 "5" 로 겹친다. 그래서 본문도 "본교재" 배지로
  // 갈라야 한다 — 한쪽만 코너를 두면 겹친 항목이 통째로 버려진다.
  ['body_book', ['본교재']],
  ['mid_unit_test', ['중단원TEST']],
  ['big_unit_test', ['대단원TEST']],
];

export function canonicalCorner(input) {
  // 라틴 문자 배지("중단원 TEST")의 대소문자 흔들림을 흡수한다. 한글은 영향 없다.
  const compact = String(input || '')
      .replace(/[\s·+]/g, '')
      .toUpperCase();
  if (!compact) return '';
  for (const [id, keywords] of CORNER_KEYWORDS) {
    for (const keyword of keywords) {
      if (compact.includes(keyword)) return id;
    }
  }
  // 개념+유형 고등 해설 박스 "문제 12~14쪽" / "연습문제 26~28쪽". "문제" 는 다른
  // 코너 이름에도 들어가므로 쪽 표기를 걷어 낸 뒤 이름 전체가 같을 때만 본다.
  const name = compact.replace(/[\d~\-.]|쪽|P/g, '');
  if (name === '문제') return 'high_problem';
  if (name.startsWith('연습문제')) return 'high_exercise';
  return '';
}

function parsePage(value) {
  const n = Number.parseInt(String(value ?? '').replace(/[^\d]/g, ''), 10);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/// 기대 문항 목록을 색인한다.
///
/// `byKey` 는 번호키 하나에 후보 배열을 담는다. `all` 은 순서를 지킨 전체
/// 목록이라 범위 배지("1~5")를 펼칠 때 쓴다. 후보의 `index` 는 호출자가 보낸
/// 배열에서의 위치이고, 이 값을 결과에 실어 보내면 앱이 번호가 아니라 위치로
/// 크롭을 찾을 수 있다.
export function buildExpectedIndex(expectedEntries, normalizeKey) {
  const byKey = new Map();
  const all = [];
  if (!Array.isArray(expectedEntries)) return { byKey, all };
  expectedEntries.forEach((entry, position) => {
    const number = String(entry?.number || '').trim();
    if (!number) return;
    const key = normalizeKey(number);
    if (!key) return;
    const page = Number(entry?.page);
    // 호출자가 원본 배열에서의 위치를 함께 보내면 그걸 쓴다. 게이트웨이는
    // 번호가 빈 항목을 걸러내므로, 여기서 다시 세면 앱이 보낸 배열과 위치가
    // 어긋나 엉뚱한 크롭에 정답이 붙는다.
    const declared = Number(entry?.position);
    const candidate = {
      index: Number.isInteger(declared) && declared >= 0 ? declared : position,
      number,
      key,
      corner: canonicalCorner(entry?.corner),
      page: Number.isFinite(page) && page > 0 ? page : 0,
      // 앱이 "같은 번호·코너 중 해설 차례상 다음에 나올 문항" 으로 짚은 항목.
      frontier: entry?.frontier === true,
    };
    all.push(candidate);
    const keys = new Set([key]);
    // 쏙쏙은 앱에서 블록 충돌 방지를 위해 "11-1"처럼 본문 페이지를 번호
    // 앞에 붙인다. 답지에는 P.11 배지 아래 "1"로 인쇄되므로, 기대 항목의
    // page와 접두어가 같을 때만 로컬 번호 "1"도 별칭으로 색인한다.
    const pagePrefix = number.match(/^(\d+)-(.+)$/);
    if (candidate.page && Number(pagePrefix?.[1]) === candidate.page) {
      const localKey = normalizeKey(pagePrefix[2]);
      if (localKey) keys.add(localKey);
    }
    for (const indexedKey of keys) {
      const bucket = byKey.get(indexedKey);
      if (bucket) bucket.push(candidate);
      else byKey.set(indexedKey, [candidate]);
    }
  });
  return { byKey, all };
}

/// 모델이 결과에 적어 보낸 출처를 코너·페이지 범위로 정리한다.
export function reportedBadge(raw) {
  const corner = canonicalCorner(raw?.source_corner ?? raw?.sourceCorner);
  const from = parsePage(raw?.source_page ?? raw?.sourcePage);
  // 끝 쪽을 안 주면 단일 쪽 배지로 본다.
  const to = from ? parsePage(raw?.source_page_end ?? raw?.sourcePageEnd) || from : 0;
  return {
    corner,
    lo: Math.min(from, to),
    hi: Math.max(from, to),
  };
}

/// 모델이 스스로 밝힌 출처 배지 중 기대 묶음과 **아예 겹치지 않는** 것들을
/// "건너뛸 묶음" 라벨로 만든다.
///
/// 고쟁이 워크북 답지는 한 지면에 "중단원 TEST" 묶음이 일곱 개까지 서고 쪽
/// 배지(174~177 / 178~181 / 182~185)가 서로 붙어 있다. 실지면 2-2 답지 6쪽에서
/// 모델은 절반쯤 옆 묶음을 골랐고(178~181 을 찾다가 182~185 의 24개를 올림),
/// 출처 대조가 그것을 전부 버려 0건이 되었다. 이 라벨을 되먹여 같은 지면을
/// 다시 물으면 모델이 그 묶음을 비켜 간다.
///
/// 기대 쪽을 하나라도 덮는 배지는 고르지 않는다. 묶음은 제대로 읽고 쪽만 한 칸
/// 잘못 옮긴 경우까지 건너뛰게 하면 정답을 영원히 못 찾는다.
export function wrongBadgeLabels(parsedJson, expectedEntries) {
  const items = Array.isArray(parsedJson?.items) ? parsedJson.items : [];
  if (items.length === 0) return [];
  const expectedPages = new Set(
    (Array.isArray(expectedEntries) ? expectedEntries : [])
      .map((entry) => parsePage(entry?.page))
      .filter((page) => page > 0),
  );
  if (expectedPages.size === 0) return [];
  const labels = new Set();
  for (const item of items) {
    const badge = reportedBadge(item);
    if (!badge.lo) continue;
    let overlaps = false;
    for (let page = badge.lo; page <= badge.hi; page += 1) {
      if (expectedPages.has(page)) {
        overlaps = true;
        break;
      }
    }
    if (overlaps) continue;
    const printed = String(item?.source_corner ?? item?.sourceCorner ?? '')
      .trim();
    const span =
      badge.hi > badge.lo ? `${badge.lo}~${badge.hi}쪽` : `${badge.lo}쪽`;
    labels.add(printed ? `${printed} ${span}` : span);
  }
  return Array.from(labels).slice(0, 6);
}

/// 후보가 모델이 밝힌 박스와 모순되지 않는지.
///
/// 양쪽 모두 값이 있을 때만 판정한다. 한쪽이라도 비어 있으면 "모른다"이므로
/// 모순으로 보지 않는다.
export function candidateFitsBadge(candidate, badge) {
  if (candidate.corner && badge.corner && candidate.corner !== badge.corner) {
    return false;
  }
  if (
    candidate.page &&
    badge.lo &&
    (candidate.page < badge.lo || candidate.page > badge.hi)
  ) {
    return false;
  }
  return true;
}

/// 결과 항목 하나를 기대 문항 후보 하나로 특정한다.
///
/// 반환값
///   `{ matched: 후보, reject: false }` — 후보를 특정했다.
///   `{ matched: null,  reject: true  }` — 출처가 어느 후보와도 맞지 않는다.
///   `{ matched: null,  reject: false }` — 판정 근거가 없다. 그대로 통과시키고
///     번호 기반 매칭에 맡긴다(코너 정보가 없는 쎈·RPM 이 이 경로다).
export function resolveExpectedBox(raw, problemNumber, expectedIndex, normalizeKey) {
  const undecided = { matched: null, reject: false };
  if (!expectedIndex || expectedIndex.byKey.size === 0) return undecided;
  const candidates = expectedIndex.byKey.get(normalizeKey(problemNumber));
  if (!candidates || candidates.length === 0) return undecided;

  const badge = reportedBadge(raw);
  const fits = [];
  for (const candidate of candidates) {
    if (!candidateFitsBadge(candidate, badge)) continue;
    // 코너와 배지가 모두 확인된 후보를 우선한다.
    const score =
      (candidate.corner && badge.corner ? 2 : 0) +
      (candidate.page && badge.lo ? 1 : 0);
    fits.push({ candidate, score });
  }
  if (fits.length === 0) return { matched: null, reject: true };
  fits.sort((a, b) => b.score - a.score || a.candidate.index - b.candidate.index);
  const best = fits[0];
  // 개념+유형 고등 해설은 소단원마다 "02-1" 이 다시 나오고, 머리 없는 이어지는
  // 지면에서는 배지로 가를 수 없다. 해설은 본문 차례대로 인쇄되므로 앱이 짚은
  // 차례상 다음 후보가 하나뿐이면 그것으로 정한다.
  const tied = fits.filter((fit) => fit.score === best.score);
  if (tied.length > 1) {
    const frontier = tied.filter((fit) => fit.candidate.frontier);
    if (frontier.length === 1) {
      return { matched: frontier[0].candidate, reject: false };
    }
  }
  // 후보가 여럿인데 모델이 출처를 안 적었으면 찍지 않는다. 잘못 연결하면
  // 다른 코너의 정답이 조용히 들어앉는다.
  if (best.score === 0 && fits.length > 1) return undecided;
  return { matched: best.candidate, reject: false };
}

/// 같은 코너에 같은 번호 후보가 여럿이면 배지 쪽을 보지 않고 본문 차례대로 붙인다.
///
/// 개념+유형 고등 해설은 소단원마다 "02-1" 이 다시 나오고, 머리 없는 이어지는
/// 지면에서 모델은 쪽 배지를 지어 적는다(해설 71쪽 02-1~03-3 을 167쪽이 아니라
/// "문제 180쪽" 으로 적어 다음 소단원 문항에 붙음). 앱은 아직 못 찾은 문항만
/// 해설 차례상 이 지면에 올 수 있는 것으로 좁혀 보내므로, 한 응답 안에서 같은
/// 묶음의 번호는 남은 후보의 본문 차례대로 짝짓는다. 63쪽처럼 "개념 Check 150쪽"
/// 과 "152쪽" 의 1 이 한 지면에 같이 있으면 첫째·둘째 후보로 갈린다.
///
/// [state] 는 한 응답 동안 유지한다. [signature] 가 같은 항목이 두 번 오면 같은
/// 문항을 되풀이한 것이므로 다음 후보로 넘기지 않는다.
/// 반환값이 null 이면 이 규칙을 쓸 수 없으니 [resolveExpectedBox] 로 넘긴다.
export function resolveSequentialBox(
  raw,
  problemNumber,
  expectedIndex,
  normalizeKey,
  state,
  signature = '',
) {
  if (!expectedIndex || expectedIndex.byKey.size === 0) return null;
  const key = normalizeKey(problemNumber);
  const candidates = expectedIndex.byKey.get(key) || [];
  const badge = reportedBadge(raw);
  const group = badge.corner
    ? candidates.filter((candidate) => candidate.corner === badge.corner)
    : candidates;
  if (group.length < 2) return null;
  const corners = new Set(group.map((candidate) => candidate.corner));
  if (corners.size > 1 || !group[0].corner) return null;
  const groupKey = `${group[0].corner}|${key}`;
  const seen = state.signatures.get(groupKey) || new Set();
  if (signature && seen.has(signature)) return { matched: null, reject: true };
  const ordered = [...group].sort(
    (a, b) => a.page - b.page || a.index - b.index,
  );
  const next = ordered.find((candidate) => !state.claimed.has(candidate.index));
  if (!next) return { matched: null, reject: true };
  state.claimed.add(next.index);
  if (signature) {
    seen.add(signature);
    state.signatures.set(groupKey, seen);
  }
  return { matched: next, reject: false };
}

export function createSequentialState() {
  return { claimed: new Set(), signatures: new Map() };
}

// 묶음 배지는 묶음이 시작되는 지면에만 인쇄된다. 이어지는 지면에서 모델은 적을
// 배지가 없어 꼬리말에 찍힌 **해설 쪽번호**("중단원 TEST 163")를 출처로 올린다.
// 그 번호는 본교재·워크북 쪽 번호와 체계가 달라, 출처 대조가 기대 문항을 하나도
// 못 맞추고 전부 버린다. 실지면 2-2 해설 163쪽에서 12~19 여덟 건이 이렇게 통째로
// 사라졌다(모델은 여덟 건 다 정확히 찾아 놓고 있었다). 개념+유형 고등 해설
// 71쪽에서도 "개념편 71" 을 출처로 적어 02-1~03-3 다섯 건이 버려졌다. 요청한
// 그 지면 번호와 같은 값은 배지가 아니므로 쪽 단서를 지우고 코너·번호로만 대조한다.
export function footerEchoPages(opts) {
  const pages = new Set();
  for (const value of [opts?.rawPage, opts?.displayPage]) {
    const page = Number.parseInt(String(value ?? ''), 10);
    if (Number.isFinite(page) && page > 0) pages.add(page);
  }
  return pages;
}

export function stripFooterEchoBadge(raw, footerPages) {
  if (footerPages.size === 0) return raw;
  const from = Number.parseInt(
    String(raw.source_page ?? raw.sourcePage ?? ''),
    10,
  );
  if (!Number.isFinite(from) || !footerPages.has(from)) return raw;
  // 진짜 범위 배지("본교재 141~142쪽")는 끝 쪽이 지면 번호와 다르다.
  const to = Number.parseInt(
    String(raw.source_page_end ?? raw.sourcePageEnd ?? ''),
    10,
  );
  if (Number.isFinite(to) && to > 0 && !footerPages.has(to)) return raw;
  return withoutBadgePage(raw);
}

function withoutBadgePage(raw) {
  const out = { ...raw };
  delete out.source_page;
  delete out.sourcePage;
  delete out.source_page_end;
  delete out.sourcePageEnd;
  return out;
}

// 개념+유형 고등 해설에서 머리 없이 이어지는 박스의 문항에 모델이 같은 지면
// 아래쪽의 다음 박스 머리 쪽을 붙인다(해설 103쪽: 본문 238쪽 03-1 에 다음
// 박스 "문제 240쪽" 을 적음). 앱이 차례상 보낸 같은 번호 후보가 하나뿐이고
// 코너가 같으며 보고 쪽이 그 후보보다 몇 쪽 뒤일 때만 쪽 단서를 버린다.
// 같은 번호는 소단원마다 10쪽 남짓 간격으로 다시 나오므로 그보다 좁게 둔다.
const NEXT_BOX_BADGE_MAX_GAP = 3;

export function stripNextBoxBadge(raw, problemNumber, expectedIndex, normalizeKey) {
  const candidates = expectedIndex?.byKey?.get(normalizeKey(problemNumber));
  if (!Array.isArray(candidates) || candidates.length !== 1) return raw;
  const candidate = candidates[0];
  const badge = reportedBadge(raw);
  if (!badge.lo || !candidate.page) return raw;
  if (candidate.corner && badge.corner && candidate.corner !== badge.corner) {
    return raw;
  }
  const gap = badge.lo - candidate.page;
  if (gap < 1 || gap > NEXT_BOX_BADGE_MAX_GAP) return raw;
  return withoutBadgePage(raw);
}

/// 범위 배지("1~5")를 기대 문항 하나하나로 펼친다.
///
/// 코너를 함께 확인하므로 필수 문제의 "1~5" 가 옆 박스 쏙쏙의 1~5 로
/// 번지지 않는다.
export function expandBadgeRange(range, expectedIndex, raw) {
  if (!range || !expectedIndex || expectedIndex.all.length === 0) return [];
  const badge = reportedBadge(raw);
  const out = [];
  for (const candidate of expectedIndex.all) {
    if (!/^\d+$/.test(candidate.number.trim())) continue;
    const n = Number(candidate.number.trim());
    if (!Number.isFinite(n) || n < range.from || n > range.to) continue;
    if (!candidateFitsBadge(candidate, badge)) continue;
    out.push(candidate);
  }
  return out;
}
