import React from 'react';
import { supabase } from '../lib/supabaseClient';
import { tokens } from '../theme';

type Row = {
  id: string; name: string; email?: string|null; school?: string|null; grade?: string|null;
  level?: string|null; created_at?: string; client_id?: string|null;
};

function parseRoundNo(value: unknown): number | null {
  const raw = String(value ?? '').trim();
  if (!raw) return null;
  const m = raw.match(/\d+/);
  if (!m) return null;
  const n = Number(m[0]);
  return Number.isFinite(n) ? n : null;
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
        const valRaw = row.answer_number as number | null;
        if (!pid || !q || q.type !== 'scale' || typeof valRaw !== 'number') return;
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

        const roundLabel = String(q.round_label ?? '').trim();
        const roundNo = roundOrderMap[roundLabel] ?? parseRoundNo(roundLabel) ?? 1;
        if (!progressMap[pid]) progressMap[pid] = {};
        progressMap[pid][roundNo] = (progressMap[pid][roundNo] ?? 0) + 1;
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
            </div>
          </div>
          <div style={{ maxHeight: 520, overflow: 'auto' }}>
            <div style={{ display:'grid', gridTemplateColumns:'0.7fr 4.3fr 1fr 1fr', gap:12, padding:'10px 12px', color:tokens.textDim, fontSize:13, background: tokens.panelAlt, borderBottom:`1px solid ${tokens.border}` }}>
              <div>성향</div><div>문항</div><div>응답</div><div>응답시간</div>
            </div>
            <div>
              {answers.map((a, i) => (
                <div key={i} style={{ display:'grid', gridTemplateColumns:'0.7fr 4.3fr 1fr 1fr', gap:12, padding:'10px 12px', borderTop:`1px solid ${tokens.border}` }}>
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



