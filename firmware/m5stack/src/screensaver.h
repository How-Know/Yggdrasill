#pragma once
#include <lvgl.h>

#ifdef __cplusplus
extern "C" {
#endif

void screensaver_init(uint32_t timeout_ms);
void screensaver_attach_activity(lv_obj_t* root);
void screensaver_notify_touch(bool pressed);
void screensaver_poll(void);
void screensaver_blink_set(uint32_t blink_ms, uint32_t interval_ms);
void screensaver_check_shake(void);
void screensaver_dismiss(void);

typedef void (*screensaver_wake_cb_t)(void);
void screensaver_set_wake_callback(screensaver_wake_cb_t cb);

#ifdef __cplusplus
}
#endif


