// 학생 필기 샘플(디지털 잉크 렌더 이미지)을 Gemini Vision 에 보내
// 인식 실패 원인 분류 + 개선 방향 제안을 받아오는 클라이언트.
//
// `vlm_detect_client.js` 와 같은 호출 규약(전송/재시도/JSON 복구)을 따르되,
// 프롬프트가 필기 인식 품질 진단 전용이라 별도 모듈로 분리했다.
// Node >= 18 의 global fetch / AbortController 만 사용한다. 외부 의존성 없음.

import {
  joinGeminiTextParts,
  parseTextbookVlmJson,
} from './vlm_json_parse.js';

const TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);
const DEFAULT_MAX_RETRIES = 2;

// 매니저앱/DB(ai_assessment)와 공유하는 판정 분류값.
export const HANDWRITING_VERDICTS = new Set([
  'recognizer_limit',
  'ambiguous_writing',
  'ui_issue',
  'other',
]);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function compactErrMsg(err) {
  return String(err?.message || err || '').replace(/\s+/g, ' ').slice(0, 300);
}

export function buildHandwritingReviewPrompt({
  recognizedText = '',
  recognizedCandidates = [],
  expectedAnswer = '',
  expectedAnswerKind = '',
  submittedAnswer = '',
  note = '',
} = {}) {
  const candidates = (Array.isArray(recognizedCandidates)
    ? recognizedCandidates
    : []
  )
    .map((c) => String(c ?? '').trim())
    .filter(Boolean);
  const lines = [
    '당신은 수학 학원 학습앱의 필기 인식(디지털 잉크, ML Kit) 품질을 진단하는 전문가입니다.',
    '첨부된 이미지는 학생이 애플펜슬로 답안 칸에 쓴 필기 원본을 흰 배경/검정 획으로 렌더한 것입니다.',
    '학생이 "필기 인식이 잘 안돼요"라고 신고한 사례이므로, 이미지와 아래 정보를 비교해 원인을 진단하세요.',
    '',
    '[상황 정보]',
    `- 문항의 기대 정답: ${expectedAnswer || '(미확인)'}`,
    `- 정답 유형: ${expectedAnswerKind || '(미확인)'}`,
    `- 인식 엔진이 답 칸에 넣은 최종 텍스트: ${recognizedText || '(비어 있음)'}`,
    `- 인식 후보 목록: ${candidates.length ? candidates.join(' | ') : '(없음)'}`,
    `- 신고 시점 답 칸의 텍스트: ${submittedAnswer || '(비어 있음)'}`,
    `- 학생 메모: ${note || '(없음)'}`,
    '',
    '[요청]',
    '1. 이미지의 필기를 사람 눈으로 읽으면 무엇으로 보이는지 판단하세요 (read_as).',
    '2. 인식 실패의 주된 원인을 다음 중 정확히 하나로 분류하세요 (verdict).',
    '   - recognizer_limit: 필기는 사람이 읽기에 명확하지만 인식 모델의 한계',
    '     (분수·지수·근호 등 수식 표기, 혼합 표기, 언어 모델 미지원 등)로 실패',
    '   - ambiguous_writing: 필기 자체가 모호함 (획 겹침, 흘려쓰기, 크기 불균형,',
    '     숫자/문자 혼동 소지 등) — 사람이 봐도 헷갈리는 경우',
    '   - ui_issue: 앱 쪽 문제로 추정 (캔버스가 좁아 필기가 잘림, 획이 끊겨 저장됨,',
    '     전처리/좌표 왜곡, 이미지가 비었거나 훼손됨 등)',
    '   - other: 위 세 가지에 해당하지 않는 경우',
    '3. 원인을 한국어로 설명하고 (cause), 구체적인 개선 방향을 제안하세요 (improvement).',
    '   개선 방향에는 예: 인식 모델/언어 교체, 수식 전용 인식기 도입, 후보 선택 UI 개선,',
    '   캔버스 확대, 학생 필기 가이드 안내 등 실행 가능한 제안을 담으세요.',
    '',
    '반드시 아래 형식의 JSON 객체 하나만 출력하세요. 다른 텍스트를 붙이지 마세요.',
    '{"verdict": "recognizer_limit|ambiguous_writing|ui_issue|other",',
    ' "read_as": "사람 눈으로 읽은 필기 내용",',
    ' "cause": "한국어 원인 설명",',
    ' "improvement": "한국어 개선 방향 제안"}',
  ];
  return lines.join('\n');
}

export function normalizeHandwritingAssessment(parsed) {
  if (!parsed || typeof parsed !== 'object') return null;
  const rawVerdict = String(parsed.verdict || '').trim().toLowerCase();
  const verdict = HANDWRITING_VERDICTS.has(rawVerdict) ? rawVerdict : 'other';
  const cause = String(parsed.cause || '').trim();
  const improvement = String(parsed.improvement || '').trim();
  const readAs = String(parsed.read_as ?? parsed.readAs ?? '').trim();
  if (!cause && !improvement) return null;
  return {
    verdict,
    read_as: readAs,
    cause: cause || '원인 설명이 제공되지 않았습니다.',
    improvement: improvement || '개선 방향 제안이 제공되지 않았습니다.',
  };
}

export async function assessHandwritingSample({
  imageBase64,
  mimeType = 'image/png',
  recognizedText = '',
  recognizedCandidates = [],
  expectedAnswer = '',
  expectedAnswerKind = '',
  submittedAnswer = '',
  note = '',
  model,
  apiKey,
  timeoutMs = 90000,
  maxRetries = DEFAULT_MAX_RETRIES,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('handwriting_review_api_key_missing');
  const img = String(imageBase64 || '').trim();
  if (!img) throw new Error('handwriting_review_image_empty');

  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=` +
    `${encodeURIComponent(key)}`;

  const body = {
    contents: [
      {
        role: 'user',
        parts: [
          {
            inline_data: {
              mime_type: mimeType,
              data: img,
            },
          },
          {
            text: buildHandwritingReviewPrompt({
              recognizedText,
              recognizedCandidates,
              expectedAnswer,
              expectedAnswerKind,
              submittedAnswer,
              note,
            }),
          },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.2,
      responseMimeType: 'application/json',
      maxOutputTokens: 2048,
    },
  };

  let lastErr = null;
  const attempts = Math.max(1, Number(maxRetries) || 1);
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let res;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } catch (err) {
      clearTimeout(timer);
      lastErr = err;
      if (attempt + 1 < attempts) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `handwriting_review_fetch_error: ${compactErrMsg(err)} (attempts=${attempt + 1})`,
      );
    } finally {
      clearTimeout(timer);
    }
    const textBody = await res.text();
    if (!res.ok) {
      if (TRANSIENT_STATUSES.has(res.status) && attempt + 1 < attempts) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `handwriting_review_http_${res.status}: ${String(textBody).slice(0, 500)} (attempts=${attempt + 1})`,
      );
    }
    let payload;
    try {
      payload = JSON.parse(textBody);
    } catch (_) {
      throw new Error(
        `handwriting_review_non_json_response: ${String(textBody).slice(0, 500)}`,
      );
    }
    const candidate = (payload?.candidates || [])[0];
    const modelText = joinGeminiTextParts(candidate?.content?.parts);
    const parsed = parseTextbookVlmJson(modelText);
    const assessment = normalizeHandwritingAssessment(parsed);
    if (!assessment) {
      throw new Error(
        `handwriting_review_parse_failed: ${String(modelText).slice(0, 300)}`,
      );
    }
    return { assessment, model: String(model || '') };
  }
  throw new Error(
    `handwriting_review_failed: ${compactErrMsg(lastErr)} (attempts=${attempts})`,
  );
}
