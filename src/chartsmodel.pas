{ chartsmodel - the yeager/wifi-analyzer app.py drawing logic (ChannelDrawingArea._draw
  lines 978-1096, SignalHistoryDrawingArea._draw lines 1179-1207, fetched
  2026-11-15) on chartdraw's primitives, parameterized by the data source.

  Differences from the esp-units examples/charts milestone copy:
    - the fake dataset is gone; the callers feed real scan snapshots
      (strongest-first sorted, as the C wifi_analyzer's ap_store_copy
      produced) and the history ring of one AP;
    - painter order is weakest -> strongest (the C port's deliberate
      change over app.py's list order - strong curves overdraw weak);
    - SSID labels are emitted for the strongest 8 (the palette size).

  Cairo-to-raster substitutions (all deliberate, milestone-verified
  against the pycairo reference to <=1 LSB on fills/grid/dash):
    - 0.5px AA gridlines -> 1px at ink-preserving alpha (GRID_A 38;
      cairo 0.5px @0.3 has total ink 0.15, our pixel values then match);
    - 61-point stroked polylines -> per-column sampling (strictly finer);
    - show_text -> TChartLabel records in cairo baseline coordinates -
      the device renders them as LVGL labels, no font is rasterized;
    - float coords -> PlotRound (symmetric), integers everywhere.

  Target-neutral: no units, compiles for esp32s31 and the host. }

unit chartsmodel;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,   { IntToStr for the label texts }
  Math,       { exp }
  chartdraw;  { the five primitives }

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
    0.15. Our 1px line matches cairo's PIXEL VALUES at alpha 38. }
  GRID_A   = 38;

  { ChannelDrawingArea margins, verbatim (relative to the canvas) }
  CH_ML = 50;
  CH_MR = 40;
  CH_MT = 20;
  CH_MB = 24;
  DBM_MIN = -100;
  DBM_MAX = -20;

  { SignalHistoryDrawingArea margins, verbatim }
  HI_ML = 42;
  HI_MR = 18;
  HI_MT = 18;
  HI_MB = 24;

  { curves/labels caps (C wifi_analyzer: MAX_CURVES 24, palette 8) }
  MAX_CURVES = 24;
  PALETTE_SIZE = 8;

type
  { one AP as the charts see it }
  TNet = record
    ssid: string;
    channel: integer;
    width_mhz: integer;
    dbm: integer;
  end;

  { a text label emitted by the renderers, in app.py's cairo semantics:
    x,y is the BASELINE origin of show_text; the UI layer converts
    baseline -> LVGL label top }
  TChartLabel = record
    x, y: integer;
    text: string;
    rgb: LongWord;
  end;
  TChartLabels = array of TChartLabel;

const
  { colors[i mod 8] from ChannelDrawingArea._draw line 1047 }
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

{ app.py ch_to_x / dbm_to_y (lines 1002/1005) }
function ChToX(plot_w: integer; ch: Double): Double;
function DbmToY(plot_h: integer; dbm: Double): Double;

{ ChannelDrawingArea._draw on the plot buffer; nets arrive STRONGEST-FIRST
  and are painted weakest-first (reverse iteration). focused: channel
  number for the dashed highlight, 0 = none. Labels come back in cairo
  baseline coordinates. }
procedure DrawChannelView(const p: TPlot; const nets: array of TNet;
  focused: integer; out labels: TChartLabels);

{ SignalHistoryDrawingArea._draw: one AP's RSSI history, newest last,
  as signal percentages 0..100. }
procedure DrawHistoryView(const p: TPlot; const pts: array of integer;
  out labels: TChartLabels);

implementation

function ChToX(plot_w: integer; ch: Double): Double;
begin
  Result := CH_ML + (ch - 1) / 12 * plot_w;
end;

function DbmToY(plot_h: integer; dbm: Double): Double;
begin
  Result := CH_MT + plot_h - (dbm - DBM_MIN) / (DBM_MAX - DBM_MIN) * plot_h;
end;

procedure AddLabel(var labels: TChartLabels; x, y: integer;
  const text: string; rgb: LongWord);
var
  n: integer;
begin
  n := Length(labels);
  SetLength(labels, n + 1);
  labels[n].x := x;
  labels[n].y := y;
  labels[n].text := text;
  labels[n].rgb := rgb;
end;

procedure DrawChannelView(const p: TPlot; const nets: array of TNet;
  focused: integer; out labels: TChartLabels);
var
  plot_w, plot_h: integer;
  dbm, ch: integer;
  y, x: Double;
  i: integer;
  color: LongWord;
  bw, center, peak_y, base_y: Double;
  x0, x1, chx, dist, amp: Double;
  xi, ry, base_i: integer;
  label_s: string;
begin
  SetLength(labels, 0);
  PlotFillRect(p, 0, 0, p.W, p.H, BG_HEX, 255);

  plot_w := p.W - CH_ML - CH_MR;
  plot_h := p.H - CH_MT - CH_MB;
  base_y := DbmToY(plot_h, DBM_MIN);
  base_i := PlotRound(base_y);

  if Length(nets) = 0 then
  begin
    { app.py line 987: empty state (hand-centered, as the reference does) }
    AddLabel(labels, p.W div 2 - 60, p.H div 2, 'No networks found', DIM_HEX);
    exit;
  end;

  { horizontal dBm gridlines + labels, lines 990-1001 }
  dbm := -100;
  while dbm <= -20 do
  begin
    y := DbmToY(plot_h, dbm);
    PlotFillRect(p, CH_ML, PlotRound(y), plot_w, 1, GRID_HEX, GRID_A);
    AddLabel(labels, 5, PlotRound(y) + 4, IntToStr(dbm), DIM_HEX);
    Inc(dbm, 10);
  end;

  { vertical channel gridlines + tick labels, lines 1002-1013 }
  for ch := 1 to 13 do
  begin
    x := ChToX(plot_w, ch);
    PlotFillRect(p, PlotRound(x), CH_MT, 1, plot_h, GRID_HEX, GRID_A);
    AddLabel(labels, PlotRound(x) - 5, p.H - CH_MB + 15, IntToStr(ch), DIM_HEX);
  end;

  { bell curves, lines 1042-1086; weakest first = reverse of the
    strongest-first array }
  for i := High(nets) downto 0 do
  begin
    if i >= MAX_CURVES then
      continue;
    color := PALETTE[i mod PALETTE_SIZE];
    center := nets[i].channel;
    bw := nets[i].width_mhz / 10;
    if bw < 1 then
      bw := 1;
    peak_y := DbmToY(plot_h, nets[i].dbm);

    x0 := ChToX(plot_w, center - bw * 2);
    x1 := ChToX(plot_w, center + bw * 2);
    for xi := PlotRound(x0) to PlotRound(x1) do
    begin
      chx := 1 + (xi - CH_ML) / plot_w * 12;
      dist := (chx - center) / bw;
      amp := exp(-dist * dist * 2);
      ry := PlotRound(base_y + (peak_y - base_y) * amp);
      PlotFillRect(p, xi, ry, 1, base_i - ry + 1, color, FILL_A);
      PlotStrokeColumn(p, xi, ry, color, STROKE_A);
    end;
  end;

  { SSID labels for the strongest PALETTE_SIZE, lines 1082-1086 }
  for i := 0 to High(nets) do
  begin
    if i >= PALETTE_SIZE then
      break;
    label_s := Copy(nets[i].ssid, 1, 18);
    if label_s = '' then
      label_s := '(hidden)';
    AddLabel(labels,
      PlotRound(ChToX(plot_w, nets[i].channel))
        - PlotRound(Length(label_s) * 2.5),
      PlotRound(DbmToY(plot_h, nets[i].dbm)) - 6,
      label_s, PALETTE[i mod PALETTE_SIZE]);
  end;

  { focused-channel dashed highlight, lines 1088-1096 }
  if (focused >= 1) and (focused <= 13) then
  begin
    x := ChToX(plot_w, focused);
    if (x >= CH_ML) and (x <= p.W - CH_MR) then
      PlotDashedVLine(p, PlotRound(x), CH_MT, p.H - CH_MB, 3,
        FOCUS_HEX, 5, 3);
  end;
end;

procedure DrawHistoryView(const p: TPlot; const pts: array of integer;
  out labels: TChartLabels);
var
  plot_w, plot_h: integer;
  signal: integer;
  y: Double;
  i, n, ry: integer;
  px, py, cx, cy: integer;
begin
  SetLength(labels, 0);
  PlotFillRect(p, 0, 0, p.W, p.H, BG_HEX, 255);   { paint, line 1181 }

  plot_w := p.W - HI_ML - HI_MR;
  plot_h := p.H - HI_MT - HI_MB;
  n := Length(pts);

  { gridlines + "N%" labels, lines 1189-1197; cairo DEFAULT width 2 }
  signal := 0;
  while signal <= 100 do
  begin
    y := HI_MT + plot_h - signal / 100 * plot_h;
    ry := PlotRound(y);
    PlotFillRect(p, HI_ML, ry - 1, plot_w, 2, HGRID_HEX, HGRID_A);
    AddLabel(labels, 4, ry + 4, IntToStr(signal) + '%', DIM_H_HEX);
    Inc(signal, 25);
  end;

  if n = 0 then
  begin
    AddLabel(labels, 20, p.H div 2, 'No local signal history yet', DIM_H_HEX);
    exit;
  end;

  { the signal polyline, lines 1198-1206; x spread over the point index }
  px := HI_ML;
  cx := px;
  cy := HI_MT + plot_h - pts[0] * plot_h div 100;
  for i := 1 to n - 1 do
  begin
    px := HI_ML + i * plot_w div (n - 1);
    ry := HI_MT + plot_h - pts[i] * plot_h div 100;
    PlotLine2(p, cx, cy, px, ry, HIST_HEX);
    cx := px;
    cy := ry;
  end;
end;

end.
