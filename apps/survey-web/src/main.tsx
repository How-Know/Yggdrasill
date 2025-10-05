import React, { useEffect, useMemo, useState } from 'react';
import './global.css';
import { createRoot } from 'react-dom/client';

type EducationLevel = 'elementary' | 'middle' | 'high';

const tokens = {
  bg: '#1F1F1F',
  panel: '#18181A',
  panelAlt: '#212A31',
  border: '#2A2A2A',
  text: '#FFFFFF',
  textDim: 'rgba(255,255,255,0.7)',
  textFaint: 'rgba(255,255,255,0.54)',
  accent: '#1976D2',
  danger: '#E53E3E',
};

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
  const label = value || placeholder || '선택';
  return (
    <div style={{ position: 'relative', width: '100%', ...style }}>
      <button
        type="button"
        onClick={() => setOpen((s) => !s)}
        style={{
          width: '100%',
          height: 44,
          background: '#2A2A2A',
          border: `1px solid ${tokens.border}`,
          borderRadius: 8,
          color: tokens.text,
          fontSize: 17,
          textAlign: 'left',
          padding: '10px 12px',
          cursor: 'pointer',
        }}
      >
        {label}
        <span style={{ float: 'right', opacity: 0.7 }}>▾</span>
      </button>
      {open && (
        <div
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            top: 46,
            background: tokens.panel,
            border: `1px solid ${tokens.border}`,
            borderRadius: 8,
            zIndex: 20,
            maxHeight: 240,
            overflowY: 'auto',
          }}
        >
          {options.map((opt) => (
            <div
              key={opt}
              onClick={() => {
                onChange(opt);
                setOpen(false);
              }}
              style={{
                padding: '10px 12px',
                cursor: 'pointer',
                color: tokens.text,
                fontSize: 17,
                background: opt === value ? '#262A2E' : 'transparent',
              }}
              onMouseEnter={(e) => ((e.currentTarget as HTMLDivElement).style.background = '#262A2E')}
              onMouseLeave={(e) => ((e.currentTarget as HTMLDivElement).style.background = opt === value ? '#262A2E' : 'transparent')}
            >
              {opt}
            </div>
          ))}
        </div>
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

function NewStudentForm() {
  const q = useQuery();
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [level, setLevel] = useState<EducationLevel>('elementary');
  const [grade, setGrade] = useState('');
  const [school, setSchool] = useState('');
  const [studentPhone, setStudentPhone] = useState('');
  const [parentPhone, setParentPhone] = useState('');
  const [agree, setAgree] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState<string | null>(null);

  const sid = q.get('sid') ?? '';

  const [isNarrow, setIsNarrow] = useState<boolean>(false);
  useEffect(() => {
    const onResize = () => setIsNarrow(window.innerWidth < 980);
    onResize();
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);

  const grades = useMemo(() => {
    if (level === 'elementary') return ['1', '2', '3', '4', '5', '6'];
    if (level === 'high') return ['1', '2', '3', 'N수'];
    return ['1', '2', '3'];
  }, [level]);

  function validate(): string | null {
    const emailOk = /.+@.+\..+/.test(email.trim());
    if (!name.trim()) return '이름은 필수입니다.';
    if (!emailOk) return '이메일 형식이 올바르지 않습니다.';
    if (!grade) return '학년을 선택해주세요.';
    if (!['elementary','middle','high'].includes(level)) return '과정을 선택해주세요.';
    if (studentPhone.trim() && !/^\d{9,11}$/.test(studentPhone.replace(/[^0-9]/g, ''))) return '학생 연락처는 숫자 9~11자리로 입력하세요.';
    if (parentPhone.trim() && !/^\d{9,11}$/.test(parentPhone.replace(/[^0-9]/g, ''))) return '학부모 연락처는 숫자 9~11자리로 입력하세요.';
    if (!agree) return '개인정보 처리 동의가 필요합니다.';
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
      email: email.trim(),
      level,
      grade: grade, // 'N수' 포함 가능
      school: school.trim() || undefined,
      studentPhone: studentPhone.trim() || undefined,
      parentPhone: parentPhone.trim() || undefined,
    };
    // MVP: 서버 저장 전까지 콘솔 출력만
    console.log('[SURVEY][NEW_STUDENT_SUBMIT]', payload);
    setOk('제출 완료 (임시 저장 없음)');
  }

  const inputStyle: React.CSSProperties = {
    width: '100%',
    background: '#2A2A2A',
    border: `1px solid ${tokens.border}`,
    borderRadius: 8,
    padding: '10px 12px',
    color: tokens.text,
    fontSize: 18,
    marginTop: 6,
    outline: 'none',
  };

  return (
    <form
      onSubmit={onSubmit}
      style={{
        width: isNarrow ? '40vw' : '40vw',
        maxWidth: 1100,
        margin: '32px auto 0',
        background: tokens.panel,
        border: `1px solid ${tokens.border}`,
        borderRadius: 12,
        padding: 28,
        boxSizing: 'border-box',
        overflow: 'hidden',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', marginBottom: 14 }}>
        <div style={{ fontSize: 22, fontWeight: 800, color: tokens.text }}>신규학생 등록</div>
        <div style={{ marginLeft: 12, color: tokens.textFaint, fontSize: 14 }}>기본 정보를 입력해 주세요.</div>
      </div>
      {/* 필수 정보 */}
      <div style={{ color: tokens.text, fontSize: 18, fontWeight: 800, margin: '4px 0 8px 4px' }}>필수 정보</div>
      {/* 1행: 이름 / 이메일 */}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: isNarrow ? '1fr' : '1fr 1fr',
          columnGap: 40,
          rowGap: 18,
        }}
      >
        <div style={{ maxWidth: 306 }}>
          <label style={{ color: tokens.textDim, fontSize: 13, marginLeft: 2 }}>이름 (필수)</label>
          <input data-testid="form-name" style={{...inputStyle, height: 44}} value={name} onChange={(e)=>setName(e.target.value)} placeholder="예: 홍길동" />
        </div>
        <div style={{ maxWidth: 306 }}>
          <label style={{ color: tokens.textDim, fontSize: 13, marginLeft: 2 }}>이메일 (필수)</label>
          <input data-testid="form-email" style={{...inputStyle, height: 44}} value={email} onChange={(e)=>setEmail(e.target.value)} placeholder="you@example.com" />
        </div>
      </div>
      {/* 2행: 학교 */}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: '1fr',
          rowGap: 18,
          marginTop: 6,
        }}
      >
        <div style={{ maxWidth: 306 }}>
          <label style={{ color: tokens.textDim, fontSize: 13, marginLeft: 2 }}>학교 (선택)</label>
          <input data-testid="form-school" style={{...inputStyle, height: 44}} value={school} onChange={(e)=>setSchool(e.target.value)} placeholder="예: 서울초등학교" />
        </div>
      </div>
      {/* 3행: 과정 / 학년 */}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: isNarrow ? '1fr' : '1fr 1fr',
          columnGap: 24,
          rowGap: 18,
          marginTop: 6,
        }}
      >
        <div style={{ maxWidth: 170 }}>
          <label style={{ color: tokens.textDim, fontSize: 13, marginLeft: 2 }}>과정 (필수)</label>
          <SelectBox
            options={['elementary', 'middle', 'high'].map((k) => ({ key: k, label: k }))
              .map((o) => (o.key === 'elementary' ? '초등' : o.key === 'middle' ? '중등' : '고등'))}
            value={level === 'elementary' ? '초등' : level === 'middle' ? '중등' : '고등'}
            placeholder="과정"
            onChange={(v) => {
              const map: Record<string, EducationLevel> = { '초등': 'elementary', '중등': 'middle', '고등': 'high' };
              setLevel(map[v] as EducationLevel);
              setGrade('');
            }}
            style={{ height: 66, marginTop: 6 }}
          />
        </div>
        <div style={{ maxWidth: 170 }}>
          <label style={{ color: tokens.textDim, fontSize: 13, marginLeft: 2 }}>학년 (필수)</label>
          <SelectBox
            options={['선택', ...grades]}
            value={grade || ''}
            placeholder="선택"
            onChange={(v) => setGrade(v === '선택' ? '' : v)}
            style={{ height: 44, marginTop: 6 }}
          />
        </div>
      </div>
      {/* 4행: 선택 정보 */}
      <div style={{ color: tokens.text, fontSize: 18, fontWeight: 800, margin: '18px 0 8px 4px' }}>선택 정보</div>
      {/* 3행: 학생 연락처 / 학부모 연락처 */}
      <div
        style={{
          display: 'grid',
          gridTemplateColumns: isNarrow ? '1fr' : '1fr 1fr',
          columnGap: 40,
          rowGap: 18,
          marginTop: 6,
        }}
      >
        <div style={{ maxWidth: 306 }}>
          <label style={{ color: tokens.textDim, fontSize: 13 }}>학생 연락처 (선택)</label>
          <input data-testid="form-student-phone" style={{...inputStyle, height: 44}} value={studentPhone} onChange={(e)=>setStudentPhone(e.target.value)} placeholder="예: 01012345678" />
        </div>
        <div style={{ maxWidth: 306 }}>
          <label style={{ color: tokens.textDim, fontSize: 13 }}>학부모 연락처 (선택)</label>
          <input data-testid="form-parent-phone" style={{...inputStyle, height: 44}} value={parentPhone} onChange={(e)=>setParentPhone(e.target.value)} placeholder="예: 01012345678" />
        </div>
      </div>
      <div style={{ marginTop: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
        <input id="agree" type="checkbox" checked={agree} onChange={(e)=>setAgree(e.target.checked)} />
        <label htmlFor="agree" style={{ color: tokens.textDim, fontSize: 14 }}>개인정보 처리에 동의합니다. (필수)</label>
      </div>
      {error && <div style={{ color: tokens.danger, marginTop: 12, fontSize: 13 }}>{error}</div>}
      {ok && <div style={{ color: '#7ED957', marginTop: 12, fontSize: 13 }} data-testid="toast-success">{ok}</div>}
      <div style={{ display: 'flex', gap: 8, marginTop: 32, justifyContent: 'flex-end' }}>
        <button data-testid="btn-submit" type="submit" style={{ background: tokens.accent, color: '#fff', border: 'none', padding: '12px 18px', borderRadius: 10, fontWeight: 800, cursor: 'pointer' }}>제출</button>
      </div>
    </form>
  );
}

function App() {
  const [step, setStep] = useState<'landing'|'new'>('landing');
  return (
    <div style={{ color: tokens.text, background: tokens.bg, minHeight: '100vh', padding: 24, overflow: 'hidden' }}>
      {step === 'landing' ? (
        <Landing onPickNew={() => setStep('new')} />
      ) : (
        <NewStudentForm />
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


