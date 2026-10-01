import type { Db } from './db.ts';

export interface BudgetStatus {
  limitUsd: number | null;
  mode: 'warn' | 'block';
  spentUsd: number;
  exceeded: boolean;
  webSearchEnabled: boolean;
}

/** 이번 달(한국 시간) 누적 비용과 한도. 설정을 읽지 못하면 제한 없음으로 본다. */
export async function getBudgetStatus(admin: Db): Promise<BudgetStatus> {
  const [settingsRes, spentRes] = await Promise.all([
    admin
      .from('ai_platform_settings')
      .select('monthly_budget_usd, budget_mode, web_search_enabled')
      .eq('id', true)
      .maybeSingle(),
    admin.rpc('ai_month_cost_usd'),
  ]);
  const settings = (settingsRes?.data ?? {}) as Record<string, unknown>;
  const rawLimit = settings.monthly_budget_usd;
  const limitUsd = rawLimit === null || rawLimit === undefined ? null : Number(rawLimit);
  const spentUsd = Number(spentRes?.data ?? 0) || 0;
  const validLimit = limitUsd !== null && Number.isFinite(limitUsd) ? limitUsd : null;
  return {
    limitUsd: validLimit,
    mode: settings.budget_mode === 'block' ? 'block' : 'warn',
    spentUsd,
    exceeded: validLimit !== null && spentUsd >= validLimit,
    webSearchEnabled: settings.web_search_enabled !== false,
  };
}
