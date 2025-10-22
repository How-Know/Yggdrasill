import sys
import os

def bin_to_c(bin_path, output_path, var_name, width, height):
    with open(bin_path, 'rb') as f:
        data = f.read()
    
    # Generate C array
    c_code = f"""#include <lvgl.h>

#ifndef LV_ATTRIBUTE_MEM_ALIGN
#define LV_ATTRIBUTE_MEM_ALIGN
#endif

const LV_ATTRIBUTE_MEM_ALIGN uint8_t {var_name}_map[] = {{
  """
    
    for i, byte in enumerate(data):
        c_code += f"0x{byte:02x}, "
        if (i + 1) % 16 == 0:
            c_code += "\n  "
    
    c_code += f"""
}};

const lv_img_dsc_t {var_name} = {{
  .header.always_zero = 0,
  .header.w = {width},
  .header.h = {height},
  .data_size = {len(data)},
  .header.cf = LV_IMG_CF_TRUE_COLOR,
  .data = {var_name}_map,
}};
"""
    
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(c_code)
    
    print(f"Generated: {output_path}")

if __name__ == "__main__":
    downloads = r"C:\Users\harry\Downloads"
    icons = [
        ("home_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48", "icon_home.c"),
        ("volume_mute_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48", "icon_volume_up.c"),
        ("settings_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48", "icon_settings.c"),
    ]
    
    for var_name, output_name in icons:
        bin_path = os.path.join(downloads, f"{var_name}.bin")
        output_path = os.path.join("firmware", "m5stack", "src", output_name)
        if os.path.exists(bin_path):
            bin_to_c(bin_path, output_path, var_name, 50, 50)
        else:
            print(f"Not found: {bin_path}")








