import React, { useEffect, useMemo, useState } from 'react';
import { getSupabaseConfig, supabase } from '../lib/supabaseClient';
import { tokens } from '../theme';

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
  const [participantId, setParticipantId] = useState<string | null>(null);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [submitted, setSubmitted] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [imgLoaded, setImgLoaded] = useState(false);
  const [imgSrc, setImgSrc] = useState<string | null>(null);
  const [maxVisitedIndex, setMaxVisitedIndex] = useState(0);
  const [needAnswerOpen, setNeedAnswerOpen] = useState(false);
  const clientId = getClientId();
  const [reloadKey, setReloadKey] = useState(0);
  const sbCfg = getSupabaseConfig();
  const hasSupabaseEnv = sbCfg.ok;
  const participantInfo = useMemo(() => {
    const q = new URLSearchParams(window.location.search);
    return {
      sid: (q.get('sid') ?? '').trim(),
      name: (q.get('name') ?? '').trim(),
      school: (q.get('school') ?? '').trim(),
      level: (q.get('level') ?? '').trim() as any,
      grade: (q.get('grade') ?? '').trim(),
    };
  }, []);

  useEffect(() => {
    (async () => {
      setLoading(true);
      if (!hasSupabaseEnv) {
        setQuestions([]);
        setIdx(0);
        setScaleValue(null);
        setTextValue('');
        setMaxVisitedIndex(0);
        setToast(`설문 서버 설정이 없어 문항을 불러올 수 없습니다. (source=${sbCfg.source})`);
        setLoading(false);
        return;
      }
      const { data, error } = await supabase
        .from('questions')
        .select('id, trait, text, type, min_score, max_score, image_url')
        .eq('is_active', true)
        .order('created_at', { ascending: true });
      if (error) {
        console.error(error);
        setToast('설문 문항을 불러오지 못했습니다.');
      }
      const list = (data || []).map((r: any) => ({
        id: r.id, trait: r.trait, text: r.text, type: r.type,
        min: r.min_score, max: r.max_score, image_url: r.image_url
      })) as TraitQuestion[];
      setQuestions(list);
      setIdx(0); setScaleValue(null); setTextValue(''); setMaxVisitedIndex(0);
      setLoading(false);
    })();
  }, [slug, reloadKey, hasSupabaseEnv]);

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

  async function ensureParticipantId(): Promise<string | null> {
    if (participantId) return participantId;
    const cached = sessionStorage.getItem('trait_participant_id');
    if (cached) { setParticipantId(cached); return cached; }
    // 참여자 정보가 없으면 최소 이름은 만들어준다(테이블 not null)
    const name = participantInfo.name || '기존학생';
    const { data: surveyRow, error: se } = await supabase
      .from('surveys')
      .select('id')
      .eq('slug', slug)
      .limit(1)
      .maybeSingle();
    if (se || !surveyRow?.id) { setToast('설문 설정을 불러오지 못했습니다.'); return null; }
    const { data: p, error: pe } = await supabase
      .from('survey_participants')
      .insert({
        survey_id: surveyRow.id,
        client_id: clientId,
        name,
        school: participantInfo.school || null,
        grade: participantInfo.grade || null,
        level: (participantInfo.level === 'elementary' || participantInfo.level === 'middle' || participantInfo.level === 'high')
          ? participantInfo.level
          : null,
      })
      .select('id')
      .single();
    if (pe || !(p as any)?.id) { setToast('참여자 정보를 저장하지 못했습니다.'); return null; }
    const pid = (p as any).id as string;
    sessionStorage.setItem('trait_participant_id', pid);
    setParticipantId(pid);
    return pid;
  }

  async function ensureResponseId(): Promise<string | null> {
    if (responseId) return responseId;
    let rid = sessionStorage.getItem('trait_response_id');
    if (rid) { setResponseId(rid); return rid; }
    // ✅ 기존학생/신규학생 플로우: 설문 시작 전 participant를 먼저 생성
    // (anon은 select가 막혀있어 "조회 후 재사용" 불가)
    const pid = await ensureParticipantId();
    if (!pid) return null;
    const { data: r, error: re } = await supabase
      .from('question_responses')
      .insert({ client_id: clientId, user_agent: navigator.userAgent, participant_id: pid })
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

  if (loading) return <p style={{ color: tokens.textDim }}>불러오는 중...</p>;
  if (submitted) return (
    <div style={{ minHeight:'60vh', display:'flex', alignItems:'center', justifyContent:'center' }}>
      <div style={{ fontSize: 18, color: tokens.text, fontWeight: 900 }}>참여해 주셔서 감사합니다!</div>
    </div>
  );

  if (!current) {
    return (
      <div style={{ maxWidth: 720, margin: '40px auto', padding: 16 }}>
        <div
          style={{
            background: tokens.panel,
            border: `1px solid ${tokens.border}`,
            borderRadius: 14,
            padding: 18,
          }}
        >
          <div style={{ color: tokens.text, fontWeight: 900, fontSize: 18 }}>설문을 시작할 수 없습니다</div>
          <div style={{ marginTop: 10, color: tokens.textFaint, lineHeight: 1.45 }}>
            {hasSupabaseEnv
              ? '활성화된 설문 문항이 없거나(questions.is_active), 문항 로딩에 실패했습니다.'
              : 'Supabase 환경변수(VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY)가 설정되지 않았습니다.'}
          </div>
          <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end', marginTop: 16 }}>
            <button
              type="button"
              onClick={() => setReloadKey((v) => v + 1)}
              style={{
                background: tokens.accent,
                color: '#fff',
                border: 'none',
                padding: '10px 16px',
                borderRadius: 10,
                cursor: 'pointer',
                fontWeight: 900,
              }}
            >
              다시 시도
            </button>
          </div>
        </div>
        {toast && <div style={{ marginTop: 12, fontSize: 13, color: tokens.accent }}>{toast}</div>}
      </div>
    );
  }

  return (
    <div style={{ maxWidth: 720, margin: '40px auto', padding: 16 }}>
      {current && (
        <div>
          <div style={{ color: tokens.textFaint, marginBottom: 8 }}>{idx + 1} / {questions.length} · {current.trait}</div>
          <div style={{ fontSize: 22, marginBottom: 18, color: tokens.text }}>{current.text}</div>
          {current.image_url && (
            <div style={{ marginBottom: 16 }}>
              {!imgLoaded && (
                <div style={{ width:'100%', height:220, background:tokens.field, border:`1px solid ${tokens.border}`, borderRadius:8 }} />
              )}
              <img loading="lazy" src={imgSrc || undefined} alt="question" onLoad={()=>setImgLoaded(true)} onError={async()=>{
                   try {
                     const url = current.image_url as string;
                     // bucket 이름에 하이픈(-)이 들어갈 수 있어 \w+ 대신 [^/]+ 사용
                     let bucket = '';
                     let path = '';
                     const m = /\/storage\/v1\/object\/public\/([^/]+)\/(.+)$/i.exec(url);
                     if (m) {
                       bucket = m[1];
                       path = decodeURIComponent(m[2]);
                     } else {
                       // fallback: URL 파싱으로 public bucket/path 추출
                       const marker = '/storage/v1/object/public/';
                       const idx = url.indexOf(marker);
                       if (idx >= 0) {
                         const rest = url.substring(idx + marker.length);
                         const slash = rest.indexOf('/');
                         if (slash > 0) {
                           bucket = rest.substring(0, slash);
                           path = decodeURIComponent(rest.substring(slash + 1));
                         }
                       }
                     }
                     if (bucket && path) {
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
                   style={{
                     display: 'block',
                     width: '100%',
                     maxWidth: '100%',
                     maxHeight: 320,
                     objectFit: 'contain',
                     borderRadius: 8,
                     border: `1px solid ${tokens.border}`,
                     opacity: imgLoaded ? 1 : 0,
                     transition: 'opacity 150ms',
                   }} />
            </div>
          )}
          {current.type === 'scale' ? (
            <div style={{ margin:`${current.image_url ? 30 : 48}px 0 24px` }}>
              {(() => {
                const isNarrow = window.innerWidth < 720;
                const min = current.min ?? 1;
                const max = current.max ?? 10;
                const count = Math.max(1, (max - min + 1));
                const btnW = isNarrow ? 40 : 48;
                const gap = isNarrow ? 8 : 12;
                const containerWidth = count * btnW + (count - 1) * gap;
                const centerIdx = (min === 1 && max === 10) ? 5 : Math.ceil(count / 2);
                return (
                  <div style={{ maxWidth: '100%', overflowX: 'auto' }}>
                    <div style={{ width: `${containerWidth}px`, maxWidth: '100%', margin: '0 auto' }}>
                    <div style={{ display:'grid', gridTemplateColumns:`repeat(${count}, ${btnW}px)`, columnGap:gap, color:tokens.textFaint, fontSize:13, marginBottom:8 }}>
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
                            style={{ width:btnW, height:btnW, borderRadius:10, border:`1px solid ${tokens.border}`, background:on?tokens.accent:tokens.field, color:'#fff', cursor:'pointer', fontSize:16 }}>{v}</button>
                        );
                      })}
                    </div>
                    </div>
                  </div>
                );
              })()}
            </div>
          ) : (
            <textarea value={textValue} onChange={(e)=>setTextValue(e.target.value)} rows={4} style={{ width:'100%', padding:12, background:tokens.field, border:`1px solid ${tokens.border}`, borderRadius:10, color:tokens.text, marginBottom:24 }} />
          )}
          <div style={{ display:'flex', gap:12, justifyContent:'flex-end' }}>
            {/* < 버튼 */}
            <button type="button" onClick={onPrev}
              style={{ width:48, height:48, lineHeight:'48px', background:'transparent', color:tokens.textFaint, border:`1px solid ${tokens.border}`, borderRadius:12, opacity: idx===0?0.4:1, pointerEvents: idx===0?'none':'auto', cursor: idx===0?'default':'pointer', fontSize:18 }}
              onMouseEnter={(e)=>{ if (idx>0) (e.currentTarget as HTMLButtonElement).style.filter = 'brightness(1.1)'; }}
              onMouseLeave={(e)=>{ (e.currentTarget as HTMLButtonElement).style.filter = 'none'; }}>{'<'}</button>
            {/* > 버튼: 이전으로 돌아간 경우에만 사용 가능 (이미 방문한 범위 내) */}
            {(() => {
              const canRight = (idx < maxVisitedIndex) && isAnswered;
              return (
                <button type="button" onClick={onNext}
                  style={{ width:48, height:48, lineHeight:'48px', background:'transparent', color:tokens.textFaint, border:`1px solid ${tokens.border}`, borderRadius:12, opacity: canRight ? 1 : 0.4, pointerEvents: canRight ? 'auto' : 'none', cursor: canRight ? 'pointer' : 'default', fontSize:18 }}
                  onMouseEnter={(e)=>{ if (canRight) (e.currentTarget as HTMLButtonElement).style.filter = 'brightness(1.1)'; }}
                  onMouseLeave={(e)=>{ (e.currentTarget as HTMLButtonElement).style.filter = 'none'; }}>{'>'}</button>
              );
            })()}
            {/* 다음/제출 버튼 */}
            <button type="button" onClick={onNext}
              style={{ background:tokens.accent, color:'#fff', border:'none', padding:'12px 22px', borderRadius:12, fontWeight:900, fontSize:16, boxShadow:'0 0 0 1px rgba(255,255,255,0.04) inset', cursor:'pointer' }}
              onMouseEnter={(e)=>{ (e.currentTarget as HTMLButtonElement).style.filter = 'brightness(1.08)'; }}
              onMouseLeave={(e)=>{ (e.currentTarget as HTMLButtonElement).style.filter = 'none'; }}>
              {idx + 1 === questions.length ? '제출' : '다음'}
            </button>
          </div>
        </div>
      )}
      {toast && (
        <div style={{ marginTop: 12, fontSize: 13, color: tokens.accent }}>{toast}</div>
      )}

      {needAnswerOpen && (
        <div style={{ position:'fixed', inset:0, background:'rgba(0,0,0,0.44)', display:'flex', alignItems:'center', justifyContent:'center', zIndex:60 }}>
          <div style={{ width:'min(420px,92vw)', background:tokens.panel, border:`1px solid ${tokens.border}`, borderRadius:12, padding:20 }}>
            <div style={{ fontSize:16, fontWeight:800, marginBottom:8 }}>안내</div>
            <div style={{ color:tokens.textFaint, marginBottom:14 }}>답변을 선택한 다음에 진행해 주세요.</div>
            <div style={{ display:'flex', gap:8, justifyContent:'flex-end' }}>
              <button onClick={()=>setNeedAnswerOpen(false)} style={{ background:tokens.accent, color:'#fff', border:'none', padding:'10px 18px', borderRadius:10, cursor:'pointer', fontWeight:700 }}>확인</button>
            </div>
          </div>
        </div>
      )}

      {confirmOpen && (
        <div style={{ position:'fixed', inset:0, background:'rgba(0,0,0,0.5)', display:'flex', alignItems:'center', justifyContent:'center', zIndex:50 }}>
          <div style={{ width:'min(520px,92vw)', background:tokens.panel, border:`1px solid ${tokens.border}`, borderRadius:12, padding:20 }}>
            <div style={{ fontSize:18, fontWeight:900, marginBottom:12 }}>제출 확인</div>
            <div style={{ color:tokens.textFaint, marginBottom:16 }}>제출 후에는 답변을 수정할 수 없습니다. 제출하시겠습니까?</div>
            <div style={{ display:'flex', gap:8, justifyContent:'flex-end' }}>
              <button onClick={()=>setConfirmOpen(false)} style={{ background:'transparent', color:tokens.textFaint, border:`1px solid ${tokens.border}`, padding:'10px 16px', borderRadius:10, cursor:'pointer' }}>취소</button>
              <button onClick={async()=>{ const ok = await saveCurrentAnswer(); if (!ok) return; setSubmitted(true); setToast('제출이 완료되었습니다. 감사합니다!'); sessionStorage.removeItem('trait_response_id'); sessionStorage.removeItem('trait_participant_id'); setConfirmOpen(false); }}
                style={{ background:tokens.accent, color:'#fff', border:'none', padding:'10px 20px', borderRadius:10, cursor:'pointer', fontWeight:800 }}>제출</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}




