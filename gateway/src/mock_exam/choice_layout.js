// 모의고사 시험지에서 문항의 선지 번호(①~⑤) 글자가 놓인 자리를 읽는다.
//
// 쓰임: 그림이 선지 아래에 있는 문항("본문 → 선지 → 그림")을 가려내는 근거.
//   검수 준비(review_staging.js)가 mock_exam_items.choice_number_region_1k 에 적고,
//   정합성 점검(ai_think textbook_problem_consistency)이 그림 자리(bbox_1k)와 견준다.
// 글자 층만 읽는다(AI 없음). 글자 층이 없는 PDF 는 자리를 찾지 못한다.
// 설계: docs/architecture/mock-exam.md

import { readWordBoxes, withTempPdf } from '../problem_bank/school_exam/pdf_tools.js';

const MARK_INDEX = new Map();
[...'①②③④⑤'].forEach((ch, i) => MARK_INDEX.set(ch, i));
[...'➀➁➂➃➄'].forEach((ch, i) => MARK_INDEX.set(ch, i));

// 번호 글자를 이만큼(종류) 찾아야 선지로 본다. 본문에 ① 하나만 적힌 문항을 선지로 읽지 않는다.
const MIN_DISTINCT_MARKS = 3;

function clamp1k(value) {
  return Math.max(0, Math.min(1000, Math.round(value)));
}

/// 선지 번호 영역으로 쓸 수 있는 값인가: [ymin, xmin, ymax, xmax] (0..1000), 높이·너비 1 이상.
export function validChoiceRegion(raw) {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const v = raw.map((x) => Math.round(Number(x)));
  if (v.some((x) => !Number.isFinite(x) || x < 0 || x > 1000)) return null;
  if (v[2] - v[0] < 1 || v[3] - v[1] < 1) return null;
  return v;
}

/// 안쪽 영역이 바깥 영역 안에 있는가(둘 다 [ymin, xmin, ymax, xmax], tolerance 만큼 벗어나도 안으로 본다).
export function regionInside(inner, outer, tolerance = 3) {
  return (
    inner[0] >= outer[0] - tolerance &&
    inner[1] >= outer[1] - tolerance &&
    inner[2] <= outer[2] + tolerance &&
    inner[3] <= outer[3] + tolerance
  );
}

/// 한 쪽의 낱말 상자에서 문항 영역 안의 선지 번호 영역을 구한다.
///   page: { width, height, words: [{ text, xMin, yMin, xMax, yMax }] } (readWordBoxes 의 한 쪽)
///   region: 문항 영역 [ymin, xmin, ymax, xmax] (0..1000)
/// 반환: 번호 글자들을 감싸는 영역 [ymin, xmin, ymax, xmax] (0..1000). 세 종류 이상 찾지 못하면 null.
/// 같은 번호가 여러 번 나오면(본문에 ①, ② 가 적힌 문항) 가장 아래 것을 선지로 본다.
export function choiceNumberRegion(page, region) {
  const width = Number(page?.width);
  const height = Number(page?.height);
  if (!(width > 0) || !(height > 0) || !Array.isArray(region) || region.length !== 4) return null;
  const [top, left, bottom, right] = region.map(Number);
  const last = new Map();
  for (const word of page.words || []) {
    const cx = ((Number(word.xMin) + Number(word.xMax)) / 2 / width) * 1000;
    const cy = ((Number(word.yMin) + Number(word.yMax)) / 2 / height) * 1000;
    if (!(cy >= top && cy <= bottom && cx >= left && cx <= right)) continue;
    for (const ch of String(word.text || '')) {
      const index = MARK_INDEX.get(ch);
      if (index === undefined) continue;
      const cur = last.get(index);
      if (!cur || word.yMin > cur.yMin || (word.yMin === cur.yMin && word.xMin > cur.xMin)) last.set(index, word);
    }
  }
  if (last.size < MIN_DISTINCT_MARKS) return null;
  const boxes = [...last.values()];
  const out = [
    clamp1k((Math.min(...boxes.map((b) => Number(b.yMin))) / height) * 1000),
    clamp1k((Math.min(...boxes.map((b) => Number(b.xMin))) / width) * 1000),
    clamp1k((Math.max(...boxes.map((b) => Number(b.yMax))) / height) * 1000),
    clamp1k((Math.max(...boxes.map((b) => Number(b.xMax))) / width) * 1000),
  ];
  return validChoiceRegion(out);
}

/// 시험지 PDF 의 쪽별 낱말 상자. 글자 층을 읽지 못하면 빈 배열.
export async function readChoicePages(pdfBuffer) {
  return withTempPdf(pdfBuffer, (pdfPath) => readWordBoxes(pdfPath));
}
