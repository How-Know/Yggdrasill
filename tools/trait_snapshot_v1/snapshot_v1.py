from __future__ import annotations

import argparse
import json
import traceback
from pathlib import Path
from typing import Dict, List

import numpy as np
import pandas as pd

from core_stats import (
    classify_type,
    compute_scale_stats,
    compute_standard_scores,
)
from io_outputs import (
    REQUIRED_OUTPUT_FILES,
    dataframe_sha256,
    enforce_immutability,
    ensure_output_dir,
    round_float_columns,
    write_frozen_input,
    write_metadata,
    write_scale_workbook,
    write_student_workbook,
)
from validators import (
    load_raw_answers_csv,
    load_scale_map_csv,
    validate_and_prepare_inputs,
)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="성향조사 1차 데이터 기반 v1.0 스냅샷 생성기"
    )
    parser.add_argument("--raw", required=True, help="raw_answers.csv 경로")
    parser.add_argument("--scale-map", required=True, help="scale_map.csv 경로")
    parser.add_argument("--out", required=True, help="출력 디렉터리")
    parser.add_argument("--survey-slug", required=True, help="예: trait_v1")
    parser.add_argument(
        "--snapshot-cutoff-at",
        required=True,
        help='예: "2026-02-13T23:59:59+09:00"',
    )
    parser.add_argument("--round-no", type=int, default=1, help="기본 1")
    parser.add_argument("--logic-version", default="v1.0.0")
    parser.add_argument("--snapshot-version", default="v1.0")
    parser.add_argument("--range-error-threshold", type=float, default=0.01)
    parser.add_argument(
        "--freeze-format",
        choices=["csv", "parquet"],
        default="csv",
        help="snapshot_input_frozen 포맷",
    )
    parser.add_argument("--force", action="store_true", help="v1.0 파일 덮어쓰기 허용")
    return parser.parse_args()


def _unique_warnings(warnings: List[str]) -> List[str]:
    seen = set()
    out: List[str] = []
    for w in warnings:
        if w not in seen:
            out.append(w)
            seen.add(w)
    return out


def _build_by_current_level(student_scores: pd.DataFrame) -> pd.DataFrame:
    if student_scores.empty:
        return pd.DataFrame(
            columns=[
                "scale_name",
                "current_level_grade",
                "n_students",
                "mean_raw_score",
                "sd_raw_score",
                "mean_z_score",
                "mean_percentile",
            ]
        )
    work = student_scores.copy()
    work = work.loc[work["current_level_grade"].notna()].copy()
    if work.empty:
        return pd.DataFrame(
            columns=[
                "scale_name",
                "current_level_grade",
                "n_students",
                "mean_raw_score",
                "sd_raw_score",
                "mean_z_score",
                "mean_percentile",
            ]
        )

    out = (
        work.groupby(["scale_name", "current_level_grade"], as_index=False)
        .agg(
            n_students=("student_id", "nunique"),
            mean_raw_score=("raw_score", "mean"),
            sd_raw_score=("raw_score", lambda s: s.std(ddof=1) if s.notna().sum() > 1 else (0.0 if s.notna().sum() == 1 else np.nan)),
            mean_z_score=("z_score", "mean"),
            mean_percentile=("percentile", "mean"),
        )
        .sort_values(["scale_name", "current_level_grade"])
        .reset_index(drop=True)
    )
    return out


def _build_student_item_matrix(df_long: pd.DataFrame) -> pd.DataFrame:
    if df_long.empty:
        return pd.DataFrame(columns=["student_id"])
    matrix = (
        df_long.pivot_table(
            index="student_id",
            columns="item_id",
            values="score_rc",
            aggfunc="last",
        )
        .sort_index()
        .reset_index()
    )
    matrix.columns = [str(c) for c in matrix.columns]
    return matrix


def _build_subjective_item_stats(df_supp: pd.DataFrame) -> pd.DataFrame:
    if df_supp.empty:
        return pd.DataFrame(
            columns=[
                "item_id",
                "item_text",
                "scale_name",
                "n_respondents",
                "mean",
                "sd",
                "min",
                "max",
                "response_time_sec_mean",
            ]
        )

    out = (
        df_supp.groupby(["item_id", "item_text", "scale_name"], as_index=False)
        .agg(
            n_respondents=("student_id", "nunique"),
            mean=("score_rc", "mean"),
            sd=("score_rc", lambda s: s.std(ddof=1) if s.notna().sum() > 1 else (0.0 if s.notna().sum() == 1 else np.nan)),
            min=("score_rc", "min"),
            max=("score_rc", "max"),
            response_time_sec_mean=("response_time_sec", "mean"),
        )
        .sort_values(["scale_name", "item_id"])
        .reset_index(drop=True)
    )
    return out


def _build_student_subjective(df_supp: pd.DataFrame, snapshot_version: str) -> pd.DataFrame:
    if df_supp.empty:
        return pd.DataFrame(
            columns=[
                "student_id",
                "item_id",
                "item_text",
                "scale_name",
                "raw_score",
                "score_rc",
                "response_time_sec",
                "current_level_grade",
                "current_math_percentile",
                "snapshot_version",
            ]
        )

    out = (
        df_supp[
            [
                "student_id",
                "item_id",
                "item_text",
                "scale_name",
                "raw_score",
                "score_rc",
                "response_time_sec",
                "current_level_grade",
                "current_math_percentile",
            ]
        ]
        .copy()
        .sort_values(["student_id", "item_id"])
        .reset_index(drop=True)
    )
    out["snapshot_version"] = snapshot_version
    return out


def _build_level_distribution(df_long: pd.DataFrame) -> Dict[str, int]:
    if df_long.empty:
        return {}
    student_levels = (
        df_long.groupby("student_id", as_index=False)
        .agg(current_level_grade=("current_level_grade", "first"))
    )
    counts = student_levels["current_level_grade"].value_counts(dropna=False)
    out: Dict[str, int] = {}
    for key, value in counts.items():
        if pd.isna(key):
            out["null"] = int(value)
        else:
            out[str(int(key))] = int(value)
    return out


def _build_percentile_summary(df_long: pd.DataFrame) -> Dict[str, float | int | None]:
    if df_long.empty:
        return {
            "count": 0,
            "mean": None,
            "sd": None,
            "min": None,
            "max": None,
            "p25": None,
            "p50": None,
            "p75": None,
        }
    student_pct = (
        df_long.groupby("student_id", as_index=False)
        .agg(current_math_percentile=("current_math_percentile", "first"))
    )["current_math_percentile"].dropna()
    if student_pct.empty:
        return {
            "count": 0,
            "mean": None,
            "sd": None,
            "min": None,
            "max": None,
            "p25": None,
            "p50": None,
            "p75": None,
        }
    return {
        "count": int(student_pct.shape[0]),
        "mean": float(student_pct.mean()),
        "sd": float(student_pct.std(ddof=1)) if student_pct.shape[0] > 1 else 0.0,
        "min": float(student_pct.min()),
        "max": float(student_pct.max()),
        "p25": float(student_pct.quantile(0.25)),
        "p50": float(student_pct.quantile(0.50)),
        "p75": float(student_pct.quantile(0.75)),
    }


def _fixed_scale_stats_dict(scale_stats: pd.DataFrame) -> Dict[str, Dict]:
    out: Dict[str, Dict] = {}
    for _, row in scale_stats.iterrows():
        scale_name = str(row["scale_name"])
        out[scale_name] = {
            "mean": None if pd.isna(row["mean"]) else float(row["mean"]),
            "sd": None if pd.isna(row["sd"]) else float(row["sd"]),
            "alpha": None if pd.isna(row["cronbach_alpha"]) else float(row["cronbach_alpha"]),
            "item_count": int(row["item_count"]),
            "n_respondents": int(row["n_respondents"]),
            "alpha_n_complete": int(row["alpha_n_complete"]),
        }
    return out


def _to_iso_timestamp(value: str) -> str:
    ts = pd.to_datetime(value, utc=True, errors="coerce")
    if pd.isna(ts):
        raise ValueError(f"snapshot_cutoff_at 파싱 실패: {value}")
    return ts.isoformat()


def _print_step(msg: str) -> None:
    print(f"[snapshot_v1] {msg}")


def main() -> int:
    args = _parse_args()
    warnings: List[str] = []

    if args.round_no < 1:
        raise ValueError("--round-no는 1 이상의 정수여야 합니다.")
    if args.range_error_threshold < 0 or args.range_error_threshold > 1:
        raise ValueError("--range-error-threshold는 0~1 범위여야 합니다.")

    snapshot_cutoff_iso = _to_iso_timestamp(args.snapshot_cutoff_at)
    snapshot_date = snapshot_cutoff_iso

    out_dir = ensure_output_dir(args.out)
    enforce_immutability(
        out_dir=out_dir,
        snapshot_version=args.snapshot_version,
        force=args.force,
        required_files=REQUIRED_OUTPUT_FILES,
    )

    _print_step("입력 CSV 로드 시작")
    raw_df = load_raw_answers_csv(args.raw)
    scale_map_df = load_scale_map_csv(args.scale_map)
    _print_step(
        f"입력 로드 완료: raw_rows={len(raw_df):,}, scale_map_rows={len(scale_map_df):,}"
    )

    long_df, effective_map, axis_config, prep_warnings = validate_and_prepare_inputs(
        raw_df=raw_df,
        scale_map_df=scale_map_df,
        round_no=args.round_no,
        range_error_threshold=args.range_error_threshold,
    )
    warnings.extend(prep_warnings)
    core_df = long_df.loc[long_df["analysis_group"] == "core_scale"].copy()
    supp_df = long_df.loc[long_df["analysis_group"] == "supplementary_numeric"].copy()
    if core_df.empty:
        raise ValueError("core_scale 데이터가 없습니다. v1.0 기준선 계산을 진행할 수 없습니다.")
    _print_step(
        f"전처리 완료: all_rows={len(long_df):,}, core_rows={len(core_df):,}, "
        f"supp_rows={len(supp_df):,}, students={long_df['student_id'].nunique():,}, "
        f"core_items={core_df['item_id'].nunique():,}, supp_items={supp_df['item_id'].nunique():,}, "
        f"core_scales={effective_map['scale_name'].nunique():,}"
    )

    scale_stats, scale_items = compute_scale_stats(
        df_long=core_df,
        scale_map=effective_map,
        snapshot_version=args.snapshot_version,
        snapshot_date=snapshot_date,
        warnings=warnings,
    )
    student_scores = compute_standard_scores(
        df_long=core_df,
        scale_stats=scale_stats,
        snapshot_version=args.snapshot_version,
    )
    student_type = classify_type(
        df_student_scores=student_scores,
        axis_config=axis_config,
    )
    student_type["snapshot_version"] = args.snapshot_version

    by_current_level = _build_by_current_level(student_scores)
    student_item_matrix = _build_student_item_matrix(long_df)
    subjective_item_stats = _build_subjective_item_stats(supp_df)
    student_subjective = _build_student_subjective(
        supp_df,
        snapshot_version=args.snapshot_version,
    )

    # 재현성을 위해 반올림/정렬 정책 고정
    scale_stats = round_float_columns(scale_stats, decimals=6)
    scale_items = round_float_columns(scale_items, decimals=6)
    student_scores = round_float_columns(student_scores, decimals=6)
    student_type = round_float_columns(student_type, decimals=6)
    by_current_level = round_float_columns(by_current_level, decimals=6)
    student_item_matrix = round_float_columns(student_item_matrix, decimals=6)
    subjective_item_stats = round_float_columns(subjective_item_stats, decimals=6)
    student_subjective = round_float_columns(student_subjective, decimals=6)

    scale_stats = scale_stats.sort_values(["scale_name"]).reset_index(drop=True)
    scale_items = scale_items.sort_values(["scale_name", "item_id"]).reset_index(drop=True)
    student_scores = student_scores.sort_values(["student_id", "scale_name"]).reset_index(drop=True)
    student_type = student_type.sort_values(["student_id"]).reset_index(drop=True)
    by_current_level = by_current_level.sort_values(["scale_name", "current_level_grade"]).reset_index(drop=True)
    student_item_matrix = student_item_matrix.sort_values(["student_id"]).reset_index(drop=True)
    subjective_item_stats = subjective_item_stats.sort_values(["scale_name", "item_id"]).reset_index(drop=True)
    student_subjective = student_subjective.sort_values(["student_id", "item_id"]).reset_index(drop=True)

    # 해시 계산
    frozen_input_df = long_df[
        [
            "student_id",
            "item_id",
            "question_type",
            "scale_name",
            "axis_tag",
            "analysis_group",
            "raw_score",
            "score_rc",
            "response_ms",
            "response_time_sec",
            "reverse_item",
            "min_score",
            "max_score",
            "weight",
            "current_level_grade",
            "current_math_percentile",
            "answered_at",
        ]
    ].copy()
    frozen_input_df["answered_at"] = frozen_input_df["answered_at"].astype("string")

    data_hash = dataframe_sha256(
        frozen_input_df,
        sort_by=["student_id", "item_id", "answered_at"],
        decimals=6,
    )
    scale_map_hash = dataframe_sha256(
        scale_map_df[["question_id", "scale_name", "include_in_alpha", "axis_tag", "analysis_group"]],
        sort_by=["question_id"],
        decimals=6,
    )

    total_n = int(core_df["student_id"].nunique())
    if total_n < 30:
        warnings.append(f"표본 수(total_N={total_n})가 30 미만입니다. 해석 시 주의가 필요합니다.")
    if supp_df.empty:
        warnings.append("보조지표(supplementary_numeric) 문항이 없습니다.")

    metadata = {
        "version": args.snapshot_version,
        "snapshot_date": snapshot_date,
        "total_N": total_n,
        "used_item_ids": sorted(core_df["item_id"].dropna().astype(str).unique().tolist()),
        "core_item_ids": sorted(core_df["item_id"].dropna().astype(str).unique().tolist()),
        "supplementary_item_ids": sorted(supp_df["item_id"].dropna().astype(str).unique().tolist()),
        "subjective_in_core": False,
        "survey_slug": args.survey_slug,
        "snapshot_cutoff_at": snapshot_cutoff_iso,
        "round_no": args.round_no,
        "fixed_scale_stats": _fixed_scale_stats_dict(scale_stats),
        "level_distribution": _build_level_distribution(core_df),
        "current_math_percentile_summary": _build_percentile_summary(core_df),
        "supplementary_item_stats_count": int(subjective_item_stats.shape[0]),
        "supplementary_student_rows": int(student_subjective.shape[0]),
        "logic_version": args.logic_version,
        "data_hash": data_hash,
        "scale_map_hash": scale_map_hash,
        "warnings": _unique_warnings(warnings),
        "axis_config": {k: sorted(set(v)) for k, v in axis_config.items()},
        "generated_at": pd.Timestamp.utcnow().isoformat(),
    }

    # 출력
    scale_book = out_dir / "scale_stats_snapshot_v1.xlsx"
    student_book = out_dir / "student_standard_scores_v1.xlsx"
    metadata_path = out_dir / "snapshot_metadata.json"
    matrix_book = out_dir / "student_item_matrix_v1.xlsx"

    write_scale_workbook(
        path=scale_book,
        scale_stats=scale_stats,
        scale_items=scale_items,
        by_current_level=by_current_level,
        subjective_numeric_items=subjective_item_stats,
    )
    write_student_workbook(
        path=student_book,
        student_scores=student_scores,
        student_type=student_type,
        student_subjective=student_subjective,
    )
    write_metadata(metadata_path, metadata)
    frozen_path = write_frozen_input(
        df=frozen_input_df.sort_values(["student_id", "item_id", "answered_at"]).reset_index(drop=True),
        out_dir=out_dir,
        freeze_format=args.freeze_format,
    )

    with pd.ExcelWriter(matrix_book, engine="openpyxl") as writer:
        student_item_matrix.to_excel(writer, index=False, sheet_name="Student_Item_Matrix")

    _print_step(f"출력 완료: {scale_book}")
    _print_step(f"출력 완료: {student_book}")
    _print_step(f"출력 완료: {metadata_path}")
    _print_step(f"권장 출력 완료: {matrix_book}")
    _print_step(f"권장 출력 완료: {frozen_path}")
    _print_step(
        "요약: "
        f"students(core)={total_n}, scales={scale_stats.shape[0]}, "
        f"student_scale_rows={student_scores.shape[0]}, supplementary_items={subjective_item_stats.shape[0]}, "
        f"warnings={len(metadata['warnings'])}"
    )
    print(json.dumps({"status": "ok", "output_dir": str(out_dir)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[snapshot_v1] ERROR: {exc}")
        traceback.print_exc()
        raise SystemExit(1)
