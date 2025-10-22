#include "settings_ui.h"
#include "wifi_ui.h"
#include <stdio.h>

static lv_obj_t* g_settings_screen = NULL;
static lv_obj_t* g_pages_ref = NULL;
static lv_obj_t* g_fab_ref = NULL;
static lv_obj_t* g_bottom_sheet_ref = NULL;
static lv_obj_t* g_bottom_handle_ref = NULL;

static void on_wifi_clicked(lv_event_t* e) {
    (void)e;
    printf("WiFi button clicked\n");
    fflush(stdout);
    if (!g_settings_screen) return;
    
    // Hide settings
    lv_obj_add_flag(g_settings_screen, LV_OBJ_FLAG_HIDDEN);
    
    // Show WiFi (on same parent)
    wifi_ui_show(lv_obj_get_parent(g_settings_screen), NULL);
}

static void on_refresh_clicked(lv_event_t* e) {
    (void)e;
    printf("Update check requested - checking for new firmware...\n");
    fflush(stdout);

    // MQTT로 업데이트 확인 요청
    extern void publish_check_update(void);
    publish_check_update();
}

static void on_close_clicked(lv_event_t* e) {
    (void)e;
    settings_ui_close();
}

static void on_deleted(lv_event_t* e) {
    (void)e;
    g_settings_screen = NULL;
}

void settings_ui_show(lv_obj_t* parent_stage,
                      lv_obj_t* pages_to_hide,
                      lv_obj_t* fab_to_hide,
                      lv_obj_t* bottom_sheet_to_hide,
                      lv_obj_t* bottom_handle_to_hide,
                      lv_font_t* title_font,
                      lv_font_t* label_font,
                      const char* app_version,
                      const lv_image_dsc_t* wifi_icon,
                      const lv_image_dsc_t* refresh_icon) {
    if (!parent_stage) return;
    
    // Save references
    g_pages_ref = pages_to_hide;
    g_fab_ref = fab_to_hide;
    g_bottom_sheet_ref = bottom_sheet_to_hide;
    g_bottom_handle_ref = bottom_handle_to_hide;
    
    // Close bottom sheet first if open
    extern void toggle_bottom_sheet(void);
    extern bool g_bottom_sheet_open;
    if (g_bottom_sheet_open) toggle_bottom_sheet();
    
    // If already created, just show
    if (g_settings_screen) {
        lv_obj_clear_flag(g_settings_screen, LV_OBJ_FLAG_HIDDEN);
        lv_obj_move_foreground(g_settings_screen);
        // Hide main UI
        if (g_pages_ref) lv_obj_add_flag(g_pages_ref, LV_OBJ_FLAG_HIDDEN);
        if (g_fab_ref) lv_obj_add_flag(g_fab_ref, LV_OBJ_FLAG_HIDDEN);
        if (g_bottom_sheet_ref) lv_obj_add_flag(g_bottom_sheet_ref, LV_OBJ_FLAG_HIDDEN);
        if (g_bottom_handle_ref) lv_obj_add_flag(g_bottom_handle_ref, LV_OBJ_FLAG_HIDDEN);
        return;
    }
    
    // Hide main UI (including bottom sheet by setting higher z-index for settings)
    if (g_pages_ref) lv_obj_add_flag(g_pages_ref, LV_OBJ_FLAG_HIDDEN);
    if (g_fab_ref) lv_obj_add_flag(g_fab_ref, LV_OBJ_FLAG_HIDDEN);
    // Don't hide bottom sheet/handle, just close if open
    extern void toggle_bottom_sheet(void);
    extern bool g_bottom_sheet_open;
    if (g_bottom_sheet_open) toggle_bottom_sheet();
    
    // Create settings screen once
    g_settings_screen = lv_obj_create(parent_stage);
    lv_obj_set_size(g_settings_screen, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_color(g_settings_screen, lv_color_hex(0x0F0F0F), 0);
    lv_obj_set_style_bg_opa(g_settings_screen, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(g_settings_screen, 0, 0);
    lv_obj_set_style_pad_all(g_settings_screen, 0, 0);
    lv_obj_clear_flag(g_settings_screen, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scroll_dir(g_settings_screen, LV_DIR_NONE);  // 스크롤 완전 차단
    lv_obj_move_foreground(g_settings_screen);  // 최상위로 (bottom sheet 위에)
    lv_obj_add_event_cb(g_settings_screen, on_deleted, LV_EVENT_DELETE, NULL);
    
    // Title
    lv_obj_t* title = lv_label_create(g_settings_screen);
    lv_label_set_text(title, "설정");
    if (title_font) lv_obj_set_style_text_font(title, title_font, 0);
    lv_obj_set_style_text_color(title, lv_color_white(), 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 24);
    
    // Version
    if (app_version) {
        lv_obj_t* ver = lv_label_create(g_settings_screen);
        lv_label_set_text_fmt(ver, "버전: %s", app_version);
        if (label_font) lv_obj_set_style_text_font(ver, label_font, 0);
        lv_obj_set_style_text_color(ver, lv_color_hex(0x999999), 0);
        lv_obj_align(ver, LV_ALIGN_TOP_MID, 0, 64);
    }
    
    // WiFi button (left) - 위로 올림
    lv_obj_t* wifi_btn = lv_btn_create(g_settings_screen);
    lv_obj_set_size(wifi_btn, 51, 51);
    lv_obj_set_style_radius(wifi_btn, 26, 0);
    lv_obj_set_style_bg_color(wifi_btn, lv_color_hex(0x1E1E1E), 0);
    lv_obj_set_style_border_width(wifi_btn, 0, 0);
    lv_obj_set_style_shadow_width(wifi_btn, 0, 0);
    lv_obj_align(wifi_btn, LV_ALIGN_CENTER, -50, 2);  // Y=2 (6px 더 아래로)
    if (wifi_icon) {
        lv_obj_t* wifi_img = lv_img_create(wifi_btn);
        lv_img_set_src(wifi_img, wifi_icon);
        lv_image_set_scale(wifi_img, 184);
        lv_obj_center(wifi_img);
    }
    lv_obj_add_event_cb(wifi_btn, on_wifi_clicked, LV_EVENT_CLICKED, NULL);
    
    // Refresh button (right) - 위로 올림
    lv_obj_t* refresh_btn = lv_btn_create(g_settings_screen);
    lv_obj_set_size(refresh_btn, 51, 51);
    lv_obj_set_style_radius(refresh_btn, 26, 0);
    lv_obj_set_style_bg_color(refresh_btn, lv_color_hex(0x1E1E1E), 0);
    lv_obj_set_style_border_width(refresh_btn, 0, 0);
    lv_obj_set_style_shadow_width(refresh_btn, 0, 0);
    lv_obj_align(refresh_btn, LV_ALIGN_CENTER, 50, 2);  // Y=2 (6px 더 아래로)
    if (refresh_icon) {
        lv_obj_t* refresh_img = lv_img_create(refresh_btn);
        lv_img_set_src(refresh_img, refresh_icon);
        lv_image_set_scale(refresh_img, 184);
        lv_obj_center(refresh_img);
    }
    lv_obj_add_event_cb(refresh_btn, on_refresh_clicked, LV_EVENT_CLICKED, NULL);
    
    // Close button
    lv_obj_t* close_btn = lv_btn_create(g_settings_screen);
    lv_obj_set_size(close_btn, 200, 44);
    lv_obj_set_style_radius(close_btn, 22, 0);
    lv_obj_set_style_bg_color(close_btn, lv_color_hex(0x333333), 0);
    lv_obj_set_style_border_width(close_btn, 0, 0);
    lv_obj_align(close_btn, LV_ALIGN_BOTTOM_MID, 0, -24);
    lv_obj_t* close_lbl = lv_label_create(close_btn);
    lv_label_set_text(close_lbl, "닫기");
    if (label_font) lv_obj_set_style_text_font(close_lbl, label_font, 0);
    lv_obj_set_style_text_color(close_lbl, lv_color_white(), 0);
    lv_obj_center(close_lbl);
    lv_obj_add_event_cb(close_btn, on_close_clicked, LV_EVENT_CLICKED, NULL);
}

void settings_ui_restore(void) {
    if (g_settings_screen) {
        lv_obj_clear_flag(g_settings_screen, LV_OBJ_FLAG_HIDDEN);
    }
}

void settings_ui_close(void) {
    if (!g_settings_screen) return;
    
    // Close WiFi UI if open
    wifi_ui_close();
    
    // Hide instead of delete
    lv_obj_add_flag(g_settings_screen, LV_OBJ_FLAG_HIDDEN);
    
    // Restore hidden UI
    if (g_pages_ref) lv_obj_clear_flag(g_pages_ref, LV_OBJ_FLAG_HIDDEN);
    if (g_fab_ref) lv_obj_clear_flag(g_fab_ref, LV_OBJ_FLAG_HIDDEN);
    if (g_bottom_sheet_ref) lv_obj_clear_flag(g_bottom_sheet_ref, LV_OBJ_FLAG_HIDDEN);
    if (g_bottom_handle_ref) lv_obj_clear_flag(g_bottom_handle_ref, LV_OBJ_FLAG_HIDDEN);
}

bool settings_ui_is_open(void) {
    return g_settings_screen && !lv_obj_has_flag(g_settings_screen, LV_OBJ_FLAG_HIDDEN);
}
