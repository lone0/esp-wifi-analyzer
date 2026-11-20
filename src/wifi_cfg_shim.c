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
 *    device and remains visible briefly after release. */
#include <stdlib.h>
#include "esp_wifi.h"
#include "lvgl.h"
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

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

static void wa_touch_tick(lv_timer_t *timer)
{
    (void)timer;
    if (lv_indev_get_state(wa_touch_indev) == LV_INDEV_STATE_PRESSED) {
        lv_point_t p;
        lv_indev_get_point(wa_touch_indev, &p);
        lv_obj_set_pos(wa_touch_dot, p.x - 6, p.y - 6);
        lv_obj_set_hidden(wa_touch_dot, false);
        wa_touch_last = lv_tick_get();
        wa_touch_seen = true;
    } else if (wa_touch_seen && lv_tick_elaps(wa_touch_last) >= 500) {
        lv_obj_set_hidden(wa_touch_dot, true);
        wa_touch_seen = false;
    }
}

bool wa_touch_indicator_start(lv_indev_t *indev)
{
    if (indev == NULL) {
        return false;
    }
    wa_touch_indev = indev;
    wa_touch_dot = lv_obj_create(lv_screen_active());
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
    if (lv_timer_create(wa_touch_tick, 30, NULL) == NULL) {
        lv_obj_delete(wa_touch_dot);
        wa_touch_dot = NULL;
        return false;
    }
    return true;
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
