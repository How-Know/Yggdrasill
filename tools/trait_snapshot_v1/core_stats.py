from __future__ import annotations

from typing import Dict, Iterable, List, Tuple

import numpy as np
import pandas as pd
from scipy.stats import rankdata


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
                "y_source",
                "y_value_z",
                "current_level_grade",
                "current_math_percentile",
            ]
        )

    student_ids = sorted(df_student_scores["student_id"].dropna().astype(str).unique().tolist())
    base = pd.DataFrame({"student_id": student_ids})

    def axis_series(axis_tag: str) -> pd.Series:
        scales = sorted(set(axis_config.get(axis_tag, [])))
        if not scales:
            return pd.Series(index=student_ids, dtype=float)
        sub = df_student_scores.loc[df_student_scores["scale_name"].isin(scales), ["student_id", "z_score"]]
        s = sub.groupby("student_id")["z_score"].mean()
        return s.reindex(student_ids)

    efficacy_z = axis_series("efficacy")
    growth_z = axis_series("growth_mindset")
    emotional_stability_z = axis_series("emotional_stability")
    anxiety_z = axis_series("anxiety")

    base["x_efficacy_z"] = efficacy_z.values
    base["x_growth_mindset_z"] = growth_z.values
    base["axis_x"] = np.where(
        pd.notna(base["x_efficacy_z"]) & pd.notna(base["x_growth_mindset_z"]),
        (base["x_efficacy_z"] + base["x_growth_mindset_z"]) / 2.0,
        np.nan,
    )

    has_emotional_stability_axis = len(set(axis_config.get("emotional_stability", []))) > 0
    if has_emotional_stability_axis:
        base["y_source"] = "emotional_stability"
        base["y_value_z"] = emotional_stability_z.values
        base["axis_y"] = base["y_value_z"]
    else:
        base["y_source"] = "anxiety_inverse"
        base["y_value_z"] = anxiety_z.values
        base["axis_y"] = -base["y_value_z"]

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
            "y_source",
            "y_value_z",
            "current_level_grade",
            "current_math_percentile",
        ]
    ]
    base = base.sort_values("student_id").reset_index(drop=True)
    return base
