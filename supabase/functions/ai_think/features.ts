// Think 기능 상태. 요청마다 서버가 계산해 도구 노출·기능 상태 메모·호출 기록(ai_runs.features)에 쓴다.
// 사용자 메시지나 기억으로는 바꿀 수 없다. 캐시하지 않으므로 Edge 배포·DB 반영 직후 다음 요청부터 반영된다.
// 설계: docs/architecture/ai-think-actions.md §7

/** 이 Edge 코드가 구현한 기능과 버전. DB(ai_think_db_features)와 앱(client.features)도 같은 버전 이상이어야 쓸 수 있다. */
export const EDGE_FEATURES = { conversation_split: 1, think_roles: 1 } as const;

export type FeatureName = keyof typeof EDGE_FEATURES;

/** ready: 준비됨 / db_required: DB 반영 필요 / app_update_required: 앱 업데이트 필요 / unknown: 확인 불가 */
export type FeatureState = 'ready' | 'db_required' | 'app_update_required' | 'unknown';

export interface FeatureStatus {
  state: FeatureState;
  edge: number;
  /** DB에 반영된 버전. 확인하지 못했으면 null(사용 가능으로 보지 않는다). */
  db: number | null;
  /** 앱이 요청에 실어 보낸 지원 버전. 보내지 않았으면 0. */
  app: number;
  permitted: boolean;
}

export type ThinkFeatures = Record<FeatureName, FeatureStatus>;

export type DbFeatureCheck =
  | { ok: true; features: Record<string, number> }
  | { ok: false; missing: boolean; error: string };

function versionMap(raw: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return out;
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof v === 'number' && Number.isFinite(v)) out[k] = Math.floor(v);
  }
  return out;
}

/** 요청 본문의 client.features. 숫자가 아닌 값은 버린다. */
export function parseClientFeatures(client: unknown): Record<string, number> {
  if (!client || typeof client !== 'object') return {};
  return versionMap((client as Record<string, unknown>).features);
}

export function parseDbFeatures(data: unknown): Record<string, number> {
  return versionMap(Array.isArray(data) ? data[0] : data);
}

/** PostgREST가 함수를 찾지 못했다(마이그레이션 전). 다른 오류는 "확인 불가"로 둔다. */
export function isMissingFunctionError(error: { code?: string; message?: string } | null | undefined): boolean {
  if (!error) return false;
  return error.code === 'PGRST202' || error.code === '42883' || /could not find the function/i.test(error.message ?? '');
}

export function computeFeatures(db: DbFeatureCheck, client: Record<string, number>, permitted: boolean): ThinkFeatures {
  const out = {} as ThinkFeatures;
  for (const name of Object.keys(EDGE_FEATURES) as FeatureName[]) {
    const edge = EDGE_FEATURES[name];
    const dbVersion = db.ok ? (db.features[name] ?? 0) : db.missing ? 0 : null;
    const app = client[name] ?? 0;
    let state: FeatureState;
    if (!permitted || dbVersion === null) state = 'unknown';
    else if (dbVersion < edge) state = 'db_required';
    else if (app < edge) state = 'app_update_required';
    else state = 'ready';
    out[name] = { state, edge, db: dbVersion, app, permitted };
  }
  return out;
}

export function featureReady(features: ThinkFeatures | null | undefined, name: FeatureName): boolean {
  return features?.[name]?.state === 'ready';
}

/** 사용자가 이번 메시지에서 직접 대화를 나누자고 했는지. 문구 규칙이라 완벽하지 않다. 거절 뒤 다시 제안할 수 있게 할 때만 쓴다. */
const SPLIT_REQUEST_RE = /(대화|주제|스레드|채팅).{0,8}(나누|나눠|나눌|분리|쪼개|따로)|새\s*(대화|채팅|스레드)\s*(로|에서|를\s*(만들|열|시작))/;

export function isSplitRequest(message: string): boolean {
  return SPLIT_REQUEST_RE.test(message);
}
