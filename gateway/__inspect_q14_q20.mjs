import fs from 'node:fs';
import AdmZip from 'adm-zip';

const z = new AdmZip(
  fs.readFileSync('C:\\Users\\harry\\OneDrive\\바탕 화면\\2025년 대구 수성구 능인중 중1공통 1학기중간 중등수학1상.hwpx'),
);
const xml = z.readAsText('Contents/section0.xml');

// Find Q14's multiplication table (×)
const tables = [...xml.matchAll(/<hp:tbl\b[\s\S]*?<\/hp:tbl>/gi)];
console.log('=== Looking for Q14 multiplication table ===');
for (let i = 0; i < tables.length; i++) {
  const t = tables[i][0];
  if (t.includes('times') || t.includes('×') || t.includes('곱셈') || t.includes('\\times')) {
    console.log(`Table ${i}: length=${t.length}`);
    const rowCnt = t.match(/rowCnt="(\d+)"/)?.[1];
    const colCnt = t.match(/colCnt="(\d+)"/)?.[1];
    console.log(`  rowCnt=${rowCnt}, colCnt=${colCnt}`);

    const cells = [...t.matchAll(/<hp:tc\b[^>]*>([\s\S]*?)<\/hp:tc>/gi)];
    for (let ci = 0; ci < cells.length; ci++) {
      const full = cells[ci][0];
      const spanM = full.match(/<hp:cellSpan\s+colSpan="(\d+)"\s+rowSpan="(\d+)"/);
      const addrM = full.match(/<hp:cellAddr\s+colAddr="(\d+)"\s+rowAddr="(\d+)"/);
      const texts = [...full.matchAll(/<hp:t>(.*?)<\/hp:t>/gi)].map(m => m[1]).join('');
      console.log(`  Cell[${ci}] addr=(${addrM?.[1]},${addrM?.[2]}) span=(${spanM?.[1]}x${spanM?.[2]}) text="${texts.substring(0,40)}"`);
    }
  }
}

// Find Q20 area - search for "서술하시오" or "box" nearby
console.log('\n=== Looking for Q20 context ===');
const q20idx = xml.indexOf('서술하시오');
if (q20idx > -1) {
  const ctx = xml.substring(Math.max(0, q20idx - 200), Math.min(xml.length, q20idx + 2000));
  // Find sub-question markers (1), (2)
  const subQs = [...ctx.matchAll(/\((\d)\)/g)];
  console.log('Sub-questions near 서술하시오:', subQs.map(m => m[0]));
  // Check for box
  const boxMatch = ctx.match(/box/gi);
  console.log('Box mentions:', boxMatch);
  console.log('\nContext around 서술하시오 (500 chars after):');
  console.log(xml.substring(q20idx, q20idx + 500));
}
