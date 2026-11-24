// 가형·나형에 같이 실린 문항(mock_exam_items.same_as_item_id 로 연결된 쌍)을 문항 하나로 합친다.
//   node scripts/mock_exam_merge_same.mjs --exam <회차 id>[,...]            바뀔 내용만 보여 준다 (DB 를 바꾸지 않는다)
//   node scripts/mock_exam_merge_same.mjs --exam <회차 id>[,...] --apply    합친다. 지우기 전 기록을 --backup-dir 에 남긴다
// 두 구간의 검수를 마친 뒤, 확정하기 전에 실행한다. 확정·공개된 구간과 학생 기록이 있는 문항은 합치지 않는다.

import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { mockReviewPending } from '../src/mock_exam/mock_preset.js';
import {
  MERGE_RECORD_CHECKS,
  applyMergePlan,
  collectMergeBackup,
  planSameQuestionMerge,
  removeDuplicate,
} from '../src/mock_exam/merge_same.js';

const SECTION_LABEL = { ga: '가형', na: '나형' };

function parseArgs(argv) {
  const value = (name) => (argv.includes(name) ? String(argv[argv.indexOf(name) + 1] || '') : '');
  return {
    exams: value('--exam').split(',').map((s) => s.trim()).filter(Boolean),
    apply: argv.includes('--apply'),
    // 지우기 전 기록은 저장소 밖에 둔다(build 폴더는 지워질 수 있고, 저장소에는 올리지 않는다).
    backupDir: value('--backup-dir')
      || path.join(process.env.LOCALAPPDATA || path.join('..', 'apps', 'yggdrasill_manager', 'build'), 'Yggdrasill', 'merge_backup'),
  };
}

async function all(query, label) {
  const { data, error } = await query;
  if (error) throw new Error(`${label}: ${error.message}`);
  return data || [];
}

async function recordCounts(supa, questions, cropIdByQuestionId) {
  const counts = new Map();
  const keyOf = { uid: (q) => q.question_uid, id: (q) => q.id, crop: (q) => cropIdByQuestionId.get(q.id) };
  for (const [table, column, by] of MERGE_RECORD_CHECKS) {
    const keys = new Map();
    for (const q of questions) {
      const key = String(keyOf[by](q) || '').trim();
      if (key) keys.set(key, q.id);
    }
    if (keys.size === 0) continue;
    const rows = await all(supa.from(table).select(column).in(column, [...keys.keys()]).limit(1000), `기록 확인 ${table}`);
    for (const row of rows) {
      const questionId = keys.get(String(row[column]));
      if (questionId) counts.set(questionId, (counts.get(questionId) || 0) + 1);
    }
  }
  return counts;
}

const slotName = (s) => `${SECTION_LABEL[s.section] || s.section} ${s.number}번`;

function describePlan(plan, decisions) {
  const lines = [];
  const head = `${slotName(plan.slot)} 자리 → ${slotName(plan.owner)} 문항`;
  if (plan.status === 'done') return [`  이미 합침  ${head}`];
  if (plan.status === 'refused') return [`  합치지 않음  ${head}: ${plan.reasons.join(', ')}`];
  lines.push(`  합침  ${head}${plan.formDiffers ? ' (객관식·단답형만 다름)' : ''}`);
  const set = plan.set;
  lines.push(`    배점: ${set.score === null ? `문항과 같음(${plan.scores.owner ?? '없음'}점)` : `자리에 ${set.score}점 (문항은 ${plan.scores.owner}점)`}`);
  if (plan.slot.answerKind === 'objective') {
    lines.push(`    선지 순서: ${set.choice_order ? `자리에 {${set.choice_order.join(',')}}` : '문항과 같음'}`);
  }
  lines.push(`    본문: ${set.stem_override === null ? '문항과 같음' : `자리에 그 시험지 본문을 둠 (${set.stem_override.length}자, 끝: …${set.stem_override.replace(/\s+/g, ' ').trim().slice(-28)})`}`);
  const edits = decisions.get(plan.duplicate.cropId) || [];
  lines.push(`    지움: ${slotName(plan.slot)} 문항 1개와 그 검수 기록${edits.length > 0 ? ` (사람이 내린 결정 ${edits.length}건: ${[...new Set(edits.map((d) => `${d.action}/${d.target}`))].join(', ')})` : ' (사람이 내린 결정 없음)'}`);
  for (const note of plan.notes) lines.push(`    참고: ${note}`);
  return lines;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.exams.length === 0) {
    console.error('사용: node scripts/mock_exam_merge_same.mjs --exam <회차 id>[,...] [--apply] [--backup-dir <폴더>]');
    process.exit(2);
  }
  const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  for (const examId of args.exams) {
    const exams = await all(supa.from('mock_exams').select('id, exam_year, exam_month').eq('id', examId), '회차 조회');
    if (exams.length === 0) {
      console.log(`${examId}: 회차를 찾지 못했습니다`);
      continue;
    }
    const label = `${exams[0].exam_year} ${exams[0].exam_month}월`;
    const items = await all(
      supa
        .from('mock_exam_items')
        .select('id, section, problem_number, answer_kind, answer_text, score, pb_question_id, same_as_item_id, merged_at')
        .eq('exam_id', examId)
        .in('section', ['ga', 'na']),
      '자리 조회',
    );
    const itemById = new Map(items.map((it) => [it.id, it]));
    const pairs = items
      .filter((it) => it.same_as_item_id && itemById.has(it.same_as_item_id))
      .map((it) => ({ a: it, b: itemById.get(it.same_as_item_id) }))
      .sort((x, y) => x.a.problem_number - y.a.problem_number);
    if (pairs.length === 0) {
      console.log(`${label}: 연결된 같은 문항이 없습니다`);
      continue;
    }

    const questionIds = [...new Set(pairs.flatMap((p) => [p.a.pb_question_id, p.b.pb_question_id]).filter(Boolean))];
    const questionRows = await all(
      supa
        .from('pb_questions')
        .select('id, question_uid, document_id, question_number, stem, choices, subjective_answer, is_published, meta')
        .in('id', questionIds),
      '문항 조회',
    );
    const questions = new Map(questionRows.map((q) => [q.id, q]));
    const documentIds = [...new Set(questionRows.map((q) => q.document_id).filter(Boolean))];
    const documents = await all(supa.from('pb_documents').select('id, meta').in('id', documentIds), '구간 문서 조회');
    const pendingDocumentIds = new Set(documents.filter((d) => mockReviewPending(d.meta)).map((d) => d.id));
    const links = await all(
      supa.from('textbook_crop_question_links').select('crop_id, pb_question_id').in('pb_question_id', questionIds),
      '크롭 연결 조회',
    );
    const cropIdByQuestionId = new Map(links.map((l) => [l.pb_question_id, l.crop_id]));
    const counts = await recordCounts(supa, questionRows, cropIdByQuestionId);
    // 검수가 고쳐 둔 본문(반영 대기). 자리에 옮길 본문과 두 본문의 비교는 이 값을 먼저 쓴다.
    const cropIds = [...new Set(links.map((l) => l.crop_id).filter(Boolean))];
    const analyses = cropIds.length === 0 ? [] : await all(
      supa.from('textbook_problem_analyses').select('crop_id, staged_changes').in('crop_id', cropIds),
      '반영 대기 값 조회',
    );
    const stagedStemByCrop = new Map(analyses
      .filter((row) => typeof row.staged_changes?.stem === 'string' && row.staged_changes.stem.trim())
      .map((row) => [row.crop_id, row.staged_changes.stem]));
    const stagedStemByQuestionId = new Map(links
      .filter((l) => stagedStemByCrop.has(l.crop_id))
      .map((l) => [l.pb_question_id, stagedStemByCrop.get(l.crop_id)]));

    const plans = pairs.map(({ a, b }) =>
      planSameQuestionMerge({
        a, b, questions, pendingDocumentIds, recordCounts: counts, cropIdByQuestionId, stagedStemByQuestionId,
      }));
    const duplicateCropIds = plans.map((p) => p.duplicate?.cropId).filter(Boolean);
    const decisionRows = duplicateCropIds.length === 0 ? [] : await all(
      supa.from('textbook_review_decisions').select('crop_id, action, target').in('crop_id', duplicateCropIds),
      '검수 결정 조회',
    );
    const decisions = new Map();
    for (const d of decisionRows) decisions.set(d.crop_id, [...(decisions.get(d.crop_id) || []), d]);

    // 합친 자리인데 그 자리의 중복 문항이 아직 남아 있는 경우(앞선 실행이 중간에 멈춤).
    const mergedItems = items.filter((it) => it.merged_at);
    const leftovers = [];
    for (const it of mergedItems) {
      const rows = await all(
        supa.from('pb_questions').select('id, question_uid').eq('meta->mock_exam_item->>item_id', it.id).neq('id', it.pb_question_id),
        '남은 중복 조회',
      );
      for (const row of rows) {
        const cropLinks = await all(
          supa.from('textbook_crop_question_links').select('crop_id').eq('pb_question_id', row.id),
          '남은 중복 크롭 조회',
        );
        leftovers.push({ item: it, duplicate: { questionId: row.id, questionUid: row.question_uid, cropId: cropLinks[0]?.crop_id || '' } });
      }
    }

    const count = (status) => plans.filter((p) => p.status === status).length;
    console.log(`${label}: 연결 ${pairs.length}쌍 · 합칠 것 ${count('merge')} · 이미 합침 ${count('done')} · 합치지 않음 ${count('refused')}${leftovers.length > 0 ? ` · 남은 중복 ${leftovers.length}` : ''}`);
    for (const plan of plans) for (const line of describePlan(plan, decisions)) console.log(line);
    for (const left of leftovers) console.log(`  남은 중복  ${slotName({ section: left.item.section, number: left.item.problem_number })} 자리의 예전 문항 ${left.duplicate.questionId}`);

    if (!args.apply) continue;
    fs.mkdirSync(args.backupDir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    for (const plan of plans.filter((p) => p.status === 'merge')) {
      const backup = await collectMergeBackup(supa, plan);
      const file = path.join(args.backupDir, `${examId}_${plan.slot.section}${plan.slot.number}_${stamp}.json`);
      fs.writeFileSync(file, JSON.stringify(backup, null, 1));
      await applyMergePlan(supa, plan);
      console.log(`  완료  ${slotName(plan.slot)} 자리 (기록 파일 ${file})`);
    }
    for (const left of leftovers) {
      const plan = {
        slot: { itemId: left.item.id, section: left.item.section, number: left.item.problem_number },
        duplicate: left.duplicate,
      };
      const backup = await collectMergeBackup(supa, plan);
      const file = path.join(args.backupDir, `${examId}_${left.item.section}${left.item.problem_number}_leftover_${stamp}.json`);
      fs.writeFileSync(file, JSON.stringify(backup, null, 1));
      await removeDuplicate(supa, left.duplicate);
      console.log(`  남은 중복 지움  ${slotName(plan.slot)} 자리 (기록 파일 ${file})`);
    }
  }
}

main().catch((e) => {
  console.error(e?.message || e);
  process.exit(1);
});
