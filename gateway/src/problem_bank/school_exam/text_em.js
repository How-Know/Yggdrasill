// 시험지 본문 글자 크기(em1k = 한 글자 폭 ÷ 쪽 폭 × 1000)를 PDF 글자 층에서 잰다.
// 그림 폭(em)은 "그림 상자 폭(0..1000) ÷ em1k" 로 정하므로, 이 값이 맞아야 그림이 원본과 같은 비율로 나온다.

// 글자 층이 없거나(스캔본) 표본이 모자랄 때 쓰는 값. 내신 시험지 8개(2023~2025, 중·고)를 재면 모두 14.4~14.5 다
// (B4 728pt 폭에 10.5pt 본문).
export const EXAM_TEXT_EM_1K_FALLBACK = 14.45;
const EM_1K_MIN = 8;
const EM_1K_MAX = 26;
const MIN_SAMPLE_SYLLABLES = 120;

const HANGUL_WORD_RE = /^[가-힣]{3,}$/;

function median(sorted) {
  if (sorted.length === 0) return null;
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// pages: readWordBoxes 결과. 한글만으로 된 3음절 이상 낱말의 (폭 ÷ 음절 수)를 음절 수만큼 세어 중앙값을 낸다.
/// 본문 글자가 지면 대부분이므로 제목·각주 글자는 중앙값에 영향을 주지 않는다.
export function measureTextEm1k(pages) {
  const samples = [];
  for (const page of Array.isArray(pages) ? pages : []) {
    const width = Number(page?.width);
    if (!(width > 0)) continue;
    for (const word of page.words || []) {
      const text = String(word?.text || '');
      if (!HANGUL_WORD_RE.test(text)) continue;
      const span = Number(word.xMax) - Number(word.xMin);
      if (!(span > 0)) continue;
      const em1k = (span / text.length / width) * 1000;
      if (!(em1k > 2 && em1k < 60)) continue;
      for (let i = 0; i < text.length; i += 1) samples.push(em1k);
    }
  }
  if (samples.length < MIN_SAMPLE_SYLLABLES) {
    return { em1k: EXAM_TEXT_EM_1K_FALLBACK, samples: samples.length, source: 'fallback' };
  }
  samples.sort((a, b) => a - b);
  const value = median(samples);
  if (!(value >= EM_1K_MIN && value <= EM_1K_MAX)) {
    return { em1k: EXAM_TEXT_EM_1K_FALLBACK, samples: samples.length, source: 'fallback', measured: value };
  }
  return { em1k: Math.round(value * 100) / 100, samples: samples.length, source: 'text_layer' };
}
