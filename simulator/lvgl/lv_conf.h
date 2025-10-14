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

/* Enable Tiny TTF for runtime TTF loading (Korean glyphs) */
#ifndef LV_USE_TINY_TTF
#define LV_USE_TINY_TTF 1
#endif

#endif // LV_CONF_H


