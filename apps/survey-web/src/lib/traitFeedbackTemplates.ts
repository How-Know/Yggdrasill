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

export type ScaleGuideIndicatorKey = 'emotion' | 'belief' | 'learning_style';

export type ScaleGuideSubscaleKey =
  | 'interest'
  | 'emotion_reactivity'
  | 'math_mindset'
  | 'effort_outcome_belief'
  | 'external_attribution_belief'
  | 'self_concept'
  | 'identity'
  | 'agency_perception'
  | 'question_understanding_belief'
  | 'recovery_expectancy_belief'
  | 'failure_interpretation_belief'
  | 'metacognition'
  | 'persistence';

export type ScaleGuideTemplate = {
  version: 'v1';
  indicatorDescriptions: Record<ScaleGuideIndicatorKey, string>;
  subscaleDescriptions: Record<ScaleGuideSubscaleKey, string>;
};

export type SemanticPolarity = 1 | -1;

export const SCALE_GUIDE_INDICATORS: Array<{ key: ScaleGuideIndicatorKey; title: string }> = [
  { key: 'emotion', title: '감정' },
  { key: 'belief', title: '신념' },
  { key: 'learning_style', title: '학습 방식' },
];

export const SCALE_GUIDE_SUBSCALES: Array<{
  key: ScaleGuideSubscaleKey;
  title: string;
  indicatorKey: ScaleGuideIndicatorKey;
}> = [
  { key: 'interest', title: '흥미', indicatorKey: 'emotion' },
  { key: 'emotion_reactivity', title: '정서 반응성', indicatorKey: 'emotion' },
  { key: 'math_mindset', title: '수학 능력관', indicatorKey: 'belief' },
  { key: 'effort_outcome_belief', title: '노력-성과 연결 신념', indicatorKey: 'belief' },
  { key: 'external_attribution_belief', title: '외적 귀인 신념', indicatorKey: 'belief' },
  { key: 'self_concept', title: '자기 개념', indicatorKey: 'belief' },
  { key: 'identity', title: '정체성', indicatorKey: 'belief' },
  { key: 'agency_perception', title: '주도성 인식', indicatorKey: 'belief' },
  { key: 'question_understanding_belief', title: '질문/이해에 대한 신념', indicatorKey: 'belief' },
  { key: 'recovery_expectancy_belief', title: '회복 기대 신념', indicatorKey: 'belief' },
  { key: 'failure_interpretation_belief', title: '실패 해석 신념', indicatorKey: 'belief' },
  { key: 'metacognition', title: '메타인지 성향', indicatorKey: 'learning_style' },
  { key: 'persistence', title: '문제 지속성', indicatorKey: 'learning_style' },
];

// +1: 점수가 높을수록 바람직, -1: 점수가 낮을수록 바람직
export const SCALE_GUIDE_SUBSCALE_POLARITY: Record<ScaleGuideSubscaleKey, SemanticPolarity> = {
  interest: 1,
  emotion_reactivity: -1,
  math_mindset: 1,
  effort_outcome_belief: 1,
  external_attribution_belief: -1,
  self_concept: 1,
  identity: 1,
  agency_perception: 1,
  question_understanding_belief: 1,
  recovery_expectancy_belief: 1,
  failure_interpretation_belief: 1,
  metacognition: 1,
  persistence: 1,
};

const DEFAULT_SCALE_GUIDE_INDICATOR_DESCRIPTIONS: Record<ScaleGuideIndicatorKey, string> = {
  emotion: '수학을 할 때 드는 느낌',
  belief: '수학이 노력과 방법에 따라 달라질 수 있다고 믿는 정도',
  learning_style: '수학 공부할 때 실제로 작동하는 습관',
};

const DEFAULT_SCALE_GUIDE_SUBSCALE_DESCRIPTIONS: Record<ScaleGuideSubscaleKey, string> = {
  interest: '수학이 얼마나 끌리는지 나타내는 지표에요. 수학 공부를 하고 싶다는 마음이 얼마나 자주 드는지를 보여줘요.',
  emotion_reactivity: '어려울 때 얼마나 흔들리는지를 나타내는 지표에요. 막히거나 틀렸을 때 긴장하거나 위축되는 정도를 말해요.',
  math_mindset: '수학 실력은 타고난 것만이 아니라 시간이 지나며 자랄 수 있다고 느끼는 정도예요. 지금 못해도 연습과 시간이 지나면 달라질 수 있다고 느끼는지를 보여줘요.',
  effort_outcome_belief: '노력하면 결과가 달라진다고 느끼는 정도예요. 공부 방법을 바꾸거나 연습을 더 하면 실제 결과도 달라질 수 있다고 생각하는지를 보여줘요.',
  external_attribution_belief: '결과의 이유를 내 바깥 요인에서 찾는 정도예요. 시험 결과가 운, 문제 난이도, 환경 때문이라고 느끼는 경향을 보여줘요.',
  self_concept: '나는 수학을 어느 정도 할 수 있다고 느끼는지예요. 지금까지의 경험을 바탕으로 스스로를 어떻게 바라보는지를 보여줘요.',
  identity: '수학이 나와 잘 맞는다고 느끼는지예요. 수학을 나와 관련 있는 것으로 느끼는지, 아니면 남의 영역처럼 느끼는지를 보여줘요.',
  agency_perception: '공부를 내가 이끌 수 있다고 느끼는 정도예요. 공부 방법을 정하고 바꾸는 주체가 나라고 느끼는지를 보여줘요.',
  question_understanding_belief: '스스로 모르는 것을 찾고 묻고 이해하려는 것이 중요하다고 느끼는 정도예요. 질문 자체가 부끄러운 일이 아니라 실력을 키우는 과정이라고 느끼는지를 보여줘요.',
  recovery_expectancy_belief: '어려워도 다시 좋아질 수 있다고 느끼는 정도예요. 실패나 슬럼프가 와도 나아질 수 있다고 믿는 힘을 보여줘요.',
  failure_interpretation_belief: '틀렸을 때 그 일을 어떤 의미로 받아들이는지를 나타내는 정도예요. 틀렸을 때 그 일을 내가 못해서로 받아들이는지, 다음에 고치면 되는 정보로 받아들이는지를 보여줘요.',
  metacognition: '공부할 때 스스로를 점검하는 습관이에요. 내가 이해했는지 확인하고 어디가 헷갈리고 다음엔 어떻게 할지 계획을 세우는 루틴이 얼마나 강한지를 나타내요.',
  persistence: '막히는 문제를 얼마나 오래 붙잡고 있을 수 있는지를 나타내요. 적당히 버티고 방법을 바꾸어 보는 힘을 보는 거예요.',
};

export const DEFAULT_SCALE_GUIDE_TEMPLATE: ScaleGuideTemplate = {
  version: 'v1',
  indicatorDescriptions: { ...DEFAULT_SCALE_GUIDE_INDICATOR_DESCRIPTIONS },
  subscaleDescriptions: { ...DEFAULT_SCALE_GUIDE_SUBSCALE_DESCRIPTIONS },
};

export function cloneScaleGuideTemplate(template: ScaleGuideTemplate): ScaleGuideTemplate {
  return {
    version: 'v1',
    indicatorDescriptions: { ...template.indicatorDescriptions },
    subscaleDescriptions: { ...template.subscaleDescriptions },
  };
}

export function normalizeScaleGuideTemplate(input: unknown): ScaleGuideTemplate {
  const raw = (input && typeof input === 'object' && !Array.isArray(input)) ? input as any : {};
  const indicatorsRaw = (raw.indicatorDescriptions && typeof raw.indicatorDescriptions === 'object')
    ? raw.indicatorDescriptions as any
    : {};
  const subscalesRaw = (raw.subscaleDescriptions && typeof raw.subscaleDescriptions === 'object')
    ? raw.subscaleDescriptions as any
    : {};

  const indicatorDescriptions = { ...DEFAULT_SCALE_GUIDE_INDICATOR_DESCRIPTIONS };
  const subscaleDescriptions = { ...DEFAULT_SCALE_GUIDE_SUBSCALE_DESCRIPTIONS };

  (Object.keys(indicatorDescriptions) as ScaleGuideIndicatorKey[]).forEach((key) => {
    const value = String(indicatorsRaw[key] ?? '').trim();
    if (value) indicatorDescriptions[key] = value;
  });
  (Object.keys(subscaleDescriptions) as ScaleGuideSubscaleKey[]).forEach((key) => {
    const value = String(subscalesRaw[key] ?? '').trim();
    if (value) subscaleDescriptions[key] = value;
  });

  return {
    version: 'v1',
    indicatorDescriptions,
    subscaleDescriptions,
  };
}

export function parseScaleGuideTemplate(input: unknown): ScaleGuideTemplate | null {
  const raw = String(input ?? '').trim();
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
    const version = String((parsed as any).version ?? '').trim();
    if (version !== 'v1') return null;
    return normalizeScaleGuideTemplate(parsed);
  } catch {
    return null;
  }
}

export function serializeScaleGuideTemplate(template: ScaleGuideTemplate): string {
  return JSON.stringify(normalizeScaleGuideTemplate(template));
}

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
