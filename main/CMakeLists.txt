# The C component exists only to drive which IDF archives the build tree
# produces for the Pascal link closure (build.sh whole-archives / -Fl's
# them). app_main.c itself is never linked into the Pascal binary - FPC's
# RTL owns app_main, and the usb_hs_console --wrap chain (auto-detected by
# esp-units.pas/scripts/build.sh from the build tree) runs before it.
idf_component_register(SRCS "app_main.c"
                       INCLUDE_DIRS "."
                       PRIV_REQUIRES esp_board_manager
                                     espressif__bmi270_sensor
                                     espressif__led_strip
                                     espressif__esp_lvgl_adapter
                                     lvgl__lvgl
                                     espressif__button
                                     espressif__bq27220 gen_bmgr_codes
                                     esp_wifi nvs_flash esp_timer
                                     esp_phy esp_coex)

# ---------------------------------------------------------------------------
# Pascal application (src/*.pas), built by the esp-units.pas submodule's
# toolchain scripts against THIS project's build tree. Paths come from the
# environment at invocation time (requirement: no hardcoded tool paths):
#   ESP_FPC_ROOT         fpc-cross install (esp-env-esp32s31 sets it)
#   ESP_IDF_VERSION      defaults to 6.1 inside build.sh
#   ESP32_SDK_PROJECT    this project (build.sh derives the link closure)
#   ESP_TOOLCHAIN_BIN    riscv32 binutils (esp-env-esp32s31 sets it)
# Run:  idf.py --preview pas        (after idf.py build)
#
# Ordinary C dependencies are owned by their L1 Pascal units via {$linklib};
# board/transport archives are passed via --lib and resolved inside link.res's
# GROUP(...) without --whole-archive.
idf_build_get_property(python PYTHON)

add_custom_target(pas
  COMMAND bash -c "cd ${CMAKE_SOURCE_DIR} && ESP32_SDK_PROJECT=${CMAKE_SOURCE_DIR} ${CMAKE_SOURCE_DIR}/esp-units.pas/scripts/build.sh src/wifi_analyzer.pas --soc esp32s31 -O2 --c src/wifi_cfg_shim.c --lib espressif__bq27220 --lib espressif__button --lib espressif__esp_video --lib espressif__esp_cam_sensor --lib espressif__esp_codec_dev --lib esp_driver_i2s --lib esp_driver_cam --lib esp_hal_i2s --lib esp_hal_cam --lib espressif__esp_sccb_intf --lib espressif__esp_lcd_touch_cst9220 --lib espressif__esp_lcd_co5300 --lib esp_lcd --lib esp_driver_i2c --lib esp_hal_i2c --lib esp_driver_spi --lib espressif__esp_lcd_touch --lib espressif__i2c_bus --lib esp_driver_ledc --lib esp_hal_ledc --lib esp_pm"
  COMMAND ${python} "$ENV{IDF_PATH}/components/partition_table/check_sizes.py"
          --offset ${CONFIG_PARTITION_TABLE_OFFSET} partition --type app --subtype factory
          ${CMAKE_BINARY_DIR}/partition_table/partition-table.bin
          ${CMAKE_SOURCE_DIR}/src/wifi_analyzer.bin
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Building src/wifi_analyzer.pas with the esp-units toolchain"
  VERBATIM)
add_dependencies(pas partition_table_bin)
