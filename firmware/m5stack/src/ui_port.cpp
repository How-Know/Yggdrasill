#include "ui_port.h"
#include <M5Unified.h>
#include <lvgl.h>
#include "screensaver.h"
#include <LittleFS.h>
#include <cstring>
#include <cctype>
#include <ctime>
#include "ota_update.h"
#include "version.h"
#include <esp_task_wdt.h>

// main.cpp에 정의된 전역 변수 (바인딩 추적용)
extern String studentId;
// Small bitmap font for meta text (school/grade)
extern const lv_font_t kakao_kr_16;
extern const lv_font_t kakao_kr_24;

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
LV_IMG_DECLARE(format_list_bulleted_90dp_999999_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(timer_90dp_999999_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(info_i_90dp_999999_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(bottom_sheet_question_64);
LV_IMG_DECLARE(bottom_sheet_add_64);
LV_IMG_DECLARE(settings_90dp_999999_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(pause_circle_90dp_999999_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(play_arrow_100dp_999999_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(stop_100dp_999999_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(lists_100dp_999999_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(check_100dp_999999_FILL0_wght400_GRAD0_opsz48);

struct ConfirmToWaitCtx;

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
static lv_obj_t* s_raise_question_confirm_popup = nullptr;
static lv_obj_t* s_test_start_confirm_popup = nullptr;
static int s_test_start_popup_group_idx = -1;
static lv_obj_t* s_test_abort_confirm_popup = nullptr;
static lv_obj_t* s_confirm_to_wait_popup = nullptr;
static ConfirmToWaitCtx* s_confirm_to_wait_ctx = nullptr;
static lv_obj_t* s_entry_hub = nullptr;
static lv_obj_t* s_entry_name_label = nullptr;
static lv_obj_t* s_hub_clock_label = nullptr;
static lv_obj_t* s_hub_battery_widget = nullptr;
static lv_obj_t* s_hub_battery_label = nullptr;
static lv_timer_t* s_hub_clock_timer = nullptr;
static lv_obj_t* s_student_info_screen = nullptr;
static lv_obj_t* s_stopwatch_screen = nullptr;
static lv_obj_t* s_sw_time_label = nullptr;
static lv_obj_t* s_sw_digits[8] = {}; // min10 min1 : sec10 sec1 . cs10 cs1
static lv_obj_t* s_sw_left_btn = nullptr;
static lv_obj_t* s_sw_right_btn = nullptr;
static lv_obj_t* s_sw_left_lbl = nullptr;
static lv_obj_t* s_sw_right_lbl = nullptr;
static lv_obj_t* s_sw_lap_list = nullptr;
static lv_timer_t* s_sw_timer = nullptr;
static uint32_t s_sw_start_tick = 0;
static uint32_t s_sw_elapsed_ms = 0;
static bool s_sw_running = false;
static int s_sw_lap_count = 0;
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
static bool s_screensaver_hid_student_info = false;
static bool s_screensaver_hid_stopwatch = false;
static String s_student_name_cache = u8"학생";
static String s_student_school_cache = "";
static int s_student_grade_cache = -1;
static bool s_sheet_dragging = false;
static bool s_sheet_drag_moved = false;
static lv_coord_t s_drag_start_touch_y = 0;
static lv_coord_t s_drag_start_sheet_y = 240;

// 이전 과제 상태 캐시 (diff 기반 업데이트)
// phase만 보면 누적시간·문항수·제목/요약 변경 시 카드가 갱신되지 않아 앱과 어긋날 수 있음 → 1단계: 수치·주요 문자열까지 비교
struct HwCacheEntry {
  char id[64];
  int8_t phase;
  int64_t run_start_epoch;
  int32_t accumulated;
  int32_t cycle_elapsed;
  int16_t check_count;
  int16_t total_count;
  int16_t time_limit_minutes;
  char group_title[40];
  char page_summary[32];
  char book_name[64];
  char m5_wait_title[128];
  char item_type[24];
  uint32_t children_fp;
};
static HwCacheEntry s_hw_cache[16];
static uint8_t s_hw_cache_cnt = 0;

static void hw_invalidate_cache(void) {
  s_hw_cache_cnt = 0;
  memset(s_hw_cache, 0, sizeof(s_hw_cache));
}
static volatile bool s_hw_updating = false;
static bool s_hw_refresh_pending = false;

// 그룹 과제 children 메모리 저장 (상세 페이지용)
struct HwChildEntry {
  char item_id[40];
  char title[32];
  char page[16];
  char memo[64];
  int16_t count;
  int16_t check_count;
  int8_t phase;
  int32_t accumulated;
};
struct ConfirmToWaitCtx {
  char group_id[40];
};

struct HwGroupData {
  char group_id[40];
  char group_title[40];
  char book_name[64];
  char m5_wait_title[128];
  char page_summary[32];
  char item_type[24];
  int8_t phase; int32_t accumulated; int32_t cycle_elapsed; int16_t check_count; int16_t total_count;
  int16_t time_limit_minutes;
  uint32_t color;
  int64_t run_start_epoch;
  /** 서버 run_start 기준 1회 정렬 + lv_tick 모노토닉 표시용 (목록/상세 공통) */
  bool display_anchor_valid;
  int64_t display_anchor_run_start;
  uint32_t display_anchor_tick;
  int32_t display_segment0_sec;
  HwChildEntry children[8];
  uint8_t child_cnt;
};

static inline bool hw_is_test_group(const HwGroupData& g) {
  return strcmp(g.item_type, u8"테스트") == 0;
}

// 그룹 내 자식 항목 변화(페이즈·문항·누적 등)까지 need_full 에 반영
static uint32_t hw_group_children_fp(const HwGroupData& g) {
  uint32_t h = 5381u;
  for (uint8_t i = 0; i < g.child_cnt; i++) {
    const HwChildEntry& c = g.children[i];
    for (const char* p = c.item_id; *p; ++p) h = ((h << 5) + h) + (uint8_t)*p;
    h = ((h << 5) + h) + (uint8_t)c.phase;
    h = ((h << 5) + h) + (uint16_t)c.count;
    h = ((h << 5) + h) + (uint16_t)c.check_count;
    h = ((h << 5) + h) + (uint32_t)c.accumulated;
  }
  h = ((h << 5) + h) + (uint8_t)g.child_cnt;
  return h;
}

static inline bool hw_server_running_group(const HwGroupData& g) {
  return g.phase == 2 && g.run_start_epoch > 0;
}

static int hw_live_segment_sec(HwGroupData& g, uint32_t now_tick) {
  if (!g.display_anchor_valid || !hw_server_running_group(g)) return 0;
  if (g.display_anchor_run_start > 0 &&
      g.run_start_epoch > 0 &&
      g.display_anchor_run_start != g.run_start_epoch) {
    return 0;
  }
  uint32_t dt = now_tick - g.display_anchor_tick;
  int delta = (int)(dt / 1000);
  int seg = g.display_segment0_sec + delta;
  if (seg < 0) seg = 0;
  return seg;
}

static HwGroupData s_groups[6];
static uint8_t s_group_cnt = 0;
struct ChildCheckCacheEntry {
  bool used;
  bool checked;
  char item_id[40];
};
static ChildCheckCacheEntry s_child_check_cache[64];
struct ChildCheckCtx {
  char item_id[40];
  lv_obj_t* box;
  lv_obj_t* mark;
  lv_coord_t press_x;
  lv_coord_t press_y;
  bool dragged;
};

// 상세 페이지
static lv_obj_t* s_hw_detail_screen = nullptr;
// Monospaced per-glyph slots for the cycle/total time so digit-width
// differences (e.g. "1" vs "5" in kakao_kr_16) cannot shift neighbors.
// Layout: HH:MM:SS  → 10 slots (8 digits + 2 colons).
static lv_obj_t* s_hw_detail_session_slots[10] = {0};
static lv_obj_t* s_hw_detail_total_slots[10] = {0};
static lv_obj_t* s_hw_detail_session_lbl = nullptr; // = session_slots[0]
static lv_obj_t* s_hw_detail_total_lbl = nullptr;   // = total_slots[0]
static lv_obj_t* s_hw_detail_play_img = nullptr;
static lv_obj_t* s_hw_detail_play_btn = nullptr;
static lv_obj_t* s_hw_list_screen = nullptr;
static int s_detail_group_idx = -1;
static bool s_detail_playing = false;
static bool s_detail_cycle_running = false;
static int32_t s_detail_cycle_base_acc = 0;
static uint32_t s_detail_local_run_start_tick = 0;
static int32_t s_detail_cycle_frozen_sec = 0;
static int32_t s_detail_total_frozen_sec = 0;
// Local-watch baselines: cycle/total seconds at the last pause or at page open.
// While running, live value = baseline + (lv_tick_get() - run_start_tick)/1000.
// Only phase=3 (submit) resets cycle baseline; total baseline never resets
// within a single detail-page session.
static int32_t s_detail_cycle_baseline_sec = 0;
static int32_t s_detail_total_baseline_sec = 0;
static uint32_t s_detail_run_start_tick = 0;
static int8_t s_detail_last_phase_seen = -1;
static uint32_t s_detail_manual_override_until_ms = 0;
static bool s_detail_manual_override_playing = false;
static lv_timer_t* s_detail_timer = nullptr;
static uint32_t s_detail_timer_epoch = 0;

// Phase 2 실시간 시간 & Phase 4 깜빡임: 글로벌 단일 타이머로 관리
struct Phase2Entry { lv_obj_t* lbl; uint8_t group_idx; };
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

static void fmt_time_static(int secs, char* buf, size_t sz);
static void fmt_time_hms(int secs, char* buf, size_t sz);

static void hw_global_timer_cb(lv_timer_t* timer) {
  uint32_t epoch = (uint32_t)(uintptr_t)timer->user_data;
  if (epoch != s_hw_timer_epoch) { lv_timer_del(timer); return; }

  static uint8_t sec_tick = 0;
  sec_tick++;
  if (sec_tick >= 10) {
    sec_tick = 0;
    for (uint8_t i = 0; i < s_p2_cnt; i++) {
      if (!s_p2_entries[i].lbl || !lv_obj_is_valid(s_p2_entries[i].lbl)) continue;
      uint8_t gi = s_p2_entries[i].group_idx;
      if (gi >= s_group_cnt) continue;
      HwGroupData& gg = s_groups[gi];
      uint32_t tick = lv_tick_get();
      int seg = hw_live_segment_sec(gg, tick);
      int total = (int)gg.accumulated + seg;
      if (total < 0) total = 0;
      char buf[32]; fmt_time_static((uint32_t)total, buf, sizeof(buf));
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

static lv_obj_t* s_snackbar = nullptr;
static lv_obj_t* s_snackbar_lbl = nullptr;
static lv_obj_t* s_snackbar_dot = nullptr;
static uint8_t s_snackbar_type = 0;
static int8_t s_first_p4_card_idx = -1;
static bool s_rest_mode = false;
static bool s_phase4_alarm_muted = false;
static uint8_t s_prev_p4_count = 0;
static uint32_t s_snackbar_click_enable_after_ms = 0;
static uint32_t s_tap_suppress_until_ms = 0;
static lv_obj_t* s_hw_add_menu_screen = nullptr;
static char s_pending_detail_group_id[40] = "";
static bool s_screensaver_hid_hw_add_menu = false;
static const uint32_t SCROLL_TAP_SUPPRESS_MS = 180;
static const lv_coord_t TAP_MOVE_SLOP_PX = 8;
static lv_coord_t s_question_btn_press_x = 0;
static lv_coord_t s_question_btn_press_y = 0;
static bool s_question_btn_dragged = false;

static inline void suppress_tap_temporarily(uint32_t ms = SCROLL_TAP_SUPPRESS_MS) {
  uint32_t until = millis() + ms;
  if ((int32_t)(until - s_tap_suppress_until_ms) > 0) s_tap_suppress_until_ms = until;
}

static inline bool is_tap_suppressed(void) {
  return millis() < s_tap_suppress_until_ms;
}

static void list_scroll_activity_cb(lv_event_t* e) {
  lv_event_code_t code = lv_event_get_code(e);
  if (code == LV_EVENT_SCROLL_BEGIN || code == LV_EVENT_SCROLL_END) {
    suppress_tap_temporarily();
  }
}

static void show_volume_popup(void);
static void close_volume_popup(void);
static void show_brightness_popup(void);
static void close_brightness_popup(void);
static void close_bind_confirm_popup(void);
static void close_raise_question_confirm_popup(void);
static void close_test_start_confirm_popup(void);
static void close_test_abort_confirm_popup(void);
static void close_confirm_to_wait_popup(void);
static void show_raise_question_confirm_popup(void);
static void show_test_start_confirm_popup(int group_idx);
static void show_test_abort_confirm_popup(void);
static bool detail_test_effective_running(const HwGroupData& g);
static void update_detail_play_button_visual(void);
static void close_homework_detail_page(void);
static void show_homework_detail_page(int group_idx);
static void show_confirm_phase_to_waiting_popup(const char* group_id, int group_idx);
static void show_entry_hub_overlay(void);
static void close_student_info_screen(bool show_entry_hub);
static void show_student_info_screen(void);
static void show_stopwatch_screen(void);
static void close_stopwatch_screen(bool show_hub);
static void show_bind_confirm_popup(const char* student_id, const char* student_name);
static void populate_student_info_container(lv_obj_t* target, bool include_back_header);
static void build_homeworks_ui_internal(void);
static void show_homework_child_list_page(int group_idx);
static void close_homework_child_list_page(bool animated);
static void bottom_sheet_drag_cb(lv_event_t* e);
static void update_battery_widget(void);
static void update_hub_battery(void);
static void hub_clock_timer_cb(lv_timer_t* timer);
static void hide_snackbar(void);
static void show_hw_add_menu_page(void);
static void close_hw_add_menu_page(void);
static void close_hw_add_menu_page_animated(void);
static void ui_port_try_open_pending_homework_detail(void);
static void snackbar_clicked_cb(lv_event_t* e) {
  (void)e;
  if (s_snackbar_type == 1) {
    uint32_t now = millis();
    if (now < s_snackbar_click_enable_after_ms) return;
    bool in_homework_list = (s_list && lv_obj_is_valid(s_list) && !lv_obj_has_flag(s_list, LV_OBJ_FLAG_HIDDEN));
    bool detail_open = (s_hw_detail_screen && lv_obj_is_valid(s_hw_detail_screen));
    if (!detail_open && in_homework_list && s_first_p4_card_idx >= 0) {
      lv_obj_t* target = lv_obj_get_child(s_list, s_first_p4_card_idx);
      if (target && lv_obj_is_valid(target)) lv_obj_scroll_to_view(target, LV_ANIM_ON);
    }
    s_phase4_alarm_muted = true;
    g_should_vibrate_phase4 = false;
    hide_snackbar();
  }
}

static void show_snackbar_phase4(int count, uint32_t color) {
  if (!s_snackbar || !lv_obj_is_valid(s_snackbar)) return;
  s_snackbar_type = 1;
  s_snackbar_click_enable_after_ms = millis() + 300;
  lv_obj_set_style_border_color(s_snackbar, lv_color_hex(0x2A2A2A), 0);
  lv_obj_set_style_border_width(s_snackbar, 1, 0);
  char buf[32];
  snprintf(buf, sizeof(buf), u8"확인 과제 %d건", count);
  if (s_snackbar_lbl) {
    lv_label_set_text(s_snackbar_lbl, buf);
    lv_obj_set_style_text_color(s_snackbar_lbl, lv_color_white(), 0);
    lv_obj_align(s_snackbar_lbl, LV_ALIGN_LEFT_MID, 14, 0);
  }
  if (s_snackbar_dot) {
    lv_obj_set_style_bg_color(s_snackbar_dot, lv_color_hex(color), 0);
    lv_obj_clear_flag(s_snackbar_dot, LV_OBJ_FLAG_HIDDEN);
  }
  lv_obj_clear_flag(s_snackbar, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(s_snackbar);
  lv_obj_align(s_snackbar, LV_ALIGN_TOP_MID, 0, 4);
}

static void show_snackbar_rest(void) {
  if (!s_snackbar || !lv_obj_is_valid(s_snackbar)) return;
  s_snackbar_type = 2;
  s_rest_mode = true;
  lv_obj_set_style_border_color(s_snackbar, lv_color_hex(0x1FA95B), 0);
  lv_obj_set_style_border_width(s_snackbar, 1, 0);
  if (s_snackbar_lbl) {
    lv_label_set_text(s_snackbar_lbl, u8"휴식 중");
    lv_obj_set_style_text_color(s_snackbar_lbl, lv_color_hex(0x1FA95B), 0);
    lv_obj_align(s_snackbar_lbl, LV_ALIGN_LEFT_MID, 2, 0);
  }
  if (s_snackbar_dot) lv_obj_add_flag(s_snackbar_dot, LV_OBJ_FLAG_HIDDEN);
  lv_obj_clear_flag(s_snackbar, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(s_snackbar);
  lv_obj_align(s_snackbar, LV_ALIGN_TOP_MID, 0, 4);
}

static void hide_snackbar(void) {
  if (!s_snackbar || !lv_obj_is_valid(s_snackbar)) return;
  s_snackbar_type = 0;
  s_snackbar_click_enable_after_ms = 0;
  lv_obj_add_flag(s_snackbar, LV_OBJ_FLAG_HIDDEN);
}

static int find_child_check_cache_idx(const char* item_id) {
  if (!item_id || !item_id[0]) return -1;
  const int cap = (int)(sizeof(s_child_check_cache) / sizeof(s_child_check_cache[0]));
  for (int i = 0; i < cap; i++) {
    if (!s_child_check_cache[i].used) continue;
    if (strcmp(s_child_check_cache[i].item_id, item_id) == 0) return i;
  }
  return -1;
}

static bool get_child_check_cached(const char* item_id) {
  int idx = find_child_check_cache_idx(item_id);
  if (idx < 0) return false;
  return s_child_check_cache[idx].checked;
}

static void set_child_check_cached(const char* item_id, bool checked) {
  if (!item_id || !item_id[0]) return;
  int idx = find_child_check_cache_idx(item_id);
  if (idx < 0) {
    const int cap = (int)(sizeof(s_child_check_cache) / sizeof(s_child_check_cache[0]));
    for (int i = 0; i < cap; i++) {
      if (s_child_check_cache[i].used) continue;
      idx = i;
      s_child_check_cache[i].used = true;
      strncpy(s_child_check_cache[i].item_id, item_id, sizeof(s_child_check_cache[i].item_id) - 1);
      s_child_check_cache[i].item_id[sizeof(s_child_check_cache[i].item_id) - 1] = '\0';
      break;
    }
  }
  if (idx < 0) {
    idx = 0;
    s_child_check_cache[idx].used = true;
    strncpy(s_child_check_cache[idx].item_id, item_id, sizeof(s_child_check_cache[idx].item_id) - 1);
    s_child_check_cache[idx].item_id[sizeof(s_child_check_cache[idx].item_id) - 1] = '\0';
  }
  s_child_check_cache[idx].checked = checked;
}

static void apply_child_check_visual(lv_obj_t* box, lv_obj_t* mark, bool checked) {
  if (!box || !lv_obj_is_valid(box)) return;
  if (checked) {
    lv_obj_set_style_bg_color(box, lv_color_hex(0x1B8F50), 0);
    lv_obj_set_style_border_color(box, lv_color_hex(0x1B8F50), 0);
    if (mark && lv_obj_is_valid(mark)) lv_obj_clear_flag(mark, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_set_style_bg_color(box, lv_color_hex(0x121212), 0);
    lv_obj_set_style_border_color(box, lv_color_hex(0x575757), 0);
    if (mark && lv_obj_is_valid(mark)) lv_obj_add_flag(mark, LV_OBJ_FLAG_HIDDEN);
  }
}

static void child_check_toggle_cb(lv_event_t* e) {
  ChildCheckCtx* c = (ChildCheckCtx*)lv_event_get_user_data(e);
  if (!c) return;
  lv_event_code_t code = lv_event_get_code(e);
  if (code == LV_EVENT_PRESSED) {
    c->dragged = false;
    lv_indev_t* indev = lv_event_get_indev(e);
    if (indev) {
      lv_point_t p;
      lv_indev_get_point(indev, &p);
      c->press_x = p.x;
      c->press_y = p.y;
    }
    return;
  }
  if (code == LV_EVENT_PRESSING) {
    if (c->dragged) return;
    lv_indev_t* indev = lv_event_get_indev(e);
    if (!indev) return;
    lv_point_t p;
    lv_indev_get_point(indev, &p);
    lv_coord_t dx = p.x - c->press_x;
    lv_coord_t dy = p.y - c->press_y;
    if (dx < 0) dx = -dx;
    if (dy < 0) dy = -dy;
    if (dx > TAP_MOVE_SLOP_PX || dy > TAP_MOVE_SLOP_PX) {
      c->dragged = true;
      suppress_tap_temporarily();
    }
    return;
  }
  if (code != LV_EVENT_CLICKED) return;
  if (c->dragged || is_tap_suppressed()) return;
  bool next = !get_child_check_cached(c->item_id);
  set_child_check_cached(c->item_id, next);
  apply_child_check_visual(c->box, c->mark, next);
}

static void child_check_ctx_delete_cb(lv_event_t* e) {
  if (lv_event_get_code(e) != LV_EVENT_DELETE) return;
  void* ud = lv_event_get_user_data(e);
  if (ud) free(ud);
}

static void attach_child_check_toggle(lv_obj_t* target, const char* item_id, lv_obj_t* box, lv_obj_t* mark) {
  if (!target || !item_id || !item_id[0]) return;
  ChildCheckCtx* cctx = (ChildCheckCtx*)malloc(sizeof(ChildCheckCtx));
  if (!cctx) return;
  strncpy(cctx->item_id, item_id, sizeof(cctx->item_id) - 1);
  cctx->item_id[sizeof(cctx->item_id) - 1] = '\0';
  cctx->box = box;
  cctx->mark = mark;
  cctx->press_x = 0;
  cctx->press_y = 0;
  cctx->dragged = false;
  lv_obj_add_event_cb(target, child_check_toggle_cb, LV_EVENT_PRESSED, cctx);
  lv_obj_add_event_cb(target, child_check_toggle_cb, LV_EVENT_PRESSING, cctx);
  lv_obj_add_event_cb(target, child_check_toggle_cb, LV_EVENT_CLICKED, cctx);
  lv_obj_add_event_cb(target, child_check_ctx_delete_cb, LV_EVENT_DELETE, cctx);
}

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
  if (is_tap_suppressed()) return;
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

  // 자식 버튼(홈/추가/질문) 클릭 시 드래그 가로채기 방지
  lv_obj_t* target = lv_event_get_target(e);
  lv_obj_t* current = lv_event_get_current_target(e);
  if (target != current && target != s_bottom_handle && target != s_bottom_sheet) {
    // 자식 위젯 터치 → 드래그 무시, 진행 중이면 정리
    if (s_sheet_dragging) {
      s_sheet_dragging = false;
      s_sheet_drag_moved = false;
    }
    return;
  }

  lv_indev_t* indev = lv_event_get_indev(e);
  if (!indev) return;
  lv_point_t p;
  lv_indev_get_point(indev, &p);

  if (code == LV_EVENT_PRESSED) {
    lv_anim_del(s_bottom_sheet, anim_set_sheet_y);
    lv_anim_del(s_bottom_handle, anim_set_handle_y);
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
      suppress_tap_temporarily();
      handle_drag_end(e);
    }
  }
}

void toggle_bottom_sheet(void) {
  if (!s_bottom_sheet || !s_bottom_handle) return;
  if (is_entry_hub_visible()) return;
  animate_bottom_sheet_to(!g_bottom_sheet_open);
}

static void add_menu_close_ready_cb(lv_anim_t* a) {
  (void)a;
  if (s_hw_add_menu_screen && lv_obj_is_valid(s_hw_add_menu_screen)) {
    lv_obj_del(s_hw_add_menu_screen);
  }
  s_hw_add_menu_screen = nullptr;
}

static void close_hw_add_menu_page(void) {
  if (s_hw_add_menu_screen && lv_obj_is_valid(s_hw_add_menu_screen)) {
    lv_anim_del(s_hw_add_menu_screen, (lv_anim_exec_xcb_t)lv_obj_set_x);
    lv_obj_del(s_hw_add_menu_screen);
  }
  s_hw_add_menu_screen = nullptr;
}

static void close_hw_add_menu_page_animated(void) {
  if (!s_hw_add_menu_screen || !lv_obj_is_valid(s_hw_add_menu_screen)) return;
  lv_anim_del(s_hw_add_menu_screen, (lv_anim_exec_xcb_t)lv_obj_set_x);
  lv_anim_t a;
  lv_anim_init(&a);
  lv_anim_set_var(&a, s_hw_add_menu_screen);
  lv_anim_set_values(&a, lv_obj_get_x(s_hw_add_menu_screen), 320);
  lv_anim_set_time(&a, 220);
  lv_anim_set_exec_cb(&a, (lv_anim_exec_xcb_t)lv_obj_set_x);
  lv_anim_set_path_cb(&a, lv_anim_path_ease_out);
  lv_anim_set_ready_cb(&a, add_menu_close_ready_cb);
  lv_anim_start(&a);
}

static void show_hw_add_menu_page(void) {
  if (!s_stage || !lv_obj_is_valid(s_stage)) return;
  if (!s_homeworks_mode) return;
  if (s_hw_add_menu_screen && lv_obj_is_valid(s_hw_add_menu_screen)) {
    lv_obj_move_foreground(s_hw_add_menu_screen);
    return;
  }
  s_hw_add_menu_screen = lv_obj_create(s_stage);
  lv_obj_set_size(s_hw_add_menu_screen, 320, 240);
  lv_obj_set_pos(s_hw_add_menu_screen, 320, 0);
  lv_obj_set_style_bg_color(s_hw_add_menu_screen, lv_color_hex(0x0B1112), 0);
  lv_obj_set_style_bg_opa(s_hw_add_menu_screen, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_hw_add_menu_screen, 0, 0);
  lv_obj_set_style_radius(s_hw_add_menu_screen, 0, 0);
  lv_obj_set_style_pad_all(s_hw_add_menu_screen, 0, 0);
  lv_obj_set_scrollbar_mode(s_hw_add_menu_screen, LV_SCROLLBAR_MODE_OFF);
  lv_obj_clear_flag(s_hw_add_menu_screen, LV_OBJ_FLAG_SCROLLABLE);
  if (s_global_font) lv_obj_set_style_text_font(s_hw_add_menu_screen, s_global_font, 0);

  lv_obj_t* header = lv_obj_create(s_hw_add_menu_screen);
  lv_obj_set_size(header, 320, 40);
  lv_obj_set_pos(header, 0, 0);
  lv_obj_set_style_bg_opa(header, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(header, 0, 0);
  lv_obj_set_style_pad_all(header, 0, 0);

  lv_obj_t* back_btn = lv_btn_create(header);
  lv_obj_set_size(back_btn, 38, 38);
  lv_obj_set_pos(back_btn, 8, 1);
  lv_obj_set_style_radius(back_btn, 10, 0);
  lv_obj_set_style_bg_color(back_btn, lv_color_hex(0x1E1E1E), 0);
  lv_obj_set_style_border_width(back_btn, 0, 0);
  lv_obj_set_style_shadow_width(back_btn, 0, 0);
  lv_obj_t* back_lbl = lv_label_create(back_btn);
  lv_obj_set_style_text_font(back_lbl, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(back_lbl, lv_color_hex(0xE6E6E6), 0);
  lv_label_set_text(back_lbl, "<");
  lv_obj_center(back_lbl);
  lv_obj_add_event_cb(back_btn, [](lv_event_t* e) {
    (void)e;
    close_hw_add_menu_page_animated();
  }, LV_EVENT_CLICKED, NULL);

  lv_obj_t* title = lv_label_create(header);
  lv_obj_set_style_text_font(title, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(title, lv_color_hex(0xFFFFFF), 0);
  lv_label_set_text(title, u8"과제추가");
  lv_obj_align(title, LV_ALIGN_LEFT_MID, 56, 1);

  lv_obj_t* grid = lv_obj_create(s_hw_add_menu_screen);
  lv_obj_set_size(grid, 320, 200);
  lv_obj_set_pos(grid, 0, 40);
  lv_obj_set_style_bg_opa(grid, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(grid, 0, 0);
  lv_obj_set_style_pad_all(grid, 0, 0);
  lv_obj_clear_flag(grid, LV_OBJ_FLAG_SCROLLABLE);

  const lv_coord_t r = 37;
  const lv_coord_t d = r * 2;
  const lv_coord_t col_gap = 18;
  const lv_coord_t row_gap = 16;
  const lv_coord_t block_w = 3 * d + 2 * col_gap;
  const lv_coord_t block_h = 2 * d + row_gap;
  const lv_coord_t x0 = (320 - block_w) / 2;
  const lv_coord_t y0 = (lv_coord_t)((200 - block_h) / 2) - 4;
  int slot = 0;
  for (int row = 0; row < 2; row++) {
    for (int col = 0; col < 3; col++) {
      lv_coord_t cx = x0 + col * (d + col_gap);
      lv_coord_t cy = y0 + row * (d + row_gap);
      if (slot == 0) {
        lv_obj_t* b = lv_btn_create(grid);
        lv_obj_set_size(b, r * 2, r * 2);
        lv_obj_set_pos(b, cx, cy);
        lv_obj_set_style_radius(b, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(b, lv_color_hex(0x2A4A5C), 0);
        lv_obj_set_style_border_width(b, 0, 0);
        lv_obj_set_style_shadow_width(b, 0, 0);
        lv_obj_t* lb = lv_label_create(b);
        lv_obj_set_style_text_font(lb, &kakao_kr_16, 0);
        lv_obj_set_style_text_color(lb, lv_color_hex(0xE6E6E6), 0);
        lv_label_set_text(lb, u8"서술");
        lv_obj_center(lb);
        lv_obj_add_event_cb(b, [](lv_event_t* e) {
          (void)e;
          close_hw_add_menu_page();
          fw_publish_create_descriptive_writing();
        }, LV_EVENT_CLICKED, NULL);
      } else {
        lv_obj_t* ph = lv_obj_create(grid);
        lv_obj_set_size(ph, r * 2, r * 2);
        lv_obj_set_pos(ph, cx, cy);
        lv_obj_set_style_radius(ph, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(ph, lv_color_hex(0x2A2A2A), 0);
        lv_obj_set_style_bg_opa(ph, LV_OPA_40, 0);
        lv_obj_set_style_border_width(ph, 0, 0);
        lv_obj_clear_flag(ph, LV_OBJ_FLAG_CLICKABLE);
      }
      slot++;
    }
  }

  lv_anim_t a;
  lv_anim_init(&a);
  lv_anim_set_var(&a, s_hw_add_menu_screen);
  lv_anim_set_values(&a, 320, 0);
  lv_anim_set_time(&a, 220);
  lv_anim_set_exec_cb(&a, (lv_anim_exec_xcb_t)lv_obj_set_x);
  lv_anim_set_path_cb(&a, lv_anim_path_ease_out);
  lv_anim_start(&a);

  screensaver_attach_activity(s_hw_add_menu_screen);
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

static void close_raise_question_confirm_popup(void) {
  if (s_raise_question_confirm_popup && lv_obj_is_valid(s_raise_question_confirm_popup)) {
    lv_obj_del(s_raise_question_confirm_popup);
  }
  s_raise_question_confirm_popup = nullptr;
}

static void close_test_start_confirm_popup(void) {
  if (s_test_start_confirm_popup && lv_obj_is_valid(s_test_start_confirm_popup)) {
    lv_obj_del(s_test_start_confirm_popup);
  }
  s_test_start_confirm_popup = nullptr;
  s_test_start_popup_group_idx = -1;
}

static void close_test_abort_confirm_popup(void) {
  if (s_test_abort_confirm_popup && lv_obj_is_valid(s_test_abort_confirm_popup)) {
    lv_obj_del(s_test_abort_confirm_popup);
  }
  s_test_abort_confirm_popup = nullptr;
}

static void close_confirm_to_wait_popup(void) {
  if (s_confirm_to_wait_popup && lv_obj_is_valid(s_confirm_to_wait_popup)) {
    lv_obj_del(s_confirm_to_wait_popup);
  }
  s_confirm_to_wait_popup = nullptr;
  if (s_confirm_to_wait_ctx) {
    free(s_confirm_to_wait_ctx);
    s_confirm_to_wait_ctx = nullptr;
  }
}

static void show_raise_question_confirm_popup(void) {
  if (s_raise_question_confirm_popup && lv_obj_is_valid(s_raise_question_confirm_popup)) return;

  s_raise_question_confirm_popup = lv_obj_create(lv_scr_act());
  lv_obj_set_size(s_raise_question_confirm_popup, 276, 148);
  lv_obj_center(s_raise_question_confirm_popup);
  lv_obj_set_style_bg_color(s_raise_question_confirm_popup, lv_color_hex(0x202020), 0);
  lv_obj_set_style_bg_opa(s_raise_question_confirm_popup, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_raise_question_confirm_popup, 1, 0);
  lv_obj_set_style_border_color(s_raise_question_confirm_popup, lv_color_hex(0x3A3A3A), 0);
  lv_obj_set_style_radius(s_raise_question_confirm_popup, 14, 0);
  lv_obj_set_style_pad_all(s_raise_question_confirm_popup, 12, 0);
  lv_obj_set_style_pad_row(s_raise_question_confirm_popup, 10, 0);
  lv_obj_clear_flag(s_raise_question_confirm_popup, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_flex_flow(s_raise_question_confirm_popup, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_raise_question_confirm_popup, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

  lv_obj_t* msg = lv_label_create(s_raise_question_confirm_popup);
  lv_obj_set_width(msg, 248);
  lv_obj_set_style_text_align(msg, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_style_text_font(msg, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(msg, lv_color_hex(0xD0D0D0), 0);
  lv_label_set_long_mode(msg, LV_LABEL_LONG_WRAP);
  lv_label_set_text(msg, u8"질문 하고 싶어요.");

  lv_obj_t* row = lv_obj_create(s_raise_question_confirm_popup);
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
    close_raise_question_confirm_popup();
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
    close_raise_question_confirm_popup();
    fw_publish_raise_question();
  }, LV_EVENT_CLICKED, NULL);

  screensaver_attach_activity(s_raise_question_confirm_popup);
}

static void show_test_start_confirm_popup(int group_idx) {
  if (group_idx < 0 || group_idx >= s_group_cnt) return;
  if (s_test_start_confirm_popup && lv_obj_is_valid(s_test_start_confirm_popup)) return;

  s_test_start_popup_group_idx = group_idx;
  const HwGroupData& g = s_groups[group_idx];
  char msgbuf[128];
  if (g.time_limit_minutes > 0) {
    snprintf(msgbuf, sizeof(msgbuf), u8"제한 시간 %d분입니다.\n시작할까요?", (int)g.time_limit_minutes);
  } else {
    snprintf(msgbuf, sizeof(msgbuf), u8"제한 시간이 없습니다.\n시작할까요?");
  }

  s_test_start_confirm_popup = lv_obj_create(lv_scr_act());
  lv_obj_set_size(s_test_start_confirm_popup, 276, 148);
  lv_obj_center(s_test_start_confirm_popup);
  lv_obj_set_style_bg_color(s_test_start_confirm_popup, lv_color_hex(0x202020), 0);
  lv_obj_set_style_bg_opa(s_test_start_confirm_popup, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_test_start_confirm_popup, 1, 0);
  lv_obj_set_style_border_color(s_test_start_confirm_popup, lv_color_hex(0x3A3A3A), 0);
  lv_obj_set_style_radius(s_test_start_confirm_popup, 14, 0);
  lv_obj_set_style_pad_all(s_test_start_confirm_popup, 12, 0);
  lv_obj_set_style_pad_row(s_test_start_confirm_popup, 10, 0);
  lv_obj_clear_flag(s_test_start_confirm_popup, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_flex_flow(s_test_start_confirm_popup, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_test_start_confirm_popup, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

  lv_obj_t* msg = lv_label_create(s_test_start_confirm_popup);
  lv_obj_set_width(msg, 248);
  lv_obj_set_style_text_align(msg, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_style_text_font(msg, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(msg, lv_color_hex(0xD0D0D0), 0);
  lv_label_set_long_mode(msg, LV_LABEL_LONG_WRAP);
  lv_label_set_text(msg, msgbuf);

  lv_obj_t* row = lv_obj_create(s_test_start_confirm_popup);
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
    close_test_start_confirm_popup();
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
    int idx = s_test_start_popup_group_idx;
    close_test_start_confirm_popup();
    if (idx < 0 || idx >= s_group_cnt) return;
    HwGroupData& grp = s_groups[idx];
    if (!fw_publish_group_transition(grp.group_id, 1)) return;
    show_homework_detail_page(idx);
    s_detail_playing = true;
    s_detail_manual_override_playing = true;
    s_detail_manual_override_until_ms = millis() + 5000;
    update_detail_play_button_visual();
  }, LV_EVENT_CLICKED, NULL);

  screensaver_attach_activity(s_test_start_confirm_popup);
}

static void show_test_abort_confirm_popup(void) {
  if (s_test_abort_confirm_popup && lv_obj_is_valid(s_test_abort_confirm_popup)) return;
  if (s_detail_group_idx < 0 || s_detail_group_idx >= s_group_cnt) return;

  s_test_abort_confirm_popup = lv_obj_create(lv_scr_act());
  lv_obj_set_size(s_test_abort_confirm_popup, 276, 148);
  lv_obj_center(s_test_abort_confirm_popup);
  lv_obj_set_style_bg_color(s_test_abort_confirm_popup, lv_color_hex(0x202020), 0);
  lv_obj_set_style_bg_opa(s_test_abort_confirm_popup, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_test_abort_confirm_popup, 1, 0);
  lv_obj_set_style_border_color(s_test_abort_confirm_popup, lv_color_hex(0x3A3A3A), 0);
  lv_obj_set_style_radius(s_test_abort_confirm_popup, 14, 0);
  lv_obj_set_style_pad_all(s_test_abort_confirm_popup, 12, 0);
  lv_obj_set_style_pad_row(s_test_abort_confirm_popup, 10, 0);
  lv_obj_clear_flag(s_test_abort_confirm_popup, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_flex_flow(s_test_abort_confirm_popup, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_test_abort_confirm_popup, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

  lv_obj_t* msg = lv_label_create(s_test_abort_confirm_popup);
  lv_obj_set_width(msg, 248);
  lv_obj_set_style_text_align(msg, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_style_text_font(msg, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(msg, lv_color_hex(0xD0D0D0), 0);
  lv_label_set_long_mode(msg, LV_LABEL_LONG_WRAP);
  lv_label_set_text(msg, u8"중단하면 자동 제출 단계로\n이동합니다. 계속할까요?");

  lv_obj_t* row = lv_obj_create(s_test_abort_confirm_popup);
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
    close_test_abort_confirm_popup();
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
    int idx = s_detail_group_idx;
    close_test_abort_confirm_popup();
    if (idx < 0 || idx >= s_group_cnt) return;
    HwGroupData& grp = s_groups[idx];
    if (fw_publish_group_transition(grp.group_id, 99)) {
      close_homework_detail_page();
    }
  }, LV_EVENT_CLICKED, NULL);

  screensaver_attach_activity(s_test_abort_confirm_popup);
}

static void show_confirm_phase_to_waiting_popup(const char* group_id, int group_idx) {
  if (!group_id || !group_id[0]) return;
  if (s_confirm_to_wait_popup && lv_obj_is_valid(s_confirm_to_wait_popup)) return;

  ConfirmToWaitCtx* ctx = (ConfirmToWaitCtx*)malloc(sizeof(ConfirmToWaitCtx));
  if (!ctx) return;
  strncpy(ctx->group_id, group_id, sizeof(ctx->group_id) - 1);
  ctx->group_id[sizeof(ctx->group_id) - 1] = '\0';
  s_confirm_to_wait_ctx = ctx;

  const char* line1 = u8"과제";
  if (group_idx >= 0 && (unsigned)group_idx < s_group_cnt) {
    const HwGroupData& g = s_groups[group_idx];
    if (g.group_title[0]) line1 = g.group_title;
    else if (g.book_name[0]) line1 = g.book_name;
  }

  s_confirm_to_wait_popup = lv_obj_create(lv_scr_act());
  lv_obj_set_size(s_confirm_to_wait_popup, 276, 168);
  lv_obj_center(s_confirm_to_wait_popup);
  lv_obj_set_style_bg_color(s_confirm_to_wait_popup, lv_color_hex(0x202020), 0);
  lv_obj_set_style_bg_opa(s_confirm_to_wait_popup, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_confirm_to_wait_popup, 1, 0);
  lv_obj_set_style_border_color(s_confirm_to_wait_popup, lv_color_hex(0x3A3A3A), 0);
  lv_obj_set_style_radius(s_confirm_to_wait_popup, 14, 0);
  lv_obj_set_style_pad_all(s_confirm_to_wait_popup, 12, 0);
  lv_obj_set_style_pad_row(s_confirm_to_wait_popup, 10, 0);
  lv_obj_clear_flag(s_confirm_to_wait_popup, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_flex_flow(s_confirm_to_wait_popup, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_confirm_to_wait_popup, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);

  lv_obj_t* msg = lv_label_create(s_confirm_to_wait_popup);
  lv_obj_set_width(msg, 248);
  lv_obj_set_style_text_align(msg, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_style_text_font(msg, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(msg, lv_color_hex(0xD0D0D0), 0);
  lv_label_set_long_mode(msg, LV_LABEL_LONG_WRAP);
  char msgbuf[160];
  snprintf(msgbuf, sizeof(msgbuf), u8"%.*s\n과제를 찾아왔나요?", 32, line1);
  lv_label_set_text(msg, msgbuf);

  lv_obj_t* row = lv_obj_create(s_confirm_to_wait_popup);
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
    close_confirm_to_wait_popup();
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
    char gid[40] = {};
    if (s_confirm_to_wait_ctx) {
      strncpy(gid, s_confirm_to_wait_ctx->group_id, sizeof(gid) - 1);
      gid[sizeof(gid) - 1] = '\0';
    }
    close_confirm_to_wait_popup();
    if (gid[0]) (void)fw_publish_group_transition(gid, 4);
  }, LV_EVENT_CLICKED, NULL);

  screensaver_attach_activity(s_confirm_to_wait_popup);
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

// ─── Stopwatch ───

static void sw_format_time(uint32_t ms, char* buf, size_t len) {
  uint32_t total_cs = ms / 10;
  uint32_t cs = total_cs % 100;
  uint32_t total_sec = ms / 1000;
  uint32_t sec = total_sec % 60;
  uint32_t min = total_sec / 60;
  snprintf(buf, len, "%02lu:%02lu.%02lu", (unsigned long)min, (unsigned long)sec, (unsigned long)cs);
}

static void sw_update_display(void) {
  if (!s_sw_digits[0] || !lv_obj_is_valid(s_sw_digits[0])) return;
  uint32_t elapsed = s_sw_elapsed_ms;
  if (s_sw_running) elapsed += (lv_tick_get() - s_sw_start_tick);
  uint32_t total_cs = elapsed / 10;
  uint32_t cs = total_cs % 100;
  uint32_t total_sec = elapsed / 1000;
  uint32_t sec = total_sec % 60;
  uint32_t min = total_sec / 60;
  char d[2] = {0, 0};
  d[0] = '0' + (min / 10) % 10;  lv_label_set_text(s_sw_digits[0], d);
  d[0] = '0' + min % 10;         lv_label_set_text(s_sw_digits[1], d);
  d[0] = '0' + sec / 10;         lv_label_set_text(s_sw_digits[3], d);
  d[0] = '0' + sec % 10;         lv_label_set_text(s_sw_digits[4], d);
  d[0] = '0' + cs / 10;          lv_label_set_text(s_sw_digits[6], d);
  d[0] = '0' + cs % 10;          lv_label_set_text(s_sw_digits[7], d);
}

static void sw_timer_cb(lv_timer_t* t) {
  (void)t;
  sw_update_display();
}

static void sw_update_buttons(void);

static void sw_start(void) {
  s_sw_start_tick = lv_tick_get();
  s_sw_running = true;
  if (!s_sw_timer) {
    s_sw_timer = lv_timer_create(sw_timer_cb, 50, NULL);
    lv_timer_set_repeat_count(s_sw_timer, -1);
  }
  sw_update_buttons();
}

static void sw_stop(void) {
  if (s_sw_running) {
    s_sw_elapsed_ms += (lv_tick_get() - s_sw_start_tick);
    s_sw_running = false;
  }
  sw_update_display();
  sw_update_buttons();
}

static void sw_reset(void) {
  s_sw_elapsed_ms = 0;
  s_sw_running = false;
  s_sw_lap_count = 0;
  if (s_sw_timer) { lv_timer_del(s_sw_timer); s_sw_timer = nullptr; }
  sw_update_display();
  if (s_sw_lap_list && lv_obj_is_valid(s_sw_lap_list)) lv_obj_clean(s_sw_lap_list);
  sw_update_buttons();
}

static void sw_lap(void) {
  if (!s_sw_running || !s_sw_lap_list || !lv_obj_is_valid(s_sw_lap_list)) return;
  uint32_t elapsed = s_sw_elapsed_ms + (lv_tick_get() - s_sw_start_tick);
  s_sw_lap_count++;
  char buf[32];
  char tbuf[16];
  sw_format_time(elapsed, tbuf, sizeof(tbuf));
  snprintf(buf, sizeof(buf), "#%d  %s", s_sw_lap_count, tbuf);
  lv_obj_t* lbl = lv_label_create(s_sw_lap_list);
  lv_obj_set_width(lbl, lv_pct(100));
  lv_obj_set_style_text_font(lbl, &lv_font_montserrat_14, 0);
  lv_obj_set_style_text_color(lbl, lv_color_hex(0xC0C0C0), 0);
  lv_label_set_text(lbl, buf);
  lv_obj_move_to_index(lbl, 0);
  lv_obj_scroll_to_y(s_sw_lap_list, 0, LV_ANIM_ON);
}

static void sw_update_buttons(void) {
  if (!s_sw_left_btn || !s_sw_right_btn) return;
  if (s_sw_running) {
    if (s_sw_left_lbl) lv_label_set_text(s_sw_left_lbl, u8"랩");
    lv_obj_set_style_bg_color(s_sw_left_btn, lv_color_hex(0x333333), 0);
    lv_obj_set_style_bg_opa(s_sw_left_btn, LV_OPA_80, 0);
    if (s_sw_right_lbl) lv_label_set_text(s_sw_right_lbl, u8"중단");
    lv_obj_set_style_bg_color(s_sw_right_btn, lv_color_hex(0xDC143C), 0);
    lv_obj_set_style_bg_opa(s_sw_right_btn, LV_OPA_60, 0);
  } else {
    bool has_time = s_sw_elapsed_ms > 0;
    if (s_sw_left_lbl) lv_label_set_text(s_sw_left_lbl, u8"재설정");
    lv_obj_set_style_bg_color(s_sw_left_btn, lv_color_hex(0x333333), 0);
    lv_obj_set_style_bg_opa(s_sw_left_btn, has_time ? LV_OPA_80 : LV_OPA_40, 0);
    if (s_sw_right_lbl) lv_label_set_text(s_sw_right_lbl, u8"시작");
    lv_obj_set_style_bg_color(s_sw_right_btn, lv_color_hex(0x1FA95B), 0);
    lv_obj_set_style_bg_opa(s_sw_right_btn, LV_OPA_60, 0);
  }
}

static void close_stopwatch_screen(bool show_hub) {
  if (s_sw_timer) { lv_timer_del(s_sw_timer); s_sw_timer = nullptr; }
  s_sw_running = false;
  s_sw_elapsed_ms = 0;
  s_sw_lap_count = 0;
  if (s_stopwatch_screen && lv_obj_is_valid(s_stopwatch_screen)) {
    lv_obj_del(s_stopwatch_screen);
  }
  s_stopwatch_screen = nullptr;
  s_sw_time_label = nullptr;
  memset(s_sw_digits, 0, sizeof(s_sw_digits));
  s_sw_left_btn = nullptr;
  s_sw_right_btn = nullptr;
  s_sw_left_lbl = nullptr;
  s_sw_right_lbl = nullptr;
  s_sw_lap_list = nullptr;
  if (show_hub) show_entry_hub_overlay();
}

static void show_stopwatch_screen(void) {
  if (!s_stage || !lv_obj_is_valid(s_stage)) return;
  if (s_entry_hub && lv_obj_is_valid(s_entry_hub)) {
    lv_obj_add_flag(s_entry_hub, LV_OBJ_FLAG_HIDDEN);
  }
  if (s_stopwatch_screen && lv_obj_is_valid(s_stopwatch_screen)) {
    lv_obj_move_foreground(s_stopwatch_screen);
    return;
  }

  s_stopwatch_screen = lv_obj_create(s_stage);
  lv_obj_set_size(s_stopwatch_screen, 320, 240);
  lv_obj_set_pos(s_stopwatch_screen, 0, 0);
  lv_obj_set_style_bg_color(s_stopwatch_screen, lv_color_hex(0x141414), 0);
  lv_obj_set_style_bg_opa(s_stopwatch_screen, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_stopwatch_screen, 0, 0);
  lv_obj_set_style_radius(s_stopwatch_screen, 0, 0);
  lv_obj_set_style_pad_all(s_stopwatch_screen, 0, 0);
  lv_obj_clear_flag(s_stopwatch_screen, LV_OBJ_FLAG_SCROLLABLE);

  // Header (same style as student info screen)
  lv_obj_t* header = lv_obj_create(s_stopwatch_screen);
  lv_obj_set_size(header, 320, 44);
  lv_obj_set_pos(header, 0, 0);
  lv_obj_set_style_bg_opa(header, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(header, 0, 0);
  lv_obj_set_style_pad_left(header, 16, 0);
  lv_obj_set_style_pad_top(header, 0, 0);
  lv_obj_set_style_pad_bottom(header, 0, 0);
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
    close_stopwatch_screen(true);
  }, LV_EVENT_CLICKED, NULL);

  lv_obj_t* title = lv_label_create(header);
  if (s_global_font) lv_obj_set_style_text_font(title, s_global_font, 0);
  lv_obj_set_style_text_color(title, lv_color_hex(0xFFFFFF), 0);
  lv_obj_set_style_pad_left(title, 10, 0);
  lv_label_set_text(title, u8"스톱워치");

  // Time display — each single digit in its own fixed-width label
  s_sw_time_label = lv_obj_create(s_stopwatch_screen);
  lv_obj_remove_style_all(s_sw_time_label);
  lv_obj_set_size(s_sw_time_label, 260, 36);
  lv_obj_align(s_sw_time_label, LV_ALIGN_TOP_MID, 0, 70);
  lv_obj_set_layout(s_sw_time_label, LV_LAYOUT_FLEX);
  lv_obj_set_flex_flow(s_sw_time_label, LV_FLEX_FLOW_ROW);
  lv_obj_set_flex_align(s_sw_time_label, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  lv_obj_set_style_pad_column(s_sw_time_label, 0, 0);
  lv_obj_clear_flag(s_sw_time_label, LV_OBJ_FLAG_SCROLLABLE);

  const lv_coord_t dw = 26;  // single digit width
  const lv_coord_t sw = 16;  // separator width

  auto make_digit = [&](const char* txt, lv_coord_t w, uint32_t color) -> lv_obj_t* {
    lv_obj_t* lbl = lv_label_create(s_sw_time_label);
    lv_obj_set_style_text_font(lbl, &lv_font_montserrat_28, 0);
    lv_obj_set_style_text_color(lbl, lv_color_hex(color), 0);
    lv_obj_set_width(lbl, w);
    lv_obj_set_style_text_align(lbl, LV_TEXT_ALIGN_CENTER, 0);
    lv_label_set_text(lbl, txt);
    return lbl;
  };

  // min10, min1, ":", sec10, sec1, ".", cs10, cs1
  s_sw_digits[0] = make_digit("0", dw, 0xFFFFFF);
  s_sw_digits[1] = make_digit("0", dw, 0xFFFFFF);
  s_sw_digits[2] = make_digit(":", sw, 0x888888);
  s_sw_digits[3] = make_digit("0", dw, 0xFFFFFF);
  s_sw_digits[4] = make_digit("0", dw, 0xFFFFFF);
  s_sw_digits[5] = make_digit(".", sw, 0x888888);
  s_sw_digits[6] = make_digit("0", dw, 0xFFFFFF);
  s_sw_digits[7] = make_digit("0", dw, 0xFFFFFF);

  // Bottom buttons
  const lv_coord_t btn_w = 110, btn_h = 44, btn_y = 120;
  s_sw_left_btn = lv_btn_create(s_stopwatch_screen);
  lv_obj_set_size(s_sw_left_btn, btn_w, btn_h);
  lv_obj_set_pos(s_sw_left_btn, 24, btn_y);
  lv_obj_set_style_radius(s_sw_left_btn, 22, 0);
  lv_obj_set_style_bg_color(s_sw_left_btn, lv_color_hex(0x333333), 0);
  lv_obj_set_style_bg_opa(s_sw_left_btn, LV_OPA_40, 0);
  lv_obj_set_style_border_width(s_sw_left_btn, 0, 0);
  lv_obj_set_style_shadow_width(s_sw_left_btn, 0, 0);
  s_sw_left_lbl = lv_label_create(s_sw_left_btn);
  lv_obj_set_style_text_font(s_sw_left_lbl, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(s_sw_left_lbl, lv_color_hex(0xE6E6E6), 0);
  lv_label_set_text(s_sw_left_lbl, u8"재설정");
  lv_obj_center(s_sw_left_lbl);
  lv_obj_add_event_cb(s_sw_left_btn, [](lv_event_t* e) {
    (void)e;
    if (s_sw_running) sw_lap();
    else sw_reset();
  }, LV_EVENT_CLICKED, NULL);

  s_sw_right_btn = lv_btn_create(s_stopwatch_screen);
  lv_obj_set_size(s_sw_right_btn, btn_w, btn_h);
  lv_obj_set_pos(s_sw_right_btn, 320 - 24 - btn_w, btn_y);
  lv_obj_set_style_radius(s_sw_right_btn, 22, 0);
  lv_obj_set_style_bg_color(s_sw_right_btn, lv_color_hex(0x1FA95B), 0);
  lv_obj_set_style_bg_opa(s_sw_right_btn, LV_OPA_60, 0);
  lv_obj_set_style_border_width(s_sw_right_btn, 0, 0);
  lv_obj_set_style_shadow_width(s_sw_right_btn, 0, 0);
  s_sw_right_lbl = lv_label_create(s_sw_right_btn);
  lv_obj_set_style_text_font(s_sw_right_lbl, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(s_sw_right_lbl, lv_color_hex(0xE6E6E6), 0);
  lv_label_set_text(s_sw_right_lbl, u8"시작");
  lv_obj_center(s_sw_right_lbl);
  lv_obj_add_event_cb(s_sw_right_btn, [](lv_event_t* e) {
    (void)e;
    if (s_sw_running) sw_stop();
    else sw_start();
  }, LV_EVENT_CLICKED, NULL);

  // Lap list
  s_sw_lap_list = lv_obj_create(s_stopwatch_screen);
  lv_obj_set_size(s_sw_lap_list, 280, 240 - btn_y - btn_h - 12);
  lv_obj_set_pos(s_sw_lap_list, 20, btn_y + btn_h + 8);
  lv_obj_set_style_bg_opa(s_sw_lap_list, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(s_sw_lap_list, 0, 0);
  lv_obj_set_style_pad_all(s_sw_lap_list, 4, 0);
  lv_obj_set_style_pad_row(s_sw_lap_list, 4, 0);
  lv_obj_set_flex_flow(s_sw_lap_list, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_scrollbar_mode(s_sw_lap_list, LV_SCROLLBAR_MODE_ACTIVE);
  lv_obj_set_scroll_dir(s_sw_lap_list, LV_DIR_VER);

  s_sw_elapsed_ms = 0;
  s_sw_running = false;
  s_sw_lap_count = 0;

  screensaver_attach_activity(s_stopwatch_screen);
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

    // --- Top bar: student name (left), clock (center), battery (right) ---
    s_entry_name_label = lv_label_create(s_entry_hub);
    lv_obj_set_width(s_entry_name_label, 120);
    lv_obj_set_style_text_color(s_entry_name_label, lv_color_hex(0xE6E6E6), 0);
    lv_obj_set_style_text_font(s_entry_name_label, &kakao_kr_16, 0);
    lv_label_set_long_mode(s_entry_name_label, LV_LABEL_LONG_DOT);
    lv_label_set_text(s_entry_name_label, s_student_name_cache.c_str());
    lv_obj_align(s_entry_name_label, LV_ALIGN_TOP_LEFT, 14, 8);

    s_hub_clock_label = lv_label_create(s_entry_hub);
    lv_obj_set_style_text_color(s_hub_clock_label, lv_color_hex(0xE6E6E6), 0);
    lv_obj_set_style_text_font(s_hub_clock_label, &lv_font_montserrat_14, 0);
    struct tm ti;
    if (getLocalTime(&ti, 0)) {
      char buf[8]; snprintf(buf, sizeof(buf), "%02d:%02d", ti.tm_hour, ti.tm_min);
      lv_label_set_text(s_hub_clock_label, buf);
    } else {
      lv_label_set_text(s_hub_clock_label, "--:--");
    }
    lv_obj_align(s_hub_clock_label, LV_ALIGN_TOP_MID, 0, 10);

    s_hub_battery_widget = lv_obj_create(s_entry_hub);
    lv_obj_set_size(s_hub_battery_widget, 84, 28);
    lv_obj_set_style_bg_opa(s_hub_battery_widget, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(s_hub_battery_widget, 0, 0);
    lv_obj_set_style_pad_all(s_hub_battery_widget, 0, 0);
    lv_obj_set_flex_flow(s_hub_battery_widget, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(s_hub_battery_widget, LV_FLEX_ALIGN_END, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_align(s_hub_battery_widget, LV_ALIGN_TOP_RIGHT, -8, 4);
    s_hub_battery_label = lv_label_create(s_hub_battery_widget);
    lv_label_set_text(s_hub_battery_label, "");
    lv_obj_set_style_text_color(s_hub_battery_label, lv_color_hex(0xC0C0C0), 0);
    lv_obj_set_style_text_font(s_hub_battery_label, &lv_font_montserrat_14, 0);
    lv_obj_set_style_pad_right(s_hub_battery_label, 2, 0);
    lv_obj_t* bat_img = lv_img_create(s_hub_battery_widget);
    lv_img_set_src(bat_img, &battery_android_frame_full_32dp_999999_FILL0_wght400_GRAD0_opsz40);
    lv_obj_set_style_img_recolor(bat_img, lv_color_hex(0xC0C0C0), 0);
    lv_obj_set_style_img_recolor_opa(bat_img, LV_OPA_COVER, 0);

    // --- 2x2 grid buttons ---
    const lv_coord_t btn_w = 116, btn_h = 90;
    const lv_coord_t gap_h = 30;
    const lv_coord_t margin_x = (320 - btn_w * 2 - gap_h) / 2;
    const lv_coord_t grid_y = 36;
    const lv_coord_t gap_v = 12;
    const lv_coord_t col1_x = margin_x, col2_x = margin_x + btn_w + gap_h;
    const lv_coord_t row1_y = grid_y, row2_y = grid_y + btn_h + gap_v;

    auto make_grid_btn = [](lv_obj_t* parent, const char* text, lv_coord_t x, lv_coord_t y,
                            lv_coord_t w, lv_coord_t h,
                            const lv_img_dsc_t* icon) -> lv_obj_t* {
      lv_obj_t* btn = lv_btn_create(parent);
      lv_obj_set_size(btn, w, h);
      lv_obj_set_pos(btn, x, y);
      lv_obj_set_style_radius(btn, 20, 0);
      lv_obj_set_style_bg_color(btn, lv_color_hex(0x1A1A1A), 0);
      lv_obj_set_style_border_color(btn, lv_color_hex(0x2C2C2C), 0);
      lv_obj_set_style_border_width(btn, 1, 0);
      lv_obj_set_style_shadow_width(btn, 0, 0);
      if (icon) {
        lv_obj_t* img = lv_img_create(btn);
        lv_img_set_src(img, icon);
        lv_img_set_zoom(img, 154);
        lv_obj_set_style_img_recolor(img, lv_color_hex(0xE6E6E6), 0);
        lv_obj_set_style_img_recolor_opa(img, LV_OPA_COVER, 0);
        lv_obj_align(img, LV_ALIGN_CENTER, 0, -8);
        lv_obj_t* lbl = lv_label_create(btn);
        lv_obj_set_style_text_font(lbl, &kakao_kr_16, 0);
        lv_obj_set_style_text_color(lbl, lv_color_hex(0xA0A0A0), 0);
        lv_label_set_text(lbl, text);
        lv_obj_align(lbl, LV_ALIGN_BOTTOM_MID, 0, 2);
      } else {
        lv_obj_t* lbl = lv_label_create(btn);
        if (s_global_font) lv_obj_set_style_text_font(lbl, s_global_font, 0);
        lv_obj_set_style_text_color(lbl, lv_color_hex(0xE6E6E6), 0);
        lv_label_set_text(lbl, text);
        lv_obj_center(lbl);
      }
      return btn;
    };

    lv_obj_t* hw_btn = make_grid_btn(s_entry_hub, u8"과제", col1_x, row1_y, btn_w, btn_h,
                                      &format_list_bulleted_90dp_999999_FILL0_wght400_GRAD0_opsz48);
    lv_obj_add_event_cb(hw_btn, [](lv_event_t* e) {
      (void)e;
      if (s_hub_clock_timer) { lv_timer_del(s_hub_clock_timer); s_hub_clock_timer = nullptr; }
      if (s_entry_hub && lv_obj_is_valid(s_entry_hub)) {
        lv_obj_add_flag(s_entry_hub, LV_OBJ_FLAG_HIDDEN);
      }
      if (s_pages && lv_obj_is_valid(s_pages)) lv_obj_clear_flag(s_pages, LV_OBJ_FLAG_HIDDEN);
      if (s_fab && lv_obj_is_valid(s_fab)) lv_obj_clear_flag(s_fab, LV_OBJ_FLAG_HIDDEN);
      if (s_bottom_handle && lv_obj_is_valid(s_bottom_handle)) lv_obj_clear_flag(s_bottom_handle, LV_OBJ_FLAG_HIDDEN);
      if (s_bottom_sheet && lv_obj_is_valid(s_bottom_sheet)) lv_obj_clear_flag(s_bottom_sheet, LV_OBJ_FLAG_HIDDEN);
      if (s_snackbar && lv_obj_is_valid(s_snackbar) && s_snackbar_type > 0) lv_obj_clear_flag(s_snackbar, LV_OBJ_FLAG_HIDDEN);
    }, LV_EVENT_CLICKED, NULL);

    lv_obj_t* watch_btn = make_grid_btn(s_entry_hub, u8"스탑", col2_x, row1_y, btn_w, btn_h,
                                        &timer_90dp_999999_FILL0_wght400_GRAD0_opsz48);
    lv_obj_add_event_cb(watch_btn, [](lv_event_t* e) {
      (void)e;
      show_stopwatch_screen();
    }, LV_EVENT_CLICKED, NULL);

    lv_obj_t* info_btn = make_grid_btn(s_entry_hub, u8"정보", col1_x, row2_y, btn_w, btn_h,
                                       &info_i_90dp_999999_FILL0_wght400_GRAD0_opsz48);
    lv_obj_add_event_cb(info_btn, [](lv_event_t* e) {
      (void)e;
      show_student_info_screen();
    }, LV_EVENT_CLICKED, NULL);

    lv_obj_t* settings_btn = make_grid_btn(s_entry_hub, u8"설정", col2_x, row2_y, btn_w, btn_h,
                                          &settings_90dp_999999_FILL0_wght400_GRAD0_opsz48);
    lv_obj_add_event_cb(settings_btn, [](lv_event_t* e) {
      (void)e;
      ui_port_show_settings(FIRMWARE_VERSION);
    }, LV_EVENT_CLICKED, NULL);

    // Clock + battery refresh timer (30s interval)
    if (s_hub_clock_timer) { lv_timer_del(s_hub_clock_timer); s_hub_clock_timer = nullptr; }
    s_hub_clock_timer = lv_timer_create(hub_clock_timer_cb, 30000, NULL);
    lv_timer_set_repeat_count(s_hub_clock_timer, -1);
  }

  if (s_entry_name_label && lv_obj_is_valid(s_entry_name_label)) {
    lv_label_set_text(s_entry_name_label, s_student_name_cache.c_str());
  }
  lv_obj_clear_flag(s_entry_hub, LV_OBJ_FLAG_HIDDEN);
  lv_obj_move_foreground(s_entry_hub);
  if (s_pages && lv_obj_is_valid(s_pages)) lv_obj_add_flag(s_pages, LV_OBJ_FLAG_HIDDEN);
  if (s_fab && lv_obj_is_valid(s_fab)) lv_obj_add_flag(s_fab, LV_OBJ_FLAG_HIDDEN);
  if (s_bottom_handle && lv_obj_is_valid(s_bottom_handle)) lv_obj_add_flag(s_bottom_handle, LV_OBJ_FLAG_HIDDEN);
  if (s_bottom_sheet && lv_obj_is_valid(s_bottom_sheet)) lv_obj_add_flag(s_bottom_sheet, LV_OBJ_FLAG_HIDDEN);
  if (s_snackbar && lv_obj_is_valid(s_snackbar)) lv_obj_add_flag(s_snackbar, LV_OBJ_FLAG_HIDDEN);
  if (g_bottom_sheet_open) {
    set_bottom_sheet_position(240);
    g_bottom_sheet_open = false;
  }
  update_hub_battery();
  hub_clock_timer_cb(nullptr);
  if (!s_hub_clock_timer) {
    s_hub_clock_timer = lv_timer_create(hub_clock_timer_cb, 30000, NULL);
    lv_timer_set_repeat_count(s_hub_clock_timer, -1);
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
  close_raise_question_confirm_popup();
  close_test_start_confirm_popup();
  close_test_abort_confirm_popup();
  close_confirm_to_wait_popup();
  if (s_hub_clock_timer) { lv_timer_del(s_hub_clock_timer); s_hub_clock_timer = nullptr; }
  if (s_entry_hub && lv_obj_is_valid(s_entry_hub)) { lv_obj_del(s_entry_hub); s_entry_hub = nullptr; s_entry_name_label = nullptr; s_hub_clock_label = nullptr; s_hub_battery_widget = nullptr; s_hub_battery_label = nullptr; }
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
  lv_obj_add_flag(s_list, LV_OBJ_FLAG_SCROLL_ELASTIC);
  lv_obj_add_flag(s_list, LV_OBJ_FLAG_SCROLL_MOMENTUM);
  lv_obj_set_style_anim_time(s_list, 180, 0);
  lv_obj_add_event_cb(s_list, list_scroll_activity_cb, LV_EVENT_SCROLL_BEGIN, NULL);
  lv_obj_add_event_cb(s_list, list_scroll_activity_cb, LV_EVENT_SCROLL_END, NULL);
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
  close_raise_question_confirm_popup();
  close_test_start_confirm_popup();
  close_test_abort_confirm_popup();
  close_confirm_to_wait_popup();
  if (s_hub_clock_timer) { lv_timer_del(s_hub_clock_timer); s_hub_clock_timer = nullptr; }
  if (s_entry_hub && lv_obj_is_valid(s_entry_hub)) { lv_obj_del(s_entry_hub); s_entry_hub = nullptr; s_entry_name_label = nullptr; s_hub_clock_label = nullptr; s_hub_battery_widget = nullptr; s_hub_battery_label = nullptr; }
  if (s_student_info_screen && lv_obj_is_valid(s_student_info_screen)) { lv_obj_del(s_student_info_screen); s_student_info_screen = nullptr; }
  if (s_bottom_handle && lv_obj_is_valid(s_bottom_handle)) { lv_obj_del(s_bottom_handle); s_bottom_handle = nullptr; }
  if (s_bottom_sheet && lv_obj_is_valid(s_bottom_sheet)) { lv_obj_del(s_bottom_sheet); s_bottom_sheet = nullptr; }
  if (s_fab && lv_obj_is_valid(s_fab)) { lv_obj_del(s_fab); s_fab = nullptr; }
  g_bottom_sheet_open = false;
  s_sheet_dragging = false;
  s_sheet_drag_moved = false;
  lv_obj_clean(s_stage);
  s_homeworks_mode = true;
  hw_invalidate_cache();

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
  lv_obj_add_flag(s_list, LV_OBJ_FLAG_SCROLL_ELASTIC);
  lv_obj_add_flag(s_list, LV_OBJ_FLAG_SCROLL_MOMENTUM);
  lv_obj_set_style_anim_time(s_list, 180, 0);
  lv_obj_add_event_cb(s_list, list_scroll_activity_cb, LV_EVENT_SCROLL_BEGIN, NULL);
  lv_obj_add_event_cb(s_list, list_scroll_activity_cb, LV_EVENT_SCROLL_END, NULL);
  lv_obj_add_flag(s_list, LV_OBJ_FLAG_EVENT_BUBBLE);
  screensaver_attach_activity(s_list);

  s_bottom_handle = lv_obj_create(s_stage);
  lv_obj_set_size(s_bottom_handle, 160, 30);
  lv_obj_set_pos(s_bottom_handle, 80, 208);
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

  lv_obj_t* question_btn = lv_btn_create(s_bottom_sheet);
  lv_obj_set_size(question_btn, 50, 50);
  lv_obj_set_style_radius(question_btn, 10, 0);
  lv_obj_set_style_bg_opa(question_btn, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(question_btn, 0, 0);
  lv_obj_set_style_shadow_width(question_btn, 0, 0);
  lv_obj_set_style_translate_x(question_btn, -2, 0);
  lv_obj_t* question_img = lv_img_create(question_btn);
  lv_img_set_src(question_img, &bottom_sheet_question_64);
  lv_obj_set_style_img_recolor(question_img, lv_color_hex(0xC0C0C0), 0);
  lv_obj_set_style_img_recolor_opa(question_img, LV_OPA_COVER, 0);
  lv_img_set_zoom(question_img, 200);
  lv_obj_center(question_img);
  lv_obj_add_event_cb(question_btn, [](lv_event_t* e) {
    lv_indev_t* indev = lv_event_get_indev(e);
    if (!indev) return;
    lv_point_t p;
    lv_indev_get_point(indev, &p);
    s_question_btn_press_x = p.x;
    s_question_btn_press_y = p.y;
    s_question_btn_dragged = false;
  }, LV_EVENT_PRESSED, NULL);
  lv_obj_add_event_cb(question_btn, [](lv_event_t* e) {
    lv_indev_t* indev = lv_event_get_indev(e);
    if (!indev) return;
    lv_point_t p;
    lv_indev_get_point(indev, &p);
    lv_coord_t dx = p.x - s_question_btn_press_x;
    lv_coord_t dy = p.y - s_question_btn_press_y;
    if (dx < 0) dx = -dx;
    if (dy < 0) dy = -dy;
    if (dx > TAP_MOVE_SLOP_PX || dy > TAP_MOVE_SLOP_PX) s_question_btn_dragged = true;
  }, LV_EVENT_PRESSING, NULL);
  lv_obj_add_event_cb(question_btn, [](lv_event_t* e) {
    (void)e;
    if (s_question_btn_dragged || is_tap_suppressed()) return;
    animate_bottom_sheet_to(false);
    show_raise_question_confirm_popup();
  }, LV_EVENT_CLICKED, NULL);

  // home button
  lv_obj_t* home_btn = lv_btn_create(s_bottom_sheet);
  lv_obj_set_size(home_btn, 50, 50);
  lv_obj_set_style_radius(home_btn, 10, 0);
  lv_obj_set_style_bg_opa(home_btn, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(home_btn, 0, 0);
  lv_obj_set_style_shadow_width(home_btn, 0, 0);
  lv_obj_set_style_translate_x(home_btn, 0, 0);
  lv_obj_t* home_img = lv_img_create(home_btn);
  lv_img_set_src(home_img, &home_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
  lv_obj_set_style_img_recolor(home_img, lv_color_hex(0xC0C0C0), 0);
  lv_obj_set_style_img_recolor_opa(home_img, LV_OPA_COVER, 0);
  lv_img_set_zoom(home_img, 200);
  lv_obj_center(home_img);
  lv_obj_add_event_cb(home_btn, [](lv_event_t* e){ (void)e; show_entry_hub_overlay(); }, LV_EVENT_CLICKED, NULL);

  // 추가 (설정은 엔트리 허브에서 유지)
  lv_obj_t* add_btn = lv_btn_create(s_bottom_sheet);
  lv_obj_set_size(add_btn, 50, 50);
  lv_obj_set_style_radius(add_btn, 10, 0);
  lv_obj_set_style_bg_opa(add_btn, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(add_btn, 0, 0);
  lv_obj_set_style_shadow_width(add_btn, 0, 0);
  lv_obj_set_style_translate_x(add_btn, 2, 0);
  lv_obj_t* add_img = lv_img_create(add_btn);
  lv_img_set_src(add_img, &bottom_sheet_add_64);
  lv_obj_set_style_img_recolor(add_img, lv_color_hex(0xC0C0C0), 0);
  lv_obj_set_style_img_recolor_opa(add_img, LV_OPA_COVER, 0);
  lv_img_set_zoom(add_img, 200);
  lv_obj_center(add_img);
  lv_obj_add_event_cb(add_btn, [](lv_event_t* e) {
    (void)e;
    animate_bottom_sheet_to(false);
    show_hw_add_menu_page();
  }, LV_EVENT_CLICKED, NULL);

  s_fab = nullptr;

  // Floating snackbar (z-order above everything in s_stage)
  s_snackbar = lv_obj_create(s_stage);
  lv_obj_set_height(s_snackbar, 38);
  lv_obj_set_style_bg_color(s_snackbar, lv_color_hex(0x232326), 0);
  lv_obj_set_style_bg_opa(s_snackbar, LV_OPA_COVER, 0);
  lv_obj_set_style_border_color(s_snackbar, lv_color_hex(0x2A2A2A), 0);
  lv_obj_set_style_border_width(s_snackbar, 1, 0);
  lv_obj_set_style_radius(s_snackbar, 19, 0);
  lv_obj_set_style_pad_left(s_snackbar, 14, 0);
  lv_obj_set_style_pad_right(s_snackbar, 16, 0);
  lv_obj_set_style_pad_top(s_snackbar, 0, 0);
  lv_obj_set_style_pad_bottom(s_snackbar, 0, 0);
  lv_obj_set_scrollbar_mode(s_snackbar, LV_SCROLLBAR_MODE_OFF);
  lv_obj_clear_flag(s_snackbar, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(s_snackbar, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_flag(s_snackbar, LV_OBJ_FLAG_HIDDEN);
  lv_obj_set_ext_click_area(s_snackbar, 12);
  lv_obj_add_event_cb(s_snackbar, snackbar_clicked_cb, LV_EVENT_CLICKED, NULL);

  s_snackbar_dot = lv_obj_create(s_snackbar);
  lv_obj_set_size(s_snackbar_dot, 8, 8);
  lv_obj_set_style_radius(s_snackbar_dot, LV_RADIUS_CIRCLE, 0);
  lv_obj_set_style_bg_opa(s_snackbar_dot, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_snackbar_dot, 0, 0);
  lv_obj_set_style_pad_all(s_snackbar_dot, 0, 0);
  lv_obj_align(s_snackbar_dot, LV_ALIGN_LEFT_MID, 0, 0);
  lv_obj_add_flag(s_snackbar_dot, LV_OBJ_FLAG_HIDDEN);

  s_snackbar_lbl = lv_label_create(s_snackbar);
  lv_obj_set_style_text_font(s_snackbar_lbl, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(s_snackbar_lbl, lv_color_white(), 0);
  lv_label_set_text(s_snackbar_lbl, "");
  lv_obj_align(s_snackbar_lbl, LV_ALIGN_LEFT_MID, 12, 0);

  lv_obj_set_width(s_snackbar, LV_SIZE_CONTENT);
  lv_obj_align(s_snackbar, LV_ALIGN_TOP_MID, 0, 2);

  s_snackbar_type = 0;
  s_first_p4_card_idx = -1;
  s_rest_mode = false;

  // Re-attach screensaver activity handlers
  screensaver_attach_activity(lv_scr_act());
}

static void on_screensaver_wake(void) {
  ui_after_screensaver_wake();
  if (s_homeworks_mode && is_entry_hub_visible()) {
    hub_clock_timer_cb(nullptr);
    if (!s_hub_clock_timer) {
      s_hub_clock_timer = lv_timer_create(hub_clock_timer_cb, 30000, NULL);
      lv_timer_set_repeat_count(s_hub_clock_timer, -1);
    }
  }
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
  screensaver_set_wake_callback(on_screensaver_wake);
}

void ui_port_set_global_font(const lv_font_t* font) {
  s_global_font = font;
  if (s_stage && lv_obj_is_valid(s_stage)) lv_obj_set_style_text_font(s_stage, s_global_font, 0);
}

void ui_before_screen_change(void) {
  if (g_bottom_sheet_open) {
    toggle_bottom_sheet();
  }
  close_bind_confirm_popup();
  close_raise_question_confirm_popup();
  close_test_start_confirm_popup();
  close_test_abort_confirm_popup();
  close_confirm_to_wait_popup();
  close_student_info_screen(false);
  close_stopwatch_screen(false);
  close_hw_add_menu_page();
  if (s_hub_clock_timer) { lv_timer_del(s_hub_clock_timer); s_hub_clock_timer = nullptr; }
  close_volume_popup();
  close_brightness_popup();
}

// 화면보호기 전용: 오버레이를 삭제하지 않고 숨기기만 해서 복귀 시 복원
void ui_before_screensaver(void) {
  if (g_bottom_sheet_open) toggle_bottom_sheet();
  close_bind_confirm_popup();
  close_raise_question_confirm_popup();
  close_test_start_confirm_popup();
  close_test_abort_confirm_popup();
  close_confirm_to_wait_popup();
  close_volume_popup();
  close_brightness_popup();
  if (s_hub_clock_timer) { lv_timer_del(s_hub_clock_timer); s_hub_clock_timer = nullptr; }
  s_screensaver_hid_student_info = false;
  s_screensaver_hid_stopwatch = false;
  if (s_student_info_screen && lv_obj_is_valid(s_student_info_screen)) {
    lv_obj_add_flag(s_student_info_screen, LV_OBJ_FLAG_HIDDEN);
    s_screensaver_hid_student_info = true;
  }
  if (s_stopwatch_screen && lv_obj_is_valid(s_stopwatch_screen)) {
    lv_obj_add_flag(s_stopwatch_screen, LV_OBJ_FLAG_HIDDEN);
    s_screensaver_hid_stopwatch = true;
  }
  s_screensaver_hid_hw_add_menu = false;
  if (s_hw_add_menu_screen && lv_obj_is_valid(s_hw_add_menu_screen)) {
    lv_obj_add_flag(s_hw_add_menu_screen, LV_OBJ_FLAG_HIDDEN);
    s_screensaver_hid_hw_add_menu = true;
  }
}

void ui_port_force_unbind(void) {
  s_hw_refresh_pending = false;
  hw_invalidate_cache();
  close_hw_add_menu_page();
  if (!s_homeworks_mode) return;
  s_hw_updating = false;
  extern void screensaver_dismiss(void);
  screensaver_dismiss();
  build_student_list_ui();
  fw_publish_list_today();
}

void ui_after_screensaver_wake(void) {
  if (s_screensaver_hid_student_info && s_student_info_screen && lv_obj_is_valid(s_student_info_screen)) {
    lv_obj_clear_flag(s_student_info_screen, LV_OBJ_FLAG_HIDDEN);
  }
  s_screensaver_hid_student_info = false;
  if (s_screensaver_hid_stopwatch && s_stopwatch_screen && lv_obj_is_valid(s_stopwatch_screen)) {
    lv_obj_clear_flag(s_stopwatch_screen, LV_OBJ_FLAG_HIDDEN);
  }
  s_screensaver_hid_stopwatch = false;
  if (s_screensaver_hid_hw_add_menu && s_hw_add_menu_screen && lv_obj_is_valid(s_hw_add_menu_screen)) {
    lv_obj_clear_flag(s_hw_add_menu_screen, LV_OBJ_FLAG_HIDDEN);
  }
  s_screensaver_hid_hw_add_menu = false;
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
  
  int32_t raw = M5.Power.getBatteryLevel();
  int level = (raw < 0 || raw > 100) ? -1 : (int)raw;
  bool charging = M5.Power.isCharging();
  
  if (s_battery_label && lv_obj_is_valid(s_battery_label)) {
    if (level < 0) lv_label_set_text(s_battery_label, "--%");
    else lv_label_set_text_fmt(s_battery_label, "%d%%", level);
  }
  if (level < 0) level = 0;
  
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

static void update_hub_battery(void) {
  if (!s_hub_battery_widget || !lv_obj_is_valid(s_hub_battery_widget)) return;
  int32_t raw = M5.Power.getBatteryLevel();
  int level = (raw < 0 || raw > 100) ? -1 : (int)raw;
  bool charging = M5.Power.isCharging();
  if (s_hub_battery_label && lv_obj_is_valid(s_hub_battery_label)) {
    if (level < 0) lv_label_set_text(s_hub_battery_label, "--%");
    else lv_label_set_text_fmt(s_hub_battery_label, "%d%%", level);
  }
  lv_obj_t* bat_img = lv_obj_get_child(s_hub_battery_widget, 1);
  if (!bat_img) return;
  if (level < 0) level = 0;
  const lv_img_dsc_t* icon = nullptr;
  if (charging) icon = &battery_android_bolt_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  else if (level <= 1) icon = &battery_android_alert_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  else if (level <= 5) icon = &battery_android_frame_1_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  else if (level <= 20) icon = &battery_android_frame_2_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  else if (level <= 35) icon = &battery_android_frame_3_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  else if (level <= 50) icon = &battery_android_frame_4_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  else if (level <= 65) icon = &battery_android_frame_5_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  else if (level <= 80) icon = &battery_android_frame_6_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  else icon = &battery_android_frame_full_32dp_999999_FILL0_wght400_GRAD0_opsz40;
  lv_img_set_src(bat_img, icon);
  lv_obj_set_style_img_recolor(bat_img, lv_color_hex(0xC0C0C0), 0);
  lv_obj_set_style_img_recolor_opa(bat_img, LV_OPA_COVER, 0);
}

static void hub_clock_timer_cb(lv_timer_t* timer) {
  (void)timer;
  if (s_hub_clock_label && lv_obj_is_valid(s_hub_clock_label)) {
    struct tm ti;
    if (getLocalTime(&ti, 0)) {
      char buf[8];
      snprintf(buf, sizeof(buf), "%02d:%02d", ti.tm_hour, ti.tm_min);
      lv_label_set_text(s_hub_clock_label, buf);
    }
  }
  update_hub_battery();
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
    int sh = s.containsKey("start_hour") ? (int)s["start_hour"] : -1;
    int sm = s.containsKey("start_minute") ? (int)s["start_minute"] : -1;
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
    lv_obj_set_style_text_font(lbl, &kakao_kr_24, 0);
    lv_label_set_text(lbl, name);
    lv_label_set_long_mode(lbl, LV_LABEL_LONG_DOT);
    lv_obj_set_width(lbl, 180);
    lv_obj_align(lbl, LV_ALIGN_LEFT_MID, 0, -14);
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
      lv_obj_align(meta_lbl, LV_ALIGN_RIGHT_MID, -6, -14);
    }
    if (sh >= 0 && sm >= 0) {
      char time_buf[32];
      snprintf(time_buf, sizeof(time_buf), "%d:%02d %s", sh, sm, u8"수업");
      lv_obj_t* time_lbl = lv_label_create(card);
      lv_obj_set_style_text_color(time_lbl, lv_color_hex(0x707070), 0);
      lv_obj_set_style_text_font(time_lbl, &kakao_kr_16, 0);
      lv_label_set_text(time_lbl, time_buf);
      lv_obj_align(time_lbl, LV_ALIGN_RIGHT_MID, -6, 12);
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
          if (is_tap_suppressed()) return;
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

// Debounce: 그룹 순서/상태 연속 변경 시 최종 상태 누락 방지를 위해 기본 비활성화
static uint32_t s_last_homework_update_ms = 0;
static const uint32_t HOMEWORK_UPDATE_DEBOUNCE_MS = 0;
// 카드 클릭 디바운스 (500ms)
static uint32_t s_last_card_click_ms = 0;
static const uint32_t CARD_CLICK_DEBOUNCE_MS = 500;

static void extract_content_marker_value(const char* content, const char* marker, char* out, size_t out_sz) {
  if (!out || out_sz == 0) return;
  out[0] = '\0';
  if (!content || !*content || !marker || !*marker) return;
  const char* pos = strstr(content, marker);
  if (!pos) return;
  const char* start = pos + strlen(marker);
  while (*start == ' ' || *start == '\t') start++;
  const char* end = strchr(start, '\n');
  size_t len = end ? (size_t)(end - start) : strlen(start);
  while (len > 0 && (start[len - 1] == ' ' || start[len - 1] == '\r' || start[len - 1] == '\t')) len--;
  if (len > out_sz - 1) len = out_sz - 1;
  memcpy(out, start, len);
  out[len] = '\0';
}

static void extract_book_name(const char* content, const char* title, const char* book_id, const char* grade_label, const char* hw_type, char* out, size_t out_sz) {
  out[0] = '\0';
  char book_buf[96] = {0};
  char course_buf[32] = {0};

  // 1) 교재명 우선
  extract_content_marker_value(content, u8"교재:", book_buf, sizeof(book_buf));

  // 2) 과정은 grade_label 우선, 없으면 content의 "과정:"에서 추출
  if (grade_label && *grade_label) {
    strncpy(course_buf, grade_label, sizeof(course_buf) - 1);
    course_buf[sizeof(course_buf) - 1] = '\0';
  } else {
    extract_content_marker_value(content, u8"과정:", course_buf, sizeof(course_buf));
  }

  // 3) 교재/과정 정보가 비어있을 때만 제목을 fallback으로 파싱
  if (!book_buf[0] && title && *title) {
    const char* dot = strstr(title, u8"·");
    if (dot) {
      size_t len = (size_t)(dot - title);
      while (len > 0 && (title[len - 1] == ' ' || title[len - 1] == '\t')) len--;
      if (len > sizeof(book_buf) - 1) len = sizeof(book_buf) - 1;
      memcpy(book_buf, title, len);
      book_buf[len] = '\0';
    }
  }
  if (!course_buf[0] && title && *title) {
    const char* dot = strstr(title, u8"·");
    if (dot) {
      const char* start = dot + strlen(u8"·");
      while (*start == ' ' || *start == '\t') start++;
      size_t len = strlen(start);
      while (len > 0 && (start[len - 1] == ' ' || start[len - 1] == '\t')) len--;
      if (len > sizeof(course_buf) - 1) len = sizeof(course_buf) - 1;
      memcpy(course_buf, start, len);
      course_buf[len] = '\0';
    }
  }

  // 4) 최종 1열: "교재명 · 과정"
  if (book_buf[0] && course_buf[0]) {
    if (strstr(book_buf, course_buf)) {
      strncpy(out, book_buf, out_sz - 1);
      out[out_sz - 1] = '\0';
    } else {
      snprintf(out, out_sz, "%s · %s", book_buf, course_buf);
    }
    return;
  }
  if (book_buf[0]) {
    strncpy(out, book_buf, out_sz - 1);
    out[out_sz - 1] = '\0';
    return;
  }
  if (course_buf[0]) {
    strncpy(out, course_buf, out_sz - 1);
    out[out_sz - 1] = '\0';
    return;
  }
  if (hw_type && *hw_type) {
    strncpy(out, hw_type, out_sz - 1);
    out[out_sz - 1] = '\0';
    return;
  }
  if (title && *title) {
    strncpy(out, title, out_sz - 1);
    out[out_sz - 1] = '\0';
    return;
  }
  if (book_id && *book_id) {
    strncpy(out, book_id, out_sz - 1);
    out[out_sz - 1] = '\0';
  }
}

static void fmt_time_static(int secs, char* buf, size_t sz) {
  int h = secs / 3600; int m = (secs % 3600) / 60;
  if (h > 0) snprintf(buf, sz, "%dh %dm", h, m);
  else snprintf(buf, sz, "%dm", m);
}

static void fmt_time_hms(int secs, char* buf, size_t sz) {
  int h = secs / 3600; int m = (secs % 3600) / 60; int s = secs % 60;
  if (h > 0) snprintf(buf, sz, "%dh %dm %ds", h, m, s);
  else if (m > 0) snprintf(buf, sz, "%dm %ds", m, s);
  else snprintf(buf, sz, "%ds", s);
}

static int64_t days_from_civil_utc(int y, unsigned m, unsigned d) {
  y -= (m <= 2) ? 1 : 0;
  const int era = (y >= 0 ? y : y - 399) / 400;
  const unsigned yoe = (unsigned)(y - era * 400);                       // [0, 399]
  const int mp = (int)m + (m > 2 ? -3 : 9);
  const unsigned doy = (153u * (unsigned)mp + 2) / 5 + d - 1; // [0, 365]
  const unsigned doe = yoe * 365u + yoe / 4u - yoe / 100u + doy;        // [0, 146096]
  return (int64_t)era * 146097 + (int64_t)doe - 719468;                 // days since 1970-01-01
}

static int64_t parse_iso8601_epoch(const char* iso) {
  if (!iso || !*iso) return 0;
  int y = 0, mon = 0, day = 0, hh = 0, mm = 0, ss = 0;
  int n = 0;
  if (sscanf(iso, "%4d-%2d-%2dT%2d:%2d:%2d%n", &y, &mon, &day, &hh, &mm, &ss, &n) < 6) {
    return 0;
  }

  const char* p = iso + n;
  if (*p == '.') {
    p++;
    while (*p && isdigit((unsigned char)*p)) p++;
  }

  int tz_sign = 0;
  int tz_h = 0;
  int tz_m = 0;
  if (*p == '+' || *p == '-') {
    tz_sign = (*p == '-') ? -1 : 1;
    p++;
    if (isdigit((unsigned char)p[0]) && isdigit((unsigned char)p[1])) {
      tz_h = (p[0] - '0') * 10 + (p[1] - '0');
      p += 2;
    }
    if (*p == ':') p++;
    if (isdigit((unsigned char)p[0]) && isdigit((unsigned char)p[1])) {
      tz_m = (p[0] - '0') * 10 + (p[1] - '0');
    }
  }

  int64_t epoch =
      days_from_civil_utc(y, (unsigned)mon, (unsigned)day) * 86400LL +
      (int64_t)hh * 3600LL + (int64_t)mm * 60LL + (int64_t)ss;
  if (tz_sign != 0) {
    epoch -= (int64_t)tz_sign * ((int64_t)tz_h * 3600LL + (int64_t)tz_m * 60LL);
  }
  return epoch;
}

static void fmt_time_cycle_clock(int secs, char* buf, size_t sz) {
  if (secs < 0) secs = 0;
  int h = secs / 3600;
  int m = (secs % 3600) / 60;
  int s = secs % 60;
  snprintf(buf, sz, "%d:%02d:%02d", h, m, s);
}

static void fmt_time_hms_fixed(int secs, char* buf, size_t sz) {
  if (secs < 0) secs = 0;
  int h = secs / 3600;
  int m = (secs % 3600) / 60;
  int s = secs % 60;
  snprintf(buf, sz, "%dh %02dm %02ds", h, m, s);
}

static void apply_detail_play_button_visual(bool playing_now) {
  const uint32_t play_bg = 0x1B8F50;
  const uint32_t stop_bg = 0x181818;
  const uint32_t icon_gray = 0xAEAEAE;
  const uint32_t bg = playing_now ? stop_bg : play_bg;

  if (s_hw_detail_play_btn && lv_obj_is_valid(s_hw_detail_play_btn)) {
    lv_color_t base = lv_color_hex(bg);
    lv_obj_set_style_bg_color(s_hw_detail_play_btn, base, LV_STATE_DEFAULT);
    lv_obj_set_style_bg_color(s_hw_detail_play_btn, lv_color_darken(base, LV_OPA_20), LV_STATE_PRESSED);
  }
  if (s_hw_detail_play_img && lv_obj_is_valid(s_hw_detail_play_img)) {
    lv_img_set_src(s_hw_detail_play_img, playing_now
      ? &stop_100dp_999999_FILL0_wght400_GRAD0_opsz48
      : &play_arrow_100dp_999999_FILL0_wght400_GRAD0_opsz48);
    lv_obj_set_style_img_recolor(s_hw_detail_play_img, lv_color_hex(icon_gray), 0);
    lv_obj_set_style_img_recolor_opa(s_hw_detail_play_img, LV_OPA_COVER, 0);
  }
}

static void update_detail_play_button_visual(void) {
  apply_detail_play_button_visual(s_detail_playing);
}

static lv_obj_t* create_hw_card(lv_obj_t* parent, int group_idx) {
  extern const lv_font_t kakao_kr_16;
  if (group_idx < 0 || group_idx >= s_group_cnt) return nullptr;
  HwGroupData& g = s_groups[group_idx];
  int phase = g.phase;
  static const uint32_t srv_color = 0x33A373;

  lv_obj_t* card = lv_obj_create(parent);
  lv_obj_set_width(card, lv_pct(100));
  lv_obj_set_height(card, 96);
  lv_obj_set_style_radius(card, 20, 0);
  lv_obj_set_style_bg_color(card, lv_color_hex(0x1A1A1A), 0);
  lv_obj_set_style_border_color(card, lv_color_hex(0x2C2C2C), 0);
  lv_obj_set_style_border_width(card, 1, 0);
  lv_obj_set_style_pad_top(card, 9, 0);
  lv_obj_set_style_pad_bottom(card, 10, 0);
  lv_obj_set_style_pad_left(card, 22, 0);
  lv_obj_set_style_pad_right(card, 22, 0);
  lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(card, LV_OBJ_FLAG_CLICKABLE);

  const bool is_test_card = hw_is_test_group(g);

  // 1열 좌: 비테스트는 교재명; 테스트는 항상「테스트」(24pt)
  lv_obj_t* title_lbl = lv_label_create(card);
  lv_obj_set_style_text_font(title_lbl, &kakao_kr_24, 0);
  lv_obj_set_style_text_color(title_lbl, lv_color_hex(0xE6E6E6), 0);
  if (is_test_card) {
    lv_label_set_text(title_lbl, u8"테스트");
  } else {
    lv_label_set_text(title_lbl, g.book_name);
  }
  lv_label_set_long_mode(title_lbl, LV_LABEL_LONG_DOT);
  lv_obj_set_width(title_lbl, lv_pct(100));
  lv_obj_align(title_lbl, LV_ALIGN_TOP_LEFT, 0, 3);
  lv_obj_add_flag(title_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);

  // phase별 카드 강조 스타일
  if (phase == 2) {
    lv_obj_set_style_outline_color(card, lv_color_hex(srv_color), 0);
    lv_obj_set_style_outline_width(card, 2, 0);
    lv_obj_set_style_outline_pad(card, 1, 0);
    lv_obj_set_style_shadow_width(card, 10, 0);
    lv_obj_set_style_shadow_color(card, lv_color_hex(srv_color), 0);
    lv_obj_set_style_shadow_opa(card, LV_OPA_20, 0);
  } else if (phase == 4) {
    lv_obj_set_style_bg_color(card, lv_color_hex(0x202020), 0);
    lv_obj_set_style_outline_color(card, lv_color_hex(srv_color), 0);
    lv_obj_set_style_outline_width(card, 2, 0);
    lv_obj_set_style_outline_pad(card, 1, 0);
    lv_obj_set_style_outline_opa(card, LV_OPA_TRANSP, 0);
    if (s_p4_cnt < 8) { s_p4_cards[s_p4_cnt] = card; s_p4_colors[s_p4_cnt] = srv_color; s_p4_cnt++; }
  }

  // 페이지·문항 문자열 (테스트 2열: 그룹명 없을 때 폴백)
  char page_count_buf[64] = {0};
  {
    const char* page = g.page_summary;
    int count = g.total_count;
    if (*page && count > 0) snprintf(page_count_buf, sizeof(page_count_buf), "p.%s · %d%s", page, count, u8"문항");
    else if (*page) snprintf(page_count_buf, sizeof(page_count_buf), "p.%s", page);
    else if (count > 0) snprintf(page_count_buf, sizeof(page_count_buf), "%d%s", count, u8"문항");
  }

  // 2열 좌: 테스트는 그룹 과제명; 비테스트는 기존
  if (phase == 3) {
    if (is_test_card) {
      const char* sub = g.group_title[0] ? g.group_title : page_count_buf;
      if (sub[0]) {
        lv_obj_t* pc_lbl = lv_label_create(card);
        lv_obj_set_style_text_font(pc_lbl, &kakao_kr_16, 0);
        lv_obj_set_style_text_color(pc_lbl, lv_color_hex(0x909090), 0);
        lv_label_set_text(pc_lbl, sub);
        lv_label_set_long_mode(pc_lbl, LV_LABEL_LONG_DOT);
        lv_obj_set_width(pc_lbl, lv_pct(55));
        lv_obj_align(pc_lbl, LV_ALIGN_TOP_LEFT, 0, 36);
        lv_obj_add_flag(pc_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
      }
    } else {
      lv_obj_t* pc_lbl = lv_label_create(card);
      lv_obj_set_style_text_font(pc_lbl, &kakao_kr_16, 0);
      lv_obj_set_style_text_color(pc_lbl, lv_color_hex(0x909090), 0);
      lv_label_set_text(pc_lbl, g.group_title);
      lv_label_set_long_mode(pc_lbl, LV_LABEL_LONG_DOT);
      lv_obj_set_width(pc_lbl, lv_pct(55));
      lv_obj_align(pc_lbl, LV_ALIGN_TOP_LEFT, 0, 36);
      lv_obj_add_flag(pc_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
    }
    if (g.accumulated > 0) {
      char tb[32]; fmt_time_hms(g.accumulated, tb, sizeof(tb));
      lv_obj_t* tl = lv_label_create(card);
      lv_obj_set_style_text_font(tl, &kakao_kr_16, 0);
      lv_obj_set_style_text_color(tl, lv_color_hex(0x808080), 0);
      lv_label_set_text(tl, tb);
      lv_obj_align(tl, LV_ALIGN_TOP_RIGHT, 0, 36);
      lv_obj_add_flag(tl, LV_OBJ_FLAG_EVENT_BUBBLE);
    }
  } else {
    const bool learning_group = (strcmp(g.item_type, u8"학습") == 0);
    if (is_test_card) {
      const char* sub = g.group_title[0] ? g.group_title : page_count_buf;
      if (sub[0]) {
        lv_obj_t* pc_lbl = lv_label_create(card);
        lv_obj_set_style_text_font(pc_lbl, &kakao_kr_16, 0);
        lv_obj_set_style_text_color(pc_lbl, lv_color_hex(0x909090), 0);
        lv_label_set_text(pc_lbl, sub);
        lv_label_set_long_mode(pc_lbl, LV_LABEL_LONG_DOT);
        lv_obj_set_width(pc_lbl, lv_pct(100));
        lv_obj_align(pc_lbl, LV_ALIGN_TOP_LEFT, 0, 36);
        lv_obj_add_flag(pc_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
      }
    } else if (learning_group && g.group_title[0]) {
      lv_obj_t* pc_lbl = lv_label_create(card);
      lv_obj_set_style_text_font(pc_lbl, &kakao_kr_16, 0);
      lv_obj_set_style_text_color(pc_lbl, lv_color_hex(0x909090), 0);
      lv_label_set_text(pc_lbl, g.group_title);
      lv_label_set_long_mode(pc_lbl, LV_LABEL_LONG_DOT);
      lv_obj_set_width(pc_lbl, lv_pct(100));
      lv_obj_align(pc_lbl, LV_ALIGN_TOP_LEFT, 0, 36);
      lv_obj_add_flag(pc_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
    } else if (page_count_buf[0]) {
      lv_obj_t* pc_lbl = lv_label_create(card);
      lv_obj_set_style_text_font(pc_lbl, &kakao_kr_16, 0);
      lv_obj_set_style_text_color(pc_lbl, lv_color_hex(0x909090), 0);
      lv_label_set_text(pc_lbl, page_count_buf);
      lv_label_set_long_mode(pc_lbl, LV_LABEL_LONG_DOT);
      lv_obj_set_width(pc_lbl, lv_pct(100));
      lv_obj_align(pc_lbl, LV_ALIGN_TOP_LEFT, 0, 36);
      lv_obj_add_flag(pc_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
    }
  }

  // 3열 우: phase별 상태(기존 1열 우 위젯 이동)
  const lv_coord_t status_y = 58;
  if (phase == 1) {
    char try_buf[32];
    snprintf(try_buf, sizeof(try_buf), u8"%d번째 시도", g.check_count + 1);
    lv_obj_t* hint = lv_label_create(card);
    lv_obj_set_style_text_font(hint, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(hint, lv_color_hex(0x33A373), 0);
    lv_label_set_text(hint, try_buf);
    lv_obj_align(hint, LV_ALIGN_TOP_RIGHT, 0, status_y);
    lv_obj_add_flag(hint, LV_OBJ_FLAG_EVENT_BUBBLE);
  } else if (phase == 2) {
    lv_obj_t* time_lbl = lv_label_create(card);
    lv_obj_set_style_text_font(time_lbl, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(time_lbl, lv_color_hex(srv_color), 0);
    lv_obj_align(time_lbl, LV_ALIGN_TOP_RIGHT, 0, status_y);
    lv_obj_add_flag(time_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
    {
      int seg = hw_live_segment_sec(g, lv_tick_get());
      int total = (int)g.accumulated + seg;
      if (total < 0) total = 0;
      char tb[32]; fmt_time_static((uint32_t)total, tb, sizeof(tb));
      lv_label_set_text(time_lbl, tb);
    }
    if (s_p2_cnt < 8) { s_p2_entries[s_p2_cnt] = {time_lbl, (uint8_t)group_idx}; s_p2_cnt++; }
  } else if (phase == 3) {
    char chk_buf[32];
    int chk_n = g.check_count < 0 ? 0 : g.check_count;
    snprintf(chk_buf, sizeof(chk_buf), u8"%d번째 검사중...", chk_n);
    lv_obj_t* wh = lv_label_create(card);
    lv_obj_set_style_text_font(wh, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(wh, lv_color_hex(0x808080), 0);
    lv_label_set_text(wh, chk_buf);
    lv_obj_align(wh, LV_ALIGN_TOP_RIGHT, 0, status_y);
    lv_obj_add_flag(wh, LV_OBJ_FLAG_EVENT_BUBBLE);
  } else if (phase == 4) {
    lv_obj_t* h4 = lv_label_create(card);
    lv_obj_set_style_text_font(h4, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(h4, lv_color_hex(srv_color), 0);
    lv_label_set_text(h4, u8"확인 >");
    lv_obj_align(h4, LV_ALIGN_TOP_RIGHT, 0, status_y);
    lv_obj_add_flag(h4, LV_OBJ_FLAG_EVENT_BUBBLE);
  }

  // 클릭 핸들러
  struct HwCardData {
    int group_idx;
    char group_id[40];
    int phase;
    lv_coord_t press_x;
    lv_coord_t press_y;
    bool dragged;
  };
  HwCardData* d = (HwCardData*)malloc(sizeof(HwCardData));
  if (d) {
    d->group_idx = group_idx;
    strncpy(d->group_id, g.group_id, sizeof(d->group_id)-1);
    d->group_id[sizeof(d->group_id)-1] = '\0';
    d->phase = phase;
    d->press_x = 0;
    d->press_y = 0;
    d->dragged = false;
    lv_obj_add_event_cb(card, [](lv_event_t* e){
      HwCardData* dd = (HwCardData*)lv_event_get_user_data(e);
      if (!dd) return;
      dd->dragged = false;
      lv_indev_t* indev = lv_event_get_indev(e);
      if (indev) {
        lv_point_t p;
        lv_indev_get_point(indev, &p);
        dd->press_x = p.x;
        dd->press_y = p.y;
      }
    }, LV_EVENT_PRESSED, d);
    lv_obj_add_event_cb(card, [](lv_event_t* e){
      HwCardData* dd = (HwCardData*)lv_event_get_user_data(e);
      if (!dd || dd->dragged) return;
      lv_indev_t* indev = lv_event_get_indev(e);
      if (!indev) return;
      lv_point_t p;
      lv_indev_get_point(indev, &p);
      lv_coord_t dx = p.x - dd->press_x;
      lv_coord_t dy = p.y - dd->press_y;
      if (dx < 0) dx = -dx;
      if (dy < 0) dy = -dy;
      if (dx > TAP_MOVE_SLOP_PX || dy > TAP_MOVE_SLOP_PX) {
        dd->dragged = true;
        suppress_tap_temporarily();
      }
    }, LV_EVENT_PRESSING, d);
    lv_obj_add_event_cb(card, [](lv_event_t* e){
      HwCardData* dd = (HwCardData*)lv_event_get_user_data(e);
      if (!dd || dd->dragged || is_tap_suppressed()) return;
      uint32_t now = millis();
      if (now - s_last_card_click_ms < CARD_CLICK_DEBOUNCE_MS) return;
      s_last_card_click_ms = now;
      if (dd->phase == 1) {
        if (hw_is_test_group(s_groups[dd->group_idx])) {
          show_test_start_confirm_popup(dd->group_idx);
        } else {
          if (!fw_publish_group_transition(dd->group_id, 1)) return;
          show_homework_detail_page(dd->group_idx);
          s_detail_playing = true;
          s_detail_manual_override_playing = true;
          s_detail_manual_override_until_ms = millis() + 5000;
          update_detail_play_button_visual();
        }
      } else if (dd->phase == 2) {
        show_homework_detail_page(dd->group_idx);
        s_detail_playing = true;
        s_detail_manual_override_playing = true;
        s_detail_manual_override_until_ms = millis() + 5000;
        update_detail_play_button_visual();
      } else if (dd->phase == 4) {
        show_confirm_phase_to_waiting_popup(dd->group_id, dd->group_idx);
      }
    }, LV_EVENT_CLICKED, d);
    lv_obj_add_event_cb(card, [](lv_event_t* e){
      if (lv_event_get_code(e) == LV_EVENT_DELETE) { void* ud = lv_event_get_user_data(e); if (ud) free(ud); }
    }, LV_EVENT_DELETE, d);
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

struct HwDisplayAnchorSnap {
  char group_id[40];
  int8_t phase;
  int32_t cycle_elapsed;
  int64_t run_start_epoch;
  bool anchor_valid;
  uint32_t anchor_tick;
  int32_t segment0_sec;
};

static void hw_snapshot_display_anchors(HwDisplayAnchorSnap* snaps, uint8_t* out_cnt) {
  *out_cnt = 0;
  for (uint8_t i = 0; i < s_group_cnt && *out_cnt < 6; i++) {
    HwDisplayAnchorSnap& s = snaps[*out_cnt];
    strncpy(s.group_id, s_groups[i].group_id, sizeof(s.group_id) - 1);
    s.group_id[sizeof(s.group_id) - 1] = '\0';
    s.phase = s_groups[i].phase;
    s.cycle_elapsed = s_groups[i].cycle_elapsed;
    s.run_start_epoch = s_groups[i].run_start_epoch;
    s.anchor_valid = s_groups[i].display_anchor_valid;
    s.anchor_tick = s_groups[i].display_anchor_tick;
    s.segment0_sec = s_groups[i].display_segment0_sec;
    (*out_cnt)++;
  }
}

static void hw_apply_display_anchors_after_parse(const HwDisplayAnchorSnap* snaps, uint8_t snap_cnt) {
  for (uint8_t i = 0; i < s_group_cnt; i++) {
    HwGroupData& g = s_groups[i];
    if (g.phase != 2) {
      g.display_anchor_valid = false;
      g.display_anchor_run_start = 0;
      g.display_anchor_tick = 0;
      g.display_segment0_sec = 0;
      continue;
    }

    // m5_list_homework_groups payload accumulated/cycle_elapsed are already
    // server-live values. Local segment must represent only "since payload arrived".
    const uint32_t now_tick = lv_tick_get();
    const bool has_server_start = g.run_start_epoch > 0;
    const HwDisplayAnchorSnap* same_group_snap = nullptr;
    bool same_anchor_key = false;
    for (uint8_t j = 0; j < snap_cnt; j++) {
      const HwDisplayAnchorSnap& sn = snaps[j];
      if (strcmp(sn.group_id, g.group_id) != 0) continue;

      if (!same_group_snap) same_group_snap = &sn;
      if (!sn.anchor_valid) continue;

      if (has_server_start) {
        same_anchor_key = (sn.run_start_epoch == g.run_start_epoch);
      } else {
        same_anchor_key = (sn.run_start_epoch <= 0);
      }
      if (same_anchor_key) break;
    }

    g.display_anchor_valid = true;
    g.display_anchor_run_start = g.run_start_epoch;
    g.display_anchor_tick = now_tick;

    int seg0 = 0;
    if (!same_anchor_key && !has_server_start && same_group_snap) {
      // transient gap(run_start missing) during phase=2: keep local monotonic flow
      uint32_t dt = now_tick - same_group_snap->anchor_tick;
      seg0 = same_group_snap->segment0_sec + (int)(dt / 1000);
      if (seg0 < 0) seg0 = 0;
    }
    g.display_segment0_sec = seg0;

    // Cycle elapsed must not reset on pause/resume.
    // Reset is allowed only when entering submit phase(phase=3).
    if (g.phase == 3) {
      g.cycle_elapsed = 0;
    } else if (same_group_snap &&
               same_group_snap->phase != 3 &&
               g.cycle_elapsed < same_group_snap->cycle_elapsed) {
      g.cycle_elapsed = same_group_snap->cycle_elapsed;
    }
    if (g.cycle_elapsed < 0) g.cycle_elapsed = 0;
  }
}

static void parse_groups_from_json(const JsonArray& groups) {
  s_group_cnt = 0;
  for (JsonObject grp : groups) {
    if (s_group_cnt >= 6) break;
    HwGroupData& g = s_groups[s_group_cnt];
    const char* gid = grp["group_id"] | "";
    strncpy(g.group_id, gid, sizeof(g.group_id)-1); g.group_id[sizeof(g.group_id)-1] = '\0';
    const char* gt = grp["group_title"] | u8"과제 그룹";
    strncpy(g.group_title, gt, sizeof(g.group_title)-1); g.group_title[sizeof(g.group_title)-1] = '\0';
    const char* ps = grp["page_summary"] | "";
    strncpy(g.page_summary, ps, sizeof(g.page_summary)-1); g.page_summary[sizeof(g.page_summary)-1] = '\0';
    g.phase = grp.containsKey("phase") ? (int)grp["phase"] : 1;
    g.accumulated = grp.containsKey("accumulated") ? (int)grp["accumulated"] : 0;
    g.cycle_elapsed = grp.containsKey("cycle_elapsed") ? (int)grp["cycle_elapsed"] : 0;
    g.check_count = grp.containsKey("check_count") ? (int)grp["check_count"] : 0;
    g.total_count = grp.containsKey("total_count") ? (int)grp["total_count"] : 0;
    g.time_limit_minutes = 0;
    if (grp.containsKey("time_limit_minutes") && !grp["time_limit_minutes"].isNull()) {
      int tlm = (int)grp["time_limit_minutes"];
      if (tlm < 0) tlm = 0;
      if (tlm > 24 * 60) tlm = 24 * 60;
      g.time_limit_minutes = (int16_t)tlm;
    }
    g.color = 0x1E88E5;
    if (grp.containsKey("color")) { double v = grp["color"]; if (v > 0) g.color = ((uint32_t)v) & 0xFFFFFFu; }
    g.run_start_epoch = 0;
    if (grp.containsKey("run_start") && !grp["run_start"].isNull()) {
      const char* rs = grp["run_start"] | "";
      if (*rs) {
        g.run_start_epoch = parse_iso8601_epoch(rs);
      }
    }
    const char* content = grp["content"] | "";
    const char* hw_type = grp["type"] | "";
    strncpy(g.item_type, hw_type, sizeof(g.item_type) - 1);
    g.item_type[sizeof(g.item_type) - 1] = '\0';
    const char* book_id = grp["book_id"] | "";
    const char* grade_label = grp["grade_label"] | "";
    extract_book_name(content, gt, book_id, grade_label, hw_type, g.book_name, sizeof(g.book_name));
    if (!g.book_name[0]) strncpy(g.book_name, gt, sizeof(g.book_name)-1);

    g.m5_wait_title[0] = '\0';
    if (grp.containsKey("m5_wait_title") && !grp["m5_wait_title"].isNull()) {
      const char* wt = grp["m5_wait_title"] | "";
      if (*wt) {
        strncpy(g.m5_wait_title, wt, sizeof(g.m5_wait_title) - 1);
        g.m5_wait_title[sizeof(g.m5_wait_title) - 1] = '\0';
      }
    }

    // children
    g.child_cnt = 0;
    if (grp.containsKey("children")) {
      JsonArray ch = grp["children"].as<JsonArray>();
      for (JsonObject c : ch) {
        if (g.child_cnt >= 8) break;
        HwChildEntry& ce = g.children[g.child_cnt];
        const char* cid = c["item_id"] | "";
        strncpy(ce.item_id, cid, sizeof(ce.item_id)-1); ce.item_id[sizeof(ce.item_id)-1] = '\0';
        const char* ct = c["title"] | "";
        strncpy(ce.title, ct, sizeof(ce.title)-1); ce.title[sizeof(ce.title)-1] = '\0';
        const char* cp = c["page"] | "";
        strncpy(ce.page, cp, sizeof(ce.page)-1); ce.page[sizeof(ce.page)-1] = '\0';
        const char* cm = c["memo"] | "";
        strncpy(ce.memo, cm, sizeof(ce.memo)-1); ce.memo[sizeof(ce.memo)-1] = '\0';
        ce.count = c.containsKey("count") ? (int)c["count"] : 0;
        ce.check_count = c.containsKey("check_count") ? (int)c["check_count"] : 0;
        ce.phase = c.containsKey("phase") ? (int)c["phase"] : 1;
        ce.accumulated = c.containsKey("accumulated") ? (int)c["accumulated"] : 0;
        g.child_cnt++;
      }
    }
    s_group_cnt++;
  }
}

void ui_port_update_homeworks(const JsonArray& groups) {
  if (studentId.length() == 0) return;
  if (s_hw_updating) {
    s_hw_refresh_pending = true;
    return;
  }
  uint32_t now = millis();
  if (HOMEWORK_UPDATE_DEBOUNCE_MS > 0 &&
      now - s_last_homework_update_ms < HOMEWORK_UPDATE_DEBOUNCE_MS) return;
  s_last_homework_update_ms = now;
  s_hw_updating = true;

  if (!s_homeworks_mode) build_homeworks_ui_internal();
  if (!s_list || !lv_obj_is_valid(s_list)) { s_hw_updating = false; Serial.println("[HW] ERROR: s_list invalid"); return; }

  HwDisplayAnchorSnap anchor_snaps[6];
  uint8_t anchor_snap_cnt = 0;
  hw_snapshot_display_anchors(anchor_snaps, &anchor_snap_cnt);

  parse_groups_from_json(groups);
  hw_apply_display_anchors_after_parse(anchor_snaps, anchor_snap_cnt);

  HwCacheEntry new_cache[16];
  uint8_t new_cnt = 0;
  for (uint8_t i = 0; i < s_group_cnt && new_cnt < 16; i++) {
    HwCacheEntry& nc = new_cache[new_cnt];
    strncpy(nc.id, s_groups[i].group_id, 63); nc.id[63] = '\0';
    nc.phase = s_groups[i].phase;
    nc.run_start_epoch = s_groups[i].run_start_epoch;
    nc.accumulated = s_groups[i].accumulated;
    nc.cycle_elapsed = s_groups[i].cycle_elapsed;
    nc.check_count = s_groups[i].check_count;
    nc.total_count = s_groups[i].total_count;
    nc.time_limit_minutes = s_groups[i].time_limit_minutes;
    strncpy(nc.group_title, s_groups[i].group_title, sizeof(nc.group_title) - 1);
    nc.group_title[sizeof(nc.group_title) - 1] = '\0';
    strncpy(nc.page_summary, s_groups[i].page_summary, sizeof(nc.page_summary) - 1);
    nc.page_summary[sizeof(nc.page_summary) - 1] = '\0';
    strncpy(nc.book_name, s_groups[i].book_name, sizeof(nc.book_name) - 1);
    nc.book_name[sizeof(nc.book_name) - 1] = '\0';
    strncpy(nc.m5_wait_title, s_groups[i].m5_wait_title, sizeof(nc.m5_wait_title) - 1);
    nc.m5_wait_title[sizeof(nc.m5_wait_title) - 1] = '\0';
    strncpy(nc.item_type, s_groups[i].item_type, sizeof(nc.item_type) - 1);
    nc.item_type[sizeof(nc.item_type) - 1] = '\0';
    nc.children_fp = hw_group_children_fp(s_groups[i]);
    new_cnt++;
  }

  bool need_full = (new_cnt != s_hw_cache_cnt);
  if (!need_full) {
    for (uint8_t i = 0; i < new_cnt; i++) {
      const HwCacheEntry& a = new_cache[i];
      const HwCacheEntry& b = s_hw_cache[i];
      if (strcmp(a.id, b.id) != 0 || a.phase != b.phase ||
          a.run_start_epoch != b.run_start_epoch ||
          a.accumulated != b.accumulated || a.cycle_elapsed != b.cycle_elapsed ||
          a.check_count != b.check_count || a.total_count != b.total_count ||
          a.time_limit_minutes != b.time_limit_minutes ||
          a.children_fp != b.children_fp ||
          strcmp(a.group_title, b.group_title) != 0 ||
          strcmp(a.page_summary, b.page_summary) != 0 ||
          strcmp(a.book_name, b.book_name) != 0 ||
          strcmp(a.m5_wait_title, b.m5_wait_title) != 0 ||
          strcmp(a.item_type, b.item_type) != 0) {
        need_full = true;
        break;
      }
    }
  }
  if (!need_full) {
    ui_port_try_open_pending_homework_detail();
    s_hw_updating = false;
    return;
  }

  s_hw_timer_epoch++;
  if (s_hw_global_timer) { lv_timer_del(s_hw_global_timer); s_hw_global_timer = nullptr; }
  s_p2_cnt = 0; s_p4_cnt = 0; s_p4_breath_step = 0;
  g_should_vibrate_phase4 = false;

  lv_coord_t prev_scroll_y = 0;
  if (s_list && lv_obj_is_valid(s_list)) {
    prev_scroll_y = lv_obj_get_scroll_y(s_list);
  }

  lv_obj_add_flag(s_list, LV_OBJ_FLAG_HIDDEN);
  esp_task_wdt_reset();
  lv_obj_clean(s_list);
  esp_task_wdt_reset();
  for (uint8_t i = 0; i < s_group_cnt; i++) {
    create_hw_card(s_list, i);
    if (i % 2 == 1) esp_task_wdt_reset();
  }
  lv_obj_clear_flag(s_list, LV_OBJ_FLAG_HIDDEN);
  lv_obj_update_layout(s_list);
  if (prev_scroll_y != 0) {
    lv_obj_scroll_to_y(s_list, prev_scroll_y, LV_ANIM_OFF);
  }

  memcpy(s_hw_cache, new_cache, sizeof(HwCacheEntry) * new_cnt);
  s_hw_cache_cnt = new_cnt;
  restart_hw_timer();

  s_first_p4_card_idx = -1;
  for (uint8_t i = 0; i < new_cnt; i++) {
    if (new_cache[i].phase == 4) { s_first_p4_card_idx = (int8_t)i; break; }
  }
  bool has_active = false;
  for (uint8_t i = 0; i < new_cnt; i++) {
    if (new_cache[i].phase == 2) { has_active = true; break; }
  }
  if (has_active && s_rest_mode) { s_rest_mode = false; }

  if (s_p4_cnt == 0) {
    s_phase4_alarm_muted = false;
  } else if (s_p4_cnt > s_prev_p4_count) {
    s_phase4_alarm_muted = false;
  }
  s_prev_p4_count = s_p4_cnt;
  g_should_vibrate_phase4 = (s_p4_cnt > 0 && !s_phase4_alarm_muted);

  if (s_p4_cnt > 0) {
    if (!s_phase4_alarm_muted) show_snackbar_phase4(s_p4_cnt, s_p4_colors[0]);
    else hide_snackbar();
  } else if (s_rest_mode) {
    show_snackbar_rest();
  } else {
    hide_snackbar();
  }

  // 상세 페이지가 열려있으면 데이터 갱신
  if (s_hw_detail_screen && lv_obj_is_valid(s_hw_detail_screen) && s_detail_group_idx >= 0) {
    if (s_detail_group_idx >= s_group_cnt) {
      close_homework_detail_page();
    } else {
      HwGroupData& dg = s_groups[s_detail_group_idx];
      bool server_running = hw_server_running_group(dg);
      bool has_manual_override = millis() < s_detail_manual_override_until_ms;
      if (!s_detail_cycle_running && server_running) {
        s_detail_local_run_start_tick = lv_tick_get();
      }
      // Note: cycle display is driven by local watch (detail_timer_cb).
      // We intentionally do NOT seed s_detail_cycle_frozen_sec from the
      // server payload here so that pause/resume on the server cannot
      // rewind the cycle value before submit-phase transition.

      if (server_running == s_detail_manual_override_playing) {
        s_detail_manual_override_until_ms = 0;
      }
      bool desired_playing = server_running;
      if (millis() < s_detail_manual_override_until_ms) {
        desired_playing = s_detail_manual_override_playing;
      }
      s_detail_cycle_running = desired_playing;
      bool was_playing = s_detail_playing;
      s_detail_playing = desired_playing;
      if (was_playing != s_detail_playing) update_detail_play_button_visual();
      if (dg.phase == 3) {
        close_homework_detail_page();
      }
    }
  }
  ui_port_try_open_pending_homework_detail();
  s_hw_updating = false;
  if (s_hw_refresh_pending) {
    s_hw_refresh_pending = false;
    if (studentId.length() > 0) {
      fw_publish_list_homeworks(studentId.c_str());
    }
  }
}

// ========== 수행 상세 페이지 (음악 앱 스타일) ==========

// Paints HH:MM:SS into 10 per-glyph slots with always-two-digit hours.
//   slots[0..1] = hours, slots[2] = ':', slots[3..4] = minutes,
//   slots[5] = ':', slots[6..7] = seconds, slots[8..9] unused.
static void hw_detail_paint_time(lv_obj_t* const* slots, int secs,
                                 bool /*unused*/, int /*unused*/) {
  if (secs < 0) secs = 0;
  int h = secs / 3600;
  int m = (secs % 3600) / 60;
  int s = secs % 60;
  char digits[6];
  digits[0] = (char)('0' + (h / 10) % 10);
  digits[1] = (char)('0' + h % 10);
  digits[2] = (char)('0' + (m / 10) % 10);
  digits[3] = (char)('0' + m % 10);
  digits[4] = (char)('0' + (s / 10) % 10);
  digits[5] = (char)('0' + s % 10);
  const int digit_slot_map[6] = {0, 1, 3, 4, 6, 7};
  for (int i = 0; i < 6; i++) {
    lv_obj_t* s_obj = slots[digit_slot_map[i]];
    if (!s_obj || !lv_obj_is_valid(s_obj)) continue;
    char buf[2];
    buf[0] = digits[i];
    buf[1] = '\0';
    lv_label_set_text(s_obj, buf);
  }
  if (slots[2] && lv_obj_is_valid(slots[2])) lv_label_set_text(slots[2], ":");
  if (slots[5] && lv_obj_is_valid(slots[5])) lv_label_set_text(slots[5], ":");
  if (slots[8] && lv_obj_is_valid(slots[8])) lv_label_set_text(slots[8], "");
  if (slots[9] && lv_obj_is_valid(slots[9])) lv_label_set_text(slots[9], "");
}

static bool detail_test_effective_running(const HwGroupData& g) {
  if (!hw_is_test_group(g)) return false;
  bool server_running = hw_server_running_group(g);
  bool effective_running = server_running || s_detail_playing;
  if (millis() < s_detail_manual_override_until_ms) {
    effective_running = s_detail_manual_override_playing;
  }
  return effective_running;
}

static void detail_timer_cb(lv_timer_t* timer) {
  uint32_t epoch = (uint32_t)(uintptr_t)timer->user_data;
  if (epoch != s_detail_timer_epoch) { lv_timer_del(timer); return; }
  if (s_detail_group_idx < 0 || s_detail_group_idx >= s_group_cnt) return;
  HwGroupData& g = s_groups[s_detail_group_idx];

  // Detect submit-phase transition: only place the cycle baseline resets.
  if (s_detail_last_phase_seen != 3 && g.phase == 3) {
    s_detail_cycle_baseline_sec = 0;
  }
  s_detail_last_phase_seen = g.phase;

  bool server_running = hw_server_running_group(g);
  bool effective_running = server_running || s_detail_playing;
  if (millis() < s_detail_manual_override_until_ms) {
    effective_running = s_detail_manual_override_playing;
  }

  // Edge: not-running -> running. Anchor a new local run_start.
  if (!s_detail_cycle_running && effective_running) {
    s_detail_run_start_tick = lv_tick_get();
    s_detail_local_run_start_tick = s_detail_run_start_tick;
  }
  // Edge: running -> not-running. Freeze baselines at the last shown values.
  if (s_detail_cycle_running && !effective_running) {
    s_detail_cycle_baseline_sec = s_detail_cycle_frozen_sec;
    s_detail_total_baseline_sec = s_detail_total_frozen_sec;
  }
  s_detail_cycle_running = effective_running;

  int segment_sec = 0;
  if (effective_running) {
    segment_sec = (int)((lv_tick_get() - s_detail_run_start_tick) / 1000);
    if (segment_sec < 0) segment_sec = 0;
  }

  int cycle_sec = s_detail_cycle_baseline_sec + segment_sec;
  int total_sec = s_detail_total_baseline_sec + segment_sec;
  if (cycle_sec < 0) cycle_sec = 0;
  if (total_sec < 0) total_sec = 0;

  // Reconcile with server values. Only allow forward jumps so local watch
  // never rewinds, but follow the server when it has a larger authoritative
  // value (e.g. this group accumulated time while we were viewing another
  // detail page, or we came back to an existing detail page).
  int server_total = (int)g.accumulated + hw_live_segment_sec(g, lv_tick_get());
  if (server_total > total_sec) {
    int delta = server_total - total_sec;
    s_detail_total_baseline_sec += delta;
    total_sec = server_total;
  }
  int server_cycle = (int)g.cycle_elapsed;
  if (server_cycle > cycle_sec) {
    int delta = server_cycle - cycle_sec;
    s_detail_cycle_baseline_sec += delta;
    cycle_sec = server_cycle;
  }

  s_detail_cycle_frozen_sec = cycle_sec;
  s_detail_total_frozen_sec = total_sec;

  int tlim_sec = (g.time_limit_minutes > 0) ? ((int)g.time_limit_minutes * 60) : 0;
  bool test_countdown = hw_is_test_group(g) && tlim_sec > 0 && effective_running;

  if (s_hw_detail_session_slots[0] && lv_obj_is_valid(s_hw_detail_session_slots[0])) {
    int show_sec = cycle_sec;
    if (test_countdown) {
      show_sec = tlim_sec - cycle_sec;
      if (show_sec < 0) show_sec = 0;
    }
    hw_detail_paint_time(s_hw_detail_session_slots, show_sec, false, 0);
  }
  if (s_hw_detail_total_slots[0] && lv_obj_is_valid(s_hw_detail_total_slots[0])) {
    hw_detail_paint_time(s_hw_detail_total_slots, total_sec, false, 0);
  }
}

static void list_page_anim_del_cb(lv_anim_t* a) {
  if (!a) return;
  lv_obj_t* obj = (lv_obj_t*)a->var;
  if (obj && lv_obj_is_valid(obj)) lv_obj_del(obj);
}

static void close_homework_child_list_page(bool animated) {
  if (!s_hw_list_screen || !lv_obj_is_valid(s_hw_list_screen)) return;
  lv_obj_t* target = s_hw_list_screen;
  s_hw_list_screen = nullptr;
  if (!animated) {
    lv_obj_del(target);
    return;
  }
  lv_anim_t a;
  lv_anim_init(&a);
  lv_anim_set_var(&a, target);
  lv_anim_set_values(&a, 0, 240);
  lv_anim_set_time(&a, 180);
  lv_anim_set_exec_cb(&a, (lv_anim_exec_xcb_t)lv_obj_set_y);
  lv_anim_set_ready_cb(&a, list_page_anim_del_cb);
  lv_anim_set_path_cb(&a, lv_anim_path_ease_in);
  lv_anim_start(&a);
}

static void show_homework_child_list_page(int group_idx) {
  if (group_idx < 0 || group_idx >= s_group_cnt) return;
  if (!s_stage || !lv_obj_is_valid(s_stage)) return;

  close_homework_child_list_page(false);
  HwGroupData& g = s_groups[group_idx];

  s_hw_list_screen = lv_obj_create(s_stage);
  lv_obj_set_size(s_hw_list_screen, 320, 240);
  lv_obj_set_pos(s_hw_list_screen, 0, 240);
  lv_obj_set_style_bg_color(s_hw_list_screen, lv_color_hex(0x0B1112), 0);
  lv_obj_set_style_bg_opa(s_hw_list_screen, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_hw_list_screen, 0, 0);
  lv_obj_set_style_radius(s_hw_list_screen, 0, 0);
  lv_obj_set_style_pad_all(s_hw_list_screen, 0, 0);
  lv_obj_clear_flag(s_hw_list_screen, LV_OBJ_FLAG_SCROLLABLE);
  screensaver_attach_activity(s_hw_list_screen);

  lv_obj_t* header = lv_obj_create(s_hw_list_screen);
  lv_obj_set_size(header, 320, 46);
  lv_obj_set_style_bg_opa(header, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(header, 0, 0);
  lv_obj_set_style_pad_all(header, 0, 0);
  lv_obj_clear_flag(header, LV_OBJ_FLAG_SCROLLABLE);

  lv_obj_t* back_btn = lv_btn_create(header);
  lv_obj_set_size(back_btn, 36, 36);
  lv_obj_set_pos(back_btn, 4, 10);
  lv_obj_set_style_radius(back_btn, 10, 0);
  lv_obj_set_style_bg_color(back_btn, lv_color_hex(0x1E1E1E), 0);
  lv_obj_set_style_border_width(back_btn, 0, 0);
  lv_obj_set_style_shadow_width(back_btn, 0, 0);
  lv_obj_t* back_lbl = lv_label_create(back_btn);
  lv_obj_set_style_text_font(back_lbl, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(back_lbl, lv_color_hex(0xE6E6E6), 0);
  lv_label_set_text(back_lbl, "<");
  lv_obj_center(back_lbl);
  lv_obj_add_event_cb(back_btn, [](lv_event_t* e){ (void)e; close_homework_child_list_page(true); }, LV_EVENT_CLICKED, NULL);

  lv_obj_t* title = lv_label_create(header);
  lv_obj_set_style_text_font(title, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(title, lv_color_hex(0xE6E6E6), 0);
  lv_label_set_text(title, u8"상세 과제 리스트");
  lv_obj_align(title, LV_ALIGN_LEFT_MID, 50, 5);

  lv_obj_t* list = lv_obj_create(s_hw_list_screen);
  lv_obj_set_size(list, 304, 188);
  lv_obj_align(list, LV_ALIGN_TOP_MID, 0, 51);
  lv_obj_set_style_bg_opa(list, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(list, 0, 0);
  lv_obj_set_style_pad_left(list, 2, 0);
  lv_obj_set_style_pad_right(list, 2, 0);
  lv_obj_set_style_pad_top(list, 4, 0);
  lv_obj_set_style_pad_bottom(list, 4, 0);
  lv_obj_set_style_pad_row(list, 6, 0);
  lv_obj_set_scroll_dir(list, LV_DIR_VER);
  lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_ACTIVE);
  lv_obj_add_flag(list, LV_OBJ_FLAG_SCROLL_ELASTIC);
  lv_obj_add_flag(list, LV_OBJ_FLAG_SCROLL_MOMENTUM);
  lv_obj_set_style_anim_time(list, 180, 0);
  lv_obj_add_event_cb(list, list_scroll_activity_cb, LV_EVENT_SCROLL_BEGIN, NULL);
  lv_obj_add_event_cb(list, list_scroll_activity_cb, LV_EVENT_SCROLL_END, NULL);
  lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_START);

  for (uint8_t i = 0; i < g.child_cnt; i++) {
    HwChildEntry& ce = g.children[i];
    lv_obj_t* row = lv_obj_create(list);
    lv_obj_set_width(row, 300);
    lv_obj_set_style_height(row, 84, 0);
    lv_obj_set_style_min_height(row, 84, 0);
    lv_obj_set_style_max_height(row, 84, 0);
    lv_obj_set_flex_grow(row, 0);
    lv_obj_set_style_radius(row, 10, 0);
    lv_obj_set_style_bg_opa(row, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(row, 1, 0);
    lv_obj_set_style_border_color(row, lv_color_hex(0x232323), 0);
    lv_obj_set_style_pad_left(row, 13, 0);
    lv_obj_set_style_pad_right(row, 13, 0);
    lv_obj_set_style_pad_top(row, 6, 0);
    lv_obj_set_style_pad_bottom(row, 6, 0);
    lv_obj_clear_flag(row, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(row, LV_OBJ_FLAG_CLICKABLE);

    const lv_coord_t text_x = 34;
    const lv_coord_t text_w = 240;
    bool checked = get_child_check_cached(ce.item_id);
    lv_obj_t* check_box = lv_btn_create(row);
    lv_obj_set_size(check_box, 20, 20);
    lv_obj_align(check_box, LV_ALIGN_LEFT_MID, 0, 0);
    lv_obj_set_style_radius(check_box, 4, 0);
    lv_obj_set_style_border_width(check_box, 2, 0);
    lv_obj_set_style_shadow_width(check_box, 0, 0);
    lv_obj_set_style_pad_all(check_box, 0, 0);
    lv_obj_clear_flag(check_box, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_t* check_mark = lv_label_create(check_box);
    lv_obj_set_style_text_font(check_mark, &lv_font_montserrat_14, 0);
    lv_obj_set_style_text_color(check_mark, lv_color_hex(0xF0F0F0), 0);
    lv_label_set_text(check_mark, LV_SYMBOL_OK);
    lv_obj_center(check_mark);
    apply_child_check_visual(check_box, check_mark, checked);
    if (ce.item_id[0]) {
      attach_child_check_toggle(check_box, ce.item_id, check_box, check_mark);
      attach_child_check_toggle(row, ce.item_id, check_box, check_mark);
    }

    lv_obj_t* r1 = lv_label_create(row);
    lv_obj_set_style_text_font(r1, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(r1, lv_color_hex(0xDCDCDC), 0);
    lv_label_set_long_mode(r1, LV_LABEL_LONG_DOT);
    lv_obj_set_width(r1, text_w);
    lv_label_set_text(r1, ce.title[0] ? ce.title : u8"과제");
    lv_obj_align(r1, LV_ALIGN_TOP_LEFT, text_x, 2);
    lv_obj_add_flag(r1, LV_OBJ_FLAG_EVENT_BUBBLE);

    char page_count[64] = {0};
    if (ce.page[0] && ce.count > 0) snprintf(page_count, sizeof(page_count), "p.%s · %d%s", ce.page, ce.count, u8"문항");
    else if (ce.page[0]) snprintf(page_count, sizeof(page_count), "p.%s", ce.page);
    else if (ce.count > 0) snprintf(page_count, sizeof(page_count), "%d%s", ce.count, u8"문항");
    else snprintf(page_count, sizeof(page_count), "-");

    lv_obj_t* r2 = lv_label_create(row);
    lv_obj_set_style_text_font(r2, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(r2, lv_color_hex(0xAAAAAA), 0);
    lv_label_set_long_mode(r2, LV_LABEL_LONG_DOT);
    lv_obj_set_width(r2, text_w);
    lv_label_set_text(r2, page_count);
    lv_obj_align(r2, LV_ALIGN_TOP_LEFT, text_x, 21);
    lv_obj_add_flag(r2, LV_OBJ_FLAG_EVENT_BUBBLE);

    lv_obj_t* r3 = lv_label_create(row);
    lv_obj_set_style_text_font(r3, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(r3, lv_color_hex(0x8F8F8F), 0);
    lv_obj_set_style_text_align(r3, LV_TEXT_ALIGN_RIGHT, 0);
    lv_label_set_long_mode(r3, LV_LABEL_LONG_DOT);
    lv_obj_set_width(r3, text_w);
    lv_label_set_text(r3, ce.memo[0] ? ce.memo : "-");
    lv_obj_align(r3, LV_ALIGN_BOTTOM_LEFT, text_x, 0);
    lv_obj_add_flag(r3, LV_OBJ_FLAG_EVENT_BUBBLE);
  }

  lv_anim_t a;
  lv_anim_init(&a);
  lv_anim_set_var(&a, s_hw_list_screen);
  lv_anim_set_values(&a, 240, 0);
  lv_anim_set_time(&a, 200);
  lv_anim_set_exec_cb(&a, (lv_anim_exec_xcb_t)lv_obj_set_y);
  lv_anim_set_path_cb(&a, lv_anim_path_ease_out);
  lv_anim_start(&a);
}

static void close_homework_detail_page(void) {
  close_test_abort_confirm_popup();
  s_detail_timer_epoch++;
  close_homework_child_list_page(false);
  if (s_detail_timer) { lv_timer_del(s_detail_timer); s_detail_timer = nullptr; }
  if (s_hw_detail_screen && lv_obj_is_valid(s_hw_detail_screen)) {
    lv_obj_del(s_hw_detail_screen);
  }
  s_hw_detail_screen = nullptr;
  s_hw_detail_session_lbl = nullptr;
  s_hw_detail_total_lbl = nullptr;
  for (int i = 0; i < 10; i++) {
    s_hw_detail_session_slots[i] = nullptr;
    s_hw_detail_total_slots[i] = nullptr;
  }
  s_hw_detail_play_img = nullptr;
  s_hw_detail_play_btn = nullptr;
  s_detail_group_idx = -1;
  s_detail_cycle_running = false;
  s_detail_cycle_base_acc = 0;
  s_detail_local_run_start_tick = 0;
  s_detail_run_start_tick = 0;
  s_detail_cycle_frozen_sec = 0;
  s_detail_total_frozen_sec = 0;
  s_detail_cycle_baseline_sec = 0;
  s_detail_total_baseline_sec = 0;
  s_detail_last_phase_seen = -1;
  s_detail_manual_override_until_ms = 0;
}

static void show_homework_detail_page(int group_idx) {
  extern const lv_font_t kakao_kr_16;
  if (group_idx < 0 || group_idx >= s_group_cnt) return;
  if (!s_stage || !lv_obj_is_valid(s_stage)) return;

  close_homework_detail_page();
  s_detail_group_idx = group_idx;
  HwGroupData& g = s_groups[group_idx];
  s_detail_playing = hw_server_running_group(g);
  s_detail_cycle_running = s_detail_playing;
  s_detail_cycle_base_acc = (int)(g.accumulated - g.cycle_elapsed);
  uint32_t now_tick = lv_tick_get();
  s_detail_local_run_start_tick = now_tick;
  s_detail_run_start_tick = now_tick;
  int32_t seed_cycle = g.cycle_elapsed;
  if (seed_cycle < 0) seed_cycle = 0;
  int32_t seed_total = (int)g.accumulated + hw_live_segment_sec(g, now_tick);
  if (seed_total < 0) seed_total = 0;
  s_detail_cycle_frozen_sec = seed_cycle;
  s_detail_total_frozen_sec = seed_total;
  s_detail_cycle_baseline_sec = seed_cycle;
  s_detail_total_baseline_sec = seed_total;
  s_detail_last_phase_seen = g.phase;
  s_detail_manual_override_until_ms = 0;

  s_hw_detail_screen = lv_obj_create(s_stage);
  lv_obj_set_size(s_hw_detail_screen, 320, 240);
  lv_obj_set_pos(s_hw_detail_screen, 0, 0);
  lv_obj_set_style_bg_color(s_hw_detail_screen, lv_color_hex(0x0B1112), 0);
  lv_obj_set_style_bg_opa(s_hw_detail_screen, LV_OPA_COVER, 0);
  lv_obj_set_style_border_width(s_hw_detail_screen, 0, 0);
  lv_obj_set_style_radius(s_hw_detail_screen, 0, 0);
  lv_obj_set_style_pad_all(s_hw_detail_screen, 0, 0);
  lv_obj_set_scrollbar_mode(s_hw_detail_screen, LV_SCROLLBAR_MODE_OFF);
  lv_obj_set_scroll_dir(s_hw_detail_screen, LV_DIR_VER);
  lv_obj_set_style_pad_row(s_hw_detail_screen, 0, 0);
  lv_obj_set_flex_flow(s_hw_detail_screen, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_hw_detail_screen, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  screensaver_attach_activity(s_hw_detail_screen);

  // -- 뒤로가기 헤더 (36px) --
  lv_obj_t* header = lv_obj_create(s_hw_detail_screen);
  lv_obj_set_size(header, 320, 36);
  lv_obj_set_style_bg_opa(header, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(header, 0, 0);
  lv_obj_set_style_pad_all(header, 0, 0);
  lv_obj_add_flag(header, LV_OBJ_FLAG_OVERFLOW_VISIBLE);
  lv_obj_clear_flag(header, LV_OBJ_FLAG_SCROLLABLE);

  lv_obj_t* back_btn = lv_btn_create(header);
  lv_obj_set_size(back_btn, 36, 36);
  lv_obj_set_pos(back_btn, 7, 10);
  lv_obj_set_style_radius(back_btn, 10, 0);
  lv_obj_set_style_bg_color(back_btn, lv_color_hex(0x1E1E1E), 0);
  lv_obj_set_style_border_width(back_btn, 0, 0);
  lv_obj_set_style_shadow_width(back_btn, 0, 0);
  lv_obj_t* back_lbl = lv_label_create(back_btn);
  lv_obj_set_style_text_font(back_lbl, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(back_lbl, lv_color_hex(0xE6E6E6), 0);
  lv_label_set_text(back_lbl, "<");
  lv_obj_center(back_lbl);
  lv_obj_add_event_cb(back_btn, [](lv_event_t* e){
    (void)e;
    if (s_detail_group_idx >= 0 && s_detail_group_idx < s_group_cnt) {
      HwGroupData& gg = s_groups[s_detail_group_idx];
      if (detail_test_effective_running(gg)) {
        show_test_abort_confirm_popup();
        return;
      }
    }
    close_homework_detail_page();
  }, LV_EVENT_CLICKED, NULL);

  // -- 1열: 교재명+과정 (가운데, 큰 글자) --
  lv_obj_t* row1 = lv_label_create(s_hw_detail_screen);
  lv_obj_set_style_text_font(row1, &kakao_kr_24, 0);
  lv_obj_set_style_text_color(row1, lv_color_hex(0xF0F0F0), 0);
  lv_obj_set_style_text_align(row1, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_width(row1, 300);
  lv_label_set_long_mode(row1, LV_LABEL_LONG_DOT);
  lv_label_set_text(row1, hw_is_test_group(g) ? u8"테스트" : g.book_name);
  lv_obj_set_style_pad_top(row1, 6, 0);
  lv_obj_set_style_translate_y(row1, -10, 0);

  // -- 2열: 그룹 과제명 (가운데) --
  lv_obj_t* row2 = lv_label_create(s_hw_detail_screen);
  lv_obj_set_style_text_font(row2, &kakao_kr_16, 0);
  lv_obj_set_style_text_color(row2, lv_color_hex(0xB0B0B0), 0);
  lv_obj_set_style_text_align(row2, LV_TEXT_ALIGN_CENTER, 0);
  lv_obj_set_width(row2, 300);
  lv_label_set_long_mode(row2, LV_LABEL_LONG_DOT);
  lv_label_set_text(row2, g.group_title);
  lv_obj_set_style_pad_top(row2, 10, 0);

  // -- 3열: 페이지 (가운데) --
  if (g.page_summary[0]) {
    char pg_buf[80];
    snprintf(pg_buf, sizeof(pg_buf), "p.%s", g.page_summary);
    lv_obj_t* row3 = lv_label_create(s_hw_detail_screen);
    lv_obj_set_style_text_font(row3, &kakao_kr_16, 0);
    lv_obj_set_style_text_color(row3, lv_color_hex(0x808080), 0);
    lv_obj_set_style_text_align(row3, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_width(row3, 300);
    lv_label_set_text(row3, pg_buf);
    lv_obj_set_style_pad_top(row3, 2, 0);
  }

  // -- 4열: 현재 진행시간 / 총 진행시간 --
  // Layout strategy:
  //   - Outer "time_row" is sized to fully contain the 22px glyph slots
  //     plus top/bottom spacing so the next flex sibling (btn_row) starts
  //     *below* the digits. This removes the visual clipping where the
  //     button row used to overlap the bottom of the time digits.
  //   - "time_row" spans the full parent width (320) so session and total
  //     blocks can be placed with symmetric left/right margins measured
  //     from the screen edges.
  //   - Each digit lives in its own fixed-width slot (monospaced) so
  //     digit-width variation in kakao_kr_16 (e.g. "1" vs "5") cannot
  //     shift neighboring characters. Session block aligns each digit to
  //     the left edge of its slot; total block to the right edge.
  // time_row band is 33px; slots sit at y=16 so they hang 5px past the
  // band (overflow is visible). The btn_row below uses a pad_top of 1
  // and has bg_opa=TRANSP, so the overflow region is empty and the
  // digits cannot be clipped. The absolute Y of the circular buttons is
  // unchanged (flex: time_row_h + btn_row.pad_top = 33 + 1 = 34).
  const lv_coord_t time_row_h = 33;
  const lv_coord_t time_row_top_pad = 16;   // was 11; +5 extra drop (visual only)
  // Horizontal offsets. Session keeps its left edge at 15.
  // Total is pulled an additional 5px to the right (negative inset so it
  // extends past the right edge in absolute terms, which keeps the
  // rendered digits flush with the screen's right margin).
  const lv_coord_t side_margin_left = 19;   // was 15; +4 nudge session right
  const lv_coord_t side_margin_right = -5;  // total block right-edge inset
  lv_obj_t* time_row = lv_obj_create(s_hw_detail_screen);
  lv_obj_set_size(time_row, 320, time_row_h);
  lv_obj_set_style_bg_opa(time_row, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(time_row, 0, 0);
  lv_obj_set_style_shadow_width(time_row, 0, 0);
  lv_obj_set_style_outline_width(time_row, 0, 0);
  lv_obj_set_style_radius(time_row, 0, 0);
  lv_obj_set_style_pad_all(time_row, 0, 0);
  lv_obj_clear_flag(time_row, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(time_row, LV_OBJ_FLAG_OVERFLOW_VISIBLE);

  auto clear_container_visuals = [](lv_obj_t* c) {
    lv_obj_set_style_bg_opa(c, LV_OPA_TRANSP, 0);
    lv_obj_set_style_bg_opa(c, LV_OPA_TRANSP, LV_STATE_FOCUSED);
    lv_obj_set_style_bg_opa(c, LV_OPA_TRANSP, LV_STATE_PRESSED);
    lv_obj_set_style_border_width(c, 0, 0);
    lv_obj_set_style_border_width(c, 0, LV_STATE_FOCUSED);
    lv_obj_set_style_shadow_width(c, 0, 0);
    lv_obj_set_style_shadow_spread(c, 0, 0);
    lv_obj_set_style_shadow_opa(c, LV_OPA_TRANSP, 0);
    lv_obj_set_style_outline_width(c, 0, 0);
    lv_obj_set_style_outline_opa(c, LV_OPA_TRANSP, 0);
    lv_obj_set_style_radius(c, 0, 0);
    lv_obj_set_style_pad_all(c, 0, 0);
    lv_obj_clear_flag(c, LV_OBJ_FLAG_SCROLLABLE);
  };

  // Monospaced time block:
  //   layout HH:MM:SS inside a fixed container using per-glyph slots.
  //   digit_w/colon_w are chosen to match kakao_kr_16 advance metrics so
  //   the block looks natural while keeping columns identical.
  const lv_coord_t digit_w = 11;
  const lv_coord_t colon_w = 6;
  const lv_coord_t slot_h = 22;
  // Width: 8 digits + 2 colons (HH:MM:SS form)
  const lv_coord_t block_w = digit_w * 8 + colon_w * 2; // 100
  // Character layout offsets inside the block (HH : MM : SS).
  const lv_coord_t slot_offsets[10] = {
    0,
    digit_w,
    digit_w * 2,
    digit_w * 2 + colon_w,
    digit_w * 3 + colon_w,
    digit_w * 4 + colon_w,
    digit_w * 4 + colon_w * 2,
    digit_w * 5 + colon_w * 2,
    digit_w * 6 + colon_w * 2,
    digit_w * 7 + colon_w * 2
  };

  auto make_time_block = [&](lv_obj_t* parent, uint32_t color_hex,
                             lv_coord_t x_left, lv_text_align_t slot_align,
                             lv_obj_t** out_slots) {
    lv_obj_t* block = lv_obj_create(parent);
    lv_obj_set_size(block, block_w, slot_h);
    lv_obj_set_pos(block, x_left, time_row_top_pad);
    clear_container_visuals(block);
    for (int i = 0; i < 10; i++) {
      lv_obj_t* ch = lv_label_create(block);
      lv_obj_set_style_text_font(ch, &kakao_kr_16, 0);
      lv_obj_set_style_text_color(ch, lv_color_hex(color_hex), 0);
      lv_obj_set_style_bg_opa(ch, LV_OPA_TRANSP, 0);
      lv_obj_set_style_pad_all(ch, 0, 0);
      lv_obj_set_style_border_width(ch, 0, 0);
      lv_obj_set_style_shadow_width(ch, 0, 0);
      bool is_colon = (i == 2 || i == 5);
      lv_coord_t w = is_colon ? colon_w : digit_w;
      lv_obj_set_size(ch, w, slot_h);
      lv_label_set_long_mode(ch, LV_LABEL_LONG_CLIP);
      // Colons stay centered so they sit visually between paired digits;
      // digit slots follow the caller-specified alignment (session → LEFT,
      // total → RIGHT) so the whole block hugs its respective screen edge.
      lv_obj_set_style_text_align(ch, is_colon ? LV_TEXT_ALIGN_CENTER : slot_align, 0);
      lv_label_set_text(ch, is_colon ? ":" : "0");
      lv_obj_set_pos(ch, slot_offsets[i], 0);
      out_slots[i] = ch;
    }
    return block;
  };

  // Both blocks are offset +5px rightwards from a fully-symmetric layout.
  make_time_block(time_row, 0x33A373, side_margin_left, LV_TEXT_ALIGN_LEFT,
                  s_hw_detail_session_slots);
  s_hw_detail_session_lbl = s_hw_detail_session_slots[0]; // back-compat sentinel

  make_time_block(time_row, 0x808080, 320 - side_margin_right - block_w,
                  LV_TEXT_ALIGN_RIGHT, s_hw_detail_total_slots);
  s_hw_detail_total_lbl = s_hw_detail_total_slots[0]; // back-compat sentinel

  {
    int init_total = (int)g.accumulated + hw_live_segment_sec(g, lv_tick_get());
    hw_detail_paint_time(s_hw_detail_total_slots, init_total, false, 0);
    hw_detail_paint_time(s_hw_detail_session_slots, 0, false, 0);
  }

  // -- 5열: 3개 버튼 --
  // pad_top is 1 (was 6) so the buttons stay at the same absolute Y after
  // we grew time_row by 5px above. Net flex offset for buttons: unchanged.
  lv_obj_t* btn_row = lv_obj_create(s_hw_detail_screen);
  lv_obj_set_size(btn_row, 300, 88);
  lv_obj_set_style_bg_opa(btn_row, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(btn_row, 0, 0);
  lv_obj_set_style_pad_all(btn_row, 0, 0);
  lv_obj_clear_flag(btn_row, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(btn_row, LV_OBJ_FLAG_OVERFLOW_VISIBLE);
  lv_obj_set_style_pad_top(btn_row, 1, 0);

  auto make_circle_btn = [&](lv_obj_t* parent, const lv_img_dsc_t* icon_src, uint16_t icon_zoom, uint32_t icon_color, lv_coord_t x, lv_coord_t y, uint32_t bg_color, lv_coord_t size) -> lv_obj_t* {
    lv_obj_t* btn = lv_btn_create(parent);
    lv_obj_set_size(btn, size, size);
    lv_obj_set_pos(btn, x, y);
    lv_obj_set_style_radius(btn, size / 2, 0);
    lv_color_t base = lv_color_hex(bg_color);
    lv_obj_set_style_bg_color(btn, base, LV_STATE_DEFAULT);
    lv_obj_set_style_bg_color(btn, lv_color_darken(base, LV_OPA_20), LV_STATE_PRESSED);
    lv_obj_set_style_border_width(btn, 0, 0);
    lv_obj_set_style_shadow_width(btn, 0, 0);
    lv_obj_set_style_translate_y(btn, 0, LV_STATE_PRESSED);
    lv_obj_set_style_transform_width(btn, 0, LV_STATE_PRESSED);
    lv_obj_set_style_transform_height(btn, 0, LV_STATE_PRESSED);
    lv_obj_t* img = lv_img_create(btn);
    lv_img_set_src(img, icon_src);
    lv_obj_set_style_img_recolor(img, lv_color_hex(icon_color), 0);
    lv_obj_set_style_img_recolor_opa(img, LV_OPA_COVER, 0);
    lv_img_set_zoom(img, icon_zoom);
    lv_obj_center(img);
    return btn;
  };

  // L (리스트) 버튼
  lv_obj_t* list_btn = make_circle_btn(btn_row, &lists_100dp_999999_FILL0_wght400_GRAD0_opsz48, 86, 0xAEAEAE, 16, 13, 0x181818, 60);
  struct ListPageCtx { int group_idx; };
  ListPageCtx* lctx = (ListPageCtx*)malloc(sizeof(ListPageCtx));
  if (lctx) {
    lctx->group_idx = group_idx;
    lv_obj_add_event_cb(list_btn, [](lv_event_t* e){
      ListPageCtx* c = (ListPageCtx*)lv_event_get_user_data(e);
      if (!c) return;
      show_homework_child_list_page(c->group_idx);
    }, LV_EVENT_CLICKED, lctx);
    lv_obj_add_event_cb(list_btn, [](lv_event_t* e){
      if (lv_event_get_code(e) == LV_EVENT_DELETE) { void* ud = lv_event_get_user_data(e); if (ud) free(ud); }
    }, LV_EVENT_DELETE, lctx);
  }

  // 재생/멈춤 버튼
  lv_obj_t* play_btn = make_circle_btn(
    btn_row,
    s_detail_playing ? &stop_100dp_999999_FILL0_wght400_GRAD0_opsz48 : &play_arrow_100dp_999999_FILL0_wght400_GRAD0_opsz48,
    153,
    0xAEAEAE,
    114,
    7,
    s_detail_playing ? 0x181818 : 0x1B8F50,
    72
  );
  s_hw_detail_play_btn = play_btn;
  s_hw_detail_play_img = lv_obj_get_child(play_btn, 0);
  update_detail_play_button_visual();

  struct DetailCtx { int group_idx; };
  DetailCtx* ctx = (DetailCtx*)malloc(sizeof(DetailCtx));
  if (ctx) {
    ctx->group_idx = group_idx;
    lv_obj_add_event_cb(play_btn, [](lv_event_t* e){
      (void)e;
      apply_detail_play_button_visual(!s_detail_playing);
    }, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(play_btn, [](lv_event_t* e){
      (void)e;
      update_detail_play_button_visual();
    }, LV_EVENT_PRESS_LOST, NULL);
    lv_obj_add_event_cb(play_btn, [](lv_event_t* e){
      DetailCtx* c = (DetailCtx*)lv_event_get_user_data(e);
      if (c->group_idx < 0 || c->group_idx >= s_group_cnt) return;
      HwGroupData& grp = s_groups[c->group_idx];
      if (s_detail_playing) {
        if (hw_is_test_group(grp) && detail_test_effective_running(grp)) {
          update_detail_play_button_visual();
          show_test_abort_confirm_popup();
          return;
        }
        // Freeze baselines at the last displayed values so the next resume
        // continues from here (local-watch monotonic, no server rewind).
        s_detail_cycle_baseline_sec = s_detail_cycle_frozen_sec;
        s_detail_total_baseline_sec = s_detail_total_frozen_sec;
        s_detail_playing = false;
        s_detail_cycle_running = false;
        s_detail_manual_override_playing = false;
        s_detail_manual_override_until_ms = millis() + 5000;
        update_detail_play_button_visual();
        fw_publish_pause_all();
      } else {
        if (!fw_publish_group_transition(grp.group_id, 1)) {
          update_detail_play_button_visual();
          return;
        }
        uint32_t now_tick = lv_tick_get();
        s_detail_local_run_start_tick = now_tick;
        s_detail_run_start_tick = now_tick;
        s_detail_cycle_running = true;
        s_detail_playing = true;
        s_detail_manual_override_playing = true;
        s_detail_manual_override_until_ms = millis() + 5000;
        update_detail_play_button_visual();
      }
    }, LV_EVENT_CLICKED, ctx);
    lv_obj_add_event_cb(play_btn, [](lv_event_t* e){
      if (lv_event_get_code(e) == LV_EVENT_DELETE) { void* ud = lv_event_get_user_data(e); if (ud) free(ud); }
    }, LV_EVENT_DELETE, ctx);
  }

  // 완료 버튼
  lv_obj_t* done_btn = make_circle_btn(btn_row, &check_100dp_999999_FILL0_wght400_GRAD0_opsz48, 110, 0x1B8F50, 224, 13, 0x181818, 60);
  struct DoneCtx { int group_idx; };
  DoneCtx* dctx = (DoneCtx*)malloc(sizeof(DoneCtx));
  if (dctx) {
    dctx->group_idx = group_idx;
    lv_obj_add_event_cb(done_btn, [](lv_event_t* e){
      DoneCtx* c = (DoneCtx*)lv_event_get_user_data(e);
      if (c->group_idx < 0 || c->group_idx >= s_group_cnt) return;
      HwGroupData& grp = s_groups[c->group_idx];
      if (fw_publish_group_transition(grp.group_id, 99)) {
        close_homework_detail_page();
      }
    }, LV_EVENT_CLICKED, dctx);
    lv_obj_add_event_cb(done_btn, [](lv_event_t* e){
      if (lv_event_get_code(e) == LV_EVENT_DELETE) { void* ud = lv_event_get_user_data(e); if (ud) free(ud); }
    }, LV_EVENT_DELETE, dctx);
  }

  // Note: do NOT move_foreground(time_row) here. The parent uses a flex
  // column layout where child order == vertical layout order; moving
  // time_row to the foreground would shift it visually *below* btn_row.
  // Instead we keep the slots fully inside the 28px band so btn_row can
  // never clip the digits.

  // 슬라이드 인 애니메이션
  lv_obj_set_x(s_hw_detail_screen, 320);
  lv_anim_t a;
  lv_anim_init(&a);
  lv_anim_set_var(&a, s_hw_detail_screen);
  lv_anim_set_values(&a, 320, 0);
  lv_anim_set_time(&a, 220);
  lv_anim_set_exec_cb(&a, (lv_anim_exec_xcb_t)lv_obj_set_x);
  lv_anim_set_path_cb(&a, lv_anim_path_ease_out);
  lv_anim_start(&a);

  // 타이머 시작
  s_detail_timer_epoch++;
  s_detail_timer = lv_timer_create(detail_timer_cb, 1000, (void*)(uintptr_t)s_detail_timer_epoch);
  lv_timer_set_repeat_count(s_detail_timer, -1);
  detail_timer_cb(s_detail_timer);
}

static void ui_port_try_open_pending_homework_detail(void) {
  if (!s_pending_detail_group_id[0]) return;
  int idx = -1;
  for (uint8_t i = 0; i < s_group_cnt; i++) {
    if (strcmp(s_groups[i].group_id, s_pending_detail_group_id) == 0) {
      idx = (int)i;
      break;
    }
  }
  if (idx < 0) return;
  if (s_groups[idx].phase != 2) return;
  s_pending_detail_group_id[0] = '\0';
  close_hw_add_menu_page();
  show_homework_detail_page(idx);
}

void ui_port_on_device_ack_json(const char* body) {
  if (!body || !body[0]) return;
  StaticJsonDocument<384> doc;
  DeserializationError err = deserializeJson(doc, body);
  if (err) return;
  const char* action = doc["action"] | "";
  if (strcmp(action, "create_descriptive_writing") != 0) return;
  if (!doc["ok"].as<bool>()) return;
  const char* gid = doc["group_id"] | "";
  if (!gid || !gid[0]) return;
  strncpy(s_pending_detail_group_id, gid, sizeof(s_pending_detail_group_id) - 1);
  s_pending_detail_group_id[sizeof(s_pending_detail_group_id) - 1] = '\0';
  ui_port_try_open_pending_homework_detail();
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


