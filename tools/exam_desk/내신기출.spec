# -*- mode: python ; coding: utf-8 -*-
"""One-file Windows build. Run from this folder: py -3 -m PyInstaller --noconfirm --clean 내신기출.spec"""

from pathlib import Path

root = Path(SPECPATH)
repo = root.parents[1]
font_dirs = [
    repo / "apps" / "yggdrasill" / "assets" / "fonts" / "kakao" / "카카오작은글씨" / "TTF",
    repo / "apps" / "yggdrasill" / "assets" / "fonts" / "kakao" / "카카오큰글씨" / "TTF",
]
datas = [(str(root / "static"), "static")]
for folder in font_dirs:
    if not folder.is_dir():
        continue
    for font in folder.glob("*.ttf"):
        datas.append((str(font), "fonts"))

a = Analysis(
    ["server.py"],
    pathex=[str(root)],
    binaries=[],
    datas=datas,
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name="내신기출",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
)
