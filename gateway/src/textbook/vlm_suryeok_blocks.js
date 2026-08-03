// 수력충전 답지·해설 지면의 "소단원 블록" 차례를 프롬프트용으로 정리한다.
//
// 답지와 해설은 소단원 블록이 줄줄이 이어지는데, 블록 머리("04 두 선분의 길이의
// 합의 최솟값 ▶p.16~17")는 블록이 **시작될 때 한 번만** 인쇄된다. 앞 지면에서
// 넘어온 부분은 배지 없이 번호부터 시작하므로, 배지로만 블록을 가리면 모델이
// 그 부분을 통째로 건너뛴다(공통수학2 중단원1 에서 166문항 중 37문항이 이렇게
// 비었다). 기대 문항 상세표는 책 차례대로 오므로, 블록 차례를 함께 알려 주면
// 모델이 "배지 없는 앞부분 = 바로 앞 블록" 을 스스로 짚을 수 있다.

/// 기대 문항 목록을 블록 단위로 묶는다.
///
/// 번호는 블록마다 01부터 다시 시작하므로, 코너가 바뀌거나 번호가 앞으로
/// 되돌아가면 새 블록이 시작된 것으로 본다.
export function groupSuryeokExpectedBlocks(expectedEntries) {
  const rows = (Array.isArray(expectedEntries) ? expectedEntries : []).filter(
    (e) => e && String(e.number || '').trim(),
  );
  const blocks = [];
  let current = null;
  let lastValue = 0;
  for (const row of rows) {
    const corner = String(row.corner || '').trim();
    const page = Number.parseInt(String(row.page ?? ''), 10);
    const number = String(row.number).trim();
    const value = Number.parseInt(number.replace(/\D/g, ''), 10);
    const startsBlock =
      !current ||
      current.corner !== corner ||
      !Number.isFinite(value) ||
      value <= lastValue;
    if (startsBlock) {
      current = {
        corner,
        pages: new Set(),
        numbers: [],
      };
      blocks.push(current);
    }
    if (Number.isFinite(page) && page > 0) current.pages.add(page);
    current.numbers.push(number);
    lastValue = Number.isFinite(value) ? value : lastValue;
  }
  return blocks.map((block) => {
    const pages = [...block.pages].sort((a, b) => a - b);
    return {
      corner: block.corner,
      pages,
      badge: pages.length
        ? pages.length === 1
          ? `p.${pages[0]}`
          : `p.${pages[0]}~${pages[pages.length - 1]}`
        : '',
      numbers: block.numbers,
    };
  });
}

/// 이미 다 읽은 블록은 건너뛰라고 못 박는다.
///
/// "빠른 정답" 한 쪽에는 소단원 블록이 여덟 개까지 들어가는데, 모델은 상세표가
/// 뒤쪽 블록만 가리켜도 지면 맨 위 블록부터 읽어 올린다(31줄을 물었더니 이미
/// 처리한 앞 네 블록만 돌려줬다). 앞 블록의 배지를 명시적으로 빼 주면 그제야
/// 뒤 블록을 읽는다.
export function buildSuryeokSkipBadgeLines(skipBadges) {
  const badges = (Array.isArray(skipBadges) ? skipBadges : [])
    .map((b) => String(b || '').trim())
    .filter(Boolean);
  if (!badges.length) return [];
  return [
    '',
    '=== 이미 처리한 블록 (건너뛸 것) ===',
    `아래 배지의 블록은 다른 호출에서 이미 다 읽었다: ${badges.join(', ')}`,
    '이 지면에 보이더라도 그 블록의 번호는 절대 items 에 담지 마라.',
    '지면 맨 위부터 읽지 말고, 위 배지 블록을 지나친 다음부터 읽어라.',
  ];
}

/// 블록 차례 + 배지 없는 이어짐 처리 규칙.
export function buildSuryeokBlockOrderLines(expectedEntries) {
  const blocks = groupSuryeokExpectedBlocks(expectedEntries);
  if (blocks.length < 2) return [];
  return [
    '',
    '=== 블록 차례 (배지가 안 보일 때 쓴다) ===',
    '아래는 상세표를 블록으로 묶어 책 차례대로 늘어놓은 것이다.',
    ...blocks.map((block, i) => {
      const corner = block.corner ? `블록="${block.corner}"` : '블록=일반 소단원';
      const badge = block.badge ? `배지=${block.badge}` : '배지=미상';
      const first = block.numbers[0];
      const last = block.numbers[block.numbers.length - 1];
      return `${i + 1}) ${corner} | ${badge} | 번호 ${first}~${last} (${block.numbers.length}개)`;
    }),
    '',
    '[C1] 블록 머리(배지)는 블록이 **시작될 때 한 번만** 인쇄된다. 지면 첫머리나',
    '   오른쪽 단 첫머리가 배지 없이 번호부터 시작하면, 그것은 앞 지면에서',
    '   넘어온 **이어지는 블록**이다. 배지가 안 보인다고 건너뛰지 마라.',
    '[C2] 이어지는 부분이 어느 블록인지는 위 차례로 짚는다. 그 뒤에 처음 나오는',
    '   배지가 차례의 k 번째이면, 배지 없는 앞부분은 k-1 번째 블록이다.',
    '   지면 전체에 배지가 하나도 없으면 전부 직전 블록의 이어짐이다.',
    '[C3] 이어지는 블록의 번호는 01 이 아니라 앞 지면에서 끊긴 다음 번호부터',
    '   시작한다. 같은 지면에 "09,10,11" 다음 새 배지와 "01" 이 오는 식이다.',
    '   앞부분 번호를 뒤 블록 것으로 붙이지 마라(정답이 통째로 어긋난다).',
  ];
}
