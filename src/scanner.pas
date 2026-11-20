{ scanner - continuous all-channel WiFi scanner, the Pascal twin of the C
  wifi_analyzer's main/wifi_scanner.c: pure radio RPC (no netif), STA-only,
  storage RAM, country CN to expose channels 12/13, blocking scan every
  ~600 ms of gap, one RSSI sample per AP per cycle into apstore.

  Threading: the WiFi chain is brought up in the MAIN task (ScannerInit),
  and the scan loop runs in an FTHREADS-managed worker (ScannerPrepare ->
  fBeginThreadNamed 16 KB, gated by ScannerStart) so the FPC threadvar
  block lives in FreeRTOS TLS slot 1 (esp-units ad67f76: fthreads moved
  off slot 0, which IDF reserves for pthread/lwIP). The worker starts
  scanning only after ScannerStart - the first scan lands after the UI
  is up (requirement 9: no contention during display bring-up).

  Scheduling (requirement 8): unpinned - the scheduler places it; revisit
  after profiling. Worker stack 16 KB: scan record handling needs more
  than fthreads' default. }

unit scanner;

{$mode objfpc}{$H+}

interface

{ 1 while a blocking scan is in flight - the UI scan dot reads it
  (single-byte flag, benign race, same posture as the C app's
  volatile bool s_scanning) }
var
  ScannerBusy: byte = 0;

function ScannerInit: boolean;
procedure ScannerPrepare;
procedure ScannerStart;

implementation

uses
  esp_task,    { vTaskDelay, pdMS_TO_TICKS, vTaskDelete }
  fthreads,    { BeginThread manager + fBeginThreadNamed (TLS slot 1) }
  c_bmgr,      { esp_err_t }
  c_wifi, apstore;

const
  TAGmsg = 'WIFI-SCAN';
  SCAN_GAP_MS = 600;
  RECORDS_PER_CHUNK = 32;   { one esp_wifi_scan_get_ap_records chunk }
  WORKER_STACK = 16 * 1024;

type
  TRecordArray = array[0..RECORDS_PER_CHUNK - 1] of TApRecordBytes;

var
  scan_cfg: TWifiScanCfgBytes;
  worker_started: byte = 0;
  run_enabled: byte = 0;

function ScanTaskFT(arg: pointer): ptrint;
var
  err: esp_err_t;
  num: word;
  recs: ^TRecordArray;
  i: integer;
  bssid: TBssid;
  now_ms: longword;
  cycle: integer = 0;
begin
  Result := 0;
  recs := nil;
  GetMem(recs, SizeOf(TRecordArray));
  writeln(TAGmsg, ': I worker up (16 KB, fthreads/TLS slot 1)');

  repeat
    if run_enabled = 0 then
    begin
      vTaskDelay(pdMS_TO_TICKS(200));
      continue;
    end;
    ScannerBusy := 1;
    num := 0;
    err := esp_wifi_scan_start(@scan_cfg, 1);  { block until done }
    ScannerBusy := 0;
    if err = ESP_OK then
    begin
      num := 0;
      esp_wifi_scan_get_ap_num(@num);
      if num > 0 then
      begin
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
      end;
      writeln(TAGmsg, ': I scan cycle ', cycle, ': ', num, ' APs');
    end
    else
      writeln(TAGmsg, ': W scan_start failed: ', err);
    Inc(cycle);
    vTaskDelay(pdMS_TO_TICKS(SCAN_GAP_MS));
  until false;
end;

{ nvs + esp_wifi init/config/start - blocking, runs in the MAIN task
  before the display chain (the C wifi_scanner.c order, minus the task) }
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

  err := esp_wifi_init(wifi_default_init_config);
  if err <> ESP_OK then
  begin
    writeln(TAGmsg, ': E esp_wifi_init failed: ', err);
    exit(false);
  end;
  esp_wifi_set_storage(WIFI_STORAGE_RAM);
  esp_wifi_set_mode(WIFI_MODE_STA);
  esp_wifi_set_country_code('CN', 1);   { expose channels 12/13 }
  err := esp_wifi_start;
  if err <> ESP_OK then
  begin
    writeln(TAGmsg, ': E esp_wifi_start failed: ', err);
    exit(false);
  end;
  writeln(TAGmsg, ': I scanner ready (all 2.4G channels, country CN)');
  ScanCfgDefault(scan_cfg);
  Result := true;
end;

{ spawn the scan worker (16 KB, fthreads/TLS slot 1); the worker waits
  for ScannerStart before its first scan. fBeginThreadNamed performs the
  once-only manager/TLS initialization itself; this standard path arms the
  foreign-task relocation hook before LVGL creates its C worker. }
procedure ScannerPrepare;
var
  id: TThreadID;
begin
  worker_started := 1;
  fBeginThreadNamed(WORKER_STACK, @ScanTaskFT, nil, id, 'wifi_scan');
  writeln(TAGmsg, ': I worker spawned (16 KB, fthreads/TLS slot 1)');
end;

procedure ScannerStart;
begin
  run_enabled := 1;
end;

end.
