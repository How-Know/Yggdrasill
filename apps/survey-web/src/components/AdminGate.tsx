import React, { useEffect, useState } from 'react';
import { supabase } from '../lib/supabaseClient';

const tokens = {
  panel: '#18181A',
  border: '#2A2A2A',
  text: '#FFFFFF',
  textDim: 'rgba(255,255,255,0.7)',
  accent: '#1976D2',
  danger: '#E53E3E',
};

function getAllowedAdmins(): string[] {
  const raw = (import.meta.env.VITE_ADMIN_EMAILS as string | undefined) || '';
  return raw.split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
}

export default function AdminGate({ children }: { children: React.ReactNode }) {
  const [email, setEmail] = useState('');
  const [code, setCode] = useState('');
  const [phase, setPhase] = useState<'checking'|'login'|'code'|'ok'>('checking');
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.auth.getUser();
      const user = data.user;
      const allowed = getAllowedAdmins();
      if (user && (!allowed.length || allowed.includes((user.email || '').toLowerCase()))) {
        setPhase('ok');
      } else if (user) {
        setMsg('관리자 권한이 없는 계정입니다.');
        setPhase('login');
      } else {
        setPhase('login');
      }
    })();
  }, []);

  async function sendCode(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    const allowed = getAllowedAdmins();
    if (allowed.length && !allowed.includes(email.trim().toLowerCase())) {
      setMsg('허용된 관리자 이메일이 아닙니다.');
      return;
    }
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      // 매직링크 혼동 방지를 위해 redirect 생략(코드 입력 흐름 사용)
      options: { shouldCreateUser: false },
    });
    if (error) setMsg(error.message);
    else setPhase('code');
  }

  async function verifyCode(e: React.FormEvent) {
    e.preventDefault();
    setMsg(null);
    const { error } = await supabase.auth.verifyOtp({
      email: email.trim(),
      token: code.trim(),
      type: 'email',
    });
    if (error) setMsg(error.message);
    else {
      const allowed = getAllowedAdmins();
      const u = (await supabase.auth.getUser()).data.user;
      if (u && (!allowed.length || allowed.includes((u.email || '').toLowerCase()))) {
        setPhase('ok');
      } else {
        setMsg('관리자 권한이 없는 계정입니다.');
        await supabase.auth.signOut();
        setPhase('login');
      }
    }
  }

  async function signOut() {
    await supabase.auth.signOut();
    setEmail(''); setCode(''); setPhase('login');
  }

  if (phase !== 'ok') {
    return (
      <div style={{ maxWidth: 420, margin: '40px auto', background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 20 }}>
        <div style={{ fontSize: 20, fontWeight: 900, color: tokens.text, marginBottom: 12 }}>관리자 로그인</div>
        {phase === 'login' && (
          <form onSubmit={sendCode}>
            <label style={{ color: tokens.textDim, fontSize: 13 }}>이메일</label>
            <input value={email} onChange={(e)=>setEmail(e.target.value)} placeholder="you@example.com" style={{ width: '100%', maxWidth: 360, marginTop: 6, height: 44, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px' }} />
            <button type="submit" style={{ marginTop: 12, background: tokens.accent, color: '#fff', border: 'none', padding: '10px 16px', borderRadius: 8, cursor: 'pointer' }}>인증 코드 전송</button>
          </form>
        )}
        {phase === 'code' && (
          <form onSubmit={verifyCode}>
            <div style={{ color: tokens.textDim, fontSize: 13, marginBottom: 8 }}>이메일로 전송된 6자리 코드를 입력하세요.</div>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <input value={code} onChange={(e)=>setCode(e.target.value)} placeholder="6자리 코드"
                     style={{ flex: 1, minWidth: 0, height: 44, background: '#2A2A2A', border: `1px solid ${tokens.border}`, borderRadius: 8, color: tokens.text, padding: '0 12px', letterSpacing: 2, boxSizing: 'border-box' }} />
              <button type="submit" style={{ background: tokens.accent, color: '#fff', border: 'none', padding: '10px 16px', borderRadius: 8, cursor: 'pointer', whiteSpace: 'nowrap' }}>확인</button>
            </div>
          </form>
        )}
        {msg && <div style={{ color: tokens.danger, marginTop: 12, fontSize: 13 }}>{msg}</div>}
      </div>
    );
  }

  return (
    <div>
      {/* ✅ 문서 플로우를 늘리지 않도록 fixed 오버레이로 배치 (스크롤 2개 방지) */}
      <button
        onClick={signOut}
        style={{
          position: 'fixed',
          top: 12,
          right: 24,
          zIndex: 2000,
          background: 'transparent',
          color: tokens.textDim,
          border: `1px solid ${tokens.border}`,
          borderRadius: 8,
          padding: '6px 10px',
          cursor: 'pointer',
        }}
      >
        로그아웃
      </button>
      {children}
    </div>
  );
}



