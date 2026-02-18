import React from 'react';
import { supabase } from '../lib/supabaseClient';
import { tokens } from '../theme';
import {
  combineSectionText,
  cloneScaleGuideTemplate,
  cloneFeedbackTemplate,
  DEFAULT_FEEDBACK_TEMPLATES,
  DEFAULT_SCALE_GUIDE_TEMPLATE,
  FEEDBACK_TYPE_CODES,
  FeedbackTemplate,
  FeedbackTypeCode,
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
  const nonProfileSections = React.useMemo(
    () => (template?.sections ?? []).filter((s) => s.key !== 'profile_summary'),
    [template],
  );

  return (
    <div style={{ maxWidth: 980, margin: '0 auto', paddingBottom: 24 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
        <div style={{ fontSize: 20, fontWeight: 900 }}>{title}</div>
        <button
          onClick={() => { if (window.history.length > 1) { window.history.back(); return; } window.location.href = '/results'; }}
          style={{ height: 36, padding: '0 12px', borderRadius: 8, border: `1px solid ${tokens.border}`, background: '#1E1E1E', color: tokens.text, cursor: 'pointer' }}
        >
          뒤로
        </button>
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
                        ? 'linear-gradient(135deg, #6366F1, #3B82F6)'
                        : reached
                          ? 'linear-gradient(135deg, rgba(59,130,246,0.5), rgba(30,64,175,0.4))'
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
                    <div style={{ fontSize: 13, fontWeight: 800, opacity: 0.85 }}>{round.no}회차</div>
                    <div style={{ marginTop: 4, fontSize: 22, fontWeight: 900, lineHeight: 1.1 }}>{round.name}</div>
                    {current && (
                      <div style={{ marginTop: 8, fontSize: 12, lineHeight: 1.5, opacity: 0.9 }}>{round.description}</div>
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
                  <div style={{ color: tokens.textDim, fontSize: 12, fontWeight: 700, marginBottom: 6 }}>기본 정보</div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
                    <div style={{ fontSize: 20 }}>
                      <span style={{ color: tokens.textDim, fontSize: 14 }}>이름</span> <span style={{ fontWeight: 900 }}>{participant.name}</span>
                    </div>
                    <div style={{ fontSize: 20 }}>
                      <span style={{ color: tokens.textDim, fontSize: 14 }}>학교</span> <span style={{ fontWeight: 700 }}>{participant.school ?? '-'}</span>
                    </div>
                    <div style={{ fontSize: 20 }}>
                      <span style={{ color: tokens.textDim, fontSize: 14 }}>학년</span> <span style={{ fontWeight: 700 }}>{participant.grade ?? '-'}</span>
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
                          <div style={{ fontWeight: 900, fontSize: 20 }}>{metric.label}</div>
                          <div style={{ color: tokens.textDim, fontSize: 14 }}>{formatScore(metric.score)}점 · {formatPercentileLabel(metric.percentile)}</div>
                        </div>
                        <div style={{ marginTop: 6, height: 10, borderRadius: 999, background: '#2A2A2A', overflow: 'hidden' }}>
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
                <div style={{ color: tokens.textDim, fontSize: 16, fontWeight: 800, marginBottom: 8 }}>보조 지표</div>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, minmax(0, 1fr))', gap: 10 }}>
                  {supportMetrics.map((metric) => {
                    const barW = metric.percentile == null ? 0 : Math.max(0, Math.min(100, metric.percentile));
                    const summary = supportStrengthSummary(metric.percentile);
                    return (
                      <div key={`support_${metric.key}`} style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, background: tokens.field, padding: '8px 10px' }}>
                        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8 }}>
                          <div style={{ fontWeight: 900, fontSize: 20 }}>{metric.label}</div>
                          <div style={{ fontSize: 16, fontWeight: 900, color: summary.color }}>{summary.label}</div>
                        </div>
                        <div style={{ marginTop: 6, height: 10, borderRadius: 999, background: '#2A2A2A', overflow: 'hidden' }}>
                          <div style={{ width: `${barW}%`, height: '100%', background: metric.color }} />
                        </div>
                        <div style={{ marginTop: 8, color: tokens.textDim, fontSize: 14 }}>
                          {formatScore(metric.score)}점 · {formatPercentileLabel(metric.percentile)}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>

              {/* 유형 + 벡터 */}
              <div>
                <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 4 }}>유형</div>
                <div style={{ fontWeight: 900, fontSize: 22, marginBottom: 10 }}>{typeLabel(typeCode)}</div>
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

          {/* ── 1. 프로파일 요약 ── */}
          {profileSummarySection ? (
            <div style={{ marginTop: 32, marginBottom: 16 }}>
              <div style={{ fontWeight: 900, fontSize: 24, marginBottom: 8 }}>{`1. ${profileSummarySection.title}`}</div>
              <div style={{ paddingLeft: 20, color: tokens.text, fontSize: 14, whiteSpace: 'pre-wrap', lineHeight: 1.6 }}>
                {combineSectionText(profileSummarySection) || '내용을 입력해 주세요.'}
              </div>
            </div>
          ) : null}

          {/* ── 자세히 보기 (척도 설명) ── */}
          <div style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'center' }}>
              <button
                onClick={() => setScaleGuideExpanded((prev) => !prev)}
                style={{ height: 42, padding: '0 22px', borderRadius: 10, border: `1px solid ${tokens.border}`, background: 'transparent', color: tokens.text, cursor: 'pointer', fontSize: 16, fontWeight: 800 }}
              >
                {scaleGuideExpanded ? '접기' : '자세히 보기'}
              </button>
            </div>
            {scaleGuideExpanded ? (
              <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 12, background: tokens.panel, padding: '12px 14px', marginTop: 8 }}>
                <div style={{ display: 'grid', gap: 10 }}>
                  {SCALE_GUIDE_INDICATORS.map((indicator) => (
                    <div key={`sg_ind_${indicator.key}`} style={{ border: `1px solid ${tokens.border}`, borderRadius: 10, background: tokens.field, padding: '10px 12px' }}>
                      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 10 }}>
                        <div style={{ fontWeight: 800 }}>{indicator.title}</div>
                        <div style={{ textAlign: 'right', fontSize: 12, color: tokens.textDim }}>
                          {(() => { const m = scaleProfile?.indicators[indicator.key] ?? null; return `${formatScore(m?.score ?? null)}점 · ${formatPercentileLabel(m?.percentile ?? null)}`; })()}
                        </div>
                      </div>
                      <div style={{ color: tokens.textDim, fontSize: 13, marginTop: 4 }}>{scaleGuide.indicatorDescriptions[indicator.key]}</div>
                      <div style={{ display: 'grid', gap: 6, marginTop: 8 }}>
                        {SCALE_GUIDE_SUBSCALES.filter((sub) => sub.indicatorKey === indicator.key).map((sub) => (
                          <div key={`sg_sub_${sub.key}`} style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, background: tokens.panel, padding: '8px 10px' }}>
                            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
                              <div style={{ fontWeight: 700, fontSize: 13 }}>{sub.title}</div>
                              <div style={{ color: tokens.textDim, fontSize: 11 }}>
                                {(() => { const m = scaleProfile?.subscales[sub.key] ?? null; return `${formatScore(m?.score ?? null)}점 · ${formatPercentileLabel(m?.percentile ?? null)}`; })()}
                              </div>
                            </div>
                            <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 4 }}>{scaleGuide.subscaleDescriptions[sub.key]}</div>
                          </div>
                        ))}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            ) : null}
          </div>

          {/* ── 2~6. 나머지 섹션 ── */}
          <div style={{ display: 'grid', gap: 16 }}>
            {nonProfileSections.map((section, index) => (
              <div key={`sec_${section.key}`}>
                <div style={{ fontWeight: 900, fontSize: 24, marginBottom: 8 }}>{`${index + 2}. ${section.title}`}</div>
                <div style={{ paddingLeft: 20, color: tokens.text, fontSize: 14, whiteSpace: 'pre-wrap', lineHeight: 1.6 }}>
                  {combineSectionText(section) || '내용을 입력해 주세요.'}
                </div>
              </div>
            ))}
          </div>
        </>
      ) : null}
    </div>
  );
}
