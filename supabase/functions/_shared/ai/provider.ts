import { aiProviderName, denoEnv, type EnvReader } from './config.ts';
import { FakeAiProvider } from './fake.ts';
import { OpenAiResponsesProvider } from './openai.ts';
import type { AiProvider } from './types.ts';

/** 설정된 공급자를 만든다. API 키가 없으면 null (호출부는 AI 없이 동작해야 한다). */
export function createAiProvider(opts: { timeoutMs?: number; env?: EnvReader } = {}): AiProvider | null {
  const env = opts.env ?? denoEnv;
  if (aiProviderName(env) === 'fake') return new FakeAiProvider();
  const apiKey = env.get('OPENAI_API_KEY')?.trim();
  if (!apiKey) return null;
  return new OpenAiResponsesProvider({ apiKey, timeoutMs: opts.timeoutMs });
}

export function isAiConfigured(env: EnvReader = denoEnv): boolean {
  if (aiProviderName(env) === 'fake') return true;
  return !!env.get('OPENAI_API_KEY')?.trim();
}
