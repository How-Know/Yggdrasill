// 임시: build_side/na13_fix.json 의 본문을 배치 도구가 읽을 UTF-8 글 파일로 적는다(저장소 밖).
import fs from 'node:fs';
import path from 'node:path';

const fix = JSON.parse(fs.readFileSync(path.resolve('build_side', 'na13_fix.json'), 'utf8'));
const stem = Object.values(fix)[0];
const out = path.join(process.env.LOCALAPPDATA, 'Yggdrasill', 'na13_stem.txt');
fs.writeFileSync(out, stem, 'utf8');
console.log(out, stem.length);
