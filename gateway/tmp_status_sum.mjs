// 임시: 배치 결과 파일(mock_status / mock_continue)에서 준비 안 된 문항만 한 줄씩 적는다.
import fs from 'node:fs';

const file = process.argv[2];
const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
if (process.argv.includes('--keys')) {
  for (const [k, v] of Object.entries(doc)) {
    const first = Array.isArray(v) ? v[0] : v;
    console.log(k, Array.isArray(v) ? `[${v.length}]` : typeof v, first && typeof first === 'object' ? Object.keys(first).join(',').slice(0, 400) : '');
    if (first && typeof first === 'object') {
      for (const [k2, v2] of Object.entries(first)) {
        if (Array.isArray(v2) && v2[0] && typeof v2[0] === 'object') console.log('  ', k2, `[${v2.length}]`, Object.keys(v2[0]).join(',').slice(0, 600));
      }
    }
  }
  process.exit(0);
}
const cut = (s, n) => String(s || '').replace(/\s+/g, ' ').slice(0, n);
for (const run of doc.runs || []) {
  if (run.error) console.log(`[오류] ${run.label}: ${cut(run.error, 120)}`);
}
const walk = (node, label) => {
  if (Array.isArray(node)) {
    for (const item of node) walk(item, label);
    return;
  }
  if (!node || typeof node !== 'object') return;
  const nextLabel = node.label || node.section_label || label;
  if ('quality_status' in node || 'ready' in node) {
    const ready = node.ready === true || node.is_ready === true;
    if (!ready) {
      if (!('number' in node)) return;
      const blockers = Array.isArray(node.blockers) ? node.blockers.join('; ') : node.blockers;
      console.log(`${cut(node.exam, 14)} ${node.section} ${node.number}번 | ${cut(blockers, 70)} | ${cut(node.issue_title || node.engine_symptom || node.quality_issue || node.mismatch_reason || '', 70)}`);
    }
    return;
  }
  for (const v of Object.values(node)) walk(v, nextLabel);
};
walk(Object.fromEntries(Object.entries(doc).filter(([k]) => k !== 'runs')), '');
