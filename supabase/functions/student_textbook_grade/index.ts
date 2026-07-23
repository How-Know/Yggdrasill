// 학생용 앱 "교재 풀기" 채점 Edge Function.
//
// RPC(student_grade_textbook_page)에서 승격된 이유:
//   * 수치 평가 기반 수학 동치 채점 (1/2 ↔ 2/4, 8 ↔ 2^3, 2√3 ↔ √12)
//   * 단위 해석/환산 (54마리 ↔ 54, 10m ↔ 1000cm)
//   * AI 판정 (발문의 단위 지정 여부, 한글 표현 동치) + DB 캐시
//   * 셀프 채점(정답 공개 + O/X)용 정답/렌더 이미지 서명 URL 발급
//
// actions:
//   grade     { book_id, grade_label, items: [{crop_id, answer}] }
//             세트형 파트 채점: items: [{crop_id, parts: [{key, answer}]}]
//   reveal    { crop_id }                          — self 모드 문항만 정답 공개
//             세트형이면 parts([{key, mode, text?}] — text는 self 파트만) 동봉
//   self_mark { book_id, grade_label, crop_id, correct, answer? }
//             세트형 파트 O/X: { crop_id, part_marks: [{key, correct}] }
//
// 세트형 문항은 crop당 기록 하나를 유지하되 part_results에 파트별 결과를
// 누적하고, is_correct는 서버가 "모든 파트 정답"으로 계산한다.
//
// AI 제공자: GEMINI_API_KEY 있으면 Gemini, 없으면 OPENAI_API_KEY 로 OpenAI.
// 둘 다 없으면 AI 판정 없이 안전한 기본값(단위 주의 표시)으로 동작한다.

import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';
import {
  compareAnswers,
  gradingMode,
  normalizeMathLinear,
  type SetAnswerPart,
  splitSetAnswerParts,
} from './grading.ts';

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// ---------------------------------------------------------------------------
// AI 판정
// ---------------------------------------------------------------------------

interface AiContext {
  stem: string | null; // pb_questions 본문 (연결된 경우)
  imageBase64: string | null; // 문항 크롭 PNG (본문 없을 때)
  imageMime: string;
}

async function callGemini(prompt: string, ctx: AiContext, apiKey: string) {
  const model = Deno.env.get('GEMINI_MODEL') || 'gemini-3.1-pro-preview';
  const parts: unknown[] = [];
  if (!ctx.stem && ctx.imageBase64) {
    parts.push({ inline_data: { mime_type: ctx.imageMime, data: ctx.imageBase64 } });
  }
  parts.push({ text: prompt });
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ role: 'user', parts }],
        generationConfig: {
          temperature: 0,
          responseMimeType: 'application/json',
          maxOutputTokens: 1024,
        },
      }),
    },
  );
  if (!res.ok) throw new Error(`gemini_http_${res.status}`);
  const payload = await res.json();
  const text = (payload?.candidates?.[0]?.content?.parts ?? [])
    .map((p: { text?: string }) => p?.text ?? '')
    .join('\n')
    .trim();
  return { parsed: JSON.parse(text), model };
}

async function callOpenAi(prompt: string, ctx: AiContext, apiKey: string) {
  const model = Deno.env.get('OPENAI_MODEL') || 'gpt-4.1-mini';
  const content: unknown[] = [];
  if (!ctx.stem && ctx.imageBase64) {
    content.push({
      type: 'image_url',
      image_url: { url: `data:${ctx.imageMime};base64,${ctx.imageBase64}` },
    });
  }
  content.push({ type: 'text', text: prompt });
  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model,
      temperature: 0,
      response_format: { type: 'json_object' },
      messages: [{ role: 'user', content }],
    }),
  });
  if (!res.ok) throw new Error(`openai_http_${res.status}`);
  const payload = await res.json();
  const text = String(payload?.choices?.[0]?.message?.content ?? '').trim();
  return { parsed: JSON.parse(text), model };
}

async function callAi(prompt: string, ctx: AiContext) {
  const gemini = Deno.env.get('GEMINI_API_KEY')?.trim();
  if (gemini) return await callGemini(prompt, ctx, gemini);
  const openai = Deno.env.get('OPENAI_API_KEY')?.trim();
  if (openai) return await callOpenAi(prompt, ctx, openai);
  return null;
}

// deno-lint-ignore no-explicit-any
type Admin = any;

/** 문항 본문(있으면) 또는 크롭 이미지를 AI 컨텍스트로 준비. */
async function buildAiContext(
  admin: Admin,
  crop: {
    id: string;
    pb_question_uid: string | null;
    storage_bucket: string;
    storage_key: string;
  },
): Promise<AiContext> {
  if (crop.pb_question_uid) {
    const { data } = await admin
      .from('pb_questions')
      .select('stem')
      .eq('question_uid', crop.pb_question_uid)
      .maybeSingle();
    const stem = String(data?.stem ?? '').trim();
    if (stem) return { stem, imageBase64: null, imageMime: 'image/png' };
  }
  try {
    const { data } = await admin.storage
      .from(crop.storage_bucket)
      .download(crop.storage_key);
    if (data) {
      const buf = new Uint8Array(await data.arrayBuffer());
      let bin = '';
      const chunk = 0x8000;
      for (let i = 0; i < buf.length; i += chunk) {
        bin += String.fromCharCode(...buf.subarray(i, i + chunk));
      }
      return { stem: null, imageBase64: btoa(bin), imageMime: 'image/png' };
    }
  } catch (_) {
    // 이미지 없이 진행 (텍스트 프롬프트만)
  }
  return { stem: null, imageBase64: null, imageMime: 'image/png' };
}

async function cachedAiVerdict(
  admin: Admin,
  cropId: string,
  cacheKey: string,
  run: () => Promise<{ verdict: Record<string, unknown>; model: string } | null>,
): Promise<Record<string, unknown> | null> {
  const { data: hit } = await admin
    .from('student_grading_ai_cache')
    .select('verdict')
    .eq('crop_id', cropId)
    .eq('cache_key', cacheKey)
    .maybeSingle();
  if (hit?.verdict) return hit.verdict as Record<string, unknown>;

  const result = await run();
  if (result === null) return null;
  await admin.from('student_grading_ai_cache').upsert(
    {
      crop_id: cropId,
      cache_key: cacheKey,
      verdict: result.verdict,
      model: result.model,
    },
    { onConflict: 'crop_id,cache_key' },
  );
  return result.verdict;
}

/** 발문이 답의 단위를 지정하는지 AI 판정. 실패 시 null. */
async function judgeUnitSpecified(
  admin: Admin,
  crop: Parameters<typeof buildAiContext>[1],
): Promise<boolean | null> {
  const verdict = await cachedAiVerdict(admin, crop.id, 'unit_spec:v1', async () => {
    const ctx = await buildAiContext(admin, crop);
    if (!ctx.stem && !ctx.imageBase64) return null;
    const prompt = [
      '너는 수학 문제 발문 분석기다.',
      ctx.stem
        ? `다음은 문제 본문이다:\n---\n${ctx.stem}\n---`
        : '첨부된 이미지는 수학 문제다.',
      '이 문제가 답을 특정 단위로 쓰라고 지정하는지 판단하라.',
      '예: "몇 cm인지 구하시오", "답을 분 단위로 쓰시오" → 지정함.',
      '단순히 문제 상황에 단위가 등장하는 것만으로는 지정이 아니다.',
      'JSON으로만 답하라: {"unit_specified": true|false, "unit": "지정된 단위 또는 null"}',
    ].join('\n');
    const res = await callAi(prompt, ctx);
    if (res === null) return null;
    return { verdict: res.parsed as Record<string, unknown>, model: res.model };
  });
  if (verdict === null) return null;
  return verdict.unit_specified === true;
}

/** 한글 서술 답 동치 AI 판정. 실패 시 null. */
async function judgeEquivalence(
  admin: Admin,
  crop: Parameters<typeof buildAiContext>[1],
  correct: string,
  student: string,
): Promise<boolean | null> {
  const key = `equiv:v1:${normalizeMathLinear(student).replace(/\s+/g, '').slice(0, 120)}`;
  const verdict = await cachedAiVerdict(admin, crop.id, key, async () => {
    const prompt = [
      '너는 수학 채점 보조자다. 정답과 학생 답이 의미상 같은지 판단하라.',
      '표현/조사/어순 차이는 무시하되, 수학적 의미가 다르면 다른 답이다.',
      `정답: ${correct}`,
      `학생 답: ${student}`,
      'JSON으로만 답하라: {"equivalent": true|false}',
    ].join('\n');
    const res = await callAi(prompt, {
      stem: 'text-only',
      imageBase64: null,
      imageMime: 'image/png',
    });
    if (res === null) return null;
    return { verdict: res.parsed as Record<string, unknown>, model: res.model };
  });
  if (verdict === null) return null;
  return verdict.equivalent === true;
}

// ---------------------------------------------------------------------------
// 본인 확인
// ---------------------------------------------------------------------------
async function resolveStudent(req: Request, admin: Admin) {
  const auth = req.headers.get('Authorization') ?? '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  if (!token) return null;
  const { data: userData, error } = await admin.auth.getUser(token);
  if (error || !userData?.user) return null;
  const { data: account } = await admin
    .from('student_app_accounts')
    .select('academy_id, student_id')
    .eq('user_id', userData.user.id)
    .maybeSingle();
  if (!account) return null;
  return {
    academyId: account.academy_id as string,
    studentId: account.student_id as string,
  };
}

// ---------------------------------------------------------------------------
// 기록 upsert
// ---------------------------------------------------------------------------
async function upsertRecord(
  admin: Admin,
  args: {
    academyId: string;
    studentId: string;
    bookId: string;
    gradeLabel: string;
    cropId: string;
    answer: string | null;
    correct: boolean;
    gradedBy: 'auto' | 'self';
    flags: string[];
    partResults?: PartResult[];
  },
) {
  const { data: existing } = await admin
    .from('student_textbook_answer_records')
    .select('id, attempt_count, first_correct_at')
    .eq('student_id', args.studentId)
    .eq('crop_id', args.cropId)
    .maybeSingle();

  const firstCorrectAt = existing?.first_correct_at ??
    (args.correct ? new Date().toISOString() : null);

  const row: Record<string, unknown> = {
    academy_id: args.academyId,
    student_id: args.studentId,
    book_id: args.bookId,
    grade_label: args.gradeLabel,
    crop_id: args.cropId,
    last_answer: args.answer,
    is_correct: args.correct,
    attempt_count: (existing?.attempt_count ?? 0) + 1,
    first_correct_at: firstCorrectAt,
    graded_by: args.gradedBy,
    flags: args.flags,
    updated_at: new Date().toISOString(),
  };
  if (args.partResults !== undefined) row.part_results = args.partResults;

  await admin.from('student_textbook_answer_records').upsert(
    row,
    { onConflict: 'student_id,crop_id' },
  );
}

// ---------------------------------------------------------------------------
// 세트형 파트 결과
// ---------------------------------------------------------------------------

interface PartResult {
  key: string; // '(1)'
  answer: string | null;
  correct: boolean;
  graded_by: 'auto' | 'self';
  flags: string[];
}

async function loadPartResults(
  admin: Admin,
  studentId: string,
  cropId: string,
): Promise<PartResult[]> {
  const { data } = await admin
    .from('student_textbook_answer_records')
    .select('part_results')
    .eq('student_id', studentId)
    .eq('crop_id', cropId)
    .maybeSingle();
  const raw = data?.part_results;
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((p: Record<string, unknown>) => typeof p?.key === 'string')
    .map((p: Record<string, unknown>) => ({
      key: String(p.key),
      answer: p.answer == null ? null : String(p.answer),
      correct: p.correct === true,
      graded_by: p.graded_by === 'self' ? 'self' as const : 'auto' as const,
      flags: Array.isArray(p.flags) ? p.flags.map(String) : [],
    }));
}

function mergePartResults(
  existing: PartResult[],
  updates: PartResult[],
): PartResult[] {
  const byKey = new Map<string, PartResult>();
  for (const p of existing) byKey.set(p.key, p);
  for (const p of updates) byKey.set(p.key, p);
  return [...byKey.values()].sort((a, b) => a.key.localeCompare(b.key));
}

/** 모든 파트가 채점되어 정답일 때만 true — is_correct의 세트형 정의. */
function allPartsCorrect(
  setParts: SetAnswerPart[],
  results: PartResult[],
): boolean {
  const byKey = new Map(results.map((p) => [p.key, p]));
  return setParts.every((part) => byKey.get(part.key)?.correct === true);
}

/** 파트별 답을 사람이 읽을 수 있는 한 줄로 합성 (last_answer 표시용). */
function composePartAnswer(results: PartResult[]): string | null {
  const chunks = results
    .filter((p) => (p.answer ?? '').trim() !== '')
    .map((p) => `${p.key} ${p.answer!.trim()}`);
  return chunks.length === 0 ? null : chunks.join('  ');
}

// ---------------------------------------------------------------------------
// actions
// ---------------------------------------------------------------------------

interface CropRow {
  id: string;
  academy_id: string;
  book_id: string;
  grade_label: string;
  is_set_header: boolean;
  pb_question_uid: string | null;
  storage_bucket: string;
  storage_key: string;
  textbook_problem_answers: {
    answer_kind: string;
    answer_text: string | null;
    answer_latex_2d: string | null;
    answer_image_bucket: string | null;
    answer_image_path: string | null;
  } | null;
}

async function loadCrop(admin: Admin, cropId: string): Promise<CropRow | null> {
  const { data } = await admin
    .from('textbook_problem_crops')
    .select(
      'id, academy_id, book_id, grade_label, is_set_header, pb_question_uid, ' +
        'storage_bucket, storage_key, ' +
        'textbook_problem_answers(answer_kind, answer_text, answer_latex_2d, ' +
        'answer_image_bucket, answer_image_path)',
    )
    .eq('id', cropId)
    .maybeSingle();
  return (data as CropRow | null) ?? null;
}

const answerTextOf = (c: CropRow) =>
  c.textbook_problem_answers?.answer_text ??
  c.textbook_problem_answers?.answer_latex_2d ??
  null;

// 신고로 보류(open/accepted)된 문항은 채점·기록하지 않는다.
async function isCropOnHold(
  admin: Admin,
  studentId: string,
  cropId: string,
): Promise<boolean> {
  const { data } = await admin
    .from('student_textbook_problem_reports')
    .select('id')
    .eq('student_id', studentId)
    .eq('crop_id', cropId)
    .in('status', ['open', 'accepted'])
    .limit(1)
    .maybeSingle();
  return data != null;
}

async function actionGrade(
  admin: Admin,
  student: { academyId: string; studentId: string },
  body: Record<string, unknown>,
) {
  const bookId = String(body.book_id ?? '');
  const gradeLabel = String(body.grade_label ?? '');
  const items = Array.isArray(body.items) ? body.items : [];
  if (!bookId || !gradeLabel || items.length === 0) {
    return json({ ok: false, error: 'invalid_request' }, 400);
  }
  if (items.length > 100) {
    return json({ ok: false, error: 'too_many_items' }, 400);
  }

  const results: Record<string, unknown>[] = [];
  let correctCount = 0;
  let wrongCount = 0;

  for (const raw of items) {
    const rawItem = raw as Record<string, unknown>;
    const cropId = String(rawItem?.crop_id ?? '');
    const answer = String(rawItem?.answer ?? '').trim();
    const rawParts = Array.isArray(rawItem?.parts) ? rawItem.parts : null;
    if (!cropId || (!answer && !(rawParts && rawParts.length > 0))) continue;

    const crop = await loadCrop(admin, cropId);
    if (
      !crop ||
      crop.academy_id !== student.academyId ||
      crop.book_id !== bookId ||
      crop.grade_label !== gradeLabel ||
      crop.is_set_header ||
      !crop.textbook_problem_answers
    ) {
      continue;
    }

    const kind = crop.textbook_problem_answers.answer_kind;
    const correctAnswer = answerTextOf(crop);

    // 세트형 파트 채점: 파트 정답이 파싱되고 파트 답이 제출된 경우
    const setParts = kind === 'subjective'
      ? splitSetAnswerParts(correctAnswer)
      : null;
    if (setParts !== null && rawParts !== null && rawParts.length > 0) {
      if (await isCropOnHold(admin, student.studentId, cropId)) {
        results.push({ crop_id: cropId, skipped: 'on_hold' });
        continue;
      }
      const partByKey = new Map(setParts.map((p) => [p.key, p]));
      const updates: PartResult[] = [];
      const partOutcomes: Record<string, unknown>[] = [];
      for (const rawPart of rawParts) {
        const partRecord = rawPart as Record<string, unknown>;
        const key = String(partRecord?.key ?? '');
        const partAnswer = String(partRecord?.answer ?? '').trim();
        const partDef = partByKey.get(key);
        if (!partDef || !partAnswer) continue;
        if (gradingMode('subjective', partDef.text) !== 'auto') {
          partOutcomes.push({ key, skipped: 'self_mode' });
          continue;
        }
        const out = compareAnswers('subjective', partDef.text, partAnswer);
        let partCorrect = out.correct;
        let partFlags = [...out.flags];
        if (out.needsUnitAi) {
          let specified: boolean | null = null;
          try {
            specified = await judgeUnitSpecified(admin, crop);
          } catch (_) {
            specified = null;
          }
          if (specified !== false) partFlags.push('unit_caution');
        }
        if (out.needsEquivAi) {
          try {
            const eq = await judgeEquivalence(
              admin,
              crop,
              partDef.text,
              partAnswer,
            );
            if (eq === true) {
              partCorrect = true;
              partFlags = partFlags.filter((f) => f !== 'form_differs');
            }
          } catch (_) {
            // AI 실패 시 결정적 결과(오답) 유지
          }
        }
        updates.push({
          key,
          answer: partAnswer,
          correct: partCorrect,
          graded_by: 'auto',
          flags: partFlags,
        });
        partOutcomes.push({ key, correct: partCorrect, flags: partFlags });
        if (partCorrect) correctCount += 1;
        else wrongCount += 1;
      }
      if (updates.length === 0) {
        results.push({ crop_id: cropId, parts: partOutcomes });
        continue;
      }
      const merged = mergePartResults(
        await loadPartResults(admin, student.studentId, cropId),
        updates,
      );
      const overall = allPartsCorrect(setParts, merged);
      await upsertRecord(admin, {
        academyId: student.academyId,
        studentId: student.studentId,
        bookId,
        gradeLabel,
        cropId,
        answer: composePartAnswer(merged),
        correct: overall,
        gradedBy: 'auto',
        flags: [],
        partResults: merged,
      });
      results.push({
        crop_id: cropId,
        correct: overall,
        parts: partOutcomes,
        part_results: merged,
      });
      continue;
    }

    if (gradingMode(kind, correctAnswer) !== 'auto' || correctAnswer === null) {
      continue; // self 모드 문항은 grade 대상 아님
    }
    if (await isCropOnHold(admin, student.studentId, cropId)) {
      results.push({ crop_id: cropId, skipped: 'on_hold' });
      continue;
    }

    const out = compareAnswers(kind, correctAnswer, answer);
    let correct = out.correct;
    let flags = [...out.flags];

    if (out.needsUnitAi) {
      // 단위 환산 동치 — 발문이 단위를 지정했으면 '단위 주의'만 표시 (정답 유지)
      let specified: boolean | null = null;
      try {
        specified = await judgeUnitSpecified(admin, crop);
      } catch (_) {
        specified = null;
      }
      // AI 실패/미설정 시에도 정답 + 주의 표시 (안전 기본값)
      if (specified !== false) flags.push('unit_caution');
    }

    if (out.needsEquivAi) {
      try {
        const eq = await judgeEquivalence(admin, crop, correctAnswer, answer);
        if (eq === true) {
          correct = true;
          flags = flags.filter((f) => f !== 'form_differs');
        }
      } catch (_) {
        // AI 실패 시 결정적 결과(오답) 유지
      }
    }

    await upsertRecord(admin, {
      academyId: student.academyId,
      studentId: student.studentId,
      bookId,
      gradeLabel,
      cropId,
      answer,
      correct,
      gradedBy: 'auto',
      flags,
    });

    if (correct) correctCount += 1;
    else wrongCount += 1;
    results.push({ crop_id: cropId, correct, flags });
  }

  return json({
    ok: true,
    results,
    correct_count: correctCount,
    wrong_count: wrongCount,
  });
}

async function actionReveal(
  admin: Admin,
  student: { academyId: string; studentId: string },
  body: Record<string, unknown>,
) {
  const cropId = String(body.crop_id ?? '');
  if (!cropId) return json({ ok: false, error: 'invalid_request' }, 400);

  const crop = await loadCrop(admin, cropId);
  if (!crop || crop.academy_id !== student.academyId) {
    return json({ ok: false, error: 'not_found' }, 404);
  }
  const answers = crop.textbook_problem_answers;
  if (!answers) return json({ ok: false, error: 'no_answer' }, 404);

  // 자동 채점 문항의 정답 유출 방지 — self 모드만 공개
  if (gradingMode(answers.answer_kind, answerTextOf(crop)) !== 'self') {
    return json({ ok: false, error: 'not_self_mode' }, 403);
  }

  // 그림 정답: 답지에서 잘라둔 정답 이미지의 서명 URL
  let imageUrl: string | null = null;
  if (answers.answer_image_bucket && answers.answer_image_path) {
    const { data: signed } = await admin.storage
      .from(answers.answer_image_bucket)
      .createSignedUrl(answers.answer_image_path, 600);
    imageUrl = signed?.signedUrl ?? null;
  }
  // 미리 렌더된 정답 PNG가 있으면 우선 사용 (분수/행렬 등 2D 표기)
  const { data: render } = await admin
    .from('textbook_answer_render_assets')
    .select('storage_bucket, storage_path, render_error')
    .eq('crop_id', cropId)
    .order('updated_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (render && !render.render_error && render.storage_path) {
    const { data: signed } = await admin.storage
      .from(render.storage_bucket)
      .createSignedUrl(render.storage_path, 600);
    imageUrl = signed?.signedUrl ?? imageUrl;
  }

  // 텍스트 정답은 LaTeX 원문 대신 학생이 읽을 수 있는 선형 표기로 변환해 반환
  const displayText = normalizeMathLinear(answerTextOf(crop));

  // 세트형이면 파트 정보 동봉 — 정답 텍스트는 self 파트만 포함해
  // 자동 채점 파트의 정답이 미리 새지 않게 한다.
  const setParts = answers.answer_kind === 'subjective'
    ? splitSetAnswerParts(answerTextOf(crop))
    : null;
  const parts = setParts?.map((part) => {
    const mode = gradingMode('subjective', part.text);
    return {
      key: part.key,
      mode,
      text: mode === 'self' ? (normalizeMathLinear(part.text) || part.text) : null,
    };
  }) ?? null;

  // 자동 채점 파트가 하나라도 있으면 전체 정답(텍스트/렌더)은 감춘다 —
  // 전체 정답에 자동 파트의 답이 포함되어 있기 때문.
  const hasAutoPart = parts?.some((p) => p.mode === 'auto') ?? false;

  return json({
    ok: true,
    answer_kind: answers.answer_kind,
    answer_text: hasAutoPart ? null : (displayText || answers.answer_text),
    answer_latex_2d: hasAutoPart ? null : answers.answer_latex_2d,
    image_url: hasAutoPart ? null : imageUrl,
    parts,
  });
}

async function actionSelfMark(
  admin: Admin,
  student: { academyId: string; studentId: string },
  body: Record<string, unknown>,
) {
  const bookId = String(body.book_id ?? '');
  const gradeLabel = String(body.grade_label ?? '');
  const cropId = String(body.crop_id ?? '');
  const correct = body.correct === true;
  const answer = body.answer == null ? null : String(body.answer);
  if (!bookId || !gradeLabel || !cropId) {
    return json({ ok: false, error: 'invalid_request' }, 400);
  }

  const crop = await loadCrop(admin, cropId);
  if (
    !crop ||
    crop.academy_id !== student.academyId ||
    crop.book_id !== bookId ||
    crop.grade_label !== gradeLabel
  ) {
    return json({ ok: false, error: 'not_found' }, 404);
  }

  if (await isCropOnHold(admin, student.studentId, cropId)) {
    return json({ ok: false, error: 'on_hold' }, 409);
  }

  // 세트형 파트 O/X: part_marks가 오고 파트 정답이 파싱되는 경우
  const rawMarks = Array.isArray(body.part_marks) ? body.part_marks : null;
  const answers = crop.textbook_problem_answers;
  const setParts = answers?.answer_kind === 'subjective'
    ? splitSetAnswerParts(answerTextOf(crop))
    : null;
  if (rawMarks !== null && rawMarks.length > 0 && setParts !== null) {
    const partByKey = new Map(setParts.map((p) => [p.key, p]));
    const updates: PartResult[] = [];
    for (const rawMark of rawMarks) {
      const markRecord = rawMark as Record<string, unknown>;
      const key = String(markRecord?.key ?? '');
      const partDef = partByKey.get(key);
      if (!partDef) continue;
      // self 파트만 자기 채점 허용 (auto 파트는 grade 액션으로만)
      if (gradingMode('subjective', partDef.text) !== 'self') continue;
      updates.push({
        key,
        answer: markRecord?.answer == null ? null : String(markRecord.answer),
        correct: markRecord?.correct === true,
        graded_by: 'self',
        flags: [],
      });
    }
    if (updates.length === 0) {
      return json({ ok: false, error: 'invalid_part_marks' }, 400);
    }
    const merged = mergePartResults(
      await loadPartResults(admin, student.studentId, cropId),
      updates,
    );
    const overall = allPartsCorrect(setParts, merged);
    await upsertRecord(admin, {
      academyId: student.academyId,
      studentId: student.studentId,
      bookId,
      gradeLabel,
      cropId,
      answer: composePartAnswer(merged) ?? answer,
      correct: overall,
      gradedBy: 'self',
      flags: [],
      partResults: merged,
    });
    return json({ ok: true, correct: overall, part_results: merged });
  }

  await upsertRecord(admin, {
    academyId: student.academyId,
    studentId: student.studentId,
    bookId,
    gradeLabel,
    cropId,
    answer,
    correct,
    gradedBy: 'self',
    flags: [],
  });

  return json({ ok: true, correct });
}

// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return json({ ok: false, error: 'method_not_allowed' }, 405);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch (_) {
    return json({ ok: false, error: 'invalid_json' }, 400);
  }

  const admin = createAdminClient();
  const student = await resolveStudent(req, admin);
  if (!student) return json({ ok: false, error: 'unauthorized' }, 401);

  const action = String(body.action ?? 'grade');
  try {
    if (action === 'grade') return await actionGrade(admin, student, body);
    if (action === 'reveal') return await actionReveal(admin, student, body);
    if (action === 'self_mark') return await actionSelfMark(admin, student, body);
    return json({ ok: false, error: 'unknown_action' }, 400);
  } catch (e) {
    return json(
      { ok: false, error: 'internal', detail: String((e as Error)?.message ?? e) },
      500,
    );
  }
});
