#pragma once
#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

void screensaver_init(uint32_t timeout_ms);
void screensaver_attach_activity(lv_obj_t* root);
void screensaver_poll(void);
void screensaver_blink_set(uint32_t blink_ms, uint32_t interval_ms);

#ifdef __cplusplus
}
#endif
