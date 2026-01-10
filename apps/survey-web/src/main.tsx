import React, { useEffect, useMemo, useRef, useState } from 'react';
import './global.css';
import { createRoot } from 'react-dom/client';
import { createPortal } from 'react-dom';
import SurveyPage from './pages/SurveyPage';
import ResultsPage from './pages/ResultsPage';
import { tokens } from './theme';

type EducationLevel = 'elementary' | 'middle' | 'high';

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

function Landing({ onPickNew }: { onPickNew: () => void }) {
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
  return (
    <div style={{ maxWidth: 1100, margin: '64px auto 0' }}>
      <div style={{ textAlign: 'center', marginBottom: 24 }}>
        <div style={{ color: tokens.text, fontSize: 84, fontWeight: 900, letterSpacing: 0.5 }}>성향분석</div>
        <div style={{ color: tokens.textFaint, marginTop: 10, fontSize: 16 }}>테스트에 15분 정도가 소요됩니다.</div>
      </div>
      <div style={{ display: 'flex', gap: 18, marginTop: 18 }}>
      <div
        data-testid="btn-existing"
        onClick={() => alert('기존학생: 추후 연동 예정')}
        onMouseEnter={(e) => ((e.currentTarget as HTMLDivElement).style.background = tokens.panelAlt)}
        onMouseLeave={(e) => ((e.currentTarget as HTMLDivElement).style.background = tokens.panel)}
        style={card}
      >
        <span style={label}>기존학생 (준비 중)</span>
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
}: {
  onRegistered?: (studentId?: string) => void;
}) {
  const q = useQuery();
  const [page, setPage] = useState<'basic' | 'details'>('basic');
  const [name, setName] = useState('');
  const [level, setLevel] = useState<EducationLevel>('elementary');
  const [grade, setGrade] = useState('');
  const [school, setSchool] = useState('');
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
          onRegistered?.(msg.studentId ? String(msg.studentId) : undefined);
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
    if (studentPhone.trim() && !/^\d{9,11}$/.test(studentPhone.replace(/[^0-9]/g, ''))) return '학생 연락처는 숫자 9~11자리로 입력하세요.';
    if (parentPhone.trim() && !/^\d{9,11}$/.test(parentPhone.replace(/[^0-9]/g, ''))) return '학부모 연락처는 숫자 9~11자리로 입력하세요.';
    return null;
  }

  function validateBasic(): string | null {
    if (!name.trim()) return '이름은 필수입니다.';
    if (!school.trim()) return '학교는 필수입니다.';
    if (!grade) return '과정/학년을 선택해주세요.';
    if (studentPhone.trim() && !/^\d{9,11}$/.test(studentPhone.replace(/[^0-9]/g, ''))) {
      return '학생 연락처는 숫자 9~11자리로 입력하세요.';
    }
    if (parentPhone.trim() && !/^\d{9,11}$/.test(parentPhone.replace(/[^0-9]/g, ''))) {
      return '학부모 연락처는 숫자 9~11자리로 입력하세요.';
    }
    return null;
  }

  function onSubmit(e: React.FormEvent) {
    e.preventDefault();
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
      onSubmit={onSubmit}
      style={{
        width: isNarrow ? '40vw' : '40vw',
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
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, marginBottom: 14 }}>
        <div>
          <div style={{ fontSize: 20, fontWeight: 900, color: tokens.text }}>신규학생 등록</div>
          <div style={{ marginTop: 4, color: tokens.textFaint, fontSize: 13 }}>
            {page === 'basic' ? '1/2 · 필수 정보와 연락처를 입력해 주세요.' : '2/2 · 추가 정보를 입력해 주세요.'}
          </div>
        </div>
        {/* 2페이지 상단 뒤로 버튼 제거(하단 버튼만 유지) */}
      </div>

      <div style={{ height: 1, background: tokens.border, margin: '14px 0 10px' }} />

      {page === 'basic' ? (
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
      ) : (
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
      )}

      {error && <div style={{ color: tokens.danger, marginTop: 12, fontSize: 13 }}>{error}</div>}
      {ok && <div style={{ color: '#7ED957', marginTop: 12, fontSize: 13 }} data-testid="toast-success">{ok}</div>}
      <div style={{ display: 'flex', gap: 8, marginTop: 32, justifyContent: 'flex-end' }}>
        {page === 'basic' ? (
          <button
            type="button"
            onClick={() => {
              setError(null); setOk(null);
              const err = validateBasic();
              if (err) { setError(err); return; }
              setPage('details');
            }}
            style={{ background: tokens.accent, color: '#fff', border: 'none', padding: '12px 18px', borderRadius: 10, fontWeight: 900, cursor: 'pointer' }}
          >
            다음
          </button>
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
              type="submit"
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
              {submitting ? '전송 중...' : '제출'}
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

function App() {
  const { path, navigate } = useRoute();
  const pathname = (path.split('?')[0] || '/');
  return (
    <div style={{ color: tokens.text, background: tokens.bg, minHeight: '100vh', padding: 24, boxSizing: 'border-box' }}>
      {pathname.startsWith('/results') ? (
        <ResultsPage />
      ) : pathname.startsWith('/survey') ? (
        <SurveyPage />
      ) : pathname.startsWith('/take') ? (
        <NewStudentForm
          onRegistered={(studentId) => {
            const sid = studentId ? encodeURIComponent(studentId) : '';
            navigate(`/survey${sid ? `?sid=${sid}` : ''}`);
          }}
        />
      ) : (
        <Landing onPickNew={() => navigate('/take')} />
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


