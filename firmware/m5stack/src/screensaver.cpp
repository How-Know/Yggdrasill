#include "screensaver.h"
#include <Arduino.h>
#include <M5Unified.h>

// Forward declaration from ui_port
extern void ui_before_screen_change(void);

static uint32_t g_timeout_ms = 60000;
static uint32_t g_last_activity_ms = 0;
static lv_obj_t* g_saver_scr = NULL;
static lv_obj_t* g_prev_scr = NULL;
static lv_timer_t* g_close_timer = NULL;
static lv_timer_t* g_blink_timer = NULL;
static uint32_t g_blink_ms = 100;
static uint32_t g_blink_interval_ms = 5000;
static uint32_t g_blink_count = 0;
static bool g_is_yawning = false;
static lv_coord_t g_mouth_base_h = 7;
static uint32_t g_last_activity_log_ms = 0;

// Display sleep state
static bool g_display_sleeping = false;
static uint32_t g_display_sleep_delay_ms = 180000; // 3분
static uint32_t g_saver_entered_ms = 0;

static lv_obj_t* g_eye_l = NULL;
static lv_obj_t* g_eye_r = NULL;
static lv_obj_t* g_brow_l = NULL;
static lv_obj_t* g_brow_r = NULL;
static lv_obj_t* g_mouth = NULL;
static lv_coord_t g_eye_l_top_y = 0;
static lv_coord_t g_eye_r_top_y = 0;
static lv_coord_t g_eye_h = 20;
static lv_obj_t* g_lid_l = NULL;
static lv_obj_t* g_lid_r = NULL;
static lv_timer_t* g_blink_once_timer = NULL;
static lv_obj_t* g_face_container = NULL;

static void eyebrow_y_anim(void* obj, int32_t v) {
    lv_obj_set_style_translate_y((lv_obj_t*)obj, (lv_coord_t)v, 0);
}

static void eye_translate_x(void* obj, int32_t v) {
    lv_obj_set_style_translate_x((lv_obj_t*)obj, (lv_coord_t)v, 0);
}

static void eye_translate_y(void* obj, int32_t v) {
    lv_obj_set_style_translate_y((lv_obj_t*)obj, (lv_coord_t)v, 0);
}

static lv_coord_t g_mouth_base_x = 0;
static void mouth_width_centered(void* obj, int32_t w) {
    lv_obj_t* mouth = (lv_obj_t*)obj;
    lv_obj_set_width(mouth, (lv_coord_t)w);
    lv_obj_set_x(mouth, g_mouth_base_x + (130 - w) / 2);
}

static void close_timer_cb(lv_timer_t* t) {
    (void)t;
    if (g_close_timer) { lv_timer_del(g_close_timer); g_close_timer = NULL; }
    if (g_blink_timer) { lv_timer_del(g_blink_timer); g_blink_timer = NULL; }
    if (g_blink_once_timer) { lv_timer_del(g_blink_once_timer); g_blink_once_timer = NULL; }
    
    g_brow_l = NULL;
    g_brow_r = NULL;
    g_eye_l = NULL;
    g_eye_r = NULL;
    g_lid_l = NULL;
    g_lid_r = NULL;
    g_mouth = NULL;
    g_face_container = NULL;
    
    if (g_prev_scr) lv_scr_load(g_prev_scr);
    if (g_saver_scr) { lv_obj_del(g_saver_scr); g_saver_scr = NULL; }
    g_last_activity_ms = lv_tick_get();
}

static void surprised_reaction(lv_coord_t touch_x, lv_coord_t touch_y) {
    if (!g_brow_l || !g_brow_r || !g_eye_l || !g_eye_r || !g_mouth) return;
    
    lv_anim_del(g_face_container, NULL);
    lv_anim_del(g_brow_l, NULL);
    lv_anim_del(g_brow_r, NULL);
    lv_anim_del(g_eye_l, NULL);
    lv_anim_del(g_eye_r, NULL);
    lv_anim_del(g_mouth, NULL);
    
    lv_anim_t brow_l;
    lv_anim_init(&brow_l);
    lv_anim_set_var(&brow_l, g_brow_l);
    lv_anim_set_values(&brow_l, 0, -8);
    lv_anim_set_time(&brow_l, 200);
    lv_anim_set_playback_time(&brow_l, 300);
    lv_anim_set_exec_cb(&brow_l, eyebrow_y_anim);
    lv_anim_start(&brow_l);
    
    lv_anim_t brow_r;
    lv_anim_init(&brow_r);
    lv_anim_set_var(&brow_r, g_brow_r);
    lv_anim_set_values(&brow_r, 0, -8);
    lv_anim_set_time(&brow_r, 200);
    lv_anim_set_playback_time(&brow_r, 300);
    lv_anim_set_exec_cb(&brow_r, eyebrow_y_anim);
    lv_anim_start(&brow_r);
    
    lv_disp_t* disp = lv_disp_get_default();
    lv_coord_t cx = disp ? lv_disp_get_hor_res(disp) / 2 : 160;
    lv_coord_t cy = disp ? lv_disp_get_ver_res(disp) / 2 : 120;
    
    lv_coord_t dx = (touch_x - cx) / 10;
    lv_coord_t dy = (touch_y - cy) / 10;
    
    lv_anim_t eye_l_x;
    lv_anim_init(&eye_l_x);
    lv_anim_set_var(&eye_l_x, g_eye_l);
    lv_anim_set_values(&eye_l_x, 0, dx);
    lv_anim_set_time(&eye_l_x, 200);
    lv_anim_set_playback_time(&eye_l_x, 300);
    lv_anim_set_exec_cb(&eye_l_x, eye_translate_x);
    lv_anim_start(&eye_l_x);
    
    lv_anim_t eye_r_x;
    lv_anim_init(&eye_r_x);
    lv_anim_set_var(&eye_r_x, g_eye_r);
    lv_anim_set_values(&eye_r_x, 0, dx);
    lv_anim_set_time(&eye_r_x, 200);
    lv_anim_set_playback_time(&eye_r_x, 300);
    lv_anim_set_exec_cb(&eye_r_x, eye_translate_x);
    lv_anim_start(&eye_r_x);
    
    lv_anim_t eye_l_y;
    lv_anim_init(&eye_l_y);
    lv_anim_set_var(&eye_l_y, g_eye_l);
    lv_anim_set_values(&eye_l_y, 0, dy);
    lv_anim_set_time(&eye_l_y, 200);
    lv_anim_set_playback_time(&eye_l_y, 300);
    lv_anim_set_exec_cb(&eye_l_y, eye_translate_y);
    lv_anim_start(&eye_l_y);
    
    lv_anim_t eye_r_y;
    lv_anim_init(&eye_r_y);
    lv_anim_set_var(&eye_r_y, g_eye_r);
    lv_anim_set_values(&eye_r_y, 0, dy);
    lv_anim_set_time(&eye_r_y, 200);
    lv_anim_set_playback_time(&eye_r_y, 300);
    lv_anim_set_exec_cb(&eye_r_y, eye_translate_y);
    lv_anim_start(&eye_r_y);
    
    g_mouth_base_x = cx - 65;
    
    lv_anim_t mouth_w;
    lv_anim_init(&mouth_w);
    lv_anim_set_var(&mouth_w, g_mouth);
    lv_anim_set_values(&mouth_w, 130, 90);
    lv_anim_set_time(&mouth_w, 200);
    lv_anim_set_playback_time(&mouth_w, 300);
    lv_anim_set_exec_cb(&mouth_w, mouth_width_centered);
    lv_anim_start(&mouth_w);
    
    lv_anim_t mouth_h;
    lv_anim_init(&mouth_h);
    lv_anim_set_var(&mouth_h, g_mouth);
    lv_anim_set_values(&mouth_h, 7, 12);
    lv_anim_set_time(&mouth_h, 200);
    lv_anim_set_playback_time(&mouth_h, 300);
    lv_anim_set_exec_cb(&mouth_h, (lv_anim_exec_xcb_t)lv_obj_set_height);
    lv_anim_start(&mouth_h);
}

static void any_activity_event_cb(lv_event_t* e) {
    lv_event_code_t code = lv_event_get_code(e);
    // 사용자 입력성 이벤트만 포착
    if (!(code == LV_EVENT_PRESSED || code == LV_EVENT_RELEASED || code == LV_EVENT_CLICKED ||
          code == LV_EVENT_SHORT_CLICKED || code == LV_EVENT_LONG_PRESSED || code == LV_EVENT_LONG_PRESSED_REPEAT ||
          code == LV_EVENT_KEY || code == LV_EVENT_SCROLL || code == LV_EVENT_SCROLL_BEGIN ||
          code == LV_EVENT_SCROLL_END || code == LV_EVENT_GESTURE)) {
        return;
    }

    g_last_activity_ms = lv_tick_get();
    if (g_last_activity_ms - g_last_activity_log_ms >= 1000) {
        Serial.printf("[SCREENSAVER] Activity event @ %lu ms\n", g_last_activity_ms);
        g_last_activity_log_ms = g_last_activity_ms;
    }

    if (g_saver_scr && lv_event_get_current_target(e) == g_saver_scr) {
        if (code == LV_EVENT_PRESSED || code == LV_EVENT_CLICKED) {
            lv_indev_t* indev = lv_indev_get_act();
            lv_point_t point;
            if (indev) {
                lv_indev_get_point(indev, &point);
                surprised_reaction(point.x, point.y);
            }
            if (g_close_timer) { lv_timer_del(g_close_timer); g_close_timer = NULL; }
            g_close_timer = lv_timer_create(close_timer_cb, 1000, NULL);
            lv_timer_set_repeat_count(g_close_timer, 1);
        }
    }
}

static void eye_radius_anim(void* obj, int32_t v) {
    lv_obj_set_style_radius((lv_obj_t*)obj, (lv_coord_t)v, 0);
}

static void breathing_anim(void* obj, int32_t v) {
    lv_obj_set_style_translate_y((lv_obj_t*)obj, (lv_coord_t)v, 0);
}

static void start_breathing(void) {
    if (!g_face_container) return;
    
    lv_anim_t breath;
    lv_anim_init(&breath);
    lv_anim_set_var(&breath, g_face_container);
    lv_anim_set_values(&breath, 0, 10);
    lv_anim_set_time(&breath, 3000);
    lv_anim_set_playback_time(&breath, 3000);
    lv_anim_set_repeat_count(&breath, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&breath, lv_anim_path_ease_in_out);
    lv_anim_set_exec_cb(&breath, breathing_anim);
    lv_anim_start(&breath);
}

static void eyebrow_raise(void) {
    if (!g_brow_l || !g_brow_r) return;
    
    lv_anim_t a1;
    lv_anim_init(&a1);
    lv_anim_set_var(&a1, g_brow_l);
    lv_anim_set_values(&a1, 0, -6);
    lv_anim_set_time(&a1, 150);
    lv_anim_set_playback_time(&a1, 150);
    lv_anim_set_exec_cb(&a1, eyebrow_y_anim);
    lv_anim_start(&a1);

    lv_anim_t a2;
    lv_anim_init(&a2);
    lv_anim_set_var(&a2, g_brow_r);
    lv_anim_set_values(&a2, 0, -6);
    lv_anim_set_time(&a2, 150);
    lv_anim_set_playback_time(&a2, 150);
    lv_anim_set_exec_cb(&a2, eyebrow_y_anim);
    lv_anim_start(&a2);
}

static void mouth_yawn_anim(void* obj, int32_t v) {
    lv_obj_t* mouth = (lv_obj_t*)obj;
    lv_coord_t h = (lv_coord_t)v;
    lv_obj_set_height(mouth, h);
    // 너비는 높이가 증가할수록 감소 (130 -> 100)
    lv_coord_t w = 130 - ((h - g_mouth_base_h) * 30 / (38 - g_mouth_base_h));
    lv_obj_set_width(mouth, w);
    lv_obj_set_x(mouth, g_mouth_base_x + (130 - w) / 2);
}

static void yawn_sequence(void) {
    if (!g_mouth || !g_eye_l || !g_eye_r || !g_brow_l || !g_brow_r) return;
    
    lv_anim_t mouth_anim;
    lv_anim_init(&mouth_anim);
    lv_anim_set_var(&mouth_anim, g_mouth);
    lv_anim_set_values(&mouth_anim, g_mouth_base_h, 38);
    lv_anim_set_time(&mouth_anim, 800);
    lv_anim_set_playback_time(&mouth_anim, 800);
    lv_anim_set_exec_cb(&mouth_anim, mouth_yawn_anim);
    lv_anim_start(&mouth_anim);
    
    lv_anim_t brow_l_anim;
    lv_anim_init(&brow_l_anim);
    lv_anim_set_var(&brow_l_anim, g_brow_l);
    lv_anim_set_values(&brow_l_anim, 0, -6);
    lv_anim_set_time(&brow_l_anim, 800);
    lv_anim_set_playback_time(&brow_l_anim, 800);
    lv_anim_set_exec_cb(&brow_l_anim, eyebrow_y_anim);
    lv_anim_start(&brow_l_anim);
    
    lv_anim_t brow_r_anim;
    lv_anim_init(&brow_r_anim);
    lv_anim_set_var(&brow_r_anim, g_brow_r);
    lv_anim_set_values(&brow_r_anim, 0, -6);
    lv_anim_set_time(&brow_r_anim, 800);
    lv_anim_set_playback_time(&brow_r_anim, 800);
    lv_anim_set_exec_cb(&brow_r_anim, eyebrow_y_anim);
    lv_anim_start(&brow_r_anim);
    
    lv_anim_t eye_l_h_anim;
    lv_anim_init(&eye_l_h_anim);
    lv_anim_set_var(&eye_l_h_anim, g_eye_l);
    lv_anim_set_values(&eye_l_h_anim, 18, 6);
    lv_anim_set_time(&eye_l_h_anim, 800);
    lv_anim_set_playback_time(&eye_l_h_anim, 800);
    lv_anim_set_exec_cb(&eye_l_h_anim, (lv_anim_exec_xcb_t)lv_obj_set_height);
    lv_anim_start(&eye_l_h_anim);
    
    lv_anim_t eye_l_r_anim;
    lv_anim_init(&eye_l_r_anim);
    lv_anim_set_var(&eye_l_r_anim, g_eye_l);
    lv_anim_set_values(&eye_l_r_anim, LV_RADIUS_CIRCLE, 3);
    lv_anim_set_time(&eye_l_r_anim, 800);
    lv_anim_set_playback_time(&eye_l_r_anim, 800);
    lv_anim_set_exec_cb(&eye_l_r_anim, eye_radius_anim);
    lv_anim_start(&eye_l_r_anim);
    
    lv_anim_t eye_r_h_anim;
    lv_anim_init(&eye_r_h_anim);
    lv_anim_set_var(&eye_r_h_anim, g_eye_r);
    lv_anim_set_values(&eye_r_h_anim, 18, 6);
    lv_anim_set_time(&eye_r_h_anim, 800);
    lv_anim_set_playback_time(&eye_r_h_anim, 800);
    lv_anim_set_exec_cb(&eye_r_h_anim, (lv_anim_exec_xcb_t)lv_obj_set_height);
    lv_anim_start(&eye_r_h_anim);
    
    lv_anim_t eye_r_r_anim;
    lv_anim_init(&eye_r_r_anim);
    lv_anim_set_var(&eye_r_r_anim, g_eye_r);
    lv_anim_set_values(&eye_r_r_anim, LV_RADIUS_CIRCLE, 3);
    lv_anim_set_time(&eye_r_r_anim, 800);
    lv_anim_set_playback_time(&eye_r_r_anim, 800);
    lv_anim_set_exec_cb(&eye_r_r_anim, eye_radius_anim);
    lv_anim_start(&eye_r_r_anim);
}

static void resume_blinking(lv_timer_t* t) {
    (void)t;
    g_is_yawning = false;
    g_blink_count = 0;
}

static void blink_once(void) {
    if (!g_lid_l || !g_lid_r) return;
    if (g_is_yawning) return;
    
    g_blink_count++;
    
    if (g_blink_count >= 8) {
        g_is_yawning = true;
        yawn_sequence();
        lv_timer_t* resume_timer = lv_timer_create(resume_blinking, 1700, NULL);
        lv_timer_set_repeat_count(resume_timer, 1);
        return;
    }
    
    if (g_blink_count % 2 == 0) {
        eyebrow_raise();
    }
    
    lv_anim_t a1;
    lv_anim_init(&a1);
    lv_anim_set_var(&a1, g_lid_l);
    lv_anim_set_values(&a1, 0, g_eye_h);
    lv_anim_set_time(&a1, g_blink_ms / 2);
    lv_anim_set_playback_time(&a1, g_blink_ms / 2);
    lv_anim_set_exec_cb(&a1, (lv_anim_exec_xcb_t)lv_obj_set_height);
    lv_anim_start(&a1);

    lv_anim_t a2;
    lv_anim_init(&a2);
    lv_anim_set_var(&a2, g_lid_r);
    lv_anim_set_values(&a2, 0, g_eye_h);
    lv_anim_set_time(&a2, g_blink_ms / 2);
    lv_anim_set_playback_time(&a2, g_blink_ms / 2);
    lv_anim_set_exec_cb(&a2, (lv_anim_exec_xcb_t)lv_obj_set_height);
    lv_anim_start(&a2);
}

static void blink_once_timer_cb(lv_timer_t* t) {
    (void)t;
    if (g_blink_once_timer) { lv_timer_del(g_blink_once_timer); g_blink_once_timer = NULL; }
    blink_once();
}

static void blink_timer_cb(lv_timer_t* t) {
    (void)t;
    blink_once();
}

static void show_screensaver(void) {
    if (g_saver_scr) return;
    ui_before_screen_change();
    lv_disp_t* disp = lv_disp_get_default();
    lv_coord_t sw = disp ? lv_disp_get_hor_res(disp) : 320;
    lv_coord_t sh = disp ? lv_disp_get_ver_res(disp) : 240;

    g_prev_scr = lv_scr_act();
    g_saver_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(g_saver_scr, lv_color_hex(0x000000), 0);
    lv_obj_set_style_bg_opa(g_saver_scr, LV_OPA_COVER, 0);
    lv_obj_clear_flag(g_saver_scr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(g_saver_scr, LV_SCROLLBAR_MODE_OFF);
    lv_scr_load(g_saver_scr);

    lv_coord_t cx = sw / 2;
    lv_coord_t cy = sh / 2;
    
    g_face_container = lv_obj_create(g_saver_scr);
    lv_obj_set_size(g_face_container, sw, sh);
    lv_obj_set_pos(g_face_container, 0, 0);
    lv_obj_set_style_bg_opa(g_face_container, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(g_face_container, 0, 0);
    lv_obj_set_style_pad_all(g_face_container, 0, 0);
    lv_obj_clear_flag(g_face_container, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(g_face_container, LV_SCROLLBAR_MODE_OFF);
    lv_obj_add_flag(g_face_container, LV_OBJ_FLAG_OVERFLOW_VISIBLE);
    lv_obj_add_flag(g_face_container, LV_OBJ_FLAG_EVENT_BUBBLE);

    g_brow_l = lv_obj_create(g_face_container);
    lv_obj_set_size(g_brow_l, 18, 4);
    lv_obj_set_style_radius(g_brow_l, 2, 0);
    lv_obj_set_style_bg_color(g_brow_l, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(g_brow_l, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(g_brow_l, 0, 0);
    lv_obj_set_style_border_width(g_brow_l, 0, 0);
    lv_obj_set_pos(g_brow_l, cx - 70 - 9, cy - 36 - 2 + 3);

    g_brow_r = lv_obj_create(g_face_container);
    lv_obj_set_size(g_brow_r, 18, 4);
    lv_obj_set_style_radius(g_brow_r, 2, 0);
    lv_obj_set_style_bg_color(g_brow_r, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(g_brow_r, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(g_brow_r, 0, 0);
    lv_obj_set_style_border_width(g_brow_r, 0, 0);
    lv_obj_set_pos(g_brow_r, cx + 70 - 9, cy - 36 - 2 + 3);

    lv_coord_t eye_l_x = cx - 70 - 9;
    lv_coord_t eye_l_y = cy - 10 - 9;
    lv_coord_t eye_r_x = cx + 70 - 9;
    lv_coord_t eye_r_y = cy - 10 - 9;
    
    g_eye_l = lv_obj_create(g_face_container);
    lv_obj_set_size(g_eye_l, 18, 18);
    lv_obj_set_style_radius(g_eye_l, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(g_eye_l, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(g_eye_l, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(g_eye_l, 0, 0);
    lv_obj_set_style_border_width(g_eye_l, 0, 0);
    lv_obj_set_scrollbar_mode(g_eye_l, LV_SCROLLBAR_MODE_OFF);
    lv_obj_clear_flag(g_eye_l, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(g_eye_l, eye_l_x, eye_l_y);

    g_eye_r = lv_obj_create(g_face_container);
    lv_obj_set_size(g_eye_r, 18, 18);
    lv_obj_set_style_radius(g_eye_r, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(g_eye_r, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(g_eye_r, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(g_eye_r, 0, 0);
    lv_obj_set_style_border_width(g_eye_r, 0, 0);
    lv_obj_set_scrollbar_mode(g_eye_r, LV_SCROLLBAR_MODE_OFF);
    lv_obj_clear_flag(g_eye_r, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(g_eye_r, eye_r_x, eye_r_y);
    
    g_eye_l_top_y = eye_l_y;
    g_eye_r_top_y = eye_r_y;
    g_eye_h = 18;

    g_lid_l = lv_obj_create(g_face_container);
    lv_obj_set_size(g_lid_l, 18, 0);
    lv_obj_set_style_radius(g_lid_l, 0, 0);
    lv_obj_set_style_bg_color(g_lid_l, lv_color_hex(0x000000), 0);
    lv_obj_set_style_bg_opa(g_lid_l, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(g_lid_l, 0, 0);
    lv_obj_set_style_border_width(g_lid_l, 0, 0);
    lv_obj_set_scrollbar_mode(g_lid_l, LV_SCROLLBAR_MODE_OFF);
    lv_obj_clear_flag(g_lid_l, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(g_lid_l, eye_l_x, eye_l_y);

    g_lid_r = lv_obj_create(g_face_container);
    lv_obj_set_size(g_lid_r, 18, 0);
    lv_obj_set_style_radius(g_lid_r, 0, 0);
    lv_obj_set_style_bg_color(g_lid_r, lv_color_hex(0x000000), 0);
    lv_obj_set_style_bg_opa(g_lid_r, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(g_lid_r, 0, 0);
    lv_obj_set_style_border_width(g_lid_r, 0, 0);
    lv_obj_set_scrollbar_mode(g_lid_r, LV_SCROLLBAR_MODE_OFF);
    lv_obj_clear_flag(g_lid_r, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(g_lid_r, eye_r_x, eye_r_y);

    g_mouth = lv_obj_create(g_face_container);
    lv_obj_set_size(g_mouth, 130, 7);
    lv_obj_set_style_radius(g_mouth, 3, 0);
    lv_obj_set_style_bg_color(g_mouth, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(g_mouth, LV_OPA_COVER, 0);
    lv_obj_set_pos(g_mouth, cx - 65, cy + 29 - 9);
    g_mouth_base_x = cx - 65;

    lv_obj_add_event_cb(g_saver_scr, any_activity_event_cb, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(g_saver_scr, any_activity_event_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_add_event_cb(g_saver_scr, any_activity_event_cb, LV_EVENT_KEY, NULL);
    lv_obj_add_event_cb(g_saver_scr, any_activity_event_cb, LV_EVENT_SCROLL, NULL);

    if (g_blink_timer) { lv_timer_del(g_blink_timer); g_blink_timer = NULL; }
    g_blink_timer = lv_timer_create(blink_timer_cb, g_blink_interval_ms, NULL);
    lv_timer_set_repeat_count(g_blink_timer, -1);
    if (g_blink_once_timer) { lv_timer_del(g_blink_once_timer); g_blink_once_timer = NULL; }
    g_blink_once_timer = lv_timer_create(blink_once_timer_cb, 300, NULL);
    lv_timer_set_repeat_count(g_blink_once_timer, 1);
    
    start_breathing();
}

// 자는 표정으로 변경 (눈썹 없음, 눈 ㅡ 모양, 입 ㄱ 모양, 숨쉬기 3배)
static void set_sleeping_face(void) {
    if (!g_brow_l || !g_brow_r || !g_eye_l || !g_eye_r || !g_mouth) return;
    
    Serial.println("[SCREENSAVER] Setting sleeping face");
    
    // Clear animations
    lv_anim_del(g_face_container, NULL);
    lv_anim_del(g_brow_l, NULL);
    lv_anim_del(g_brow_r, NULL);
    lv_anim_del(g_eye_l, NULL);
    lv_anim_del(g_eye_r, NULL);
    lv_anim_del(g_mouth, NULL);
    
    // 눈썹 숨김 (투명하게)
    lv_obj_set_style_opa(g_brow_l, LV_OPA_TRANSP, 0);
    lv_obj_set_style_opa(g_brow_r, LV_OPA_TRANSP, 0);
    
    // 눈 ㅡ 모양 (높이 2, 너비 20)
    lv_obj_set_width(g_eye_l, 20);
    lv_obj_set_height(g_eye_l, 2);
    lv_obj_set_style_radius(g_eye_l, 0, 0);
    lv_obj_set_width(g_eye_r, 20);
    lv_obj_set_height(g_eye_r, 2);
    lv_obj_set_style_radius(g_eye_r, 0, 0);
    
    // 입 ㄱ 모양 (침흘리는 모양: L자 형태)
    // 세로 직사각형으로 표현
    lv_obj_set_width(g_mouth, 3);
    lv_obj_set_height(g_mouth, 15);
    lv_obj_set_style_radius(g_mouth, 0, 0);
    lv_obj_set_x(g_mouth, g_mouth_base_x + 130 - 10); // 오른쪽 끝
    
    // 숨쉬기 효과 3배 (0~30으로 증가)
    lv_anim_t breath;
    lv_anim_init(&breath);
    lv_anim_set_var(&breath, g_face_container);
    lv_anim_set_values(&breath, 0, 30);
    lv_anim_set_time(&breath, 3000);
    lv_anim_set_playback_time(&breath, 3000);
    lv_anim_set_repeat_count(&breath, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&breath, lv_anim_path_ease_in_out);
    lv_anim_set_exec_cb(&breath, breathing_anim);
    lv_anim_start(&breath);
    
    lv_obj_invalidate(g_face_container);
}

// 깨는 애니메이션 (자는 표정 → 놀람 → 정상 표정)
static void wake_up_sequence(void) {
    if (!g_brow_l || !g_brow_r || !g_eye_l || !g_eye_r || !g_mouth) {
        Serial.println("[SCREENSAVER] wake_up_sequence: face elements NULL!");
        return;
    }
    
    Serial.println("[SCREENSAVER] Starting wake up animation");
    
    // 눈썹 나타나며 빠르게 위로 올라갔다가 정상 위치로 (0.5초 up, 0.5초 down)
    lv_obj_set_style_opa(g_brow_l, LV_OPA_COVER, 0);
    lv_obj_set_style_opa(g_brow_r, LV_OPA_COVER, 0);
    
    lv_anim_t brow_l;
    lv_anim_init(&brow_l);
    lv_anim_set_var(&brow_l, g_brow_l);
    lv_anim_set_exec_cb(&brow_l, eyebrow_y_anim);
    lv_anim_set_values(&brow_l, 0, -12);
    lv_anim_set_time(&brow_l, 500);
    lv_anim_set_playback_time(&brow_l, 500);
    lv_anim_set_path_cb(&brow_l, lv_anim_path_ease_out);
    lv_anim_start(&brow_l);
    
    lv_anim_t brow_r;
    lv_anim_init(&brow_r);
    lv_anim_set_var(&brow_r, g_brow_r);
    lv_anim_set_exec_cb(&brow_r, eyebrow_y_anim);
    lv_anim_set_values(&brow_r, 0, -12);
    lv_anim_set_time(&brow_r, 500);
    lv_anim_set_playback_time(&brow_r, 500);
    lv_anim_set_path_cb(&brow_r, lv_anim_path_ease_out);
    lv_anim_start(&brow_r);
    
    // 눈 큰 원(24x24)에서 정상 크기(18x18)로 (0.5초 + 0.5초)
    lv_anim_t eye_l_w;
    lv_anim_init(&eye_l_w);
    lv_anim_set_var(&eye_l_w, g_eye_l);
    lv_anim_set_exec_cb(&eye_l_w, (lv_anim_exec_xcb_t)lv_obj_set_width);
    lv_anim_set_values(&eye_l_w, 20, 24);
    lv_anim_set_time(&eye_l_w, 500);
    lv_anim_set_playback_time(&eye_l_w, 500);
    lv_anim_set_path_cb(&eye_l_w, lv_anim_path_ease_out);
    lv_anim_start(&eye_l_w);
    
    lv_anim_t eye_l_h;
    lv_anim_init(&eye_l_h);
    lv_anim_set_var(&eye_l_h, g_eye_l);
    lv_anim_set_exec_cb(&eye_l_h, (lv_anim_exec_xcb_t)lv_obj_set_height);
    lv_anim_set_values(&eye_l_h, 2, 24);
    lv_anim_set_time(&eye_l_h, 500);
    lv_anim_set_playback_time(&eye_l_h, 500);
    lv_anim_set_path_cb(&eye_l_h, lv_anim_path_ease_out);
    lv_anim_start(&eye_l_h);
    
    lv_anim_t eye_l_r;
    lv_anim_init(&eye_l_r);
    lv_anim_set_var(&eye_l_r, g_eye_l);
    lv_anim_set_exec_cb(&eye_l_r, eye_radius_anim);
    lv_anim_set_values(&eye_l_r, 0, LV_RADIUS_CIRCLE);
    lv_anim_set_time(&eye_l_r, 500);
    lv_anim_set_playback_time(&eye_l_r, 500);
    lv_anim_set_path_cb(&eye_l_r, lv_anim_path_ease_out);
    lv_anim_start(&eye_l_r);
    
    lv_anim_t eye_r_w;
    lv_anim_init(&eye_r_w);
    lv_anim_set_var(&eye_r_w, g_eye_r);
    lv_anim_set_exec_cb(&eye_r_w, (lv_anim_exec_xcb_t)lv_obj_set_width);
    lv_anim_set_values(&eye_r_w, 20, 24);
    lv_anim_set_time(&eye_r_w, 500);
    lv_anim_set_playback_time(&eye_r_w, 500);
    lv_anim_set_path_cb(&eye_r_w, lv_anim_path_ease_out);
    lv_anim_start(&eye_r_w);
    
    lv_anim_t eye_r_h;
    lv_anim_init(&eye_r_h);
    lv_anim_set_var(&eye_r_h, g_eye_r);
    lv_anim_set_exec_cb(&eye_r_h, (lv_anim_exec_xcb_t)lv_obj_set_height);
    lv_anim_set_values(&eye_r_h, 2, 24);
    lv_anim_set_time(&eye_r_h, 500);
    lv_anim_set_playback_time(&eye_r_h, 500);
    lv_anim_set_path_cb(&eye_r_h, lv_anim_path_ease_out);
    lv_anim_start(&eye_r_h);
    
    lv_anim_t eye_r_r;
    lv_anim_init(&eye_r_r);
    lv_anim_set_var(&eye_r_r, g_eye_r);
    lv_anim_set_exec_cb(&eye_r_r, eye_radius_anim);
    lv_anim_set_values(&eye_r_r, 0, LV_RADIUS_CIRCLE);
    lv_anim_set_time(&eye_r_r, 500);
    lv_anim_set_playback_time(&eye_r_r, 500);
    lv_anim_set_path_cb(&eye_r_r, lv_anim_path_ease_out);
    lv_anim_start(&eye_r_r);
    
    // 입 빠르게 세로 직사각형(10x30)으로 변했다가 정상(130x7)으로 (0.5초 + 0.5초)
    lv_anim_t mouth_w;
    lv_anim_init(&mouth_w);
    lv_anim_set_var(&mouth_w, g_mouth);
    lv_anim_set_exec_cb(&mouth_w, mouth_width_centered);
    lv_anim_set_values(&mouth_w, 3, 10);
    lv_anim_set_time(&mouth_w, 500);
    lv_anim_set_playback_time(&mouth_w, 500);
    lv_anim_set_path_cb(&mouth_w, lv_anim_path_ease_out);
    lv_anim_start(&mouth_w);
    
    lv_anim_t mouth_h;
    lv_anim_init(&mouth_h);
    lv_anim_set_var(&mouth_h, g_mouth);
    lv_anim_set_exec_cb(&mouth_h, (lv_anim_exec_xcb_t)lv_obj_set_height);
    lv_anim_set_values(&mouth_h, 15, 30);
    lv_anim_set_time(&mouth_h, 500);
    lv_anim_set_playback_time(&mouth_h, 500);
    lv_anim_set_path_cb(&mouth_h, lv_anim_path_ease_out);
    lv_anim_start(&mouth_h);
    
    lv_anim_t mouth_r;
    lv_anim_init(&mouth_r);
    lv_anim_set_var(&mouth_r, g_mouth);
    lv_anim_set_exec_cb(&mouth_r, (lv_anim_exec_xcb_t)lv_obj_set_style_radius);
    lv_anim_set_values(&mouth_r, 0, 3);
    lv_anim_set_time(&mouth_r, 500);
    lv_anim_set_playback_time(&mouth_r, 500);
    lv_anim_set_path_cb(&mouth_r, lv_anim_path_ease_out);
    lv_anim_start(&mouth_r);
    
    Serial.println("[SCREENSAVER] Wake up animation started!");
}

void screensaver_init(uint32_t timeout_ms) {
    g_timeout_ms = timeout_ms;
    g_last_activity_ms = lv_tick_get();
    Serial.printf("[SCREENSAVER] init timeout=%lu, last=%lu\n", g_timeout_ms, g_last_activity_ms);
}

void screensaver_attach_activity(lv_obj_t* root) {
    if (!root) return;
    
    // 중복 부착 방지: 최대 10개 객체 추적
    static lv_obj_t* attached_objs[10] = {NULL};
    for (int i = 0; i < 10; i++) {
        if (attached_objs[i] == root) return; // 이미 부착됨
        if (attached_objs[i] == NULL) {
            attached_objs[i] = root; // 새로 추가
            break;
        }
    }
    // 버블 보장
    lv_obj_add_flag(root, LV_OBJ_FLAG_EVENT_BUBBLE);
    // 필요한 이벤트만 등록
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_RELEASED, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_SHORT_CLICKED, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_LONG_PRESSED, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_LONG_PRESSED_REPEAT, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_KEY, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_SCROLL, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_SCROLL_BEGIN, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_SCROLL_END, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_GESTURE, NULL);

    // 상위 레이어에도 부착
    lv_obj_t* top = lv_layer_top();
    if (top) {
        lv_obj_add_flag(top, LV_OBJ_FLAG_EVENT_BUBBLE);
        lv_obj_add_event_cb(top, any_activity_event_cb, LV_EVENT_PRESSED, NULL);
        lv_obj_add_event_cb(top, any_activity_event_cb, LV_EVENT_RELEASED, NULL);
        lv_obj_add_event_cb(top, any_activity_event_cb, LV_EVENT_CLICKED, NULL);
        lv_obj_add_event_cb(top, any_activity_event_cb, LV_EVENT_KEY, NULL);
        lv_obj_add_event_cb(top, any_activity_event_cb, LV_EVENT_GESTURE, NULL);
    }
    lv_obj_t* sys = lv_layer_sys();
    if (sys) {
        lv_obj_add_flag(sys, LV_OBJ_FLAG_EVENT_BUBBLE);
        lv_obj_add_event_cb(sys, any_activity_event_cb, LV_EVENT_PRESSED, NULL);
        lv_obj_add_event_cb(sys, any_activity_event_cb, LV_EVENT_RELEASED, NULL);
        lv_obj_add_event_cb(sys, any_activity_event_cb, LV_EVENT_CLICKED, NULL);
        lv_obj_add_event_cb(sys, any_activity_event_cb, LV_EVENT_KEY, NULL);
        lv_obj_add_event_cb(sys, any_activity_event_cb, LV_EVENT_GESTURE, NULL);
    }
    Serial.printf("[SCREENSAVER] activity hooks attached to root=%p/top/sys\n", root);
}

void screensaver_poll(void) {
    uint32_t now = lv_tick_get();
    if (!g_saver_scr && now - g_last_activity_ms > g_timeout_ms) {
        Serial.printf("[SCREENSAVER] Timeout reached. now=%lu, last=%lu, delta=%lu, threshold=%lu\n", 
                      now, g_last_activity_ms, now - g_last_activity_ms, g_timeout_ms);
        show_screensaver();
        g_saver_entered_ms = now;
        g_display_sleeping = false;
    }
    
    // Display sleep after screensaver timeout
    if (g_saver_scr && !g_display_sleeping && (now - g_saver_entered_ms > g_display_sleep_delay_ms)) {
        Serial.println("[SCREENSAVER] Display sleep");
        
        M5.Display.sleep();
        g_display_sleeping = true;
        
        // Stop timers to save power
        if (g_blink_timer) { lv_timer_pause(g_blink_timer); }
        if (g_blink_once_timer) { lv_timer_pause(g_blink_once_timer); }
    }
}

void screensaver_check_shake(void) {
    if (!g_display_sleeping) return;
    
    M5.Imu.update();
    float ax, ay, az;
    M5.Imu.getAccel(&ax, &ay, &az);
    float accel_magnitude = sqrt(ax * ax + ay * ay + az * az);
    
    // Shake detection: magnitude > 1.5g (adjust threshold as needed)
    if (accel_magnitude > 1.5f) {
        Serial.printf("[SCREENSAVER] Shake detected! accel=%.2f - returning to main screen\n", accel_magnitude);
        
        // Wake display
        M5.Display.wakeup();
        M5.Display.setBrightness(128);
        g_display_sleeping = false;
        
        // Close the screensaver immediately and return to main screen
        Serial.println("[SCREENSAVER] Closing screensaver");
        if (g_close_timer) { lv_timer_del(g_close_timer); g_close_timer = NULL; }
        if (g_blink_timer) { lv_timer_del(g_blink_timer); g_blink_timer = NULL; }
        if (g_blink_once_timer) { lv_timer_del(g_blink_once_timer); g_blink_once_timer = NULL; }
        
        g_brow_l = NULL;
        g_brow_r = NULL;
        g_eye_l = NULL;
        g_eye_r = NULL;
        g_lid_l = NULL;
        g_lid_r = NULL;
        g_mouth = NULL;
        g_face_container = NULL;
        
        if (g_prev_scr) lv_scr_load(g_prev_scr);
        if (g_saver_scr) { lv_obj_del(g_saver_scr); g_saver_scr = NULL; }
        g_last_activity_ms = lv_tick_get();
    }
}

void screensaver_blink_set(uint32_t blink_ms, uint32_t interval_ms) {
    g_blink_ms = blink_ms;
    g_blink_interval_ms = interval_ms;
}

