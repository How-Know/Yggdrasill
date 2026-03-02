#include "ui_port.h"
#include <M5Unified.h>
#include <lvgl.h>
#include "screensaver.h"
#include <LittleFS.h>
#include <cstring>
#include "ota_update.h"
#include "version.h"

// main.cpp에 정의된 전역 변수 (바인딩 추적용)
extern String studentId;
// Small bitmap font for meta text (school/grade)
extern const lv_font_t kakao_kr_16;

// External icon declarations
LV_IMG_DECLARE(home_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(volume_mute_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(settings_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(wifi_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(update_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(light_mode_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(battery_android_alert_32dp_999999_FILL0_wght400_GRAD0_opsz40);
LV_IMG_DECLARE(battery_android_bolt_32dp_999999_FILL0_wght400_GRAD0_opsz40);
LV_IMG_DECLARE(battery_android_frame_1_32dp_999999_FILL0_wght400_GRAD0_opsz40);
LV_IMG_DECLARE(battery_android_frame_2_32dp_999999_FILL0_wght400_GRAD0_opsz40);
LV_IMG_DECLARE(battery_android_frame_3_32dp_999999_FILL0_wght400_GRAD0_opsz40);
LV_IMG_DECLARE(battery_android_frame_4_32dp_999999_FILL0_wght400_GRAD0_opsz40);
LV_IMG_DECLARE(battery_android_frame_5_32dp_999999_FILL0_wght400_GRAD0_opsz40);
LV_IMG_DECLARE(battery_android_frame_6_32dp_999999_FILL0_wght400_GRAD0_opsz40);
LV_IMG_DECLARE(battery_android_frame_full_32dp_999999_FILL0_wght400_GRAD0_opsz40);

// 간단 포팅: 시뮬레이터 레이아웃을 축약 반영
static lv_obj_t* s_stage = nullptr;
static lv_obj_t* s_pages = nullptr;
static lv_obj_t* s_info_panel = nullptr;
static lv_obj_t* s_list = nullptr;
static lv_obj_t* s_fab = nullptr;
static lv_obj_t* s_bottom_sheet = nullptr;
static lv_obj_t* s_bottom_handle = nullptr;
static lv_obj_t* s_settings_scr = nullptr;
static const lv_font_t* s_global_font = nullptr;
static bool s_homeworks_mode = false; // false: 학생 리스트, true: 바인딩 후 메인 플로우
static lv_obj_t* s_empty_label = nullptr;
static lv_obj_t* s_empty_overlay = nullptr;
static lv_obj_t* s_volume_popup = nullptr;
static lv_obj_t* s_bind_confirm_popup = nullptr;
static lv_obj_t* s_entry_hub = nullptr;
static lv_obj_t* s_entry_name_label = nullptr;
static lv_obj_t* s_student_info_screen = nullptr;
static uint8_t s_current_volume = 50;
static lv_timer_t* s_vibration_timer = nullptr;
static bool s_vibration_on = false;
static lv_obj_t* s_brightness_popup = nullptr;
static uint8_t s_current_brightness = 128;
static lv_obj_t* s_battery_widget = nullptr;
static lv_obj_t* s_battery_label = nullptr;
static lv_obj_t* s_ota_popup = nullptr;
static lv_obj_t* s_ota_progress_bar = nullptr;
static lv_obj_t* s_ota_status_label = nullptr;
static uint32_t s_last_refresh_ms = 0;
static String s_pending_bind_student_id = "";
static String s_pending_bind_student_name = "";
static String s_student_name_cache = u8"학생";
static String s_student_school_cache = "";
static int s_student_grade_cache = -1;
static bool s_sheet_dragging = false;
static bool s_sheet_drag_moved = false;
static lv_coord_t s_drag_start_touch_y = 0;
static lv_coord_t s_drag_start_sheet_y = 240;

// 이전 과제 상태 캐시 (diff 기반 업데이트)
struct HwCacheEntry { char id[64]; int phase; int acc; };
static HwCacheEntry s_hw_cache[16];
static uint8_t s_hw_cache_cnt = 0;

// Phase 2 실시간 시간 & Phase 4 깜빡임: 글로벌 단일 타이머로 관리
struct Phase2Entry { lv_obj_t* lbl; uint32_t base_acc; uint32_t start_tick; };
static Phase2Entry s_p2_entries[8];
static uint8_t s_p2_cnt = 0;

static lv_obj_t* s_p4_cards[8];
static uint8_t s_p4_cnt = 0;
static uint32_t s_p4_colors[8];
static uint8_t s_p4_breath_step = 0;

static lv_timer_t* s_hw_global_timer = nullptr;
static uint32_t s_hw_timer_epoch = 0;

static const lv_opa_t BREATH_LUT[] = {
  0, 10, 25, 45, 70, 100, 130, 160, 190, 215, 235, 248, 255, 248, 235, 215,
  190, 160, 130, 100, 70, 45, 25, 10
};
#define BREATH_STEPS (sizeof(BREATH_LUT)/sizeof(BREATH_LUT[0]))

static void hw_global_timer_cb(lv_timer_t* timer) {
  uint32_t epoch = (uint32_t)(uintptr_t)timer->user_data;
  if (epoch != s_hw_timer_epoch) { lv_timer_del(timer); return; }

  static uint8_t sec_tick = 0;
  sec_tick++;
  if (sec_tick >= 10) {
    sec_tick = 0;
    for (uint8_t i = 0; i < s_p2_cnt; i++) {
      if (!s_p2_entries[i].lbl || !lv_obj_is_valid(s_p2_entries[i].lbl)) continue;
      uint32_t elapsed = (lv_tick_get() - s_p2_entries[i].start_tick) / 1000;
      uint32_t total = s_p2_entries[i].base_acc + elapsed;
      int h = total / 3600, m = (total % 3600) / 60;
      char buf[32];
      if (h > 0) snprintf(buf, sizeof(buf), "%dh %dm", h, m);
      else snprintf(buf, sizeof(buf), "%dm", m);
      lv_label_set_text(s_p2_entries[i].lbl, buf);
    }
  }

  s_p4_breath_step = (s_p4_breath_step + 1) % BREATH_STEPS;
  lv_opa_t opa = BREATH_LUT[s_p4_breath_step];
  for (uint8_t i = 0; i < s_p4_cnt; i++) {
    if (!s_p4_cards[i] || !lv_obj_is_valid(s_p4_cards[i])) continue;
    lv_obj_set_style_outline_opa(s_p4_cards[i], opa, 0);
  }
}

bool g_bottom_sheet_open = false;
bool g_should_vibrate_phase4 = false;

static void show_volume_popup(void);
static void close_volume_popup(void);
static void show_brightness_popup(void);
static void close_brightness_popup(void);
static void close_bind_confirm_popup(void);
static void show_entry_hub_overlay(void);
static void close_student_info_screen(bool show_entry_hub);
static void show_student_info_screen(void);
static void show_bind_confirm_popup(const char* student_id, const char* student_name);
static void populate_student_info_container(lv_obj_t* target, bool include_back_header);
static void build_homeworks_ui_internal(void);
static void bottom_sheet_drag_cb(lv_event_t* e);
static void update_battery_widget(void);
// Delayed restart helper so UI message can render before reboot
static void restart_app_timer_cb(lv_timer_t* timer) {
  (void)timer;
  ESP.restart();
}
static void anim_set_bg_gray(void* obj, int32_t v) {
  uint32_t g = ((uint32_t)v) & 0xFFu;
  uint32_t hex = (g << 16) | (g << 8) | g;
  lv_obj_set_style_bg_color((lv_obj_t*)obj, lv_color_hex(hex), 0);
}


static void refresh_list_cb(lv_event_t* e) {
  if (lv_event_get_code(e) != LV_EVENT_CLICKED) return;
  uint32_t now = millis();
  if (now - s_last_refresh_ms < 800) return;
  s_last_refresh_ms = now;
  fw_publish_list_today();
}

static void append_refresh_button() {
  if (!s_list || !lv_obj_is_valid(s_list)) return;
  lv_obj_t* card = lv_obj_create(s_list);
  lv_obj_set_width(card, lv_pct(100));
  lv_obj_set_height(card, 72);
  lv_obj_set_style_radius(card, 10, 0);
  lv_obj_set_style_bg_color(card, lv_color_hex(0x232326), 0);
  lv_obj_set_style_border_color(card, lv_color_hex(0x2C2C2C), 0);
  lv_obj_set_style_border_width(card, 2, 0);
  lv_obj_set_style_pad_all(card, 12, 0);
  lv_obj_t* lbl = lv_label_create(card);
  lv_obj_set_style_text_color(lbl, lv_color_hex(0xE6E6E6), 0);
  if (s_global_font) lv_obj_set_style_text_font(lbl, s_global_font, 0);
  lv_label_set_text(lbl, u8"새로고침");
  lv_obj_center(lbl);
  lv_obj_add_event_cb(card, refresh_list_cb, LV_EVENT_CLICKED, NULL);
}

static void append_empty_message() {
  if (!s_list || !lv_obj_is_valid(s_list)) return;
  lv_obj_t* row = lv_obj_create(s_list);
  lv_obj_set_width(row, lv_pct(100));
  lv_obj_set_height(row, 64);
  lv_obj_set_style_bg_opa(row, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(row, 0, 0);
  lv_obj_set_style_pad_all(row, 8, 0);
  lv_obj_t* lbl = lv_label_create(row);
  lv_obj_set_style_text_color(lbl, lv_color_hex(0xA0A0A0), 0);
  if (s_global_font) lv_obj_set_style_text_font(lbl, s_global_font, 0);
  lv_label_set_text(lbl, u8"등원 예정 학생이 없습니다.");
  lv_obj_center(lbl);
}

static lv_coord_t clamp_sheet_y(lv_coord_t y) {
  if (y < 140) return 140;
  if (y > 240) return 240;
  return y;
}

static void set_bottom_sheet_position(lv_coord_t sheet_y) {
  if (!s_bottom_sheet || !s_bottom_handle) return;
  lv_coord_t clamped_sheet = clamp_sheet_y(sheet_y);
  lv_coord_t handle_y = clamped_sheet - 20;
  lv_obj_set_y(s_bottom_sheet, clamped_sheet);
  lv_obj_set_y(s_bottom_handle, handle_y);
}

static void anim_set_sheet_y(void* obj, int32_t v) {
  lv_obj_set_y((lv_obj_t*)obj, clamp_sheet_y((lv_coord_t)v));
}
static void anim_set_handle_y(void* obj, int32_t v) {
  lv_coord_t clamped = clamp_sheet_y((lv_coord_t)(v + 20)) - 20;
  lv_obj_set_y((lv_obj_t*)obj, clamped);
}

static void animate_bottom_sheet_to(bool open_target) {
  if (!s_bottom_sheet || !s_bottom_handle) return;
  lv_coord_t target_sheet = open_target ? 140 : 240;
  lv_coord_t target_handle = target_sheet - 20;

  lv_anim_del(s_bottom_sheet, anim_set_sheet_y);
  lv_anim_del(s_bottom_handle, anim_set_handle_y);
  lv_anim_del(s_bottom_sheet, (lv_anim_exec_xcb_t)lv_obj_set_y);
  lv_anim_del(s_bottom_handle, (lv_anim_exec_xcb_t)lv_obj_set_y);

  lv_anim_t a1; lv_anim_init(&a1); lv_anim_set_var(&a1, s_bottom_sheet);
  lv_anim_set_time(&a1, 230); lv_anim_set_path_cb(&a1, lv_anim_path_ease_out);
  lv_anim_set_exec_cb(&a1, anim_set_sheet_y);
  lv_anim_set_values(&a1, clamp_sheet_y(lv_obj_get_y(s_bottom_sheet)), target_sheet);

  lv_anim_t a2; lv_anim_init(&a2); lv_anim_set_var(&a2, s_bottom_handle);
  lv_anim_set_time(&a2, 230); lv_anim_set_path_cb(&a2, lv_anim_path_ease_out);
  lv_anim_set_exec_cb(&a2, anim_set_handle_y);
  lv_anim_set_values(&a2, lv_obj_get_y(s_bottom_handle), target_handle);

  lv_anim_start(&a1);
  lv_anim_start(&a2);
  g_bottom_sheet_open = open_target;
}

static void handle_drag_end(lv_event_t* e) {
  (void)e;
  if (!s_bottom_sheet || !s_bottom_handle) return;
  lv_coord_t sheet_y = clamp_sheet_y(lv_obj_get_y(s_bottom_sheet));
  lv_coord_t threshold = (140 + 240) / 2; // 190
  animate_bottom_sheet_to(sheet_y < threshold);
}

static bool is_entry_hub_visible(void) {
  return s_entry_hub && lv_obj_is_valid(s_entry_hub) && !lv_obj_has_flag(s_entry_hub, LV_OBJ_FLAG_HIDDEN);
}

static void bottom_sheet_drag_cb(lv_event_t* e) {
  if (!s_bottom_sheet || !s_bottom_handle) return;
  if (is_entry_hub_visible()) return;
  lv_event_code_t code = lv_event_get_code(e);
  lv_indev_t* indev = lv_event_get_indev(e);
  if (!indev) return;
  lv_point_t p;
  lv_indev_get_point(indev, &p);

  if (code == LV_EVENT_PRESSED) {
    lv_anim_del(s_bottom_sheet, (lv_anim_exec_xcb_t)lv_obj_set_y);
    lv_anim_del(s_bottom_handle, (lv_anim_exec_xcb_t)lv_obj_set_y);
    s_sheet_dragging = true;
    s_sheet_drag_moved = false;
    s_drag_start_touch_y = p.y;
    s_drag_start_sheet_y = clamp_sheet_y(lv_obj_get_y(s_bottom_sheet));
    return;
  }

  if (code == LV_EVENT_PRESSING && s_sheet_dragging) {
    lv_coord_t delta = (lv_coord_t)(p.y - s_drag_start_touch_y);
    if (delta > 3 || delta < -3) s_sheet_drag_moved = true;
    lv_coord_t raw_y = s_drag_start_sheet_y + delta;
    set_bottom_sheet_position(raw_y);
    return;
  }

  if ((code == LV_EVENT_RELEASED || code == LV_EVENT_PRESS_LOST) && s_sheet_dragging) {
    s_sheet_dragging = false;
    if (s_sheet_drag_moved) {
      handle_drag_end(e);
    }
  }
}

void toggle_bottom_sheet(void) {
  if (!s_bottom_sheet || !s_bottom_handle) return;
  if (is_entry_hub_visible()) return;
  animate_bottom_sheet_to(!g_bottom_sheet_open);
}

static void create_base_container() {
  if (s_stage) return;
  lv_obj_t* scr = lv_scr_act();
  // 단일 루트(stage)로 평탄화해 불필요한 컨테이너 중첩 제거
  s_stage = lv_obj_create(scr);
  lv_obj_set_size(s_stage, lv_pct(100), lv_pct(100));
  lv_obj_set_style_bg_color(s_stage, lv_color_hex(0x0B1112), 0);
  lv_obj_set_style_bg_opa(s_stage, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_stage, 0, 0);
  lv_obj_set_style_radius(s_stage, 0, 0);
  lv_obj_set_style_pad_all(s_stage, 0, 0);
  lv_obj_set_scrollbar_mode(s_stage, LV_SCROLLBAR_MODE_OFF);
  lv_obj_clear_flag(s_stage, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_pad_all(s_stage, 0, 0);
  lv_obj_set_scrollbar_mode(s_stage, LV_SCROLLBAR_MODE_OFF);
  lv_obj_clear_flag(s_stage, LV_OBJ_FLAG_SCROLLABLE);
  if (s_global_font) lv_obj_set_style_text_font(s_stage, s_global_font, 0);
  // stage 하위 라벨에도 기본 폰트 전파
  lv_obj_set_style_text_font(s_stage, s_global_font, LV_PART_MAIN | LV_STATE_DEFAULT);
}

static void show_transient_notice(const char* message) {
  if (!message || !*message) return;
  lv_obj_t* popup = lv_obj_create(lv_scr_act());
  lv_obj_set_size(popup, 220, 90);
  lv_obj_center(popup);
  lv_obj_set_style_bg_color(popup, lv_color_hex(0x202020), 0);
  lv_obj_set_style_bg_opa(popup, LV_OPA_90, 0);
  lv_obj_set_style_border_width(popup, 0, 0);
  lv_obj_set_style_radius(popup, 12, 0);
  lv_obj_set_style_pad_all(popup, 12, 0);
  lv_obj_clear_flag(popup, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_t* label = lv_label_create(popup);
  if (s_global_font) lv_obj_set_style_text_font(label, s_global_font, 0);
  lv_obj_set_style_text_color(label, lv_color_hex(0xFFFFFF), 0);
  lv_label_set_text(label, message);
  lv_obj_center(label);

  lv_timer_t* close_timer = lv_timer_create([](lv_timer_t* t) {
    lv_obj_t* target = (lv_obj_t*)t->user_data;
    if (target && lv_obj_is_valid(target)) lv_obj_del(target);
    lv_timer_del(t);
  }, 1200, popup);
  lv_timer_set_repeat_count(close_timer, 1);
}

static void close_bind_confirm_popup(void) {
  if (s_bind_confirm_popup && lv_obj_is_valid(s_bind_confirm_popup)) {
    lv_obj_del(s_bind_confirm_popup);
  }
  s_bind_confirm_popup = nullptr;
  s_pending_bind_student_id = "";
  s_pending_bind_student_name = "";
}

static void close_student_info_screen(bool show_entry_hub) {
  if (s_student_info_screen && lv_obj_is_valid(s_student_info_screen)) {
    lv_obj_del(s_student_info_screen);
  }
  s_student_info_screen = nullptr;
  if (show_entry_hub) show_entry_hub_overlay();
}

static void populate_student_info_container(lv_obj_t* target, bool include_back_header) {
  if (!target || !lv_obj_is_valid(target)) return;
  lv_obj_clean(target);
  lv_obj_set_style_bg_color(target, lv_color_hex(0x141414), 0);
  lv_obj_set_style_bg_opa(target, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(target, 0, 0);
  lv_obj_set_style_radius(target, 0, 0);
  lv_obj_set_style_pad_all(target, 16, 0);
  lv_obj_set_style_pad_row(target, 8, 0);
  lv_obj_set_scrollbar_mode(target, LV_SCROLLBAR_MODE_OFF);
  lv_obj_set_scroll_dir(target, LV_DIR_VER);
  lv_obj_set_flex_flow(target, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(target, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_START);

  if (include_back_header) {
    lv_obj_t* header = lv_obj_create(target);
    lv_obj_set_width(header, lv_pct(100));
    lv_obj_set_height(header, 44);
    lv_obj_set_style_bg_opa(header, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(header, 0, 0);
    lv_obj_set_style_pad_all(header, 0, 0);
    lv_obj_set_flex_flow(header, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(header, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

    lv_obj_t* back_btn = lv_btn_create(header);
    lv_obj_set_size(back_btn, 38, 38);
    lv_obj_set_style_radius(back_btn, 10, 0);
    lv_obj_set_style_bg_color(back_btn, lv_color_hex(0x1E1E1E), 0);
    lv_obj_set_style_border_width(back_btn, 0, 0);
    lv_obj_set_style_shadow_width(back_btn, 0, 0);
    lv_obj_t* back_lbl = lv_label_create(back_btn);
    if (s_global_font) lv_obj_set_style_text_font(back_lbl, s_global_font, 0);
    lv_obj_set_style_text_color(back_lbl, lv_color_hex(0xE6E6E6), 0);
    lv_label_set_text(back_lbl, "<");
    lv_obj_center(back_lbl);
    lv_obj_add_event_cb(back_btn, [](lv_event_t* e) {
      (void)e;
      close_student_info_screen(true);
    }, LV_EVENT_CLICKED, NULL);

    lv_obj_t* title = lv_label_create(header);
    if (s_global_font) lv_obj_set_style_text_font(title, s_global_font, 0);
    lv_obj_set_style_text_color(title, lv_color_hex(0xFFFFFF), 0);
    lv_obj_set_style_pad_left(title, 10, 0);
    lv_label_set_text(title, u8"학생 정보");
  }

  lv_obj_t* name_lbl = lv_label_create(target);
  if (s_global_font) lv_obj_set_style_text_font(name_lbl, s_global_font, 0);
  lv_obj_set_style_text_color(name_lbl, lv_color_hex(0xE6E6E6), 0);
  lv_label_set_text(name_lbl, s_student_name_cache.c_str());

  lv_obj_t* spacer = lv_obj_create(target);
  lv_obj_set_size(spacer, 1, 14);
  lv_obj_set_style_bg_opa(spacer, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(spacer, 0, 0);

  lv_obj_t* sg = lv_label_create(target);
  lv_obj_set_style_text_color(sg, lv_color_hex(0xA0A0A0), 0);
  if (s_global_font) lv_obj_set_style_text_font(sg, s_global_font, 0);
  char line2[128];
  if (s_student_school_cache.length() > 0 && s_student_grade_cache >= 0) {
    snprintf(line2, sizeof(line2), u8"%s · %d학년", s_student_school_cache.c_str(), s_student_grade_cache);
  } else if (s_student_school_cache.length() > 0) {
    snprintf(line2, sizeof(line2), "%s", s_student_school_cache.c_str());
  } else if (s_student_grade_cache >= 0) {
    snprintf(line2, sizeof(line2), u8"%d학년", s_student_grade_cache);
  } else {
    snprintf(line2, sizeof(line2), u8"—");
  }
  lv_label_set_text(sg, line2);

  lv_obj_t* spacer2 = lv_obj_create(target);
  lv_obj_set_size(spacer2, 1, 28);
  lv_obj_set_style_bg_opa(spacer2, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(spacer2, 0, 0);

  lv_obj_t* logout_btn = lv_btn_create(target);
  lv_obj_set_size(logout_btn, 200, 44);
  lv_obj_set_style_radius(logout_btn, 22, 0);
  lv_obj_set_style_bg_color(logout_btn, lv_color_hex(0xDC143C), 0);
  lv_obj_set_style_border_width(logout_btn, 0, 0);
  lv_obj_set_style_shadow_width(logout_btn, 0, 0);
  lv_obj_t* logout_lbl = lv_label_create(logout_btn);
  if (s_global_font) lv_obj_set_style_text_font(logout_lbl, s_global_font, 0);
  lv_label_set_text(logout_lbl, u8"로그아웃");
  lv_obj_center(logout_lbl);
  lv_obj_add_event_cb(logout_btn, [](lv_event_t* e) {
    (void)e;

    lv_obj_t* popup = lv_obj_create(lv_scr_act());
    lv_obj_set_size(popup, 280, 160);
    lv_obj_center(popup);
    lv_obj_set_style_radius(popup, 20, 0);
    lv_obj_set_style_bg_color(popup, lv_color_hex(0x202020), 0);
    lv_obj_set_style_border_width(popup, 0, 0);
    lv_obj_set_style_shadow_width(popup, 20, 0);
    lv_obj_set_style_shadow_opa(popup, LV_OPA_30, 0);
    lv_obj_clear_flag(popup, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t* msg_lbl = lv_label_create(popup);
    if (s_global_font) lv_obj_set_style_text_font(msg_lbl, s_global_font, 0);
    lv_obj_set_style_text_color(msg_lbl, lv_color_hex(0xFFFFFF), 0);
    lv_label_set_text(msg_lbl, u8"오늘도 수고했어!");
    lv_obj_center(msg_lbl);

    fw_publish_unbind();
    lv_timer_t* restart_timer = lv_timer_create(restart_app_timer_cb, 1800, NULL);
    lv_timer_set_repeat_count(restart_timer, 1);
  }, LV_EVENT_CLICKED, NULL);
}

static void show_student_info_screen(void) {
  if (!s_stage || !lv_obj_is_valid(s_stage)) return;
  if (s_entry_hub && lv_obj_is_valid(s_entry_hub)) {
    lv_obj_add_flag(s_entry_hub, LV_OBJ_FLAG_HIDDEN);
  }
  if (s_student_info_screen && lv_obj_is_valid(s_student_info_screen)) {
    lv_obj_move_foreground(s_student_info_screen);
    return;
  }
  s_student_info_screen = lv_obj_create(s_stage);
  lv_obj_set_size(s_student_info_screen, lv_pct(100), lv_pct(100));
  lv_obj_set_pos(s_student_info_screen, 0, 0);
  lv_obj_set_style_bg_color(s_student_info_screen, lv_color_hex(0x141414), 0);
  lv_obj_set_style_bg_opa(s_student_info_screen, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_student_info_screen, 0, 0);
  lv_obj_set_style_radius(s_student_info_screen, 0, 0);
  if (s_global_font) lv_obj_set_style_text_font(s_student_info_screen, s_global_font, 0);

  populate_student_info_container(s_student_info_screen, true);
  lv_obj_set_x(s_student_info_screen, 320);
  lv_anim_t a;
  lv_anim_init(&a);
  lv_anim_set_var(&a, s_student_info_screen);
  lv_anim_set_values(&a, 320, 0);
  lv_anim_set_time(&a, 220);
  lv_anim_set_exec_cb(&a, (lv_anim_exec_xcb_t)lv_obj_set_x);
  lv_anim_set_path_cb(&a, lv_anim_path_ease_out);
  lv_anim_start(&a);
  screensaver_attach_activity(s_student_info_screen);
}

static void show_entry_hub_overlay(void) {
  if (!s_stage || !lv_obj_is_valid(s_stage) || !s_homeworks_mode) return;
  if (s_student_info_screen && lv_obj_is_valid(s_student_info_screen)) {
    lv_obj_del(s_student_info_screen);
    s_student_info_screen = nullptr;
  }

  if (!s_entry_hub || !lv_obj_is_valid(s_entry_hub)) {
    s_entry_hub = lv_obj_create(s_stage);
    lv_obj_set_size(s_entry_hub, lv_pct(100), lv_pct(100));
    lv_obj_set_pos(s_entry_hub, 0, 0);
    lv_obj_set_style_bg_color(s_entry_hub, lv_color_hex(0x0B1112), 0);
    lv_obj_set_style_bg_opa(s_entry_hub, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(s_entry_hub, 0, 0);
    lv_obj_set_style_radius(s_entry_hub, 0, 0);
    lv_obj_set_style_pad_all(s_entry_hub, 0, 0);
    lv_obj_set_scrollbar_mode(s_entry_hub, LV_SCROLLBAR_MODE_OFF);
    lv_obj_clear_flag(s_entry_hub, LV_OBJ_FLAG_SCROLLABLE);
    if (s_global_font) lv_obj_set_style_text_font(s_entry_hub, s_global_font, 0);

    s_entry_name_label = lv_label_create(s_entry_hub);
    lv_obj_set_width(s_entry_name_label, 280);
    lv_obj_set_style_text_align(s_entry_name_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(s_entry_name_label, lv_color_hex(0xE6E6E6), 0);
    lv_obj_set_style_text_font(s_entry_name_label, &kakao_kr_16, 0);
    lv_label_set_long_mode(s_entry_name_label, LV_LABEL_LONG_DOT);
    lv_label_set_text(s_entry_name_label, s_student_name_cache.c_str());
    lv_obj_align(s_entry_name_label, LV_ALIGN_TOP_MID, 0, 20);

    auto make_hub_btn = [](lv_obj_t* parent, const char* text, lv_coord_t y_off) -> lv_obj_t* {
      lv_obj_t* btn = lv_btn_create(parent);
      lv_obj_set_size(btn, 284, 48);
      lv_obj_set_style_radius(btn, 12, 0);
      lv_obj_set_style_bg_color(btn, lv_color_hex(0x1A1A1A), 0);
      lv_obj_set_style_border_color(btn, lv_color_hex(0x2C2C2C), 0);
      lv_obj_set_style_border_width(btn, 2, 0);
      lv_obj_set_style_shadow_width(btn, 0, 0);
      lv_obj_align(btn, LV_ALIGN_TOP_MID, 0, y_off);
      lv_obj_t* lbl = lv_label_create(btn);
      if (s_global_font) lv_obj_set_style_text_font(lbl, s_global_font, 0);
      lv_obj_set_style_text_color(lbl, lv_color_hex(0xE6E6E6), 0);
      lv_label_set_text(lbl, text);
      lv_obj_center(lbl);
      return btn;
    };

    lv_obj_t* watch_btn = make_hub_btn(s_entry_hub, u8"워치", 56);
    lv_obj_add_event_cb(watch_btn, [](lv_event_t* e) {
      (void)e;
      show_transient_notice(u8"스탑워치 준비 중");
    }, LV_EVENT_CLICKED, NULL);

    lv_obj_t* info_btn = make_hub_btn(s_entry_hub, u8"정보", 116);
    lv_obj_add_event_cb(info_btn, [](lv_event_t* e) {
      (void)e;
      show_student_info_screen();
    }, LV_EVENT_CLICKED, NULL);

    lv_obj_t* hw_btn = make_hub_btn(s_entry_hub, u8"과제", 176);
    lv_obj_add_event_cb(hw_btn, [](lv_event_t* e) {
      (void)e;
      if (s_entry_hub && lv_obj_is_valid(s_entry_hub)) {
        lv_obj_add_flag(s_entry_hub, LV_OBJ_FLAG_HIDDEN);
      }
      if (s_pages && lv_obj_is_valid(s_pages)) {
        lv_obj_clear_flag(s_pages, LV_OBJ_FLAG_HIDDEN);
      }
      if (s_fab && lv_obj_is_valid(s_fab)) {
        lv_obj_clear_flag(s_fab, LV_OBJ_FLAG_HIDDEN);
      }
      if (s_bottom_handle && lv_obj_is_valid(s_bottom_handle)) lv_obj_clear_flag(s_bottom_handle, LV_OBJ_FLAG_HIDDEN);
      if (s_bottom_sheet && lv_obj_is_valid(s_bottom_sheet)) lv_obj_clear_flag(s_bottom_sheet, LV_OBJ_FLAG_HIDDEN);
    }, LV_EVENT_CLICKED, NULL);
  }

  if (s_entry_name_label && lv_obj_is_valid(s_entry_name_label)) {
    lv_label_set_text(s_entry_name_label, s_student_name_cache.c_str());
  }
  lv_obj_clear_flag(s_entry_hub, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(s_entry_hub);
  if (s_pages && lv_obj_is_valid(s_pages)) lv_obj_add_flag(s_pages, LV_OBJ_FLAG_HIDDEN);
  if (s_fab && lv_obj_is_valid(s_fab)) {
    lv_obj_add_flag(s_fab, LV_OBJ_FLAG_HIDDEN);
  }
  if (s_bottom_handle && lv_obj_is_valid(s_bottom_handle)) lv_obj_add_flag(s_bottom_handle, LV_OBJ_FLAG_HIDDEN);
  if (s_bottom_sheet && lv_obj_is_valid(s_bottom_sheet)) lv_obj_add_flag(s_bottom_sheet, LV_OBJ_FLAG_HIDDEN);
  if (g_bottom_sheet_open) {
    set_bottom_sheet_position(240);
    g_bottom_sheet_open = false;
  }
  screensaver_attach_activity(s_entry_hub);
}

static void show_bind_confirm_popup(const char* student_id, const char* student_name) {
  if (!student_id || !*student_id) return;
  if (s_bind_confirm_popup && lv_obj_is_valid(s_bind_confirm_popup)) return;
  s_pending_bind_student_id = student_id;
  s_pending_bind_student_name = (student_name && *student_name) ? String(student_name) : u8"학생";

  s_bind_confirm_popup = lv_obj_create(lv_scr_act());
  lv_obj_set_size(s_bind_confirm_popup, 276, 148);
  lv_obj_center(s_bind_confirm_popup);
  lv_obj_set_style_bg_color(s_bind_confirm_popup, lv_color_hex(0x202020), 0);
  lv_obj_set_style_bg_opa(s_bind_confirm_popup, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_bind_confirm_popup, 1, 0);
  lv_obj_set_style_border_color(s_bind_confirm_popup, lv_color_hex(0x3A3A3A), 0);
  lv_obj_set_style_radius(s_bind_confirm_popup, 14, 0);
  lv_obj_set_style_pad_all(s_bind_confirm_popup, 12, 0);
  lv_obj_set_style_pad_row(s_bind_confirm_popup, 10, 0);
  lv_obj_clear_flag(s_bind_confirm_popup, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_flex_flow(s_bind_confirm_popup, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_bind_confirm_popup, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

  lv_obj_t* msg = lv_label_create(s_bind_confirm_popup);
  lv_obj_set_width(msg, 248);
  lv_obj_set_style_text_align(msg, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_style_text_font(msg, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(msg, lv_color_hex(0xD0D0D0), 0);
  lv_label_set_long_mode(msg, LV_LABEL_LONG_WRAP);
  String message;
  message = s_pending_bind_student_name + u8" 학생으로 로그인할까요?";
  lv_label_set_text(msg, message.c_str());

  lv_obj_t* row = lv_obj_create(s_bind_confirm_popup);
  lv_obj_set_width(row, lv_pct(100));
  lv_obj_set_height(row, 50);
  lv_obj_set_style_bg_opa(row, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(row, 0, 0);
  lv_obj_set_style_pad_all(row, 0, 0);
  lv_obj_set_style_pad_column(row, 12, 0);
  lv_obj_set_scrollbar_mode(row, LV_SCROLLBAR_MODE_OFF);
  lv_obj_clear_flag(row, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(row, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

  lv_obj_t* cancel_btn = lv_btn_create(row);
  lv_obj_set_size(cancel_btn, 118, 40);
  lv_obj_set_style_radius(cancel_btn, 10, 0);
  lv_obj_set_style_bg_color(cancel_btn, lv_color_hex(0x323232), 0);
  lv_obj_set_style_border_width(cancel_btn, 0, 0);
  lv_obj_t* cancel_lbl = lv_label_create(cancel_btn);
  lv_obj_set_style_text_font(cancel_lbl, &kakao_kr_16, 0);
  lv_label_set_text(cancel_lbl, u8"취소");
  lv_obj_center(cancel_lbl);
  lv_obj_add_event_cb(cancel_btn, [](lv_event_t* e) {
    (void)e;
    close_bind_confirm_popup();
  }, LV_EVENT_CLICKED, NULL);

  lv_obj_t* confirm_btn = lv_btn_create(row);
  lv_obj_set_size(confirm_btn, 118, 40);
  lv_obj_set_style_radius(confirm_btn, 10, 0);
  lv_obj_set_style_bg_color(confirm_btn, lv_color_hex(0x1FA95B), 0);
  lv_obj_set_style_border_width(confirm_btn, 0, 0);
  lv_obj_t* confirm_lbl = lv_label_create(confirm_btn);
  lv_obj_set_style_text_font(confirm_lbl, &kakao_kr_16, 0);
  lv_label_set_text(confirm_lbl, u8"확인");
  lv_obj_center(confirm_lbl);
  lv_obj_add_event_cb(confirm_btn, [](lv_event_t* e) {
    (void)e;
    const String sid = s_pending_bind_student_id;
    const String name = s_pending_bind_student_name;
    close_bind_confirm_popup();
    if (sid.length() == 0) return;
    if (name.length() > 0) s_student_name_cache = name;
    fw_publish_bind(sid.c_str());
    build_homeworks_ui_internal();
    fw_publish_student_info(sid.c_str());
    show_entry_hub_overlay();
  }, LV_EVENT_CLICKED, NULL);

  screensaver_attach_activity(s_bind_confirm_popup);
}

static void build_student_list_ui() {
  create_base_container();
  close_bind_confirm_popup();
  if (s_entry_hub && lv_obj_is_valid(s_entry_hub)) { lv_obj_del(s_entry_hub); s_entry_hub = nullptr; s_entry_name_label = nullptr; }
  if (s_student_info_screen && lv_obj_is_valid(s_student_info_screen)) { lv_obj_del(s_student_info_screen); s_student_info_screen = nullptr; }
  if (s_bottom_handle && lv_obj_is_valid(s_bottom_handle)) { lv_obj_del(s_bottom_handle); s_bottom_handle = nullptr; }
  if (s_bottom_sheet && lv_obj_is_valid(s_bottom_sheet)) { lv_obj_del(s_bottom_sheet); s_bottom_sheet = nullptr; }
  if (s_fab && lv_obj_is_valid(s_fab)) { lv_obj_del(s_fab); s_fab = nullptr; }
  g_bottom_sheet_open = false;
  s_sheet_dragging = false;
  s_sheet_drag_moved = false;
  lv_obj_clean(s_stage);
  s_pages = nullptr;
  s_info_panel = nullptr;
  s_homeworks_mode = false;
  // student list only
  s_list = lv_obj_create(s_stage);
  lv_obj_set_size(s_list, lv_pct(100), lv_pct(100));
  lv_obj_align(s_list, LV_ALIGN_TOP_LEFT, 0, 0);
  lv_obj_set_style_bg_color(s_list, lv_color_hex(0x0B1112), 0);
  lv_obj_set_style_border_width(s_list, 0, 0);
  lv_obj_set_style_radius(s_list, 0, 0);
  lv_obj_set_style_pad_all(s_list, 4, 0);
  if (s_global_font) lv_obj_set_style_text_font(s_list, s_global_font, 0);
  lv_obj_set_flex_flow(s_list, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_START);
  lv_obj_set_style_pad_row(s_list, 8, 0);
  lv_obj_set_scroll_dir(s_list, LV_DIR_VER);
  lv_obj_set_scrollbar_mode(s_list, LV_SCROLLBAR_MODE_OFF);
  // 리스트 스크롤 이벤트를 화면보호기에 직접 부착
  lv_obj_add_flag(s_list, LV_OBJ_FLAG_EVENT_BUBBLE);
  // 스크롤 감지를 위한 직접 훅 (버블만으로는 부족할 수 있음)
  extern void screensaver_attach_activity(lv_obj_t* root);
  screensaver_attach_activity(s_list);
  // empty overlay centered (default visible)
  s_empty_overlay = lv_obj_create(s_stage);
  lv_obj_set_size(s_empty_overlay, lv_pct(100), lv_pct(100));
  lv_obj_set_style_bg_opa(s_empty_overlay, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(s_empty_overlay, 0, 0);
  s_empty_label = lv_label_create(s_empty_overlay);
  lv_obj_set_style_text_color(s_empty_label, lv_color_hex(0xA0A0A0), 0);
  lv_label_set_text(s_empty_label, u8"등원 예정 학생이 없습니다.");
  lv_obj_center(s_empty_label);
  lv_obj_add_flag(s_empty_overlay, LV_OBJ_FLAG_HIDDEN);
  LV_LOG_USER("empty_label created and text set");
  // Re-attach screensaver activity handlers
  screensaver_attach_activity(lv_scr_act());
  append_refresh_button();
}

static void build_homeworks_ui_internal() {
  create_base_container();
  close_bind_confirm_popup();
  if (s_entry_hub && lv_obj_is_valid(s_entry_hub)) { lv_obj_del(s_entry_hub); s_entry_hub = nullptr; s_entry_name_label = nullptr; }
  if (s_student_info_screen && lv_obj_is_valid(s_student_info_screen)) { lv_obj_del(s_student_info_screen); s_student_info_screen = nullptr; }
  if (s_bottom_handle && lv_obj_is_valid(s_bottom_handle)) { lv_obj_del(s_bottom_handle); s_bottom_handle = nullptr; }
  if (s_bottom_sheet && lv_obj_is_valid(s_bottom_sheet)) { lv_obj_del(s_bottom_sheet); s_bottom_sheet = nullptr; }
  if (s_fab && lv_obj_is_valid(s_fab)) { lv_obj_del(s_fab); s_fab = nullptr; }
  g_bottom_sheet_open = false;
  s_sheet_dragging = false;
  s_sheet_drag_moved = false;
  lv_obj_clean(s_stage);
  s_homeworks_mode = true;

  s_pages = lv_obj_create(s_stage);
  lv_obj_set_size(s_pages, 320, 240);
  lv_obj_set_style_bg_opa(s_pages, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(s_pages, 0, 0);
  lv_obj_set_style_radius(s_pages, 0, 0);
  lv_obj_set_style_pad_all(s_pages, 0, 0);
  lv_obj_set_scrollbar_mode(s_pages, LV_SCROLLBAR_MODE_OFF);
  lv_obj_clear_flag(s_pages, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(s_pages, LV_OBJ_FLAG_EVENT_BUBBLE);
  screensaver_attach_activity(s_pages);
  s_info_panel = nullptr;

  s_list = lv_obj_create(s_pages);
  lv_obj_set_size(s_list, lv_pct(100), lv_pct(100));
  lv_obj_set_style_bg_color(s_list, lv_color_hex(0x0B1112), 0);
  lv_obj_set_style_bg_opa(s_list, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_list, 0, 0);
  lv_obj_set_style_radius(s_list, 0, 0);
  lv_obj_set_style_pad_top(s_list, 8, 0);
  lv_obj_set_style_pad_left(s_list, 8, 0);
  lv_obj_set_style_pad_right(s_list, 8, 0);
  lv_obj_set_style_pad_bottom(s_list, 28, 0);
  lv_obj_set_flex_flow(s_list, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_START);
  lv_obj_set_style_pad_row(s_list, 12, 0);
  lv_obj_set_scroll_dir(s_list, LV_DIR_VER);
  lv_obj_set_scrollbar_mode(s_list, LV_SCROLLBAR_MODE_ACTIVE);
  lv_obj_add_flag(s_list, LV_OBJ_FLAG_EVENT_BUBBLE);
  screensaver_attach_activity(s_list);

  s_bottom_handle = lv_obj_create(s_stage);
  lv_obj_set_size(s_bottom_handle, 80, 18);
  lv_obj_set_pos(s_bottom_handle, 120, 220);
  lv_obj_set_style_bg_opa(s_bottom_handle, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(s_bottom_handle, 0, 0);
  lv_obj_set_style_radius(s_bottom_handle, 8, 0);
  lv_obj_set_style_pad_all(s_bottom_handle, 0, 0);
  lv_obj_set_scrollbar_mode(s_bottom_handle, LV_SCROLLBAR_MODE_OFF);
  lv_obj_clear_flag(s_bottom_handle, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_t* indicator = lv_obj_create(s_bottom_handle);
  lv_obj_set_size(indicator, 60, 5);
  lv_obj_set_style_bg_color(indicator, lv_color_hex(0xFFFFFF), 0);
  lv_obj_set_style_bg_opa(indicator, LV_OPA_30, 0);
  lv_obj_set_style_radius(indicator, 3, 0);
  lv_obj_set_style_border_width(indicator, 0, 0);
  lv_obj_align(indicator, LV_ALIGN_CENTER, 0, 0);
  lv_obj_add_event_cb(s_bottom_handle, [](lv_event_t* e){
    lv_event_code_t code = lv_event_get_code(e);
    if (code == LV_EVENT_CLICKED) {
      if (s_sheet_drag_moved) {
        s_sheet_drag_moved = false;
        return;
      }
      toggle_bottom_sheet();
    }
  }, LV_EVENT_CLICKED, NULL);
  lv_obj_add_event_cb(s_bottom_handle, bottom_sheet_drag_cb, LV_EVENT_PRESSED, NULL);
  lv_obj_add_event_cb(s_bottom_handle, bottom_sheet_drag_cb, LV_EVENT_PRESSING, NULL);
  lv_obj_add_event_cb(s_bottom_handle, bottom_sheet_drag_cb, LV_EVENT_RELEASED, NULL);
  lv_obj_add_event_cb(s_bottom_handle, bottom_sheet_drag_cb, LV_EVENT_PRESS_LOST, NULL);

  s_bottom_sheet = lv_obj_create(s_stage);
  lv_obj_set_size(s_bottom_sheet, 320, 100);
  lv_obj_set_pos(s_bottom_sheet, 0, 240);
  lv_obj_set_style_bg_color(s_bottom_sheet, lv_color_hex(0x1A1A1A), 0);
  lv_obj_set_style_bg_opa(s_bottom_sheet, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_bottom_sheet, 0, 0);
  lv_obj_set_style_radius(s_bottom_sheet, 0, 0);
  lv_obj_set_style_pad_all(s_bottom_sheet, 20, 0);
  lv_obj_set_flex_flow(s_bottom_sheet, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(s_bottom_sheet, LV_FLEX_ALIGN_SPACE_EVENLY, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_scrollbar_mode(s_bottom_sheet, LV_SCROLLBAR_MODE_OFF);
  lv_obj_clear_flag(s_bottom_sheet, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_clip_corner(s_bottom_sheet, true, 0);
  lv_obj_add_event_cb(s_bottom_sheet, bottom_sheet_drag_cb, LV_EVENT_PRESSED, NULL);
  lv_obj_add_event_cb(s_bottom_sheet, bottom_sheet_drag_cb, LV_EVENT_PRESSING, NULL);
  lv_obj_add_event_cb(s_bottom_sheet, bottom_sheet_drag_cb, LV_EVENT_RELEASED, NULL);
  lv_obj_add_event_cb(s_bottom_sheet, bottom_sheet_drag_cb, LV_EVENT_PRESS_LOST, NULL);

  lv_obj_t* pause_btn = lv_btn_create(s_bottom_sheet);
  lv_obj_set_size(pause_btn, 50, 50);
  lv_obj_set_style_radius(pause_btn, 10, 0);
  lv_obj_set_style_bg_opa(pause_btn, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(pause_btn, 0, 0);
  lv_obj_set_style_shadow_width(pause_btn, 0, 0);
  lv_obj_t* pause_lbl = lv_label_create(pause_btn);
  if (s_global_font) lv_obj_set_style_text_font(pause_lbl, s_global_font, 0);
  lv_obj_set_style_text_color(pause_lbl, lv_color_hex(0xC0C0C0), 0);
  lv_label_set_text(pause_lbl, u8"휴식");
  lv_obj_center(pause_lbl);
  lv_obj_add_event_cb(pause_btn, [](lv_event_t* e){ (void)e; fw_publish_pause_all(); }, LV_EVENT_CLICKED, NULL);

  // home button
  lv_obj_t* home_btn = lv_btn_create(s_bottom_sheet);
  lv_obj_set_size(home_btn, 50, 50);
  lv_obj_set_style_radius(home_btn, 10, 0);
  lv_obj_set_style_bg_opa(home_btn, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(home_btn, 0, 0);
  lv_obj_set_style_shadow_width(home_btn, 0, 0);
  // 왼쪽으로 3px 이동
  lv_obj_set_style_translate_x(home_btn, -3, 0);
  lv_obj_t* home_img = lv_img_create(home_btn);
  lv_img_set_src(home_img, &home_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
  lv_obj_set_style_img_recolor(home_img, lv_color_hex(0xC0C0C0), 0);
  lv_obj_set_style_img_recolor_opa(home_img, LV_OPA_COVER, 0);
  lv_img_set_zoom(home_img, 200);
  lv_obj_center(home_img);
  lv_obj_add_event_cb(home_btn, [](lv_event_t* e){ (void)e; show_entry_hub_overlay(); }, LV_EVENT_CLICKED, NULL);

  // settings button
  lv_obj_t* settings_btn = lv_btn_create(s_bottom_sheet);
  lv_obj_set_size(settings_btn, 50, 50);
  lv_obj_set_style_radius(settings_btn, 10, 0);
  lv_obj_set_style_bg_opa(settings_btn, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(settings_btn, 0, 0);
  lv_obj_set_style_shadow_width(settings_btn, 0, 0);
  lv_obj_t* set_img = lv_img_create(settings_btn);
  lv_img_set_src(set_img, &settings_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
  lv_obj_set_style_img_recolor(set_img, lv_color_hex(0xC0C0C0), 0);
  lv_obj_set_style_img_recolor_opa(set_img, LV_OPA_COVER, 0);
  lv_img_set_zoom(set_img, 200);
  lv_obj_center(set_img);
  lv_obj_add_event_cb(settings_btn, [](lv_event_t* e){ (void)e; ui_port_show_settings(FIRMWARE_VERSION); }, LV_EVENT_CLICKED, NULL);

  s_fab = nullptr;
  
  // Re-attach screensaver activity handlers
  screensaver_attach_activity(lv_scr_act());
}

void ui_port_init() { 
  // Load saved brightness/volume/student_id from LittleFS
  String savedStudentId = "";
  if (LittleFS.begin()) {
    File f = LittleFS.open("/brightness.txt", "r");
    if (f) {
      String val = f.readStringUntil('\n');
      s_current_brightness = val.toInt();
      if (s_current_brightness == 0) s_current_brightness = 128;
      M5.Display.setBrightness(s_current_brightness);
      Serial.printf("[INIT] Loaded brightness: %d\n", s_current_brightness);
      f.close();
    }
    f = LittleFS.open("/volume.txt", "r");
    if (f) {
      String val = f.readStringUntil('\n');
      s_current_volume = val.toInt();
      if (s_current_volume == 0) s_current_volume = 50;
      M5.Speaker.setVolume(s_current_volume);
      Serial.printf("[INIT] Loaded volume: %d\n", s_current_volume);
      f.close();
    }
    // 바인딩된 학생 ID 복원
    f = LittleFS.open("/student_id.txt", "r");
    if (f) {
      savedStudentId = f.readStringUntil('\n');
      savedStudentId.trim();
      f.close();
      Serial.printf("[INIT] Loaded student_id: %s\n", savedStudentId.c_str());
    }
    LittleFS.end();
  }
  
  // 바인딩된 학생이 있으면 과제 데이터를 준비하고 홈 허브부터 노출
  if (savedStudentId.length() > 0) {
    studentId = savedStudentId;
    build_homeworks_ui_internal();
    show_entry_hub_overlay();
    Serial.printf("[INIT] Starting in homework mode for student: %s\n", studentId.c_str());
    // MQTT 연결 후 student_info와 homeworks는 onMqttConnect에서 자동 요청됨
  } else {
    studentId = "";
    build_student_list_ui();
    Serial.println("[INIT] Starting in student list mode");
  }
}

void ui_port_set_global_font(const lv_font_t* font) {
  s_global_font = font;
  if (s_stage && lv_obj_is_valid(s_stage)) lv_obj_set_style_text_font(s_stage, s_global_font, 0);
}

void ui_before_screen_change(void) {
  // Called by screensaver before switching screens
  // Close any transient overlays or popups here
  if (g_bottom_sheet_open) {
    toggle_bottom_sheet();
  }
  close_bind_confirm_popup();
  close_student_info_screen(false);
  if (s_entry_hub && lv_obj_is_valid(s_entry_hub)) {
    lv_obj_add_flag(s_entry_hub, LV_OBJ_FLAG_HIDDEN);
  }
  close_volume_popup();
  close_brightness_popup();
}

static void volume_slider_cb(lv_event_t* e) {
  lv_obj_t* slider = lv_event_get_target(e);
  s_current_volume = (uint8_t)lv_slider_get_value(slider);
  Serial.printf("Volume: %d\n", s_current_volume);
  M5.Speaker.setVolume(s_current_volume);
  // Save to LittleFS
  if (LittleFS.begin()) {
    File f = LittleFS.open("/volume.txt", "w");
    if (f) { f.printf("%d", s_current_volume); f.close(); }
    LittleFS.end();
  }
}

static void brightness_slider_cb(lv_event_t* e) {
  lv_obj_t* slider = lv_event_get_target(e);
  s_current_brightness = (uint8_t)lv_slider_get_value(slider);
  Serial.printf("Brightness: %d\n", s_current_brightness);
  M5.Display.setBrightness(s_current_brightness);
  // Save to LittleFS
  if (LittleFS.begin()) {
    File f = LittleFS.open("/brightness.txt", "w");
    if (f) { f.printf("%d", s_current_brightness); f.close(); }
    LittleFS.end();
  }
}

static void close_volume_popup(void) {
  if (s_volume_popup) {
    lv_obj_del(s_volume_popup);
    s_volume_popup = nullptr;
  }
}

static void close_brightness_popup(void) {
  if (s_brightness_popup) {
    lv_obj_del(s_brightness_popup);
    s_brightness_popup = nullptr;
  }
}

static void ota_progress_callback(int percent, const char* status) {
  if (!s_ota_popup || !lv_obj_is_valid(s_ota_popup)) return;
  if (s_ota_progress_bar && lv_obj_is_valid(s_ota_progress_bar)) {
    lv_bar_set_value(s_ota_progress_bar, percent, LV_ANIM_ON);
  }
  if (s_ota_status_label && lv_obj_is_valid(s_ota_status_label)) {
    lv_label_set_text(s_ota_status_label, status);
  }
  lv_timer_handler(); // UI 즉시 갱신
}

static void show_ota_popup(void) {
  if (s_ota_popup) return;
  
  s_ota_popup = lv_obj_create(lv_scr_act());
  lv_obj_set_size(s_ota_popup, 280, 200);
  lv_obj_center(s_ota_popup);
  lv_obj_set_style_bg_color(s_ota_popup, lv_color_hex(0x1C1C1C), 0);
  lv_obj_set_style_bg_opa(s_ota_popup, LV_OPA_COVER, 0);
  lv_obj_set_style_border_color(s_ota_popup, lv_color_hex(0x404040), 0);
  lv_obj_set_style_border_width(s_ota_popup, 1, 0);
  lv_obj_set_style_radius(s_ota_popup, 12, 0);
  lv_obj_set_style_pad_all(s_ota_popup, 24, 0);
  lv_obj_clear_flag(s_ota_popup, LV_OBJ_FLAG_SCROLLABLE);
  
  lv_obj_t* title = lv_label_create(s_ota_popup);
  if (s_global_font) lv_obj_set_style_text_font(title, s_global_font, 0);
  lv_label_set_text(title, u8"펌웨어 업데이트");
  lv_obj_set_style_text_color(title, lv_color_white(), 0);
  lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 0);
  
  s_ota_status_label = lv_label_create(s_ota_popup);
  if (s_global_font) lv_obj_set_style_text_font(s_ota_status_label, s_global_font, 0);
  lv_label_set_text(s_ota_status_label, u8"확인 중...");
  lv_obj_set_style_text_color(s_ota_status_label, lv_color_hex(0xC0C0C0), 0);
  lv_obj_align(s_ota_status_label, LV_ALIGN_CENTER, 0, -20);
  
  s_ota_progress_bar = lv_bar_create(s_ota_popup);
  lv_obj_set_size(s_ota_progress_bar, 220, 12);
  lv_obj_set_style_bg_color(s_ota_progress_bar, lv_color_hex(0x2A2A2A), 0);
  lv_obj_set_style_bg_color(s_ota_progress_bar, lv_color_hex(0x1E88E5), LV_PART_INDICATOR);
  lv_obj_set_style_radius(s_ota_progress_bar, 6, 0);
  lv_bar_set_range(s_ota_progress_bar, 0, 100);
  lv_bar_set_value(s_ota_progress_bar, 0, LV_ANIM_OFF);
  lv_obj_align(s_ota_progress_bar, LV_ALIGN_CENTER, 0, 20);
}

static void close_ota_popup(void) {
  if (s_ota_popup) {
    lv_obj_del(s_ota_popup);
    s_ota_popup = nullptr;
    s_ota_progress_bar = nullptr;
    s_ota_status_label = nullptr;
  }
}

static void start_ota_update(void) {
  Serial.println("[OTA] User requested update check");
  show_ota_popup();
  
  String latestVersion, downloadUrl;
  bool updateAvailable = checkForUpdate(latestVersion, downloadUrl);
  
  if (!updateAvailable) {
    if (s_ota_status_label && lv_obj_is_valid(s_ota_status_label)) {
      lv_label_set_text_fmt(s_ota_status_label, u8"최신 버전입니다\n(v%s)", FIRMWARE_VERSION);
    }
    // 3초 후 자동 닫기
    lv_timer_t* close_timer = lv_timer_create([](lv_timer_t* t){ 
      close_ota_popup(); 
      lv_timer_del(t);
    }, 3000, NULL);
    lv_timer_set_repeat_count(close_timer, 1);
    return;
  }
  
  if (s_ota_status_label && lv_obj_is_valid(s_ota_status_label)) {
    lv_label_set_text_fmt(s_ota_status_label, u8"v%s → v%s", FIRMWARE_VERSION, latestVersion.c_str());
  }
  
  // OTA 업데이트 시작
  bool success = performOtaUpdate(downloadUrl, ota_progress_callback);
  if (!success) {
    if (s_ota_status_label && lv_obj_is_valid(s_ota_status_label)) {
      lv_label_set_text(s_ota_status_label, u8"업데이트 실패");
    }
    // 3초 후 자동 닫기
    lv_timer_t* close_timer = lv_timer_create([](lv_timer_t* t){ 
      close_ota_popup(); 
      lv_timer_del(t);
    }, 3000, NULL);
    lv_timer_set_repeat_count(close_timer, 1);
  }
  // 성공 시 자동 재부팅
}

static void show_brightness_popup(void) {
  if (s_brightness_popup) return;
  s_brightness_popup = lv_obj_create(lv_scr_act());
  lv_obj_set_size(s_brightness_popup, 280, 180);
  lv_obj_center(s_brightness_popup);
  screensaver_attach_activity(lv_scr_act());
  lv_obj_set_style_bg_color(s_brightness_popup, lv_color_hex(0x1C1C1C), 0);
  lv_obj_set_style_bg_opa(s_brightness_popup, LV_OPA_90, 0);
  lv_obj_set_style_border_color(s_brightness_popup, lv_color_hex(0x404040), 0);
  lv_obj_set_style_border_width(s_brightness_popup, 1, 0);
  lv_obj_set_style_radius(s_brightness_popup, 12, 0);
  lv_obj_set_style_pad_all(s_brightness_popup, 24, 0);
  lv_obj_set_flex_flow(s_brightness_popup, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_brightness_popup, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  
  lv_obj_t* title = lv_label_create(s_brightness_popup);
  lv_obj_set_style_text_color(title, lv_color_hex(0xFFFFFF), 0);
  if (s_global_font) lv_obj_set_style_text_font(title, s_global_font, 0);
  lv_label_set_text(title, u8"밝기 조절");
  
  lv_obj_t* slider = lv_slider_create(s_brightness_popup);
  lv_obj_set_width(slider, 230);
  lv_slider_set_range(slider, 0, 255);
  lv_slider_set_value(slider, s_current_brightness, LV_ANIM_OFF);
  lv_obj_add_event_cb(slider, brightness_slider_cb, LV_EVENT_VALUE_CHANGED, NULL);
  
  lv_obj_t* close_btn = lv_btn_create(s_brightness_popup);
  lv_obj_set_size(close_btn, 120, 40);
  lv_obj_set_style_radius(close_btn, 20, 0);
  lv_obj_set_style_bg_color(close_btn, lv_color_hex(0x444444), 0);
  lv_obj_t* cl = lv_label_create(close_btn);
  if (s_global_font) lv_obj_set_style_text_font(cl, s_global_font, 0);
  lv_label_set_text(cl, u8"닫기");
  lv_obj_center(cl);
  lv_obj_add_event_cb(close_btn, [](lv_event_t* e){ (void)e; close_brightness_popup(); }, LV_EVENT_CLICKED, NULL);
  lv_obj_add_event_cb(s_brightness_popup, [](lv_event_t* e){ 
    if (lv_event_get_code(e) == LV_EVENT_CLICKED && lv_event_get_target(e) == s_brightness_popup) close_brightness_popup();
  }, LV_EVENT_CLICKED, NULL);
}

static void update_battery_widget(void) {
  if (!s_battery_widget || !lv_obj_is_valid(s_battery_widget)) return;
  
  // M5.Power.getBatteryLevel() 0-100, isCharging()
  int level = M5.Power.getBatteryLevel();
  bool charging = M5.Power.isCharging();
  
  Serial.printf("[BAT] update: level=%d, charging=%d\n", level, charging ? 1 : 0);
  
  // Update percentage label (first child, index 0)
  if (s_battery_label && lv_obj_is_valid(s_battery_label)) {
    lv_label_set_text_fmt(s_battery_label, "%d%%", level);
  }
  
  // Get icon image (second child, index 1)
  lv_obj_t* bat_img = lv_obj_get_child(s_battery_widget, 1);
  if (!bat_img) {
    Serial.println("[BAT] ERROR: bat_img not found");
    return;
  }
  
  const lv_img_dsc_t* icon = nullptr;
  
  if (charging) {
    icon = &battery_android_bolt_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  } else if (level <= 1) {
    icon = &battery_android_alert_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  } else if (level <= 5) {
    icon = &battery_android_frame_1_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  } else if (level <= 20) {
    icon = &battery_android_frame_2_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  } else if (level <= 35) {
    icon = &battery_android_frame_3_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  } else if (level <= 50) {
    icon = &battery_android_frame_4_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  } else if (level <= 65) {
    icon = &battery_android_frame_5_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  } else if (level <= 80) {
    icon = &battery_android_frame_6_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  } else if (level <= 95) {
    icon = &battery_android_frame_full_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  } else {
    icon = &battery_android_frame_full_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  }
  
  lv_img_set_src(bat_img, icon);
  // ALPHA_8BIT 소스이므로 리컬러로 최종 색 지정 (밝은 회색)
  lv_obj_set_style_img_recolor(bat_img, lv_color_hex(0xC0C0C0), 0);
  lv_obj_set_style_img_recolor_opa(bat_img, LV_OPA_COVER, 0);
  Serial.println("[BAT] icon applied");
}

static void show_volume_popup(void) {
  if (s_volume_popup) return;
  s_volume_popup = lv_obj_create(lv_scr_act());
  lv_obj_set_size(s_volume_popup, 280, 180);
  lv_obj_center(s_volume_popup);
  screensaver_attach_activity(lv_scr_act());
  lv_obj_set_style_bg_color(s_volume_popup, lv_color_hex(0x1C1C1C), 0);
  lv_obj_set_style_bg_opa(s_volume_popup, LV_OPA_90, 0);
  lv_obj_set_style_border_color(s_volume_popup, lv_color_hex(0x404040), 0);
  lv_obj_set_style_border_width(s_volume_popup, 1, 0);
  lv_obj_set_style_radius(s_volume_popup, 12, 0);
  lv_obj_set_style_pad_all(s_volume_popup, 24, 0);
  lv_obj_set_flex_flow(s_volume_popup, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_volume_popup, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  
  lv_obj_t* title = lv_label_create(s_volume_popup);
  lv_obj_set_style_text_color(title, lv_color_hex(0xFFFFFF), 0);
  if (s_global_font) lv_obj_set_style_text_font(title, s_global_font, 0);
  lv_label_set_text(title, u8"음량 조절");
  
  lv_obj_t* slider = lv_slider_create(s_volume_popup);
  lv_obj_set_width(slider, 230);
  lv_slider_set_range(slider, 0, 100);
  lv_slider_set_value(slider, s_current_volume, LV_ANIM_OFF);
  lv_obj_add_event_cb(slider, volume_slider_cb, LV_EVENT_VALUE_CHANGED, NULL);
  
  lv_obj_t* close_btn = lv_btn_create(s_volume_popup);
  lv_obj_set_size(close_btn, 120, 40);
  lv_obj_set_style_radius(close_btn, 20, 0);
  lv_obj_set_style_bg_color(close_btn, lv_color_hex(0x444444), 0);
  lv_obj_t* cl = lv_label_create(close_btn);
  if (s_global_font) lv_obj_set_style_text_font(cl, s_global_font, 0);
  lv_label_set_text(cl, u8"닫기");
  lv_obj_center(cl);
  lv_obj_add_event_cb(close_btn, [](lv_event_t* e){ (void)e; close_volume_popup(); }, LV_EVENT_CLICKED, NULL);
  lv_obj_add_event_cb(s_volume_popup, [](lv_event_t* e){ 
    if (lv_event_get_code(e) == LV_EVENT_CLICKED && lv_event_get_target(e) == s_volume_popup) close_volume_popup();
  }, LV_EVENT_CLICKED, NULL);
}

void ui_port_update_students(const JsonArray& students) {
  if (!s_stage || !lv_obj_is_valid(s_stage)) build_student_list_ui();
  if (s_homeworks_mode) {
    // 학생 리스트 모드가 아니면 학생 목록 갱신은 무시
    return;
  }
  struct StudentBindData {
    char sid[64];
    char name[96];
  };
  lv_obj_clean(s_list);
  s_empty_label = nullptr;
  size_t count = 0;
  for (JsonObject _ : students) { (void)_; ++count; }
  if (s_empty_overlay) lv_obj_add_flag(s_empty_overlay, LV_OBJ_FLAG_HIDDEN);
  if (count == 0) {
    append_empty_message();
    append_refresh_button();
    return;
  }
  for (JsonObject s : students) {
    const char* name = s["name"] | s["student_name"] | u8"학생";
    const char* sid = s.containsKey("student_id") ? (const char*)s["student_id"] : (s.containsKey("id") ? (const char*)s["id"] : "");
    const char* school = s["school"] | "";
    int grade = s["grade"] | 0;
    lv_obj_t* card = lv_obj_create(s_list);
    lv_obj_set_width(card, lv_pct(100));
    lv_obj_set_height(card, 96);
    lv_obj_set_style_radius(card, 20, 0);
    lv_obj_set_style_bg_color(card, lv_color_hex(0x1A1A1A), 0);
    lv_obj_set_style_border_color(card, lv_color_hex(0x2C2C2C), 0);
    lv_obj_set_style_border_width(card, 1, 0);
    lv_obj_set_style_pad_all(card, 14, 0);
    lv_obj_set_style_pad_left(card, 21, 0);
    lv_obj_t* lbl = lv_label_create(card);
    lv_obj_set_style_text_color(lbl, lv_color_hex(0xE6E6E6), 0);
    if (s_global_font) lv_obj_set_style_text_font(lbl, s_global_font, 0);
    lv_label_set_text(lbl, name);
    lv_label_set_long_mode(lbl, LV_LABEL_LONG_DOT);
    lv_obj_set_width(lbl, 180);
    lv_obj_align(lbl, LV_ALIGN_LEFT_MID, 0, 0);
    String meta;
    if (school && *school) {
      meta += school;
    }
    if (grade > 0) {
      if (meta.length() > 0) meta += " ";
      meta += String(grade) + u8"학년";
    }
    if (meta.length() > 0) {
      lv_obj_t* meta_lbl = lv_label_create(card);
      lv_obj_set_style_text_color(meta_lbl, lv_color_hex(0xA0A0A0), 0);
      lv_obj_set_style_text_font(meta_lbl, &kakao_kr_16, 0);
      lv_label_set_text(meta_lbl, meta.c_str());
      lv_obj_align(meta_lbl, LV_ALIGN_RIGHT_MID, -6, 0);
    }
    if (sid && *sid) {
      StudentBindData* bind_data = (StudentBindData*)malloc(sizeof(StudentBindData));
      if (bind_data) {
        strncpy(bind_data->sid, sid, sizeof(bind_data->sid) - 1);
        bind_data->sid[sizeof(bind_data->sid) - 1] = '\0';
        strncpy(bind_data->name, name, sizeof(bind_data->name) - 1);
        bind_data->name[sizeof(bind_data->name) - 1] = '\0';
        lv_obj_add_event_cb(card, [](lv_event_t* e){
          StudentBindData* data = (StudentBindData*)lv_event_get_user_data(e);
          if (!data) return;
          show_bind_confirm_popup(data->sid, data->name);
        }, LV_EVENT_CLICKED, bind_data);
        lv_obj_add_event_cb(card, [](lv_event_t* e){
          if (lv_event_get_code(e) == LV_EVENT_DELETE) {
            void* ud = lv_event_get_user_data(e);
            if (ud) free(ud);
          }
        }, LV_EVENT_DELETE, bind_data);
      }
    }
  }
  append_refresh_button();
}

// Debounce: M5에서 연속 업데이트 시 충돌 방지 (500ms)
static uint32_t s_last_homework_update_ms = 0;
static const uint32_t HOMEWORK_UPDATE_DEBOUNCE_MS = 500;
// 카드 클릭 디바운스 (500ms)
static uint32_t s_last_card_click_ms = 0;
static const uint32_t CARD_CLICK_DEBOUNCE_MS = 500;

static void extract_book_name(const char* content, const char* title, const char* book_id, const char* grade_label, const char* hw_type, char* out, size_t out_sz) {
  out[0] = '\0';
  const char* marker = strstr(content, u8"교재:");
  if (!marker) marker = strstr(content, u8"교재: ");
  if (marker) {
    const char* start = marker + strlen(u8"교재:");
    while (*start == ' ') start++;
    const char* end = strchr(start, '\n');
    size_t len = end ? (size_t)(end - start) : strlen(start);
    if (len > out_sz-1) len = out_sz-1;
    memcpy(out, start, len); out[len] = '\0'; return;
  }
  if (*book_id && *grade_label) {
    const char* dot = strstr(title, u8"·");
    if (dot) {
      size_t len = (size_t)(dot - title);
      while (len > 0 && title[len-1] == ' ') len--;
      if (len > out_sz-1) len = out_sz-1;
      memcpy(out, title, len); out[len] = '\0'; return;
    }
  }
  if (*hw_type) { strncpy(out, hw_type, out_sz-1); out[out_sz-1] = '\0'; return; }
  strncpy(out, title, out_sz-1); out[out_sz-1] = '\0';
}

static void fmt_time_static(int secs, char* buf, size_t sz) {
  int h = secs / 3600; int m = (secs % 3600) / 60;
  if (h > 0) snprintf(buf, sz, "%dh %dm", h, m);
  else snprintf(buf, sz, "%dm", m);
}

static lv_obj_t* create_hw_card(lv_obj_t* parent, const char* book_name, int phase,
    const char* page, int count, int check_count, int accumulated,
    uint32_t srv_color, const char* itemId) {
  extern const lv_font_t kakao_kr_16;
  lv_obj_t* card = lv_obj_create(parent);
  lv_obj_set_width(card, lv_pct(100));
  lv_obj_set_height(card, 92);
  lv_obj_set_style_radius(card, 12, 0);
  lv_obj_set_style_bg_color(card, lv_color_hex(0x1A1A1A), 0);
  lv_obj_set_style_border_color(card, lv_color_hex(0x2C2C2C), 0);
  lv_obj_set_style_border_width(card, 1, 0);
  lv_obj_set_style_pad_top(card, 12, 0);
  lv_obj_set_style_pad_bottom(card, 12, 0);
  lv_obj_set_style_pad_left(card, 14, 0);
  lv_obj_set_style_pad_right(card, 14, 0);
  lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(card, LV_OBJ_FLAG_CLICKABLE);

  lv_obj_t* title_lbl = lv_label_create(card);
  if (s_global_font) lv_obj_set_style_text_font(title_lbl, s_global_font, 0);
  lv_obj_set_style_text_color(title_lbl, lv_color_hex(0xE6E6E6), 0);
  lv_label_set_text(title_lbl, book_name);
  lv_label_set_long_mode(title_lbl, LV_LABEL_LONG_DOT);
  lv_obj_set_width(title_lbl, lv_pct(65));
  lv_obj_align(title_lbl, LV_ALIGN_TOP_LEFT, 0, 0);
  lv_obj_add_flag(title_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);

  char page_count_buf[64] = {0};
  if (*page && count > 0) snprintf(page_count_buf, sizeof(page_count_buf), "%s · %d%s", page, count, u8"문항");
  else if (*page) snprintf(page_count_buf, sizeof(page_count_buf), "%s", page);
  else if (count > 0) snprintf(page_count_buf, sizeof(page_count_buf), "%d%s", count, u8"문항");

  if (phase == 1) {
    lv_obj_t* hint = lv_label_create(card);
    lv_obj_set_style_text_font(hint, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(hint, lv_color_hex(0x1FA95B), 0);
    lv_label_set_text(hint, u8"시작 >");
    lv_obj_align(hint, LV_ALIGN_TOP_RIGHT, 0, 4);
    lv_obj_add_flag(hint, LV_OBJ_FLAG_EVENT_BUBBLE);
    if (page_count_buf[0]) {
      lv_obj_t* pc_lbl = lv_label_create(card);
      lv_obj_set_style_text_font(pc_lbl, &kakao_kr_16, 0);
      lv_obj_set_style_text_color(pc_lbl, lv_color_hex(0x909090), 0);
      lv_label_set_text(pc_lbl, page_count_buf);
      lv_label_set_long_mode(pc_lbl, LV_LABEL_LONG_DOT);
      lv_obj_set_width(pc_lbl, lv_pct(60));
      lv_obj_align(pc_lbl, LV_ALIGN_TOP_LEFT, 0, 32);
      lv_obj_add_flag(pc_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
    }
    if (check_count > 0) {
      char chk_buf[32]; snprintf(chk_buf, sizeof(chk_buf), u8"검사 %d회", check_count);
      lv_obj_t* chk_lbl = lv_label_create(card);
      lv_obj_set_style_text_font(chk_lbl, &kakao_kr_16, 0);
      lv_obj_set_style_text_color(chk_lbl, lv_color_hex(0x707070), 0);
      lv_label_set_text(chk_lbl, chk_buf);
      lv_obj_align(chk_lbl, LV_ALIGN_TOP_RIGHT, 0, 32);
      lv_obj_add_flag(chk_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
    }
  } else if (phase == 2) {
    lv_obj_set_style_outline_color(card, lv_color_hex(srv_color), 0);
    lv_obj_set_style_outline_width(card, 2, 0);
    lv_obj_set_style_outline_pad(card, 0, 0);
    lv_obj_set_style_shadow_width(card, 10, 0);
    lv_obj_set_style_shadow_color(card, lv_color_hex(srv_color), 0);
    lv_obj_set_style_shadow_opa(card, LV_OPA_20, 0);
    char p2_buf[80] = {0};
    if (*page) snprintf(p2_buf, sizeof(p2_buf), "p %s", page);
    if (p2_buf[0] && count > 0) { char t[80]; snprintf(t, sizeof(t), "%s · %d%s", p2_buf, count, u8"문항"); strncpy(p2_buf, t, sizeof(p2_buf)-1); }
    else if (!p2_buf[0] && count > 0) snprintf(p2_buf, sizeof(p2_buf), "%d%s", count, u8"문항");
    if (p2_buf[0]) {
      lv_obj_t* pc = lv_label_create(card);
      lv_obj_set_style_text_font(pc, &kakao_kr_16, 0);
      lv_obj_set_style_text_color(pc, lv_color_hex(0x909090), 0);
      lv_label_set_text(pc, p2_buf);
      lv_label_set_long_mode(pc, LV_LABEL_LONG_DOT);
      lv_obj_set_width(pc, lv_pct(55));
      lv_obj_align(pc, LV_ALIGN_TOP_LEFT, 0, 32);
      lv_obj_add_flag(pc, LV_OBJ_FLAG_EVENT_BUBBLE);
    }
    lv_obj_t* time_lbl = lv_label_create(card);
    lv_obj_set_style_text_font(time_lbl, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(time_lbl, lv_color_hex(srv_color), 0);
    lv_obj_align(time_lbl, LV_ALIGN_TOP_RIGHT, 0, 32);
    lv_obj_add_flag(time_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
    char tb[32]; fmt_time_static(accumulated, tb, sizeof(tb));
    lv_label_set_text(time_lbl, tb);
    if (s_p2_cnt < 8) { s_p2_entries[s_p2_cnt] = {time_lbl, (uint32_t)accumulated, lv_tick_get()}; s_p2_cnt++; }
  } else if (phase == 3) {
    lv_obj_t* wh = lv_label_create(card);
    lv_obj_set_style_text_font(wh, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(wh, lv_color_hex(srv_color), 0);
    lv_label_set_text(wh, u8"채점중..");
    lv_obj_align(wh, LV_ALIGN_TOP_RIGHT, 0, 4);
    lv_obj_add_flag(wh, LV_OBJ_FLAG_EVENT_BUBBLE);
    if (accumulated > 0) {
      char tb[32]; fmt_time_static(accumulated, tb, sizeof(tb));
      lv_obj_t* tl = lv_label_create(card);
      lv_obj_set_style_text_font(tl, &kakao_kr_16, 0);
      lv_obj_set_style_text_color(tl, lv_color_hex(0x808080), 0);
      lv_label_set_text(tl, tb);
      lv_obj_align(tl, LV_ALIGN_TOP_LEFT, 0, 32);
      lv_obj_add_flag(tl, LV_OBJ_FLAG_EVENT_BUBBLE);
    }
  } else if (phase == 4) {
    lv_obj_set_style_bg_color(card, lv_color_hex(0x202020), 0);
    lv_obj_set_style_outline_color(card, lv_color_hex(srv_color), 0);
    lv_obj_set_style_outline_width(card, 3, 0);
    lv_obj_set_style_outline_pad(card, 0, 0);
    lv_obj_set_style_outline_opa(card, LV_OPA_TRANSP, 0);
    g_should_vibrate_phase4 = true;
    if (s_p4_cnt < 8) { s_p4_cards[s_p4_cnt] = card; s_p4_colors[s_p4_cnt] = srv_color; s_p4_cnt++; }
    lv_obj_t* h4 = lv_label_create(card);
    lv_obj_set_style_text_font(h4, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(h4, lv_color_hex(srv_color), 0);
    lv_label_set_text(h4, u8"확인 >");
    lv_obj_align(h4, LV_ALIGN_TOP_RIGHT, 0, 4);
    lv_obj_add_flag(h4, LV_OBJ_FLAG_EVENT_BUBBLE);
    if (*page) {
      lv_obj_t* pg = lv_label_create(card);
      lv_obj_set_style_text_font(pg, &kakao_kr_16, 0);
      lv_obj_set_style_text_color(pg, lv_color_hex(0x808080), 0);
      lv_label_set_text(pg, page);
      lv_obj_align(pg, LV_ALIGN_TOP_LEFT, 0, 32);
      lv_obj_add_flag(pg, LV_OBJ_FLAG_EVENT_BUBBLE);
    }
  }

  if (itemId && *itemId) {
    struct HwData { char id[64]; int phase; };
    HwData* d = (HwData*)malloc(sizeof(HwData));
    if (d) {
      strncpy(d->id, itemId, sizeof(d->id)-1); d->id[sizeof(d->id)-1] = '\0';
      d->phase = phase;
      lv_obj_add_event_cb(card, [](lv_event_t* e){
        uint32_t now = millis();
        if (now - s_last_card_click_ms < CARD_CLICK_DEBOUNCE_MS) return;
        s_last_card_click_ms = now;
        HwData* dd = (HwData*)lv_event_get_user_data(e);
        const char* act = nullptr;
        if (dd->phase == 1) act = "start";
        else if (dd->phase == 2) act = "submit";
        else if (dd->phase == 4) act = "wait";
        if (act) fw_publish_homework_action(act, dd->id);
      }, LV_EVENT_CLICKED, d);
      lv_obj_add_event_cb(card, [](lv_event_t* e){
        if (lv_event_get_code(e) == LV_EVENT_DELETE) { void* ud = lv_event_get_user_data(e); if (ud) free(ud); }
      }, LV_EVENT_DELETE, d);
    }
  }
  return card;
}

static void restart_hw_timer() {
  if (s_p2_cnt > 0 || s_p4_cnt > 0) {
    uint32_t interval = s_p4_cnt > 0 ? 100 : 1000;
    s_hw_global_timer = lv_timer_create(hw_global_timer_cb, interval, (void*)(uintptr_t)s_hw_timer_epoch);
    lv_timer_set_repeat_count(s_hw_global_timer, -1);
  }
}

void ui_port_update_homeworks(const JsonArray& items) {
  // Serial.printf("[HW] update items=%d\n", (int)items.size());
  uint32_t now = millis();
  if (now - s_last_homework_update_ms < HOMEWORK_UPDATE_DEBOUNCE_MS) {
    // debounced
    return;
  }
  s_last_homework_update_ms = now;

  if (!s_homeworks_mode) {
    build_homeworks_ui_internal();
  }
  if (!s_list || !lv_obj_is_valid(s_list)) { Serial.println("[HW] ERROR: s_list invalid"); return; }

  // Build new cache from incoming data
  HwCacheEntry new_cache[16];
  uint8_t new_cnt = 0;
  for (JsonObject it : items) {
    if (new_cnt >= 16) break;
    const char* iid = it.containsKey("item_id") ? (const char*)it["item_id"] : "";
    int ph = it.containsKey("phase") ? (int)it["phase"] : 1;
    int acc = it.containsKey("accumulated") ? (int)it["accumulated"] : 0;
    strncpy(new_cache[new_cnt].id, iid, 63); new_cache[new_cnt].id[63] = '\0';
    new_cache[new_cnt].phase = ph;
    new_cache[new_cnt].acc = acc;
    new_cnt++;
  }

  // Diff: find which indices changed
  bool need_full = (new_cnt != s_hw_cache_cnt);
  uint8_t changed[16]; uint8_t changed_cnt = 0;
  if (!need_full) {
    for (uint8_t i = 0; i < new_cnt; i++) {
      if (strcmp(new_cache[i].id, s_hw_cache[i].id) != 0) { need_full = true; break; }
      if (new_cache[i].phase != s_hw_cache[i].phase) {
        if (changed_cnt < 16) changed[changed_cnt++] = i;
      }
    }
  }

  if (!need_full && changed_cnt == 0) {
    // no changes
    return;
  }

  // Invalidate old timer
  s_hw_timer_epoch++;
  s_p2_cnt = 0; s_p4_cnt = 0; s_p4_breath_step = 0;
  s_hw_global_timer = nullptr;
  g_should_vibrate_phase4 = false;

  if (need_full) {
    // full rebuild
    lv_obj_add_flag(s_list, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clean(s_list);

    uint8_t idx = 0;
    for (JsonObject it : items) {
      const char* title = it["title"] | it["name"] | u8"과제";
      const char* itemId = it.containsKey("item_id") ? (const char*)it["item_id"] : "";
      int phase = it.containsKey("phase") ? (int)it["phase"] : 1;
      const char* page = it["page"] | "";
      int count = it.containsKey("count") ? (int)it["count"] : 0;
      int check_count = it.containsKey("check_count") ? (int)it["check_count"] : 0;
      int accumulated = it.containsKey("accumulated") ? (int)it["accumulated"] : 0;
      const char* content = it["content"] | "";
      const char* hw_type = it["type"] | "";
      const char* book_id = it["book_id"] | "";
      const char* grade_label = it["grade_label"] | "";
      uint32_t srv_color = 0x1E88E5;
      if (it.containsKey("color")) { double v = it["color"]; if (v > 0) srv_color = ((uint32_t)v) & 0xFFFFFFu; }
      char bn[128]; extract_book_name(content, title, book_id, grade_label, hw_type, bn, sizeof(bn));
      if (!bn[0]) strncpy(bn, title, sizeof(bn)-1);
      // card created
      create_hw_card(s_list, bn, phase, page, count, check_count, accumulated, srv_color, itemId);
      idx++;
      yield();
    }
    lv_obj_clear_flag(s_list, LV_OBJ_FLAG_HIDDEN);
  } else {
    // partial update
    // Re-scan all cards to rebuild p2/p4 arrays for unchanged cards
    uint8_t idx = 0;
    uint8_t ci = 0;
    for (JsonObject it : items) {
      bool is_changed = (ci < changed_cnt && changed[ci] == idx);
      if (is_changed) ci++;

      const char* title = it["title"] | it["name"] | u8"과제";
      const char* itemId = it.containsKey("item_id") ? (const char*)it["item_id"] : "";
      int phase = it.containsKey("phase") ? (int)it["phase"] : 1;
      const char* page = it["page"] | "";
      int count = it.containsKey("count") ? (int)it["count"] : 0;
      int check_count = it.containsKey("check_count") ? (int)it["check_count"] : 0;
      int accumulated = it.containsKey("accumulated") ? (int)it["accumulated"] : 0;
      const char* content = it["content"] | "";
      const char* hw_type = it["type"] | "";
      const char* book_id = it["book_id"] | "";
      const char* grade_label = it["grade_label"] | "";
      uint32_t srv_color = 0x1E88E5;
      if (it.containsKey("color")) { double v = it["color"]; if (v > 0) srv_color = ((uint32_t)v) & 0xFFFFFFu; }

      if (is_changed) {
        lv_obj_t* old_card = lv_obj_get_child(s_list, idx);
        if (old_card && lv_obj_is_valid(old_card)) lv_obj_del(old_card);
        char bn[128]; extract_book_name(content, title, book_id, grade_label, hw_type, bn, sizeof(bn));
        if (!bn[0]) strncpy(bn, title, sizeof(bn)-1);
        // card updated
        lv_obj_t* nc = create_hw_card(s_list, bn, phase, page, count, check_count, accumulated, srv_color, itemId);
        lv_obj_move_to_index(nc, idx);
      } else {
        // unchanged card - but still register p2/p4 if applicable
        lv_obj_t* card = lv_obj_get_child(s_list, idx);
        if (phase == 4 && card && lv_obj_is_valid(card) && s_p4_cnt < 8) {
          s_p4_cards[s_p4_cnt] = card; s_p4_colors[s_p4_cnt] = srv_color; s_p4_cnt++;
          g_should_vibrate_phase4 = true;
        }
      }
      idx++;
    }
  }

  memcpy(s_hw_cache, new_cache, sizeof(HwCacheEntry) * new_cnt);
  s_hw_cache_cnt = new_cnt;
  restart_hw_timer();
  // update done
}

void ui_port_update_student_info(const JsonObject& info) {
  if (!s_homeworks_mode) {
    build_homeworks_ui_internal();
  }
  const char* name = info["name"] | u8"학생";
  const char* school = info["school"] | "";
  const int grade = info.containsKey("grade") ? (int)info["grade"] : -1;
  s_student_name_cache = name;
  s_student_school_cache = school;
  s_student_grade_cache = grade;

  if (s_info_panel && lv_obj_is_valid(s_info_panel)) {
    populate_student_info_container(s_info_panel, false);
  }
  if (s_entry_name_label && lv_obj_is_valid(s_entry_name_label)) {
    lv_label_set_text(s_entry_name_label, s_student_name_cache.c_str());
  }
  if (s_student_info_screen && lv_obj_is_valid(s_student_info_screen)) {
    populate_student_info_container(s_student_info_screen, true);
  }
}

void ui_port_show_settings(const char* appVersion) {
  if (g_bottom_sheet_open) toggle_bottom_sheet();
  if (!s_settings_scr) {
    s_settings_scr = lv_obj_create(lv_scr_act());
    lv_obj_set_size(s_settings_scr, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_color(s_settings_scr, lv_color_hex(0x0F0F0F), 0);
    lv_obj_set_style_border_width(s_settings_scr, 0, 0);
    lv_obj_set_style_pad_all(s_settings_scr, 0, 0);
    
    // Battery widget container (top-right)
    s_battery_widget = lv_obj_create(s_settings_scr);
    lv_obj_set_size(s_battery_widget, 80, 32);
    lv_obj_set_style_bg_opa(s_battery_widget, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_battery_widget, 0, 0);
    lv_obj_set_style_pad_all(s_battery_widget, 0, 0);
    lv_obj_set_flex_flow(s_battery_widget, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(s_battery_widget, LV_FLEX_ALIGN_END, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_align(s_battery_widget, LV_ALIGN_TOP_RIGHT, -10, 20);
    
    // Battery percentage label (left, small font)
    s_battery_label = lv_label_create(s_battery_widget);
    lv_label_set_text(s_battery_label, "100%");
    lv_obj_set_style_text_color(s_battery_label, lv_color_hex(0xC0C0C0), 0);
    lv_obj_set_style_text_font(s_battery_label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_pad_right(s_battery_label, 2, 0);
    
    // Battery icon (right)
    lv_obj_t* bat_img = lv_img_create(s_battery_widget);
    lv_img_set_src(bat_img, &battery_android_frame_full_32dp_999999_FILL0_wght400_GRAD0_opsz40);
    Serial.println("[BAT] created, set initial full icon");
    // ALPHA_8BIT 소스 → 밝은 회색으로 리컬러하여 채움
    lv_obj_set_style_img_recolor(bat_img, lv_color_hex(0xC0C0C0), 0);
    lv_obj_set_style_img_recolor_opa(bat_img, LV_OPA_COVER, 0);
    
    // Title
    lv_obj_t* title = lv_label_create(s_settings_scr);
    if (s_global_font) lv_obj_set_style_text_font(title, s_global_font, 0);
    lv_label_set_text(title, u8"설정");
    lv_obj_set_style_text_color(title, lv_color_white(), 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 24);
    // Version
    if (appVersion) {
      lv_obj_t* ver = lv_label_create(s_settings_scr);
      if (s_global_font) lv_obj_set_style_text_font(ver, s_global_font, 0);
      lv_label_set_text_fmt(ver, u8"버전: %s", appVersion);
      lv_obj_set_style_text_color(ver, lv_color_hex(0x999999), 0);
      lv_obj_align(ver, LV_ALIGN_TOP_MID, 0, 64);
    }
    lv_obj_t* vol_settings_btn = lv_btn_create(s_settings_scr);
    lv_obj_set_size(vol_settings_btn, 51, 51);
    lv_obj_set_style_radius(vol_settings_btn, 26, 0);
    lv_obj_set_style_bg_color(vol_settings_btn, lv_color_hex(0x1E1E1E), 0);
    lv_obj_set_style_border_width(vol_settings_btn, 0, 0);
    lv_obj_set_style_shadow_width(vol_settings_btn, 0, 0);
    lv_obj_align(vol_settings_btn, LV_ALIGN_CENTER, -70, 5);
    lv_obj_t* vol_settings_img = lv_img_create(vol_settings_btn);
    lv_img_set_src(vol_settings_img, &volume_mute_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
    lv_obj_set_style_img_recolor(vol_settings_img, lv_color_hex(0xE3E3E3), 0);
    lv_obj_set_style_img_recolor_opa(vol_settings_img, LV_OPA_COVER, 0);
    lv_img_set_zoom(vol_settings_img, 180);
    lv_obj_center(vol_settings_img);
    lv_obj_add_event_cb(vol_settings_btn, [](lv_event_t* e){ (void)e; show_volume_popup(); }, LV_EVENT_CLICKED, NULL);
    // Brightness button (icon, center)
    lv_obj_t* bright_btn = lv_btn_create(s_settings_scr);
    lv_obj_set_size(bright_btn, 51, 51);
    lv_obj_set_style_radius(bright_btn, 26, 0);
    lv_obj_set_style_bg_color(bright_btn, lv_color_hex(0x1E1E1E), 0);
    lv_obj_set_style_border_width(bright_btn, 0, 0);
    lv_obj_set_style_shadow_width(bright_btn, 0, 0);
    lv_obj_align(bright_btn, LV_ALIGN_CENTER, 0, 5);
    lv_obj_t* bright_img = lv_img_create(bright_btn);
    lv_img_set_src(bright_img, &light_mode_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
    lv_obj_set_style_img_recolor(bright_img, lv_color_hex(0xE3E3E3), 0);
    lv_obj_set_style_img_recolor_opa(bright_img, LV_OPA_COVER, 0);
    lv_img_set_zoom(bright_img, 180);
    lv_obj_center(bright_img);
    lv_obj_add_event_cb(bright_btn, [](lv_event_t* e){ (void)e; show_brightness_popup(); }, LV_EVENT_CLICKED, NULL);
    // Update button (icon)
    lv_obj_t* ref_btn = lv_btn_create(s_settings_scr);
    lv_obj_set_size(ref_btn, 51, 51);
    lv_obj_set_style_radius(ref_btn, 26, 0);
    lv_obj_set_style_bg_color(ref_btn, lv_color_hex(0x1E1E1E), 0);
    lv_obj_set_style_border_width(ref_btn, 0, 0);
    lv_obj_set_style_shadow_width(ref_btn, 0, 0);
    lv_obj_align(ref_btn, LV_ALIGN_CENTER, 70, 5);
    lv_obj_t* upd_img = lv_img_create(ref_btn);
    lv_img_set_src(upd_img, &update_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
    lv_obj_set_style_img_recolor(upd_img, lv_color_hex(0xE3E3E3), 0);
    lv_obj_set_style_img_recolor_opa(upd_img, LV_OPA_COVER, 0);
    lv_img_set_zoom(upd_img, 180);
    lv_obj_center(upd_img);
    lv_obj_add_event_cb(ref_btn, [](lv_event_t* e){ (void)e; start_ota_update(); }, LV_EVENT_CLICKED, NULL);
    // Close button
    lv_obj_t* close_btn = lv_btn_create(s_settings_scr);
    lv_obj_set_size(close_btn, 200, 44);
    lv_obj_set_style_radius(close_btn, 22, 0);
    lv_obj_set_style_bg_color(close_btn, lv_color_hex(0x333333), 0);
    lv_obj_set_style_border_width(close_btn, 0, 0);
    lv_obj_align(close_btn, LV_ALIGN_BOTTOM_MID, 0, -24);
    lv_obj_t* cl = lv_label_create(close_btn);
    if (s_global_font) lv_obj_set_style_text_font(cl, s_global_font, 0);
    lv_label_set_text(cl, u8"닫기");
    lv_obj_center(cl);
    lv_obj_add_event_cb(close_btn, [](lv_event_t* e){ (void)e; if (s_settings_scr) lv_obj_add_flag(s_settings_scr, LV_OBJ_FLAG_HIDDEN); }, LV_EVENT_CLICKED, NULL);
  }
  lv_obj_clear_flag(s_settings_scr, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(s_settings_scr);
  screensaver_attach_activity(lv_scr_act());
  update_battery_widget();
}


