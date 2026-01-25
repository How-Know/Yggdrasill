import path from 'path';
import { fileURLToPath } from 'url';
import * as XLSXNS from 'xlsx';

const XLSX = XLSXNS.default ?? XLSXNS;

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const defaultInput = path.resolve(
  __dirname,
  '../../docs/surveys/questions_2026-01-24T15-36-43-347Z.xlsx'
);

const inputPath = process.argv[2] ? path.resolve(process.argv[2]) : defaultInput;
const outputPath = process.argv[3]
  ? path.resolve(process.argv[3])
  : path.join(
      path.dirname(inputPath),
      'questions_2026-01-24T15-36-43-347Z_tagged_pairs.xlsx'
    );

const header = [
  '번호',
  '영역',
  '그룹',
  '회차',
  '파트',
  '성향',
  '내용',
  '평가 타입',
  '최소',
  '최대',
  '가중치',
  '역문항',
  '페어 ID',
  '태그',
  '메모',
];

const tagByNumber = {
  1: '마음>신념 체계>능력 신념>수학 능력에 대한 암묵적 신념',
  2: '마음>신념 체계>능력 신념>수학 능력에 대한 암묵적 신념',
  3: '마음>신념 체계>통제 가능성 신념>노력-성과 연결 신념',
  4: '마음>신념 체계>통제 가능성 신념>노력-성과 연결 신념',
  5: '마음>신념 체계>실패 해석 신념',
  6: '마음>신념 체계>실패 해석 신념',
  7: '마음>신념 체계>통제 가능성 신념',
  8: '마음>신념 체계>통제 가능성 신념',
  9: '마음>신념 체계>질문/이해 신념',
  10: '마음>신념 체계>질문/이해 신념',
  11: '마음>신념 체계>회복 기대 신념',
  12: '마음>신념 체계>회복 기대 신념',
  13: '정신>상태 지표>흥미/즐거움',
  14: '정신>상태 지표>흥미/즐거움',
  15: '마음>기질(정서 반응성)',
  16: '마음>기질(정서 반응성)',
  17: '마음>자기 개념/정체성(자기 인식 포함)',
  18: '마음>자기 개념/정체성(자기 인식 포함)',
  19: '마음>신념 체계>통제 가능성 신념>주도성 인식',
  20: '마음>신념 체계>통제 가능성 신념>주도성 인식',
  21: '마음>자기 개념/정체성',
  22: '마음>자기 개념/정체성',
};

const reverseNumbers = new Set([4, 5, 8, 12, 20, 22]);

const pairs = [
  [3, 4],
  [5, 6],
  [7, 8],
  [11, 12],
  [19, 20],
  [21, 22],
];

function normalizeText(value) {
  return String(value ?? '').trim();
}

function isPreSurvey(row) {
  const round = normalizeText(row['회차']);
  const trait = normalizeText(row['성향']);
  return !trait && round.includes('사전');
}

const wb = XLSX.readFile(inputPath, { cellDates: false });
const sheetName = wb.SheetNames[0];
const ws = wb.Sheets[sheetName];
const rows = XLSX.utils.sheet_to_json(ws, { defval: '', raw: false });

const rowsByNumber = new Map();
let maxPair = 0;

for (const row of rows) {
  const no = Number(row['번호']);
  if (Number.isFinite(no)) rowsByNumber.set(no, row);
  const m = normalizeText(row['페어 ID']).match(/^PAIR-(\d+)$/);
  if (m) maxPair = Math.max(maxPair, Number(m[1]));
}

function nextPairId() {
  maxPair += 1;
  return `PAIR-${String(maxPair).padStart(4, '0')}`;
}

for (const row of rows) {
  if (!isPreSurvey(row)) continue;
  const no = Number(row['번호']);
  if (!Number.isFinite(no)) continue;

  const tag = tagByNumber[no];
  if (tag) {
    const existing = normalizeText(row['태그']);
    if (!existing) row['태그'] = tag;
    else if (!existing.split(',').map((s) => s.trim()).includes(tag)) {
      row['태그'] = `${existing},${tag}`;
    }
  }

  if (reverseNumbers.has(no)) {
    row['역문항'] = 'Y';
  }
}

for (const [a, b] of pairs) {
  const rowA = rowsByNumber.get(a);
  const rowB = rowsByNumber.get(b);
  if (!rowA || !rowB) continue;
  if (!isPreSurvey(rowA) || !isPreSurvey(rowB)) continue;

  const idA = normalizeText(rowA['페어 ID']);
  const idB = normalizeText(rowB['페어 ID']);
  let pairId = '';

  if (idA && idB) {
    pairId = idA === idB ? idA : idA;
  } else if (idA) {
    pairId = idA;
  } else if (idB) {
    pairId = idB;
  } else {
    pairId = nextPairId();
  }

  rowA['페어 ID'] = pairId;
  rowB['페어 ID'] = pairId;
}

const nextSheet = XLSX.utils.json_to_sheet(rows, { header, skipHeader: false });
wb.Sheets[sheetName] = nextSheet;
XLSX.writeFile(wb, outputPath);

console.log(`완료: ${outputPath}`);
