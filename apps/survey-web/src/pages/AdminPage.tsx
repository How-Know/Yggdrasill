import React from 'react';
import AdminGate from '../components/AdminGate';
import AdminQuestionsPage from './AdminQuestionsPage';
import ResultsPage from './ResultsPage';

const tokens = {
  // ✅ 앱(학생 탭) 배경색과 통일 (Flutter: 0xFF0B1112)
  bg: '#0B1112',
  panel: '#18181A',
  border: '#2A2A2A',
  text: '#FFFFFF',
  textDim: 'rgba(255,255,255,0.7)',
  accent: '#1976D2',
};

export default function AdminPage() {
  const [route, setRoute] = React.useState<'root'|'questions'|'results'>('root');
  if (route === 'results') {
    return (
      <AdminGate>
        <div style={{ color: tokens.text, background: tokens.bg, height: '100vh', padding: 24, boxSizing: 'border-box', overflowY: 'auto' }}>
          <div style={{ maxWidth: 1800, margin: '0 auto' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 }}>
              <div style={{ fontSize: 24, fontWeight: 900 }}>결과 관리</div>
              <button onClick={()=>setRoute('root')} style={{ background: 'transparent', color: tokens.textDim, border: `1px solid ${tokens.border}`, borderRadius: 8, padding: '6px 10px', cursor: 'pointer' }}>뒤로</button>
            </div>
            <ResultsPage />
          </div>
        </div>
      </AdminGate>
    );
  }
  if (route === 'questions') {
    return (
      <AdminGate>
        <div style={{ color: tokens.text, background: tokens.bg, height: '100vh', padding: 24, boxSizing: 'border-box', overflowY: 'auto' }}>
          <div style={{ maxWidth: 1800, margin: '0 auto' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 }}>
              <div style={{ fontSize: 24, fontWeight: 900 }}>문항 관리</div>
              <button onClick={()=>setRoute('root')} style={{ background: 'transparent', color: tokens.textDim, border: `1px solid ${tokens.border}`, borderRadius: 8, padding: '6px 10px', cursor: 'pointer' }}>뒤로</button>
            </div>
            <AdminQuestionsPage />
          </div>
        </div>
      </AdminGate>
    );
  }
  return (
    <AdminGate>
      <div style={{ color: tokens.text, background: tokens.bg, minHeight: '100vh', padding: 24, boxSizing: 'border-box' }}>
        <div style={{ maxWidth: 1800, margin: '0 auto' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 }}>
            <div style={{ fontSize: 24, fontWeight: 900 }}>관리자</div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 16 }}>
            <div
              style={{ background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 20, textAlign: 'center', cursor: 'pointer' }}
              onClick={() => setRoute('questions')}>
              <div style={{ fontSize: 18, fontWeight: 800 }}>문항 관리</div>
              <div style={{ color: tokens.textDim, marginTop: 8, fontSize: 13 }}>질문 추가/편집</div>
            </div>
            <div
              style={{ background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 20, textAlign: 'center', cursor: 'pointer' }}
              onClick={() => setRoute('results')}>
              <div style={{ fontSize: 18, fontWeight: 800 }}>결과 관리</div>
              <div style={{ color: tokens.textDim, marginTop: 8, fontSize: 13 }}>참여자/결과 조회</div>
            </div>
            <div
              style={{ background: tokens.panel, border: `1px solid ${tokens.border}`, borderRadius: 12, padding: 20, textAlign: 'center', cursor: 'pointer' }}
              onClick={() => alert('설정 (준비 중)')}>
              <div style={{ fontSize: 18, fontWeight: 800 }}>설정</div>
              <div style={{ color: tokens.textDim, marginTop: 8, fontSize: 13 }}>준비 중</div>
            </div>
          </div>
        </div>
      </div>
    </AdminGate>
  );
}

