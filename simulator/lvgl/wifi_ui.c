#include "wifi_ui.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static lv_obj_t* g_wifi_screen = NULL;
static lv_obj_t* g_wifi_list_view = NULL;
static lv_obj_t* g_password_view = NULL;
static lv_obj_t* g_password_textarea = NULL;
static char g_selected_ssid[64] = {0};

// Forward declaration
void settings_ui_restore(void);

static void show_password_view(void);
static void show_list_view(void);

static void password_connect_clicked(lv_event_t* e) {
    (void)e;
    const char* password = g_password_textarea ? lv_textarea_get_text(g_password_textarea) : "";
    
    printf("Connecting to WiFi: SSID='%s', Password='%s'\n", g_selected_ssid, password);
    fflush(stdout);
    
    // TODO: M5.WiFi.begin(g_selected_ssid, password)
    
    // Close WiFi and return to settings
    wifi_ui_close();
    settings_ui_restore();
}

static void password_cancel_clicked(lv_event_t* e) {
    (void)e;
    show_list_view();
}

static void wifi_network_clicked(lv_event_t* e) {
    const char* ssid = (const char*)lv_event_get_user_data(e);
    if (!ssid) return;
    
    printf("WiFi network selected: %s\n", ssid);
    fflush(stdout);
    
    strncpy(g_selected_ssid, ssid, sizeof(g_selected_ssid) - 1);
    show_password_view();
}

static void show_list_view(void) {
    if (g_wifi_list_view) lv_obj_clear_flag(g_wifi_list_view, LV_OBJ_FLAG_HIDDEN);
    if (g_password_view) lv_obj_add_flag(g_password_view, LV_OBJ_FLAG_HIDDEN);
}

static void show_password_view(void) {
    if (g_wifi_list_view) lv_obj_add_flag(g_wifi_list_view, LV_OBJ_FLAG_HIDDEN);
    if (g_password_view) {
        lv_obj_clear_flag(g_password_view, LV_OBJ_FLAG_HIDDEN);
        if (g_password_textarea) lv_textarea_set_text(g_password_textarea, "");
    }
}

void wifi_ui_show(lv_obj_t* parent, lv_font_t* font) {
    if (!parent) return;
    
    // If already created, just show
    if (g_wifi_screen) {
        lv_obj_clear_flag(g_wifi_screen, LV_OBJ_FLAG_HIDDEN);
        lv_obj_move_foreground(g_wifi_screen);
        show_list_view();  // Always start with list view
        printf("WiFi screen shown\n");
        return;
    }
    
    printf("Creating WiFi screen...\n");
    fflush(stdout);
    
    // Create base screen
    g_wifi_screen = lv_obj_create(parent);
    lv_obj_set_size(g_wifi_screen, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_color(g_wifi_screen, lv_color_hex(0x0F0F0F), 0);
    lv_obj_set_style_bg_opa(g_wifi_screen, LV_OPA_COVER, 0);
    lv_obj_set_style_border_width(g_wifi_screen, 0, 0);
    lv_obj_set_style_pad_all(g_wifi_screen, 16, 0);
    lv_obj_clear_flag(g_wifi_screen, LV_OBJ_FLAG_SCROLLABLE);
    
    // === LIST VIEW ===
    g_wifi_list_view = lv_obj_create(g_wifi_screen);
    lv_obj_set_size(g_wifi_list_view, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_opa(g_wifi_list_view, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(g_wifi_list_view, 0, 0);
    lv_obj_set_style_pad_all(g_wifi_list_view, 0, 0);
    lv_obj_clear_flag(g_wifi_list_view, LV_OBJ_FLAG_SCROLLABLE);
    
    // Title
    lv_obj_t* title = lv_label_create(g_wifi_list_view);
    lv_label_set_text(title, "WiFi");
    if (font) lv_obj_set_style_text_font(title, font, 0);
    lv_obj_set_style_text_color(title, lv_color_white(), 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 0);
    
    // Network list
    lv_obj_t* list = lv_obj_create(g_wifi_list_view);
    lv_obj_set_size(list, lv_pct(100), lv_pct(85));
    lv_obj_align(list, LV_ALIGN_TOP_MID, 0, 40);
    lv_obj_set_style_bg_opa(list, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(list, 0, 0);
    lv_obj_set_style_pad_all(list, 4, 0);
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_row(list, 8, 0);
    lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_OFF);
    
    // Mock WiFi networks
    const char* networks[] = {"Home-WiFi", "Office-5G", "Guest-Network"};
    const int rssi[] = {-45, -62, -78};
    
    for (int i = 0; i < 3; i++) {
        lv_obj_t* item = lv_btn_create(list);
        lv_obj_set_size(item, lv_pct(90), 40);
        lv_obj_set_style_bg_color(item, lv_color_hex(0x1E1E1E), 0);
        lv_obj_set_style_border_width(item, 0, 0);
        lv_obj_set_style_radius(item, 10, 0);
        lv_obj_set_style_shadow_width(item, 0, 0);
        
        char* ssid_copy = (char*)malloc(strlen(networks[i]) + 1);
        if (ssid_copy) {
            strcpy(ssid_copy, networks[i]);
            lv_obj_add_event_cb(item, wifi_network_clicked, LV_EVENT_CLICKED, ssid_copy);
        }
        
        lv_obj_t* ssid_lbl = lv_label_create(item);
        lv_label_set_text(ssid_lbl, networks[i]);
        lv_obj_set_style_text_color(ssid_lbl, lv_color_white(), 0);
        lv_obj_align(ssid_lbl, LV_ALIGN_LEFT_MID, 16, 0);
        lv_obj_add_flag(ssid_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
        
        // Signal strength bars
        int bars = (rssi[i] > -50) ? 4 : (rssi[i] > -60) ? 3 : (rssi[i] > -70) ? 2 : 1;
        for (int b = 0; b < 4; b++) {
            lv_obj_t* bar = lv_obj_create(item);
            lv_obj_set_size(bar, 5, 12);
            lv_obj_set_style_radius(bar, 1, 0);
            lv_obj_set_style_border_width(bar, 0, 0);
            if (b < bars) {
                lv_obj_set_style_bg_color(bar, lv_color_white(), 0);
                lv_obj_set_style_bg_opa(bar, LV_OPA_COVER, 0);
            } else {
                lv_obj_set_style_bg_color(bar, lv_color_hex(0x444444), 0);
                lv_obj_set_style_bg_opa(bar, LV_OPA_50, 0);
            }
            lv_obj_align(bar, LV_ALIGN_RIGHT_MID, -16 - (3 - b) * 7, 0);
            lv_obj_add_flag(bar, LV_OBJ_FLAG_EVENT_BUBBLE);
        }
    }
    
    // === PASSWORD VIEW ===
    g_password_view = lv_obj_create(g_wifi_screen);
    lv_obj_set_size(g_password_view, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_opa(g_password_view, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(g_password_view, 0, 0);
    lv_obj_set_style_pad_all(g_password_view, 0, 0);
    lv_obj_clear_flag(g_password_view, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(g_password_view, LV_OBJ_FLAG_HIDDEN);  // Initially hidden
    
    // SSID title (will be updated)
    lv_obj_t* ssid_title = lv_label_create(g_password_view);
    lv_label_set_text(ssid_title, "Network");
    lv_obj_set_style_text_color(ssid_title, lv_color_white(), 0);
    lv_obj_align(ssid_title, LV_ALIGN_TOP_MID, 0, 8);
    
    // Password textarea
    g_password_textarea = lv_textarea_create(g_password_view);
    lv_obj_set_size(g_password_textarea, lv_pct(90), 36);
    lv_obj_align(g_password_textarea, LV_ALIGN_TOP_MID, 0, 44);
    lv_textarea_set_one_line(g_password_textarea, true);
    lv_textarea_set_password_mode(g_password_textarea, true);
    lv_textarea_set_text(g_password_textarea, "");
    lv_textarea_set_placeholder_text(g_password_textarea, "Password");
    
    // Keyboard (QWERTY)
    lv_obj_t* kb = lv_keyboard_create(g_password_view);
    lv_obj_set_size(kb, lv_pct(100), 100);
    lv_obj_align(kb, LV_ALIGN_TOP_MID, 0, 88);
    lv_keyboard_set_textarea(kb, g_password_textarea);
    lv_keyboard_set_mode(kb, LV_KEYBOARD_MODE_TEXT_UPPER);
    
    // Connect button
    lv_obj_t* connect_btn = lv_btn_create(g_password_view);
    lv_obj_set_size(connect_btn, 130, 36);
    lv_obj_set_style_bg_color(connect_btn, lv_color_hex(0x1E88E5), 0);
    lv_obj_set_style_border_width(connect_btn, 0, 0);
    lv_obj_set_style_radius(connect_btn, 18, 0);
    lv_obj_align(connect_btn, LV_ALIGN_BOTTOM_LEFT, 8, -8);
    lv_obj_t* connect_lbl = lv_label_create(connect_btn);
    lv_label_set_text(connect_lbl, "Connect");
    lv_obj_set_style_text_color(connect_lbl, lv_color_white(), 0);
    lv_obj_center(connect_lbl);
    lv_obj_add_event_cb(connect_btn, password_connect_clicked, LV_EVENT_CLICKED, NULL);
    
    // Cancel button
    lv_obj_t* cancel_btn = lv_btn_create(g_password_view);
    lv_obj_set_size(cancel_btn, 130, 36);
    lv_obj_set_style_bg_color(cancel_btn, lv_color_hex(0x333333), 0);
    lv_obj_set_style_border_width(cancel_btn, 0, 0);
    lv_obj_set_style_radius(cancel_btn, 18, 0);
    lv_obj_align(cancel_btn, LV_ALIGN_BOTTOM_RIGHT, -8, -8);
    lv_obj_t* cancel_lbl = lv_label_create(cancel_btn);
    lv_label_set_text(cancel_lbl, "Cancel");
    lv_obj_set_style_text_color(cancel_lbl, lv_color_white(), 0);
    lv_obj_center(cancel_lbl);
    lv_obj_add_event_cb(cancel_btn, password_cancel_clicked, LV_EVENT_CLICKED, NULL);
    
    printf("WiFi screen created\n");
    fflush(stdout);
}

void wifi_ui_close(void) {
    if (g_wifi_screen) {
        lv_obj_add_flag(g_wifi_screen, LV_OBJ_FLAG_HIDDEN);
        show_list_view();  // Reset to list view
        printf("WiFi screen hidden\n");
    }
}

bool wifi_ui_is_open(void) {
    return g_wifi_screen && !lv_obj_has_flag(g_wifi_screen, LV_OBJ_FLAG_HIDDEN);
}
