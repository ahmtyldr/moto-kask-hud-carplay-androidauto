/*
 * Minimal LVGL config for livi-statusui. Everything not set here falls back to
 * the defaults in lvgl's lv_conf_internal.h — only the deltas live here.
 */
#ifndef LV_CONF_H
#define LV_CONF_H

/* DRM dumb buffers are XRGB8888 */
#define LV_COLOR_DEPTH 32

/* The whole point: render straight to KMS/DRM, no compositor */
#define LV_USE_LINUX_DRM 1

/* Fonts used by main.c (ASCII coverage only — see README for Turkish glyphs) */
#define LV_FONT_MONTSERRAT_16 1
#define LV_FONT_MONTSERRAT_28 1

/* Idle screen on a 1 GHz quad A53: keep the tick cheap, no perf monitor */
#define LV_USE_PERF_MONITOR 0
#define LV_USE_MEM_MONITOR 0

#endif /* LV_CONF_H */
