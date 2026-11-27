// 그림 엔진(packages/ygg_figure)이 내보낸 그림을 실서비스에 싣는다.
//
// 기본은 "미리 보기"다. 아무것도 쓰지 않고, 무엇을 어디에 올리고 어느 문항에 붙일지만 적어 낸다.
//
//   node scripts/publish_engine_figures.mjs                       # 계획만 (DB·저장소에 접속하지 않는다)
//   node scripts/publish_engine_figures.mjs --only csat-2026-common-4-1
//
// 실제로 실을 때(사장님 승인 후에만):
//
//   node --env-file=.env scripts/publish_engine_figures.mjs --apply --status approved
//   node --env-file=.env scripts/publish_engine_figures.mjs --remove --only <그림 이름>   # 되돌리기(원본 그림으로 돌아간다)
//
// --apply 가 하는 일(그림 한 장마다):
//   1. 문항을 읽어 원본 그림이 계획과 같은 자리에 그대로 있는지 확인한다. 다르면 그 그림은 건너뛴다.
//   2. 묶음 파일을 저장소(problem-figures)에 올린다.
//   3. 문항의 meta.engine_figures 에 한 줄을 적는다(pb_set_engine_figure). 원본 그림(figure_assets)은 건드리지 않는다.
//
// --status approved 로 실은 그림만 인쇄와 미리보기에 쓰인다. 기본값 draft 는 올려만 두고 쓰지 않는다.
// 저장소와 기록 기능은 supabase/migrations/20261126233000_problem_engine_figures.sql 에 있다.
//
// 옵션: --export <묶음 폴더> --manifest <원본 목록> --rows <문항 목록> --out <기록 폴더> --only <이름,이름>
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

import { ENGINE_FIGURE_BUCKET } from '../src/problem_bank/engine_figures.js';
import {
  bundleFileNames,
  originalStillThere,
  planEngineFigurePublish,
} from '../src/problem_bank/engine_figure_publish.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const pkg = path.join(root, 'packages', 'ygg_figure');
const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);
const arg = (name, fallback) => {
  const i = argv.indexOf(name);
  return i < 0 || i + 1 >= argv.length ? fallback : argv[i + 1];
};

const exportDir = path.resolve(arg('--export', path.join(pkg, 'build', 'export')));
const manifestFile = path.resolve(arg('--manifest', path.join(pkg, 'reference', 'manifest.json')));
const rowsFile = path.resolve(arg('--rows', path.join(pkg, 'reference', 'work', 'csat_rows.json')));
const outDir = path.resolve(arg('--out', path.join(pkg, 'build', 'publish')));
const only = new Set(String(arg('--only', '')).split(',').map((s) => s.trim()).filter(Boolean));
const status = arg('--status', 'draft') === 'approved' ? 'approved' : 'draft';
const apply = flag('--apply');
const remove = flag('--remove');

for (const file of [manifestFile, rowsFile]) {
  if (!fs.existsSync(file)) {
    console.error(`파일이 없습니다: ${file}`);
    process.exit(2);
  }
}
if (!fs.existsSync(exportDir)) {
  console.error(`내보낸 묶음 폴더가 없습니다: ${exportDir}`);
  process.exit(2);
}

const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8')).figures;
const rows = JSON.parse(fs.readFileSync(rowsFile, 'utf8')).rows;
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

// 1. 계획: 묶음마다 어느 문항의 몇 번째 그림인지 찾고, 올릴 자리와 적을 한 줄을 만든다.
const plans = [];
const names = fs.readdirSync(exportDir)
  .filter((name) => fs.existsSync(path.join(exportDir, name, 'asset.json')))
  .filter((name) => only.size === 0 || only.has(name))
  .sort();
for (const name of names) {
  const dir = path.join(exportDir, name);
  const bundle = JSON.parse(fs.readFileSync(path.join(dir, 'asset.json'), 'utf8'));
  // 그림 이름이 곧 원본 목록의 이름이다.
  const entry = manifest.find((one) => one.id === bundle.id);
  const row = entry && rows.find((one) => one.pb_question_id === entry.pb_question_id);
  const asset = row && (Array.isArray(row.figure_assets) ? row.figure_assets : [])
    .find((one) => Number(one.figure_index) === Number(entry.figure_order));
  if (!entry || !row || !asset) {
    plans.push({ id: name, dir, problems: ['원본 목록에서 이 그림의 문항을 찾지 못했습니다'], warnings: [] });
    continue;
  }
  const fileHashes = {};
  const tikzTexts = {};
  for (const file of bundleFileNames(bundle)) {
    const full = path.join(dir, file);
    if (!fs.existsSync(full)) continue;
    const bytes = fs.readFileSync(full);
    fileHashes[file] = sha256(bytes);
    if (file.endsWith('.tikz')) tikzTexts[file] = bytes.toString('utf8');
  }
  const originalPath = String(asset.path || '');
  const plan = planEngineFigurePublish({
    bundle,
    fileHashes,
    tikzTexts,
    academyId: originalPath.split('/')[0],
    questionId: entry.pb_question_id,
    figureIndex: entry.figure_order,
    originalPath,
    status,
  });
  plans.push({
    id: name,
    dir,
    alias: Boolean(entry.same_as),
    question: `${entry.exam_year} ${entry.section} ${entry.problem_number}번`,
    questionId: entry.pb_question_id,
    figureIndex: Number(entry.figure_order),
    originalBucket: String(asset.bucket || ''),
    originalPath,
    ...plan,
  });
}

// 가형·나형이 함께 쓰는 문항은 DB 에 한 번만 들어 있다. 그 문항의 그림도 한 장만 싣는다.
//   원본 그림을 따로 가진 쪽(same_as 가 없는 쪽)을 싣고, 나머지는 "함께 씀" 으로 적어 둔다.
const slots = new Map();
for (const one of plans) {
  if (one.problems.length > 0) continue;
  const slot = `${one.questionId}/${one.figureIndex}`;
  const held = slots.get(slot);
  if (!held) {
    slots.set(slot, one);
  } else if (held.alias && !one.alias) {
    held.sharedWith = one.id;
    slots.set(slot, one);
  } else {
    one.sharedWith = held.id;
  }
}

fs.mkdirSync(outDir, { recursive: true });
const shared = plans.filter((one) => one.sharedWith);
const ready = plans.filter((one) => one.problems.length === 0 && !one.sharedWith);
const blocked = plans.filter((one) => one.problems.length > 0);
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const summary = {
  made_at: new Date().toISOString(),
  mode: remove ? 'remove' : apply ? 'apply' : 'plan',
  status,
  bucket: ENGINE_FIGURE_BUCKET,
  figures: plans.length,
  ready: ready.length,
  shared: shared.map((one) => ({ id: one.id, published_as: one.sharedWith })),
  blocked: blocked.length,
  files: ready.reduce((sum, one) => sum + one.uploads.length, 0),
  bytes: ready.reduce(
    (sum, one) => sum + one.uploads.reduce((s, up) => s + fs.statSync(path.join(one.dir, up.name)).size, 0),
    0,
  ),
  with_warnings: ready.filter((one) => one.warnings.length > 0).map((one) => ({ id: one.id, warnings: one.warnings })),
  blocked_list: blocked.map((one) => ({ id: one.id, problems: one.problems })),
};
const planFile = path.join(outDir, 'plan.json');
fs.writeFileSync(planFile, JSON.stringify({
  ...summary,
  plans: plans.map(({ dir, ...rest }) => rest),
}, null, 2));
console.log(`그림 ${summary.figures}장: 실을 수 있음 ${summary.ready}, 같은 문항을 함께 씀 ${shared.length}, 막힘 ${summary.blocked}`);
for (const one of shared) console.log(`  함께 씀 ${one.id}: ${one.sharedWith} 의 그림으로 싣는다(같은 문항)`);
console.log(`올릴 파일 ${summary.files}개, ${(summary.bytes / 1024 / 1024).toFixed(1)} MB → 저장소 ${ENGINE_FIGURE_BUCKET}`);
for (const one of summary.with_warnings) console.log(`  주의 ${one.id}: ${one.warnings.join(' / ')}`);
for (const one of summary.blocked_list) console.log(`  막힘 ${one.id}: ${one.problems.join(' / ')}`);
console.log(`계획: ${planFile}`);

if (!apply && !remove) {
  console.log('미리 보기만 했습니다. DB 와 저장소에는 아무것도 쓰지 않았습니다.');
  process.exit(blocked.length > 0 ? 1 : 0);
}
if (apply && remove) {
  console.error('--apply 와 --remove 는 함께 쓸 수 없습니다.');
  process.exit(2);
}

// 2. 실제 반영. 여기부터 DB 와 저장소에 접속한다.
const url = String(process.env.SUPABASE_URL || '').trim();
const key = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
if (!url || !key) {
  console.error('SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY 가 없습니다. node --env-file=.env 로 실행하세요.');
  process.exit(2);
}
const { createClient } = await import('@supabase/supabase-js');
const supabase = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

const done = [];
const skipped = [];
for (const one of ready) {
  try {
    const { data: question, error: readError } = await supabase
      .from('pb_questions')
      .select('id,academy_id,figure_assets:meta->figure_assets,engine_figures:meta->engine_figures')
      .eq('id', one.questionId)
      .maybeSingle();
    if (readError) throw new Error(`문항을 읽지 못했습니다: ${readError.message}`);
    if (!question) throw new Error('문항이 없습니다');
    const before = (Array.isArray(question.engine_figures) ? question.engine_figures : [])
      .filter((line) => Number(line?.figure_index) === one.figureIndex);

    if (remove) {
      const { error } = await supabase.rpc('pb_remove_engine_figure', {
        p_question_id: one.questionId,
        p_figure_index: one.figureIndex,
      });
      if (error) throw new Error(`지우지 못했습니다: ${error.message}`);
      done.push({ id: one.id, question_id: one.questionId, figure_index: one.figureIndex, removed: before });
      console.log(`지움 ${one.id}`);
      continue;
    }

    if (String(question.academy_id) !== one.originalPath.split('/')[0]) throw new Error('문항의 학원이 계획과 다릅니다');
    if (!originalStillThere(question.figure_assets, one.figureIndex, one.originalPath)) {
      throw new Error('원본 그림이 바뀌었습니다(다시 잘렸거나 순서가 바뀜). 문항 목록을 다시 받아야 합니다');
    }
    for (const up of one.uploads) {
      const { error } = await supabase.storage.from(ENGINE_FIGURE_BUCKET).upload(
        up.path,
        fs.readFileSync(path.join(one.dir, up.name)),
        { contentType: up.contentType, upsert: true },
      );
      if (error) throw new Error(`올리지 못했습니다(${up.name}): ${error.message}`);
    }
    // 올린 인쇄용 그림을 다시 받아 본다. 받지 못하는 그림을 문항에 붙이지 않는다.
    const { data: back, error: backError } = await supabase.storage.from(ENGINE_FIGURE_BUCKET).download(one.record.pdf_path);
    if (backError || !back) throw new Error(`올린 그림을 다시 받지 못했습니다: ${backError?.message || '빈 응답'}`);
    if (Buffer.from(await back.arrayBuffer()).subarray(0, 5).toString('latin1') !== '%PDF-') {
      throw new Error('올린 그림이 PDF 가 아닙니다');
    }
    const record = { ...one.record, published_at: new Date().toISOString() };
    if (record.status === 'approved') record.approved_at = record.published_at;
    const { error: writeError } = await supabase.rpc('pb_set_engine_figure', {
      p_question_id: one.questionId,
      p_record: record,
    });
    if (writeError) throw new Error(`문항에 적지 못했습니다: ${writeError.message}`);
    done.push({ id: one.id, question_id: one.questionId, figure_index: one.figureIndex, base: one.base, status: record.status, replaced: before });
    console.log(`실음 ${one.id} (${record.status})`);
  } catch (err) {
    skipped.push({ id: one.id, reason: String(err?.message || err) });
    console.log(`건너뜀 ${one.id}: ${err?.message || err}`);
  }
}
const logFile = path.join(outDir, `${remove ? 'removed' : 'applied'}-${stamp}.json`);
fs.writeFileSync(logFile, JSON.stringify({ ...summary, done, skipped }, null, 2));
console.log(`${remove ? '지움' : '실음'} ${done.length}장, 건너뜀 ${skipped.length}장. 기록: ${logFile}`);
process.exit(skipped.length > 0 ? 1 : 0);
