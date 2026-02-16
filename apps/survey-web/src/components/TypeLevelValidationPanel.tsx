import React from 'react';
import { tokens } from '../theme';

type AxisTypeCode = 'TYPE_A' | 'TYPE_B' | 'TYPE_C' | 'TYPE_D' | 'UNCLASSIFIED';

type AxisPointLike = {
  participantId: string;
  participantName: string;
  emotionZ: number | null;
  beliefZ: number | null;
  typeCode: AxisTypeCode;
  currentLevelGrade: number | null;
  currentMathPercentile: number | null;
};

export type TypeLevelValidationSummary = {
  status?: string | null;
  n_students_with_level?: number | null;
  n_students_with_type?: number | null;
  kruskal_p_value?: number | null;
  kruskal_epsilon2?: number | null;
  interaction_p_value?: number | null;
  cv_mae_mean?: number | null;
  cv_qwk_mean?: number | null;
  spearman_emotion_vs_grade?: number | null;
  spearman_belief_vs_grade?: number | null;
  interpretation?: {
    type_explains_current_ability?: string | null;
    type_suggests_growth_potential?: string | null;
    type_as_independent_state?: string | null;
  } | null;
};

type TypeLevelValidationPanelProps = {
  axisPoints: AxisPointLike[];
  asOfDate?: string | null;
  compact?: boolean;
  validationSummary?: TypeLevelValidationSummary | null;
};

const TYPE_ORDER: AxisTypeCode[] = ['TYPE_A', 'TYPE_B', 'TYPE_C', 'TYPE_D'];

function typeLabel(typeCode: AxisTypeCode): string {
  if (typeCode === 'TYPE_A') return '확장형';
  if (typeCode === 'TYPE_B') return '동기형';
  if (typeCode === 'TYPE_C') return '회복형';
  if (typeCode === 'TYPE_D') return '안정형';
  return '미분류';
}

function toNumber(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string' && value.trim()) {
    const n = Number(value);
    if (Number.isFinite(n)) return n;
  }
  return null;
}

function normalizeGrade(value: unknown): number | null {
  const n = toNumber(value);
  if (n == null) return null;
  if (!Number.isInteger(n)) return null;
  if (n < 0 || n > 6) return null;
  return n;
}

function percentileToLevelGrade(value: unknown): number | null {
  const n = toNumber(value);
  if (n == null) return null;
  if (n < 0 || n > 100) return null;
  if (n <= 1) return 0;
  if (n <= 4) return 1;
  if (n <= 11) return 2;
  if (n <= 23) return 3;
  if (n <= 40) return 4;
  if (n <= 60) return 5;
  return 6;
}

function resolveLevelGrade(point: AxisPointLike): number | null {
  const explicitGrade = normalizeGrade(point.currentLevelGrade);
  if (explicitGrade != null) return explicitGrade;
  return percentileToLevelGrade(point.currentMathPercentile);
}

function mean(values: number[]): number | null {
  if (!values.length) return null;
  return values.reduce((sum, v) => sum + v, 0) / values.length;
}

function sampleVariance(values: number[]): number | null {
  if (!values.length) return null;
  if (values.length === 1) return 0;
  const m = mean(values);
  if (m == null) return null;
  return values.reduce((sum, v) => sum + ((v - m) ** 2), 0) / (values.length - 1);
}

function quantile(sortedValues: number[], q: number): number | null {
  if (!sortedValues.length) return null;
  if (sortedValues.length === 1) return sortedValues[0];
  const pos = (sortedValues.length - 1) * q;
  const base = Math.floor(pos);
  const rest = pos - base;
  const a = sortedValues[base];
  const b = sortedValues[Math.min(base + 1, sortedValues.length - 1)];
  return a + ((b - a) * rest);
}

function median(values: number[]): number | null {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return quantile(sorted, 0.5);
}

function iqr(values: number[]): number | null {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const q1 = quantile(sorted, 0.25);
  const q3 = quantile(sorted, 0.75);
  if (q1 == null || q3 == null) return null;
  return q3 - q1;
}

function rankWithTies(values: number[]): number[] {
  const pairs = values.map((value, index) => ({ value, index })).sort((a, b) => a.value - b.value);
  const ranks = new Array<number>(values.length);
  let i = 0;
  while (i < pairs.length) {
    let j = i + 1;
    while (j < pairs.length && pairs[j].value === pairs[i].value) j += 1;
    const avgRank = ((i + j - 1) / 2) + 1;
    for (let k = i; k < j; k += 1) {
      ranks[pairs[k].index] = avgRank;
    }
    i = j;
  }
  return ranks;
}

function pearson(x: number[], y: number[]): number | null {
  if (x.length !== y.length || x.length < 2) return null;
  const meanX = mean(x);
  const meanY = mean(y);
  if (meanX == null || meanY == null) return null;
  let numerator = 0;
  let xVar = 0;
  let yVar = 0;
  for (let i = 0; i < x.length; i += 1) {
    const dx = x[i] - meanX;
    const dy = y[i] - meanY;
    numerator += dx * dy;
    xVar += dx * dx;
    yVar += dy * dy;
  }
  if (xVar <= 0 || yVar <= 0) return null;
  return numerator / Math.sqrt(xVar * yVar);
}

function spearman(x: number[], y: number[]): number | null {
  if (x.length !== y.length || x.length < 2) return null;
  return pearson(rankWithTies(x), rankWithTies(y));
}

function formatNumber(value: number | null, digits = 2): string {
  if (value == null || !Number.isFinite(value)) return '-';
  return value.toFixed(digits);
}

function formatDateTime(value?: string | null): string {
  if (!value) return '-';
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return '-';
  return d.toLocaleString('ko-KR', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export default function TypeLevelValidationPanel({
  axisPoints,
  asOfDate = null,
  compact = false,
  validationSummary = null,
}: TypeLevelValidationPanelProps) {
  const analysisRows = React.useMemo(() => (
    axisPoints
      .map((point) => ({
        ...point,
        levelGrade: resolveLevelGrade(point),
      }))
      .filter((point) => point.typeCode !== 'UNCLASSIFIED')
  ), [axisPoints]);

  const validRows = React.useMemo(() => (
    analysisRows.filter(
      (row) => row.levelGrade != null
        && row.emotionZ != null
        && Number.isFinite(row.emotionZ)
        && row.beliefZ != null
        && Number.isFinite(row.beliefZ),
    )
  ), [analysisRows]);

  const statsByType = React.useMemo(() => {
    return TYPE_ORDER.map((typeCode) => {
      const rows = validRows.filter((row) => row.typeCode === typeCode);
      const grades = rows.map((row) => row.levelGrade as number);
      return {
        typeCode,
        n: rows.length,
        meanGrade: mean(grades),
        varianceGrade: sampleVariance(grades),
        medianGrade: median(grades),
        iqrGrade: iqr(grades),
      };
    });
  }, [validRows]);

  const gradeByTypeMatrix = React.useMemo(() => {
    return TYPE_ORDER.map((typeCode) => {
      const rows = validRows.filter((row) => row.typeCode === typeCode);
      const counts = [0, 0, 0, 0, 0, 0, 0];
      rows.forEach((row) => {
        const grade = row.levelGrade;
        if (grade != null && grade >= 0 && grade <= 6) counts[grade] += 1;
      });
      return { typeCode, counts };
    });
  }, [validRows]);

  const mismatchSummary = React.useMemo(() => {
    const highAbilityLowState = validRows.filter(
      (row) => (row.levelGrade as number) <= 2 && (row.emotionZ as number) < 0 && (row.beliefZ as number) < 0,
    );
    const lowAbilityHighState = validRows.filter(
      (row) => (row.levelGrade as number) >= 4 && (row.emotionZ as number) >= 0 && (row.beliefZ as number) >= 0,
    );
    const n = validRows.length;
    return {
      highAbilityLowStateN: highAbilityLowState.length,
      highAbilityLowStateRate: n ? highAbilityLowState.length / n : null,
      lowAbilityHighStateN: lowAbilityHighState.length,
      lowAbilityHighStateRate: n ? lowAbilityHighState.length / n : null,
    };
  }, [validRows]);

  const correlationSummary = React.useMemo(() => {
    const grade = validRows.map((row) => row.levelGrade as number);
    const emotion = validRows.map((row) => row.emotionZ as number);
    const belief = validRows.map((row) => row.beliefZ as number);
    return {
      emotionVsGradeRho: spearman(emotion, grade),
      beliefVsGradeRho: spearman(belief, grade),
    };
  }, [validRows]);

  const gradeMissingN = analysisRows.filter((row) => row.levelGrade == null).length;
  const summaryKruskalP = toNumber(validationSummary?.kruskal_p_value);
  const summaryKruskalEps2 = toNumber(validationSummary?.kruskal_epsilon2);
  const summaryInteractionP = toNumber(validationSummary?.interaction_p_value);
  const summaryCvMae = toNumber(validationSummary?.cv_mae_mean);
  const summaryCvQwk = toNumber(validationSummary?.cv_qwk_mean);
  const summaryInterp = validationSummary?.interpretation ?? null;

  return (
    <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 12, overflow: 'hidden', background: tokens.panel }}>
      <div style={{ padding: '12px 14px', borderBottom: `1px solid ${tokens.border}`, background: tokens.panelAlt }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
          <div style={{ fontWeight: 900 }}>유형-실력 검증 요약 (탐색)</div>
          <div style={{ color: tokens.textDim, fontSize: 12 }}>
            기준 시점 {formatDateTime(asOfDate)} · 등급 0~6 (숫자가 낮을수록 상위)
          </div>
        </div>
      </div>

      <div style={{ padding: '12px 14px' }}>
        <div style={{ display: 'grid', gridTemplateColumns: compact ? 'repeat(2, minmax(0, 1fr))' : 'repeat(4, minmax(0, 1fr))', gap: 10, marginBottom: 10 }}>
          <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, padding: '8px 10px', background: tokens.field }}>
            <div style={{ color: tokens.textDim, fontSize: 11 }}>분석 가능 학생 수</div>
            <div style={{ fontWeight: 900, marginTop: 3 }}>{validRows.length.toLocaleString('ko-KR')}명</div>
          </div>
          <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, padding: '8px 10px', background: tokens.field }}>
            <div style={{ color: tokens.textDim, fontSize: 11 }}>등급 미입력 (유형 확정자)</div>
            <div style={{ fontWeight: 900, marginTop: 3 }}>{gradeMissingN.toLocaleString('ko-KR')}명</div>
          </div>
          <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, padding: '8px 10px', background: tokens.field }}>
            <div style={{ color: tokens.textDim, fontSize: 11 }}>감정-등급 Spearman ρ</div>
            <div style={{ fontWeight: 900, marginTop: 3 }}>{formatNumber(correlationSummary.emotionVsGradeRho, 3)}</div>
          </div>
          <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, padding: '8px 10px', background: tokens.field }}>
            <div style={{ color: tokens.textDim, fontSize: 11 }}>신념-등급 Spearman ρ</div>
            <div style={{ fontWeight: 900, marginTop: 3 }}>{formatNumber(correlationSummary.beliefVsGradeRho, 3)}</div>
          </div>
        </div>

        {validationSummary ? (
          <div style={{ display: 'grid', gridTemplateColumns: compact ? 'repeat(2, minmax(0, 1fr))' : 'repeat(5, minmax(0, 1fr))', gap: 10, marginBottom: 10 }}>
            <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, padding: '8px 10px', background: tokens.field }}>
              <div style={{ color: tokens.textDim, fontSize: 11 }}>Kruskal p-value</div>
              <div style={{ fontWeight: 900, marginTop: 3 }}>{formatNumber(summaryKruskalP, 4)}</div>
            </div>
            <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, padding: '8px 10px', background: tokens.field }}>
              <div style={{ color: tokens.textDim, fontSize: 11 }}>효과크기 (epsilon²)</div>
              <div style={{ fontWeight: 900, marginTop: 3 }}>{formatNumber(summaryKruskalEps2, 3)}</div>
            </div>
            <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, padding: '8px 10px', background: tokens.field }}>
              <div style={{ color: tokens.textDim, fontSize: 11 }}>상호작용 p-value</div>
              <div style={{ fontWeight: 900, marginTop: 3 }}>{formatNumber(summaryInteractionP, 4)}</div>
            </div>
            <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, padding: '8px 10px', background: tokens.field }}>
              <div style={{ color: tokens.textDim, fontSize: 11 }}>교차검증 MAE</div>
              <div style={{ fontWeight: 900, marginTop: 3 }}>{formatNumber(summaryCvMae, 3)}</div>
            </div>
            <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 8, padding: '8px 10px', background: tokens.field }}>
              <div style={{ color: tokens.textDim, fontSize: 11 }}>교차검증 QWK</div>
              <div style={{ fontWeight: 900, marginTop: 3 }}>{formatNumber(summaryCvQwk, 3)}</div>
            </div>
          </div>
        ) : (
          <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 10 }}>
            고급 검정(비모수 검정/순서형 회귀/상호작용/CV)은 `type_level_validation_summary_v1.json`을 불러오면 함께 표시됩니다.
          </div>
        )}

        <div style={{ display: 'grid', gap: 8, marginBottom: 10 }}>
          <div style={{ fontWeight: 800, fontSize: 13 }}>유형별 등급 요약</div>
          <div style={{ maxHeight: compact ? 220 : 280, overflow: 'auto', border: `1px solid ${tokens.border}`, borderRadius: 8 }}>
            <div style={{ display: 'grid', gridTemplateColumns: '1.2fr 0.7fr 0.9fr 0.9fr 0.9fr 0.9fr', gap: 10, padding: '8px 10px', fontSize: 12, color: tokens.textDim, background: tokens.panelAlt, borderBottom: `1px solid ${tokens.border}` }}>
              <div>유형</div>
              <div>N</div>
              <div>평균등급</div>
              <div>분산</div>
              <div>중앙값</div>
              <div>IQR</div>
            </div>
            {statsByType.map((row) => (
              <div
                key={`type_level_row_${row.typeCode}`}
                style={{ display: 'grid', gridTemplateColumns: '1.2fr 0.7fr 0.9fr 0.9fr 0.9fr 0.9fr', gap: 10, padding: '8px 10px', fontSize: 12, borderTop: `1px solid ${tokens.border}` }}
              >
                <div>{typeLabel(row.typeCode)}</div>
                <div>{row.n}</div>
                <div>{formatNumber(row.meanGrade)}</div>
                <div>{formatNumber(row.varianceGrade)}</div>
                <div>{formatNumber(row.medianGrade)}</div>
                <div>{formatNumber(row.iqrGrade)}</div>
              </div>
            ))}
          </div>
        </div>

        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginBottom: compact ? 0 : 10 }}>
          <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 999, padding: '4px 10px', fontSize: 12 }}>
            실력 높음 + 유형 낮음: {mismatchSummary.highAbilityLowStateN}명
            {' '}
            ({formatNumber(mismatchSummary.highAbilityLowStateRate == null ? null : mismatchSummary.highAbilityLowStateRate * 100, 1)}%)
          </div>
          <div style={{ border: `1px solid ${tokens.border}`, borderRadius: 999, padding: '4px 10px', fontSize: 12 }}>
            실력 낮음 + 유형 높음: {mismatchSummary.lowAbilityHighStateN}명
            {' '}
            ({formatNumber(mismatchSummary.lowAbilityHighStateRate == null ? null : mismatchSummary.lowAbilityHighStateRate * 100, 1)}%)
          </div>
        </div>

        {!compact ? (
          <div style={{ display: 'grid', gap: 8 }}>
            <div style={{ fontWeight: 800, fontSize: 13 }}>유형 × 등급 분포</div>
            <div style={{ maxHeight: 260, overflow: 'auto', border: `1px solid ${tokens.border}`, borderRadius: 8 }}>
              <div style={{ display: 'grid', gridTemplateColumns: '1.2fr repeat(7, 0.7fr)', gap: 10, padding: '8px 10px', fontSize: 12, color: tokens.textDim, background: tokens.panelAlt, borderBottom: `1px solid ${tokens.border}` }}>
                <div>유형</div>
                {[0, 1, 2, 3, 4, 5, 6].map((grade) => <div key={`grade_header_${grade}`}>{grade}등급</div>)}
              </div>
              {gradeByTypeMatrix.map((row) => (
                <div
                  key={`grade_by_type_${row.typeCode}`}
                  style={{ display: 'grid', gridTemplateColumns: '1.2fr repeat(7, 0.7fr)', gap: 10, padding: '8px 10px', fontSize: 12, borderTop: `1px solid ${tokens.border}` }}
                >
                  <div>{typeLabel(row.typeCode)}</div>
                  {row.counts.map((count, idx) => <div key={`grade_count_${row.typeCode}_${idx}`}>{count}</div>)}
                </div>
              ))}
            </div>
          </div>
        ) : null}

        {summaryInterp ? (
          <div style={{ marginTop: 10, display: 'grid', gap: 6 }}>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>
              - 유형이 현재 실력을 설명하는가?: {summaryInterp.type_explains_current_ability || '-'}
            </div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>
              - 유형이 성장 가능성을 시사하는가?: {summaryInterp.type_suggests_growth_potential || '-'}
            </div>
            <div style={{ color: tokens.textDim, fontSize: 12 }}>
              - 유형이 독립 상태변수인가?: {summaryInterp.type_as_independent_state || '-'}
            </div>
          </div>
        ) : null}

        <div style={{ color: tokens.textDim, fontSize: 12, marginTop: 10 }}>
          해석 주의: 이 패널은 상관 기반 탐색 요약이며, 유형을 실력의 원인으로 단정하지 않습니다.
        </div>
      </div>
    </div>
  );
}

