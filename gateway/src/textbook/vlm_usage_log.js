// Gemini 호출 한 건의 토큰 사용량을 한 줄로 남긴다.
//
// 정답·해설 단계는 지면마다 호출이 나가므로 "코너별로 쪼개 부를까, 한 번에
// 부를까" 같은 결정이 곧 비용 결정이 된다. 그런데 응답의 usageMetadata 를
// 아무도 안 보고 있어서 실제로 얼마가 나가는지 알 수 없었다.
//
// thinking 토큰(thoughtsTokenCount)은 candidatesTokenCount 와 별도로 잡히지만
// 출력 단가로 청구되므로 따로 찍어 준다. 이걸 빼고 계산하면 실제 비용을
// 크게 낮춰 잡는다.

function tokenCount(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.round(n) : 0;
}

export function summarizeVlmUsage(usage) {
  const prompt = tokenCount(usage?.promptTokenCount);
  const output = tokenCount(usage?.candidatesTokenCount);
  const thinking = tokenCount(usage?.thoughtsTokenCount);
  const cached = tokenCount(usage?.cachedContentTokenCount);
  const total = tokenCount(usage?.totalTokenCount) || prompt + output + thinking;
  return { prompt, output, thinking, cached, total };
}

/// `[vlm-usage] stage=answers page=11 prompt=1820 output=430 thinking=1210 total=3460 elapsed=5210ms`
export function logVlmUsage(stage, usage, extra = {}) {
  if (!usage) return;
  const t = summarizeVlmUsage(usage);
  const parts = [`stage=${stage}`];
  for (const [key, value] of Object.entries(extra)) {
    if (value === null || value === undefined || value === '') continue;
    parts.push(`${key}=${value}`);
  }
  parts.push(
    `prompt=${t.prompt}`,
    `output=${t.output}`,
    `thinking=${t.thinking}`,
  );
  if (t.cached > 0) parts.push(`cached=${t.cached}`);
  parts.push(`total=${t.total}`);
  console.log(`[vlm-usage] ${parts.join(' ')}`);
}
