import React, { Suspense, useEffect, useMemo, useRef, useState } from 'react';
import './global.css';
import { createRoot } from 'react-dom/client';
import { createPortal } from 'react-dom';
import { tokens } from './theme';
import packageJson from '../package.json';
import { getSupabaseConfig, supabase } from './lib/supabaseClient';

type EducationLevel = 'elementary' | 'middle' | 'high';

type ExistingStudent = {
  id: string;
  name: string;
  school?: string;
  level?: EducationLevel;
  grade?: string;
};

type RoundProgressState = 'inactive' | 'active' | 'done';

function levelLabel(level?: string): string {
  if (!level) return '-';
  if (level === 'elementary') return '초등';
  if (level === 'middle') return '중등';
  if (level === 'high') return '고등';
  return level; // fallback
}

function isValidEmail(email: string): boolean {
  const v = email.trim();
  if (!v) return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);
}

function parseRoundNo(value: unknown): number | null {
  const raw = String(value ?? '').trim();
  if (!raw) return null;
  const m = raw.match(/\d+/);
  if (!m) return null;
  const n = Number(m[0]);
  return Number.isFinite(n) ? n : null;
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function newUuid(): string {
  const cryptoObj = (globalThis as any).crypto as Crypto | undefined;
  if (cryptoObj?.randomUUID) return cryptoObj.randomUUID();
  if (!cryptoObj?.getRandomValues) {
    return `uuid_${Date.now()}_${Math.random().toString(16).slice(2)}`;
  }
  const bytes = new Uint8Array(16);
  cryptoObj.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// ✅ Supabase env 미설정 시에도 첫 화면(Landing)이 안 죽게,
// 설문/결과 페이지는 필요할 때만 로드(lazy import)한다.
const SurveyPage = React.lazy(() => import('./pages/SurveyPage'));
const ResultsPage = React.lazy(() => import('./pages/ResultsPage'));
const ReportPreviewPage = React.lazy(() => import('./pages/ReportPreviewPage'));
const APP_VERSION = packageJson.version;

function sendToAppViaHash(message: unknown): boolean {
  try {
    const encoded = encodeURIComponent(JSON.stringify(message));
    // ✅ 같은 값이면 hashchange가 안 뜰 수 있어 nonce를 붙인다.
    const nonce = `${Date.now()}_${Math.random().toString(16).slice(2)}`;
    window.location.hash = `__ygg__${nonce}__${encoded}`;
    return true;
  } catch {
    return false;
  }
}

function postToHost(message: unknown): boolean {
  const w = window as any;
  const host = w?.chrome?.webview;
  if (!host?.postMessage) return false;
  try {
    // ✅ WebView2 postMessage는 객체를 그대로 보내는게 정석.
    // 문자열(JSON.stringify)로 보내면 호스트/플러그인에서 한 번 더 감싸져
    // Flutter 쪽에서 Map 대신 String으로 들어와 메시지가 무시될 수 있음.
    host.postMessage(message);
    return true;
  } catch {
    return false;
  }
}

function subscribeHostMessages(onMessage: (msg: any) => void): (() => void) | null {
  const w = window as any;
  const host = w?.chrome?.webview;
  if (!host?.addEventListener) return null;
  const handler = (e: any) => {
    const raw = e?.data;
    if (raw == null) return;
    try {
      onMessage(typeof raw === 'string' ? JSON.parse(raw) : raw);
    } catch {
      // ignore
    }
  };
  host.addEventListener('message', handler);
  return () => host.removeEventListener('message', handler);
}

function subscribeYggEvents(onMessage: (msg: any) => void): () => void {
  const handler = (e: any) => {
    const msg = e?.detail;
    if (!msg || typeof msg !== 'object') return;
    onMessage(msg);
  };
  window.addEventListener('ygg_result', handler as any);
  return () => window.removeEventListener('ygg_result', handler as any);
}

function SectionHeader({ title, subtitle }: { title: string; subtitle?: string }) {
  return (
    <div style={{ marginTop: 18, marginBottom: 10 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <div style={{ width: 4, height: 16, borderRadius: 2, background: tokens.accent }} />
        <div style={{ color: tokens.text, fontSize: 16, fontWeight: 900 }}>{title}</div>
        {subtitle ? <div style={{ color: tokens.textFaint, fontSize: 13 }}>{subtitle}</div> : null}
      </div>
    </div>
  );
}

function FieldLabel({ text, required }: { text: string; required?: boolean }) {
  return (
    <label style={{ color: tokens.textDim, fontSize: 13, marginLeft: 2 }}>
      {text}{required ? ' *' : ''}
    </label>
  );
}

function TextInput({
  value,
  onChange,
  placeholder,
  inputMode,
}: {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  inputMode?: React.HTMLAttributes<HTMLInputElement>['inputMode'];
}) {
  return (
    <input
      value={value}
      onChange={(e) => onChange(e.target.value)}
      placeholder={placeholder}
      inputMode={inputMode}
      style={{
        width: '100%',
        height: 44,
        background: tokens.field,
        border: `1px solid ${tokens.border}`,
        borderRadius: 10,
        padding: '10px 12px',
        color: tokens.text,
        fontSize: 16,
        marginTop: 6,
        outline: 'none',
        boxSizing: 'border-box',
      }}
    />
  );
}

function TextArea({
  value,
  onChange,
  placeholder,
  rows = 3,
}: {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  rows?: number;
}) {
  return (
    <textarea
      value={value}
      onChange={(e) => onChange(e.target.value)}
      placeholder={placeholder}
      rows={rows}
      style={{
        width: '100%',
        background: tokens.field,
        border: `1px solid ${tokens.border}`,
        borderRadius: 10,
        padding: 12,
        color: tokens.text,
        fontSize: 15,
        marginTop: 6,
        outline: 'none',
        resize: 'none',
        boxSizing: 'border-box',
        lineHeight: 1.35,
      }}
    />
  );
}

function SelectBox({
  options,
  value,
  placeholder,
  onChange,
  style,
}: {
  options: string[];
  value: string;
  placeholder?: string;
  onChange: (v: string) => void;
  style?: React.CSSProperties;
}) {
  const [open, setOpen] = useState(false);
  const btnRef = useRef<HTMLButtonElement | null>(null);
  const popupRef = useRef<HTMLDivElement | null>(null);
  const [rect, setRect] = useState<DOMRect | null>(null);
  const label = value || placeholder || '선택';

  useEffect(() => {
    function onDoc(e: MouseEvent) {
      if (!open) return;
      const target = e.target as Node;
      if (btnRef.current && btnRef.current.contains(target)) return;
      if (popupRef.current && popupRef.current.contains(target)) return;
      setOpen(false);
    }
    document.addEventListener('mousedown', onDoc);
    return () => document.removeEventListener('mousedown', onDoc);
  }, [open]);

  function toggle() {
    if (!btnRef.current) return;
    setRect(btnRef.current.getBoundingClientRect());
    setOpen((s) => !s);
  }

  function pick(v: string) {
    onChange(v);
    setOpen(false);
  }

  return (
    <div style={{ position: 'relative', width: '100%', ...style }}>
      <button
        ref={btnRef}
        type="button"
        onClick={toggle}
        style={{
          width: '100%',
          height: 44,
          background: tokens.field,
          border: `1px solid ${tokens.border}`,
          borderRadius: 10,
          color: tokens.text,
          fontSize: 16,
          textAlign: 'left',
          padding: '10px 12px',
          cursor: 'pointer',
        }}
      >
        {label}
        <span style={{ float: 'right', opacity: 0.7 }}>▾</span>
      </button>

      {open && rect && createPortal(
        (() => {
          const gap = 6;
          const maxH = 320;
          const w = rect.width;
          const left = Math.max(gap, Math.min(rect.left, window.innerWidth - w - gap));
          const spaceDown = window.innerHeight - rect.bottom - gap;
          const spaceUp = rect.top - gap;
          const openDown = spaceDown >= Math.min(180, spaceUp);
          const height = Math.max(120, Math.min(maxH, openDown ? spaceDown : spaceUp));
          const top = openDown ? (rect.bottom + gap) : undefined;
          const bottom = !openDown ? (window.innerHeight - rect.top + gap) : undefined;

          return (
            <div
              ref={popupRef}
              style={{
                position: 'fixed',
                left,
                top,
                bottom,
                width: w,
                maxHeight: height,
                overflowY: 'auto',
                background: tokens.panel,
                border: `1px solid ${tokens.border}`,
                borderRadius: 10,
                zIndex: 9999,
              }}
            >
              {options.map((opt) => {
                const selected = opt === value;
                return (
                  <div
                    key={opt}
                    onMouseDown={(e) => { e.preventDefault(); e.stopPropagation(); pick(opt); }}
                    style={{
                      padding: '10px 12px',
                      cursor: 'pointer',
                      color: tokens.text,
                      fontSize: 16,
                      background: selected ? tokens.panelAlt : 'transparent',
                    }}
                    onMouseEnter={(e) => ((e.currentTarget as HTMLDivElement).style.background = tokens.panelAlt)}
                    onMouseLeave={(e) => ((e.currentTarget as HTMLDivElement).style.background = selected ? tokens.panelAlt : 'transparent')}
                  >
                    {opt}
                  </div>
                );
              })}
            </div>
          );
        })(),
        document.body
      )}
    </div>
  );
}

function useQuery() {
  return useMemo(() => new URLSearchParams(window.location.search), []);
}

function Landing({
  onPickNew,
  onPickExisting,
  isInWebViewHost,
}: {
  onPickNew: () => void;
  onPickExisting: () => void;
  isInWebViewHost: boolean;
}) {
  const card: React.CSSProperties = {
    flex: 1,
    minHeight: 240,
    background: tokens.panel,
    border: `1px solid ${tokens.border}`,
    borderRadius: 12,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    cursor: 'pointer',
    transition: 'background 160ms ease',
  };
  const label: React.CSSProperties = { color: tokens.text, fontSize: 30, fontWeight: 800 };
  const versionLabel: React.CSSProperties = { color: tokens.textFaint, marginTop: 8, fontSize: 12, letterSpacing: 0.6 };
  if (!isInWebViewHost) {
    return (
      <div style={{ maxWidth: 1100, margin: '64px auto 0' }}>
        <div style={{ textAlign: 'center', marginBottom: 24 }}>
          <div style={{ color: tokens.text, fontSize: 84, fontWeight: 900, letterSpacing: 0.5 }}>성향분석</div>
          <div style={versionLabel}>v{APP_VERSION}</div>
          <div style={{ color: tokens.textFaint, marginTop: 10, fontSize: 16 }}>테스트에 15분 정도가 소요됩니다.</div>
        </div>
        <div style={{ display: 'flex', justifyContent: 'center', marginTop: 18 }}>
          <div
            data-testid="btn-start"
            onClick={onPickNew}
            onMouseEnter={(e) => ((e.currentTarget as HTMLDivElement).style.background = tokens.panelAlt)}
            onMouseLeave={(e) => ((e.currentTarget as HTMLDivElement).style.background = tokens.panel)}
            style={{ ...card, maxWidth: 420, minHeight: 180 }}
          >
            <span style={label}>시작하기</span>
          </div>
        </div>
        <div style={{ textAlign: 'center', marginTop: 14, color: tokens.textDim, fontSize: 14, fontWeight: 800, letterSpacing: 1.2 }}>
          SISU MATH
        </div>
      </div>
    );
  }
  return (
    <div style={{ maxWidth: 1100, margin: '64px auto 0' }}>
      <div style={{ textAlign: 'center', marginBottom: 24 }}>
        <div style={{ color: tokens.text, fontSize: 84, fontWeight: 900, letterSpacing: 0.5 }}>성향분석</div>
        <div style={versionLabel}>v{APP_VERSION}</div>
        <div style={{ color: tokens.textFaint, marginTop: 10, fontSize: 16 }}>테스트에 15분 정도가 소요됩니다.</div>
      </div>
      <div style={{ display: 'flex', gap: 18, marginTop: 18 }}>
      <div
        data-testid="btn-existing"
        onClick={onPickExisting}
        onMouseEnter={(e) => ((e.currentTarget as HTMLDivElement).style.background = tokens.panelAlt)}
        onMouseLeave={(e) => ((e.currentTarget as HTMLDivElement).style.background = tokens.panel)}
        style={card}
      >
        <span style={label}>기존학생</span>
      </div>
      <div
        data-testid="btn-new"
        onClick={onPickNew}
        onMouseEnter={(e) => ((e.currentTarget as HTMLDivElement).style.background = tokens.panelAlt)}
        onMouseLeave={(e) => ((e.currentTarget as HTMLDivElement).style.background = tokens.panel)}
        style={card}
      >
        <span style={label}>신규학생</span>
      </div>
      </div>
    </div>
  );
}

function NewStudentForm({
  onRegistered,
  onBack,
  isInWebViewHost,
}: {
  onRegistered?: (student?: { id: string; name: string; school: string; level: EducationLevel; grade: string; email?: string }) => void;
  onBack?: () => void;
  isInWebViewHost: boolean;
}) {
  const q = useQuery();
  const [page, setPage] = useState<'basic' | 'details'>('basic');
  const [name, setName] = useState('');
  const [level, setLevel] = useState<EducationLevel>('elementary');
  const [grade, setGrade] = useState('');
  const [school, setSchool] = useState('');
  const [email, setEmail] = useState('');
  const [studentPhone, setStudentPhone] = useState('');
  const [parentPhone, setParentPhone] = useState('');
  // ✅ 추가 입력(양식만)
  const [progressCurrent, setProgressCurrent] = useState('');
  const [progressPrev, setProgressPrev] = useState('');
  const [examBook, setExamBook] = useState('');
  const [examCorrectRate, setExamCorrectRate] = useState(''); // %
  const [scoreLatest, setScoreLatest] = useState('');
  const [scoreRecent4Max, setScoreRecent4Max] = useState('');
  const [scoreRecent4Min, setScoreRecent4Min] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [pendingRequestId, setPendingRequestId] = useState<string | null>(null);
  const submitTimerRef = useRef<number | null>(null);

  const sid = q.get('sid') ?? '';
  const isSimpleWeb = !isInWebViewHost;

  const [isNarrow, setIsNarrow] = useState<boolean>(false);
  useEffect(() => {
    const onResize = () => setIsNarrow(window.innerWidth < 980);
    onResize();
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);

  // ✅ 과정+학년을 한 번에 선택 (학생등록 다이얼로그 톤과 동일한 UX)
  const gradeOptions = useMemo(() => {
    const out: { label: string; level: EducationLevel; grade: string }[] = [];
    const push = (lv: EducationLevel, kLabel: string, gs: string[]) => {
      for (const g of gs) out.push({ label: `${kLabel} ${g}`, level: lv, grade: g });
    };
    push('elementary', '초등', ['1', '2', '3', '4', '5', '6']);
    push('middle', '중등', ['1', '2', '3']);
    push('high', '고등', ['1', '2', '3', 'N수']);
    return out;
  }, []);
  const selectedGradeLabel = useMemo(() => {
    const hit = gradeOptions.find((x) => x.level === level && x.grade === grade);
    return hit ? hit.label : '';
  }, [gradeOptions, level, grade]);

  useEffect(() => {
    const onMsg = (msg: any) => {
      if (!msg || typeof msg !== 'object') return;
      if (!pendingRequestId || msg.requestId !== pendingRequestId) return;

      if (msg.type === 'new_student_progress') {
        // 앱에서 "수신/처리중" 등의 진행상태를 보내면 UI에 표시
        const stage = msg.stage ? String(msg.stage) : 'processing';
        if (stage === 'received') setOk('앱에서 수신했습니다. 처리 중...');
        else if (stage === 'saving') setOk('학생 등록 처리 중...');
        else if (stage === 'done') setOk('등록 마무리 중...');
        else setOk('앱에서 처리 중...');
        return;
      }

      if (msg.type !== 'new_student_result') return;

      if (submitTimerRef.current != null) {
        window.clearTimeout(submitTimerRef.current);
        submitTimerRef.current = null;
      }
      setSubmitting(false);
      setPendingRequestId(null);

      if (msg.ok) {
        setError(null);
        setOk('등록 완료');
        try {
          const id = msg.studentId ? String(msg.studentId) : '';
          if (id) {
            onRegistered?.({
              id,
              name: name.trim(),
              school: school.trim(),
              level,
              grade,
              email: email.trim() || undefined,
            });
          } else {
            onRegistered?.();
          }
        } catch {
          // ignore
        }
      } else {
        setOk(null);
        setError(msg.error ? String(msg.error) : '등록 실패');
      }
    };

    // 1) WebMessage 채널(동작하면 사용)
    const unsubHost = subscribeHostMessages(onMsg);
    // 2) ✅ 안전장치: hash->flutter->executeScript(CustomEvent) 경로
    const unsubYgg = subscribeYggEvents(onMsg);
    return () => {
      try { unsubHost?.(); } catch {}
      try { unsubYgg(); } catch {}
    };
  }, [pendingRequestId]);

  function validate(): string | null {
    if (!name.trim()) return '이름은 필수입니다.';
    if (!school.trim()) return '학교는 필수입니다.';
    if (!grade) return '학년을 선택해주세요.';
    if (!['elementary','middle','high'].includes(level)) return '과정을 선택해주세요.';
    if (isSimpleWeb && !email.trim()) return '이메일은 필수입니다.';
    if (email.trim() && !isValidEmail(email)) return '이메일 형식을 확인해주세요.';
    if (studentPhone.trim() && !/^\d{9,11}$/.test(studentPhone.replace(/[^0-9]/g, ''))) return '학생 연락처는 숫자 9~11자리로 입력하세요.';
    if (parentPhone.trim() && !/^\d{9,11}$/.test(parentPhone.replace(/[^0-9]/g, ''))) return '학부모 연락처는 숫자 9~11자리로 입력하세요.';
    return null;
  }

  function validateBasic(): string | null {
    if (!name.trim()) return '이름은 필수입니다.';
    if (!school.trim()) return '학교는 필수입니다.';
    if (!grade) return '과정/학년을 선택해주세요.';
    if (isSimpleWeb && !email.trim()) return '이메일은 필수입니다.';
    if (email.trim() && !isValidEmail(email)) return '이메일 형식을 확인해주세요.';
    if (studentPhone.trim() && !/^\d{9,11}$/.test(studentPhone.replace(/[^0-9]/g, ''))) {
      return '학생 연락처는 숫자 9~11자리로 입력하세요.';
    }
    if (parentPhone.trim() && !/^\d{9,11}$/.test(parentPhone.replace(/[^0-9]/g, ''))) {
      return '학부모 연락처는 숫자 9~11자리로 입력하세요.';
    }
    return null;
  }

  function submitNewStudent() {
    if (isSimpleWeb) {
      setError(null); setOk(null);
      const err = validateBasic();
      if (err) { setError(err); return; }
      const id = (sid && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(sid))
        ? sid
        : newUuid();
      onRegistered?.({
        id,
        name: name.trim(),
        school: school.trim(),
        level,
        grade,
        email: email.trim(),
      });
      return;
    }
    // ✅ 2/2(추가정보) 단계에서 "시작" 버튼을 눌렀을 때만 전송한다.
    // (1/2 → 2/2 전환 시점에 의도치 않게 전송/설문 시작되는 현상 방지)
    if (page !== 'details') return;
    setError(null); setOk(null);
    const err = validate();
    if (err) { setError(err); return; }
    const payload = {
      sid,
      name: name.trim(),
      level,
      grade: grade, // 'N수' 포함 가능
      school: school.trim(),
      studentPhone: studentPhone.trim() || undefined,
      parentPhone: parentPhone.trim() || undefined,
      // 아래는 양식만(서버 저장 로직 없음)
      progress: { current: progressCurrent.trim() || undefined, previous: progressPrev.trim() || undefined },
      exam: {
        book: examBook.trim() || undefined,
        approxCorrectRate: examCorrectRate.trim() || undefined, // e.g. "70"
      },
      score: {
        latest: scoreLatest.trim() || undefined,
        recent4Max: scoreRecent4Max.trim() || undefined,
        recent4Min: scoreRecent4Min.trim() || undefined,
      },
    };

    const requestId = `req_${Date.now()}_${Math.random().toString(16).slice(2)}`;

    // ✅ 1순위: URL hash 브릿지(가장 안정적, 플러그인 설정 영향 적음)
    // ✅ 2순위: WebView2 postMessage(동작하면 그대로 사용)
    const msg = { type: 'new_student_submit', requestId, payload };
    const sent = sendToAppViaHash(msg) || postToHost(msg);
    if (sent) {
      setSubmitting(true);
      setPendingRequestId(requestId);
      setOk('앱으로 전송 중...');
      if (submitTimerRef.current != null) window.clearTimeout(submitTimerRef.current);
      submitTimerRef.current = window.setTimeout(() => {
        setSubmitting(false);
        setPendingRequestId(null);
        setOk(null);
        setError('앱 응답이 지연되고 있습니다. 앱 상태를 확인 후 다시 시도해 주세요.');
        }, 60000);
      return;
    }

    // WebView 안이 아니면(브라우저 단독 실행 등) 기존처럼 콘솔 출력
    console.log('[SURVEY][NEW_STUDENT_SUBMIT]', payload);
    setOk('제출 완료 (브라우저 단독 실행: 앱 연동 없음)');
  }

  return (
    <form
      onSubmit={(e) => {
        // ✅ submit 이벤트로는 절대 전송하지 않는다. (Enter/암묵적 submit 방지)
        e.preventDefault();
      }}
      onKeyDown={(e) => {
        // ✅ Enter 키로 인한 "자동 제출" 방지 (특히 2/2에서 입력 중 Enter → submit 되는 문제)
        const t = e.target as HTMLElement | null;
        if (e.key === 'Enter' && t?.tagName === 'INPUT') {
          e.preventDefault();
        }
      }}
      style={{
        width: isNarrow ? '92vw' : '40vw',
        maxWidth: 1100,
        margin: '32px auto 0',
        background: tokens.panel,
        border: `1px solid ${tokens.border}`,
        borderRadius: 16,
        padding: 28,
        boxSizing: 'border-box',
        // ✅ 스크롤/드롭다운 잘림 방지
        overflow: 'visible',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'flex-start', gap: 12, marginBottom: 14 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 900, color: tokens.text }}>
            {isSimpleWeb ? '설문 시작' : '신규학생 등록'}
          </div>
          <div style={{ marginTop: 4, color: tokens.textFaint, fontSize: 13 }}>
            {isSimpleWeb
              ? '필수 정보를 입력해 주세요.'
              : (page === 'basic' ? '1/2 · 필수 정보와 연락처를 입력해 주세요.' : '2/2 · 추가 정보를 입력해 주세요.')}
          </div>
        </div>
      </div>

      <div style={{ height: 1, background: tokens.border, margin: '14px 0 10px' }} />

      {!isSimpleWeb && page === 'details' ? (
        <>
          <SectionHeader title="진도" subtitle="현재/이전 진도를 입력해 주세요." />
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: isNarrow ? '1fr' : '1fr 1fr',
              columnGap: 16,
              rowGap: 14,
            }}
          >
            <div>
              <FieldLabel text="현재 진도" />
              <TextInput value={progressCurrent} onChange={setProgressCurrent} placeholder="예: 수학(상) 2단원 / 쎈 B 3-2" />
            </div>
            <div>
              <FieldLabel text="이전 진도" />
              <TextInput value={progressPrev} onChange={setProgressPrev} placeholder="예: 수학(상) 1단원 / 개념원리 3-1" />
            </div>
          </div>

          <SectionHeader title="시험" subtitle="시험 대비 정보(교재/정답률)를 입력해 주세요." />
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: isNarrow ? '1fr' : '1fr 1fr',
              columnGap: 16,
              rowGap: 14,
            }}
          >
            <div>
              <FieldLabel text="시험 대비 교재" />
              <TextInput value={examBook} onChange={setExamBook} placeholder="예: 자이스토리 / EBS / 학교 프린트" />
            </div>
            <div>
              <FieldLabel text="대략적인 정답률(%)" />
              <TextInput value={examCorrectRate} onChange={setExamCorrectRate} placeholder="예: 70" inputMode="decimal" />
            </div>
          </div>

          <SectionHeader title="성적" subtitle="최근 시험 성적과 최근 4회 기준 최대/최소를 입력해 주세요." />
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: isNarrow ? '1fr' : '1fr 1fr 1fr',
              columnGap: 16,
              rowGap: 14,
            }}
          >
            <div>
              <FieldLabel text="가장 최근 시험 성적" />
              <TextInput value={scoreLatest} onChange={setScoreLatest} placeholder="예: 84 (또는 2등급)" />
            </div>
            <div>
              <FieldLabel text="최근 4회 최대점" />
              <TextInput value={scoreRecent4Max} onChange={setScoreRecent4Max} placeholder="예: 92" inputMode="decimal" />
            </div>
            <div>
              <FieldLabel text="최근 4회 최소점" />
              <TextInput value={scoreRecent4Min} onChange={setScoreRecent4Min} placeholder="예: 71" inputMode="decimal" />
            </div>
          </div>

        </>
      ) : (
        <>
          <SectionHeader title="필수 정보" />
          {/* 1행: 이름 / 학교 */}
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: isNarrow ? '1fr' : '1fr 1fr',
              columnGap: 16,
              rowGap: 14,
            }}
          >
            <div style={{ maxWidth: 306 }}>
              <FieldLabel text="이름" required />
              <TextInput value={name} onChange={setName} placeholder="예: 홍길동" />
            </div>
            <div style={{ maxWidth: 306 }}>
              <FieldLabel text="학교" required />
              <TextInput value={school} onChange={setSchool} placeholder="예: 서울중학교" />
            </div>
          </div>

          <div style={{ marginTop: 12, maxWidth: 306 }}>
            <FieldLabel text="과정/학년" required />
            <SelectBox
              options={['선택', ...gradeOptions.map((x) => x.label)]}
              value={selectedGradeLabel || ''}
              placeholder="선택"
              onChange={(v) => {
                if (v === '선택') { setGrade(''); return; }
                const hit = gradeOptions.find((x) => x.label === v);
                if (!hit) return;
                setLevel(hit.level);
                setGrade(hit.grade);
              }}
              style={{ height: 44, marginTop: 6 }}
            />
          </div>
          {isSimpleWeb ? (
            <div style={{ marginTop: 12, maxWidth: 306 }}>
              <FieldLabel text="이메일" required />
              <TextInput value={email} onChange={setEmail} placeholder="you@example.com" inputMode="email" />
            </div>
          ) : (
            <>
              <SectionHeader title="연락처" />
              <div
                style={{
                  display: 'grid',
                  gridTemplateColumns: isNarrow ? '1fr' : '1fr 1fr',
                  columnGap: 16,
                  rowGap: 14,
                }}
              >
                <div style={{ maxWidth: 306 }}>
                  <FieldLabel text="학부모 연락처" />
                  <TextInput value={parentPhone} onChange={setParentPhone} placeholder="예: 01012345678" inputMode="numeric" />
                </div>
                <div style={{ maxWidth: 306 }}>
                  <FieldLabel text="본인 연락처" />
                  <TextInput value={studentPhone} onChange={setStudentPhone} placeholder="예: 01012345678" inputMode="numeric" />
                </div>
              </div>
            </>
          )}
        </>
      )}

      {error && <div style={{ color: tokens.danger, marginTop: 12, fontSize: 13 }}>{error}</div>}
      {ok && <div style={{ color: '#7ED957', marginTop: 12, fontSize: 13 }} data-testid="toast-success">{ok}</div>}
      <div style={{ display: 'flex', gap: 8, marginTop: 32, justifyContent: 'flex-end' }}>
        {isSimpleWeb ? (
          <>
            <button
              type="button"
              onClick={onBack}
              style={{ background: 'transparent', color: tokens.textDim, border: `1px solid ${tokens.border}`, padding: '12px 18px', borderRadius: 10, fontWeight: 900, cursor: 'pointer' }}
            >
              뒤로
            </button>
            <button
              data-testid="btn-submit"
              type="button"
              onClick={() => submitNewStudent()}
              style={{
                background: tokens.accent,
                color: '#fff',
                border: 'none',
                padding: '12px 18px',
                borderRadius: 10,
                fontWeight: 900,
                cursor: 'pointer',
              }}
            >
              시작하기
            </button>
          </>
        ) : page === 'basic' ? (
          <>
            <button
              type="button"
              onClick={onBack}
              style={{ background: 'transparent', color: tokens.textDim, border: `1px solid ${tokens.border}`, padding: '12px 18px', borderRadius: 10, fontWeight: 900, cursor: 'pointer' }}
            >
              뒤로
            </button>
            <button
              type="button"
              onClick={(e) => {
                e.preventDefault();
                setError(null); setOk(null);
                const err = validateBasic();
                if (err) { setError(err); return; }
                setPage('details');
              }}
              style={{ background: tokens.accent, color: '#fff', border: 'none', padding: '12px 18px', borderRadius: 10, fontWeight: 900, cursor: 'pointer' }}
            >
              다음
            </button>
          </>
        ) : (
          <>
            <button
              type="button"
              onClick={() => { setError(null); setOk(null); setPage('basic'); }}
              style={{ background: 'transparent', color: tokens.textDim, border: `1px solid ${tokens.border}`, padding: '12px 18px', borderRadius: 10, fontWeight: 900, cursor: 'pointer' }}
            >
              뒤로
            </button>
            <button
              data-testid="btn-submit"
              type="button"
              onClick={() => submitNewStudent()}
              disabled={submitting}
              style={{
                background: tokens.accent,
                color: '#fff',
                border: 'none',
                padding: '12px 18px',
                borderRadius: 10,
                fontWeight: 900,
                cursor: submitting ? 'not-allowed' : 'pointer',
                opacity: submitting ? 0.6 : 1,
              }}
            >
              {submitting ? '시작 중...' : '시작'}
            </button>
          </>
        )}
      </div>
    </form>
  );
}

function useRoute() {
  const [path, setPath] = useState(() => `${window.location.pathname}${window.location.search}`);
  useEffect(() => {
    const onPop = () => setPath(`${window.location.pathname}${window.location.search}`);
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, []);
  function navigate(to: string) {
    window.history.pushState(null, '', to);
    setPath(to);
  }
  return { path, navigate };
}

function ExistingStudentsPage({
  isInWebViewHost,
  loading,
  error,
  students,
  onBack,
  onRequest,
  onPick,
}: {
  isInWebViewHost: boolean;
  loading: boolean;
  error: string | null;
  students: ExistingStudent[];
  onBack: () => void;
  onRequest: () => void;
  onPick: (s: ExistingStudent) => void;
}) {
  const [q, setQ] = useState('');
  const sbCfg = getSupabaseConfig();
  const canFetchProgress = isInWebViewHost && sbCfg.ok;
  const [questionRoundMap, setQuestionRoundMap] = useState<Record<string, number>>({});
  const [roundTotals, setRoundTotals] = useState<Record<number, number>>({});
  const [progressMap, setProgressMap] = useState<Record<string, RoundProgressState[]>>({});
  const [progressLoading, setProgressLoading] = useState(false);
  const defaultProgress: RoundProgressState[] = ['inactive', 'inactive', 'inactive'];

  useEffect(() => {
    // 페이지 진입 시 자동 로드
    if (isInWebViewHost && students.length === 0 && !loading && !error) {
      onRequest();
    }
  }, [isInWebViewHost]);

  const filtered = useMemo(() => {
    const needle = q.trim().toLowerCase();
    if (!needle) return students;
    return students.filter((s) => {
      const hay = `${s.name} ${(s.school ?? '')} ${(s.grade ?? '')}`.toLowerCase();
      return hay.includes(needle);
    });
  }, [q, students]);

  useEffect(() => {
    if (!canFetchProgress) return;
    let cancelled = false;
    (async () => {
      try {
        const roundOrderMap: Record<string, number> = {};
        const { data: roundData } = await supabase.rpc('list_trait_rounds_public');
        if (Array.isArray(roundData)) {
          const sorted = [...roundData].sort((a: any, b: any) => (a.order_index ?? 0) - (b.order_index ?? 0));
          sorted.forEach((r: any, i: number) => {
            const key = String(r?.name ?? '').trim();
            if (key) roundOrderMap[key] = i + 1;
          });
        }
        const { data, error: qErr } = await supabase
          .from('questions')
          .select('id, round_label')
          .eq('is_active', true)
          .order('created_at', { ascending: true });
        if (qErr) throw qErr;
        const nextRoundMap: Record<string, number> = {};
        const totals: Record<number, number> = {};
        for (const row of (data ?? []) as any[]) {
          const label = String(row?.round_label ?? '').trim();
          const roundNo = roundOrderMap[label] ?? parseRoundNo(label) ?? 1;
          const qid = String(row?.id ?? '');
          if (!qid) continue;
          nextRoundMap[qid] = roundNo;
          totals[roundNo] = (totals[roundNo] ?? 0) + 1;
        }
        if (!cancelled) {
          setQuestionRoundMap(nextRoundMap);
          setRoundTotals(totals);
        }
      } catch {
        if (!cancelled) {
          setQuestionRoundMap({});
          setRoundTotals({});
        }
      }
    })();
    return () => { cancelled = true; };
  }, [canFetchProgress]);

  useEffect(() => {
    if (!canFetchProgress) return;
    if (!students.length || Object.keys(questionRoundMap).length === 0) {
      setProgressMap({});
      return;
    }
    let cancelled = false;
    (async () => {
      setProgressLoading(true);
      const ids = students.map((s) => s.id).filter((id) => isUuid(id));
      if (!ids.length) {
        if (!cancelled) {
          setProgressMap({});
          setProgressLoading(false);
        }
        return;
      }
      const { data, error: pErr } = await supabase.rpc('list_trait_answers_by_participants', { p_participant_ids: ids });
      if (cancelled) return;
      if (pErr) {
        setProgressMap({});
        setProgressLoading(false);
        return;
      }
      const countsByStudent: Record<string, Record<number, number>> = {};
      for (const row of (data ?? []) as any[]) {
        const pid = String(row?.participant_id ?? '');
        const qid = String(row?.question_id ?? '');
        const roundNo = questionRoundMap[qid];
        if (!pid || !roundNo) continue;
        if (!countsByStudent[pid]) countsByStudent[pid] = {};
        countsByStudent[pid][roundNo] = (countsByStudent[pid][roundNo] ?? 0) + 1;
      }
      const roundSlots = [1, 2, 3];
      const nextProgress: Record<string, RoundProgressState[]> = {};
      for (const s of students) {
        const counts = countsByStudent[s.id] ?? {};
        nextProgress[s.id] = roundSlots.map((roundNo) => {
          const total = roundTotals[roundNo] ?? 0;
          const answered = counts[roundNo] ?? 0;
          if (total <= 0) return 'inactive';
          if (answered <= 0) return 'inactive';
          if (answered >= total) return 'done';
          return 'active';
        });
      }
      setProgressMap(nextProgress);
      setProgressLoading(false);
    })();
    return () => { cancelled = true; };
  }, [canFetchProgress, students, questionRoundMap, roundTotals]);

  return (
    <div style={{ maxWidth: 900, margin: '32px auto 0' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 900, color: tokens.text }}>기존학생 선택</div>
          <div style={{ marginTop: 4, color: tokens.textFaint, fontSize: 13 }}>학생을 선택하면 설문이 바로 시작됩니다.</div>
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <button onClick={onBack} style={{ background: 'transparent', border: `1px solid ${tokens.border}`, color: tokens.textDim, borderRadius: 10, padding: '10px 14px', cursor: 'pointer', fontWeight: 900 }}>뒤로</button>
          <button onClick={onRequest} style={{ background: tokens.accent, border: 'none', color: '#fff', borderRadius: 10, padding: '10px 14px', cursor: 'pointer', fontWeight: 900 }}>새로고침</button>
        </div>
      </div>

      <div style={{ height: 1, background: tokens.border, margin: '14px 0 14px' }} />

      {!isInWebViewHost ? (
        <div style={{ padding: 16, background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 12, color: tokens.textFaint }}>
          브라우저에서는 기존학생 연동이 준비 중입니다. (앱에서만 사용)
        </div>
      ) : (
        <>
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="이름/학교/학년 검색"
            style={{
              width: '100%',
              height: 44,
              background: tokens.field,
              border: `1px solid ${tokens.border}`,
              borderRadius: 10,
              padding: '10px 12px',
              color: tokens.text,
              fontSize: 16,
              outline: 'none',
              boxSizing: 'border-box',
            }}
          />

          <div style={{ marginTop: 12, color: tokens.textFaint, fontSize: 13 }}>
            {loading ? '불러오는 중...' : error ? error : `${filtered.length}명`}
          </div>

          <div style={{ marginTop: 12, border: `1px solid ${tokens.border}`, borderRadius: 12, overflow: 'hidden' }}>
            {filtered.map((s) => (
              <div
                key={s.id}
                onClick={() => onPick(s)}
                style={{ padding: '12px 16px', cursor: 'pointer', borderBottom: `1px solid ${tokens.border}`, background: 'transparent' }}
                onMouseEnter={(e) => ((e.currentTarget as HTMLDivElement).style.background = tokens.panelAlt)}
                onMouseLeave={(e) => ((e.currentTarget as HTMLDivElement).style.background = 'transparent')}
              >
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
                  <div style={{ minWidth: 0 }}>
                    <div style={{ color: tokens.text, fontWeight: 900 }}>{s.name}</div>
                    <div style={{ color: tokens.textFaint, marginTop: 2, fontSize: 13 }}>
                      {(s.school ?? '-') + ' · ' + levelLabel(s.level) + ' ' + (s.grade ?? '-')}
                    </div>
                  </div>
                  {isInWebViewHost && (
                    <div style={{ display: 'flex', alignItems: 'center', gap: 6, opacity: progressLoading ? 0.7 : 1 }}>
                      {(progressMap[s.id] ?? defaultProgress).map((st, i) => {
                        const color = st === 'done' ? tokens.accent : st === 'active' ? tokens.textDim : tokens.border;
                        return (
                          <div
                            key={`${s.id}_${i}`}
                            style={{ width: 22, height: 8, borderRadius: 999, background: color, border: `1px solid ${tokens.border}` }}
                          />
                        );
                      })}
                    </div>
                  )}
                </div>
              </div>
            ))}
            {!loading && !error && filtered.length === 0 && (
              <div style={{ padding: 16, color: tokens.textFaint }}>검색 결과가 없습니다.</div>
            )}
          </div>
        </>
      )}
    </div>
  );
}

function App() {
  const { path, navigate } = useRoute();
  const pathname = (path.split('?')[0] || '/');
  const isInWebViewHost = !!((window as any)?.chrome?.webview);
  const isNarrowScreen = window.innerWidth < 720;
  const appPadding = isNarrowScreen ? 12 : 24;
  const [existingLoading, setExistingLoading] = useState(false);
  const [existingError, setExistingError] = useState<string | null>(null);
  const [existingStudents, setExistingStudents] = useState<ExistingStudent[]>([]);
  const [existingReqId, setExistingReqId] = useState<string | null>(null);

  useEffect(() => {
    const unsub = subscribeYggEvents((msg) => {
      if (!msg || typeof msg !== 'object') return;
      if (msg.type !== 'existing_students_result') return;
      if (!existingReqId || msg.requestId !== existingReqId) return;
      setExistingLoading(false);
      setExistingReqId(null);
      if (msg.ok) {
        setExistingError(null);
        setExistingStudents(Array.isArray(msg.students) ? (msg.students as ExistingStudent[]) : []);
      } else {
        setExistingError(msg.error ? String(msg.error) : '학생 목록을 불러오지 못했습니다.');
      }
    });
    return () => { try { unsub(); } catch {} };
  }, [existingReqId]);

  function requestExistingStudents() {
    if (!isInWebViewHost) {
      alert('브라우저에서는 기존학생 연동이 준비 중입니다.');
      return;
    }
    const reqId = `req_${Date.now()}_${Math.random().toString(16).slice(2)}`;
    setExistingReqId(reqId);
    setExistingLoading(true);
    setExistingError(null);
    setExistingStudents([]);
    const sent = sendToAppViaHash({ type: 'existing_students_request', requestId: reqId }) ||
      postToHost({ type: 'existing_students_request', requestId: reqId });
    if (!sent) {
      setExistingLoading(false);
      setExistingReqId(null);
      setExistingError('앱과 통신할 수 없습니다.');
    }
  }

  function goSurveyWithStudent(s: ExistingStudent) {
    const qs = new URLSearchParams();
    qs.set('sid', s.id);
    if (s.name) qs.set('name', s.name);
    if (s.school) qs.set('school', s.school);
    if (s.level) qs.set('level', s.level);
    if (s.grade) qs.set('grade', s.grade);
    navigate(`/survey?${qs.toString()}`);
  }
  return (
    <div style={{ color: tokens.text, background: tokens.bg, minHeight: '100vh', padding: appPadding, boxSizing: 'border-box' }}>
      {pathname.startsWith('/results') ? (
        <Suspense fallback={<div style={{ color: tokens.textDim }}>불러오는 중...</div>}>
          <ResultsPage />
        </Suspense>
      ) : pathname.startsWith('/report-preview') ? (
        <Suspense fallback={<div style={{ color: tokens.textDim }}>불러오는 중...</div>}>
          <ReportPreviewPage />
        </Suspense>
      ) : pathname.startsWith('/survey') ? (
        <Suspense fallback={<div style={{ color: tokens.textDim }}>불러오는 중...</div>}>
          <SurveyPage />
        </Suspense>
      ) : pathname.startsWith('/existing') ? (
        <ExistingStudentsPage
          isInWebViewHost={isInWebViewHost}
          loading={existingLoading}
          error={existingError}
          students={existingStudents}
          onBack={() => navigate('/')}
          onRequest={requestExistingStudents}
          onPick={(s) => goSurveyWithStudent(s)}
        />
      ) : pathname.startsWith('/take') ? (
        <NewStudentForm
          onRegistered={(s) => {
            if (!s?.id) return;
            const qs = new URLSearchParams();
            qs.set('sid', s.id);
            qs.set('name', s.name);
            qs.set('school', s.school);
            qs.set('level', s.level);
            qs.set('grade', s.grade);
            if (s.email) qs.set('email', s.email);
            navigate(`/survey?${qs.toString()}`);
          }}
          onBack={() => navigate('/')}
          isInWebViewHost={isInWebViewHost}
        />
      ) : (
        <Landing
          onPickNew={() => navigate('/take')}
          onPickExisting={() => navigate('/existing')}
          isInWebViewHost={isInWebViewHost}
        />
      )}
    </div>
  );
}

const root = createRoot(document.getElementById('root')!);
root.render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);


