import React from 'react';
import * as XLSX from 'xlsx';
import { supabase } from '../lib/supabaseClient';
import { tokens } from '../theme';

type Row = {
  id: string; name: string; email?: string|null; school?: string|null; grade?: string|null;
  level?: string|null; created_at?: string; client_id?: string|null;
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

type Round2LinkStatus = {
  email: string | null;
  sentAt: string | null;
  lastStatus: string | null;
  lastError: string | null;
  lastMessageId: string | null;
  expiresAt: string | null;
  updatedAt: string | null;
};

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

export default function ResultsPage() {
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
  const [round2LinksByParticipant, setRound2LinksByParticipant] = React.useState<Record<string, Round2LinkStatus>>({});

  React.useEffect(() => {
    (async () => {
      const { data } = await supabase
        .from('survey_participants')
        .select('id, name, email, school, grade, level, created_at, client_id')
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
            .select('id'),
        ]);

        if (answersRes.error) throw answersRes.error;
        if (questionsRes.error) throw questionsRes.error;
        if (participantsRes.error) throw participantsRes.error;

        const asOfDate = new Date().toISOString();
        const statsMap: Record<string, ItemStatAcc> = {};
        const participantSet = new Set<string>();
        const validParticipantSet = new Set(
          (participantsRes.data as any[] || [])
            .map((p) => String(p?.id ?? '').trim())
            .filter(Boolean),
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
  }, []);

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

  function exportItemStats() {
    if (!itemStats.length) {
      alert('내보낼 Item_Stats 데이터가 없습니다.');
      return;
    }
    const asOfDate = itemStatsMeta?.asOfDate ?? new Date().toISOString();
    const cumulativeN = itemStatsMeta?.cumulativeParticipants ?? 0;
    const rows = itemStats.map((item) => ({
      as_of_date: asOfDate,
      cumulative_n: cumulativeN,
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
    XLSX.writeFile(wb, `item_stats_${fileStamp}.xlsx`);
  }

  const itemGridTemplate = '0.9fr 0.6fr 0.6fr 3.2fr 0.6fr 0.8fr 0.8fr 0.8fr 0.8fr 1fr';
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

  return (
    <div>
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
          </div>
          <div style={{ marginTop: 8, color: tokens.textDim, fontSize: 12 }}>
            {itemStatsLoading
              ? 'Item_Stats 집계 중...'
              : itemStatsError
                ? `Item_Stats 오류: ${itemStatsError}`
                : `표시 ${filteredItemStats.length.toLocaleString('ko-KR')} / ${itemStats.length.toLocaleString('ko-KR')}`}
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

      <div style={{ marginBottom: 12, fontSize: 18, fontWeight: 900 }}>참여자</div>
      <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden', background: tokens.panel }}>
        <div style={{ display:'grid', gridTemplateColumns:'1.2fr 1.4fr 1.6fr 1.6fr 110px', gap:12, padding:'12px 14px', borderBottom:`1px solid ${tokens.border}`, color:tokens.textDim, fontSize:13, background: tokens.panelAlt }}>
          <div>참여자</div>
          <div>이메일 · 참여일시</div>
          <div>회차별 진행률</div>
          <div>요약</div>
          <div>삭제</div>
        </div>
        {rows.map(r => (
          <div
            key={r.id}
            onClick={()=>openDetails(r)}
            style={{
              display:'grid',
              gridTemplateColumns:'1.2fr 1.4fr 1.6fr 1.6fr 110px',
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
                {(selected.school ?? '-') + ' · ' + (selected.level ?? '-') + ' ' + (selected.grade ?? '-')} · {selected.email || '-'} · {formatDateTime(selected.created_at)}
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
    </div>
  );
}



