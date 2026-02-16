from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Dict, Iterable

import numpy as np
import pandas as pd


REQUIRED_OUTPUT_FILES = [
    "scale_stats_snapshot_v1.xlsx",
    "student_standard_scores_v1.xlsx",
    "snapshot_metadata.json",
]


def ensure_output_dir(path: str | Path) -> Path:
    out = Path(path)
    out.mkdir(parents=True, exist_ok=True)
    return out


def enforce_immutability(
    out_dir: Path,
    snapshot_version: str,
    force: bool = False,
    required_files: Iterable[str] | None = None,
) -> None:
    files = list(required_files) if required_files is not None else REQUIRED_OUTPUT_FILES
    if force:
        return
    if snapshot_version != "v1.0":
        return

    existing = [name for name in files if (out_dir / name).exists()]
    if existing:
        raise FileExistsError(
            "v1.0 산출물이 이미 존재합니다. 기본 정책상 덮어쓰기를 금지합니다. "
            f"(존재 파일: {existing}) --force 옵션 사용 시에만 덮어쓰기 허용."
        )


def round_float_columns(df: pd.DataFrame, decimals: int = 6) -> pd.DataFrame:
    out = df.copy()
    float_cols = out.select_dtypes(include=["float", "float16", "float32", "float64"]).columns
    for col in float_cols:
        out[col] = out[col].round(decimals)
    return out


def dataframe_sha256(
    df: pd.DataFrame,
    sort_by: Iterable[str] | None = None,
    decimals: int = 6,
) -> str:
    work = df.copy()
    if sort_by is not None:
        valid_sort_cols = [c for c in sort_by if c in work.columns]
        if valid_sort_cols:
            work = work.sort_values(valid_sort_cols).reset_index(drop=True)
    work = round_float_columns(work, decimals=decimals)
    csv_text = work.to_csv(index=False, na_rep="__NA__", lineterminator="\n")
    return hashlib.sha256(csv_text.encode("utf-8")).hexdigest()


def write_scale_workbook(
    path: str | Path,
    scale_stats: pd.DataFrame,
    scale_items: pd.DataFrame,
    by_current_level: pd.DataFrame,
    subjective_numeric_items: pd.DataFrame | None = None,
) -> None:
    output_path = Path(path)
    with pd.ExcelWriter(output_path, engine="openpyxl") as writer:
        scale_stats.to_excel(writer, index=False, sheet_name="Scale_Stats")
        scale_items.to_excel(writer, index=False, sheet_name="Scale_Items")
        by_current_level.to_excel(writer, index=False, sheet_name="By_Current_Level")
        if subjective_numeric_items is not None:
            subjective_numeric_items.to_excel(
                writer,
                index=False,
                sheet_name="Subjective_Numeric_Items",
            )


def write_student_workbook(
    path: str | Path,
    student_scores: pd.DataFrame,
    student_type: pd.DataFrame,
    student_subjective: pd.DataFrame | None = None,
) -> None:
    output_path = Path(path)
    with pd.ExcelWriter(output_path, engine="openpyxl") as writer:
        student_scores.to_excel(writer, index=False, sheet_name="Student_Standard_Scores")
        student_type.to_excel(writer, index=False, sheet_name="Student_Type")
        if student_subjective is not None:
            student_subjective.to_excel(
                writer,
                index=False,
                sheet_name="Student_Subjective",
            )


def write_type_level_workbook(path: str | Path, sheets: Dict[str, pd.DataFrame]) -> None:
    output_path = Path(path)
    ordered_sheet_names = [
        "Type_Level_Stats",
        "Group_Difference_Tests",
        "Ordinal_Regression",
        "Interaction_Test",
        "Mismatch_Patterns",
        "Cross_Validation",
    ]
    with pd.ExcelWriter(output_path, engine="openpyxl") as writer:
        wrote_any = False
        for sheet_name in ordered_sheet_names:
            df = sheets.get(sheet_name, pd.DataFrame())
            if df is None:
                df = pd.DataFrame()
            df.to_excel(writer, index=False, sheet_name=sheet_name)
            wrote_any = True
        if not wrote_any:
            pd.DataFrame().to_excel(writer, index=False, sheet_name="Type_Level_Stats")


def _json_safe(value):
    if isinstance(value, (np.generic,)):
        return value.item()
    if isinstance(value, float) and (np.isnan(value) or np.isinf(value)):
        return None
    if isinstance(value, (pd.Timestamp,)):
        return value.isoformat()
    return value


def write_metadata(path: str | Path, metadata: Dict) -> None:
    output_path = Path(path)
    with output_path.open("w", encoding="utf-8") as f:
        json.dump(metadata, f, ensure_ascii=False, indent=2, default=_json_safe)


def write_type_level_summary_json(path: str | Path, summary: Dict) -> None:
    output_path = Path(path)
    with output_path.open("w", encoding="utf-8") as f:
        json.dump(summary, f, ensure_ascii=False, indent=2, default=_json_safe)


def write_frozen_input(
    df: pd.DataFrame,
    out_dir: Path,
    freeze_format: str = "csv",
) -> Path:
    freeze_format = freeze_format.lower().strip()
    if freeze_format == "parquet":
        target = out_dir / "snapshot_input_frozen.parquet"
        try:
            df.to_parquet(target, index=False)
            return target
        except Exception:
            # pyarrow/fastparquet가 없는 환경을 고려해 CSV로 fallback
            fallback = out_dir / "snapshot_input_frozen.csv"
            df.to_csv(fallback, index=False, encoding="utf-8-sig")
            return fallback
    target = out_dir / "snapshot_input_frozen.csv"
    df.to_csv(target, index=False, encoding="utf-8-sig")
    return target
