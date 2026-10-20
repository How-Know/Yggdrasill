# -*- coding: utf-8 -*-
"""Local desk for the two exam folders.

Run: py -3 tools/exam_desk/server.py
"""

from __future__ import annotations

import base64
import json
import os
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import catalog


def bundle_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS"))
    return Path(__file__).resolve().parent


BUNDLE = bundle_dir()
STATIC = BUNDLE / "static"
REPO = Path(__file__).resolve().parents[2]
SMALL = REPO / "apps" / "yggdrasill" / "assets" / "fonts" / "kakao" / "카카오작은글씨" / "TTF"
BIG = REPO / "apps" / "yggdrasill" / "assets" / "fonts" / "kakao" / "카카오큰글씨" / "TTF"
FONT_NAMES = (
    "KakaoSmallSans-Light.ttf",
    "KakaoSmallSans-Regular.ttf",
    "KakaoSmallSans-Bold.ttf",
    "KakaoBigSans-Regular.ttf",
    "KakaoBigSans-Bold.ttf",
    "KakaoBigSans-ExtraBold.ttf",
)


def _font_path(name: str) -> Path | None:
    bundled = BUNDLE / "fonts" / name
    if bundled.is_file():
        return bundled
    for folder in (SMALL, BIG):
        candidate = folder / name
        if candidate.is_file():
            return candidate
    return None


FONTS = {name: path for name in FONT_NAMES if (path := _font_path(name))}
PAGES = {
    "/": STATIC / "index.html",
    "/app.css": STATIC / "app.css",
    "/app.js": STATIC / "app.js",
}
TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".ttf": "font/ttf",
}
MAX_BODY = 30 * 1024 * 1024


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        if args and isinstance(args[0], str) and ("/api/search" in args[0] or "/fonts/" in args[0]):
            return
        super().log_message(fmt, *args)

    def _origin_ok(self) -> bool:
        origin = self.headers.get("Origin")
        if not origin:
            return True
        return origin == f"http://{self.headers.get('Host', '')}"

    def _send(self, status: int, body: bytes, content_type: str, cache: str = "no-store") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, data, status: int = 200) -> None:
        self._send(status, json.dumps(data, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length < 0 or length > MAX_BODY:
            raise ValueError("파일이 너무 큽니다")
        return self.rfile.read(length) if length else b""

    def _read_json(self) -> dict:
        raw = self._read_body()
        if not raw:
            return {}
        try:
            data = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError("요청을 읽지 못했습니다") from exc
        if not isinstance(data, dict):
            raise ValueError("요청을 읽지 못했습니다")
        return data

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if not self._origin_ok():
            self._json({"error": "허용되지 않은 주소입니다"}, 403)
            return
        parsed = urlparse(self.path)
        if parsed.path in PAGES:
            self._file(PAGES[parsed.path], cache="no-store")
            return
        if parsed.path.startswith("/fonts/"):
            font = FONTS.get(parsed.path.rsplit("/", 1)[-1])
            if font and font.is_file():
                self._file(font, cache="public, max-age=86400")
                return
            self._json({"error": "글꼴을 찾지 못했습니다"}, 404)
            return
        if parsed.path == "/favicon.ico":
            self._send(204, b"", "image/x-icon")
            return
        query = parse_qs(parsed.query)
        refresh = query.get("refresh", ["0"])[0] == "1"
        try:
            if parsed.path == "/api/status":
                self._json(self._status(refresh))
                return
            if parsed.path == "/api/search":
                level = query.get("level", ["all"])[0]
                text = query.get("q", [""])[0]
                self._json(catalog.search(text, level, force=refresh))
                return
            if parsed.path == "/api/missing":
                snap = catalog.snapshot(force=refresh)
                self._json({"items": snap["visible"], "hidden": snap["hidden"]})
                return
        except ValueError as exc:
            self._json({"error": str(exc)}, 400)
            return
        self._json({"error": "없는 주소입니다"}, 404)

    def do_POST(self):
        if not self._origin_ok():
            self._json({"error": "허용되지 않은 주소입니다"}, 403)
            return
        path = urlparse(self.path).path
        try:
            if path == "/api/import":
                encoded = self.headers.get("X-Filename", "")
                try:
                    filename = base64.b64decode(encoded).decode("utf-8")
                except (ValueError, UnicodeDecodeError) as exc:
                    raise ValueError("파일 이름을 읽지 못했습니다") from exc
                result = catalog.import_bytes(filename, self._read_body())
                names = ", ".join(item["name"] for item in result.get("items", [result]))
                print(f"import {result['status']} {names}", flush=True)
                self._json(result)
                return
            data = self._read_json()
            if path == "/api/dismiss":
                catalog.dismiss(str(data.get("id", "")))
                self._json({"ok": True})
                return
            if path == "/api/restore":
                catalog.restore(str(data.get("id", "")))
                self._json({"ok": True})
                return
            if path == "/api/open":
                target = catalog.inside_archives(Path(str(data.get("path", ""))))
                if data.get("folder"):
                    target = target.parent
                if not target.exists():
                    raise ValueError("파일을 찾지 못했습니다")
                os.startfile(target)  # noqa: S606 - local desk, path already confined to the two folders
                self._json({"ok": True})
                return
        except ValueError as exc:
            self._json({"error": str(exc)}, 400)
            return
        except OSError as exc:
            self._json({"error": "파일을 열지 못했습니다"}, 400)
            print(exc, flush=True)
            return
        self._json({"error": "없는 주소입니다"}, 404)

    def _status(self, refresh: bool) -> dict:
        snap = catalog.snapshot(force=refresh)
        return {
            "high_count": snap["high_count"],
            "mid_count": snap["mid_count"],
            "unread": snap["unread"],
            "missing": len(snap["visible"]),
            "hidden": len(snap["hidden"]),
            "high_root": str(catalog.HIGH_ROOT),
            "mid_root": str(catalog.MID_ROOT),
            "high_ok": catalog.HIGH_ROOT.is_dir(),
            "mid_ok": catalog.MID_ROOT.is_dir(),
            "mock_count": catalog.mock_pdf_count(),
            "mock_root": str(catalog.MOCK_ROOT),
            "mock_ok": catalog.MOCK_ROOT.is_dir(),
        }

    def _file(self, path: Path, cache: str) -> None:
        if not path.is_file():
            self._json({"error": "화면 파일을 찾지 못했습니다"}, 404)
            return
        self._send(200, path.read_bytes(), TYPES.get(path.suffix, "application/octet-stream"), cache)


def main() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    host = "127.0.0.1"
    server = None
    port = 0
    for candidate in range(8765, 8775):
        try:
            server = ThreadingHTTPServer((host, candidate), Handler)
            port = candidate
            break
        except OSError:
            continue
    if server is None:
        raise SystemExit("8765-8774 포트를 모두 사용 중입니다")
    url = f"http://{host}:{port}"
    if sys.platform == "win32":
        try:
            import ctypes

            ctypes.windll.kernel32.SetConsoleTitleW("내신 기출")
        except (AttributeError, OSError):
            pass
    print("내신 기출", flush=True)
    print(url, flush=True)
    print(catalog.HIGH_ROOT, flush=True)
    print(catalog.MID_ROOT, flush=True)
    print(catalog.MOCK_ROOT, flush=True)
    print("이 창이 켜져 있는 동안만 이 PC에서 열립니다.", flush=True)
    print("다른 PC에서는 그 PC의 실행 파일을 켜면 됩니다.", flush=True)
    print("이 창을 닫으면 프로그램이 끝납니다.", flush=True)
    if not os.environ.get("EXAM_DESK_NO_BROWSER"):
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("종료", flush=True)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
