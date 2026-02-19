import React from 'react';
import { supabase } from '../lib/supabaseClient';
import { tokens } from '../theme';
import {
  buildCautionsText,
  buildCoreStrengthsText,
  buildGrowthCheckpointText,
  buildLearningTraitsText,
  buildProfileSummaryText,
  buildTeachingStrategyText,
  combineSectionText,
  cloneScaleGuideTemplate,
  cloneFeedbackTemplate,
  DEFAULT_FEEDBACK_TEMPLATES,
  DEFAULT_SCALE_GUIDE_TEMPLATE,
  FEEDBACK_COLOR_LEGEND,
  FEEDBACK_TYPE_CODES,
  FeedbackTemplate,
  FeedbackTypeCode,
  getIntensityLevel,
  getSectionSummary,
  getSubscaleFeedback,
  getTypeKeywords,
  mergeTemplateSections,
  parseScaleGuideTemplate,
  SCALE_GUIDE_INDICATORS,
  SCALE_GUIDE_SUBSCALES,
  ScaleGuideTemplate,
} from '../lib/traitFeedbackTemplates';

type ParticipantMeta = {
  id: string;
  name: string;
  school: string | null;
  grade: string | null;
};

type ReportMetricValue = {
  score: number | null;
  percentile: number | null;
};

type ParticipantScaleProfile = {
  indicators: Record<'emotion' | 'belief' | 'learning_style', ReportMetricValue>;
  subscales: Record<
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
    | 'persistence',
    ReportMetricValue
  >;
};

function parseTypeCode(value: string | null): FeedbackTypeCode | null {
  const raw = String(value ?? '').trim();
  if ((FEEDBACK_TYPE_CODES as string[]).includes(raw)) return raw as FeedbackTypeCode;
  return null;
}

function typeLabel(typeCode: FeedbackTypeCode | null): string {
  if (typeCode === 'TYPE_A') return '확장형';
  if (typeCode === 'TYPE_B') return '동기형';
  if (typeCode === 'TYPE_C') return '회복형';
  if (typeCode === 'TYPE_D') return '안정형';
  return '미분류';
}

function formatZ(value: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '-';
  return value.toFixed(2);
}

function formatScore(value: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '-';
  return value.toFixed(2);
}

function formatPercentileLabel(value: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '-';
  return `${value.toFixed(1)}백분위`;
}

function parseNumberParam(params: URLSearchParams, key: string): number | null {
  const raw = String(params.get(key) ?? '').trim();
  if (!raw) return null;
  const n = Number(raw);
  return Number.isFinite(n) ? n : null;
}

function parsePeerSourceParam(params: URLSearchParams): 'knn' | 'global' | 'none' {
  const raw = String(params.get('peerSource') ?? '').trim().toLowerCase();
  if (raw === 'knn' || raw === 'global') return raw;
  return 'none';
}

function formatLevelGrade(value: number | null): string {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '-';
  return `${value.toFixed(1)}등급`;
}

function computeVectorStrengthPercent(emotionZ: number | null, beliefZ: number | null): number | null {
  if (emotionZ == null || beliefZ == null) return null;
  if (!Number.isFinite(emotionZ) || !Number.isFinite(beliefZ)) return null;
  const magnitude = Math.sqrt((emotionZ ** 2) + (beliefZ ** 2));
  const maxMagnitude = Math.sqrt((3 ** 2) + (3 ** 2));
  return Math.max(0, Math.min(100, (magnitude / maxMagnitude) * 100));
}

const SURVEY_ROUNDS = [
  { no: 1, name: '사전조사', description: '수학을 대하는 나의 근간을 간단하게 살펴보는 단계예요.' },
  { no: 2, name: '코어진단', description: '핵심 학습 습관과 신념의 변화를 점검하는 단계예요.' },
  { no: 3, name: '확장진단', description: '확장 전략과 성장 방향을 구체화하는 단계예요.' },
] as const;

function supportStrengthSummary(percentile: number | null): { label: string; color: string } {
  if (percentile == null || !Number.isFinite(percentile)) {
    return { label: '평가 어려움', color: tokens.textDim };
  }
  if (percentile >= 86) return { label: '매우 강함', color: '#4ADE80' };
  if (percentile >= 72) return { label: '강함', color: '#22C55E' };
  if (percentile >= 58) return { label: '조금 강함', color: '#84CC16' };
  if (percentile >= 43) return { label: '보통', color: '#EAB308' };
  if (percentile >= 29) return { label: '조금 약함', color: '#F59E0B' };
  if (percentile >= 15) return { label: '약함', color: '#F97316' };
  return { label: '매우 약함', color: '#EF4444' };
}

export default function ReportPreviewPage() {
  const [participant, setParticipant] = React.useState<ParticipantMeta | null>(null);
  const [template, setTemplate] = React.useState<FeedbackTemplate | null>(null);
  const [scaleGuide, setScaleGuide] = React.useState<ScaleGuideTemplate>(
    () => cloneScaleGuideTemplate(DEFAULT_SCALE_GUIDE_TEMPLATE),
  );
  const [scaleGuideExpanded, setScaleGuideExpanded] = React.useState(false);
  const [expandedSections, setExpandedSections] = React.useState<Record<string, boolean>>({});
  const [loading, setLoading] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  const params = React.useMemo(() => new URLSearchParams(window.location.search), []);
  const participantId = React.useMemo(() => String(params.get('participantId') ?? '').trim(), [params]);
  const typeCode = React.useMemo(() => parseTypeCode(params.get('typeCode')), [params]);
  const emotionZ = React.useMemo(() => parseNumberParam(params, 'emotionZ'), [params]);
  const beliefZ = React.useMemo(() => parseNumberParam(params, 'beliefZ'), [params]);
  const emotionPercentileParam = React.useMemo(() => parseNumberParam(params, 'emotionPercentile'), [params]);
  const beliefPercentileParam = React.useMemo(() => parseNumberParam(params, 'beliefPercentile'), [params]);
  const metacognitionPercentileParam = React.useMemo(() => parseNumberParam(params, 'metacognitionPercentile'), [params]);
  const persistencePercentileParam = React.useMemo(() => parseNumberParam(params, 'persistencePercentile'), [params]);
  const peerAvgLevelGradeParam = React.useMemo(() => parseNumberParam(params, 'peerAvgLevelGrade'), [params]);
  const peerSampleNParam = React.useMemo(() => parseNumberParam(params, 'peerSampleN'), [params]);
  const vectorStrengthParam = React.useMemo(() => parseNumberParam(params, 'vectorStrength'), [params]);
  const studentGradeParam = React.useMemo(() => parseNumberParam(params, 'studentGrade'), [params]);
  const roundNoParam = React.useMemo(() => parseNumberParam(params, 'roundNo'), [params]);
  const peerSourceParam = React.useMemo(() => parsePeerSourceParam(params), [params]);
  const scaleProfile = React.useMemo(() => {
    const raw = String(params.get('scaleProfile') ?? '').trim();
    if (!raw) return null;
    try {
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
      return parsed as ParticipantScaleProfile;
    } catch {
      return null;
    }
  }, [params]);

  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      setLoading(true);
      setError(null);
      try {
        if (!participantId) throw new Error('participantId가 없습니다.');
        if (!typeCode) throw new Error('유형(typeCode) 정보가 없습니다.');

        const fallback = cloneFeedbackTemplate(DEFAULT_FEEDBACK_TEMPLATES[typeCode]);

        const participantReq = supabase
          .from('survey_participants')
          .select('id, name, school, grade')
          .eq('id', participantId)
          .maybeSingle();
        const templateReq = supabase
          .from('trait_feedback_templates')
          .select('type_code, template_name, sections, scale_description, updated_at, is_active')
          .eq('type_code', typeCode)
          .eq('is_active', true)
          .maybeSingle();
        const [participantRes, templateResRaw] = await Promise.all([
          participantReq,
          templateReq,
        ]);

        let templateRes = templateResRaw;
        if (templateResRaw.error) {
          const message = String(templateResRaw.error?.message ?? '');
          if (/scale_description/i.test(message)) {
            templateRes = await supabase
              .from('trait_feedback_templates')
              .select('type_code, template_name, sections, updated_at, is_active')
              .eq('type_code', typeCode)
              .eq('is_active', true)
              .maybeSingle();
          }
        }

        if (participantRes.error) throw participantRes.error;
        if (templateRes.error) throw templateRes.error;

        const p = participantRes.data as any;
        if (!p?.id) throw new Error('학생 정보를 찾을 수 없습니다.');

        const row = templateRes.data as any;
        const nextTemplate: FeedbackTemplate = row
          ? {
              typeCode,
              templateName: String(row?.template_name ?? fallback.templateName).trim() || fallback.templateName,
              sections: mergeTemplateSections(row?.sections, fallback.sections),
              updatedAt: row?.updated_at ?? null,
            }
          : fallback;

        if (!cancelled) {
          const parsedGuide = parseScaleGuideTemplate(row?.scale_description ?? '');
          setParticipant({
            id: String(p.id),
            name: String(p.name ?? '').trim() || '학생',
            school: String(p.school ?? '').trim() || null,
            grade: String(p.grade ?? '').trim() || null,
          });
          setTemplate(nextTemplate);
          setScaleGuide(parsedGuide ?? cloneScaleGuideTemplate(DEFAULT_SCALE_GUIDE_TEMPLATE));
        }
      } catch (error: any) {
        if (!cancelled) {
          setError(error?.message ?? '미리보기 로드 실패');
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => { cancelled = true; };
  }, [participantId, typeCode]);

  const title = '학생 화면 미리보기';
  const currentRoundNo = React.useMemo(() => {
    const raw = roundNoParam == null ? 1 : Math.round(roundNoParam);
    if (raw === 2 || raw === 3) return raw;
    return 1;
  }, [roundNoParam]);
  const currentRound = React.useMemo(
    () => SURVEY_ROUNDS.find((round) => round.no === currentRoundNo) ?? SURVEY_ROUNDS[0],
    [currentRoundNo],
  );
  const vectorStrength = React.useMemo(
    () => vectorStrengthParam ?? computeVectorStrengthPercent(emotionZ, beliefZ),
    [beliefZ, emotionZ, vectorStrengthParam],
  );
  const peerAvgLevelGrade = React.useMemo(
    () => (peerAvgLevelGradeParam != null ? peerAvgLevelGradeParam : null),
    [peerAvgLevelGradeParam],
  );
  const peerSampleN = React.useMemo(
    () => (peerSampleNParam != null && peerSampleNParam > 0 ? Math.round(peerSampleNParam) : 0),
    [peerSampleNParam],
  );
  const peerAverageLabel = '나와 비슷한 위치의 학생들 평균 등급';
  const peerAverageDisplay = React.useMemo(
    () => (peerAvgLevelGrade == null ? '계산 데이터 부족' : formatLevelGrade(peerAvgLevelGrade)),
    [peerAvgLevelGrade],
  );
  const peerSampleSuffix = '';
  const barMetrics = React.useMemo(() => {
    return [
      { key: 'emotion', label: '감정', color: '#F59E0B', score: scaleProfile?.indicators.emotion.score ?? null, percentile: scaleProfile?.indicators.emotion.percentile ?? emotionPercentileParam },
      { key: 'belief', label: '신념', color: '#60A5FA', score: scaleProfile?.indicators.belief.score ?? null, percentile: scaleProfile?.indicators.belief.percentile ?? beliefPercentileParam },
      { key: 'metacognition', label: '메타인지', color: '#A78BFA', score: scaleProfile?.subscales.metacognition.score ?? null, percentile: scaleProfile?.subscales.metacognition.percentile ?? metacognitionPercentileParam },
      { key: 'persistence', label: '문제지속성', color: '#34D399', score: scaleProfile?.subscales.persistence.score ?? null, percentile: scaleProfile?.subscales.persistence.percentile ?? persistencePercentileParam },
    ] as const;
  }, [beliefPercentileParam, emotionPercentileParam, metacognitionPercentileParam, persistencePercentileParam, scaleProfile]);
  const axisMetrics = React.useMemo(
    () => barMetrics.filter((m) => m.key === 'emotion' || m.key === 'belief'),
    [barMetrics],
  );
  const supportMetrics = React.useMemo(
    () => barMetrics.filter((m) => m.key === 'metacognition' || m.key === 'persistence'),
    [barMetrics],
  );
  const vectorGeometry = React.useMemo(() => {
    const size = 300;
    const center = size / 2;
    const labelOffset = 26;
    const axisRadius = center - labelOffset;
    const x = Math.max(-3, Math.min(3, emotionZ ?? 0));
    const y = Math.max(-3, Math.min(3, beliefZ ?? 0));
    const endX = center + (x / 3) * axisRadius;
    const endY = center - (y / 3) * axisRadius;
    return { size, center, labelOffset, axisRadius, endX, endY };
  }, [beliefZ, emotionZ]);
  const profileSummarySection = React.useMemo(
    () => template?.sections.find((s) => s.key === 'profile_summary') ?? null,
    [template],
  );
  const profileSummaryText = React.useMemo(() => {
    const dbText = profileSummarySection ? combineSectionText(profileSummarySection) : '';
    const isPlaceholder = !dbText || /공통 피드백.*작성하세요|학생별 미세 조정.*작성하세요/.test(dbText);
    if (!isPlaceholder) return dbText;
    return buildProfileSummaryText(typeCode, vectorStrength, studentGradeParam, peerAvgLevelGrade);
  }, [peerAvgLevelGrade, profileSummarySection, studentGradeParam, typeCode, vectorStrength]);
  const nonProfileSections = React.useMemo(
    () => (template?.sections ?? []).filter((s) => s.key !== 'profile_summary'),
    [template],
  );

  const metacognitionPctResolved = React.useMemo(
    () => barMetrics.find((m) => m.key === 'metacognition')?.percentile ?? null,
    [barMetrics],
  );
  const persistencePctResolved = React.useMemo(
    () => barMetrics.find((m) => m.key === 'persistence')?.percentile ?? null,
    [barMetrics],
  );

  const learningTraitsText = React.useMemo(() => {
    const ltSection = nonProfileSections.find((s) => s.key === 'learning_traits');
    const dbText = ltSection ? combineSectionText(ltSection) : '';
    const isPlaceholder = !dbText || /공통 피드백.*작성하세요|학생별 미세 조정.*작성하세요/.test(dbText);
    if (!isPlaceholder) return dbText;
    return buildLearningTraitsText(typeCode, vectorStrength, studentGradeParam, metacognitionPctResolved, persistencePctResolved);
  }, [metacognitionPctResolved, nonProfileSections, persistencePctResolved, studentGradeParam, typeCode, vectorStrength]);

  const coreStrengthsText = React.useMemo(() => {
    const swSection = nonProfileSections.find((s) => s.key === 'strength_weakness');
    const dbText = swSection ? combineSectionText(swSection) : '';
    const isPlaceholder = !dbText || /공통 피드백.*작성하세요|학생별 미세 조정.*작성하세요/.test(dbText);
    if (!isPlaceholder) return dbText;
    return buildCoreStrengthsText(typeCode, vectorStrength, metacognitionPctResolved, persistencePctResolved);
  }, [metacognitionPctResolved, nonProfileSections, persistencePctResolved, typeCode, vectorStrength]);

  const cautionsText = React.useMemo(() => {
    const cSection = nonProfileSections.find((s) => s.key === 'cautions');
    const dbText = cSection ? combineSectionText(cSection) : '';
    const isPlaceholder = !dbText || /공통 피드백.*작성하세요|학생별 미세 조정.*작성하세요/.test(dbText);
    if (!isPlaceholder) return dbText;
    return buildCautionsText(typeCode, vectorStrength, metacognitionPctResolved, persistencePctResolved);
  }, [metacognitionPctResolved, nonProfileSections, persistencePctResolved, typeCode, vectorStrength]);

  const teachingStrategyText = React.useMemo(() => {
    const tsSection = nonProfileSections.find((s) => s.key === 'teaching_strategy');
    const dbText = tsSection ? combineSectionText(tsSection) : '';
    const isPlaceholder = !dbText || /공통 피드백.*작성하세요|학생별 미세 조정.*작성하세요/.test(dbText);
    if (!isPlaceholder) return dbText;
    return buildTeachingStrategyText(typeCode);
  }, [nonProfileSections, typeCode]);

  const growthCheckpointText = React.useMemo(() => {
    const gcSection = nonProfileSections.find((s) => s.key === 'growth_checkpoint');
    const dbText = gcSection ? combineSectionText(gcSection) : '';
    const isPlaceholder = !dbText || /공통 피드백.*작성하세요|학생별 미세 조정.*작성하세요/.test(dbText);
    if (!isPlaceholder) return dbText;
    return buildGrowthCheckpointText(typeCode, vectorStrength);
  }, [nonProfileSections, typeCode, vectorStrength]);

  const intensity = React.useMemo(() => getIntensityLevel(vectorStrength), [vectorStrength]);
  const keywords = React.useMemo(() => getTypeKeywords(typeCode), [typeCode]);

  const handlePrint = React.useCallback(() => {
    const prevExpanded = { ...expandedSections };
    const prevScaleGuide = scaleGuideExpanded;

    const allOpen: Record<string, boolean> = {};
    for (const s of nonProfileSections) allOpen[s.key] = true;
    setExpandedSections(allOpen);
    setScaleGuideExpanded(true);

    const restore = () => {
      setExpandedSections(prevExpanded);
      setScaleGuideExpanded(prevScaleGuide);
      window.removeEventListener('afterprint', restore);
    };
    window.addEventListener('afterprint', restore);

    requestAnimationFrame(() => {
      setTimeout(() => window.print(), 350);
    });
  }, [expandedSections, nonProfileSections, scaleGuideExpanded]);

  return (
    <>
      <style>{`
        @media print {
          @page { size: A4 portrait; margin: 12mm 10mm; }
          html, body {
            background: #fff !important;
            overflow: visible !important;
            -webkit-print-color-adjust: exact !important;
            print-color-adjust: exact !important;
          }
          body::-webkit-scrollbar { display: none !important; }
          #root, #root > div {
            background: transparent !important;
            overflow: visible !important;
            min-height: auto !important;
            padding: 0 !important;
          }
          .report-no-print { display: none !important; }
          .report-print-root {
            max-width: 100% !important;
            padding: 0 !important;
            filter: invert(1) hue-rotate(180deg);
          }
          .report-print-root button { display: none !important; }
          .report-print-only { display: none; }
          .report-print-root .report-print-only { display: block !important; }
        }
      `}</style>
      <div className="report-print-root" style={{ maxWidth: 980, margin: '0 auto', paddingBottom: 24 }}>
        <div className="report-no-print" style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
          <div style={{ fontSize: 20, fontWeight: 900 }}>{title}</div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button
              onClick={handlePrint}
              style={{ height: 36, padding: '0 14px', borderRadius: 8, border: `1px solid ${tokens.border}`, background: tokens.accent, color: '#fff', cursor: 'pointer', fontWeight: 700, fontSize: 13 }}
            >
              인쇄
            </button>
            <button
              onClick={() => { if (window.history.length > 1) { window.history.back(); return; } window.location.href = '/results'; }}
              style={{ height: 36, padding: '0 12px', borderRadius: 8, border: `1px solid ${tokens.border}`, background: '#1E1E1E', color: tokens.text, cursor: 'pointer' }}
            >
              뒤로
            </button>
          </div>
        </div>

        <div className="report-print-only" style={{ display: 'none', textAlign: 'center', marginBottom: 28, paddingBottom: 18, borderBottom: `2px solid ${tokens.border}` }}>
          <div style={{ fontSize: 36, fontWeight: 900, letterSpacing: 3, color: tokens.accent }}>수학 학습 성향 조사</div>
          <div style={{ marginTop: 6, fontSize: 12, fontWeight: 700, opacity: 0.5, letterSpacing: 2 }}>SISU MATH</div>
        </div>

      {loading ? (
        <div style={{ color: tokens.textDim, fontSize: 13 }}>미리보기 데이터를 불러오는 중...</div>
      ) : error ? (
        <div style={{ color: tokens.danger, fontSize: 13 }}>{error}</div>
      ) : participant && template ? (
        <>
          {/* ── 회차 안내 ── */}
          <div style={{ marginBottom: 32 }}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
              {SURVEY_ROUNDS.map((round) => {
                const reached = round.no <= currentRoundNo;
                const current = round.no === currentRoundNo;
                return (
                  <div
                    key={`round_${round.no}`}
                    style={{
                      position: 'relative',
                      background: current
                        ? 'linear-gradient(135deg, #1F7A52, #33A373)'
                        : reached
                          ? 'linear-gradient(135deg, rgba(51,163,115,0.4), rgba(31,122,82,0.3))'
                          : '#343434',
                      color: '#fff',
                      borderRadius: 14,
                      padding: '18px 18px 16px',
                      overflow: 'hidden',
                    }}
                  >
                    <div style={{ position: 'absolute', right: 8, top: '50%', transform: 'translateY(-50%)', fontSize: 34, fontWeight: 900, opacity: 0.18, lineHeight: 1 }}>
                      {'>'}
                    </div>
                    <div style={{ fontSize: 11, fontWeight: 800, opacity: 0.85 }}>{round.no}회차</div>
                    <div style={{ marginTop: 3, fontSize: 18, fontWeight: 900, lineHeight: 1.1 }}>{round.name}</div>
                    {current && (
                      <div style={{ marginTop: 8, fontSize: 12, lineHeight: 1.5, opacity: 0.9, paddingRight: 28 }}>{round.description}</div>
                    )}
                  </div>
                );
              })}
            </div>
          </div>

          {/* ── 기본 정보 + 축 점수 + 보조 + 벡터 ── */}
          <div style={{ marginBottom: 16 }}>
            <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 18, alignItems: 'start' }}>
              <div>
                {/* 기본 정보 */}
                <div style={{ marginBottom: 18 }}>
                  <div style={{ color: tokens.textDim, fontSize: 13, fontWeight: 800, marginBottom: 6 }}>기본 정보</div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
                    <div style={{ fontSize: 16 }}>
                      <span style={{ color: tokens.textDim, fontSize: 12 }}>이름</span> <span style={{ fontWeight: 900 }}>{participant.name}</span>
                    </div>
                    <div style={{ fontSize: 16 }}>
                      <span style={{ color: tokens.textDim, fontSize: 12 }}>학교</span> <span style={{ fontWeight: 700 }}>{participant.school ?? '-'}</span>
                    </div>
                    <div style={{ fontSize: 16 }}>
                      <span style={{ color: tokens.textDim, fontSize: 12 }}>학년</span> <span style={{ fontWeight: 700 }}>{participant.grade ?? '-'}</span>
                    </div>
                  </div>
                  <div style={{ marginTop: 6, color: tokens.textDim, fontSize: 11 }}>
                    {peerAverageLabel}: {peerAverageDisplay}{peerSampleSuffix}
                  </div>
                </div>

                {/* 축 점수 (감정/신념) */}
                <div style={{ display: 'grid', gap: 10, marginBottom: 18 }}>
                  {axisMetrics.map((metric) => {
                    const barW = metric.percentile == null ? 0 : Math.max(0, Math.min(100, metric.percentile));
                    return (
                      <div key={`axis_${metric.key}`} style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, background: tokens.field, padding: '8px 10px' }}>
                        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8 }}>
                          <div style={{ fontWeight: 900, fontSize: 16 }}>{metric.label}</div>
                          <div style={{ color: tokens.textDim, fontSize: 12 }}>{formatScore(metric.score)}점 · {formatPercentileLabel(metric.percentile)}</div>
                        </div>
                        <div style={{ marginTop: 5, height: 8, borderRadius: 999, background: '#2A2A2A', overflow: 'hidden' }}>
                          <div style={{ width: `${barW}%`, height: '100%', background: metric.color }} />
                        </div>
                        <div style={{ marginTop: 6, color: tokens.textDim, fontSize: 13 }}>
                          {peerAverageLabel}: {peerAverageDisplay}{peerSampleSuffix}
                        </div>
                      </div>
                    );
                  })}
                </div>

                {/* 보조 지표 */}
                <div style={{ color: tokens.textDim, fontSize: 13, fontWeight: 800, marginBottom: 8 }}>보조 지표</div>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: 10 }}>
                  {supportMetrics.map((metric) => {
                    const barW = metric.percentile == null ? 0 : Math.max(0, Math.min(100, metric.percentile));
                    const summary = supportStrengthSummary(metric.percentile);
                    return (
                      <div key={`support_${metric.key}`} style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, background: tokens.field, padding: '8px 10px' }}>
                        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8 }}>
                          <div style={{ fontWeight: 900, fontSize: 16 }}>{metric.label}</div>
                          <div style={{ fontSize: 14, fontWeight: 900, color: summary.color }}>{summary.label}</div>
                        </div>
                        <div style={{ marginTop: 5, height: 8, borderRadius: 999, background: '#2A2A2A', overflow: 'hidden' }}>
                          <div style={{ width: `${barW}%`, height: '100%', background: metric.color }} />
                        </div>
                        <div style={{ marginTop: 6, color: tokens.textDim, fontSize: 12 }}>
                          {formatScore(metric.score)}점 · {formatPercentileLabel(metric.percentile)}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>

              {/* 유형 + 벡터 */}
              <div>
                <div style={{ color: tokens.textDim, fontSize: 13, fontWeight: 800, marginBottom: 4 }}>유형</div>
                <div style={{ fontWeight: 900, fontSize: 18, marginBottom: 8 }}>{typeLabel(typeCode)}</div>
                <div style={{ marginBottom: 6, color: tokens.textDim, fontSize: 12, textAlign: 'center' }}>
                  감정 z={formatZ(emotionZ)} · 신념 z={formatZ(beliefZ)} · 강도 {vectorStrength == null ? '-' : `${vectorStrength.toFixed(0)}%`}
                </div>
                <div style={{ width: '100%', aspectRatio: '1 / 1', borderRadius: 14, overflow: 'hidden' }}>
                  <svg width="100%" height="100%" viewBox={`0 0 ${vectorGeometry.size} ${vectorGeometry.size}`} role="img" aria-label="유형 벡터">
                    <line x1={vectorGeometry.center} y1={vectorGeometry.labelOffset} x2={vectorGeometry.center} y2={vectorGeometry.size - vectorGeometry.labelOffset} stroke="rgba(255,255,255,0.12)" />
                    <line x1={vectorGeometry.labelOffset} y1={vectorGeometry.center} x2={vectorGeometry.size - vectorGeometry.labelOffset} y2={vectorGeometry.center} stroke="rgba(255,255,255,0.12)" />

                    <text x={vectorGeometry.center} y={16} textAnchor="middle" fontSize="12" fontWeight="700" fill="rgba(255,255,255,0.45)">감정 +</text>
                    <text x={vectorGeometry.center} y={vectorGeometry.size - 6} textAnchor="middle" fontSize="12" fontWeight="700" fill="rgba(255,255,255,0.45)">감정 -</text>
                    <text x={8} y={vectorGeometry.center + 4} textAnchor="start" fontSize="12" fontWeight="700" fill="rgba(255,255,255,0.45)">신념 -</text>
                    <text x={vectorGeometry.size - 8} y={vectorGeometry.center + 4} textAnchor="end" fontSize="12" fontWeight="700" fill="rgba(255,255,255,0.45)">신념 +</text>

                    <line x1={vectorGeometry.center} y1={vectorGeometry.center} x2={vectorGeometry.endX} y2={vectorGeometry.endY} stroke={tokens.accent} strokeWidth={3} strokeLinecap="round" />
                    <circle cx={vectorGeometry.endX} cy={vectorGeometry.endY} r={6} fill={tokens.accent} />
                    <circle cx={vectorGeometry.center} cy={vectorGeometry.center} r={3} fill="rgba(255,255,255,0.25)" />
                  </svg>
                </div>
              </div>
            </div>
          </div>

          {/* ── 키워드 ── */}
          {keywords.length > 0 ? (
            <div style={{ marginTop: 48, textAlign: 'center' }}>
              <div style={{ fontSize: 18, fontWeight: 800, color: tokens.textDim, marginBottom: 12 }}>키워드</div>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, justifyContent: 'center' }}>
                {keywords.map((kw) => (
                  <span key={kw} style={{ fontSize: 15, fontWeight: 800, color: tokens.accent, background: 'transparent', border: `1px solid ${tokens.border}`, borderRadius: 20, padding: '5px 14px' }}>
                    {kw}
                  </span>
                ))}
              </div>
            </div>
          ) : null}

          {/* ── 디바이더 ── */}
          <div style={{ height: 1, background: tokens.border, margin: '36px 0' }} />

          {/* ── 1. 프로파일 요약 + 자세히 보기 ── */}
          {profileSummarySection ? (
            <div style={{ marginBottom: 28 }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, marginBottom: 12 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                  <span style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: 28, height: 28, borderRadius: 8, background: tokens.accent, color: '#fff', fontWeight: 900, fontSize: 14, flexShrink: 0 }}>1</span>
                  <span style={{ fontWeight: 900, fontSize: 20, color: tokens.accent }}>{profileSummarySection.title.replace(/\s*\(상세점수\s*표시\)\s*/g, '').replace(/\s*\(상세\s*점수\s*표시\)\s*/g, '')}</span>
                </div>
                <button
                  onClick={() => setScaleGuideExpanded((prev) => !prev)}
                  style={{ height: 32, padding: '0 14px', borderRadius: 8, border: `1px solid ${tokens.border}`, background: 'transparent', color: scaleGuideExpanded ? tokens.accent : tokens.textDim, cursor: 'pointer', fontSize: 13, fontWeight: 700, flexShrink: 0, transition: 'color 0.15s' }}
                >
                  {scaleGuideExpanded ? '접기' : '자세히 보기'}
                </button>
              </div>
              {(() => {
                const s1Summary = getSectionSummary('profile_summary', typeCode, intensity);
                return s1Summary ? (
                  <div style={{ marginBottom: 12 }}>
                    <div data-deco-box style={{ background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 10, padding: '10px 14px', fontSize: 14, color: tokens.text, lineHeight: 1.7, whiteSpace: 'pre-line' }}>
                      {s1Summary}
                    </div>
                  </div>
                ) : null;
              })()}
              <div style={{ paddingLeft: 6, color: tokens.textDim, fontSize: 14, whiteSpace: 'pre-wrap', lineHeight: 1.7 }}>
                {profileSummaryText || '내용을 입력해 주세요.'}
              </div>

              {scaleGuideExpanded ? (
                <div style={{ marginTop: 54, paddingBottom: 54, display: 'grid', gap: 50 }}>
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12, alignItems: 'center', justifyContent: 'center' }}>
                    <span style={{ fontSize: 12, color: tokens.textDim, marginRight: 4 }}>색상 기준:</span>
                    {FEEDBACK_COLOR_LEGEND.map((item) => (
                      <span key={item.label} style={{ display: 'inline-flex', alignItems: 'center', gap: 4, fontSize: 11, color: tokens.textDim }}>
                        <span style={{ width: 10, height: 10, borderRadius: '50%', background: item.color, flexShrink: 0 }} />
                        {item.label}
                      </span>
                    ))}
                  </div>
                  {(() => {
                    let subIdx = 0;
                    return SCALE_GUIDE_INDICATORS.map((indicator) => {
                      const indMetric = scaleProfile?.indicators[indicator.key] ?? null;
                      const subs = SCALE_GUIDE_SUBSCALES.filter((sub) => sub.indicatorKey === indicator.key);
                      return (
                        <div key={`sg_ind_${indicator.key}`}>
                          <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 10, background: tokens.panel, padding: '10px 14px', marginBottom: 12 }}>
                            <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 10 }}>
                              <div style={{ fontWeight: 900, fontSize: 18 }}>{indicator.title}</div>
                              <div style={{ fontSize: 13, color: tokens.textDim, flexShrink: 0 }}>
                                {scaleGuide.indicatorDescriptions[indicator.key]}
                              </div>
                            </div>
                            <div style={{ fontSize: 12, color: tokens.textDim, marginTop: 4 }}>
                              {formatScore(indMetric?.score ?? null)}점 · {formatPercentileLabel(indMetric?.percentile ?? null)}
                            </div>
                          </div>
                          <div style={{ display: 'grid', gap: 24 }}>
                            {subs.map((sub) => {
                              subIdx += 1;
                              const circled = String.fromCodePoint(0x2460 + subIdx - 1);
                              const subMetric = scaleProfile?.subscales[sub.key] ?? null;
                              const fb = getSubscaleFeedback(sub.key, subMetric?.percentile ?? null);
                              return (
                                <div key={`sg_sub_${sub.key}`} style={{ paddingLeft: 8, borderLeft: `2px solid ${tokens.border}` }}>
                                  <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 10 }}>
                                    <div style={{ fontWeight: 700, fontSize: 16, flexShrink: 0, whiteSpace: 'nowrap' }}>
                                      <span style={{ marginRight: 6, opacity: 0.5 }}>{circled}</span>{sub.title}
                                    </div>
                                    <div style={{ color: tokens.textDim, fontSize: 12, textAlign: 'right', lineHeight: 1.5 }}>{scaleGuide.subscaleDescriptions[sub.key]}</div>
                                  </div>
                                  <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 8, marginTop: 4 }}>
                                    {fb ? (
                                      <div style={{ fontSize: 14, fontWeight: 600, color: fb.color, lineHeight: 1.5, paddingLeft: 12 }}>{fb.text}</div>
                                    ) : <div />}
                                    <div style={{ color: tokens.textDim, fontSize: 12, flexShrink: 0 }}>
                                      {formatScore(subMetric?.score ?? null)}점 · {formatPercentileLabel(subMetric?.percentile ?? null)}
                                    </div>
                                  </div>
                                </div>
                              );
                            })}
                          </div>
                        </div>
                      );
                    });
                  })()}
                </div>
              ) : null}
            </div>
          ) : null}

          {/* ── 2~6. 나머지 섹션 ── */}
          <div style={{ display: 'grid', gap: 28 }}>
            {nonProfileSections.map((section, index) => {
              const isOpen = !!expandedSections[section.key];
              return (
                <div key={`sec_${section.key}`}>
                  <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, marginBottom: 10 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                      <span style={{ display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: 28, height: 28, borderRadius: 8, background: tokens.accent, color: '#fff', fontWeight: 900, fontSize: 14, flexShrink: 0 }}>{index + 2}</span>
                      <span style={{ fontWeight: 900, fontSize: 20, color: tokens.accent }}>{section.title}</span>
                    </div>
                    <button
                      onClick={() => setExpandedSections((prev) => ({ ...prev, [section.key]: !prev[section.key] }))}
                      style={{ height: 32, padding: '0 14px', borderRadius: 8, border: `1px solid ${tokens.border}`, background: 'transparent', color: isOpen ? tokens.accent : tokens.textDim, cursor: 'pointer', fontSize: 13, fontWeight: 700, flexShrink: 0, transition: 'color 0.15s' }}
                    >
                      {isOpen ? '접기' : '자세히 보기'}
                    </button>
                  </div>
                  {(() => {
                    const secSummary = getSectionSummary(section.key, typeCode, intensity);
                    return secSummary ? (
                      <div style={{ marginBottom: 12 }}>
                        <div data-deco-box style={{ background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 10, padding: '10px 14px', fontSize: 14, color: tokens.text, lineHeight: 1.7, whiteSpace: 'pre-line' }}>
                          {secSummary}
                        </div>
                      </div>
                    ) : null;
                  })()}
                  {isOpen ? (
                    <div style={{ paddingLeft: 6, color: tokens.textDim, fontSize: 14, whiteSpace: 'pre-wrap', lineHeight: 1.7 }}>
                      {section.key === 'learning_traits'
                        ? (learningTraitsText || '내용을 입력해 주세요.')
                        : section.key === 'strength_weakness'
                          ? (coreStrengthsText || '내용을 입력해 주세요.')
                          : section.key === 'cautions'
                            ? (cautionsText || '내용을 입력해 주세요.')
                            : section.key === 'teaching_strategy'
                              ? (teachingStrategyText || '내용을 입력해 주세요.')
                              : section.key === 'growth_checkpoint'
                                ? (growthCheckpointText || '내용을 입력해 주세요.')
                                : (combineSectionText(section) || '내용을 입력해 주세요.')}
                    </div>
                  ) : null}
                </div>
              );
            })}
          </div>
        </>
      ) : null}
    </div>
    </>
  );
}
