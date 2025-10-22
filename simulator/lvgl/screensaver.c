#include "screensaver.h"
#include <time.h>

// From main.c – allow UI to cleanup transient overlays before screen switch
void ui_before_screen_change(void);

static uint32_t g_timeout_ms = 5000;
static uint32_t g_last_activity_ms = 0;
static lv_obj_t* g_saver_scr = NULL;
static lv_obj_t* g_prev_scr = NULL;
static lv_timer_t* g_close_timer = NULL;
static lv_timer_t* g_blink_timer = NULL;
static uint32_t g_blink_ms = 100;  // 50ms down + 50ms up = 100ms total
static uint32_t g_blink_interval_ms = 5000;  // 5 seconds between blinks
static uint32_t g_blink_count = 0;  // Counter for eyebrow animation timing
static bool g_is_yawning = false;  // Flag to pause regular blink during yawn
static lv_coord_t g_mouth_base_h = 7;  // Original mouth height

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
static lv_obj_t* g_face_container = NULL;  // Container for breathing effect

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
    // Recenter: base_x + (130 - w) / 2
    lv_obj_set_x(mouth, g_mouth_base_x + (130 - w) / 2);
}

static void close_timer_cb(lv_timer_t* t) {
    (void)t;
    if (g_close_timer) { lv_timer_del(g_close_timer); g_close_timer = NULL; }
    if (g_blink_timer) { lv_timer_del(g_blink_timer); g_blink_timer = NULL; }
    if (g_blink_once_timer) { lv_timer_del(g_blink_once_timer); g_blink_once_timer = NULL; }
    
    // Clear all object references before deleting
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
    
    // Stop all animations
    lv_anim_del(g_face_container, NULL);
    lv_anim_del(g_brow_l, NULL);
    lv_anim_del(g_brow_r, NULL);
    lv_anim_del(g_eye_l, NULL);
    lv_anim_del(g_eye_r, NULL);
    lv_anim_del(g_mouth, NULL);
    
    // (1) Eyebrows: bounce up
    lv_anim_t brow_l;
    lv_anim_init(&brow_l);
    lv_anim_set_var(&brow_l, g_brow_l);
    lv_anim_set_values(&brow_l, 0, -8);  // Up 8px
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
    
    // (2) Eyes: bounce toward touch direction
    lv_display_t* disp = lv_disp_get_default();
    lv_coord_t cx = disp ? lv_display_get_horizontal_resolution(disp) / 2 : 160;
    lv_coord_t cy = disp ? lv_display_get_vertical_resolution(disp) / 2 : 120;
    
    lv_coord_t dx = (touch_x - cx) / 10;  // Direction scaled
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
    
    // Eyes Y direction
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
    
    // (3) Mouth: width shrink + height bounce (centered)
    g_mouth_base_x = cx - 65;  // Base position (130px width centered)
    
    lv_anim_t mouth_w;
    lv_anim_init(&mouth_w);
    lv_anim_set_var(&mouth_w, g_mouth);
    lv_anim_set_values(&mouth_w, 130, 90);  // Shrink width
    lv_anim_set_time(&mouth_w, 200);
    lv_anim_set_playback_time(&mouth_w, 300);
    lv_anim_set_exec_cb(&mouth_w, mouth_width_centered);
    lv_anim_start(&mouth_w);
    
    lv_anim_t mouth_h;
    lv_anim_init(&mouth_h);
    lv_anim_set_var(&mouth_h, g_mouth);
    lv_anim_set_values(&mouth_h, 7, 12);  // Height bounce
    lv_anim_set_time(&mouth_h, 200);
    lv_anim_set_playback_time(&mouth_h, 300);
    lv_anim_set_exec_cb(&mouth_h, (lv_anim_exec_xcb_t)lv_obj_set_height);
    lv_anim_start(&mouth_h);
}

static void any_activity_event_cb(lv_event_t* e) {
    g_last_activity_ms = lv_tick_get();
    // if tapping inside saver, schedule close after 1s
    if (g_saver_scr && lv_event_get_current_target(e) == g_saver_scr) {
        lv_event_code_t code = lv_event_get_code(e);
        if (code == LV_EVENT_PRESSED || code == LV_EVENT_CLICKED) {
            // Get touch position
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
    
    // Breathing: 0 -> 5px down -> 0 (6 seconds cycle)
    lv_anim_t breath;
    lv_anim_init(&breath);
    lv_anim_set_var(&breath, g_face_container);
    lv_anim_set_values(&breath, 0, 5);  // 0 -> 5px down
    lv_anim_set_time(&breath, 3000);  // 3s down
    lv_anim_set_playback_time(&breath, 3000);  // 3s up
    lv_anim_set_repeat_count(&breath, LV_ANIM_REPEAT_INFINITE);
    lv_anim_set_path_cb(&breath, lv_anim_path_ease_in_out);  // Smooth easing
    lv_anim_set_exec_cb(&breath, breathing_anim);
    lv_anim_start(&breath);
}

static void eyebrow_raise(void) {
    if (!g_brow_l || !g_brow_r) return;
    
    // Eyebrow animation: translate UP 6px, then back down
    lv_anim_t a1;
    lv_anim_init(&a1);
    lv_anim_set_var(&a1, g_brow_l);
    lv_anim_set_values(&a1, 0, -6);  // 0 -> -6px (UP)
    lv_anim_set_time(&a1, 150);  // 150ms up
    lv_anim_set_playback_time(&a1, 150);  // 150ms down
    lv_anim_set_exec_cb(&a1, eyebrow_y_anim);
    lv_anim_start(&a1);

    lv_anim_t a2;
    lv_anim_init(&a2);
    lv_anim_set_var(&a2, g_brow_r);
    lv_anim_set_values(&a2, 0, -6);  // 0 -> -6px (UP)
    lv_anim_set_time(&a2, 150);
    lv_anim_set_playback_time(&a2, 150);
    lv_anim_set_exec_cb(&a2, eyebrow_y_anim);
    lv_anim_start(&a2);
}

static void yawn_sequence(void) {
    if (!g_mouth || !g_eye_l || !g_eye_r || !g_brow_l || !g_brow_r) return;
    
    // Mouth yawn: height 7 -> 32 -> 7 (30% increase: 25 * 1.3 = 32.5)
    lv_anim_t mouth_anim;
    lv_anim_init(&mouth_anim);
    lv_anim_set_var(&mouth_anim, g_mouth);
    lv_anim_set_values(&mouth_anim, g_mouth_base_h, 32);
    lv_anim_set_time(&mouth_anim, 800);  // 800ms open (2x)
    lv_anim_set_playback_time(&mouth_anim, 800);  // 800ms close (2x)
    lv_anim_set_exec_cb(&mouth_anim, (lv_anim_exec_xcb_t)lv_obj_set_height);
    lv_anim_start(&mouth_anim);
    
    // Eyebrow raise during yawn
    lv_anim_t brow_l_anim;
    lv_anim_init(&brow_l_anim);
    lv_anim_set_var(&brow_l_anim, g_brow_l);
    lv_anim_set_values(&brow_l_anim, 0, -6);
    lv_anim_set_time(&brow_l_anim, 800);  // 2x
    lv_anim_set_playback_time(&brow_l_anim, 800);
    lv_anim_set_exec_cb(&brow_l_anim, eyebrow_y_anim);
    lv_anim_start(&brow_l_anim);
    
    lv_anim_t brow_r_anim;
    lv_anim_init(&brow_r_anim);
    lv_anim_set_var(&brow_r_anim, g_brow_r);
    lv_anim_set_values(&brow_r_anim, 0, -6);
    lv_anim_set_time(&brow_r_anim, 800);  // 2x
    lv_anim_set_playback_time(&brow_r_anim, 800);
    lv_anim_set_exec_cb(&brow_r_anim, eyebrow_y_anim);
    lv_anim_start(&brow_r_anim);
    
    // Eyes: wavy effect ~ shape (squish vertically: 18px -> 6px -> 18px)
    lv_anim_t eye_l_h_anim;
    lv_anim_init(&eye_l_h_anim);
    lv_anim_set_var(&eye_l_h_anim, g_eye_l);
    lv_anim_set_values(&eye_l_h_anim, 18, 6);  // Squish to ~ shape
    lv_anim_set_time(&eye_l_h_anim, 800);
    lv_anim_set_playback_time(&eye_l_h_anim, 800);
    lv_anim_set_exec_cb(&eye_l_h_anim, (lv_anim_exec_xcb_t)lv_obj_set_height);
    lv_anim_start(&eye_l_h_anim);
    
    // Also reduce radius to make it more wavy
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
    lv_anim_set_values(&eye_r_h_anim, 18, 6);  // Squish to ~ shape
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
    g_blink_count = 0;  // Reset counter to restart cycle
}

static void blink_once(void) {
    if (!g_lid_l || !g_lid_r) return;
    
    // Skip if yawning
    if (g_is_yawning) return;
    
    // Increment blink counter
    g_blink_count++;
    
    // Every 8th blink: trigger yawn and pause blinking
    if (g_blink_count >= 8) {
        g_is_yawning = true;
        yawn_sequence();
        // Resume blinking after yawn animation (1600ms)
        lv_timer_t* resume_timer = lv_timer_create(resume_blinking, 1700, NULL);
        lv_timer_set_repeat_count(resume_timer, 1);
        return;
    }
    
    // Every 2nd blink, raise eyebrows
    if (g_blink_count % 2 == 0) {
        eyebrow_raise();
    }
    
    // Animation: ONLY change height, NEVER touch position
    lv_anim_t a1;
    lv_anim_init(&a1);
    lv_anim_set_var(&a1, g_lid_l);
    lv_anim_set_values(&a1, 0, g_eye_h);  // 0 -> 18
    lv_anim_set_time(&a1, g_blink_ms / 2);
    lv_anim_set_playback_time(&a1, g_blink_ms / 2);
    lv_anim_set_exec_cb(&a1, (lv_anim_exec_xcb_t)lv_obj_set_height);  // ONLY height
    lv_anim_start(&a1);

    lv_anim_t a2;
    lv_anim_init(&a2);
    lv_anim_set_var(&a2, g_lid_r);
    lv_anim_set_values(&a2, 0, g_eye_h);  // 0 -> 18
    lv_anim_set_time(&a2, g_blink_ms / 2);
    lv_anim_set_playback_time(&a2, g_blink_ms / 2);
    lv_anim_set_exec_cb(&a2, (lv_anim_exec_xcb_t)lv_obj_set_height);  // ONLY height
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
    // Ensure transient overlays (e.g., settings_screen) are closed before switching screen
    ui_before_screen_change();
    lv_display_t* disp = lv_disp_get_default();
    lv_coord_t sw = disp ? lv_display_get_horizontal_resolution(disp) : 320;
    lv_coord_t sh = disp ? lv_display_get_vertical_resolution(disp) : 240;

    g_prev_scr = lv_scr_act();
    g_saver_scr = lv_obj_create(NULL);
    lv_obj_set_style_bg_color(g_saver_scr, lv_color_hex(0x000000), 0);
    lv_obj_set_style_bg_opa(g_saver_scr, LV_OPA_COVER, 0);
    lv_obj_clear_flag(g_saver_scr, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(g_saver_scr, LV_SCROLLBAR_MODE_OFF);
    lv_scr_load(g_saver_scr);

    // face container for breathing effect
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
    lv_obj_add_flag(g_face_container, LV_OBJ_FLAG_EVENT_BUBBLE);  // Let events bubble to parent

    g_brow_l = lv_obj_create(g_face_container);
    lv_obj_set_size(g_brow_l, 18, 4);  // Match eye width (18px)
    lv_obj_set_style_radius(g_brow_l, 2, 0);
    lv_obj_set_style_bg_color(g_brow_l, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(g_brow_l, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(g_brow_l, 0, 0);
    lv_obj_set_style_border_width(g_brow_l, 0, 0);
    lv_obj_set_pos(g_brow_l, cx - 70 - 9, cy - 36 - 2 + 3);  // Align with eye

    g_brow_r = lv_obj_create(g_face_container);
    lv_obj_set_size(g_brow_r, 18, 4);  // Match eye width (18px)
    lv_obj_set_style_radius(g_brow_r, 2, 0);
    lv_obj_set_style_bg_color(g_brow_r, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(g_brow_r, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(g_brow_r, 0, 0);
    lv_obj_set_style_border_width(g_brow_r, 0, 0);
    lv_obj_set_pos(g_brow_r, cx + 70 - 9, cy - 36 - 2 + 3);  // Align with eye

    // Eyes with EXACT calculated positions
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

    // Eyelids: BLACK, start with height 0, position LOCKED
    g_lid_l = lv_obj_create(g_face_container);
    lv_obj_set_size(g_lid_l, 18, 0);  // Start with 0 height
    lv_obj_set_style_radius(g_lid_l, 0, 0);
    lv_obj_set_style_bg_color(g_lid_l, lv_color_hex(0x000000), 0);  // BLACK
    lv_obj_set_style_bg_opa(g_lid_l, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(g_lid_l, 0, 0);
    lv_obj_set_style_border_width(g_lid_l, 0, 0);
    lv_obj_set_scrollbar_mode(g_lid_l, LV_SCROLLBAR_MODE_OFF);
    lv_obj_clear_flag(g_lid_l, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(g_lid_l, eye_l_x, eye_l_y);  // LOCKED position

    g_lid_r = lv_obj_create(g_face_container);
    lv_obj_set_size(g_lid_r, 18, 0);  // Start with 0 height
    lv_obj_set_style_radius(g_lid_r, 0, 0);
    lv_obj_set_style_bg_color(g_lid_r, lv_color_hex(0x000000), 0);  // BLACK
    lv_obj_set_style_bg_opa(g_lid_r, LV_OPA_COVER, 0);
    lv_obj_set_style_pad_all(g_lid_r, 0, 0);
    lv_obj_set_style_border_width(g_lid_r, 0, 0);
    lv_obj_set_scrollbar_mode(g_lid_r, LV_SCROLLBAR_MODE_OFF);
    lv_obj_clear_flag(g_lid_r, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(g_lid_r, eye_r_x, eye_r_y);  // LOCKED position

    g_mouth = lv_obj_create(g_face_container);
    lv_obj_set_size(g_mouth, 130, 7);
    lv_obj_set_style_radius(g_mouth, 3, 0);
    lv_obj_set_style_bg_color(g_mouth, lv_color_white(), 0);
    lv_obj_set_style_bg_opa(g_mouth, LV_OPA_COVER, 0);
    lv_obj_set_pos(g_mouth, cx - 65, cy + 29 - 9);

    // any key/press closes saver
    lv_obj_add_event_cb(g_saver_scr, any_activity_event_cb, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(g_saver_scr, any_activity_event_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_add_event_cb(g_saver_scr, any_activity_event_cb, LV_EVENT_KEY, NULL);

    // schedule blinking
    if (g_blink_timer) { lv_timer_del(g_blink_timer); g_blink_timer = NULL; }
    g_blink_timer = lv_timer_create(blink_timer_cb, g_blink_interval_ms, NULL);
    lv_timer_set_repeat_count(g_blink_timer, -1);
    // trigger first blink shortly after screen draw
    if (g_blink_once_timer) { lv_timer_del(g_blink_once_timer); g_blink_once_timer = NULL; }
    g_blink_once_timer = lv_timer_create(blink_once_timer_cb, 300, NULL);
    lv_timer_set_repeat_count(g_blink_once_timer, 1);
    
    // start breathing animation
    start_breathing();
}

static void hide_screensaver(void) {
    if (!g_saver_scr) return;
    if (g_prev_scr) lv_scr_load(g_prev_scr);
    lv_obj_del(g_saver_scr);
    g_saver_scr = NULL;
}

void screensaver_init(uint32_t timeout_ms) {
    g_timeout_ms = timeout_ms;
    g_last_activity_ms = lv_tick_get();
}

void screensaver_set_timeout(uint32_t timeout_ms) {
    g_timeout_ms = timeout_ms;
}

void screensaver_attach_activity(lv_obj_t* root) {
    if (!root) return;
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_PRESSED, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_CLICKED, NULL);
    lv_obj_add_event_cb(root, any_activity_event_cb, LV_EVENT_KEY, NULL);
}

void screensaver_poll(void) {
    uint32_t now = lv_tick_get();
    // Trigger only after last activity timeout
    if (!g_saver_scr && now - g_last_activity_ms > g_timeout_ms) {
        show_screensaver();
    }
}

void screensaver_blink_set(uint32_t blink_ms, uint32_t interval_ms) {
    g_blink_ms = blink_ms;
    g_blink_interval_ms = interval_ms;
}
