#!/usr/bin/env python3
"""Convert .bin battery icon files to LVGL C arrays"""

import os
import sys

# Mapping of bin files to output C files
ICON_MAPPING = {
    'battery_android_bolt_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48.bin': 'icon_battery_bolt.c',
    'battery_android_0_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48.bin': 'icon_battery_0.c',
    'battery_android_frame_1_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48.bin': 'icon_battery_1.c',
    'battery_android_frame_2_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48.bin': 'icon_battery_2.c',
    'battery_android_frame_3_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48.bin': 'icon_battery_3.c',
    'battery_android_frame_4_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48.bin': 'icon_battery_4.c',
    'battery_android_frame_5_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48.bin': 'icon_battery_5.c',
    'battery_android_frame_6_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48.bin': 'icon_battery_6.c',
    'battery_android_frame_full_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48.bin': 'icon_battery_full.c',
}

DOWNLOADS_DIR = r'C:\Users\harry\Downloads'
OUTPUT_DIR = 'src'

def convert_bin_to_c(bin_path, c_path, array_name):
    """Convert binary file to C array"""
    with open(bin_path, 'rb') as f:
        data = f.read()
    
    # Generate C file
    with open(c_path, 'w') as f:
        f.write('#include <lvgl.h>\n\n')
        f.write(f'const uint8_t {array_name}_map[]={{\n')
        
        # Write hex data, 16 bytes per line
        for i in range(0, len(data), 16):
            chunk = data[i:i+16]
            hex_str = ','.join(f'0x{b:02x}' for b in chunk)
            f.write(f'  {hex_str},\n')
        
        f.write('};\n\n')
        
        # Write image descriptor
        f.write(f'const lv_img_dsc_t {array_name} = {{\n')
        f.write('  .header.always_zero = 0,\n')
        f.write('  .header.w = 0,\n')
        f.write('  .header.h = 0,\n')
        f.write('  .data_size = sizeof(' + array_name + '_map),\n')
        f.write('  .header.cf = LV_IMG_CF_RAW_ALPHA,\n')
        f.write('  .data = ' + array_name + '_map,\n')
        f.write('};\n')
    
    print(f'✓ Converted {os.path.basename(bin_path)} -> {os.path.basename(c_path)}')

def main():
    for bin_file, c_file in ICON_MAPPING.items():
        bin_path = os.path.join(DOWNLOADS_DIR, bin_file)
        c_path = os.path.join(OUTPUT_DIR, c_file)
        
        if not os.path.exists(bin_path):
            print(f'✗ Missing: {bin_file}')
            continue
        
        # Extract array name from bin filename (remove extension)
        array_name = os.path.splitext(bin_file)[0]
        
        convert_bin_to_c(bin_path, c_path, array_name)
    
    print('\nAll icons converted successfully!')

if __name__ == '__main__':
    main()








