/** 시각 요소 표준 태그. 2단계 풀이와 메타 단계가 같은 목록을 쓴다. */
export const VISUAL_TAGS = [
  '수직선',
  '좌표평면',
  '일차함수(직선)',
  '이차함수(포물선)',
  '삼차·사차함수',
  '유리·무리함수',
  '지수·로그함수',
  '삼각함수',
  '각·평행선',
  '삼각형',
  '직각삼각형',
  '이등변·정삼각형',
  '사각형',
  '다각형',
  '원·부채꼴·접선',
  '합동·닮음',
  '입체도형·회전체',
  '전개도·겨냥도',
  '표(Table)',
  '조건상자(보기)',
  '통계그래프(히스토그램·상자그림)',
  '수형도·경로망',
];

/** 시각 요소가 없는 문항의 태그(사양 3번 추가 확정). 빈 태그는 누락이다. 다른 태그와 함께 두지 않는다. */
export const VISUAL_TAG_NONE = '없음';

/** 공백·중복을 지우고, '없음'이 다른 태그와 함께 오면 '없음'을 뺀다. */
export function normalizeVisualTags(raw: unknown): string[] {
  const tags = [
    ...new Set((Array.isArray(raw) ? raw : []).map((x) => String(x ?? '').trim()).filter((x) => x.length > 0)),
  ];
  return tags.some((t) => t !== VISUAL_TAG_NONE) ? tags.filter((t) => t !== VISUAL_TAG_NONE) : tags;
}
