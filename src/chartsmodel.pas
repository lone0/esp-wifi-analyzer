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

  { ChannelDrawingArea margins + axis ranges, verbatim }
  CH_ML = 50;
  CH_MR = 20;
  CH_MT = 20;
  CH_MB = 40;
  CH_MIN = 1;
  CH_MAX = 13;
  DBM_MIN = -100;
  DBM_MAX = -20;

  { SignalHistoryDrawingArea margins, verbatim }
  HI_ML = 42;
  HI_MR = 18;
  HI_MT = 18;
  HI_MB = 30;

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

{ channel-axis map: channels 1..13 across the plot width }
function ChAxis(plot_w: integer): TAxisMap;
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
  TPctArray = array of Double;   { 0..100 percentages, oldest -> newest }
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

implementation

{ C wifi_analyzer channel_view.c util_band_color via lv_color_hsv_to_rgb }
function wa_util_band_rgb(permille: LongInt): LongWord; cdecl; external;

function ChAxis(plot_w: integer): TAxisMap;
begin
  Result.Pix0 := CH_ML;
  Result.Pix1 := CH_ML + plot_w;
  Result.Val0 := CH_MIN;
  Result.Val1 := CH_MAX;
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
  bw, center, amp: Double;
  s: TSeries;
  label_s: string;
  tx, ty, tw, tries, np: integer;
  collided: boolean;
  x0, x1: integer;
  placed: array[0..9] of record x0, y0, x1, y1: integer; end;
  grid_h: array[0..8] of Double;    { -100..-20 step 10 }
  grid_v: array[0..12] of Double;   { 1..13 }
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
    util_pm[i]: 0..1000, -1 = no data (stays black). Clip to the plot
    so ch1/ch13 do not paint into the dBm / right margins. }
  for i := 0 to 12 do
  begin
    k := util_pm[i];
    x0 := PlotRound(AxPix(ax, (i + 1) - 0.5));
    x1 := PlotRound(AxPix(ax, (i + 1) + 0.5));
    if x0 < CH_ML then
      x0 := CH_ML;
    if x1 > CH_ML + plot_w then
      x1 := CH_ML + plot_w;
    if (x1 >= x0) and (k >= 0) then
      PlotFillRect(p, x0, CH_MT, x1 - x0 + 1, plot_h, wa_util_band_rgb(k), 255);
  end;

  { horizontal dBm gridlines + labels }
  for i := 0 to 8 do
    grid_h[i] := DBM_MIN + i * 10;
  gst.Color := GRID_HEX;
  gst.Alpha := GRID_A;
  gst.WidthPx := 1;
  PlotGridH(p, grid_h, ay, CH_ML, CH_ML + plot_w, gst);
  for i := 0 to 8 do
    AddLabel(labels, 5, PlotRound(AxPix(ay, grid_h[i])) + 4,
      IntToStr(DBM_MIN + i * 10), DIM_HEX);

  { vertical channel gridlines + tick labels }
  for i := 0 to 12 do
    grid_v[i] := CH_MIN + i;
  PlotGridV(p, grid_v, ax, CH_MT, CH_MT + plot_h, gst);
  for i := 0 to 12 do
    AddLabel(labels, PlotRound(AxPix(ax, grid_v[i])) - 5,
      p.H - CH_MB + 15, IntToStr(CH_MIN + i), DIM_HEX);

  if Length(nets) = 0 then
  begin
    AddLabel(labels, p.W div 2 - 60, p.H div 2, 'No networks found', DIM_HEX);
    exit;
  end;

  { bell curves, weakest first; 61 gaussian samples in value space }
  for i := High(nets) downto 0 do
  begin
    if i >= MAX_CURVES then
      continue;
    color := nets[i].color;
    center := nets[i].channel;
    bw := nets[i].width_mhz / 10;
    if bw < 1 then
      bw := 1;

    SetLength(s, 61);
    for k := 0 to 60 do
    begin
      s[k].X := center - bw * 2 + bw * 4 * k / 60;
      amp := exp(-sqr((s[k].X - center) / bw) * 2);
      s[k].Y := DBM_MIN + (nets[i].dbm - DBM_MIN) * amp;
    end;
    fst.Color := color;
    fst.Alpha := FILL_A;
    sst.Color := color;
    sst.Alpha := STROKE_A;
    sst.WidthPx := 2;
    PlotSeriesFillBaseline(p, s, ax, ay, DBM_MIN, fst, sst);
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
    if i >= 10 then
      break;
    label_s := Copy(nets[i].ssid, 1, 16);
    if label_s = '' then
      label_s := '(hidden)';
    tx := PlotRound(AxPix(ax, nets[i].channel)) + 2;
    tw := Length(label_s) * 9 + 4;
    if tx + tw > p.W - 4 then
      tx := p.W - 4 - tw;
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
  if (focused >= CH_MIN) and (focused <= CH_MAX) then
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
  bw, center, amp: Double;
  s: TSeries;
  gst: TGridStyle;
  fst: TFillStyle;
  sst: TStrokeStyle;
begin
  if (ch < CH_MIN) or (ch > CH_MAX) then
    exit;

  plot_w := p.W - CH_ML - CH_MR;
  plot_h := p.H - CH_MT - CH_MB;
  ax := ChAxis(plot_w);
  ay := DbmAxis(plot_h);
  x0 := PlotRound(AxPix(ax, ch - 0.5));
  x1 := PlotRound(AxPix(ax, ch + 0.5));
  { ch1 extends left of CH_ML (dBm gutter); ch13 past the right edge —
    keep util paint inside the plot so the strength column stays stable. }
  if x0 < CH_ML then
    x0 := CH_ML;
  if x1 > CH_ML + plot_w then
    x1 := CH_ML + plot_w;
  if x1 < x0 then
    exit;

  { util band (or black if no data) }
  if util_pm >= 0 then
    PlotFillRect(p, x0, CH_MT, x1 - x0 + 1, plot_h, wa_util_band_rgb(util_pm), 255)
  else
    PlotFillRect(p, x0, CH_MT, x1 - x0 + 1, plot_h, 0, 255);

  { horizontal grid segments across this strip }
  gst.Color := GRID_HEX;
  gst.Alpha := GRID_A;
  gst.WidthPx := 1;
  for i := 0 to 8 do
  begin
    gy := PlotRound(AxPix(ay, DBM_MIN + i * 10));
    PlotFillRect(p, x0, gy, x1 - x0 + 1, 1, gst.Color, gst.Alpha);
  end;
  { vertical channel line }
  PlotFillRect(p, PlotRound(AxPix(ax, ch)), CH_MT, 1, plot_h, gst.Color, gst.Alpha);

  { restore bell pixels that fall in this strip }
  for i := High(nets) downto 0 do
  begin
    if i >= MAX_CURVES then
      continue;
    color := nets[i].color;
    center := nets[i].channel;
    bw := nets[i].width_mhz / 10;
    if bw < 1 then
      bw := 1;
    SetLength(s, 61);
    for k := 0 to 60 do
    begin
      s[k].X := center - bw * 2 + bw * 4 * k / 60;
      amp := exp(-sqr((s[k].X - center) / bw) * 2);
      s[k].Y := DBM_MIN + (nets[i].dbm - DBM_MIN) * amp;
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
  grid_v: array[0..4] of Double;
begin
  SetLength(labels, 0);
  PlotFillRect(p, 0, 0, p.W, p.H, BG_HEX, 255);

  plot_w := p.W - HI_ML - HI_MR;
  plot_h := p.H - HI_MT - HI_MB;

  { percent gridlines + "N%" labels, 25% steps }
  gst.Color := HGRID_HEX;
  gst.Alpha := HGRID_A;
  gst.WidthPx := 2;
  for i := 0 to 4 do
    grid_v[i] := i * 25;
  PlotGridH(p, grid_v, ay, HI_ML, HI_ML + plot_w, gst);
  for i := 0 to 4 do
    AddLabel(labels, 4, PlotRound(AxPix(ay, grid_v[i])) + 4,
      IntToStr(i * 25) + '%', DIM_H_HEX);

  if Length(lines) = 0 then
  begin
    AddLabel(labels, 20, p.H div 2, 'No local signal history yet', DIM_H_HEX);
    exit;
  end;

  { one polyline per AP, strongest 6; right-aligned over the 60-sample
    scrolling window, weakest painted first (C history_view.c) }
  ax.Pix0 := HI_ML;
  ax.Pix1 := HI_ML + plot_w;
  ax.Val0 := 0;
  ax.Val1 := HIST_WINDOW - 1;
  ay.Pix0 := HI_MT + plot_h;
  ay.Pix1 := HI_MT;
  ay.Val0 := 0;
  ay.Val1 := 100;
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
