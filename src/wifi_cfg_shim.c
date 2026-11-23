/* C shims for the Pascal app (compiled by build.sh --c with the
 * IDF-recorded flags).
 *
 * 1) WIFI_INIT_CONFIG_DEFAULT is a 26-field designated initializer that
 *    references extern symbols (g_wifi_osi_funcs, and g_wifi_default_wpa_
 *    crypto_funcs copied by value) - not expressible as a Pascal constant
 *    or blob (pointer members would need link-time relocations). This
 *    shim materializes it once at runtime and hands out the pointer.
 *
 * 2) nvs_flash's C++ objects (nvs_page.cpp) reference exactly three
 *    libstdc++ symbols: operator new[](size, nothrow), operator delete[],
 *    and the std::nothrow object. Instead of linking a whole multilib
 *    libstdc++ into the Pascal image (whole-archive bloat + toolchain
 *    path coupling), provide them here via asm-name aliases forwarding to
 *    malloc/free - allocations then land in the same IDF heap the Pascal
 *    side (idfheap) uses. If a future view pulls real C++ library code
 *    into the closure, replace this with the toolchain libstdc++ link.
 *
 * 3) A non-clickable LVGL touch indicator follows the registered input
 *    device and remains visible briefly after release.
 *
 * 4) Channel utilization meter: promiscuous dwell per 2.4 GHz channel,
 *    airtime accumulation, per-mille store with TTL, and
 *    wa_util_band_rgb (C util_band_color / HSV). LVGL adapter is paused
 *    for each dwell so paint cannot overlap RX on Mosaico MSPI. */
#include <stdlib.h>
#include <string.h>
#include "esp_wifi.h"
#include "esp_wifi_he_types.h"
#include "esp_timer.h"
#include "esp_log.h"
#include "esp_lv_adapter.h"
#include "lvgl.h"
#include "src/display/lv_display_private.h"
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

static void wa_console_flush_task(void *arg)
{
    (void)arg;
    while (true) {
        (void)fflush(stdout);
        vTaskDelay(pdMS_TO_TICKS(250));
    }
}

void wa_console_flush_start(void)
{
    static bool started;
    if (!started) {
        started = true;
        (void)xTaskCreate(wa_console_flush_task, "wa_flush",
                          2048, NULL, 1, NULL);
    }
}

const wifi_init_config_t *wifi_default_init_config(void)
{
    static wifi_init_config_t cfg;
    static int done;

    if (!done) {
        cfg = (wifi_init_config_t)WIFI_INIT_CONFIG_DEFAULT();
        done = 1;
    }

    return &cfg;
}

static lv_indev_t *wa_touch_indev;
static lv_obj_t *wa_touch_dot;
static uint32_t wa_touch_last;
static bool wa_touch_seen;

/* --- UI-First Preemptive MSPI / Sniffer Exclusivity ---
 * Instead of pausing LVGL during channel dwells, LVGL runs continuously
 * and preempts any in-progress promiscuous dwell as soon as touch or
 * display invalidation/refresh occurs. */
static SemaphoreHandle_t s_mspi_sem;
static SemaphoreHandle_t s_abort_sem;
static volatile int s_ui_want_bus;
static bool s_ui_has_bus;

void wa_ui_bus_acquire(void)
{
    s_ui_want_bus = 1;
    __sync_synchronize();
    if (!s_ui_has_bus) {
        if (s_abort_sem != NULL) {
            xSemaphoreGive(s_abort_sem);
        }
        if (s_mspi_sem != NULL) {
            xSemaphoreTake(s_mspi_sem, portMAX_DELAY);
        }
        s_ui_has_bus = true;
    }
}

static void wa_ui_bus_release_if_idle(lv_display_t *disp)
{
    if (!s_ui_has_bus) {
        return;
    }
    if (wa_touch_indev != NULL &&
        lv_indev_get_state(wa_touch_indev) == LV_INDEV_STATE_PRESSED) {
        return;
    }
    if (disp == NULL) {
        disp = lv_display_get_default();
    }
    if (disp != NULL &&
        (disp->inv_p > 0 || disp->rendering_in_progress || disp->flushing)) {
        return;
    }
    s_ui_has_bus = false;
    s_ui_want_bus = 0;
    __sync_synchronize();
    if (s_mspi_sem != NULL) {
        xSemaphoreGive(s_mspi_sem);
    }
}

void wa_ui_wait_idle(int timeout_ms)
{
    int waited = 0;
    while (s_ui_want_bus && waited < timeout_ms) {
        vTaskDelay(pdMS_TO_TICKS(5));
        waited += 5;
    }
}

static void wa_wait_disp_flush_done(lv_display_t *disp)
{
    if (disp == NULL || !disp->flushing) {
        return;
    }
    int64_t t0 = esp_timer_get_time();
    while (disp->flushing) {
        int64_t elapsed_us = esp_timer_get_time() - t0;
        if (elapsed_us < 1500) {
            taskYIELD();
        } else if (elapsed_us < 50000) {
            vTaskDelay(1);
        } else {
            ESP_LOGW("wa-ui", "flush wait timeout (>50 ms)");
            break;
        }
    }
}

/* --- LVGL & LCD DMA Timing Profiler --- */
static int64_t s_prof_refr_start_us;
static int64_t s_prof_render_start_us;
static int64_t s_prof_flush_start_us;
static int64_t s_prof_wait_start_us;
static int64_t s_prof_wait_sum_us;
static int64_t s_prof_flush_call_sum_us;
static uint32_t s_prof_flush_cnt;
static uint32_t s_prof_total_px;
static int32_t s_prof_x1, s_prof_y1, s_prof_x2, s_prof_y2;

static void wa_prof_disp_cb(lv_event_t *e)
{
    lv_event_code_t code = lv_event_get_code(e);
    lv_display_t *disp = (lv_display_t *)lv_event_get_target(e);
    int64_t now = esp_timer_get_time();

    switch (code) {
    case LV_EVENT_INVALIDATE_AREA:
        wa_ui_bus_acquire();
        break;
    case LV_EVENT_REFR_START:
        wa_ui_bus_acquire();
        s_prof_refr_start_us = now;
        s_prof_wait_sum_us = 0;
        s_prof_flush_call_sum_us = 0;
        s_prof_flush_cnt = 0;
        s_prof_total_px = 0;
        break;
    case LV_EVENT_RENDER_START:
        s_prof_render_start_us = now;
        break;
    case LV_EVENT_FLUSH_WAIT_START:
        s_prof_wait_start_us = now;
        break;
    case LV_EVENT_FLUSH_WAIT_FINISH:
        if (s_prof_wait_start_us > 0) {
            s_prof_wait_sum_us += (now - s_prof_wait_start_us);
        }
        break;
    case LV_EVENT_FLUSH_START: {
        s_prof_flush_start_us = now;
        const lv_area_t *a = (const lv_area_t *)lv_event_get_param(e);
        if (a) {
            int32_t w = a->x2 - a->x1 + 1;
            int32_t h = a->y2 - a->y1 + 1;
            s_prof_total_px += (uint32_t)(w * h);
            if (s_prof_flush_cnt == 0) {
                s_prof_x1 = a->x1;
                s_prof_y1 = a->y1;
            }
            s_prof_x2 = a->x2;
            s_prof_y2 = a->y2;
        }
        s_prof_flush_cnt++;
        break;
    }
    case LV_EVENT_FLUSH_FINISH:
        s_prof_flush_call_sum_us += (now - s_prof_flush_start_us);
        break;
    case LV_EVENT_RENDER_READY: {
        int64_t render_ready_us = now;
        int64_t dma_tail_start = esp_timer_get_time();
        wa_wait_disp_flush_done(disp);
        int64_t dma_done_us = esp_timer_get_time();
        int64_t last_dma_us = dma_done_us - s_prof_flush_start_us;
        int64_t tail_after_render_ready_us = dma_done_us - dma_tail_start;
        int64_t layout_us = s_prof_render_start_us - s_prof_refr_start_us;
        int64_t render_total_us = render_ready_us - s_prof_render_start_us;
        int64_t sw_draw_only_us = render_total_us - s_prof_wait_sum_us - s_prof_flush_call_sum_us;

        if (s_prof_total_px > 0) {
            printf("PROF-FRAME: area=(%ld,%ld..%ld,%ld) px=%lu flushes=%lu | "
                   "layout=%lld us | render_start->ready=%lld us (sw_draw=%lld us, dma_wait=%lld us, flush_cb=%lld us) | "
                   "last_dma_tx=%lld us (tail_after_ready=%lld us) | total_refr_to_dma_done=%lld us\n",
                   (long)s_prof_x1, (long)s_prof_y1, (long)s_prof_x2, (long)s_prof_y2,
                   (unsigned long)s_prof_total_px, (unsigned long)s_prof_flush_cnt,
                   (long long)layout_us,
                   (long long)render_total_us,
                   (long long)sw_draw_only_us,
                   (long long)s_prof_wait_sum_us,
                   (long long)s_prof_flush_call_sum_us,
                   (long long)last_dma_us,
                   (long long)tail_after_render_ready_us,
                   (long long)(dma_done_us - s_prof_refr_start_us));
        }
        break;
    }
    case LV_EVENT_REFR_READY:
        wa_wait_disp_flush_done(disp);
        wa_ui_bus_release_if_idle(disp);
        break;
    default:
        break;
    }
}

static void wa_co5300_rounder_cb(lv_area_t *area, void *user_data)
{
    (void)user_data;
    /* CO5300 CASET/RASET require 2-pixel alignment (even start, odd end). */
    area->x1 &= ~1;
    area->y1 &= ~1;
    area->x2 |= 1;
    area->y2 |= 1;
}

/* --- Canvas Gesture Recognizer (Swipes, Continuous Drag, Double Tap) --- */
enum {
    WA_GESTURE_NONE        = 0,
    WA_GESTURE_SWIPE_LEFT  = 1,
    WA_GESTURE_SWIPE_RIGHT = 2,
    WA_GESTURE_SWIPE_UP    = 3,
    WA_GESTURE_SWIPE_DOWN  = 4,
    WA_GESTURE_DRAG_BEGIN  = 5,
    WA_GESTURE_DRAG_MOVE   = 6,
    WA_GESTURE_DRAG_END    = 7,
    WA_GESTURE_DOUBLE_TAP  = 8,
};

#define WA_EDGE_X_MARGIN_PX    100
#define WA_SWIPE_MIN_DIST_PX    42
#define WA_DRAG_MIN_DIST_PX     10
#define WA_DRAG_STEP_MIN_PX      4
#define WA_TAP_MAX_DIST_PX      16
#define WA_TAP_MAX_TIME_MS     280
#define WA_DBLTAP_MAX_TIME_MS  400
#define WA_DBLTAP_MAX_DIST_PX   40

typedef void (*wa_gesture_cb_t)(int32_t gtype, int32_t x, int32_t y, int32_t dx, int32_t dy);

static lv_obj_t *s_gesture_obj;
static wa_gesture_cb_t s_gesture_cb;
static int32_t s_g_start_x, s_g_start_y;
static int32_t s_g_last_x, s_g_last_y;
static uint32_t s_g_press_ms;
static bool s_g_was_pressed;
static bool s_g_dragging;
static bool s_g_swiped;
static bool s_g_ignore;
static bool s_g_edge_left;
static bool s_g_edge_right;
static int32_t s_g_active_view;
static int32_t s_g_panel_open;
static uint32_t s_g_last_tap_ms;
static int32_t s_g_last_tap_x, s_g_last_tap_y;

void wa_gesture_set_state(int32_t active_view, int32_t panel_open)
{
    s_g_active_view = active_view;
    s_g_panel_open = panel_open;
}

static int32_t wa_iabs(int32_t v)
{
    return v < 0 ? -v : v;
}

static void wa_process_touch_gesture(bool pressed, const lv_point_t *pt)
{
    if (s_gesture_cb == NULL) {
        return;
    }

    if (pressed && !s_g_was_pressed) {
        s_g_was_pressed = true;
        s_g_start_x = pt->x;
        s_g_start_y = pt->y;
        s_g_last_x = pt->x;
        s_g_last_y = pt->y;
        s_g_press_ms = lv_tick_get();
        s_g_dragging = false;
        s_g_swiped = false;
        /* Ignore touches that start directly on the top-right CH/HIST buttons,
         * or inside the open Quick Action panel (so its buttons can be clicked). */
        s_g_ignore = (pt->y < 44 && pt->x >= 330) ||
                     (s_g_panel_open != 0 && pt->y >= 44 && pt->y <= 182);
        s_g_edge_left = (pt->x < WA_EDGE_X_MARGIN_PX) || (s_g_active_view != 0);
        s_g_edge_right = (pt->x >= 480 - WA_EDGE_X_MARGIN_PX) || (s_g_active_view != 0);
        return;
    }

    if (pressed && s_g_was_pressed) {
        if (s_g_ignore || s_g_swiped) {
            return;
        }
        int32_t dx = pt->x - s_g_start_x;
        int32_t dy = pt->y - s_g_start_y;
        int32_t adx = wa_iabs(dx);
        int32_t ady = wa_iabs(dy);
        s_g_last_x = pt->x;
        s_g_last_y = pt->y;

        /* 1) Left-edge swipe right -> switch view immediately */
        if (!s_g_dragging && s_g_edge_left && dx >= WA_SWIPE_MIN_DIST_PX &&
            adx * 10 >= ady * 12) {
            s_g_swiped = true;
            s_g_last_tap_ms = 0;
            lv_indev_wait_release(wa_touch_indev);
            s_gesture_cb(WA_GESTURE_SWIPE_RIGHT, pt->x, pt->y, dx, dy);
            return;
        }

        /* 2) Right-edge swipe left -> switch view immediately */
        if (!s_g_dragging && s_g_edge_right && dx <= -WA_SWIPE_MIN_DIST_PX &&
            adx * 10 >= ady * 12) {
            s_g_swiped = true;
            s_g_last_tap_ms = 0;
            lv_indev_wait_release(wa_touch_indev);
            s_gesture_cb(WA_GESTURE_SWIPE_LEFT, pt->x, pt->y, dx, dy);
            return;
        }

        /* 3) Top-to-bottom swipe -> open Quick Action pull-down panel */
        if (!s_g_dragging && s_g_start_y < 180 && dy >= WA_SWIPE_MIN_DIST_PX &&
            ady * 10 >= adx * 13) {
            s_g_swiped = true;
            s_g_last_tap_ms = 0;
            lv_indev_wait_release(wa_touch_indev);
            s_gesture_cb(WA_GESTURE_SWIPE_DOWN, pt->x, pt->y, dx, dy);
            return;
        }

        /* 4) Bottom-to-top swipe -> close Quick Action pull-down panel */
        if (!s_g_dragging && dy <= -WA_SWIPE_MIN_DIST_PX &&
            ady * 10 >= adx * 13) {
            s_g_swiped = true;
            s_g_last_tap_ms = 0;
            lv_indev_wait_release(wa_touch_indev);
            s_gesture_cb(WA_GESTURE_SWIPE_UP, pt->x, pt->y, dx, dy);
            return;
        }

        /* 5) Interior horizontal drag -> scroll channel view */
        if (!s_g_edge_left && !s_g_edge_right && s_g_start_y >= 44) {
            if (!s_g_dragging) {
                if (adx >= WA_DRAG_MIN_DIST_PX && adx * 10 >= ady * 13) {
                    s_g_dragging = true;
                    s_g_last_tap_ms = 0;
                    s_gesture_cb(WA_GESTURE_DRAG_BEGIN, s_g_start_x, s_g_start_y, 0, 0);
                    s_gesture_cb(WA_GESTURE_DRAG_MOVE, pt->x, pt->y, dx, dy);
                }
            } else {
                s_gesture_cb(WA_GESTURE_DRAG_MOVE, pt->x, pt->y, dx, dy);
            }
        }
        return;
    }

    if (!pressed && s_g_was_pressed) {
        s_g_was_pressed = false;
        if (s_g_ignore || s_g_swiped) {
            return;
        }
        int32_t dx = s_g_last_x - s_g_start_x;
        int32_t dy = s_g_last_y - s_g_start_y;
        int32_t adx = wa_iabs(dx);
        int32_t ady = wa_iabs(dy);
        uint32_t elapsed = lv_tick_elaps(s_g_press_ms);

        if (s_g_dragging) {
            s_g_dragging = false;
            s_gesture_cb(WA_GESTURE_DRAG_END, s_g_last_x, s_g_last_y, dx, dy);
            return;
        }

        /* Stationary tap on canvas -> check Double Tap */
        if (s_g_start_y >= 44 && elapsed <= WA_TAP_MAX_TIME_MS &&
            adx <= WA_TAP_MAX_DIST_PX && ady <= WA_TAP_MAX_DIST_PX) {
            uint32_t now_ms = lv_tick_get();
            if (s_g_last_tap_ms != 0 &&
                lv_tick_elaps(s_g_last_tap_ms) <= WA_DBLTAP_MAX_TIME_MS &&
                wa_iabs(s_g_last_x - s_g_last_tap_x) <= WA_DBLTAP_MAX_DIST_PX &&
                wa_iabs(s_g_last_y - s_g_last_tap_y) <= WA_DBLTAP_MAX_DIST_PX) {
                s_g_last_tap_ms = 0;
                s_gesture_cb(WA_GESTURE_DOUBLE_TAP, s_g_last_x, s_g_last_y, 0, 0);
            } else {
                s_g_last_tap_ms = now_ms ? now_ms : 1;
                s_g_last_tap_x = s_g_last_x;
                s_g_last_tap_y = s_g_last_y;
            }
        } else {
            s_g_last_tap_ms = 0;
        }
    }
}

static void wa_indev_event_cb(lv_event_t *e)
{
    lv_event_code_t code = lv_event_get_code(e);
    if (code == LV_EVENT_PRESSED || code == LV_EVENT_PRESSING ||
        code == LV_EVENT_SHORT_CLICKED || code == LV_EVENT_CLICKED) {
        wa_ui_bus_acquire();
    }
}

static void wa_touch_tick(lv_timer_t *timer)
{
    (void)timer;
    lv_point_t p = {0, 0};
    bool pressed = (lv_indev_get_state(wa_touch_indev) == LV_INDEV_STATE_PRESSED);
    if (pressed) {
        wa_ui_bus_acquire();
        lv_indev_get_point(wa_touch_indev, &p);
        lv_obj_set_pos(wa_touch_dot, p.x - 6, p.y - 6);
        lv_obj_set_hidden(wa_touch_dot, false);
        wa_touch_last = lv_tick_get();
        wa_touch_seen = true;
    } else {
        if (wa_touch_seen && lv_tick_elaps(wa_touch_last) >= 500) {
            lv_obj_set_hidden(wa_touch_dot, true);
            wa_touch_seen = false;
        }
    }
    wa_process_touch_gesture(pressed, &p);
    if (!pressed) {
        wa_ui_bus_release_if_idle(NULL);
    }
}

bool wa_touch_indicator_start(lv_indev_t *indev)
{
    if (indev == NULL) {
        return false;
    }
    wa_touch_indev = indev;
    lv_obj_set_scrollable(lv_screen_active(), false);
    wa_touch_dot = lv_obj_create(lv_layer_top());
    if (wa_touch_dot == NULL) {
        return false;
    }
    lv_obj_set_size(wa_touch_dot, 12, 12);
    lv_obj_set_style_radius(wa_touch_dot, 6, 0);
    lv_obj_set_style_border_width(wa_touch_dot, 2, 0);
    lv_obj_set_style_border_color(wa_touch_dot, lv_color_hex(0xffffff), 0);
    lv_obj_set_style_bg_color(wa_touch_dot, lv_color_hex(0x2d6cdf), 0);
    lv_obj_set_style_pad_all(wa_touch_dot, 0, 0);
    lv_obj_set_scrollable(wa_touch_dot, false);
    lv_obj_set_clickable(wa_touch_dot, false);
    lv_obj_set_hidden(wa_touch_dot, true);
    if (lv_timer_create(wa_touch_tick, 15, NULL) == NULL) {
        lv_obj_delete(wa_touch_dot);
        wa_touch_dot = NULL;
        return false;
    }

    lv_indev_add_event_cb(indev, wa_indev_event_cb, LV_EVENT_ALL, NULL);

    lv_display_t *disp = lv_display_get_default();
    if (disp != NULL) {
        (void)esp_lv_adapter_set_area_rounder_cb(disp, wa_co5300_rounder_cb, NULL);
        lv_display_add_event_cb(disp, wa_prof_disp_cb, LV_EVENT_ALL, NULL);
    }
    return true;
}

void wa_gesture_attach(lv_obj_t *target, wa_gesture_cb_t cb)
{
    if (target == NULL || cb == NULL) {
        return;
    }
    s_gesture_obj = target;
    s_gesture_cb = cb;
    lv_obj_set_scrollable(target, false);
}

/* void* operator new[](unsigned int, std::nothrow_t const&) */
void *wa_operator_new_array_nothrow(unsigned int size, const void *nt)
    __asm("_ZnajRKSt9nothrow_t");
void *wa_operator_new_array_nothrow(unsigned int size, const void *nt)
{
    (void)nt;
    return malloc(size);
}

/* void operator delete[](void*) */
void wa_operator_delete_array(void *p) __asm("_ZdaPv");
void wa_operator_delete_array(void *p)
{
    free(p);
}

/* std::nothrow - an empty const object of size 1 */
const char wa_std_nothrow __asm("_ZSt7nothrow") = 0;

/* --- pure-register vibration motor probe (GPIO8, active high) ---
   no gpio driver, no vTaskDelay: busy-wait, works from the first
   Pascal statement. GPIO base 0x20583000 (soc/esp32s31/reg_base.h),
   ENABLE_W1TS +0x38, OUT_W1TS +0x8, OUT_W1TC +0xC. */
#define WA_GPIO_BASE 0x20583000UL

void wa_motor_init(void)
{
    volatile unsigned int *en_w1ts = (unsigned int *)(WA_GPIO_BASE + 0x38);
    *en_w1ts = (1u << 8);
}

void wa_motor_buzz(int n)
{
    volatile unsigned int *w1ts = (unsigned int *)(WA_GPIO_BASE + 0x8);
    volatile unsigned int *w1tc = (unsigned int *)(WA_GPIO_BASE + 0xC);
    volatile unsigned int i;
    int k;
    for (k = 0; k < n; k++) {
        *w1ts = (1u << 8);
        for (i = 0; i < 8000000; i++) { }   /* ~90 ms busy */
        *w1tc = (1u << 8);
        for (i = 0; i < 24000000; i++) { }  /* ~280 ms gap */
    }
}

/* =====================================================================
 * Channel utilization meter (C twin of /mnt/storage/wifi_analyzer
 * util_meter + util_store), adapted for S31 MAC v3 rx_ctrl
 * (esp_wifi_rxctrl_t / cur_bb_format + he_siga*).
 *
 * The RX callback stays entirely in C (WiFi driver task: integer math
 * only). During the sweep the LVGL adapter is paused so PSRAM panel
 * paint/flush cannot overlap promiscuous RX on the Mosaico MSPI path.
 * ===================================================================== */

static const char *UTIL_TAG = "wa-util";

#define UTIL_CH_MIN 1
#define UTIL_CH_MAX 13
#define UTIL_NCHAN (UTIL_CH_MAX - UTIL_CH_MIN + 1)
#define UTIL_DWELL_MS 100
#define UTIL_MAX_FRAME_US 20000
#define UTIL_STORE_TTL_MS 10000

static uint16_t s_permille[UTIL_NCHAN];
static uint32_t s_last_ms[UTIL_NCHAN];
static uint32_t s_revision;
static SemaphoreHandle_t s_util_mutex;

static volatile uint8_t g_cur_ch;
static volatile uint32_t g_busy_us;

void wa_util_init(void)
{
    if (s_util_mutex == NULL) {
        s_util_mutex = xSemaphoreCreateMutex();
    }
    if (s_mspi_sem == NULL) {
        s_mspi_sem = xSemaphoreCreateBinary();
        if (s_mspi_sem != NULL) {
            xSemaphoreGive(s_mspi_sem);
        }
    }
    if (s_abort_sem == NULL) {
        s_abort_sem = xSemaphoreCreateBinary();
    }
    memset(s_permille, 0, sizeof(s_permille));
    memset(s_last_ms, 0, sizeof(s_last_ms));
    s_revision = 0;
}

void wa_util_clear(void)
{
    if (s_util_mutex == NULL) {
        return;
    }
    xSemaphoreTake(s_util_mutex, portMAX_DELAY);
    memset(s_permille, 0, sizeof(s_permille));
    memset(s_last_ms, 0, sizeof(s_last_ms));
    ++s_revision;
    xSemaphoreGive(s_util_mutex);
}

static void util_store_set(uint8_t ch, uint16_t permille, uint32_t now_ms)
{
    if (ch < UTIL_CH_MIN || ch > UTIL_CH_MAX || s_util_mutex == NULL) {
        return;
    }
    xSemaphoreTake(s_util_mutex, portMAX_DELAY);
    s_permille[ch - UTIL_CH_MIN] = permille;
    s_last_ms[ch - UTIL_CH_MIN] = now_ms;
    ++s_revision;
    xSemaphoreGive(s_util_mutex);
}

/* Pascal UI: 0..1000, or -1 if never probed / TTL expired. */
/* Exact twin of wifi_analyzer main/ui/channel_view.c util_band_color(). */
uint32_t wa_util_band_rgb(int permille)
{
    if (permille < 0) {
        permille = 0;
    }
    if (permille > 1000) {
        permille = 1000;
    }
    uint16_t h = (uint16_t)(220 - (220 * (unsigned)permille) / 1000);
    uint8_t v = (uint8_t)(16 + (13 * (unsigned)permille) / 1000);
    lv_color_t lc = lv_color_hsv_to_rgb(h, 85, v);
    return ((uint32_t)lc.red << 16) | ((uint32_t)lc.green << 8) | (uint32_t)lc.blue;
}

int wa_util_channel_pm(int ch)
{
    if (ch < UTIL_CH_MIN || ch > UTIL_CH_MAX || s_util_mutex == NULL) {
        return -1;
    }
    const uint32_t now = (uint32_t)(esp_timer_get_time() / 1000);
    xSemaphoreTake(s_util_mutex, portMAX_DELAY);
    const uint32_t last = s_last_ms[ch - UTIL_CH_MIN];
    const uint16_t pm = s_permille[ch - UTIL_CH_MIN];
    xSemaphoreGive(s_util_mutex);
    if (last == 0 || now < last || (now - last) > UTIL_STORE_TTL_MS) {
        return -1;
    }
    return (int)pm;
}

uint32_t wa_util_revision(void)
{
    if (s_util_mutex == NULL) {
        return 0;
    }
    xSemaphoreTake(s_util_mutex, portMAX_DELAY);
    const uint32_t rev = s_revision;
    xSemaphoreGive(s_util_mutex);
    return rev;
}

/* Airtime from S31 rx_ctrl: same model as the discarded Pascal
 * FrameAirtimeUs (preamble + sig_len*8/rate), with HT MCS from he_siga1. */
static uint32_t frame_airtime_us(const wifi_pkt_rx_ctrl_t *c)
{
    uint32_t mbps_x10 = 0;
    uint32_t pre = 20;
    const unsigned fmt = c->cur_bb_format;
    const unsigned rate = c->rate;
    const unsigned sig_len = c->sig_len;

    if (sig_len == 0) {
        return 0;
    }

    if (fmt == RX_BB_FORMAT_11B) {
        switch (rate) {
        case 0: mbps_x10 = 10; pre = 192; break; /* long 1M */
        case 1: mbps_x10 = 20; pre = 192; break;
        case 2: mbps_x10 = 55; pre = 192; break;
        case 3: mbps_x10 = 110; pre = 192; break;
        case 5: mbps_x10 = 20; pre = 96; break; /* short */
        case 6: mbps_x10 = 55; pre = 96; break;
        case 7: mbps_x10 = 110; pre = 96; break;
        default: return 0;
        }
    } else if (fmt == RX_BB_FORMAT_11G) {
        switch (rate) {
        case 8:  mbps_x10 = 480; break;
        case 9:  mbps_x10 = 240; break;
        case 10: mbps_x10 = 120; break;
        case 11: mbps_x10 = 60; break;
        case 12: mbps_x10 = 540; break;
        case 13: mbps_x10 = 360; break;
        case 14: mbps_x10 = 180; break;
        case 15: mbps_x10 = 90; break;
        default: return 0;
        }
        pre = 20;
    } else if (fmt == RX_BB_FORMAT_HT) {
        unsigned mcs = c->he_siga1 & 0x7Fu;
        unsigned cwb = (c->he_siga1 >> 7) & 1u;
        unsigned sgi = (c->he_siga2 >> 7) & 1u; /* HT-SIG2 Short GI */
        static const uint16_t ht20[8] = {65, 130, 195, 260, 390, 520, 585, 650};
        mbps_x10 = ht20[mcs % 8];
        mbps_x10 *= (1u + mcs / 8u);
        if (cwb) {
            mbps_x10 = mbps_x10 * 207 / 100;
        }
        if (sgi) {
            mbps_x10 = mbps_x10 * 10 / 9;
        }
        pre = 26;
    } else {
        /* VHT/HE: nominal MCS7 20 MHz; SIG encoding not fully documented */
        mbps_x10 = 650;
        pre = 60;
    }

    if (mbps_x10 == 0) {
        return 0;
    }
    uint32_t air = pre + (uint32_t)sig_len * 80u / mbps_x10;
    return air > UTIL_MAX_FRAME_US ? UTIL_MAX_FRAME_US : air;
}

static void util_rx_cb(void *buf, wifi_promiscuous_pkt_type_t type)
{
    (void)type;
    const wifi_promiscuous_pkt_t *pkt = (const wifi_promiscuous_pkt_t *)buf;
    const wifi_pkt_rx_ctrl_t *c = &pkt->rx_ctrl;

    if (c->channel != g_cur_ch) {
        return;
    }
    if (c->sig_len < 16) {
        return;
    }
    g_busy_us += frame_airtime_us(c);
}

/* Prepare sniffer once; Pascal then calls wa_util_dwell_channel per ch and
 * yields for LVGL paint between dwells (promiscuous is off during yield). */
void wa_util_sweep_begin(void)
{
    const wifi_promiscuous_filter_t filt = {
        .filter_mask = WIFI_PROMIS_FILTER_MASK_MGMT | WIFI_PROMIS_FILTER_MASK_DATA |
                       WIFI_PROMIS_FILTER_MASK_CTRL,
    };
    esp_wifi_set_promiscuous_filter(&filt);
    esp_wifi_set_promiscuous_rx_cb(util_rx_cb);
    g_cur_ch = 0;
}

/* One channel: acquire MSPI exclusivity → abortable promiscuous dwell →
 * sniff off → release MSPI. Returns 1 on completed dwell, 0 if preempted by
 * UI/touch (caller should wait for UI idle and retry ch), or -1 on error. */
int wa_util_dwell_channel(int ch)
{
    if (ch < UTIL_CH_MIN || ch > UTIL_CH_MAX) {
        return -1;
    }

    if (s_ui_want_bus) {
        return 0;
    }
    if (s_mspi_sem != NULL) {
        xSemaphoreTake(s_mspi_sem, portMAX_DELAY);
    }
    if (s_abort_sem != NULL) {
        xSemaphoreTake(s_abort_sem, 0);
    }
    __sync_synchronize();
    if (s_ui_want_bus) {
        if (s_mspi_sem != NULL) {
            xSemaphoreGive(s_mspi_sem);
        }
        return 0;
    }

    g_busy_us = 0;
    g_cur_ch = (uint8_t)ch;
    esp_wifi_set_channel((uint8_t)ch, WIFI_SECOND_CHAN_NONE);

    esp_err_t err = esp_wifi_set_promiscuous(true);
    if (err != ESP_OK) {
        ESP_LOGE(UTIL_TAG, "promiscuous enable ch%d: %s", ch, esp_err_to_name(err));
        g_cur_ch = 0;
        if (s_mspi_sem != NULL) {
            xSemaphoreGive(s_mspi_sem);
        }
        return -1;
    }

    int64_t t_start = esp_timer_get_time();
    BaseType_t aborted = pdFALSE;
    if (s_abort_sem != NULL) {
        aborted = xSemaphoreTake(s_abort_sem, pdMS_TO_TICKS(UTIL_DWELL_MS));
    } else {
        vTaskDelay(pdMS_TO_TICKS(UTIL_DWELL_MS));
    }
    int64_t elapsed_us = esp_timer_get_time() - t_start;
    uint32_t busy = g_busy_us;

    g_cur_ch = 0;
    esp_wifi_set_promiscuous(false);
    /* brief settle so any in-flight RX DMA descriptor drains before PSRAM burst */
    vTaskDelay(pdMS_TO_TICKS(2));

    if (aborted == pdTRUE || s_ui_want_bus) {
        ESP_LOGI(UTIL_TAG, "dwell ch%d preempted by UI after %lld us", ch, (long long)elapsed_us);
        if (s_mspi_sem != NULL) {
            xSemaphoreGive(s_mspi_sem);
        }
        return 0;
    }

    if (busy > UTIL_DWELL_MS * 1000u) {
        busy = UTIL_DWELL_MS * 1000u;
    }
    uint16_t permille = (uint16_t)(busy * 1000u / (UTIL_DWELL_MS * 1000u));
    util_store_set((uint8_t)ch, permille, (uint32_t)(esp_timer_get_time() / 1000));

    if (s_mspi_sem != NULL) {
        xSemaphoreGive(s_mspi_sem);
    }
    return 1;
}

void wa_util_sweep_end(void)
{
    g_cur_ch = 0;
    esp_wifi_set_promiscuous(false);
    esp_wifi_set_channel(1, WIFI_SECOND_CHAN_NONE);
    vTaskDelay(pdMS_TO_TICKS(10));

    ESP_LOGI(UTIL_TAG,
             "sweep pm = %d %d %d %d %d %d %d %d %d %d %d %d %d",
             wa_util_channel_pm(1), wa_util_channel_pm(2), wa_util_channel_pm(3),
             wa_util_channel_pm(4), wa_util_channel_pm(5), wa_util_channel_pm(6),
             wa_util_channel_pm(7), wa_util_channel_pm(8), wa_util_channel_pm(9),
             wa_util_channel_pm(10), wa_util_channel_pm(11), wa_util_channel_pm(12),
             wa_util_channel_pm(13));
}

/* Back-compat single-shot (unused by Pascal now). */
void wa_util_sweep_once(void)
{
    wa_util_sweep_begin();
    for (uint8_t ch = UTIL_CH_MIN; ch <= UTIL_CH_MAX; ++ch) {
        wa_util_dwell_channel(ch);
        vTaskDelay(pdMS_TO_TICKS(120));
    }
    wa_util_sweep_end();
}
