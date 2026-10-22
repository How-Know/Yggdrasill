// 과제를 낼 때 채점 시트가 쓸 정답 PNG 대상(소스 종류·id·answer_kind)을 고른다.
// 앱의 채점 페이로드(class_content_screen.dart)와 같은 규칙을 따른다:
// - 교재: homework_item_problems.crop_id, 객관식·그림 정답은 제외
// - 문제은행: 프리셋 선택 문항(스냅샷이 있으면 교집합), 출제 모드가 객관식이면 제외,
//   서술형이면 'essay', 나머지는 'subjective'

const MODE_ORIGINAL = "original";
const MODE_OBJECTIVE = "objective";
const MODE_SUBJECTIVE = "subjective";
const MODE_ESSAY = "essay";

function trimmedStrings(raw) {
  if (!Array.isArray(raw)) return [];
  return raw.map((value) => String(value ?? "").trim()).filter(Boolean);
}

function objectOrEmpty(raw) {
  return raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {};
}

export function presetSelectedQuestionUids(preset) {
  const row = objectOrEmpty(preset);
  const direct = trimmedStrings(
    row.selected_question_uids ?? row.selected_question_ids,
  );
  if (direct.length > 0) return direct;
  const renderConfig = objectOrEmpty(row.render_config);
  for (const key of [
    "selectedQuestionUidsOrdered",
    "selectedQuestionIdsOrdered",
    "selectedQuestionUids",
    "selectedQuestionIds",
  ]) {
    const values = trimmedStrings(renderConfig[key]);
    if (values.length > 0) return values;
  }
  return [];
}

export function presetQuestionModeMap(preset) {
  const row = objectOrEmpty(preset);
  const raw =
    row.question_mode_by_question_uid &&
    typeof row.question_mode_by_question_uid === "object"
      ? row.question_mode_by_question_uid
      : row.question_mode_by_question_id;
  const out = {};
  for (const [key, value] of Object.entries(objectOrEmpty(raw))) {
    const mode = String(value ?? "").trim();
    if (key.trim() && mode) out[key.trim()] = mode;
  }
  return out;
}

export function presetForcesOriginalMode(preset) {
  const row = objectOrEmpty(preset);
  const renderConfig = objectOrEmpty(row.render_config);
  return String(renderConfig.naesinLinkKey ?? row.naesin_link_key ?? "").trim()
    .length > 0;
}

// 스냅샷이 프리셋의 절반 이하만 남았으면 부분 동기화로 보고 프리셋 전체를 쓴다.
export function filterUidsBySnapshot(selectedUids, snapshotUids) {
  const selected = trimmedStrings(selectedUids);
  const snapshot = new Set(trimmedStrings(snapshotUids));
  if (snapshot.size === 0) return selected;
  const filtered = selected.filter((uid) => snapshot.has(uid));
  if (filtered.length === 0) return [];
  const truncated =
    filtered.length < selected.length && filtered.length * 2 <= selected.length;
  return truncated ? selected : filtered;
}

function questionChoiceCount(question) {
  const objective = Array.isArray(question?.objective_choices)
    ? question.objective_choices
    : [];
  if (objective.length > 0) return objective.length;
  return Array.isArray(question?.choices) ? question.choices.length : 0;
}

function allowObjective(question) {
  return question?.allow_objective !== false;
}

function allowSubjective(question) {
  return question?.allow_subjective !== false;
}

function allowEssay(question) {
  if (!allowSubjective(question)) return false;
  return (
    question?.meta?.allow_essay === true ||
    String(question?.question_type ?? "").includes("서술")
  );
}

export function originalQuestionMode(question) {
  const type = String(question?.question_type ?? "").trim();
  if (type.includes("서술")) return MODE_ESSAY;
  if (type.includes("객관식")) return MODE_OBJECTIVE;
  if (type.includes("주관식")) return MODE_SUBJECTIVE;
  if (allowObjective(question) && !allowSubjective(question)) {
    return MODE_OBJECTIVE;
  }
  if (!allowObjective(question) && allowSubjective(question)) {
    return MODE_SUBJECTIVE;
  }
  return questionChoiceCount(question) >= 2 ? MODE_OBJECTIVE : MODE_SUBJECTIVE;
}

function selectableQuestionModes(question) {
  const out = [];
  if (allowObjective(question)) out.push(MODE_OBJECTIVE);
  if (allowSubjective(question)) out.push(MODE_SUBJECTIVE);
  if (allowEssay(question)) out.push(MODE_ESSAY);
  if (out.length === 0) out.push(originalQuestionMode(question));
  return [...new Set(out)];
}

export function effectiveQuestionMode(
  question,
  { modeByQuestionUid = {}, forceOriginalMode = false } = {},
) {
  if (forceOriginalMode) return originalQuestionMode(question);
  const uid = String(question?.question_uid ?? "").trim();
  const id = String(question?.id ?? "").trim();
  const stableKey = uid || id;
  const preferred = String(
    modeByQuestionUid[stableKey] ?? modeByQuestionUid[id] ?? "",
  ).trim();
  const allowed = selectableQuestionModes(question);
  if (preferred && preferred !== MODE_ORIGINAL && allowed.includes(preferred)) {
    return preferred;
  }
  const original = originalQuestionMode(question);
  if (allowed.includes(original)) return original;
  return allowed[0];
}

// 채점 시트가 PNG를 찾는 answer_kind. 객관식이면 null(PNG 불필요).
export function answerRenderKindForMode(mode) {
  const normalized = String(mode ?? "").trim().toLowerCase();
  if (normalized === MODE_OBJECTIVE) return null;
  if (normalized === MODE_ESSAY || normalized.includes("서술")) return "essay";
  return "subjective";
}

export function textbookAnswerKindNeedsRender(answerKind) {
  const kind = String(answerKind ?? "").trim().toLowerCase();
  if (kind === "image") return false;
  if (kind === "objective" || kind === "choice" || kind.includes("객관")) {
    return false;
  }
  return true;
}
