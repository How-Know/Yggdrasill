# -*- coding: utf-8 -*-
"""Read a mock-exam PDF and place it in the 모의고사 folder."""

from __future__ import annotations

import base64
import os
import re
import subprocess
import tempfile
from io import BytesIO
from pathlib import Path

import pymupdf

SUBJECT_ORDER = ("확통", "미적", "기하")
SUBJECT_LABEL = {
    "확률과통계": "확통",
    "확률과 통계": "확통",
    "미적분": "미적",
    "기하": "기하",
    "가형": "가형",
    "나형": "나형",
    "가": "가형",
    "나": "나형",
}
SECTION_RE = re.compile(
    r"\[\s*(?:선택\s*:\s*)?(확률과\s*통계|미적분|기하|가\s*형|나\s*형)\s*\]"
    r"|(?:선택\s*)?(확률과\s*통계|미적분|기하|가\s*형|나\s*형)\s*\[\s*:?\s*\]"
    r"|(?:^|\n)\s*(?:수학\s*)?(?:[‘'\"\(\（]\s*)?(확률과\s*통계|미적분|기하)(?:\s*[’'\"\)\）])?\s*(?:정답|해설)\b"
    r"|(?:^|\n)[^\S\n]*(?:수학[^\S\n]*)?[^가-힣A-Za-z0-9\n]{0,2}(가|나)[^가-힣A-Za-z0-9\n]{0,2}형[^가-힣A-Za-z0-9\n]{0,2}(?:정답|해설)\b"
)
SOLUTION_TYPE_RE = re.compile(r"수학\s*영역[^가-힣A-Za-z0-9\n]{0,3}(가|나)[^가-힣A-Za-z0-9\n]{0,3}형")
PROBLEM_RE = re.compile(
    r"수학\s*영역\s*(?:"
    r"[\(（\[]\s*(확률과\s*통계|미적분|기하|가\s*형|나\s*형)\s*[\)）\]]"
    r"|(확률과\s*통계|미적분|기하|가\s*형|나\s*형)\s*[\(（\[]\s*[\)）\]]"
    r"|(가\s*형|나\s*형)\b"
    r")"
)
HEADER_RE = re.compile(r"[\(（]\s*(확률과\s*통계|미적분|기하)\s*[\)）]")
EDU_RE = re.compile(r"(20\d{2})학년도(\d{1,2})월고([123])전국연합학력평가")
EDU_SOL_AFTER_RE = re.compile(r"(20\d{2})학년도(\d{1,2})월전국연합학력평가정답및(?:해설|풀이)고([123])")
EDU_SOL_BEFORE_RE = re.compile(r"고([123])정답및(?:해설|풀이)(20\d{2})학년도(\d{1,2})월전국연합학력평가")
EDU_SPLIT_RE = re.compile(r"학년도\s*월\s*고\s*전국연합학력평가\s*(?:문제지\s*)?(20\d{2})\s+(\d{1,2})\s+([123])\b")
MOCK_RE = re.compile(r"(20\d{2})학년도대학수학능력시험(\d{1,2})월모의평가")
MOCK_SPLIT_RE = re.compile(
    r"학년도\s*대학수학능력시험\s*(?:(\d{1,2})\s*월\s*모의평가\s*(20\d{2})|월\s*모의평가\s*(20\d{2})\s+(\d{1,2}))\b"
)
SAT_RE = re.compile(r"(20\d{2})학년도대학수학능력시험(?!대비)(?!\d월)")
SAT_SPLIT_RE = re.compile(r"학년도\s*대학수학능력시험\s*(20\d{2})\b(?!\s*(?:대비|\d{1,2}\s*월|모의평가))")
MATH_WORD_RE = re.compile(r"log|ln|sin|cos|tan|lim")
NOTICE_BOX_RE = re.compile(r"[｢「][^｣」]*선택\s*과목[^｣」]*[｣」]")


def _raw_pdf_pages(data: bytes, limit: int | None = None) -> list[str]:
    doc = None
    try:
        doc = pymupdf.open(stream=data, filetype="pdf")
        if doc.needs_pass and not doc.authenticate(""):
            raise ValueError("암호가 걸린 PDF는 읽지 못합니다")
        chosen = doc if limit is None else list(doc)[:limit]
        return [(page.get_text("text") or "") for page in chosen]
    except ValueError:
        raise
    except Exception as exc:
        raise ValueError("PDF를 열지 못했습니다") from exc
    finally:
        if doc is not None:
            doc.close()


def pdf_pages(data: bytes, limit: int | None = None) -> list[str]:
    pages = _raw_pdf_pages(data, limit=limit)
    if not any(page.strip() for page in pages):
        raise ValueError("PDF에서 글자를 읽지 못했습니다")
    return pages


_WIN_OCR_PS = r"""
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine,Windows.Foundation,ContentType=WindowsRuntime]
$null = [Windows.Globalization.Language,Windows.Foundation,ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder,Windows.Foundation,ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.RandomAccessStream,Windows.Foundation,ContentType=WindowsRuntime]
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, $type) { $m = $asTaskGeneric.MakeGenericMethod($type); $t = $m.Invoke($null, @($op)); return $t.GetAwaiter().GetResult() }
$lang = New-Object Windows.Globalization.Language('ko')
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
if ($null -eq $engine) { exit 2 }
Get-ChildItem -LiteralPath $env:EXAM_DESK_OCR_DIR -Filter '*.png' | Sort-Object Name | ForEach-Object {
  $fs = [System.IO.File]::OpenRead($_.FullName)
  $stream = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($fs)
  $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bmp = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $res = Await ($engine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
  $stream.Dispose(); $fs.Dispose()
  $clean = ($res.Text -replace '[\r\n\t]+', ' ')
  Write-Output ($_.BaseName + "`t" + $clean)
}
"""


def _ocr_top_banners(items: dict[int, bytes]) -> dict[int, str]:
    """글자 층이 없거나 상단 유형 표기가 곡선으로 그려진 문제지는 1쪽 상단만 로컬 Windows OCR로 읽는다."""
    if not items or os.name != "nt":
        return {}
    try:
        import pymupdf
    except Exception:
        return {}
    out: dict[int, str] = {}
    with tempfile.TemporaryDirectory(prefix="exam_desk_ocr_") as tmp:
        tmp_dir = Path(tmp)
        rendered = 0
        for idx, data in items.items():
            doc = None
            try:
                doc = pymupdf.open(stream=data, filetype="pdf")
                if (doc.needs_pass and not doc.authenticate("")) or len(doc) == 0:
                    continue
                page = doc[0]
                rect = page.rect
                if rect.width <= 0 or rect.height <= 0:
                    continue
                clip = pymupdf.Rect(0, 0, rect.width, rect.height * 0.25)
                pix = page.get_pixmap(clip=clip, dpi=200)
                pix.save(str(tmp_dir / f"b_{idx}.png"))
                rendered += 1
            except Exception:
                continue
            finally:
                if doc is not None:
                    doc.close()
        if rendered == 0:
            return {}
        encoded = base64.b64encode(_WIN_OCR_PS.encode("utf-16le")).decode("ascii")
        env = dict(os.environ)
        env["EXAM_DESK_OCR_DIR"] = str(tmp_dir)
        try:
            proc = subprocess.run(
                ["powershell", "-NoProfile", "-EncodedCommand", encoded],
                env=env,
                text=True,
                encoding="utf-8",
                capture_output=True,
                timeout=45,
                check=False,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except (OSError, subprocess.TimeoutExpired):
            return {}
        if proc.returncode != 0:
            return {}
        for line in (proc.stdout or "").splitlines():
            if "\t" not in line:
                continue
            tag, text = line.split("\t", 1)
            if tag.startswith("b_") and text.strip():
                try:
                    out[int(tag[2:])] = text.strip()
                except ValueError:
                    continue
    return out


def _needs_banner_ocr(raw_pages: list[str]) -> bool:
    if not any(page.strip() for page in raw_pages):
        return True
    text = "\n".join(raw_pages)
    try:
        kind = document_kind(text)
    except ValueError:
        return True
    if kind == "해설":
        return False
    try:
        info = exam_from_text(text)
    except ValueError:
        return True
    if info["grade"] == 3 and not (problem_subjects(text) or header_subjects(raw_pages[8:])):
        return True
    return False


def _merge_banner(raw_pages: list[str], banner: str) -> list[str]:
    if not banner:
        return raw_pages
    if not raw_pages:
        return [banner]
    first = f"{banner}\n{raw_pages[0]}" if raw_pages[0].strip() else banner
    return [first, *raw_pages[1:]]


def _compact(text: str) -> str:
    return re.sub(r"\s+", "", text)


def _canonical(raw: str) -> str:
    key = re.sub(r"[\s‘’'\"\(\)（）]+", "", raw)
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
    edu = EDU_RE.search(compact) or EDU_SOL_AFTER_RE.search(compact)
    if edu:
        return {
            "year": int(edu.group(1)),
            "month": int(edu.group(2)),
            "grade": int(edu.group(3)),
            "org": "교육청",
        }
    edu_before = EDU_SOL_BEFORE_RE.search(compact)
    if edu_before:
        return {
            "year": int(edu_before.group(2)),
            "month": int(edu_before.group(3)),
            "grade": int(edu_before.group(1)),
            "org": "교육청",
        }
    edu_split = EDU_SPLIT_RE.search(text)
    if edu_split:
        return {
            "year": int(edu_split.group(1)),
            "month": int(edu_split.group(2)),
            "grade": int(edu_split.group(3)),
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
    mock_split = MOCK_SPLIT_RE.search(text)
    if mock_split:
        if mock_split.group(1):
            month, acad_year = int(mock_split.group(1)), int(mock_split.group(2))
        else:
            acad_year, month = int(mock_split.group(3)), int(mock_split.group(4))
        return {"year": acad_year - 1, "month": month, "grade": 3, "org": "평가원"}
    sat = SAT_RE.search(compact)
    if sat:
        return {"year": int(sat.group(1)) - 1, "month": 11, "grade": 3, "org": "수능"}
    sat_split = SAT_SPLIT_RE.search(text)
    if sat_split:
        return {"year": int(sat_split.group(1)) - 1, "month": 11, "grade": 3, "org": "수능"}
    raise ValueError("시험 제목을 읽지 못했습니다")


def _exam_key(info: dict) -> tuple:
    return (info["year"], info["month"], info["grade"], info["org"])


def _is_formula(ch: str) -> bool:
    if ch.isspace() or ch in ".,?!;:()[]{}'\"“”‘’※•·ㆍ<>＜＞⋯…~～-–—_/\\":
        return False
    if "가" <= ch <= "힣" or "ㄱ" <= ch <= "ㅣ":
        return False
    if "\u2460" <= ch <= "\u24ff" or ch in "◦「」『』｢｣■□▲△▼▽◆◇○●◎★☆":
        return False
    if ch.isascii():
        return False
    if "\u0080" <= ch <= "\u036f" and ch not in "±×÷":
        return False
    if "\uf900" <= ch <= "\uffff":
        return False
    return True


def _question_body(text: str, number: int) -> str:
    match = re.search(rf"(?:^|\n)\s*0?{number}\s*[\.．]", text)
    if not match:
        return ""
    body = text[match.end() :]
    stop = re.search(r"[\u2460-\u24ff]|\[\d점\]|\n\s*0?\d+\s*[\.．]", body)
    if stop:
        body = body[: stop.start()]
    return body


def _formula_runs(text: str, min_len: int = 5) -> list[str]:
    found: list[str] = []
    buf: list[str] = []
    index = 0
    while index < len(text):
        ch = text[index]
        if ch.isspace():
            index += 1
            continue
        word = MATH_WORD_RE.match(text, index)
        if word:
            buf.append(word.group(0))
            index = word.end()
            continue
        if _is_formula(ch):
            buf.append(ch)
            index += 1
            continue
        if buf:
            run = "".join(buf)
            if len(run) >= min_len and any(not c.isascii() for c in run):
                found.append(run)
            buf = []
        index += 1
    if buf:
        run = "".join(buf)
        if len(run) >= min_len and any(not c.isascii() for c in run):
            found.append(run)
    return found


def question_marks(text: str) -> tuple[str, list[str]]:
    """1번 식과, 1번이 겹칠 때 가를 2·3번 식 조각."""
    first = _formula_runs(_question_body(text, 1), min_len=5)
    second = _formula_runs(_question_body(text, 2), min_len=5) or _formula_runs(
        _question_body(text, 3), min_len=5
    )
    return (first[0] if first else ""), second


def _problem_mark_entry(text: str, info: dict) -> tuple | None:
    first = _formula_runs(_question_body(text, 1), min_len=5)
    rest = [
        _formula_runs(_question_body(text, number), min_len=6 if number == 4 else 5)
        for number in (2, 3, 4)
    ]
    if not first and sum(1 for group in rest if group) < 2:
        return None
    return (first, rest, info)


def _normalize_mark_entry(q1, q2) -> tuple[list[str], list[list[str]]]:
    q1_runs = [q1] if isinstance(q1, str) else list(q1 or [])
    q1_runs = [r for r in q1_runs if r]
    if q2 and isinstance(q2[0], list):
        rest_groups = [[r for r in group if r] for group in q2]
    else:
        flat = [r for r in (q2 or []) if r]
        rest_groups = [flat] if flat else []
    return q1_runs, rest_groups


def _solution_early_text(text: str) -> str:
    first = re.search(r"(?:^|\n)\s*0?1\s*[\.．]", text)
    if not first:
        return text
    sixth = re.search(r"(?:^|\n)\s*0?6\s*[\.．]", text[first.end() :])
    if not sixth:
        return text
    return text[: first.end() + sixth.start()]


def exam_from_problem_one(text: str, problems: list[tuple]) -> dict:
    """제목이 없는 해설은 초반 문항(1~4번) 수식이 같은 문제지의 회차를 따른다."""
    if document_kind(text) != "해설":
        raise ValueError("시험 제목을 읽지 못했습니다")
    compact = _compact(_solution_early_text(text))
    by_key: dict[tuple, tuple[int, dict]] = {}
    for q1, q2, info in problems:
        q1_runs, rest_groups = _normalize_mark_entry(q1, q2)
        q1_hit = any(r in compact for r in q1_runs)
        rest_hits = sum(1 for group in rest_groups if any(r in compact for r in group))
        rest_long_hits = sum(
            1 for group in rest_groups if any(len(r) >= 6 and r in compact for r in group)
        )
        if not q1_hit and rest_long_hits < 2:
            continue
        score = (1 if q1_hit else 0) + rest_hits
        key = _exam_key(info)
        prev = by_key.get(key)
        if prev is None or score > prev[0]:
            by_key[key] = (score, info)
    if not by_key:
        raise ValueError("시험 제목을 읽지 못했습니다")
    candidates = list(by_key.values())
    if len(candidates) > 1:
        best_score = max(score for score, _ in candidates)
        if best_score < 2:
            raise ValueError("어느 시험인지 정하지 못했습니다")
        candidates = [(score, info) for score, info in candidates if score == best_score]
    if len(candidates) != 1:
        raise ValueError("어느 시험인지 정하지 못했습니다")
    info = candidates[0][1]
    return {
        "year": info["year"],
        "month": info["month"],
        "grade": info["grade"],
        "org": info["org"],
    }


_MARK_CACHE: dict[tuple, tuple] = {}
_ELECTIVE_CACHE: dict[tuple, tuple] = {}
_PAGE_CACHE: dict[tuple, list[str]] = {}


def problem_marks(root: Path) -> list[tuple]:
    """이미 있는 문제지의 1번·2번 식. 해설 파일은 기준이 아니다."""
    found = []
    if not root.is_dir():
        return found
    for path in root.rglob("*.pdf"):
        if not path.is_file() or path.name.startswith("~$") or "해설" in path.name:
            continue
        stat = path.stat()
        key = (str(path), stat.st_mtime_ns, stat.st_size)
        cached = _MARK_CACHE.get(key)
        if cached is None:
            try:
                text = "\n".join(pdf_pages(path.read_bytes(), limit=2))
                info = exam_from_text(text)
                entry = _problem_mark_entry(text, info)
                cached = entry if entry else ()
            except ValueError:
                cached = ()
            _MARK_CACHE[key] = cached
        if cached:
            found.append(cached)
    return found


def _elective_runs(pages: list[str]) -> list[str]:
    tail = "\n".join(pages[8:])
    runs: list[str] = []
    for number in range(23, 31):
        for run in _formula_runs(_question_body(tail, number), min_len=6):
            if run not in runs:
                runs.append(run)
    return runs


def elective_subjects_from_marks(
    pages: list[str], subject_runs: dict[str, list[str]]
) -> list[str]:
    """한글 글꼴이 깨진 해설지는 같은 시험 3과목 문제지의 23~30번 수식 등장 순서로 판별한다."""
    if not all(subject_runs.get(sub) for sub in SUBJECT_ORDER):
        return []
    tail = "\n".join(pages[1:]) if len(pages) > 1 else "\n".join(pages)
    start = re.search(r"(?:^|\s)0?23\s*[\.．]", tail)
    if start:
        tail = tail[start.start() :]
    compact = _compact(tail)
    hits: list[tuple[int, str]] = []
    for subject in SUBJECT_ORDER:
        positions = [compact.find(run) for run in subject_runs[subject] if run and compact.find(run) >= 0]
        if positions:
            hits.append((min(positions), subject))
    hits.sort()
    return [subject for _, subject in hits]


def elective_marks_for_exam(root: Path, info: dict) -> dict[str, list[str]]:
    target_key = _exam_key(info)
    found: dict[str, list[str]] = {}
    if not root.is_dir() or info["grade"] != 3:
        return found
    seen_paths: set[Path] = set()
    for folder in (root / folder_name(info), root):
        if not folder.is_dir():
            continue
        for path in sorted(folder.glob("*.pdf")):
            if path in seen_paths or not path.is_file() or path.name.startswith("~$") or "해설" in path.name:
                continue
            seen_paths.add(path)
            stat = path.stat()
            cache_key = (str(path), stat.st_mtime_ns, stat.st_size)
            cached = _ELECTIVE_CACHE.get(cache_key)
            if cached is None:
                try:
                    raw = path.read_bytes()
                    head_text = "\n".join(pdf_pages(raw, limit=2))
                    p_info = exam_from_text(head_text)
                    if p_info["grade"] == 3 and document_kind(head_text) == "문제":
                        full_pages = pdf_pages(raw)
                        full_text = "\n".join(full_pages)
                        subs = problem_subjects(full_text) or header_subjects(full_pages[8:])
                        cached = (_exam_key(p_info), subs[0], _elective_runs(full_pages)) if len(subs) == 1 else ()
                    else:
                        cached = ()
                except ValueError:
                    cached = ()
                _ELECTIVE_CACHE[cache_key] = cached
            if cached and cached[0] == target_key and cached[1] not in found:
                found[cached[1]] = cached[2]
    return found


def document_kind(text: str) -> str:
    compact = _compact(text)
    if (
        "출제의도" in compact
        or "정답및풀이" in compact
        or "정답및해설" in compact
        or "최근수정일" in compact
        or "최종수정일" in compact
        or SECTION_RE.search(text)
    ):
        return "해설"
    if "문제지" in compact:
        return "문제"
    raise ValueError("문제지인지 해설인지 읽지 못했습니다")


def solution_subjects(text: str) -> list[str]:
    found = [
        _canonical(next(group for group in match.groups() if group))
        for match in SECTION_RE.finditer(text)
    ]
    if not found:
        found = [_canonical(match.group(1)) for match in SOLUTION_TYPE_RE.finditer(text)]
    return _unique(found)


def problem_subjects(text: str) -> list[str]:
    return _unique(
        [
            _canonical(next(group for group in match.groups() if group))
            for match in PROBLEM_RE.finditer(text)
        ]
    )


def header_subjects(pages: list[str]) -> list[str]:
    found = []
    for page in pages:
        cleaned = NOTICE_BOX_RE.sub("", page)
        kept = "\n".join(
            line for line in cleaned.splitlines() if "선택과목" not in line and "이어서" not in line
        )
        found.extend(_canonical(match.group(1)) for match in HEADER_RE.finditer(kept))
    return _unique(found)


def classify_text(
    pages: list[str],
    problems: list[tuple] | None = None,
    electives: dict[tuple, dict[str, list[str]]] | None = None,
) -> dict:
    text = "\n".join(pages)
    try:
        info = exam_from_text(text)
    except ValueError:
        info = exam_from_problem_one(text, problems or [])
    if info["month"] < 1 or info["month"] > 12:
        raise ValueError("시험 월을 읽지 못했습니다")
    kind = document_kind(text)
    if info["grade"] < 3:
        subjects = [""]
    elif kind == "해설":
        subjects = solution_subjects(text)
        if not subjects and electives:
            subjects = elective_subjects_from_marks(pages, electives.get(_exam_key(info), {}))
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


def _cached_pages(path: Path) -> list[str]:
    stat = path.stat()
    key = (str(path), stat.st_mtime_ns, stat.st_size)
    cached = _PAGE_CACHE.get(key)
    if cached is None:
        try:
            cached = pdf_pages(path.read_bytes())
        except ValueError:
            cached = []
        _PAGE_CACHE[key] = cached
    return cached


def _place_mock_pdf(
    target: Path, data: bytes, root: Path, pages: list[str] | None
) -> tuple[Path, str]:
    from catalog import place_new, sha256_bytes, sha256_file

    digest = sha256_bytes(data)
    names = [target, target.with_name(f"{target.stem} (다른 내용){target.suffix}")]
    for index in range(3, 20):
        names.append(target.with_name(f"{target.stem} (다른 내용 {index}){target.suffix}"))
    for candidate in names:
        if not candidate.exists():
            break
        if sha256_file(candidate) == digest:
            return candidate, "same"
        if pages and _cached_pages(candidate) == pages:
            return candidate, "same"
    path, status = place_new(target, data, root)
    if pages and path.is_file():
        stat = path.stat()
        _PAGE_CACHE[(str(path), stat.st_mtime_ns, stat.st_size)] = pages
    return path, status


def place_classified(
    info: dict, data: bytes, root: Path, pages: list[str] | None = None
) -> dict:
    folder = folder_name(info)
    items = []
    for subject in info["subjects"]:
        name = file_name(info, subject)
        target = root / folder / name
        path, status = _place_mock_pdf(target, data, root, pages)
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


def _placed_pdf(
    filename: str,
    data: bytes,
    pages: list[str],
    root: Path,
    problems: list[tuple] | None,
    batch_electives: dict[tuple, dict[str, list[str]]] | None = None,
    compare_pages: list[str] | None = ...,
) -> dict:
    if compare_pages is ...:
        compare_pages = pages
    try:
        info = classify_text(pages, problems, batch_electives)
    except ValueError as exc:
        if "해설에서 선택 과목을" not in str(exc):
            raise
        text = "\n".join(pages)
        try:
            base = exam_from_text(text)
        except ValueError:
            base = exam_from_problem_one(text, problems or [])
        key = _exam_key(base)
        merged = dict(elective_marks_for_exam(root, base))
        if batch_electives and key in batch_electives:
            merged.update(batch_electives[key])
        info = classify_text(pages, problems, {key: merged})
    placed = place_classified(info, data, root, pages=compare_pages)
    placed["from"] = Path(filename).name
    for item in placed["items"]:
        item["from"] = placed["from"]
    return placed


def import_pdf(filename: str, data: bytes, root: Path) -> dict:
    if Path(filename).suffix.lower() != ".pdf":
        raise ValueError("pdf 파일만 넣을 수 있습니다")
    if not data:
        raise ValueError("빈 파일은 넣지 않습니다")
    if not root.is_dir():
        raise ValueError("모의고사 폴더를 찾지 못했습니다")
    raw_pages = _raw_pdf_pages(data)
    has_text = any(page.strip() for page in raw_pages)
    pages = raw_pages
    if _needs_banner_ocr(raw_pages):
        banners = _ocr_top_banners({0: data})
        pages = _merge_banner(raw_pages, banners.get(0, ""))
    if not any(page.strip() for page in pages):
        raise ValueError("PDF에서 글자를 읽지 못했습니다")
    problems = None
    try:
        exam_from_text("\n".join(pages))
    except ValueError:
        problems = problem_marks(root)
    return _placed_pdf(
        filename,
        data,
        pages,
        root,
        problems,
        compare_pages=raw_pages if has_text else None,
    )


def import_many(files: list[tuple[str, bytes]], root: Path) -> list[dict]:
    """한 번에 넣은 PDF를 같이 본다. 해설의 1번·선택과목을 같은 묶음의 문제지와도 비교한다."""
    if not root.is_dir():
        raise ValueError("모의고사 폴더를 찾지 못했습니다")
    prepared = []
    ocr_targets: dict[int, bytes] = {}
    for index, (filename, data) in enumerate(files):
        name = Path(filename).name
        if Path(filename).suffix.lower() != ".pdf":
            prepared.append({"name": name, "error": "pdf 파일만 넣을 수 있습니다"})
            continue
        if not data:
            prepared.append({"name": name, "error": "빈 파일은 넣지 않습니다"})
            continue
        try:
            raw_pages = _raw_pdf_pages(data)
        except ValueError as exc:
            prepared.append({"name": name, "error": str(exc)})
            continue
        has_text = any(page.strip() for page in raw_pages)
        if _needs_banner_ocr(raw_pages):
            ocr_targets[index] = data
        prepared.append(
            {
                "index": index,
                "name": name,
                "filename": filename,
                "data": data,
                "raw_pages": raw_pages,
                "has_text": has_text,
            }
        )
    banners = _ocr_top_banners(ocr_targets) if ocr_targets else {}
    batch_marks = []
    batch_electives: dict[tuple, dict[str, list[str]]] = {}
    for item in prepared:
        if "error" in item:
            continue
        pages = _merge_banner(item["raw_pages"], banners.get(item["index"], ""))
        if not any(page.strip() for page in pages):
            item["error"] = "PDF에서 글자를 읽지 못했습니다"
            continue
        item["pages"] = pages
        text = "\n".join(pages)
        try:
            info = exam_from_text(text)
        except ValueError:
            continue
        try:
            kind = document_kind(text)
        except ValueError:
            continue
        if kind == "문제":
            entry = _problem_mark_entry(text, info)
            if entry:
                batch_marks.append(entry)
            if info["grade"] == 3:
                subs = problem_subjects(text) or header_subjects(pages[8:])
                if len(subs) == 1 and subs[0] in SUBJECT_ORDER:
                    runs = _elective_runs(pages)
                    if runs:
                        batch_electives.setdefault(_exam_key(info), {})[subs[0]] = runs
    archive_marks: list[tuple] | None = None
    results = []
    for item in prepared:
        if "error" in item:
            results.append({"status": "error", "from": item["name"], "error": item["error"]})
            continue
        compare_pages = item["raw_pages"] if item["has_text"] else None
        marks = batch_marks if archive_marks is None else archive_marks + batch_marks
        try:
            results.append(
                _placed_pdf(
                    item["filename"],
                    item["data"],
                    item["pages"],
                    root,
                    marks,
                    batch_electives,
                    compare_pages=compare_pages,
                )
            )
        except ValueError as exc:
            if archive_marks is None and (
                "시험 제목을" in str(exc) or "어느 시험인지" in str(exc)
            ):
                archive_marks = problem_marks(root)
                try:
                    results.append(
                        _placed_pdf(
                            item["filename"],
                            item["data"],
                            item["pages"],
                            root,
                            archive_marks + batch_marks,
                            batch_electives,
                            compare_pages=compare_pages,
                        )
                    )
                    continue
                except ValueError as retry_exc:
                    exc = retry_exc
            results.append({"status": "error", "from": item["name"], "error": str(exc)})
    return results


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

    may_sol = classify_text(
        [
            "출제의도 지수법칙 계산하기1. [ ]\n학년도 월 고 전국연합학력평가2026 5 3 ",
            "미적분[ ]\n출제의도 확률의 덧셈정리 이해하기24. [ ]",
        ]
    )
    assert may_sol["year"] == 2026 and may_sol["month"] == 5 and may_sol["org"] == "교육청"
    assert may_sol["kind"] == "해설" and may_sol["subjects"] == ["미적"]
    assert file_name(may_sol, "미적") == "2026 고3 5월 교육청 (미적) - 해설.pdf"

    july_sol = classify_text(
        [
            "2026학년도 7월\n전국연합학력평가 정답 및 해설 고3\n1. [출제의도] 지수 계산하기",
            "기하 정답\n23 ③ 24 ④\n기하 해설\n23. [출제의도] 벡터 계산하기",
        ]
    )
    assert july_sol["year"] == 2026 and july_sol["month"] == 7 and july_sol["org"] == "교육청"
    assert july_sol["kind"] == "해설" and july_sol["subjects"] == ["기하"]
    assert file_name(july_sol, "기하") == "2026 고3 7월 교육청 (기하) - 해설.pdf"

    wrapped_pages = ["2022학년도 대학수학능력시험 6월 모의평가 문제지"] + [""] * 7
    wrapped_pages.append("(확률과\n통계) 3\n◦이어서, ｢선택과목\n(미적분)｣ 문제가 제시되오니")
    wrapped_prob = classify_text(wrapped_pages)
    assert wrapped_prob["year"] == 2021 and wrapped_prob["month"] == 6 and wrapped_prob["org"] == "평가원"
    assert wrapped_prob["subjects"] == ["확통"]

    q1_mar, _ = question_marks("1. log\ue03b\ue034\ue039의 값은? [2점]")
    q1_oct, _ = question_marks("1. log\ue036\ue0fc\ue047\ue036일 때, \ue0fc의 값은? [2점]")
    assert q1_mar == "log\ue03b\ue034\ue039"
    assert q1_oct == "log\ue036\ue0fc\ue047\ue036"
    mar21_sol = classify_text(
        ["1. [출제의도] 로그 계산\nlog\ue03b\ue034\ue039\ue047\ue034\n[확률과 통계]\n[미적분]\n[기하]"],
        [(q1_mar, [], {"year": 2021, "month": 3, "grade": 3, "org": "교육청"})],
    )
    assert mar21_sol["year"] == 2021 and mar21_sol["month"] == 3 and mar21_sol["subjects"] == ["확통", "미적", "기하"]

    csat21_key = (2021, 11, 3, "수능")
    csat21_elec = {
        csat21_key: {
            "확통": ["\ue044\ue0fc\ue048\ue035\ue045\ue03a"],
            "미적": ["lim\ue0f2→∞\ue06d\ue0f2\ue034"],
            "기하": ["\ue044\ue035\ue052\ue034\ue052\ue036\ue045"],
        }
    }
    csat21_sol = classify_text(
        [
            "학년도 대학수학능력시험 2022 \n수학영역 정답 및 풀이\n최근 수정일 * : 22.03.07",
            "12\n[ : ]\n23. \ue044\ue0fc \ue048 \ue035\ue045\ue03a\n17\n[ : ]\n23. lim \n\ue0f2→∞ \ue06d\ue0f2\ue034\n25\n23. A\ue044\ue035\ue052 \ue034\ue052 \ue036\ue045",
        ],
        electives=csat21_elec,
    )
    assert csat21_sol["year"] == 2021 and csat21_sol["month"] == 11 and csat21_sol["org"] == "수능"
    assert csat21_sol["kind"] == "해설" and csat21_sol["subjects"] == ["확통", "미적", "기하"]

    csat21_single = classify_text(
        [
            "학년도 대학수학능력시험 2022 \n수학영역 정답 및 풀이",
            "1. \ue044\ue035\ue052\ue034\ue052\ue036\ue045\n23. lim \n\ue0f2→∞ \ue06d\ue0f2\ue034",
        ],
        electives=csat21_elec,
    )
    assert csat21_single["subjects"] == ["미적"]

    ga_prob = classify_text(["2020학년도 3월 고3 전국연합학력평가 문제지\n수학 영역(가형)"])
    assert ga_prob == {
        "year": 2020,
        "month": 3,
        "grade": 3,
        "org": "교육청",
        "kind": "문제",
        "subjects": ["가형"],
    }
    assert file_name(ga_prob, "가형") == "2020 고3 3월 교육청 (가형).pdf"

    na_spaced = classify_text(["2021학년도 대학수학능력시험 문제지\n수학 영역 (나 형)"])
    assert na_spaced["year"] == 2020 and na_spaced["month"] == 11 and na_spaced["org"] == "수능"
    assert na_spaced["kind"] == "문제" and na_spaced["subjects"] == ["나형"]
    assert file_name(na_spaced, "나형") == "2020 고3 11월 수능 (나형).pdf"

    split_paren_prob = classify_text(
        ["학년도 월 고\n전국연합학력평가 문제지\n2016\n4\n3 \n수학 영역가형\n(\n)"]
    )
    assert split_paren_prob["year"] == 2016 and split_paren_prob["month"] == 4
    assert split_paren_prob["kind"] == "문제" and split_paren_prob["subjects"] == ["가형"]

    ga_kice_sol = classify_text(
        ["학년도 대학수학능력시험 2021\n수학영역 가형 정답 및 풀이\n최종 수정일 * : 22.02.28"]
    )
    assert ga_kice_sol["year"] == 2020 and ga_kice_sol["month"] == 11 and ga_kice_sol["org"] == "수능"
    assert ga_kice_sol["kind"] == "해설" and ga_kice_sol["subjects"] == ["가형"]
    assert file_name(ga_kice_sol, "가형") == "2020 고3 11월 수능 (가형) - 해설.pdf"

    oct20_q1 = "log\ue035\ue05c\ue06d\ue03b"
    na_oct_sol = classify_text(
        [f"수학 ‘나’형 정답\n1. [출제의도] 로그 계산\n{oct20_q1}"],
        [(oct20_q1, [], {"year": 2020, "month": 10, "grade": 3, "org": "교육청"})],
    )
    assert na_oct_sol["year"] == 2020 and na_oct_sol["month"] == 10 and na_oct_sol["subjects"] == ["나형"]
    assert file_name(na_oct_sol, "나형") == "2020 고3 10월 교육청 (나형) - 해설.pdf"

    paren_sol = classify_text(
        [
            "• 수학 영역 •\n수학(나형) 정답\n2. [출제의도] 지수\n\ue044\ue036\ue037\ue045\ue06d\ue035\ue034\n"
            "4. [출제의도] 합의 성질\n\ue067\ue0f2\ue047\ue034\ue034\ue03d\ue044\ue0e5\ue0f2\ue046\ue034\ue045"
        ],
        [
            (
                [],
                [["\ue044\ue036\ue037\ue045\ue06d\ue035\ue034"], [], ["\ue067\ue0f2\ue047\ue034\ue034\ue03d\ue044\ue0e5\ue0f2\ue046\ue034\ue045"]],
                {"year": 2018, "month": 4, "grade": 3, "org": "교육청"},
            )
        ],
    )
    assert paren_sol["year"] == 2018 and paren_sol["month"] == 4 and paren_sol["subjects"] == ["나형"]

    garbled_quote_sol = classify_text(
        ["2019학년도 대학수학능력시험 대비\n2018학년도 10월 고3 전국연합학력평가 정답 및 해설\n悱 수학 영역 悱\n수학拁가拂형 정답\n1. [출제의도] 벡터"]
    )
    assert garbled_quote_sol["year"] == 2018 and garbled_quote_sol["month"] == 10
    assert garbled_quote_sol["kind"] == "해설" and garbled_quote_sol["subjects"] == ["가형"]

    vec_shared = "\ue035\ue06d\ue06e\ue0e5\ue046\ue06d\ue06e\ue0e6"
    oct19_q2 = "lim\ue0fc→\ue03d\ue06d\ue035\ue0fcln\ue044\ue034\ue048\ue03b\ue0fc\ue045"
    jul18_q3_tail = "\ue0e5\ue048\ue0e6\ue048\ue0e7"
    oct19_sol = classify_text(
        [
            f"수학(가형) 정답\n1. [출제의도] 벡터\n{vec_shared}\n"
            f"2. [출제의도] 극한\n{oct19_q2}\n"
            f"6. [출제의도] 수열\n7. [출제의도] 합\n{jul18_q3_tail}"
        ],
        [
            ([vec_shared], [[oct19_q2]], {"year": 2019, "month": 10, "grade": 3, "org": "교육청"}),
            ([vec_shared], [[], [jul18_q3_tail]], {"year": 2018, "month": 7, "grade": 3, "org": "교육청"}),
        ],
    )
    assert oct19_sol["year"] == 2019 and oct19_sol["month"] == 10 and oct19_sol["subjects"] == ["가형"]

    owner_doc = pymupdf.open()
    owner_page = owner_doc.new_page()
    owner_page.insert_text((72, 72), "owner-only")
    owner_bytes = owner_doc.tobytes(
        encryption=pymupdf.PDF_ENCRYPT_AES_128,
        owner_pw="owner-secret",
        user_pw="",
    )
    owner_doc.close()
    assert "owner-only" in _raw_pdf_pages(owner_bytes)[0]

    locked_doc = pymupdf.open()
    locked_doc.new_page()
    locked_bytes = locked_doc.tobytes(
        encryption=pymupdf.PDF_ENCRYPT_AES_128,
        owner_pw="owner-secret",
        user_pw="user-secret",
    )
    locked_doc.close()
    try:
        _raw_pdf_pages(locked_bytes)
        raise AssertionError("expected locked PDF to fail")
    except ValueError as err:
        assert "암호" in str(err)

    try:
        classify_text(
            ["학년도 대학수학능력시험 2022 \n수학영역 정답 및 풀이", "23. lim\ue0f2→∞\ue06d\ue0f2\ue034"],
            electives={csat21_key: {"확통": ["\ue044\ue0fc\ue048\ue035\ue045\ue03a"], "미적": ["lim\ue0f2→∞\ue06d\ue0f2\ue034"]}},
        )
        raise AssertionError("incomplete elective problem set should fail closed")
    except ValueError:
        pass

    try:
        classify_text(["[출제의도] 계산한다"])
        raise AssertionError("titleless solution should fail")
    except ValueError:
        pass

    shared = "\ue05c\ue036\ue06d\ue037\u00d7\ue035\ue06d\ue036\ue034"
    march_two = "\ue0ea\ue044\ue034\ue048\ue0ec\ue045\ue046\ue0ea\ue044\ue036\ue045"
    june_two = "\ue036\ue035\ue037\ue048\ue036\ue06d\ue03b\ue036"
    march_info = {"year": 2025, "month": 3, "grade": 3, "org": "교육청"}
    june_info = {"year": 2024, "month": 6, "grade": 2, "org": "교육청"}
    paired = classify_text(
        [f"1. [출제의도] 계산한다.\n{shared}\n2. [출제의도] 미분한다.\n{march_two}\n[확률과통계]\n[미적분]\n[기하]"],
        [(shared, [march_two], march_info), (shared, [june_two], june_info)],
    )
    assert paired["year"] == 2025 and paired["month"] == 3 and paired["org"] == "교육청"
    assert paired["kind"] == "해설" and paired["subjects"] == ["확통", "미적", "기하"]
    grade1_info = {"year": 2024, "month": 3, "grade": 1, "org": "교육청"}
    grade1_mark = "\ue15c\ue15d\ue035\ue030\ue048\ue15c\ue15d\ue038"
    grade1_sol = classify_text(
        [f"[출제의도] 계산한다.\n1. {grade1_mark}"],
        [(grade1_mark, [], grade1_info)],
    )
    assert grade1_sol["grade"] == 1 and grade1_sol["subjects"] == [""]
    try:
        classify_text(
            [f"[출제의도] 계산한다.\n{shared}\n{march_two}\n{june_two}"],
            [(shared, [march_two], march_info), (shared, [june_two], june_info)],
        )
        raise AssertionError("two exams with the same first question should fail")
    except ValueError as exc:
        assert "어느 시험인지" in str(exc)

    import shutil
    import tempfile

    from catalog import MOCK_ROOT

    root = Path(tempfile.mkdtemp())
    try:
        placed = place_classified(edu, b"same-solutions", root, pages=["page-1", "page-2"])
        assert [item["status"] for item in placed["items"]] == ["created", "created", "created"]
        assert len(list((root / "2024").glob("*.pdf"))) == 3
        again = place_classified(edu, b"same-solutions", root, pages=["page-1", "page-2"])
        assert [item["status"] for item in again["items"]] == ["same", "same", "same"]
        repacked = place_classified(edu, b"repacked-pdf-bytes", root, pages=["page-1", "page-2"])
        assert [item["status"] for item in repacked["items"]] == ["same", "same", "same"]
        changed = place_classified(edu, b"changed-pdf-bytes", root, pages=["page-1", "page-2-edited"])
        assert [item["status"] for item in changed["items"]] == ["variant", "variant", "variant"]
        assert len(list((root / "2024").glob("*.pdf"))) == 6
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
    march_file = MOCK_ROOT / "2025" / "2025 고3 3월 교육청 (미적)_해설.pdf"
    if march_file.is_file():
        march_live = classify_text(pdf_pages(march_file.read_bytes()), problem_marks(MOCK_ROOT))
        assert march_live["year"] == 2025 and march_live["month"] == 3 and march_live["org"] == "교육청"
        assert march_live["grade"] == 3 and march_live["kind"] == "해설"
        assert march_live["subjects"] == ["확통", "미적", "기하"]
    grade1_file = MOCK_ROOT / "1학년" / "2024 고1 3월 교육청 - 해설.pdf"
    if grade1_file.is_file():
        grade1_live = classify_text(pdf_pages(grade1_file.read_bytes()), problem_marks(MOCK_ROOT))
        assert grade1_live["year"] == 2024 and grade1_live["month"] == 3 and grade1_live["grade"] == 1
        assert grade1_live["subjects"] == [""]
