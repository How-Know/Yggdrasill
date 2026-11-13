import { createHash } from "node:crypto";

// 교재 검수의 반영 대기 값(확정 전 수정안)을 문제은행 문항 행에 덮어 V2 카드를 찍는다. DB 는 바꾸지 않는다.
// override 키: stem, choices, common_stem, figure_assets, figure_layout, question_type, allow_objective, allow_subjective
export function applyQuestionOverride(row, override) {
  if (!row || !override || typeof override !== "object") return row;
  const out = { ...row };
  const meta = { ...(row.meta && typeof row.meta === "object" ? row.meta : {}) };
  if (typeof override.stem === "string") out.stem = override.stem;
  if (Array.isArray(override.choices)) out.choices = override.choices;
  if (typeof override.question_type === "string" && override.question_type.trim()) {
    out.question_type = override.question_type.trim();
  }
  if (typeof override.allow_objective === "boolean") out.allow_objective = override.allow_objective;
  if (typeof override.allow_subjective === "boolean") out.allow_subjective = override.allow_subjective;
  if (Array.isArray(override.figure_assets)) {
    meta.figure_assets = override.figure_assets;
    const count = new Set(
      override.figure_assets
        .map((a) => String(a?.figure_index ?? "").trim())
        .filter((v) => /^[1-9][0-9]*$/.test(v)),
    ).size;
    meta.figure_count = count;
    out.figure_refs = Array.from({ length: count }, () => "[그림]");
  }
  if (override.figure_layout && typeof override.figure_layout === "object") {
    meta.figure_layout = override.figure_layout;
  }
  if (typeof override.common_stem === "string") {
    const setModel = { ...(meta.set_model && typeof meta.set_model === "object" ? meta.set_model : {}) };
    delete setModel.commonStem;
    setModel.common_stem = override.common_stem;
    meta.set_model = setModel;
  }
  out.meta = meta;
  return out;
}

// 덮어쓴 카드는 실제 문항 카드 캐시(card/<id>.png)를 덮지 않게 내용별 경로에 둔다.
export function overridePreviewKey(qid, override) {
  const hash = createHash("sha256").update(JSON.stringify(override ?? {})).digest("hex").slice(0, 16);
  return `${qid}-${hash}`;
}
