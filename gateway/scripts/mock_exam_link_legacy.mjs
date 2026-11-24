// 가형·나형에 똑같이 실린 문항을 찾아 나형 문항에 가형 문항을 적는다(mock_exam_items.same_as_item_id).
// AI 를 쓰지 않는다. 기본은 찾은 쌍만 보여 주고, --apply 를 붙여야 DB 에 적는다.
//   node scripts/mock_exam_link_legacy.mjs --exam <회차 id>[,<회차 id>...] [--apply]
// 사람이 정한 연결(same_as_source = 'manual')은 건드리지 않는다. 다시 돌리면 'auto' 연결을 새 결과로 바꾼다.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import { matchLegacySameQuestions } from '../src/mock_exam/legacy_links.js';

function parseArgs(argv) {
  const out = { exams: [], apply: false };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--apply') out.apply = true;
    else if (argv[i] === '--exam') out.exams = String(argv[i + 1] || '').split(',').map((s) => s.trim()).filter(Boolean);
  }
  return out;
}

async function loadSection(supa, examId, section) {
  const { data: items, error } = await supa
    .from('mock_exam_items')
    .select('id, problem_number, answer_kind, answer_text, pb_question_id, same_as_item_id, same_as_source, merged_at')
    .eq('exam_id', examId)
    .eq('section', section)
    .order('problem_number');
  if (error) throw new Error(`mock_exam_items: ${error.message}`);
  const ids = (items || []).map((it) => it.pb_question_id).filter(Boolean);
  const questions = new Map();
  if (ids.length > 0) {
    const { data, error: qError } = await supa.from('pb_questions').select('id, stem, choices').in('id', ids);
    if (qError) throw new Error(`pb_questions: ${qError.message}`);
    for (const q of data || []) questions.set(q.id, q);
  }
  return (items || []).map((it) => {
    const q = questions.get(it.pb_question_id);
    return {
      id: it.id,
      number: it.problem_number,
      stem: q?.stem ?? '',
      choices: Array.isArray(q?.choices) ? q.choices : [],
      answerKind: it.answer_kind,
      answerText: it.answer_text,
      sameAsItemId: it.same_as_item_id,
      sameAsSource: it.same_as_source,
      merged: Boolean(it.merged_at),
    };
  });
}

/** 합친 자리와 그 짝 자리의 id. 연결(same_as_item_id)은 나형 자리에 적혀 있다. */
function mergedPairItemIds(ga, na) {
  const gaById = new Map(ga.map((it) => [it.id, it]));
  const out = new Set();
  for (const it of na) {
    const target = gaById.get(it.sameAsItemId);
    if (!target || (!it.merged && !target.merged)) continue;
    out.add(it.id);
    out.add(target.id);
  }
  return out;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.exams.length === 0) {
    console.error('사용: node scripts/mock_exam_link_legacy.mjs --exam <회차 id>[,...] [--apply]');
    process.exit(2);
  }
  const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  for (const examId of args.exams) {
    const { data: exam, error } = await supa
      .from('mock_exams')
      .select('id, exam_year, exam_month, org')
      .eq('id', examId)
      .maybeSingle();
    if (error || !exam) {
      console.log(`${examId}: 회차를 찾지 못했습니다`);
      continue;
    }
    const label = `${exam.exam_year} ${exam.exam_month}월`;
    const gaAll = await loadSection(supa, examId, 'ga');
    const naAll = await loadSection(supa, examId, 'na');
    // 이미 합친 쌍(문항 하나를 두 자리가 가리킨다)은 다시 비교하지 않고 연결도 건드리지 않는다.
    // 합친 자리는 짝의 문항을 읽으므로, 다시 비교하면 선지 순서가 다른 쌍의 연결이 지워진다.
    const settled = mergedPairItemIds(gaAll, naAll);
    const ga = gaAll.filter((it) => !settled.has(it.id));
    const na = naAll.filter((it) => !settled.has(it.id));
    if (settled.size > 0) console.log(`${exam.exam_year} ${exam.exam_month}월: 이미 합친 쌍 ${settled.size / 2}쌍은 건너뜁니다`);
    if (ga.length === 0 || na.length === 0) {
      console.log(`${label}: 가형 ${ga.length}문항 · 나형 ${na.length}문항. 두 구간이 모두 있어야 비교합니다`);
      continue;
    }
    const { same, uncertain } = matchLegacySameQuestions(ga, na);
    console.log(`${label}: 같은 문항 ${same.length}쌍 · 사람이 볼 쌍 ${uncertain.length}쌍`);
    for (const s of same) {
      console.log(`  같음   나형 ${s.naNumber}번 = 가형 ${s.gaNumber}번 (닮음 ${s.similarity})${s.formDiffers ? ' 객관식·주관식만 다름' : ''}`);
    }
    for (const u of uncertain) {
      console.log(`  확인   나형 ${u.naNumber}번 ~ 가형 ${u.gaNumber}번 (닮음 ${u.similarity}) ${u.reasons.join(', ')}`);
    }
    if (!args.apply) continue;
    const gaByNumber = new Map(ga.map((it) => [it.number, it]));
    const linked = new Map(same.map((s) => [s.naNumber, gaByNumber.get(s.gaNumber)?.id ?? null]));
    let written = 0;
    let cleared = 0;
    for (const it of na) {
      if (it.sameAsSource === 'manual') continue;
      const target = linked.get(it.number) ?? null;
      if ((it.sameAsItemId ?? null) === target) continue;
      const { error: wError } = await supa
        .from('mock_exam_items')
        .update({ same_as_item_id: target, same_as_source: target ? 'auto' : null })
        .eq('id', it.id);
      if (wError) throw new Error(`기록 실패(나형 ${it.number}번): ${wError.message}`);
      if (target) written += 1;
      else cleared += 1;
    }
    console.log(`  기록: 연결 ${written}건 · 지움 ${cleared}건`);
  }
}

main().catch((e) => {
  console.error(e?.message || e);
  process.exit(1);
});
