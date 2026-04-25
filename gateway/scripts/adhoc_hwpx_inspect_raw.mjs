// Raw inspect: dump a slice of section0.xml around "2/7의 소수 표현" text and
// list which image tags HWPX actually uses.
import fs from 'node:fs';
import path from 'node:path';
import AdmZip from 'adm-zip';

const file = process.argv[2];
const zip = new AdmZip(path.resolve(file));
const entries = zip.getEntries();

// 1) list all entry names
console.log('=== entries ===');
for (const e of entries) {
  console.log(e.entryName, e.header.size);
}

// 2) find section*.xml and count hp:pic / hp:picture / binaryItemIDRef occurrences
const sections = entries.filter((e) =>
  /^Contents\/section\d+\.xml$/i.test(e.entryName),
);
for (const s of sections) {
  const xml = s.getData().toString('utf8');
  console.log(`\n=== ${s.entryName} size=${xml.length} ===`);
  const picCount = (xml.match(/<hp:pic\b/g) || []).length;
  const pictureCount = (xml.match(/<hp:picture\b/g) || []).length;
  const drawCount = (xml.match(/<hp:drawing\b/g) || []).length;
  const refCount = (xml.match(/binaryItemIDRef/g) || []).length;
  const imgRefMatches = xml.match(/binaryItemIDRef\s*=\s*"([^"]+)"/g) || [];
  console.log('counts:', { picCount, pictureCount, drawCount, refCount });
  console.log('binaryItemIDRefs unique =', [
    ...new Set(imgRefMatches.map((m) => m.match(/"([^"]+)"/)[1])),
  ]);

  // find first snippet around image ref
  const firstRef = xml.search(/binaryItemIDRef/);
  if (firstRef > 0) {
    console.log(`\n--- context around first binaryItemIDRef (offset=${firstRef}) ---`);
    console.log(xml.slice(Math.max(0, firstRef - 300), firstRef + 600));
  }

  // search for "2/7" or "2} over {7"
  const target = xml.search(/2\}\s*over\s*\{7|2\/7|\{2\}\s*over\s*\{7\}/);
  if (target > 0) {
    console.log(`\n--- context around "2/7" (offset=${target}) ---`);
    console.log(xml.slice(Math.max(0, target - 400), target + 1500));
  }
}
