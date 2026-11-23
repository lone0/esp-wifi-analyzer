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

  { chart canvas: (0,40)-(480,480), ARGB8888 (touches bottom of status bar) }
  CANVAS_X = 0;
  CANVAS_Y = 40;
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

  { canvas gesture codes (matched with wa_gesture_obj_cb in wifi_cfg_shim.c) }
  WA_GESTURE_NONE        = 0;
  WA_GESTURE_SWIPE_LEFT  = 1;
  WA_GESTURE_SWIPE_RIGHT = 2;
  WA_GESTURE_SWIPE_UP    = 3;
  WA_GESTURE_SWIPE_DOWN  = 4;
  WA_GESTURE_DRAG_BEGIN  = 5;
  WA_GESTURE_DRAG_MOVE   = 6;
  WA_GESTURE_DRAG_END    = 7;
  WA_GESTURE_DOUBLE_TAP  = 8;

var
  { the chart canvas pixel buffer; the program allocates it (GetMem,
    PSRAM) before UIStart }
  canvas_buf: pointer;

{ bring the chrome up (call once under TBoardLvgl.UILock, after Start) }
procedure UIStart;

implementation

type
  TlvTimerCb = procedure(timer: pointer); cdecl;
  TWaGestureCb = procedure(gtype, x, y, dx, dy: cint32); cdecl;
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
procedure wa_ui_bus_acquire; cdecl; external;
procedure wa_gesture_attach(target: plv_obj_t; cb: TWaGestureCb); cdecl; external;
procedure wa_gesture_set_state(active_view, panel_open: cint32); cdecl; external;
procedure wa_battery_widget_create(bar: plv_obj_t); cdecl; external;
procedure wa_battery_widget_update; cdecl; external;

var
  canvas_obj: plv_obj_t;
  bar: plv_obj_t;
  dot: plv_obj_t;
  ap_label: plv_obj_t;
  quick_panel: plv_obj_t;
  view_btns: array[0..VIEW_COUNT - 1] of plv_obj_t;
  quick_span_btns: array[0..2] of plv_obj_t;
  label_pool: array[0..N_LABELS - 1] of plv_obj_t;
  active_view: integer = 0;
  active_span_mode: integer = 0;
  quick_panel_open: boolean = false;
  drag_start_v0: Single = CH_MIN;
  drag_start_v1: Single = CH_MAX;
  last_drawn_v0: Single = CH_MIN;
  repaint_pending: byte = 0;   { a view switch awaits a walk-free tick }
  drawn_revision: longword = 0;
  drawn_util_rev: longword = 0;
  last_ap_count: longint = -1;
  last_scan_busy: shortint = -1;
  last_bat_poll_us: int64 = 0;
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
  i, n, rssi: integer;
begin
  APStoreCopySorted(snap);
  SetLength(nets, Length(snap));
  n := 0;
  for i := 0 to Length(snap) - 1 do
  begin
    rssi := APLatestRssi(snap[i]);
    if rssi < chartsmodel.DBM_MIN then
      continue;
    nets[n].ssid := snap[i].ssid;
    nets[n].channel := snap[i].channel;
    nets[n].width_mhz := 20;   { TODO: map wifi_bandwidth_t per AP }
    nets[n].dbm := rssi;
    if snap[i].color_idx <= High(chartsmodel.PALETTE) then
      nets[n].color := chartsmodel.PALETTE[snap[i].color_idx]
    else
      nets[n].color := chartsmodel.PALETTE_OTHER;
    Inc(n);
  end;
  SetLength(nets, n);
end;

{ Colored APs' rings as history lines in dBm (-80..-20, aligned with CH view);
  uncolored (gray) APs and APs weaker than -80 dBm are excluded. }
procedure BuildHistLines(out lines: THistLines);
var
  i, k, n, dbm: integer;
begin
  SetLength(lines, 0);
  for i := 0 to Length(snap) - 1 do
  begin
    if Length(lines) >= 6 then
      break;
    if snap[i].color_idx > High(chartsmodel.PALETTE) then
      continue;
    if APLatestRssi(snap[i]) < chartsmodel.DBM_MIN then
      continue;
    if snap[i].hist_count < 2 then
      continue;
    SetLength(lines, Length(lines) + 1);
    lines[High(lines)].color := chartsmodel.PALETTE[snap[i].color_idx];
    if snap[i].ssid <> '' then
      lines[High(lines)].name := Copy(snap[i].ssid, 1, 8)
    else
      lines[High(lines)].name := '(hidden)';
    n := snap[i].hist_count;
    SetLength(lines[High(lines)].pts, n);
    for k := 0 to n - 1 do
    begin
      dbm := snap[i].rssi_hist[(snap[i].hist_head + k) mod AP_HIST_LEN];
      if dbm < chartsmodel.DBM_MIN then
        dbm := chartsmodel.DBM_MIN;
      if dbm > chartsmodel.DBM_MAX then
        dbm := chartsmodel.DBM_MAX;
      lines[High(lines)].pts[k] := dbm;
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
  wa_ui_bus_acquire;
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
  if x0 < 0 then
    x0 := 0;
  if x1 >= CANVAS_W then
    x1 := CANVAS_W - 1;
  if x1 < x0 then
    exit;
  area.x1 := (CANVAS_X + x0) and (not 1);
  area.y1 := (CANVAS_Y + CH_MT) and (not 1);
  area.x2 := (CANVAS_X + x1) or 1;
  area.y2 := (CANVAS_Y + CH_MT + plot_h + 1) or 1;
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

  { User-initiated view switch preempts everything immediately. }
  if repaint_pending <> 0 then
  begin
    drawn_revision := rev;
    drawn_util_rev := util_rev;
    repaint_pending := 0;
    if Length(nets) = 0 then
      RefreshSnapshot;
    RepaintActive;
    exit;
  end;

  { While a background channel dwell runs and no user action is pending,
    stay off the MSPI/PSRAM bus so the 100 ms dwell completes cleanly. }
  if scanner.WalkActive <> 0 then
    exit;

  if longint(count) <> last_ap_count then
  begin
    last_ap_count := longint(count);
    status_buf := 'AP: ' + IntToStr(count);
    lv_label_set_text(ap_label, PChar(status_buf));
  end;
  if shortint(ScannerBusy) <> last_scan_busy then
  begin
    last_scan_busy := shortint(ScannerBusy);
    if ScannerBusy <> 0 then
      lv_obj_set_style_bg_color(dot, ColorMake((SCAN_ON shr 16) and $FF,
        (SCAN_ON shr 8) and $FF, SCAN_ON and $FF), LV_STYLE_MAIN)
    else
      lv_obj_set_style_bg_color(dot, ColorMake((SCAN_OFF shr 16) and $FF,
        (SCAN_OFF shr 8) and $FF, SCAN_OFF and $FF), LV_STYLE_MAIN);
  end;

  tp0 := esp_timer_get_time;
  if (last_bat_poll_us = 0) or (tp0 - last_bat_poll_us >= 5000000) then
  begin
    last_bat_poll_us := tp0;
    wa_battery_widget_update;
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
  if (scanner.UtilDeferPaint <> 0) and (scanner.UtilPatchCh <> 0) then
  begin
    pch := scanner.UtilPatchCh;
    if active_view = 0 then
    begin
      if Length(nets) = 0 then
        RefreshSnapshot;
      wa_ui_bus_acquire;
      tp0 := esp_timer_get_time;
      PatchChannelUtilColumn(Plot, pch,
        scanner.ChannelUtilPM(pch), nets);
      tp1 := esp_timer_get_time;
      InvalidateChannelStrip(pch);
      writeln('PROF-O2: ColPatch ch=', pch, ' nets=', Length(nets),
        ' | patch_draw=', tp1 - tp0, ' us');
    end;
    scanner.UtilPatchCh := 0;
    drawn_util_rev := util_rev;
    exit;
  end;

  need_paint := (rev <> drawn_revision) or (util_rev <> drawn_util_rev);
  if need_paint and (scanner.UtilDeferPaint = 0) then
  begin
    drawn_revision := rev;
    drawn_util_rev := util_rev;
    RefreshSnapshot;
    RepaintActive;
  end;
end;

procedure SwitchView(v: integer); forward;
procedure PerformViewSwitch(v: integer); forward;

procedure ViewBtnCb(e: plv_event_t); cdecl;
var
  v: integer;
begin
  v := PtrInt(lv_event_get_user_data(e));
  PerformViewSwitch(v);
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
  wa_gesture_set_state(active_view, Ord(quick_panel_open));
  for i := 0 to VIEW_COUNT - 1 do
    StyleViewBtn(view_btns[i], i = v);
end;

procedure PerformViewSwitch(v: integer);
begin
  if (v < 0) or (v >= VIEW_COUNT) or (v = active_view) then
    exit;
  wa_ui_bus_acquire;
  SwitchView(v);
  drawn_revision := APStoreRevision;
  drawn_util_rev := scanner.UtilRevision;
  repaint_pending := 0;
  if Length(nets) = 0 then
    RefreshSnapshot;
  RepaintActive;
end;

procedure ShowQuickPanel(open: boolean);
begin
  if quick_panel = nil then
    exit;
  wa_ui_bus_acquire;
  quick_panel_open := open;
  wa_gesture_set_state(active_view, Ord(quick_panel_open));
  if open then
    lv_obj_remove_flag(quick_panel, LV_OBJ_FLAG_HIDDEN)
  else
    lv_obj_add_flag(quick_panel, LV_OBJ_FLAG_HIDDEN);
end;

procedure StyleQuickSpanBtns(mode: integer);
var
  i: integer;
begin
  active_span_mode := mode;
  for i := 0 to 2 do
    if quick_span_btns[i] <> nil then
      StyleViewBtn(quick_span_btns[i], i = mode);
end;

procedure ApplySpanPreset(mode: integer);
begin
  StyleQuickSpanBtns(mode);
  case mode of
    0: SetChViewport(1.0, 13.0, -1.0, 15.0);
    1: SetChViewport(1.0, 7.0, 0.5, 13.5);
    2: SetChViewport(36.0, 68.0, 32.0, 169.0);
  end;
  last_drawn_v0 := ChViewStart;
  if active_view <> 0 then
    SwitchView(0);
  if Length(nets) = 0 then
    RefreshSnapshot;
  RepaintActive;
end;

procedure ClearHistoryAndRescan;
begin
  wa_ui_bus_acquire;
  scanner.ScannerRequestRescan;
  SetLength(snap, 0);
  SetLength(nets, 0);
  last_ap_count := 0;
  lv_label_set_text(ap_label, 'AP: 0');
  drawn_revision := APStoreRevision;
  drawn_util_rev := scanner.UtilRevision;
  repaint_pending := 0;
  RepaintActive;
end;

procedure QuickActionCb(e: plv_event_t); cdecl;
var
  act: integer;
begin
  act := PtrInt(lv_event_get_user_data(e));
  case act of
    0, 1, 2:
    begin
      ShowQuickPanel(false);
      ApplySpanPreset(act);
    end;
    3:
    begin
      ShowQuickPanel(false);
      ClearHistoryAndRescan;
    end;
    4:
    begin
      ShowQuickPanel(false);
      PerformViewSwitch(1 - active_view);
    end;
    5:
      ShowQuickPanel(false);
  end;
end;

procedure OnCanvasGesture(gtype, x, y, dx, dy: cint32); cdecl;
var
  plot_w: integer;
  span, dval: Single;
begin
  case gtype of
    WA_GESTURE_SWIPE_DOWN:
    begin
      writeln('GESTURE: SWIPE_DOWN -> Quick Action Panel open');
      ShowQuickPanel(true);
    end;
    WA_GESTURE_SWIPE_UP:
    begin
      if quick_panel_open then
      begin
        writeln('GESTURE: SWIPE_UP -> Quick Action Panel close');
        ShowQuickPanel(false);
      end;
    end;
    WA_GESTURE_SWIPE_LEFT, WA_GESTURE_SWIPE_RIGHT:
    begin
      if quick_panel_open then
        ShowQuickPanel(false);
      writeln('GESTURE: EDGE_SWIPE dir=', gtype, ' -> switch view to ', 1 - active_view);
      PerformViewSwitch(1 - active_view);
    end;
    WA_GESTURE_DRAG_BEGIN:
    begin
      if (active_view = 0) and (not quick_panel_open) then
      begin
        drag_start_v0 := ChViewStart;
        drag_start_v1 := ChViewEnd;
        last_drawn_v0 := ChViewStart;
        writeln('GESTURE: DRAG_BEGIN ch_view=[', Round(drag_start_v0), '..', Round(drag_start_v1), ']');
      end;
    end;
    WA_GESTURE_DRAG_MOVE:
    begin
      if (active_view = 0) and (not quick_panel_open) then
      begin
        plot_w := CANVAS_W - CH_ML - CH_MR;
        span := drag_start_v1 - drag_start_v0;
        dval := -dx * span / plot_w;
        SetChViewport(drag_start_v0 + dval, drag_start_v1 + dval, ChScrollMin, ChScrollMax);
        if Abs(ChViewStart - last_drawn_v0) >= 0.15 then
        begin
          last_drawn_v0 := ChViewStart;
          RepaintActive;
        end;
      end;
    end;
    WA_GESTURE_DRAG_END:
    begin
      if (active_view = 0) and (not quick_panel_open) then
      begin
        if Abs(ChViewStart - last_drawn_v0) >= 0.01 then
        begin
          last_drawn_v0 := ChViewStart;
          RepaintActive;
        end;
        writeln('GESTURE: DRAG_END ch_view=[', Round(ChViewStart), '..', Round(ChViewEnd), ']');
      end;
    end;
    WA_GESTURE_DOUBLE_TAP:
    begin
      if quick_panel_open then
        ShowQuickPanel(false)
      else
      begin
        writeln('GESTURE: DOUBLE_TAP -> Clear history and rescan');
        ClearHistoryAndRescan;
      end;
    end;
  end;
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
  lv_obj_set_pos(title, 18, 10);

  dot := lv_obj_create(bar);
  lv_obj_set_size(dot, 10, 10);
  lv_obj_set_pos(dot, 148, 13);
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
  lv_obj_set_pos(ap_label, 164, 10);

  wa_battery_widget_create(bar);

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

  { ---- pull-down quick action panel (hidden until top-down swipe) ---- }
  quick_panel := lv_obj_create(lv_screen_active);
  lv_obj_set_pos(quick_panel, 12, 44);
  lv_obj_set_size(quick_panel, SCREEN_W - 24, 134);
  lv_obj_set_style_bg_color(quick_panel, ColorMake($1E, $22, $2A), LV_STYLE_MAIN);
  lv_obj_set_style_border_width(quick_panel, 2, LV_STYLE_MAIN);
  lv_obj_set_style_pad_all(quick_panel, 8, LV_STYLE_MAIN);
  lv_obj_remove_flag(quick_panel, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_add_flag(quick_panel, LV_OBJ_FLAG_HIDDEN);

  title := lv_label_create(quick_panel);
  lv_label_set_text(title, 'Quick Actions  (Swipe Up / Close)');
  lv_obj_set_style_text_color(title, ColorMake($FF, $FF, $FF), LV_STYLE_MAIN);
  lv_obj_set_pos(title, 8, 2);

  for i := 0 to 2 do
  begin
    quick_span_btns[i] := lv_button_create(quick_panel);
    lv_obj_set_pos(quick_span_btns[i], 6 + i * 144, 30);
    lv_obj_set_size(quick_span_btns[i], 136, 36);
    lv_obj_set_style_pad_all(quick_span_btns[i], 0, LV_STYLE_MAIN);
    lv_obj_add_event_cb(quick_span_btns[i], @QuickActionCb, LV_EVENT_CLICKED,
      pointer(PtrInt(i)));
    btn_lbl := lv_label_create(quick_span_btns[i]);
    case i of
      0: lv_label_set_text(btn_lbl, '2.4G (1-13)');
      1: lv_label_set_text(btn_lbl, '2.4G Zoom');
      2: lv_label_set_text(btn_lbl, '5G (36-165)');
    end;
    lv_obj_center(btn_lbl);
  end;
  StyleQuickSpanBtns(0);

  for i := 3 to 5 do
  begin
    btn_lbl := lv_button_create(quick_panel);
    lv_obj_set_pos(btn_lbl, 6 + (i - 3) * 144, 76);
    lv_obj_set_size(btn_lbl, 136, 36);
    lv_obj_set_style_pad_all(btn_lbl, 0, LV_STYLE_MAIN);
    lv_obj_add_event_cb(btn_lbl, @QuickActionCb, LV_EVENT_CLICKED,
      pointer(PtrInt(i)));
    title := lv_label_create(btn_lbl);
    case i of
      3: lv_label_set_text(title, 'Clear & Scan');
      4: lv_label_set_text(title, 'Toggle View');
      5: lv_label_set_text(title, 'Close Menu');
    end;
    lv_obj_center(title);
    StyleViewBtn(btn_lbl, i = 3);
  end;

  { ---- first paint + the revision-gated tick ---- }
  if not wa_touch_indicator_start(TBoardLvgl.Touch) then
    writeln('WA: W touch indicator unavailable');
  wa_gesture_attach(canvas_obj, @OnCanvasGesture);
  SwitchView(0);
  RefreshSnapshot;
  RepaintActive;
  lv_timer_create(@TickCb, 15, nil);
end;

end.
