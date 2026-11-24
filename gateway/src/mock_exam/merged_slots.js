// 합친 자리(mock_exam_items.merged_at): 다른 구간의 문항을 가리키는 자리.
// 재추출이 그 자리의 문항을 다시 만들거나, 문항을 가진 구간의 재추출로 자리가 끊기지 않게 한다.
// 설계: docs/architecture/mock-exam.md "One question, many slots".

const compact = (v) => String(v ?? '').trim();

const slotItemIdOf = (question) => compact(question?.meta?.mock_exam_item?.item_id);

/**
 * 추출 결과에서 합친 자리의 문항을 뺀다(배열을 그 자리에서 고친다). 뺀 문항의 번호를 돌려준다.
 * 그 자리의 문항은 다른 구간에 이미 있으므로, 다시 만들면 같은 문항이 둘이 된다.
 */
export async function dropMergedSlotQuestions(supa, questions, mockScope) {
  const rows = Array.isArray(questions) ? questions : [];
  const examId = compact(mockScope?.exam_id);
  const section = compact(mockScope?.section);
  if (rows.length === 0 || !examId || !section) return [];
  const { data, error } = await supa
    .from('mock_exam_items')
    .select('id, problem_number')
    .eq('exam_id', examId)
    .eq('section', section)
    .not('merged_at', 'is', null);
  if (error) throw new Error(`mock_merged_slots_fetch_failed:${error.message}`);
  const mergedIds = new Set((data || []).map((row) => compact(row.id)));
  const mergedNumbers = new Set((data || []).map((row) => Number(row.problem_number)));
  if (mergedIds.size === 0) return [];
  // 자리 표시(meta.mock_exam_item)가 붙은 문항은 자리로, 표시 없이 읽힌 문항은 번호로 가려낸다.
  const isMerged = (q) => {
    const itemId = slotItemIdOf(q);
    if (itemId) return mergedIds.has(itemId);
    const number = Number.parseInt(compact(q?.question_number), 10);
    return Number.isFinite(number) && mergedNumbers.has(number);
  };
  const dropped = [];
  for (let i = rows.length - 1; i >= 0; i -= 1) {
    if (!isMerged(rows[i])) continue;
    dropped.unshift(compact(rows[i]?.question_number));
    rows.splice(i, 1);
  }
  return dropped;
}

/**
 * 합친 자리가 짝 자리의 지금 문항을 가리키게 한다. 문항을 가진 구간을 다시 추출하면 문항 id 가 바뀌고
 * 자리의 pb_question_id 는 비워지므로(FK on delete set null), 추출 뒤에 다시 이어 준다.
 * 짝은 same_as_item_id 로 이어진 자리다(어느 쪽에 적혀 있든).
 */
export async function relinkMergedSlots(supa, { academyId, examId }) {
  const { data, error } = await supa
    .from('mock_exam_items')
    .select('id, pb_question_id, same_as_item_id, merged_at')
    .eq('academy_id', academyId)
    .eq('exam_id', examId);
  if (error) throw new Error(`mock_merged_slots_fetch_failed:${error.message}`);
  const items = data || [];
  const byId = new Map(items.map((it) => [compact(it.id), it]));
  const pointingTo = new Map();
  for (const it of items) {
    const target = compact(it.same_as_item_id);
    if (target) pointingTo.set(target, it);
  }
  let relinked = 0;
  const unresolved = [];
  for (const slot of items) {
    if (!slot.merged_at) continue;
    const partner = byId.get(compact(slot.same_as_item_id)) || pointingTo.get(compact(slot.id)) || null;
    const questionId = compact(partner?.pb_question_id);
    if (!partner || partner.merged_at || !questionId) {
      if (!compact(slot.pb_question_id)) unresolved.push(compact(slot.id));
      continue;
    }
    if (compact(slot.pb_question_id) === questionId) continue;
    const { error: updateErr } = await supa
      .from('mock_exam_items')
      .update({ pb_question_id: questionId })
      .eq('academy_id', academyId)
      .eq('id', slot.id);
    if (updateErr) throw new Error(`mock_merged_slot_relink_failed:${updateErr.message}`);
    relinked += 1;
  }
  return { relinked, unresolved };
}
