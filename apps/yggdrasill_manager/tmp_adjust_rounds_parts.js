const XLSX = require('xlsx');

const inputPath = 'C:/Users/harry/Yggdrasill/docs/surveys/questions_2026-01-27T11-52-55-182Z_rebalanced_rounds_labels.xlsx';
const outputPath = 'C:/Users/harry/Yggdrasill/docs/surveys/questions_2026-01-27T11-52-55-182Z_rebalanced_rounds_labels_parts.xlsx';

const PRE_LABEL = '사전 조사';
const CORE_LABEL = '코어 진단';
const EXT_LABEL = '확장 진단';

const wb = XLSX.readFile(inputPath);
const ws = wb.Sheets[wb.SheetNames[0]];
const rows = XLSX.utils.sheet_to_json(ws, { defval: '' });
const keys = Object.keys(rows[0] || {});

const findKey = (frag) => keys.find((k) => k.includes(frag)) || '';
const kNo = findKey('번호');
const kRound = findKey('회차');
const kPart = findKey('파트');
const kText = findKey('내용');

const isSubjective = (text) => {
  const t = String(text || '');
  return t.includes('00분') || t.includes('분까지는 고민');
};

// 1) Move 2 subjective items to pre-survey
rows.forEach((row) => {
  if (isSubjective(row[kText])) {
    row[kRound] = PRE_LABEL;
    row[kPart] = '';
  }
});

// 2) Re-assign parts for 3rd round (확장 진단): 22 / 20 / 10
const extItems = rows
  .map((row, idx) => ({ row, idx }))
  .filter((x) => String(x.row[kRound] || '').trim() === EXT_LABEL);

// Keep original order, assign part numbers
extItems.forEach((item, i) => {
  if (i < 22) item.row[kPart] = 1;
  else if (i < 22 + 20) item.row[kPart] = 2;
  else item.row[kPart] = 3;
});

// Renumber for neatness
rows.forEach((row, i) => {
  if (kNo) row[kNo] = i + 1;
});

const outWb = XLSX.utils.book_new();
const outWs = XLSX.utils.json_to_sheet(rows, { header: keys });
XLSX.utils.book_append_sheet(outWb, outWs, 'questions');
XLSX.writeFile(outWb, outputPath);

// Summary
const roundCounts = {};
const partCounts = {};
rows.forEach((row) => {
  const r = String(row[kRound] || '').trim();
  roundCounts[r] = (roundCounts[r] || 0) + 1;
  if (r === EXT_LABEL) {
    const p = String(row[kPart] || '').trim() || '(empty)';
    partCounts[p] = (partCounts[p] || 0) + 1;
  }
});

console.log('output', outputPath);
console.log('roundCounts', roundCounts);
console.log('extPartCounts', partCounts);
