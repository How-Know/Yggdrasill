export type FeedbackTypeCode = 'TYPE_A' | 'TYPE_B' | 'TYPE_C' | 'TYPE_D';

export type FeedbackSectionKey =
  | 'profile_summary'
  | 'strength_weakness'
  | 'learning_traits'
  | 'cautions'
  | 'teaching_strategy'
  | 'growth_checkpoint';

export type FeedbackSectionTemplate = {
  key: FeedbackSectionKey;
  title: string;
  common: string;
  fine_tune: string;
};

export type FeedbackTemplate = {
  typeCode: FeedbackTypeCode;
  templateName: string;
  sections: FeedbackSectionTemplate[];
  updatedAt?: string | null;
};

export const FEEDBACK_TYPE_CODES: FeedbackTypeCode[] = ['TYPE_A', 'TYPE_B', 'TYPE_C', 'TYPE_D'];

export const FEEDBACK_SECTION_DEFINITIONS: Array<{ key: FeedbackSectionKey; title: string }> = [
  { key: 'profile_summary', title: '정서, 신념 프로파일 요약 (상세점수 표시)' },
  { key: 'strength_weakness', title: '핵심 강점과 단점' },
  { key: 'learning_traits', title: '학습 성향 특징' },
  { key: 'cautions', title: '주의해야할 부분' },
  { key: 'teaching_strategy', title: '맞춤 수업전략' },
  { key: 'growth_checkpoint', title: '향후 성장 체크포인트' },
];

export const INTERPRETATION_FRAME_GUIDE_QUESTIONS = [
  '유형이 현재 실력을 설명하는가?',
  '유형이 성장 가능성을 시사하는가?',
  '유형이 현재 실력과 별개인 상태 변수인가?',
] as const;

export const INTERPRETATION_FRAME_GUARDRAILS = [
  '유형을 실력의 원인으로 단정하지 않는다.',
  '상관과 인과를 구분하고 효과크기 중심으로 해석한다.',
  '성장 가능성 평가는 추적 데이터(2차/3차)로 검증한다.',
] as const;

function sectionByKey(rows: FeedbackSectionTemplate[]): Record<FeedbackSectionKey, FeedbackSectionTemplate> {
  const out = {} as Record<FeedbackSectionKey, FeedbackSectionTemplate>;
  rows.forEach((row) => {
    out[row.key] = row;
  });
  return out;
}

function feedbackTypeLabel(typeCode: FeedbackTypeCode): string {
  if (typeCode === 'TYPE_A') return '확장형';
  if (typeCode === 'TYPE_B') return '동기형';
  if (typeCode === 'TYPE_C') return '회복형';
  return '안정형';
}

function buildDefaultSections(typeCode: FeedbackTypeCode): FeedbackSectionTemplate[] {
  const typeLabel = feedbackTypeLabel(typeCode);
  return FEEDBACK_SECTION_DEFINITIONS.map((def) => ({
    key: def.key,
    title: def.title,
    common: `[${typeLabel}] ${def.title} 공통 피드백(70%)을 작성하세요.`,
    fine_tune: `${def.title}에 대한 학생별 미세 조정(30%)을 작성하세요.`,
  }));
}

export const DEFAULT_FEEDBACK_TEMPLATES: Record<FeedbackTypeCode, FeedbackTemplate> = {
  TYPE_A: { typeCode: 'TYPE_A', templateName: '확장형 기본틀', sections: buildDefaultSections('TYPE_A'), updatedAt: null },
  TYPE_B: { typeCode: 'TYPE_B', templateName: '동기형 기본틀', sections: buildDefaultSections('TYPE_B'), updatedAt: null },
  TYPE_C: { typeCode: 'TYPE_C', templateName: '회복형 기본틀', sections: buildDefaultSections('TYPE_C'), updatedAt: null },
  TYPE_D: { typeCode: 'TYPE_D', templateName: '안정형 기본틀', sections: buildDefaultSections('TYPE_D'), updatedAt: null },
};

export function cloneFeedbackTemplate(template: FeedbackTemplate): FeedbackTemplate {
  return {
    ...template,
    sections: template.sections.map((section) => ({ ...section })),
  };
}

export function mergeTemplateSections(
  input: unknown,
  fallback: FeedbackSectionTemplate[],
): FeedbackSectionTemplate[] {
  const fallbackByKey = sectionByKey(fallback);
  const inputArr = Array.isArray(input) ? input : [];
  const inputByKey = {} as Partial<Record<FeedbackSectionKey, any>>;
  inputArr.forEach((row) => {
    const key = String((row as any)?.key ?? '').trim() as FeedbackSectionKey;
    if (!key) return;
    inputByKey[key] = row;
  });

  return FEEDBACK_SECTION_DEFINITIONS.map((def) => {
    const base = fallbackByKey[def.key];
    const row = inputByKey[def.key] ?? {};
    const title = String((row as any)?.title ?? base.title ?? def.title).trim() || def.title;
    const common = String((row as any)?.common ?? base.common ?? '').trim();
    const fineTune = String((row as any)?.fine_tune ?? (row as any)?.fineTune ?? base.fine_tune ?? '').trim();
    return {
      key: def.key,
      title,
      common,
      fine_tune: fineTune,
    };
  });
}

export function combineSectionText(section: FeedbackSectionTemplate): string {
  const common = section.common.trim();
  const fineTune = section.fine_tune.trim();
  if (common && fineTune) return `${common}\n${fineTune}`;
  return common || fineTune;
}
