unit UColors;

// Shared colour helpers for the routing/floorplan views. Pure functions only
// (no FMX, no form state). Previously these existed twice: as TForm1 methods
// and as nested copies inside PaintRouting.

interface

uses
  System.UITypes;

// HSV -> TAlphaColor. H in degrees [0..360], S/L/A in [0..1]. The FMX
// TAlphaColorF.CreateHSL helper is not available on this toolchain, so the
// conversion is done by hand.
function HslToColor(H, S, L, A: Single): TAlphaColor;

// The legend/port colour for a layer, keyed by its position in the parsed
// library order (LayerIndex < 0 is treated as 0). Base hue 216, 222-degree step
// per layer. AAlpha is the opacity [0..1].
function RoutingLayerColor(LayerIndex: Integer; AAlpha: Single): TAlphaColor;

// The 'spectrogram' colour scale for wire length: blue - cyan - green - yellow
// - red. T is clamped to [0..1]; 0 = shortest (blue), 1 = at/over the cap (red).
function LengthColor(T: Double): TAlphaColor;

const
  LayerBaseHue = 216.0;
  LayerHueShift = 222.0;

  // ---- Shared palette ($AARRGGBB): one definition per colour value so a
  // change lands in a single place. Used by the pipeline/clock/floorplan/
  // routing canvases, the legends and the validation lists.
  PalCanvasBg   = $FFF2F2F2;  // paint-canvas background
  PalGrey       = $FF909090;  // passive / separators
  PalGreyMid    = $FF606060;  // disabled swatch borders
  PalGreyDark   = $FF404040;  // panel outline
  PalGreyGrid   = $FF555555;  // grid lines (clock page)
  PalPads       = $FF455A64;  // I/O pads
  PalPanelFrost = $E6FFFFFF;  // legend panel backdrop

  // Cell / status colours (pipeline, clock tree, selection lists).
  PalGreen      = $FF00C853;  // splitter / OK
  PalRedDeep    = $FFD50000;  // flip-flop / removed
  PalRed        = $FFFF0000;  // hard error / validation item
  PalOrange     = $FFFF8C00;  // warning
  PalBlueDark   = $FF1565C0;  // clock-capable logic
  PalBlueLight  = $FF81D4FA;  // general logic / active
  PalYellow     = $FFFFEB3B;  // primary inputs / clock highlight
  PalPurple     = $FF9C27B0;  // primary outputs

  // Floorplan / routing geometry.
  PalLogicInk   = $FF2563C4;  // logic rows
  PalLogicPaper = $FFE8F0FF;  // logic row backdrop
  PalClockInk   = $FF6BA839;  // clock rows
  PalClockPaper = $FFF0F7E8;  // clock row backdrop
  PalBiasInk    = $FFFF6251;  // bias rows
  PalCellBlue   = $FF3A88FE;  // placed logic components
  PalClockCell  = $FF96D35F;  // clock subtree nodes
  PalSelStroke  = $FF7BA8FF;  // selection highlight
  PalOkStroke   = $FFB8E68E;  // validated / OK highlight
  PalWireDim    = $60000000;  // dim connection wire (pipeline)

  // Translucent LEF port-shape colours (cell viewer), one per layer slot.
  CellShapeLayerColors: array[0..5] of TAlphaColor = (
    $B34488CC, $B388AA44, $B3CC8844, $B38844CC, $B344CCAA, $B3CC4488);

implementation

uses
  System.Math;

function HslToColor(H, S, L, A: Single): TAlphaColor;
var
  C, X, M: Single;
  R, G, B: Single;
  Hh: Single;
begin
  if S <= 0 then
  begin
    R := L;
    G := L;
    B := L;
  end
  else
  begin
    Hh := H / 360.0;
    C := (1 - Abs(2 * L - 1)) * S;
    X := C * (1 - Abs(Frac(Hh * 6.0) * 2 - 1));
    M := L - C / 2;
    case Trunc(Hh * 6.0) mod 6 of
      0: begin R := C; G := X; B := 0; end;
      1: begin R := X; G := C; B := 0; end;
      2: begin R := 0; G := C; B := X; end;
      3: begin R := 0; G := X; B := C; end;
      4: begin R := X; G := 0; B := C; end;
    else
      begin R := C; G := 0; B := X; end;
    end;
    R := R + M;
    G := G + M;
    B := B + M;
  end;
  Result := TAlphaColorF.Create(R, G, B, A).ToAlphaColor;
end;

function RoutingLayerColor(LayerIndex: Integer; AAlpha: Single): TAlphaColor;
begin
  if LayerIndex < 0 then
    LayerIndex := 0;
  Result := HslToColor(LayerBaseHue + LayerIndex * LayerHueShift, 0.65, 0.55, AAlpha);
end;

function LengthColor(T: Double): TAlphaColor;
const
  Stops: array[0..4] of record P: Double; R, G, B: Byte; end = (
    (P: 0.00; R: 0;   G: 0;    B: 255),
    (P: 0.25; R: 0;   G: 255;  B: 255),
    (P: 0.50; R: 0;   G: 255;  B: 0),
    (P: 0.75; R: 255; G: 255;  B: 0),
    (P: 1.00; R: 255; G: 0;    B: 0));
var
  i: Integer;
  Frac, R, G, B: Double;
begin
  if T <= 0 then
    Result := $FF0000FF
  else if T >= 1 then
    Result := $FFFF0000
  else
  begin
    i := 0;
    while (i < 4) and (T > Stops[i + 1].P) do
      Inc(i);
    if Stops[i + 1].P = Stops[i].P then
      Frac := 0
    else
      Frac := (T - Stops[i].P) / (Stops[i + 1].P - Stops[i].P);
    R := Stops[i].R + (Stops[i + 1].R - Stops[i].R) * Frac;
    G := Stops[i].G + (Stops[i + 1].G - Stops[i].G) * Frac;
    B := Stops[i].B + (Stops[i + 1].B - Stops[i].B) * Frac;
    Result := $FF000000 or (Round(R) shl 16) or (Round(G) shl 8) or Round(B);
  end;
end;

end.
