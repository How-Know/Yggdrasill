import React, { useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabaseClient';

type TraitQuestion = {
  id: string;
  trait: string;
  text: string;
  type: 'scale'|'text';
  min?: number|null;
  max?: number|null;
  image_url?: string|null;
};

function getClientId(): string {
  const key = 'survey_client_id';
  let id = localStorage.getItem(key);
  if (!id) {
    id = (window.crypto?.randomUUID?.() || Math.random().toString(36).slice(2));
    localStorage.setItem(key, id);
  }
  return id;
}

export default function SurveyPage({ slug = 'welcome' }: { slug?: string }) {
  const [questions, setQuestions] = useState<TraitQuestion[]>([]);
  const [idx, setIdx] = useState(0);
  const [scaleValue, setScaleValue] = useState<number | null>(null);
  const [textValue, setTextValue] = useState('');
  const [answers, setAnswers] = useState<Record<string, number | string>>({});
  const [responseId, setResponseId] = useState<string | null>(null);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [submitted, setSubmitted] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [imgLoaded, setImgLoaded] = useState(false);
  const [imgSrc, setImgSrc] = useState<string | null>(null);
  const [maxVisitedIndex, setMaxVisitedIndex] = useState(0);
  const [needAnswerOpen, setNeedAnswerOpen] = useState(false);
  const clientId = getClientId();

  useEffect(() => {
    (async () => {
      setLoading(true);
      const { data, error } = await supabase
        .from('questions')
        .select('id, trait, text, type, min_score, max_score, image_url')
        .eq('is_active', true)
        .order('created_at', { ascending: true });
      if (error) console.error(error);
      const list = (data || []).map((r: any) => ({
        id: r.id, trait: r.trait, text: r.text, type: r.type,
        min: r.min_score, max: r.max_score, image_url: r.image_url
      })) as TraitQuestion[];
      setQuestions(list);
      setIdx(0); setScaleValue(null); setTextValue(''); setMaxVisitedIndex(0);
      setLoading(false);
    })();
  }, [slug]);

  useEffect(() => {
    const q = questions[idx];
    if (!q) return;
    setImgLoaded(false);
    setImgSrc(q.image_url || null);
    const prev = answers[q.id];
    if (q.type === 'scale') {
      setScaleValue(typeof prev === 'number' ? (prev as number) : null);
      setTextValue('');
    } else {
      setTextValue(typeof prev === 'string' ? (prev as string) : '');
      setScaleValue(null);
    }
  }, [idx, questions]);

  const current = questions[idx];

  async function ensureResponseId(): Promise<string | null> {
    if (responseId) return responseId;
    let rid = sessionStorage.getItem('trait_response_id');
    if (rid) { setResponseId(rid); return rid; }
    // 최근 참가자(같은 client_id)를 찾아 연결
    let participantId: string | null = null;
    try {
      const { data: parts } = await supabase
        .from('survey_participants')
        .select('id, created_at')
        .eq('client_id', clientId)
        .order('created_at', { ascending: false })
        .limit(1);
      if (parts && Array.isArray(parts) && parts.length) participantId = (parts[0] as any).id as string;
    } catch {}
    const { data: r, error: re } = await supabase
      .from('question_responses')
      .insert({ client_id: clientId, user_agent: navigator.userAgent, participant_id: participantId })
      .select('id')
      .single();
    if (re) { setToast('오류가 발생했습니다.'); return null; }
    rid = (r as any).id; sessionStorage.setItem('trait_response_id', rid as string); setResponseId(rid);
    return rid;
  }

  async function saveCurrentAnswer(): Promise<boolean> {
    if (!current) return false;
    const rid = await ensureResponseId();
    if (!rid) return false;
    const payload: any = { response_id: rid, question_id: current.id };
    if (current.type === 'scale') payload.answer_number = scaleValue;
    else payload.answer_text = textValue;
    const { error } = await supabase
      .from('question_answers')
      .upsert(payload, { onConflict: 'response_id,question_id' });
    if (error) { setToast('답변 저장 중 오류'); return false; }
    setAnswers((m) => ({ ...m, [current.id]: current.type === 'scale' ? (scaleValue as number) : textValue }));
    return true;
  }

  const isAnswered = current ? (current.type === 'scale' ? scaleValue !== null : (textValue.trim().length > 0)) : false;

  async function onNext() {
    if (!current) return;
    if (!isAnswered) { setNeedAnswerOpen(true); return; }
    const ok = await saveCurrentAnswer();
    if (!ok) return;
    if (idx + 1 < questions.length) {
      const nextIdx = idx + 1;
      setIdx(nextIdx);
      setMaxVisitedIndex((m) => Math.max(m, nextIdx));
    } else {
      setConfirmOpen(true);
    }
  }

  function onPrev() {
    if (idx > 0) setIdx(idx - 1);
  }

  if (loading) return <p>불러오는 중...</p>;
  if (submitted) return (
    <div style={{ minHeight:'60vh', display:'flex', alignItems:'center', justifyContent:'center' }}>
      <div style={{ fontSize: 18, color: '#FFFFFF', fontWeight: 900 }}>참여해 주셔서 감사합니다!</div>
    </div>
  );

  return (
    <div style={{ maxWidth: 720, margin: '40px auto', padding: 16 }}>
      {current && (
        <div>
          <div style={{ color: '#9aa4af', marginBottom: 8 }}>{idx + 1} / {questions.length} · {current.trait}</div>
          <div style={{ fontSize: 22, marginBottom: 18 }}>{current.text}</div>
          {current.image_url && (
            <div style={{ marginBottom: 16 }}>
              {!imgLoaded && (
                <div style={{ width:'100%', height:220, background:'#2A2A2A', border:'1px solid #2A2A2A', borderRadius:8 }} />
              )}
              <img loading="lazy" src={imgSrc || undefined} alt="question" onLoad={()=>setImgLoaded(true)} onError={async()=>{
                   try {
                     const url = current.image_url as string;
                     const m = /\/storage\/v1\/object\/public\/(\w+)\/(.+)$/i.exec(url);
                     if (m) {
                       const bucket = m[1];
                       const path = decodeURIComponent(m[2]);
                       const { data: s } = await supabase.storage.from(bucket).createSignedUrl(path, 3600);
                       if ((s as any)?.signedUrl) {
                         setImgSrc((s as any).signedUrl as string);
                         return;
                       }
                     }
                     // fallback: cache-busting
                     const bust = url + (url.includes('?') ? '&' : '?') + 'ts=' + Date.now();
                     setImgSrc(bust);
                   } catch {}
                   setImgLoaded(true);
                 }}
                   style={{ maxWidth:'100%', borderRadius: 8, border:'1px solid #2A2A2A', opacity: imgLoaded ? 1 : 0, transition:'opacity 150ms' }} />
            </div>
          )}
          {current.type === 'scale' ? (
            <div style={{ margin:`${current.image_url ? 30 : 48}px 0 24px` }}>
              {(() => {
                const min = current.min ?? 1;
                const max = current.max ?? 10;
                const count = Math.max(1, (max - min + 1));
                const btnW = 48; const gap = 12;
                const containerWidth = count * btnW + (count - 1) * gap;
                const centerIdx = (min === 1 && max === 10) ? 5 : Math.ceil(count / 2);
                return (
                  <div style={{ width: `${containerWidth}px`, margin: '0 auto' }}>
                    <div style={{ display:'grid', gridTemplateColumns:`repeat(${count}, ${btnW}px)`, columnGap:gap, color:'#9aa4af', fontSize:13, marginBottom:8 }}>
                      <div style={{ gridColumn:'1', justifySelf:'start', whiteSpace:'nowrap' }}>전혀 그렇지 않다</div>
                      <div style={{ gridColumn:String(centerIdx), justifySelf:'center', whiteSpace:'nowrap' }}>보통이다</div>
                      <div style={{ gridColumn:String(count), justifySelf:'end', whiteSpace:'nowrap' }}>매우 그렇다</div>
                    </div>
                    <div style={{ display:'grid', gridTemplateColumns:`repeat(${count}, ${btnW}px)`, columnGap:gap }}>
                      {Array.from({length: count}).map((_,i)=>{
                        const v = min + i;
                        const on = scaleValue === v;
                        return (
                          <button key={v} type="button" onClick={()=>setScaleValue(v)}
                            style={{ width:btnW, height:btnW, borderRadius:10, border:`1px solid #2A2A2A`, background:on?'#1976D2':'#2A2A2A', color:'#fff', cursor:'pointer', fontSize:16 }}>{v}</button>
                        );
                      })}
                    </div>
                  </div>
                );
              })()}
            </div>
          ) : (
            <textarea value={textValue} onChange={(e)=>setTextValue(e.target.value)} rows={4} style={{ width:'100%', padding:12, background:'#2A2A2A', border:'1px solid #2A2A2A', borderRadius:10, color:'#fff', marginBottom:24 }} />
          )}
          <div style={{ display:'flex', gap:12, justifyContent:'flex-end' }}>
            {/* < 버튼 */}
            <button type="button" onClick={onPrev}
              style={{ width:48, height:48, lineHeight:'48px', background:'transparent', color:'#9aa4af', border:'1px solid #2A2A2A', borderRadius:12, opacity: idx===0?0.4:1, pointerEvents: idx===0?'none':'auto', cursor: idx===0?'default':'pointer', fontSize:18 }}
              onMouseEnter={(e)=>{ if (idx>0) (e.currentTarget as HTMLButtonElement).style.filter = 'brightness(1.1)'; }}
              onMouseLeave={(e)=>{ (e.currentTarget as HTMLButtonElement).style.filter = 'none'; }}>{'<'}</button>
            {/* > 버튼: 이전으로 돌아간 경우에만 사용 가능 (이미 방문한 범위 내) */}
            {(() => {
              const canRight = (idx < maxVisitedIndex) && isAnswered;
              return (
                <button type="button" onClick={onNext}
                  style={{ width:48, height:48, lineHeight:'48px', background:'transparent', color:'#9aa4af', border:'1px solid #2A2A2A', borderRadius:12, opacity: canRight ? 1 : 0.4, pointerEvents: canRight ? 'auto' : 'none', cursor: canRight ? 'pointer' : 'default', fontSize:18 }}
                  onMouseEnter={(e)=>{ if (canRight) (e.currentTarget as HTMLButtonElement).style.filter = 'brightness(1.1)'; }}
                  onMouseLeave={(e)=>{ (e.currentTarget as HTMLButtonElement).style.filter = 'none'; }}>{'>'}</button>
              );
            })()}
            {/* 다음/제출 버튼 */}
            <button type="button" onClick={onNext}
              style={{ background:'#1976D2', color:'#fff', border:'none', padding:'12px 22px', borderRadius:12, fontWeight:900, fontSize:16, boxShadow:'0 0 0 1px rgba(255,255,255,0.04) inset', cursor:'pointer' }}
              onMouseEnter={(e)=>{ (e.currentTarget as HTMLButtonElement).style.filter = 'brightness(1.08)'; }}
              onMouseLeave={(e)=>{ (e.currentTarget as HTMLButtonElement).style.filter = 'none'; }}>
              {idx + 1 === questions.length ? '제출' : '다음'}
            </button>
          </div>
        </div>
      )}
      {toast && (
        <div style={{ marginTop: 12, fontSize: 13, color: '#7ED957' }}>{toast}</div>
      )}

      {needAnswerOpen && (
        <div style={{ position:'fixed', inset:0, background:'rgba(0,0,0,0.44)', display:'flex', alignItems:'center', justifyContent:'center', zIndex:60 }}>
          <div style={{ width:'min(420px,92vw)', background:'#18181A', border:'1px solid #2A2A2A', borderRadius:12, padding:20 }}>
            <div style={{ fontSize:16, fontWeight:800, marginBottom:8 }}>안내</div>
            <div style={{ color:'#9aa4af', marginBottom:14 }}>답변을 선택한 다음에 진행해 주세요.</div>
            <div style={{ display:'flex', gap:8, justifyContent:'flex-end' }}>
              <button onClick={()=>setNeedAnswerOpen(false)} style={{ background:'#1976D2', color:'#fff', border:'none', padding:'10px 18px', borderRadius:10, cursor:'pointer', fontWeight:700 }}>확인</button>
            </div>
          </div>
        </div>
      )}

      {confirmOpen && (
        <div style={{ position:'fixed', inset:0, background:'rgba(0,0,0,0.5)', display:'flex', alignItems:'center', justifyContent:'center', zIndex:50 }}>
          <div style={{ width:'min(520px,92vw)', background:'#18181A', border:'1px solid #2A2A2A', borderRadius:12, padding:20 }}>
            <div style={{ fontSize:18, fontWeight:900, marginBottom:12 }}>제출 확인</div>
            <div style={{ color:'#9aa4af', marginBottom:16 }}>제출 후에는 답변을 수정할 수 없습니다. 제출하시겠습니까?</div>
            <div style={{ display:'flex', gap:8, justifyContent:'flex-end' }}>
              <button onClick={()=>setConfirmOpen(false)} style={{ background:'transparent', color:'#9aa4af', border:'1px solid #2A2A2A', padding:'10px 16px', borderRadius:10, cursor:'pointer' }}>취소</button>
              <button onClick={async()=>{ const ok = await saveCurrentAnswer(); if (!ok) return; setSubmitted(true); setToast('제출이 완료되었습니다. 감사합니다!'); sessionStorage.removeItem('trait_response_id'); setConfirmOpen(false); }}
                style={{ background:'#1976D2', color:'#fff', border:'none', padding:'10px 20px', borderRadius:10, cursor:'pointer', fontWeight:800 }}>제출</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}




