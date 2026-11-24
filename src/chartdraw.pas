{ chartdraw - five raster primitives reproducing the cairo drawing of
  yeager/wifi-analyzer app.py (ChannelDrawingArea._draw lines 978-1096,
  SignalHistoryDrawingArea._draw lines 1179-1207) on a plain pixel buffer.

  Why these five: the reference's complete cairo surface vocabulary is

    rectangle+fill / paint        -> PlotFillRect   (opaque + alpha)
    move_to/line_to stroke 0.5px  -> PlotFillRect(w=1) at compensated alpha
    close_path+fill (bell curve)  -> PlotFillRect(w=1) columns (see below)
    stroke width 2 (curve, line)  -> PlotStrokeColumn / PlotLine2
    set_dash([5,3]) width 3       -> PlotDashedVLine

  Everything else cairo offers (curve_to, arc, gradients, clip, save/
  restore, line_cap/join, Pango text) never appears in the reference;
  its text calls map to LVGL labels, not pixels (see chartsmodel).

  Buffer format: ARGB8888, one Cardinal per pixel, value $FFRRGGBB.
  Byte order in memory (B,G,R,A) is exactly LVGL's LV_COLOR_FORMAT_
  ARGB8888, so the buffer feeds lv_canvas_set_buffer unchanged. Alpha
  stays $FF everywhere; blending happens on the 24-bit color in 8-bit
  channel precision - the same precision cairo's ARGB32 accumulation
  uses, so stacked translucent fills (0.3 fill over 0.3 fill) match the
  reference bit-for-bit up to <=1 LSB of truncation. Only the final
  blit onto the RGB565 panel quantizes once, like the reference's own
  cairo->monitor path.

  Clipping: every pixel write bounds-checks against the plot rect -
  the same semantics as cairo clipping to the widget surface (app.py's
  bell curves do bleed into the margins and so do ours, right up to
  the buffer edge).

  No units, no targets: this file compiles unchanged for esp32s31
  (device) and x86_64-linux (desktop harness). }

unit chartdraw;

{$mode objfpc}{$H+}

interface

type
  { one row of W pixels, top-left origin, row-major, H rows }
  TPlot = record
    Buf: PCardinal;  { $FFRRGGBB per pixel }
    W, H: integer;
  end;

{ core: one alpha-blended pixel. alpha=255 replaces, 0 is a no-op.
  Outside the buffer = invisible, like cairo's surface clip. }
procedure PlotBlendPixel(const p: TPlot; x, y: integer;
  rgb: LongWord; alpha: Byte);

{ filled rectangle (the grid, the background, and the bell-curve fill
  body, which is per-column rectangles down to the baseline). alpha
  255 = opaque store. }
procedure PlotFillRect(const p: TPlot; x, y, w, h: integer;
  rgb: LongWord; alpha: Byte);

{ cairo "stroke width 2" of a shallow function curve y(x): a 2px
  vertical pair per column at the stroke alpha. Cairo's default butt
  cap = flat ends, so no cap decoration is drawn. }
procedure PlotStrokeColumn(const p: TPlot; x, y: integer;
  rgb: LongWord; alpha: Byte);

{ cairo "stroke width 2" between two polyline points (the signal-
  history line): Bresenham plus the perpendicular neighbor pixel.
  Butt-capped, no joins - segments meet within one pixel. }
procedure PlotLine2(const p: TPlot; x0, y0, x1, y1: integer; rgb: LongWord);

{ cairo set_dash([on, off]) stroke width w of a vertical line (the
  focused-channel highlight: width 3, dash [5,3]). Pattern starts
  "on" at y0. }
procedure PlotDashedVLine(const p: TPlot; x, y0, y1, w: integer;
  rgb: LongWord; onLen, offLen: integer);

{ app.py draws with float cairo coordinates; the raster world needs
  integers. Symmetric rounding (not banker's): 2.5 -> 3. }
function PlotRound(v: Single): integer; inline;

implementation

procedure PlotBlendPixel(const p: TPlot; x, y: integer;
  rgb: LongWord; alpha: Byte);
var
  q: PCardinal;
  dst, r0, g0, b0, a256, inv_a: LongWord;
begin
  if (x < 0) or (x >= p.W) or (y < 0) or (y >= p.H) or (alpha = 0) then
    exit;
  q := p.Buf + (y * p.W + x);
  if alpha = 255 then
  begin
    q^ := $FF000000 or (rgb and $FFFFFF);
    exit;
  end;
  dst := q^;
  a256 := alpha + (alpha shr 7);
  inv_a := 256 - a256;
  r0 := (((rgb shr 16) and $FF) * a256 + ((dst shr 16) and $FF) * inv_a) shr 8;
  g0 := (((rgb shr 8) and $FF) * a256 + ((dst shr 8) and $FF) * inv_a) shr 8;
  b0 := ((rgb and $FF) * a256 + (dst and $FF) * inv_a) shr 8;
  q^ := $FF000000 or (r0 shl 16) or (g0 shl 8) or b0;
end;

procedure PlotFillRect(const p: TPlot; x, y, w, h: integer;
  rgb: LongWord; alpha: Byte);
var
  x0, y0, x1, y1, span_w, i, j, stride: integer;
  q: PCardinal;
  val, dst, sr, sg, sb, r0, g0, b0, a256, inv_a: LongWord;
begin
  if (w <= 0) or (h <= 0) or (alpha = 0) then
    exit;
  x0 := x;
  y0 := y;
  x1 := x + w - 1;
  y1 := y + h - 1;
  if x0 < 0 then
    x0 := 0;
  if y0 < 0 then
    y0 := 0;
  if x1 >= p.W then
    x1 := p.W - 1;
  if y1 >= p.H then
    y1 := p.H - 1;
  if (x0 > x1) or (y0 > y1) then
    exit;

  span_w := x1 - x0 + 1;
  stride := p.W;

  if alpha = 255 then
  begin
    val := $FF000000 or (rgb and $FFFFFF);
    if (x0 = 0) and (span_w = stride) then
    begin
      FillDWord((p.Buf + y0 * stride)^, (y1 - y0 + 1) * stride, val);
      exit;
    end;
    q := p.Buf + (y0 * stride + x0);
    for j := y0 to y1 do
    begin
      FillDWord(q^, span_w, val);
      Inc(q, stride);
    end;
    exit;
  end;

  a256 := alpha + (alpha shr 7);
  inv_a := 256 - a256;
  sr := ((rgb shr 16) and $FF) * a256;
  sg := ((rgb shr 8) and $FF) * a256;
  sb := (rgb and $FF) * a256;

  if span_w = 1 then
  begin
    q := p.Buf + (y0 * stride + x0);
    for j := y0 to y1 do
    begin
      dst := q^;
      r0 := (sr + ((dst shr 16) and $FF) * inv_a) shr 8;
      g0 := (sg + ((dst shr 8) and $FF) * inv_a) shr 8;
      b0 := (sb + (dst and $FF) * inv_a) shr 8;
      q^ := $FF000000 or (r0 shl 16) or (g0 shl 8) or b0;
      Inc(q, stride);
    end;
    exit;
  end;

  for j := y0 to y1 do
  begin
    q := p.Buf + (j * stride + x0);
    for i := 0 to span_w - 1 do
    begin
      dst := q^;
      r0 := (sr + ((dst shr 16) and $FF) * inv_a) shr 8;
      g0 := (sg + ((dst shr 8) and $FF) * inv_a) shr 8;
      b0 := (sb + (dst and $FF) * inv_a) shr 8;
      q^ := $FF000000 or (r0 shl 16) or (g0 shl 8) or b0;
      Inc(q);
    end;
  end;
end;

procedure PlotStrokeColumn(const p: TPlot; x, y: integer;
  rgb: LongWord; alpha: Byte);
begin
  PlotBlendPixel(p, x, y, rgb, alpha);
  PlotBlendPixel(p, x, y - 1, rgb, alpha);
end;

procedure PlotLine2(const p: TPlot; x0, y0, x1, y1: integer; rgb: LongWord);
var
  dx, dy, sx, sy, err, e2: integer;
begin
  dx := Abs(x1 - x0);
  dy := -Abs(y1 - y0);
  if x0 < x1 then sx := 1 else sx := -1;
  if y0 < y1 then sy := 1 else sy := -1;
  err := dx + dy;
  repeat
    { width 2: extend perpendicular to the local slope (shallow ->
      vertical pair, steep -> horizontal pair) - cairo's butt stroke
      covers +-1 px across the ideal line }
    if Abs(dx) >= Abs(dy) then
    begin
      PlotBlendPixel(p, x0, y0, rgb, 255);
      PlotBlendPixel(p, x0, y0 + 1, rgb, 255);
    end
    else
    begin
      PlotBlendPixel(p, x0, y0, rgb, 255);
      PlotBlendPixel(p, x0 + 1, y0, rgb, 255);
    end;
    if (x0 = x1) and (y0 = y1) then
      break;
    e2 := 2 * err;
    if e2 >= dy then
    begin
      Inc(err, dy);
      Inc(x0, sx);
    end;
    if e2 <= dx then
    begin
      Inc(err, dx);
      Inc(y0, sy);
    end;
  until false;
end;

procedure PlotDashedVLine(const p: TPlot; x, y0, y1, w: integer;
  rgb: LongWord; onLen, offLen: integer);
var
  y, seg, half: integer;
  on: boolean;
begin
  if w < 1 then
    exit;
  half := w div 2;
  y := y0;
  on := true;
  while y <= y1 do
  begin
    if on then
    begin
      seg := onLen;
      if y + seg - 1 > y1 then
        seg := y1 - y + 1;
      PlotFillRect(p, x - half, y, w, seg, rgb, 255);
      Inc(y, onLen);
    end
    else
      Inc(y, offLen);
    on := not on;
  end;
end;

function wa_round_s(v: Single): LongInt; cdecl; external;

function PlotRound(v: Single): integer; inline;
begin
  Result := wa_round_s(v);
end;

end.
