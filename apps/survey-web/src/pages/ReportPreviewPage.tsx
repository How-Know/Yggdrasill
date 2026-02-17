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
  INTERPRETATION_FRAME_GUARDRAILS,
  mergeTemplateSections,
  parseScaleGuideTemplate,
  SCALE_GUIDE_INDICATORS,
  SCALE_GUIDE_SUBSCALES,
  ScaleGuideTemplate,
} from '../lib/traitFeedbackTemplates';

type ParticipantMeta = {
  id: string;
  name: string;
  current_level_grade: number | null;
  current_math_percentile: number | null;
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

function formatCurrentLevel(levelGrade: number | null, percentile: number | null): string {
  if (typeof levelGrade === 'number' && Number.isFinite(levelGrade)) return `${levelGrade}등급`;
  if (typeof percentile === 'number' && Number.isFinite(percentile)) return `상위 ${percentile}%`;
  return '미입력';
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

function adjustmentLevelLabel(value: number | null): '높음' | '중간' | '낮음' | '미측정' {
  if (value == null || !Number.isFinite(value)) return '미측정';
  if (value >= 0.5) return '높음';
  if (value <= -0.5) return '낮음';
  return '중간';
}

function buildLearningAdjustmentHints(metacognitionZ: number | null, persistenceZ: number | null): string[] {
  const hints: string[] = [];
  const metacognitionLevel = adjustmentLevelLabel(metacognitionZ);
  const persistenceLevel = adjustmentLevelLabel(persistenceZ);

  if (metacognitionLevel === '높음') {
    hints.push('메타인지가 높아 스스로 점검하고 전략을 조정하는 힘이 있습니다.');
  } else if (metacognitionLevel === '낮음') {
    hints.push('메타인지가 낮아 풀이 과정을 짧게 말해보는 점검 루틴이 필요합니다.');
  } else if (metacognitionLevel === '중간') {
    hints.push('메타인지는 중간 수준으로, 전략 선택 이유를 말하게 하면 안정적으로 향상됩니다.');
  } else {
    hints.push('메타인지 보정값은 응답 부족으로 해석이 제한됩니다.');
  }

  if (persistenceLevel === '높음') {
    hints.push('문제지속성이 높아 어려운 과제에서도 끝까지 시도하는 강점이 있습니다.');
  } else if (persistenceLevel === '낮음') {
    hints.push('문제지속성이 낮아 문제 수를 줄이고 즉시 피드백하는 단계형 설계가 필요합니다.');
  } else if (persistenceLevel === '중간') {
    hints.push('문제지속성은 중간 수준이며, 짧은 성공 경험 누적이 효과적입니다.');
  } else {
    hints.push('문제지속성 보정값은 응답 부족으로 해석이 제한됩니다.');
  }

  return hints;
}

export default function ReportPreviewPage() {
  const [participant, setParticipant] = React.useState<ParticipantMeta | null>(null);
  const [template, setTemplate] = React.useState<FeedbackTemplate | null>(null);
  const [scaleGuide, setScaleGuide] = React.useState<ScaleGuideTemplate>(
    () => cloneScaleGuideTemplate(DEFAULT_SCALE_GUIDE_TEMPLATE),
  );
  const [loading, setLoading] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  const params = React.useMemo(() => new URLSearchParams(window.location.search), []);
  const participantId = React.useMemo(() => String(params.get('participantId') ?? '').trim(), [params]);
  const typeCode = React.useMemo(() => parseTypeCode(params.get('typeCode')), [params]);
  const emotionZ = React.useMemo(() => {
    const n = Number(params.get('emotionZ'));
    return Number.isFinite(n) ? n : null;
  }, [params]);
  const beliefZ = React.useMemo(() => {
    const n = Number(params.get('beliefZ'));
    return Number.isFinite(n) ? n : null;
  }, [params]);
  const metacognitionZ = React.useMemo(() => {
    const n = Number(params.get('metacognitionZ'));
    return Number.isFinite(n) ? n : null;
  }, [params]);
  const persistenceZ = React.useMemo(() => {
    const n = Number(params.get('persistenceZ'));
    return Number.isFinite(n) ? n : null;
  }, [params]);
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
          .select('id, name, current_level_grade, current_math_percentile')
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
            current_level_grade: typeof p.current_level_grade === 'number' ? p.current_level_grade : null,
            current_math_percentile: typeof p.current_math_percentile === 'number' ? p.current_math_percentile : null,
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

  const title = participant ? `${participant.name} 학생 피드백` : '학생 피드백 미리보기';

  return (
    <div style={{ maxWidth: 980, margin: '0 auto', paddingBottom: 24 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 900 }}>{title}</div>
          <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 4 }}>
            실제 학생 화면 미리보기 · 유형 {typeLabel(typeCode)}
          </div>
        </div>
        <button
          onClick={() => {
            if (window.history.length > 1) {
              window.history.back();
              return;
            }
            window.location.href = '/results';
          }}
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
          <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 12, background: tokens.panel, padding: '10px 12px', marginBottom: 12 }}>
            <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 6 }}>
              해석 원칙
            </div>
            <div style={{ display: 'grid', gap: 4 }}>
              {INTERPRETATION_FRAME_GUARDRAILS.map((rule) => (
                <div key={`preview_guardrail_${rule}`} style={{ color: tokens.textDim, fontSize: 12 }}>
                  - {rule}
                </div>
              ))}
            </div>
          </div>

          <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 12, background: tokens.panel, padding: '12px 14px', marginBottom: 12 }}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, minmax(0, 1fr))', gap: 10 }}>
              <div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>이름</div>
                <div style={{ marginTop: 4 }}>{participant.name}</div>
              </div>
              <div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>유형</div>
                <div style={{ marginTop: 4 }}>{typeLabel(typeCode)}</div>
              </div>
              <div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>현재 수준</div>
                <div style={{ marginTop: 4 }}>{formatCurrentLevel(participant.current_level_grade, participant.current_math_percentile)}</div>
              </div>
              <div>
                <div style={{ color: tokens.textDim, fontSize: 12 }}>축 점수</div>
                <div style={{ marginTop: 4 }}>감정 z={formatZ(emotionZ)} · 신념 z={formatZ(beliefZ)}</div>
                <div style={{ marginTop: 4, color: tokens.textDim }}>
                  보정: 메타인지 z={formatZ(metacognitionZ)} ({adjustmentLevelLabel(metacognitionZ)}) · 문제지속성 z={formatZ(persistenceZ)} ({adjustmentLevelLabel(persistenceZ)})
                </div>
              </div>
            </div>
          </div>

          <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 12, background: tokens.panel, padding: '12px 14px', marginBottom: 12 }}>
            <div style={{ fontWeight: 900, marginBottom: 8 }}>학습 방식 보정 (유형 미세조정)</div>
            <div style={{ display: 'grid', gap: 6 }}>
              {buildLearningAdjustmentHints(metacognitionZ, persistenceZ).map((hint) => (
                <div key={`preview_hint_${hint}`} style={{ color: tokens.textDim, fontSize: 13 }}>
                  - {hint}
                </div>
              ))}
            </div>
          </div>

          <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 12, background: tokens.panel, padding: '12px 14px', marginBottom: 12 }}>
            <div style={{ fontWeight: 900, marginBottom: 8 }}>척도 설명 (공통)</div>
            <div style={{ display: 'grid', gap: 10 }}>
              {SCALE_GUIDE_INDICATORS.map((indicator) => (
                <div key={`preview_scale_indicator_${indicator.key}`} style={{ border: `1px solid ${tokens.border}`, borderRadius: 10, background: tokens.field, padding: '10px 12px' }}>
                  <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 10 }}>
                    <div style={{ fontWeight: 800 }}>{indicator.title}</div>
                    <div style={{ textAlign: 'right', fontSize: 12, color: tokens.textDim }}>
                      {(() => {
                        const metric = scaleProfile?.indicators[indicator.key] ?? null;
                        return `${formatScore(metric?.score ?? null)}점 · ${formatPercentileLabel(metric?.percentile ?? null)}`;
                      })()}
                    </div>
                  </div>
                  <div style={{ color: tokens.textDim, fontSize: 13, marginTop: 4 }}>
                    {scaleGuide.indicatorDescriptions[indicator.key]}
                  </div>
                  <div style={{ display: 'grid', gap: 6, marginTop: 8 }}>
                    {SCALE_GUIDE_SUBSCALES
                      .filter((subscale) => subscale.indicatorKey === indicator.key)
                      .map((subscale) => (
                        <div key={`preview_scale_sub_${subscale.key}`} style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, background: tokens.panel, padding: '8px 10px' }}>
                          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
                            <div style={{ fontWeight: 700, fontSize: 13 }}>{subscale.title}</div>
                            <div style={{ color: tokens.textDim, fontSize: 11 }}>
                              {(() => {
                                const metric = scaleProfile?.subscales[subscale.key] ?? null;
                                return `${formatScore(metric?.score ?? null)}점 · ${formatPercentileLabel(metric?.percentile ?? null)}`;
                              })()}
                            </div>
                          </div>
                          <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 4 }}>
                            {scaleGuide.subscaleDescriptions[subscale.key]}
                          </div>
                        </div>
                      ))}
                  </div>
                </div>
              ))}
            </div>
          </div>

          <div style={{ display: 'grid', gap: 10 }}>
            {template.sections.map((section) => (
              <div key={`preview_section_${section.key}`} style={{ border: `1px solid ${tokens.border}`, borderRadius: 12, background: tokens.panel, padding: '12px 14px' }}>
                <div style={{ fontWeight: 900, marginBottom: 8 }}>{section.title}</div>
                <div style={{ color: tokens.text, fontSize: 14, whiteSpace: 'pre-wrap', lineHeight: 1.5 }}>
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
