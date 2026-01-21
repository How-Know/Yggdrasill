#pragma once

#include <ArduinoJson.h>
#include <lvgl.h>

#ifdef __cplusplus
extern "C" {
#endif

// 외부에서 토글을 사용할 수 있도록 공개 (settings 등에서 참조)
extern bool g_bottom_sheet_open;
extern bool g_should_vibrate_phase4;
void toggle_bottom_sheet(void);

#ifdef __cplusplus
}
#endif

// C++ 인터페이스 (ArduinoJson 연계)
void ui_port_init();
void ui_port_update_students(const JsonArray& students);
void ui_port_update_homeworks(const JsonArray& items);
void ui_port_update_student_info(const JsonObject& info);
void ui_port_show_settings(const char* appVersion);
void ui_port_set_global_font(const lv_font_t* font);
void ui_before_screen_change(void);

// 펌웨어 측 MQTT publish 콜백(메인에서 구현)
void fw_publish_bind(const char* studentId);
void fw_publish_unbind();
void fw_publish_student_info(const char* studentId);
void fw_publish_homework_action(const char* action, const char* itemId);
void fw_publish_pause_all();
void fw_publish_check_update();
void fw_publish_list_today();


