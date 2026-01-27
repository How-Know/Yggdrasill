import React, { useEffect, useMemo, useRef, useState } from 'react';
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
  round_label?: string|null;
  part_index?: number|null;
};

type TraitRound = {
  id: string;
  name: string;
  description?: string | null;
  image_url?: string | null;
  order_index?: number | null;
  is_active?: boolean | null;
};

type TraitRoundPart = {
  id: string;
  round_id: string;
  name: string;
  description?: string | null;
  image_url?: string | null;
  order_index?: number | null;
};

type NormalizedQuestion = TraitQuestion & {
  round_no: number;
  part_no: number;
  order_index: number;
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

function newUuid(): string {
  return (window.crypto?.randomUUID?.() || `u_${Date.now()}_${Math.random().toString(16).slice(2)}`);
}

function isValidEmail(email: string): boolean {
  const v = email.trim();
  if (!v) return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);
}

function resolveImageUrl(raw: string | null | undefined): string | null {
  const v = (raw ?? '').trim();
  if (!v) return null;
  if (/^https?:\/\//i.test(v)) {
    // ✅ 관리자 화면에서 로컬 supabase(예: localhost)로 생성된 URL이 저장된 경우,
    // 앱(WebView)에서는 원격 supabase로 치환해서 사용한다.
    try {
      const u = new URL(v);
      const isLocalHost = (u.hostname === 'localhost' || u.hostname === '127.0.0.1');
      if (isLocalHost && u.pathname.startsWith('/storage/v1/')) {
        const cfg = getSupabaseConfig();
        if (cfg.ok) {
          const base = cfg.url.replace(/\/$/, '');
          return `${base}${u.pathname}${u.search}${u.hash}`;
        }
      }
    } catch {}
    return v;
  }

  const cfg = getSupabaseConfig();
  const base = cfg.ok ? cfg.url.replace(/\/$/, '') : '';
  if (base) {
    // common: "/storage/v1/object/public/<bucket>/<path>"
    if (v.startsWith('/storage/v1/')) return `${base}${v}`;
    if (v.startsWith('storage/v1/')) return `${base}/${v}`;
    if (v.startsWith('/')) return `${base}${v}`;
  }

  // common: "<bucket>/<path>" or just "<path>" (assume survey bucket)
  const parts = v.split('/').filter(Boolean);
  if (parts.length >= 2) {
    const bucket = parts[0];
    const path = parts.slice(1).join('/');
    const { data } = supabase.storage.from(bucket).getPublicUrl(path);
    return data.publicUrl || v;
  }
  const { data } = supabase.storage.from('survey').getPublicUrl(v);
  return data.publicUrl || v;
}

function parseRoundNo(value: unknown): number | null {
  const raw = String(value ?? '').trim();
  if (!raw) return null;
  const m = raw.match(/\d+/);
  if (!m) return null;
  const n = Number(m[0]);
  return Number.isFinite(n) ? n : null;
}

function parsePartNo(value: unknown): number | null {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  const raw = String(value ?? '').trim();
  if (!raw) return null;
  const n = Number(raw);
  return Number.isFinite(n) ? n : null;
}

function shuffleList<T>(list: T[]): T[] {
  const arr = list.slice();
  for (let i = arr.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

function normalizeNonNegativeInt(value: string): string {
  return value.replace(/[^\d]/g, '');
}

function isValidNonNegativeInt(value: string): boolean {
  return /^\d+$/.test(value.trim());
}

export default function SurveyPage({ slug = 'welcome' }: { slug?: string }) {
  const FAST_RESPONSE_MS = 3000;
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
  const [imgErr, setImgErr] = useState<string | null>(null);
  const [maxVisitedIndex, setMaxVisitedIndex] = useState(0);
  const [needAnswerOpen, setNeedAnswerOpen] = useState(false);
  const [rounds, setRounds] = useState<TraitRound[]>([]);
  const [roundParts, setRoundParts] = useState<TraitRoundPart[]>([]);
  const [activeRound, setActiveRound] = useState<number | null>(null);
  const [answersLoaded, setAnswersLoaded] = useState(false);
  const [seenRounds, setSeenRounds] = useState<Record<string, boolean>>({});
  const [roundIntroOpen, setRoundIntroOpen] = useState(false);
  const [seenParts, setSeenParts] = useState<Record<string, boolean>>({});
  const [partIntroOpen, setPartIntroOpen] = useState(false);
  const [roundOrders, setRoundOrders] = useState<Record<number, string[]>>({});
  const [roundComplete, setRoundComplete] = useState(false);
  const isInWebViewHost = !!((window as any)?.chrome?.webview);
  const [round2Access, setRound2Access] = useState<'unknown' | 'allowed' | 'denied'>(isInWebViewHost ? 'allowed' : 'unknown');
  const [round2AccessMsg, setRound2AccessMsg] = useState<string | null>(null);
  const [round2LinkStatus, setRound2LinkStatus] = useState<'idle' | 'sending' | 'sent' | 'error'>('idle');
  const [round2LinkError, setRound2LinkError] = useState<string | null>(null);
  const round2Token = useMemo(() => {
    try {
      const q = new URLSearchParams(window.location.search);
      return (q.get('r2') ?? '').trim();
    } catch {
      return '';
    }
  }, []);
  const questionStartRef = useRef<number | null>(null);
  const lastQuestionIdRef = useRef<string | null>(null);
  const questionElapsedRef = useRef<number>(0);
  const timerRunningRef = useRef<boolean>(false);
  const questionVisibleAtRef = useRef<number | null>(null);
  const isSavingRef = useRef<boolean>(false);
  const isNarrowScreen = window.innerWidth < 720;
  const pageMargin = isNarrowScreen ? '24px auto' : '40px auto';
  const pagePadding = isNarrowScreen ? 8 : 16;
  const [pageActive, setPageActive] = useState(() => {
    if (typeof document === 'undefined') return true;
    return document.visibilityState === 'visible';
  });
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
      email: (q.get('email') ?? '').trim(),
    };
  }, []);

  useEffect(() => {
    const isWebView = (() => {
      try {
        return Boolean((window as any)?.chrome?.webview);
      } catch {
        return false;
      }
    })();
    const update = () => {
      const visible = isWebView ? true : document.visibilityState === 'visible';
      const focused = isWebView ? true : (document.hasFocus ? document.hasFocus() : true);
      setPageActive(visible && focused);
    };
    update();
    if (!isWebView) {
      document.addEventListener('visibilitychange', update);
      window.addEventListener('focus', update);
      window.addEventListener('blur', update);
    }
    return () => {
      if (!isWebView) {
        document.removeEventListener('visibilitychange', update);
        window.removeEventListener('focus', update);
        window.removeEventListener('blur', update);
      }
    };
  }, []);

  useEffect(() => {
    if (isInWebViewHost) {
      setRound2Access('allowed');
      setRound2AccessMsg(null);
      return;
    }
    if (!round2Token) {
      setRound2Access('denied');
      setRound2AccessMsg('2차 설문은 이메일로 받은 링크에서만 진행할 수 있습니다.');
      return;
    }
    const tokenIsUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(round2Token);
    if (!tokenIsUuid) {
      setRound2Access('denied');
      setRound2AccessMsg('링크가 유효하지 않습니다.');
      return;
    }
    const sid = participantInfo.sid;
    const sidIsUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sid);
    if (!sidIsUuid) {
      setRound2Access('denied');
      setRound2AccessMsg('링크에 참여자 정보가 없어 2차 설문을 시작할 수 없습니다.');
      return;
    }
    let cancelled = false;
    setRound2Access('unknown');
    setRound2AccessMsg(null);
    (async () => {
      const { data, error } = await supabase.rpc('verify_trait_round2_link', { p_token: round2Token } as any);
      if (cancelled) return;
      if (error) {
        setRound2Access('denied');
        setRound2AccessMsg('링크 확인 중 오류가 발생했습니다.');
        return;
      }
      const row = Array.isArray(data) ? data[0] : data;
      if (!row?.participant_id || String(row.participant_id) !== sid) {
        setRound2Access('denied');
        setRound2AccessMsg('링크가 유효하지 않습니다.');
        return;
      }
      setRound2Access('allowed');
    })();
    return () => { cancelled = true; };
  }, [isInWebViewHost, round2Token, participantInfo.sid]);

  useEffect(() => {
    (async () => {
      if (!hasSupabaseEnv) return;
      try {
        const { data: roundData, error: roundErr } = await supabase.rpc('list_trait_rounds_public');
        if (!roundErr && Array.isArray(roundData)) {
          setRounds(roundData as TraitRound[]);
        }
        const { data: partData, error: partErr } = await supabase.rpc('list_trait_round_parts_public');
        if (!partErr && Array.isArray(partData)) {
          setRoundParts(partData as TraitRoundPart[]);
        }
      } catch (e) {
        console.error(e);
      }
    })();
  }, [hasSupabaseEnv]);

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
        .select('id, trait, text, type, min_score, max_score, image_url, round_label, part_index')
        .eq('is_active', true)
        .order('created_at', { ascending: true });
      if (error) {
        console.error(error);
        setToast('설문 문항을 불러오지 못했습니다.');
      }
      const list = (data || []).map((r: any) => ({
        id: r.id, trait: r.trait, text: r.text, type: r.type,
        min: r.min_score, max: r.max_score, image_url: r.image_url,
        round_label: r.round_label, part_index: r.part_index,
      })) as TraitQuestion[];
      setQuestions(list);
      setActiveRound(null);
      setIdx(0); setScaleValue(null); setTextValue(''); setMaxVisitedIndex(0);
      setLoading(false);
    })();
  }, [slug, reloadKey, hasSupabaseEnv]);

  function goHome() {
    try {
      const u = new URL(window.location.href);
      u.pathname = '/';
      // sid/theme는 유지 (앱에서 재진입 용이)
      const qs = new URLSearchParams(u.search);
      if (participantInfo.sid) qs.set('sid', participantInfo.sid);
      if (qs.get('theme') == null) qs.set('theme', 'dark');
      u.search = `?${qs.toString()}`;
      window.location.href = u.toString();
    } catch {
      window.location.href = '/';
    }
  }

  async function onSaveAndExit(skipSave = false) {
    // 현재 문항에 응답이 있으면 저장 후 종료
    if (!skipSave && isAnswered) await saveCurrentAnswer();
    goHome();
  }

  // ✅ 앱(WebView) 플로우: 학생(sid=uuid) 기준으로 진행상태를 불러와 이어하기
  useEffect(() => {
    let cancelled = false;
    (async () => {
      setAnswersLoaded(false);
      if (!hasSupabaseEnv) { if (!cancelled) setAnswersLoaded(true); return; }
      const sid = participantInfo.sid;
      const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sid);
      if (!isUuid) { if (!cancelled) setAnswersLoaded(true); return; }

      try {
        // ✅ participant row가 없으면 먼저 생성(또는 캐시 사용)
        const pid = await ensureParticipantId();
        if (!pid) { if (!cancelled) setAnswersLoaded(true); return; }

        // response를 항상 동일하게(1명=1응답) 가져와서 답변을 불러온다.
        const { data: rid, error: re } = await supabase.rpc('get_or_create_trait_response', {
          p_participant_id: pid,
          p_client_id: clientId,
          p_user_agent: navigator.userAgent,
        } as any);
        if (re || !rid) {
          console.error(re);
          if (!cancelled) setAnswersLoaded(true);
          return;
        }
        const rId = String(rid);
        setResponseId(rId);

        const { data: rows, error: ae } = await supabase.rpc('list_trait_answers', { p_response_id: rId } as any);
        if (ae) {
          console.error(ae);
          if (!cancelled) setAnswersLoaded(true);
          return;
        }
        const map: Record<string, number | string> = {};
        for (const row of (rows as any[] | null) ?? []) {
          const qid = String(row.question_id);
          if (row.answer_number != null) map[qid] = Number(row.answer_number);
          else if (row.answer_text != null) map[qid] = String(row.answer_text);
        }
        setAnswers(map);
      } catch (e) {
        console.error(e);
      } finally {
        if (!cancelled) setAnswersLoaded(true);
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
    return () => {
      cancelled = true;
    };
  }, [hasSupabaseEnv, participantInfo.sid, slug]);

  const hasAnswer = (qid: string) => {
    const v = answers[qid];
    if (v == null) return false;
    if (typeof v === 'string') return v.trim().length > 0;
    return true;
  };

  const sortedRounds = useMemo(() => {
    return [...rounds].sort((a, b) => (a.order_index ?? 0) - (b.order_index ?? 0));
  }, [rounds]);

  const roundOrderMap = useMemo(() => {
    const map: Record<string, number> = {};
    sortedRounds.forEach((r, i) => {
      const name = String(r.name ?? '').trim();
      if (name) map[name] = i + 1;
    });
    return map;
  }, [sortedRounds]);

  const normalizedQuestions = useMemo(() => {
    return questions.map((q, orderIndex) => {
      const roundLabel = String(q.round_label ?? '').trim();
      const roundNo = roundOrderMap[roundLabel] ?? parseRoundNo(q.round_label) ?? 1;
      const partNo = parsePartNo(q.part_index) ?? 1;
      return { ...q, round_no: roundNo, part_no: partNo, order_index: orderIndex };
    });
  }, [questions, roundOrderMap]);

  const hasRoundData = useMemo(() => {
    return questions.some((q) => String(q.round_label ?? '').trim().length > 0);
  }, [questions]);

  const roundQuestionsByNo = useMemo(() => {
    const map: Record<number, NormalizedQuestion[]> = {};
    for (const q of normalizedQuestions) {
      if (!map[q.round_no]) map[q.round_no] = [];
      map[q.round_no].push(q);
    }
    for (const key of Object.keys(map)) {
      const list = map[Number(key)];
      list.sort((a, b) => {
        if (a.part_no !== b.part_no) return a.part_no - b.part_no;
        return a.order_index - b.order_index;
      });
    }
    return map;
  }, [normalizedQuestions]);

  const roundNos = useMemo(() => {
    return Object.keys(roundQuestionsByNo).map(Number).sort((a, b) => a - b);
  }, [roundQuestionsByNo]);

  useEffect(() => {
    if (activeRound != null) return;
    if (!answersLoaded || normalizedQuestions.length === 0) return;
    if (!hasRoundData || roundNos.length <= 1) {
      setActiveRound(roundNos[0] ?? 1);
      return;
    }
    const round1 = roundQuestionsByNo[1] ?? roundQuestionsByNo[roundNos[0]];
    const round2 = roundQuestionsByNo[2] ?? roundQuestionsByNo[roundNos[1]];
    const round1Complete = !!round1?.length && round1.every((q) => hasAnswer(q.id));
    const nextRound = round1Complete && round2?.length ? 2 : 1;
    setActiveRound(nextRound);
  }, [activeRound, answersLoaded, normalizedQuestions.length, hasRoundData, roundNos, roundQuestionsByNo, answers]);

  useEffect(() => {
    setSeenParts({});
    setPartIntroOpen(false);
    setRoundIntroOpen(false);
    setRoundComplete(false);
    setIdx(0);
    setMaxVisitedIndex(0);
  }, [activeRound]);

  const currentRoundMeta = useMemo(() => {
    if (activeRound == null) return null;
    return sortedRounds[activeRound - 1] ?? null;
  }, [activeRound, sortedRounds]);

  const activeQuestionsRaw = useMemo(() => {
    if (activeRound == null) return [] as NormalizedQuestion[];
    return roundQuestionsByNo[activeRound] ?? [];
  }, [activeRound, roundQuestionsByNo]);

  const isPreSurveyRound = useMemo(() => {
    const metaName = currentRoundMeta?.name ?? '';
    if (metaName.includes('사전')) return true;
    const sampleLabel = String(activeQuestionsRaw[0]?.round_label ?? '');
    if (sampleLabel.includes('사전')) return true;
    const firstRoundNo = roundNos[0] ?? 1;
    return activeRound === firstRoundNo;
  }, [currentRoundMeta, activeQuestionsRaw, activeRound, roundNos]);

  useEffect(() => {
    if (activeRound == null) return;
    if (!activeQuestionsRaw.length) return;
    if (!isPreSurveyRound) return;
    const key = `trait_round_order:${slug}:${activeRound}:${clientId}`;
    let order: string[] | null = null;
    try {
      const raw = localStorage.getItem(key);
      if (raw) {
        const parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) order = parsed.filter((v) => typeof v === 'string');
      }
    } catch {}
    const ids = activeQuestionsRaw.map((q) => q.id);
    if (!order || order.length !== ids.length || order.some((id) => !ids.includes(id))) {
      order = shuffleList(ids);
      try {
        localStorage.setItem(key, JSON.stringify(order));
      } catch {}
    }
    setRoundOrders((prev) => ({ ...prev, [activeRound]: order as string[] }));
  }, [activeRound, activeQuestionsRaw, isPreSurveyRound, slug, clientId]);

  const activeQuestions = useMemo(() => {
    if (!activeQuestionsRaw.length) return [] as NormalizedQuestion[];
    if (!isPreSurveyRound) return activeQuestionsRaw;
    const order = activeRound != null ? roundOrders[activeRound] : null;
    if (!order || !order.length) return activeQuestionsRaw;
    const rank = new Map(order.map((id, i) => [id, i]));
    return [...activeQuestionsRaw].sort((a, b) => {
      return (rank.get(a.id) ?? 0) - (rank.get(b.id) ?? 0);
    });
  }, [activeQuestionsRaw, isPreSurveyRound, roundOrders, activeRound]);

  const current = activeQuestions[idx];
  const totalQuestions = activeQuestions.length;
  const progressPercent = totalQuestions > 0
    ? Math.round(((idx + 1) / totalQuestions) * 100)
    : 0;
  const secondRoundNo = roundNos.length > 1 ? roundNos[1] : null;
  const isSecondRound = secondRoundNo != null && activeRound === secondRoundNo;
  const round2Blocked = !isInWebViewHost && !!secondRoundNo && isSecondRound && round2Access !== 'allowed';
  const round2BlockMessage = round2Access === 'unknown'
    ? '링크를 확인 중입니다...'
    : (round2AccessMsg || '2차 설문은 이메일로 받은 링크에서만 진행할 수 있습니다.');

  const roundPartsByRoundId = useMemo(() => {
    const map: Record<string, TraitRoundPart[]> = {};
    for (const p of roundParts) {
      if (!map[p.round_id]) map[p.round_id] = [];
      map[p.round_id].push(p);
    }
    for (const key of Object.keys(map)) {
      map[key].sort((a, b) => (a.order_index ?? 0) - (b.order_index ?? 0));
    }
    return map;
  }, [roundParts]);

  const currentRoundParts = useMemo(() => {
    if (!currentRoundMeta) return [];
    return roundPartsByRoundId[currentRoundMeta.id] ?? [];
  }, [currentRoundMeta, roundPartsByRoundId]);

  const hasPartsForRound = currentRoundParts.length > 0;

  const currentPartNo = current?.part_no ?? 1;
  const currentPartMeta = useMemo(() => {
    if (!currentRoundParts.length) return null;
    const idx = Math.max(0, currentPartNo - 1);
    return currentRoundParts[idx] ?? null;
  }, [currentRoundParts, currentPartNo]);

  const fallbackRoundLabel = String(current?.round_label ?? '').trim();
  const currentRoundLabel = currentRoundMeta?.name ?? (fallbackRoundLabel || (activeRound ? `${activeRound}차` : ''));
  const currentPartLabel = hasPartsForRound
    ? (currentPartMeta?.name ?? (currentPartNo ? `파트 ${currentPartNo}` : ''))
    : '';
  const roundKey = activeRound != null ? `round:${activeRound}` : '';

  useEffect(() => {
    if (!current || activeRound == null || !hasRoundData) {
      setRoundIntroOpen(false);
      return;
    }
    if (roundKey && !seenRounds[roundKey]) {
      setRoundIntroOpen(true);
      return;
    }
    setRoundIntroOpen(false);
  }, [current, activeRound, hasRoundData, roundKey, seenRounds]);

  const progressLabel = [currentRoundLabel, currentPartLabel].filter(Boolean).join(' · ');
  const questionPositionLabel = `${idx + 1} / ${activeQuestions.length}`;
  const headerLabel = progressLabel ? `${progressLabel} · ${questionPositionLabel}` : questionPositionLabel;

  useEffect(() => {
    const q = activeQuestions[idx];
    if (!q) return;
    setImgLoaded(false);
    setImgErr(null);
    setImgSrc(resolveImageUrl(q.image_url));
    const prev = answers[q.id];
    if (q.type === 'scale') {
      setScaleValue(typeof prev === 'number' ? (prev as number) : null);
      setTextValue('');
    } else {
      setTextValue(typeof prev === 'string' ? (prev as string) : '');
      setScaleValue(null);
    }
  }, [idx, activeQuestions, answers]);

  useEffect(() => {
    const shouldRunTimer = !!current
      && !roundIntroOpen
      && !partIntroOpen
      && !confirmOpen
      && !needAnswerOpen
      && pageActive;

    if (!current) return;
    if (lastQuestionIdRef.current !== current.id) {
      lastQuestionIdRef.current = current.id;
      questionVisibleAtRef.current = Date.now();
      questionElapsedRef.current = 0;
      questionStartRef.current = null;
      timerRunningRef.current = false;
    }

    if (shouldRunTimer) {
      if (questionStartRef.current == null) {
        questionStartRef.current = Date.now();
        timerRunningRef.current = true;
      }
    } else if (questionStartRef.current != null) {
      questionElapsedRef.current += Date.now() - questionStartRef.current;
      questionStartRef.current = null;
      timerRunningRef.current = false;
    }
  }, [current, roundIntroOpen, partIntroOpen, confirmOpen, needAnswerOpen, pageActive]);

  const partKey = current && hasPartsForRound ? `${activeRound ?? 0}:${currentPartNo}` : '';
  const isFirstOfPart = !!current && hasPartsForRound && (idx === 0 || activeQuestions[idx - 1]?.part_no !== currentPartNo);

  useEffect(() => {
    if (roundIntroOpen) {
      setPartIntroOpen(false);
      return;
    }
    if (!current || !hasPartsForRound || !activeQuestions.length) {
      setPartIntroOpen(false);
      return;
    }
    if (isFirstOfPart && partKey && !seenParts[partKey]) {
      setPartIntroOpen(true);
      return;
    }
    setPartIntroOpen(false);
  }, [current, hasPartsForRound, activeQuestions.length, isFirstOfPart, partKey, seenParts, roundIntroOpen]);

  useEffect(() => {
    if (!roundComplete) return;
    if (isInWebViewHost) return;
    if (roundNos.length < 2) return;
    if (round2LinkStatus !== 'idle') return;
    void sendRound2Link();
  }, [roundComplete, isInWebViewHost, roundNos.length, round2LinkStatus]);

  async function ensureParticipantId(): Promise<string | null> {
    if (participantId) return participantId;
    // ✅ 앱(WebView)에서는 sid(학생 uuid)를 참여자 id로 사용해 재진입 시 이어하기 가능
    const sid = participantInfo.sid;
    const sidIsUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sid);
    const cacheKey = sidIsUuid ? `trait_participant_id:${slug}:${sid}` : `trait_participant_id:${slug}`;
    const cached = sessionStorage.getItem(cacheKey);
    if (cached) { setParticipantId(cached); return cached; }
    const pid = sidIsUuid ? sid : newUuid();
    // ✅ 권장: get_or_create RPC(SECURITY DEFINER)로 participant를 보장한다.
    // - 기존학생 재진입 시 PK 중복으로 실패하는 문제 해결
    const { data: out, error: pe } = await supabase.rpc('get_or_create_trait_participant', {
      p_participant_id: pid,
      p_survey_slug: slug,
      p_client_id: clientId,
      p_name: participantInfo.name || null,
      p_school: participantInfo.school || null,
      p_level: participantInfo.level || null,
      p_grade: participantInfo.grade || null,
      p_email: participantInfo.email || null,
    } as any);
    if (pe || !out) { console.error(pe); setToast(`참여자 정보를 저장하지 못했습니다. (${pe?.message || 'unknown'})`); return null; }
    sessionStorage.setItem(cacheKey, pid);
    setParticipantId(pid);
    return pid;
  }

  async function ensureResponseId(): Promise<string | null> {
    if (responseId) return responseId;
    const sid = participantInfo.sid;
    const sidIsUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sid);
    const cacheKey = sidIsUuid ? `trait_response_id:${slug}:${sid}` : `trait_response_id:${slug}`;
    let rid = sessionStorage.getItem(cacheKey);
    if (rid) { setResponseId(rid); return rid; }
    // ✅ 기존학생/신규학생 플로우: 설문 시작 전 participant를 먼저 생성
    // (anon은 select가 막혀있어 "조회 후 재사용" 불가)
    const pid = await ensureParticipantId();
    if (!pid) return null;
    // ✅ 1명=1응답 형태로 이어하기 위해 RPC로 response를 생성/조회한다.
    const { data: rpcRid, error: re } = await supabase.rpc('get_or_create_trait_response', {
      p_participant_id: pid,
      p_client_id: clientId,
      p_user_agent: navigator.userAgent,
    } as any);
    if (re || !rpcRid) { console.error(re); setToast(`오류가 발생했습니다. (${re?.message || 'unknown'})`); return null; }
    rid = String(rpcRid);
    sessionStorage.setItem(cacheKey, rid); setResponseId(rid);
    return rid;
  }

  async function sendRound2Link(): Promise<boolean> {
    if (isInWebViewHost) return false;
    if (!hasSupabaseEnv) {
      setRound2LinkStatus('error');
      setRound2LinkError('설문 서버 설정이 없어 이메일을 전송할 수 없습니다.');
      return false;
    }
    const email = participantInfo.email.trim();
    if (!email) {
      setRound2LinkStatus('error');
      setRound2LinkError('이메일 정보가 없습니다.');
      return false;
    }
    if (!isValidEmail(email)) {
      setRound2LinkStatus('error');
      setRound2LinkError('이메일 형식을 확인해주세요.');
      return false;
    }
    const pid = await ensureParticipantId();
    const rid = await ensureResponseId();
    if (!pid || !rid) {
      setRound2LinkStatus('error');
      setRound2LinkError('참여자 정보를 확인하지 못했습니다.');
      return false;
    }
    setRound2LinkStatus('sending');
    setRound2LinkError(null);
    const baseUrl = window.location.origin;
    const { data, error } = await supabase.functions.invoke('trait_round2_link_send', {
      body: {
        participant_id: pid,
        response_id: rid,
        email,
        base_url: baseUrl,
      },
    });
    if (error || (data as any)?.error) {
      const msg = (data as any)?.error || error?.message || '메일 전송 실패';
      setRound2LinkStatus('error');
      setRound2LinkError(String(msg));
      return false;
    }
    setRound2LinkStatus('sent');
    return true;
  }

  async function saveCurrentAnswer(): Promise<boolean> {
    const q = current; // 현재 문항 스냅샷 고정
    if (!q || isSavingRef.current) return false;

    const rid = await ensureResponseId();
    if (!rid) return false;

    isSavingRef.current = true;

    // 1. 시간 계산 (동기적으로 즉시 수행)
    const startedAt = questionStartRef.current;
    const elapsedSoFar = questionElapsedRef.current;
    const visibleAt = questionVisibleAtRef.current;
    const runningMs = startedAt != null ? (Date.now() - startedAt) : 0;
    let elapsedMs = Math.round(elapsedSoFar + runningMs);
    if (startedAt == null && elapsedSoFar <= 0 && visibleAt != null) {
      elapsedMs = Math.round(Date.now() - visibleAt);
    }
    elapsedMs = Math.max(0, elapsedMs);
    const isFast = elapsedMs < FAST_RESPONSE_MS;

    // 2. 응답 값 스냅샷 고정
    const answerNumber = q.type === 'scale' ? scaleValue : null;
    const answerText = q.type === 'text' ? textValue : null;

    // 3. 타이머 리셋 (중요: DB 저장 전에 동기적으로 리셋하여 다음 문항 타이머와의 간섭 차단)
    questionStartRef.current = null;
    questionElapsedRef.current = 0;
    timerRunningRef.current = false;
    questionVisibleAtRef.current = null;

    try {
      // ✅ 1순위: RPC(SECURITY DEFINER)로 저장
      const { error: rpcErr } = await supabase.rpc('save_question_answer', {
        p_response_id: rid,
        p_question_id: q.id,
        p_answer_number: answerNumber,
        p_answer_text: answerText,
        p_response_ms: elapsedMs,
        p_is_fast: isFast,
      } as any);

      if (rpcErr) {
        console.error('[save_question_answer][rpc]', rpcErr);
        const payload: any = { response_id: rid, question_id: q.id };
        if (q.type === 'scale') payload.answer_number = answerNumber;
        else payload.answer_text = answerText;
        payload.response_ms = elapsedMs;
        payload.is_fast = isFast;
        const { error } = await supabase
          .from('question_answers')
          .upsert(payload, { onConflict: 'response_id,question_id' });

        if (error) {
          console.error('[question_answers][upsert]', error);
          setToast(`답변 저장 중 오류: ${error.message || 'unknown'}`);
          return false;
        }
      }
      setAnswers((m) => ({ ...m, [q.id]: q.type === 'scale' ? (answerNumber as number) : (answerText as string) }));
      return true;
    } finally {
      isSavingRef.current = false;
    }
  }

  const isAnswered = current
    ? (current.type === 'scale' ? scaleValue !== null : isValidNonNegativeInt(textValue))
    : false;

  async function onNext() {
    if (!current) return;
    if (!isAnswered) { setNeedAnswerOpen(true); return; }
    const ok = await saveCurrentAnswer();
    if (!ok) return;
    if (idx + 1 < activeQuestions.length) {
      const nextIdx = idx + 1;
      setIdx(nextIdx);
      setMaxVisitedIndex((m) => Math.max(m, nextIdx));
    } else {
      if (isPreSurveyRound) {
        setRoundComplete(true);
        return;
      }
      setConfirmOpen(true);
    }
  }

  function onPrev() {
    if (idx > 0) setIdx(idx - 1);
  }

  // answers가 로드된 뒤, 첫 미응답 문항으로 자동 이동(이어하기)
  useEffect(() => {
    if (!activeQuestions.length) return;
    const firstUnanswered = activeQuestions.findIndex((q) => answers[q.id] == null || (typeof answers[q.id] === 'string' && String(answers[q.id]).trim() === ''));
    const nextIdx = firstUnanswered >= 0 ? firstUnanswered : Math.max(0, activeQuestions.length - 1);
    if (idx !== nextIdx) setIdx(nextIdx);
    setMaxVisitedIndex((m) => Math.max(m, nextIdx));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeQuestions, answers]);

  if (loading) return <p style={{ color: tokens.textDim }}>불러오는 중...</p>;
  if (submitted) return (
    <div style={{ minHeight:'60vh', display:'flex', alignItems:'center', justifyContent:'center' }}>
      <div style={{ fontSize: 18, color: tokens.text, fontWeight: 900 }}>참여해 주셔서 감사합니다!</div>
    </div>
  );
  if (roundComplete) {
    return (
      <div style={{ minHeight:'60vh', display:'flex', alignItems:'center', justifyContent:'center' }}>
        <div style={{ background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 14, padding: 24, minWidth: 320 }}>
          <div style={{ fontSize: 20, fontWeight: 900, color: tokens.text }}>수고하셨습니다!</div>
          <div style={{ marginTop: 10, color: tokens.textFaint, lineHeight: 1.5 }}>
            사전 조사가 완료되었습니다. 감사합니다.
            {!isInWebViewHost && secondRoundNo ? (
              <div style={{ marginTop: 8 }}>
                2차 설문 링크를 이메일로 전송했습니다. 해당 링크로 접속해 진행해 주세요.
              </div>
            ) : null}
            {!isInWebViewHost && round2LinkStatus === 'sending' ? (
              <div style={{ marginTop: 8 }}>이메일 전송 중...</div>
            ) : null}
            {!isInWebViewHost && round2LinkStatus === 'sent' ? (
              <div style={{ marginTop: 8, color: '#7ED957' }}>이메일 전송 완료</div>
            ) : null}
            {!isInWebViewHost && round2LinkStatus === 'error' ? (
              <div style={{ marginTop: 8, color: tokens.danger }}>
                링크 전송 실패: {round2LinkError || '알 수 없는 오류'}
              </div>
            ) : null}
          </div>
          <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 18 }}>
            <button
              type="button"
              onClick={() => {
                sessionStorage.removeItem('trait_response_id');
                sessionStorage.removeItem('trait_participant_id');
                onSaveAndExit(true);
              }}
              style={{
                background: tokens.accent,
                color: '#fff',
                border: 'none',
                padding: '10px 18px',
                borderRadius: 10,
                fontWeight: 800,
                cursor: 'pointer',
              }}
            >
              종료
            </button>
          </div>
        </div>
      </div>
    );
  }

  if (round2Blocked) {
    return (
      <div style={{ minHeight:'60vh', display:'flex', alignItems:'center', justifyContent:'center' }}>
        <div style={{ background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 14, padding: 24, minWidth: 320, maxWidth: 520 }}>
          <div style={{ fontSize: 20, fontWeight: 900, color: tokens.text }}>2차 설문 안내</div>
          <div style={{ marginTop: 10, color: tokens.textFaint, lineHeight: 1.5 }}>
            {round2BlockMessage}
          </div>
          <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 18 }}>
            <button
              type="button"
              onClick={goHome}
              style={{
                background: tokens.accent,
                color: '#fff',
                border: 'none',
                padding: '10px 18px',
                borderRadius: 10,
                fontWeight: 800,
                cursor: 'pointer',
              }}
            >
              홈으로
            </button>
          </div>
        </div>
      </div>
    );
  }

  if (!current) {
    return (
      <div style={{ maxWidth: 720, margin: pageMargin, padding: pagePadding }}>
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

  const roundImageSrc = currentRoundMeta?.image_url ? resolveImageUrl(currentRoundMeta.image_url) : null;
  const partImageSrc = currentPartMeta?.image_url ? resolveImageUrl(currentPartMeta.image_url) : null;
  const isFinalRound = activeRound != null ? (roundNos.length <= 1 || activeRound === roundNos[roundNos.length - 1]) : true;

  return (
    <div style={{ maxWidth: 720, margin: pageMargin, padding: pagePadding }}>
      {roundIntroOpen && current ? (
        <div
          style={{
            background: tokens.panel,
            border: `1px solid ${tokens.border}`,
            borderRadius: 14,
            padding: 20,
          }}
        >
          <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 6 }}>회차 안내</div>
          <div style={{ fontSize: 24, fontWeight: 900, color: tokens.text }}>{currentRoundLabel}</div>
          {currentRoundMeta?.description && (
            <div style={{ marginTop: 10, color: tokens.textFaint, lineHeight: 1.5 }}>
              {currentRoundMeta.description}
            </div>
          )}
          {roundImageSrc && (
            <div style={{ marginTop: 16 }}>
              <img
                src={roundImageSrc}
                alt="round"
                loading="eager"
                decoding="async"
                style={{
                  width: '100%',
                  maxHeight: 320,
                  objectFit: 'contain',
                  borderRadius: 10,
                  border: `1px solid ${tokens.border}`,
                }}
              />
            </div>
          )}
          <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 18 }}>
            <button
              type="button"
              onClick={() => {
                if (roundKey) {
                  setSeenRounds((m) => ({ ...m, [roundKey]: true }));
                }
                setRoundIntroOpen(false);
              }}
              style={{
                background: tokens.accent,
                color: '#fff',
                border: 'none',
                padding: '12px 22px',
                borderRadius: 12,
                fontWeight: 900,
                cursor: 'pointer',
              }}
            >
              다음
            </button>
          </div>
        </div>
      ) : partIntroOpen && current ? (
        <div
          style={{
            background: tokens.panel,
            border: `1px solid ${tokens.border}`,
            borderRadius: 14,
            padding: 20,
          }}
        >
          {currentRoundLabel && (
            <div style={{ color: tokens.textDim, fontSize: 12, marginBottom: 6 }}>{currentRoundLabel}</div>
          )}
          <div style={{ fontSize: 24, fontWeight: 900, color: tokens.text }}>{currentPartLabel}</div>
          {currentPartMeta?.description && (
            <div style={{ marginTop: 10, color: tokens.textFaint, lineHeight: 1.5 }}>
              {currentPartMeta.description}
            </div>
          )}
          {partImageSrc && (
            <div style={{ marginTop: 16 }}>
              <img
                src={partImageSrc}
                alt="part"
                loading="eager"
                decoding="async"
                style={{
                  width: '100%',
                  maxHeight: 320,
                  objectFit: 'contain',
                  borderRadius: 10,
                  border: `1px solid ${tokens.border}`,
                }}
              />
            </div>
          )}
          <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 18 }}>
            <button
              type="button"
              onClick={() => {
                if (partKey) {
                  setSeenParts((m) => ({ ...m, [partKey]: true }));
                }
                setPartIntroOpen(false);
              }}
              style={{
                background: tokens.accent,
                color: '#fff',
                border: 'none',
                padding: '12px 22px',
                borderRadius: 12,
                fontWeight: 900,
                cursor: 'pointer',
              }}
            >
              시작
            </button>
          </div>
        </div>
      ) : current ? (
        <div>
          <div style={{ display:'flex', alignItems:'center', justifyContent:'space-between', gap:12, marginBottom: 12 }}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ color: tokens.textFaint, marginBottom: 6 }}>{headerLabel}</div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <div style={{ flex: 1, height: 8, background: tokens.field, border: `1px solid ${tokens.border}`, borderRadius: 999, overflow: 'hidden' }}>
                  <div style={{ width: `${progressPercent}%`, height: '100%', background: tokens.accent }} />
                </div>
                <div style={{ color: tokens.textFaint, fontSize: 12, minWidth: 48, textAlign: 'right' }}>{progressPercent}%</div>
              </div>
            </div>
            <button
              type="button"
              onClick={() => {
                void onSaveAndExit();
              }}
              style={{ background:'transparent', color:tokens.textFaint, border:`1px solid ${tokens.border}`, padding:'8px 12px', borderRadius:10, cursor:'pointer', fontWeight:800, whiteSpace:'nowrap' }}
            >
              저장 후 종료
            </button>
          </div>
          <div style={{ fontSize: 22, marginBottom: 18, color: tokens.text }}>{current.text}</div>
          {imgSrc && (
            <div style={{ marginBottom: 16 }}>
              {/* ✅ WebView2에서 lazy 이미지가 첫 진입에 로딩 트리거가 늦는 케이스가 있어
                  eager 로딩 + "이미지 숨김(opacity 0)" 제거로 안정화 */}
              <div style={{ position: 'relative' }}>
                {!imgLoaded && (
                  <div
                    style={{
                      position: 'absolute',
                      inset: 0,
                      width: '100%',
                      height: 220,
                      background: tokens.field,
                      border: `1px solid ${tokens.border}`,
                      borderRadius: 8,
                      pointerEvents: 'none',
                    }}
                  />
                )}
              <img
                   key={imgSrc}
                   loading="eager"
                   decoding="async"
                   src={imgSrc || undefined}
                   alt="question"
                   onLoad={()=>{ setImgLoaded(true); setImgErr(null); }}
                   onError={async()=>{
                   try {
                     const url = imgSrc as string;
                     setImgErr('이미지를 불러오지 못했습니다.');
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
                     transition: 'filter 150ms',
                     filter: imgLoaded ? 'none' : 'brightness(0.98)',
                   }} />
              </div>
              {imgErr && (
                <div style={{ marginTop: 8, color: tokens.textFaint, fontSize: 12 }}>
                  {imgErr}
                </div>
              )}
            </div>
          )}
          {current.type === 'scale' ? (
            <div style={{ margin:`${current.image_url ? 30 : 48}px 0 24px` }}>
              {(() => {
                const isNarrow = window.innerWidth < 720;
                const min = current.min ?? 1;
                const max = current.max ?? 10;
                const count = Math.max(1, (max - min + 1));
                const gap = isNarrow ? 4 : 12;
                const available = Math.min(720, window.innerWidth) - (pagePadding * 2) - (isNarrow ? 24 : 0);
                const rawBtnW = Math.floor((available - (count - 1) * gap) / count);
                const btnW = isNarrow ? Math.max(14, Math.min(44, rawBtnW)) : 48;
                const btnFont = isNarrow ? Math.max(11, Math.min(16, Math.round(btnW * 0.55))) : 16;
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
                            style={{ width:btnW, height:btnW, borderRadius:10, border:`1px solid ${tokens.border}`, background:on?tokens.accent:tokens.field, color:'#fff', cursor:'pointer', fontSize:btnFont }}>{v}</button>
                        );
                      })}
                    </div>
                    </div>
                  </div>
                );
              })()}
            </div>
          ) : (
            <input
              value={textValue}
              onChange={(e)=>setTextValue(normalizeNonNegativeInt(e.target.value))}
              inputMode="numeric"
              pattern="[0-9]*"
              placeholder="0 이상 정수 입력"
              style={{ width:'100%', height:44, padding:'0 12px', background:tokens.field, border:`1px solid ${tokens.border}`, borderRadius:10, color:tokens.text, marginBottom:24, boxSizing:'border-box', appearance:'textfield' as any }}
            />
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
              {idx + 1 === activeQuestions.length ? '제출' : '다음'}
            </button>
          </div>
        </div>
      ) : null}
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
            <div style={{ fontSize:18, fontWeight:900, marginBottom:12 }}>
              {isFinalRound ? '제출 확인' : `${currentRoundLabel || '1회차'} 종료`}
            </div>
            <div style={{ color:tokens.textFaint, marginBottom:16 }}>
              {isFinalRound
                ? '제출 후에는 답변을 수정할 수 없습니다. 제출하시겠습니까?'
                : '제출하면 1회차가 종료됩니다. 나중에 2회차를 이어서 진행할 수 있어요.'}
            </div>
            <div style={{ display:'flex', gap:8, justifyContent:'flex-end' }}>
              <button onClick={()=>setConfirmOpen(false)} style={{ background:'transparent', color:tokens.textFaint, border:`1px solid ${tokens.border}`, padding:'10px 16px', borderRadius:10, cursor:'pointer' }}>취소</button>
              <button
                onClick={async()=> {
                  sessionStorage.removeItem('trait_response_id');
                  sessionStorage.removeItem('trait_participant_id');
                  setConfirmOpen(false);
                  if (!isFinalRound) {
                    await onSaveAndExit(true);
                    return;
                  }
                  setSubmitted(true);
                  setToast('제출이 완료되었습니다. 감사합니다!');
                }}
                style={{ background:tokens.accent, color:'#fff', border:'none', padding:'10px 20px', borderRadius:10, cursor:'pointer', fontWeight:800 }}
              >
                {isFinalRound ? '제출' : '1회차 제출'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}




