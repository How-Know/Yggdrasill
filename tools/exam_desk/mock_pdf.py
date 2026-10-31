# -*- coding: utf-8 -*-
"""Read a mock-exam PDF and place it in the 모의고사 folder."""

from __future__ import annotations

import re
from io import BytesIO
from pathlib import Path

from pypdf import PdfReader

SUBJECT_ORDER = ("확통", "미적", "기하")
SUBJECT_LABEL = {
    "확률과통계": "확통",
    "확률과 통계": "확통",
    "미적분": "미적",
    "기하": "기하",
}
SECTION_RE = re.compile(r"\[\s*(?:선택\s*:\s*)?(확률과\s*통계|미적분|기하)\s*\]")
PROBLEM_RE = re.compile(r"수학\s*영역\s*[\(（]\s*(확률과\s*통계|미적분|기하)\s*[\)）]")
HEADER_RE = re.compile(r"[\(（]\s*(확률과\s*통계|미적분|기하)\s*[\)）]")
EDU_RE = re.compile(r"(20\d{2})학년도(\d{1,2})월고([123])전국연합학력평가")
MOCK_RE = re.compile(r"(20\d{2})학년도대학수학능력시험(\d{1,2})월모의평가")
SAT_RE = re.compile(r"(20\d{2})학년도대학수학능력시험(?!대비)(?!\d월)")


def pdf_pages(data: bytes) -> list[str]:
    try:
        reader = PdfReader(BytesIO(data))
        if reader.is_encrypted:
            raise ValueError("암호가 걸린 PDF는 읽지 못합니다")
        pages = [(page.extract_text() or "") for page in reader.pages]
    except ValueError:
        raise
    except Exception as exc:
        raise ValueError("PDF를 열지 못했습니다") from exc
    if not any(page.strip() for page in pages):
        raise ValueError("PDF에서 글자를 읽지 못했습니다")
    return pages


def _compact(text: str) -> str:
    return re.sub(r"\s+", "", text)


def _canonical(raw: str) -> str:
    key = re.sub(r"\s+", "", raw)
    if key not in SUBJECT_LABEL:
        raise ValueError("선택 과목을 읽지 못했습니다")
    return SUBJECT_LABEL[key]


def _unique(names: list[str]) -> list[str]:
    found = []
    for name in names:
        if name not in found:
            found.append(name)
    return found


def exam_from_text(text: str) -> dict:
    compact = _compact(text)
    edu = EDU_RE.search(compact)
    if edu:
        return {
            "year": int(edu.group(1)),
            "month": int(edu.group(2)),
            "grade": int(edu.group(3)),
            "org": "교육청",
        }
    mock = MOCK_RE.search(compact)
    if mock:
        return {
            "year": int(mock.group(1)) - 1,
            "month": int(mock.group(2)),
            "grade": 3,
            "org": "평가원",
        }
    sat = SAT_RE.search(compact)
    if sat:
        return {"year": int(sat.group(1)) - 1, "month": 11, "grade": 3, "org": "수능"}
    raise ValueError("시험 제목을 읽지 못했습니다")


def document_kind(text: str) -> str:
    compact = _compact(text)
    if "출제의도" in compact or "정답및풀이" in compact or "정답및해설" in compact or SECTION_RE.search(text):
        return "해설"
    if "문제지" in compact:
        return "문제"
    raise ValueError("문제지인지 해설인지 읽지 못했습니다")


def solution_subjects(text: str) -> list[str]:
    return _unique([_canonical(match.group(1)) for match in SECTION_RE.finditer(text)])


def problem_subjects(text: str) -> list[str]:
    return _unique([_canonical(match.group(1)) for match in PROBLEM_RE.finditer(text)])


def header_subjects(pages: list[str]) -> list[str]:
    found = []
    for page in pages:
        for line in page.splitlines():
            if "선택과목" in line or "이어서" in line:
                continue
            found.extend(_canonical(match.group(1)) for match in HEADER_RE.finditer(line))
    return _unique(found)


def classify_text(pages: list[str]) -> dict:
    text = "\n".join(pages)
    info = exam_from_text(text)
    if info["month"] < 1 or info["month"] > 12:
        raise ValueError("시험 월을 읽지 못했습니다")
    kind = document_kind(text)
    if info["grade"] < 3:
        subjects = [""]
    elif kind == "해설":
        subjects = solution_subjects(text)
        if not subjects:
            raise ValueError("해설에서 선택 과목을 읽지 못했습니다")
    else:
        subjects = problem_subjects(text) or header_subjects(pages[8:])
        if not subjects:
            raise ValueError("문제지에서 선택 과목을 읽지 못했습니다")
    info["kind"] = kind
    info["subjects"] = subjects
    return info


def file_name(info: dict, subject: str) -> str:
    base = f"{info['year']} 고{info['grade']} {info['month']}월 {info['org']}"
    if subject:
        base += f" ({subject})"
    if info["kind"] == "해설":
        base += " - 해설"
    return base + ".pdf"


def folder_name(info: dict) -> str:
    if info["grade"] == 1:
        return "1학년"
    if info["grade"] == 2:
        return "2학년"
    return str(info["year"])


def place_classified(info: dict, data: bytes, root: Path) -> dict:
    from catalog import place_new

    folder = folder_name(info)
    items = []
    for subject in info["subjects"]:
        name = file_name(info, subject)
        target = root / folder / name
        path, status = place_new(target, data, root)
        items.append(
            {
                "status": status,
                "name": path.name,
                "where": f"모의고사 / {folder}",
                "path": str(path),
                "level": "모의",
            }
        )
    if any(item["status"] == "created" for item in items):
        status = "created"
    elif any(item["status"] == "variant" for item in items):
        status = "variant"
    else:
        status = "same"
    first = items[0]
    return {
        "status": status,
        "name": first["name"],
        "where": first["where"],
        "path": first["path"],
        "level": "모의",
        "items": items,
    }


def import_pdf(filename: str, data: bytes, root: Path) -> dict:
    if Path(filename).suffix.lower() != ".pdf":
        raise ValueError("pdf 파일만 넣을 수 있습니다")
    if not data:
        raise ValueError("빈 파일은 넣지 않습니다")
    if not root.is_dir():
        raise ValueError("모의고사 폴더를 찾지 못했습니다")
    info = classify_text(pdf_pages(data))
    placed = place_classified(info, data, root)
    placed["from"] = Path(filename).name
    for item in placed["items"]:
        item["from"] = placed["from"]
    return placed


def self_check() -> None:
    edu = classify_text(
        [
            "2025학년도 대학수학능력시험 대비\n"
            "2024학년도 10월 고3 전국연합학력평가 정답 및 해설\n"
            "[확률과통계]\n[미적분]\n[기하]\n[출제의도] 지수"
        ]
    )
    assert edu["year"] == 2024 and edu["month"] == 10 and edu["org"] == "교육청"
    assert edu["kind"] == "해설" and edu["subjects"] == ["확통", "미적", "기하"]
    assert folder_name(edu) == "2024"
    assert [file_name(edu, subject) for subject in edu["subjects"]] == [
        "2024 고3 10월 교육청 (확통) - 해설.pdf",
        "2024 고3 10월 교육청 (미적) - 해설.pdf",
        "2024 고3 10월 교육청 (기하) - 해설.pdf",
    ]

    sat = classify_text(["2023학년도 대학수학능력시험 문제지\n수학영역(미적분)"])
    assert sat == {
        "year": 2022,
        "month": 11,
        "grade": 3,
        "org": "수능",
        "kind": "문제",
        "subjects": ["미적"],
    }
    assert file_name(sat, "미적") == "2022 고3 11월 수능 (미적).pdf"

    june = classify_text(
        ["2026학년도 대학수학능력시험 6월 모의평가\n정답 및 풀이\n[선택: 확률과 통계]\n[선택: 미적분]\n[선택: 기하]"]
    )
    assert june["year"] == 2025 and june["month"] == 6 and june["org"] == "평가원"
    assert june["subjects"] == list(SUBJECT_ORDER)

    july = classify_text(["2025학년도 7월 고3 전국연합학력평가 문제지\n수학영역(기하)"])
    assert july["year"] == 2025 and july["month"] == 7 and july["org"] == "교육청"
    assert july["subjects"] == ["기하"]

    pages = [""] * 8
    pages.append(
        "2026학년도 대학수학능력시험 9월 모의평가 문제지\n"
        "◦이어서, ｢선택과목(확률과 통계)｣ 문제가 제시되오니\n"
        "(미적분)제2교시\n"
    )
    pages.append("◦이어서, ｢선택과목(기하)｣ 문제가 제시되오니")
    mock_calc = classify_text(pages)
    assert mock_calc["year"] == 2025 and mock_calc["month"] == 9 and mock_calc["org"] == "평가원"
    assert mock_calc["subjects"] == ["미적"]
    assert file_name(mock_calc, "미적") == "2025 고3 9월 평가원 (미적).pdf"

    sat_pages = [""] * 8
    sat_pages.append("2026학년도 대학수학능력시험 문제지\n(기하)제2교시\n◦이어서, ｢선택과목(확률과 통계)｣")
    sat_geo = classify_text(sat_pages)
    assert sat_geo["year"] == 2025 and sat_geo["month"] == 11 and sat_geo["org"] == "수능"
    assert sat_geo["subjects"] == ["기하"]

    grade1 = classify_text(["2024학년도 3월 고1 전국연합학력평가 문제지"])
    assert grade1["grade"] == 1 and grade1["subjects"] == [""]
    assert folder_name(grade1) == "1학년"
    assert file_name(grade1, "") == "2024 고1 3월 교육청.pdf"

    try:
        classify_text(["[출제의도] 계산한다"])
        raise AssertionError("titleless solution should fail")
    except ValueError:
        pass

    import shutil
    import tempfile

    from catalog import MOCK_ROOT

    root = Path(tempfile.mkdtemp())
    try:
        placed = place_classified(edu, b"same-solutions", root)
        assert [item["status"] for item in placed["items"]] == ["created", "created", "created"]
        assert len(list((root / "2024").glob("*.pdf"))) == 3
        again = place_classified(edu, b"same-solutions", root)
        assert [item["status"] for item in again["items"]] == ["same", "same", "same"]
    finally:
        shutil.rmtree(root, ignore_errors=True)

    july_file = MOCK_ROOT / "2025 고3 7월 평가원 (기하).pdf"
    if july_file.is_file():
        july_live = classify_text(pdf_pages(july_file.read_bytes()))
        assert july_live["org"] == "교육청" and july_live["year"] == 2025 and july_live["subjects"] == ["기하"]
    june_file = MOCK_ROOT / "2024" / "2024 고3 6월 평가원 (기하) - 해설.pdf"
    if june_file.is_file():
        june_live = classify_text(pdf_pages(june_file.read_bytes()))
        assert june_live["year"] == 2024 and june_live["org"] == "평가원"
        assert june_live["kind"] == "해설" and june_live["subjects"] == ["확통", "미적", "기하"]
    october_file = MOCK_ROOT / "2024" / "2024 고3 10월 교육청 (미적) - 해설.pdf"
    if october_file.is_file():
        october_live = classify_text(pdf_pages(october_file.read_bytes()))
        assert october_live["year"] == 2024 and october_live["org"] == "교육청"
        assert october_live["subjects"] == ["확통", "미적", "기하"]
