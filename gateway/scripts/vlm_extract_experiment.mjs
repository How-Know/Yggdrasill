// VLM(PDF 입력) 추출 실험 스크립트.
//
// 목적: 기존 HWPX 규칙 파서가 실패한 문서를 Gemini 에 PDF 그대로 넘겨
//       문항 추출 정확도 / 비용 / 지연을 측정한다. 기존 추출 파이프라인은
//       전혀 건드리지 않는 독립 실험 도구.
//
// 사용:
//   node scripts/vlm_extract_experiment.mjs \
//     --pdf "C:\\Users\\harry\\...\\대륜중.pdf" \
//     [--document-id <uuid>]   # 현재 DB 결과와 diff 를 찍을 때만 필요
//     [--model <gemini_model>] # 기본: PB_GEMINI_MODEL env (예: gemini-3.1-pro-preview)
//     [--out <dir>]            # 기본: gateway/experiments/<timestamp>_<basename>/
//
// 출력:
//   - <out>/prompt.txt, response.json, extracted.json, metrics.json
//   - stdout 에 요약 리포트 (문항 수, 추정 토큰, 비용, 지연)

import 'dotenv/config';
import fs from 'fs';
import path from 'path';
import { createClient } from '@supabase/supabase-js';

const GEMINI_API_KEY = String(process.env.GEMINI_API_KEY || '').trim();
const DEFAULT_MODEL = String(process.env.PB_GEMINI_MODEL || 'gemini-3.1-pro-preview').trim();

function parseArgs(argv) {
  const out = { pdf: '', documentId: '', model: DEFAULT_MODEL, outDir: '' };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '--pdf') out.pdf = argv[++i] || '';
    else if (a === '--document-id' || a === '--doc') out.documentId = argv[++i] || '';
    else if (a === '--model') out.model = argv[++i] || DEFAULT_MODEL;
    else if (a === '--out') out.outDir = argv[++i] || '';
  }
  return out;
}

function buildPrompt() {
  // 목표: Yggdrasill 기존 HWPX 파이프라인과 "동일한 stem 포맷" 을 출력하도록 VLM 을
  // 강하게 제약한다. 렌더러(xelatex/template.js:smartTexLine) 는 stem 을 다음 규약
  // 위에서 해석한다:
  //   - 한국어 덩어리는 \text 로, 비한국어 연속 구간은 $\displaystyle ...$ 로 감쌈
  //   - 줄바꿈과 [문단] 마커는 문단 경계
  //   - [그림] / [표] / [보기시작]/[보기끝] / [박스시작]/[박스끝] / [소문항N] 마커를 해석
  //
  // 따라서 stem 에 수식 delimiter \(...\) 나 $...$ 를 섞으면 이중 감싸기로 실패한다.
  // VLM 은 순수 LaTeX 명령(\frac, \times 등)만 내보내고 delimiter 는 쓰지 않는다.
  return [
    '당신은 한국 중·고등학교 수학 시험지 PDF 를 분석해 문항을 "Yggdrasill stem 포맷" 의 구조화 JSON 으로 추출하는 AI 입니다.',
    '반드시 다음 JSON 스키마만 출력합니다. 설명 문장·마크다운 금지. JSON 외 어떤 텍스트도 출력하지 마세요.',
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "document_meta": {',
    '    "total_questions": <정수>,',
    '    "page_count": <정수>,',
    '    "confidence": "high" | "medium" | "low"',
    '  },',
    '  "questions": [',
    '    {',
    '      "question_number": "1",',
    '      "source_page": 1,',
    '      "stem": "Yggdrasill stem 포맷 문자열 — 아래 === STEM 포맷 규칙 === 준수",',
    '      "question_type": "객관식" | "주관식" | "서술형",',
    '      "is_set_question": false,',
    '      "sub_questions": [ { "label": "(1)", "text": "소문항 본문 (stem 과 동일한 포맷)" } ],',
    '      "choices": [ { "label": "①", "text": "선택지 본문 (stem 과 동일한 포맷)" } ],',
    '      "answer": {',
    '        "objective_key": "①",',
    '        "subjective": "정답 문자열 (세트형은 \\"(1) 12 (2) ㄱ, ㄷ\\" 형식)",',
    '        "parts": [ { "sub": "1", "value": "12" }, { "sub": "2", "value": "ㄱ, ㄷ" } ]',
    '      },',
    '      "score": <실수 또는 null>,',
    '      "figures": [ { "order": 1, "description": "그림 간단 설명" } ],',
    '      "tables":  [ { "order": 1, "rows": <정수>, "cols": <정수>, "has_diagonal_cell": <bool>, "description": "표 간단 설명", "rendered_as": "tabular" | "image" } ],',
    '      "flags": [ "contains_figure" | "contains_table" | "contains_box" | "contains_view_block" ],',
    '      "uncertain_fields": [ "choices" | "answer" | "figures" | "tables" | "stem" | "..." ]',
    '    }',
    '  ]',
    '}',
    '',
    '=== STEM 포맷 규칙 (매우 중요) ===',
    '[S1] 수식은 LaTeX 명령만 사용하되 "delimiter 를 쓰지 마라" (\\( \\) / \\[ \\] / $ / $$ 전부 금지).',
    '     예) 올바른: "a + \\frac{b}{c} = 3"     잘못된: "\\(a + \\frac{b}{c}\\) = 3"  /  "$a+\\frac{b}{c}$"',
    '[S2] 곱셈 기호는 "\\times", 나눗셈은 "\\div", ±는 "\\pm", ≤≥≠는 "\\leq","\\geq","\\neq" 로만 표기. 알파벳 x / ÷ / ± 문자 직접 사용 금지.',
    '[S3] 분수는 반드시 "\\frac{a}{b}" 형태. "a/b" 같은 슬래시 분수 금지 (단, 정답 문자열은 허용).',
    '[S4] 본문 중간에 등장하는 모든 그림·도형은 해당 위치에 "[그림]" 마커를 삽입해 자리를 잡아라. 여러 개면 각각 "[그림]" 을 삽입.',
    '     stem 내부에서 그림을 언급할 때 "[그림1]", "[그림2]" 같은 참조 문구가 실제 인쇄돼 있으면 그대로 유지하되, 그림 자체가 있던 자리에도 별도로 "[그림]" 을 넣는다.',
    '[S5] 본문 중간에 등장하는 모든 "표" 는 해당 위치를 다음 중 하나로 표기한다:',
    '     (a) 단순 행/열 표 (대각선 셀·병합 셀 없음, 텍스트·숫자·수식만)  → "[표시작]" ... "[표끝]" 사이에 LaTeX tabular 로 재현한다.',
    '         cellspec 은 "|c|c|..." 처럼 모든 열을 c 정렬로 둔다. \\\\begin{tabular}...\\\\end{tabular} 전체를 넣어라.',
    '         ★ tabular 셀 안에 수식 명령(\\\\times, \\\\frac, \\\\pm, \\\\leq ...) 이 있으면 그 셀을 반드시 "$...$" 로 감싸라.',
    '         ★ tabular 셀 안에 한글이 있으면 그 셀을 반드시 "\\\\text{...}" 로 감싸라 (예: "\\\\text{자연수}").',
    '         ★ 빈 셀이나 단순 숫자/기호 (○, ×, -, +, 3, 0.5) 는 감싸지 않아도 된다.',
    '         예시: "[표시작]\\n\\\\begin{tabular}{|c|c|c|}\\n\\\\hline\\n\\\\text{수의 분류} & 3 & -3 \\\\\\\\\\n\\\\hline\\n\\\\text{자연수} & ○ & $\\\\times$ \\\\\\\\\\n\\\\hline\\n\\\\end{tabular}\\n[표끝]"',
    '     (b) 대각선 셀을 가진 표, 여러 셀 병합, 도형 삽입 같은 복잡한 표  → tabular 로 재현 불가. "[그림]" 마커 하나만 남겨 이미지로 처리한다는 신호.',
    '         또한 해당 questions[].tables[i].rendered_as 를 "image" 로 세팅한다.',
    '[S6] 문단 구분은 개행 또는 "[문단]" 마커로 표기 (렌더러가 여백을 잡는다). 불필요하게 많이 쓰지 말 것.',
    '[S7] 보기 박스 (<보기> 또는 <보 기>) 는 "[보기시작]" ... "[보기끝]" 사이에 본문을 그대로 담는다.',
    '     조건·규칙 박스(보기 아님)는 "[박스시작]" ... "[박스끝]" 사이에 담는다. 두 마커를 혼동하지 말 것.',
    '[S8] 세트형(하위문항 (1),(2),... 로 구성) 은 다음 규칙을 지킨다:',
    '     - is_set_question = true, sub_questions 배열에 각 소문항을 채운다.',
    '     - sub_questions[i].text 는 "(1)" 같은 레이블을 제외한 "본문만" 담는다. 레이블은 label 필드로 분리.',
    '     - stem 에는 공통 도입 문장만 남긴다 ("물음에 답하시오." 가 있으면 유지).',
    '     - answer.parts 는 각 소문항 정답, answer.subjective 는 화면 표시용 전체 문자열 "(1) X (2) Y".',
    '[S9] 객관식 선택지 ①~⑤ 는 choices 에 순서대로 담고 answer.objective_key 에 "①".."⑤" 를 넣는다. 정답을 모르면 "".',
    '[S10] 배점 "[N점]" 이 문제 번호 옆에 있으면 score=N (실수), 없으면 null.',
    '[S11] 판단이 불확실한 필드는 uncertain_fields 에 필드명을 넣고, 추측 값 대신 빈 값("" / null / [])으로 둔다.',
    '',
    '=== 문항 수 / 범위 규칙 ===',
    '[R1] PDF 에 실제로 인쇄된 문항만 추출 (해설/풀이 페이지 제외).',
    '[R2] document_meta.total_questions 는 questions 배열 길이와 반드시 일치.',
    '[R3] 문항 번호는 시험지 상 번호(1, 2, 3...) 그대로.',
    '',
    '=== JSON 이스케이프 규칙 (반드시 지킬 것) ===',
    '[E1] JSON 문자열 안의 LaTeX 백슬래시 "\\" 는 "\\\\" 로 이스케이프해야 한다. 즉 출력 JSON 에서',
    '     "stem": "\\\\frac{1}{2}" / "\\\\times" / "\\\\leq" 처럼 한 번 더 백슬래시를 넣어라.',
    '     "\\frac" 처럼 1 개만 쓰면 JSON 파서 실패한다.',
    '[E2] 줄바꿈은 "\\n" 으로 작성하라 (JSON 리터럴 "\\\\n" 이 아니라 실제 개행 이스케이프).',
    '',
    '=== 예시 (형식만 참고, 실제 문제는 PDF 에 있는 것만 추출) ===',
    'stem 예시 A (그림 없음, 분수 있음):  "두 분수 \\frac{27}{14}, \\frac{63}{20} 의 어느 것에 곱해도 항상 자연수가 되게 하는 가장 작은 기약분수를 구하시오."',
    'stem 예시 B (표 재현):               "다음 표를 완성하여라.\\n[문단]\\n[표시작]\\n\\\\begin{tabular}{|c|c|c|}\\n\\\\hline\\na & b & c \\\\\\\\\\n\\\\hline\\n\\\\end{tabular}\\n[표끝]"',
    'stem 예시 C (그림 + 보기):           "다음 그림과 <보기> 의 설명에 대해 옳은 것을 고르시오.\\n[문단]\\n[그림]\\n[문단]\\n[보기시작]\\nㄱ. a+b>0\\nㄴ. ab<0\\n[보기끝]"',
    'stem 예시 D (세트형 공통 도입):      "다음 물음에 답하시오."  (sub_questions 에 (1)/(2) 본문 분리)',
    '',
    '지금 첨부된 PDF 를 분석해 위 스키마로만 출력하라. 반드시 stem 에 delimiter(\\(, \\[, $) 를 쓰지 말 것.',
  ].join('\n');
}

// JSON 문자열 리터럴 안에서 "\X (X 가 허용 escape 아님)" 을 "\\X" 로 바꿔 파싱 가능하게 만든다.
// 허용 escape: \" \\ \/ \b \f \n \r \t \uXXXX.
// 문자열 리터럴 밖은 건드리지 않는다 ("스캔 상태머신" 이 필요함).
function repairLatexBackslashes(input) {
  if (typeof input !== 'string' || !input) return input;
  const out = [];
  let inString = false;
  let escapeNext = false; // 바로 앞 문자가 백슬래시인 상태 (유효 escape 처리 중)
  for (let i = 0; i < input.length; i += 1) {
    const ch = input[i];
    if (!inString) {
      out.push(ch);
      if (ch === '"') {
        inString = true;
        escapeNext = false;
      }
      continue;
    }
    // inString = true
    if (escapeNext) {
      // 이전 문자가 '\' 라 어떤 문자가 오든 리터럴처럼 통과. (이미 out 에 '\' 를 넣어두었음)
      out.push(ch);
      escapeNext = false;
      continue;
    }
    if (ch === '\\') {
      const nx = input[i + 1];
      const valid = nx && /["\\/bfnrtu]/.test(nx);
      if (valid) {
        out.push(ch); // '\'
        escapeNext = true; // 다음 문자 통과
      } else {
        // JSON 에서 허용 안 되는 escape → '\\' 로 이스케이프 보정.
        out.push('\\', '\\');
        // 다음 문자는 일반 문자로 처리되도록 escapeNext=false 유지.
      }
      continue;
    }
    if (ch === '"') {
      out.push(ch);
      inString = false;
      continue;
    }
    out.push(ch);
  }
  return out.join('');
}

async function callGeminiWithPdf({ pdfBuffer, model, timeoutMs = 180000 }) {
  if (!GEMINI_API_KEY) throw new Error('GEMINI_API_KEY is empty');
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=` +
    `${encodeURIComponent(GEMINI_API_KEY)}`;

  const body = {
    contents: [
      {
        role: 'user',
        parts: [
          {
            inline_data: {
              mime_type: 'application/pdf',
              data: pdfBuffer.toString('base64'),
            },
          },
          { text: buildPrompt() },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.1,
      responseMimeType: 'application/json',
      // 주의: Gemini 3.x 에서 maxOutputTokens 는 thinking 토큰까지 포함하는 "전체 출력 상한".
      // 3.1 Pro 는 thinking 비활성화 불가 → thinkingLevel=low 로 사고 토큰을 최소화.
      // 17문항 JSON 은 실제 출력 ~6~8k 토큰, thinking low 권장 ~2~3k 토큰 → 32k 로 여유.
      maxOutputTokens: 32768,
      thinkingConfig: {
        thinkingLevel: 'low',
      },
    },
  };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const t0 = Date.now();
  let res;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
  const elapsedMs = Date.now() - t0;
  const textBody = await res.text();
  if (!res.ok) {
    throw new Error(`gemini_http_${res.status}: ${textBody.slice(0, 500)}`);
  }
  let payload;
  try {
    payload = JSON.parse(textBody);
  } catch (_) {
    throw new Error(`gemini_non_json_response: ${textBody.slice(0, 500)}`);
  }
  const candidate = (payload?.candidates || [])[0];
  const modelText = (candidate?.content?.parts || [])
    .map((p) => p?.text || '')
    .join('\n')
    .trim();
  let parsedJson = null;
  try {
    parsedJson = JSON.parse(modelText);
  } catch (_) {
    // Gemini 가 LaTeX 백슬래시를 JSON 이스케이프하지 않고 그대로 넣는 경우가 있다.
    //   예) "stem": "\frac{1}{2}"  ← JSON 파서 입장에서 "\f" 는 허용되지만 "\frac" 은 invalid escape.
    //   예) "\square" 의 "\s"  → invalid.
    // 전략: 문자열 리터럴 내부에서만 "유효하지 않은 JSON escape" 뒤의 백슬래시를 한 번 더 붙여 "\\" 로 고친다.
    const repaired = repairLatexBackslashes(modelText);
    try {
      parsedJson = JSON.parse(repaired);
    } catch (_) {
      const m = repaired.match(/\{[\s\S]*\}/);
      if (m) {
        try { parsedJson = JSON.parse(m[0]); } catch (_) {}
      }
    }
  }
  return {
    rawPayload: payload,
    modelText,
    parsedJson,
    elapsedMs,
    usageMetadata: payload?.usageMetadata || null,
    finishReason: candidate?.finishReason || '',
  };
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

function basenameWithoutExt(p) {
  const b = path.basename(p);
  const i = b.lastIndexOf('.');
  return i > 0 ? b.slice(0, i) : b;
}

async function loadSupabaseGroundTruth(documentId) {
  if (!documentId) return null;
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_ANON_KEY;
  if (!url || !key) return null;
  const c = createClient(url, key);
  const { data: rows, error } = await c
    .from('pb_questions')
    .select(
      'question_number,question_type,stem,choices,subjective_answer,objective_answer_key,meta,figure_refs,source_page',
    )
    .eq('document_id', documentId);
  if (error) throw new Error(`supabase_error: ${error.message}`);
  return Array.isArray(rows) ? rows : [];
}

function normalizeQNum(v) {
  return String(Number.parseInt(String(v || '').trim(), 10) || '');
}

function buildDiff(existingRows, vlmQuestions) {
  const byExisting = new Map();
  for (const q of existingRows || []) {
    const n = normalizeQNum(q.question_number);
    if (n) byExisting.set(n, q);
  }
  const byVlm = new Map();
  for (const q of vlmQuestions || []) {
    const n = normalizeQNum(q.question_number);
    if (n) byVlm.set(n, q);
  }
  const allNums = Array.from(new Set([...byExisting.keys(), ...byVlm.keys()]))
    .map((n) => Number.parseInt(n, 10))
    .sort((a, b) => a - b);

  const rows = [];
  let agreeCount = 0;
  let disagreeCount = 0;
  for (const n of allNums) {
    const key = String(n);
    const a = byExisting.get(key);
    const b = byVlm.get(key);
    const inA = !!a;
    const inB = !!b;

    const aType = a?.question_type || '';
    const bType = b?.question_type || '';
    const aIsSet = a?.meta?.is_set_question === true;
    const bIsSet = b?.is_set_question === true;
    const aObj = (a?.objective_answer_key || '').trim();
    const bObj = (b?.answer?.objective_key || '').trim();
    const aSub = (a?.subjective_answer || '').trim();
    const bSub = (b?.answer?.subjective || '').trim();
    const aChoices = Array.isArray(a?.choices) ? a.choices.length : 0;
    const bChoices = Array.isArray(b?.choices) ? b.choices.length : 0;

    const issues = [];
    if (!inA) issues.push('missing_in_existing');
    if (!inB) issues.push('missing_in_vlm');
    if (inA && inB) {
      if (aType !== bType) issues.push(`type:${aType}_vs_${bType}`);
      if (aIsSet !== bIsSet) issues.push(`set:${aIsSet}_vs_${bIsSet}`);
      if (aObj !== bObj) issues.push(`obj:${aObj || '-'}_vs_${bObj || '-'}`);
      if (aSub !== bSub) issues.push('sub_diff');
      if (aChoices !== bChoices) issues.push(`choices:${aChoices}_vs_${bChoices}`);
    }
    if (issues.length === 0 && inA && inB) agreeCount += 1;
    else disagreeCount += 1;
    rows.push({ q: key, inA, inB, issues });
  }

  return { rows, agreeCount, disagreeCount, totalA: existingRows?.length || 0, totalB: vlmQuestions?.length || 0 };
}

// 공식 가격 (2026-04 기준; 실험 목적 근사치)
//   gemini-3.1-pro-preview 기준 추정: $2 / 1M input, $8 / 1M output
//   * 주의: Google 가격은 수시 변동. 리포트에 공식가 아니라고 명시.
function estimateCostUsd(usageMetadata, model) {
  if (!usageMetadata) return { inputUsd: null, outputUsd: null, totalUsd: null, note: 'no_usage_metadata' };
  const inputTokens = Number(usageMetadata.promptTokenCount || 0);
  const outputTokens = Number(usageMetadata.candidatesTokenCount || 0);
  // 매우 러프한 추정. 변동 있음.
  const perM = { input: 2.0, output: 8.0 };
  const inputUsd = (inputTokens / 1_000_000) * perM.input;
  const outputUsd = (outputTokens / 1_000_000) * perM.output;
  return {
    inputTokens,
    outputTokens,
    inputUsd,
    outputUsd,
    totalUsd: inputUsd + outputUsd,
    note: `러프 추정 (input=$${perM.input}/1M, output=$${perM.output}/1M). 모델: ${model}`,
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.pdf) {
    console.error('usage: node scripts/vlm_extract_experiment.mjs --pdf <path> [--document-id <uuid>] [--model <name>] [--out <dir>]');
    process.exit(2);
  }
  if (!fs.existsSync(args.pdf)) {
    console.error(`PDF not found: ${args.pdf}`);
    process.exit(2);
  }

  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const outDir =
    args.outDir ||
    path.join(
      path.dirname(new URL(import.meta.url).pathname.replace(/^\//, '')),
      '..',
      'experiments',
      `${ts}_${basenameWithoutExt(args.pdf)}`,
    );
  ensureDir(outDir);

  const pdfBuffer = fs.readFileSync(args.pdf);
  const pdfSize = pdfBuffer.length;

  console.log('── VLM 추출 실험 ──');
  console.log(`PDF       : ${args.pdf}`);
  console.log(`PDF 크기  : ${(pdfSize / 1024).toFixed(1)} KB`);
  console.log(`Model     : ${args.model}`);
  console.log(`Out       : ${outDir}`);
  if (args.documentId) console.log(`Ground DB : document_id=${args.documentId}`);
  console.log('');

  fs.writeFileSync(path.join(outDir, 'prompt.txt'), buildPrompt(), 'utf8');

  console.log('[1/3] Gemini 호출 중...');
  const result = await callGeminiWithPdf({
    pdfBuffer,
    model: args.model,
  });
  fs.writeFileSync(path.join(outDir, 'response.json'), JSON.stringify(result.rawPayload, null, 2), 'utf8');
  fs.writeFileSync(path.join(outDir, 'model_text.txt'), result.modelText || '', 'utf8');
  if (result.parsedJson) {
    fs.writeFileSync(path.join(outDir, 'extracted.json'), JSON.stringify(result.parsedJson, null, 2), 'utf8');
  }

  const cost = estimateCostUsd(result.usageMetadata, args.model);
  const vlmQuestions = Array.isArray(result.parsedJson?.questions) ? result.parsedJson.questions : [];
  console.log(`        → 파싱 성공=${result.parsedJson ? 'yes' : 'NO'}, finish=${result.finishReason || '-'}`);
  console.log(`        → 지연 ${result.elapsedMs} ms`);
  if (cost.inputTokens != null) {
    const thoughtTokens = Number(result.usageMetadata?.thoughtsTokenCount || 0);
    console.log(`        → 토큰 input=${cost.inputTokens} output=${cost.outputTokens} thinking=${thoughtTokens}`);
    console.log(`        → 추정 비용 $${cost.totalUsd.toFixed(4)} (${cost.note})`);
  }
  console.log('');

  console.log('[2/3] VLM 결과 요약');
  console.log(`        총 문항 수 (VLM): ${vlmQuestions.length}`);
  console.log(`        total_questions(meta): ${result.parsedJson?.document_meta?.total_questions ?? '-'}`);
  console.log(`        confidence(meta): ${result.parsedJson?.document_meta?.confidence ?? '-'}`);
  const setQs = vlmQuestions.filter((q) => q?.is_set_question === true).length;
  const objQs = vlmQuestions.filter((q) => q?.question_type === '객관식').length;
  const subQs = vlmQuestions.filter((q) => q?.question_type === '주관식').length;
  const essayQs = vlmQuestions.filter((q) => q?.question_type === '서술형').length;
  console.log(`        타입 분포: 객관식=${objQs}, 주관식=${subQs}, 서술형=${essayQs}, 세트형=${setQs}`);
  const uncertainQs = vlmQuestions.filter((q) => Array.isArray(q?.uncertain_fields) && q.uncertain_fields.length > 0).length;
  console.log(`        불확실 필드 신고 문항: ${uncertainQs}`);
  console.log('');

  console.log('[3/3] 기존 DB 결과와 diff');
  let diff = null;
  try {
    const existing = await loadSupabaseGroundTruth(args.documentId);
    if (existing == null) {
      console.log('        (document_id 미지정 또는 Supabase 미구성 → diff 생략)');
    } else {
      diff = buildDiff(existing, vlmQuestions);
      console.log(`        기존 문항: ${diff.totalA}개 / VLM 문항: ${diff.totalB}개`);
      console.log(`        완전 일치: ${diff.agreeCount} / 차이 있음: ${diff.disagreeCount}`);
      console.log('        ─ 문항별 차이 ─');
      for (const r of diff.rows) {
        if (r.issues.length === 0) continue;
        console.log(`        Q${r.q.padStart(2, ' ')}  [${r.inA ? 'A' : '-'}${r.inB ? 'B' : '-'}]  ${r.issues.join(' | ')}`);
      }
    }
  } catch (e) {
    console.log(`        (Supabase diff 실패: ${e.message})`);
  }
  console.log('');

  const metrics = {
    pdf: args.pdf,
    pdfSizeBytes: pdfSize,
    model: args.model,
    elapsedMs: result.elapsedMs,
    parsed: !!result.parsedJson,
    finishReason: result.finishReason,
    usage: result.usageMetadata || null,
    costUsdEstimate: cost,
    totals: {
      vlmQuestions: vlmQuestions.length,
      metaTotalQuestions: result.parsedJson?.document_meta?.total_questions ?? null,
      setQuestions: setQs,
      objectiveQuestions: objQs,
      subjectiveQuestions: subQs,
      essayQuestions: essayQs,
      uncertainQuestions: uncertainQs,
    },
    diff,
  };
  fs.writeFileSync(path.join(outDir, 'metrics.json'), JSON.stringify(metrics, null, 2), 'utf8');
  console.log(`완료. 모든 산출물: ${outDir}`);
}

main().catch((err) => {
  console.error('실험 실패:', err?.message || err);
  process.exitCode = 1;
});
