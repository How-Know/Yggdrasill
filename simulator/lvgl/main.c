#include "lvgl.h"
#include "src/drivers/sdl/lv_sdl_window.h"
#include "src/drivers/sdl/lv_sdl_mouse.h"
#include "src/drivers/sdl/lv_sdl_keyboard.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include "src/libs/tiny_ttf/lv_tiny_ttf.h"
#include <mosquitto.h>
#include <parson.h>
#include "screensaver.h"
#include "settings_ui.h"

// External icon declarations (from icon_*.c files)
LV_IMG_DECLARE(home_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(volume_mute_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(settings_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(wifi_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
LV_IMG_DECLARE(refresh_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);

#if defined(_WIN32)
#include <windows.h>
#include <direct.h>
#endif

#define APP_VERSION "1.0.0"

static lv_display_t* disp;
static lv_indev_t* mouse;
static lv_indev_t* kb;

static lv_obj_t* list;                 // vertical cards list
static lv_obj_t* list_root = NULL;     // to be removed in refactor (unused)
static lv_obj_t* stage = NULL;         // root content container
static lv_font_t* font20;
static lv_font_t* font22;
static lv_font_t* font26;
static lv_font_t* font28;
static bool showing_homeworks = false;
static char g_bound_student_id[128] = {0};
static lv_obj_t* g_fab = NULL;
static lv_obj_t* pages = NULL;         // horizontal pager container
static lv_obj_t* info_panel = NULL;    // right page with student info
static lv_obj_t* g_bottom_sheet = NULL;      // 하단 슬라이드 시트
static lv_obj_t* g_bottom_handle = NULL;     // 슬라이드 핸들 (드래그용)
static lv_obj_t* g_volume_popup = NULL;      // 음량 조절 팝업
static uint8_t g_current_volume = 50;        // 현재 음량 (0-100)
bool g_bottom_sheet_open = false;     // 시트 열림 상태 (extern for settings_ui)

// cached info for bound student (for info_panel)
static char g_info_name[128] = {0};
static char g_info_course[128] = {0};
static char g_info_grade[32] = {0};
static char g_info_time[64] = {0};
static char g_info_level[32] = {0};

// screensaver state (moved to screensaver.c module)
// All screensaver-related code is now in screensaver.c/h

/* Anim exec helpers used by homework card breathing effect */
static void anim_set_shadow_opa(void* obj, int32_t v) {
    lv_obj_set_style_shadow_opa((lv_obj_t*)obj, (lv_opa_t)v, 0);
}
static void anim_set_bg_gray(void* obj, int32_t v) {
    uint32_t g = ((uint32_t)v) & 0xFFu;
    uint32_t hex = (g << 16) | (g << 8) | g;
    lv_obj_set_style_bg_color((lv_obj_t*)obj, lv_color_hex(hex), 0);
}

/* Event payload for homework card clicks */
typedef struct HwEventData {
    char* item_id;
    int   phase;
} HwEventData;

static void show_volume_popup(void);
static void close_volume_popup(void);
static void goto_home_page(void);
void toggle_bottom_sheet(void);  // Exposed for settings_ui
static void handle_drag_cb(lv_event_t* e);
static void draw_volume_icon(lv_obj_t* parent);
static void draw_home_icon(lv_obj_t* parent);

/* Exposed for screensaver to safely clean UI before screen switch */
void ui_before_screen_change(void);

static bool fs_exists(const char* path) {
    if (!path || !*path) return false;
    lv_fs_file_t f;
    lv_fs_res_t r = lv_fs_open(&f, path, LV_FS_MODE_RD);
    if (r == LV_FS_RES_OK) {
        lv_fs_close(&f);
        return true;
    }
    return false;
}

static bool image_can_decode(const char* path) {
    if (!path || !*path) return false;
    lv_image_header_t header;
    lv_result_t r = lv_image_decoder_get_info(path, &header);
    return r == LV_RESULT_OK;
}

static void update_info_panel(void) {
    if (!info_panel) return;
    // clear previous children
    lv_obj_clean(info_panel);

    // 1행: 이름
    lv_obj_t* name_lbl = lv_label_create(info_panel);
    lv_obj_set_style_text_font(name_lbl, font26 ? font26 : font22, 0);
    lv_obj_set_style_text_color(name_lbl, lv_color_hex(0xE6E6E6), 0);
    lv_label_set_text_fmt(name_lbl, "%s", g_info_name[0] ? g_info_name : "학생");

    // 2행: 학교와 학년 (한 줄에)
    lv_obj_t* school_grade_lbl = lv_label_create(info_panel);
    lv_obj_set_style_text_font(school_grade_lbl, font20 ? font20 : font22, 0);
    lv_obj_set_style_text_color(school_grade_lbl, lv_color_hex(0xCFCFCF), 0);
    char school_grade[256];
    const char* school = g_info_course[0] ? g_info_course : "";
    const char* grade = g_info_grade[0] ? g_info_grade : "";
    if (school[0] && grade[0]) {
        snprintf(school_grade, sizeof(school_grade), "%s · %s학년", school, grade);
    } else if (school[0]) {
        snprintf(school_grade, sizeof(school_grade), "%s", school);
    } else if (grade[0]) {
        snprintf(school_grade, sizeof(school_grade), "%s학년", grade);
    } else {
        snprintf(school_grade, sizeof(school_grade), "—");
    }
    lv_label_set_text(school_grade_lbl, school_grade);

    // 3행: 수업시간
    lv_obj_t* time_lbl = lv_label_create(info_panel);
    lv_obj_set_style_text_font(time_lbl, font20 ? font20 : font22, 0);
    lv_obj_set_style_text_color(time_lbl, lv_color_hex(0xCFCFCF), 0);
    lv_label_set_text_fmt(time_lbl, "%s", g_info_time[0] ? g_info_time : "—");

    // Spacer for separation before logout
    lv_obj_t* spacer = lv_obj_create(info_panel);
    lv_obj_set_size(spacer, lv_pct(100), 1);
    lv_obj_set_style_bg_opa(spacer, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(spacer, 0, 0);
    lv_obj_set_flex_grow(spacer, 1);  // Push logout to bottom

    // Logout button (flex child, not absolute positioned)
    lv_obj_t* unbind = lv_btn_create(info_panel);
    lv_obj_set_size(unbind, lv_pct(90), 40);  // 90% width, 40px height
    lv_obj_set_style_radius(unbind, 20, 0);
    lv_obj_set_style_bg_color(unbind, lv_color_hex(0x2C2C2C), 0);
    lv_obj_set_style_border_width(unbind, 0, 0);
    lv_obj_add_flag(unbind, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_t* lbl = lv_label_create(unbind);
    lv_obj_set_style_text_color(lbl, lv_color_hex(0xFF4444), 0);  // 빨간색
    lv_obj_set_style_text_font(lbl, font20 ? font20 : font22, 0);
    lv_label_set_text(lbl, "로그아웃");
    lv_obj_center(lbl);  // 가운데 정렬
    extern void unbind_event_cb(lv_event_t* e);
    lv_obj_add_event_cb(unbind, unbind_event_cb, LV_EVENT_CLICKED, NULL);
}

/* utils: uuid v4 string (36 chars + NUL) */
static void generate_uuid_v4(char out[37]) {
    static const char* hex = "0123456789abcdef";
    unsigned char rnd[16];
    for (int i = 0; i < 16; ++i) rnd[i] = (unsigned char)(rand() & 0xFF);
    rnd[6] = (rnd[6] & 0x0F) | 0x40; // version 4
    rnd[8] = (rnd[8] & 0x3F) | 0x80; // variant
    int p = 0;
    for (int i = 0; i < 16; ++i) {
        if (i == 4 || i == 6 || i == 8 || i == 10) out[p++] = '-';
        out[p++] = hex[(rnd[i] >> 4) & 0x0F];
        out[p++] = hex[rnd[i] & 0x0F];
    }
    out[p] = '\0';
}

/* utils: now → ISO8601 (local time) */
static void now_iso8601(char* out, size_t out_size) {
    time_t now = time(NULL);
    struct tm t;
#if defined(_WIN32)
    localtime_s(&t, &now);
#else
    localtime_r(&now, &t);
#endif
    snprintf(out, out_size, "%04d-%02d-%02dT%02d:%02d:%02d",
             t.tm_year + 1900, t.tm_mon + 1, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec);
}

static const char* getenv_or_default(const char* name, const char* default_value) {
    const char* v = getenv(name);
    return (v && *v) ? v : default_value;
}

static lv_font_t* load_ttf_file(const char* path, int size) {
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long len = ftell(f);
    if (len <= 0) { fclose(f); return NULL; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    uint8_t* buf = (uint8_t*)malloc((size_t)len);
    if (!buf) { fclose(f); return NULL; }
    size_t rd = fread(buf, 1, (size_t)len, f);
    fclose(f);
    if (rd != (size_t)len) { free(buf); return NULL; }
    lv_font_t* font = lv_tiny_ttf_create_data(buf, (size_t)len, size);
    if (!font) { free(buf); return NULL; }
    return font;
}

static lv_font_t* try_load_korean_font(int size) {
    const char* candidates[] = {
        "assets/KakaoSmallSans-Regular.ttf",
        "../assets/KakaoSmallSans-Regular.ttf",
        "../../assets/KakaoSmallSans-Regular.ttf",
        "C:/Windows/Fonts/malgun.ttf",
    };
    const int count = sizeof(candidates) / sizeof(candidates[0]);
    for (int i = 0; i < count; ++i) {
        lv_font_t* f = load_ttf_file(candidates[i], size);
        if (f) return f;
    }
    return NULL;
}

static void rebuild_student_cards(JSON_Array* students) {
    // Clear list children
    lv_obj_clean(list);

    if (!students) return;
    size_t n = json_array_get_count(students);
    for (size_t i = 0; i < n; ++i) {
        JSON_Object* s = json_array_get_object(students, i);
        const char* name = s ? json_object_get_string(s, "name") : NULL;
        const char* student_name = s ? json_object_get_string(s, "student_name") : NULL;
        const char* student_id = s ? json_object_get_string(s, "student_id") : NULL;
        if (!student_id && s) student_id = json_object_get_string(s, "id");
        const char* display = name && *name ? name : (student_name ? student_name : "학생");

        lv_obj_t* card = lv_obj_create(list);
        lv_obj_set_width(card, lv_pct(100));
        lv_obj_set_height(card, 104);
        lv_obj_set_style_radius(card, 10, 0);
        lv_obj_set_style_bg_color(card, lv_color_hex(0x1A1A1A), 0);
        lv_obj_set_style_border_color(card, lv_color_hex(0x2C2C2C), 0);
        lv_obj_set_style_border_width(card, 2, 0);
        lv_obj_set_style_pad_all(card, 14, 0);
        lv_obj_add_flag(card, LV_OBJ_FLAG_CLICKABLE);

        lv_obj_t* name_lbl = lv_label_create(card);
        lv_obj_set_style_text_font(name_lbl, font28 ? font28 : font22, 0);
        lv_obj_set_style_text_color(name_lbl, lv_color_hex(0xE6E6E6), 0);
        lv_label_set_text(name_lbl, display);
        lv_obj_align(name_lbl, LV_ALIGN_LEFT_MID, 0, 0);
        lv_obj_add_flag(name_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);

        // attach click handler to bind on selection; pass student_id as user data
        if (student_id && *student_id) {
            char* id_copy = (char*)malloc(strlen(student_id) + 1);
            if (id_copy) {
                strcpy(id_copy, student_id);
                // attach click-only to avoid LV_EVENT_DELETE double free
                extern void student_card_event_cb(lv_event_t* e);
                lv_obj_add_event_cb(card, student_card_event_cb, LV_EVENT_CLICKED, id_copy);
            }
        }
    }
}

// Build homeworks pager (list + info) and mount to stage. Creates FAB.
static void build_homeworks_ui(void) {
    if (!stage) return;
    lv_obj_clean(stage);

    // create horizontal pages
    pages = lv_obj_create(stage);
    lv_obj_set_size(pages, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_opa(pages, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(pages, 0, 0);
    lv_obj_set_flex_flow(pages, LV_FLEX_FLOW_ROW);
    lv_obj_set_scroll_dir(pages, LV_DIR_HOR);
    lv_obj_set_scroll_snap_x(pages, LV_SCROLL_SNAP_CENTER);
    lv_obj_set_style_pad_column(pages, 12, 0); // 페이지 사이 여백 확보
    lv_obj_set_scrollbar_mode(pages, LV_SCROLLBAR_MODE_OFF);
    screensaver_attach_activity(pages);

    // left: INFO page
    info_panel = lv_obj_create(pages);
    lv_obj_set_size(info_panel, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_color(info_panel, lv_color_hex(0x141414), 0);
    lv_obj_set_style_border_width(info_panel, 0, 0);
    lv_obj_set_style_pad_all(info_panel, 12, 0);
    lv_obj_set_style_pad_right(info_panel, 12, 0);
    lv_obj_set_style_pad_row(info_panel, 4, 0);  // 기본 줄간격
    lv_obj_set_style_pad_bottom(info_panel, 16, 0);  // 하단 여유 줄임
    lv_obj_set_scrollbar_mode(info_panel, LV_SCROLLBAR_MODE_OFF);  // 스크롤바만 숨김
    lv_obj_set_scroll_dir(info_panel, LV_DIR_VER);  // 세로 스크롤 활성화
    lv_obj_set_flex_flow(info_panel, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(info_panel, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);  // 가운데 정렬
    update_info_panel();
    screensaver_attach_activity(info_panel);

    // middle: homeworks page
    lv_obj_t* homeworks_page = lv_obj_create(pages);
    lv_obj_set_size(homeworks_page, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_opa(homeworks_page, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(homeworks_page, 0, 0);
    lv_obj_set_style_pad_all(homeworks_page, 0, 0);

    list = lv_obj_create(homeworks_page);
    lv_obj_set_size(list, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_color(list, lv_color_hex(0x141414), 0);
    lv_obj_set_style_border_width(list, 0, 0);
    lv_obj_set_style_pad_all(list, 8, 0);
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_START);
    lv_obj_set_style_pad_row(list, 12, 0);
    lv_obj_set_scroll_dir(list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_OFF);
    lv_obj_add_flag(list, LV_OBJ_FLAG_GESTURE_BUBBLE);
    lv_obj_add_flag(list, LV_OBJ_FLAG_SCROLL_CHAIN_HOR);
    screensaver_attach_activity(homeworks_page);
    screensaver_attach_activity(list);

    // right: classes page (수업 페이지 - 빈 상태)
    lv_obj_t* classes_page = lv_obj_create(pages);
    lv_obj_set_size(classes_page, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_color(classes_page, lv_color_hex(0x141414), 0);
    lv_obj_set_style_border_width(classes_page, 0, 0);
    lv_obj_set_style_pad_all(classes_page, 12, 0);
    lv_obj_set_scrollbar_mode(classes_page, LV_SCROLLBAR_MODE_OFF);
    
    // Placeholder label for classes page
    lv_obj_t* classes_label = lv_label_create(classes_page);
    lv_obj_set_style_text_font(classes_label, font22 ? font22 : font20, 0);
    lv_obj_set_style_text_color(classes_label, lv_color_hex(0x808080), 0);
    lv_label_set_text(classes_label, "수업 페이지\n(준비 중)");
    lv_obj_center(classes_label);
    screensaver_attach_activity(classes_page);

    // align to middle page(homeworks) 기본 표시
    lv_obj_scroll_to_view(homeworks_page, LV_ANIM_OFF);

    // FAB (휴식): now create
    if (!g_fab) {
        lv_obj_t* container = lv_obj_get_parent(stage);
        g_fab = lv_btn_create(container);
        lv_obj_set_size(g_fab, 67, 57);
        lv_obj_set_style_radius(g_fab, 12, 0);
        lv_obj_set_style_bg_color(g_fab, lv_color_hex(0x1E88E5), 0);
        lv_obj_set_style_border_width(g_fab, 0, 0);
        lv_obj_set_style_shadow_color(g_fab, lv_color_hex(0x1E88E5), 0);
        lv_obj_set_style_shadow_width(g_fab, 14, 0);
        lv_obj_set_style_shadow_opa(g_fab, LV_OPA_30, 0);
        lv_obj_align(g_fab, LV_ALIGN_BOTTOM_RIGHT, -8, -8);
        lv_obj_add_flag(g_fab, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_t* icon = lv_label_create(g_fab);
        lv_obj_set_style_text_color(icon, lv_color_hex(0xFFFFFF), 0);
        lv_obj_set_style_text_font(icon, font22 ? font22 : font28, 0);
        lv_label_set_text(icon, "휴식");
        lv_obj_center(icon);
        extern void fab_pause_all_event_cb(lv_event_t* e);
        lv_obj_add_event_cb(g_fab, fab_pause_all_event_cb, LV_EVENT_CLICKED, NULL);
    }
    
    // Bottom slide sheet with iPhone-style handle
    if (!g_bottom_sheet) {
        lv_obj_t* container = lv_obj_get_parent(stage);
        
        // Handle bar (iPhone style - always visible)
        g_bottom_handle = lv_obj_create(container);
        lv_obj_set_size(g_bottom_handle, 320, 24);
        lv_obj_set_pos(g_bottom_handle, 0, 216);  // Y=216 (240-24)
        lv_obj_set_style_bg_opa(g_bottom_handle, LV_OPA_TRANSP, 0);
        lv_obj_set_style_border_width(g_bottom_handle, 0, 0);
        lv_obj_set_style_pad_all(g_bottom_handle, 0, 0);
        
        // Handle indicator (horizontal bar) - 20% wider
        lv_obj_t* indicator = lv_obj_create(g_bottom_handle);
        lv_obj_set_size(indicator, 50, 5);  // 36 * 1.2 = 43
        lv_obj_set_style_bg_color(indicator, lv_color_hex(0xFFFFFF), 0);
        lv_obj_set_style_bg_opa(indicator, LV_OPA_30, 0);
        lv_obj_set_style_radius(indicator, 3, 0);
        lv_obj_set_style_border_width(indicator, 0, 0);
        lv_obj_align(indicator, LV_ALIGN_CENTER, 0, 0);
        
        lv_obj_add_event_cb(g_bottom_handle, handle_drag_cb, LV_EVENT_CLICKED, NULL);
        
        // Bottom sheet (initially hidden below screen)
        g_bottom_sheet = lv_obj_create(container);
        lv_obj_set_size(g_bottom_sheet, 320, 100);
        lv_obj_set_pos(g_bottom_sheet, 0, 240);  // Hidden below
        lv_obj_set_style_bg_color(g_bottom_sheet, lv_color_hex(0x1C1C1C), 0);
        lv_obj_set_style_bg_opa(g_bottom_sheet, LV_OPA_80, 0);  // Semi-transparent
        lv_obj_set_style_border_width(g_bottom_sheet, 0, 0);
        lv_obj_set_style_radius(g_bottom_sheet, 0, 0);
        lv_obj_set_style_pad_all(g_bottom_sheet, 20, 0);
        lv_obj_set_scrollbar_mode(g_bottom_sheet, LV_SCROLLBAR_MODE_OFF);
        lv_obj_set_flex_flow(g_bottom_sheet, LV_FLEX_FLOW_ROW);
        lv_obj_set_flex_align(g_bottom_sheet, LV_FLEX_ALIGN_SPACE_EVENLY, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        
        // Volume button (embedded high-quality icon)
        lv_obj_t* vol_btn = lv_btn_create(g_bottom_sheet);
        lv_obj_set_size(vol_btn, 50, 50);
        lv_obj_set_style_radius(vol_btn, 0, 0);
        lv_obj_set_style_bg_opa(vol_btn, LV_OPA_TRANSP, 0);
        lv_obj_set_style_border_width(vol_btn, 0, 0);
        lv_obj_set_style_shadow_width(vol_btn, 0, 0);
        lv_obj_t* vol_img = lv_img_create(vol_btn);
        lv_img_set_src(vol_img, &volume_mute_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
        lv_image_set_scale(vol_img, 230);  // 10% 축소 (256 = 100%, 230 = 90%)
        lv_obj_center(vol_img);
        extern void volume_btn_cb(lv_event_t* e);
        lv_obj_add_event_cb(vol_btn, volume_btn_cb, LV_EVENT_CLICKED, NULL);
        
        // Home button (embedded high-quality icon)
        lv_obj_t* home_btn = lv_btn_create(g_bottom_sheet);
        lv_obj_set_size(home_btn, 50, 50);
        lv_obj_set_style_radius(home_btn, 0, 0);
        lv_obj_set_style_bg_opa(home_btn, LV_OPA_TRANSP, 0);
        lv_obj_set_style_border_width(home_btn, 0, 0);
        lv_obj_set_style_shadow_width(home_btn, 0, 0);
        lv_obj_t* home_img = lv_img_create(home_btn);
        lv_img_set_src(home_img, &home_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
        lv_image_set_scale(home_img, 205);  // 20% 축소 (256 = 100%, 205 = 80%)
        lv_obj_center(home_img);
        extern void home_btn_cb(lv_event_t* e);
        lv_obj_add_event_cb(home_btn, home_btn_cb, LV_EVENT_CLICKED, NULL);
        
        // Settings button (3rd button in bottom sheet)
        lv_obj_t* settings_btn = lv_btn_create(g_bottom_sheet);
        lv_obj_set_size(settings_btn, 50, 50);
        lv_obj_set_style_radius(settings_btn, 0, 0);
        lv_obj_set_style_bg_opa(settings_btn, LV_OPA_TRANSP, 0);
        lv_obj_set_style_border_width(settings_btn, 0, 0);
        lv_obj_set_style_shadow_width(settings_btn, 0, 0);
        lv_obj_t* settings_img = lv_img_create(settings_btn);
        lv_img_set_src(settings_img, &settings_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
        lv_image_set_scale(settings_img, 205);  // 20% 축소 (홈 버튼과 동일)
        lv_obj_center(settings_img);
        extern void settings_event_cb(lv_event_t* e);
        lv_obj_add_event_cb(settings_btn, settings_event_cb, LV_EVENT_CLICKED, NULL);
    }
}
static void rebuild_homework_cards(JSON_Array* items) {
    showing_homeworks = true;
    lv_obj_clean(list);

    size_t n = items ? json_array_get_count(items) : 0;
    for (size_t i = 0; i < n; ++i) {
        JSON_Object* it = json_array_get_object(items, i);
        const char* title = it ? json_object_get_string(it, "title") : NULL;
        const char* name = it ? json_object_get_string(it, "name") : NULL;
        const char* display = (title && *title) ? title : (name && *name ? name : "과제");

        // parse phase and color from payload (server color as bigint ARGB; use RGB part)
        int phase = 1;
        if (it && json_object_has_value_of_type(it, "phase", JSONNumber)) {
            phase = (int)json_object_get_number(it, "phase");
        }
        uint32_t srv_color = 0x1E88E5;
        if (it && json_object_has_value_of_type(it, "color", JSONNumber)) {
            double v = json_object_get_number(it, "color");
            if (v > 0) srv_color = ((uint32_t)v) & 0xFFFFFFu;
        }
        const char* item_id = it ? json_object_get_string(it, "item_id") : NULL;

        // wrapper frame to simulate gradient border when needed
        lv_obj_t* frame = lv_obj_create(list);
        lv_obj_set_width(frame, lv_pct(100));
        lv_obj_set_height(frame, 96); // 20% 줄임 (기존 120->96 기준)
        lv_obj_set_style_pad_all(frame, 2, 0);
        lv_obj_set_style_radius(frame, 12, 0);
        // base frame bg = container bg
        lv_obj_set_style_bg_color(frame, lv_color_hex(0x141414), 0);
        lv_obj_set_style_border_width(frame, 0, 0);

        // inner card
        lv_obj_t* card = lv_obj_create(frame);
        lv_obj_set_width(card, lv_pct(100));
        lv_obj_set_height(card, 92); // 20% 줄임
        lv_obj_set_style_radius(card, 10, 0);
        lv_obj_set_style_bg_color(card, lv_color_hex(0x1A1A1A), 0);
        lv_obj_set_style_border_color(card, lv_color_hex(0x2C2C2C), 0);
        lv_obj_set_style_border_width(card, 2, 0);
        lv_obj_set_style_pad_all(card, 14, 0);
        lv_obj_set_style_pad_left(card, 21, 0); // 왼쪽 여백 50% 증가
        lv_obj_add_flag(card, LV_OBJ_FLAG_CLICKABLE);

        // title on the left
        lv_obj_t* title_lbl = lv_label_create(card);
        lv_obj_set_style_text_font(title_lbl, font28 ? font28 : font22, 0);
        lv_obj_set_style_text_color(title_lbl, lv_color_hex(0xE6E6E6), 0);
        lv_label_set_text(title_lbl, display);
        lv_obj_align(title_lbl, LV_ALIGN_LEFT_MID, 0, 0);
        lv_obj_add_flag(title_lbl, LV_OBJ_FLAG_EVENT_BUBBLE);

        // state-specific visuals
        if (phase == 2) {
            // 수행: gradient border via frame bg gradient
            // compute gradient colors from server color (lighter -> darker)
            uint8_t r = (srv_color >> 16) & 0xFF, g = (srv_color >> 8) & 0xFF, b = srv_color & 0xFF;
            int lr = r + 40; if (lr > 255) lr = 255; int lg = g + 40; if (lg > 255) lg = 255; int lb = b + 40; if (lb > 255) lb = 255;
            int dr = r - 30; if (dr < 0) dr = 0; int dg = g - 30; if (dg < 0) dg = 0; int db = b - 30; if (db < 0) db = 0;
            uint32_t c1 = ((uint32_t)lr << 16) | ((uint32_t)lg << 8) | (uint32_t)lb;
            uint32_t c2 = ((uint32_t)dr << 16) | ((uint32_t)dg << 8) | (uint32_t)db;
            lv_obj_set_style_bg_color(frame, lv_color_hex(c1), 0);
            lv_obj_set_style_bg_grad_color(frame, lv_color_hex(c2), 0);
            lv_obj_set_style_bg_grad_dir(frame, LV_GRAD_DIR_HOR, 0);
            // emphasize
            lv_obj_set_style_shadow_width(card, 10, 0);
            lv_obj_set_style_shadow_color(card, lv_color_hex(srv_color), 0);
            lv_obj_set_style_shadow_opa(card, LV_OPA_20, 0);
        } else if (phase == 3) {
            // 제출: disable border + spinner on the right
            lv_obj_set_style_border_width(card, 0, 0);
            lv_obj_t* sp = lv_spinner_create(card);
            lv_obj_set_size(sp, 24, 24);
            // add a bit more right margin
            lv_obj_align(sp, LV_ALIGN_RIGHT_MID, -8, 0);
            // match spinner background to card color (avoid white bg)
            lv_obj_set_style_bg_opa(sp, LV_OPA_TRANSP, 0);
            lv_obj_set_style_arc_color(sp, lv_color_hex(0x1A1A1A), 0 /* LV_PART_MAIN */);
            lv_obj_set_style_arc_width(sp, 4, 0 /* LV_PART_MAIN */);
            lv_obj_set_style_arc_color(sp, lv_color_hex(srv_color), LV_PART_INDICATOR);
            lv_obj_set_style_arc_width(sp, 4, LV_PART_INDICATOR);
            lv_obj_add_flag(sp, LV_OBJ_FLAG_EVENT_BUBBLE);
        } else if (phase == 4) {
            // 확인: 배경을 카드색(0x1A1A1A)보다 조금 밝은 회색으로 만들고, 색상 자체를 숨쉬는 리듬으로 애니메이션
            lv_obj_set_style_bg_opa(card, LV_OPA_COVER, 0);
            lv_obj_set_style_bg_color(card, lv_color_hex(0x202020), 0); // base: 더 밝은 회색
            lv_obj_set_style_shadow_color(card, lv_color_hex(srv_color), 0);
            lv_obj_set_style_shadow_width(card, 10, 0);
            lv_obj_set_style_shadow_opa(card, LV_OPA_20, 0);

            // 섀도우도 천천히 호흡하도록 펄스
            lv_anim_t a; lv_anim_init(&a);
            lv_anim_set_var(&a, card);
            lv_anim_set_values(&a, 40, 140); // 대비 한 단계 강화
            lv_anim_set_time(&a, 1000); // 2000ms 왕복
            lv_anim_set_playback_time(&a, 1000);
            lv_anim_set_repeat_count(&a, LV_ANIM_REPEAT_INFINITE);
            lv_anim_set_exec_cb(&a, (lv_anim_exec_xcb_t)anim_set_shadow_opa);
            lv_anim_set_path_cb(&a, lv_anim_path_ease_in_out);
            lv_anim_start(&a);

            // 배경 회색값 자체를 0x1E(30) ↔ 0x2A(42) 사이에서 왕복(부드러운 숨쉬기)
            lv_anim_t a2; lv_anim_init(&a2);
            lv_anim_set_var(&a2, card);
            lv_anim_set_values(&a2, 0x1C, 0x2E); // 대비 강화
            lv_anim_set_time(&a2, 1000); // 2000ms 왕복
            lv_anim_set_playback_time(&a2, 1000);
            lv_anim_set_repeat_count(&a2, LV_ANIM_REPEAT_INFINITE);
            lv_anim_set_exec_cb(&a2, (lv_anim_exec_xcb_t)anim_set_bg_gray);
            lv_anim_set_path_cb(&a2, lv_anim_path_ease_in_out);
            lv_anim_start(&a2);
        } else {
            // 대기: disabled look
            lv_obj_set_style_border_color(card, lv_color_hex(0x2C2C2C), 0);
            lv_obj_set_style_border_width(card, 1, 0);
            lv_obj_set_style_text_color(title_lbl, lv_color_hex(0xAAAAAA), 0);
            lv_obj_set_style_bg_opa(card, LV_OPA_90, 0);
        }
        // 터치 시 A버튼 로직 수행을 위한 이벤트 데이터 부여
        if (item_id && *item_id) {
            HwEventData* ed = (HwEventData*)malloc(sizeof(HwEventData));
            if (ed) {
                size_t len = strlen(item_id);
                ed->item_id = (char*)malloc(len + 1);
                if (ed->item_id) {
                    memcpy(ed->item_id, item_id, len + 1);
                    ed->phase = phase;
                    extern void homework_card_event_cb(lv_event_t* e);
                    lv_obj_add_event_cb(card, homework_card_event_cb, LV_EVENT_CLICKED, ed);
                } else {
                    free(ed);
                }
            }
        }
    }
}

static void create_student_list_ui(void) {
    lv_obj_t* scr = lv_scr_act();
    lv_obj_set_style_bg_color(scr, lv_color_hex(0x0B0B0B), 0);
    lv_obj_set_style_pad_all(scr, 0, 0);
    lv_obj_set_style_border_width(scr, 0, 0);
    lv_obj_set_scrollbar_mode(scr, LV_SCROLLBAR_MODE_OFF);
    screensaver_attach_activity(scr);

    /* Container (pager) */
    lv_obj_t* container = lv_obj_create(scr);
    lv_obj_set_size(container, lv_pct(100), lv_pct(100));
    lv_obj_set_style_radius(container, 0, 0);
    lv_obj_set_style_bg_color(container, lv_color_hex(0x141414), 0);
    lv_obj_set_style_border_width(container, 0, 0);
    lv_obj_set_style_pad_all(container, 0, 0);
    lv_obj_align(container, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_scrollbar_mode(container, LV_SCROLLBAR_MODE_OFF);

    // stage: root that hosts either StudentList or HomeworksPager
    stage = lv_obj_create(container);
    lv_obj_set_size(stage, lv_pct(100), lv_pct(100));
    lv_obj_set_style_bg_opa(stage, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(stage, 0, 0);
    lv_obj_set_style_pad_all(stage, 0, 0);
    lv_obj_set_scroll_dir(stage, LV_DIR_NONE);
    lv_obj_set_scrollbar_mode(stage, LV_SCROLLBAR_MODE_OFF);
    screensaver_attach_activity(stage);

    /* Fonts */
    lv_tiny_ttf_init();
    if (!font20) font20 = try_load_korean_font(20);
    if (!font22) font22 = try_load_korean_font(22);
    if (!font26) font26 = try_load_korean_font(26);
    if (!font28) font28 = try_load_korean_font(28);

    // Initial student list page (no horizontal pager yet)
    list = lv_obj_create(stage);
    lv_obj_set_size(list, lv_pct(100), lv_pct(100));
    lv_obj_align(list, LV_ALIGN_TOP_LEFT, 0, 0);
    lv_obj_set_style_bg_color(list, lv_color_hex(0x141414), 0);
    lv_obj_set_style_border_width(list, 0, 0);
    lv_obj_set_style_pad_all(list, 4, 0);
    lv_obj_set_flex_flow(list, LV_FLEX_FLOW_COLUMN);
    lv_obj_set_flex_align(list, LV_FLEX_ALIGN_START, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_START);
    lv_obj_set_style_pad_row(list, 8, 0);
    lv_obj_set_scroll_dir(list, LV_DIR_VER);
    lv_obj_set_scrollbar_mode(list, LV_SCROLLBAR_MODE_OFF);
    screensaver_attach_activity(list);

    // seed empty UI
    rebuild_student_cards(NULL);

    // FAB은 홈워크 모드에서만 생성 (초기엔 없음)
}

/* MQTT */
static struct mosquitto* mq = NULL;
static char g_academy_id[128] = {0};
static char g_device_id[128] = {0};

static void publish_presence_and_list_today(void) {
    if (!mq) return;
    // presence
    char topic[256];
    snprintf(topic, sizeof(topic), "academies/%s/devices/%s/presence", g_academy_id, g_device_id);
    char payload[256];
    // simple ISO8601 now
    time_t now = time(NULL);
    struct tm t; 
#if defined(_WIN32)
    localtime_s(&t, &now);
#else
    localtime_r(&now, &t);
#endif
    snprintf(payload, sizeof(payload), "{\"online\":true,\"at\":\"%04d-%02d-%02dT%02d:%02d:%02d\"}",
             t.tm_year + 1900, t.tm_mon + 1, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec);
    mosquitto_publish(mq, NULL, topic, (int)strlen(payload), payload, 1, true /* retain */);

    // list_today command
    snprintf(topic, sizeof(topic), "academies/%s/devices/%s/command", g_academy_id, g_device_id);
    const char* cmd = "{\"action\":\"list_today\"}";
    mosquitto_publish(mq, NULL, topic, (int)strlen(cmd), cmd, 1, false);
}

static void on_mqtt_connect(struct mosquitto* m, void* ud, int rc) {
    (void)m; (void)ud; (void)rc;
    publish_presence_and_list_today();
}

static void on_mqtt_message(struct mosquitto* m, void* ud, const struct mosquitto_message* msg) {
    (void)m; (void)ud;
    if (!msg || !msg->topic || !msg->payload) return;
    const char* topic = (const char*)msg->topic;

    // expect academies/{academy_id}/devices/{device_id}/students_today
    char expect[256];
    snprintf(expect, sizeof(expect), "academies/%s/devices/%s/students_today", g_academy_id, g_device_id);
    if (strcmp(topic, expect) == 0) {
        const char* json = (const char*)msg->payload;
        JSON_Value* root = json_parse_string(json);
        if (!root) return;
        JSON_Object* obj = json_value_get_object(root);
        JSON_Array* students = obj ? json_object_get_array(obj, "students") : NULL;
        // Try capture minimal info for info panel if available
        if (students && json_array_get_count(students) > 0 && g_bound_student_id[0]) {
            size_t m = json_array_get_count(students);
            for (size_t i = 0; i < m; ++i) {
                JSON_Object* s = json_array_get_object(students, i);
                const char* sid = s ? json_object_get_string(s, "student_id") : NULL;
                if (!sid && s) sid = json_object_get_string(s, "id");
                if (sid && strcmp(sid, g_bound_student_id) == 0) {
                    const char* nm = json_object_get_string(s, "name");
                    const char* course = json_object_get_string(s, "course_name");
                    const char* grade = json_object_get_string(s, "grade_name");
                    const char* time = json_object_get_string(s, "class_time");
                    if (nm) { strncpy(g_info_name, nm, sizeof(g_info_name)-1); }
                    if (course) { strncpy(g_info_course, course, sizeof(g_info_course)-1); }
                    if (grade) { strncpy(g_info_grade, grade, sizeof(g_info_grade)-1); }
                    if (time) { strncpy(g_info_time, time, sizeof(g_info_time)-1); }
                    break;
                }
            }
            update_info_panel();
            // enable horizontal scroll right away on bind
            if (pages) {
                lv_obj_set_scroll_dir(pages, LV_DIR_HOR);
                // ensure we are at the homeworks page (right)
                lv_obj_scroll_to_view(list, LV_ANIM_OFF);
            }
        }
        showing_homeworks = false;
        rebuild_student_cards(students);
        json_value_free(root);
        return;
    }

    // academies/{academy_id}/devices/{device_id}/homeworks
    snprintf(expect, sizeof(expect), "academies/%s/devices/%s/homeworks", g_academy_id, g_device_id);
    if (strcmp(topic, expect) == 0) {
        const char* json = (const char*)msg->payload;
        JSON_Value* root = json_parse_string(json);
        if (!root) return;
        JSON_Object* obj = json_value_get_object(root);
        JSON_Array* items = obj ? json_object_get_array(obj, "items") : NULL;
        rebuild_homework_cards(items);
        json_value_free(root);
        return;
    }

    // academies/{academy_id}/devices/{device_id}/student_info
    snprintf(expect, sizeof(expect), "academies/%s/devices/%s/student_info", g_academy_id, g_device_id);
    if (strcmp(topic, expect) == 0) {
        const char* json = (const char*)msg->payload;
        JSON_Value* root = json_parse_string(json);
        if (!root) return;
        JSON_Object* obj = json_value_get_object(root);
        JSON_Object* info = obj ? json_object_get_object(obj, "info") : NULL;
        if (info) {
            const char* name = json_object_get_string(info, "name");
            const char* school = json_object_get_string(info, "school");
            int edu = (int)json_object_get_number(info, "education_level");
            int sh = (int)json_object_get_number(info, "start_hour");
            int sm = (int)json_object_get_number(info, "start_minute");
            const char* weekday = json_object_get_string(info, "weekday_kr");
            const char* grade = NULL;
            if (json_object_has_value_of_type(info, "grade", JSONNumber)) {
                static char gbuf[32];
                snprintf(gbuf, sizeof(gbuf), "%d", (int)json_object_get_number(info, "grade"));
                grade = gbuf;
            }
            if (name) { strncpy(g_info_name, name, sizeof(g_info_name)-1); }
            if (school) { strncpy(g_info_course, school, sizeof(g_info_course)-1); } // 과정 라벨에 학교/과정명 표시
            if (grade) { strncpy(g_info_grade, grade, sizeof(g_info_grade)-1); }
            if (sh >= 0 && sm >= 0) {
                static char tbuf[64];
                if (weekday && *weekday)
                    snprintf(tbuf, sizeof(tbuf), "%s %02d:%02d", weekday, sh, sm);
                else
                    snprintf(tbuf, sizeof(tbuf), "%02d:%02d", sh, sm);
                strncpy(g_info_time, tbuf, sizeof(g_info_time)-1);
            }
            update_info_panel();
        }
        json_value_free(root);
        return;
    }

    // academies/{academy_id}/devices/{device_id}/update
    snprintf(expect, sizeof(expect), "academies/%s/devices/%s/update", g_academy_id, g_device_id);
    if (strcmp(topic, expect) == 0) {
        const char* json = (const char*)msg->payload;
        printf("[UPDATE] %s\n", json);
        fflush(stdout);
        // Expected example payloads:
        // {"available":true,"version":"1.2.3","notes":"..."}
        // {"available":false}
        return;
    }
}

static void start_mqtt(const char* url, const char* username, const char* password,
                       const char* academy_id, const char* device_id) {
    strncpy(g_academy_id, academy_id ? academy_id : "", sizeof(g_academy_id) - 1);
    strncpy(g_device_id, device_id ? device_id : "", sizeof(g_device_id) - 1);

    mosquitto_lib_init();
    mq = mosquitto_new(NULL, true, NULL);
    if (!mq) return;
    if (username && *username) mosquitto_username_pw_set(mq, username, password ? password : "");
    mosquitto_message_callback_set(mq, on_mqtt_message);
    mosquitto_connect_callback_set(mq, on_mqtt_connect);

    // Parse url (simple): mqtt://host:port (ws/wss will be treated as mqtt without WS)
    const char* p = strstr(url, "://");
    char scheme[8] = {0};
    const char* host = url;
    int port = 1883;
    if (p) {
        size_t slen = (size_t)(p - url);
        if (slen >= sizeof(scheme)) slen = sizeof(scheme) - 1;
        memcpy(scheme, url, slen);
        for (size_t i = 0; i < slen; ++i) { if (scheme[i] >= 'A' && scheme[i] <= 'Z') scheme[i] += 32; }
        host = p + 3;
    }
    const char* colon = strrchr(host, ':');
    char hostbuf[256];
    if (colon) {
        size_t hlen = (size_t)(colon - host);
        if (hlen >= sizeof(hostbuf)) hlen = sizeof(hostbuf) - 1;
        memcpy(hostbuf, host, hlen); hostbuf[hlen] = '\0';
        port = atoi(colon + 1);
        host = hostbuf;
    }
    // Map ws/wss to mqtt default ports (note: libmosquitto is not a WS client)
    if (scheme[0]) {
        if (strcmp(scheme, "wss") == 0) {
            if (!colon) port = 8883; // typical TLS port, but we use plain MQTT unless configured otherwise
        } else if (strcmp(scheme, "ws") == 0) {
            if (!colon) port = 1883;
        } else if (strcmp(scheme, "mqtts") == 0) {
            if (!colon) port = 8883; // no TLS config here; prefer mqtt:// or provide local broker
        }
    }

    // Connect
    mosquitto_connect(mq, host, port, 30);

    // Subscribe
    char topic[256];
    snprintf(topic, sizeof(topic), "academies/%s/devices/%s/students_today", g_academy_id, g_device_id);
    mosquitto_subscribe(mq, NULL, topic, 1);
    snprintf(topic, sizeof(topic), "academies/%s/devices/%s/homeworks", g_academy_id, g_device_id);
    mosquitto_subscribe(mq, NULL, topic, 1);
    snprintf(topic, sizeof(topic), "academies/%s/devices/%s/student_info", g_academy_id, g_device_id);
    mosquitto_subscribe(mq, NULL, topic, 1);
    snprintf(topic, sizeof(topic), "academies/%s/devices/%s/update", g_academy_id, g_device_id);
    mosquitto_subscribe(mq, NULL, topic, 1);
}

// Publish: request update check (used by settings UI)
void publish_check_update(void) {
    if (!mq || !g_academy_id[0] || !g_device_id[0]) return;
    char topic[256];
    snprintf(topic, sizeof(topic), "academies/%s/devices/%s/command", g_academy_id, g_device_id);
    const char* payload = "{\"action\":\"check_update\"}";
    mosquitto_publish(mq, NULL, topic, (int)strlen(payload), payload, 1, false);
    printf("Published check_update command\n");
    fflush(stdout);
}

int main(void) {
    lv_init();

    // Create SDL-backed display and input devices (provided by LVGL's SDL driver)
    // M5Core2: 320x240 (landscape)
    disp = lv_sdl_window_create(320, 240);
#if defined(_WIN32)
    {
        char cwd[MAX_PATH];
        _getcwd(cwd, sizeof(cwd));
        printf("CWD: %s\n", cwd);
        // Try to chdir to simulator/lvgl if not already, so S:/assets resolves to local path
        if (strstr(cwd, "simulator\\lvgl") == NULL) {
            _chdir("C:/Users/harry/Yggdrasill/simulator/lvgl");
            _getcwd(cwd, sizeof(cwd));
            printf("Switched CWD: %s\n", cwd);
        }
    }
#endif
    mouse = lv_sdl_mouse_create();
    // screensaver module
    screensaver_init(60000);  // 1분 (60초)
    screensaver_attach_activity(lv_scr_act());
    kb = lv_sdl_keyboard_create();

    create_student_list_ui();

    // MQTT connect (env-driven)
    // Use plain MQTT by default. Example: mqtt://localhost:1883
    const char* url = getenv_or_default("BROKER_URL", "mqtt://localhost:1883");
    const char* user = getenv_or_default("MQTT_USERNAME", "");
    const char* pass = getenv_or_default("MQTT_PASSWORD", "");
    const char* academy = getenv_or_default("ACADEMY_ID", "test-academy");
    const char* device = getenv_or_default("DEVICE_ID", "m5-001");
    start_mqtt(url, user, pass, academy, device);

    // Mosquitto network loop in a simple non-blocking way + midnight rollover timer
    while (1) {
        mosquitto_loop(mq, 0, 1);
        lv_timer_handler();
        lv_tick_inc(5);
#if defined(_WIN32)
        Sleep(5);
#else
        usleep(5000);
#endif
        // screensaver module polling
        screensaver_poll();
        // At local midnight(+5s) trigger list_today once
        static int last_day = -1;
        time_t now = time(NULL);
        struct tm lt;
#if defined(_WIN32)
        localtime_s(&lt, &now);
#else
        localtime_r(&now, &lt);
#endif
        if (last_day == -1) last_day = lt.tm_mday;
        if (lt.tm_mday != last_day && lt.tm_hour == 0 && lt.tm_min == 0 && lt.tm_sec >= 5) {
            last_day = lt.tm_mday;
            publish_presence_and_list_today();
        }
    }
    return 0;
}

/* Event: student card clicked → bind */
void student_card_event_cb(lv_event_t* e) {
    lv_event_code_t code = lv_event_get_code(e);
    void* ud = lv_event_get_user_data(e);
    if (!ud) return;
    if (code == LV_EVENT_CLICKED) {
        const char* student_id = (const char*)ud;
        if (!mq || !student_id || !*student_id) return;
        // remember currently bound student locally and clear info (will be populated on list_today/homeworks)
        memset(g_bound_student_id, 0, sizeof(g_bound_student_id));
        strncpy(g_bound_student_id, student_id, sizeof(g_bound_student_id) - 1);
        memset(g_info_name, 0, sizeof(g_info_name));
        memset(g_info_course, 0, sizeof(g_info_course));
        memset(g_info_grade, 0, sizeof(g_info_grade));
        memset(g_info_time, 0, sizeof(g_info_time));
        update_info_panel();
        char topic[256];
        snprintf(topic, sizeof(topic), "academies/%s/devices/%s/command", g_academy_id, g_device_id);
        char payload[256];
        snprintf(payload, sizeof(payload), "{\"action\":\"bind\",\"student_id\":\"%s\"}", student_id);
        mosquitto_publish(mq, NULL, topic, (int)strlen(payload), payload, 1, false);

        // switch to homeworks UI (pager) and fetch student info
        build_homeworks_ui();
        // fetch student info for info_panel
        snprintf(topic, sizeof(topic), "academies/%s/devices/%s/command", g_academy_id, g_device_id);
        snprintf(payload, sizeof(payload), "{\"action\":\"student_info\",\"student_id\":\"%s\"}", student_id);
        mosquitto_publish(mq, NULL, topic, (int)strlen(payload), payload, 1, false);
    }
}

/* Event: homework card clicked → emulate 'A' button behavior via MQTT commands */
static void send_hw_command(const char* academy_id, const char* device_id, const char* action, const char* item_id) {
    if (!mq || !academy_id || !device_id || !action) return;
    char topic[256];
    snprintf(topic, sizeof(topic), "academies/%s/students/%s/homework/%s/command", g_academy_id, "", item_id ? item_id : "");
}

void homework_card_event_cb(lv_event_t* e) {
    lv_event_code_t code = lv_event_get_code(e);
    void* ud = lv_event_get_user_data(e);
    if (code != LV_EVENT_CLICKED || !ud) return;
    HwEventData* ed = (HwEventData*)ud;
    if (!ed->item_id || !*ed->item_id) return;
    if (!g_bound_student_id[0]) return; // no bound student → ignore

    // A 버튼의 규칙
    // 1) 대기(1) → 수행(start)
    // 2) 수행(2) → 제출(submit)
    //    (다른 과제 선택 시에는 서버 RPC가 기존 과제를 대기, 새 과제를 수행으로 전환함)
    // 3) 확인(4) → 대기(wait)
    const char* action = NULL;
    if (ed->phase == 1) action = "start";
    else if (ed->phase == 2) action = "submit";
    else if (ed->phase == 4) action = "wait";
    else return; // 제출(3) 등에서는 무시

    // publish command as gateway expects
    char topic[256];
    snprintf(topic, sizeof(topic), "academies/%s/students/%s/homework/%s/command", g_academy_id, g_bound_student_id, ed->item_id);

    char idem[37]; generate_uuid_v4(idem);
    char ts[32]; now_iso8601(ts, sizeof(ts));
    char payload[512];
    snprintf(payload, sizeof(payload),
             "{\"action\":\"%s\",\"academy_id\":\"%s\",\"student_id\":\"%s\",\"item_id\":\"%s\",\"idempotency_key\":\"%s\",\"at\":\"%s\"}",
             action, g_academy_id, g_bound_student_id, ed->item_id, idem, ts);
    mosquitto_publish(mq, NULL, topic, (int)strlen(payload), payload, 1, false);
}

/* Event: FAB pause_all */
void fab_pause_all_event_cb(lv_event_t* e) {
    (void)e;
    if (!mq || !g_bound_student_id[0]) return;
    char topic[256];
    snprintf(topic, sizeof(topic), "academies/%s/students/%s/homework/ALL/command", g_academy_id, g_bound_student_id);
    char idem[37]; generate_uuid_v4(idem);
    char ts[32]; now_iso8601(ts, sizeof(ts));
    char payload[256];
    snprintf(payload, sizeof(payload), "{\"action\":\"pause_all\",\"academy_id\":\"%s\",\"student_id\":\"%s\",\"item_id\":\"ALL\",\"idempotency_key\":\"%s\",\"at\":\"%s\"}", g_academy_id, g_bound_student_id, idem, ts);
    mosquitto_publish(mq, NULL, topic, (int)strlen(payload), payload, 1, false);
}

void unbind_event_cb(lv_event_t* e) {
    (void)e;
    if (!mq || !g_bound_student_id[0]) return;
    char topic[256];
    snprintf(topic, sizeof(topic), "academies/%s/devices/%s/command", g_academy_id, g_device_id);
    const char* payload = "{\"action\":\"unbind\"}";
    mosquitto_publish(mq, NULL, topic, (int)strlen(payload), payload, 1, false);
    // reset local state
    g_bound_student_id[0] = '\0';
    memset(g_info_name, 0, sizeof(g_info_name));
    memset(g_info_course, 0, sizeof(g_info_course));
    memset(g_info_grade, 0, sizeof(g_info_grade));
    memset(g_info_time, 0, sizeof(g_info_time));
    
    // Restart app after unbind (clean state)
    printf("Unbind complete - restarting app...\n");
    fflush(stdout);
    exit(0);  // Clean exit - OS will restart if configured
}

// screensaver-related helpers removed (all moved to screensaver.c)

void ui_before_screen_change(void) {
    settings_ui_close();
}

static void volume_slider_cb(lv_event_t* e) {
    lv_obj_t* slider = lv_event_get_target(e);
    g_current_volume = (uint8_t)lv_slider_get_value(slider);
    printf("Volume changed: %d\n", g_current_volume);
    // TODO: M5.Axp.SetSpkVolume(g_current_volume * 255 / 100);
}

static void close_volume_popup(void) {
    if (g_volume_popup) {
        lv_obj_del(g_volume_popup);
        g_volume_popup = NULL;
    }
}

static void volume_popup_close_cb(lv_event_t* e) {
    (void)e;
    close_volume_popup();
}

static void show_volume_popup(void) {
    if (g_volume_popup) return;
    
    // Semi-transparent overlay
    g_volume_popup = lv_obj_create(lv_scr_act());
    lv_obj_set_size(g_volume_popup, 280, 150);
    lv_obj_center(g_volume_popup);
    lv_obj_set_style_bg_color(g_volume_popup, lv_color_hex(0x1C1C1C), 0);
    lv_obj_set_style_bg_opa(g_volume_popup, LV_OPA_90, 0);
    lv_obj_set_style_border_color(g_volume_popup, lv_color_hex(0x404040), 0);
    lv_obj_set_style_border_width(g_volume_popup, 1, 0);
    lv_obj_set_style_radius(g_volume_popup, 12, 0);
    lv_obj_set_style_pad_all(g_volume_popup, 20, 0);
    
    // Title
    lv_obj_t* title = lv_label_create(g_volume_popup);
    lv_obj_set_style_text_font(title, font22 ? font22 : font20, 0);
    lv_obj_set_style_text_color(title, lv_color_hex(0xFFFFFF), 0);
    lv_label_set_text(title, "음량 조절");
    lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 0);
    
    // Volume slider
    lv_obj_t* slider = lv_slider_create(g_volume_popup);
    lv_obj_set_width(slider, lv_pct(90));
    lv_slider_set_range(slider, 0, 100);
    lv_slider_set_value(slider, g_current_volume, LV_ANIM_OFF);
    lv_obj_align(slider, LV_ALIGN_CENTER, 0, 0);
    lv_obj_set_style_bg_color(slider, lv_color_hex(0x404040), LV_PART_MAIN);
    lv_obj_set_style_bg_color(slider, lv_color_hex(0x1E88E5), LV_PART_INDICATOR);
    lv_obj_set_style_bg_color(slider, lv_color_hex(0x1E88E5), LV_PART_KNOB);
    lv_obj_add_event_cb(slider, volume_slider_cb, LV_EVENT_VALUE_CHANGED, NULL);
    
    // Close button
    lv_obj_t* close_btn = lv_btn_create(g_volume_popup);
    lv_obj_set_size(close_btn, lv_pct(60), 32);
    lv_obj_set_style_bg_color(close_btn, lv_color_hex(0x2C2C2C), 0);
    lv_obj_set_style_radius(close_btn, 16, 0);
    lv_obj_align(close_btn, LV_ALIGN_BOTTOM_MID, 0, 0);
    lv_obj_t* close_lbl = lv_label_create(close_btn);
    lv_obj_set_style_text_font(close_lbl, font20 ? font20 : font22, 0);
    lv_label_set_text(close_lbl, "닫기");
    lv_obj_center(close_lbl);
    lv_obj_add_event_cb(close_btn, volume_popup_close_cb, LV_EVENT_CLICKED, NULL);
}

void toggle_bottom_sheet(void) {
    if (!g_bottom_sheet || !g_bottom_handle) return;
    
    lv_anim_t sheet_anim;
    lv_anim_init(&sheet_anim);
    lv_anim_set_var(&sheet_anim, g_bottom_sheet);
    lv_anim_set_time(&sheet_anim, 300);
    lv_anim_set_path_cb(&sheet_anim, lv_anim_path_ease_out);
    lv_anim_set_exec_cb(&sheet_anim, (lv_anim_exec_xcb_t)lv_obj_set_y);
    
    lv_anim_t handle_anim;
    lv_anim_init(&handle_anim);
    lv_anim_set_var(&handle_anim, g_bottom_handle);
    lv_anim_set_time(&handle_anim, 300);
    lv_anim_set_path_cb(&handle_anim, lv_anim_path_ease_out);
    lv_anim_set_exec_cb(&handle_anim, (lv_anim_exec_xcb_t)lv_obj_set_y);
    
    if (g_bottom_sheet_open) {
        // Close: move down
        lv_anim_set_values(&sheet_anim, 140, 240);
        lv_anim_set_values(&handle_anim, 116, 216);
        g_bottom_sheet_open = false;
    } else {
        // Open: move up
        lv_anim_set_values(&sheet_anim, 240, 140);
        lv_anim_set_values(&handle_anim, 216, 116);
        g_bottom_sheet_open = true;
    }
    
    lv_anim_start(&sheet_anim);
    lv_anim_start(&handle_anim);
}

static void handle_drag_cb(lv_event_t* e) {
    (void)e;
    toggle_bottom_sheet();
}

static void goto_home_page(void) {
    // Close volume popup if open
    close_volume_popup();
    // Close bottom sheet
    if (g_bottom_sheet_open) {
        toggle_bottom_sheet();
    }
    
    // Scroll to homeworks page (middle)
    if (pages) {
        uint32_t child_cnt = lv_obj_get_child_cnt(pages);
        if (child_cnt >= 2) {
            lv_obj_t* homeworks_page = lv_obj_get_child(pages, 1);  // Index 1 = middle
            if (homeworks_page) {
                lv_obj_scroll_to_view(homeworks_page, LV_ANIM_ON);
            }
        }
    }
}

void volume_btn_cb(lv_event_t* e) {
    (void)e;
    show_volume_popup();
}

void home_btn_cb(lv_event_t* e) {
    (void)e;
    goto_home_page();
}

// Draw volume icon (speaker shape using simple objects)
static void draw_volume_icon(lv_obj_t* parent) {
    // Speaker body (rectangle)
    lv_obj_t* speaker = lv_obj_create(parent);
    lv_obj_set_size(speaker, 8, 12);
    lv_obj_set_pos(speaker, 12, 14);
    lv_obj_set_style_bg_color(speaker, lv_color_hex(0xE8E8E8), 0);
    lv_obj_set_style_border_width(speaker, 0, 0);
    lv_obj_set_style_radius(speaker, 1, 0);
    
    // Speaker cone (triangle-like)
    lv_obj_t* cone = lv_obj_create(parent);
    lv_obj_set_size(cone, 6, 16);
    lv_obj_set_pos(cone, 20, 12);
    lv_obj_set_style_bg_color(cone, lv_color_hex(0xE8E8E8), 0);
    lv_obj_set_style_border_width(cone, 0, 0);
    lv_obj_set_style_radius(cone, 0, 0);
    
    // Sound waves
    for (int i = 0; i < 2; i++) {
        lv_obj_t* wave = lv_obj_create(parent);
        lv_obj_set_size(wave, 2, 6 + i * 4);
        lv_obj_set_pos(wave, 28 + i * 4, 17 - i * 2);
        lv_obj_set_style_bg_color(wave, lv_color_hex(0xE8E8E8), 0);
        lv_obj_set_style_border_width(wave, 0, 0);
        lv_obj_set_style_radius(wave, 1, 0);
    }
}

// Draw home icon (house shape using simple objects)
static void draw_home_icon(lv_obj_t* parent) {
    // Roof (triangle using rotated square)
    lv_obj_t* roof = lv_obj_create(parent);
    lv_obj_set_size(roof, 20, 12);
    lv_obj_set_pos(roof, 15, 10);
    lv_obj_set_style_bg_color(roof, lv_color_hex(0xE8E8E8), 0);
    lv_obj_set_style_border_width(roof, 0, 0);
    lv_obj_set_style_radius(roof, 2, 0);
    
    // House body
    lv_obj_t* body = lv_obj_create(parent);
    lv_obj_set_size(body, 16, 14);
    lv_obj_set_pos(body, 17, 20);
    lv_obj_set_style_bg_color(body, lv_color_hex(0xE8E8E8), 0);
    lv_obj_set_style_border_width(body, 0, 0);
    lv_obj_set_style_radius(body, 2, 0);
    
    // Door
    lv_obj_t* door = lv_obj_create(parent);
    lv_obj_set_size(door, 6, 8);
    lv_obj_set_pos(door, 22, 26);
    lv_obj_set_style_bg_color(door, lv_color_hex(0x2C2C2C), 0);
    lv_obj_set_style_border_width(door, 0, 0);
    lv_obj_set_style_radius(door, 1, 0);
}

void settings_event_cb(lv_event_t* e) {
    (void)e;
    printf("Settings button clicked - calling settings_ui_show\n");
    fflush(stdout);
    settings_ui_show(stage, pages, g_fab, g_bottom_sheet, g_bottom_handle,
                     font26, font20, APP_VERSION,
                     &wifi_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48,
                     &refresh_50dp_E3E3E3_FILL0_wght400_GRAD0_opsz48);
    printf("settings_ui_show returned\n");
    fflush(stdout);
}