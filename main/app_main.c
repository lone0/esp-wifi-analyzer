/* Ladder step 1: C hello world through the usb_hs_console CDC chain. */
#include <stdio.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

void app_main(void)
{
    printf("HELLO-C: boot\n");
    while (1) {
        printf("HELLO-C: tick\n");
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}
