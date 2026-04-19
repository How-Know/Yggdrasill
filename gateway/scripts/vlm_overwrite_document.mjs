// VLM 추출 결과(JSON) 를 특정 pb_documents.document_id 의 pb_questions 전체에
// 덮어쓰는 스크립트. 실 운영 워커/파이프라인은 건드리지 않는 실험 전용 도구.
//
// 기본 정책:
//   - 기존 문항의 그림(meta.figure_assets, meta.figure_layout)은 "문항번호 단위"로
//     그대로 보존한다. VLM 이 서술한 figures 배열은 stem 렌더링용 설명으로만 쓰고,
//     실제 이미지 파일/레이아웃은 건드리지 않는다.
//   - VLM 이 제공한 stem / choices / is_set_question / sub_questions /
//     answer.* / question_type / score / flags 를 반영한다.
//   - 세트형은 (1),(2) sub_questions 를 stem 뒤에 [소문항1]/[소문항2] 마커와 함께
//     붙이고, meta.answer_parts 와 subjective_answer 를 모두 채운다.
//   - 객관식만 objective_choices / objective_answer_key 를 채운다.
//     VLM 이 선택지를 안 넣은 주관식/서술형/세트형은 allow_objective=false 로 기록.
//
// 사용:
//   # dry-run: 덮어쓸 필드만 콘솔로 확인 (DB 변경 없음)
//   node scripts/vlm_overwrite_document.mjs \
//     --extracted experiments/<폴더>/extracted.json \
//     --document-id 1026558d-a6a6-4943-bae2-6eed11710288
//
//   # 실제 덮어쓰기 + 기존 전체 백업
//   node scripts/vlm_overwrite_document.mjs \
//     --extracted experiments/<폴더>/extracted.json \
//     --document-id 1026558d-a6a6-4943-bae2-6eed11710288 \
//     --apply
//
// 롤백:
//   node scripts/vlm_overwrite_document.mjs \
//     --rollback experiments/<폴더>/backup_before_overwrite.json \
//     --document-id 1026558d-a6a6-4943-bae2-6eed11710288 \
//     --apply

import 'dotenv/config';
import fs from 'fs';
import path from 'path';
import { createClient } from '@supabase/supabase-js';

function parseArgs(argv) {
  const out = { extracted: '', documentId: '', apply: false, rollback: '', keepTypeFromDb: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--extracted') out.extracted = argv[++i] || '';
    else if (a === '--document-id' || a === '--doc') out.documentId = argv[++i] || '';
    else if (a === '--apply') out.apply = true;
    else if (a === '--rollback') out.rollback = argv[++i] || '';
    else if (a === '--keep-type-from-db') out.keepTypeFromDb = true;
  }
  return out;
}

function normQNum(v) {
  const n = Number.parseInt(String(v || '').trim(), 10);
  return Number.isFinite(n) ? String(n) : '';
}

// VLM 은 수식을 MathJax 스타일 \(...\) / \[...\] 로 내보낸다. 그러나 현재 XeLaTeX
// 렌더러(template.js:smartTexLine)는 stem/choice 본문에서 "한국어가 아닌 모든
// 연속 구간" 을 자동으로 $\displaystyle ...$ 로 감싸준다는 가정을 한다.
// 따라서 \(...\) / \[...\] / $...$ / $$...$$ 같은 수식 구분자를 남겨 두면:
//   - \(x\)      : LaTeX 수식이지만 렌더러가 또 $...$ 로 한 번 더 감싸 nested.
//   - $x$        : 달러가 글자로 남아 있는 상태에서 다시 $...$ 로 감싸져 nested.
// 두 경우 모두 "Bad math environment delimiter" 로 컴파일 실패한다.
//
// 해결책은 "구분자만 제거, 내부 LaTeX 명령은 보존" 이다. 즉 `\(x+1\)` → `x+1`.
// 이렇게 저장하면 기존 HWPX 파이프라인과 형태가 동일해지고, 렌더러가 자동 감싸기
// 로직으로 문제 없이 처리한다.
//
// 주의:
//  - 한국어 마커 [보기시작]/[박스시작]/[그림] 은 대괄호 기반이라 영향받지 않음.
//  - JSON 파싱 후 문자열이므로 \\( 은 실제 문자 `\(` 한 개. 그대로 치환한다.
//  - 드물게 VLM 이 진짜 "\\("(백슬래시 둘 + 괄호)를 주는 경우도 방어적으로 처리.
function normalizeMathDelimiters(input) {
  if (typeof input !== 'string' || !input) return input;
  let s = input;

  // 1) 백슬래시 둘로 이스케이프된 경계 방어: "\\(" → "\(" / "\\[" → "\["
  s = s.replace(/\\\\\(/g, '\\(').replace(/\\\\\)/g, '\\)');
  s = s.replace(/\\\\\[/g, '\\[').replace(/\\\\\]/g, '\\]');

  // 2) 디스플레이 수식 \[...\] → inner 만 남김 (블록 수식은 현재 파이프라인이 인라인처럼 취급).
  s = s.replace(/\\\[([\s\S]*?)\\\]/g, (_, inner) => inner);
  // 3) 인라인 수식 \(...\) → inner 만 남김.
  s = s.replace(/\\\(([\s\S]*?)\\\)/g, (_, inner) => inner);

  // 4) 간혹 VLM 이 이미 $...$ / $$...$$ 로 낸 경우에도 달러를 벗겨 둔다.
  //    $ 한 쌍(짝수 개수 전제): 비탐욕 매칭으로 내부만 남김.
  //    $$...$$ 를 먼저 처리(더 긴 패턴이 우선).
  s = s.replace(/\$\$([\s\S]*?)\$\$/g, (_, inner) => inner);
  s = s.replace(/\$([^$\n]+?)\$/g, (_, inner) => inner);

  return s;
}

function normalizeVlmQuestion(vlmQ) {
  if (!vlmQ || typeof vlmQ !== 'object') return vlmQ;
  const out = { ...vlmQ };
  out.stem = normalizeMathDelimiters(out.stem);
  if (Array.isArray(out.choices)) {
    out.choices = out.choices.map((c) => ({
      ...c,
      text: normalizeMathDelimiters(c?.text),
    }));
  }
  if (Array.isArray(out.sub_questions)) {
    out.sub_questions = out.sub_questions.map((sq) => ({
      ...sq,
      text: normalizeMathDelimiters(sq?.text),
    }));
  }
  if (out.answer && typeof out.answer === 'object') {
    const a = { ...out.answer };
    if (typeof a.subjective === 'string') a.subjective = normalizeMathDelimiters(a.subjective);
    if (typeof a.objective_key === 'string') a.objective_key = normalizeMathDelimiters(a.objective_key);
    if (Array.isArray(a.parts)) {
      a.parts = a.parts.map((p) => ({ ...p, value: normalizeMathDelimiters(p?.value) }));
    }
    out.answer = a;
  }
  return out;
}

const OBJ_LABELS = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];
function normalizeObjectiveLabel(raw, index) {
  const s = String(raw || '').trim();
  if (!s) return OBJ_LABELS[index] || '';
  if (OBJ_LABELS.includes(s)) return s;
  const m = s.match(/[1-9]\d?/);
  if (m) {
    const n = Number.parseInt(m[0], 10);
    if (n >= 1 && n <= OBJ_LABELS.length) return OBJ_LABELS[n - 1];
  }
  return s;
}

// VLM 의 은닉 sub_questions 를 stem 본문에 마커와 함께 복원.
// 기존 파이프라인이 "(1)" / "(2)" 구분을 [소문항N] 마커로 기대하므로 맞춰 삽입.
function buildStemWithSubQuestions(vlmQ, existingFigureSlots) {
  const baseStem = String(vlmQ.stem || '').trim();
  const subs = Array.isArray(vlmQ.sub_questions) ? vlmQ.sub_questions : [];
  const pieces = [];
  if (baseStem) pieces.push(baseStem);

  for (let i = 0; i < subs.length; i += 1) {
    const label = String(subs[i]?.label || `(${i + 1})`).trim();
    const text = String(subs[i]?.text || '').trim();
    if (!text) continue;
    // [소문항N] 은 반드시 "단독 라인" 이어야 렌더러(SUBQ_MARKER_LINE_RE) 가 마커로 소비한다.
    // 같은 라인에 본문을 붙이면 "[소문항1] (1) ..." 전체가 한 줄 텍스트가 되어 [ / ] 가
    // 수식 경계로 오인되어 $\displaystyle [$ 처럼 깨져 렌더된다.
    pieces.push('[문단]');
    pieces.push(`[소문항${i + 1}]`);
    pieces.push(`${label} ${text}`);
  }

  // 기존 문항이 그림을 가지고 있었다면 stem 끝에 [그림] 마커를 그 개수만큼 보존.
  if (existingFigureSlots > 0) {
    pieces.push('[문단]');
    pieces.push(Array.from({ length: existingFigureSlots }, () => '[그림]').join(' '));
  }
  return pieces.join('\n');
}

function deriveQuestionType(vlmQ) {
  const t = String(vlmQ.question_type || '').trim();
  if (vlmQ.is_set_question) return '주관식'; // 세트형은 주관식으로 통일(현 매니저 앱 규약)
  if (t === '객관식' || t === '주관식' || t === '서술형') return t;
  const hasChoices = Array.isArray(vlmQ.choices) && vlmQ.choices.length > 0;
  return hasChoices ? '객관식' : '주관식';
}

function buildRowUpdate(existingRow, vlmQ, opts = {}) {
  const existingMeta = (existingRow?.meta && typeof existingRow.meta === 'object') ? existingRow.meta : {};
  const figureAssets = Array.isArray(existingMeta.figure_assets) ? existingMeta.figure_assets : [];
  const figureLayout = existingMeta.figure_layout || null;
  const existingFigureSlots =
    figureLayout && Array.isArray(figureLayout.items) ? figureLayout.items.length : figureAssets.length;

  const vlmType = deriveQuestionType(vlmQ);
  const existingType = String(existingRow?.question_type || '').trim();
  // 세트형은 VLM 판단이 항상 우선. 그 외에는 --keep-type-from-db 옵션 여부에 따라 결정.
  const isSet = vlmQ.is_set_question === true;
  const qType = isSet ? '주관식' : (opts.keepTypeFromDb && existingType ? existingType : vlmType);
  const stem = buildStemWithSubQuestions(vlmQ, existingFigureSlots);

  const vlmChoices = Array.isArray(vlmQ.choices) ? vlmQ.choices : [];
  const objectiveChoices = vlmChoices.map((c, idx) => ({
    label: normalizeObjectiveLabel(c?.label, idx),
    text: String(c?.text || '').trim(),
  }));

  const objectiveAnswerKeyRaw = String(vlmQ?.answer?.objective_key || '').trim();
  const objectiveAnswerKey = objectiveAnswerKeyRaw ? normalizeObjectiveLabel(objectiveAnswerKeyRaw, -1) : '';
  const subjectiveAnswer = String(vlmQ?.answer?.subjective || '').trim();
  const answerParts = Array.isArray(vlmQ?.answer?.parts) ? vlmQ.answer.parts : [];

  const allowObjective = qType === '객관식' && objectiveChoices.length > 0;
  const allowSubjective = qType !== '객관식';

  const vlmFigures = Array.isArray(vlmQ.figures) ? vlmQ.figures : [];
  const vlmTables = Array.isArray(vlmQ.tables) ? vlmQ.tables : [];

  const newMeta = {
    ...existingMeta,
    is_set_question: isSet || existingMeta.is_set_question === true,
    answer_parts: isSet
      ? answerParts.map((p, i) => ({ sub: String(p.sub ?? i + 1), value: String(p.value ?? '') }))
      : [],
    answer_key: isSet ? subjectiveAnswer : (existingMeta.answer_key || ''),
    vlm: {
      model: 'gemini-3.1-pro-preview',
      source_page: vlmQ.source_page ?? null,
      confidence: vlmQ?.uncertain_fields?.length ? 'medium' : 'high',
      uncertain_fields: Array.isArray(vlmQ.uncertain_fields) ? vlmQ.uncertain_fields : [],
      figures_described: vlmFigures,
      tables_described: vlmTables,
      flags: Array.isArray(vlmQ.flags) ? vlmQ.flags : [],
      overwritten_at: new Date().toISOString(),
    },
  };

  // figure_refs 재구축:
  //   - 매니저 UI 는 figure_assets 가 비어 있으면 figure_refs.length 로 "그림 수" 를 대체 추정한다
  //     (problem_bank_screen.dart: fallbackCount = assets.isNotEmpty ? ... : max(1, figureRefs.length))
  //   - 기존 HWPX 파이프라인이 남긴 [표행]/[표셀]/[미주] 같은 표 파싱 마커가 섞여 있는 경우,
  //     figure_layout 다이얼로그에 "그림 23개" 처럼 쓰레기 카운트가 노출된다.
  //   - VLM 재덮어쓰기 시에는 "실제 stem 에 남아 있는 [그림] 마커 수 + 기존 figure_assets 수" 를
  //     기준으로 figure_refs 를 깨끗하게 재구성한다.
  const stemFigureMarkerCount = (String(stem).match(/\[그림\]/g) || []).length;
  const desiredRefCount = Math.max(stemFigureMarkerCount, figureAssets.length);
  const newFigureRefs = Array.from({ length: desiredRefCount }, () => '[그림]');

  const update = {
    stem,
    question_type: qType,
    objective_choices: allowObjective ? objectiveChoices : [],
    objective_answer_key: allowObjective ? objectiveAnswerKey : '',
    subjective_answer: allowSubjective ? (isSet ? subjectiveAnswer : subjectiveAnswer) : '',
    allow_objective: allowObjective,
    allow_subjective: allowSubjective || isSet,
    objective_generated: false,
    flags: Array.isArray(vlmQ.flags) ? vlmQ.flags : [],
    figure_refs: newFigureRefs,
    meta: newMeta,
    updated_at: new Date().toISOString(),
  };

  return update;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.documentId) {
    console.error('--document-id 필수');
    process.exit(2);
  }
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_ANON_KEY;
  if (!url || !key) {
    console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 필요');
    process.exit(2);
  }
  const c = createClient(url, key);

  // 롤백 분기
  if (args.rollback) {
    const backup = JSON.parse(fs.readFileSync(args.rollback, 'utf8'));
    console.log(`── 롤백 모드 ── 파일=${args.rollback} rows=${backup.rows?.length || 0}`);
    if (!args.apply) {
      console.log('(dry-run) --apply 없이는 아무것도 쓰지 않음');
      return;
    }
    for (const row of backup.rows || []) {
      const { id, ...rest } = row;
      const { error } = await c.from('pb_questions').update(rest).eq('id', id);
      if (error) {
        console.error(`rollback fail id=${id}: ${error.message}`);
      } else {
        console.log(`rollback ok Q${row.question_number} (id=${id})`);
      }
    }
    console.log('롤백 완료.');
    return;
  }

  if (!args.extracted) {
    console.error('--extracted 필수');
    process.exit(2);
  }
  const extractedAbs = path.resolve(args.extracted);
  if (!fs.existsSync(extractedAbs)) {
    console.error(`extracted.json not found: ${extractedAbs}`);
    process.exit(2);
  }
  const extracted = JSON.parse(fs.readFileSync(extractedAbs, 'utf8'));
  const rawVlmQuestions = Array.isArray(extracted?.questions) ? extracted.questions : [];
  // VLM 이 내보낸 \(...\) / \[...\] 를 XeLaTeX 가 이해하는 $...$ / $$...$$ 로 일괄 정규화.
  const vlmQuestions = rawVlmQuestions.map(normalizeVlmQuestion);
  if (!vlmQuestions.length) {
    console.error('VLM questions 비어있음. extracted.json 확인 필요');
    process.exit(2);
  }
  console.log(`── VLM overwrite ── document=${args.documentId}`);
  console.log(`   VLM questions: ${vlmQuestions.length}`);

  const { data: rows, error } = await c
    .from('pb_questions')
    .select('*')
    .eq('document_id', args.documentId);
  if (error) throw error;
  console.log(`   기존 pb_questions rows: ${rows.length}`);

  const byNum = new Map();
  for (const r of rows) {
    const k = normQNum(r.question_number);
    if (k) byNum.set(k, r);
  }

  const plan = [];
  const missingInDb = [];
  for (const q of vlmQuestions) {
    const k = normQNum(q.question_number);
    if (!k) continue;
    const existing = byNum.get(k);
    if (!existing) {
      missingInDb.push(k);
      continue;
    }
    const update = buildRowUpdate(existing, q, { keepTypeFromDb: args.keepTypeFromDb });
    plan.push({ id: existing.id, qnum: k, update, existing });
  }

  const extraInDb = [];
  const touched = new Set(plan.map((p) => p.qnum));
  for (const r of rows) {
    const k = normQNum(r.question_number);
    if (k && !touched.has(k)) extraInDb.push(k);
  }

  console.log('');
  console.log('── 덮어쓸 계획 ──');
  for (const p of plan) {
    const existingChoices = Array.isArray(p.existing.objective_choices) ? p.existing.objective_choices.length : 0;
    const newChoices = Array.isArray(p.update.objective_choices) ? p.update.objective_choices.length : 0;
    const existingIsSet = p.existing?.meta?.is_set_question === true;
    const newIsSet = p.update?.meta?.is_set_question === true;
    const existingFigs = Array.isArray(p.existing?.meta?.figure_assets) ? p.existing.meta.figure_assets.length : 0;
    const existingStemLen = String(p.existing.stem || '').length;
    const newStemLen = String(p.update.stem || '').length;
    const changes = [];
    if (p.existing.question_type !== p.update.question_type) changes.push(`type:${p.existing.question_type}→${p.update.question_type}`);
    if (existingChoices !== newChoices) changes.push(`choices:${existingChoices}→${newChoices}`);
    if (existingIsSet !== newIsSet) changes.push(`set:${existingIsSet}→${newIsSet}`);
    if (p.existing.objective_answer_key !== p.update.objective_answer_key)
      changes.push(`objkey:${p.existing.objective_answer_key || '-'}→${p.update.objective_answer_key || '-'}`);
    if (existingStemLen !== newStemLen) changes.push(`stem:${existingStemLen}→${newStemLen}`);
    console.log(
      `  Q${p.qnum.padStart(2)} figs_kept=${existingFigs} ${changes.length ? changes.join(' | ') : '(구조 동일, 내용만 업데이트)'}`,
    );
  }
  if (missingInDb.length) {
    console.log(`  ! VLM 에는 있으나 DB 에 없는 문항: ${missingInDb.join(', ')}`);
  }
  if (extraInDb.length) {
    console.log(`  ! DB 에는 있으나 VLM 에 없는 문항: ${extraInDb.join(', ')}  (이번에는 건드리지 않음)`);
  }

  if (!args.apply) {
    console.log('');
    console.log('(dry-run) --apply 를 붙이면 실제로 덮어씁니다.');
    return;
  }

  // 백업 파일 저장
  const extractedDir = path.dirname(extractedAbs);
  const backupPath = path.join(extractedDir, 'backup_before_overwrite.json');
  fs.writeFileSync(
    backupPath,
    JSON.stringify({ document_id: args.documentId, saved_at: new Date().toISOString(), rows }, null, 2),
    'utf8',
  );
  console.log(`백업 저장: ${backupPath}`);

  let ok = 0;
  let fail = 0;
  for (const p of plan) {
    const { error: upErr } = await c.from('pb_questions').update(p.update).eq('id', p.id);
    if (upErr) {
      console.error(`  Q${p.qnum} 실패: ${upErr.message}`);
      fail += 1;
    } else {
      ok += 1;
    }
  }
  console.log(`완료. ok=${ok} fail=${fail}`);
  console.log('');
  console.log('되돌리려면:');
  console.log(`  node scripts/vlm_overwrite_document.mjs --rollback "${backupPath}" --document-id ${args.documentId} --apply`);
}

main().catch((err) => {
  console.error('overwrite 실패:', err?.message || err);
  process.exitCode = 1;
});
