#pragma once
#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

// WiFi UI module
void wifi_ui_show(lv_obj_t* parent, lv_font_t* font);
void wifi_ui_close(void);
bool wifi_ui_is_open(void);

#ifdef __cplusplus
}
#endif




