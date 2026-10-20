// 사람이 고친 교재 자료를 기계 작업이 지우거나 덮지 않게 가르는 규칙.
//
// 설계: docs/architecture/textbook-review.md
//
// 정답·해설 좌표를 덮는 쓰기는 DB 트리거(20261014233000_textbook_manual_guard)가 그 행만
// 건너뛴다. 게이트웨이는 요청한 crop_id 와 DB 가 돌려준 crop_id 를 비교해 몇 건을 지켰는지
// 알려 주고, 지킨 행으로는 후속 작업(정답 그림 렌더)을 돌리지 않는다.
//
// 범위 동기화(sync-scope)는 크롭을 지우고, 크롭이 지워지면 정답·해설 좌표·문항 연결이 연쇄
// 삭제된다. 그래서 아래 표시가 하나라도 있는 크롭은 지우지 않는다.
//   pb_question      문제은행 문항까지 만들어진 크롭(pb_question_uid)
//   question_link    문제은행 문항 연결(textbook_crop_question_links)
//   manual_answer    사람이 고친 정답(answer_source = 'manual')
//   manual_solution  사람이 고친 해설 좌표(edited_at 이 있음)

const MARKER_CHUNK = 200;

export const QUESTION_REASONS = new Set(['pb_question', 'question_link']);

/** 요청했지만 DB 가 돌려주지 않은 crop_id. 수동 보호로 건너뛴 행이다. */
export function skippedCropIds(requestedIds, returnedRows) {
  const returned = new Set(
    (Array.isArray(returnedRows) ? returnedRows : []).map((row) =>
      String(row?.crop_id || ''),
    ),
  );
  const out = [];
  const seen = new Set();
  for (const raw of Array.isArray(requestedIds) ? requestedIds : []) {
    const id = String(raw || '').trim();
    if (!id || seen.has(id)) continue;
    seen.add(id);
    if (!returned.has(id)) out.push(id);
  }
  return out;
}

export async function fetchManualMarkers({ supa, cropIds }) {
  const ids = [
    ...new Set(
      (Array.isArray(cropIds) ? cropIds : [])
        .map((id) => String(id || '').trim())
        .filter(Boolean),
    ),
  ];
  const markers = {
    manualAnswer: new Set(),
    manualSolution: new Set(),
    questionLink: new Set(),
  };
  for (let i = 0; i < ids.length; i += MARKER_CHUNK) {
    const chunk = ids.slice(i, i + MARKER_CHUNK);
    const [answers, refs, links] = await Promise.all([
      supa
        .from('textbook_problem_answers')
        .select('crop_id')
        .in('crop_id', chunk)
        .eq('answer_source', 'manual'),
      supa
        .from('textbook_problem_solution_refs')
        .select('crop_id')
        .in('crop_id', chunk)
        .not('edited_at', 'is', null),
      supa
        .from('textbook_crop_question_links')
        .select('crop_id')
        .in('crop_id', chunk),
    ]);
    for (const [label, result, target] of [
      ['answers', answers, markers.manualAnswer],
      ['solution_refs', refs, markers.manualSolution],
      ['question_links', links, markers.questionLink],
    ]) {
      if (result?.error) {
        throw new Error(
          `manual_markers_${label}_failed: ${result.error.message || result.error}`,
        );
      }
      for (const row of result?.data || []) target.add(String(row?.crop_id || ''));
    }
  }
  return markers;
}

export function manualProtectionReasons(crop, markers) {
  const id = String(crop?.id || '');
  const reasons = [];
  if (String(crop?.pb_question_uid || '').trim()) reasons.push('pb_question');
  if (markers?.questionLink?.has(id)) reasons.push('question_link');
  if (markers?.manualAnswer?.has(id)) reasons.push('manual_answer');
  if (markers?.manualSolution?.has(id)) reasons.push('manual_solution');
  return reasons;
}

/**
 * 지울 크롭과 남길 크롭을 가른다.
 * questionNumbers: 문제은행이 걸려 남긴 번호(문제은행에서 정리해야 한다).
 * manualNumbers: 사람이 고친 정답·해설 좌표 때문에만 남긴 번호.
 */
export function partitionStaleCrops(staleRows, markers) {
  const deletable = [];
  const kept = [];
  for (const row of Array.isArray(staleRows) ? staleRows : []) {
    const reasons = manualProtectionReasons(row, markers);
    if (reasons.length === 0) {
      deletable.push(row);
      continue;
    }
    kept.push({
      id: row.id,
      problemNumber: String(row?.problem_number || '').trim(),
      reasons,
    });
  }
  const numbersWhere = (pick) =>
    kept.filter(pick).map((row) => row.problemNumber).filter(Boolean);
  return {
    deletable,
    kept,
    questionNumbers: numbersWhere((row) =>
      row.reasons.some((reason) => QUESTION_REASONS.has(reason)),
    ),
    manualNumbers: numbersWhere(
      (row) => !row.reasons.some((reason) => QUESTION_REASONS.has(reason)),
    ),
  };
}
