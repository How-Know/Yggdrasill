// 객관식 문항 크롭 이미지에서 보기 번호(①~⑤) 원문자 좌표를 추출한다.
//
// 이미지 스캔 교재(텍스트 레이어 없음)의 원본 보기 화면에서 학생이
// 보기 번호(①~⑤)를 직접 탭/펜슬 체크했을 때 인식하기 위해 사용한다.

const DEFAULT_MODEL = (
  process.env.PB_CHOICE_MARKER_MODEL || 'gemini-3.8-flash'
).trim();
const TRANSIENT_STATUSES = new Set([429, 499, 500, 502, 503, 504]);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeBox(raw) {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const nums = raw.map((v) => Number(v));
  if (nums.some((v) => !Number.isFinite(v))) return null;
  const y1 = Math.max(0, Math.min(1000, Math.round(nums[0])));
  const x1 = Math.max(0, Math.min(1000, Math.round(nums[1])));
  const y2 = Math.max(0, Math.min(1000, Math.round(nums[2])));
  const x2 = Math.max(0, Math.min(1000, Math.round(nums[3])));
  if (y2 <= y1 || x2 <= x1) return null;
  return [y1, x1, y2, x2];
}

export function normalizeChoiceMap(rawChoices) {
  if (!rawChoices || typeof rawChoices !== 'object') return {};
  const circledToKey = {
    '①': '1',
    '②': '2',
    '③': '3',
    '④': '4',
    '⑤': '5',
    '⑴': '1',
    '⑵': '2',
    '⑶': '3',
    '⑷': '4',
    '⑸': '5',
  };
  const out = {};
  for (const [rawKey, rawBox] of Object.entries(rawChoices)) {
    const trimmed = String(rawKey || '').trim();
    const key = circledToKey[trimmed] || (/^[1-5]$/.test(trimmed) ? trimmed : '');
    if (!key) continue;
    const box = normalizeBox(rawBox);
    if (!box) continue;
    out[key] = box;
  }
  return out;
}

export function mapCropChoicesToPage1k({
  choices,
  cropX,
  cropY,
  cropW,
  cropH,
  pageW,
  pageH,
}) {
  const out = {};
  if (cropW <= 0 || cropH <= 0 || pageW <= 0 || pageH <= 0) return out;
  for (const [key, b] of Object.entries(choices || {})) {
    if (!Array.isArray(b) || b.length !== 4) continue;
    const py1 = Math.max(
      0,
      Math.min(1000, Math.round(((cropY + (b[0] / 1000) * cropH) / pageH) * 1000)),
    );
    const px1 = Math.max(
      0,
      Math.min(1000, Math.round(((cropX + (b[1] / 1000) * cropW) / pageW) * 1000)),
    );
    const py2 = Math.max(
      0,
      Math.min(1000, Math.round(((cropY + (b[2] / 1000) * cropH) / pageH) * 1000)),
    );
    const px2 = Math.max(
      0,
      Math.min(1000, Math.round(((cropX + (b[3] / 1000) * cropW) / pageW) * 1000)),
    );
    if (py2 <= py1 || px2 <= px1) continue;
    out[key] = [py1, px1, py2, px2];
  }
  return out;
}

export function validatePageChoiceMarkers(pageChoices, itemRegion1k) {
  const entries = Object.entries(pageChoices || {});
  if (entries.length < 4) {
    return { ok: false, reason: `too_few_choices:${entries.length}` };
  }
  for (const [key, box] of entries) {
    if (!['1', '2', '3', '4', '5'].includes(key)) {
      return { ok: false, reason: `invalid_key:${key}` };
    }
    const h = box[2] - box[0];
    const w = box[3] - box[1];
    if (w <= 0 || h <= 0 || w > 90 || h > 70) {
      return { ok: false, reason: `abnormal_size:${key}:${w}x${h}` };
    }
    if (Array.isArray(itemRegion1k) && itemRegion1k.length === 4) {
      const cy = (box[0] + box[2]) / 2;
      const cx = (box[1] + box[3]) / 2;
      if (
        cy < itemRegion1k[0] - 25 ||
        cy > itemRegion1k[2] + 35 ||
        cx < itemRegion1k[1] - 25 ||
        cx > itemRegion1k[3] + 25
      ) {
        return { ok: false, reason: `outside_item_region:${key}` };
      }
    }
  }
  return { ok: true };
}

export async function extractChoiceMarkersFromProblemCrop({
  imageBase64,
  mimeType = 'image/png',
  apiKey = process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '',
  model = DEFAULT_MODEL,
  timeoutMs = 30000,
  maxRetries = 3,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('gemini_api_key_missing');
  const prompt = [
    '이 이미지는 한국 수학 문제 1개를 잘라낸 이미지입니다.',
    '문항에 객관식 보기 번호 원문자(①, ②, ③, ④, ⑤ 또는 ⑴~⑸)가 실제로 인쇄되어 있으면,',
    '각 보기 번호 기호 자체(원문자 1글자만, 뒤의 보기 내용 제외)의 정확한 위치 [ymin, xmin, ymax, xmax]를 0~1000 정규화 좌표로 반환하세요.',
    '발문 안의 조건 번호나 문항 번호가 아니라, 정답으로 고르는 선택지 번호 ①~⑤만 고르세요.',
    '객관식 보기 번호가 인쇄되어 있지 않은 주관식/서술형 문제면 has_choices=false, choices={}로 반환하세요.',
    '반드시 JSON으로만 응답하세요: {"has_choices": true|false, "choices": {"1": [ymin,xmin,ymax,xmax], "2": [...], ...}}',
  ].join('\n');

  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(key)}`;
  const body = {
    contents: [
      {
        role: 'user',
        parts: [
          { inline_data: { mime_type: mimeType, data: imageBase64 } },
          { text: prompt },
        ],
      },
    ],
    generationConfig: {
      temperature: 0,
      responseMimeType: 'application/json',
      thinkingConfig: { thinkingLevel: 'low' },
    },
  };

  for (let attempt = 0; attempt < maxRetries; attempt += 1) {
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
      if (attempt + 1 < maxRetries) {
        await sleep(700 * 2 ** attempt);
        continue;
      }
      throw err;
    } finally {
      clearTimeout(timer);
    }
    const textBody = await res.text();
    if (!res.ok) {
      if (TRANSIENT_STATUSES.has(res.status) && attempt + 1 < maxRetries) {
        await sleep(700 * 2 ** attempt);
        continue;
      }
      throw new Error(`choice_vlm_http_${res.status}:${textBody.slice(0, 300)}`);
    }
    const payload = JSON.parse(textBody);
    const text =
      payload?.candidates?.[0]?.content?.parts
        ?.map((p) => p?.text || '')
        .join('') || '';
    const parsed = JSON.parse(text);
    const choices = normalizeChoiceMap(parsed?.choices);
    return {
      hasChoices:
        parsed?.has_choices === true && Object.keys(choices).length >= 4,
      choices,
      usageMetadata: payload?.usageMetadata || null,
    };
  }
  throw new Error('choice_vlm_exhausted');
}
