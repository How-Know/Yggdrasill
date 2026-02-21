import React from 'react';
import * as XLSX from 'xlsx';
import { supabase } from '../lib/supabaseClient';
import { tokens } from '../theme';
import {
  combineSectionText,
  cloneFeedbackTemplate,
  cloneScaleGuideTemplate,
  DEFAULT_FEEDBACK_TEMPLATES,
  DEFAULT_SCALE_GUIDE_TEMPLATE,
  FEEDBACK_SECTION_DEFINITIONS,
  FEEDBACK_TYPE_CODES,
  FeedbackSectionKey,
  FeedbackTemplate,
  FeedbackTypeCode,
  INTERPRETATION_FRAME_GUIDE_QUESTIONS,
  INTERPRETATION_FRAME_GUARDRAILS,
  mergeTemplateSections,
  parseScaleGuideTemplate,
  SCALE_GUIDE_INDICATORS,
  SCALE_GUIDE_SUBSCALE_POLARITY,
  SCALE_GUIDE_SUBSCALES,
  SemanticPolarity,
  ScaleGuideIndicatorKey,
  ScaleGuideSubscaleKey,
  ScaleGuideTemplate,
  serializeScaleGuideTemplate,
} from '../lib/traitFeedbackTemplates';
import TypeLevelValidationPanel, { TypeLevelValidationSummary } from '../components/TypeLevelValidationPanel';

type Row = {
  id: string; name: string; email?: string|null; school?: string|null; grade?: string|null;
  level?: string|null; created_at?: string; client_id?: string|null;
  current_math_percentile?: number | null; current_level_grade?: number | null;
};

type ItemStat = {
  questionId: string;
  text: string;
  trait: string;
  type: string;
  roundLabel: string;
  itemN: number;
  mean: number | null;
  sd: number | null;
  min: number | null;
  max: number | null;
  avgResponseMs: number | null;
  responseMsN: number;
};

type ItemStatAcc = {
  questionId: string;
  text: string;
  trait: string;
  type: string;
  roundLabel: string;
  itemN: number;
  mean: number;
  m2: number;
  min: number | null;
  max: number | null;
  sumMs: number;
  countMs: number;
};

type ItemStatsMeta = {
  asOfDate: string;
  cumulativeParticipants: number;
  totalAnswers: number;
  avgResponseMs: number | null;
};

type SnapshotScaleStat = {
  scaleName: string;
  itemCount: number;
  mean: number | null;
  sd: number | null;
  min: number | null;
  max: number | null;
  nRespondents: number;
  alpha: number | null;
  alphaNComplete: number;
};

type SnapshotSubjectiveStat = {
  questionId: string;
  text: string;
  itemN: number;
  mean: number | null;
  sd: number | null;
  min: number | null;
  max: number | null;
};

type SnapshotMeta = {
  asOfDate: string;
  totalN: number;
  scaleCount: number;
  coreItemCount: number;
  supplementaryItemCount: number;
  totalItemCount: number;
  scaleBasis: string;
};

type AxisTypeCode = 'TYPE_A' | 'TYPE_B' | 'TYPE_C' | 'TYPE_D' | 'UNCLASSIFIED';

type SnapshotAxisPoint = {
  participantId: string;
  participantName: string;
  emotionZ: number | null;
  beliefZ: number | null;
  metacognitionZ: number | null;
  persistenceZ: number | null;
  typeCode: AxisTypeCode;
  currentLevelGrade: number | null;
  currentMathPercentile: number | null;
};

type SnapshotAxisMeta = {
  emotionScaleNames: string[];
  beliefScaleNames: string[];
  metacognitionLabels: string[];
  persistenceLabels: string[];
};

type ReportMetricValue = {
  score: number | null;
  percentile: number | null;
};

type ParticipantReportScaleProfile = {
  indicators: Record<ScaleGuideIndicatorKey, ReportMetricValue>;
  subscales: Record<ScaleGuideSubscaleKey, ReportMetricValue>;
};

type SnapshotAxisHover = {
  point: SnapshotAxisPoint;
  x: number;
  y: number;
  width: number;
  height: number;
};

type Round2LinkStatus = {
  email: string | null;
  sentAt: string | null;
  lastStatus: string | null;
  lastError: string | null;
  lastMessageId: string | null;
  expiresAt: string | null;
  updatedAt: string | null;
};

type LevelBandCode = 'ALL' | 'NO_VALUE' | 'G0' | 'G1' | 'G2' | 'G3' | 'G4' | 'G5' | 'G6';

const LEVEL_BAND_OPTIONS: Array<{ code: LevelBandCode; label: string }> = [
  { code: 'ALL', label: '전체' },
  { code: 'NO_VALUE', label: '미입력' },
  { code: 'G0', label: '0등급 (상위 1%)' },
  { code: 'G1', label: '1등급 (상위 4%)' },
  { code: 'G2', label: '2등급 (상위 11%)' },
  { code: 'G3', label: '3등급 (상위 23%)' },
  { code: 'G4', label: '4등급 (상위 40%)' },
  { code: 'G5', label: '5등급 (상위 60%)' },
  { code: 'G6', label: '6등급 (그 이하)' },
];

const PREVIEW_PEER_K = 5;
const PEER_SHRINKAGE_PRIOR = 3;
const ADJUSTMENT_AXIS_WEIGHT = 0.35;

function parseRoundNo(value: unknown): number | null {
  const raw = String(value ?? '').trim();
  if (!raw) return null;
  const m = raw.match(/\d+/);
  if (!m) return null;
  const n = Number(m[0]);
  return Number.isFinite(n) ? n : null;
}

function toNumber(value: unknown): number | null {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'string' && value.trim()) {
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

function formatNumber(value: number | null | undefined, digits = 2) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '-';
  return value.toFixed(digits);
}

function formatPercentileLabel(value: number | null | undefined): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '-';
  return `${value.toFixed(1)}백분위`;
}

function formatRoundLabel(value?: string | null) {
  return String(value ?? '').trim() || '미지정';
}

function formatTypeLabel(value?: string | null) {
  if (value === 'scale') return '척도';
  if (value === 'text') return '서술';
  return value ? value : '-';
}

function formatDateTime(value?: string) {
  if (!value) return '-';
  try {
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return '-';
    return d.toLocaleString('ko-KR', {
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
    });
  } catch {
    return '-';
  }
}

function computeSampleSd(values: number[]): number | null {
  if (!values.length) return null;
  if (values.length === 1) return 0;
  const mean = values.reduce((sum, v) => sum + v, 0) / values.length;
  const variance = values.reduce((sum, v) => sum + ((v - mean) ** 2), 0) / (values.length - 1);
  return Math.sqrt(variance);
}

function normalizePercentile(value: unknown): number | null {
  const n = toNumber(value);
  if (n == null) return null;
  if (n < 0 || n > 100) return null;
  return Math.round(n * 100) / 100;
}

function normalizeLevelGrade(value: unknown): number | null {
  const n = toNumber(value);
  if (n == null) return null;
  if (!Number.isInteger(n)) return null;
  if (n < 0 || n > 6) return null;
  return n;
}

function resolveLevelGrade(levelGrade: unknown, percentile: unknown): number | null {
  const explicit = normalizeLevelGrade(levelGrade);
  if (explicit != null) return explicit;
  const pct = normalizePercentile(percentile);
  if (pct == null) return null;
  return percentileToLevelGrade(pct);
}

function computeVectorStrengthPercent(emotionZ: number | null, beliefZ: number | null): number | null {
  if (emotionZ == null || beliefZ == null) return null;
  if (!Number.isFinite(emotionZ) || !Number.isFinite(beliefZ)) return null;
  const magnitude = Math.sqrt((emotionZ ** 2) + (beliefZ ** 2));
  const maxMagnitude = Math.sqrt((3 ** 2) + (3 ** 2));
  return Math.max(0, Math.min(100, (magnitude / maxMagnitude) * 100));
}

function formatPercentileInputValue(value: number | null): string {
  if (value == null) return '';
  return Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/\.?0+$/, '');
}

function percentileToLevelGrade(percentile: number): number {
  if (percentile <= 1) return 0;
  if (percentile <= 4) return 1;
  if (percentile <= 11) return 2;
  if (percentile <= 23) return 3;
  if (percentile <= 40) return 4;
  if (percentile <= 60) return 5;
  return 6;
}

function percentileToBandCode(percentile: number | null): Exclude<LevelBandCode, 'ALL'> {
  if (percentile == null) return 'NO_VALUE';
  const grade = percentileToLevelGrade(percentile);
  return (`G${grade}` as Exclude<LevelBandCode, 'ALL'>);
}

function deriveParticipantBandCode(levelGrade: unknown, percentile: unknown): Exclude<LevelBandCode, 'ALL'> {
  const normalizedGrade = normalizeLevelGrade(levelGrade);
  if (normalizedGrade != null) {
    return `G${normalizedGrade}` as Exclude<LevelBandCode, 'ALL'>;
  }
  return percentileToBandCode(normalizePercentile(percentile));
}

function matchesLevelBand(levelGrade: unknown, percentile: unknown, code: LevelBandCode): boolean {
  if (code === 'ALL') return true;
  return deriveParticipantBandCode(levelGrade, percentile) === code;
}

function bandCodeToLevelGrade(code: Exclude<LevelBandCode, 'ALL'>): number | null {
  if (code === 'NO_VALUE') return null;
  return Number(code.slice(1));
}

function getLevelBandLabel(code: LevelBandCode): string {
  return LEVEL_BAND_OPTIONS.find((x) => x.code === code)?.label ?? code;
}

function formatCurrentLevelDisplay(levelGrade: unknown, percentile: unknown): string {
  const code = deriveParticipantBandCode(levelGrade, percentile);
  if (code === 'NO_VALUE') return '미입력';
  const label = getLevelBandLabel(code);

  // 기존 percentile-only 데이터는 추정치임을 노출해 혼동을 줄인다.
  const hasExplicitGrade = normalizeLevelGrade(levelGrade) != null;
  if (hasExplicitGrade) return label;

  const pct = normalizePercentile(percentile);
  if (pct == null) return label;
  return `${label} (상위 ${formatPercentileInputValue(pct)}% 추정)`;
}

const AXIS_TYPE_COLOR_MAP: Record<AxisTypeCode, string> = {
  TYPE_A: '#4CAF50',
  TYPE_B: '#FF9800',
  TYPE_C: '#EF5350',
  TYPE_D: '#42A5F5',
  UNCLASSIFIED: '#9E9E9E',
};

function axisTypeLabel(typeCode: AxisTypeCode): string {
  if (typeCode === 'TYPE_A') return '확장형';
  if (typeCode === 'TYPE_B') return '동기형';
  if (typeCode === 'TYPE_C') return '회복형';
  if (typeCode === 'TYPE_D') return '안정형';
  return '미분류';
}

function toFeedbackTypeCode(typeCode: AxisTypeCode): FeedbackTypeCode | null {
  if (typeCode === 'UNCLASSIFIED') return null;
  return typeCode;
}

function parseTagList(raw: unknown): string[] {
  if (Array.isArray(raw)) {
    return raw.map((v) => String(v).trim()).filter(Boolean);
  }
  const text = String(raw ?? '').trim();
  if (!text) return [];
  return text.split(',').map((v) => v.trim()).filter(Boolean);
}

function tagLeafLabel(path: string): string {
  const parts = path.split('>').map((v) => v.trim()).filter(Boolean);
  return parts.length ? parts[parts.length - 1] : path.trim();
}

function normalizeAxisSourceText(value: string): string {
  return value.toLowerCase().replace(/\s+/g, '').replace(/[_-]/g, '');
}

function buildQuestionCandidates(tagsRaw: unknown, traitRaw: unknown, textRaw: unknown): string[] {
  const tags = parseTagList(tagsRaw);
  const candidates: string[] = [];
  tags.forEach((tag) => {
    candidates.push(tag);
    candidates.push(tagLeafLabel(tag));
  });
  if (!candidates.length) {
    candidates.push(String(traitRaw ?? ''));
    candidates.push(String(textRaw ?? ''));
  }
  return candidates;
}

function classifyLearningAdjustmentFromQuestion(
  tagsRaw: unknown,
  traitRaw: unknown,
  textRaw: unknown,
  questionTypeRaw: unknown,
): 'metacognition' | 'persistence' | null {
  const candidates = buildQuestionCandidates(tagsRaw, traitRaw, textRaw);
  const questionType = String(questionTypeRaw ?? '').trim().toLowerCase();
  let metacognitionScore = 0;
  let persistenceScore = 0;
  candidates.forEach((raw) => {
    const key = normalizeAxisSourceText(raw);
    if (!key) return;
    if (/(메타인지|자기점검|자기조절|자기모니터|계획점검|전략점검|학습전략|모니터링|metacog|selfmonitor|selfregulat|reflection|strategy|monitor)/.test(key)) {
      metacognitionScore += 1;
    }
    if (/(문제지속|지속성|지속|끈기|포기|끝까지|버티|꾸준|재도전|persist|grit|tenacit|retry|giveup|quit)/.test(key)) {
      persistenceScore += 1;
    }
  });

  if (questionType === 'text') {
    if (metacognitionScore > persistenceScore && metacognitionScore > 0) return 'metacognition';
    if (persistenceScore > 0) return 'persistence';
    // 보조문항(text)은 기본적으로 문제지속성 지표로 취급
    return 'persistence';
  }

  if (metacognitionScore <= 0 && persistenceScore <= 0) return null;
  if (metacognitionScore >= persistenceScore) return 'metacognition';
  return 'persistence';
}

function shouldInvertLearningAdjustment(
  role: 'metacognition' | 'persistence',
  tagsRaw: unknown,
  traitRaw: unknown,
  textRaw: unknown,
): boolean {
  const candidates = buildQuestionCandidates(tagsRaw, traitRaw, textRaw);
  if (role === 'persistence') {
    return candidates.some((raw) => {
      const key = normalizeAxisSourceText(raw);
      if (!key) return false;
      return /(포기|회피|중단|그만|avoid|giveup|quit|drop)/.test(key);
    });
  }
  return false;
}

const SUBSCALE_CLASSIFIERS: Array<{ key: ScaleGuideSubscaleKey; pattern: RegExp }> = [
  { key: 'interest', pattern: /(흥미|재미|관심|호기심|몰입|interest|enjoy|engage)/ },
  { key: 'emotion_reactivity', pattern: /(정서반응|반응성|불안|긴장|위협|stress|anxiety|reactiv|fear|frustrat)/ },
  { key: 'math_mindset', pattern: /(수학능력관|능력관|성장신념|고정신념|mindset|growthmindset|entity|incremental)/ },
  { key: 'effort_outcome_belief', pattern: /(노력성과|노력-성과|노력결과|effort|outcome|성과연결)/ },
  { key: 'external_attribution_belief', pattern: /(외적귀인|외부귀인|귀인|운|난이도|환경|externalattribution|luck|environment)/ },
  { key: 'self_concept', pattern: /(자기개념|selfconcept|유능감|자기평가)/ },
  { key: 'identity', pattern: /(정체성|identity|나와맞|나랑맞|수학은나)/ },
  { key: 'agency_perception', pattern: /(주도성|주체성|통제가능|통제감|agency|ownership|selfdirect|control)/ },
  { key: 'question_understanding_belief', pattern: /(질문|이해신념|질문이해|ask|question|understand|clarify)/ },
  { key: 'recovery_expectancy_belief', pattern: /(회복기대|회복|다시좋아|recover|bounceback|resilien)/ },
  { key: 'failure_interpretation_belief', pattern: /(실패해석|실패의미|오답해석|틀렸|failureinterpret|errorbelief)/ },
  { key: 'metacognition', pattern: /(메타인지|자기점검|자기모니터|자기조절|전략점검|반성|metacog|selfmonitor|selfregulat|reflection|monitor)/ },
  { key: 'persistence', pattern: /(문제지속|지속성|끈기|버티|포기|재도전|persist|grit|tenacit|retry|giveup|quit)/ },
];

const INDICATOR_SUBSCALE_KEYS: Record<ScaleGuideIndicatorKey, ScaleGuideSubscaleKey[]> = {
  emotion: ['interest', 'emotion_reactivity'],
  belief: [
    'math_mindset',
    'effort_outcome_belief',
    'external_attribution_belief',
    'self_concept',
    'identity',
    'agency_perception',
    'question_understanding_belief',
    'recovery_expectancy_belief',
    'failure_interpretation_belief',
  ],
  learning_style: ['metacognition', 'persistence'],
};

type AxisRole = 'emotion_pos' | 'emotion_neg' | 'belief_pos' | 'belief_neg';

function isReverseItem(value: unknown): boolean {
  return String(value ?? '').trim().toUpperCase() === 'Y';
}

function axisRoleFromSubscale(subscale: ScaleGuideSubscaleKey | null): AxisRole | null {
  if (!subscale) return null;
  if (subscale === 'interest') return 'emotion_pos';
  if (subscale === 'emotion_reactivity') return 'emotion_neg';
  if (subscale === 'external_attribution_belief') return 'belief_neg';
  if (subscale === 'metacognition' || subscale === 'persistence') return null;
  return 'belief_pos';
}

function semanticSignForPolarityWithReverse(
  polarity: SemanticPolarity,
  reverseRaw: unknown,
): 1 | -1 {
  if (polarity === 1) return 1;
  return isReverseItem(reverseRaw) ? 1 : -1;
}

function axisContributionSign(axisRole: AxisRole, reverseRaw: unknown): 1 | -1 {
  if (axisRole === 'emotion_pos' || axisRole === 'belief_pos') return 1;
  return semanticSignForPolarityWithReverse(-1, reverseRaw);
}

function orientedDisplayScoreForSubscale(
  scoreRc: number,
  subscaleKey: ScaleGuideSubscaleKey,
  reverseRaw: unknown,
  minScoreRaw: unknown,
  maxScoreRaw: unknown,
): number {
  const polarity = SCALE_GUIDE_SUBSCALE_POLARITY[subscaleKey];
  if (polarity === 1) return scoreRc;
  if (isReverseItem(reverseRaw)) return scoreRc;
  const minScore = toNumber(minScoreRaw);
  const maxScore = toNumber(maxScoreRaw);
  if (minScore == null || maxScore == null || !Number.isFinite(minScore + maxScore)) {
    return scoreRc;
  }
  return (minScore + maxScore) - scoreRc;
}

function classifySubscaleFromQuestion(
  tagsRaw: unknown,
  traitRaw: unknown,
  textRaw: unknown,
  questionTypeRaw: unknown,
): ScaleGuideSubscaleKey | null {
  const candidates = buildQuestionCandidates(tagsRaw, traitRaw, textRaw);
  const questionType = String(questionTypeRaw ?? '').trim().toLowerCase();
  const scores: Record<ScaleGuideSubscaleKey, number> = {
    interest: 0,
    emotion_reactivity: 0,
    math_mindset: 0,
    effort_outcome_belief: 0,
    external_attribution_belief: 0,
    self_concept: 0,
    identity: 0,
    agency_perception: 0,
    question_understanding_belief: 0,
    recovery_expectancy_belief: 0,
    failure_interpretation_belief: 0,
    metacognition: 0,
    persistence: 0,
  };
  candidates.forEach((raw) => {
    const key = normalizeAxisSourceText(raw);
    if (!key) return;
    SUBSCALE_CLASSIFIERS.forEach((entry) => {
      if (entry.pattern.test(key)) {
        scores[entry.key] += 1;
      }
    });
  });

  if (questionType === 'text') {
    if (scores.metacognition > scores.persistence && scores.metacognition > 0) return 'metacognition';
    return 'persistence';
  }

  let best: ScaleGuideSubscaleKey | null = null;
  let bestScore = 0;
  (Object.entries(scores) as Array<[ScaleGuideSubscaleKey, number]>).forEach(([key, value]) => {
    if (value > bestScore) {
      best = key;
      bestScore = value;
    }
  });
  return bestScore > 0 ? best : null;
}

function classifyAxisFromQuestion(
  tagsRaw: unknown,
  traitRaw: unknown,
  textRaw: unknown,
): AxisRole | null {
  const subscaleKey = classifySubscaleFromQuestion(tagsRaw, traitRaw, textRaw, 'scale');
  const axisFromSubscale = axisRoleFromSubscale(subscaleKey);
  if (axisFromSubscale) return axisFromSubscale;

  const candidates = buildQuestionCandidates(tagsRaw, traitRaw, textRaw);

  let beliefPosScore = 0;
  let beliefNegScore = 0;
  let emotionPosScore = 0;
  let emotionNegScore = 0;
  let metacognitionScore = 0;
  let persistenceScore = 0;

  candidates.forEach((raw) => {
    const key = normalizeAxisSourceText(raw);
    if (!key) return;
    if (/(메타인지|자기점검|자기조절|자기모니터|계획점검|전략점검|학습전략|모니터링|metacog|selfmonitor|selfregulat|reflection|strategy|monitor)/.test(key)) {
      metacognitionScore += 1;
    }
    if (/(문제지속|지속성|지속|끈기|포기|끝까지|버티|꾸준|재도전|persist|grit|tenacit|retry|giveup|quit)/.test(key)) {
      persistenceScore += 1;
    }
    if (/(외적귀인|외부귀인|귀인|운|난이도|환경|externalattribution|luck|environment)/.test(key)) {
      beliefNegScore += 1;
    }
    if (/(신념|효능|자기효능|성장신념|능력관|통제가능성|통제|노력성과|주도성|실패해석|회복기대|belief|efficacy|growth|mindset|control|attribution|resilien)/.test(key)) {
      beliefPosScore += 1;
    }
    if (/(흥미|몰입|재미|호기심|정서안정|안정성|즐거움|자신감|interest|engage|enjoy|stability|confidence)/.test(key)) {
      emotionPosScore += 1;
    }
    if (/(불안|긴장|위협|정서반응성|정서반응|반응성|스트레스|좌절|기질적불안민감성|anxiety|stress|threat|reactiv|frustrat|fear)/.test(key)) {
      emotionNegScore += 1;
    }
  });

  // 메타인지/문제지속성 문항은 유형 축(감정/신념)에서 제외하고 보정 변수로 사용
  if (metacognitionScore > 0 || persistenceScore > 0) return null;

  const maxScore = Math.max(beliefPosScore, beliefNegScore, emotionPosScore, emotionNegScore);
  if (maxScore <= 0) return null;
  if (beliefNegScore === maxScore) return 'belief_neg';
  if (beliefPosScore === maxScore) return 'belief_pos';
  if (emotionNegScore === maxScore) return 'emotion_neg';
  return 'emotion_pos';
}

function computeMean(values: number[]): number | null {
  if (!values.length) return null;
  return values.reduce((sum, v) => sum + v, 0) / values.length;
}

function computePercentileRank(values: number[], target: number | null): number | null {
  if (target == null || !Number.isFinite(target) || !values.length) return null;
  const epsilon = 1e-9;
  const less = values.filter((v) => v < (target - epsilon)).length;
  const equal = values.filter((v) => Math.abs(v - target) <= epsilon).length;
  const rank = (less + (equal * 0.5)) / values.length;
  return Math.max(0, Math.min(100, Math.round(rank * 10000) / 100));
}

function emptyMetricValue(): ReportMetricValue {
  return { score: null, percentile: null };
}

function buildEmptyReportScaleProfile(): ParticipantReportScaleProfile {
  return {
    indicators: {
      emotion: emptyMetricValue(),
      belief: emptyMetricValue(),
      learning_style: emptyMetricValue(),
    },
    subscales: {
      interest: emptyMetricValue(),
      emotion_reactivity: emptyMetricValue(),
      math_mindset: emptyMetricValue(),
      effort_outcome_belief: emptyMetricValue(),
      external_attribution_belief: emptyMetricValue(),
      self_concept: emptyMetricValue(),
      identity: emptyMetricValue(),
      agency_perception: emptyMetricValue(),
      question_understanding_belief: emptyMetricValue(),
      recovery_expectancy_belief: emptyMetricValue(),
      failure_interpretation_belief: emptyMetricValue(),
      metacognition: emptyMetricValue(),
      persistence: emptyMetricValue(),
    },
  };
}

function classifyEmotionBeliefType(emotionZ: number | null, beliefZ: number | null): AxisTypeCode {
  if (emotionZ == null || beliefZ == null) return 'UNCLASSIFIED';
  if (emotionZ >= 0 && beliefZ >= 0) return 'TYPE_A';
  if (emotionZ >= 0 && beliefZ < 0) return 'TYPE_B';
  if (emotionZ < 0 && beliefZ < 0) return 'TYPE_C';
  return 'TYPE_D';
}

function zToDisplayPercent(value: number | null): number | null {
  if (value == null || !Number.isFinite(value)) return null;
  const clamped = Math.max(-2.5, Math.min(2.5, value));
  return ((clamped + 2.5) / 5) * 100;
}

function adjustmentLevelLabel(value: number | null): '높음' | '중간' | '낮음' | '미측정' {
  if (value == null || !Number.isFinite(value)) return '미측정';
  if (value >= 0.5) return '높음';
  if (value <= -0.5) return '낮음';
  return '중간';
}

function buildDefaultTemplateMap(): Record<FeedbackTypeCode, FeedbackTemplate> {
  return {
    TYPE_A: cloneFeedbackTemplate(DEFAULT_FEEDBACK_TEMPLATES.TYPE_A),
    TYPE_B: cloneFeedbackTemplate(DEFAULT_FEEDBACK_TEMPLATES.TYPE_B),
    TYPE_C: cloneFeedbackTemplate(DEFAULT_FEEDBACK_TEMPLATES.TYPE_C),
    TYPE_D: cloneFeedbackTemplate(DEFAULT_FEEDBACK_TEMPLATES.TYPE_D),
  };
}

export default function ResultsPage() {
  const [activeTab, setActiveTab] = React.useState<'status' | 'result' | 'report'>('status');
  const [rows, setRows] = React.useState<Row[]>([]);
  const [selected, setSelected] = React.useState<Row | null>(null);
  const [answers, setAnswers] = React.useState<any[]>([]);
  const [traitSumByParticipant, setTraitSumByParticipant] = React.useState<Record<string, Record<string, number>>>({});
  const [fastStatsByParticipant, setFastStatsByParticipant] = React.useState<Record<string, { fast: number; total: number; avgMs: number | null }>>({});
  const [roundOrderMap, setRoundOrderMap] = React.useState<Record<string, number>>({});
  const [roundTotals, setRoundTotals] = React.useState<Record<number, number>>({});
  const [roundMeta, setRoundMeta] = React.useState<{ no: number; label: string }[]>([]);
  const [progressByParticipant, setProgressByParticipant] = React.useState<Record<string, Record<number, number>>>({});
  const [itemStats, setItemStats] = React.useState<ItemStat[]>([]);
  const [itemStatsMeta, setItemStatsMeta] = React.useState<ItemStatsMeta | null>(null);
  const [itemStatsLoading, setItemStatsLoading] = React.useState(false);
  const [itemStatsError, setItemStatsError] = React.useState<string | null>(null);
  const [filterText, setFilterText] = React.useState('');
  const [filterTrait, setFilterTrait] = React.useState('ALL');
  const [filterType, setFilterType] = React.useState('ALL');
  const [filterRound, setFilterRound] = React.useState('ALL');
  const [filterLevelBand, setFilterLevelBand] = React.useState<LevelBandCode>('ALL');
  const [round2LinksByParticipant, setRound2LinksByParticipant] = React.useState<Record<string, Round2LinkStatus>>({});
  const [savingLevelById, setSavingLevelById] = React.useState<Record<string, boolean>>({});
  const [levelErrorById, setLevelErrorById] = React.useState<Record<string, string | null>>({});
  const [snapshotScaleStats, setSnapshotScaleStats] = React.useState<SnapshotScaleStat[]>([]);
  const [snapshotSubjectiveStats, setSnapshotSubjectiveStats] = React.useState<SnapshotSubjectiveStat[]>([]);
  const [snapshotMeta, setSnapshotMeta] = React.useState<SnapshotMeta | null>(null);
  const [snapshotAxisPoints, setSnapshotAxisPoints] = React.useState<SnapshotAxisPoint[]>([]);
  const [reportScaleProfilesByParticipant, setReportScaleProfilesByParticipant] = React.useState<Record<string, ParticipantReportScaleProfile>>({});
  const [snapshotAxisMeta, setSnapshotAxisMeta] = React.useState<SnapshotAxisMeta>({
    emotionScaleNames: [],
    beliefScaleNames: [],
    metacognitionLabels: [],
    persistenceLabels: [],
  });
  const [snapshotAxisHover, setSnapshotAxisHover] = React.useState<SnapshotAxisHover | null>(null);
  const [snapshotLoading, setSnapshotLoading] = React.useState(false);
  const [snapshotError, setSnapshotError] = React.useState<string | null>(null);
  const [typeLevelSummary, setTypeLevelSummary] = React.useState<TypeLevelValidationSummary | null>(null);
  const [typeLevelSummaryFileName, setTypeLevelSummaryFileName] = React.useState<string | null>(null);
  const [typeLevelSummaryError, setTypeLevelSummaryError] = React.useState<string | null>(null);
  const [reportSearchKeyword, setReportSearchKeyword] = React.useState('');
  const [selectedReportParticipantId, setSelectedReportParticipantId] = React.useState<string | null>(null);
  const [feedbackTemplates, setFeedbackTemplates] = React.useState<Record<FeedbackTypeCode, FeedbackTemplate>>(
    () => buildDefaultTemplateMap(),
  );
  const [editingTemplateType, setEditingTemplateType] = React.useState<FeedbackTypeCode>('TYPE_A');
  const [templateLoading, setTemplateLoading] = React.useState(false);
  const [templateSaving, setTemplateSaving] = React.useState(false);
  const [templateError, setTemplateError] = React.useState<string | null>(null);
  const [templateScaleDescription, setTemplateScaleDescription] = React.useState('');
  const [templateScaleGuide, setTemplateScaleGuide] = React.useState<ScaleGuideTemplate>(
    () => cloneScaleGuideTemplate(DEFAULT_SCALE_GUIDE_TEMPLATE),
  );
  const [templateScaleDescriptionAvailable, setTemplateScaleDescriptionAvailable] = React.useState(true);
  const [templateCommonDirty, setTemplateCommonDirty] = React.useState(false);
  const [templateDirty, setTemplateDirty] = React.useState<Record<FeedbackTypeCode, boolean>>({
    TYPE_A: false,
    TYPE_B: false,
    TYPE_C: false,
    TYPE_D: false,
  });

  React.useEffect(() => {
    (async () => {
      const { data } = await supabase
        .from('survey_participants')
        .select('id, name, email, school, grade, level, created_at, client_id, current_math_percentile, current_level_grade')
        .order('created_at', { ascending: false });
      setRows((data as any[]) || []);
    })();
  }, []);

  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      if (!rows.length) {
        if (!cancelled) setRound2LinksByParticipant({});
        return;
      }
      const ids = rows.map((r) => r.id).filter(Boolean);
      if (!ids.length) {
        if (!cancelled) setRound2LinksByParticipant({});
        return;
      }
      const { data, error } = await supabase
        .from('trait_round2_links')
        .select('participant_id, email, sent_at, last_send_status, last_send_error, last_message_id, expires_at, updated_at')
        .in('participant_id', ids);
      if (cancelled) return;
      if (error) {
        console.error('[trait_round2_links]', error);
        return;
      }
      const map: Record<string, Round2LinkStatus> = {};
      (data as any[] || []).forEach((row) => {
        const pid = String(row?.participant_id ?? '').trim();
        if (!pid) return;
        map[pid] = {
          email: row?.email ?? null,
          sentAt: row?.sent_at ?? null,
          lastStatus: row?.last_send_status ?? null,
          lastError: row?.last_send_error ?? null,
          lastMessageId: row?.last_message_id ?? null,
          expiresAt: row?.expires_at ?? null,
          updatedAt: row?.updated_at ?? null,
        };
      });
      setRound2LinksByParticipant(map);
    })();
    return () => { cancelled = true; };
  }, [rows]);

  React.useEffect(() => {
    (async () => {
      const roundOrder: Record<string, number> = {};
      const roundLabelByNo: Record<number, string> = {};
      try {
        const { data: roundData } = await supabase.rpc('list_trait_rounds_public');
        if (Array.isArray(roundData)) {
          const sorted = [...roundData].sort((a: any, b: any) => (a.order_index ?? 0) - (b.order_index ?? 0));
          sorted.forEach((r: any, idx: number) => {
            const name = String(r?.name ?? '').trim();
            if (!name) return;
            const no = idx + 1;
            roundOrder[name] = no;
            roundLabelByNo[no] = name;
          });
        }
      } catch {}
      const { data: qData } = await supabase
        .from('questions')
        .select('id, round_label')
        .eq('is_active', true)
        .order('created_at', { ascending: true });
      const totals: Record<number, number> = {};
      const map: Record<string, number> = {};
      (qData as any[] || []).forEach((q) => {
        const label = String(q?.round_label ?? '').trim();
        const roundNo = roundOrder[label] ?? parseRoundNo(label) ?? 1;
        map[String(q.id)] = roundNo;
        totals[roundNo] = (totals[roundNo] ?? 0) + 1;
        if (!roundLabelByNo[roundNo] && label) roundLabelByNo[roundNo] = label;
      });
      const roundNos = Object.keys(totals).map(Number).sort((a, b) => a - b);
      const meta = roundNos.map((no) => ({ no, label: roundLabelByNo[no] ?? `${no}회차` }));
      setRoundOrderMap(roundOrder);
      setRoundTotals(totals);
      setRoundMeta(meta);
    })();
  }, []);

  React.useEffect(() => {
    (async () => {
      const { data } = await supabase
        .from('question_answers')
        .select('answer_number, response_ms, is_fast, question_id, question:questions(trait,type,min_score,max_score,reverse,weight,round_label), response:question_responses(participant_id)');
      const map: Record<string, Record<string, number>> = {};
      const fastMap: Record<string, { fast: number; total: number; sumMs: number; countMs: number }> = {};
      const progressMap: Record<string, Record<number, number>> = {};
      (data as any[] || []).forEach((row) => {
        const pid = row.response?.participant_id as string | undefined;
        const q = row.question as any;
        if (!pid || !q) return;

        // ✅ 진행률은 문항 타입과 무관하게 "응답 존재" 기준으로 집계
        const roundLabel = String(q.round_label ?? '').trim();
        const roundNo = roundOrderMap[roundLabel] ?? parseRoundNo(roundLabel) ?? 1;
        if (!progressMap[pid]) progressMap[pid] = {};
        progressMap[pid][roundNo] = (progressMap[pid][roundNo] ?? 0) + 1;

        // ✅ 점수/빠름 통계는 scale 문항만 집계
        const valRaw = row.answer_number as number | null;
        if (q.type !== 'scale' || typeof valRaw !== 'number') return;
        const trait = q.trait as string;
        const min = (q.min_score ?? 1) as number;
        const max = (q.max_score ?? 10) as number;
        const weight = Number(q.weight ?? 1);
        let val = valRaw;
        if (q.reverse === 'Y') val = (min + max) - val;
        const adj = val * weight;
        if (!map[pid]) map[pid] = {};
        map[pid][trait] = (map[pid][trait] ?? 0) + adj;

        if (!fastMap[pid]) fastMap[pid] = { fast: 0, total: 0, sumMs: 0, countMs: 0 };
        const isFast = row.is_fast === true;
        if (isFast) fastMap[pid].fast += 1;
        fastMap[pid].total += 1;
        if (typeof row.response_ms === 'number') {
          fastMap[pid].sumMs += row.response_ms;
          fastMap[pid].countMs += 1;
        }
      });
      setTraitSumByParticipant(map);
      const out: Record<string, { fast: number; total: number; avgMs: number | null }> = {};
      Object.entries(fastMap).forEach(([pid, stats]) => {
        out[pid] = {
          fast: stats.fast,
          total: stats.total,
          avgMs: stats.countMs ? (stats.sumMs / stats.countMs) : null,
        };
      });
      setFastStatsByParticipant(out);
      setProgressByParticipant(progressMap);
    })();
  }, [roundOrderMap]);

  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      setItemStatsLoading(true);
      setItemStatsError(null);
      try {
        const [answersRes, questionsRes, participantsRes] = await Promise.all([
          supabase
            .from('question_answers')
            .select('answer_number, answer_text, response_ms, question_id, response:question_responses(participant_id), question:questions(id, text, trait, type, round_label, is_active)'),
          supabase
            .from('questions')
            .select('id, text, trait, type, round_label, is_active'),
          supabase
            .from('survey_participants')
            .select('id, current_math_percentile, current_level_grade'),
        ]);

        if (answersRes.error) throw answersRes.error;
        if (questionsRes.error) throw questionsRes.error;
        if (participantsRes.error) throw participantsRes.error;

        const asOfDate = new Date().toISOString();
        const statsMap: Record<string, ItemStatAcc> = {};
        const participantSet = new Set<string>();
        const validParticipantSet = new Set(
          (participantsRes.data as any[] || [])
            .map((p) => ({
              id: String(p?.id ?? '').trim(),
              levelGrade: normalizeLevelGrade(p?.current_level_grade),
              percentile: normalizePercentile(p?.current_math_percentile),
            }))
            .filter((p) => Boolean(p.id) && matchesLevelBand(p.levelGrade, p.percentile, filterLevelBand))
            .map((p) => p.id),
        );
        let totalAnswers = 0;
        let totalMs = 0;
        let totalMsCount = 0;

        (questionsRes.data as any[] || []).forEach((q) => {
          const id = String(q?.id ?? '').trim();
          if (!id) return;
          statsMap[id] = {
            questionId: id,
            text: String(q?.text ?? ''),
            trait: String(q?.trait ?? ''),
            type: String(q?.type ?? ''),
            roundLabel: formatRoundLabel(q?.round_label),
            itemN: 0,
            mean: 0,
            m2: 0,
            min: null,
            max: null,
            sumMs: 0,
            countMs: 0,
          };
        });

        (answersRes.data as any[] || []).forEach((row) => {
          const pid = row.response?.participant_id as string | undefined;
          if (!pid || !validParticipantSet.has(pid)) return;
          participantSet.add(pid);
          totalAnswers += 1;

          const q = row.question as any;
          const qid = String(q?.id ?? row.question_id ?? '').trim();
          if (!qid) return;

          if (!statsMap[qid]) {
            statsMap[qid] = {
              questionId: qid,
              text: String(q?.text ?? ''),
              trait: String(q?.trait ?? ''),
              type: String(q?.type ?? ''),
              roundLabel: formatRoundLabel(q?.round_label),
              itemN: 0,
              mean: 0,
              m2: 0,
              min: null,
              max: null,
              sumMs: 0,
              countMs: 0,
            };
          } else {
            if (!statsMap[qid].text && q?.text) statsMap[qid].text = String(q.text);
            if (!statsMap[qid].trait && q?.trait) statsMap[qid].trait = String(q.trait);
            if (!statsMap[qid].type && q?.type) statsMap[qid].type = String(q.type);
            if (q?.round_label) statsMap[qid].roundLabel = formatRoundLabel(q.round_label);
          }

          const entry = statsMap[qid];
          const val = toNumber(row.answer_number ?? row.answer_text);
          if (val != null) {
            entry.itemN += 1;
            const delta = val - entry.mean;
            entry.mean += delta / entry.itemN;
            const delta2 = val - entry.mean;
            entry.m2 += delta * delta2;
            entry.min = entry.min == null ? val : Math.min(entry.min, val);
            entry.max = entry.max == null ? val : Math.max(entry.max, val);
          }

          const ms = toNumber(row.response_ms);
          if (ms != null) {
            entry.sumMs += ms;
            entry.countMs += 1;
            totalMs += ms;
            totalMsCount += 1;
          }
        });

        const stats: ItemStat[] = Object.values(statsMap).map((entry) => {
          const sd = entry.itemN > 1 ? Math.sqrt(entry.m2 / (entry.itemN - 1)) : entry.itemN === 1 ? 0 : null;
          return {
            questionId: entry.questionId,
            text: entry.text || '(내용 없음)',
            trait: entry.trait || '-',
            type: entry.type || '-',
            roundLabel: entry.roundLabel,
            itemN: entry.itemN,
            mean: entry.itemN ? entry.mean : null,
            sd,
            min: entry.itemN ? entry.min : null,
            max: entry.itemN ? entry.max : null,
            avgResponseMs: entry.countMs ? entry.sumMs / entry.countMs : null,
            responseMsN: entry.countMs,
          };
        });

        if (!cancelled) {
          setItemStats(stats);
          setItemStatsMeta({
            asOfDate,
            cumulativeParticipants: participantSet.size,
            totalAnswers,
            avgResponseMs: totalMsCount ? totalMs / totalMsCount : null,
          });
        }
      } catch (error) {
        if (!cancelled) {
          setItemStatsError((error as any)?.message ?? 'Item_Stats 계산 실패');
        }
      } finally {
        if (!cancelled) setItemStatsLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [filterLevelBand, rows]);

  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      setSnapshotLoading(true);
      setSnapshotError(null);
      try {
        const [answersRes, questionsRes, participantsRes] = await Promise.all([
          supabase
            .from('question_answers')
            .select('answer_number, answer_text, question_id, response:question_responses(participant_id), question:questions(id, text, trait, tags, type, round_label, min_score, max_score, reverse, is_active)'),
          supabase
            .from('questions')
            .select('id, text, trait, tags, type, round_label, min_score, max_score, reverse, is_active')
            .eq('is_active', true),
          supabase
            .from('survey_participants')
            .select('id, name, current_level_grade, current_math_percentile'),
        ]);

        if (answersRes.error) throw answersRes.error;
        if (questionsRes.error) throw questionsRes.error;
        if (participantsRes.error) throw participantsRes.error;

        const validParticipantSet = new Set(
          (participantsRes.data as any[] || [])
            .map((p) => String(p?.id ?? '').trim())
            .filter(Boolean),
        );
        const participantMetaById: Record<string, { name: string; levelGrade: number | null; percentile: number | null }> = {};
        (participantsRes.data as any[] || []).forEach((p) => {
          const pid = String(p?.id ?? '').trim();
          if (!pid) return;
          participantMetaById[pid] = {
            name: String(p?.name ?? '').trim() || pid,
            levelGrade: normalizeLevelGrade(p?.current_level_grade),
            percentile: normalizePercentile(p?.current_math_percentile),
          };
        });

        const scaleItemSetMap: Record<string, Set<string>> = {};
        const supplementaryQuestionMap: Record<string, string> = {};
        const questionMetaById: Record<string, {
          text: string;
          trait: string;
          tags: string[];
          type: string;
          reverse: string;
          minScore: number | null;
          maxScore: number | null;
        }> = {};
        (questionsRes.data as any[] || []).forEach((q) => {
          const qid = String(q?.id ?? '').trim();
          if (!qid) return;
          const roundLabel = String(q?.round_label ?? '').trim();
          const roundNo = roundOrderMap[roundLabel] ?? parseRoundNo(roundLabel) ?? 1;
          if (roundNo !== 1) return;
          const qText = String(q?.text ?? '').trim();
          const qTrait = String(q?.trait ?? '').trim();
          const qTags = parseTagList(q?.tags);
          const qType = String(q?.type ?? '').trim();
          questionMetaById[qid] = {
            text: qText,
            trait: qTrait,
            tags: qTags,
            type: qType,
            reverse: String(q?.reverse ?? 'N').toUpperCase(),
            minScore: toNumber(q?.min_score),
            maxScore: toNumber(q?.max_score),
          };
          if (qType === 'scale') {
            const scaleName = qTrait || '미분류';
            if (!scaleItemSetMap[scaleName]) scaleItemSetMap[scaleName] = new Set<string>();
            scaleItemSetMap[scaleName].add(qid);
          } else if (qType === 'text') {
            supplementaryQuestionMap[qid] = qText || `(문항 ${qid})`;
          }
        });

        const coreScoreMap: Record<string, Record<string, Record<string, number>>> = {};
        const supplementaryValuesMap: Record<string, number[]> = {};
        const typeAxisQuestionScoreMap: Record<string, Record<string, number>> = {};
        const allQuestionScoreMap: Record<string, Record<string, number>> = {};
        const participantSet = new Set<string>();
        (answersRes.data as any[] || []).forEach((row) => {
          const pid = String(row?.response?.participant_id ?? '').trim();
          if (!pid || !validParticipantSet.has(pid)) return;
          const q = row?.question as any;
          const qid = String(q?.id ?? row?.question_id ?? '').trim();
          if (!qid) return;

          const roundLabel = String(q?.round_label ?? '').trim();
          const roundNo = roundOrderMap[roundLabel] ?? parseRoundNo(roundLabel) ?? 1;
          if (roundNo !== 1) return;

          const qType = String(q?.type ?? '').trim();
          if (qType === 'scale') {
            const raw = toNumber(row?.answer_number);
            if (raw == null) return;
            const minScore = toNumber(q?.min_score) ?? 1;
            const maxScore = toNumber(q?.max_score) ?? 10;
            const reverse = String(q?.reverse ?? 'N').toUpperCase() === 'Y';
            const scoreRc = reverse ? ((minScore + maxScore) - raw) : raw;
            if (!Number.isFinite(scoreRc)) return;

            const scaleName = String(q?.trait ?? '').trim() || '미분류';
            if (!questionMetaById[qid]) {
              questionMetaById[qid] = {
                text: String(q?.text ?? '').trim(),
                trait: String(q?.trait ?? '').trim(),
                tags: parseTagList(q?.tags),
                type: 'scale',
                reverse: String(q?.reverse ?? 'N').toUpperCase(),
                minScore: toNumber(q?.min_score),
                maxScore: toNumber(q?.max_score),
              };
            }
            if (!scaleItemSetMap[scaleName]) scaleItemSetMap[scaleName] = new Set<string>();
            scaleItemSetMap[scaleName].add(qid);
            if (!coreScoreMap[scaleName]) coreScoreMap[scaleName] = {};
            if (!coreScoreMap[scaleName][pid]) coreScoreMap[scaleName][pid] = {};
            coreScoreMap[scaleName][pid][qid] = scoreRc;
            if (!typeAxisQuestionScoreMap[qid]) typeAxisQuestionScoreMap[qid] = {};
            typeAxisQuestionScoreMap[qid][pid] = scoreRc;
            if (!allQuestionScoreMap[qid]) allQuestionScoreMap[qid] = {};
            allQuestionScoreMap[qid][pid] = scoreRc;
            participantSet.add(pid);
          } else if (qType === 'text') {
            const numericTextAnswer = toNumber(row?.answer_number ?? row?.answer_text);
            if (numericTextAnswer == null) return;
            if (!questionMetaById[qid]) {
              questionMetaById[qid] = {
                text: String(q?.text ?? '').trim(),
                trait: String(q?.trait ?? '').trim(),
                tags: parseTagList(q?.tags),
                type: 'text',
                reverse: 'N',
                minScore: null,
                maxScore: null,
              };
            }
            if (!supplementaryQuestionMap[qid]) {
              supplementaryQuestionMap[qid] = String(q?.text ?? '').trim() || `(문항 ${qid})`;
            }
            if (!supplementaryValuesMap[qid]) supplementaryValuesMap[qid] = [];
            supplementaryValuesMap[qid].push(numericTextAnswer);
            if (!allQuestionScoreMap[qid]) allQuestionScoreMap[qid] = {};
            allQuestionScoreMap[qid][pid] = numericTextAnswer;
            participantSet.add(pid);
          }
        });

        const scaleNames = Array.from(
          new Set([...Object.keys(scaleItemSetMap), ...Object.keys(coreScoreMap)]),
        ).sort((a, b) => a.localeCompare(b));

        const nextStats: SnapshotScaleStat[] = scaleNames.map((scaleName) => {
          const itemIds = Array.from(scaleItemSetMap[scaleName] ?? []);
          const byStudent = coreScoreMap[scaleName] ?? {};
          const rawScores: number[] = [];
          const completeRows: number[][] = [];

          Object.values(byStudent).forEach((itemScoreMap) => {
            const values = Object.values(itemScoreMap).filter(
              (v): v is number => typeof v === 'number' && Number.isFinite(v),
            );
            if (values.length) {
              const mean = values.reduce((sum, v) => sum + v, 0) / values.length;
              rawScores.push(mean);
            }

            if (itemIds.length >= 2) {
              const rowValues = itemIds.map((itemId) => itemScoreMap[itemId]);
              const isComplete = rowValues.every((v) => typeof v === 'number' && Number.isFinite(v));
              if (isComplete) completeRows.push(rowValues as number[]);
            }
          });

          const mean = rawScores.length
            ? rawScores.reduce((sum, v) => sum + v, 0) / rawScores.length
            : null;
          const sd = computeSampleSd(rawScores);
          const min = rawScores.length ? Math.min(...rawScores) : null;
          const max = rawScores.length ? Math.max(...rawScores) : null;

          let alpha: number | null = null;
          const alphaNComplete = completeRows.length;
          if (itemIds.length >= 2 && completeRows.length >= 2) {
            const k = itemIds.length;
            let sumItemVar = 0;
            for (let col = 0; col < k; col += 1) {
              const colValues = completeRows.map((row) => row[col]);
              const colMean = colValues.reduce((sum, v) => sum + v, 0) / colValues.length;
              const colVar = colValues.reduce((sum, v) => sum + ((v - colMean) ** 2), 0) / (colValues.length - 1);
              sumItemVar += colVar;
            }
            const totalScores = completeRows.map((row) => row.reduce((sum, v) => sum + v, 0));
            const totalMean = totalScores.reduce((sum, v) => sum + v, 0) / totalScores.length;
            const totalVar = totalScores.reduce((sum, v) => sum + ((v - totalMean) ** 2), 0) / (totalScores.length - 1);
            if (totalVar > 0) {
              alpha = (k / (k - 1)) * (1 - (sumItemVar / totalVar));
              if (!Number.isFinite(alpha)) alpha = null;
            }
          }

          return {
            scaleName,
            itemCount: itemIds.length,
            mean,
            sd,
            min,
            max,
            nRespondents: rawScores.length,
            alpha,
            alphaNComplete,
          };
        });

        const nextSubjectiveStats: SnapshotSubjectiveStat[] = Object.entries(supplementaryValuesMap)
          .map(([questionId, values]) => {
            const valid = values.filter((v) => Number.isFinite(v));
            return {
              questionId,
              text: supplementaryQuestionMap[questionId] || `(문항 ${questionId})`,
              itemN: valid.length,
              mean: valid.length ? (valid.reduce((sum, v) => sum + v, 0) / valid.length) : null,
              sd: computeSampleSd(valid),
              min: valid.length ? Math.min(...valid) : null,
              max: valid.length ? Math.max(...valid) : null,
            };
          })
          .sort((a, b) => a.text.localeCompare(b.text));

        const axisByParticipant: Record<string, { emotion: number[]; belief: number[] }> = {};
        const emotionAxisLabelSet = new Set<string>();
        const beliefAxisLabelSet = new Set<string>();
        const directionAudit = {
          negativeWithReverseY: 0,
          negativeWithReverseN: 0,
          positiveWithReverseY: 0,
        };
        Object.entries(typeAxisQuestionScoreMap).forEach(([questionId, byStudent]) => {
          const values = Object.values(byStudent).filter(
            (v): v is number => typeof v === 'number' && Number.isFinite(v),
          );
          if (values.length < 2) return;
          const mean = computeMean(values);
          const sd = computeSampleSd(values);
          if (mean == null || sd == null || sd <= 0) return;

          const questionMeta = questionMetaById[questionId];
          const axisRole = classifyAxisFromQuestion(
            questionMeta?.tags,
            questionMeta?.trait,
            questionMeta?.text,
          );
          if (!axisRole) return;
          const reverseY = isReverseItem(questionMeta?.reverse);
          if (axisRole === 'emotion_neg' || axisRole === 'belief_neg') {
            if (reverseY) directionAudit.negativeWithReverseY += 1;
            else directionAudit.negativeWithReverseN += 1;
          } else if (reverseY) {
            directionAudit.positiveWithReverseY += 1;
          }

          const labelSource = (questionMeta?.tags ?? []).map(tagLeafLabel).find(Boolean)
            || questionMeta?.text
            || questionMeta?.trait
            || questionId;

          Object.entries(byStudent).forEach(([participantId, score]) => {
            if (!Number.isFinite(score)) return;
            const z = (score - mean) / sd;
            if (!Number.isFinite(z)) return;
            if (!axisByParticipant[participantId]) {
              axisByParticipant[participantId] = { emotion: [], belief: [] };
            }
            const sign = axisContributionSign(axisRole, questionMeta?.reverse);
            const zOriented = z * sign;
            if (axisRole === 'belief_pos' || axisRole === 'belief_neg') {
              axisByParticipant[participantId].belief.push(zOriented);
              beliefAxisLabelSet.add(labelSource);
            } else if (axisRole === 'emotion_pos' || axisRole === 'emotion_neg') {
              axisByParticipant[participantId].emotion.push(zOriented);
              emotionAxisLabelSet.add(labelSource);
            }
          });
        });

        const adjustmentByParticipant: Record<string, { metacognition: number[]; persistence: number[] }> = {};
        const metacognitionLabelSet = new Set<string>();
        const persistenceLabelSet = new Set<string>();
        Object.entries(allQuestionScoreMap).forEach(([questionId, byStudent]) => {
          const values = Object.values(byStudent).filter(
            (v): v is number => typeof v === 'number' && Number.isFinite(v),
          );
          if (values.length < 2) return;
          const mean = computeMean(values);
          const sd = computeSampleSd(values);
          if (mean == null || sd == null || sd <= 0) return;

          const questionMeta = questionMetaById[questionId];
          const adjustmentRole = classifyLearningAdjustmentFromQuestion(
            questionMeta?.tags,
            questionMeta?.trait,
            questionMeta?.text,
            questionMeta?.type,
          );
          if (!adjustmentRole) return;
          const invertDirection = shouldInvertLearningAdjustment(
            adjustmentRole,
            questionMeta?.tags,
            questionMeta?.trait,
            questionMeta?.text,
          );

          const labelSource = (questionMeta?.tags ?? []).map(tagLeafLabel).find(Boolean)
            || questionMeta?.text
            || questionMeta?.trait
            || questionId;

          Object.entries(byStudent).forEach(([participantId, score]) => {
            if (!Number.isFinite(score)) return;
            let z = (score - mean) / sd;
            if (!Number.isFinite(z)) return;
            if (invertDirection) z *= -1;
            if (!adjustmentByParticipant[participantId]) {
              adjustmentByParticipant[participantId] = { metacognition: [], persistence: [] };
            }
            if (adjustmentRole === 'metacognition') {
              adjustmentByParticipant[participantId].metacognition.push(z);
              metacognitionLabelSet.add(labelSource);
            } else {
              adjustmentByParticipant[participantId].persistence.push(z);
              persistenceLabelSet.add(labelSource);
            }
          });
        });

        const subscaleKeys = SCALE_GUIDE_SUBSCALES.map((item) => item.key);
        const subscaleRawByParticipant: Record<ScaleGuideSubscaleKey, Record<string, number[]>> = {
          interest: {},
          emotion_reactivity: {},
          math_mindset: {},
          effort_outcome_belief: {},
          external_attribution_belief: {},
          self_concept: {},
          identity: {},
          agency_perception: {},
          question_understanding_belief: {},
          recovery_expectancy_belief: {},
          failure_interpretation_belief: {},
          metacognition: {},
          persistence: {},
        };
        Object.entries(allQuestionScoreMap).forEach(([questionId, byStudent]) => {
          const questionMeta = questionMetaById[questionId];
          const subscaleKey = classifySubscaleFromQuestion(
            questionMeta?.tags,
            questionMeta?.trait,
            questionMeta?.text,
            questionMeta?.type,
          );
          if (!subscaleKey) return;
          Object.entries(byStudent).forEach(([participantId, score]) => {
            if (!Number.isFinite(score)) return;
            const orientedScore = (
              questionMeta?.type === 'scale'
                ? orientedDisplayScoreForSubscale(
                  score,
                  subscaleKey,
                  questionMeta?.reverse,
                  questionMeta?.minScore,
                  questionMeta?.maxScore,
                )
                : score
            );
            if (!Number.isFinite(orientedScore)) return;
            if (!subscaleRawByParticipant[subscaleKey][participantId]) {
              subscaleRawByParticipant[subscaleKey][participantId] = [];
            }
            subscaleRawByParticipant[subscaleKey][participantId].push(orientedScore);
          });
        });

        const subscaleScoreByParticipant: Record<string, Partial<Record<ScaleGuideSubscaleKey, number>>> = {};
        const subscalePopulationValues: Record<ScaleGuideSubscaleKey, number[]> = {
          interest: [],
          emotion_reactivity: [],
          math_mindset: [],
          effort_outcome_belief: [],
          external_attribution_belief: [],
          self_concept: [],
          identity: [],
          agency_perception: [],
          question_understanding_belief: [],
          recovery_expectancy_belief: [],
          failure_interpretation_belief: [],
          metacognition: [],
          persistence: [],
        };
        subscaleKeys.forEach((subscaleKey) => {
          Object.entries(subscaleRawByParticipant[subscaleKey]).forEach(([participantId, values]) => {
            const score = computeMean(values);
            if (score == null || !Number.isFinite(score)) return;
            if (!subscaleScoreByParticipant[participantId]) subscaleScoreByParticipant[participantId] = {};
            subscaleScoreByParticipant[participantId][subscaleKey] = score;
            subscalePopulationValues[subscaleKey].push(score);
          });
        });

        const indicatorKeys = SCALE_GUIDE_INDICATORS.map((item) => item.key);
        const indicatorScoreByParticipant: Record<string, Partial<Record<ScaleGuideIndicatorKey, number>>> = {};
        const indicatorPopulationValues: Record<ScaleGuideIndicatorKey, number[]> = {
          emotion: [],
          belief: [],
          learning_style: [],
        };
        Array.from(participantSet).forEach((participantId) => {
          indicatorKeys.forEach((indicatorKey) => {
            const scoreValues = INDICATOR_SUBSCALE_KEYS[indicatorKey]
              .map((subscaleKey) => subscaleScoreByParticipant[participantId]?.[subscaleKey])
              .filter((v): v is number => typeof v === 'number' && Number.isFinite(v));
            const score = computeMean(scoreValues);
            if (score == null || !Number.isFinite(score)) return;
            if (!indicatorScoreByParticipant[participantId]) indicatorScoreByParticipant[participantId] = {};
            indicatorScoreByParticipant[participantId][indicatorKey] = score;
            indicatorPopulationValues[indicatorKey].push(score);
          });
        });

        const nextReportScaleProfilesByParticipant: Record<string, ParticipantReportScaleProfile> = {};
        Array.from(participantSet).forEach((participantId) => {
          const profile = buildEmptyReportScaleProfile();
          subscaleKeys.forEach((subscaleKey) => {
            const score = subscaleScoreByParticipant[participantId]?.[subscaleKey] ?? null;
            profile.subscales[subscaleKey] = {
              score,
              percentile: computePercentileRank(subscalePopulationValues[subscaleKey], score),
            };
          });
          indicatorKeys.forEach((indicatorKey) => {
            const score = indicatorScoreByParticipant[participantId]?.[indicatorKey] ?? null;
            profile.indicators[indicatorKey] = {
              score,
              percentile: computePercentileRank(indicatorPopulationValues[indicatorKey], score),
            };
          });
          nextReportScaleProfilesByParticipant[participantId] = profile;
        });

        const nextAxisPoints: SnapshotAxisPoint[] = Array.from(participantSet)
          .map((participantId) => {
            const axis = axisByParticipant[participantId];
            const emotionZ = axis ? computeMean(axis.emotion) : null;
            const beliefZ = axis ? computeMean(axis.belief) : null;
            const adjustment = adjustmentByParticipant[participantId];
            const metacognitionZ = adjustment ? computeMean(adjustment.metacognition) : null;
            const persistenceZ = adjustment ? computeMean(adjustment.persistence) : null;
            const meta = participantMetaById[participantId];
            return {
              participantId,
              participantName: meta?.name || participantId,
              emotionZ,
              beliefZ,
              metacognitionZ,
              persistenceZ,
              typeCode: classifyEmotionBeliefType(emotionZ, beliefZ),
              currentLevelGrade: meta?.levelGrade ?? null,
              currentMathPercentile: meta?.percentile ?? null,
            };
          })
          .sort((a, b) => a.participantName.localeCompare(b.participantName, 'ko'));

        if (!cancelled) {
          const coreItemCount = nextStats.reduce((sum, item) => sum + item.itemCount, 0);
          const supplementaryItemCount = nextSubjectiveStats.length;
          setSnapshotScaleStats(nextStats);
          setSnapshotSubjectiveStats(nextSubjectiveStats);
          setSnapshotAxisPoints(nextAxisPoints);
          setReportScaleProfilesByParticipant(nextReportScaleProfilesByParticipant);
          setSnapshotAxisMeta({
            emotionScaleNames: Array.from(emotionAxisLabelSet).sort((a, b) => a.localeCompare(b)),
            beliefScaleNames: Array.from(beliefAxisLabelSet).sort((a, b) => a.localeCompare(b)),
            metacognitionLabels: Array.from(metacognitionLabelSet).sort((a, b) => a.localeCompare(b)),
            persistenceLabels: Array.from(persistenceLabelSet).sort((a, b) => a.localeCompare(b)),
          });
          setSnapshotMeta({
            asOfDate: new Date().toISOString(),
            totalN: participantSet.size,
            scaleCount: nextStats.length,
            coreItemCount,
            supplementaryItemCount,
            totalItemCount: coreItemCount + supplementaryItemCount,
            scaleBasis: `유형축=emotion+belief(tags), 보정축=metacognition+persistence(text 포함), 방향보정(neg Y:${directionAudit.negativeWithReverseY}, neg N:${directionAudit.negativeWithReverseN}, pos Y:${directionAudit.positiveWithReverseY})`,
          });
        }
      } catch (error: any) {
        if (!cancelled) {
          setSnapshotScaleStats([]);
          setSnapshotSubjectiveStats([]);
          setSnapshotAxisPoints([]);
          setReportScaleProfilesByParticipant({});
          setSnapshotAxisMeta({ emotionScaleNames: [], beliefScaleNames: [], metacognitionLabels: [], persistenceLabels: [] });
          setSnapshotMeta(null);
          setSnapshotError(error?.message ?? 'Scale_Stats 계산 실패');
        }
      } finally {
        if (!cancelled) setSnapshotLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [roundOrderMap, rows]);

  const filteredItemStats = React.useMemo(() => {
    const keyword = filterText.trim().toLowerCase();
    const filtered = itemStats.filter((item) => {
      const roundLabel = formatRoundLabel(item.roundLabel);
      if (filterTrait !== 'ALL' && item.trait !== filterTrait) return false;
      if (filterType !== 'ALL' && item.type !== filterType) return false;
      if (filterRound !== 'ALL' && roundLabel !== filterRound) return false;
      if (keyword) {
        const target = `${item.text} ${item.questionId}`.toLowerCase();
        if (!target.includes(keyword)) return false;
      }
      return true;
    });
    return filtered.sort((a, b) => {
      const aRound = parseRoundNo(a.roundLabel) ?? 999;
      const bRound = parseRoundNo(b.roundLabel) ?? 999;
      if (aRound !== bRound) return aRound - bRound;
      if (a.trait !== b.trait) return a.trait.localeCompare(b.trait);
      return a.text.localeCompare(b.text);
    });
  }, [filterRound, filterText, filterTrait, filterType, itemStats]);

  const traitOptions = React.useMemo(() => {
    const set = new Set<string>();
    itemStats.forEach((item) => {
      if (item.trait) set.add(item.trait);
    });
    return Array.from(set).sort();
  }, [itemStats]);

  const typeOptions = React.useMemo(() => {
    const set = new Set<string>();
    itemStats.forEach((item) => {
      if (item.type) set.add(item.type);
    });
    return Array.from(set).sort();
  }, [itemStats]);

  const roundOptions = React.useMemo(() => {
    const set = new Set<string>();
    itemStats.forEach((item) => {
      set.add(formatRoundLabel(item.roundLabel));
    });
    return Array.from(set).sort((a, b) => {
      const aNo = parseRoundNo(a) ?? 999;
      const bNo = parseRoundNo(b) ?? 999;
      if (aNo !== bNo) return aNo - bNo;
      return a.localeCompare(b);
    });
  }, [itemStats]);

  const levelBandCounts = React.useMemo(() => {
    const counts: Record<LevelBandCode, number> = {
      ALL: rows.length,
      NO_VALUE: 0,
      G0: 0,
      G1: 0,
      G2: 0,
      G3: 0,
      G4: 0,
      G5: 0,
      G6: 0,
    };
    rows.forEach((row) => {
      const code = deriveParticipantBandCode(row.current_level_grade, row.current_math_percentile);
      counts[code] += 1;
    });
    return counts;
  }, [rows]);

  const filteredRows = React.useMemo(
    () => rows.filter((row) => matchesLevelBand(row.current_level_grade, row.current_math_percentile, filterLevelBand)),
    [filterLevelBand, rows],
  );

  const selectedLevelBandLabel = React.useMemo(
    () => getLevelBandLabel(filterLevelBand),
    [filterLevelBand],
  );

  const axisPointsWithValues = React.useMemo(
    () => snapshotAxisPoints.filter(
      (p) => p.emotionZ != null && Number.isFinite(p.emotionZ) && p.beliefZ != null && Number.isFinite(p.beliefZ),
    ),
    [snapshotAxisPoints],
  );

  const axisTypeCounts = React.useMemo(() => {
    const counts: Record<AxisTypeCode, number> = {
      TYPE_A: 0,
      TYPE_B: 0,
      TYPE_C: 0,
      TYPE_D: 0,
      UNCLASSIFIED: 0,
    };
    snapshotAxisPoints.forEach((point) => {
      counts[point.typeCode] += 1;
    });
    return counts;
  }, [snapshotAxisPoints]);

  const axisTypeAvgGrade = React.useMemo(() => {
    const gradesByType: Record<AxisTypeCode, number[]> = {
      TYPE_A: [], TYPE_B: [], TYPE_C: [], TYPE_D: [], UNCLASSIFIED: [],
    };
    snapshotAxisPoints.forEach((point) => {
      const grade = resolveLevelGrade(point.currentLevelGrade, point.currentMathPercentile);
      if (grade != null) gradesByType[point.typeCode].push(grade);
    });
    const result: Record<AxisTypeCode, number | null> = {
      TYPE_A: null, TYPE_B: null, TYPE_C: null, TYPE_D: null, UNCLASSIFIED: null,
    };
    (Object.keys(gradesByType) as AxisTypeCode[]).forEach((code) => {
      const arr = gradesByType[code];
      result[code] = arr.length ? arr.reduce((s, v) => s + v, 0) / arr.length : null;
    });
    return result;
  }, [snapshotAxisPoints]);

  const adjustmentGradeCorr = React.useMemo(() => {
    const pairs: { meta: number; persist: number; grade: number }[] = [];
    snapshotAxisPoints.forEach((point) => {
      const grade = resolveLevelGrade(point.currentLevelGrade, point.currentMathPercentile);
      if (grade == null || point.metacognitionZ == null || point.persistenceZ == null) return;
      pairs.push({ meta: point.metacognitionZ, persist: point.persistenceZ, grade });
    });
    if (pairs.length < 5) return { metaCorr: 0, persistCorr: 0, n: 0 };

    function pearson(xs: number[], ys: number[]): number {
      const n = xs.length;
      const mx = xs.reduce((a, b) => a + b, 0) / n;
      const my = ys.reduce((a, b) => a + b, 0) / n;
      let num = 0; let dx2 = 0; let dy2 = 0;
      for (let i = 0; i < n; i++) {
        const dxi = xs[i] - mx; const dyi = ys[i] - my;
        num += dxi * dyi; dx2 += dxi * dxi; dy2 += dyi * dyi;
      }
      const denom = Math.sqrt(dx2 * dy2);
      return denom > 0 ? num / denom : 0;
    }
    const grades = pairs.map((p) => p.grade);
    return {
      metaCorr: pearson(pairs.map((p) => p.meta), grades),
      persistCorr: pearson(pairs.map((p) => p.persist), grades),
      n: pairs.length,
    };
  }, [snapshotAxisPoints]);

  const reportCandidatePoints = React.useMemo(() => {
    const keyword = reportSearchKeyword.trim().toLowerCase();
    if (!keyword) return snapshotAxisPoints;
    return snapshotAxisPoints.filter((point) => (
      `${point.participantName} ${point.participantId}`.toLowerCase().includes(keyword)
    ));
  }, [reportSearchKeyword, snapshotAxisPoints]);

  React.useEffect(() => {
    if (!snapshotAxisPoints.length) {
      setSelectedReportParticipantId(null);
      return;
    }
    setSelectedReportParticipantId((prev) => {
      if (prev && snapshotAxisPoints.some((point) => point.participantId === prev)) {
        return prev;
      }
      return snapshotAxisPoints[0].participantId;
    });
  }, [snapshotAxisPoints]);

  const selectedReportPoint = React.useMemo(
    () => snapshotAxisPoints.find((point) => point.participantId === selectedReportParticipantId) ?? null,
    [selectedReportParticipantId, snapshotAxisPoints],
  );

  const selectedReportScaleProfile = React.useMemo(
    () => (
      selectedReportPoint
        ? (reportScaleProfilesByParticipant[selectedReportPoint.participantId] ?? buildEmptyReportScaleProfile())
        : null
    ),
    [reportScaleProfilesByParticipant, selectedReportPoint],
  );

  const selectedReportPeerSummary = React.useMemo(() => {
    type PeerNeighbor = { participantId: string; participantName: string; distance: number; levelGrade: number; emotionZ: number; beliefZ: number };
    const empty = {
      avgLevelGrade: null as number | null,
      knnRawAvg: null as number | null,
      typeAvg: null as number | null,
      adjustmentDelta: null as number | null,
      sampleN: 0,
      source: 'none' as 'none' | 'knn' | 'global',
      neighbors: [] as PeerNeighbor[],
    };
    if (!selectedReportPoint) {
      return empty;
    }
    if (selectedReportPoint.emotionZ == null || selectedReportPoint.beliefZ == null) {
      return empty;
    }
    const anchorX = selectedReportPoint.emotionZ;
    const anchorY = selectedReportPoint.beliefZ;
    if (!Number.isFinite(anchorX) || !Number.isFinite(anchorY)) {
      return empty;
    }

    const candidatePeers = snapshotAxisPoints
      .filter((point) => point.participantId !== selectedReportPoint.participantId)
      .map((point) => {
        if (point.emotionZ == null || point.beliefZ == null) return null;
        if (!Number.isFinite(point.emotionZ) || !Number.isFinite(point.beliefZ)) return null;
        const levelGrade = resolveLevelGrade(point.currentLevelGrade, point.currentMathPercentile);
        if (levelGrade == null) return null;
        const dx = point.emotionZ - anchorX;
        const dy = point.beliefZ - anchorY;
        return {
          participantId: point.participantId,
          participantName: point.participantName,
          distance: Math.sqrt((dx ** 2) + (dy ** 2)),
          levelGrade,
          emotionZ: point.emotionZ,
          beliefZ: point.beliefZ,
        };
      })
      .filter((row): row is PeerNeighbor => row != null)
      .sort((a, b) => a.distance - b.distance);

    if (candidatePeers.length > 0) {
      const neighbors = candidatePeers.slice(0, Math.min(PREVIEW_PEER_K, candidatePeers.length));
      const knnRaw = neighbors.reduce((sum, row) => sum + row.levelGrade, 0) / neighbors.length;
      const typeAvg = axisTypeAvgGrade[selectedReportPoint.typeCode];
      const blended = typeAvg != null
        ? (neighbors.length * knnRaw + PEER_SHRINKAGE_PRIOR * typeAvg) / (neighbors.length + PEER_SHRINKAGE_PRIOR)
        : knnRaw;

      let adjustmentDelta = 0;
      const metaZ = selectedReportPoint.metacognitionZ;
      const persistZ = selectedReportPoint.persistenceZ;
      if (adjustmentGradeCorr.n >= 5 && metaZ != null && persistZ != null) {
        adjustmentDelta = ADJUSTMENT_AXIS_WEIGHT * (
          adjustmentGradeCorr.metaCorr * metaZ + adjustmentGradeCorr.persistCorr * persistZ
        );
      }
      const avgLevelGrade = Math.max(0, Math.min(6, blended + adjustmentDelta));

      return {
        avgLevelGrade,
        knnRawAvg: knnRaw,
        typeAvg: typeAvg ?? null,
        adjustmentDelta: adjustmentDelta !== 0 ? adjustmentDelta : null,
        sampleN: neighbors.length,
        source: 'knn' as const,
        neighbors,
      };
    }

    const globalLevels = snapshotAxisPoints
      .map((point) => resolveLevelGrade(point.currentLevelGrade, point.currentMathPercentile))
      .filter((levelGrade): levelGrade is number => levelGrade != null);
    if (!globalLevels.length) return empty;
    const globalAvg = globalLevels.reduce((sum, row) => sum + row, 0) / globalLevels.length;
    return {
      avgLevelGrade: globalAvg,
      knnRawAvg: null,
      typeAvg: null,
      adjustmentDelta: null,
      sampleN: globalLevels.length,
      source: 'global' as const,
      neighbors: [] as PeerNeighbor[],
    };
  }, [selectedReportPoint, snapshotAxisPoints, axisTypeAvgGrade, adjustmentGradeCorr]);

  const selectedReportSubscalePeerGrades = React.useMemo(() => {
    const result: Record<string, number | null> = {};
    if (!selectedReportPoint) return result;
    const anchorProfile = reportScaleProfilesByParticipant[selectedReportPoint.participantId];
    if (!anchorProfile) return result;
    const typeAvg = axisTypeAvgGrade[selectedReportPoint.typeCode] ?? null;

    const ALL_SUBSCALE_KEYS: ScaleGuideSubscaleKey[] = [
      'interest', 'emotion_reactivity',
      'math_mindset', 'effort_outcome_belief', 'external_attribution_belief',
      'self_concept', 'identity', 'agency_perception',
      'question_understanding_belief', 'recovery_expectancy_belief', 'failure_interpretation_belief',
      'metacognition', 'persistence',
    ];

    for (const subKey of ALL_SUBSCALE_KEYS) {
      const anchorPct = anchorProfile.subscales[subKey]?.percentile;
      if (anchorPct == null || !Number.isFinite(anchorPct)) { result[subKey] = null; continue; }

      const candidates: Array<{ distance: number; grade: number }> = [];
      for (const point of snapshotAxisPoints) {
        if (point.participantId === selectedReportPoint.participantId) continue;
        const grade = resolveLevelGrade(point.currentLevelGrade, point.currentMathPercentile);
        if (grade == null) continue;
        const peerProfile = reportScaleProfilesByParticipant[point.participantId];
        const peerPct = peerProfile?.subscales[subKey]?.percentile;
        if (peerPct == null || !Number.isFinite(peerPct)) continue;
        candidates.push({ distance: Math.abs(peerPct - anchorPct), grade });
      }
      candidates.sort((a, b) => a.distance - b.distance);

      if (candidates.length === 0) { result[subKey] = null; continue; }
      const neighbors = candidates.slice(0, Math.min(PREVIEW_PEER_K, candidates.length));
      const knnRaw = neighbors.reduce((s, n) => s + n.grade, 0) / neighbors.length;
      const blended = typeAvg != null
        ? (neighbors.length * knnRaw + PEER_SHRINKAGE_PRIOR * typeAvg) / (neighbors.length + PEER_SHRINKAGE_PRIOR)
        : knnRaw;
      result[subKey] = Math.max(0, Math.min(6, blended));
    }
    return result;
  }, [selectedReportPoint, snapshotAxisPoints, reportScaleProfilesByParticipant, axisTypeAvgGrade]);

  const selectedReportTypeCode = React.useMemo(
    () => (selectedReportPoint ? toFeedbackTypeCode(selectedReportPoint.typeCode) : null),
    [selectedReportPoint],
  );

  const selectedReportTemplate = React.useMemo(
    () => (selectedReportTypeCode ? feedbackTemplates[selectedReportTypeCode] : null),
    [feedbackTemplates, selectedReportTypeCode],
  );

  const selectedReportSectionsByKey = React.useMemo(() => {
    const map: Partial<Record<FeedbackSectionKey, string>> = {};
    if (!selectedReportTemplate) return map;
    selectedReportTemplate.sections.forEach((section) => {
      map[section.key] = combineSectionText(section);
    });
    return map;
  }, [selectedReportTemplate]);

  const editingTemplate = React.useMemo(
    () => feedbackTemplates[editingTemplateType],
    [editingTemplateType, feedbackTemplates],
  );

  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      setTemplateLoading(true);
      setTemplateError(null);
      try {
        let scaleDescriptionAvailable = true;
        let templateRows: any[] = [];

        const fullSelect = await supabase
          .from('trait_feedback_templates')
          .select('type_code, template_name, sections, scale_description, updated_at, is_active')
          .in('type_code', FEEDBACK_TYPE_CODES)
          .eq('is_active', true);

        if (fullSelect.error) {
          const message = String(fullSelect.error?.message ?? '');
          if (/scale_description/i.test(message)) {
            scaleDescriptionAvailable = false;
            const fallbackSelect = await supabase
              .from('trait_feedback_templates')
              .select('type_code, template_name, sections, updated_at, is_active')
              .in('type_code', FEEDBACK_TYPE_CODES)
              .eq('is_active', true);
            if (fallbackSelect.error) throw fallbackSelect.error;
            templateRows = (fallbackSelect.data as any[]) || [];
          } else {
            throw fullSelect.error;
          }
        } else {
          templateRows = (fullSelect.data as any[]) || [];
        }

        const next = buildDefaultTemplateMap();
        let sharedScaleDescription = '';
        templateRows.forEach((row) => {
          const typeCode = String(row?.type_code ?? '').trim() as FeedbackTypeCode;
          if (!(FEEDBACK_TYPE_CODES as string[]).includes(typeCode)) return;
          if (scaleDescriptionAvailable && !sharedScaleDescription) {
            sharedScaleDescription = String(row?.scale_description ?? '').trim();
          }
          const fallback = next[typeCode];
          next[typeCode] = {
            typeCode,
            templateName: String(row?.template_name ?? fallback.templateName).trim() || fallback.templateName,
            sections: mergeTemplateSections(row?.sections, fallback.sections),
            updatedAt: row?.updated_at ?? null,
          };
        });
        const parsedGuide = parseScaleGuideTemplate(sharedScaleDescription);
        const normalizedGuide = parsedGuide ?? cloneScaleGuideTemplate(DEFAULT_SCALE_GUIDE_TEMPLATE);
        const serializedGuide = serializeScaleGuideTemplate(normalizedGuide);
        if (!cancelled) {
          setFeedbackTemplates(next);
          setTemplateScaleGuide(normalizedGuide);
          setTemplateScaleDescription(parsedGuide ? sharedScaleDescription : serializedGuide);
          setTemplateScaleDescriptionAvailable(scaleDescriptionAvailable);
          setTemplateCommonDirty(false);
          setTemplateDirty({ TYPE_A: false, TYPE_B: false, TYPE_C: false, TYPE_D: false });
        }
      } catch (error: any) {
        if (!cancelled) {
          setTemplateError(error?.message ?? '유형 템플릿 로드 실패');
        }
      } finally {
        if (!cancelled) setTemplateLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  function arrayToBase64(arr: ArrayBuffer): string {
    const bytes = new Uint8Array(arr);
    let binary = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
    }
    return btoa(binary);
  }

  function exportItemStats() {
    if (!filteredItemStats.length) {
      alert('내보낼 Item_Stats 데이터가 없습니다.');
      return;
    }
    const asOfDate = itemStatsMeta?.asOfDate ?? new Date().toISOString();
    const cumulativeN = itemStatsMeta?.cumulativeParticipants ?? 0;
    const levelFilterCode = filterLevelBand;
    const levelFilterLabel = selectedLevelBandLabel;
    const rows = filteredItemStats.map((item) => ({
      as_of_date: asOfDate,
      cumulative_n: cumulativeN,
      level_filter_code: levelFilterCode,
      level_filter_label: levelFilterLabel,
      question_id: item.questionId,
      round_label: formatRoundLabel(item.roundLabel),
      trait: item.trait,
      type: item.type,
      text: item.text,
      item_n: item.itemN,
      mean: item.mean,
      sd: item.sd,
      min: item.min,
      max: item.max,
      avg_response_ms: item.avgResponseMs,
    }));
    const ws = XLSX.utils.json_to_sheet(rows);
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, 'Item_Stats');
    const fileStamp = asOfDate.replace(/[:T]/g, '-').slice(0, 19);
    const filename = `item_stats_${fileStamp}.xlsx`;
    const out = XLSX.write(wb, { bookType: 'xlsx', type: 'array' }) as ArrayBuffer;

    // ✅ WebView2(관리자앱)에서는 브라우저 다운로드가 막힐 수 있어 host로 전달
    const host = (window as any)?.chrome?.webview;
    if (host?.postMessage) {
      try {
        host.postMessage({
          type: 'download_file',
          filename,
          mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          base64: arrayToBase64(out),
        });
        return;
      } catch (e: any) {
        console.warn('[export] host postMessage failed', e);
      }
    }

    // 브라우저 환경: Blob 다운로드
    const blob = new Blob([out], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  }

  const itemGridTemplate = '0.9fr 0.6fr 0.6fr 3.2fr 0.6fr 0.8fr 0.8fr 0.8fr 0.8fr 1fr';
  const snapshotGridTemplate = '1.3fr 0.7fr 0.8fr 0.8fr 0.8fr 0.8fr 0.9fr 0.9fr 1fr';
  const snapshotSubjectiveGridTemplate = '2.6fr 0.8fr 0.9fr 0.9fr 0.9fr 0.9fr';
  const chipBaseStyle: React.CSSProperties = {
    height: 32,
    padding: '0 10px',
    borderRadius: 999,
    border: `1px solid ${tokens.border}`,
    background: tokens.field,
    color: tokens.textDim,
    fontSize: 12,
    cursor: 'pointer',
    whiteSpace: 'nowrap',
  };
  const chipActiveStyle: React.CSSProperties = {
    background: tokens.accent,
    border: `1px solid ${tokens.accent}`,
    color: '#FFFFFF',
    fontWeight: 700,
  };

  function formatRound2Status(link?: Round2LinkStatus | null) {
    if (!link) return '미발송';
    if (link.lastStatus === 'error') {
      return link.lastError ? `발송 실패: ${link.lastError}` : '발송 실패';
    }
    if (link.sentAt) return `발송됨 ${formatDateTime(link.sentAt)}`;
    if (link.lastStatus) return `상태: ${link.lastStatus}`;
    return '발송 기록 없음';
  }

  async function openDetails(row: Row) {
    setSelected(row);
    const { data } = await supabase
      .from('question_answers')
      .select('question_id, answer_text, answer_number, response_ms, is_fast, question:questions(text, trait, type), response:question_responses!inner(participant_id)')
      .eq('response.participant_id', row.id)
      .order('question_id');
    setAnswers((data as any[]) || []);
  }

  async function saveCurrentLevelGrade(participantId: string, code: Exclude<LevelBandCode, 'ALL'>) {
    const nextLevelGrade = bandCodeToLevelGrade(code);
    const currentLevelGrade = normalizeLevelGrade(
      rows.find((row) => row.id === participantId)?.current_level_grade,
    );
    if (currentLevelGrade === nextLevelGrade) {
      setLevelErrorById((prev) => ({ ...prev, [participantId]: null }));
      return;
    }

    setSavingLevelById((prev) => ({ ...prev, [participantId]: true }));
    setLevelErrorById((prev) => ({ ...prev, [participantId]: null }));
    try {
      const { error } = await supabase
        .from('survey_participants')
        .update({ current_level_grade: nextLevelGrade })
        .eq('id', participantId);
      if (error) throw error;
      setRows((prev) => prev.map((row) => (
        row.id === participantId
          ? { ...row, current_level_grade: nextLevelGrade }
          : row
      )));
      setSelected((prev) => {
        if (!prev || prev.id !== participantId) return prev;
        return { ...prev, current_level_grade: nextLevelGrade };
      });
    } catch (error: any) {
      const message = (error?.message as string | undefined) ?? '저장에 실패했습니다.';
      setLevelErrorById((prev) => ({ ...prev, [participantId]: message }));
    } finally {
      setSavingLevelById((prev) => ({ ...prev, [participantId]: false }));
    }
  }

  function updateEditingTemplateName(nextName: string) {
    setFeedbackTemplates((prev) => ({
      ...prev,
      [editingTemplateType]: {
        ...prev[editingTemplateType],
        templateName: nextName,
      },
    }));
    setTemplateDirty((prev) => ({ ...prev, [editingTemplateType]: true }));
  }

  function updateEditingTemplateSection(
    key: FeedbackSectionKey,
    field: 'common' | 'fine_tune',
    value: string,
  ) {
    setFeedbackTemplates((prev) => {
      const current = prev[editingTemplateType];
      return {
        ...prev,
        [editingTemplateType]: {
          ...current,
          sections: current.sections.map((section) => (
            section.key === key
              ? { ...section, [field]: value }
              : section
          )),
        },
      };
    });
    setTemplateDirty((prev) => ({ ...prev, [editingTemplateType]: true }));
  }

  function updateTemplateScaleGuide(nextGuide: ScaleGuideTemplate) {
    const normalized = cloneScaleGuideTemplate(nextGuide);
    setTemplateScaleGuide(normalized);
    setTemplateScaleDescription(serializeScaleGuideTemplate(normalized));
    setTemplateCommonDirty(true);
  }

  function updateTemplateScaleIndicatorDescription(key: ScaleGuideIndicatorKey, value: string) {
    updateTemplateScaleGuide({
      ...templateScaleGuide,
      indicatorDescriptions: {
        ...templateScaleGuide.indicatorDescriptions,
        [key]: value,
      },
    });
  }

  function updateTemplateSubscaleDescription(key: ScaleGuideSubscaleKey, value: string) {
    updateTemplateScaleGuide({
      ...templateScaleGuide,
      subscaleDescriptions: {
        ...templateScaleGuide.subscaleDescriptions,
        [key]: value,
      },
    });
  }

  function resetEditingTemplateToDefault() {
    setFeedbackTemplates((prev) => ({
      ...prev,
      [editingTemplateType]: cloneFeedbackTemplate(DEFAULT_FEEDBACK_TEMPLATES[editingTemplateType]),
    }));
    setTemplateDirty((prev) => ({ ...prev, [editingTemplateType]: true }));
  }

  function resetTemplateScaleGuideToDefault() {
    updateTemplateScaleGuide(cloneScaleGuideTemplate(DEFAULT_SCALE_GUIDE_TEMPLATE));
  }

  async function saveEditingTemplate() {
    const current = feedbackTemplates[editingTemplateType];
    const normalizedName = current.templateName.trim() || `${axisTypeLabel(editingTemplateType)} 기본틀`;
    const normalizedScaleDescription = templateScaleDescription.trim();
    const canSaveScaleDescription = templateScaleDescriptionAvailable;
    setTemplateSaving(true);
    setTemplateError(null);
    try {
      if (canSaveScaleDescription) {
        const { error: commonError } = await supabase
          .from('trait_feedback_templates')
          .update({ scale_description: normalizedScaleDescription })
          .in('type_code', FEEDBACK_TYPE_CODES);
        if (commonError) throw commonError;
      }

      const payload: Record<string, unknown> = {
        type_code: editingTemplateType,
        template_name: normalizedName,
        sections: current.sections.map((section) => ({
          key: section.key,
          title: section.title,
          common: section.common,
          fine_tune: section.fine_tune,
        })),
        is_active: true,
      };
      if (canSaveScaleDescription) {
        payload.scale_description = normalizedScaleDescription;
      }
      const { data, error } = await supabase
        .from('trait_feedback_templates')
        .upsert(payload, { onConflict: 'type_code' })
        .select('updated_at')
        .single();
      if (error) throw error;

      setFeedbackTemplates((prev) => ({
        ...prev,
        [editingTemplateType]: {
          ...prev[editingTemplateType],
          templateName: normalizedName,
          updatedAt: data?.updated_at ?? new Date().toISOString(),
        },
      }));
      setTemplateDirty((prev) => ({ ...prev, [editingTemplateType]: false }));
      if (canSaveScaleDescription) {
        setTemplateCommonDirty(false);
      } else if (templateCommonDirty) {
        setTemplateError('척도 설명 저장을 위해 DB 마이그레이션을 먼저 적용해 주세요.');
      }
    } catch (error: any) {
      setTemplateError(error?.message ?? '템플릿 저장 실패');
    } finally {
      setTemplateSaving(false);
    }
  }

  function clearTypeLevelSummary() {
    setTypeLevelSummary(null);
    setTypeLevelSummaryFileName(null);
    setTypeLevelSummaryError(null);
  }

  function handleTypeLevelSummaryFileChange(event: React.ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0] ?? null;
    if (!file) return;
    void (async () => {
      try {
        const text = await file.text();
        const parsed = JSON.parse(text);
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
          throw new Error('JSON 객체 형식이 아닙니다.');
        }
        setTypeLevelSummary(parsed as TypeLevelValidationSummary);
        setTypeLevelSummaryFileName(file.name);
        setTypeLevelSummaryError(null);
      } catch (error: any) {
        setTypeLevelSummary(null);
        setTypeLevelSummaryFileName(null);
        setTypeLevelSummaryError(error?.message ?? '검증 요약 JSON 파싱 실패');
      } finally {
        event.target.value = '';
      }
    })();
  }

  function openReportPreview() {
    if (!selectedReportPoint) {
      alert('미리보기할 학생을 먼저 선택해 주세요.');
      return;
    }
    if (!selectedReportTypeCode) {
      alert('유형이 확정된 학생만 미리보기를 열 수 있습니다.');
      return;
    }
    const qs = new URLSearchParams();
    qs.set('participantId', selectedReportPoint.participantId);
    qs.set('typeCode', selectedReportTypeCode);
    if (selectedReportPoint.emotionZ != null) qs.set('emotionZ', String(selectedReportPoint.emotionZ));
    if (selectedReportPoint.beliefZ != null) qs.set('beliefZ', String(selectedReportPoint.beliefZ));
    if (selectedReportPoint.metacognitionZ != null) qs.set('metacognitionZ', String(selectedReportPoint.metacognitionZ));
    if (selectedReportPoint.persistenceZ != null) qs.set('persistenceZ', String(selectedReportPoint.persistenceZ));
    if (selectedReportScaleProfile) qs.set('scaleProfile', JSON.stringify(selectedReportScaleProfile));
    const vectorStrength = computeVectorStrengthPercent(
      selectedReportPoint.emotionZ,
      selectedReportPoint.beliefZ,
    );
    if (vectorStrength != null) qs.set('vectorStrength', String(vectorStrength));

    const emotionPercentile = selectedReportScaleProfile?.indicators.emotion.percentile ?? null;
    const beliefPercentile = selectedReportScaleProfile?.indicators.belief.percentile ?? null;
    const metacognitionPercentile = selectedReportScaleProfile?.subscales.metacognition.percentile ?? null;
    const persistencePercentile = selectedReportScaleProfile?.subscales.persistence.percentile ?? null;
    if (emotionPercentile != null) qs.set('emotionPercentile', String(emotionPercentile));
    if (beliefPercentile != null) qs.set('beliefPercentile', String(beliefPercentile));
    if (metacognitionPercentile != null) qs.set('metacognitionPercentile', String(metacognitionPercentile));
    if (persistencePercentile != null) qs.set('persistencePercentile', String(persistencePercentile));
    qs.set('roundNo', '1');
    qs.set('peerSampleN', String(selectedReportPeerSummary.sampleN));
    qs.set('peerSource', selectedReportPeerSummary.source);
    if (selectedReportPeerSummary.avgLevelGrade != null) {
      qs.set('peerAvgLevelGrade', String(selectedReportPeerSummary.avgLevelGrade));
    }
    if (selectedReportPoint.currentLevelGrade != null) {
      qs.set('studentGrade', String(selectedReportPoint.currentLevelGrade));
    }
    const totalWithType = snapshotAxisPoints.filter((p) => p.typeCode !== 'UNCLASSIFIED').length;
    const typeCount = axisTypeCounts[selectedReportPoint.typeCode] ?? 0;
    if (totalWithType > 0) {
      qs.set('typeRatio', String(Math.round((typeCount / totalWithType) * 100)));
    }
    const tAvg = axisTypeAvgGrade[selectedReportPoint.typeCode];
    if (tAvg != null) {
      qs.set('typeAvgGrade', String(tAvg));
    }
    if (Object.keys(selectedReportSubscalePeerGrades).length > 0) {
      qs.set('subscalePeerGrades', JSON.stringify(selectedReportSubscalePeerGrades));
    }
    window.location.href = `/report-preview?${qs.toString()}`;
  }

  const templateEditorPanel = (
    <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel, marginBottom: 14 }}>
      <div style={{ padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, background: tokens.panelAlt }}>
        <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', gap:12 }}>
          <div style={{ fontWeight: 900 }}>유형별 공통 템플릿 편집 (공통 70% + 미세 조정 30%)</div>
          <div style={{ display:'flex', alignItems:'center', gap:8 }}>
            <button
              onClick={resetEditingTemplateToDefault}
              style={{ height:34, padding:'0 10px', borderRadius:8, border:`1px solid ${tokens.border}`, background:'#1E1E1E', color: tokens.textDim, cursor:'pointer' }}
            >
              유형 기본값
            </button>
            <button
              onClick={resetTemplateScaleGuideToDefault}
              style={{ height:34, padding:'0 10px', borderRadius:8, border:`1px solid ${tokens.border}`, background:'#1E1E1E', color: tokens.textDim, cursor:'pointer' }}
            >
              척도 설명 기본값
            </button>
            <button
              onClick={() => { void saveEditingTemplate(); }}
              disabled={templateSaving}
              style={{ height:34, padding:'0 12px', borderRadius:8, border:`1px solid ${tokens.border}`, background: tokens.accent, color:'#fff', cursor:'pointer', opacity: templateSaving ? 0.7 : 1 }}
            >
              {templateSaving ? '저장 중...' : '템플릿 저장'}
            </button>
          </div>
        </div>
      </div>
      <div style={{ padding:'12px 14px' }}>
        <div style={{ display:'flex', flexWrap:'wrap', gap:6, marginBottom: 10 }}>
          {FEEDBACK_TYPE_CODES.map((code) => (
            <button
              key={`template_type_${code}`}
              onClick={() => setEditingTemplateType(code)}
              style={{
                ...chipBaseStyle,
                ...(editingTemplateType === code ? chipActiveStyle : {}),
              }}
            >
              {axisTypeLabel(code)}
            </button>
          ))}
        </div>

        <div style={{ display:'grid', gridTemplateColumns:'1.2fr 1fr', gap:12, marginBottom: 10 }}>
          <div>
            <div style={{ color: tokens.textDim, fontSize:12, marginBottom: 6 }}>템플릿 이름</div>
            <input
              value={editingTemplate?.templateName ?? ''}
              onChange={(e) => updateEditingTemplateName(e.target.value)}
              style={{ width:'100%', height:36, padding:'0 10px', borderRadius:8, border:`1px solid ${tokens.border}`, background: tokens.field, color: tokens.text }}
            />
          </div>
          <div>
            <div style={{ color: tokens.textDim, fontSize:12, marginBottom: 6 }}>마지막 저장 시각</div>
            <div style={{ height:36, display:'flex', alignItems:'center', padding:'0 10px', borderRadius:8, border:`1px solid ${tokens.border}`, background: tokens.field, color: tokens.textDim }}>
              {editingTemplate?.updatedAt ? formatDateTime(editingTemplate.updatedAt) : '저장 이력 없음'}
            </div>
          </div>
        </div>

        <div style={{ marginBottom: 12, border:`1px solid ${tokens.border}`, borderRadius:10, padding:'10px 12px', background: tokens.field }}>
          <div style={{ fontWeight: 800, marginBottom: 6 }}>공통 지표 설명 (메인 2개 + 보조 1개)</div>
          <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 10 }}>
            학생용 피드백에서 감정/신념/학습 방식 구조로 표시됩니다.
          </div>
          <div style={{ display:'grid', gridTemplateColumns:'repeat(3, minmax(0, 1fr))', gap:8 }}>
            {SCALE_GUIDE_INDICATORS.map((indicator) => (
              <div key={`scale_indicator_editor_${indicator.key}`} style={{ border:`1px solid ${tokens.border}`, borderRadius:8, background: tokens.panel, padding:'8px 10px' }}>
                <div style={{ fontWeight: 800, fontSize: 12, marginBottom: 4 }}>{indicator.title}</div>
                <textarea
                  value={templateScaleGuide.indicatorDescriptions[indicator.key]}
                  onChange={(e) => updateTemplateScaleIndicatorDescription(indicator.key, e.target.value)}
                  rows={3}
                  style={{ width:'100%', resize:'vertical', padding:'8px 10px', borderRadius:8, border:`1px solid ${tokens.border}`, background: tokens.field, color: tokens.text, fontFamily:'inherit', fontSize:12, boxSizing:'border-box' }}
                />
              </div>
            ))}
          </div>
        </div>

        <div style={{ marginBottom: 10, border:`1px solid ${tokens.border}`, borderRadius:10, padding:'10px 12px', background: tokens.field }}>
          <div style={{ fontWeight: 800, marginBottom: 6 }}>하위 척도 설명 (13개)</div>
          <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 10 }}>
            각 척도 설명은 학생용 리포트의 세부 카드에 반영됩니다.
          </div>
          <div style={{ display:'grid', gridTemplateColumns:'repeat(2, minmax(0, 1fr))', gap:8 }}>
            {SCALE_GUIDE_SUBSCALES.map((subscale, index) => (
              <div key={`scale_sub_editor_${subscale.key}`} style={{ border:`1px solid ${tokens.border}`, borderRadius:8, background: tokens.panel, padding:'8px 10px' }}>
                <div style={{ fontWeight: 800, fontSize: 12, marginBottom: 4 }}>{index + 1}. {subscale.title}</div>
                <textarea
                  value={templateScaleGuide.subscaleDescriptions[subscale.key]}
                  onChange={(e) => updateTemplateSubscaleDescription(subscale.key, e.target.value)}
                  rows={3}
                  style={{ width:'100%', resize:'vertical', padding:'8px 10px', borderRadius:8, border:`1px solid ${tokens.border}`, background: tokens.field, color: tokens.text, fontFamily:'inherit', fontSize:12, boxSizing:'border-box' }}
                />
              </div>
            ))}
          </div>
        </div>

        {!templateScaleDescriptionAvailable ? (
          <div style={{ color: tokens.danger, fontSize:11, marginBottom: 8 }}>
            DB 마이그레이션 적용 전에는 척도 설명을 저장할 수 없습니다.
          </div>
        ) : null}
        {templateLoading ? (
          <div style={{ color: tokens.textDim, fontSize: 12 }}>템플릿 로드 중...</div>
        ) : null}
        {templateError ? (
          <div style={{ color: tokens.danger, fontSize: 12, marginBottom: 8 }}>{templateError}</div>
        ) : null}
        {(templateDirty[editingTemplateType] || templateCommonDirty) ? (
          <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 8 }}>저장되지 않은 변경 사항이 있습니다.</div>
        ) : null}

        <div style={{ display:'grid', gap:10 }}>
          {editingTemplate?.sections.map((section) => (
            <div key={`template_section_editor_${editingTemplateType}_${section.key}`} style={{ border:`1px solid ${tokens.border}`, borderRadius:10, padding:'10px 12px', background: tokens.field }}>
              <div style={{ fontWeight: 800, marginBottom: 8 }}>{section.title}</div>
              <div style={{ display:'grid', gap:8 }}>
                <div>
                  <div style={{ color: tokens.textDim, fontSize:12, marginBottom:4 }}>공통 70% (common)</div>
                  <textarea
                    value={section.common}
                    onChange={(e) => updateEditingTemplateSection(section.key, 'common', e.target.value)}
                    rows={3}
                    style={{ width:'100%', resize:'vertical', padding:'8px 10px', borderRadius:8, border:`1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, fontFamily:'inherit', fontSize:13, boxSizing:'border-box' }}
                  />
                </div>
                <div>
                  <div style={{ color: tokens.textDim, fontSize:12, marginBottom:4 }}>미세 조정 30% (fine_tune)</div>
                  <textarea
                    value={section.fine_tune}
                    onChange={(e) => updateEditingTemplateSection(section.key, 'fine_tune', e.target.value)}
                    rows={2}
                    style={{ width:'100%', resize:'vertical', padding:'8px 10px', borderRadius:8, border:`1px solid ${tokens.border}`, background: tokens.panel, color: tokens.text, fontFamily:'inherit', fontSize:13, boxSizing:'border-box' }}
                  />
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );

  return (
    <div>
      <div style={{ display:'flex', gap:8, marginBottom: 14 }}>
        <button
          onClick={() => setActiveTab('status')}
          style={{
            ...chipBaseStyle,
            minWidth: 92,
            ...(activeTab === 'status' ? chipActiveStyle : {}),
          }}>
          현황
        </button>
        <button
          onClick={() => setActiveTab('result')}
          style={{
            ...chipBaseStyle,
            minWidth: 92,
            ...(activeTab === 'result' ? chipActiveStyle : {}),
          }}>
          결과
        </button>
        <button
          onClick={() => setActiveTab('report')}
          style={{
            ...chipBaseStyle,
            minWidth: 92,
            ...(activeTab === 'report' ? chipActiveStyle : {}),
          }}>
          리포트
        </button>
      </div>

      {activeTab === 'status' ? (
        <>
      <div style={{ marginBottom: 12 }}>
        <div style={{ fontSize: 18, fontWeight: 900 }}>모니터링</div>
        <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 4 }}>
          누적 데이터 기반 Item_Stats 자동 집계 · 스냅샷 저장 없음 (Rolling)
        </div>
      </div>

      <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel, marginBottom: 14 }}>
        <div style={{ padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, background: tokens.panelAlt }}>
          <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', gap: 12 }}>
            <div style={{ fontWeight: 900 }}>현황 요약</div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>as_of_date · 누적 표본수 포함</div>
          </div>
        </div>
        <div style={{ display:'grid', gridTemplateColumns:'repeat(4, minmax(0, 1fr))', gap:12, padding:'12px 14px' }}>
          <div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>계산 시점</div>
            <div style={{ fontWeight: 800 }}>
              {itemStatsMeta ? formatDateTime(itemStatsMeta.asOfDate) : '-'}
            </div>
          </div>
          <div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>누적 표본수</div>
            <div style={{ fontWeight: 800 }}>
              {itemStatsMeta ? itemStatsMeta.cumulativeParticipants.toLocaleString('ko-KR') : '-'}
            </div>
          </div>
          <div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>누적 응답 수</div>
            <div style={{ fontWeight: 800 }}>
              {itemStatsMeta ? itemStatsMeta.totalAnswers.toLocaleString('ko-KR') : '-'}
            </div>
          </div>
          <div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>문항 수</div>
            <div style={{ fontWeight: 800 }}>
              {itemStats.length ? itemStats.length.toLocaleString('ko-KR') : '-'}
            </div>
          </div>
        </div>
      </div>

      <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'visible', background: tokens.panel, marginBottom: 20 }}>
        <div style={{ padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, background: tokens.panelAlt, position: 'relative', zIndex: 2 }}>
          <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', gap: 12 }}>
            <div style={{ fontWeight: 900 }}>Item_Stats</div>
            <button
              onClick={exportItemStats}
              style={{ height:36, padding:'0 12px', background:'#1E1E1E', border:`1px solid ${tokens.border}`, borderRadius:8, color: tokens.text, cursor:'pointer' }}>
              엑셀 다운로드
            </button>
          </div>
          <div style={{ display:'grid', gridTemplateColumns:'1.6fr auto', gap:8, marginTop: 12 }}>
            <input
              value={filterText}
              onChange={(e)=>setFilterText(e.target.value)}
              placeholder="문항/ID 검색"
              style={{ height:36, padding:'0 10px', background: tokens.field, border:`1px solid ${tokens.border}`, borderRadius:8, color: tokens.text }}
            />
            <button
              onClick={() => {
                setFilterText('');
                setFilterTrait('ALL');
                setFilterType('ALL');
                setFilterRound('ALL');
                setFilterLevelBand('ALL');
              }}
              style={{ height:36, padding:'0 12px', background:'#1E1E1E', border:`1px solid ${tokens.border}`, borderRadius:8, color: tokens.textDim, cursor:'pointer' }}>
              필터 초기화
            </button>
          </div>
          <div style={{ display:'grid', gridTemplateColumns:'1fr', gap:10, marginTop: 12 }}>
            <div>
              <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 6 }}>성향</div>
              <div style={{ display:'flex', flexWrap:'wrap', gap:6 }}>
                <button
                  onClick={() => setFilterTrait('ALL')}
                  style={{ ...chipBaseStyle, ...(filterTrait === 'ALL' ? chipActiveStyle : {}) }}>
                  전체
                </button>
                {traitOptions.map((t) => (
                  <button
                    key={`trait_${t}`}
                    onClick={() => setFilterTrait(t)}
                    style={{ ...chipBaseStyle, ...(filterTrait === t ? chipActiveStyle : {}) }}>
                    {t}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 6 }}>유형</div>
              <div style={{ display:'flex', flexWrap:'wrap', gap:6 }}>
                <button
                  onClick={() => setFilterType('ALL')}
                  style={{ ...chipBaseStyle, ...(filterType === 'ALL' ? chipActiveStyle : {}) }}>
                  전체
                </button>
                {typeOptions.map((t) => (
                  <button
                    key={`type_${t}`}
                    onClick={() => setFilterType(t)}
                    style={{ ...chipBaseStyle, ...(filterType === t ? chipActiveStyle : {}) }}>
                    {formatTypeLabel(t)}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 6 }}>회차</div>
              <div style={{ display:'flex', flexWrap:'wrap', gap:6 }}>
                <button
                  onClick={() => setFilterRound('ALL')}
                  style={{ ...chipBaseStyle, ...(filterRound === 'ALL' ? chipActiveStyle : {}) }}>
                  전체
                </button>
                {roundOptions.map((r) => (
                  <button
                    key={`round_${r}`}
                    onClick={() => setFilterRound(r)}
                    style={{ ...chipBaseStyle, ...(filterRound === r ? chipActiveStyle : {}) }}>
                    {r}
                  </button>
                ))}
              </div>
            </div>
            <div>
              <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 6 }}>현재 수준</div>
              <div style={{ display:'flex', flexWrap:'wrap', gap:6 }}>
                {LEVEL_BAND_OPTIONS.map((opt) => (
                  <button
                    key={`level_band_${opt.code}`}
                    onClick={() => setFilterLevelBand(opt.code)}
                    style={{ ...chipBaseStyle, ...(filterLevelBand === opt.code ? chipActiveStyle : {}) }}>
                    {opt.label} ({levelBandCounts[opt.code] ?? 0})
                  </button>
                ))}
              </div>
            </div>
          </div>
          <div style={{ marginTop: 8, color: tokens.textDim, fontSize: 12 }}>
            {itemStatsLoading
              ? 'Item_Stats 집계 중...'
              : itemStatsError
                ? `Item_Stats 오류: ${itemStatsError}`
                : `표시 ${filteredItemStats.length.toLocaleString('ko-KR')} / ${itemStats.length.toLocaleString('ko-KR')} · 수준 필터: ${selectedLevelBandLabel}`}
          </div>
        </div>
        <div style={{ maxHeight: 480, overflow: 'auto' }}>
          <div style={{ minWidth: 1100 }}>
            <div style={{ display:'grid', gridTemplateColumns:itemGridTemplate, gap:12, padding:'10px 12px', color:tokens.textDim, fontSize:12, background: tokens.panelAlt, borderBottom:`1px solid ${tokens.border}` }}>
              <div>회차</div>
              <div>성향</div>
              <div>유형</div>
              <div>문항</div>
              <div>N</div>
              <div>평균</div>
              <div>SD</div>
              <div>최소</div>
              <div>최대</div>
              <div>평균 응답시간</div>
            </div>
            {itemStatsLoading ? (
              <div style={{ padding:'14px 12px', color: tokens.textDim }}>집계 중...</div>
            ) : itemStatsError ? (
              <div style={{ padding:'14px 12px', color: tokens.danger }}>{itemStatsError}</div>
            ) : filteredItemStats.length ? (
              filteredItemStats.map((item) => (
                <div
                  key={`item_${item.questionId}`}
                  style={{ display:'grid', gridTemplateColumns:itemGridTemplate, gap:12, padding:'10px 12px', borderTop:`1px solid ${tokens.border}`, fontSize:12 }}
                >
                  <div style={{ color: tokens.textDim }}>{formatRoundLabel(item.roundLabel)}</div>
                  <div style={{ color: tokens.textDim }}>{item.trait || '-'}</div>
                  <div style={{ color: tokens.textDim }}>{formatTypeLabel(item.type)}</div>
                  <div style={{ color: tokens.text }} title={item.text}>
                    <div style={{ overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap' }}>{item.text}</div>
                  </div>
                  <div>{item.itemN}</div>
                  <div>{formatNumber(item.mean)}</div>
                  <div>{formatNumber(item.sd)}</div>
                  <div>{formatNumber(item.min, 2)}</div>
                  <div>{formatNumber(item.max, 2)}</div>
                  <div>
                    {item.avgResponseMs != null ? `${formatNumber(item.avgResponseMs, 0)}ms` : '-'}
                  </div>
                </div>
              ))
            ) : (
              <div style={{ padding:'14px 12px', color: tokens.textDim }}>표시할 데이터가 없습니다.</div>
            )}
          </div>
        </div>
      </div>

      <div style={{ marginBottom: 12, fontSize: 18, fontWeight: 900 }}>
        참여자
        <span style={{ marginLeft: 8, color: tokens.textDim, fontSize: 12, fontWeight: 500 }}>
          표시 {filteredRows.length.toLocaleString('ko-KR')} / {rows.length.toLocaleString('ko-KR')} · {selectedLevelBandLabel}
        </span>
      </div>
      <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel }}>
        <div style={{ display:'grid', gridTemplateColumns:'1.2fr 1.4fr 1.6fr 1.5fr 1.2fr 110px', gap:12, padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, color:tokens.textDim, fontSize:13, background: tokens.panelAlt }}>
          <div>참여자</div>
          <div>이메일 · 참여일시</div>
          <div>회차별 진행률</div>
          <div>요약</div>
          <div>현재 수준</div>
          <div>삭제</div>
        </div>
        {filteredRows.map(r => (
          <div
            key={r.id}
            onClick={()=>openDetails(r)}
            style={{
              display:'grid',
              gridTemplateColumns:'1.2fr 1.4fr 1.6fr 1.5fr 1.2fr 110px',
              gap:12,
              padding:'12px 14px',
              borderBottom:`1px solid ${tokens.border}`,
              cursor:'pointer',
            }}
          >
            <div>
              <div style={{ color: tokens.text, fontWeight: 900 }}>{r.name || '-'}</div>
              <div style={{ color: tokens.textDim, marginTop: 4, fontSize: 12 }}>
                {(r.school ?? '-') + ' · ' + (r.level ?? '-') + ' ' + (r.grade ?? '-')}
              </div>
            </div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>
              <div>{r.email || '-'}</div>
              <div style={{ marginTop: 6 }}>참여: {formatDateTime(r.created_at)}</div>
            </div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>
              {(() => {
                const progress = progressByParticipant[r.id] || {};
                const rounds = roundMeta.length ? roundMeta : Object.keys(roundTotals).map((k) => ({ no: Number(k), label: `${k}회차` }));
                if (!rounds.length) return <div>미집계</div>;
                return (
                  <div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      {rounds.map((rMeta) => {
                        const total = roundTotals[rMeta.no] ?? 0;
                        const done = progress[rMeta.no] ?? 0;
                        const ratio = total > 0 ? done / total : 0;
                        const color = ratio >= 1 ? tokens.accent : ratio > 0 ? tokens.textDim : tokens.border;
                        return (
                          <div
                            key={`bar_${r.id}_${rMeta.no}`}
                            style={{ flex: 1, height: 8, borderRadius: 999, background: color, border: `1px solid ${tokens.border}` }}
                          />
                        );
                      })}
                    </div>
                    <div style={{ marginTop: 6 }}>
                      {rounds.map((rMeta) => {
                        const total = roundTotals[rMeta.no] ?? 0;
                        const done = progress[rMeta.no] ?? 0;
                        return (
                          <span key={`label_${r.id}_${rMeta.no}`} style={{ marginRight: 10 }}>
                            {rMeta.label} {done}/{total || '-'}
                          </span>
                        );
                      })}
                    </div>
                  </div>
                );
              })()}
            </div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>
              {(() => {
                const s = traitSumByParticipant[r.id];
                const f = fastStatsByParticipant[r.id];
                const order = ['D','I','A','C','N','L','S','P'];
                if (!s) return '미집계';
                const parts = order
                  .filter(k => s[k] !== undefined)
                  .map(k => `${k} ${Math.round(s[k])}`);
                const fastLabel = f ? `빠름 ${f.fast}/${f.total}` : '빠름 -';
                const avgLabel = f?.avgMs != null ? `평균 ${Math.round(f.avgMs)}ms` : '';
                return parts.length
                  ? [parts.join(' · '), fastLabel, avgLabel].filter(Boolean).join(' · ')
                  : '미집계';
              })()}
            </div>
            <div
              onClick={(e) => e.stopPropagation()}
              style={{ color: tokens.textDim, fontSize: 12 }}
            >
              <select
                value={deriveParticipantBandCode(r.current_level_grade, r.current_math_percentile)}
                onChange={(e) => {
                  const nextCode = e.target.value as Exclude<LevelBandCode, 'ALL'>;
                  void saveCurrentLevelGrade(r.id, nextCode);
                }}
                disabled={savingLevelById[r.id] === true}
                style={{
                  width: '100%',
                  height: 30,
                  padding: '0 8px',
                  borderRadius: 8,
                  border: `1px solid ${tokens.border}`,
                  background: tokens.field,
                  color: tokens.text,
                  cursor: savingLevelById[r.id] ? 'default' : 'pointer',
                  opacity: savingLevelById[r.id] ? 0.6 : 1,
                }}
              >
                {LEVEL_BAND_OPTIONS.filter((opt) => opt.code !== 'ALL').map((opt) => (
                  <option key={`row_level_${r.id}_${opt.code}`} value={opt.code}>
                    {opt.label}
                  </option>
                ))}
              </select>
              <div style={{ marginTop: 6 }}>
                {formatCurrentLevelDisplay(r.current_level_grade, r.current_math_percentile)}
              </div>
              {savingLevelById[r.id] ? (
                <div style={{ marginTop: 4 }}>저장 중...</div>
              ) : null}
              {levelErrorById[r.id] ? (
                <div style={{ marginTop: 4, color: tokens.danger }}>
                  {levelErrorById[r.id]}
                </div>
              ) : null}
            </div>
            <div
              onClick={(e) => e.stopPropagation()}
              style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-end' }}
            >
              <button
                onClick={async()=>{
                  const ok = window.confirm('해당 참여자와 응답을 삭제하시겠습니까? 되돌릴 수 없습니다.');
                  if (!ok) return;
                  try {
                    const { data: resps } = await supabase.from('question_responses').select('id').eq('participant_id', r.id);
                    const ids = (resps as any[]||[]).map(x=>x.id);
                    if (ids.length) {
                      await supabase.from('question_answers').delete().in('response_id', ids);
                      await supabase.from('question_responses').delete().in('id', ids);
                    }
                    await supabase.from('survey_participants').delete().eq('id', r.id);
                    setRows(prev => prev.filter(x => x.id !== r.id));
                  } catch (e) {
                    alert('삭제 실패: ' + ((e as any)?.message || '알 수 없는 오류'));
                  }
                }}
                style={{ width:72, height:36, background:'#2A2A2A', border:`1px solid ${tokens.border}`, borderRadius:8, color:'#ff6b6b', cursor:'pointer' }}>삭제</button>
            </div>
          </div>
        ))}
      </div>

      {selected && (
        <div style={{ marginTop:20, border:`1px solid ${tokens.border}`, borderRadius:12, background: tokens.panel }}>
          <div style={{ padding:12, borderBottom:`1px solid ${tokens.border}`, display:'flex', justifyContent:'space-between', alignItems:'center', gap:12 }}>
            <div>
              <div style={{ fontWeight:900 }}>{selected.name} · 상세 응답</div>
              <div style={{ color: tokens.textDim, fontSize:12, marginTop: 4 }}>
                {(selected.school ?? '-') + ' · ' + (selected.level ?? '-') + ' ' + (selected.grade ?? '-')}
                {' · '}
                {formatCurrentLevelDisplay(selected.current_level_grade, selected.current_math_percentile)}
                {' · '}
                {selected.email || '-'}
                {' · '}
                {formatDateTime(selected.created_at)}
              </div>
              <div style={{ color: tokens.textDim, fontSize:12, marginTop: 4 }}>
                {(() => {
                  const link = round2LinksByParticipant[selected.id];
                  const parts: string[] = [`2차 링크 이메일: ${formatRound2Status(link)}`];
                  if (link?.lastMessageId) parts.push(`Resend ID ${link.lastMessageId}`);
                  if (link?.expiresAt) parts.push(`만료 ${formatDateTime(link.expiresAt)}`);
                  return parts.join(' · ');
                })()}
              </div>
            </div>
          </div>
          <div style={{ maxHeight: 520, overflow: 'auto' }}>
            <div style={{ display:'grid', gridTemplateColumns:'0.45fr 0.7fr 4.1fr 1fr 1fr', gap:12, padding:'10px 12px', color:tokens.textDim, fontSize:13, background: tokens.panelAlt, borderBottom:`1px solid ${tokens.border}` }}>
              <div>No</div><div>성향</div><div>문항</div><div>응답</div><div>응답시간</div>
            </div>
            <div>
              {answers.map((a, i) => (
                <div key={i} style={{ display:'grid', gridTemplateColumns:'0.45fr 0.7fr 4.1fr 1fr 1fr', gap:12, padding:'10px 12px', borderTop:`1px solid ${tokens.border}` }}>
                  <div style={{ color: tokens.textDim }}>{i + 1}</div>
                  <div>{a.question?.trait}</div>
                  <div style={{ color: tokens.text }}>{a.question?.text}</div>
                  <div>{a.answer_number ?? a.answer_text ?? ''}</div>
                  <div style={{ color: tokens.textDim }}>
                    {typeof a.response_ms === 'number'
                      ? `${Math.round(a.response_ms)}ms${a.is_fast ? ' · 빠름' : ''}`
                      : '-'}
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}
        </>
      ) : activeTab === 'result' ? (
        <div>
          <div style={{ marginBottom: 12 }}>
            <div style={{ fontSize: 18, fontWeight: 900 }}>1차 스냅샷 결과 요약</div>
            <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 4 }}>
              round_no=1 · core=questions.trait · supplementary=숫자형 주관식
            </div>
          </div>

          <div style={{ border:`1px solid ${tokens.accent}`, borderRadius:12, background:'rgba(54,141,255,0.10)', padding:'10px 12px', marginBottom: 12 }}>
            <div style={{ fontWeight: 900, marginBottom: 4 }}>해석 프레임 v3 반영됨</div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>
              유형 생성축(감정×신념) + 보정축(메타인지·문제지속성) + 유형-실력 검증 지표를 함께 해석합니다.
              {typeLevelSummaryFileName ? ` · 고급 검증 요약 로드됨: ${typeLevelSummaryFileName}` : ' · (고급 검증 지표는 JSON 업로드 시 표시)'}
            </div>
          </div>

          <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel, marginBottom: 14 }}>
            <div style={{ padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, background: tokens.panelAlt }}>
              <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', gap:12 }}>
                <div style={{ fontWeight: 900 }}>감정 × 신념 참여 분포</div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>
                  x=감정 · y=신념 · 참여 {snapshotAxisPoints.length.toLocaleString('ko-KR')}명
                </div>
              </div>
            </div>
            <div style={{ padding:'12px 14px' }}>
              <div style={{ display:'flex', flexWrap:'wrap', gap:8, marginBottom: 10 }}>
                {(['TYPE_A', 'TYPE_D', 'TYPE_C', 'TYPE_B'] as AxisTypeCode[]).map((code) => (
                  <div
                    key={`axis_count_${code}`}
                    style={{ display:'inline-flex', alignItems:'center', gap:6, border:`1px solid ${tokens.border}`, borderRadius:999, padding:'4px 10px', fontSize:12 }}
                  >
                    <span style={{ width:8, height:8, borderRadius:'50%', background: AXIS_TYPE_COLOR_MAP[code], display:'inline-block' }} />
                    <span>{axisTypeLabel(code)} {axisTypeCounts[code]}명</span>
                  </div>
                ))}
                <div style={{ display:'inline-flex', alignItems:'center', gap:6, border:`1px solid ${tokens.border}`, borderRadius:999, padding:'4px 10px', fontSize:12 }}>
                  <span style={{ width:8, height:8, borderRadius:'50%', background: AXIS_TYPE_COLOR_MAP.UNCLASSIFIED, display:'inline-block' }} />
                  <span>미분류 {axisTypeCounts.UNCLASSIFIED}명</span>
                </div>
              </div>

              <div
                style={{ position:'relative', height: 360, border:`1px solid ${tokens.border}`, borderRadius:10, background: tokens.field, overflow:'hidden' }}
                onMouseLeave={() => setSnapshotAxisHover(null)}
              >
                <div style={{ position:'absolute', left:'50%', top:0, bottom:0, width:1, background: tokens.border }} />
                <div style={{ position:'absolute', top:'50%', left:0, right:0, height:1, background: tokens.border }} />
                <div style={{ position:'absolute', right:10, top:10, fontSize:11, color: tokens.textDim }}>확장형</div>
                <div style={{ position:'absolute', left:10, top:10, fontSize:11, color: tokens.textDim }}>안정형</div>
                <div style={{ position:'absolute', left:10, bottom:10, fontSize:11, color: tokens.textDim }}>회복형</div>
                <div style={{ position:'absolute', right:10, bottom:10, fontSize:11, color: tokens.textDim }}>동기형</div>
                <div style={{ position:'absolute', right:8, top:'calc(50% + 6px)', fontSize:10, color: tokens.textDim }}>감정 +</div>
                <div style={{ position:'absolute', left:'calc(50% + 6px)', top:8, fontSize:10, color: tokens.textDim }}>신념 +</div>

                {!axisPointsWithValues.length ? (
                  <div style={{ position:'absolute', inset:0, display:'flex', alignItems:'center', justifyContent:'center', color: tokens.textDim, fontSize:12 }}>
                    축 분포를 계산할 데이터가 없습니다.
                  </div>
                ) : null}

                {/* KNN 연결선 (SVG 오버레이) */}
                {selectedReportPoint && selectedReportPeerSummary.neighbors.length > 0 && (() => {
                  const anchorX = Math.max(-3, Math.min(3, selectedReportPoint.emotionZ ?? 0));
                  const anchorY = Math.max(-3, Math.min(3, selectedReportPoint.beliefZ ?? 0));
                  const anchorLeft = ((anchorX + 3) / 6) * 100;
                  const anchorTop = (1 - ((anchorY + 3) / 6)) * 100;
                  return (
                    <svg style={{ position:'absolute', inset:0, width:'100%', height:'100%', pointerEvents:'none', zIndex:1 }}>
                      {selectedReportPeerSummary.neighbors.map((nb) => {
                        const nx = Math.max(-3, Math.min(3, nb.emotionZ));
                        const ny = Math.max(-3, Math.min(3, nb.beliefZ));
                        const nLeft = ((nx + 3) / 6) * 100;
                        const nTop = (1 - ((ny + 3) / 6)) * 100;
                        return (
                          <line
                            key={`knn_line_${nb.participantId}`}
                            x1={`${anchorLeft}%`} y1={`${anchorTop}%`}
                            x2={`${nLeft}%`} y2={`${nTop}%`}
                            stroke="rgba(255,255,255,0.35)"
                            strokeWidth={1.5}
                            strokeDasharray="4 3"
                          />
                        );
                      })}
                    </svg>
                  );
                })()}

                {axisPointsWithValues.map((point) => {
                  const x = Math.max(-3, Math.min(3, point.emotionZ ?? 0));
                  const y = Math.max(-3, Math.min(3, point.beliefZ ?? 0));
                  const left = ((x + 3) / 6) * 100;
                  const top = (1 - ((y + 3) / 6)) * 100;
                  const isAnchor = selectedReportPoint?.participantId === point.participantId;
                  const knnNeighbor = selectedReportPeerSummary.neighbors.find((nb) => nb.participantId === point.participantId);
                  const isKnnNeighbor = !!knnNeighbor;
                  const dotSize = isAnchor ? 16 : isKnnNeighbor ? 14 : 10;
                  return (
                    <div
                      key={`axis_point_${point.participantId}`}
                      title={`${point.participantName} · ${axisTypeLabel(point.typeCode)} · 감정 ${formatNumber(point.emotionZ)} / 신념 ${formatNumber(point.beliefZ)} · 메타인지 ${formatNumber(point.metacognitionZ)} / 지속성 ${formatNumber(point.persistenceZ)}${isKnnNeighbor ? ` · KNN거리 ${knnNeighbor.distance.toFixed(3)} · ${knnNeighbor.levelGrade}등급` : ''}`}
                      onMouseEnter={(e) => {
                        const rect = (e.currentTarget.parentElement as HTMLDivElement | null)?.getBoundingClientRect();
                        if (!rect) return;
                        setSnapshotAxisHover({
                          point,
                          x: e.clientX - rect.left,
                          y: e.clientY - rect.top,
                          width: rect.width,
                          height: rect.height,
                        });
                      }}
                      onMouseMove={(e) => {
                        const rect = (e.currentTarget.parentElement as HTMLDivElement | null)?.getBoundingClientRect();
                        if (!rect) return;
                        setSnapshotAxisHover({
                          point,
                          x: e.clientX - rect.left,
                          y: e.clientY - rect.top,
                          width: rect.width,
                          height: rect.height,
                        });
                      }}
                      onMouseLeave={() => setSnapshotAxisHover(null)}
                      style={{
                        position:'absolute',
                        left:`calc(${left}% - ${dotSize / 2}px)`,
                        top:`calc(${top}% - ${dotSize / 2}px)`,
                        width: dotSize,
                        height: dotSize,
                        borderRadius:'50%',
                        background: AXIS_TYPE_COLOR_MAP[point.typeCode],
                        border: isAnchor
                          ? '3px solid #fff'
                          : isKnnNeighbor
                            ? '2.5px solid rgba(255,255,255,0.9)'
                            : '1px solid rgba(0,0,0,0.25)',
                        opacity: isAnchor || isKnnNeighbor ? 1 : 0.55,
                        zIndex: isAnchor ? 4 : isKnnNeighbor ? 3 : 2,
                        boxShadow: isAnchor
                          ? '0 0 0 3px rgba(255,255,255,0.3), 0 2px 8px rgba(0,0,0,0.4)'
                          : isKnnNeighbor
                            ? '0 0 0 2px rgba(255,255,255,0.2), 0 1px 4px rgba(0,0,0,0.3)'
                            : 'none',
                        cursor: 'pointer',
                      }}
                    />
                  );
                })}

                {snapshotAxisHover ? (
                  <div
                    style={{
                      position:'absolute',
                      left: Math.min(
                        Math.max(snapshotAxisHover.x + 10, 8),
                        Math.max(snapshotAxisHover.width - 220, 8),
                      ),
                      top: Math.min(
                        Math.max(snapshotAxisHover.y + 10, 8),
                        Math.max(snapshotAxisHover.height - 72, 8),
                      ),
                      minWidth: 190,
                      maxWidth: 240,
                      border:`1px solid ${tokens.border}`,
                      borderRadius:8,
                      background:'rgba(10,10,10,0.92)',
                      color: tokens.text,
                      padding:'8px 10px',
                      fontSize:12,
                      pointerEvents:'none',
                      zIndex: 10,
                      boxShadow: '0 6px 20px rgba(0,0,0,0.35)',
                    }}
                  >
                    <div style={{ fontWeight: 800, marginBottom: 2 }}>
                      {snapshotAxisHover.point.participantName}
                      {selectedReportPoint?.participantId === snapshotAxisHover.point.participantId && (
                        <span style={{ marginLeft: 6, fontSize: 10, color: '#FFD54F', fontWeight: 600 }}>● 선택됨</span>
                      )}
                    </div>
                    <div style={{ color: tokens.textDim }}>
                      {axisTypeLabel(snapshotAxisHover.point.typeCode)} · 감정 {formatNumber(snapshotAxisHover.point.emotionZ)} · 신념 {formatNumber(snapshotAxisHover.point.beliefZ)}
                    </div>
                    <div style={{ color: tokens.textDim, marginTop: 2 }}>
                      보정: 메타인지 {formatNumber(snapshotAxisHover.point.metacognitionZ)} · 지속성 {formatNumber(snapshotAxisHover.point.persistenceZ)}
                    </div>
                    {(() => {
                      const nb = selectedReportPeerSummary.neighbors.find((n) => n.participantId === snapshotAxisHover.point.participantId);
                      if (!nb) return null;
                      return (
                        <div style={{ marginTop: 4, padding:'3px 6px', background:'rgba(255,255,255,0.08)', borderRadius: 4, fontSize: 11 }}>
                          <span style={{ color: '#81C784' }}>KNN 이웃</span>
                          {' · '}거리 {nb.distance.toFixed(3)} · {nb.levelGrade}등급
                        </div>
                      );
                    })()}
                  </div>
                ) : null}
              </div>

              {/* KNN 이웃 상세 패널 */}
              {selectedReportPoint && selectedReportPeerSummary.neighbors.length > 0 && (
                <div style={{ marginTop: 10, border:`1px solid ${tokens.border}`, borderRadius: 8, overflow:'hidden' }}>
                  <div style={{ padding:'8px 12px', background: tokens.panelAlt, borderBottom:`1px solid ${tokens.border}` }}>
                    <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between' }}>
                      <div style={{ fontSize: 12, fontWeight: 700 }}>
                        KNN 이웃 상세 (K={selectedReportPeerSummary.sampleN})
                        <span style={{ fontWeight: 400, color: tokens.textDim, marginLeft: 8 }}>
                          {selectedReportPoint.participantName} 기준
                        </span>
                      </div>
                      <div style={{ fontSize: 12, fontWeight: 700, color: tokens.accent }}>
                        보정 {selectedReportPeerSummary.avgLevelGrade?.toFixed(1)}등급
                      </div>
                    </div>
                    {selectedReportPeerSummary.knnRawAvg != null && selectedReportPeerSummary.typeAvg != null && (
                      <div style={{ display:'flex', alignItems:'center', gap: 6, marginTop: 6, fontSize: 11, color: tokens.textDim, flexWrap:'wrap' }}>
                        <span>유형보정 (KNN {selectedReportPeerSummary.knnRawAvg.toFixed(2)}×{selectedReportPeerSummary.sampleN} + {axisTypeLabel(selectedReportPoint.typeCode)} {selectedReportPeerSummary.typeAvg.toFixed(2)}×{PEER_SHRINKAGE_PRIOR}) ÷ {selectedReportPeerSummary.sampleN + PEER_SHRINKAGE_PRIOR}</span>
                        {selectedReportPeerSummary.adjustmentDelta != null && (
                          <>
                            <span style={{ color: tokens.textDim }}>→</span>
                            <span>
                              보조지표 {selectedReportPeerSummary.adjustmentDelta > 0 ? '+' : ''}{selectedReportPeerSummary.adjustmentDelta.toFixed(2)}
                              <span style={{ marginLeft: 4, opacity: 0.7 }}>
                                (r<sub>메타</sub>={adjustmentGradeCorr.metaCorr.toFixed(2)}, r<sub>지속</sub>={adjustmentGradeCorr.persistCorr.toFixed(2)})
                              </span>
                            </span>
                          </>
                        )}
                        <span style={{ color: tokens.textDim }}>=</span>
                        <span style={{ fontWeight: 700, color: tokens.accent }}>{selectedReportPeerSummary.avgLevelGrade?.toFixed(2)}</span>
                      </div>
                    )}
                  </div>
                  <div style={{ padding:'6px 12px' }}>
                    <div style={{ display:'grid', gridTemplateColumns:'minmax(60px,auto) repeat(4, 1fr)', gap:'2px 8px', fontSize: 11, color: tokens.textDim, padding:'4px 0', borderBottom:`1px solid ${tokens.border}` }}>
                      <div style={{ fontWeight: 600 }}>이름</div>
                      <div style={{ fontWeight: 600, textAlign:'right' }}>감정Z</div>
                      <div style={{ fontWeight: 600, textAlign:'right' }}>신념Z</div>
                      <div style={{ fontWeight: 600, textAlign:'right' }}>거리</div>
                      <div style={{ fontWeight: 600, textAlign:'right' }}>등급</div>
                    </div>
                    {selectedReportPeerSummary.neighbors.map((nb, idx) => (
                      <div
                        key={`knn_row_${nb.participantId}`}
                        style={{ display:'grid', gridTemplateColumns:'minmax(60px,auto) repeat(4, 1fr)', gap:'2px 8px', fontSize: 11, padding:'4px 0', borderBottom: idx < selectedReportPeerSummary.neighbors.length - 1 ? `1px solid ${tokens.border}` : 'none' }}
                      >
                        <div style={{ fontWeight: 600, display:'flex', alignItems:'center', gap: 4 }}>
                          <span style={{ width: 6, height: 6, borderRadius:'50%', background:'rgba(255,255,255,0.9)', border:'1.5px solid rgba(255,255,255,0.5)', flexShrink:0 }} />
                          {nb.participantName}
                        </div>
                        <div style={{ textAlign:'right', color: tokens.textDim }}>{nb.emotionZ.toFixed(2)}</div>
                        <div style={{ textAlign:'right', color: tokens.textDim }}>{nb.beliefZ.toFixed(2)}</div>
                        <div style={{ textAlign:'right', color: tokens.textDim }}>{nb.distance.toFixed(3)}</div>
                        <div style={{ textAlign:'right', fontWeight: 700 }}>{nb.levelGrade}</div>
                      </div>
                    ))}
                    <div style={{ display:'grid', gridTemplateColumns:'minmax(60px,auto) repeat(4, 1fr)', gap:'2px 8px', fontSize: 11, padding:'5px 0 3px', borderTop:`1px solid ${tokens.border}`, marginTop: 2 }}>
                      <div style={{ fontWeight: 600, color: tokens.accent }}>
                        기준 학생
                      </div>
                      <div style={{ textAlign:'right', color: tokens.accent, fontWeight: 600 }}>{(selectedReportPoint.emotionZ ?? 0).toFixed(2)}</div>
                      <div style={{ textAlign:'right', color: tokens.accent, fontWeight: 600 }}>{(selectedReportPoint.beliefZ ?? 0).toFixed(2)}</div>
                      <div style={{ textAlign:'right', color: tokens.textDim }}>—</div>
                      <div style={{ textAlign:'right', fontWeight: 700, color: tokens.accent }}>{selectedReportPoint.currentLevelGrade ?? '—'}</div>
                    </div>
                  </div>
                </div>
              )}

              <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 8 }}>
                해석 프레임 v3 · 유형축(감정/신념) 사용 태그/문항: 감정 {snapshotAxisMeta.emotionScaleNames.length ? snapshotAxisMeta.emotionScaleNames.join(', ') : '-'}
                {' · '}
                신념 {snapshotAxisMeta.beliefScaleNames.length ? snapshotAxisMeta.beliefScaleNames.join(', ') : '-'}
              </div>
              <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 4 }}>
                보정축(유형 미사용): 메타인지 {snapshotAxisMeta.metacognitionLabels.length ? snapshotAxisMeta.metacognitionLabels.join(', ') : '-'}
                {' · '}
                문제지속성 {snapshotAxisMeta.persistenceLabels.length ? snapshotAxisMeta.persistenceLabels.join(', ') : '-'}
              </div>
            </div>
          </div>

          <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel, marginBottom: 14 }}>
            <div style={{ padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, background: tokens.panelAlt }}>
              <div style={{ fontWeight: 900 }}>스냅샷 메타</div>
            </div>
            <div style={{ display:'grid', gridTemplateColumns:'repeat(6, minmax(0, 1fr))', gap:12, padding:'12px 14px' }}>
              <div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>버전</div>
                <div style={{ fontWeight: 800 }}>v1.0</div>
              </div>
              <div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>계산 시점</div>
                <div style={{ fontWeight: 800 }}>
                  {snapshotMeta ? formatDateTime(snapshotMeta.asOfDate) : '-'}
                </div>
              </div>
              <div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>표본수 (N)</div>
                <div style={{ fontWeight: 800 }}>
                  {snapshotMeta ? snapshotMeta.totalN.toLocaleString('ko-KR') : '-'}
                </div>
              </div>
              <div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>Scale 수</div>
                <div style={{ fontWeight: 800 }}>
                  {snapshotMeta ? snapshotMeta.scaleCount.toLocaleString('ko-KR') : '-'}
                </div>
              </div>
              <div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>Core 문항 수</div>
                <div style={{ fontWeight: 800 }}>
                  {snapshotMeta ? snapshotMeta.coreItemCount.toLocaleString('ko-KR') : '-'}
                </div>
              </div>
              <div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>보조 문항 수</div>
                <div style={{ fontWeight: 800 }}>
                  {snapshotMeta ? snapshotMeta.supplementaryItemCount.toLocaleString('ko-KR') : '-'}
                </div>
              </div>
            </div>
          </div>

          <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel }}>
            <div style={{ padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, background: tokens.panelAlt }}>
              <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', gap: 12 }}>
                <div style={{ fontWeight: 900 }}>Scale_Stats_Snapshot_v1</div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>
                  {snapshotMeta
                    ? `Core ${snapshotMeta.coreItemCount} + 보조 ${snapshotMeta.supplementaryItemCount} = 총 ${snapshotMeta.totalItemCount} · Cronbach α는 complete-case 기준`
                    : 'Cronbach α는 complete-case 기준'}
                </div>
              </div>
            </div>
            <div style={{ maxHeight: 520, overflow: 'auto' }}>
              <div style={{ minWidth: 1050 }}>
                <div style={{ display:'grid', gridTemplateColumns:snapshotGridTemplate, gap:12, padding:'10px 12px', color:tokens.textDim, fontSize:12, background: tokens.panelAlt, borderBottom:`1px solid ${tokens.border}` }}>
                  <div>Scale</div>
                  <div>문항 수</div>
                  <div>평균</div>
                  <div>SD</div>
                  <div>최소</div>
                  <div>최대</div>
                  <div>N</div>
                  <div>Cronbach α</div>
                  <div>alpha N</div>
                </div>
                {snapshotLoading ? (
                  <div style={{ padding:'14px 12px', color: tokens.textDim }}>Scale_Stats 계산 중...</div>
                ) : snapshotError ? (
                  <div style={{ padding:'14px 12px', color: tokens.danger }}>{snapshotError}</div>
                ) : snapshotScaleStats.length ? (
                  snapshotScaleStats.map((item) => (
                    <div
                      key={`snapshot_scale_${item.scaleName}`}
                      style={{ display:'grid', gridTemplateColumns:snapshotGridTemplate, gap:12, padding:'10px 12px', borderTop:`1px solid ${tokens.border}`, fontSize:12 }}
                    >
                      <div style={{ color: tokens.text }}>{item.scaleName}</div>
                      <div>{item.itemCount}</div>
                      <div>{formatNumber(item.mean)}</div>
                      <div>{formatNumber(item.sd)}</div>
                      <div>{formatNumber(item.min)}</div>
                      <div>{formatNumber(item.max)}</div>
                      <div>{item.nRespondents}</div>
                      <div>{formatNumber(item.alpha, 3)}</div>
                      <div>{item.alphaNComplete}</div>
                    </div>
                  ))
                ) : (
                  <div style={{ padding:'14px 12px', color: tokens.textDim }}>표시할 스냅샷 데이터가 없습니다.</div>
                )}
              </div>
            </div>
          </div>

          <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel, marginTop: 14 }}>
            <div style={{ padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, background: tokens.panelAlt }}>
              <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', gap: 12 }}>
                <div style={{ fontWeight: 900 }}>Subjective_Numeric_Supplementary</div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>
                  기준선 미포함 · 보조 통계만 제공
                </div>
              </div>
            </div>
            <div style={{ maxHeight: 360, overflow: 'auto' }}>
              <div style={{ minWidth: 920 }}>
                <div style={{ display:'grid', gridTemplateColumns:snapshotSubjectiveGridTemplate, gap:12, padding:'10px 12px', color:tokens.textDim, fontSize:12, background: tokens.panelAlt, borderBottom:`1px solid ${tokens.border}` }}>
                  <div>문항</div>
                  <div>N</div>
                  <div>평균</div>
                  <div>SD</div>
                  <div>최소</div>
                  <div>최대</div>
                </div>
                {snapshotLoading ? (
                  <div style={{ padding:'14px 12px', color: tokens.textDim }}>보조 지표 계산 중...</div>
                ) : snapshotError ? (
                  <div style={{ padding:'14px 12px', color: tokens.danger }}>{snapshotError}</div>
                ) : snapshotSubjectiveStats.length ? (
                  snapshotSubjectiveStats.map((item) => (
                    <div
                      key={`snapshot_subjective_${item.questionId}`}
                      style={{ display:'grid', gridTemplateColumns:snapshotSubjectiveGridTemplate, gap:12, padding:'10px 12px', borderTop:`1px solid ${tokens.border}`, fontSize:12 }}
                    >
                      <div style={{ color: tokens.text }}>{item.text}</div>
                      <div>{item.itemN}</div>
                      <div>{formatNumber(item.mean)}</div>
                      <div>{formatNumber(item.sd)}</div>
                      <div>{formatNumber(item.min)}</div>
                      <div>{formatNumber(item.max)}</div>
                    </div>
                  ))
                ) : (
                  <div style={{ padding:'14px 12px', color: tokens.textDim }}>보조 문항 데이터가 없습니다.</div>
                )}
              </div>
            </div>
          </div>

          <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel, marginTop: 14 }}>
            <div style={{ padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, background: tokens.panelAlt }}>
              <div style={{ fontWeight: 900 }}>고급 검증 요약(JSON) 연동</div>
            </div>
            <div style={{ padding:'12px 14px', display:'grid', gap:8 }}>
              <div style={{ color: tokens.textDim, fontSize: 12 }}>
                `type_level_validation_summary_v1.json` 파일을 업로드하면 p-value/효과크기/CV 지표가 함께 표시됩니다.
              </div>
              <div style={{ display:'flex', flexWrap:'wrap', alignItems:'center', gap:8 }}>
                <label style={{ display:'inline-flex', alignItems:'center', height:34, padding:'0 12px', borderRadius:8, border:`1px solid ${tokens.border}`, background:'#1E1E1E', color: tokens.text, cursor:'pointer' }}>
                  JSON 불러오기
                  <input
                    type="file"
                    accept=".json,application/json"
                    onChange={handleTypeLevelSummaryFileChange}
                    style={{ display:'none' }}
                  />
                </label>
                <button
                  onClick={clearTypeLevelSummary}
                  style={{ height:34, padding:'0 12px', borderRadius:8, border:`1px solid ${tokens.border}`, background: tokens.field, color: tokens.textDim, cursor:'pointer' }}
                >
                  불러온 요약 지우기
                </button>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>
                  {typeLevelSummaryFileName ? `적용 파일: ${typeLevelSummaryFileName}` : '적용된 요약 파일 없음'}
                </div>
              </div>
              {typeLevelSummaryError ? (
                <div style={{ color: tokens.danger, fontSize: 12 }}>{typeLevelSummaryError}</div>
              ) : null}
            </div>
          </div>

          <div style={{ marginTop: 14 }}>
            <TypeLevelValidationPanel
              axisPoints={snapshotAxisPoints}
              asOfDate={snapshotMeta?.asOfDate ?? null}
              validationSummary={typeLevelSummary}
            />
          </div>
        </div>
      ) : (
        <div>
          <div style={{ marginBottom: 12 }}>
            <div style={{ fontSize: 18, fontWeight: 900 }}>유형 리포트</div>
            <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 4 }}>
              학생용 우선 · 교사용 보조 · 유형=감정×신념 · 보정=메타인지/문제지속성 · 해석 프레임 v3
            </div>
          </div>

          <div style={{ border:`1px solid ${tokens.accent}`, borderRadius:12, background:'rgba(54,141,255,0.10)', padding:'10px 12px', marginBottom: 12 }}>
            <div style={{ fontWeight: 900, marginBottom: 4 }}>리포트 UI v3 적용됨</div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>
              해석 가이드(3개 질문), 인과 경계 문구, 유형-실력 검증 요약 패널, 학습 보정축 표시가 함께 적용되었습니다.
            </div>
          </div>

          <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel, marginBottom: 14 }}>
            <div style={{ padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, background: tokens.panelAlt }}>
              <div style={{ fontWeight: 900 }}>해석 프레임 가이드</div>
            </div>
            <div style={{ padding:'12px 14px', display:'grid', gap: 10 }}>
              <div style={{ color: tokens.textDim, fontSize: 12 }}>
                리포트 해석은 아래 3개 질문을 기준으로 정리합니다.
              </div>
              <div style={{ display:'grid', gridTemplateColumns:'repeat(3, minmax(0, 1fr))', gap:8 }}>
                {INTERPRETATION_FRAME_GUIDE_QUESTIONS.map((q) => (
                  <div key={`interp_q_${q}`} style={{ border:`1px solid ${tokens.border}`, borderRadius:8, padding:'8px 10px', background: tokens.field, fontSize:12 }}>
                    {q}
                  </div>
                ))}
              </div>
              <div style={{ display:'grid', gap:6 }}>
                {INTERPRETATION_FRAME_GUARDRAILS.map((rule) => (
                  <div key={`interp_rule_${rule}`} style={{ color: tokens.textDim, fontSize: 12 }}>
                    - {rule}
                  </div>
                ))}
              </div>
              <div style={{ display:'flex', flexWrap:'wrap', alignItems:'center', gap:8 }}>
                <label style={{ display:'inline-flex', alignItems:'center', height:32, padding:'0 10px', borderRadius:8, border:`1px solid ${tokens.border}`, background:'#1E1E1E', color: tokens.text, cursor:'pointer', fontSize:12 }}>
                  검증 요약 JSON 불러오기
                  <input
                    type="file"
                    accept=".json,application/json"
                    onChange={handleTypeLevelSummaryFileChange}
                    style={{ display:'none' }}
                  />
                </label>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>
                  {typeLevelSummaryFileName ? `적용됨: ${typeLevelSummaryFileName}` : '미적용'}
                </div>
              </div>
              {typeLevelSummaryError ? (
                <div style={{ color: tokens.danger, fontSize: 12 }}>{typeLevelSummaryError}</div>
              ) : null}
            </div>
          </div>

          {templateEditorPanel}

          <div style={{ marginBottom: 14 }}>
            <TypeLevelValidationPanel
              axisPoints={snapshotAxisPoints}
              asOfDate={snapshotMeta?.asOfDate ?? null}
              compact
              validationSummary={typeLevelSummary}
            />
          </div>

          <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel, marginBottom: 14 }}>
            <div style={{ padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, background: tokens.panelAlt }}>
              <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', gap:12 }}>
                <div style={{ fontWeight: 900 }}>학생용 리포트 (우선)</div>
                <button
                  onClick={openReportPreview}
                  style={{ height:34, padding:'0 12px', borderRadius:8, border:`1px solid ${tokens.border}`, background:'#1E1E1E', color: tokens.text, cursor:'pointer' }}
                >
                  미리보기
                </button>
              </div>
            </div>
            <div style={{ padding:'12px 14px' }}>
              <div style={{ display:'grid', gridTemplateColumns:'1.3fr 2.7fr', gap:12 }}>
                <div>
                  <input
                    value={reportSearchKeyword}
                    onChange={(e) => setReportSearchKeyword(e.target.value)}
                    placeholder="학생 이름/ID 검색"
                    style={{ width:'100%', height:36, padding:'0 10px', background: tokens.field, border:`1px solid ${tokens.border}`, borderRadius:8, color: tokens.text }}
                  />
                  <div style={{ marginTop: 8, maxHeight: 320, overflow:'auto', display:'grid', gap:6 }}>
                    {reportCandidatePoints.length ? reportCandidatePoints.slice(0, 80).map((point) => (
                      <button
                        key={`report_candidate_${point.participantId}`}
                        onClick={() => setSelectedReportParticipantId(point.participantId)}
                        style={{
                          textAlign:'left',
                          height:34,
                          padding:'0 10px',
                          borderRadius:8,
                          border:`1px solid ${tokens.border}`,
                          background: selectedReportParticipantId === point.participantId ? tokens.accent : tokens.field,
                          color: selectedReportParticipantId === point.participantId ? '#FFFFFF' : tokens.text,
                          cursor:'pointer',
                          fontSize:12,
                        }}
                      >
                        {point.participantName}
                        <span style={{ color: selectedReportParticipantId === point.participantId ? 'rgba(255,255,255,0.85)' : tokens.textDim, marginLeft: 6 }}>
                          ({axisTypeLabel(point.typeCode)})
                        </span>
                      </button>
                    )) : (
                      <div style={{ color: tokens.textDim, fontSize:12, padding:'8px 2px' }}>검색 결과가 없습니다.</div>
                    )}
                  </div>
                </div>

                <div style={{ border:`1px solid ${tokens.border}`, borderRadius:10, padding:'12px 14px', background: tokens.field }}>
                  {!selectedReportPoint ? (
                    <div style={{ color: tokens.textDim, fontSize: 12 }}>리포트를 볼 학생을 선택해 주세요.</div>
                  ) : (
                    <>
                      <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', gap:10, marginBottom: 10 }}>
                        <div>
                          <div style={{ fontSize: 16, fontWeight: 900 }}>{selectedReportPoint.participantName}</div>
                          <div style={{ color: tokens.textDim, fontSize:12, marginTop:4 }}>
                            {formatCurrentLevelDisplay(selectedReportPoint.currentLevelGrade, selectedReportPoint.currentMathPercentile)}
                          </div>
                        </div>
                        <div style={{ display:'inline-flex', alignItems:'center', gap:6, border:`1px solid ${tokens.border}`, borderRadius:999, padding:'4px 10px', fontSize:12 }}>
                          <span style={{ width:8, height:8, borderRadius:'50%', background: AXIS_TYPE_COLOR_MAP[selectedReportPoint.typeCode], display:'inline-block' }} />
                          <span>{axisTypeLabel(selectedReportPoint.typeCode)}</span>
                        </div>
                      </div>

                      <div style={{ marginTop: 4, display:'grid', gap:10 }}>
                        {SCALE_GUIDE_INDICATORS.map((indicator) => {
                          const indicatorMetric = selectedReportScaleProfile?.indicators[indicator.key] ?? emptyMetricValue();
                          const indicatorColor = (
                            indicator.key === 'emotion'
                              ? '#F59E0B'
                              : indicator.key === 'belief'
                                ? '#60A5FA'
                                : '#34D399'
                          );
                          const indicatorPct = indicatorMetric.percentile ?? 0;
                          const relatedSubscales = SCALE_GUIDE_SUBSCALES.filter(
                            (subscale) => subscale.indicatorKey === indicator.key,
                          );
                          return (
                            <div key={`report_indicator_card_${indicator.key}`} style={{ border:`1px solid ${tokens.border}`, borderRadius:8, padding:'10px 12px', background: tokens.panel }}>
                              <div style={{ display:'flex', alignItems:'flex-start', justifyContent:'space-between', gap:8 }}>
                                <div>
                                  <div style={{ fontWeight: 900, fontSize: 13 }}>{indicator.title}</div>
                                  <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 4 }}>
                                    {templateScaleGuide.indicatorDescriptions[indicator.key]}
                                  </div>
                                </div>
                                <div style={{ textAlign:'right', fontSize: 12 }}>
                                  <div>점수 {formatNumber(indicatorMetric.score)}</div>
                                  <div style={{ color: tokens.textDim, marginTop: 2 }}>
                                    전체 위치 {formatPercentileLabel(indicatorMetric.percentile)}
                                  </div>
                                </div>
                              </div>

                              <div style={{ marginTop: 8, height:8, borderRadius:999, background:'#2A2A2A', overflow:'hidden' }}>
                                <div style={{ width:`${indicatorPct}%`, height:'100%', background: indicatorColor }} />
                              </div>

                              <div style={{ marginTop: 10, display:'grid', gap:8 }}>
                                {relatedSubscales.map((subscale) => {
                                  const metric = selectedReportScaleProfile?.subscales[subscale.key] ?? emptyMetricValue();
                                  const subscalePct = metric.percentile ?? 0;
                                  const subscaleIndex = SCALE_GUIDE_SUBSCALES.findIndex((item) => item.key === subscale.key) + 1;
                                  return (
                                    <div key={`report_subscale_card_${selectedReportPoint.participantId}_${subscale.key}`} style={{ border:`1px solid ${tokens.border}`, borderRadius:8, padding:'8px 10px', background: tokens.field }}>
                                      <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', gap:8 }}>
                                        <div style={{ fontWeight: 800, fontSize: 12 }}>{subscaleIndex}. {subscale.title}</div>
                                        <div style={{ color: tokens.textDim, fontSize: 11 }}>
                                          {formatNumber(metric.score)}점 · {formatPercentileLabel(metric.percentile)}
                                        </div>
                                      </div>
                                      <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 4, whiteSpace:'pre-wrap' }}>
                                        {templateScaleGuide.subscaleDescriptions[subscale.key]}
                                      </div>
                                      <div style={{ marginTop: 6, height:6, borderRadius:999, background:'#2A2A2A', overflow:'hidden' }}>
                                        <div style={{ width:`${subscalePct}%`, height:'100%', background: indicatorColor }} />
                                      </div>
                                    </div>
                                  );
                                })}
                              </div>
                            </div>
                          );
                        })}
                      </div>

                      {selectedReportTemplate ? (
                        <div style={{ marginTop: 12, display:'grid', gap:10 }}>
                          {selectedReportTemplate.sections.map((section) => (
                            <div
                              key={`student_section_${selectedReportPoint.participantId}_${section.key}`}
                              style={{ border:`1px solid ${tokens.border}`, borderRadius:8, padding:'10px 12px', background: tokens.panel }}
                            >
                              <div style={{ fontWeight: 800, fontSize: 13, marginBottom: 6 }}>{section.title}</div>
                              <div style={{ whiteSpace:'pre-wrap', color: tokens.text, fontSize: 13 }}>
                                {combineSectionText(section) || '내용을 입력해 주세요.'}
                              </div>
                            </div>
                          ))}
                        </div>
                      ) : (
                        <div style={{ marginTop: 12, color: tokens.textDim, fontSize: 12 }}>
                          축 계산에 필요한 응답이 부족하여 유형을 확정할 수 없습니다.
                        </div>
                      )}
                    </>
                  )}
                </div>
              </div>
            </div>
          </div>

          <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel, marginBottom: 14 }}>
            <div style={{ padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, background: tokens.panelAlt }}>
              <div style={{ fontWeight: 900 }}>교사용 리포트</div>
            </div>
            <div style={{ padding:'12px 14px' }}>
              {!selectedReportPoint || !selectedReportTemplate ? (
                <div style={{ color: tokens.textDim, fontSize: 12 }}>
                  유형이 확정된 학생을 선택하면 교사용 전략이 표시됩니다.
                </div>
              ) : (
                <div style={{ display:'grid', gap:10 }}>
                  <div style={{ color: tokens.textDim, fontSize: 12 }}>
                    유형: {axisTypeLabel(selectedReportPoint.typeCode)} · 편집 템플릿: {selectedReportTemplate.templateName || '-'}
                  </div>
                  <div style={{ color: tokens.textDim, fontSize: 12 }}>
                    보정축: 메타인지 {formatNumber(selectedReportPoint.metacognitionZ)} ({adjustmentLevelLabel(selectedReportPoint.metacognitionZ)}) ·
                    {' '}
                    문제지속성 {formatNumber(selectedReportPoint.persistenceZ)} ({adjustmentLevelLabel(selectedReportPoint.persistenceZ)})
                  </div>
                  {FEEDBACK_SECTION_DEFINITIONS.map((def) => (
                    <div
                      key={`teacher_section_${selectedReportPoint.participantId}_${def.key}`}
                      style={{ border:`1px solid ${tokens.border}`, borderRadius:8, padding:'10px 12px', background: tokens.field }}
                    >
                      <div style={{ fontWeight: 800, fontSize: 13, marginBottom: 6 }}>{def.title}</div>
                      <div style={{ whiteSpace:'pre-wrap', fontSize:13 }}>
                        {selectedReportSectionsByKey[def.key] || '내용을 입력해 주세요.'}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>

        </div>
      )}
    </div>
  );
}



