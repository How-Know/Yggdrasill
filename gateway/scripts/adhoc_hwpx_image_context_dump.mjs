import fs from 'node:fs';
import path from 'node:path';
import AdmZip from 'adm-zip';

const file = process.argv[2];
if (!file) {
  console.error('Usage: node scripts/adhoc_hwpx_image_context_dump.mjs <hwpx>');
  process.exit(2);
}

const zip = new AdmZip(fs.readFileSync(path.resolve(file)));
const section = zip.getEntry('Contents/section0.xml');
if (!section) throw new Error('Contents/section0.xml not found');
const xml = section.getData().toString('utf8');
const re = /binaryItemIDRef\s*=\s*"([^"]+)"/g;
let match;
while ((match = re.exec(xml)) !== null) {
  const id = match[1];
  const start = Math.max(0, match.index - 1400);
  const end = Math.min(xml.length, match.index + 1900);
  const text = xml
    .slice(start, end)
    .replace(/<hp:t>/g, '')
    .replace(/<\/hp:t>/g, '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim();
  console.log(`\n--- ${id} offset=${match.index} ---`);
  console.log(text.slice(0, 2200));
}
