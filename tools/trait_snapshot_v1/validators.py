from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import pandas as pd

RAW_REQUIRED_COLUMNS = [
    "student_id",
    "item_id",
    "question_type",
    "round_no",
    "raw_score",
    "response_ms",
    "answered_at",
    "reverse_item",
    "min_score",
    "max_score",
    "weight",
    "current_level_grade",
    "current_math_percentile",
]

RAW_OPTIONAL_COLUMNS = [
    "response_id",
    "item_text",
    "trait",
    "round_label",
]

SCALE_MAP_REQUIRED_COLUMNS = [
    "question_id",
    "scale_name",
    "include_in_alpha",
    "axis_tag",
]

SCALE_MAP_OPTIONAL_COLUMNS = [
    "analysis_group",  # core_scale | supplementary_numeric
]


def _validate_required_columns(df: pd.DataFrame, required: List[str], label: str) -> None:
    missing = [c for c in required if c not in df.columns]
    if missing:
        raise ValueError(f"[{label}] 필수 컬럼 누락: {missing}")


def _normalize_string_columns(df: pd.DataFrame, cols: List[str]) -> None:
    for col in cols:
        if col in df.columns:
            df[col] = df[col].astype("string").str.strip()


def _to_numeric(df: pd.DataFrame, cols: List[str]) -> None:
    for col in cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")


def load_raw_answers_csv(path: str | Path) -> pd.DataFrame:
    raw_path = Path(path)
    if not raw_path.exists():
        raise FileNotFoundError(f"raw_answers.csv 파일을 찾을 수 없습니다: {raw_path}")
    df = pd.read_csv(raw_path)
    df.columns = [str(c).strip() for c in df.columns]
    _validate_required_columns(df, RAW_REQUIRED_COLUMNS, "raw_answers.csv")

    for optional_col in RAW_OPTIONAL_COLUMNS:
        if optional_col not in df.columns:
            df[optional_col] = pd.NA

    _normalize_string_columns(
        df,
        [
            "student_id",
            "item_id",
            "question_type",
            "reverse_item",
            "response_id",
            "item_text",
            "trait",
            "round_label",
        ],
    )
    _to_numeric(
        df,
        [
            "round_no",
            "raw_score",
            "response_ms",
            "min_score",
            "max_score",
            "weight",
            "current_level_grade",
            "current_math_percentile",
        ],
    )
    df["answered_at"] = pd.to_datetime(df["answered_at"], errors="coerce", utc=True)
    df["question_type"] = df["question_type"].str.lower()
    df["reverse_item"] = df["reverse_item"].str.upper()
    return df


def load_scale_map_csv(path: str | Path) -> pd.DataFrame:
    map_path = Path(path)
    if not map_path.exists():
        raise FileNotFoundError(f"scale_map.csv 파일을 찾을 수 없습니다: {map_path}")
    df = pd.read_csv(map_path)
    df.columns = [str(c).strip() for c in df.columns]
    _validate_required_columns(df, SCALE_MAP_REQUIRED_COLUMNS, "scale_map.csv")

    for optional_col in SCALE_MAP_OPTIONAL_COLUMNS:
        if optional_col not in df.columns:
            df[optional_col] = pd.NA

    _normalize_string_columns(df, ["question_id", "scale_name", "axis_tag", "analysis_group"])
    _to_numeric(df, ["include_in_alpha"])
    df["include_in_alpha"] = df["include_in_alpha"].fillna(0).astype(int)
    invalid_include = ~df["include_in_alpha"].isin([0, 1])
    if invalid_include.any():
        bad_rows = df.loc[invalid_include, ["question_id", "include_in_alpha"]].to_dict("records")
        raise ValueError(f"[scale_map.csv] include_in_alpha는 0/1만 허용됩니다: {bad_rows[:10]}")

    # axis_tag는 빈 문자열을 결측으로 처리
    df["axis_tag"] = df["axis_tag"].replace("", pd.NA)
    df["analysis_group"] = (
        df["analysis_group"]
        .astype("string")
        .str.strip()
        .str.lower()
        .replace("", pd.NA)
        .fillna("core_scale")
    )
    invalid_group = ~df["analysis_group"].isin(["core_scale", "supplementary_numeric"])
    if invalid_group.any():
        bad_rows = df.loc[invalid_group, ["question_id", "analysis_group"]].to_dict("records")
        raise ValueError(
            "[scale_map.csv] analysis_group는 core_scale/supplementary_numeric만 허용됩니다: "
            f"{bad_rows[:10]}"
        )
    return df


def _validate_level_columns(df: pd.DataFrame, warnings: List[str]) -> None:
    level = df["current_level_grade"]
    invalid_level_mask = level.notna() & (~level.isin([0, 1, 2, 3, 4, 5, 6]))
    if invalid_level_mask.any():
        invalid_count = int(invalid_level_mask.sum())
        df.loc[invalid_level_mask, "current_level_grade"] = np.nan
        warnings.append(
            f"current_level_grade 범위(0~6) 이탈 {invalid_count}건을 결측으로 처리했습니다."
        )

    percentile = df["current_math_percentile"]
    invalid_pct_mask = percentile.notna() & ((percentile < 0) | (percentile > 100))
    if invalid_pct_mask.any():
        invalid_count = int(invalid_pct_mask.sum())
        df.loc[invalid_pct_mask, "current_math_percentile"] = np.nan
        warnings.append(
            f"current_math_percentile 범위(0~100) 이탈 {invalid_count}건을 결측으로 처리했습니다."
        )


def _dedupe_latest(df: pd.DataFrame) -> pd.DataFrame:
    work = df.copy()
    work["_row_order"] = np.arange(len(work))
    work["_answered_sort"] = work["answered_at"]
    min_ts = pd.Timestamp("1900-01-01", tz="UTC")
    work["_answered_sort"] = work["_answered_sort"].fillna(min_ts)
    sort_cols = ["student_id", "item_id", "_answered_sort", "_row_order"]
    if "response_id" in work.columns:
        sort_cols.insert(3, "response_id")
    work = work.sort_values(sort_cols)
    work = work.drop_duplicates(["student_id", "item_id"], keep="last")
    work = work.drop(columns=["_row_order", "_answered_sort"])
    return work


def _validate_raw_score_range(
    df: pd.DataFrame,
    range_error_threshold: float,
    warnings: List[str],
) -> pd.DataFrame:
    work = df.copy()
    scope_mask = work["question_type"] == "scale"
    if (work.loc[scope_mask, "min_score"] > work.loc[scope_mask, "max_score"]).any():
        bad = work.loc[
            scope_mask & (work["min_score"] > work["max_score"]),
            ["item_id", "min_score", "max_score"],
        ]
        raise ValueError(
            "min_score > max_score 데이터가 존재합니다. 예시: "
            f"{bad.head(10).to_dict('records')}"
        )

    valid_score_mask = scope_mask & work["raw_score"].notna() & work["min_score"].notna() & work["max_score"].notna()
    if valid_score_mask.sum() == 0:
        warnings.append("scale 문항의 min/max 유효범위 검증 대상이 없어 범위 검증을 건너뛰었습니다.")
        return work

    out_of_range_mask = valid_score_mask & (
        (work["raw_score"] < work["min_score"]) | (work["raw_score"] > work["max_score"])
    )
    out_of_range_n = int(out_of_range_mask.sum())
    ratio = out_of_range_n / int(valid_score_mask.sum())

    if ratio > range_error_threshold:
        sample = work.loc[out_of_range_mask, ["student_id", "item_id", "raw_score", "min_score", "max_score"]]
        raise ValueError(
            "raw_score 범위 이탈 비율이 임계치 초과: "
            f"{ratio:.4f} > {range_error_threshold:.4f}. "
            f"예시: {sample.head(10).to_dict('records')}"
        )

    if out_of_range_n > 0:
        warnings.append(
            f"raw_score 범위 이탈 {out_of_range_n}건({ratio:.2%})은 분석에서 제외했습니다."
        )
        work = work.loc[~out_of_range_mask].copy()

    return work


def _build_axis_config(scale_map: pd.DataFrame) -> Dict[str, List[str]]:
    axis_config: Dict[str, List[str]] = {}
    grouped = scale_map.groupby("scale_name", dropna=False)
    for scale_name, sub in grouped:
        tags = (
            sub["axis_tag"]
            .dropna()
            .astype("string")
            .str.strip()
            .replace("", pd.NA)
            .dropna()
            .unique()
            .tolist()
        )
        if len(tags) > 1:
            raise ValueError(
                f"scale_name={scale_name}에 axis_tag가 여러 개입니다: {tags}. "
                "scale 단위 axis_tag는 1개만 허용합니다."
            )
        if len(tags) == 1:
            tag = str(tags[0]).lower()
            axis_config.setdefault(tag, []).append(str(scale_name))

    for tag in axis_config:
        axis_config[tag] = sorted(set(axis_config[tag]))
    return axis_config


def _validate_axis_requirements(axis_config: Dict[str, List[str]]) -> None:
    missing_axes: List[str] = []
    if not axis_config.get("efficacy"):
        missing_axes.append("efficacy")
    if not axis_config.get("growth_mindset"):
        missing_axes.append("growth_mindset")
    if not axis_config.get("emotional_stability") and not axis_config.get("anxiety"):
        missing_axes.append("emotional_stability|anxiety")

    if missing_axes:
        raise ValueError(
            "유형 분류 필수 axis_tag 누락: "
            f"{missing_axes}. "
            "scale_map.csv의 axis_tag를 확인하세요."
        )


def validate_and_prepare_inputs(
    raw_df: pd.DataFrame,
    scale_map_df: pd.DataFrame,
    round_no: int,
    range_error_threshold: float,
) -> Tuple[pd.DataFrame, pd.DataFrame, Dict[str, List[str]], List[str]]:
    warnings: List[str] = []
    work = raw_df.copy()
    map_df = scale_map_df.copy()

    work = work.loc[
        work["student_id"].notna() & (work["student_id"] != "") & work["item_id"].notna() & (work["item_id"] != "")
    ].copy()
    if work.empty:
        raise ValueError("student_id/item_id가 유효한 행이 없습니다.")

    # 1) round_no / question_type / raw_score 필터
    work = work.loc[work["round_no"] == round_no].copy()
    if work.empty:
        raise ValueError(f"round_no={round_no} 데이터가 없습니다.")
    work = work.loc[work["question_type"].isin(["scale", "text"])].copy()
    if work.empty:
        raise ValueError("question_type이 scale/text인 데이터가 없습니다.")
    work = work.loc[work["raw_score"].notna()].copy()
    if work.empty:
        raise ValueError("raw_score가 모두 결측입니다.")

    invalid_reverse = work["reverse_item"].notna() & (~work["reverse_item"].isin(["Y", "N"]))
    if invalid_reverse.any():
        examples = work.loc[invalid_reverse, ["item_id", "reverse_item"]].drop_duplicates().head(10)
        raise ValueError(
            "reverse_item은 Y/N만 허용됩니다. 예시: "
            f"{examples.to_dict('records')}"
        )

    _validate_level_columns(work, warnings)
    work = _validate_raw_score_range(work, range_error_threshold, warnings)

    # 2) 최신 응답 dedupe
    before_dedupe = len(work)
    work = _dedupe_latest(work)
    if len(work) < before_dedupe:
        warnings.append(f"(student_id,item_id) 중복 {before_dedupe - len(work)}건을 최신 answered_at 기준으로 정리했습니다.")

    # 3) scale_map 유효성
    map_df = map_df.loc[map_df["question_id"].notna() & map_df["scale_name"].notna()].copy()
    dup = map_df.loc[map_df["question_id"].duplicated(keep=False)].copy()
    if not dup.empty:
        conflict_ids: List[str] = []
        for qid, g in dup.groupby("question_id"):
            sign = g[
                ["scale_name", "include_in_alpha", "axis_tag", "analysis_group"]
            ].fillna("__NA__").drop_duplicates()
            if sign.shape[0] > 1:
                conflict_ids.append(str(qid))
        if conflict_ids:
            raise ValueError(
                "scale_map.csv에 동일 question_id의 상충 매핑이 있습니다. "
                f"question_id 예시: {conflict_ids[:20]}"
            )
    map_df = map_df.drop_duplicates(subset=["question_id"], keep="first")
    if map_df.empty:
        raise ValueError("scale_map.csv에 유효한 question_id/scale_name이 없습니다.")

    core_candidates = work.loc[work["question_type"] == "scale", "item_id"].dropna().astype(str)
    core_map_ids = set(
        map_df.loc[map_df["analysis_group"] != "supplementary_numeric", "question_id"]
        .dropna()
        .astype(str)
        .tolist()
    )
    missing_map_items = sorted(set(core_candidates.tolist()) - core_map_ids)
    if missing_map_items:
        raise ValueError(
            "scale_map.csv에 없는 question_id가 raw_answers.csv에 존재합니다. "
            f"누락 수={len(missing_map_items)}, 예시={missing_map_items[:20]}"
        )

    # 4) merge + 파생 컬럼
    long_df = work.merge(
        map_df[["question_id", "scale_name", "include_in_alpha", "axis_tag", "analysis_group"]],
        left_on="item_id",
        right_on="question_id",
        how="left",
        validate="many_to_one",
    )
    core_missing_scale = long_df["scale_name"].isna() & (long_df["question_type"] == "scale")
    if core_missing_scale.any():
        bad_ids = sorted(long_df.loc[core_missing_scale, "item_id"].dropna().unique().tolist())
        raise ValueError(f"scale_name 매핑 실패 question_id: {bad_ids[:20]}")

    # map 미등록 text 문항은 보조지표로 자동 편입
    text_missing_scale = long_df["scale_name"].isna() & (long_df["question_type"] == "text")
    if text_missing_scale.any():
        auto_scale = (
            long_df.loc[text_missing_scale, "item_text"]
            .astype("string")
            .str.strip()
            .replace("", pd.NA)
            .fillna(long_df.loc[text_missing_scale, "item_id"].astype(str).map(lambda s: f"subjective_{s[:8]}"))
        )
        long_df.loc[text_missing_scale, "scale_name"] = auto_scale
        long_df.loc[text_missing_scale, "include_in_alpha"] = 0
        long_df.loc[text_missing_scale, "analysis_group"] = "supplementary_numeric"
        long_df.loc[text_missing_scale, "axis_tag"] = pd.NA
        warnings.append(
            f"scale_map에 없는 text 문항 {int(text_missing_scale.sum())}건을 보조지표(supplementary_numeric)로 자동 편입했습니다."
        )

    # analysis_group 기본값 및 타입-그룹 정합성 보정
    analysis_group = (
        long_df["analysis_group"]
        .astype("string")
        .str.strip()
        .str.lower()
        .replace("", pd.NA)
    )
    default_group = pd.Series(
        np.where(long_df["question_type"] == "text", "supplementary_numeric", "core_scale"),
        index=long_df.index,
        dtype="string",
    )
    long_df["analysis_group"] = analysis_group.where(analysis_group.notna(), default_group)
    text_core_mask = (long_df["question_type"] == "text") & (long_df["analysis_group"] == "core_scale")
    if text_core_mask.any():
        long_df.loc[text_core_mask, "analysis_group"] = "supplementary_numeric"
        long_df.loc[text_core_mask, "include_in_alpha"] = 0
        warnings.append(
            f"text 문항 {int(text_core_mask.sum())}건의 analysis_group을 supplementary_numeric로 보정했습니다."
        )
    scale_supp_mask = (long_df["question_type"] == "scale") & (long_df["analysis_group"] == "supplementary_numeric")
    if scale_supp_mask.any():
        long_df.loc[scale_supp_mask, "analysis_group"] = "core_scale"
        warnings.append(
            f"scale 문항 {int(scale_supp_mask.sum())}건의 analysis_group을 core_scale로 보정했습니다."
        )

    long_df["include_in_alpha"] = pd.to_numeric(long_df["include_in_alpha"], errors="coerce").fillna(0).astype(int)
    long_df.loc[long_df["analysis_group"] == "supplementary_numeric", "include_in_alpha"] = 0

    long_df["score_rc"] = np.where(
        (long_df["reverse_item"] == "Y") & (long_df["question_type"] == "scale"),
        long_df["min_score"] + long_df["max_score"] - long_df["raw_score"],
        long_df["raw_score"],
    )
    long_df["response_time_sec"] = long_df["response_ms"] / 1000.0
    long_df["axis_tag"] = long_df["axis_tag"].astype("string").str.strip().str.lower().replace("", pd.NA)

    # 5) axis config 검증 (실제 사용 문항 기준)
    effective_map = (
        long_df.loc[long_df["analysis_group"] == "core_scale", ["item_id", "scale_name", "include_in_alpha", "axis_tag"]]
        .drop_duplicates()
        .rename(columns={"item_id": "question_id"})
    )
    effective_map["axis_tag"] = effective_map["axis_tag"].astype("string").str.strip().str.lower().replace("", pd.NA)
    axis_config = _build_axis_config(effective_map)
    _validate_axis_requirements(axis_config)

    keep_cols = [
        "student_id",
        "item_id",
        "item_text",
        "trait",
        "question_type",
        "round_label",
        "round_no",
        "response_id",
        "answered_at",
        "raw_score",
        "score_rc",
        "response_ms",
        "response_time_sec",
        "reverse_item",
        "min_score",
        "max_score",
        "weight",
        "scale_name",
        "include_in_alpha",
        "axis_tag",
        "analysis_group",
        "current_level_grade",
        "current_math_percentile",
    ]
    out = long_df[keep_cols].copy()
    out = out.sort_values(["student_id", "item_id"]).reset_index(drop=True)
    return out, effective_map, axis_config, warnings
