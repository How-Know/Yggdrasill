const fs = require('fs');
const p = 'C:/Users/harry/AppData/Local/Temp/pb-xelatex-doc-030ec1bb-b501-48ed-a0af-62e7a6e7448d/document.tex';
let s = fs.readFileSync(p, 'utf8');
const marker = '\\AtBeginShipoutNext{\\global\\mocktitlepagefalse}';
const i = s.indexOf(marker);
if (i < 0) {
  console.log('NOT FOUND');
  process.exit(1);
}
if (s.includes('\\restoregeometry')) {
  console.log('Already has \\restoregeometry, skipping');
} else {
  s = s.slice(0, i) + '\\restoregeometry\n' + s.slice(i);
  fs.writeFileSync(p, s, 'utf8');
  console.log('Inserted at idx', i);
}
