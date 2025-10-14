#include "lvgl.h"
// SDL helpers are provided by LVGL when LV_USE_SDL is enabled; include headers if available
#include "src/drivers/sdl/lv_sdl_window.h"
#include "src/drivers/sdl/lv_sdl_mouse.h"
#include "src/drivers/sdl/lv_sdl_keyboard.h"
#include <stdio.h>
#include "src/libs/tiny_ttf/lv_tiny_ttf.h"

static lv_display_t* disp;
static lv_indev_t* mouse;
static lv_indev_t* kb;

static void create_student_list_ui(void) {
    lv_obj_t* scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x0B0B0B), 0);

    /* Container */
    lv_obj_t* container = lv_obj_create(scr);
    lv_obj_set_size(container, 468, 300);
    lv_obj_set_style_radius(container, 12, 0);
    lv_obj_set_style_bg_color(container, lv_color_hex(0x141414), 0);
    lv_obj_set_style_border_color(container, lv_color_hex(0x2C2C2C), 0);
    lv_obj_set_style_border_width(container, 2, 0);
    lv_obj_center(container);

    /* Load Kakao font (Regular 22px) with ASCII-safe fallback path */
    lv_tiny_ttf_init();
    static lv_font_t* font22;
    if (!font22) {
        /* Prefer local assets path to avoid non-ASCII path issues on Windows */
        font22 = lv_tiny_ttf_create_file("assets/KakaoSmallSans-Regular.ttf", 22);
        if (!font22) {
            /* Fallback to project original path (may fail on some locales) */
            font22 = lv_tiny_ttf_create_file("../../apps/yggdrasill/assets/fonts/kakao/카카오작은글씨/TTF/KakaoSmallSans-Regular.ttf", 22);
        }
        if (!font22) {
            /* Final fallback: Malgun Gothic system font if available */
            font22 = lv_tiny_ttf_create_file("C:/Windows/Fonts/malgun.ttf", 22);
        }
    }

    /* Title */
    lv_obj_t* title = lv_label_create(container);
    lv_obj_set_style_text_font(title, font22, 0);
    lv_label_set_text(title, "M5 LVGL Simulator · 오늘 등원 목록");
    lv_obj_set_style_text_color(title, lv_color_hex(0xE6E6E6), 0);
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 8);

    /* List */
    lv_obj_t* list = lv_list_create(container);
    lv_obj_set_size(list, 440, 240);
    lv_obj_align(list, LV_ALIGN_BOTTOM_MID, 0, -8);
    lv_obj_set_style_bg_color(list, lv_color_hex(0xE5E5E5), 0);
    lv_obj_set_style_radius(list, 8, 0);

    for (int i = 0; i < 8; ++i) {
        char buf[64];
        snprintf(buf, sizeof(buf), "학생 %d", i+1);
        lv_obj_t* t = lv_list_add_text(list, buf);
        lv_obj_set_style_text_font(t, font22, 0);
    }
}

int main(void) {
    lv_init();

    // Create SDL-backed display and input devices (provided by LVGL's SDL driver)
    disp = lv_sdl_window_create(480, 320);
    mouse = lv_sdl_mouse_create();
    kb = lv_sdl_keyboard_create();

    create_student_list_ui();

    while (1) {
        lv_timer_handler();
        lv_tick_inc(5);
#if defined(_WIN32)
        Sleep(5);
#else
        usleep(5000);
#endif
    }
    return 0;
}


