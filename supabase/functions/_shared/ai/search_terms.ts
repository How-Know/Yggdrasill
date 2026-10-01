// 한국어 질문에서 기억 검색용 단어를 뽑는다. 형태소 분석 없이 흔한 조사만 떼어 낸다.

const PARTICLES = [
  '으로써', '으로서', '에게서', '에서는', '에서도', '이라는', '이라고', '에서', '에게', '한테', '으로',
  '까지', '부터', '처럼', '보다', '하고', '이나', '이랑', '라는', '라고', '랑', '은', '는', '이', '가',
  '을', '를', '의', '에', '로', '와', '과', '도', '만', '요',
];

const STOPWORDS = new Set([
  '그리고', '그런데', '하지만', '그래서', '어떻게', '무엇', '뭐야', '뭔가', '이거', '저거', '그거', '우리',
  '지금', '정도', '관련', '대해', '대한', '있는', '없는', '하는', '해줘', '해주세요', '같은', '이런',
  '저런', '그런', '어떤', '생각', '정리', '알려줘', '말해줘', '어때', '있어', '없어', '할까', '하면',
]);

export function extractSearchTerms(text: string, max = 8): string[] {
  const tokens = text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .split(/\s+/)
    .filter(Boolean);
  const out: string[] = [];
  const seen = new Set<string>();
  for (const token of tokens) {
    let t = token;
    for (const p of PARTICLES) {
      if (t.length > p.length + 1 && t.endsWith(p)) {
        t = t.slice(0, -p.length);
        break;
      }
    }
    if (t.length < 2 || STOPWORDS.has(t) || seen.has(t)) continue;
    seen.add(t);
    out.push(t);
    if (out.length >= max) break;
  }
  return out;
}
