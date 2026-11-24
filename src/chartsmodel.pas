{ chartsmodel - the WiFi semantic layer: maps scan data onto the generic
  chartplot renderer. Everything WiFi-specific lives here (channel axis,
  dBm axis, SSID label text, palette assignment, width_mhz semantics);
  everything generic lives in chartplot (axis maps, grid, fill+stroke
  series, dashed reference line, label coordinates).

  Transcription sources (yeager/wifi-analyzer app.py, fetched 2026-11-15):
    - ChannelDrawingArea._draw (978-1096): margins 50/20/20/40, channels
      1..13, dBm -100..-20, gridlines, bell curves (61 gaussian samples,
      fill alpha 0.3, stroke alpha 0.9 width 2), SSID labels, focused-
      channel dashed highlight (width 3, dash 5:3).
    - SignalHistoryDrawingArea._draw (1179-1207): margins 42/18/18/30,
      percent gridlines (cairo default width 2), signal polyline
      rgb(0.25,0.65,1.0) width 2, x spread over point index.

  Ink compensation: app.py draws 0.5 px gridlines at alpha 0.3 - the
  equivalent 1 px raster line carries alpha 0.15 (GRID_A 38: total ink =
  coverage x alpha is what must match, verified pixel-exact vs cairo).
  The bell fill (0.3) and stroke (0.9) are true area/stroke styles and
  keep their alpha values.

  Sampling: the bell curves are sampled at 61 points exactly like app.py
  (and cairo draws them as 61-point polylines) - chartplot interpolates
  between samples, matching the reference geometry. Percentages for the
  history view: (rssi + 100) * 100 / 55 clamped (C wifi_scanner formula).

  Labels are emitted in cairo show_text semantics (BASELINE coordinates,
  app.py exact placement formulas); the UI layer converts baseline ->
  LVGL label top. Target-neutral like chartplot. }

unit chartsmodel;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,   { IntToStr for the label texts }
  Math,       { exp }
  chartdraw,  { the 5 pixel primitives }
  chartplot;  { the generic chart renderer }

const
  { app.py colors, float rgb * 255 (cairo 1.0 = 255) }
  BG_HEX      = $26262E;  { 0.15, 0.15, 0.18 }
  GRID_HEX    = $666666;  { 0.4, 0.4, 0.4 }
  HGRID_HEX   = $8C8C8C;  { 0.55, 0.55, 0.55 }
  DIM_HEX     = $999999;  { 0.6, 0.6, 0.6 - channel-view text }
  DIM_H_HEX   = $B3B3B3;  { 0.7, 0.7, 0.7 - history-view text }
  FOCUS_HEX   = $FFD91A;  { 1.0, 0.85, 0.1 }
  HIST_HEX    = $40A6FF;  { 0.25, 0.65, 1.0 }

  { cairo alpha * 255 }
  FILL_A   = 76;   { 0.3 - bell fill (a true 0.3 area fill) }
  STROKE_A = 230;  { 0.9 - bell outline }
  HGRID_A  = 89;   { 0.35 - history grid (true 2px @0.35) }
  { the channel grid is cairo 0.5px @0.3 - total ink = coverage*alpha =
    0.15; our 1px line matches cairo's pixel values at alpha 38 }
  GRID_A   = 38;

  { ChannelDrawingArea margins + axis ranges }
  CH_ML = 20;
  CH_MR = 20;
  CH_MT = 0;
  CH_MB = 40;
  CH_MIN = 1;
  CH_MAX = 13;
  DBM_MIN = -80;
  DBM_MAX = -20;

  { Hardware-supported 5 GHz channels on Mosaico (ESP32-S31 esp_wifi_types_generic.h
    wifi_5g_channel_bit_t, 36..165):
      UNII-1 & UNII-2A: 36, 40, 44, 48, 52, 56, 60, 64  (cols 1..8)
      [68..96 unsupported by hardware -> skipped]
      UNII-2C (DFS):    100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144 (cols 9..20)
      [148 unsupported -> skipped]
      UNII-3:           149, 153, 157, 161, 165 (cols 21..25)
    Each column has the same width as 1 channel in 2.4 GHz view and
    accommodates 4 channel numbers (e.g. col 1 = 36/37/38/39 displayed as 36). }
  CH5G_COUNT = 25;
  CH5G_CHANNELS: array[1..CH5G_COUNT] of integer = (
    36, 40, 44, 48, 52, 56, 60, 64,
    100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144,
    149, 153, 157, 161, 165
  );

  { SignalHistoryDrawingArea margins (aligned with CH view Y-axis) }
  HI_ML = 42;
  HI_MR = 18;
  HI_MT = CH_MT;
  HI_MB = CH_MB;

  { caps: MAX_CURVES 24 is ours (C caps at 12 for its ~280 ms vector
    rasterization; our raster path is far cheaper). The C label cap is
    10. PALETTE_SIZE is the exclusive color pool size. }
  MAX_CURVES = 24;
  PALETTE_SIZE = 8;

type
  { one AP as the charts see it }
  TNet = record
    ssid: string;
    channel: integer;
    width_mhz: integer;
    dbm: integer;
    color: LongWord;   { resolved render color: palette slot or the
                         shared fallback }
  end;
  TNetArray = array of TNet;

  { per-channel occupancy per-mille; fixed bounds avoid open-array High
    surprises at the unit boundary }
  TUtil13 = array[0..12] of integer;

const
  { the 8 exclusive palette slots (colors[0..7] of the C app's palette,
    ChannelDrawingArea._draw line 1047) - granted per AP by apstore's
    APStoreAssignColors, lifetime until eviction }
  PALETTE: array[0..PALETTE_SIZE - 1] of LongWord = (
    $3399FF,  { 0.2, 0.6, 1.0 }
    $FF664D,  { 1.0, 0.4, 0.3 }
    $4DE666,  { 0.3, 0.9, 0.4 }
    $FFCC33,  { 1.0, 0.8, 0.2 }
    $CC4DE6,  { 0.8, 0.3, 0.9 }
    $33E6E6,  { 0.2, 0.9, 0.9 }
    $FF8000,  { 1.0, 0.5, 0.0 }
    $9999FF   { 0.6, 0.6, 1.0 }
  );
  { the 9th, shared: every uncolored AP renders with this }
  PALETTE_OTHER: LongWord = $8C8C8C;   { neutral gray for the uncolored }

{ channel-axis map: current visible channel window across the plot width }
function ChAxis(plot_w: integer): TAxisMap;
procedure SetChViewport(v0, v1, min_limit, max_limit: Single);
procedure ScrollChViewportByPixels(dx_px, plot_w: integer);
procedure ResetChViewport;
procedure SetChBand5G(enable: boolean);
function Ch5GToColPos(ch: integer): Single; inline;
procedure BuildFake5GNets(out out_nets: TNetArray);

var
  ChBand5G: boolean = false;
  ChViewStart: Single = CH_MIN;
  ChViewEnd: Single = CH_MAX;
  ChScrollMin: Single = -1.0;
  ChScrollMax: Single = 15.0;
{ dBm-axis map: DBM_MIN at the plot bottom, DBM_MAX at the top }
function DbmAxis(plot_h: integer): TAxisMap;

{ ChannelDrawingArea._draw on the plot buffer; nets arrive STRONGEST-FIRST
  and are painted weakest-first (reverse iteration). focused: channel
  number for the dashed highlight, 0 = none. util_pm: per-channel
  occupancy per-mille 0..1000, -1 = no data (pure black column). Labels
  come back in cairo baseline coordinates (app.py exact placement). }
procedure DrawChannelView(const p: TPlot; const nets: array of TNet;
  focused: integer; const util_pm: TUtil13;
  out labels: TChartLabels);

{ Repaint only channel ch's util strip (band + grid + overlapping bells).
  Much cheaper than DrawChannelView; used between util dwells. }
procedure PatchChannelUtilColumn(const p: TPlot; ch: integer;
  util_pm: integer; const nets: array of TNet);

{ THistLine - one AP's history polyline payload (appui builds them from
  the strongest snapshot entries; the drawer renders them C-style) }
type
  TPctArray = array of Single;   { 0..100 percentages, oldest -> newest }
  THistLine = record
    color: LongWord;   { resolved render color (palette slot or gray) }
    name: string;      { SSID truncated to 8 chars, '(hidden)' if empty }
    pts: TPctArray;
  end;
  THistLines = array of THistLine;

{ history view, C history_view.c port (supersedes the app.py single-line
  reference): the strongest 6 APs each get one polyline over a fixed
  60-sample scrolling window (right-aligned while the ring fills),
  weakest painted first, every line in its AP's own color; legend strip
  along the bottom (chip + 8-char SSID per rank slot, empty slots
  blank). Percent = (rssi+100)*100/55 clamped, the C formula. }
procedure DrawHistoryView(const p: TPlot; const lines: THistLines;
  out labels: TChartLabels);
procedure BuildFake5GHistLines(out lines: THistLines);

implementation

{ C wifi_analyzer channel_view.c util_band_color via lv_color_hsv_to_rgb }
function wa_util_band_rgb(permille: LongInt): LongWord; cdecl; external;
function expf(x: Single): Single; cdecl; external;

var
  gauss_amp: array[0..60] of Single;
  gauss_norm: array[0..60] of Single;
  gauss_ready: boolean = false;

procedure EnsureGaussLut;
var
  k: integer;
  u: Single;
begin
  if gauss_ready then
    exit;
  for k := 0 to 60 do
  begin
    u := -2.0 + (4.0 * k) / 60.0;
    gauss_norm[k] := u;
    gauss_amp[k] := expf(-u * u * 2.0);
  end;
  gauss_ready := true;
end;

function ChAxis(plot_w: integer): TAxisMap;
begin
  Result.Pix0 := CH_ML;
  Result.Pix1 := CH_ML + plot_w;
  Result.Val0 := ChViewStart;
  Result.Val1 := ChViewEnd;
end;

procedure SetChViewport(v0, v1, min_limit, max_limit: Single);
var
  span: Single;
begin
  span := v1 - v0;
  if span < 4.0 then
    span := 4.0;
  ChScrollMin := min_limit;
  ChScrollMax := max_limit;
  if v0 < ChScrollMin then
  begin
    v0 := ChScrollMin;
    v1 := v0 + span;
  end;
  if v1 > ChScrollMax then
  begin
    v1 := ChScrollMax;
    v0 := v1 - span;
  end;
  ChViewStart := v0;
  ChViewEnd := v1;
end;

procedure ScrollChViewportByPixels(dx_px, plot_w: integer);
var
  span, dval: Single;
begin
  if plot_w <= 0 then
    exit;
  span := ChViewEnd - ChViewStart;
  { Dragging finger right (dx_px > 0) pans the viewport toward lower channels }
  dval := -dx_px * span / plot_w;
  SetChViewport(ChViewStart + dval, ChViewEnd + dval, ChScrollMin, ChScrollMax);
end;

const
  { Fixed fake per-channel occupancy (per-mille) for the 25 Mosaico-supported
    5 GHz columns (36..64, 100..144, 149..165) }
  FAKE_5G_UTIL_PM: array[1..CH5G_COUNT] of integer = (
    185, 95, 240, 160, 70, 110, 45, 30,
    140, 65, 90, 40, 210, 120, 55, 25, 80, 35, 15, 20,
    310, 195, 260, 145, 85
  );

procedure ResetChViewport;
begin
  ChBand5G := false;
  SetChViewport(CH_MIN, CH_MAX, -1.0, 15.0);
end;

procedure SetChBand5G(enable: boolean);
begin
  ChBand5G := enable;
  if enable then
    { 13 columns visible per screen width (same column width as 2.4 GHz),
      scrollable across all 25 hardware-supported 5 GHz columns (36..165) }
    SetChViewport(1.0, 13.0, -1.0, CH5G_COUNT + 2.0)
  else
    SetChViewport(CH_MIN, CH_MAX, -1.0, 15.0);
end;

function Ch5GToColPos(ch: integer): Single; inline;
begin
  if (ch >= 36) and (ch <= 67) then
    Result := 1.0 + (ch - 36) * 0.25
  else if (ch >= 100) and (ch <= 147) then
    Result := 9.0 + (ch - 100) * 0.25
  else if (ch >= 149) and (ch <= 168) then
    Result := 21.0 + (ch - 149) * 0.25
  else
    Result := -100.0;
end;

procedure BuildFake5GNets(out out_nets: TNetArray);
  procedure Put(idx: integer; const ssid: string; ch, w_mhz, dbm: integer;
    col: LongWord);
  begin
    out_nets[idx].ssid := ssid;
    out_nets[idx].channel := ch;
    out_nets[idx].width_mhz := w_mhz;
    out_nets[idx].dbm := dbm;
    out_nets[idx].color := col;
  end;
begin
  { Sorted strongest-first (-34 dBm down to -72 dBm) across UNII-1 (36..48),
    UNII-2A (52..64), UNII-2C (100..144), and UNII-3 (149..165), with
    20 / 40 / 80 MHz channel widths }
  SetLength(out_nets, 12);
  Put(0,  'Mosaico-5G-Ultra', 42,  80, -34, PALETTE[0]);
  Put(1,  'HomeTheater-5G',   155, 80, -38, PALETTE[4]);
  Put(2,  'Office-Lab-36',    36,  20, -42, PALETTE[1]);
  Put(3,  'ESP32-S31-5G',     54,  40, -46, PALETTE[2]);
  Put(4,  'Studio-Mesh-100',  102, 40, -49, PALETTE[3]);
  Put(5,  'CloudLab-DFS',     122, 80, -52, PALETTE[6]);
  Put(6,  'DevNet-UNII2',     64,  20, -56, PALETTE[5]);
  Put(7,  'Guest-5GHz-165',   165, 20, -59, PALETTE[7]);
  Put(8,  'IoT-Backbone-48',  48,  20, -63, PALETTE_OTHER);
  Put(9,  'Sensor-Link-136',  134, 40, -65, PALETTE_OTHER);
  Put(10, 'Conference-108',   108, 20, -68, PALETTE_OTHER);
  Put(11, 'Roof-Relay-149',   149, 20, -72, PALETTE_OTHER);
end;

procedure BuildFake5GHistLines(out lines: THistLines);
const
  NAMES: array[0..5] of string = (
    'Mosaico-', 'HomeThea', 'Office-L', 'ESP32-S3', 'Studio-M', 'CloudLab'
  );
  BASE_DBM: array[0..5] of integer = (-34, -38, -42, -46, -49, -52);
  COLORS: array[0..5] of LongWord = (
    $3399FF, $CC4DE6, $FF664D, $4DE666, $FFCC33, $FF8000
  );
  RIPPLE: array[0..7] of integer = (0, 1, 2, 1, 0, -1, -2, -1);
var
  i, k, v: integer;
begin
  SetLength(lines, 6);
  for i := 0 to 5 do
  begin
    lines[i].color := COLORS[i];
    lines[i].name := NAMES[i];
    SetLength(lines[i].pts, 60);
    for k := 0 to 59 do
    begin
      v := BASE_DBM[i] + RIPPLE[(k + i * 3) and 7];
      if ((k + i * 5) mod 17) = 0 then
        Dec(v, 2);
      lines[i].pts[k] := v;
    end;
  end;
end;

function DbmAxis(plot_h: integer): TAxisMap;
begin
  Result.Pix0 := CH_MT + plot_h;   { DBM_MIN at the bottom }
  Result.Pix1 := CH_MT;            { DBM_MAX at the top }
  Result.Val0 := DBM_MIN;
  Result.Val1 := DBM_MAX;
end;

procedure DrawChannelView(const p: TPlot; const nets: array of TNet;
  focused: integer; const util_pm: TUtil13;
  out labels: TChartLabels);
var
  plot_w, plot_h: integer;
  ax, ay: TAxisMap;
  i, k: integer;
  color: LongWord;
  bw, center, amp: Single;
  s: TSeries;
  label_s: string;
  tx, ty, tw, tries, np: integer;
  collided: boolean;
  x0, x1: integer;
  placed: array[0..9] of record x0, y0, x1, y1: integer; end;
  grid_h: array[0..6] of Single;    { -80..-20 step 10 }
  gst: TGridStyle;
  fst: TFillStyle;
  sst: TStrokeStyle;
  dst: TDashSpec;
begin
  SetLength(labels, 0);
  { black base (C grid canvas) so night-sky bands read as colored shadow }
  PlotFillRect(p, 0, 0, p.W, p.H, 0, 255);

  plot_w := p.W - CH_ML - CH_MR;
  plot_h := p.H - CH_MT - CH_MB;
  ax := ChAxis(plot_w);
  ay := DbmAxis(plot_h);

  { occupancy bands under grid/curves — C util_band_color per permille.
    util_pm[i]: 0..1000, -1 = no data (stays black). Extend across the
    full width [0..p.W-1] so ch1's column renders behind the Y-axis labels. }
  if not ChBand5G then
  begin
    for i := 0 to 12 do
    begin
      k := util_pm[i];
      x0 := PlotRound(AxPix(ax, (i + 1) - 0.5));
      x1 := PlotRound(AxPix(ax, (i + 1) + 0.5));
      if x0 < 0 then
        x0 := 0;
      if x1 >= p.W then
        x1 := p.W - 1;
      if (x1 >= x0) and (k >= 0) then
        PlotFillRect(p, x0, CH_MT, x1 - x0 + 1, plot_h, wa_util_band_rgb(k), 255);
    end;
  end
  else
  begin
    for i := 1 to CH5G_COUNT do
    begin
      k := FAKE_5G_UTIL_PM[i];
      x0 := PlotRound(AxPix(ax, i - 0.5));
      x1 := PlotRound(AxPix(ax, i + 0.5));
      if x0 < 0 then
        x0 := 0;
      if x1 >= p.W then
        x1 := p.W - 1;
      if (x1 >= x0) and (k >= 0) then
        PlotFillRect(p, x0, CH_MT, x1 - x0 + 1, plot_h, wa_util_band_rgb(k), 255);
    end;
  end;

  { horizontal dBm gridlines + labels (-80..-20 step 10) }
  for i := 0 to 6 do
    grid_h[i] := DBM_MIN + i * 10;
  gst.Color := GRID_HEX;
  gst.Alpha := GRID_A;
  gst.WidthPx := 1;
  PlotGridH(p, grid_h, ay, 0, p.W - 1, gst);
  for i := 0 to 6 do
  begin
    ty := PlotRound(AxPix(ay, grid_h[i])) + 4;
    if ty < 15 then
      ty := 15;
    AddLabel(labels, 4, ty, IntToStr(DBM_MIN + i * 10), DIM_HEX);
  end;

  { vertical channel gridlines + tick labels across [0..p.W-1] }
  if not ChBand5G then
  begin
    for i := 1 to 14 do
    begin
      tx := PlotRound(AxPix(ax, i));
      if (tx >= 0) and (tx < p.W) then
      begin
        PlotFillRect(p, tx, CH_MT, 1, plot_h + 1, gst.Color, gst.Alpha);
        AddLabel(labels, tx - 5, p.H - CH_MB + 15, IntToStr(i), DIM_HEX);
      end;
    end;
  end
  else
  begin
    { 25 Mosaico-supported 5 GHz columns: 1 column = 4 channels (same width
      as 1 channel in 2.4 GHz), labeled 36, 40, 44, 48 .. 64, 100 .. 144, 149 .. 165 }
    for i := 1 to CH5G_COUNT do
    begin
      tx := PlotRound(AxPix(ax, i));
      if (tx >= 0) and (tx < p.W) then
      begin
        PlotFillRect(p, tx, CH_MT, 1, plot_h + 1, gst.Color, gst.Alpha);
        k := CH5G_CHANNELS[i];
        if k >= 100 then
          AddLabel(labels, tx - 11, p.H - CH_MB + 15, IntToStr(k), DIM_HEX)
        else
          AddLabel(labels, tx - 7, p.H - CH_MB + 15, IntToStr(k), DIM_HEX);
      end;
    end;
    { Sub-band skip markers between 64..100 (col 8.5) and 144..149 (col 20.5) }
    dst.Color := HGRID_HEX;
    dst.WidthPx := 1;
    dst.OnLen := 4;
    dst.OffLen := 4;
    PlotRefLineV(p, 8.5, ax, CH_MT, p.H - CH_MB, dst);
    PlotRefLineV(p, 20.5, ax, CH_MT, p.H - CH_MB, dst);
  end;

  if Length(nets) = 0 then
  begin
    AddLabel(labels, p.W div 2 - 60, p.H div 2, 'No networks found', DIM_HEX);
    exit;
  end;

  { bell curves, weakest first; 61 gaussian samples in value space }
  EnsureGaussLut;
  SetLength(s, 61);
  for i := High(nets) downto 0 do
  begin
    if i >= MAX_CURVES then
      continue;
    if nets[i].dbm < DBM_MIN then
      continue;
    color := nets[i].color;
    if not ChBand5G then
    begin
      center := nets[i].channel;
      bw := nets[i].width_mhz div 10;
      if bw < 1 then
        bw := 1;
    end
    else
    begin
      center := Ch5GToColPos(nets[i].channel);
      if center < 0 then
        continue;
      { 1 column in 5 GHz view = 4 channels (20 MHz), so bw in columns is width_mhz / 40 }
      bw := Single(nets[i].width_mhz) * Single(0.025);
      if bw < Single(0.5) then
        bw := Single(0.5);
    end;
    if (center + bw * 2 < ChViewStart - 1.0) or
       (center - bw * 2 > ChViewEnd + 1.0) then
      continue;

    amp := nets[i].dbm - DBM_MIN;
    for k := 0 to 60 do
    begin
      s[k].X := center + bw * gauss_norm[k];
      s[k].Y := DBM_MIN + amp * gauss_amp[k];
    end;
    fst.Color := color;
    fst.Alpha := FILL_A;
    sst.Color := color;
    sst.Alpha := STROKE_A;
    sst.WidthPx := 2;
    PlotSeriesFillBaselineClip(p, s, ax, ay, DBM_MIN, fst, sst, 0, p.W - 1);
  end;

  { SSID labels, strongest 10 (C MAX_LABELS), 16-char truncation.
    Placement: x anchored at the AP's channel peak (+2 px, clamped to
    the right edge); y starts at the curve peak and DESCENDS 13 px per
    collision against already-placed label rectangles - names spread
    down the plot instead of crowding the top (the pct mapping packs
    real-world RSSI into the upper half, leaving the bottom empty). }
  np := 0;
  for i := 0 to High(nets) do
  begin
    if np >= 10 then
      break;
    if nets[i].dbm < DBM_MIN then
      continue;
    if not ChBand5G then
      center := nets[i].channel
    else
    begin
      center := Ch5GToColPos(nets[i].channel);
      if center < 0 then
        continue;
    end;
    tx := PlotRound(AxPix(ax, center));
    if (tx < 0) or (tx >= p.W) then
      continue;
    tx := tx + 2;
    label_s := Copy(nets[i].ssid, 1, 16);
    if label_s = '' then
      label_s := '(hidden)';
    tw := Length(label_s) * 9 + 4;
    if tx + tw > p.W - 4 then
      tx := p.W - 4 - tw;
    if tx < 4 then
      tx := 4;
    ty := PlotRound(AxPix(ay, nets[i].dbm)) - 10;
    { greedy descent: step down until the rectangle is free }
    for tries := 1 to 25 do
    begin
      collided := False;
      for k := 0 to np - 1 do
        if (tx < placed[k].x1) and (tx + tw > placed[k].x0) and
           (ty < placed[k].y1) and (ty + 18 > placed[k].y0) then
        begin
          ty := ty + 13;
          collided := True;
          break;
        end;
      if not collided then
        break;
    end;
    if ty < 12 then
      ty := 12;
    if ty > HI_MT + plot_h - 16 then
      ty := HI_MT + plot_h - 16;
    placed[np].x0 := tx;
    placed[np].x1 := tx + tw;
    placed[np].y0 := ty;
    placed[np].y1 := ty + 18;
    Inc(np);
    AddLabel(labels, tx, ty, label_s, nets[i].color);
  end;

  { focused-channel dashed highlight, lines 1088-1096 }
  if (not ChBand5G) and (focused >= CH_MIN) and (focused <= CH_MAX) then
  begin
    dst.Color := FOCUS_HEX;
    dst.WidthPx := 3;
    dst.OnLen := 5;
    dst.OffLen := 3;
    PlotRefLineV(p, focused, ax, CH_MT, p.H - CH_MB, dst);
  end;
end;

procedure PatchChannelUtilColumn(const p: TPlot; ch: integer;
  util_pm: integer; const nets: array of TNet);
var
  plot_w, plot_h: integer;
  ax, ay: TAxisMap;
  i, k, x0, x1, gy: integer;
  color: LongWord;
  bw, center, amp: Single;
  s: TSeries;
  gst: TGridStyle;
  fst: TFillStyle;
  sst: TStrokeStyle;
begin
  if ChBand5G or (ch < CH_MIN) or (ch > CH_MAX) then
    exit;

  plot_w := p.W - CH_ML - CH_MR;
  plot_h := p.H - CH_MT - CH_MB;
  ax := ChAxis(plot_w);
  ay := DbmAxis(plot_h);
  x0 := PlotRound(AxPix(ax, ch - 0.5));
  x1 := PlotRound(AxPix(ax, ch + 0.5));
  if x0 < 0 then
    x0 := 0;
  if x1 >= p.W then
    x1 := p.W - 1;
  if x1 < x0 then
    exit;

  { util band (or black if no data) }
  if util_pm >= 0 then
    PlotFillRect(p, x0, CH_MT, x1 - x0 + 1, plot_h, wa_util_band_rgb(util_pm), 255)
  else
    PlotFillRect(p, x0, CH_MT, x1 - x0 + 1, plot_h, 0, 255);
  { clear the 2 baseline stroke rows below plot_h so bell/grid alpha does not accumulate }
  PlotFillRect(p, x0, CH_MT + plot_h, x1 - x0 + 1, 2, 0, 255);

  { horizontal grid segments across this strip (-80..-20 step 10) }
  gst.Color := GRID_HEX;
  gst.Alpha := GRID_A;
  gst.WidthPx := 1;
  for i := 0 to 6 do
  begin
    gy := PlotRound(AxPix(ay, DBM_MIN + i * 10));
    PlotFillRect(p, x0, gy, x1 - x0 + 1, 1, gst.Color, gst.Alpha);
  end;
  { vertical channel line }
  gy := PlotRound(AxPix(ax, ch));
  if (gy >= x0) and (gy <= x1) then
    PlotFillRect(p, gy, CH_MT, 1, plot_h + 1, gst.Color, gst.Alpha);

  { restore bell pixels that fall in this strip }
  EnsureGaussLut;
  SetLength(s, 61);
  for i := High(nets) downto 0 do
  begin
    if i >= MAX_CURVES then
      continue;
    if nets[i].dbm < DBM_MIN then
      continue;
    color := nets[i].color;
    center := nets[i].channel;
    bw := nets[i].width_mhz div 10;
    if bw < 1 then
      bw := 1;
    if (center + bw * 2 < ch - 0.6) or (center - bw * 2 > ch + 0.6) then
      continue;
    amp := nets[i].dbm - DBM_MIN;
    for k := 0 to 60 do
    begin
      s[k].X := center + bw * gauss_norm[k];
      s[k].Y := DBM_MIN + amp * gauss_amp[k];
    end;
    fst.Color := color;
    fst.Alpha := FILL_A;
    sst.Color := color;
    sst.Alpha := STROKE_A;
    sst.WidthPx := 2;
    PlotSeriesFillBaselineClip(p, s, ax, ay, DBM_MIN, fst, sst, x0, x1);
  end;
end;

procedure DrawHistoryView(const p: TPlot; const lines: THistLines;
  out labels: TChartLabels);
const
  HIST_WINDOW = 60;
var
  plot_w, plot_h: integer;
  ax, ay: TAxisMap;
  i, li, m, k: integer;
  s: TSeries;
  hst: TStrokeStyle;
  gst: TGridStyle;
  grid_h: array[0..6] of Single;
begin
  SetLength(labels, 0);
  PlotFillRect(p, 0, 0, p.W, p.H, BG_HEX, 255);

  plot_w := p.W - HI_ML - HI_MR;
  plot_h := p.H - HI_MT - HI_MB;

  ax.Pix0 := HI_ML;
  ax.Pix1 := HI_ML + plot_w;
  ax.Val0 := 0;
  ax.Val1 := HIST_WINDOW - 1;
  ay := DbmAxis(plot_h);

  { dBm gridlines + labels (-80..-20 step 10), aligned with CH view }
  gst.Color := HGRID_HEX;
  gst.Alpha := HGRID_A;
  gst.WidthPx := 1;
  for i := 0 to 6 do
    grid_h[i] := DBM_MIN + i * 10;
  PlotGridH(p, grid_h, ay, HI_ML, HI_ML + plot_w, gst);
  for i := 0 to 6 do
  begin
    k := PlotRound(AxPix(ay, grid_h[i])) + 4;
    if k < 15 then
      k := 15;
    AddLabel(labels, 4, k, IntToStr(DBM_MIN + i * 10), DIM_H_HEX);
  end;

  if Length(lines) = 0 then
  begin
    AddLabel(labels, 20, p.H div 2, 'No local signal history yet', DIM_H_HEX);
    exit;
  end;

  { one polyline per AP, strongest 6; right-aligned over the 60-sample
    scrolling window, weakest painted first (C history_view.c) }
  for li := High(lines) downto 0 do
  begin
    m := Length(lines[li].pts);
    if m < 2 then
      continue;
    if m > HIST_WINDOW then
      m := HIST_WINDOW;
    SetLength(s, m);
    for k := 0 to m - 1 do
    begin
      s[k].X := k + (HIST_WINDOW - m);
      s[k].Y := lines[li].pts[Length(lines[li].pts) - m + k];
    end;
    hst.Color := lines[li].color;
    hst.Alpha := 255;
    hst.WidthPx := 2;
    PlotSeriesLine(p, s, ax, ay, hst);
  end;

  { legend strip along the bottom (C history_view.c): 79 px pitch fills
    the 480 px width; chip 8x8 at slot top+3, label baseline slot+10 }
  for li := 0 to High(lines) do
  begin
    if Length(lines[li].pts) < 2 then
      continue;
    PlotFillRect(p, 6 + li * 79, p.H - 19, 8, 8, lines[li].color, 255);
    AddLabel(labels, 18 + li * 79, p.H - 13, lines[li].name, lines[li].color);
  end;
end;

end.
