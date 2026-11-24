import test from "node:test";
import assert from "node:assert/strict";

import {
  EXPLANATION_CARD_MAX_HEIGHT_MM,
  EXPLANATION_CARD_MIN_HEIGHT_MM,
  explanationCardPageHeightMm,
  explanationCardRows,
} from "../src/problem_bank/explanation_card_page.js";

test("짧은 해설 카드는 예전과 같은 쪽 높이를 쓴다", () => {
  assert.equal(explanationCardPageHeightMm(""), EXPLANATION_CARD_MIN_HEIGHT_MM);
  const short = Array.from({ length: 30 }, (_, i) => `$a_${i}=1$`).join("\n\n");
  assert.equal(explanationCardRows(short), 30);
  assert.equal(explanationCardPageHeightMm(short), EXPLANATION_CARD_MIN_HEIGHT_MM);
});

test("줄이 백 줄을 넘는 해설은 쪽을 길게 잡는다", () => {
  // 2024 고3 9월 평가원 22번: 117줄. 800mm 쪽에서는 빈 카드가 나왔다.
  const long = Array.from({ length: 117 }, (_, i) => `$a_{${i}}=k$`).join("\n\n");
  const height = explanationCardPageHeightMm(long);
  assert.ok(height > 1500, `height ${height}`);
  assert.ok(height <= EXPLANATION_CARD_MAX_HEIGHT_MM);
});

test("긴 줄과 해설 그림은 높이를 더 잡는다", () => {
  const line = `${"가".repeat(150)}`;
  assert.equal(explanationCardRows(line), 3);
  const lines = Array.from({ length: 60 }, () => "$x=1$").join("\n");
  assert.ok(
    explanationCardPageHeightMm(lines, 3) > explanationCardPageHeightMm(lines),
  );
});

test("쪽 높이는 TeX 길이 한계 아래에서 멈춘다", () => {
  const huge = Array.from({ length: 2000 }, () => "$x=1$").join("\n");
  assert.equal(explanationCardPageHeightMm(huge), EXPLANATION_CARD_MAX_HEIGHT_MM);
});
