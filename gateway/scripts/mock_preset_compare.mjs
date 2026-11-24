// 모의고사 프리셋을 지금 코드로 다시 만들어 저장된 프리셋과 비교한다. DB 는 읽기만 한다.
//   node scripts/mock_preset_compare.mjs            전체 회차
//   node scripts/mock_preset_compare.mjs --exam <id,id>
// pb_export_presets 로 가는 쓰기는 실행하지 않고 값만 잡아 둔다. 다른 표로 가는 쓰기는 오류로 막는다.

import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import { syncMockExamPresetsForExam } from '../src/mock_exam/mock_preset.js';
import { applyMockPaperSlotValues } from '../src/mock_exam/paper_slots.js';

const FIELDS = [
  'source_document_id',
  'source_document_ids',
  'display_name',
  'render_config',
  'selected_question_uids',
  'selected_question_ids',
  'question_mode_by_question_uid',
  'question_mode_by_question_id',
];
const WRITES = ['insert', 'update', 'upsert', 'delete'];

const canonical = (value) => {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((k) => [k, canonical(value[k])]));
  }
  return value ?? null;
};
const same = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));

function readOnlyClient(real, captured) {
  const capture = (kind, values) => {
    const entry = { kind, values, id: '' };
    captured.push(entry);
    const done = () => Promise.resolve({
      data: { id: entry.id || 'new', display_name: values?.display_name || '' },
      error: null,
    });
    const chain = {
      eq(col, val) {
        if (col === 'id') entry.id = String(val);
        return chain;
      },
      select: () => chain,
      single: done,
      maybeSingle: done,
    };
    return chain;
  };
  return {
    from(table) {
      const query = real.from(table);
      return new Proxy(query, {
        get(target, prop) {
          if (WRITES.includes(prop)) {
            if (table === 'pb_export_presets' && (prop === 'insert' || prop === 'update')) {
              return (values) => capture(prop, values);
            }
            throw new Error(`write_blocked:${table}.${String(prop)}`);
          }
          const value = target[prop];
          return typeof value === 'function' ? value.bind(target) : value;
        },
      });
    },
  };
}

async function main() {
  const args = process.argv.slice(2);
  const examArg = args.includes('--exam') ? String(args[args.indexOf('--exam') + 1] || '') : '';
  const only = examArg.split(',').map((s) => s.trim()).filter(Boolean);

  const real = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  const captured = [];
  const supa = readOnlyClient(real, captured);

  let examQuery = real
    .from('mock_exams')
    .select('id, academy_id, grade, exam_year, exam_month, org')
    .order('exam_year', { ascending: true })
    .order('exam_month', { ascending: true });
  if (only.length > 0) examQuery = examQuery.in('id', only);
  const { data: exams, error: examErr } = await examQuery;
  if (examErr) throw new Error(`exams_fetch_failed:${examErr.message}`);

  const { data: stored, error: storedErr } = await real
    .from('pb_export_presets')
    .select(`id, ${FIELDS.join(', ')}`)
    .eq('preset_kind', 'settings');
  if (storedErr) throw new Error(`presets_fetch_failed:${storedErr.message}`);
  const storedById = new Map((stored || []).map((row) => [String(row.id), row]));

  const totals = { exams: 0, examErrors: 0, rebuilt: 0, identical: 0, different: 0, wouldInsert: 0 };
  const lines = [];
  for (const exam of exams || []) {
    totals.exams += 1;
    captured.length = 0;
    const label = `${exam.exam_year} 고${exam.grade} ${exam.exam_month}월`;
    try {
      await syncMockExamPresetsForExam(supa, exam.id);
    } catch (err) {
      totals.examErrors += 1;
      lines.push(`[오류] ${label}: ${String(err?.message || err).slice(0, 160)}`);
      continue;
    }
    for (const entry of captured) {
      totals.rebuilt += 1;
      if (entry.kind === 'insert') {
        totals.wouldInsert += 1;
        lines.push(`[새로 생김] ${entry.values?.display_name || label}`);
        continue;
      }
      const before = storedById.get(entry.id);
      const changed = FIELDS.filter((f) => !same(before?.[f], entry.values?.[f]));
      if (changed.length === 0) {
        totals.identical += 1;
        continue;
      }
      totals.different += 1;
      let detail = changed.join(', ');
      if (changed.includes('render_config')) {
        const a = before?.render_config || {};
        const b = entry.values?.render_config || {};
        const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].filter((k) => !same(a[k], b[k]));
        detail += ` | render_config: ${keys.join(', ')}`;
      }
      lines.push(`[다름] ${entry.values?.display_name || label}: ${detail}`);
    }
  }

  // 인쇄 쪽 자리 조회가 실제 DB 에서 도는지: 가형·나형 문항이 섞인 묶음으로 한 번 불러 본다.
  let probe = '가형·나형 회차 없음';
  const legacy = (exams || []).find((e) => Number(e.exam_year) <= 2020 && Number(e.grade) === 3);
  if (legacy) {
    const fake = (id, section) => ({ id, question_uid: id, meta: { mock_exam_item: { exam_id: legacy.id, section } } });
    try {
      const result = await applyMockPaperSlotValues({
        supa,
        academyId: legacy.academy_id,
        questions: [fake('probe-1', 'na'), fake('probe-2', 'na'), fake('probe-3', 'ga')],
      });
      probe = result.paper ? `시험지로 판단됨(${result.paper.section})` : '조회 정상';
    } catch (err) {
      probe = `오류: ${String(err?.message || err).slice(0, 160)}`;
    }
  }

  console.log(JSON.stringify(totals));
  console.log(`인쇄 쪽 자리 조회: ${probe}`);
  for (const line of lines.slice(0, 60)) console.log(line);
  if (lines.length > 60) console.log(`… 외 ${lines.length - 60}줄`);
}

main().catch((err) => {
  console.error(`실패: ${String(err?.message || err).slice(0, 300)}`);
  process.exit(1);
});
