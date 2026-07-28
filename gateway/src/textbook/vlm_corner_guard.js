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
  ['concept_check', ['개념확인', '개념체크']],
  ['extra_practice', ['한번더', '한번더연습']],
  ['essential_problem', ['필수문제', '필수']],
  ['step_drill', ['쏙쏙']],
  ['unit_drill', ['탄탄']],
  ['descriptive', ['쓱쓱', '서술형']],
];

export function canonicalCorner(input) {
  const compact = String(input || '').replace(/[\s·+]/g, '');
  if (!compact) return '';
  for (const [id, keywords] of CORNER_KEYWORDS) {
    for (const keyword of keywords) {
      if (compact.includes(keyword)) return id;
    }
  }
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
    };
    all.push(candidate);
    const bucket = byKey.get(key);
    if (bucket) bucket.push(candidate);
    else byKey.set(key, [candidate]);
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
  // 후보가 여럿인데 모델이 출처를 안 적었으면 찍지 않는다. 잘못 연결하면
  // 다른 코너의 정답이 조용히 들어앉는다.
  if (best.score === 0 && fits.length > 1) return undecided;
  return { matched: best.candidate, reject: false };
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
