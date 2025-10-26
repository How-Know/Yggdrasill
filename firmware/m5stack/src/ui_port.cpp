#include "ui_port.h"
#include <M5Unified.h>
#include <lvgl.h>
#include "screensaver.h"
#include <LittleFS.h>
#include "ota_update.h"
#include "version.h"

// main.cpp에 정의된 전역 변수 (바인딩 추적용)
extern String studentId;

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
static bool s_homeworks_mode = false; // false: 학생 리스트, true: 과제/정보 pager
static lv_obj_t* s_empty_label = nullptr;
static lv_obj_t* s_empty_overlay = nullptr;
static lv_obj_t* s_volume_popup = nullptr;
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

// Phase 2 카드의 accumulated 실시간 업데이트용
struct Phase2CardData {
  lv_obj_t* card;
  lv_obj_t* time_lbl;
  uint32_t base_accumulated;
  uint32_t start_tick;
  lv_timer_t* timer;
};

static void update_phase2_time_cb(lv_timer_t* timer) {
  if (!timer || !timer->user_data) return;
  Phase2CardData* data = (Phase2CardData*)timer->user_data;
  
  // 강화된 유효성 체크: 카드와 라벨 모두 확인
  if (!data->card || !data->time_lbl) {
    Serial.println("[TIMER] Invalid data pointers - deleting timer");
    lv_timer_del(timer);
    free(data);
    return;
  }
  
  // lv_obj_is_valid는 완벽하지 않으므로, 추가로 부모 체크
  if (!lv_obj_is_valid(data->card) || !lv_obj_is_valid(data->time_lbl)) {
    Serial.println("[TIMER] Objects invalidated - deleting timer");
    lv_timer_del(timer);
    free(data);
    return;
  }
  
  // 카드가 리스트에 여전히 속해있는지 확인
  lv_obj_t* parent = lv_obj_get_parent(data->card);
  if (!parent || !lv_obj_is_valid(parent)) {
    Serial.println("[TIMER] Parent invalidated - deleting timer");
    lv_timer_del(timer);
    free(data);
    return;
  }
  
  // 정상 동작
  uint32_t elapsed_sec = (lv_tick_get() - data->start_tick) / 1000;
  uint32_t total_sec = data->base_accumulated + elapsed_sec;
  int hours = total_sec / 3600;
  int mins = (total_sec % 3600) / 60;
  
  char time_buf[32];
  if (hours > 0) {
    snprintf(time_buf, sizeof(time_buf), "%dh %dm", hours, mins);
  } else {
    snprintf(time_buf, sizeof(time_buf), "%dm", mins);
  }
  lv_label_set_text(data->time_lbl, time_buf);
}

bool g_bottom_sheet_open = false;
bool g_should_vibrate_phase4 = false;

static void show_volume_popup(void);
static void close_volume_popup(void);
static void show_brightness_popup(void);
static void close_brightness_popup(void);
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

// Safe exec wrapper for border opacity animation (avoid mismatched function signature)
static void anim_exec_set_border_opa(void* obj, int32_t v) {
  lv_obj_set_style_border_opa((lv_obj_t*)obj, (lv_opa_t)v, LV_PART_MAIN);
}

static void handle_drag_end(lv_event_t* e) {
  if (!s_bottom_sheet || !s_bottom_handle) return;
  lv_coord_t sheetY = lv_obj_get_y(s_bottom_sheet);
  lv_coord_t threshold = (140 + 240) / 2; // 중간 지점 = 190
  
  lv_anim_t a1; lv_anim_init(&a1); lv_anim_set_var(&a1, s_bottom_sheet);
  lv_anim_set_time(&a1, 250); lv_anim_set_path_cb(&a1, lv_anim_path_ease_out);
  lv_anim_set_exec_cb(&a1, (lv_anim_exec_xcb_t)lv_obj_set_y);
  lv_anim_t a2; lv_anim_init(&a2); lv_anim_set_var(&a2, s_bottom_handle);
  lv_anim_set_time(&a2, 250); lv_anim_set_path_cb(&a2, lv_anim_path_ease_out);
  lv_anim_set_exec_cb(&a2, (lv_anim_exec_xcb_t)lv_obj_set_y);
  
  if (sheetY < threshold) {
    // 더 위쪽이면 완전히 열기
    lv_anim_set_values(&a1, sheetY, 140);
    lv_anim_set_values(&a2, lv_obj_get_y(s_bottom_handle), 116);
    g_bottom_sheet_open = true;
  } else {
    // 더 아래쪽이면 완전히 닫기
    lv_anim_set_values(&a1, sheetY, 240);
    lv_anim_set_values(&a2, lv_obj_get_y(s_bottom_handle), 216);
    g_bottom_sheet_open = false;
  }
  lv_anim_start(&a1); lv_anim_start(&a2);
}

void toggle_bottom_sheet(void) {
  if (!s_bottom_sheet || !s_bottom_handle) return;
  lv_anim_t a1; lv_anim_init(&a1); lv_anim_set_var(&a1, s_bottom_sheet);
  lv_anim_set_time(&a1, 250); lv_anim_set_path_cb(&a1, lv_anim_path_ease_out);
  lv_anim_set_exec_cb(&a1, (lv_anim_exec_xcb_t)lv_obj_set_y);
  lv_anim_t a2; lv_anim_init(&a2); lv_anim_set_var(&a2, s_bottom_handle);
  lv_anim_set_time(&a2, 250); lv_anim_set_path_cb(&a2, lv_anim_path_ease_out);
  lv_anim_set_exec_cb(&a2, (lv_anim_exec_xcb_t)lv_obj_set_y);
  if (g_bottom_sheet_open) {
    lv_anim_set_values(&a1, 140, 240);
    lv_anim_set_values(&a2, 116, 216);
    g_bottom_sheet_open = false;
  } else {
    lv_anim_set_values(&a1, 240, 140);
    lv_anim_set_values(&a2, 216, 116);
    g_bottom_sheet_open = true;
  }
  lv_anim_start(&a1); lv_anim_start(&a2);
}

static void create_base_container() {
  if (s_stage) return;
  lv_obj_t* scr = lv_scr_act();
  // container (full screen, no rounding)
  lv_obj_t* container = lv_obj_create(scr);
  lv_obj_set_size(container, lv_pct(100), lv_pct(100));
  lv_obj_set_style_bg_color(container, lv_color_hex(0x141414), 0);
  lv_obj_set_style_border_width(container, 0, 0);
  lv_obj_set_style_radius(container, 0, 0);
  lv_obj_set_style_pad_all(container, 0, 0);
  lv_obj_set_scrollbar_mode(container, LV_SCROLLBAR_MODE_OFF);
  if (s_global_font) lv_obj_set_style_text_font(container, s_global_font, 0);

  // stage
  s_stage = lv_obj_create(container);
  lv_obj_set_size(s_stage, lv_pct(100), lv_pct(100));
  lv_obj_set_style_bg_opa(s_stage, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(s_stage, 0, 0);
  lv_obj_set_style_radius(s_stage, 0, 0);
  lv_obj_set_style_pad_all(s_stage, 0, 0);
  lv_obj_set_scrollbar_mode(s_stage, LV_SCROLLBAR_MODE_OFF);
  if (s_global_font) lv_obj_set_style_text_font(s_stage, s_global_font, 0);
  // stage 하위 라벨에도 기본 폰트 전파
  lv_obj_set_style_text_font(s_stage, s_global_font, LV_PART_MAIN | LV_STATE_DEFAULT);
}

static void build_student_list_ui() {
  create_base_container();
  lv_obj_clean(s_stage);
  s_homeworks_mode = false;
  // student list only
  s_list = lv_obj_create(s_stage);
  lv_obj_set_size(s_list, lv_pct(100), lv_pct(100));
  lv_obj_align(s_list, LV_ALIGN_TOP_LEFT, 0, 0);
  lv_obj_set_style_bg_color(s_list, lv_color_hex(0x141414), 0);
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
  LV_LOG_USER("empty_label created and text set");
  // Re-attach screensaver activity handlers
  screensaver_attach_activity(lv_scr_act());
}

static void build_homeworks_ui_internal() {
  create_base_container();
  lv_obj_clean(s_stage);
  s_homeworks_mode = true;

  // pages: info | homeworks | classes
  s_pages = lv_obj_create(s_stage);
  lv_obj_set_size(s_pages, lv_pct(100), lv_pct(100));
  lv_obj_set_style_bg_opa(s_pages, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(s_pages, 0, 0);
  lv_obj_set_style_radius(s_pages, 0, 0);
  lv_obj_set_flex_flow(s_pages, LV_FLEX_FLOW_ROW);
  lv_obj_set_scroll_dir(s_pages, LV_DIR_HOR);
  lv_obj_set_scroll_snap_x(s_pages, LV_SCROLL_SNAP_CENTER);
  // 과도한 관성으로 2페이지 이동 방지
  lv_obj_clear_flag(s_pages, LV_OBJ_FLAG_SCROLL_MOMENTUM);
  lv_obj_set_style_pad_column(s_pages, 12, 0);
  lv_obj_set_scrollbar_mode(s_pages, LV_SCROLLBAR_MODE_OFF);
  // 페이지 스크롤 감지를 위한 직접 훅
  lv_obj_add_flag(s_pages, LV_OBJ_FLAG_EVENT_BUBBLE);
  screensaver_attach_activity(s_pages);

  // info panel
  s_info_panel = lv_obj_create(s_pages);
  lv_obj_set_size(s_info_panel, lv_pct(100), lv_pct(100));
  lv_obj_set_style_bg_color(s_info_panel, lv_color_hex(0x141414), 0);
  lv_obj_set_style_border_width(s_info_panel, 0, 0);
  lv_obj_set_style_radius(s_info_panel, 0, 0);
  lv_obj_set_style_pad_all(s_info_panel, 12, 0);
  lv_obj_set_style_pad_right(s_info_panel, 12, 0);
  lv_obj_set_style_pad_row(s_info_panel, 4, 0);
  lv_obj_set_style_pad_bottom(s_info_panel, 16, 0);
  lv_obj_set_scrollbar_mode(s_info_panel, LV_SCROLLBAR_MODE_OFF);
  lv_obj_set_scroll_dir(s_info_panel, LV_DIR_VER);
  lv_obj_set_flex_flow(s_info_panel, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_info_panel, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
  if (s_global_font) lv_obj_set_style_text_font(s_info_panel, s_global_font, 0);
  // 정보 패널 스크롤 감지
  lv_obj_add_flag(s_info_panel, LV_OBJ_FLAG_EVENT_BUBBLE);
  screensaver_attach_activity(s_info_panel);

  // homeworks page
  lv_obj_t* homeworks_page = lv_obj_create(s_pages);
  lv_obj_set_size(homeworks_page, lv_pct(100), lv_pct(100));
  lv_obj_set_style_bg_opa(homeworks_page, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(homeworks_page, 0, 0);
  lv_obj_set_style_radius(homeworks_page, 0, 0);
  lv_obj_set_style_pad_all(homeworks_page, 0, 0);

  s_list = lv_obj_create(homeworks_page);
  lv_obj_set_size(s_list, lv_pct(100), lv_pct(100));
  lv_obj_set_style_bg_color(s_list, lv_color_hex(0x141414), 0);
  lv_obj_set_style_border_width(s_list, 0, 0);
  lv_obj_set_style_radius(s_list, 0, 0);
  lv_obj_set_style_pad_all(s_list, 8, 0);
  lv_obj_set_flex_flow(s_list, LV_FLEX_FLOW_COLUMN);
  lv_obj_set_flex_align(s_list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_START);
  lv_obj_set_style_pad_row(s_list, 12, 0);
  lv_obj_set_scroll_dir(s_list, LV_DIR_VER);
  lv_obj_set_scrollbar_mode(s_list, LV_SCROLLBAR_MODE_OFF);
  // 과제 리스트 스크롤 이벤트를 화면보호기에 직접 부착
  lv_obj_add_flag(s_list, LV_OBJ_FLAG_EVENT_BUBBLE);
  screensaver_attach_activity(s_list);

  // classes page (placeholder)
  lv_obj_t* classes_page = lv_obj_create(s_pages);
  lv_obj_set_size(classes_page, lv_pct(100), lv_pct(100));
  lv_obj_set_style_bg_color(classes_page, lv_color_hex(0x141414), 0);
  lv_obj_set_style_border_width(classes_page, 0, 0);
  lv_obj_set_style_radius(classes_page, 0, 0);
  lv_obj_set_style_pad_all(classes_page, 12, 0);
  lv_obj_set_scrollbar_mode(classes_page, LV_SCROLLBAR_MODE_OFF);
  if (s_global_font) lv_obj_set_style_text_font(classes_page, s_global_font, 0);
  lv_obj_t* classes_label = lv_label_create(classes_page);
  lv_obj_set_style_text_color(classes_label, lv_color_hex(0x808080), 0);
  lv_label_set_text(classes_label, u8"수업 페이지\n(준비 중)");
  lv_obj_center(classes_label);

  // bottom sheet handle
  s_bottom_handle = lv_obj_create(lv_obj_get_parent(s_stage));
  lv_obj_set_size(s_bottom_handle, 320, 24);
  lv_obj_set_pos(s_bottom_handle, 0, 216);
  lv_obj_set_style_bg_opa(s_bottom_handle, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(s_bottom_handle, 0, 0);
  lv_obj_set_style_radius(s_bottom_handle, 0, 0);
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
    if (code == LV_EVENT_CLICKED) toggle_bottom_sheet();
  }, LV_EVENT_CLICKED, NULL);

  // bottom sheet body
  s_bottom_sheet = lv_obj_create(lv_obj_get_parent(s_stage));
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

  // volume button (10% larger) - transparent background, gray icon
  lv_obj_t* vol_btn = lv_btn_create(s_bottom_sheet);
  lv_obj_set_size(vol_btn, 55, 55);
  lv_obj_set_style_radius(vol_btn, 10, 0);
  lv_obj_set_style_bg_opa(vol_btn, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(vol_btn, 0, 0);
  lv_obj_set_style_shadow_width(vol_btn, 0, 0);
  // 왼쪽으로 3px 이동
  lv_obj_set_style_translate_x(vol_btn, -3, 0);
  lv_obj_t* vol_img = lv_img_create(vol_btn);
  lv_img_set_src(vol_img, &volume_mute_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
  lv_obj_set_style_img_recolor(vol_img, lv_color_hex(0xC0C0C0), 0);
  lv_obj_set_style_img_recolor_opa(vol_img, LV_OPA_COVER, 0);
  lv_img_set_zoom(vol_img, 220);
  lv_obj_center(vol_img);
  lv_obj_add_event_cb(vol_btn, [](lv_event_t* e){ (void)e; show_volume_popup(); }, LV_EVENT_CLICKED, NULL);

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
  lv_obj_add_event_cb(home_btn, [](lv_event_t* e){ (void)e; if (s_pages) { lv_obj_scroll_to_view(lv_obj_get_child(s_pages, 1), LV_ANIM_ON); } }, LV_EVENT_CLICKED, NULL);

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

  // FAB (휴식)
  if (!s_fab) {
    s_fab = lv_btn_create(lv_obj_get_parent(s_stage));
    lv_obj_set_size(s_fab, 67, 57);
    lv_obj_set_style_radius(s_fab, 12, 0);
    lv_obj_set_style_bg_color(s_fab, lv_color_hex(0x1E88E5), 0);
    lv_obj_set_style_border_width(s_fab, 0, 0);
    lv_obj_set_style_shadow_width(s_fab, 14, 0);
    lv_obj_set_style_shadow_opa(s_fab, LV_OPA_30, 0);
    lv_obj_align(s_fab, LV_ALIGN_BOTTOM_RIGHT, -16, -16);
    lv_obj_t* icon = lv_label_create(s_fab);
    lv_obj_set_style_text_color(icon, lv_color_hex(0xFFFFFF), 0);
    lv_label_set_text(icon, u8"휴식");
    lv_obj_center(icon);
    lv_obj_add_event_cb(s_fab, [](lv_event_t* e){ (void)e; fw_publish_pause_all(); }, LV_EVENT_CLICKED, NULL);
  }
  
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
  
  // 바인딩된 학생이 있으면 과제 모드로 시작, 없으면 학생 리스트 모드
  if (savedStudentId.length() > 0) {
    studentId = savedStudentId;
    build_homeworks_ui_internal();
    Serial.printf("[INIT] Starting in homework mode for student: %s\n", studentId.c_str());
    // MQTT 연결 후 student_info와 homeworks는 onMqttConnect에서 자동 요청됨
  } else {
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
    // 또는 좌측 정보 페이지로 바꿀 때까지 대기
    // 여기서는 homeworks 모드에서도 학생 리스트 갱신 시 별도 처리 없이 반환
  }
  lv_obj_clean(s_list);
  s_empty_label = nullptr;
  size_t count = 0;
  for (JsonObject _ : students) { (void)_; ++count; }
  if (count == 0) {
    // show empty message
    if (!s_empty_overlay) {
      s_empty_overlay = lv_obj_create(s_stage);
      lv_obj_set_size(s_empty_overlay, lv_pct(100), lv_pct(100));
      lv_obj_set_style_bg_opa(s_empty_overlay, LV_OPA_TRANSP, 0);
      lv_obj_set_style_border_width(s_empty_overlay, 0, 0);
      s_empty_label = lv_label_create(s_empty_overlay);
    }
    lv_obj_clear_flag(s_empty_overlay, LV_OBJ_FLAG_HIDDEN);
    if (!s_empty_label) s_empty_label = lv_label_create(s_empty_overlay);
    lv_obj_set_style_text_color(s_empty_label, lv_color_hex(0xA0A0A0), 0);
    lv_label_set_text(s_empty_label, u8"등원 예정 학생이 없습니다.");
    lv_obj_center(s_empty_label);
    return;
  }
  // hide empty overlay when data is present
  if (s_empty_overlay) lv_obj_add_flag(s_empty_overlay, LV_OBJ_FLAG_HIDDEN);
  for (JsonObject s : students) {
    const char* name = s["name"] | s["student_name"] | u8"학생";
    const char* sid = s.containsKey("student_id") ? (const char*)s["student_id"] : (s.containsKey("id") ? (const char*)s["id"] : "");
    lv_obj_t* card = lv_obj_create(s_list);
    lv_obj_set_width(card, lv_pct(100));
    lv_obj_set_height(card, 96);
    lv_obj_set_style_radius(card, 10, 0);
    lv_obj_set_style_bg_color(card, lv_color_hex(0x1A1A1A), 0);
    lv_obj_set_style_border_color(card, lv_color_hex(0x2C2C2C), 0);
    lv_obj_set_style_border_width(card, 2, 0);
    lv_obj_set_style_pad_all(card, 14, 0);
    lv_obj_t* lbl = lv_label_create(card);
    lv_obj_set_style_text_color(lbl, lv_color_hex(0xE6E6E6), 0);
    lv_label_set_text(lbl, name);
    lv_obj_align(lbl, LV_ALIGN_LEFT_MID, 0, 0);
    if (sid && *sid) {
      char* sid_copy = (char*)malloc(strlen(sid) + 1);
      if (sid_copy) {
        strcpy(sid_copy, sid);
        lv_obj_add_event_cb(card, [](lv_event_t* e){
          const char* studentId = (const char*)lv_event_get_user_data(e);
          fw_publish_bind(studentId);
          // 홈워크 UI로 전환 후 정보 요청
          build_homeworks_ui_internal();
          fw_publish_student_info(studentId);
          if (lv_obj_is_valid(s_pages)) { lv_obj_scroll_to_view(lv_obj_get_child(s_pages, 1), LV_ANIM_OFF); }
        }, LV_EVENT_CLICKED, sid_copy);
      }
    }
  }
}

// Debounce: M5에서 연속 업데이트 시 충돌 방지 (300ms)
static uint32_t s_last_homework_update_ms = 0;
static const uint32_t HOMEWORK_UPDATE_DEBOUNCE_MS = 300;
// 카드 클릭 디바운스 (500ms)
static uint32_t s_last_card_click_ms = 0;
static const uint32_t CARD_CLICK_DEBOUNCE_MS = 500;

void ui_port_update_homeworks(const JsonArray& items) {
  uint32_t now = millis();
  if (now - s_last_homework_update_ms < HOMEWORK_UPDATE_DEBOUNCE_MS) {
    Serial.println("[HW] Debounced - update too fast, skipping");
    return;
  }
  s_last_homework_update_ms = now;
  
  if (!s_homeworks_mode) {
    build_homeworks_ui_internal();
  }
  
  // 기존 Phase2 타이머 모두 강제 정리 (카드 삭제 전) - 해결책 2
  if (s_list && lv_obj_is_valid(s_list)) {
    uint32_t child_count = lv_obj_get_child_cnt(s_list);
    for (uint32_t i = 0; i < child_count; i++) {
      lv_obj_t* frame = lv_obj_get_child(s_list, i);
      if (!frame || !lv_obj_is_valid(frame)) continue;
      if (lv_obj_get_child_cnt(frame) == 0) continue;
      lv_obj_t* card = lv_obj_get_child(frame, 0);
      if (!card || !lv_obj_is_valid(card)) continue;
      
      // DELETE 이벤트 핸들러 수동 트리거하여 타이머 정리
      lv_event_send(card, LV_EVENT_DELETE, NULL);
    }
    // 약간의 지연으로 이벤트 처리 완료 보장
    lv_timer_handler();
  }
  
  g_should_vibrate_phase4 = false;
  lv_obj_clean(s_list);
  for (JsonObject it : items) {
    const char* title = it["title"] | it["name"] | u8"과제";
    const char* itemId = it.containsKey("item_id") ? (const char*)it["item_id"] : "";
    int phase = it.containsKey("phase") ? (int)it["phase"] : 1;
    uint32_t srv_color = 0x1E88E5;
    if (it.containsKey("color")) {
      double v = it["color"];
      if (v > 0) srv_color = ((uint32_t)v) & 0xFFFFFFu;
    }
    
    // wrapper frame for gradient border
    lv_obj_t* frame = lv_obj_create(s_list);
    lv_obj_set_width(frame, lv_pct(100));
    lv_obj_set_height(frame, 96);
    lv_obj_set_style_pad_all(frame, 2, 0);
    lv_obj_set_style_radius(frame, 12, 0);
    lv_obj_set_style_bg_color(frame, lv_color_hex(0x141414), 0);
    lv_obj_set_style_border_width(frame, 0, 0);
    lv_obj_clear_flag(frame, LV_OBJ_FLAG_SCROLLABLE);

    lv_obj_t* card = lv_obj_create(frame);
    lv_obj_set_width(card, lv_pct(100));
    lv_obj_set_height(card, 92);
    lv_obj_set_style_radius(card, 10, 0);
    lv_obj_set_style_bg_color(card, lv_color_hex(0x1A1A1A), 0);
    lv_obj_set_style_border_color(card, lv_color_hex(0x2C2C2C), 0);
    lv_obj_set_style_border_width(card, 2, 0);
    lv_obj_set_style_pad_all(card, 14, 0);
    lv_obj_set_style_pad_left(card, 21, 0);
    lv_obj_clear_flag(card, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(card, LV_OBJ_FLAG_CLICKABLE);
    
    lv_obj_t* lbl = lv_label_create(card);
    lv_obj_set_style_text_color(lbl, lv_color_hex(0xE6E6E6), 0);
    lv_label_set_text(lbl, title);
    lv_label_set_long_mode(lbl, LV_LABEL_LONG_DOT);
    lv_obj_set_width(lbl, lv_pct(60));
    lv_obj_align(lbl, LV_ALIGN_LEFT_MID, 0, 0);
    lv_obj_add_flag(lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
    
    if (phase == 2) {
      // 수행: gradient border + shadow + body/time info
      uint8_t r = (srv_color >> 16) & 0xFF, g = (srv_color >> 8) & 0xFF, b = srv_color & 0xFF;
      int lr = r + 40; if (lr > 255) lr = 255; int lg = g + 40; if (lg > 255) lg = 255; int lb = b + 40; if (lb > 255) lb = 255;
      int dr = r - 30; if (dr < 0) dr = 0; int dg = g - 30; if (dg < 0) dg = 0; int db = b - 30; if (db < 0) db = 0;
      uint32_t c1 = ((uint32_t)lr << 16) | ((uint32_t)lg << 8) | (uint32_t)lb;
      uint32_t c2 = ((uint32_t)dr << 16) | ((uint32_t)dg << 8) | (uint32_t)db;
      lv_obj_set_style_bg_color(frame, lv_color_hex(c1), 0);
      lv_obj_set_style_bg_grad_color(frame, lv_color_hex(c2), 0);
      lv_obj_set_style_bg_grad_dir(frame, LV_GRAD_DIR_HOR, 0);
      lv_obj_set_style_shadow_width(card, 10, 0);
      lv_obj_set_style_shadow_color(card, lv_color_hex(srv_color), 0);
      lv_obj_set_style_shadow_opa(card, LV_OPA_20, 0);
      
      // body와 accumulated 표시 (카드 우측, 작은 폰트)
      const char* body = it["body"] | "";
      int accumulated = it.containsKey("accumulated") ? (int)it["accumulated"] : 0;
      
      if (*body || accumulated > 0) {
        lv_obj_t* info_cont = lv_obj_create(card);
        lv_obj_set_size(info_cont, 100, LV_SIZE_CONTENT);
        lv_obj_align(info_cont, LV_ALIGN_RIGHT_MID, -8, 0);
        lv_obj_set_style_bg_opa(info_cont, LV_OPA_TRANSP, 0);
        lv_obj_set_style_border_width(info_cont, 0, 0);
        lv_obj_set_style_pad_all(info_cont, 0, 0);
        lv_obj_set_flex_flow(info_cont, LV_FLEX_FLOW_COLUMN);
        lv_obj_set_flex_align(info_cont, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_END, LV_FLEX_ALIGN_END);
        lv_obj_add_flag(info_cont, LV_OBJ_FLAG_EVENT_BUBBLE);
        
        extern const lv_font_t kakao_kr_18;
        extern const lv_font_t kakao_kr_16;
        
        if (*body) {
          lv_obj_t* body_lbl = lv_label_create(info_cont);
          lv_obj_set_style_text_font(body_lbl, &kakao_kr_16, 0);
          lv_obj_set_style_text_color(body_lbl, lv_color_hex(0xB0B0B0), 0);
          lv_obj_set_style_text_align(body_lbl, LV_TEXT_ALIGN_RIGHT, 0);
          lv_label_set_text(body_lbl, body);
          lv_label_set_long_mode(body_lbl, LV_LABEL_LONG_DOT);
          lv_obj_set_width(body_lbl, lv_pct(100));
          lv_obj_add_flag(body_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
        }
        
        // accumulated 시간 (실시간 업데이트)
        lv_obj_t* time_lbl = lv_label_create(info_cont);
        lv_obj_set_style_text_font(time_lbl, &kakao_kr_16, 0);
        lv_obj_set_style_text_color(time_lbl, lv_color_hex(0x808080), 0);
        lv_obj_add_flag(time_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
        
        // 타이머로 1초마다 업데이트 (안전하게)
        Phase2CardData* timer_data = (Phase2CardData*)malloc(sizeof(Phase2CardData));
        if (timer_data) {
          timer_data->card = card;
          timer_data->time_lbl = time_lbl;
          timer_data->base_accumulated = accumulated;
          timer_data->start_tick = lv_tick_get();
          
          lv_timer_t* upd_timer = lv_timer_create(update_phase2_time_cb, 1000, timer_data);
          lv_timer_set_repeat_count(upd_timer, -1);
          timer_data->timer = upd_timer;
          
          // 카드 삭제 시 타이머도 명시적으로 정리
          lv_obj_add_event_cb(card, [](lv_event_t* e){
            if (lv_event_get_code(e) == LV_EVENT_DELETE) {
              void* ud = lv_event_get_user_data(e);
              if (ud) {
                Phase2CardData* d = (Phase2CardData*)ud;
                if (d->timer) lv_timer_del(d->timer);
                free(d);
              }
            }
          }, LV_EVENT_DELETE, timer_data);
          
          // 초기 표시
          int hours = accumulated / 3600;
          int mins = (accumulated % 3600) / 60;
          char time_buf[32];
          if (hours > 0) {
            snprintf(time_buf, sizeof(time_buf), "%dh %dm", hours, mins);
          } else {
            snprintf(time_buf, sizeof(time_buf), "%dm", mins);
          }
          lv_label_set_text(time_lbl, time_buf);
        }
      }
    } else if (phase == 3) {
      // 제출: donut spinner
      lv_obj_set_style_border_width(card, 0, 0);
      lv_obj_t* sp = lv_spinner_create(card, 1000, 60);
      lv_obj_set_size(sp, 24, 24);
      lv_obj_align(sp, LV_ALIGN_RIGHT_MID, -8, 0);
      lv_obj_set_style_bg_opa(sp, LV_OPA_TRANSP, 0);
      lv_obj_set_style_arc_color(sp, lv_color_hex(0x1A1A1A), 0);
      lv_obj_set_style_arc_width(sp, 4, 0);
      lv_obj_set_style_arc_color(sp, lv_color_hex(srv_color), LV_PART_INDICATOR);
      lv_obj_set_style_arc_width(sp, 4, LV_PART_INDICATOR);
      lv_obj_add_flag(sp, LV_OBJ_FLAG_EVENT_BUBBLE);
      lv_obj_set_style_shadow_color(card, lv_color_hex(srv_color), 0);
      lv_obj_set_style_shadow_width(card, 12, 0);
      lv_obj_set_style_shadow_opa(card, LV_OPA_20, 0);
    } else if (phase == 4) {
      // 확인: blinking border + vibration
      Serial.println("[PHASE4] Setting up card styles...");
      lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
      lv_obj_set_style_bg_color(card, lv_color_hex(0x202020), 0);
      lv_obj_set_style_border_color(card, lv_color_hex(srv_color), 0);
      lv_obj_set_style_border_width(card, 3, 0);
      lv_obj_set_style_border_opa(card, LV_OPA_TRANSP, 0);
      // 애니 중복 방지: 카드 대상 기존 애니 삭제
      lv_anim_del(card, NULL);
      Serial.println("[PHASE4] Creating animation...");
      lv_anim_t a1;
      lv_anim_init(&a1);
      lv_anim_set_var(&a1, card);
      lv_anim_set_time(&a1, 1000);
      lv_anim_set_playback_time(&a1, 1000);
      lv_anim_set_repeat_count(&a1, LV_ANIM_REPEAT_INFINITE);
      lv_anim_set_values(&a1, 0, 250);
      lv_anim_set_exec_cb(&a1, anim_exec_set_border_opa);
      lv_anim_set_path_cb(&a1, lv_anim_path_ease_in_out);
      lv_anim_start(&a1);
      Serial.println("[PHASE4] Animation started");
      g_should_vibrate_phase4 = true;
      Serial.println("[PHASE4] Complete!");
    }
    if (itemId && *itemId) {
      struct HwData { char id[64]; int phase; };
      HwData* d = (HwData*)malloc(sizeof(HwData));
      if (d) {
        strncpy(d->id, itemId, sizeof(d->id)-1); d->id[sizeof(d->id)-1] = '\0';
        d->phase = phase;
        // 클릭 이벤트 (디바운스 적용) - 해결책 1
        lv_obj_add_event_cb(card, [](lv_event_t* e){
          uint32_t now = millis();
          if (now - s_last_card_click_ms < CARD_CLICK_DEBOUNCE_MS) {
            Serial.println("[CARD] Click debounced - too fast");
            return;
          }
          s_last_card_click_ms = now;
          
          HwData* dd = (HwData*)lv_event_get_user_data(e);
          const char* act = nullptr;
          if (dd->phase == 1) act = "start"; 
          else if (dd->phase == 2) act = "submit"; 
          else if (dd->phase == 4) act = "wait"; 
          else act = nullptr;
          if (act) fw_publish_homework_action(act, dd->id);
        }, LV_EVENT_CLICKED, d);
        // 삭제 시 user_data 해제
        lv_obj_add_event_cb(card, [](lv_event_t* e){
          if (lv_event_get_code(e) == LV_EVENT_DELETE) {
            void* ud = lv_event_get_user_data(e);
            if (ud) free(ud);
          }
        }, LV_EVENT_DELETE, d);
      }
    }
  }
}

void ui_port_update_student_info(const JsonObject& info) {
  if (!s_homeworks_mode) {
    build_homeworks_ui_internal();
  }
  lv_obj_clean(s_info_panel);
  const char* name = info["name"] | u8"학생";
  const char* school = info["school"] | "";
  const int grade = info.containsKey("grade") ? (int)info["grade"] : -1;
  
  // 이름
  lv_obj_t* name_lbl = lv_label_create(s_info_panel);
  lv_obj_set_style_text_color(name_lbl, lv_color_hex(0xE6E6E6), 0);
  lv_label_set_text(name_lbl, name);
  
  // 여백 추가 (spacer)
  lv_obj_t* spacer = lv_obj_create(s_info_panel);
  lv_obj_set_size(spacer, 1, 16);
  lv_obj_set_style_bg_opa(spacer, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(spacer, 0, 0);
  
  // 학교/학년 (밝은 회색)
  lv_obj_t* sg = lv_label_create(s_info_panel);
  lv_obj_set_style_text_color(sg, lv_color_hex(0xA0A0A0), 0);
  char line2[128];
  if (*school && grade >= 0) snprintf(line2, sizeof(line2), u8"%s · %d학년", school, grade); 
  else if (*school) snprintf(line2, sizeof(line2), "%s", school); 
  else if (grade >= 0) snprintf(line2, sizeof(line2), u8"%d학년", grade); 
  else snprintf(line2, sizeof(line2), u8"—");
  lv_label_set_text(sg, line2);
  
  // 상단 내용과 버튼 사이 여백 (spacer)
  lv_obj_t* spacer2 = lv_obj_create(s_info_panel);
  lv_obj_set_size(spacer2, 1, 30);
  lv_obj_set_style_bg_opa(spacer2, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(spacer2, 0, 0);
  
  // 로그아웃 버튼 (하단)
  lv_obj_t* logout_btn = lv_btn_create(s_info_panel);
  lv_obj_set_size(logout_btn, 200, 44);
  lv_obj_set_style_radius(logout_btn, 22, 0);
  lv_obj_set_style_bg_color(logout_btn, lv_color_hex(0xDC143C), 0);
  lv_obj_set_style_border_width(logout_btn, 0, 0);
  lv_obj_set_style_shadow_width(logout_btn, 0, 0);
  lv_obj_t* logout_lbl = lv_label_create(logout_btn);
  if (s_global_font) lv_obj_set_style_text_font(logout_lbl, s_global_font, 0);
  lv_label_set_text(logout_lbl, u8"로그아웃");
  lv_obj_center(logout_lbl);
  lv_obj_add_event_cb(logout_btn, [](lv_event_t* e){ 
    (void)e; 
    
    // "오늘도 수고했어" 메시지 팝업 생성
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
    
    // 하원 기록 요청을 즉시 전송하고, 재시작은 타이머로 지연 수행
    fw_publish_unbind();
    lv_timer_t* restart_timer = lv_timer_create(restart_app_timer_cb, 1800, NULL);
    lv_timer_set_repeat_count(restart_timer, 1);
  }, LV_EVENT_CLICKED, NULL);
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
    // WiFi button (icon)
    lv_obj_t* wifi_btn = lv_btn_create(s_settings_scr);
    lv_obj_set_size(wifi_btn, 51, 51);
    lv_obj_set_style_radius(wifi_btn, 26, 0);
    lv_obj_set_style_bg_color(wifi_btn, lv_color_hex(0x1E1E1E), 0);
    lv_obj_set_style_border_width(wifi_btn, 0, 0);
    lv_obj_set_style_shadow_width(wifi_btn, 0, 0);
    lv_obj_align(wifi_btn, LV_ALIGN_CENTER, -70, 5);
    lv_obj_t* wifi_img = lv_img_create(wifi_btn);
    lv_img_set_src(wifi_img, &wifi_64dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
    lv_obj_set_style_img_recolor(wifi_img, lv_color_hex(0xE3E3E3), 0);
    lv_obj_set_style_img_recolor_opa(wifi_img, LV_OPA_COVER, 0);
    lv_img_set_zoom(wifi_img, 180);
    lv_obj_center(wifi_img);
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


