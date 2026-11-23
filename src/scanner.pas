{ scanner - WiFi probe engine, alternating two phases per cycle (C twin
  of /mnt/storage/wifi_analyzer main/wifi_scanner.c):

    PHASE SCAN: esp_wifi_scan_start (AP list for curves/labels).
    PHASE UTIL: per-channel promiscuous dwell in wifi_cfg_shim.c
      (100 ms/ch, airtime -> per-mille store with TTL). LVGL adapter is
      paused for each dwell so PSRAM paint cannot overlap RX on the
      Mosaico MSPI path.

  UI handshake: UtilNeedFullPaint + WaitUiPainted so AP curves are drawn
  before util column patches; between dwells the tick patches one strip.
  WalkActive: UI skips canvas work while a dwell runs.
  ChannelUtilPM reads the C store (-1 = expired/never probed). }

unit scanner;

{$mode objfpc}{$H+}

interface

var
  ScannerBusy: byte = 0;
  { 1 while a channel dwell runs (sniff on / LVGL paused) }
  WalkActive: byte = 0;
  { 1 between dwells / during sweep: prefer column patch over full redraw }
  UtilDeferPaint: byte = 0;
  { channel just measured (1..13); UI patches that column then clears to 0 }
  UtilPatchCh: integer = 0;
  { 1: UI must full-repaint (AP curves) at next walk-free tick }
  UtilNeedFullPaint: byte = 0;

function ScannerInit: boolean;
procedure ScannerPrepare;
procedure ScannerStart;

{ per-channel occupancy, per-mille 0..1000; -1 = expired/never probed }
function ChannelUtilPM(ch: integer): integer;
function UtilRevision: longword;

implementation

uses
  esp_task,    { vTaskDelay, pdMS_TO_TICKS }
  fthreads,    { fBeginThreadNamed (TLS slot 1) }
  c_bmgr,      { esp_err_t }
  c_wifi, apstore;

const
  TAGmsg = 'WIFI-SCAN';
  SCAN_GAP_MS = 600;
  { After each dwell: sniff off, LVGL window for touch + column patch.
    Full redraw is handshaked after scan and again after the sweep. }
  UTIL_TOUCH_YIELD_MS = 60;
  RECORDS_PER_CHUNK = 32;
  WORKER_STACK = 16 * 1024;

type
  TRecordArray = array[0..RECORDS_PER_CHUNK - 1] of TApRecordBytes;

var
  scan_cfg: TWifiScanCfgBytes;
  run_enabled: byte = 0;

procedure wa_util_init; cdecl; external;
procedure wa_util_sweep_begin; cdecl; external;
function wa_util_dwell_channel(ch: cint): cint; cdecl; external;
procedure wa_util_sweep_end; cdecl; external;
function wa_util_channel_pm(ch: cint): cint; cdecl; external;
function wa_util_revision: longword; cdecl; external;
procedure wa_ui_wait_idle(timeout_ms: cint); cdecl; external;

function ChannelUtilPM(ch: integer): integer;
begin
  Result := wa_util_channel_pm(ch);
end;

function UtilRevision: longword;
begin
  Result := wa_util_revision;
end;

{ Spin until UI clears UtilNeedFullPaint and finishes LVGL/DMA flush. }
procedure WaitUiPainted(timeout_ms: integer);
var
  waited: integer;
begin
  waited := 0;
  while (UtilNeedFullPaint <> 0) and (waited < timeout_ms) do
  begin
    vTaskDelay(pdMS_TO_TICKS(5));
    Inc(waited, 5);
  end;
  wa_ui_wait_idle(timeout_ms);
end;

{ Spin until UI clears UtilPatchCh and finishes strip DMA flush. }
procedure WaitChannelPatched(timeout_ms: integer);
var
  waited: integer;
begin
  waited := 0;
  while (UtilPatchCh <> 0) and (waited < timeout_ms) do
  begin
    vTaskDelay(pdMS_TO_TICKS(5));
    Inc(waited, 5);
  end;
  wa_ui_wait_idle(timeout_ms);
end;

procedure ScanAPs;
var
  err: esp_err_t;
  num: word;
  recs: ^TRecordArray;
  i: integer;
  bssid: TBssid;
  now_ms: longword;
  t0: longword;   { this scan's start: the seen/not-seen boundary }
begin
  GetMem(recs, SizeOf(TRecordArray));
  t0 := longword(esp_timer_get_time div 1000);
  try
    num := 0;
    err := esp_wifi_scan_start(@scan_cfg, 1);
    if err <> ESP_OK then
    begin
      writeln(TAGmsg, ': W scan_start failed: ', err);
      exit;
    end;
    num := 0;
    esp_wifi_scan_get_ap_num(@num);
    if num = 0 then
    begin
      esp_wifi_clear_ap_list;
      writeln(TAGmsg, ': I scan: 0 APs');
      exit;
    end;
    if num > RECORDS_PER_CHUNK then
      num := RECORDS_PER_CHUNK;
    esp_wifi_scan_get_ap_records(@num, PApRecordBytes(recs));
    now_ms := longword(esp_timer_get_time div 1000);
    for i := 0 to num - 1 do
    begin
      RecBssid(PApRecordBytes(recs) + i, bssid);
      APStoreAdd(bssid, RecSsid(PApRecordBytes(recs) + i),
        RecPrimary(PApRecordBytes(recs) + i),
        RecRssi(PApRecordBytes(recs) + i), now_ms);
    end;
    writeln(TAGmsg, ': I scan: ', num, ' APs (store ', APStoreCount, ')');
  finally
    FreeMem(recs);
    APStoreSweepMisses(t0);   { every cycle: reset/increment misses, evict at 2 }
    APStoreAssignColors;      { then promote top-3 uncolored APs (freed
                                slots re-claimable in the same cycle) }
  end;
end;

function ScanTaskFT(arg: pointer): ptrint;
var
  cycle: integer = 0;
  ch, dwell_res: integer;
begin
  Result := 0;
  writeln(TAGmsg, ': I worker up (16 KB, fthreads/TLS slot 1)');

  repeat
    if run_enabled = 0 then
    begin
      vTaskDelay(pdMS_TO_TICKS(200));
      continue;
    end;
    ScannerBusy := 1;

    ScanAPs;

    { Wait until the UI tick has drawn AP curves before util patches. }
    UtilNeedFullPaint := 1;
    WaitUiPainted(1500);
    if UtilNeedFullPaint <> 0 then
      writeln(TAGmsg, ': W UI paint ack timeout after scan');

    { Per channel: abortable dwell → UI patches that strip → next. }
    UtilDeferPaint := 1;
    wa_util_sweep_begin;
    ch := 1;
    while ch <= 13 do
    begin
      WalkActive := 1;
      dwell_res := wa_util_dwell_channel(ch);
      WalkActive := 0;
      if dwell_res > 0 then
      begin
        UtilPatchCh := ch;   { tick patches this strip, then clears }
        WaitChannelPatched(300);
        Inc(ch);
      end
      else if dwell_res = 0 then
      begin
        { Dwell preempted by UI/touch; wait for UI idle then retry ch }
        wa_ui_wait_idle(500);
      end
      else
        Inc(ch);
    end;
    UtilPatchCh := 0;
    wa_util_sweep_end;
    UtilDeferPaint := 0;
    UtilNeedFullPaint := 1;  { reconcile util + AP curves after the sweep }
    WaitUiPainted(1500);
    writeln(TAGmsg, ': I util sweep done');

    ScannerBusy := 0;
    Inc(cycle);
    vTaskDelay(pdMS_TO_TICKS(SCAN_GAP_MS));
  until false;
end;

function ScannerInit: boolean;
var
  err: esp_err_t;
begin
  err := nvs_flash_init;
  if (err = ESP_ERR_NVS_NO_FREE_PAGES) or (err = ESP_ERR_NVS_NEW_VERSION_FOUND) then
  begin
    nvs_flash_erase;
    err := nvs_flash_init;
  end;
  if err <> ESP_OK then
  begin
    writeln(TAGmsg, ': E nvs_flash_init failed: ', err);
    exit(false);
  end;

  { channel-switch / sniffer post WiFi events; without a default loop
    the driver logs ESP_ERR_INVALID_STATE (259) on every dwell. }
  err := esp_event_loop_create_default;
  if (err <> ESP_OK) and (err <> ESP_ERR_INVALID_STATE) then
  begin
    writeln(TAGmsg, ': E esp_event_loop_create_default: ', err);
    exit(false);
  end;

  err := esp_wifi_init(wifi_default_init_config);
  if err <> ESP_OK then
  begin
    writeln(TAGmsg, ': E esp_wifi_init failed: ', err);
    exit(false);
  end;
  esp_wifi_set_storage(WIFI_STORAGE_RAM);
  esp_wifi_set_mode(WIFI_MODE_STA);
  esp_wifi_set_country_code('CN', 1);
  err := esp_wifi_start;
  if err <> ESP_OK then
  begin
    writeln(TAGmsg, ': E esp_wifi_start failed: ', err);
    exit(false);
  end;

  wa_util_init;
  ScanCfgDefault(scan_cfg);
  writeln(TAGmsg, ': I scanner ready (all 2.4G channels, country CN)');
  Result := true;
end;

procedure ScannerPrepare;
var
  id: TThreadID;
begin
  fBeginThreadNamed(WORKER_STACK, @ScanTaskFT, nil, id, 'wifi_scan');
  writeln(TAGmsg, ': I worker spawned (16 KB, fthreads/TLS slot 1)');
end;

procedure ScannerStart;
begin
  run_enabled := 1;
end;

end.
