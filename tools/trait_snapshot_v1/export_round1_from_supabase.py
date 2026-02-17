from __future__ import annotations

import argparse
import csv
import json
import os
import re
from pathlib import Path
from typing import Dict, Iterable, List, Optional
from urllib.parse import quote
from urllib.request import Request, urlopen


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Supabase에서 round1 raw_answers.csv/scale_map.csv 자동 추출"
    )
    parser.add_argument("--out-dir", required=True, help="출력 디렉터리")
    parser.add_argument("--survey-slug", default="trait_v1", help="기본 trait_v1")
    parser.add_argument(
        "--snapshot-cutoff-at",
        default=None,
        help="예: 2026-02-13T23:59:59+09:00, 미입력 시 현재까지 전체",
    )
    parser.add_argument("--supabase-url", default=None)
    parser.add_argument("--service-role-key", default=None)
    parser.add_argument(
        "--env-file",
        default=str(Path(__file__).resolve().parents[2] / "gateway" / ".env"),
        help="SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY를 읽을 .env 경로",
    )
    return parser.parse_args()


def load_env_file(path: str | Path) -> Dict[str, str]:
    env_path = Path(path)
    out: Dict[str, str] = {}
    if not env_path.exists():
        return out
    for line in env_path.read_text(encoding="utf-8").splitlines():
        row = line.strip()
        if not row or row.startswith("#") or "=" not in row:
            continue
        key, value = row.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def build_headers(service_role_key: str) -> Dict[str, str]:
    return {
        "apikey": service_role_key,
        "Authorization": f"Bearer {service_role_key}",
        "Accept": "application/json",
    }


def encode_query(params: Dict[str, str]) -> str:
    pieces: List[str] = []
    safe_chars = "(),.:_*+-/"
    for key, value in params.items():
        pieces.append(f"{quote(key, safe='') }={quote(value, safe=safe_chars)}")
    return "&".join(pieces)


def rest_get_json(
    base_url: str,
    table: str,
    headers: Dict[str, str],
    params: Dict[str, str],
) -> List[dict]:
    qs = encode_query(params)
    url = f"{base_url.rstrip('/')}/rest/v1/{table}?{qs}"
    req = Request(url, headers=headers, method="GET")
    with urlopen(req) as response:
        raw = response.read().decode("utf-8")
    data = json.loads(raw)
    if isinstance(data, list):
        return data
    raise ValueError(f"{table} 응답이 list가 아닙니다.")


def fetch_all(
    base_url: str,
    table: str,
    headers: Dict[str, str],
    params: Dict[str, str],
    page_size: int = 1000,
) -> List[dict]:
    offset = 0
    rows: List[dict] = []
    while True:
        page_params = {**params, "limit": str(page_size), "offset": str(offset)}
        page = rest_get_json(base_url, table, headers, page_params)
        rows.extend(page)
        if len(page) < page_size:
            break
        offset += page_size
    return rows


def chunked(values: List[str], size: int) -> Iterable[List[str]]:
    for idx in range(0, len(values), size):
        yield values[idx : idx + size]


def parse_round_no(round_label: str, round_map: Dict[str, int]) -> int:
    label = (round_label or "").strip()
    if label in round_map:
        return round_map[label]
    m = re.search(r"\d+", label)
    if m:
        return int(m.group(0))
    return 1


def to_number(value: object) -> Optional[float]:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    text = str(value).strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def to_raw_score(question_type: str, answer_number: object, answer_text: object) -> Optional[float]:
    num = to_number(answer_number)
    if num is not None:
        return num
    if question_type == "text":
        text = str(answer_text or "").strip()
        if re.fullmatch(r"\d+", text):
            return float(text)
    return None


def parse_tags(tags_raw: object) -> List[str]:
    if isinstance(tags_raw, list):
        return [str(x).strip() for x in tags_raw if str(x).strip()]
    text = str(tags_raw or "").strip()
    if not text:
        return []
    return [x.strip() for x in text.split(",") if x.strip()]


def normalize_key(text: str) -> str:
    return text.lower().replace(" ", "").replace("_", "").replace("-", "")


def infer_axis_tag(question: dict) -> str:
    tags = parse_tags(question.get("tags"))
    trait = str(question.get("trait") or "").strip()
    text = str(question.get("text") or "").strip()
    candidates = tags + [trait, text]
    keys = [normalize_key(x) for x in candidates if x]
    if any(re.search(r"외적귀인|외부귀인|귀인|운|난이도|환경|externalattribution|luck|environment", k) for k in keys):
        return "belief_neg"
    if any(re.search(r"growth|mindset|성장신념|능력관|efficacy|효능|자기효능|통제|주도|노력성과|회복기대|실패해석|자기개념|정체성|질문|이해", k) for k in keys):
        return "belief_pos"
    if any(re.search(r"anxiety|불안|긴장|위협|스트레스|반응성|fear|threat|reactiv", k) for k in keys):
        return "emotion_neg"
    if any(re.search(r"정서안정|안정성|흥미|몰입|재미|enjoy|stability|interest", k) for k in keys):
        return "emotion_pos"
    return ""


def write_csv(path: Path, rows: List[dict], fieldnames: List[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def main() -> int:
    args = parse_args()
    env_file_vars = load_env_file(args.env_file)

    supabase_url = args.supabase_url or os.environ.get("SUPABASE_URL") or env_file_vars.get("SUPABASE_URL")
    service_key = args.service_role_key or os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or env_file_vars.get("SUPABASE_SERVICE_ROLE_KEY")
    if not supabase_url or not service_key:
        raise ValueError("SUPABASE_URL 또는 SUPABASE_SERVICE_ROLE_KEY를 찾을 수 없습니다.")

    headers = build_headers(service_key)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    surveys = rest_get_json(
        supabase_url,
        "surveys",
        headers,
        {"select": "id,slug", "slug": f"eq.{args.survey_slug}", "limit": "1"},
    )
    if not surveys:
        raise ValueError(f"survey_slug={args.survey_slug} 를 찾을 수 없습니다.")
    survey_id = str(surveys[0]["id"])

    participants = fetch_all(
        supabase_url,
        "survey_participants",
        headers,
        {
            "select": "id,current_level_grade,current_math_percentile,survey_id",
            "survey_id": f"eq.{survey_id}",
            "order": "created_at.asc",
        },
    )
    participant_ids = [str(row["id"]) for row in participants if row.get("id")]
    participant_meta = {
        str(row["id"]): {
            "current_level_grade": row.get("current_level_grade"),
            "current_math_percentile": row.get("current_math_percentile"),
        }
        for row in participants
        if row.get("id")
    }
    if not participant_ids:
        raise ValueError("해당 survey의 participant가 없습니다.")

    questions = fetch_all(
        supabase_url,
        "questions",
        headers,
        {
            "select": "id,text,trait,tags,type,round_label,min_score,max_score,reverse,weight,is_active",
            "order": "created_at.asc",
        },
    )
    question_by_id = {
        str(q["id"]): q
        for q in questions
        if q.get("id")
    }

    rounds = fetch_all(
        supabase_url,
        "trait_rounds",
        headers,
        {"select": "name,order_index,created_at", "is_active": "eq.true", "order": "order_index.asc,created_at.asc"},
    )
    round_map: Dict[str, int] = {}
    for idx, row in enumerate(rounds):
        name = str(row.get("name") or "").strip()
        if not name:
            continue
        round_map[name] = idx + 1

    response_rows: List[dict] = []
    for chunk in chunked(participant_ids, 300):
        in_clause = ",".join(chunk)
        response_rows.extend(
            fetch_all(
                supabase_url,
                "question_responses",
                headers,
                {
                    "select": "id,participant_id",
                    "participant_id": f"in.({in_clause})",
                },
            )
        )
    response_to_participant = {
        str(r["id"]): str(r["participant_id"])
        for r in response_rows
        if r.get("id") and r.get("participant_id")
    }
    response_ids = list(response_to_participant.keys())
    if not response_ids:
        raise ValueError("question_responses가 없습니다.")

    answer_rows: List[dict] = []
    for chunk in chunked(response_ids, 250):
        in_clause = ",".join(chunk)
        params = {
            "select": "response_id,question_id,answer_number,answer_text,response_ms,answered_at",
            "response_id": f"in.({in_clause})",
        }
        if args.snapshot_cutoff_at:
            params["answered_at"] = f"lte.{args.snapshot_cutoff_at}"
        answer_rows.extend(fetch_all(supabase_url, "question_answers", headers, params))

    raw_output: List[dict] = []
    used_question_ids: set[str] = set()
    for row in answer_rows:
        response_id = str(row.get("response_id") or "").strip()
        question_id = str(row.get("question_id") or "").strip()
        participant_id = response_to_participant.get(response_id)
        question = question_by_id.get(question_id)
        if not participant_id or not question:
            continue

        q_type = str(question.get("type") or "").strip().lower()
        if q_type not in ("scale", "text"):
            continue

        raw_score = to_raw_score(q_type, row.get("answer_number"), row.get("answer_text"))
        if raw_score is None:
            continue

        round_label = str(question.get("round_label") or "").strip()
        round_no = parse_round_no(round_label, round_map)
        if round_no != 1:
            continue

        meta = participant_meta.get(participant_id, {})
        used_question_ids.add(question_id)
        raw_output.append(
            {
                "student_id": participant_id,
                "item_id": question_id,
                "question_type": q_type,
                "round_no": round_no,
                "raw_score": raw_score,
                "response_ms": to_number(row.get("response_ms")),
                "answered_at": row.get("answered_at"),
                "reverse_item": str(question.get("reverse") or "N").upper(),
                "min_score": to_number(question.get("min_score")) or 1,
                "max_score": to_number(question.get("max_score")) or 10,
                "weight": to_number(question.get("weight")) or 1,
                "current_level_grade": meta.get("current_level_grade"),
                "current_math_percentile": meta.get("current_math_percentile"),
                "response_id": response_id,
                "item_text": str(question.get("text") or ""),
                "trait": str(question.get("trait") or ""),
                "round_label": round_label,
            }
        )

    if not raw_output:
        raise ValueError("round_no=1 raw_output이 비어 있습니다.")

    scale_map_rows: List[dict] = []
    for question_id in sorted(used_question_ids):
        question = question_by_id.get(question_id, {})
        q_type = str(question.get("type") or "").strip().lower()
        trait = str(question.get("trait") or "").strip()
        text = str(question.get("text") or "").strip()
        if q_type == "text":
            scale_map_rows.append(
                {
                    "question_id": question_id,
                    "scale_name": text or f"subjective_{question_id[:8]}",
                    "include_in_alpha": 0,
                    "axis_tag": "",
                    "analysis_group": "supplementary_numeric",
                }
            )
            continue

        axis_tag = infer_axis_tag(question)
        scale_map_rows.append(
            {
                "question_id": question_id,
                "scale_name": trait or f"scale_{question_id[:8]}",
                "include_in_alpha": 1,
                "axis_tag": axis_tag,
                "analysis_group": "core_scale",
            }
        )

    core_indices = [i for i, row in enumerate(scale_map_rows) if row["analysis_group"] == "core_scale"]
    core_axis_tags = {scale_map_rows[i]["axis_tag"] for i in core_indices}
    fill_cursor = 0
    required = ["belief_pos"]
    has_emotion = ("emotion_neg" in core_axis_tags) or ("emotion_pos" in core_axis_tags)
    if not has_emotion:
        required.append("emotion_neg")
    for axis_tag in required:
        if axis_tag in core_axis_tags:
            continue
        if not core_indices:
            continue
        idx = core_indices[fill_cursor % len(core_indices)]
        scale_map_rows[idx]["axis_tag"] = axis_tag
        core_axis_tags.add(axis_tag)
        fill_cursor += 1

    raw_path = out_dir / "raw_answers.csv"
    scale_map_path = out_dir / "scale_map.csv"
    write_csv(
        raw_path,
        raw_output,
        [
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
            "response_id",
            "item_text",
            "trait",
            "round_label",
        ],
    )
    write_csv(
        scale_map_path,
        scale_map_rows,
        ["question_id", "scale_name", "include_in_alpha", "axis_tag", "analysis_group"],
    )
    print(f"[export] raw_answers.csv: {raw_path}")
    print(f"[export] scale_map.csv: {scale_map_path}")
    print(f"[export] rows={len(raw_output)}, map_rows={len(scale_map_rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
