{ appui - LVGL chrome: status bar, view toggles, raster chart canvas.
  50 ms tick: full redraw on UtilNeedFullPaint / revision change; during
  a util sweep, patch one channel column per dwell. Never paint while
  WalkActive (promiscuous RX) - PSRAM paint overlapping RX hangs MSPI.

  Rounded corners (requirement 7): status bar is dark-on-dark; chart
  margins keep axes/labels off the AMOLED cutouts.

  Views: CH (channel util + AP curves) and HIST (strongest RSSI%). }

unit appui;

{$mode objfpc}{$H+}

interface

uses
  c_bmgr,           { esp_err_t }
  c_lvgl,           { LVGL 9.6 working subset (esp-units submodule) }
  boardlvgl,
  SysUtils,         { IntToStr }
  c_wifi,           { esp_timer_get_time }
  chartdraw, chartplot, chartsmodel, apstore, scanner;

const
  SCREEN_W = 480;
  SCREEN_H = 480;

  { status bar: dark strip, info inset >=24 px from the screen edges }
  BAR_X = 4;
  BAR_Y = 4;
  BAR_W = SCREEN_W - 8;   { 472 }
  BAR_H = 36;

  { chart canvas: (0,44)-(480,480), ARGB8888 }
  CANVAS_X = 0;
  CANVAS_Y = 44;
  CANVAS_W = SCREEN_W;
  CANVAS_H = SCREEN_H - CANVAS_Y;

  { app.py/C-app chrome colors }
  SCREEN_BG    = $14161A;
  BAR_BG       = $1B1E24;
  TAB_ACTIVE   = $2D6CDF;
  TAB_IDLE     = $262A31;
  SCAN_ON      = $4CAF50;
  SCAN_OFF     = $555B60;
  TEXT_WHITE   = $FFFFFF;
  TEXT_DIM     = $9AA0A6;

  { montserrat_14: label top = cairo baseline - (16 - 3) }
  LABEL_BASELINE_OFFSET = 13;

  { label pool: channel view 9 dBm + 13 ch + 8 SSID = 30, history 5 }
  N_LABELS = 40;

  { view registry - add entries here as views grow }
  VIEW_COUNT = 2;
  VIEW_NAMES: array[0..VIEW_COUNT - 1] of PChar = ('CH', 'HIST');

var
  { the chart canvas pixel buffer; the program allocates it (GetMem,
    PSRAM) before UIStart }
  canvas_buf: pointer;

{ bring the chrome up (call once under TBoardLvgl.UILock, after Start) }
procedure UIStart;

implementation

type
  TlvTimerCb = procedure(timer: pointer); cdecl;
  TlvArea = record
    x1, y1, x2, y2: cint32;
  end;

{ app-side LVGL growth (the submodule is frozen; these land back in
  esp-units' c_lvgl when it next evolves) }
function lv_timer_create(cb: TlvTimerCb; period_ms: cuint;
  user_data: pointer): pointer; cdecl; external;
function lv_event_get_user_data(e: plv_event_t): pointer; cdecl; external;
function lv_obj_get_child(obj: plv_obj_t; idx: cint32): plv_obj_t; cdecl; external;
function lv_obj_invalidate_area(obj: plv_obj_t; const area: TlvArea): cint; cdecl; external;
procedure lv_obj_set_style_border_width(obj: plv_obj_t; value: cint32;
  selector: cuint); cdecl; external;
procedure lv_obj_set_style_pad_all(obj: plv_obj_t; value: cint32;
  selector: cuint); cdecl; external;
function wa_touch_indicator_start(indev: pointer): cbool; cdecl; external;

var
  canvas_obj: plv_obj_t;
  bar: plv_obj_t;
  dot: plv_obj_t;
  ap_label: plv_obj_t;
  view_btns: array[0..VIEW_COUNT - 1] of plv_obj_t;
  label_pool: array[0..N_LABELS - 1] of plv_obj_t;
  active_view: integer = 0;
  repaint_pending: byte = 0;   { a view switch awaits a walk-free tick }
  drawn_revision: longword = 0;
  drawn_util_rev: longword = 0;
  snap: TAPEntries;
  nets: array of TNet;

function Plot: TPlot; inline;
begin
  Result.Buf := canvas_buf;
  Result.W := CANVAS_W;
  Result.H := CANVAS_H;
end;

procedure SyncLabels(const labels: TChartLabels);
var
  i: integer;
begin
  for i := 0 to N_LABELS - 1 do
  begin
    if i < Length(labels) then
    begin
      lv_label_set_text(label_pool[i], PChar(labels[i].text));
      { canvas coordinates -> screen: canvas sits at (CANVAS_X, CANVAS_Y);
        labels are canvas children, so positions stay canvas-local }
      lv_obj_set_pos(label_pool[i], labels[i].x,
        labels[i].y - LABEL_BASELINE_OFFSET);
      lv_obj_set_style_text_color(label_pool[i],
        ColorMake((labels[i].rgb shr 16) and $FF,
                  (labels[i].rgb shr 8) and $FF,
                  labels[i].rgb and $FF), LV_STYLE_MAIN);
      lv_obj_remove_flag(label_pool[i], LV_OBJ_FLAG_HIDDEN);
    end
    else
      lv_obj_add_flag(label_pool[i], LV_OBJ_FLAG_HIDDEN);
  end;
end;

procedure RefreshSnapshot;
var
  i: integer;
begin
  APStoreCopySorted(snap);
  SetLength(nets, Length(snap));
  for i := 0 to Length(snap) - 1 do
  begin
    nets[i].ssid := snap[i].ssid;
    nets[i].channel := snap[i].channel;
    nets[i].width_mhz := 20;   { TODO: map wifi_bandwidth_t per AP }
    nets[i].dbm := APLatestRssi(snap[i]);
    if snap[i].color_idx <= High(chartsmodel.PALETTE) then
      nets[i].color := chartsmodel.PALETTE[snap[i].color_idx]
    else
      nets[i].color := chartsmodel.PALETTE_OTHER;
  end;
end;

{ the strongest 6 APs' rings as C-style history lines (C history_view.c):
  percent = (rssi+100)*100/55 clamped; color = the AP's palette slot or
  the shared gray; name = 8-char SSID or '(hidden)' }
procedure BuildHistLines(out lines: THistLines);
var
  i, k, n, pct: integer;
begin
  SetLength(lines, 0);
  for i := 0 to Length(snap) - 1 do
  begin
    if Length(lines) >= 6 then
      break;
    if snap[i].hist_count < 2 then
      continue;
    SetLength(lines, Length(lines) + 1);
    if snap[i].color_idx <= High(chartsmodel.PALETTE) then
      lines[High(lines)].color := chartsmodel.PALETTE[snap[i].color_idx]
    else
      lines[High(lines)].color := chartsmodel.PALETTE_OTHER;
    if snap[i].ssid <> '' then
      lines[High(lines)].name := Copy(snap[i].ssid, 1, 8)
    else
      lines[High(lines)].name := '(hidden)';
    n := snap[i].hist_count;
    SetLength(lines[High(lines)].pts, n);
    for k := 0 to n - 1 do
    begin
      pct := (snap[i].rssi_hist[(snap[i].hist_head + k) mod AP_HIST_LEN]
        + 100) * 100 div 55;
      if pct < 0 then
        pct := 0;
      if pct > 100 then
        pct := 100;
      lines[High(lines)].pts[k] := pct;
    end;
  end;
end;

procedure RepaintActive;
var
  labels: TChartLabels;
  hlines: THistLines;
  util: TUtil13;
  ch: integer;
  t0, t1, t2: int64;
begin
  t0 := esp_timer_get_time;
  for ch := 0 to 12 do
    util[ch] := scanner.ChannelUtilPM(ch + 1);
  case active_view of
    0: DrawChannelView(Plot, nets, 0, util, labels);
    1:
    begin
      BuildHistLines(hlines);
      DrawHistoryView(Plot, hlines, labels);
    end;
  end;
  t1 := esp_timer_get_time;
  SyncLabels(labels);
  lv_obj_invalidate(canvas_obj);
  t2 := esp_timer_get_time;
  writeln('PROF-O2: FullRepaint view=', active_view, ' nets=', Length(nets),
    ' | chartdraw=', t1 - t0, ' us | sync_labels=', t2 - t1, ' us');
end;

procedure InvalidateChannelStrip(ch: integer);
var
  plot_w, plot_h, x0, x1: integer;
  ax: TAxisMap;
  area: TlvArea;
begin
  if (ch < CH_MIN) or (ch > CH_MAX) then
    exit;
  plot_w := CANVAS_W - CH_ML - CH_MR;
  plot_h := CANVAS_H - CH_MT - CH_MB;
  ax := ChAxis(plot_w);
  x0 := PlotRound(AxPix(ax, ch - 0.5));
  x1 := PlotRound(AxPix(ax, ch + 0.5));
  if x0 < CH_ML then
    x0 := CH_ML;
  if x1 > CH_ML + plot_w then
    x1 := CH_ML + plot_w;
  if x1 < x0 then
    exit;
  area.x1 := CANVAS_X + x0;
  area.y1 := CANVAS_Y + CH_MT;
  area.x2 := CANVAS_X + x1;
  area.y2 := CANVAS_Y + CH_MT + plot_h - 1;
  lv_obj_invalidate_area(canvas_obj, area);
end;

procedure TickCb(timer: pointer); cdecl;
var
  rev, util_rev, count: longword;
  status_buf: string;
  need_paint: boolean;
  tp0, tp1: int64;
  pch: integer;
begin
  if canvas_buf = nil then
    exit;

  rev := APStoreRevision;
  util_rev := scanner.UtilRevision;
  count := APStoreCount;

  status_buf := 'AP: ' + IntToStr(count);
  lv_label_set_text(ap_label, PChar(status_buf));
  if ScannerBusy <> 0 then
    lv_obj_set_style_bg_color(dot, ColorMake((SCAN_ON shr 16) and $FF,
      (SCAN_ON shr 8) and $FF, SCAN_ON and $FF), LV_STYLE_MAIN)
  else
    lv_obj_set_style_bg_color(dot, ColorMake((SCAN_OFF shr 16) and $FF,
      (SCAN_OFF shr 8) and $FF, SCAN_OFF and $FF), LV_STYLE_MAIN);

  if scanner.WalkActive <> 0 then
  begin
    repaint_pending := 1;
    exit;
  end;

  { Forced full redraw (after scan / after util sweep). Clear the flag
    only after paint so the scanner handshake WaitUiPainted can proceed. }
  if scanner.UtilNeedFullPaint <> 0 then
  begin
    drawn_revision := rev;
    drawn_util_rev := util_rev;
    repaint_pending := 0;
    RefreshSnapshot;
    RepaintActive;
    scanner.UtilNeedFullPaint := 0;
    exit;
  end;

  { Between dwells: patch only the channel strip that just finished. }
  if (scanner.UtilDeferPaint <> 0) and (scanner.UtilPatchCh <> 0) and
    (active_view = 0) then
  begin
    if Length(nets) = 0 then
      RefreshSnapshot;
    pch := scanner.UtilPatchCh;
    tp0 := esp_timer_get_time;
    PatchChannelUtilColumn(Plot, pch,
      scanner.ChannelUtilPM(pch), nets);
    tp1 := esp_timer_get_time;
    InvalidateChannelStrip(pch);
    scanner.UtilPatchCh := 0;
    drawn_util_rev := util_rev;
    writeln('PROF-O2: ColPatch ch=', pch, ' nets=', Length(nets),
      ' | patch_draw=', tp1 - tp0, ' us');
    exit;
  end;

  need_paint := (rev <> drawn_revision) or (util_rev <> drawn_util_rev) or
    (repaint_pending <> 0);
  if need_paint and (scanner.UtilDeferPaint <> 0) then
  begin
    repaint_pending := 1;
    exit;
  end;
  if need_paint then
  begin
    drawn_revision := rev;
    drawn_util_rev := util_rev;
    repaint_pending := 0;
    RefreshSnapshot;
    RepaintActive;
  end;
end;

procedure SwitchView(v: integer); forward;

procedure ViewBtnCb(e: plv_event_t); cdecl;
var
  v: integer;
begin
  v := PtrInt(lv_event_get_user_data(e));
  if (v >= 0) and (v < VIEW_COUNT) and (v <> active_view) then
  begin
    SwitchView(v);
    { never repaint from the event callback directly: a PSRAM paint
      burst overlapping the promiscuous walk hard-hangs the MSPI
      arbiter - mark it pending; the tick repaints in a walk-free
      window (<= ~1.5 s) }
    repaint_pending := 1;
  end;
end;

procedure StyleViewBtn(btn: plv_obj_t; active: boolean);
var
  bg: longword;
  fg: longword;
begin
  if active then
  begin
    bg := TAB_ACTIVE;
    fg := TEXT_WHITE;
  end
  else
  begin
    bg := TAB_IDLE;
    fg := TEXT_DIM;
  end;
  lv_obj_set_style_bg_color(btn, ColorMake((bg shr 16) and $FF,
    (bg shr 8) and $FF, bg and $FF), LV_STYLE_MAIN);
  lv_obj_set_style_text_color(lv_obj_get_child(btn, 0),
    ColorMake((fg shr 16) and $FF, (fg shr 8) and $FF, fg and $FF),
    LV_STYLE_MAIN);
end;

procedure SwitchView(v: integer);
var
  i: integer;
begin
  active_view := v;
  for i := 0 to VIEW_COUNT - 1 do
    StyleViewBtn(view_btns[i], i = v);
end;

procedure UIStart;
var
  i: integer;
  btn_lbl: plv_obj_t;
  title: plv_obj_t;
  btn_x: integer;
  status_buf: string;
begin
  lv_obj_set_style_bg_color(lv_screen_active,
    ColorMake((SCREEN_BG shr 16) and $FF, (SCREEN_BG shr 8) and $FF,
      SCREEN_BG and $FF), LV_STYLE_MAIN);

  { ---- status bar ---- }
  bar := lv_obj_create(lv_screen_active);
  lv_obj_set_pos(bar, BAR_X, BAR_Y);
  lv_obj_set_size(bar, BAR_W, BAR_H);
  lv_obj_set_style_bg_color(bar, ColorMake((BAR_BG shr 16) and $FF,
    (BAR_BG shr 8) and $FF, BAR_BG and $FF), LV_STYLE_MAIN);
  lv_obj_remove_flag(bar, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_border_width(bar, 0, LV_STYLE_MAIN);
  lv_obj_set_style_pad_all(bar, 0, LV_STYLE_MAIN);

  title := lv_label_create(bar);
  lv_label_set_text(title, 'WiFi Analyzer');
  lv_obj_set_style_text_color(title,
    ColorMake($FF, $FF, $FF), LV_STYLE_MAIN);
  lv_obj_set_pos(title, 20, 10);   { >=24 px from the screen corner }

  dot := lv_obj_create(bar);
  lv_obj_set_size(dot, 10, 10);
  lv_obj_set_pos(dot, 180, 13);
  lv_obj_set_style_border_width(dot, 0, LV_STYLE_MAIN);
  lv_obj_set_style_bg_color(dot, ColorMake((SCAN_OFF shr 16) and $FF,
    (SCAN_OFF shr 8) and $FF, SCAN_OFF and $FF), LV_STYLE_MAIN);
  lv_obj_remove_flag(dot, LV_OBJ_FLAG_SCROLLABLE);

  ap_label := lv_label_create(bar);
  status_buf := 'AP: 0';
  lv_label_set_text(ap_label, PChar(status_buf));
  lv_obj_set_style_text_color(ap_label,
    ColorMake((TEXT_DIM shr 16) and $FF, (TEXT_DIM shr 8) and $FF,
      TEXT_DIM and $FF), LV_STYLE_MAIN);
  lv_obj_set_pos(ap_label, 200, 10);

  for i := 0 to VIEW_COUNT - 1 do
  begin
    btn_x := BAR_W - 12 - (VIEW_COUNT - i) * 66;
    view_btns[i] := lv_button_create(bar);
    lv_obj_set_pos(view_btns[i], btn_x, 5);
    lv_obj_set_size(view_btns[i], 60, 26);
    lv_obj_set_style_pad_all(view_btns[i], 0, LV_STYLE_MAIN);
    lv_obj_add_event_cb(view_btns[i], @ViewBtnCb, LV_EVENT_CLICKED,
      pointer(PtrInt(i)));
    btn_lbl := lv_label_create(view_btns[i]);
    lv_label_set_text(btn_lbl, VIEW_NAMES[i]);
    lv_obj_center(btn_lbl);
    StyleViewBtn(view_btns[i], i = 0);
  end;

  { ---- chart canvas ---- }
  canvas_obj := lv_canvas_create(lv_screen_active);
  lv_canvas_set_buffer(canvas_obj, canvas_buf, CANVAS_W, CANVAS_H,
    LV_COLOR_FORMAT_ARGB8888);
  lv_obj_remove_flag(canvas_obj, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_style_pad_all(canvas_obj, 0, LV_STYLE_MAIN);
  lv_obj_set_style_border_width(canvas_obj, 0, LV_STYLE_MAIN);
  lv_obj_set_pos(canvas_obj, CANVAS_X, CANVAS_Y);
  lv_obj_set_size(canvas_obj, CANVAS_W, CANVAS_H);

  { ---- overlay label pool ---- }
  for i := 0 to N_LABELS - 1 do
  begin
    label_pool[i] := lv_label_create(canvas_obj);
    lv_obj_set_style_text_font(label_pool[i], @lv_font_montserrat_14,
      LV_STYLE_MAIN);
    lv_label_set_text(label_pool[i], '');
    lv_obj_add_flag(label_pool[i], LV_OBJ_FLAG_HIDDEN);
  end;

  { ---- first paint + the revision-gated tick ---- }
  SwitchView(0);
  RefreshSnapshot;
  RepaintActive;
  lv_timer_create(@TickCb, 50, nil);
  if not wa_touch_indicator_start(TBoardLvgl.Touch) then
    writeln('WA: W touch indicator unavailable');
end;

end.
