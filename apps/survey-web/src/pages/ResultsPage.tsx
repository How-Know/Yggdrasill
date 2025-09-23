import React from 'react';
import { supabase } from '../lib/supabaseClient';

const tokens = {
  panel: '#18181A',
  border: '#2A2A2A',
  text: '#FFFFFF',
  textDim: 'rgba(255,255,255,0.7)'
};

type Row = {
  id: string; name: string; email?: string|null; school?: string|null; grade?: string|null;
  level?: string|null; created_at?: string; client_id?: string|null;
};

export default function ResultsPage() {
  const [rows, setRows] = React.useState<Row[]>([]);
  const [selected, setSelected] = React.useState<Row | null>(null);
  const [answers, setAnswers] = React.useState<any[]>([]);
  const [traitSumByParticipant, setTraitSumByParticipant] = React.useState<Record<string, Record<string, number>>>({});

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
      const { data } = await supabase
        .from('question_answers')
        .select('answer_number, question:questions(trait,type,min_score,max_score,reverse,weight), response:question_responses(participant_id)');
      const map: Record<string, Record<string, number>> = {};
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
      });
      setTraitSumByParticipant(map);
    })();
  }, []);

  async function openDetails(row: Row) {
    setSelected(row);
    const { data } = await supabase
      .from('question_answers')
      .select('question_id, answer_text, answer_number, question:questions(text, trait, type)')
      .order('question_id');
    setAnswers((data as any[]) || []);
  }

  return (
    <div>
      <div style={{ marginBottom: 12, fontSize: 18, fontWeight: 900 }}>참여자</div>
      <div style={{ border:`1px solid ${tokens.border}`, borderRadius:12, overflow:'hidden' }}>
        <div style={{ display:'grid', gridTemplateColumns:'1fr 1fr 1fr 1fr 100px', gap:12, padding:12, borderBottom:`1px solid ${tokens.border}`, color:tokens.textDim }}>
          <div>이름</div><div>학교/학년</div><div>이메일</div><div>요약</div><div>삭제</div>
        </div>
        {rows.map(r => (
          <div key={r.id}
               style={{ display:'grid', gridTemplateColumns:'1fr 1fr 1fr 1fr 100px', gap:12, padding:12, borderBottom:`1px solid ${tokens.border}` }}>
            <div onClick={()=>openDetails(r)} style={{ cursor:'pointer' }}>{r.name}</div>
            <div onClick={()=>openDetails(r)} style={{ color: tokens.textDim, cursor:'pointer' }}>{r.school} {r.grade}</div>
            <div onClick={()=>openDetails(r)} style={{ color: tokens.textDim, cursor:'pointer' }}>{r.email}</div>
            <div onClick={()=>openDetails(r)} style={{ color: tokens.textDim, cursor:'pointer' }}>
              {(() => {
                const s = traitSumByParticipant[r.id];
                const order = ['D','I','A','C','N','L','S','P'];
                if (!s) return '미집계';
                const parts = order
                  .filter(k => s[k] !== undefined)
                  .map(k => `${k} ${Math.round(s[k])}`);
                return parts.length ? parts.join(' · ') : '미집계';
              })()}
            </div>
            <div>
              <button
                onClick={async()=>{
                  const ok = window.confirm('해당 참여자와 응답을 삭제하시겠습니까? 되돌릴 수 없습니다.');
                  if (!ok) return;
                  try {
                    // 참가자 삭제: 응답은 별도 테이블이라 정합성을 위해 함께 정리
                    await supabase.from('survey_participants').delete().eq('id', r.id);
                    // 연쇄 삭제: 해당 참가자의 response가 있다면 정리
                    const { data: resps } = await supabase.from('question_responses').select('id').eq('participant_id', r.id);
                    const ids = (resps as any[]||[]).map(x=>x.id);
                    if (ids.length) await supabase.from('question_responses').delete().in('id', ids);
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
        <div style={{ marginTop:20, border:`1px solid ${tokens.border}`, borderRadius:12 }}>
          <div style={{ padding:12, borderBottom:`1px solid ${tokens.border}`, display:'flex', justifyContent:'space-between', alignItems:'center' }}>
            <div style={{ fontWeight:900 }}>{selected.name} · 상세 응답</div>
            <div style={{ color: tokens.textDim, fontSize:12 }}>{selected.email}</div>
          </div>
          <div>
            <div style={{ display:'grid', gridTemplateColumns:'0.8fr 5fr 1fr', gap:12, padding:12, color:tokens.textDim }}>
              <div>성향</div><div>문항</div><div>응답</div>
            </div>
            <div>
              {answers.map((a, i) => (
                <div key={i} style={{ display:'grid', gridTemplateColumns:'0.8fr 5fr 1fr', gap:12, padding:'10px 12px', borderTop:`1px solid ${tokens.border}` }}>
                  <div>{a.question?.trait}</div>
                  <div>{a.question?.text}</div>
                  <div>{a.answer_number ?? a.answer_text ?? ''}</div>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}



