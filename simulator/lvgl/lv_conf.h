#ifndef LV_CONF_H
#define LV_CONF_H

#define LV_USE_OS 0
#define LV_COLOR_DEPTH 32
#define LV_COLOR_16_SWAP 0

#define LV_USE_LOG 1
#define LV_LOG_LEVEL LV_LOG_LEVEL_INFO

#define LV_USE_DRAW_SW 1
#define LV_USE_DRAW_PXP 0

#define LV_USE_FONT_DEFAULT 1

#define LV_USE_MSG 0

#define LV_USE_SDL 1
#define LV_SDL_BUF_COUNT 1

/* Image decoders for external assets */
#ifndef LV_USE_PNG
#define LV_USE_PNG 1
#endif

#ifndef LV_USE_SVG
#define LV_USE_SVG 1
#endif

/* Vector renderer for SVG (already linked as lvgl_thorvg) */
#ifndef LV_USE_THORVG
#define LV_USE_THORVG 1
#endif

/* Enable Tiny TTF for runtime TTF loading (Korean glyphs) */
#ifndef LV_USE_TINY_TTF
#define LV_USE_TINY_TTF 1
#endif

/* Enable file support for Tiny TTF (required for lv_tiny_ttf_create_file) */
#ifndef LV_TINY_TTF_FILE_SUPPORT
#define LV_TINY_TTF_FILE_SUPPORT 1
#endif

/* Enable stdio FS so we can open files like S:assets/xxx.ttf or S:C:/Windows/Fonts/... */
#ifndef LV_USE_FS_STDIO
#define LV_USE_FS_STDIO 1
#endif
#ifndef LV_FS_STDIO_LETTER
#define LV_FS_STDIO_LETTER 'S'
#endif

#endif // LV_CONF_H


