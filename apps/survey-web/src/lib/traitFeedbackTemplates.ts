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
  { key: 'profile_summary', title: '정서, 신념 프로파일 요약' },
  { key: 'learning_traits', title: '학습 성향 특징' },
  { key: 'strength_weakness', title: '핵심 강점' },
  { key: 'cautions', title: '주의해야할 부분' },
  { key: 'teaching_strategy', title: '추천 수업 전략' },
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
    const title = def.title;
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

/* ────────────────────────────────────────────
 * Subscale Feedback
 * 학생에게 보여줄 지표별 1줄 피드백
 * ──────────────────────────────────────────── */

const SUBSCALE_FEEDBACK: Record<ScaleGuideSubscaleKey, { high: string; mid: string; low: string }> = {
  interest: {
    high: '수학에 대한 흥미가 잘 유지되고 있어요.',
    mid: '수학에 대한 관심이 어느 정도 있는 상태예요.',
    low: '수학에 대한 흥미가 아직 충분히 생기지 않은 상태일 수 있어요.',
  },
  emotion_reactivity: {
    high: '어려운 상황에서도 감정적으로 안정적인 편이에요.',
    mid: '어려울 때 약간 흔들릴 수 있지만, 회복하는 힘이 있어요.',
    low: '어려운 문제를 만나면 감정적으로 긴장하는 경향이 있어요.',
  },
  math_mindset: {
    high: '수학 실력은 노력으로 달라질 수 있다는 믿음이 잘 자리 잡고 있어요.',
    mid: '노력과 실력의 관계를 어느 정도 느끼고 있는 상태예요.',
    low: '수학 실력이 쉽게 바뀔 수 있다는 느낌이 아직 약한 편이에요.',
  },
  effort_outcome_belief: {
    high: '노력하면 결과가 달라진다는 확신이 있어요.',
    mid: '노력과 결과의 연결을 느끼고 있지만, 아직 확고하지는 않아요.',
    low: '노력이 결과로 이어진다는 느낌이 충분히 자리 잡지 않은 상태예요.',
  },
  external_attribution_belief: {
    high: '결과의 원인을 자신에게서 찾는 경향이 있어요.',
    mid: '결과의 원인을 자신과 외부 사이에서 고르게 보는 편이에요.',
    low: '결과가 외부 요인에 의해 좌우된다고 느끼는 경향이 있어요.',
  },
  self_concept: {
    high: '수학에 대한 자기 이미지가 긍정적인 편이에요.',
    mid: '수학에 대한 자기 평가가 보통 수준이에요.',
    low: '수학에 대한 자신감이 아직 충분히 형성되지 않은 상태예요.',
  },
  identity: {
    high: '수학이 자신과 잘 맞는다고 느끼고 있어요.',
    mid: '수학과의 관계를 어느 정도 느끼고 있는 상태예요.',
    low: '수학이 자신과는 다소 거리가 있다고 느끼는 편이에요.',
  },
  agency_perception: {
    high: '공부 방향을 스스로 이끌 수 있다는 느낌이 잘 자리 잡고 있어요.',
    mid: '공부의 주도성이 어느 정도 형성되어 있는 상태예요.',
    low: '공부 방향을 스스로 정하는 힘이 아직 약한 편이에요.',
  },
  question_understanding_belief: {
    high: '모르는 것을 찾고 질문하는 것의 가치를 잘 알고 있어요.',
    mid: '질문과 이해의 중요성을 어느 정도 느끼고 있어요.',
    low: '질문하는 것에 대한 가치 인식이 아직 충분히 형성되지 않은 상태예요.',
  },
  recovery_expectancy_belief: {
    high: '어려운 시기가 와도 다시 나아질 수 있다는 믿음이 있어요.',
    mid: '회복에 대한 기대감이 어느 정도 있는 상태예요.',
    low: '어려움 뒤에 다시 좋아질 수 있다는 느낌이 아직 약한 편이에요.',
  },
  failure_interpretation_belief: {
    high: '실패를 다음에 고칠 수 있는 정보로 받아들이는 편이에요.',
    mid: '실패에 대한 해석이 긍정과 부정 사이에 있는 상태예요.',
    low: '실패를 자신의 능력 문제로 해석하는 경향이 있어요.',
  },
  metacognition: {
    high: '공부할 때 스스로를 점검하는 습관이 잘 잡혀 있어요.',
    mid: '자기 점검 습관이 어느 정도 형성되어 있는 상태예요.',
    low: '공부할 때 스스로를 돌아보는 루틴이 아직 충분하지 않은 편이에요.',
  },
  persistence: {
    high: '막히는 문제도 포기하지 않고 붙잡아 보는 힘이 있어요.',
    mid: '문제를 어느 정도 붙잡고 시도해 보는 편이에요.',
    low: '막히는 문제 앞에서 빨리 포기하게 되는 경향이 있어요.',
  },
};

function feedbackColor(percentile: number): string {
  if (percentile >= 86) return '#4ADE80';
  if (percentile >= 72) return '#22C55E';
  if (percentile >= 58) return '#84CC16';
  if (percentile >= 43) return '#EAB308';
  if (percentile >= 29) return '#F59E0B';
  if (percentile >= 15) return '#F97316';
  return '#EF4444';
}

export function getSubscaleFeedback(
  key: ScaleGuideSubscaleKey,
  percentile: number | null,
): { text: string; color: string } | null {
  const fb = SUBSCALE_FEEDBACK[key];
  if (!fb) return null;
  if (percentile == null || !Number.isFinite(percentile)) return null;
  const text = percentile >= 70 ? fb.high : percentile >= 30 ? fb.mid : fb.low;
  return { text, color: feedbackColor(percentile) };
}

/* ────────────────────────────────────────────
 * Profile Summary Builder
 * 4유형 × 3강도 기본 템플릿 + 등급 방향 문구
 * ──────────────────────────────────────────── */

export type IntensityLevel = 'strong' | 'moderate' | 'mild';
export type GradeTier = 'top' | 'mid' | 'low';
type TypeFavorability = 'favorable' | 'moderate_fav' | 'caution' | 'unfavorable';

export function getIntensityLevel(vectorStrength: number | null): IntensityLevel {
  if (vectorStrength == null || !Number.isFinite(vectorStrength)) return 'mild';
  if (vectorStrength >= 55) return 'strong';
  if (vectorStrength >= 25) return 'moderate';
  return 'mild';
}

export function getGradeTier(grade: number | null): GradeTier | null {
  if (grade == null || !Number.isFinite(grade)) return null;
  if (grade <= 2) return 'top';
  if (grade <= 4) return 'mid';
  return 'low';
}

function getTypeFavorability(typeCode: FeedbackTypeCode): TypeFavorability {
  if (typeCode === 'TYPE_A') return 'favorable';
  if (typeCode === 'TYPE_D') return 'moderate_fav';
  if (typeCode === 'TYPE_B') return 'caution';
  return 'unfavorable';
}

const PROFILE_SUMMARY_TEMPLATES: Record<FeedbackTypeCode, Record<IntensityLevel, string>> = {
  TYPE_A: {
    strong:
      '이 학생은 수학을 대할 때 비교적 안정적인 감정 상태를 유지하며, ' +
      '수학 실력은 노력과 방법에 따라 달라질 수 있다고 믿고 있습니다. ' +
      '어려움이 있어도 감정적으로 크게 무너지지 않으며, ' +
      '실패를 성장 과정의 일부로 받아들이는 경향이 있습니다. ' +
      '현재의 성적과 관계없이 방향이 맞으면 안정적으로 성장할 가능성이 있는 상태입니다.',
    moderate:
      '이 학생은 수학을 대할 때 감정 상태가 비교적 안정적인 편에 속하며, ' +
      '수학 실력이 노력과 방법에 따라 달라질 수 있다고 느끼는 경향이 있습니다. ' +
      '어려움이 있어도 감정적으로 크게 흔들리지 않는 편이며, ' +
      '실패를 성장 과정의 일부로 바라보려는 태도가 엿보입니다. ' +
      '방향이 맞으면 점차 안정적인 흐름으로 이어질 가능성이 있는 상태입니다.',
    mild:
      '이 학생은 수학을 대할 때 감정이 비교적 안정적일 수 있으며, ' +
      '수학 실력이 노력에 따라 달라질 수 있다는 생각을 어느 정도 갖고 있을 수 있습니다. ' +
      '어려움에 대한 감정적 반응이 크지 않을 수 있으나, 아직 뚜렷한 패턴으로 자리 잡지는 않은 상태입니다. ' +
      '현재로서는 감정과 신념 모두 긍정적 방향의 가능성이 엿보이는 단계입니다.',
  },
  TYPE_B: {
    strong:
      '이 학생은 수학을 할 때 감정적으로는 비교적 안정적인 편이지만, ' +
      '수학 실력이 노력이나 방법에 따라 충분히 달라질 수 있다는 확신은 다소 약한 상태입니다. ' +
      '어려움이 와도 감정적으로는 크게 흔들리지 않지만, ' +
      '결과의 원인을 스스로에게 연결하는 힘은 제한적일 수 있습니다. ' +
      '신념 구조가 강화되면 성장 폭이 더 커질 가능성이 있는 상태입니다.',
    moderate:
      '이 학생은 수학을 할 때 감정적으로는 비교적 안정적인 편에 속하지만, ' +
      '수학 실력이 노력에 따라 달라진다는 확신이 충분히 강하지는 않은 경향이 있습니다. ' +
      '감정적으로 크게 흔들리지는 않는 편이지만, ' +
      '결과의 원인을 자신과 연결 짓는 힘이 다소 약할 수 있습니다. ' +
      '신념이 보강되면 성장 흐름이 더 뚜렷해질 가능성이 있는 상태입니다.',
    mild:
      '이 학생은 수학을 할 때 감정 반응이 크지 않을 수 있으나, ' +
      '노력에 따라 실력이 달라질 수 있다는 믿음은 아직 뚜렷하지 않을 수 있습니다. ' +
      '감정과 신념 모두 방향이 명확히 자리 잡기 전 단계일 수 있으며, ' +
      '향후 신념 구조가 형성되는 과정에서 변화 가능성이 열려 있는 상태입니다.',
  },
  TYPE_C: {
    strong:
      '이 학생은 수학을 할 때 감정적으로 긴장하거나 흔들리는 반응이 비교적 높은 편이며, ' +
      '수학 실력이 노력이나 방법에 따라 달라질 수 있다는 확신도 충분히 자리 잡지 않은 상태입니다. ' +
      '어려움이 반복될 경우 스스로에 대한 해석이 위축될 가능성이 있습니다. ' +
      '현재는 감정과 신념 구조 모두 재정비가 필요한 상태입니다.',
    moderate:
      '이 학생은 수학을 할 때 감정적으로 긴장하거나 흔들리는 경향이 있으며, ' +
      '수학 실력이 노력에 따라 달라질 수 있다는 확신도 충분히 강하지 않은 편입니다. ' +
      '어려움이 반복되면 자기 해석이 위축될 가능성이 있습니다. ' +
      '현재는 감정과 신념 구조 모두 안정화가 필요한 경향이 보이는 상태입니다.',
    mild:
      '이 학생은 수학을 할 때 감정적 반응이 다소 클 수 있으며, ' +
      '노력에 따라 실력이 달라진다는 확신도 아직 뚜렷하지 않을 수 있습니다. ' +
      '감정과 신념 모두 방향이 명확히 자리 잡기 전 단계일 수 있으며, ' +
      '재정비를 통해 변화할 여지가 있는 상태입니다.',
  },
  TYPE_D: {
    strong:
      '이 학생은 수학이 노력에 따라 달라질 수 있다고 믿고 있으며, ' +
      '실패를 분석하려는 태도도 비교적 갖추고 있습니다. ' +
      '다만 수학을 할 때 감정적으로 긴장하거나 흔들리는 반응이 비교적 높은 편입니다. ' +
      '신념은 단단하지만 감정 기복이 학습 흐름에 영향을 줄 수 있는 상태입니다. ' +
      '감정 안정성이 보완되면 실력이 더 안정적으로 발휘될 가능성이 있습니다.',
    moderate:
      '이 학생은 수학이 노력에 따라 달라질 수 있다고 느끼는 경향이 있으며, ' +
      '실패를 분석하려는 태도도 어느 정도 갖추고 있는 편입니다. ' +
      '다만 수학을 할 때 감정적으로 긴장하거나 흔들리는 반응이 나타나는 경향이 있습니다. ' +
      '신념은 비교적 안정적이지만 감정 기복이 학습 흐름에 영향을 줄 수 있는 상태입니다. ' +
      '감정 안정성이 보완되면 실력 발휘가 더 안정될 가능성이 있습니다.',
    mild:
      '이 학생은 수학이 노력으로 달라질 수 있다는 생각을 어느 정도 갖고 있을 수 있으며, ' +
      '실패를 분석하려는 시도도 엿보입니다. ' +
      '다만 감정적 반응이 학습에 영향을 줄 가능성이 있으며, 아직 뚜렷한 패턴으로 자리 잡지는 않은 상태입니다. ' +
      '감정과 신념 모두 방향이 형성되는 과정에 있는 단계입니다.',
  },
};

function buildGradeDirectionFragment(
  typeCode: FeedbackTypeCode,
  studentGrade: number | null,
  peerAvgGrade: number | null,
): string {
  if (studentGrade == null || peerAvgGrade == null) return '';
  if (!Number.isFinite(studentGrade) || !Number.isFinite(peerAvgGrade)) return '';

  const fav = getTypeFavorability(typeCode);
  const isFavorable = fav === 'favorable' || fav === 'moderate_fav';
  const peerLabel = peerAvgGrade.toFixed(1);
  const diff = studentGrade - peerAvgGrade;

  if (Math.abs(diff) < 0.8) {
    return '현재 성적과 학습 상태가 비슷한 위치의 학생들과 유사한 흐름에 있습니다. ' +
      '이 흐름을 유지하면서 자신만의 속도로 나아가는 것이 중요합니다.';
  }

  if (diff > 0) {
    if (isFavorable) {
      return `현재 성적은 아직 이 학습 상태를 충분히 반영하지 못하고 있지만, ` +
        `비슷한 위치의 학생들 평균(${peerLabel}등급)을 고려하면 점차 안정적인 흐름으로 수렴할 가능성이 있습니다. ` +
        `지금의 감정과 신념 상태가 유지된다면 성적이 뒤따라올 수 있는 방향입니다.`;
    }
    return `현재 성적과 학습 상태 모두 보강이 필요한 시점입니다. ` +
      `비슷한 위치의 학생들 평균(${peerLabel}등급)과의 차이가 있지만, ` +
      `감정과 신념이 안정되면 성적에도 긍정적인 변화가 나타날 수 있습니다.`;
  }

  if (isFavorable) {
    return `현재 성적이 학습 상태와 잘 맞물려 있어 안정적인 흐름이 이어질 가능성이 높습니다. ` +
      `비슷한 위치의 학생들 평균(${peerLabel}등급)과 비교해도 좋은 방향에 있습니다.`;
  }
  return `현재 좋은 성적을 유지하고 있지만, 감정과 신념 상태가 안정되면 이 성과가 더 오래 지속될 수 있습니다. ` +
    `비슷한 위치의 학생들 평균(${peerLabel}등급)을 참고하면 지금의 상태를 점검하는 데 도움이 될 수 있습니다.`;
}

export function buildProfileSummaryText(
  typeCode: FeedbackTypeCode | null,
  vectorStrength: number | null,
  studentGrade: number | null,
  peerAvgGrade: number | null,
): string {
  if (!typeCode) return '';
  const intensity = getIntensityLevel(vectorStrength);
  const base = PROFILE_SUMMARY_TEMPLATES[typeCode]?.[intensity] ?? '';
  const direction = buildGradeDirectionFragment(typeCode, studentGrade, peerAvgGrade);
  if (!direction) return base;
  return `${base}\n\n${direction}`;
}

/* ────────────────────────────────────────────
 * Learning Traits Builder
 * 학습 성향 특징 = 공통 70% + 상세 30% + 행동 패턴
 * ──────────────────────────────────────────── */

type StrengthLevel = 'strong' | 'moderate' | 'weak';

function getStrengthLevel(percentile: number | null): StrengthLevel {
  if (percentile == null || !Number.isFinite(percentile)) return 'moderate';
  if (percentile >= 70) return 'strong';
  if (percentile >= 30) return 'moderate';
  return 'weak';
}

const LEARNING_TRAITS_COMMON: Record<FeedbackTypeCode, string> = {
  TYPE_A:
    '이 학생은 새로운 개념이나 유형을 접하면 먼저 구조를 이해하려는 경향이 있습니다. ' +
    '문제를 단순히 푸는 것보다 "왜 이런가"를 확인하려는 성향이 비교적 뚜렷합니다. ' +
    '어려움이 생겨도 시도 시간을 유지하는 편이며, 실패 후에도 비교적 빠르게 다시 시도합니다. ' +
    '학습 과정에서 탐색과 확장이 자연스럽게 나타나는 유형입니다.',
  TYPE_D:
    '이 학생은 제시된 구조를 따라가는 학습에서는 비교적 안정적인 흐름을 보입니다. ' +
    '설명이나 절차가 분명할 때 이해 속도가 유지되며, 과제 수행은 일정 수준 이상으로 완수합니다. ' +
    '다만 자발적으로 확장하거나 새로운 방식으로 탐색하는 움직임은 크지 않은 편입니다. ' +
    '학습이 구조화되어 있을수록 안정적인 성향을 보입니다.',
  TYPE_C:
    '이 학생은 학습 상황에서 긴장 반응이 먼저 올라오는 경향이 있습니다. ' +
    '설명을 듣는 동안에는 따라가지만, 혼자 문제를 해결하는 단계에서 급격히 위축될 수 있습니다. ' +
    '어려운 문제를 만났을 때 시도 시간이 짧아지거나 회피 행동이 나타날 수 있습니다. ' +
    '학습 에너지가 감정 반응에 크게 영향을 받는 유형입니다.',
  TYPE_B:
    '이 학생은 수업 초반 반응과 참여 에너지는 높은 편입니다. ' +
    '새로운 아이디어나 흥미 요소에 빠르게 반응합니다. ' +
    '다만 난도가 올라가거나 실패가 반복되면 학습 흐름이 급격히 흔들릴 수 있습니다. ' +
    '탐색 에너지는 충분하지만, 학습 구조의 안정성은 일정하지 않은 유형입니다.',
};

const LEARNING_TRAITS_DETAIL: Record<FeedbackTypeCode, Record<
  'grade_top' | 'grade_mid' | 'grade_low',
  string
> & Record<
  'meta_strong' | 'meta_moderate' | 'meta_weak',
  string
> & Record<
  'persist_strong' | 'persist_moderate' | 'persist_weak',
  string
>> = {
  TYPE_A: {
    grade_top: '현재 성취 수준과 학습 구조가 비교적 일관되게 연결되어 있습니다.',
    grade_mid: '성취가 일정 수준에 있으며, 탐색 습관이 더 정리되면 한 단계 올라갈 가능성이 있습니다.',
    grade_low: '실제 성취는 아직 충분히 반영되지 않았지만, 시도 유지 능력은 안정적인 편입니다.',
    meta_strong: '이해 점검이 체계적으로 이루어지고 있어, 학습 확장이 효율적으로 쌓일 수 있습니다.',
    meta_moderate: '이해 점검을 시도하고 있으나, 체계적인 정리 루틴이 좀 더 갖춰지면 효과가 클 수 있습니다.',
    meta_weak: '아이디어 탐색은 활발하나, 과정 점검이 체계적으로 정리되지는 않을 수 있습니다.',
    persist_strong: '막히는 문제에도 시도 시간을 충분히 유지하는 편입니다.',
    persist_moderate: '시도 유지 시간은 보통 수준이며, 흥미 있는 문제에서는 더 길어지는 경향이 있습니다.',
    persist_weak: '탐색은 활발하나 학습 흐름이 체계적으로 쌓이지 못할 가능성도 있습니다.',
  },
  TYPE_D: {
    grade_top: '현재 성취는 구조 이해 능력과 비교적 일치하는 흐름을 보입니다.',
    grade_mid: '구조화된 학습에서는 안정적이며, 확장 단계의 연습이 더해지면 성취가 올라갈 수 있습니다.',
    grade_low: '구조 이해는 가능하지만, 확장 단계에서 학습 밀도가 낮아질 수 있습니다.',
    meta_strong: '이해 점검은 비교적 안정적으로 이루어지는 편입니다.',
    meta_moderate: '이해 점검을 시도하고 있으며, 루틴이 좀 더 강화되면 자발적 확장에도 도움이 될 수 있습니다.',
    meta_weak: '주어진 구조는 따라가지만, 스스로 점검하고 확장하는 루틴은 아직 약한 편입니다.',
    persist_strong: '과제 수행 시 끝까지 유지하는 힘이 있어, 안정적인 완수가 가능합니다.',
    persist_moderate: '기본 과제는 완수하지만, 도전 문항에서는 시도 유지 시간이 짧아질 수 있습니다.',
    persist_weak: '난도가 올라갈수록 시도 유지 시간이 짧아질 가능성이 있습니다.',
  },
  TYPE_C: {
    grade_top: '현재 성취는 유지되고 있으나, 실력 발휘의 안정성은 일정하지 않을 수 있습니다.',
    grade_mid: '현재 성취 수준과 학습 반응 패턴이 비교적 유사한 방향을 보입니다.',
    grade_low: '성취와 학습 반응 모두 회복이 필요한 시점이며, 작은 성공 경험부터 쌓아가는 것이 중요합니다.',
    meta_strong: '이해 점검은 시도하고 있어, 감정이 안정되면 학습 효율이 올라갈 수 있습니다.',
    meta_moderate: '이해 점검은 시도하지만 감정 반응이 이를 방해할 가능성이 있습니다.',
    meta_weak: '감정 반응이 이해 점검보다 먼저 작동하여, 학습 루틴이 흔들릴 수 있습니다.',
    persist_strong: '어려움이 있어도 일정 시간은 버티려는 힘은 남아 있는 상태입니다.',
    persist_moderate: '시도 유지 시간이 감정 상태에 따라 달라질 수 있습니다.',
    persist_weak: '막히는 문제 앞에서 시도를 빨리 멈추는 경향이 나타날 수 있습니다.',
  },
  TYPE_B: {
    grade_top: '현재 성취는 높지만, 수행 안정성은 일정하지 않을 수 있습니다.',
    grade_mid: '흥미는 존재하지만 성취로 안정적으로 연결되지는 않는 흐름입니다.',
    grade_low: '흥미와 에너지는 있으나, 성취로 연결되기 위해 구조적인 지원이 필요한 상태입니다.',
    meta_strong: '아이디어 생성이 활발하고, 과정 점검도 비교적 이루어지고 있어 잠재력이 높습니다.',
    meta_moderate: '아이디어 생성은 활발하나 과정 점검은 체계적이지 않을 수 있습니다.',
    meta_weak: '흥미 중심의 탐색은 활발하지만, 이해 점검이 뒤따르지 않아 학습이 흩어질 수 있습니다.',
    persist_strong: '흥미가 유지되는 영역에서는 시도 시간이 길어지는 경향이 있습니다.',
    persist_moderate: '흥미 있는 문제는 오래 붙잡지만, 반복 연습에서는 금방 집중이 떨어질 수 있습니다.',
    persist_weak: '실패가 반복되면 시도 자체를 빠르게 포기하는 경향이 나타날 수 있습니다.',
  },
};

const LEARNING_TRAITS_BEHAVIORS: Record<FeedbackTypeCode, string[]> = {
  TYPE_A: [
    '새로운 유형을 보면 풀이 전에 조건·정의를 먼저 정리하려고 합니다.',
    '풀이가 끝난 뒤 "다른 방법도 되지 않아요?"라고 묻는 편입니다.',
    '오답이 나오면 바로 지우지 않고, 왜 틀렸는지 확인하려 합니다.',
    '숙제에서 기본 문제보다 응용·변형 문제에 더 오래 머무는 편입니다.',
    '시험 후 채점 결과보다 "내가 어디서 구조를 잘못 봤는지"를 먼저 봅니다.',
  ],
  TYPE_D: [
    '교사가 설명한 풀이 구조를 그대로 적용하면 정확하게 수행합니다.',
    '질문을 잘 하지는 않지만, 물어보면 이해는 빠른 편입니다.',
    '숙제는 빠짐없이 하지만, 추가 문제를 자발적으로 더 풀지는 않습니다.',
    '쉬운 문제는 빠르게 처리하고, 남은 시간에 멍해질 수 있습니다.',
    '시험에서는 실수는 적지만, 도전 문항은 시도 자체가 적습니다.',
  ],
  TYPE_C: [
    '문제를 받자마자 "어렵다…"라는 반응이 먼저 나올 수 있습니다.',
    '막히면 펜을 멈추고 손을 놓거나 한숨을 쉬는 경향이 있습니다.',
    '오답 확인 순간 표정 변화가 크고, 말수가 줄어들 수 있습니다.',
    '숙제를 시작하는 데 시간이 오래 걸리고, 어려운 문항은 비워두는 편입니다.',
    '시험 중 시간이 남아도 확신 없는 문제는 다시 보지 않는 경향이 있습니다.',
  ],
  TYPE_B: [
    '수업 초반에는 적극적으로 손을 들고 아이디어를 말하는 편입니다.',
    '새로운 방식은 좋아하지만, 반복 연습은 금방 흥미가 떨어질 수 있습니다.',
    '어려운 문제를 도전하다가 몇 번 실패하면 갑자기 집중이 꺾이는 경향이 있습니다.',
    '숙제는 좋아하는 유형은 과하게 하고, 싫은 유형은 최소로 하는 편입니다.',
    '시험이 끝난 뒤 "문제가 이상했어"라는 말을 할 수 있습니다.',
  ],
};

export function buildLearningTraitsText(
  typeCode: FeedbackTypeCode | null,
  vectorStrength: number | null,
  studentGrade: number | null,
  metacognitionPct: number | null,
  persistencePct: number | null,
): string {
  if (!typeCode) return '';

  const common = LEARNING_TRAITS_COMMON[typeCode] ?? '';
  const detail = LEARNING_TRAITS_DETAIL[typeCode];
  const behaviors = LEARNING_TRAITS_BEHAVIORS[typeCode] ?? [];
  const intensity = getIntensityLevel(vectorStrength);

  const gradeTier = getGradeTier(studentGrade);
  const metaLevel = getStrengthLevel(metacognitionPct);
  const persistLevel = getStrengthLevel(persistencePct);

  const detailLines: string[] = [];
  if (detail) {
    const gradeKey = gradeTier ? `grade_${gradeTier}` as const : null;
    if (gradeKey && detail[gradeKey]) detailLines.push(detail[gradeKey]);
    const metaKey = `meta_${metaLevel}` as const;
    if (detail[metaKey]) detailLines.push(detail[metaKey]);
    const persistKey = `persist_${persistLevel}` as const;
    if (detail[persistKey]) detailLines.push(detail[persistKey]);
  }

  const behaviorCount = intensity === 'strong' ? 5 : intensity === 'moderate' ? 3 : 2;
  const selectedBehaviors = behaviors.slice(0, behaviorCount);

  const parts: string[] = [common];
  if (detailLines.length > 0) {
    parts.push(detailLines.join('\n'));
  }
  if (selectedBehaviors.length > 0) {
    const header = intensity === 'mild'
      ? '다음과 같은 행동이 나타날 수 있습니다:'
      : '다음과 같은 행동이 나타나는 편입니다:';
    parts.push(`${header}\n${selectedBehaviors.map((b, i) => `${i + 1}. ${b}`).join('\n')}`);
  }

  return parts.join('\n\n');
}

/* ────────────────────────────────────────────
 * Core Strengths Builder
 * 핵심 강점 = 도입(70%) + 강점 항목(강도별) + 상세(30%) + 마무리
 * 성적 미반영 · 긍정 해석 중심 · 전략 미포함
 * ──────────────────────────────────────────── */

const CORE_STRENGTHS_INTRO: Record<FeedbackTypeCode, string> = {
  TYPE_A:
    '이 학생은 수학을 대하는 감정과 믿음이 모두 안정적이어서, ' +
    '꾸준히 성장할 수 있는 힘이 있습니다.',
  TYPE_D:
    '이 학생은 "할 수 있다"는 믿음은 있지만 수학에 대한 감정 에너지가 낮은 편입니다. ' +
    '폭발적이진 않지만 쉽게 무너지지 않는 안정적인 힘이 있습니다.',
  TYPE_C:
    '이 학생은 감정과 믿음 모두 아직 회복이 필요한 상태이지만, ' +
    '환경이 바뀌면 크게 달라질 수 있는 숨겨진 가능성이 있습니다.',
  TYPE_B:
    '이 학생은 수학에 대한 에너지는 높지만 아직 "나도 할 수 있다"는 믿음이 불안정합니다. ' +
    '불꽃이 붙으면 강한 힘을 발휘할 수 있는 가능성이 있습니다.',
};

const CORE_STRENGTHS_ITEMS: Record<FeedbackTypeCode, { mild: string[][]; strong: string[][] }> = {
  TYPE_A: {
    mild: [
      ['설명을 들을 때 "왜 그런지"를 먼저 이해하려는 경향이 있습니다.', '설명을 들을 때 "왜 그런지"를 먼저 이해하려는 경향이 비교적 뚜렷합니다.', '설명을 들을 때 "왜 그런지"를 먼저 이해하려는 경향이 강하게 나타납니다.'],
      ['어려운 문제를 만나도 비교적 빨리 다시 시도하는 편입니다.', '어려운 문제를 만나도 빨리 다시 시도하는 힘이 비교적 뚜렷합니다.', '어려운 문제를 만나도 빨리 다시 시도하는 힘이 강하게 나타납니다.'],
      ['실수가 나와도 공부 흐름이 크게 흔들리지 않는 편입니다.', '실수가 나와도 공부 흐름을 유지하는 안정감이 뚜렷한 편입니다.', '실수가 나와도 공부 흐름을 유지하는 안정감이 강하게 나타납니다.'],
      ['문제를 풀 때 "왜 이 답이 나오는지"를 확인하려는 습관이 있습니다.', '문제를 풀 때 "왜 이 답이 나오는지"를 확인하려는 습관이 비교적 뚜렷합니다.', '문제를 풀 때 "왜 이 답이 나오는지"를 확인하려는 습관이 강하게 나타납니다.'],
    ],
    strong: [
      ['처음 보는 문제도 겁내지 않고 먼저 시도하는 편입니다.', '처음 보는 문제를 겁내지 않고 시도하는 적극성이 뚜렷한 편입니다.', '처음 보는 문제를 겁내지 않고 먼저 시도하는 적극성이 강하게 나타납니다.'],
      ['답을 맞히는 것보다 "왜 이렇게 되는지"를 이해하려는 편입니다.', '답을 맞히는 것보다 "왜 이렇게 되는지"를 이해하려는 경향이 비교적 뚜렷합니다.', '답을 맞히는 것보다 "왜 이렇게 되는지"를 이해하려는 경향이 강하게 나타납니다.'],
      ['틀린 문제를 "왜 틀렸지?" 하고 돌아보는 태도가 있습니다.', '틀린 문제를 분석하고 다음에 활용하는 태도가 비교적 안정적입니다.', '틀린 문제를 분석하고 다음에 활용하는 태도가 확실하게 나타납니다.'],
      ['서로 다른 개념을 연결해서 스스로 넓혀가는 편입니다.', '서로 다른 개념을 연결해서 스스로 넓혀가는 능력이 뚜렷한 편입니다.', '서로 다른 개념을 연결해서 스스로 넓혀가는 능력이 강하게 나타납니다.'],
      ['어려운 문제에도 오래 붙잡고 있는 편입니다.', '어려운 문제에서도 오래 집중하는 힘(몰입 지속력)이 비교적 뚜렷합니다.', '어려운 문제에서도 오래 집중하는 힘(몰입 지속력)이 강하게 나타납니다.'],
      ['점수와 관계없이 "나는 성장하고 있다"는 방향을 유지하는 편입니다.', '점수와 관계없이 성장 방향을 유지하는 힘이 비교적 안정적입니다.', '점수와 관계없이 성장 방향을 유지하는 힘이 확실하게 나타납니다.'],
      ['문제가 어려워져도 "나는 할 수 있다"는 느낌(자기 효능감*)이 유지되는 편입니다.\n  * 자기 효능감: 어떤 일을 해낼 수 있다고 스스로 믿는 감각', '문제가 어려워져도 자기 효능감*을 유지하는 안정감이 뚜렷한 편입니다.\n  * 자기 효능감: 어떤 일을 해낼 수 있다고 스스로 믿는 감각', '문제가 어려워져도 자기 효능감*이 흔들리지 않는 안정감이 강하게 나타납니다.\n  * 자기 효능감: 어떤 일을 해낼 수 있다고 스스로 믿는 감각'],
      ['공부하면서 "아, 이거 재밌다"는 느낌을 받을 가능성이 있습니다.', '공부하면서 지적 즐거움을 경험하는 경향이 비교적 뚜렷합니다.', '공부하면서 지적 즐거움을 경험하는 경향이 강하게 나타납니다.'],
    ],
  },
  TYPE_D: {
    mild: [
      ['정해진 풀이 순서를 정확하게 따라가는 편입니다.', '정해진 풀이 순서를 정확하게 따라가는 능력이 비교적 뚜렷합니다.', '정해진 풀이 순서를 정확하게 따라가는 능력이 강하게 나타납니다.'],
      ['설명을 들으면 이해하고 넘어갈 수 있는 편입니다.', '설명을 듣고 이해하는 능력이 비교적 안정적입니다.', '설명을 듣고 이해하는 능력이 강하게 나타납니다.'],
      ['틀려도 감정적으로 크게 흔들리지 않는 편입니다.', '틀려도 감정적으로 크게 흔들리지 않는 안정감이 뚜렷한 편입니다.', '틀려도 감정적으로 크게 흔들리지 않는 안정감이 확실하게 나타납니다.'],
    ],
    strong: [
      ['잘 정리된 설명을 빠르게 받아들이는 편입니다.', '잘 정리된 설명을 빠르게 받아들이는 능력이 비교적 뚜렷합니다.', '잘 정리된 설명을 빠르게 받아들이는 능력이 강하게 나타납니다.'],
      ['같은 유형을 반복할 때 정확도가 높은 편입니다.', '같은 유형을 반복할 때 정확도가 비교적 안정적입니다.', '같은 유형을 반복할 때 정확도가 강하게 나타납니다.'],
      ['매일 공부하는 습관이 비교적 유지되는 편입니다.', '매일 공부하는 습관(학습 루틴)의 안정감이 뚜렷한 편입니다.', '매일 공부하는 습관(학습 루틴)의 안정감이 확실하게 나타납니다.'],
      ['실수 뒤에도 감정 변화가 적어 공부 흐름이 끊기지 않는 편입니다.', '실수 뒤에도 감정 변화가 적어 공부 흐름을 유지하는 힘이 비교적 뚜렷합니다.', '실수 뒤에도 감정 변화가 적어 공부 흐름이 끊기지 않는 안정감이 강하게 나타납니다.'],
      ['시간이 지나면서 조금씩 오를 수 있는 가능성이 있습니다.', '시간이 지나면서 조금씩 오르는 흐름이 비교적 뚜렷합니다.', '시간이 지나면서 조금씩 오르는 흐름이 강하게 나타납니다.'],
      ['꾸준히 하는 것이 실력으로 쌓일 가능성이 있습니다.', '꾸준히 하는 것이 실력으로 이어지는 흐름이 비교적 안정적입니다.', '꾸준히 하는 것이 실력으로 이어지는 흐름이 확실하게 나타납니다.'],
      ['과제를 빠지지 않고 해 오는 편입니다.', '과제 완수율이 비교적 뚜렷합니다.', '과제 완수율이 강하게 나타납니다.'],
    ],
  },
  TYPE_C: {
    mild: [
      ['선생님 설명을 듣는 동안은 집중할 수 있는 편입니다.', '선생님 설명을 듣는 동안 집중을 유지하는 힘이 비교적 안정적입니다.', '선생님 설명을 듣는 동안 집중을 유지하는 힘이 강하게 나타납니다.'],
      ['이해하는 능력 자체가 부족한 것은 아닙니다.', '환경만 맞으면 이해 능력이 충분히 발휘될 가능성이 비교적 뚜렷합니다.', '환경만 맞으면 이해 능력이 충분히 발휘될 가능성이 강하게 나타납니다.'],
    ],
    strong: [
      ['분위기 변화를 잘 느끼는 섬세한 감각이 있습니다.', '분위기 변화를 잘 느끼는 섬세한 감각이 비교적 뚜렷합니다.', '분위기 변화를 잘 느끼는 섬세한 감각이 강하게 나타납니다.'],
      ['한번 틀린 문제를 잘 기억해서 같은 실수를 줄일 가능성이 있습니다.', '한번 틀린 문제를 잘 기억해서 같은 실수를 줄이는 경향이 비교적 뚜렷합니다.', '한번 틀린 문제를 잘 기억해서 같은 실수를 줄이는 경향이 강하게 나타납니다.'],
      ['편안한 환경에서는 집중력이 올라갈 수 있습니다.', '편안한 환경에서는 집중력이 올라가는 경향이 비교적 뚜렷합니다.', '편안한 환경에서는 집중력이 크게 올라가는 경향이 확실하게 나타납니다.'],
      ['다른 사람의 감정을 잘 읽고 공감하는 힘이 있는 편입니다.', '다른 사람의 감정을 잘 읽고 공감하는 힘이 비교적 뚜렷합니다.', '다른 사람의 감정을 잘 읽고 공감하는 힘이 강하게 나타납니다.'],
      ['작은 성공 하나에도 의욕이 올라가는 편입니다.', '작은 성공 하나에도 의욕이 올라가는 폭이 비교적 뚜렷합니다.', '작은 성공 하나에도 의욕이 크게 올라가는 경향이 강하게 나타납니다.'],
      ['안정적으로 응원받는 환경에서 크게 달라질 가능성이 있습니다.', '안정적으로 응원받는 환경에서 크게 달라질 가능성이 비교적 뚜렷합니다.', '안정적으로 응원받는 환경에서 크게 달라질 가능성이 확실하게 나타납니다.'],
    ],
  },
  TYPE_B: {
    mild: [
      ['재미있으면 적극적으로 참여하는 편입니다.', '재미있는 것에 적극적으로 참여하는 경향이 비교적 뚜렷합니다.', '재미있는 것에 적극적으로 참여하는 경향이 강하게 나타납니다.'],
      ['아이디어가 빠르게 떠오르는 편입니다.', '아이디어가 빠르게 떠오르는 속도가 비교적 뚜렷합니다.', '아이디어가 빠르게 떠오르는 속도가 강하게 나타납니다.'],
    ],
    strong: [
      ['새로운 문제를 보면 빠르게 접근하는 편입니다.', '새로운 문제에 빠르게 접근하는 경향이 비교적 뚜렷합니다.', '새로운 문제에 빠르게 접근하는 경향이 강하게 나타납니다.'],
      ['남들과 다른 방법으로 풀어보려는 경향이 있습니다.', '남들과 다른 방법으로 풀어보려는 시도가 비교적 뚜렷합니다.', '남들과 다른 방법으로 풀어보려는 시도가 강하게 나타납니다.'],
      ['새로운 것을 찾아보려는 에너지가 있는 편입니다.', '새로운 것을 찾아보려는 에너지가 비교적 안정적입니다.', '새로운 것을 찾아보려는 에너지가 강하게 나타납니다.'],
      ['생각을 넓혀가는 힘이 있는 편입니다.', '생각을 넓혀가는 힘이 비교적 뚜렷합니다.', '생각을 넓혀가는 힘이 강하게 나타납니다.'],
      ['좋아하는 분야에서는 깊이 빠져드는 편입니다.', '좋아하는 분야에서의 몰입도가 비교적 뚜렷합니다.', '좋아하는 분야에서의 몰입도가 확실하게 나타납니다.'],
      ['수업 시작할 때 에너지가 올라가는 편입니다.', '수업 시작할 때 에너지가 올라가는 경향이 비교적 뚜렷합니다.', '수업 시작할 때 에너지가 올라가는 경향이 강하게 나타납니다.'],
      ['감정이 "밀어주는 힘"이 되는 편입니다.', '감정이 "밀어주는 힘"이 되는 경향이 비교적 안정적입니다.', '감정이 "밀어주는 힘"이 되는 경향이 강하게 나타납니다.'],
      ['의미를 느끼는 주제에서는 빠르게 성장할 가능성이 있습니다.', '의미를 느끼는 주제에서 빠르게 성장하는 경향이 비교적 뚜렷합니다.', '의미를 느끼는 주제에서 빠르게 성장하는 경향이 확실하게 나타납니다.'],
    ],
  },
};

const CORE_STRENGTHS_CLOSING: Record<FeedbackTypeCode, string> = {
  TYPE_A: '구조 이해와 탐색이 자연스러운 만큼, 이를 실전 점수로 연결하는 것이 다음 단계입니다.',
  TYPE_D: '반복과 절차에 강한 만큼, 확장과 응용 영역에서의 작은 시도가 도약의 열쇠가 됩니다.',
  TYPE_C: '안전한 환경에서 작은 성공 경험이 쌓이면, 실력 발휘의 안정성이 크게 달라질 수 있습니다.',
  TYPE_B: '흥미 에너지를 구조화된 학습 흐름에 연결하면, 폭발적인 성장이 가능합니다.',
};

const CORE_STRENGTHS_DETAIL: Record<FeedbackTypeCode, Record<
  'meta_strong' | 'meta_moderate' | 'meta_weak' | 'persist_strong' | 'persist_moderate' | 'persist_weak',
  string
>> = {
  TYPE_A: {
    meta_strong: '스스로 "내가 제대로 이해했나?" 확인하는 힘이 뒷받침되어 있어, 강점이 더 효과적으로 쌓일 수 있습니다.',
    meta_moderate: '스스로 점검하는 습관을 시도하고 있으며, 이 습관이 더 정리되면 성장 속도가 더 빨라질 수 있습니다.',
    meta_weak: '탐색은 활발하지만, "내가 뭘 이해했고 뭘 모르는지" 확인하는 습관이 더해지면 강점이 더 안정적으로 발휘될 수 있습니다.',
    persist_strong: '어려운 문제도 오래 붙잡는 힘이 있어, 강점이 충분히 발휘되고 있습니다.',
    persist_moderate: '문제를 붙잡는 시간은 보통 수준이며, 재미있는 영역에서 강점이 더 잘 드러납니다.',
    persist_weak: '탐색 에너지는 충분하지만, 어려운 문제를 좀 더 오래 붙잡는 힘이 생기면 강점이 더 오래 이어질 수 있습니다.',
  },
  TYPE_D: {
    meta_strong: '스스로 점검하는 습관이 안정적이어서, 체계적인 환경에서 강점이 꾸준히 발휘됩니다.',
    meta_moderate: '스스로 점검하는 습관을 시도하고 있으며, 이 습관이 더 강해지면 스스로 넓혀가는 공부에서도 강점이 나타날 수 있습니다.',
    meta_weak: '정해진 순서는 잘 따라가지만, "내가 뭘 이해했나?" 확인하는 습관이 더해지면 강점이 더 넓은 범위에서 발휘될 수 있습니다.',
    persist_strong: '과제를 끝까지 해내는 힘이 있어, 실력이 꾸준히 쌓일 수 있습니다.',
    persist_moderate: '기본 과제에서는 안정적이며, 도전 과제에서도 오래 붙잡는 힘이 더해지면 성장 폭이 넓어질 수 있습니다.',
    persist_weak: '안정적인 공부 흐름이 있지만, 어려운 문제를 좀 더 오래 시도하는 힘이 더해지면 강점이 더 넓은 영역에서 나타날 수 있습니다.',
  },
  TYPE_C: {
    meta_strong: '마음이 안정되면, 이미 갖고 있는 "스스로 확인하는 능력"이 공부에 좋은 영향을 줄 수 있습니다.',
    meta_moderate: '스스로 확인하는 습관을 시도하는 편이며, 편안한 환경에서 이 능력이 더 잘 나타날 수 있습니다.',
    meta_weak: '마음이 먼저 안정되면, 스스로 확인하는 능력도 함께 자랄 가능성이 있습니다.',
    persist_strong: '어려운 상황에서도 버티려는 힘이 남아 있어, 작은 성공이 이어지면 변화의 시작이 될 수 있습니다.',
    persist_moderate: '문제를 붙잡는 시간이 감정 상태에 따라 달라질 수 있으며, 편안한 환경에서 더 길어질 수 있습니다.',
    persist_weak: '마음이 안정되면서 문제를 붙잡는 힘도 함께 회복되면, 숨겨진 가능성이 드러나기 시작할 수 있습니다.',
  },
  TYPE_B: {
    meta_strong: '아이디어 탐색과 스스로 점검하는 힘이 함께 작동해서, 에너지가 성과로 이어질 가능성이 높습니다.',
    meta_moderate: '탐색 에너지는 충분하며, "내가 뭘 이해했나?" 확인하는 습관이 더 정리되면 강점이 성과로 이어질 수 있습니다.',
    meta_weak: '에너지와 아이디어는 많지만, 스스로 확인하는 습관이 더해지면 강점이 흩어지지 않고 쌓일 수 있습니다.',
    persist_strong: '재미있는 영역에서는 오래 붙잡는 힘이 있어, 깊이 있는 공부가 가능합니다.',
    persist_moderate: '재미있는 영역에서는 오래 붙잡는 편이며, 이 패턴이 넓어지면 강점이 더 커질 수 있습니다.',
    persist_weak: '탐색 에너지는 강하지만, 어려운 문제를 좀 더 오래 붙잡는 힘이 생기면 강점이 더 안정적으로 나타날 수 있습니다.',
  },
};

const CIRCLED_NUMBERS = ['①','②','③','④','⑤','⑥','⑦','⑧','⑨','⑩','⑪','⑫'] as const;

function pickStrengthSentence(item: string[], intensity: IntensityLevel): string {
  const idx = intensity === 'mild' ? 0 : intensity === 'moderate' ? 1 : 2;
  return item[idx] ?? item[0];
}

export function buildCoreStrengthsText(
  typeCode: FeedbackTypeCode | null,
  vectorStrength: number | null,
  metacognitionPct: number | null,
  persistencePct: number | null,
): string {
  if (!typeCode) return '';

  const intro = CORE_STRENGTHS_INTRO[typeCode] ?? '';
  const pools = CORE_STRENGTHS_ITEMS[typeCode];
  const closing = CORE_STRENGTHS_CLOSING[typeCode] ?? '';
  const detail = CORE_STRENGTHS_DETAIL[typeCode];
  const intensity = getIntensityLevel(vectorStrength);
  const metaLevel = getStrengthLevel(metacognitionPct);
  const persistLevel = getStrengthLevel(persistencePct);

  let selectedItems: string[][] = [];
  if (pools) {
    if (intensity === 'mild') {
      selectedItems = pools.mild.slice(0, 3);
    } else if (intensity === 'moderate') {
      const needed = 6 - pools.mild.length;
      selectedItems = [...pools.mild, ...pools.strong.slice(0, Math.max(needed, 1))];
    } else {
      selectedItems = [...pools.mild, ...pools.strong];
    }
  }

  const styledItems = selectedItems.map((item, i) => {
    const num = CIRCLED_NUMBERS[i] ?? `${i + 1}.`;
    return `${num} ${pickStrengthSentence(item, intensity)}`;
  });

  const detailLines: string[] = [];
  if (detail) {
    const metaKey = `meta_${metaLevel}` as const;
    if (detail[metaKey]) detailLines.push(detail[metaKey]);
    const persistKey = `persist_${persistLevel}` as const;
    if (detail[persistKey]) detailLines.push(detail[persistKey]);
  }

  const parts: string[] = [intro];
  if (styledItems.length > 0) {
    parts.push(styledItems.join('\n'));
  }
  if (detailLines.length > 0) {
    parts.push(detailLines.join('\n'));
  }
  if (closing) {
    parts.push(closing);
  }

  return parts.join('\n\n');
}

/* ────────────────────────────────────────────
 * Cautions Builder
 * 주의해야할 부분 = 도입 + 주의 항목(강도별) + 상세 + 마무리
 * 전략/처방 없음 · 리스크 중심 · 강점 대비 2/3 분량
 * ──────────────────────────────────────────── */

const CAUTIONS_INTRO: Record<FeedbackTypeCode, string> = {
  TYPE_A:
    '이 학생은 감정과 믿음이 모두 안정적이지만, ' +
    '이런 상태가 계속되면 주의할 부분이 있습니다.',
  TYPE_D:
    '이 학생은 공부의 안정감이 높지만, ' +
    '이런 상태가 계속되면 주의할 부분이 있습니다.',
  TYPE_C:
    '이 학생은 감정과 믿음 모두 회복이 필요한 상태로, ' +
    '이런 상태가 계속되면 주의할 부분이 있습니다.',
  TYPE_B:
    '이 학생은 에너지는 높지만 믿음이 불안정한 상태로, ' +
    '이런 상태가 계속되면 주의할 부분이 있습니다.',
};

const CAUTIONS_ITEMS: Record<FeedbackTypeCode, { mild: string[][]; strong: string[][] }> = {
  TYPE_A: {
    mild: [
      ['이것저것 탐색은 하지만, 배운 것이 정리되지 않고 흘러갈 가능성이 있습니다.', '이것저것 탐색은 하지만, 배운 것이 정리되지 않고 흘러가는 경향이 비교적 뚜렷합니다.', '이것저것 탐색은 하지만, 배운 것이 정리 없이 흘러가는 패턴이 계속 반복될 가능성이 있습니다.'],
      ['어려운 문제에만 관심이 가고, 기본 반복 연습이 약해질 가능성이 있습니다.', '어려운 문제에만 관심이 가고, 기본 반복 연습이 약해지는 경향이 계속될 수 있습니다.', '어려운 문제에만 관심이 가고, 기본 반복 연습이 약해지는 패턴이 굳어질 수 있습니다.'],
      ['점수가 낮게 나오면 생각보다 실망이 클 가능성이 있습니다.', '점수가 낮게 나오면 생각보다 실망이 뚜렷하게 나타날 수 있습니다.', '성장 속도에 비해 점수가 따라오지 않으면, 실망 반응이 크게 나타날 수 있습니다.'],
    ],
    strong: [
      ['"이해"에 집중하느라 시험에 맞춘 연습이 느슨해질 가능성이 있습니다.\n  * 실전 최적화: 시험에서 실수 없이 빠르게 푸는 연습', '"이해"에 집중하느라 시험에 맞춘 연습(실전 최적화*)이 느슨해지는 경향이 비교적 뚜렷합니다.\n  * 실전 최적화: 시험에서 실수 없이 빠르게 푸는 연습', '"이해"에 집중하느라 시험에 맞춘 연습(실전 최적화*)이 계속 느슨해질 수 있습니다.\n  * 실전 최적화: 시험에서 실수 없이 빠르게 푸는 연습'],
      ['한 문제에 너무 빠져들어 시간 관리가 흐트러질 가능성이 있습니다.', '한 문제에 너무 빠져들어 시간 관리가 흐트러지는 경향이 계속될 수 있습니다.', '한 문제에 빠져드는 패턴이 반복되면서 시간 관리가 계속 흐트러질 수 있습니다.'],
      ['기대만큼 점수가 안 나오면 의욕이 떨어질 가능성이 있습니다.', '기대만큼 점수가 안 나오면 의욕이 뚜렷하게 떨어질 수 있습니다.', '기대만큼 점수가 안 나오는 것이 반복되면, 의욕이 계속 떨어질 수 있습니다.'],
      ['스스로에게 너무 높은 기준을 세워서 완벽하게 하려다 지칠 가능성이 있습니다.', '스스로에게 너무 높은 기준을 세우는 경향이 비교적 뚜렷합니다.', '스스로에게 너무 높은 기준을 세우는 패턴이 계속 반복될 수 있습니다.'],
      ['이해하는 데 시간을 많이 쓰고, 실제 점수로 연결되는 효율이 떨어질 가능성이 있습니다.', '이해하는 데 시간을 많이 쓰고, 실제 점수로 연결되는 효율이 뚜렷하게 떨어질 수 있습니다.', '이해 과정에만 치우치는 패턴이 지속되면, 실제 점수로 이어지는 효율이 계속 낮아질 수 있습니다.'],
    ],
  },
  TYPE_D: {
    mild: [
      ['공부는 하지만, 깊이 빠져드는 느낌(몰입)이 약할 가능성이 있습니다.', '공부는 하지만, 깊이 빠져드는 느낌이 약한 경향이 비교적 뚜렷합니다.', '공부는 하지만, 깊이 빠져들지 못하는 패턴이 계속될 가능성이 있습니다.'],
      ['스스로 더 넓혀가려는 노력이 부족해 성장이 느릴 가능성이 있습니다.', '스스로 더 넓혀가려는 노력이 부족해 성장이 느려지는 경향이 계속될 수 있습니다.', '스스로 넓혀가려는 노력이 부족한 패턴이 이어지면 성장이 정체될 가능성이 있습니다.'],
    ],
    strong: [
      ['"이 정도면 됐다"고 빨리 마무리하려는 경향이 나타날 수 있습니다.', '"이 정도면 됐다"고 빨리 마무리하려는 경향이 비교적 뚜렷합니다.', '"이 정도면 됐다"고 빨리 마무리하려는 패턴이 굳어질 수 있습니다.'],
      ['선생님이 방향을 안 잡아 주면 갑자기 소극적으로 변할 가능성이 있습니다.', '선생님이 방향을 안 잡아 주면 소극적으로 변하는 경향이 비교적 뚜렷합니다.', '선생님이 방향을 안 잡아 주면 소극적으로 변하는 패턴이 계속 반복될 수 있습니다.'],
      ['재미있는 요소가 없으면 공부의 밀도가 떨어질 가능성이 있습니다.', '재미있는 요소가 없으면 공부의 밀도가 뚜렷하게 떨어질 수 있습니다.', '재미있는 요소가 없으면 공부의 밀도가 계속 떨어지는 패턴이 반복될 수 있습니다.'],
      ['중상위권에서 더 이상 오르지 못하고 멈출 가능성이 있습니다.', '중상위권에서 정체되는 경향이 계속될 수 있습니다.', '중상위권에서 정체가 굳어질 수 있습니다.'],
      ['응용 문제나 생각을 넓혀야 하는 문제에서 소극적으로 넘어갈 가능성이 있습니다.', '응용 문제에서 소극적으로 넘어가는 경향이 비교적 뚜렷합니다.', '응용 문제에서 소극적으로 넘어가는 패턴이 계속 반복될 수 있습니다.'],
    ],
  },
  TYPE_C: {
    mild: [
      ['틀리는 경험이 반복되면 "나는 못해"라는 생각이 굳어질 가능성이 있습니다.', '틀리는 경험이 반복되면 "나는 못해"라는 생각이 뚜렷해질 수 있습니다.', '틀리는 경험이 반복되면 "나는 못해"라는 생각이 굳어질 수 있습니다.'],
      ['문제를 붙잡는 시간 자체가 짧아질 가능성이 있습니다.', '문제를 붙잡는 시간 자체가 짧아지는 경향이 계속될 수 있습니다.', '문제를 붙잡는 시간이 계속 짧아지는 패턴이 굳어질 수 있습니다.'],
    ],
    strong: [
      ['어려운 문제를 아예 시도하지 않으려는 경향이 나타날 수 있습니다.', '어려운 문제를 아예 시도하지 않으려는 경향이 비교적 뚜렷합니다.', '어려운 문제를 아예 시도하지 않으려는 패턴이 계속 강해질 수 있습니다.'],
      ['"내가 나빠서 못하는 거야"라는 생각이 공부 자체를 피하게 만들 가능성이 있습니다.', '"내가 나빠서 못하는 거야"라는 생각이 공부를 피하게 만드는 경향이 비교적 뚜렷합니다.', '"내가 나빠서 못하는 거야"라는 생각이 공부를 피하게 만드는 패턴이 이어질 수 있습니다.'],
      ['시험에서 실제 실력만큼 발휘하지 못할 가능성이 있습니다.', '시험에서 실제 실력만큼 발휘하지 못하는 경향이 비교적 뚜렷합니다.', '시험에서 실력만큼 발휘하지 못하는 패턴이 계속 반복될 수 있습니다.'],
      ['긴장이나 불안이 먼저 올라와서 생각이 멈출 가능성이 있습니다.', '긴장이나 불안이 먼저 올라와서 생각이 멈추는 경향이 비교적 뚜렷합니다.', '긴장이나 불안이 생각을 멈추게 하는 패턴이 굳어질 수 있습니다.'],
      ['쉬운 것만 골라 하는 패턴이 나타날 수 있습니다.', '쉬운 것만 골라 하는 경향이 비교적 뚜렷합니다.', '쉬운 것만 골라 하는 패턴이 굳어질 수 있습니다.'],
    ],
  },
  TYPE_B: {
    mild: [
      ['재미있는 것만 골라 공부하는 쪽으로 치우칠 가능성이 있습니다.', '재미있는 것만 골라 공부하는 경향이 비교적 뚜렷합니다.', '재미있는 것만 골라 공부하는 패턴이 굳어질 수 있습니다.'],
      ['틀리는 순간 의욕이 확 떨어질 가능성이 있습니다.', '틀리는 순간 의욕이 확 떨어지는 경향이 비교적 뚜렷합니다.', '틀리는 순간 의욕이 확 떨어지는 패턴이 계속 반복될 수 있습니다.'],
    ],
    strong: [
      ['기분에 따라 공부 집중도가 크게 흔들릴 가능성이 있습니다.', '기분에 따라 공부 집중도가 흔들리는 경향이 비교적 뚜렷합니다.', '기분에 따라 공부 집중도가 크게 흔들리는 패턴이 계속 반복될 수 있습니다.'],
      ['계획 없이 도전만 반복하다 실패가 쌓일 가능성이 있습니다.', '계획 없이 도전만 반복하는 경향이 비교적 뚜렷합니다.', '계획 없이 도전만 반복되면서 실패가 계속 쌓일 수 있습니다.'],
      ['"문제가 이상했어", "선생님이 안 알려줬어" 같은 식으로 결과를 돌릴 가능성이 있습니다.\n  * 외적 귀인: 결과의 원인을 자기 밖의 것(환경, 운 등)으로 돌리는 경향', '"문제가 이상했어" 식의 해석(외적 귀인*)이 비교적 뚜렷합니다.\n  * 외적 귀인: 결과의 원인을 자기 밖의 것(환경, 운 등)으로 돌리는 경향', '"문제가 이상했어" 식의 해석(외적 귀인*)이 계속 강해질 수 있습니다.\n  * 외적 귀인: 결과의 원인을 자기 밖의 것(환경, 운 등)으로 돌리는 경향'],
      ['좋아하는 과목과 싫어하는 과목 간 공부량 차이가 클 가능성이 있습니다.', '좋아하는 과목과 싫어하는 과목 간 공부량 차이가 비교적 뚜렷합니다.', '좋아하는 과목과 싫어하는 과목 간 공부량 차이가 계속 벌어질 수 있습니다.'],
      ['수업 처음엔 집중하지만, 후반으로 갈수록 집중이 떨어질 가능성이 있습니다.', '수업 처음엔 집중하지만, 후반으로 갈수록 집중 저하가 비교적 뚜렷합니다.', '수업 처음엔 집중하지만, 후반 집중 저하가 계속 반복될 수 있습니다.'],
    ],
  },
};

const CAUTIONS_CLOSING: Record<FeedbackTypeCode, string> = {
  TYPE_A: '주요 주의점: 이것저것 넓히는 데 치우치고, 시험에 맞춘 실전 연습이 부족해지는 것이 가장 큰 주의 포인트입니다.',
  TYPE_D: '주요 주의점: 안정적이지만 그 이상으로 나아가는 힘이 부족해지는 것이 가장 큰 주의 포인트입니다.',
  TYPE_C: '주요 주의점: 실력보다 감정이 먼저 반응해서 공부를 방해하는 것이 가장 큰 주의 포인트입니다.',
  TYPE_B: '주요 주의점: 에너지는 높지만 공부 흐름이 불안정한 것이 가장 큰 주의 포인트입니다.',
};

const CAUTIONS_DETAIL: Record<FeedbackTypeCode, Record<
  'meta_strong' | 'meta_moderate' | 'meta_weak' | 'persist_strong' | 'persist_moderate' | 'persist_weak',
  string
>> = {
  TYPE_A: {
    meta_strong: '다행히 "내가 뭘 이해했나?" 확인하는 습관이 있어, 위 주의점이 스스로 조절될 가능성이 있습니다.',
    meta_moderate: '스스로 점검하는 습관을 시도하고 있지만, 정리 습관이 부족하면 위 주의점이 계속될 수 있습니다.',
    meta_weak: '스스로 점검하는 습관이 약한 상태에서는 위 주의점이 더 뚜렷하게 나타날 수 있습니다.',
    persist_strong: '어려운 문제도 오래 붙잡는 힘이 있어, 시험 연습 부족 문제가 점차 나아질 수 있습니다.',
    persist_moderate: '문제를 붙잡는 시간이 보통 수준이어서, 재미있는 영역과 그렇지 않은 영역 간 차이가 나타날 수 있습니다.',
    persist_weak: '문제를 붙잡는 시간이 짧아, 넓게는 탐색하지만 깊이 있게 쌓이기 어려울 수 있습니다.',
  },
  TYPE_D: {
    meta_strong: '스스로 점검하는 습관이 안정적이어서, 위 주의점이 스스로 관리될 가능성이 있습니다.',
    meta_moderate: '스스로 점검하는 습관을 시도하고 있지만, 스스로 넓혀가는 공부까지는 이어지지 못할 수 있습니다.',
    meta_weak: '스스로 점검하는 습관이 약한 상태에서는 위 주의점이 소극적인 공부 패턴으로 이어질 수 있습니다.',
    persist_strong: '과제를 끝까지 해내는 힘이 있어, 방향만 잡히면 위 주의점이 줄어들 수 있습니다.',
    persist_moderate: '문제를 붙잡는 시간이 보통 수준이어서, 문제가 어려워지면 공부 밀도가 떨어질 수 있습니다.',
    persist_weak: '문제를 붙잡는 시간이 짧아, 도전 과제에서의 정체가 더 뚜렷해질 수 있습니다.',
  },
  TYPE_C: {
    meta_strong: '스스로 확인하는 능력이 갖추어져 있어, 마음이 안정되면 위 주의점이 자연스럽게 줄어들 수 있습니다.',
    meta_moderate: '스스로 확인하는 습관을 시도하지만, 긴장이나 불안이 방해해서 위 주의점이 계속될 수 있습니다.',
    meta_weak: '스스로 확인하는 습관이 약한 상태에서 긴장까지 겹치면, 위 주의점이 더 강하게 나타날 수 있습니다.',
    persist_strong: '버티려는 힘이 남아 있어, 편안한 환경에서는 위 주의점이 줄어들 가능성이 있습니다.',
    persist_moderate: '문제를 붙잡는 시간이 감정 상태에 따라 달라져, 위 주의점이 상황에 따라 변할 수 있습니다.',
    persist_weak: '문제를 붙잡는 시간이 짧아, 위 주의점이 "아예 안 하기" 패턴으로 이어질 가능성이 있습니다.',
  },
  TYPE_B: {
    meta_strong: '스스로 점검하는 힘이 함께 작동하면, 위 주의점이 에너지 조절로 줄어들 가능성이 있습니다.',
    meta_moderate: '스스로 점검하는 습관을 시도하고 있지만, 기분 변화 앞에서 꾸준함을 유지하기 어려울 수 있습니다.',
    meta_weak: '스스로 점검하는 습관이 약한 상태에서 기분 변화가 겹치면, 위 주의점이 더 뚜렷해질 수 있습니다.',
    persist_strong: '재미있는 영역에서는 오래 붙잡는 힘이 있어, 특정 영역에서는 위 주의점이 줄어들 수 있습니다.',
    persist_moderate: '문제를 붙잡는 시간이 영역마다 달라서, 재미없는 영역에서 위 주의점이 더 강하게 나타날 수 있습니다.',
    persist_weak: '문제를 붙잡는 시간이 짧아, 실패가 쌓이고 의욕이 떨어지는 악순환이 반복될 수 있습니다.',
  },
};

export function buildCautionsText(
  typeCode: FeedbackTypeCode | null,
  vectorStrength: number | null,
  metacognitionPct: number | null,
  persistencePct: number | null,
): string {
  if (!typeCode) return '';

  const cIntro = CAUTIONS_INTRO[typeCode] ?? '';
  const cPools = CAUTIONS_ITEMS[typeCode];
  const cClosing = CAUTIONS_CLOSING[typeCode] ?? '';
  const cDetail = CAUTIONS_DETAIL[typeCode];
  const cIntensity = getIntensityLevel(vectorStrength);
  const cMetaLevel = getStrengthLevel(metacognitionPct);
  const cPersistLevel = getStrengthLevel(persistencePct);

  let cSelected: string[][] = [];
  if (cPools) {
    if (cIntensity === 'mild') {
      cSelected = cPools.mild.slice(0, 2);
    } else if (cIntensity === 'moderate') {
      const needed = 4 - cPools.mild.length;
      cSelected = [...cPools.mild, ...cPools.strong.slice(0, Math.max(needed, 1))];
    } else {
      cSelected = [...cPools.mild, ...cPools.strong];
    }
  }

  const cStyled = cSelected.map((item, i) => {
    const num = CIRCLED_NUMBERS[i] ?? `${i + 1}.`;
    return `${num} ${pickStrengthSentence(item, cIntensity)}`;
  });

  const cDetailLines: string[] = [];
  if (cDetail) {
    const metaKey = `meta_${cMetaLevel}` as const;
    if (cDetail[metaKey]) cDetailLines.push(cDetail[metaKey]);
    const persistKey = `persist_${cPersistLevel}` as const;
    if (cDetail[persistKey]) cDetailLines.push(cDetail[persistKey]);
  }

  const cParts: string[] = [cIntro];
  if (cStyled.length > 0) {
    cParts.push(cStyled.join('\n'));
  }
  if (cDetailLines.length > 0) {
    cParts.push(cDetailLines.join('\n'));
  }
  if (cClosing) {
    cParts.push(cClosing);
  }

  return cParts.join('\n\n');
}

/* ────────────────────────────────────────────
 * Teaching Strategy Builder
 * 추천 수업 전략 = 공통 전략 3개 + 유형별 특별 전략 3개 + 마무리
 * 수업 구조/환경/과제 설계 중심 · 심리 설득 금지 · 고1 수준 언어
 * ──────────────────────────────────────────── */

const STRATEGY_COMMON: string[] = [
  '구조 가시화* 설계\n' +
  '모든 개념을 "정의 → 조건 → 적용 → 반례" 순서로 정리합니다. ' +
  '풀이 과정은 "한 줄 요약"으로 남기는 습관을 만들고, ' +
  '문제 유형을 구조 단위로 나누어 연습합니다.\n' +
  '  * 구조 가시화: 머릿속 개념을 눈에 보이는 형태로 정리하는 것',

  '오답 해석 프레임* 고정\n' +
  '틀린 문제를 "기분이 나쁜 경험"이 아니라 "어디서 구조가 어긋났는지 찾는 과정"으로 바꿉니다. ' +
  '오답 노트에는 감정이 아닌, 풀이 구조에서 빠진 부분만 기록합니다.\n' +
  '  * 오답 해석 프레임: 틀린 문제를 어떻게 받아들이는지를 정하는 기준',

  '수학 언어화* 설계\n' +
  '모든 개념을 기호와 문장 양쪽으로 바꿔 보는 연습을 합니다. ' +
  '풀이 과정은 "논리 문장"으로 설명하게 하고, ' +
  '기호 표현을 일상 말로, 일상 말을 다시 기호로 바꾸는 루틴을 반복합니다. ' +
  '말로 설명할 수 있는 개념만이 진짜 이해한 개념입니다.\n' +
  '  * 수학 언어화: 수학 기호를 말로, 말을 수학 기호로 바꿔 표현하는 훈련',
];

const STRATEGY_TYPE_SPECIFIC: Record<FeedbackTypeCode, string[]> = {
  TYPE_A: [
    '확장 제한 설계\n' +
    '한 개념당 확장 문제 수를 정해 둡니다. ' +
    '확장에 들어가기 전에 반드시 "정리 단계"를 거치게 합니다. ' +
    '탐색을 막지 않되, 배운 것이 정리된 상태에서 넓혀가도록 설계합니다.',

    '실전 전환 설계\n' +
    '같은 개념을 "시간 제한" 조건으로 다시 풀게 합니다. ' +
    '"이해했다"에서 끝내지 않고, 시험에서 빠르게 적용하는 연습을 별도로 설계합니다.',

    '압축 요약 훈련\n' +
    '"3줄 구조 요약" 루틴을 고정합니다. ' +
    '배운 개념을 핵심만 남겨 짧게 정리하는 연습을 반복합니다. ' +
    '넓히는 것이 강점인 학생에게는 압축이 성장을 빠르게 하는 장치가 됩니다.',
  ],
  TYPE_D: [
    '계단식 확장 설계\n' +
    '기본 문제 5개를 완료하면 자동으로 확장 문제 2개를 제공합니다. ' +
    '구조는 유지하되 난이도만 한 칸 올립니다. ' +
    '무리한 도전이 아니라 자연스러운 계단식 확장을 설계합니다.',

    '의미 연결 질문 삽입\n' +
    '매 단원마다 "이 개념이 시험에서 왜 중요한가?" 질문을 넣습니다. ' +
    '실생활 연결이 아니라, 시험 구조와의 연결을 보여줍니다. ' +
    '감정 에너지가 낮은 학생에게 의미 연결이 동기 보완 역할을 합니다.',

    '반복 구조 변형\n' +
    '같은 개념을 조금씩 다른 형태로 반복합니다. ' +
    '단순 반복은 금지하고, 조건이나 숫자를 미세하게 바꿔 연습합니다. ' +
    '안정적인 구조 위에 변화를 얹어 정체 구간을 돌파하게 설계합니다.',
  ],
  TYPE_C: [
    '성공 밀도 설계\n' +
    '한 수업 안에서 "맞히는 경험"의 비율이 60% 이상 되도록 설계합니다. ' +
    '난이도를 갑자기 올리지 않고, 감정이 안정된 상태에서 공부하도록 환경을 만듭니다.',

    '단계 분해 설계\n' +
    '한 문제를 3~4단계로 나누어 제공합니다. ' +
    '처음부터 완성된 문제를 주지 않고, 부분 완성 경험을 먼저 쌓게 합니다. ' +
    '"끝까지 풀었다"는 경험을 작은 단위로 자주 느끼도록 설계합니다.',

    '선택 구조 통제\n' +
    '문제 선택권을 넓게 주지 않습니다. ' +
    '쉬운 것만 골라 하는 패턴이 반복되지 않도록, ' +
    '적정 난이도의 문제를 순서대로 제시하여 회피 패턴을 자연스럽게 차단합니다.',
  ],
  TYPE_B: [
    '구조 먼저, 도전 나중\n' +
    '새로운 문제를 주기 전에 반드시 기본 구조를 확인합니다. ' +
    '"바로 도전"은 금지하고, 구조 확인이 끝난 후에 도전 문제를 제공합니다. ' +
    '실패가 쌓이지 않도록 순서를 설계합니다.',

    '흥미-기본기 교차 설계\n' +
    '퍼즐형 문제 2개 → 기본기 문제 3개 패턴을 반복합니다. ' +
    '재미있는 요소를 "보상"으로 활용하여, ' +
    '흥미 에너지가 기본기 연습으로 자연스럽게 이어지도록 설계합니다.',

    '실패 안정화 루틴\n' +
    '틀렸을 때 바로 다시 풀지 않고, 먼저 풀이 구조를 다시 확인하는 단계를 넣습니다. ' +
    '감정이 떨어지는 순간에 바로 재도전하면 기복이 커지므로, ' +
    '구조 확인이라는 완충 단계를 반드시 사이에 둡니다.',
  ],
};

const STRATEGY_CLOSING: Record<FeedbackTypeCode, string> = {
  TYPE_A: '설계 핵심: 넓히는 힘을 압축과 실전 전환으로 연결하는 것이 이 유형의 핵심 전략입니다.',
  TYPE_D: '설계 핵심: 안정적인 구조 위에 계단식 확장을 얹는 것이 이 유형의 핵심 전략입니다.',
  TYPE_C: '설계 핵심: 성공 경험의 밀도를 높여 감정 안정 기반을 먼저 확보하는 것이 이 유형의 핵심 전략입니다.',
  TYPE_B: '설계 핵심: 에너지를 구조에 먼저 연결하고, 기복을 완충하는 것이 이 유형의 핵심 전략입니다.',
};

const TYPE_LABEL: Record<FeedbackTypeCode, string> = {
  TYPE_A: '확장형',
  TYPE_D: '안정형',
  TYPE_C: '회복형',
  TYPE_B: '동기형',
};

export function buildTeachingStrategyText(
  typeCode: FeedbackTypeCode | null,
): string {
  if (!typeCode) return '';

  const typeSpecific = STRATEGY_TYPE_SPECIFIC[typeCode] ?? [];
  const sClosing = STRATEGY_CLOSING[typeCode] ?? '';
  const label = TYPE_LABEL[typeCode] ?? '';

  const commonItems = STRATEGY_COMMON.map((item, i) => {
    const num = CIRCLED_NUMBERS[i] ?? `${i + 1}.`;
    return `${num} ${item}`;
  });

  const typeItems = typeSpecific.map((item, i) => {
    const num = CIRCLED_NUMBERS[i] ?? `${i + 1}.`;
    return `${num} ${item}`;
  });

  const sParts: string[] = [];
  sParts.push('[ 공통 수업 설계 원칙 ]');
  sParts.push(commonItems.join('\n\n'));
  sParts.push(`[ ${label} 특별 전략 ]`);
  sParts.push(typeItems.join('\n\n'));
  if (sClosing) {
    sParts.push(sClosing);
  }

  return sParts.join('\n\n');
}

/* ────────────────────────────────────────────
 * Growth Checkpoint Builder
 * 향후 성장 체크포인트 = 도입 + 관찰 항목(강도별) + 강조(strong만) + 마무리
 * 전략/처방/평가 없음 · 관찰 가능한 변화 지표 중심
 * ──────────────────────────────────────────── */

const GROWTH_INTRO: Record<FeedbackTypeCode, string> = {
  TYPE_A:
    '이 학생의 핵심 이동 방향은 "확장 → 압축 → 실전 전환"입니다. ' +
    '아래 항목이 시간이 지나면서 변화하고 있는지 관찰합니다.',
  TYPE_D:
    '이 학생의 핵심 이동 방향은 "안정 → 확장 → 가속"입니다. ' +
    '아래 항목이 시간이 지나면서 변화하고 있는지 관찰합니다.',
  TYPE_C:
    '이 학생의 핵심 이동 방향은 "감정 안정 → 시도 유지 → 자기 해석 변화"입니다. ' +
    '아래 항목이 시간이 지나면서 변화하고 있는지 관찰합니다.',
  TYPE_B:
    '이 학생의 핵심 이동 방향은 "흥미 → 구조 고정 → 수행 안정"입니다. ' +
    '아래 항목이 시간이 지나면서 변화하고 있는지 관찰합니다.',
};

const GROWTH_ITEMS: Record<FeedbackTypeCode, { mild: string[][]; strong: string[][] }> = {
  TYPE_A: {
    mild: [
      ['배운 것을 말로 정리하는 횟수가 조금씩 늘어나는지 살펴봅니다.', '배운 것을 말로 정리하는 횟수가 뚜렷해지는지 확인합니다.', '배운 것을 말로 정리하는 습관이 안정적으로 나타나는지 확인합니다.'],
      ['틀린 문제 뒤에 풀이 구조를 요약하는 습관이 나타나는지 살펴봅니다.', '틀린 문제 뒤에 풀이 구조 요약이 뚜렷해지는지 확인합니다.', '틀린 문제 뒤에 풀이 구조 요약이 안정적으로 이루어지는지 확인합니다.'],
      ['도전 문제와 기본 문제의 균형이 유지되는지 살펴봅니다.', '도전 문제와 기본 문제의 균형이 뚜렷해지는지 확인합니다.', '도전 문제와 기본 문제의 균형이 안정적으로 유지되는지 확인합니다.'],
    ],
    strong: [
      ['새로운 것을 넓힌 뒤에 "요약 정리 단계"가 반드시 존재하는지 확인합니다.', '넓힌 뒤 요약 정리 단계가 뚜렷하게 나타나는지 확인합니다.', '넓힌 뒤 요약 정리 단계가 안정적으로 자리 잡고 있는지 확인합니다.'],
      ['시간 제한이 있는 상황에서도 풀이가 안정적으로 유지되는지 살펴봅니다.', '시간 제한 상황에서의 풀이 안정성이 뚜렷해지는지 확인합니다.', '시간 제한 상황에서의 풀이 안정성이 확실하게 연결되는지 확인합니다.'],
      ['실제 시험 점수와 이해도 사이의 차이가 줄어들고 있는지 살펴봅니다.', '시험 점수와 이해도 사이의 차이가 뚜렷하게 줄어드는지 확인합니다.', '시험 점수와 이해도가 안정적으로 가까워지고 있는지 확인합니다.'],
      ['도전하는 횟수와 실수하는 비율이 균형을 이루는지 살펴봅니다.', '도전 횟수와 실수 비율의 균형이 뚜렷해지는지 확인합니다.', '도전 횟수와 실수 비율의 균형이 안정적으로 유지되는지 확인합니다.'],
    ],
  },
  TYPE_D: {
    mild: [
      ['기본 문제를 처리하는 속도가 조금씩 빨라지는지 살펴봅니다.', '기본 문제 처리 속도 향상이 뚜렷해지는지 확인합니다.', '기본 문제 처리 속도 향상이 안정적으로 나타나는지 확인합니다.'],
      ['설명을 수동적으로 듣기만 하는 비율이 줄어드는지 살펴봅니다.', '수동적으로 듣기만 하는 비율 감소가 뚜렷해지는지 확인합니다.', '수동적으로 듣기만 하는 비율 감소가 안정적으로 유지되는지 확인합니다.'],
      ['이해한 뒤에 응용을 시도하는 횟수가 늘어나는지 살펴봅니다.', '이해 후 응용 시도 증가가 뚜렷해지는지 확인합니다.', '이해 후 응용 시도가 안정적으로 나타나는지 확인합니다.'],
    ],
    strong: [
      ['"이 정도면 됐다"고 빨리 마무리하는 패턴이 줄어드는지 살펴봅니다.', '빨리 마무리하는 패턴 감소가 뚜렷해지는지 확인합니다.', '빨리 마무리하는 패턴 감소가 안정적으로 유지되는지 확인합니다.'],
      ['확장 문제에 접근하는 횟수가 늘어나는지 살펴봅니다.', '확장 문제 접근 횟수 증가가 뚜렷해지는지 확인합니다.', '확장 문제 접근 횟수 증가가 안정적으로 연결되는지 확인합니다.'],
      ['난이도가 올라갔을 때 포기 대신 탐색을 시도하는지 살펴봅니다.', '난이도 상승 시 탐색 시도가 뚜렷해지는지 확인합니다.', '난이도 상승 시 탐색 시도가 안정적으로 유지되는지 확인합니다.'],
      ['단원 후반부에서도 공부 밀도가 유지되는지 살펴봅니다.', '단원 후반부 공부 밀도 유지가 뚜렷해지는지 확인합니다.', '단원 후반부 공부 밀도가 안정적으로 유지되는지 확인합니다.'],
    ],
  },
  TYPE_C: {
    mild: [
      ['막힌 뒤에 다시 시도하는 시간이 조금씩 늘어나는지 살펴봅니다.', '막힌 뒤 재시도 시간 증가가 뚜렷해지는지 확인합니다.', '막힌 뒤 재시도 시간이 안정적으로 늘어나는지 확인합니다.'],
      ['틀린 직후의 표정이나 태도 변화 폭이 줄어드는지 살펴봅니다.', '틀린 직후 반응 폭 감소가 뚜렷해지는지 확인합니다.', '틀린 직후 반응 폭 감소가 안정적으로 유지되는지 확인합니다.'],
      ['부분적으로라도 풀어낸 경험이 쌓이고 있는지 살펴봅니다.', '부분 해결 경험의 누적이 뚜렷해지는지 확인합니다.', '부분 해결 경험이 안정적으로 쌓이고 있는지 확인합니다.'],
    ],
    strong: [
      ['문제를 시작하기 전의 긴장 반응이 줄어드는지 살펴봅니다.', '문제 시작 전 긴장 반응 감소가 뚜렷해지는지 확인합니다.', '문제 시작 전 긴장 반응 감소가 안정적으로 나타나는지 확인합니다.'],
      ['"모르겠다"라고 말하는 빈도가 줄어드는지 살펴봅니다.', '"모르겠다" 발화 빈도 감소가 뚜렷해지는지 확인합니다.', '"모르겠다" 발화 빈도 감소가 안정적으로 연결되는지 확인합니다.'],
      ['어려운 문제에서도 일정 시간 동안 버티는지 살펴봅니다.', '어려운 문제에서의 버티는 시간이 뚜렷해지는지 확인합니다.', '어려운 문제에서도 안정적으로 일정 시간 버티는지 확인합니다.'],
      ['틀린 뒤 "나는 못해"같은 자기비난 표현이 줄어드는지 살펴봅니다.', '자기비난 표현 감소가 뚜렷해지는지 확인합니다.', '자기비난 표현 감소가 안정적으로 유지되는지 확인합니다.'],
    ],
  },
  TYPE_B: {
    mild: [
      ['수업 후반까지 참여 에너지가 유지되는지 살펴봅니다.', '수업 후반 참여 에너지 유지가 뚜렷해지는지 확인합니다.', '수업 후반 참여 에너지가 안정적으로 유지되는지 확인합니다.'],
      ['재미없는 문제에서도 최소한의 시도 시간이 확보되는지 살펴봅니다.', '비흥미 문제에서의 최소 시도 시간 확보가 뚜렷해지는지 확인합니다.', '비흥미 문제에서의 최소 시도 시간이 안정적으로 확보되는지 확인합니다.'],
      ['실수 뒤에 바로 포기하지 않는지 살펴봅니다.', '실수 뒤 즉시 포기 감소가 뚜렷해지는지 확인합니다.', '실수 뒤 즉시 포기하지 않는 패턴이 안정적으로 나타나는지 확인합니다.'],
    ],
    strong: [
      ['수업 초반 에너지와 후반 수행 안정성이 연결되는지 살펴봅니다.', '초반 에너지와 후반 안정성의 연결이 뚜렷해지는지 확인합니다.', '초반 에너지와 후반 안정성이 안정적으로 연결되는지 확인합니다.'],
      ['"문제가 이상했어" 같은 외부 탓 표현이 줄어드는지 살펴봅니다.', '외부 탓 표현 감소가 뚜렷해지는지 확인합니다.', '외부 탓 표현 감소가 안정적으로 유지되는지 확인합니다.'],
      ['기본기 반복 연습의 밀도가 일정하게 유지되는지 살펴봅니다.', '기본기 반복 밀도의 일정함이 뚜렷해지는지 확인합니다.', '기본기 반복 밀도가 안정적으로 유지되는지 확인합니다.'],
      ['실패 뒤 감정이 급격히 떨어지는 폭이 줄어드는지 살펴봅니다.', '실패 뒤 감정 급락 폭 감소가 뚜렷해지는지 확인합니다.', '실패 뒤 감정 급락 폭 감소가 안정적으로 연결되는지 확인합니다.'],
    ],
  },
};

const GROWTH_EMPHASIS: Record<FeedbackTypeCode, string> = {
  TYPE_A: '구조적 이동이 확인됩니다. 확장이 압축과 실전으로 점차 연결되고 있는 흐름입니다.',
  TYPE_D: '점차 변화가 나타나고 있습니다. 안정에서 확장으로 이동하는 흐름이 감지됩니다.',
  TYPE_C: '아직 이동 폭은 크지 않지만, 감정 반응이 조금씩 완화되는 흐름이 나타나고 있습니다.',
  TYPE_B: '에너지가 구조로 연결되기 시작하는 흐름이 나타나고 있습니다.',
};

const GROWTH_CLOSING: Record<FeedbackTypeCode, string> = {
  TYPE_A: '체크 핵심: 확장이 점수와 압축으로 연결되고 있는지가 이 유형의 성장 관찰 기준입니다.',
  TYPE_D: '체크 핵심: 안정이 정체로 굳어지지 않고 있는지가 이 유형의 성장 관찰 기준입니다.',
  TYPE_C: '체크 핵심: 감정이 사고를 덜 방해하고 있는지가 이 유형의 성장 관찰 기준입니다.',
  TYPE_B: '체크 핵심: 에너지가 구조로 전환되고 있는지가 이 유형의 성장 관찰 기준입니다.',
};

export function buildGrowthCheckpointText(
  typeCode: FeedbackTypeCode | null,
  vectorStrength: number | null,
): string {
  if (!typeCode) return '';

  const intro = GROWTH_INTRO[typeCode] ?? '';
  const pools = GROWTH_ITEMS[typeCode];
  const emphasis = GROWTH_EMPHASIS[typeCode] ?? '';
  const closing = GROWTH_CLOSING[typeCode] ?? '';
  const intensity = getIntensityLevel(vectorStrength);

  let selected: string[][] = [];
  if (pools) {
    if (intensity === 'mild') {
      selected = pools.mild.slice(0, 3);
    } else if (intensity === 'moderate') {
      const needed = 4 - pools.mild.length;
      selected = [...pools.mild, ...pools.strong.slice(0, Math.max(needed, 1))];
    } else {
      selected = [...pools.mild, ...pools.strong];
    }
  }

  const styled = selected.map((item, i) => {
    const num = CIRCLED_NUMBERS[i] ?? `${i + 1}.`;
    return `${num} ${pickStrengthSentence(item, intensity)}`;
  });

  const gParts: string[] = [intro];
  if (styled.length > 0) {
    gParts.push(styled.join('\n'));
  }
  if (intensity === 'strong' && emphasis) {
    gParts.push(emphasis);
  }
  if (closing) {
    gParts.push(closing);
  }

  return gParts.join('\n\n');
}

/* ────────────────────────────────────────────
 * Section Summary / Color Legend / Keywords
 * 리포트 마무리 유틸
 * ──────────────────────────────────────────── */

export function getSectionSummary(
  key: FeedbackSectionKey,
  typeCode: FeedbackTypeCode | null,
  intensity: IntensityLevel,
): string {
  if (!typeCode) return '';
  switch (key) {
    case 'profile_summary': {
      const tpl = PROFILE_SUMMARY_TEMPLATES[typeCode]?.[intensity] ?? '';
      const parts = tpl.split('.').filter((s) => s.trim());
      if (parts.length === 0) return '';
      return parts.slice(0, 2).map((s) => s.trim() + '.').join('\n');
    }
    case 'learning_traits': {
      const raw = LEARNING_TRAITS_COMMON[typeCode] ?? '';
      const parts = raw.split('.').filter((s) => s.trim());
      if (parts.length === 0) return '';
      return parts.slice(0, 2).map((s) => s.trim() + '.').join('\n');
    }
    case 'strength_weakness': {
      const intro = CORE_STRENGTHS_INTRO[typeCode] ?? '';
      const closing = CORE_STRENGTHS_CLOSING[typeCode] ?? '';
      return [intro, closing].filter(Boolean).join('\n');
    }
    case 'cautions': {
      const intro = CAUTIONS_INTRO[typeCode] ?? '';
      const closing = CAUTIONS_CLOSING[typeCode] ?? '';
      return [intro, closing].filter(Boolean).join('\n');
    }
    case 'teaching_strategy': {
      const closing = STRATEGY_CLOSING[typeCode] ?? '';
      const label = TYPE_LABEL[typeCode] ?? '';
      return `${label} 유형에 맞춘 수업 환경과 과제 설계 기준을 제시합니다.\n${closing}`;
    }
    case 'growth_checkpoint': {
      const intro = GROWTH_INTRO[typeCode]?.split('.')[0]?.trim() ?? '';
      const closing = GROWTH_CLOSING[typeCode] ?? '';
      return [intro ? intro + '.' : '', closing].filter(Boolean).join('\n');
    }
    default:
      return '';
  }
}

export const FEEDBACK_COLOR_LEGEND = [
  { color: '#4ADE80', label: '매우 높음' },
  { color: '#22C55E', label: '높음' },
  { color: '#84CC16', label: '약간 높음' },
  { color: '#EAB308', label: '보통' },
  { color: '#F59E0B', label: '약간 낮음' },
  { color: '#F97316', label: '낮음' },
  { color: '#EF4444', label: '매우 낮음' },
] as const;

const TYPE_KEYWORDS: Record<FeedbackTypeCode, string[]> = {
  TYPE_A: ['구조 이해', '실전 전환', '압축 요약', '확장 과잉 주의', '성장 가속', '점수 연결'],
  TYPE_D: ['절차 정확', '꾸준함', '계단식 확장', '정체 주의', '반복 변형', '밀도 유지'],
  TYPE_C: ['감정 안정', '작은 성공', '성공 밀도', '회피 주의', '단계 분해', '시도 유지'],
  TYPE_B: ['빠른 탐색', '흥미 에너지', '구조 우선', '기복 주의', '흥미-기본기 교차', '수행 안정'],
};

export function getTypeKeywords(typeCode: FeedbackTypeCode | null): string[] {
  if (!typeCode) return [];
  return TYPE_KEYWORDS[typeCode] ?? [];
}
