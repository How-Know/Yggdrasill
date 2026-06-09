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
// 유휴 타이머를 리셋(필요 시 깨우기)해 절전 진입을 막는다.
// 초기 MQTT 연결/첫 데이터 수신 전 "연결 중" 화면이 꺼지지 않게 하는 용도.
void screensaver_keep_awake(void);

typedef void (*screensaver_wake_cb_t)(void);
void screensaver_set_wake_callback(screensaver_wake_cb_t cb);

#ifdef __cplusplus
}
#endif


