// 교재 본문 추출 진행도. 워커가 청크 하나를 끝낼 때마다 끝난 청크 수와 문항 번호를
// textbook_pb_extract_runs.progress 에 남겨, 앱이 문항 카드마다 진행 상태를 보여 준다.
// 추출 결과 저장은 여전히 마지막에 한 번이므로 여기 번호는 "모델이 읽어 낸 문항"이다.

import { normalizeProblemNumberKey } from '../textbook/problem_number_key.js';

function compactNumber(value) {
  return String(value ?? '').replace(/\s+/g, '').trim();
}

/**
 * VLM 로그 이벤트를 받아 진행도 객체를 만든다. write 는 이전 쓰기가 끝난 뒤에만
 * 다음 쓰기를 시작하므로 순서가 뒤바뀐 진행도가 남지 않는다.
 */
export function createExtractProgressTracker({ write, now = () => new Date() }) {
  let state = null;
  let chain = Promise.resolve();

  const snapshot = () => ({
    chunks_total: state.chunksTotal,
    chunks_done: state.chunksDone.size,
    expected_count: state.expectedCount,
    numbers_done: [...state.numbers],
    updated_at: now().toISOString(),
  });

  const flush = () => {
    const progress = snapshot();
    chain = chain
      .then(() => write(progress))
      .catch(() => {});
    return chain;
  };

  return {
    onEvent(event, payload = {}) {
      if (event === 'vlm_call_start') {
        const chunks = Array.isArray(payload.chunks) ? payload.chunks : [];
        // 빠진 번호만 읽는 런은 같은 세트 번호도 함께 읽지만 저장은 대상 번호만 한다.
        const onlyKeys = Array.isArray(payload.onlyQuestionNumbers)
          ? new Set(payload.onlyQuestionNumbers.map(normalizeProblemNumberKey).filter(Boolean))
          : null;
        state = {
          chunksTotal: chunks.length || 1,
          chunksDone: new Set(),
          expectedCount: onlyKeys
            ? onlyKeys.size
            : chunks.reduce(
              (sum, chunk) => sum + (Number(chunk?.expectedQuestionCount) || 0),
              0,
            ),
          onlyKeys,
          numbers: new Set(),
        };
        return flush();
      }
      if (event === 'vlm_chunk_call_done' && state) {
        state.chunksDone.add(Number(payload.chunkIndex) || 0);
        for (const number of Array.isArray(payload.questionNumbers) ? payload.questionNumbers : []) {
          const key = compactNumber(number);
          if (!key) continue;
          if (state.onlyKeys && !state.onlyKeys.has(normalizeProblemNumberKey(key))) continue;
          state.numbers.add(key);
        }
        return flush();
      }
      return null;
    },
    idle() {
      return chain;
    },
  };
}
