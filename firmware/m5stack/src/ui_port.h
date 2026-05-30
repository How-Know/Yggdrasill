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
void ui_before_screensaver(void);
void ui_after_screensaver_wake(void);
void ui_port_force_unbind(void);
void ui_port_on_device_ack_json(const char* body);
// bind ack 결과 처리 (메인 deviceAck 핸들러에서 호출)
void ui_port_on_bind_ack(bool ok, const char* reason, int attempts_left, int locked_seconds);

// 펌웨어 측 MQTT publish 콜백(메인에서 구현)
void fw_publish_bind(const char* studentId);
// ack 대기형 bind 요청: 로컬 바인딩 상태를 바꾸지 않고 bind 커맨드만 발행(pin 선택)
void fw_request_bind(const char* studentId, const char* pin);
// bind ack 성공 시 로컬 바인딩 상태 확정(NVS/LittleFS 저장)
void fw_commit_bind(const char* studentId);
void fw_publish_unbind();
void fw_clear_local_binding_state(void);
void fw_publish_student_info(const char* studentId);
void fw_publish_homework_action(const char* action, const char* itemId);
bool fw_publish_group_transition(const char* groupId, int from_phase = 0);
void fw_publish_pause_all();
void fw_publish_raise_question();
void fw_publish_create_descriptive_writing(void);
void fw_publish_check_update();
void fw_publish_list_today();
void fw_publish_list_homeworks(const char* studentIdArg);


