{ chartplot - generic 2D chart renderer over chartdraw's pixel primitives.

  Value-space API: series points and grid/reference values arrive in DATA
  coordinates, mapped to pixels through caller-owned linear axis maps.
  Nothing here knows what the axes mean (channels, dBm, percent - all
  application semantics live above).

  Three layers:
    chartdraw    pixels: 5 primitives, clipping, blending   (no charts)
    chartplot    THIS: generic chart semantics in value space
    application  axis definitions, data mapping, label text, palette

  Sampling model: series arrive as sampled point lists; the renderer
  linearly interpolates between samples in pixel space (per-column for
  baseline fills, per-segment for polylines). This matches cairo's
  straight-segment geometry exactly - the yeager/wifi-analyzer reference
  draws 61-point polylines the same way. No AA: hard edges, the only
  residual vs the cairo reference.

  Labels are OUTPUT DATA (TChartLabel, cairo show_text baseline
  coordinates) - the caller renders them (LVGL on device, cairo in the
  desktop reference). No font is rasterized here.

  Ink compensation is a caller decision: app.py draws 0.5 px gridlines at
  alpha 0.3; the equivalent 1 px line carries alpha 0.15 (total ink =
  coverage x alpha is what must match). This unit takes the alpha it is
  given.

  Target-neutral: uses chartdraw only; compiles for esp32s31 and the
  host alike. }

unit chartplot;

{$mode objfpc}{$H+}

interface

uses
  chartdraw;   { TPlot, the 5 primitives, PlotRound }

type
  { linear value->pixel axis map: Val0 sits at pixel Pix0, Val1 at Pix1 }
  TAxisMap = record
    Pix0, Pix1: integer;
    Val0, Val1: Single;
  end;

  { one series sample in VALUE space }
  TSeriesPt = record
    X, Y: Single;
  end;
  TSeries = array of TSeriesPt;

  TFillStyle = record
    Color: LongWord;
    Alpha: byte;
  end;

  TStrokeStyle = record
    Color: LongWord;
    Alpha: byte;
    WidthPx: integer;         { 2 = the cairo width-2 look }
  end;

  TGridStyle = record
    Color: LongWord;
    Alpha: byte;
    WidthPx: integer;
  end;

  TDashSpec = record
    Color: LongWord;
    WidthPx: integer;
    OnLen, OffLen: integer;
  end;

  { a text label emitted in cairo show_text semantics: x,y is the BASELINE
    origin; the device layer converts baseline -> LVGL label top }
  TChartLabel = record
    x, y: integer;
    text: string;
    rgb: LongWord;
  end;
  TChartLabels = array of TChartLabel;

{ linear value->pixel mapping (both directions) }
function AxPix(const m: TAxisMap; v: Single): Single; inline;
function AxVal(const m: TAxisMap; px: Single): Single; inline;

{ horizontal gridlines at the given Y values, spanning [x0..x1] }
procedure PlotGridH(const p: TPlot; const yvals: array of Single;
  const ay: TAxisMap; x0, x1: integer; const g: TGridStyle);

{ vertical gridlines at the given X values, spanning [y0..y1] }
procedure PlotGridV(const p: TPlot; const xvals: array of Single;
  const ax: TAxisMap; y0, y1: integer; const g: TGridStyle);

{ closed-to-baseline fill + width-2 stroke of a function-style series
  (x monotone in value space); the fill runs per column from the
  interpolated curve down to the baseline pixel }
procedure PlotSeriesFillBaseline(const p: TPlot; const s: TSeries;
  const ax, ay: TAxisMap; baselineVal: Single;
  const fill: TFillStyle; const stroke: TStrokeStyle);

{ same, but only pixel columns in [clipX0..clipX1] (single-channel patch) }
procedure PlotSeriesFillBaselineClip(const p: TPlot; const s: TSeries;
  const ax, ay: TAxisMap; baselineVal: Single;
  const fill: TFillStyle; const stroke: TStrokeStyle;
  clipX0, clipX1: integer);

{ plain width-2 polyline through the series (the history-line look) }
procedure PlotSeriesLine(const p: TPlot; const s: TSeries;
  const ax, ay: TAxisMap; const st: TStrokeStyle);

{ vertical dashed reference line at value xv (the focused-channel mark) }
procedure PlotRefLineV(const p: TPlot; xv: Single; const ax: TAxisMap;
  y0, y1: integer; const d: TDashSpec);

procedure AddLabel(var labels: TChartLabels; x, y: integer;
  const text: string; rgb: LongWord);

implementation

function AxPix(const m: TAxisMap; v: Single): Single; inline;
begin
  if m.Val1 = m.Val0 then
    Result := m.Pix0
  else
    Result := m.Pix0 + (v - m.Val0) / (m.Val1 - m.Val0) * (m.Pix1 - m.Pix0);
end;

function AxVal(const m: TAxisMap; px: Single): Single; inline;
begin
  if m.Pix1 = m.Pix0 then
    Result := m.Val0
  else
    Result := m.Val0 + (px - m.Pix0) / (m.Pix1 - m.Pix0) * (m.Val1 - m.Val0);
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

procedure PlotGridH(const p: TPlot; const yvals: array of Single;
  const ay: TAxisMap; x0, x1: integer; const g: TGridStyle);
var
  i: integer;
begin
  for i := 0 to High(yvals) do
    PlotFillRect(p, x0, PlotRound(AxPix(ay, yvals[i])), x1 - x0 + 1,
      g.WidthPx, g.Color, g.Alpha);
end;

procedure PlotGridV(const p: TPlot; const xvals: array of Single;
  const ax: TAxisMap; y0, y1: integer; const g: TGridStyle);
var
  i: integer;
begin
  for i := 0 to High(xvals) do
    PlotFillRect(p, PlotRound(AxPix(ax, xvals[i])), y0, 1, y1 - y0 + 1,
      g.Color, g.Alpha);
end;

{ fill+stroke of a function-style series. The series is the sampled
  curve in value space (x strictly monotone); each pixel column between
  the first and last sample gets the linearly-interpolated curve height
  (cairo draws the same polyline as straight segments) and the fill runs
  from there down to the baseline. Stroke = the 2 px vertical pair per
  column (cairo's butt-capped width-2 stroke on a shallow curve). }
procedure PlotSeriesFillBaselineClip(const p: TPlot; const s: TSeries;
  const ax, ay: TAxisMap; baselineVal: Single;
  const fill: TFillStyle; const stroke: TStrokeStyle;
  clipX0, clipX1: integer);
var
  i, xi, x0, x1, ry, base_i: integer;
  frac: Single;
begin
  if Length(s) < 2 then
    exit;
  x0 := PlotRound(AxPix(ax, s[0].X));
  x1 := PlotRound(AxPix(ax, s[High(s)].X));
  if x0 < clipX0 then
    x0 := clipX0;
  if x1 > clipX1 then
    x1 := clipX1;
  if x0 > x1 then
    exit;
  base_i := PlotRound(AxPix(ay, baselineVal));

  for xi := x0 to x1 do
  begin
    i := 0;
    while (i < High(s)) and (AxPix(ax, s[i + 1].X) < xi) do
      Inc(i);
    if AxPix(ax, s[i + 1].X) = AxPix(ax, s[i].X) then
      frac := 0
    else
      frac := (xi - AxPix(ax, s[i].X)) / (AxPix(ax, s[i + 1].X) - AxPix(ax, s[i].X));
    if frac > 1 then
      frac := 1;
    ry := PlotRound(AxPix(ay, s[i].Y) + frac * (AxPix(ay, s[i + 1].Y) - AxPix(ay, s[i].Y)));
    PlotFillRect(p, xi, ry, 1, base_i - ry + 1, fill.Color, fill.Alpha);
    PlotStrokeColumn(p, xi, ry, stroke.Color, stroke.Alpha);
  end;
end;

procedure PlotSeriesFillBaseline(const p: TPlot; const s: TSeries;
  const ax, ay: TAxisMap; baselineVal: Single;
  const fill: TFillStyle; const stroke: TStrokeStyle);
var
  x0, x1: integer;
begin
  if Length(s) < 2 then
    exit;
  x0 := PlotRound(AxPix(ax, s[0].X));
  x1 := PlotRound(AxPix(ax, s[High(s)].X));
  PlotSeriesFillBaselineClip(p, s, ax, ay, baselineVal, fill, stroke, x0, x1);
end;

procedure PlotSeriesLine(const p: TPlot; const s: TSeries;
  const ax, ay: TAxisMap; const st: TStrokeStyle);
var
  i, x0, y0, x1, y1: integer;
begin
  if Length(s) < 2 then
    exit;
  x0 := PlotRound(AxPix(ax, s[0].X));
  y0 := PlotRound(AxPix(ay, s[0].Y));
  for i := 1 to High(s) do
  begin
    x1 := PlotRound(AxPix(ax, s[i].X));
    y1 := PlotRound(AxPix(ay, s[i].Y));
    PlotLine2(p, x0, y0, x1, y1, st.Color);
    x0 := x1;
    y0 := y1;
  end;
end;

procedure PlotRefLineV(const p: TPlot; xv: Single; const ax: TAxisMap;
  y0, y1: integer; const d: TDashSpec);
begin
  PlotDashedVLine(p, PlotRound(AxPix(ax, xv)), y0, y1, d.WidthPx,
    d.Color, d.OnLen, d.OffLen);
end;

end.
