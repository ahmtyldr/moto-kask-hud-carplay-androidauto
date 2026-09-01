/*
 * livi-statusui — LVGL idle screen for the headless LIVI appliance.
 *
 * Draws directly on KMS/DRM: a spinner, a title ("Cihaz bekleniyor") and one
 * line of secondary status. It owns the display ONLY while no projection
 * session runs; the Node side (statusUi.ts) spawns it at boot, SIGTERMs it the
 * moment video starts — exiting releases the DRM master, which is all kmssink
 * needs — and spawns it again when the phone disconnects.
 *
 * Control protocol, newline-delimited on stdin:
 *     title <text>   replace the big label
 *     msg <text>     replace the secondary line (BT pairing code etc.)
 *     quit           exit
 * EOF on stdin (the Node parent died) also exits: the screen must never
 * outlive the process that would have killed it.
 *
 * Built-in Montserrat fonts cover ASCII only — default strings avoid Turkish
 * glyphs on purpose. See README.md for generating a full Turkish font with
 * lv_font_conv.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <xf86drm.h>
#include <xf86drmMode.h>

#include "lvgl.h"

static volatile sig_atomic_t quit_flag = 0;

/*
 * _exit, not a flag: lv_timer_handler can block inside the DRM page-flip wait
 * (seen in the field — systemd had to SIGKILL after the 90 s stop timeout), and
 * a flag only helps if the loop comes back around. There is nothing to unwind:
 * exiting releases the DRM master, which is the entire cleanup.
 */
static void on_signal(int sig)
{
  (void)sig;
  quit_flag = 1;
  _exit(0);
}

static uint32_t tick_ms(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

/*
 * On a Pi the display device is not always card0: vc4 (KMS) and v3d (render
 * only) enumerate in either order depending on kernel/firmware. Probe for the
 * card that actually has a connected connector with modes instead of guessing.
 */
static const char* find_drm_card(void)
{
  static char path[32];
  const char* from_env = getenv("LIVI_DRM_DEVICE");
  if (from_env && *from_env) return from_env;

  for (int i = 0; i < 8; i++) {
    snprintf(path, sizeof(path), "/dev/dri/card%d", i);
    int fd = open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) continue;
    int ok = 0;
    drmModeRes* res = drmModeGetResources(fd);
    if (res) {
      for (int c = 0; c < res->count_connectors && !ok; c++) {
        drmModeConnector* conn = drmModeGetConnector(fd, res->connectors[c]);
        if (conn) {
          if (conn->connection == DRM_MODE_CONNECTED && conn->count_modes > 0) ok = 1;
          drmModeFreeConnector(conn);
        }
      }
      drmModeFreeResources(res);
    }
    close(fd);
    if (ok) return path;
  }
  return NULL;
}

static lv_obj_t* title_label;
static lv_obj_t* msg_label;

static void build_ui(void)
{
  lv_obj_t* scr = lv_screen_active();
  lv_obj_set_style_bg_color(scr, lv_color_black(), 0);

  lv_obj_t* spinner = lv_spinner_create(scr);
  lv_spinner_set_anim_params(spinner, 1200, 200);
  lv_obj_set_size(spinner, 96, 96);
  lv_obj_align(spinner, LV_ALIGN_CENTER, 0, -60);

  title_label = lv_label_create(scr);
  lv_label_set_text(title_label, "Cihaz bekleniyor");
  lv_obj_set_style_text_color(title_label, lv_color_white(), 0);
  lv_obj_set_style_text_font(title_label, &lv_font_montserrat_28, 0);
  lv_obj_align(title_label, LV_ALIGN_CENTER, 0, 30);

  msg_label = lv_label_create(scr);
  lv_label_set_text(msg_label, "USB / Kablosuz baglanti hazir");
  lv_obj_set_style_text_color(msg_label, lv_color_hex(0x808080), 0);
  lv_obj_set_style_text_font(msg_label, &lv_font_montserrat_16, 0);
  lv_obj_align(msg_label, LV_ALIGN_CENTER, 0, 70);
}

/* Accumulates stdin into a line buffer; returns 1 while stdin is still open. */
static int handle_stdin(void)
{
  static char buf[512];
  static size_t len = 0;
  char chunk[256];

  for (;;) {
    ssize_t n = read(STDIN_FILENO, chunk, sizeof(chunk));
    if (n == 0) return 0; /* EOF: parent is gone */
    if (n < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK) return 1;
      return 0;
    }
    for (ssize_t i = 0; i < n; i++) {
      if (chunk[i] != '\n') {
        if (len < sizeof(buf) - 1) buf[len++] = chunk[i];
        continue;
      }
      buf[len] = '\0';
      len = 0;
      if (!strncmp(buf, "title ", 6)) {
        lv_label_set_text(title_label, buf + 6);
        lv_obj_align(title_label, LV_ALIGN_CENTER, 0, 30);
      } else if (!strncmp(buf, "msg ", 4)) {
        lv_label_set_text(msg_label, buf + 4);
        lv_obj_align(msg_label, LV_ALIGN_CENTER, 0, 70);
      } else if (!strcmp(buf, "quit")) {
        return 0;
      }
    }
  }
}

int main(void)
{
  signal(SIGTERM, on_signal);
  signal(SIGINT, on_signal);
  signal(SIGPIPE, SIG_IGN);
  fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);

  const char* card = find_drm_card();
  if (!card) {
    fprintf(stderr, "[statusui] no connected DRM display found\n");
    return 1;
  }

  lv_init();
  lv_tick_set_cb(tick_ms);

  lv_display_t* disp = lv_linux_drm_create();
  if (!disp) {
    fprintf(stderr, "[statusui] lv_linux_drm_create failed\n");
    return 1;
  }
  lv_linux_drm_set_file(disp, card, -1);

  build_ui();
  fprintf(stderr, "[statusui] up on %s\n", card);

  while (!quit_flag) {
    if (!handle_stdin()) break;
    lv_timer_handler();
    usleep(5000);
  }

  /* Exiting releases the DRM master; nothing else to unwind. */
  return 0;
}
