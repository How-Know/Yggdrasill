#!/usr/bin/env python3
"""
LVGL Image Converter - PNG to C Array
Converts PNG images to LVGL C image descriptor format
"""
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("PIL/Pillow not found. Installing...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "Pillow"])
    from PIL import Image

def png_to_lvgl_c(png_path, var_name):
    """Convert PNG to LVGL C array format (CF_TRUE_COLOR_ALPHA)"""
    img = Image.open(png_path).convert('RGBA')
    w, h = img.size
    
    # LVGL v9 uses ARGB8888 format (4 bytes per pixel)
    pixels = []
    for y in range(h):
        for x in range(w):
            r, g, b, a = img.getpixel((x, y))
            # ARGB8888: alpha, red, green, blue
            pixels.append(f"0x{a:02x}, 0x{r:02x}, 0x{g:02x}, 0x{b:02x}")
    
    pixel_data = ",\n  ".join(pixels)
    
    c_code = f"""#ifndef LV_ATTRIBUTE_MEM_ALIGN
#define LV_ATTRIBUTE_MEM_ALIGN
#endif

#ifndef LV_ATTRIBUTE_IMG_{var_name.upper()}
#define LV_ATTRIBUTE_IMG_{var_name.upper()}
#endif

const LV_ATTRIBUTE_MEM_ALIGN LV_ATTRIBUTE_IMG_{var_name.upper()} uint8_t {var_name}_map[] = {{
  {pixel_data}
}};

const lv_image_dsc_t {var_name} = {{
  .header.cf = LV_COLOR_FORMAT_ARGB8888,
  .header.always_zero = 0,
  .header.reserved = 0,
  .header.w = {w},
  .header.h = {h},
  .data_size = {len(pixels) * 4},
  .data = {var_name}_map,
}};
"""
    return c_code

def main():
    # Check if PNG files exist
    icons_dir = Path(__file__).parent / "assets" / "icons" / "md3"
    
    print("LVGL Icon Converter")
    print("=" * 50)
    print(f"Looking for icons in: {icons_dir}")
    
    if not icons_dir.exists():
        print(f"ERROR: Directory not found: {icons_dir}")
        print("\nPlease save your icons as:")
        print("  - assets/icons/md3/home.png")
        print("  - assets/icons/md3/volume_up.png")
        return 1
    
    home_png = icons_dir / "home.png"
    volume_png = icons_dir / "volume_up.png"
    
    if not home_png.exists() or not volume_png.exists():
        print(f"\nERROR: PNG files not found!")
        print(f"  home.png: {'✓' if home_png.exists() else '✗'}")
        print(f"  volume_up.png: {'✓' if volume_png.exists() else '✗'}")
        print("\nPlease save the images you provided as PNG files in:")
        print(f"  {icons_dir}")
        return 1
    
    # Convert icons
    print("\nConverting icons...")
    home_c = png_to_lvgl_c(home_png, "icon_home")
    volume_c = png_to_lvgl_c(volume_png, "icon_volume_up")
    
    # Write header file
    header_path = Path(__file__).parent / "icons_embedded.h"
    with open(header_path, 'w', encoding='utf-8') as f:
        f.write(f"""// Auto-generated LVGL embedded icons
// Generated from PNG files in assets/icons/md3/

#ifndef ICONS_EMBEDDED_H
#define ICONS_EMBEDDED_H

#ifdef __cplusplus
extern "C" {{
#endif

#include "lvgl.h"

// Home icon (24x24 ARGB8888)
{home_c}

// Volume Up icon (24x24 ARGB8888)
{volume_c}

#ifdef __cplusplus
}} /*extern "C"*/
#endif

#endif // ICONS_EMBEDDED_H
""")
    
    print(f"✓ Generated: {header_path}")
    print("\nNext steps:")
    print("1. Include 'icons_embedded.h' in main.c")
    print("2. Use LV_IMAGE_DECLARE(icon_home) and lv_image_set_src(img, &icon_home)")
    print("3. Rebuild the project")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())





