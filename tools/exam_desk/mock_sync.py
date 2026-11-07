# -*- coding: utf-8 -*-
"""모의고사 폴더에 넣은 PDF 를 학습앱 카드로 올린다. 추출은 시작하지 않는다."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

LATER = "카드 반영은 잠시 뒤 자동으로 됩니다"
DONE = "카드에 올렸습니다"


def _gateway_dir() -> Path | None:
    env = os.environ.get("EXAM_DESK_GATEWAY", "").strip()
    candidates = []
    if env:
        candidates.append(Path(env))
    if not getattr(sys, "frozen", False):
        candidates.append(Path(__file__).resolve().parents[2] / "gateway")
    candidates.append(Path.home() / "Yggdrasill" / "gateway")
    for candidate in candidates:
        script = candidate / "scripts" / "mock_exam_enqueue.mjs"
        if script.is_file():
            return candidate
    return None


def sync_placed(paths: list[str]) -> str:
    files = [path for path in paths if path]
    if not files:
        return LATER
    gateway = _gateway_dir()
    node = shutil.which("node")
    if gateway is None or not node:
        return LATER
    script = gateway / "scripts" / "mock_exam_enqueue.mjs"
    try:
        proc = subprocess.run(
            [node, str(script), "--register", "--academy", "auto", *files],
            cwd=str(gateway),
            capture_output=True,
            timeout=180,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return LATER
    return DONE if proc.returncode == 0 else LATER
