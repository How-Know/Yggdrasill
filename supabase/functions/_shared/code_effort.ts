// 코드 작업 강도(Think 결정 255670bc, 2026-10-10). 요청에는 request.effort / request.effort_reason으로 저장한다.
// 비어 있거나 모르는 값은 high. 실제로 쓴 강도는 작업자가 회차 기록(effort)에 남긴다.

export const CODE_EFFORTS = ['medium', 'high', 'xhigh'] as const;
export type CodeEffort = (typeof CODE_EFFORTS)[number];
export const DEFAULT_CODE_EFFORT: CodeEffort = 'high';
/** 모델이 요청 강도를 지원하지 않으면 가장 가까운 강도로 돌므로 회차 기록에는 low도 올 수 있다. */
export const ROUND_EFFORTS = ['low', 'medium', 'high', 'xhigh'] as const;
export const EFFORT_REASON_CHARS = 200;

export function normalizeEffort(value: unknown): CodeEffort {
  return typeof value === 'string' && (CODE_EFFORTS as readonly string[]).includes(value) ? (value as CodeEffort) : DEFAULT_CODE_EFFORT;
}

export function effortReason(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const t = value.trim().replace(/\s+/g, ' ');
  return t ? t.slice(0, EFFORT_REASON_CHARS) : null;
}

/** Think 도구 스키마의 강도 칸(strict라 required + null 허용). */
export const EFFORT_TOOL_PROPERTIES = {
  effort: {
    type: ['string', 'null'],
    enum: ['medium', 'high', 'xhigh', null],
    description:
      'Cursor 작업 강도. medium: 파일 한두 개·문구·스타일 같은 작은 수정, high: 여러 파일에 걸친 기능 추가·테스트 포함, ' +
      'xhigh: DB·Edge·앱을 함께 바꾸거나 동시성처럼 원인을 찾기 어려운 버그. 모르면 null(high로 실행).',
  },
  effort_reason: {
    type: ['string', 'null'],
    description: '그 강도를 고른 이유 한 줄(60자 안팎). 없으면 null.',
  },
} as const;
