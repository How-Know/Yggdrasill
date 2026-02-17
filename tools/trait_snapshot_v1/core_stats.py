from __future__ import annotations

from itertools import combinations
from typing import Any, Dict, Iterable, List, Tuple

import numpy as np
import pandas as pd
from scipy.stats import chi2, kruskal, mannwhitneyu, rankdata, spearmanr


def _first_valid(series: pd.Series):
    non_null = series.dropna()
    if non_null.empty:
        return np.nan
    return non_null.iloc[0]


def _safe_sd(series: pd.Series) -> float:
    valid = series.dropna()
    n = len(valid)
    if n == 0:
        return np.nan
    if n == 1:
        return 0.0
    return float(valid.std(ddof=1))


def _weighted_student_mean(group: pd.DataFrame) -> float:
    valid = group.loc[group["score_rc"].notna(), ["score_rc", "weight"]].copy()
    if valid.empty:
        return np.nan
    weights = valid["weight"].fillna(1.0).astype(float)
    weight_sum = float(weights.sum())
    if np.isclose(weight_sum, 0.0):
        return np.nan
    values = valid["score_rc"].astype(float)
    return float(np.average(values, weights=weights))


def compute_alpha(df_scale_matrix: pd.DataFrame) -> float:
    if df_scale_matrix.shape[1] < 2:
        return np.nan
    complete = df_scale_matrix.dropna(axis=0, how="any")
    if complete.shape[0] < 2:
        return np.nan

    k = complete.shape[1]
    item_vars = complete.var(axis=0, ddof=1)
    total_var = complete.sum(axis=1).var(ddof=1)
    if not np.isfinite(total_var) or total_var <= 0:
        return np.nan

    alpha = (k / (k - 1)) * (1 - (item_vars.sum() / total_var))
    if not np.isfinite(alpha):
        return np.nan
    return float(alpha)


def compute_scale_stats(
    df_long: pd.DataFrame,
    scale_map: pd.DataFrame,
    snapshot_version: str = "v1.0",
    snapshot_date: str | None = None,
    warnings: List[str] | None = None,
) -> Tuple[pd.DataFrame, pd.DataFrame]:
    warn = warnings if warnings is not None else []
    map_df = scale_map.copy()
    map_df["include_in_alpha"] = map_df["include_in_alpha"].fillna(0).astype(int)
    map_df["axis_tag"] = map_df["axis_tag"].astype("string").str.strip().str.lower().replace("", pd.NA)

    # Scale_Items 시트용: 문항 단위 집계
    item_stats = (
        df_long.groupby(["scale_name", "item_id"], as_index=False)
        .agg(
            item_text=("item_text", _first_valid),
            trait=("trait", _first_valid),
            reverse_item=("reverse_item", _first_valid),
            min_score=("min_score", _first_valid),
            max_score=("max_score", _first_valid),
            weight=("weight", _first_valid),
            response_n=("score_rc", lambda s: int(s.notna().sum())),
            mean=("score_rc", "mean"),
            sd=("score_rc", _safe_sd),
            min=("score_rc", "min"),
            max=("score_rc", "max"),
            response_time_sec_mean=("response_time_sec", "mean"),
        )
        .merge(
            map_df[["question_id", "scale_name", "include_in_alpha", "axis_tag"]].drop_duplicates("question_id"),
            left_on=["scale_name", "item_id"],
            right_on=["scale_name", "question_id"],
            how="left",
        )
        .drop(columns=["question_id"])
    )
    item_stats = item_stats.sort_values(["scale_name", "item_id"]).reset_index(drop=True)

    scale_rows: List[Dict[str, object]] = []
    item_by_scale = (
        map_df.groupby("scale_name")["question_id"]
        .apply(lambda s: sorted(set(s.astype(str))))
        .to_dict()
    )
    alpha_items_by_scale = (
        map_df.loc[map_df["include_in_alpha"] == 1]
        .groupby("scale_name")["question_id"]
        .apply(lambda s: sorted(set(s.astype(str))))
        .to_dict()
    )

    for scale_name in sorted(item_by_scale.keys()):
        sub = df_long.loc[df_long["scale_name"] == scale_name].copy()
        if sub.empty:
            continue

        student_rows = []
        for student_id, g in sub.groupby("student_id", dropna=False):
            valid_score = g["score_rc"].dropna()
            student_rows.append(
                {
                    "student_id": student_id,
                    "raw_score": float(valid_score.mean()) if not valid_score.empty else np.nan,
                    "weighted_raw_score": _weighted_student_mean(g),
                }
            )
        student_scores = pd.DataFrame(student_rows)
        valid_raw = student_scores["raw_score"].dropna()

        mean = float(valid_raw.mean()) if not valid_raw.empty else np.nan
        sd = _safe_sd(valid_raw)
        min_v = float(valid_raw.min()) if not valid_raw.empty else np.nan
        max_v = float(valid_raw.max()) if not valid_raw.empty else np.nan
        n_respondents = int(valid_raw.shape[0])
        weighted_mean = (
            float(student_scores["weighted_raw_score"].dropna().mean())
            if student_scores["weighted_raw_score"].notna().any()
            else np.nan
        )

        alpha_items = alpha_items_by_scale.get(scale_name, [])
        alpha_n_complete = 0
        alpha = np.nan
        if len(alpha_items) < 2:
            warn.append(
                f"[{scale_name}] include_in_alpha 문항 수 < 2 이므로 Cronbach alpha를 계산하지 않았습니다."
            )
        else:
            alpha_matrix = (
                sub.loc[sub["item_id"].isin(alpha_items)]
                .pivot_table(index="student_id", columns="item_id", values="score_rc", aggfunc="last")
                .reindex(columns=alpha_items)
            )
            alpha_n_complete = int(alpha_matrix.dropna(how="any").shape[0])
            alpha = compute_alpha(alpha_matrix)
            if np.isnan(alpha):
                warn.append(
                    f"[{scale_name}] Cronbach alpha 계산 불가(complete-case N={alpha_n_complete})."
                )

        scale_rows.append(
            {
                "scale_name": scale_name,
                "item_count": int(len(item_by_scale.get(scale_name, []))),
                "mean": mean,
                "sd": sd,
                "min": min_v,
                "max": max_v,
                "n_respondents": n_respondents,
                "cronbach_alpha": alpha,
                "alpha_n_complete": alpha_n_complete,
                "weighted_mean": weighted_mean,
                "snapshot_version": snapshot_version,
                "snapshot_date": snapshot_date,
            }
        )

    scale_stats = pd.DataFrame(scale_rows).sort_values("scale_name").reset_index(drop=True)
    return scale_stats, item_stats


def compute_standard_scores(
    df_long: pd.DataFrame,
    scale_stats: pd.DataFrame,
    snapshot_version: str = "v1.0",
) -> pd.DataFrame:
    item_count_map = (
        scale_stats.set_index("scale_name")["item_count"].to_dict()
        if not scale_stats.empty
        else {}
    )
    baseline_map = (
        scale_stats.set_index("scale_name")[["mean", "sd"]]
        .rename(columns={"mean": "baseline_mean", "sd": "baseline_sd"})
        .to_dict("index")
        if not scale_stats.empty
        else {}
    )

    rows: List[Dict[str, object]] = []
    for (student_id, scale_name), g in df_long.groupby(["student_id", "scale_name"], dropna=False):
        valid_scores = g["score_rc"].dropna()
        raw_score = float(valid_scores.mean()) if not valid_scores.empty else np.nan
        oriented_series = g["score_oriented"] if "score_oriented" in g.columns else g["score_rc"]
        valid_oriented_scores = oriented_series.dropna()
        axis_raw_score = float(valid_oriented_scores.mean()) if not valid_oriented_scores.empty else np.nan
        answered_item_n = int(valid_scores.shape[0])
        total_item_n = int(item_count_map.get(scale_name, 0))
        completion_rate = (
            float(answered_item_n / total_item_n) if total_item_n > 0 else np.nan
        )
        response_time_valid = g["response_time_sec"].dropna()
        response_time_sec_mean = (
            float(response_time_valid.mean()) if not response_time_valid.empty else np.nan
        )

        baseline_mean = baseline_map.get(scale_name, {}).get("baseline_mean", np.nan)
        baseline_sd = baseline_map.get(scale_name, {}).get("baseline_sd", np.nan)
        if np.isfinite(raw_score) and np.isfinite(baseline_sd) and baseline_sd > 0:
            z_score = float((raw_score - baseline_mean) / baseline_sd)
        else:
            z_score = np.nan

        rows.append(
            {
                "student_id": student_id,
                "scale_name": scale_name,
                "raw_score": raw_score,
                "z_score": z_score,
                "axis_raw_score": axis_raw_score,
                "axis_z_score": np.nan,
                "percentile": np.nan,
                "answered_item_n": answered_item_n,
                "total_item_n": total_item_n,
                "completion_rate": completion_rate,
                "current_level_grade": _first_valid(g["current_level_grade"]),
                "current_math_percentile": _first_valid(g["current_math_percentile"]),
                "response_time_sec_mean": response_time_sec_mean,
                "snapshot_version": snapshot_version,
            }
        )

    out = pd.DataFrame(rows)
    if out.empty:
        return out

    # scale_name별 백분위 (rank 기반, 권장 공식)
    for scale_name, idx in out.groupby("scale_name").groups.items():
        row_index = np.array(list(idx))
        vals = out.loc[row_index, "raw_score"].to_numpy(dtype=float)
        mask = np.isfinite(vals)
        n = int(mask.sum())
        if n == 0:
            continue
        ranks = rankdata(vals[mask], method="average")
        pct = 100.0 * (ranks - 0.5) / n
        target_index = row_index[mask]
        out.loc[target_index, "percentile"] = pct

    for scale_name, idx in out.groupby("scale_name").groups.items():
        row_index = np.array(list(idx))
        vals = out.loc[row_index, "axis_raw_score"].to_numpy(dtype=float)
        mask = np.isfinite(vals)
        if int(mask.sum()) <= 1:
            continue
        mean_v = float(vals[mask].mean())
        sd_v = float(vals[mask].std(ddof=1))
        if not np.isfinite(sd_v) or sd_v <= 0:
            continue
        target_index = row_index[mask]
        out.loc[target_index, "axis_z_score"] = (vals[mask] - mean_v) / sd_v

    out = out.sort_values(["student_id", "scale_name"]).reset_index(drop=True)
    return out


def classify_type(
    df_student_scores: pd.DataFrame,
    axis_config: Dict[str, Iterable[str]],
) -> pd.DataFrame:
    if df_student_scores.empty:
        return pd.DataFrame(
            columns=[
                "student_id",
                "axis_x",
                "axis_y",
                "type_code",
                "type_label",
                "x_efficacy_z",
                "x_growth_mindset_z",
                "x_belief_neg_z",
                "y_source",
                "y_value_z",
                "y_emotion_pos_z",
                "y_emotion_neg_z",
                "current_level_grade",
                "current_math_percentile",
            ]
        )

    student_ids = sorted(df_student_scores["student_id"].dropna().astype(str).unique().tolist())
    base = pd.DataFrame({"student_id": student_ids})
    axis_value_col = "axis_z_score" if "axis_z_score" in df_student_scores.columns else "z_score"
    use_oriented_axis = axis_value_col == "axis_z_score"

    belief_pos_aliases = ["belief_pos", "efficacy", "growth_mindset", "belief"]
    belief_neg_aliases = ["belief_neg", "external_attribution", "external_attribution_belief"]
    emotion_pos_aliases = ["emotion_pos", "emotional_stability", "interest"]
    emotion_neg_aliases = ["emotion_neg", "anxiety", "emotion_reactivity"]

    def axis_series_by_aliases(aliases: List[str], negative_axis: bool) -> pd.Series:
        scale_names: List[str] = []
        for alias in aliases:
            scale_names.extend(list(axis_config.get(alias, [])))
        scales = sorted(set(scale_names))
        if not scales:
            return pd.Series(index=student_ids, dtype=float)
        sub = df_student_scores.loc[df_student_scores["scale_name"].isin(scales), ["student_id", axis_value_col]].copy()
        if sub.empty:
            return pd.Series(index=student_ids, dtype=float)
        sign = 1.0
        if negative_axis and not use_oriented_axis:
            sign = -1.0
        sub["_axis_value"] = pd.to_numeric(sub[axis_value_col], errors="coerce") * sign
        s = sub.groupby("student_id")["_axis_value"].mean()
        return s.reindex(student_ids)

    belief_pos_z = axis_series_by_aliases(belief_pos_aliases, negative_axis=False)
    belief_neg_z = axis_series_by_aliases(belief_neg_aliases, negative_axis=True)
    emotion_pos_z = axis_series_by_aliases(emotion_pos_aliases, negative_axis=False)
    emotion_neg_z = axis_series_by_aliases(emotion_neg_aliases, negative_axis=True)

    base["x_efficacy_z"] = belief_pos_z.values
    base["x_growth_mindset_z"] = belief_pos_z.values
    base["x_belief_neg_z"] = belief_neg_z.values
    base["y_emotion_pos_z"] = emotion_pos_z.values
    base["y_emotion_neg_z"] = emotion_neg_z.values

    base["axis_x"] = (
        pd.concat([belief_pos_z, belief_neg_z], axis=1)
        .mean(axis=1, skipna=True)
        .reindex(student_ids)
        .to_numpy()
    )
    base["axis_x"] = np.where(
        np.isfinite(base["axis_x"]),
        base["axis_x"],
        np.nan,
    )
    base["axis_y"] = (
        pd.concat([emotion_pos_z, emotion_neg_z], axis=1)
        .mean(axis=1, skipna=True)
        .reindex(student_ids)
        .to_numpy()
    )
    base["axis_y"] = np.where(
        np.isfinite(base["axis_y"]),
        base["axis_y"],
        np.nan,
    )
    base["y_source"] = np.where(
        pd.notna(base["y_emotion_pos_z"]) & pd.notna(base["y_emotion_neg_z"]),
        "emotion_pos+emotion_neg",
        np.where(
            pd.notna(base["y_emotion_pos_z"]),
            "emotion_pos",
            np.where(pd.notna(base["y_emotion_neg_z"]), "emotion_neg", "missing"),
        ),
    )
    base["y_value_z"] = base["axis_y"]

    type_code = np.full(len(base), "UNCLASSIFIED", dtype=object)
    valid = pd.notna(base["axis_x"]) & pd.notna(base["axis_y"])
    mask_a = valid & (base["axis_x"] >= 0) & (base["axis_y"] >= 0)
    mask_b = valid & (base["axis_x"] < 0) & (base["axis_y"] >= 0)
    mask_c = valid & (base["axis_x"] < 0) & (base["axis_y"] < 0)
    mask_d = valid & (base["axis_x"] >= 0) & (base["axis_y"] < 0)
    type_code[mask_a] = "TYPE_A"
    type_code[mask_b] = "TYPE_B"
    type_code[mask_c] = "TYPE_C"
    type_code[mask_d] = "TYPE_D"
    base["type_code"] = type_code

    label_map = {
        "TYPE_A": "TYPE_A (x>=0, y>=0)",
        "TYPE_B": "TYPE_B (x<0, y>=0)",
        "TYPE_C": "TYPE_C (x<0, y<0)",
        "TYPE_D": "TYPE_D (x>=0, y<0)",
        "UNCLASSIFIED": "UNCLASSIFIED (결측/축값 없음)",
    }
    base["type_label"] = base["type_code"].map(label_map)

    student_meta = (
        df_student_scores.groupby("student_id", as_index=False)
        .agg(
            current_level_grade=("current_level_grade", _first_valid),
            current_math_percentile=("current_math_percentile", _first_valid),
        )
    )
    base = base.merge(student_meta, on="student_id", how="left")
    base = base[
        [
            "student_id",
            "axis_x",
            "axis_y",
            "type_code",
            "type_label",
            "x_efficacy_z",
            "x_growth_mindset_z",
            "x_belief_neg_z",
            "y_source",
            "y_value_z",
            "y_emotion_pos_z",
            "y_emotion_neg_z",
            "current_level_grade",
            "current_math_percentile",
        ]
    ]
    base = base.sort_values("student_id").reset_index(drop=True)
    return base


TYPE_CODE_ORDER = ["TYPE_A", "TYPE_B", "TYPE_C", "TYPE_D"]


def _percentile_to_level_grade(value: float | int | None) -> float:
    if value is None or not np.isfinite(value):
        return np.nan
    pct = float(value)
    if pct < 0 or pct > 100:
        return np.nan
    if pct <= 1:
        return 0.0
    if pct <= 4:
        return 1.0
    if pct <= 11:
        return 2.0
    if pct <= 23:
        return 3.0
    if pct <= 40:
        return 4.0
    if pct <= 60:
        return 5.0
    return 6.0


def _safe_variance(series: pd.Series) -> float:
    valid = series.dropna()
    n = len(valid)
    if n == 0:
        return np.nan
    if n == 1:
        return 0.0
    return float(valid.var(ddof=1))


def _safe_median(series: pd.Series) -> float:
    valid = series.dropna()
    if valid.empty:
        return np.nan
    return float(valid.median())


def _safe_iqr(series: pd.Series) -> float:
    valid = series.dropna()
    if valid.empty:
        return np.nan
    q1 = float(np.quantile(valid.to_numpy(dtype=float), 0.25))
    q3 = float(np.quantile(valid.to_numpy(dtype=float), 0.75))
    return float(q3 - q1)


def _cliffs_delta(group_a: np.ndarray, group_b: np.ndarray) -> float:
    a = np.asarray(group_a, dtype=float)
    b = np.asarray(group_b, dtype=float)
    if a.size == 0 or b.size == 0:
        return np.nan
    diff = a[:, None] - b[None, :]
    wins = np.sum(diff > 0)
    losses = np.sum(diff < 0)
    denom = float(a.size * b.size)
    if np.isclose(denom, 0.0):
        return np.nan
    return float((wins - losses) / denom)


def _holm_adjust(p_values: List[float]) -> List[float]:
    if not p_values:
        return []
    p = np.asarray(p_values, dtype=float)
    m = p.size
    order = np.argsort(p)
    adjusted = np.full(m, np.nan, dtype=float)
    prev = 0.0
    for rank, idx in enumerate(order):
        raw = p[idx]
        if not np.isfinite(raw):
            adjusted[idx] = np.nan
            continue
        value = (m - rank) * raw
        value = max(value, prev)
        prev = value
        adjusted[idx] = min(1.0, value)
    return adjusted.tolist()


def _build_type_level_base(student_type: pd.DataFrame) -> pd.DataFrame:
    work = student_type.copy()
    work["student_id"] = work["student_id"].astype("string").str.strip()
    work = work.loc[work["student_id"].notna() & (work["student_id"] != "")].copy()
    if work.empty:
        return work

    work["axis_x"] = pd.to_numeric(work.get("axis_x"), errors="coerce")
    work["axis_y"] = pd.to_numeric(work.get("axis_y"), errors="coerce")
    work["current_level_grade"] = pd.to_numeric(work.get("current_level_grade"), errors="coerce")
    work["current_math_percentile"] = pd.to_numeric(work.get("current_math_percentile"), errors="coerce")
    work["type_code"] = work["type_code"].astype("string").str.strip()

    explicit_grade = work["current_level_grade"]
    fallback_grade = work["current_math_percentile"].map(_percentile_to_level_grade)
    level_grade = explicit_grade.where(explicit_grade.notna(), fallback_grade)
    work["level_grade"] = level_grade
    work["level_grade_source"] = np.where(explicit_grade.notna(), "current_level_grade", np.where(fallback_grade.notna(), "current_math_percentile", "missing"))

    valid_grade = work["level_grade"].notna() & (work["level_grade"] >= 0) & (work["level_grade"] <= 6)
    work = work.loc[valid_grade].copy()
    if work.empty:
        return work

    work["level_grade"] = work["level_grade"].round().astype(int)
    work["state_index"] = work[["axis_y", "axis_x"]].mean(axis=1)
    work["is_high_state"] = (work["axis_y"] >= 0) & (work["axis_x"] >= 0)
    work["is_low_state"] = (work["axis_y"] < 0) & (work["axis_x"] < 0)
    work["is_high_ability"] = work["level_grade"] <= 2
    work["is_low_ability"] = work["level_grade"] >= 4
    return work


def _empty_validation_sheets() -> Dict[str, pd.DataFrame]:
    return {
        "Type_Level_Stats": pd.DataFrame(),
        "Group_Difference_Tests": pd.DataFrame(),
        "Ordinal_Regression": pd.DataFrame(),
        "Interaction_Test": pd.DataFrame(),
        "Mismatch_Patterns": pd.DataFrame(),
        "Cross_Validation": pd.DataFrame(),
    }


def _ordered_model_pseudo_r2(result: Any) -> float:
    llf = float(getattr(result, "llf", np.nan))
    llnull = float(getattr(result, "llnull", np.nan))
    if not np.isfinite(llf) or not np.isfinite(llnull) or np.isclose(llnull, 0.0):
        return np.nan
    return float(1.0 - (llf / llnull))


def _type_effect_interpretation(p_value: float, effect_size: float) -> str:
    if not np.isfinite(p_value):
        return "유형-실력 차이 검정을 수행할 데이터가 부족합니다."
    if p_value >= 0.05:
        return "유형이 현재 실력을 유의하게 설명한다고 보기 어렵습니다."
    if np.isfinite(effect_size) and effect_size >= 0.14:
        return "유형이 현재 실력과 비교적 큰 연관을 보입니다."
    if np.isfinite(effect_size) and effect_size >= 0.06:
        return "유형이 현재 실력과 중간 수준의 연관을 보입니다."
    return "유형-실력 차이는 유의하지만 효과 크기는 작습니다."


def compute_type_level_validation(
    student_type: pd.DataFrame,
    snapshot_version: str = "v1.0",
    cv_splits: int = 5,
    random_state: int = 42,
    warnings: List[str] | None = None,
) -> Tuple[Dict[str, pd.DataFrame], Dict[str, Any]]:
    warn = warnings if warnings is not None else []
    sheets = _empty_validation_sheets()
    summary: Dict[str, Any] = {
        "snapshot_version": snapshot_version,
        "status": "no_data",
        "n_students_total": int(student_type["student_id"].nunique()) if not student_type.empty and "student_id" in student_type.columns else 0,
        "n_students_with_level": 0,
        "n_students_with_type": 0,
        "kruskal_p_value": np.nan,
        "kruskal_epsilon2": np.nan,
        "interaction_p_value": np.nan,
        "cv_mae_mean": np.nan,
        "cv_qwk_mean": np.nan,
        "interpretation": {
            "type_explains_current_ability": "검증 데이터가 부족합니다.",
            "type_suggests_growth_potential": "단면 자료만으로 성장 가능성을 확정할 수 없습니다.",
            "type_as_independent_state": "추가 근거가 필요합니다.",
        },
    }

    if student_type.empty:
        warn.append("Student_Type가 비어 있어 유형-실력 검증을 건너뛰었습니다.")
        return sheets, summary

    base = _build_type_level_base(student_type)
    if base.empty:
        warn.append("current_level_grade/current_math_percentile 유효값이 없어 유형-실력 검증을 건너뛰었습니다.")
        return sheets, summary

    classified = base.loc[base["type_code"].isin(TYPE_CODE_ORDER)].copy()
    summary["n_students_with_level"] = int(base["student_id"].nunique())
    summary["n_students_with_type"] = int(classified["student_id"].nunique())

    if classified.empty:
        warn.append("유형(type_code)이 확정된 학생이 없어 유형-실력 검증을 건너뛰었습니다.")
        return sheets, summary

    # 1) 유형별 기술통계
    type_stats = (
        classified.groupby("type_code", as_index=False)
        .agg(
            n_students=("student_id", "nunique"),
            mean_level_grade=("level_grade", "mean"),
            variance_level_grade=("level_grade", _safe_variance),
            median_level_grade=("level_grade", _safe_median),
            iqr_level_grade=("level_grade", _safe_iqr),
            mean_emotion_z=("axis_y", "mean"),
            mean_belief_z=("axis_x", "mean"),
            mean_state_index=("state_index", "mean"),
        )
    )
    type_stats["type_code"] = pd.Categorical(type_stats["type_code"], categories=TYPE_CODE_ORDER, ordered=True)
    type_stats = type_stats.sort_values("type_code").reset_index(drop=True)
    type_stats["type_code"] = type_stats["type_code"].astype("string")
    for grade_code in range(7):
        counts = classified.loc[classified["level_grade"] == grade_code, "type_code"].value_counts()
        type_stats[f"grade_{grade_code}_n"] = type_stats["type_code"].map(counts).fillna(0).astype(int)
    type_stats["snapshot_version"] = snapshot_version
    sheets["Type_Level_Stats"] = type_stats

    # 2) 유형 간 차이 검정 (Kruskal + pairwise Mann-Whitney + Holm)
    grouped = {
        code: classified.loc[classified["type_code"] == code, "level_grade"].dropna().to_numpy(dtype=float)
        for code in TYPE_CODE_ORDER
    }
    test_rows: List[Dict[str, Any]] = []
    valid_groups = [(code, vals) for code, vals in grouped.items() if vals.size > 0]
    if len(valid_groups) >= 2:
        kw_groups = [vals for _, vals in valid_groups]
        kw_h, kw_p = kruskal(*kw_groups)
        n_total = int(sum(vals.size for vals in kw_groups))
        k = len(kw_groups)
        epsilon2 = np.nan
        if n_total > k:
            epsilon2 = float((kw_h - k + 1) / (n_total - k))
        summary["kruskal_p_value"] = float(kw_p)
        summary["kruskal_epsilon2"] = float(epsilon2) if np.isfinite(epsilon2) else np.nan
        test_rows.append(
            {
                "test": "kruskal_wallis",
                "comparison": "all_types",
                "group_count": k,
                "n_total": n_total,
                "statistic": float(kw_h),
                "p_value": float(kw_p),
                "p_adjusted_holm": np.nan,
                "effect_size": float(epsilon2) if np.isfinite(epsilon2) else np.nan,
                "effect_size_name": "epsilon_squared",
            }
        )
    else:
        warn.append("유형 간 비교를 위한 그룹 수가 부족해 Kruskal-Wallis를 계산하지 못했습니다.")

    pair_rows: List[Dict[str, Any]] = []
    raw_pvals: List[float] = []
    for code_a, code_b in combinations(TYPE_CODE_ORDER, 2):
        group_a = grouped.get(code_a, np.array([], dtype=float))
        group_b = grouped.get(code_b, np.array([], dtype=float))
        if group_a.size == 0 or group_b.size == 0:
            continue
        u_stat, p_value = mannwhitneyu(group_a, group_b, alternative="two-sided")
        delta = _cliffs_delta(group_a, group_b)
        row = {
            "test": "mann_whitney_u",
            "comparison": f"{code_a}_vs_{code_b}",
            "group_count": 2,
            "n_total": int(group_a.size + group_b.size),
            "n_group_a": int(group_a.size),
            "n_group_b": int(group_b.size),
            "statistic": float(u_stat),
            "p_value": float(p_value),
            "p_adjusted_holm": np.nan,
            "effect_size": float(delta) if np.isfinite(delta) else np.nan,
            "effect_size_name": "cliffs_delta",
            "median_diff_a_minus_b": float(np.median(group_a) - np.median(group_b)),
        }
        pair_rows.append(row)
        raw_pvals.append(float(p_value))

    adjusted_p = _holm_adjust(raw_pvals)
    for idx, row in enumerate(pair_rows):
        row["p_adjusted_holm"] = adjusted_p[idx] if idx < len(adjusted_p) else np.nan
    test_rows.extend(pair_rows)
    group_tests = pd.DataFrame(test_rows)
    if not group_tests.empty:
        group_tests["snapshot_version"] = snapshot_version
    sheets["Group_Difference_Tests"] = group_tests

    # 3) 순서형 회귀 + 상호작용 + 교차검증
    reg_base = classified.dropna(subset=["axis_x", "axis_y", "level_grade"]).copy()
    regression_rows: List[Dict[str, Any]] = []
    interaction_rows: List[Dict[str, Any]] = []
    cv_rows: List[Dict[str, Any]] = []

    if reg_base["level_grade"].nunique() >= 2:
        ordered_model_available = True
        sklearn_available = True
        try:
            from statsmodels.miscmodels.ordinal_model import OrderedModel
        except Exception:
            ordered_model_available = False
            warn.append("statsmodels가 없어 순서형 회귀/상호작용 검정을 건너뛰었습니다. requirements 설치가 필요합니다.")

        try:
            from sklearn.metrics import cohen_kappa_score, mean_absolute_error
            from sklearn.model_selection import KFold, StratifiedKFold
        except Exception:
            sklearn_available = False
            warn.append("scikit-learn이 없어 교차검증을 건너뛰었습니다. requirements 설치가 필요합니다.")

        if ordered_model_available:
            reg_work = reg_base.copy()
            reg_work["emotion_z"] = reg_work["axis_y"]
            reg_work["belief_z"] = reg_work["axis_x"]
            reg_work["interaction"] = reg_work["emotion_z"] * reg_work["belief_z"]
            reg_work = reg_work.sort_values("student_id").reset_index(drop=True)
            categories = sorted(reg_work["level_grade"].astype(int).unique().tolist())
            y_cat = pd.Categorical(reg_work["level_grade"].astype(int), categories=categories, ordered=True)
            x_base = reg_work[["emotion_z", "belief_z"]]
            x_full = reg_work[["emotion_z", "belief_z", "interaction"]]

            try:
                model_base = OrderedModel(y_cat, x_base, distr="logit")
                result_base = model_base.fit(method="bfgs", disp=False)
                model_full = OrderedModel(y_cat, x_full, distr="logit")
                result_full = model_full.fit(method="bfgs", disp=False)

                def _append_coeff_rows(result: Any, model_name: str, feature_names: List[str]) -> None:
                    params = result.params
                    if not isinstance(params, pd.Series):
                        params = pd.Series(params)
                    pvalues = result.pvalues
                    if not isinstance(pvalues, pd.Series):
                        pvalues = pd.Series(pvalues, index=params.index)
                    conf = result.conf_int() if hasattr(result, "conf_int") else None
                    conf_map: Dict[str, Tuple[float, float]] = {}
                    if conf is not None:
                        if isinstance(conf, pd.DataFrame):
                            for idx_name in conf.index:
                                conf_map[str(idx_name)] = (
                                    float(conf.loc[idx_name, 0]),
                                    float(conf.loc[idx_name, 1]),
                                )
                        else:
                            conf_arr = np.asarray(conf, dtype=float)
                            for idx, idx_name in enumerate(params.index):
                                if conf_arr.ndim >= 2 and idx < conf_arr.shape[0] and conf_arr.shape[1] >= 2:
                                    conf_map[str(idx_name)] = (
                                        float(conf_arr[idx, 0]),
                                        float(conf_arr[idx, 1]),
                                    )
                    for param_name, coef in params.items():
                        p_val = float(pvalues.get(param_name, np.nan))
                        ci_low = np.nan
                        ci_high = np.nan
                        if str(param_name) in conf_map:
                            ci_low = conf_map[str(param_name)][0]
                            ci_high = conf_map[str(param_name)][1]
                        is_coef = param_name in feature_names
                        regression_rows.append(
                            {
                                "model": model_name,
                                "parameter": param_name,
                                "parameter_type": "coefficient" if is_coef else "threshold",
                                "coef": float(coef),
                                "odds_ratio": float(np.exp(coef)) if is_coef else np.nan,
                                "ci_low": ci_low,
                                "ci_high": ci_high,
                                "p_value": p_val,
                                "is_significant_05": bool(np.isfinite(p_val) and p_val < 0.05),
                            }
                        )

                _append_coeff_rows(result_base, "ordinal_logit_base", ["emotion_z", "belief_z"])
                _append_coeff_rows(result_full, "ordinal_logit_interaction", ["emotion_z", "belief_z", "interaction"])

                lr_stat = 2.0 * (float(result_full.llf) - float(result_base.llf))
                df_diff = int(len(result_full.params) - len(result_base.params))
                lr_p = float(chi2.sf(lr_stat, df_diff)) if df_diff > 0 else np.nan
                interaction_rows.extend(
                    [
                        {
                            "model": "ordinal_logit_base",
                            "n_students": int(reg_work.shape[0]),
                            "log_likelihood": float(result_base.llf),
                            "aic": float(result_base.aic),
                            "bic": float(result_base.bic),
                            "pseudo_r2_mcfadden": _ordered_model_pseudo_r2(result_base),
                        },
                        {
                            "model": "ordinal_logit_interaction",
                            "n_students": int(reg_work.shape[0]),
                            "log_likelihood": float(result_full.llf),
                            "aic": float(result_full.aic),
                            "bic": float(result_full.bic),
                            "pseudo_r2_mcfadden": _ordered_model_pseudo_r2(result_full),
                        },
                        {
                            "model": "likelihood_ratio_test",
                            "n_students": int(reg_work.shape[0]),
                            "log_likelihood": np.nan,
                            "aic": np.nan,
                            "bic": np.nan,
                            "pseudo_r2_mcfadden": np.nan,
                            "lr_statistic": lr_stat,
                            "df_diff": df_diff,
                            "p_value": lr_p,
                        },
                    ]
                )
                summary["interaction_p_value"] = lr_p

                if sklearn_available:
                    y_values = reg_work["level_grade"].astype(int).to_numpy()
                    min_count = int(pd.Series(y_values).value_counts().min())
                    n_splits = int(max(2, min(cv_splits, reg_work.shape[0])))
                    if min_count >= 2 and n_splits <= min_count and len(np.unique(y_values)) >= 2:
                        splitter = StratifiedKFold(n_splits=n_splits, shuffle=True, random_state=random_state)
                        split_iter = splitter.split(x_full, y_values)
                    else:
                        splitter = KFold(n_splits=n_splits, shuffle=True, random_state=random_state)
                        split_iter = splitter.split(x_full)
                        warn.append(
                            "표본 제약으로 StratifiedKFold 대신 KFold를 사용했습니다. 교차검증 분산이 커질 수 있습니다."
                        )

                    for fold_no, (train_idx, test_idx) in enumerate(split_iter, start=1):
                        x_train = x_full.iloc[train_idx].reset_index(drop=True)
                        x_test = x_full.iloc[test_idx].reset_index(drop=True)
                        y_train = y_values[train_idx]
                        y_test = y_values[test_idx]
                        train_categories = sorted(np.unique(y_train).tolist())
                        if len(train_categories) < 2:
                            warn.append(f"fold={fold_no}의 train class가 1개라 CV를 건너뛰었습니다.")
                            continue
                        y_train_cat = pd.Categorical(y_train, categories=train_categories, ordered=True)
                        try:
                            cv_model = OrderedModel(y_train_cat, x_train, distr="logit")
                            cv_result = cv_model.fit(method="bfgs", disp=False)
                            pred_prob = np.asarray(cv_result.model.predict(cv_result.params, exog=x_test))
                            if pred_prob.ndim == 1:
                                pred_prob = pred_prob.reshape(-1, 1)
                            pred_idx = np.argmax(pred_prob, axis=1)
                            pred_grade = np.asarray(train_categories)[pred_idx]
                            mae = float(mean_absolute_error(y_test, pred_grade))
                            qwk = float(cohen_kappa_score(y_test, pred_grade, weights="quadratic"))
                            within_one = float(np.mean(np.abs(y_test - pred_grade) <= 1))
                            cv_rows.append(
                                {
                                    "fold": fold_no,
                                    "n_train": int(train_idx.size),
                                    "n_test": int(test_idx.size),
                                    "mae": mae,
                                    "qwk": qwk,
                                    "within_one_rate": within_one,
                                }
                            )
                        except Exception as exc:
                            warn.append(f"교차검증 fold={fold_no} 적합 실패: {exc}")

                    if cv_rows:
                        cv_df = pd.DataFrame(cv_rows)
                        cv_summary_row = {
                            "fold": "mean",
                            "n_train": int(cv_df["n_train"].mean()),
                            "n_test": int(cv_df["n_test"].mean()),
                            "mae": float(cv_df["mae"].mean()),
                            "qwk": float(cv_df["qwk"].mean()),
                            "within_one_rate": float(cv_df["within_one_rate"].mean()),
                        }
                        cv_df = pd.concat([cv_df, pd.DataFrame([cv_summary_row])], ignore_index=True)
                        sheets["Cross_Validation"] = cv_df
                        summary["cv_mae_mean"] = float(cv_summary_row["mae"])
                        summary["cv_qwk_mean"] = float(cv_summary_row["qwk"])
                    else:
                        warn.append("교차검증 결과가 비어 있어 성능 요약을 생성하지 못했습니다.")

            except Exception as exc:
                warn.append(f"순서형 회귀 적합 실패: {exc}")
        else:
            warn.append("순서형 회귀를 수행하지 못했습니다. statsmodels 설치 상태를 확인하세요.")
    else:
        warn.append("current_level_grade의 범주 다양성이 부족해 회귀/교차검증을 건너뛰었습니다.")

    if regression_rows:
        regression_df = pd.DataFrame(regression_rows)
        regression_df["snapshot_version"] = snapshot_version
        sheets["Ordinal_Regression"] = regression_df
    if interaction_rows:
        interaction_df = pd.DataFrame(interaction_rows)
        interaction_df["snapshot_version"] = snapshot_version
        sheets["Interaction_Test"] = interaction_df

    # 4) 불일치 패턴 탐색
    mismatch_source = classified.dropna(subset=["axis_x", "axis_y", "level_grade"]).copy()
    mismatch_rows: List[Dict[str, Any]] = []
    if not mismatch_source.empty:
        mismatch_source["pattern"] = "aligned_or_other"
        high_ability_low_state = mismatch_source["is_high_ability"] & mismatch_source["is_low_state"]
        low_ability_high_state = mismatch_source["is_low_ability"] & mismatch_source["is_high_state"]
        mismatch_source.loc[high_ability_low_state, "pattern"] = "high_ability_low_state"
        mismatch_source.loc[low_ability_high_state, "pattern"] = "low_ability_high_state"

        total_n = int(mismatch_source.shape[0])
        for pattern, grp in mismatch_source.groupby("pattern"):
            type_mix = grp["type_code"].value_counts(normalize=True)
            top_mix = ", ".join([f"{k}:{v:.0%}" for k, v in type_mix.head(3).items()])
            mismatch_rows.append(
                {
                    "pattern": pattern,
                    "n_students": int(grp["student_id"].nunique()),
                    "ratio": float(grp.shape[0] / total_n) if total_n > 0 else np.nan,
                    "mean_level_grade": float(grp["level_grade"].mean()),
                    "median_level_grade": float(grp["level_grade"].median()),
                    "mean_emotion_z": float(grp["axis_y"].mean()),
                    "mean_belief_z": float(grp["axis_x"].mean()),
                    "type_mix_top3": top_mix,
                }
            )
    mismatch_df = pd.DataFrame(mismatch_rows)
    if not mismatch_df.empty:
        mismatch_df["snapshot_version"] = snapshot_version
    sheets["Mismatch_Patterns"] = mismatch_df

    # 5) 요약 해석 텍스트
    if not classified.empty:
        corr_frame = classified.dropna(subset=["axis_x", "axis_y", "level_grade"]).copy()
        rho_emotion = np.nan
        rho_belief = np.nan
        if not corr_frame.empty:
            rho_emotion = float(spearmanr(corr_frame["axis_y"], corr_frame["level_grade"], nan_policy="omit").correlation)
            rho_belief = float(spearmanr(corr_frame["axis_x"], corr_frame["level_grade"], nan_policy="omit").correlation)
        summary["spearman_emotion_vs_grade"] = rho_emotion
        summary["spearman_belief_vs_grade"] = rho_belief

    summary["status"] = "ok"
    summary["type_counts"] = {
        code: int(classified.loc[classified["type_code"] == code, "student_id"].nunique())
        for code in TYPE_CODE_ORDER
    }
    summary["interpretation"] = {
        "type_explains_current_ability": _type_effect_interpretation(
            float(summary.get("kruskal_p_value", np.nan)),
            float(summary.get("kruskal_epsilon2", np.nan)),
        ),
        "type_suggests_growth_potential": "현재 분석은 단면 자료 기반이므로 성장 가능성은 추적 조사(2차/3차)로 별도 검증해야 합니다.",
        "type_as_independent_state": (
            "실력과 일부 연관이 있어도 유형을 원인으로 단정할 수 없으며, 정서·신념 상태 변수로 독립적으로 관찰하는 접근이 필요합니다."
        ),
    }
    return sheets, summary
