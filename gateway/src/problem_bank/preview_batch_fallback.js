// 문항 카드 묶음 조판의 실패 처리(계산만, 조판·저장은 호출한 쪽이 한다).
//
// 문항 카드는 요청한 문항을 한 문서로 조판해 쪽마다 한 장씩 자른다. 한 문항이 조판 오류를 내면 문서 전체가
// 실패해 그 묶음의 카드가 하나도 나오지 않는다(2026 고3 7월 공통 20번, 9월 확통 27번: 구간 전체가 원본 대조 없이
// 지나갔다). 실패한 묶음은 반으로 나눠 다시 찍어, 조판이 안 되는 문항만 카드 없이 남긴다.

/// 실패한 조판을 이 횟수까지만 되풀이한다. 엔진 자체가 죽었을 때 문항 수만큼 헛돌지 않게 한다.
export const MAX_FAILED_RENDERS = 12;
const ERROR_MAX = 300;

function errorText(err) {
  return String(err?.message || err || '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, ERROR_MAX);
}

/// renderGroup(questions, qids) → { thumbnails: { [qid]: {...} }, pageCount } (실패하면 던진다)
/// 반환: { thumbnails, pageCount, failed: [qid], firstError }
///   thumbnails[qid] = renderGroup 이 준 값, 조판이 안 된 문항은 { error }
export async function renderThumbnailGroups({ questions, qids, renderGroup, maxFailedRenders = MAX_FAILED_RENDERS }) {
  const thumbnails = {};
  const failed = [];
  let pageCount = 0;
  let failures = 0;
  let firstError = '';

  const giveUp = (ids, message) => {
    for (const id of ids) {
      thumbnails[id] = { error: message };
      failed.push(id);
    }
  };

  const run = async (qs, ids) => {
    if (ids.length === 0) return;
    if (failures >= maxFailedRenders) {
      giveUp(ids, `render_skipped: ${firstError}`);
      return;
    }
    try {
      const out = await renderGroup(qs, ids);
      Object.assign(thumbnails, out?.thumbnails || {});
      pageCount += Number(out?.pageCount) || 0;
    } catch (err) {
      failures += 1;
      const message = errorText(err);
      if (!firstError) firstError = message;
      if (ids.length === 1) {
        giveUp(ids, `render_failed: ${message}`);
        return;
      }
      const mid = Math.ceil(ids.length / 2);
      await run(qs.slice(0, mid), ids.slice(0, mid));
      await run(qs.slice(mid), ids.slice(mid));
    }
  };

  await run(questions, qids);
  return { thumbnails, pageCount, failed, firstError };
}
