// 수력충전 "빠른 정답" 은 지면을 두 단으로 쓴다. 한 지면에 소단원 여덟 개,
// 정답 190개가 들어차면 모델이 **한 단을 통째로 건너뛴 채** 멀쩡히 끝내 버린다
// (finishReason=STOP). 3-1 답지 1쪽을 같은 렌더러로 크기만 바꿔 재 본 결과가
// 2200px→왼쪽 단 누락, 2268px→정상, 2400px→왼쪽 단 누락 이었다. 크기나 화질의
// 문제가 아니라 어느 이미지에서 걸리느냐의 문제라, 해상도를 올려도 운에 맡기는
// 꼴이 된다. 그래서 한 단만 읽고 온 게 보이면 나머지 단을 잘라 따로 물어본다.

/// 정답 좌표는 [ymin, xmin, ymax, xmax] 를 0~1000 으로 정규화해 온다.
export const ANSWER_LAYOUT_COLUMN_SPLIT = 500;

/// 읽어 온 요소가 한쪽 단에만 몰려 있으면 비어 있는 쪽('left'|'right')을,
/// 두 단에 걸쳐 있으면 빈 문자열을 돌려준다.
///
/// 요소가 두어 개뿐인 지면(답지 마지막 쪽 등)은 원래 한 단만 쓰는 일이 흔해
/// 판단하지 않는다. 괜히 다시 물으면 빈 단을 훑느라 1분을 버린다.
export function answerLayoutMissingHalf(
  entries,
  { split = ANSWER_LAYOUT_COLUMN_SPLIT, minEntries = 5 } = {},
) {
  const boxes = (entries ?? [])
    .map((entry) => entry?.bbox)
    .filter((bbox) => Array.isArray(bbox) && bbox.length === 4);
  if (boxes.length < minEntries) return '';
  const hasLeft = boxes.some((bbox) => bbox[1] < split);
  const hasRight = boxes.some((bbox) => bbox[3] > split);
  if (hasLeft === hasRight) return '';
  return hasLeft ? 'right' : 'left';
}

/// 반쪽 이미지에서 읽은 좌표를 지면 전체 기준으로 되돌린다.
export function remapAnswerLayoutHalf(
  entries,
  half,
  { split = ANSWER_LAYOUT_COLUMN_SPLIT } = {},
) {
  const scale = (half === 'left' ? split : 1000 - split) / 1000;
  const offset = half === 'left' ? 0 : split;
  const toFull = (x) =>
    Math.max(0, Math.min(1000, Math.round(offset + x * scale)));
  return (entries ?? []).map((entry) => {
    const bbox = entry?.bbox;
    if (!Array.isArray(bbox) || bbox.length !== 4) return entry;
    return { ...entry, bbox: [bbox[0], toFull(bbox[1]), bbox[2], toFull(bbox[3])] };
  });
}

/// 이미 읽은 요소와 다시 읽은 반쪽을 합친다. 왼쪽을 되찾았으면 앞에 붙는다.
///
/// 번호로 겹침을 걸러서는 안 된다. 소단원이 바뀔 때마다 번호가 01 부터 다시
/// 시작해, 왼쪽 단의 01~35 가 오른쪽 단의 01~27 과 죄다 부딪힌다. 애초에 두
/// 반쪽은 서로 겹치지 않는 지면이라 같은 정답이 양쪽에 나올 일이 없다.
export function mergeAnswerLayoutHalf(entries, repaired, half) {
  const fresh = repaired ?? [];
  if (fresh.length === 0) return entries ?? [];
  return half === 'left'
    ? [...fresh, ...(entries ?? [])]
    : [...(entries ?? []), ...fresh];
}
