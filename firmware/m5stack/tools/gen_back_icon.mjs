import sharp from 'file:///C:/Users/harry/Yggdrasill/gateway/node_modules/sharp/lib/index.js';
import { writeFileSync } from 'fs';

const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50"><path fill="#E6E6E6" d="M 34.980469 3.992188 C 34.71875 3.996094 34.472656 4.105469 34.292969 4.292969 L 14.292969 24.292969 C 13.902344 24.683594 13.902344 25.316406 14.292969 25.707031 L 34.292969 45.707031 C 34.542969 45.96875 34.917969 46.074219 35.265625 45.980469 C 35.617188 45.890625 35.890625 45.617188 35.980469 45.265625 C 36.074219 44.917969 35.96875 44.542969 35.707031 44.292969 L 16.414063 25 L 35.707031 5.707031 C 36.003906 5.417969 36.089844 4.980469 35.929688 4.601563 C 35.769531 4.21875 35.394531 3.976563 34.980469 3.992188 Z"/></svg>`;
const size = 24;
const { data } = await sharp(Buffer.from(svg)).resize(size, size).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
const bytes = [];
for (let i = 0; i < data.length; i += 4) {
  const r = data[i];
  const g = data[i + 1];
  const b = data[i + 2];
  const a = data[i + 3];
  const value = ((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3);
  bytes.push(value & 0xff, value >> 8, a);
}
const rows = [];
for (let i = 0; i < bytes.length; i += 16) {
  rows.push('  ' + bytes.slice(i, i + 16).map((b) => '0x' + b.toString(16).padStart(2, '0')).join(',') + ',');
}
const c = `#include <lvgl.h>

const uint8_t icon_back_left_map[] = {
${rows.join('\n')}
};

const lv_img_dsc_t icon_back_left = {
  .header = { .always_zero = 0, .w = ${size}, .h = ${size}, .cf = LV_IMG_CF_TRUE_COLOR_ALPHA },
  .data_size = ${bytes.length},
  .data = icon_back_left_map,
};
`;
writeFileSync(new URL('../src/icon_back_left.c', import.meta.url), c);
console.log('wrote', bytes.length);
