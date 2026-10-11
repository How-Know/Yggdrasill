# -*- coding: utf-8 -*-
"""Search, rename, and missing-paper rules for the two exam folders."""

from __future__ import annotations

import base64
import hashlib
import json
import math
import os
import re
import shutil
import sys
import tempfile
import threading
import time
from collections import defaultdict
from pathlib import Path

HIGH_NAME = "- 내신 기출 (고등)"
MID_NAME = "- 내신 기출 (중등)"


def program_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent


HERE = program_dir()


def _dropbox_roots() -> list[Path]:
    roots = []
    bases = []
    for key in ("APPDATA", "LOCALAPPDATA"):
        value = os.environ.get(key, "").strip()
        if value:
            bases.append(Path(value) / "Dropbox")
    for base in bases:
        info = base / "info.json"
        if info.is_file():
            try:
                data = json.loads(info.read_text(encoding="utf-8-sig"))
            except (OSError, json.JSONDecodeError):
                data = {}
            if isinstance(data, dict):
                for item in data.values():
                    if isinstance(item, dict) and item.get("path"):
                        roots.append(Path(item["path"]))
        host = base / "host.db"
        if host.is_file():
            try:
                lines = [line.strip() for line in host.read_text(encoding="utf-8", errors="ignore").splitlines() if line.strip()]
                if lines:
                    roots.append(Path(base64.b64decode(lines[-1]).decode("utf-8")))
            except (OSError, ValueError, UnicodeDecodeError):
                pass
    home = Path.home() / "Dropbox"
    if home.is_dir():
        roots.append(home)
    return roots


def _find_named(root: Path, name: str) -> Path | None:
    direct = root / name
    if direct.is_dir():
        return direct
    try:
        children = [child for child in root.iterdir() if child.is_dir()]
    except OSError:
        return None
    for child in children:
        nested = child / name
        if nested.is_dir():
            return nested
    return None


def discover_roots() -> tuple[Path, Path]:
    env_high = os.environ.get("EXAM_DESK_HIGH", "").strip()
    env_mid = os.environ.get("EXAM_DESK_MID", "").strip()
    found_high = Path(env_high) if env_high else None
    found_mid = Path(env_mid) if env_mid else None
    seen = set()
    for root in (HERE, HERE.parent, *_dropbox_roots()):
        key = os.path.normcase(str(root))
        if key in seen or not root.is_dir():
            continue
        seen.add(key)
        if found_high is None:
            found_high = _find_named(root, HIGH_NAME)
        if found_mid is None:
            found_mid = _find_named(root, MID_NAME)
        if found_high and found_mid:
            break
    if found_high is None:
        found_high = Path.home() / "Dropbox" / HIGH_NAME
    if found_mid is None:
        found_mid = Path.home() / "Dropbox" / MID_NAME
    return found_high, found_mid


def _dismiss_file(high: Path) -> Path:
    if high.is_dir():
        return high / "내신기출_숨김.json"
    return HERE / "data" / "dismissed.json"


def _migrate_dismiss(path: Path) -> None:
    local = HERE / "data" / "dismissed.json"
    if path == local or path.exists() or not local.is_file():
        return
    try:
        data = json.loads(local.read_text(encoding="utf-8"))
        ids = [item for item in data.get("ids", []) if isinstance(item, str)]
    except (OSError, json.JSONDecodeError):
        return
    if not ids:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"ids": ids}, ensure_ascii=False, indent=2), encoding="utf-8")


HIGH_ROOT, MID_ROOT = discover_roots()
DISMISS_PATH = _dismiss_file(HIGH_ROOT)
_migrate_dismiss(DISMISS_PATH)

HIGH_MAJOR = [
    "경신고",
    "경북고",
    "능인고",
    "대구여고",
    "대구혜화여고",
    "대륜고",
    "오성고",
    "정화여고",
]
HIGH_MAJOR_SET = set(HIGH_MAJOR)
HIGH_SUSEONG = ["대구남산고", "대구중앙고", "덕원고", "동문고", "수성고", "시지고"]
HIGH_GROUPS = {"주요 8교": HIGH_MAJOR, "수성구 기타": HIGH_SUSEONG}

MID_MAJOR = ["경신중", "능인중", "대륜중", "동도중", "소선여중", "오성중", "정화중", "황금중"]
MID_MAJOR_SET = set(MID_MAJOR)

GRADE_RE = re.compile(r"(중[123]|고[123])\s*(공통)?")
EXAM_RE = re.compile(r"^([12])학기(중간|기말|[12]차)(.+)$")
PREFIX_RE = re.compile(r"^(?:내신\s*)?(\d{4})년\s+(.+)$")
NOTE_RE = re.compile(r"[（(]([^）)]*)[）)]")
PERIOD_RE = re.compile(r"^(\d{4}) ([12])학기 (중간|기말)$")

STANDARD_G1 = {}
for _year in (2022, 2023, 2024):
    for _exam in ("중간", "기말"):
        STANDARD_G1[(_year, "1", _exam)] = "수학상"
        STANDARD_G1[(_year, "2", _exam)] = "수학하"
STANDARD_G1[(2025, "1", "중간")] = "공통수학1"
STANDARD_G1[(2025, "1", "기말")] = "공통수학1"
STANDARD_G1[(2025, "2", "중간")] = "공통수학2"
STANDARD_G1[(2025, "2", "기말")] = "공통수학2"

STANDARD_MID = {}
for _year in (2022, 2023, 2024, 2025):
    for _exam in ("중간", "기말"):
        STANDARD_MID[(_year, "1", _exam, "중1")] = "중등수학1상"
        STANDARD_MID[(_year, "1", _exam, "중2")] = "중등수학2상"
        STANDARD_MID[(_year, "1", _exam, "중3")] = "중등수학3상"
        STANDARD_MID[(_year, "2", _exam, "중2")] = "중등수학2하"
        STANDARD_MID[(_year, "2", _exam, "중3")] = "중등수학3하"

_LOCK = threading.Lock()
_FILES = None
_AT = 0.0
_TTL = 20.0
_DISMISS_LOCK = threading.Lock()


def normalize_sido(token: str) -> str:
    if token in ("대구시", "부산시", "인천시", "광주시", "대전시", "울산시"):
        return token[:-1]
    return token


def folder_exam_name(file_exam: str) -> str:
    if file_exam == "1차":
        return "중간"
    if file_exam == "2차":
        return "기말"
    return file_exam


def parse_filename(name: str) -> dict:
    stem = Path(name).stem.strip()
    raw_notes = [note.strip() for note in NOTE_RE.findall(stem) if note.strip()]
    copies = []
    notes = []
    for note in raw_notes:
        compact = re.sub(r"\s+", "", note)
        if re.fullmatch(r"\d+", compact):
            copies.append(compact)
        elif compact == "서술형없음":
            notes.append("(서술형 없음)")
        elif compact == "서술형":
            notes.append("(서술형)")
        else:
            notes.append(f"({note})")
    cleaned = re.sub(r"\s+", " ", NOTE_RE.sub(" ", stem)).strip()
    match = PREFIX_RE.match(cleaned)
    if not match:
        raise ValueError("연도 형식을 읽지 못했습니다")
    year = match.group(1)
    rest = match.group(2).strip()
    grade_match = GRADE_RE.search(rest)
    if not grade_match:
        raise ValueError("학년을 읽지 못했습니다")
    before = rest[: grade_match.start()].strip()
    after = rest[grade_match.end() :].strip()
    grade = grade_match.group(1)
    loc = before.split()
    if len(loc) < 3:
        raise ValueError("지역과 학교를 읽지 못했습니다")
    school = loc[-1]
    sido = normalize_sido(loc[0])
    sigungu = loc[1]
    exam_match = EXAM_RE.match(re.sub(r"\s+", "", after))
    if not exam_match:
        raise ValueError("시험과 과목을 읽지 못했습니다")
    sem = exam_match.group(1)
    file_exam = exam_match.group(2)
    subject = exam_match.group(3)
    letter = ""
    if len(subject) >= 2 and subject[-1].isascii() and subject[-1].isupper() and subject[-2] in "상하":
        letter = subject[-1]
        subject = subject[:-1]
    if subject.endswith("서술형없음") and len(subject) > len("서술형없음"):
        subject = subject[: -len("서술형없음")]
        if "(서술형 없음)" not in notes:
            notes.append("(서술형 없음)")
    elif subject.endswith("서술형") and len(subject) > len("서술형"):
        subject = subject[: -len("서술형")]
        if "(서술형)" not in notes:
            notes.append("(서술형)")
    if not subject:
        raise ValueError("과목이 비어 있습니다")
    placed_exam = folder_exam_name(file_exam)
    new_name = f"{year}년 {sido} {sigungu} {school} {grade} {sem}학기{file_exam} {subject}"
    if letter:
        new_name += f" {letter}"
    if notes:
        new_name += " " + " ".join(notes)
    new_name += ".hml"
    return {
        "year": year,
        "sem": sem,
        "file_exam": file_exam,
        "placed_exam": placed_exam,
        "period": f"{year} {sem}학기 {placed_exam}",
        "sido": sido,
        "sigungu": sigungu,
        "school": school,
        "grade": grade,
        "subject": subject,
        "letter": letter,
        "notes": notes,
        "copies": copies,
        "new_name": new_name,
    }


def classify(parsed: dict, high: Path | None = None, mid: Path | None = None) -> dict:
    high = HIGH_ROOT if high is None else high
    mid = MID_ROOT if mid is None else mid
    root = high if parsed["grade"].startswith("고") else mid
    period = root / parsed["period"]
    grade = parsed["grade"]
    school = parsed["school"]
    if grade.startswith("중"):
        level = "중등"
        if school in MID_MAJOR_SET:
            group = "주요 학교"
            bucket = ""
            target = period / parsed["new_name"]
        elif parsed["sigungu"] == "수성구":
            group = "수성구 기타"
            bucket = "수성구"
            target = period / bucket / parsed["new_name"]
        else:
            raise ValueError("수성구가 아닌 중학교는 중등 폴더에 넣을 자리가 없습니다")
        root = mid
    else:
        level = "고등"
        root = high
        if school in HIGH_MAJOR_SET:
            group = "주요 8교"
            bucket = ""
            target = period / parsed["new_name"]
        elif parsed["sigungu"] == "수성구":
            group = "수성구 기타"
            bucket = "수성구"
            target = period / bucket / parsed["new_name"]
        else:
            group = "전국"
            bucket = "전국구"
            target = period / bucket / parsed["new_name"]
    return {
        "level": level,
        "group": group,
        "bucket": bucket,
        "target": target,
        "root": root,
    }


def actual_bucket(path: Path) -> str:
    parent = path.parent.name
    if parent in ("수성구", "전국구", "중등"):
        return parent
    if PERIOD_RE.match(parent):
        return "시험폴더"
    return parent


def _under(path: Path, root: Path) -> Path:
    resolved = path.resolve()
    resolved.relative_to(root.resolve())
    return resolved


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def place_new(target: Path, data: bytes, root: Path) -> tuple[Path, str]:
    digest = sha256_bytes(data)
    names = [target]
    names.append(target.with_name(f"{target.stem} (다른 내용){target.suffix}"))
    for index in range(3, 20):
        names.append(target.with_name(f"{target.stem} (다른 내용 {index}){target.suffix}"))
    for index, candidate in enumerate(names):
        _under(candidate, root)
        if candidate.exists():
            if sha256_file(candidate) == digest:
                return candidate, "same"
            continue
        candidate.parent.mkdir(parents=True, exist_ok=True)
        _under(candidate, root)
        temp_path = candidate.with_name(f".{candidate.name}.part")
        temp_path.write_bytes(data)
        temp_path.replace(candidate)
        return candidate, "created" if index == 0 else "variant"
    raise ValueError("같은 이름의 파일이 너무 많습니다")


def import_bytes(filename: str, data: bytes) -> dict:
    if Path(filename).suffix.lower() != ".hml":
        raise ValueError("hml 파일만 넣을 수 있습니다")
    if not data:
        raise ValueError("빈 파일은 넣지 않습니다")
    parsed = parse_filename(filename)
    placed = classify(parsed)
    target, status = place_new(placed["target"], data, placed["root"])
    invalidate()
    bucket = placed["bucket"] or "시험폴더"
    return {
        "status": status,
        "from": Path(filename).name,
        "name": target.name,
        "level": placed["level"],
        "where": f"{placed['level']} / {parsed['period']} / {bucket}",
        "path": str(target),
    }


def _iter_hml(root: Path):
    if not root.exists():
        return
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() != ".hml":
            continue
        if path.name.startswith("~$") or "_재정리_임시" in path.parts:
            continue
        yield path


def _index_path(path: Path, archive: str, root: Path) -> dict:
    bucket = actual_bucket(path)
    record = {
        "path": str(path),
        "name": path.name,
        "rel": str(path.relative_to(root)),
        "archive": archive,
        "bucket": bucket,
        "ok": False,
        "level": archive,
        "year": "",
        "sem": "",
        "exam": "",
        "file_exam": "",
        "school": "",
        "grade": "",
        "subject": "",
        "letter": "",
        "group": "",
        "sido": "",
        "sigungu": "",
        "notes": "",
        "error": "",
        "infer": None,
    }
    try:
        parsed = parse_filename(path.name)
    except ValueError as exc:
        record["error"] = str(exc)
        return record
    record.update(
        {
            "year": parsed["year"],
            "sem": parsed["sem"],
            "exam": parsed["placed_exam"],
            "file_exam": parsed["file_exam"],
            "school": parsed["school"],
            "grade": parsed["grade"],
            "subject": parsed["subject"],
            "letter": parsed["letter"],
            "sido": parsed["sido"],
            "sigungu": parsed["sigungu"],
            "notes": " ".join(parsed["notes"]),
            "level": "중등" if parsed["grade"].startswith("중") else "고등",
        }
    )
    try:
        placed = classify(parsed)
    except ValueError as exc:
        record["error"] = str(exc)
        return record
    record["ok"] = True
    record["group"] = placed["group"]
    record["infer"] = {
        "year": parsed["year"],
        "sem": parsed["sem"],
        "file_exam": parsed["file_exam"],
        "placed_exam": parsed["placed_exam"],
        "school": parsed["school"],
        "grade": parsed["grade"],
        "subject": parsed["subject"],
        "group": placed["group"],
        "sido": parsed["sido"],
        "sigungu": parsed["sigungu"],
    }
    return record


def scan() -> list[dict]:
    records = []
    for path in _iter_hml(HIGH_ROOT):
        records.append(_index_path(path, "고등", HIGH_ROOT))
    for path in _iter_hml(MID_ROOT):
        records.append(_index_path(path, "중등", MID_ROOT))
    return records


def get_files(force: bool = False) -> list[dict]:
    global _FILES, _AT
    with _LOCK:
        now = time.monotonic()
        if not force and _FILES is not None and now - _AT < _TTL:
            return _FILES
        files = scan()
        _FILES = files
        _AT = now
        return files


def invalidate() -> None:
    global _AT
    with _LOCK:
        _AT = 0.0


def _missing_id(level: str, row: dict) -> str:
    return "|".join(
        [level, row["year"], row["sem"], row["exam"], row["school"], row["grade"], row["subject"]]
    )


def _finish_missing(level: str, row: dict) -> dict:
    bucket = row.get("bucket") or ""
    filename = (
        f"{row['year']}년 {row['sido']} {row['sigungu']} {row['school']} "
        f"{row['grade']} {row['sem']}학기{row['exam']} {row['subject']}.hml"
    )
    where_parts = [row["period"], bucket, filename] if bucket else [row["period"], filename]
    row["level"] = level
    row["filename"] = filename
    row["where"] = " / ".join(where_parts)
    row["id"] = _missing_id(level, row)
    row["bucket_label"] = bucket or "시험폴더"
    return row


def infer_high(rows: list[dict]) -> list[dict]:
    present = set()
    school_meta = {}
    g1_periods = defaultdict(set)
    schools_with_g1 = set()
    by_school_pattern = defaultdict(set)
    period_grade_subject = defaultdict(set)
    for row in rows:
        if not str(row["grade"]).startswith("고"):
            continue
        present.add((row["year"], row["sem"], row["placed_exam"], row["school"], row["grade"], row["subject"]))
        school_meta[row["school"]] = {
            "group": row["group"],
            "sido": row["sido"],
            "sigungu": row["sigungu"],
        }
        if row["grade"] == "고1":
            schools_with_g1.add(row["school"])
            g1_periods[(row["school"], row["year"], row["sem"], row["placed_exam"])].add(row["subject"])
        if row["file_exam"] in ("중간", "기말"):
            by_school_pattern[
                (row["school"], row["grade"], row["subject"], row["sem"], row["file_exam"])
            ].add(int(row["year"]))
        period_grade_subject[
            (row["year"], row["sem"], row["placed_exam"], row["group"], row["grade"], row["subject"])
        ].add(row["school"])

    missing = {}

    def add(year, sem, exam, school, grade, subject, reason):
        meta = school_meta.get(school)
        if meta is None:
            return
        key = (str(year), sem, exam, school, grade, subject)
        if key in present:
            return
        item = missing.get(key)
        if item is None:
            missing[key] = {
                "year": str(year),
                "sem": sem,
                "exam": exam,
                "school": school,
                "grade": grade,
                "subject": subject,
                "group": meta["group"],
                "sido": meta["sido"],
                "sigungu": meta["sigungu"],
                "reasons": [reason],
            }
        elif reason not in item["reasons"]:
            item["reasons"].append(reason)

    for (school, grade, subject, sem, exam), years in by_school_pattern.items():
        if len(years) < 2:
            continue
        have = ", ".join(str(year) for year in sorted(years))
        for year in range(min(years), max(years) + 1):
            if year not in years:
                add(
                    year,
                    sem,
                    exam,
                    school,
                    grade,
                    subject,
                    f"같은 학교·학년·과목이 {have}년에 있고 {year}년에는 없음",
                )

    for (year, sem, exam), subject in STANDARD_G1.items():
        for group_name, schools in HIGH_GROUPS.items():
            for school in schools:
                if school not in school_meta:
                    continue
                if g1_periods.get((school, str(year), sem, exam)):
                    continue
                if group_name != "주요 8교" and school not in schools_with_g1:
                    continue
                add(year, sem, exam, school, "고1", subject, "고1 기본 과목이 이 회차에 없음")

    for (year, sem, exam, group, grade, subject), schools in period_grade_subject.items():
        if grade not in ("고1", "고2") or group not in HIGH_GROUPS:
            continue
        universe = [school for school in HIGH_GROUPS[group] if school in school_meta]
        need = math.ceil(len(universe) * 0.75)
        if len(schools) < need:
            continue
        for school in universe:
            if school in schools:
                continue
            add(
                year,
                sem,
                exam,
                school,
                grade,
                subject,
                f"같은 시기 {group} {len(universe)}곳 중 {len(schools)}곳이 가지고 있음",
            )

    done = []
    for row in missing.values():
        if row["group"] == "주요 8교":
            bucket = ""
        elif row["group"] == "수성구 기타":
            bucket = "수성구"
        else:
            bucket = "전국구"
        row["bucket"] = bucket
        row["period"] = f"{row['year']} {row['sem']}학기 {row['exam']}"
        done.append(_finish_missing("고등", row))
    exam_order = {"중간": 0, "기말": 1}
    done.sort(
        key=lambda row: (
            0 if row["group"] == "주요 8교" else 1 if row["group"] == "수성구 기타" else 2,
            HIGH_MAJOR.index(row["school"]) if row["school"] in HIGH_MAJOR_SET else 99,
            row["school"],
            row["year"],
            row["sem"],
            exam_order.get(row["exam"], 9),
            row["grade"],
            row["subject"],
        )
    )
    return done


def infer_middle(rows: list[dict]) -> list[dict]:
    present = set()
    any_paper = set()
    grade_seen = set()
    school_meta = {}
    pattern_years = defaultdict(set)
    peer = defaultdict(set)
    for row in rows:
        if not str(row["grade"]).startswith("중"):
            continue
        base = (row["year"], row["sem"], row["placed_exam"], row["school"], row["grade"], row["subject"])
        present.add(base)
        any_paper.add((row["year"], row["sem"], row["placed_exam"], row["school"], row["grade"]))
        grade_seen.add((row["school"], row["grade"]))
        school_meta[row["school"]] = {
            "group": row["group"],
            "sido": row["sido"],
            "sigungu": row["sigungu"],
        }
        pattern_years[(row["school"], row["grade"], row["subject"], row["sem"], row["placed_exam"])].add(int(row["year"]))
        peer[(row["year"], row["sem"], row["placed_exam"], row["group"], row["grade"], row["subject"])].add(row["school"])

    missing = {}

    def add(year, sem, exam, school, grade, subject, reason):
        key = (str(year), sem, exam, school, grade, subject)
        if key in present:
            return
        item = missing.get(key)
        if item is None:
            meta = school_meta[school]
            missing[key] = {
                "year": str(year),
                "sem": sem,
                "exam": exam,
                "school": school,
                "grade": grade,
                "subject": subject,
                "group": meta["group"],
                "sido": meta["sido"],
                "sigungu": meta["sigungu"],
                "reasons": [reason],
            }
        elif reason not in item["reasons"]:
            item["reasons"].append(reason)

    for (school, grade, subject, sem, exam), years in pattern_years.items():
        if len(years) < 2:
            continue
        have = ", ".join(str(year) for year in sorted(years))
        for year in range(min(years), max(years) + 1):
            if year not in years:
                add(year, sem, exam, school, grade, subject, f"같은 학교·학년·과목이 {have}년에 있고 {year}년에는 없음")

    groups = {
        "주요 학교": [school for school in MID_MAJOR if school in school_meta],
        "수성구 기타": [school for school, meta in school_meta.items() if meta["group"] == "수성구 기타"],
    }
    for (year, sem, exam, grade), subject in STANDARD_MID.items():
        for group_name, schools in groups.items():
            for school in schools:
                if (str(year), sem, exam, school, grade) in any_paper:
                    continue
                if group_name != "주요 학교" and (school, grade) not in grade_seen:
                    continue
                add(year, sem, exam, school, grade, subject, "이 학년의 기본 과목이 이 회차에 없음")

    for (year, sem, exam, group, grade, subject), schools in peer.items():
        if group not in groups:
            continue
        universe = groups[group]
        need = math.ceil(len(universe) * 0.75)
        if len(schools) < need:
            continue
        for school in universe:
            if school in schools:
                continue
            if group != "주요 학교" and (school, grade) not in grade_seen:
                continue
            add(
                year,
                sem,
                exam,
                school,
                grade,
                subject,
                f"같은 시기 {group} {len(universe)}곳 중 {len(schools)}곳이 가지고 있음",
            )

    done = []
    for row in missing.values():
        bucket = "" if row["group"] == "주요 학교" else "수성구"
        row["bucket"] = bucket
        row["period"] = f"{row['year']} {row['sem']}학기 {row['exam']}"
        done.append(_finish_missing("중등", row))
    exam_order = {"중간": 0, "기말": 1}
    done.sort(
        key=lambda row: (
            0 if row["group"] == "주요 학교" else 1,
            MID_MAJOR.index(row["school"]) if row["school"] in MID_MAJOR_SET else 99,
            row["school"],
            row["year"],
            row["sem"],
            exam_order.get(row["exam"], 9),
            row["grade"],
            row["subject"],
        )
    )
    return done


def load_dismissed() -> set[str]:
    with _DISMISS_LOCK:
        if not DISMISS_PATH.exists():
            return set()
        try:
            data = json.loads(DISMISS_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return set()
        return {item for item in data.get("ids", []) if isinstance(item, str)}


def _save_dismissed(ids: set[str]) -> None:
    DISMISS_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"ids": sorted(ids)}, ensure_ascii=False, indent=2)
    temp = DISMISS_PATH.with_suffix(".tmp")
    temp.write_text(payload, encoding="utf-8")
    temp.replace(DISMISS_PATH)


def dismiss(item_id: str) -> None:
    if item_id.count("|") != 6:
        raise ValueError("항목을 찾지 못했습니다")
    with _DISMISS_LOCK:
        ids = set()
        if DISMISS_PATH.exists():
            try:
                ids = {item for item in json.loads(DISMISS_PATH.read_text(encoding="utf-8")).get("ids", []) if isinstance(item, str)}
            except (OSError, json.JSONDecodeError):
                ids = set()
        ids.add(item_id)
        _save_dismissed(ids)


def restore(item_id: str) -> None:
    with _DISMISS_LOCK:
        ids = set()
        if DISMISS_PATH.exists():
            try:
                ids = {item for item in json.loads(DISMISS_PATH.read_text(encoding="utf-8")).get("ids", []) if isinstance(item, str)}
            except (OSError, json.JSONDecodeError):
                ids = set()
        ids.discard(item_id)
        _save_dismissed(ids)


def snapshot(force: bool = False) -> dict:
    files = get_files(force)
    high_rows = []
    mid_rows = []
    for record in files:
        row = record.get("infer")
        if not row:
            continue
        if record["level"] == "중등":
            mid_rows.append(row)
        elif record["level"] == "고등":
            high_rows.append(row)
    missing = infer_high(high_rows) + infer_middle(mid_rows)
    hidden_ids = load_dismissed()
    visible = [row for row in missing if row["id"] not in hidden_ids]
    hidden = [row for row in missing if row["id"] in hidden_ids]
    return {
        "files": files,
        "visible": visible,
        "hidden": hidden,
        "high_count": sum(1 for record in files if record["archive"] == "고등"),
        "mid_count": sum(1 for record in files if record["archive"] == "중등"),
        "unread": sum(1 for record in files if not record["ok"]),
    }


def public_file(record: dict) -> dict:
    sem = f"{record['sem']}학기" if record["sem"] else ""
    title = " ".join(part for part in (record["school"], record["grade"], record["subject"], record["letter"]) if part)
    if record["notes"]:
        title = f"{title} {record['notes']}".strip()
    if not title:
        title = record["name"]
    folder = "고등 폴더" if record["archive"] == "고등" else "중등 폴더"
    meta = " · ".join(
        part
        for part in (
            f"{record['year']}년" if record["year"] else "",
            sem,
            record["file_exam"] or record["exam"],
            folder,
            record["bucket"],
        )
        if part
    )
    return {
        "path": record["path"],
        "name": record["name"],
        "title": title,
        "meta": meta,
        "level": record["level"],
        "archive": record["archive"],
        "ok": record["ok"],
    }


def search(query: str, level: str, force: bool = False, limit: int = 80) -> dict:
    tokens = [token for token in query.split() if token.strip()]
    files = get_files(force)
    if not tokens:
        return {"total": 0, "items": [], "empty": True}
    matched = []
    for record in files:
        if level in ("고등", "중등") and record["level"] != level:
            continue
        parts = [
            record["name"],
            record["rel"],
            record["year"],
            f"{record['sem']}학기" if record["sem"] else "",
            record["exam"],
            record["file_exam"],
            record["school"],
            record["grade"],
            record["subject"],
            record["letter"],
            record["group"],
            record["bucket"],
            record["sido"],
            record["sigungu"],
            record["level"],
            record["archive"],
            record["notes"],
        ]
        hay = " ".join(part for part in parts if part).casefold()
        compact = hay.replace(" ", "")
        ok = True
        for token in tokens:
            folded = token.casefold()
            squeezed = folded.replace(" ", "")
            if folded not in hay and squeezed not in compact:
                ok = False
                break
        if ok:
            matched.append(record)
    matched.sort(key=lambda record: (record["year"], record["sem"], record["exam"], record["school"], record["grade"], record["name"]))
    return {
        "total": len(matched),
        "items": [public_file(record) for record in matched[:limit]],
        "empty": False,
        "limited": len(matched) > limit,
    }


def inside_archives(path: Path) -> Path:
    resolved = path.resolve()
    for root in (HIGH_ROOT, MID_ROOT):
        try:
            resolved.relative_to(root.resolve())
            return resolved
        except ValueError:
            continue
    raise ValueError("두 폴더 안의 파일만 열 수 있습니다")


def _self_check() -> None:
    parsed = parse_filename("내신 2022년 대구시 수성구 경북고 고1 공통 1학기 기말 수학상.hml")
    assert parsed["new_name"] == "2022년 대구 수성구 경북고 고1 1학기기말 수학상.hml"
    assert parsed["sido"] == "대구"
    placed = classify(parsed)
    assert placed["level"] == "고등" and placed["bucket"] == ""
    assert placed["target"].parent == HIGH_ROOT / "2022 1학기 기말"

    parsed = parse_filename("내신 2023년 대구 수성구 시지고 고2공통 1학기기말 수학1 (1).hml")
    assert parsed["new_name"] == "2023년 대구 수성구 시지고 고2 1학기기말 수학1.hml"
    assert classify(parsed)["bucket"] == "수성구"

    parsed = parse_filename("2024년 서울 강남구 휘문고 고1 1학기기말 수학상 (1).hml")
    assert classify(parsed)["bucket"] == "전국구"
    assert "(1)" not in parsed["new_name"]

    parsed = parse_filename("내신 2024년 대구시 수성구 경신중 중2공통 1학기1차 중등수학2상 A.hml")
    assert parsed["new_name"] == "2024년 대구 수성구 경신중 중2 1학기1차 중등수학2상 A.hml"
    assert parsed["placed_exam"] == "중간" and parsed["file_exam"] == "1차"
    mid_placed = classify(parsed)
    assert mid_placed["level"] == "중등" and mid_placed["bucket"] == ""
    assert mid_placed["target"].parent == MID_ROOT / "2024 1학기 중간"

    parsed = parse_filename("내신 2023년 대구시 수성구 고산중 중3공통 2학기기말 중등수학3하 (2).hml")
    assert classify(parsed)["bucket"] == "수성구"
    assert parsed["new_name"].endswith("중등수학3하.hml")

    parsed = parse_filename("내신 2024년 대구 수성구 덕원고 고2공통 2학기기말 미적분 서술형.hml")
    assert parsed["subject"] == "미적분"
    assert parsed["notes"] == ["(서술형)"]
    assert classify(parsed)["level"] == "고등"

    parsed = parse_filename("2025년 대구 수성구 경북고 고1 2학기중간 공통수학2 (서술형없음).hml")
    assert parsed["subject"] == "공통수학2"
    assert parsed["notes"] == ["(서술형 없음)"]

    try:
        classify(parse_filename("2024년 서울 강남구 휘문중 중2 1학기중간 중등수학2상.hml"))
        raise AssertionError("non-suseong middle should fail")
    except ValueError:
        pass

    high = Path(tempfile.mkdtemp())
    mid = Path(tempfile.mkdtemp())
    try:
        parsed = parse_filename("내신 2024년 대구시 수성구 경신고 고1공통 1학기중간 수학상 (1).hml")
        info = classify(parsed, high, mid)
        assert info["target"].name == "2024년 대구 수성구 경신고 고1 1학기중간 수학상.hml"
        first, status = place_new(info["target"], b"abc", high)
        assert status == "created" and first.exists()
        again, status = place_new(info["target"], b"abc", high)
        assert status == "same" and again == first
        other, status = place_new(info["target"], b"xyz", high)
        assert status == "variant" and other.name.endswith(" (다른 내용).hml")
    finally:
        shutil.rmtree(high, ignore_errors=True)
        shutil.rmtree(mid, ignore_errors=True)

    def row(year, school, grade, subject, group, sem="1", file_exam="중간", sido="대구", sigungu="수성구"):
        return {
            "year": str(year),
            "sem": sem,
            "file_exam": file_exam,
            "placed_exam": folder_exam_name(file_exam),
            "school": school,
            "grade": grade,
            "subject": subject,
            "group": group,
            "sido": sido,
            "sigungu": sigungu,
        }

    gap = infer_high(
        [
            row(2022, "경신고", "고1", "수학상", "주요 8교"),
            row(2023, "경신고", "고1", "수학상", "주요 8교", file_exam="1차"),
            row(2024, "경신고", "고1", "수학상", "주요 8교"),
        ]
    )
    assert not any(
        item["year"] == "2023" and item["exam"] == "중간" and item["subject"] == "수학상" for item in gap
    )

    only_ends = infer_high(
        [
            row(2022, "경신고", "고1", "확률과통계", "주요 8교"),
            row(2024, "경신고", "고1", "확률과통계", "주요 8교"),
        ]
    )
    assert any(item["year"] == "2023" and item["subject"] == "확률과통계" for item in only_ends)

    seniors = [row(2024, school, "고3", "미적분", "주요 8교") for school in HIGH_MAJOR if school != "정화여고"]
    seniors.append(row(2024, "정화여고", "고1", "수학상", "주요 8교"))
    assert not any(item["grade"] == "고3" for item in infer_high(seniors))

    mid_rows = [row(2024, "고산중", "중3", "중등수학3상", "수성구 기타", sem="2")]
    mid_missing = infer_middle(mid_rows)
    assert not any(item["grade"] == "중1" for item in mid_missing)
    assert not any(item["sem"] == "2" and item["grade"] == "중1" for item in infer_middle([row(2024, "경신중", "중2", "중등수학2상", "주요 학교")]))
    assert any(item["grade"] == "중1" and item["sem"] == "1" for item in infer_middle([row(2024, "경신중", "중2", "중등수학2상", "주요 학교")]))


if __name__ == "__main__":
    _self_check()
    print("self-check ok")
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == "scan":
        snap = snapshot(force=True)
        print(f"high {snap['high_count']} mid {snap['mid_count']} unread {snap['unread']}")
        print(f"missing {len(snap['visible'])} hidden {len(snap['hidden'])}")
        high_missing = sum(1 for row in snap["visible"] if row["level"] == "고등")
        mid_missing = sum(1 for row in snap["visible"] if row["level"] == "중등")
        print(f"missing high {high_missing} mid {mid_missing}")
        for record in snap["files"]:
            if not record["ok"]:
                print(f"UNREAD {record['archive']} {record['name']} {record['error']}")
