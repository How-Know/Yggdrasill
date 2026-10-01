// 모델 이름·추론 강도·가격은 코드가 아니라 환경변수로 바꾼다.
//   AI_PROVIDER            openai | fake            (기본 openai)
//   AI_MODEL_PRIMARY       기본 대화                  (기본 gpt-6-sol)
//   AI_MODEL_DEEP          깊게 생각하기               (기본 gpt-6-astra, AI_MODEL_REASONING도 인식)
//   AI_MODEL_FAST          메모 요약·제목 같은 짧은 작업  (기본 gpt-6-luna)
//   AI_REASONING_PRIMARY / AI_REASONING_DEEP / AI_REASONING_FAST
//   AI_MAX_OUTPUT_PRIMARY / AI_MAX_OUTPUT_DEEP / AI_MAX_OUTPUT_FAST
//   AI_PRICING_JSON        {"model":{"input":..,"cachedInput":..,"cacheWrite":..,"output":..}} (USD / 1M tokens)
//   AI_THINK_WALL_MS       ai_think 한 요청의 최대 실행 시간 (기본 140000, 유료 요금제는 늘릴 수 있음)

import type { AiUsage } from './types.ts';

export type ModelTier = 'primary' | 'deep' | 'fast';

export interface EnvReader {
  get(name: string): string | undefined;
}

export const denoEnv: EnvReader = { get: (name) => Deno.env.get(name) };

const DEFAULT_MODELS: Record<ModelTier, string> = {
  primary: 'gpt-6-sol',
  deep: 'gpt-6-astra',
  fast: 'gpt-6-luna',
};

const MODEL_ENV_KEYS: Record<ModelTier, string[]> = {
  primary: ['AI_MODEL_PRIMARY'],
  deep: ['AI_MODEL_DEEP', 'AI_MODEL_REASONING'],
  fast: ['AI_MODEL_FAST'],
};

const DEFAULT_REASONING: Record<ModelTier, string> = {
  primary: 'medium',
  deep: 'high',
  fast: 'none',
};

// 추론 토큰도 출력 한도에 포함된다.
const DEFAULT_MAX_OUTPUT: Record<ModelTier, number> = {
  primary: 16000,
  deep: 32000,
  fast: 600,
};

function readTrimmed(env: EnvReader, key: string): string | undefined {
  const v = env.get(key)?.trim();
  return v ? v : undefined;
}

export function aiProviderName(env: EnvReader = denoEnv): string {
  return (readTrimmed(env, 'AI_PROVIDER') ?? 'openai').toLowerCase();
}

export function modelFor(tier: ModelTier, env: EnvReader = denoEnv): string {
  for (const key of MODEL_ENV_KEYS[tier]) {
    const v = readTrimmed(env, key);
    if (v) return v;
  }
  return DEFAULT_MODELS[tier];
}

export function reasoningFor(tier: ModelTier, env: EnvReader = denoEnv): string {
  return readTrimmed(env, `AI_REASONING_${tier.toUpperCase()}`) ?? DEFAULT_REASONING[tier];
}

export function maxOutputTokensFor(tier: ModelTier, env: EnvReader = denoEnv): number {
  const raw = Number(readTrimmed(env, `AI_MAX_OUTPUT_${tier.toUpperCase()}`));
  return Number.isFinite(raw) && raw > 0 ? Math.floor(raw) : DEFAULT_MAX_OUTPUT[tier];
}

export function thinkWallClockMs(env: EnvReader = denoEnv): number {
  const raw = Number(readTrimmed(env, 'AI_THINK_WALL_MS'));
  return Number.isFinite(raw) && raw >= 30000 ? Math.floor(raw) : 140000;
}

export interface TokenRates {
  input: number;
  cachedInput: number;
  cacheWrite: number;
  output: number;
}

export interface ModelPrice extends TokenRates {
  longContext?: TokenRates & { threshold: number };
}

// USD / 1M tokens (2026-09 OpenAI 공개 가격)
const BUILTIN_PRICES: Record<string, ModelPrice> = {
  'gpt-6-astra': {
    input: 10, cachedInput: 1, cacheWrite: 12.5, output: 50,
    longContext: { threshold: 272000, input: 20, cachedInput: 2, cacheWrite: 25, output: 75 },
  },
  'gpt-6-sol': {
    input: 2, cachedInput: 0.2, cacheWrite: 2.5, output: 10,
    longContext: { threshold: 272000, input: 4, cachedInput: 0.4, cacheWrite: 5, output: 15 },
  },
  'gpt-6-luna': {
    input: 0.1, cachedInput: 0.01, cacheWrite: 0.125, output: 0.5,
    longContext: { threshold: 272000, input: 0.2, cachedInput: 0.02, cacheWrite: 0.25, output: 0.75 },
  },
  'gpt-5.6-sol': { input: 4, cachedInput: 0.4, cacheWrite: 5, output: 20 },
};

export const WEB_SEARCH_USD_PER_CALL = 0.01;

function isRates(v: unknown): v is TokenRates {
  if (!v || typeof v !== 'object') return false;
  const r = v as Record<string, unknown>;
  return ['input', 'cachedInput', 'cacheWrite', 'output'].every((k) => typeof r[k] === 'number' && (r[k] as number) >= 0);
}

export function priceFor(model: string, env: EnvReader = denoEnv): ModelPrice | null {
  const raw = readTrimmed(env, 'AI_PRICING_JSON');
  if (raw) {
    try {
      const parsed = JSON.parse(raw) as Record<string, unknown>;
      const hit = parsed[model];
      if (isRates(hit)) return hit;
    } catch {
      // 잘못된 JSON이면 내장 가격표를 쓴다.
    }
  }
  if (BUILTIN_PRICES[model]) return BUILTIN_PRICES[model];
  // 날짜가 붙은 스냅샷 이름(gpt-6-sol-2026-08-01 등)은 기본 이름의 가격을 쓴다.
  const base = Object.keys(BUILTIN_PRICES).find((name) => model.startsWith(`${name}-`));
  return base ? BUILTIN_PRICES[base] : null;
}

/** 요청 1건의 비용. 가격을 모르는 모델이면 null. */
export function estimateCostUsd(
  model: string,
  usage: AiUsage,
  webSearchCalls = 0,
  env: EnvReader = denoEnv,
): number | null {
  const price = priceFor(model, env);
  if (!price) return null;
  const rates: TokenRates =
    price.longContext && usage.inputTokens > price.longContext.threshold ? price.longContext : price;
  const cached = Math.max(0, usage.cachedInputTokens);
  const cacheWrite = Math.max(0, usage.cacheWriteTokens);
  const uncached = Math.max(0, usage.inputTokens - cached - cacheWrite);
  const tokenCost =
    (uncached * rates.input +
      cached * rates.cachedInput +
      cacheWrite * rates.cacheWrite +
      Math.max(0, usage.outputTokens) * rates.output) /
    1_000_000;
  return roundUsd(tokenCost + Math.max(0, webSearchCalls) * WEB_SEARCH_USD_PER_CALL);
}

export function roundUsd(v: number): number {
  return Math.round(v * 1_000_000) / 1_000_000;
}
