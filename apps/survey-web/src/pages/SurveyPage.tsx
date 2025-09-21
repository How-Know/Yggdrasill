import React, { useEffect, useState } from 'react';
import { supabase } from '../lib/supabaseClient';

type Survey = { id: string; title: string; description: string };
type Question = { id: number; question_text: string; question_type: string; is_required: boolean; order_index: number };

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
  const [survey, setSurvey] = useState<Survey | null>(null);
  const [questions, setQuestions] = useState<Question[]>([]);
  const [answer, setAnswer] = useState('');
  const [loading, setLoading] = useState(true);
  const [submitted, setSubmitted] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const clientId = getClientId();

  useEffect(() => {
    (async () => {
      setLoading(true);
      const { data: s, error: se } = await supabase
        .from('surveys')
        .select('id, title, description')
        .eq('slug', slug)
        .single();
      if (se) {
        console.error(se);
        setLoading(false);
        return;
      }
      setSurvey(s as Survey);

      const { data: qs, error: qe } = await supabase
        .from('survey_questions')
        .select('id, question_text, question_type, is_required, order_index')
        .eq('survey_id', (s as Survey).id)
        .order('order_index', { ascending: true });
      if (qe) console.error(qe);
      else setQuestions(qs as Question[]);

      setLoading(false);
    })();
  }, [slug]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!survey) return;

    const { data: resp, error: re } = await supabase
      .from('survey_responses')
      .insert({
        survey_id: survey.id,
        client_id: clientId,
        user_agent: navigator.userAgent,
      })
      .select()
      .single();
    if (re) {
      setToast('이미 참여했거나 오류가 발생했습니다.');
      return;
    }

    const first = questions[0];
    if (first) {
      const { error: ae } = await supabase
        .from('survey_answers')
        .insert({
          response_id: (resp as any).id,
          question_id: first.id,
          answer_text: answer,
        });
      if (ae) {
        console.error(ae);
        setToast('답변 저장 중 오류가 발생했습니다.');
        return;
      }
    }

    setSubmitted(true);
    setToast('제출이 완료되었습니다. 감사합니다!');
  };

  if (loading) return <p>불러오는 중...</p>;
  if (!survey) return <p>설문을 찾을 수 없어요.</p>;
  if (submitted) return <p>참여해 주셔서 감사합니다!</p>;

  return (
    <div style={{ maxWidth: 560, margin: '40px auto', padding: 16 }}>
      <h1>{survey.title}</h1>
      <p>{survey.description}</p>
      <form onSubmit={handleSubmit}>
        <label style={{ display: 'block', marginBottom: 12 }}>
          {questions[0]?.question_text ?? '의견'}
          <input
            type="text"
            value={answer}
            onChange={(e) => setAnswer(e.target.value)}
            required={questions[0]?.is_required}
            style={{ display: 'block', width: '100%', marginTop: 8, padding: 8 }}
          />
        </label>
        <button type="submit">제출</button>
      </form>
      {toast && (
        <div style={{ marginTop: 12, fontSize: 13, color: '#7ED957' }}>{toast}</div>
      )}
    </div>
  );
}



