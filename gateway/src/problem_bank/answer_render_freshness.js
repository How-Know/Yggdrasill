// answer_render_assets 행은 렌더 당시 정답의 source_hash 를 갖는다. 정답을
// 고친 뒤 재렌더가 아직 안 됐거나 실패하면 옛 PNG 가 남으므로, 조회 응답에서는
// 현재 정답으로 계산한 해시와 같은 행만 내보낸다.

export function answerRenderFreshnessKey(sourceId, answerKind, styleVersion) {
  return `${String(sourceId || "").trim()}\n${String(answerKind || "").trim()}\n${String(
    styleVersion || "",
  ).trim()}`;
}

export function currentAnswerRenderHashMap(descriptors) {
  const out = new Map();
  for (const descriptor of Array.isArray(descriptors) ? descriptors : []) {
    if (!descriptor?.sourceHash) continue;
    out.set(
      answerRenderFreshnessKey(
        descriptor.sourceId,
        descriptor.answerKind,
        descriptor.styleVersion,
      ),
      String(descriptor.sourceHash),
    );
  }
  return out;
}

// currentHashByKey 가 null 이면 현재 정답을 읽지 못한 경우다. 그때는 이미지를
// 숨기지 않고 기존 행을 그대로 쓴다.
export function partitionFreshAnswerRenderRows(rows, currentHashByKey) {
  const list = Array.isArray(rows) ? rows : [];
  if (!(currentHashByKey instanceof Map)) {
    return { fresh: list, stale: [] };
  }
  const fresh = [];
  const stale = [];
  for (const row of list) {
    const expected = currentHashByKey.get(
      answerRenderFreshnessKey(row?.source_id, row?.answer_kind, row?.style_version),
    );
    const stored = String(row?.source_hash || "").trim();
    if (expected && stored && stored === expected) {
      fresh.push(row);
    } else {
      stale.push(row);
    }
  }
  return { fresh, stale };
}
