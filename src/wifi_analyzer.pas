program wifi_analyzer;

{ WiFi analyzer for the ESP-Mosaico - the Pascal rewrite of the C app
  (/mnt/storage/wifi_analyzer).

  Architecture (mirrors the C app's three layers):
    scanner task  - esp_wifi blocking scan, one RSSI sample per AP per
                    cycle into apstore; UNPINNED (the scheduler places
                    it; revisit after profiling)
    apstore       - 64 AP x 96-sample ring, mutex, revision counter
    appui         - LVGL chrome (status bar + view buttons via
                    boardlvgl) over the chartdraw raster canvas; 250 ms
                    revision-gated tick, no paint near the 100 ms budget

  The display chain is boardlvgl.Start: BMGR display_lcd through the
  boarddisplay override path (psram_dma_direct + 80 MHz) + adapter +
  touch, one call. Everything LVGL afterwards runs under UILock/UIUnlock
  (the adapter lock is recursive, so the LVGL task's own timer/event
  callbacks may take it too).

  esp-units.pas is used frozen (submodule): the app-side L1 growth
  (esp_wifi scan offsets from compiled probes, lv_timer/event-user-data/
  obj-get-child externals, the wifi_init_config shim) lives in src/.

  Build: idf.py --preview build && idf.py --preview pas   (see README)

  idfheap comes first in uses - the IDF heap manager must be installed
  before anything else allocates. }

{$mode objfpc}{$H+}

uses
  idfheap,          { MUST be first: installs the IDF heap manager }
  fthreads,         { Pascal TLS for scanner and LVGL callbacks }
  mosaicobmgrdeps,  { app-specific generated Mosaico table closure }
  c_bmgr,           { esp_err_t + BMGR core (esp-units submodule) }
  boardlvgl,        { L2 facade: one Start lights the panel chain }
  SysUtils,         { HexStr }
  esp_task,         { vTaskDelay for the parking loop }
  scanner,          { the scan task }
  apstore,          { AP registry (scanner <-> UI) }
  appui;            { status bar + canvas + view chrome }

const
  TAGmsg = 'WA';

var
  lvgl_config: TBoardLvglConfig;

procedure wa_console_flush_start; cdecl; external;

begin
  wa_console_flush_start;
  writeln(TAGmsg, ': I WiFi analyzer starting (Mosaico, real scan)');

  { canvas buffer: 480x436 ARGB8888, >16 KB -> PSRAM via
    idfheap + SPIRAM_USE_MALLOC }
  GetMem(appui.canvas_buf, appui.CANVAS_W * appui.CANVAS_H * SizeOf(Cardinal));
  writeln(TAGmsg, ': I canvas buffer @0x', HexStr(PtrUInt(appui.canvas_buf), 8));

  APStoreInit;
  writeln(TAGmsg, ': I initializing WiFi');
  if not ScannerInit then
    exit;
  writeln(TAGmsg, ': I preparing scanner thread');
  ScannerPrepare;
  writeln(TAGmsg, ': I scanner thread prepared');

  lvgl_config := TBoardLvgl.DefaultConfig;
  lvgl_config.TaskStackSize := 32 * 1024;
  writeln(TAGmsg, ': I starting board LVGL');
  if TBoardLvgl.StartEx(lvgl_config) <> ESP_OK then
  begin
    writeln(TAGmsg, ': E boardlvgl start failed');
    exit;
  end;

  { build the chrome under the UI lock (the adapter task is live now) }
  TBoardLvgl.UILock;
  appui.UIStart;
  TBoardLvgl.UIUnlock;

  writeln(TAGmsg, ': I starting scanner');
  writeln(TAGmsg, ': I running - CH/HIST top right switch views');
  ScannerStart;
  repeat
    vTaskDelay(pdMS_TO_TICKS(1000));
  until false;
end.
