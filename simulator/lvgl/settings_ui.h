#pragma once
#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

// Settings UI module
void settings_ui_show(lv_obj_t* parent_stage, 
                      lv_obj_t* pages_to_hide, 
                      lv_obj_t* fab_to_hide,
                      lv_obj_t* bottom_sheet_to_hide,
                      lv_obj_t* bottom_handle_to_hide,
                      lv_font_t* title_font,
                      lv_font_t* label_font,
                      const char* app_version,
                      const lv_image_dsc_t* wifi_icon,
                      const lv_image_dsc_t* refresh_icon);
void settings_ui_close(void);
void settings_ui_restore(void);  // Show settings without hiding other UI
bool settings_ui_is_open(void);

#ifdef __cplusplus
}
#endif

