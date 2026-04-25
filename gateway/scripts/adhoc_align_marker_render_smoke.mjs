/**
 * `[문단:가운데]` 마커가 XeLaTeX 렌더 경로에서 \begin{center} 로 반영되는지 확인.
 *
 * - 실제 DB 문항을 하나 골라 stem 을 수정하여 렌더 인풋 객체에 넣는다.
 * - buildDocumentTexSource 로 .tex 소스를 만들고 `\begin{center}` 출현 여부를 검증.
 * - 파이프라인 전체를 실제로 돌리지는 않고, 템플릿 조합만 검사 (빠르고 결정적).
 */
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import { buildDocumentTexSource } from '../src/problem_bank/render_engine/xelatex/template.js';

const docId = process.argv[2] || 'c2e37ceb-164f-4d0f-96f6-f63e2112ea74';

const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const { data, error } = await supa
  .from('pb_questions')
  .select('*')
  .eq('document_id', docId)
  .order('question_number');

if (error) throw error;
if (!data?.length) {
  console.error('No questions found for document_id', docId);
  process.exit(1);
}

const target = data.find((q) => Number(q.question_number) === 2) || data[0];
console.log(`target Q${target.question_number} stem len=${(target.stem||'').length}`);

// stem 내부에 `[문단:가운데]` 삽입: 기존 stem 앞에 "가운데 테스트 문장" 을 center 로.
const patched = {
  ...target,
  stem: `앞 문장입니다.\n[문단:가운데]\n이 줄은 가운데 정렬.\n[문단]\n${target.stem}`,
};

const tex = buildDocumentTexSource([patched], {
  paper: 'B4',
  fontFamily: 'Malgun Gothic',
  fontBold: 'Malgun Gothic Bold',
  fontSize: 11,
  columns: 1,
  sectionLabel: '수학 영역',
  profile: 'naesin',
  maxQuestionsPerPage: 4,
});

const beginCenter = (tex.match(/\\begin\{center\}/g) || []).length;
const endCenter = (tex.match(/\\end\{center\}/g) || []).length;
const hasPatchText = tex.includes('가운데 정렬');
const noMarkerLeak = !/\[문단:가운데\]/.test(tex);
const hasCenterContent = /\\begin\{center\}[\s\S]{0,400}가운데 정렬/.test(tex);

console.log(`\\begin{center} count: ${beginCenter}`);
console.log(`\\end{center} count:   ${endCenter}`);
console.log(`patched text present: ${hasPatchText}`);
console.log(`raw marker not leaked: ${noMarkerLeak}`);
console.log(`center block wraps patched text: ${hasCenterContent}`);

const ok = beginCenter >= 1 && endCenter === beginCenter && hasPatchText && noMarkerLeak && hasCenterContent;

// 2) negative control: 마커 없이 렌더 시 추가 center 가 생기지 않아야 한다.
const texCtrl = buildDocumentTexSource([target], {
  paper: 'B4',
  fontFamily: 'Malgun Gothic',
  fontBold: 'Malgun Gothic Bold',
  fontSize: 11,
  columns: 1,
  sectionLabel: '수학 영역',
  profile: 'naesin',
  maxQuestionsPerPage: 4,
});
const ctrlBegin = (texCtrl.match(/\\begin\{center\}/g) || []).length;
const ctrlEnd = (texCtrl.match(/\\end\{center\}/g) || []).length;
console.log(`\n[control, no marker] \\begin{center}: ${ctrlBegin}, \\end{center}: ${ctrlEnd}`);

const addedByMarker = beginCenter - ctrlBegin;
console.log(`net center blocks added by [문단:가운데]: ${addedByMarker}`);

if (!ok) {
  console.log('\n----- snippet around "가운데 정렬" -----');
  const idx = tex.indexOf('가운데 정렬');
  if (idx >= 0) {
    console.log(tex.slice(Math.max(0, idx - 200), idx + 200));
  } else {
    console.log(tex.slice(0, 500));
  }
  process.exit(2);
}
if (addedByMarker !== 1) {
  console.log(`\nWARN: expected exactly 1 added center block, got ${addedByMarker}`);
  process.exit(3);
}
console.log('\nSMOKE OK');
