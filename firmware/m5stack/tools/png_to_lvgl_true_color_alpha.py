"""PNG -> LVGL 8 RGB565 + alpha (LV_IMG_CF_TRUE_COLOR_ALPHA), 16-bit LE + opa."""
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("pip install pillow", file=sys.stderr)
    sys.exit(1)


def rgb565(r: int, g: int, b: int) -> int:
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


def pixel_bytes(r: int, g: int, b: int, a: int) -> bytes:
    c = rgb565(r, g, b)
    return bytes((c & 0xFF, (c >> 8) & 0xFF, a & 0xFF))


def convert_png(src: Path, dst: Path, c_name: str, w: int = 64, h: int = 64) -> None:
    im = Image.open(src).convert("RGBA")
    im = im.resize((w, h), Image.Resampling.LANCZOS)
    raw = bytearray()
    for y in range(h):
        for x in range(w):
            r, g, b, a = im.getpixel((x, y))
            raw.extend(pixel_bytes(r, g, b, a))
    arr = c_name + "_map"
    lines = []
    for i in range(0, len(raw), 16):
        chunk = ", ".join(f"0x{b:02x}" for b in raw[i : i + 16])
        lines.append("  " + chunk + ",")
    body = "\n".join(lines)
    px = w * h * 3
    content = f'''#include <lvgl.h>

const uint8_t {arr}[] = {{
{body}
}};

const lv_img_dsc_t {c_name} = {{
  .header.cf = LV_IMG_CF_TRUE_COLOR_ALPHA,
  .header.always_zero = 0,
  .header.reserved = 0,
  .header.w = {w},
  .header.h = {h},
  .data_size = {px},
  .data = {arr},
}};
'''
    dst.write_text(content, encoding="utf-8")
    print(dst, len(raw), "bytes")


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    convert_png(
        root / "add_2_100dp_999999_FILL0_wght400_GRAD0_opsz48.png",
        root / "src" / "bottom_sheet_add_64.c",
        "bottom_sheet_add_64",
    )
    convert_png(
        root / "person_raised_hand_100dp_999999_FILL0_wght400_GRAD0_opsz48.png",
        root / "src" / "bottom_sheet_question_64.c",
        "bottom_sheet_question_64",
    )
