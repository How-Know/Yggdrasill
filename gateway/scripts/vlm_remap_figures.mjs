// VLM 기반 그림 재매핑 스크립트.
//
// 목적: 기존 figure_assets 가 "어느 문항 / 어느 슬롯"에 귀속되는지 Gemini 가 PDF 와
//       이미지들을 함께 보고 다시 판단하도록 시킨다. HWPX 추출기에서 인덱스가 엇나가
//       엉뚱한 문항에 그림이 붙은 경우(Daeryun-joong Q9/Q10/Q17)를 자동 보정한다.
//
// 사용:
//   node scripts/vlm_remap_figures.mjs \
//     --pdf "...pdf" \
//     --document-id <uuid> \
//     [--model gemini-3.1-pro-preview] \
//     [--apply]   # 기본은 dry-run. --apply 를 주면 DB 업데이트까지 수행.
//
// 동작:
//   1) pb_documents 로부터 academy_id / doc_id 취득
//   2) problem-previews 버킷에서 해당 docDir 하위 모든 PNG 후보 수집
//   3) pb_questions 를 모두 가져와서 stem [그림] 마커 수 / 현재 assets 을 파악
//   4) Gemini 에 PDF + 후보 이미지들 + "문항별 stem + 슬롯 수" 메타 전달
//      → "이 후보는 QN 의 K 번째 슬롯" (혹은 null)
//   5) 결과를 JSON 리포트로 저장. --apply 시 각 pb_questions.meta.figure_assets 재구성.
//
// 안전장치:
//   - --apply 전이라면 DB 는 읽기만.
//   - --apply 시 원본 meta.figure_assets 를 meta.figure_assets_backup_<ts> 로 백업.

import 'dotenv/config';
import fs from 'fs';
import path from 'path';
import { createClient } from '@supabase/supabase-js';

const GEMINI_API_KEY = String(process.env.GEMINI_API_KEY || '').trim();
const DEFAULT_MODEL = String(process.env.PB_GEMINI_MODEL || 'gemini-3.1-pro-preview').trim();

function parseArgs(argv) {
  const out = {
    pdf: '',
    documentId: '',
    model: DEFAULT_MODEL,
    apply: false,
    outDir: '',
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--pdf') out.pdf = argv[++i] || '';
    else if (a === '--document-id' || a === '--doc') out.documentId = argv[++i] || '';
    else if (a === '--model') out.model = argv[++i] || DEFAULT_MODEL;
    else if (a === '--apply') out.apply = true;
    else if (a === '--out') out.outDir = argv[++i] || '';
  }
  return out;
}

function tsSafe() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

async function main() {
  if (!GEMINI_API_KEY) throw new Error('GEMINI_API_KEY is required');
  const args = parseArgs(process.argv.slice(2));
  if (!args.pdf) throw new Error('--pdf <path> is required');
  if (!args.documentId) throw new Error('--document-id <uuid> is required');
  if (!fs.existsSync(args.pdf)) throw new Error(`PDF not found: ${args.pdf}`);

  const supabaseUrl = String(process.env.SUPABASE_URL || '').trim();
  const supabaseKey = String(
    process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_ANON_KEY || ''
  ).trim();
  if (!supabaseUrl || !supabaseKey) throw new Error('SUPABASE_URL / SERVICE_ROLE_KEY required');
  const sb = createClient(supabaseUrl, supabaseKey, {
    auth: { persistSession: false },
  });

  const outDir = args.outDir
    || path.join(
      process.cwd(),
      'experiments',
      `remap_${tsSafe()}_${path.basename(args.pdf, '.pdf')}`,
    );
  ensureDir(outDir);
  console.log(`[remap] outDir = ${outDir}`);

  // 1) 문항 / 문서 메타
  const { data: doc, error: docErr } = await sb
    .from('pb_documents')
    .select('id, academy_id')
    .eq('id', args.documentId)
    .single();
  if (docErr || !doc) throw new Error(`pb_documents not found: ${docErr?.message || 'n/a'}`);
  const academyId = doc.academy_id;

  const { data: rows, error: rowsErr } = await sb
    .from('pb_questions')
    .select('id, question_number, stem, meta, figure_refs')
    .eq('document_id', args.documentId)
    .order('question_number');
  if (rowsErr) throw new Error(`pb_questions fetch failed: ${rowsErr.message}`);

  // 문항별 "stem 에 필요한 그림 슬롯 수" 추정 = [그림] 마커 수.
  const qInfo = [];
  for (const r of rows) {
    const stem = String(r.stem || '');
    const slots = (stem.match(/\[그림\]/g) || []).length;
    qInfo.push({
      id: r.id,
      number: String(r.question_number),
      stem,
      slots,
      currentAssetPaths: (Array.isArray(r.meta?.figure_assets) ? r.meta.figure_assets : [])
        .map((a) => String(a?.path || ''))
        .filter(Boolean),
      meta: r.meta || {},
    });
  }

  // 2) 후보 PNG 수집 — problem-previews 버킷의 <academyId>/<docId>/* 하위.
  const baseDir = `${academyId}/${args.documentId}`;
  console.log(`[remap] scanning storage: problem-previews/${baseDir}`);
  const { data: subDirs, error: listErr } = await sb.storage
    .from('problem-previews')
    .list(baseDir, { limit: 1000 });
  if (listErr) throw new Error(`storage list failed: ${listErr.message}`);

  const candidates = [];
  for (const entry of subDirs || []) {
    if (entry?.id) continue; // 파일(직접) 은 스킵
    const sub = `${baseDir}/${entry.name}`;
    const { data: files } = await sb.storage.from('problem-previews').list(sub, { limit: 1000 });
    for (const f of files || []) {
      const ext = String(f?.name || '').toLowerCase().split('.').pop();
      if (!['png', 'jpg', 'jpeg', 'webp'].includes(ext)) continue;
      candidates.push({ path: `${sub}/${f.name}`, name: f.name });
    }
  }
  console.log(`[remap] candidate figures: ${candidates.length}`);

  // 각 후보가 "현재 어느 문항" 에 연결되어 있는지 미리 기록.
  const pathToQ = new Map();
  for (const q of qInfo) {
    for (const p of q.currentAssetPaths) pathToQ.set(p, q.number);
  }

  // 후보 이미지 다운로드.
  const candidatesDir = path.join(outDir, 'candidates');
  ensureDir(candidatesDir);
  const candidateBundle = [];
  for (let i = 0; i < candidates.length; i += 1) {
    const c = candidates[i];
    const { data, error } = await sb.storage.from('problem-previews').download(c.path);
    if (error || !data) {
      console.warn(`[remap] download failed: ${c.path}: ${error?.message || 'no data'}`);
      continue;
    }
    const buf = Buffer.from(await data.arrayBuffer());
    const localName = `cand_${String(i + 1).padStart(2, '0')}_${c.name}`;
    const localPath = path.join(candidatesDir, localName);
    fs.writeFileSync(localPath, buf);
    candidateBundle.push({
      label: `C${i + 1}`,
      storagePath: c.path,
      localPath,
      mime: c.name.toLowerCase().endsWith('.jpg') || c.name.toLowerCase().endsWith('.jpeg')
        ? 'image/jpeg'
        : c.name.toLowerCase().endsWith('.webp') ? 'image/webp' : 'image/png',
      currentAssignment: pathToQ.get(c.path) || null,
    });
  }
  console.log(`[remap] downloaded candidates: ${candidateBundle.length}`);

  // 3) Gemini 호출: PDF + 후보 이미지들 + 문항 슬롯 사양.
  const pdfBase64 = fs.readFileSync(args.pdf).toString('base64');
  const prompt = buildRemapPrompt({ qInfo, candidateBundle });
  fs.writeFileSync(path.join(outDir, 'prompt.txt'), prompt, 'utf8');

  const parts = [{ text: prompt }];
  parts.push({ inline_data: { mime_type: 'application/pdf', data: pdfBase64 } });
  for (const c of candidateBundle) {
    const b64 = fs.readFileSync(c.localPath).toString('base64');
    parts.push({
      inline_data: { mime_type: c.mime, data: b64 },
    });
  }

  const payload = {
    contents: [{ role: 'user', parts }],
    generationConfig: {
      temperature: 0.0,
      topP: 0.1,
      maxOutputTokens: 16384,
      responseMimeType: 'application/json',
      thinkingConfig: { thinkingLevel: 'low' },
    },
  };
  fs.writeFileSync(path.join(outDir, 'request_meta.json'), JSON.stringify({
    model: args.model,
    candidates: candidateBundle.map((c) => ({
      label: c.label, storagePath: c.storagePath, currentAssignment: c.currentAssignment,
    })),
    questions: qInfo.map((q) => ({ number: q.number, slots: q.slots, currentAssets: q.currentAssetPaths })),
  }, null, 2));

  const url = `https://generativelanguage.googleapis.com/v1beta/models/${args.model}:generateContent?key=${GEMINI_API_KEY}`;
  console.log(`[remap] calling Gemini (${args.model})...`);
  const t0 = Date.now();
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const elapsed = Date.now() - t0;
  const raw = await res.text();
  fs.writeFileSync(path.join(outDir, 'response.json'), raw);
  if (!res.ok) {
    console.error(`[remap] HTTP ${res.status} in ${elapsed}ms`);
    console.error(raw.slice(0, 1500));
    process.exit(1);
  }
  const body = JSON.parse(raw);
  const modelText = body?.candidates?.[0]?.content?.parts?.[0]?.text || '';
  fs.writeFileSync(path.join(outDir, 'model_text.txt'), modelText);

  let parsed;
  try {
    parsed = JSON.parse(modelText);
  } catch (e) {
    console.error(`[remap] JSON parse failed: ${e.message}`);
    console.error(modelText.slice(0, 600));
    process.exit(2);
  }
  fs.writeFileSync(path.join(outDir, 'mapping.json'), JSON.stringify(parsed, null, 2));
  console.log(`[remap] Gemini responded in ${elapsed}ms. total_candidates=${(parsed?.candidates||[]).length}`);

  // 4) 리포트 출력 — "현재 vs 제안" diff.
  const proposals = Array.isArray(parsed?.candidates) ? parsed.candidates : [];
  const byLabel = new Map(candidateBundle.map((c) => [c.label, c]));
  console.log('\n=== Remap plan ===');
  console.log('Label  Current → Proposed (slot)');
  const changes = [];
  for (const p of proposals) {
    const label = String(p?.label || '').trim();
    const bundle = byLabel.get(label);
    if (!bundle) continue;
    const curr = bundle.currentAssignment || '-';
    const propQ = p?.question_number ? String(p.question_number) : null;
    const propSlot = Number.isFinite(Number(p?.slot_index)) ? Number(p.slot_index) : null;
    const suffix = propQ ? `Q${propQ}${propSlot ? `(#${propSlot})` : ''}` : 'unused';
    const changed = propQ !== curr && !(curr === '-' && !propQ);
    console.log(`  ${label.padEnd(5)}  Q${curr.padEnd(3)} → ${suffix}${changed ? '  *' : ''}`);
    if (changed) {
      changes.push({ label, from: curr, to: propQ, slot: propSlot, bundle, proposal: p });
    }
  }

  if (!args.apply) {
    console.log(`\n[remap] dry-run complete. Review ${outDir}\\mapping.json then re-run with --apply`);
    return;
  }

  // 5) --apply: DB 업데이트 — 각 문항의 meta.figure_assets 를 새로 구성.
  // 전략: (a) 각 문항이 "이번에 받을 assets" 배열을 proposal 로부터 재구성.
  //       (b) 기존 meta 를 meta.figure_assets_backup_<ts> 로 보존한 뒤 업데이트.
  //       (c) bucket 은 problem-previews 로 고정.
  console.log('\n[remap] applying...');

  // qid → 새 assets (slot 순으로 정렬)
  const nextAssetsByQid = new Map();
  for (const q of qInfo) nextAssetsByQid.set(q.id, []);
  const qIdByNumber = new Map(qInfo.map((q) => [q.number, q.id]));

  for (const p of proposals) {
    const label = String(p?.label || '').trim();
    const bundle = byLabel.get(label);
    const propQ = p?.question_number ? String(p.question_number) : null;
    const propSlot = Number.isFinite(Number(p?.slot_index)) ? Number(p.slot_index) : null;
    if (!bundle || !propQ || !propSlot) continue;
    const qid = qIdByNumber.get(propQ);
    if (!qid) continue;
    const arr = nextAssetsByQid.get(qid);
    arr.push({
      bucket: 'problem-previews',
      path: bundle.storagePath,
      mime_type: bundle.mime,
      figure_index: propSlot,
      approved: true,
      remap_source: 'vlm_remap',
      remap_at: new Date().toISOString(),
    });
  }
  for (const [qid, arr] of nextAssetsByQid.entries()) {
    arr.sort((a, b) => (a.figure_index || 0) - (b.figure_index || 0));
  }

  const ts = new Date().toISOString();
  let updated = 0;
  for (const q of qInfo) {
    const nextAssets = nextAssetsByQid.get(q.id) || [];
    const currentAssets = Array.isArray(q.meta?.figure_assets) ? q.meta.figure_assets : [];
    // 동일하면 스킵 (경로 집합이 같은지 비교)
    const curSet = new Set(currentAssets.map((a) => String(a?.path || '')));
    const nextSet = new Set(nextAssets.map((a) => String(a?.path || '')));
    const same = curSet.size === nextSet.size && [...curSet].every((p) => nextSet.has(p));
    if (same) continue;

    const newMeta = { ...(q.meta || {}) };
    // 백업 키는 1회만.
    if (!newMeta.figure_assets_backup_remap) {
      newMeta.figure_assets_backup_remap = currentAssets;
      newMeta.figure_assets_backup_remap_at = ts;
    }
    newMeta.figure_assets = nextAssets;

    // figure_refs 는 stem 의 [그림] 마커 수에 맞춰 placeholder 로 재구성.
    const slotCount = q.slots;
    const newFigureRefs = Array.from({ length: slotCount }, (_, i) => `[그림]#${i + 1}`);

    const { error: updErr } = await sb
      .from('pb_questions')
      .update({ meta: newMeta, figure_refs: newFigureRefs })
      .eq('id', q.id);
    if (updErr) {
      console.error(`  Q${q.number} update failed: ${updErr.message}`);
      continue;
    }
    console.log(`  Q${q.number} updated: assets ${currentAssets.length} → ${nextAssets.length} (refs=${slotCount})`);
    updated += 1;
  }
  console.log(`[remap] done. updated questions: ${updated}`);
}

function buildRemapPrompt({ qInfo, candidateBundle }) {
  const lines = [];
  lines.push('당신은 한국 중·고등학교 수학 시험지 PDF 와 그 페이지에서 추출된 여러 장의 후보 이미지 파일을 비교하여,');
  lines.push('각 이미지가 "몇 번 문항 / 그 문항 안에서 몇 번째 그림 슬롯" 에 해당하는지를 결정하는 매핑 전문가입니다.');
  lines.push('');
  lines.push('반드시 다음 JSON 스키마로만 응답하세요. 설명 문장, 마크다운, 주석 금지.');
  lines.push('{');
  lines.push('  "candidates": [');
  lines.push('    {');
  lines.push('      "label": "C1" | "C2" | ...,  // 아래 후보 목록에 맞춤');
  lines.push('      "question_number": "10" | null,  // 해당 문항 번호(문자열), 해당 없음이면 null');
  lines.push('      "slot_index": 1 | 2 | 3 | null,  // 1-based, 문항 내 [그림] 마커 N번째');
  lines.push('      "confidence": "high" | "medium" | "low",');
  lines.push('      "reason": "왜 이 문항의 이 슬롯인지 아주 짧게 (<= 80자)"');
  lines.push('    }');
  lines.push('  ]');
  lines.push('}');
  lines.push('');
  lines.push('=== 후보 이미지 목록 (첨부 이미지는 PDF 다음부터 이 순서대로 들어옵니다) ===');
  for (const c of candidateBundle) {
    const curr = c.currentAssignment ? `현재 Q${c.currentAssignment} 에 연결됨` : '현재 할당 없음';
    lines.push(`- ${c.label} : filename="${path.basename(c.storagePath)}", ${curr}`);
  }
  lines.push('');
  lines.push('=== 문항별 그림 슬롯 사양 (stem 안 [그림] 마커 개수) ===');
  for (const q of qInfo) {
    if (q.slots === 0) continue;
    lines.push(`- Q${q.number} : 슬롯 ${q.slots} 개`);
    const stemShort = q.stem.replace(/\s+/g, ' ').trim().slice(0, 160);
    lines.push(`    stem 발췌: ${stemShort}${q.stem.length > 160 ? '…' : ''}`);
  }
  lines.push('');
  lines.push('=== 규칙 ===');
  lines.push('1. PDF 는 원본 시험지입니다. 문항 번호와 그림 내용은 PDF 가 "정답" 입니다. 현재 할당 정보는 참고용일 뿐 맹신하지 마세요.');
  lines.push('2. 각 후보 이미지가 PDF 에서 몇 번 문항의 어느 슬롯인지 시각적으로 대조해 결정하세요.');
  lines.push('3. 한 문항은 [그림] 마커 수만큼만 이미지를 받을 수 있습니다. 과다 할당 금지.');
  lines.push('4. 같은 이미지가 두 문항에 동시 속하면 안 됩니다(중복 할당 금지).');
  lines.push('5. PDF 어느 문항에도 대응되지 않으면 { "question_number": null, "slot_index": null } 로 표시하세요.');
  lines.push('6. 슬롯은 stem 에서 [그림] 마커가 등장한 순서(위→아래, 좌→우) 그대로 1-based.');
  lines.push('7. slot_index 는 반드시 해당 문항의 슬롯 수 이하여야 합니다.');
  lines.push('8. 모든 후보에 대해 정확히 한 번씩 응답을 내세요. 누락 금지.');
  lines.push('');
  lines.push('응답은 JSON 한 덩어리만 출력하세요.');
  return lines.join('\n');
}

main().catch((err) => {
  console.error('[remap] FATAL:', err?.message || err);
  process.exit(1);
});
