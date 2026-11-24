// 임시: 카드 그림 왼쪽 부분의 글줄 띠를 찾아 줄 사이 거리(픽셀)를 적는다.
import path from 'node:path';
import sharp from 'sharp';

for (const name of process.argv.slice(2)) {
  const file = path.resolve('build_side', name);
  const { data, info } = await sharp(file).greyscale().raw().toBuffer({ resolveWithObject: true });
  const right = Math.round(info.width * 0.45);
  const bands = [];
  let start = -1;
  for (let y = 0; y < info.height; y += 1) {
    let ink = false;
    for (let x = 0; x < right && !ink; x += 1) ink = data[y * info.width + x] < 128;
    if (ink && start < 0) start = y;
    if (!ink && start >= 0) {
      if (y - start >= 6) bands.push([start, y - 1]);
      start = -1;
    }
  }
  const mids = bands.map(([a, b]) => Math.round((a + b) / 2));
  console.log(`${name.slice(-40)} | 줄 가운데 ${mids.join(',')} | 간격 ${mids.slice(1).map((m, i) => m - mids[i]).join(',')}`);
}
