{ c_wifi - app-side L1 binding for esp_wifi scan (the esp-units.pas
  submodule is used frozen: business bindings live in this project, the
  submodule's L1 grammar is followed - cdecl; external, C names kept).

  All struct facts below are COMPILED PROBES (the toolchain gcc against
  this project's own build/config, see README "binding probes"), not
  hand arithmetic:
    sizeof(wifi_ap_record_t) = 92
      bssid @0 (6 bytes), ssid @6 (33 bytes), primary @39,
      rssi @44, authmode @48 (4-byte enum)
    sizeof(wifi_scan_config_t) = 44, show_hidden @9
  The records are handled as opaque byte blobs with offset accessors -
  we never reconstruct the C layout in Pascal. All-channel scan uses a
  zero-filled scan config with show_hidden=1 (the C wifi_analyzer's
  settings, main/wifi_scanner.c:59).

  esp_wifi_init takes a wifi_init_config_t whose WIFI_INIT_CONFIG_DEFAULT
  macro is a 26-field designated initializer referencing extern symbols
  and by-value struct copies - not expressible as Pascal data. The shim
  wifi_cfg_shim.c materializes it at runtime and hands out the pointer. }

unit c_wifi;

{$mode objfpc}{$H+}
{$linklib esp_wifi}
{$linklib pp}
{$linklib net80211}
{$linklib phy}
{$linklib esp_coex}
{$linklib coexist}
{$linklib core}
{$linklib espnow}
{$linklib mesh}
{$linklib esp_event}
{$linklib nvs_flash}
{$linklib wpa_supplicant}

interface

uses
  c_bmgr;  { esp_err_t scalar alias }

const
  WIFI_AP_RECORD_SIZE = 92;
  WIFI_SCAN_CFG_SIZE = 44;

  WIFI_SCAN_REC_OFF_BSSID = 0;
  WIFI_SCAN_REC_OFF_SSID = 6;
  WIFI_SCAN_REC_OFF_PRIMARY = 39;
  WIFI_SCAN_REC_OFF_RSSI = 44;
  WIFI_SCAN_REC_OFF_AUTHMODE = 48;
  WIFI_SCAN_CFG_OFF_SHOW_HIDDEN = 9;

  WIFI_MODE_STA = 1;       { wifi_mode_t (esp_wifi_types_generic.h) }
  WIFI_STORAGE_RAM = 1;

  { nvs.h error codes (ESP_ERR_NVS_BASE 0x1100 + offset) }
  ESP_ERR_NVS_NO_FREE_PAGES = $110D;
  ESP_ERR_NVS_NEW_VERSION_FOUND = $1110;

type
  TBssid = array[0..5] of byte;
  PWifiScanCfg = ^TWifiScanCfgBytes;
  TWifiScanCfgBytes = array[0..WIFI_SCAN_CFG_SIZE - 1] of byte;
  PApRecordBytes = ^TApRecordBytes;
  TApRecordBytes = array[0..WIFI_AP_RECORD_SIZE - 1] of byte;

{ --- accessors over the opaque record blob --- }
procedure ScanCfgDefault(var buf: TWifiScanCfgBytes);
function RecPrimary(rec: PApRecordBytes): byte; inline;
function RecRssi(rec: PApRecordBytes): shortint; inline;
function RecAuthmode(rec: PApRecordBytes): integer; inline;
procedure RecBssid(rec: PApRecordBytes; out bssid: TBssid); inline;
function RecSsid(rec: PApRecordBytes): string;

{ --- esp_wifi API (esp_wifi.h); bool params are C _Bool = 1 byte --- }
function wifi_default_init_config: pointer; cdecl; external;   { wifi_cfg_shim.c }
function esp_event_loop_create_default: esp_err_t; cdecl; external;
function esp_wifi_init(cfg: pointer): esp_err_t; cdecl; external;
function esp_wifi_set_storage(storage: cint): esp_err_t; cdecl; external;
function esp_wifi_set_mode(mode: cint): esp_err_t; cdecl; external;
function esp_wifi_set_country_code(country: PChar; ieee80211d: byte): esp_err_t; cdecl; external;
function esp_wifi_start: esp_err_t; cdecl; external;
function esp_wifi_scan_start(cfg: pointer; blocking: byte): esp_err_t; cdecl; external;
function esp_wifi_scan_get_ap_num(num: pointer): esp_err_t; cdecl; external;
function esp_wifi_scan_get_ap_records(num: pointer; records: pointer): esp_err_t; cdecl; external;
function esp_wifi_clear_ap_list: esp_err_t; cdecl; external;

{ --- NVS (esp_wifi_init requires it for PHY calibration data) --- }
function nvs_flash_init: esp_err_t; cdecl; external;
function nvs_flash_erase: esp_err_t; cdecl; external;

{ --- esp_timer (monotonic microseconds; the store stamps come from it) --- }
function esp_timer_get_time: int64; cdecl; external;
implementation

procedure ScanCfgDefault(var buf: TWifiScanCfgBytes);
begin
  FillChar(buf, SizeOf(buf), 0);   { all channels, defaults }
  buf[WIFI_SCAN_CFG_OFF_SHOW_HIDDEN] := 1;  { C wifi_scanner.c:60 }
end;

function RecPrimary(rec: PApRecordBytes): byte; inline;
begin
  Result := PByte(PByte(rec) + WIFI_SCAN_REC_OFF_PRIMARY)^;
end;

function RecRssi(rec: PApRecordBytes): shortint; inline;
begin
  Result := PShortInt(PByte(rec) + WIFI_SCAN_REC_OFF_RSSI)^;
end;

function RecAuthmode(rec: PApRecordBytes): integer; inline;
begin
  Result := PInteger(PByte(rec) + WIFI_SCAN_REC_OFF_AUTHMODE)^;
end;

procedure RecBssid(rec: PApRecordBytes; out bssid: TBssid); inline;
var
  i: integer;
begin
  for i := 0 to 5 do
    bssid[i] := PByte(PByte(rec) + i)^;
end;

function RecSsid(rec: PApRecordBytes): string;
var
  p: PByte;
  i: integer;
begin
  { 33 bytes, possibly without a terminator (C ap_store.c:84) }
  SetLength(Result, 0);
  p := PByte(PByte(rec) + WIFI_SCAN_REC_OFF_SSID);
  for i := 0 to 32 do
  begin
    if p^ = 0 then
      break;
    Result := Result + chr(p^);
    Inc(p);
  end;
end;

end.
