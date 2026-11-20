{ apstore - AP registry shared between the WiFi scanner task and the UI,
  same shape as the C wifi_analyzer's ap_store (main/ap_store.c):
  one entry per BSSID with a ring of RSSI samples (one per scan cycle),
  a stable palette slot for chart coloring, a monotonic revision counter
  the UI repaint gate reads, and a strongest-first sorted snapshot copy.

  Task safety: one mutex (esp_semphr) protects the shared entries.
  Pascal threads must be initialized before this unit is used by tasks. }

unit apstore;

{$mode objfpc}{$H+}

interface

uses
  esp_semphr;  { mutex primitives (esp-units freertos-fpc, L1) }

const
  AP_STORE_MAX_APS = 64;
  AP_HIST_LEN = 96;
  AP_PALETTE_SLOTS = 8;

  { RSSI sentinel: never produced by esp_wifi (real RSSI >= -128) }
  AP_RSSI_NONE = -128;

type
  TBssid = array[0..5] of byte;

  TAPEntry = record
    bssid: TBssid;
    ssid: string;
    channel: integer;
    rssi_hist: array[0..AP_HIST_LEN - 1] of shortint;  { ring: oldest at head }
    hist_head: byte;
    hist_count: byte;
    last_seen_ms: longword;
    color_idx: byte;
  end;
  TAPEntries = array of TAPEntry;

{ create the mutex; call once before any task touches the store }
procedure APStoreInit;

{ record one scan result (fields read from a C wifi_ap_record_t blob by
  the caller, which owns the offsets); now_ms from esp_timer }
procedure APStoreAdd(const bssid: TBssid;
  const ssid: string; channel: integer; rssi: shortint; now_ms: longword);

function APStoreCount: integer;

{ monotonic data revision: bumps on every store change; the UI repaints
  charts only when this differs from the drawn revision (scan cadence
  ~2 s -> full vector repaints at ~0.5 Hz) }
function APStoreRevision: longword;

{ copy all entries, sorted by latest RSSI (strongest first) - the
  snapshot the UI paints; returns the number of entries written }
function APStoreCopySorted(out out_entries: TAPEntries): integer;

{ newest sample of an entry (its sort key) }
function APLatestRssi(const e: TAPEntry): shortint;

implementation

var
  entries: array[0..AP_STORE_MAX_APS - 1] of TAPEntry;
  entry_count: integer = 0;
  next_color: byte = 0;
  revision: longword = 0;
  mutex: pointer;

procedure APStoreInit;
begin
  mutex := xSemaphoreCreateMutex;
  if mutex = nil then
    RunError(203);
  entry_count := 0;
  next_color := 0;
  revision := 0;
end;

procedure APStoreAdd(const bssid: TBssid;
  const ssid: string; channel: integer; rssi: shortint; now_ms: longword);
var
  i, idx, oldest: integer;
  e: ^TAPEntry;
  slot: byte;
begin
  xSemaphoreTake(mutex, $FFFFFFFF);  { portMAX_DELAY }
  try
    idx := -1;
    for i := 0 to entry_count - 1 do
      if (entries[i].bssid[0] = bssid[0]) and (entries[i].bssid[1] = bssid[1])
         and (entries[i].bssid[2] = bssid[2]) and (entries[i].bssid[3] = bssid[3])
         and (entries[i].bssid[4] = bssid[4]) and (entries[i].bssid[5] = bssid[5]) then
      begin
        idx := i;
        break;
      end;

    if idx < 0 then
    begin
      if entry_count < AP_STORE_MAX_APS then
        idx := entry_count
      else
      begin
        { full: replace the least-recently-seen entry (C ap_store.c:69) }
        oldest := 0;
        for i := 1 to AP_STORE_MAX_APS - 1 do
          if entries[i].last_seen_ms < entries[oldest].last_seen_ms then
            oldest := i;
        idx := oldest;
      end;
      entries[idx] := Default(TAPEntry);
      entries[idx].bssid[0] := bssid[0];
      entries[idx].bssid[1] := bssid[1];
      entries[idx].bssid[2] := bssid[2];
      entries[idx].bssid[3] := bssid[3];
      entries[idx].bssid[4] := bssid[4];
      entries[idx].bssid[5] := bssid[5];
      entries[idx].color_idx := next_color;
      next_color := (next_color + 1) mod AP_PALETTE_SLOTS;
      if idx = entry_count then
        Inc(entry_count);
    end;

    e := @entries[idx];
    e^.ssid := ssid;
    e^.channel := channel;
    e^.last_seen_ms := now_ms;
    slot := (e^.hist_head + e^.hist_count) mod AP_HIST_LEN;
    e^.rssi_hist[slot] := rssi;
    if e^.hist_count < AP_HIST_LEN then
      Inc(e^.hist_count)
    else
      e^.hist_head := (e^.hist_head + 1) mod AP_HIST_LEN;
    Inc(revision);
  finally
    xSemaphoreGive(mutex);
  end;
end;

function APStoreCount: integer;
begin
  xSemaphoreTake(mutex, $FFFFFFFF);
  try
    Result := entry_count;
  finally
    xSemaphoreGive(mutex);
  end;
end;

function APStoreRevision: longword;
begin
  xSemaphoreTake(mutex, $FFFFFFFF);
  try
    Result := revision;
  finally
    xSemaphoreGive(mutex);
  end;
end;

function APLatestRssi(const e: TAPEntry): shortint;
begin
  if e.hist_count = 0 then
    exit(AP_RSSI_NONE);
  Result := e.rssi_hist[(e.hist_head + e.hist_count - 1) mod AP_HIST_LEN];
end;

function APStoreCopySorted(out out_entries: TAPEntries): integer;
var
  i, j, n: integer;
  tmp: TAPEntry;
begin
  xSemaphoreTake(mutex, $FFFFFFFF);
  try
    n := entry_count;
    SetLength(out_entries, n);
    for i := 0 to n - 1 do
      out_entries[i] := entries[i];
  finally
    xSemaphoreGive(mutex);
  end;
  { insertion sort, strongest first - a 64-entry sort every scan cycle }
  for i := 1 to n - 1 do
  begin
    tmp := out_entries[i];
    j := i - 1;
    while (j >= 0) and (APLatestRssi(out_entries[j]) < APLatestRssi(tmp)) do
    begin
      out_entries[j + 1] := out_entries[j];
      Dec(j);
    end;
    out_entries[j + 1] := tmp;
  end;
  Result := n;
end;

end.
