unit URoutingLegend;

// The interactive routing-page layer legend (top-right of the routing canvas):
// one row per routing layer (colour box + name; box filled = visible, outlined =
// hidden) plus a 'Debug' row that toggles length-based colouring.
//
// The layout lives here so the draw and the hit-test can never drift apart -
// they used to be duplicated in DrawRoutingLegend / PaintBox4MouseDown with a
// "must match" comment.

interface

uses
  System.Classes, System.UITypes, FMX.Graphics;

type
  // What a click on the legend hit.
  TLegendHit = (lhNone, lhLayer, lhLengthToggle);

// Draws the legend at the top-right of a canvas ACanvasWidth wide.
// ALayers: layer names in display order; AEnabled: parallel visibility flags;
// ALengthColorOn: the length/debug toggle state.
procedure DrawLegend(Canvas: TCanvas; ACanvasWidth: Single;
  ALayers: TStrings; const AEnabled: TArray<Boolean>; ALengthColorOn: Boolean);

// Hit-tests a click. ALayerIndex is set (and lhLayer returned) when a layer's
// colour box was hit.
function HitTestLegend(X, Y, ACanvasWidth: Single; ALayerCount: Integer;
  out ALayerIndex: Integer): TLegendHit;

type
  // Informational legend entry (not clickable): swatch colour, label, and an
  // indent level for sub-items of the row above.
  TLegendInfoItem = record
    Colour: TAlphaColor;
    Text: string;
    Indent: Integer;
  end;

function LegendItem(AColour: TAlphaColor; const AText: string;
  AIndent: Integer = 0): TLegendInfoItem;

// Draws a descriptive legend panel in the canvas' top-right corner: a heading
// then one swatch+label row per item. Purely informational - DrawLegend above is
// the interactive (routing layer) one.
procedure DrawInfoLegend(Canvas: TCanvas; ACanvasWidth: Single;
  const AItems: TArray<TLegendInfoItem>; const ATitle: string = 'Legend');

implementation

uses
  System.Types, FMX.Types,
  UColors;

const
  LegendPad = 8;       // margin from the canvas top-right corner
  RowH = 18;           // per-row height
  BoxSize = 12;        // colour-box side length
  TextX = 26;          // text left offset within a row
  PanelW = 70;         // legend panel width (names are short)

function LegendItem(AColour: TAlphaColor; const AText: string;
  AIndent: Integer): TLegendInfoItem;
begin
  Result.Colour := AColour;
  Result.Text := AText;
  Result.Indent := AIndent;
end;

procedure DrawInfoLegend(Canvas: TCanvas; ACanvasWidth: Single;
  const AItems: TArray<TLegendInfoItem>; const ATitle: string);
const
  Pad = 8;
  InfoRowH = 16;
  BoxSz = 10;
  PanelW = 158;
var
  PanelX, PanelY, PanelH, BoxL, BoxT: Single;
  i: Integer;
begin
  PanelH := Pad * 2 + InfoRowH * (Length(AItems) + 1);
  PanelX := ACanvasWidth - PanelW - Pad;
  PanelY := Pad;
  Canvas.Fill.Color := PalPanelFrost;
  Canvas.FillRect(TRectF.Create(PanelX, PanelY, PanelX + PanelW,
    PanelY + PanelH), 0, 0, [], 1.0);
  Canvas.Fill.Color := PalGreyDark;
  Canvas.FillRect(TRectF.Create(PanelX, PanelY, PanelX + PanelW, PanelY + 1), 0, 0, [], 1.0);
  Canvas.FillRect(TRectF.Create(PanelX, PanelY + PanelH - 1, PanelX + PanelW,
    PanelY + PanelH), 0, 0, [], 1.0);
  Canvas.FillRect(TRectF.Create(PanelX, PanelY, PanelX + 1, PanelY + PanelH), 0, 0, [], 1.0);
  Canvas.FillRect(TRectF.Create(PanelX + PanelW - 1, PanelY, PanelX + PanelW,
    PanelY + PanelH), 0, 0, [], 1.0);

  Canvas.Font.Size := 10;
  Canvas.Fill.Color := TAlphaColorRec.Black;
  Canvas.FillText(TRectF.Create(PanelX + Pad, PanelY + Pad - 2,
    PanelX + PanelW - Pad, PanelY + Pad + InfoRowH), ATitle, False, 1.0, [],
    TTextAlign.Leading, TTextAlign.Center);

  for i := 0 to High(AItems) do
  begin
    BoxL := PanelX + Pad + AItems[i].Indent * 12;
    BoxT := PanelY + Pad + (i + 1) * InfoRowH + (InfoRowH - BoxSz) / 2;
    Canvas.Fill.Color := AItems[i].Colour;
    Canvas.FillRect(TRectF.Create(BoxL, BoxT, BoxL + BoxSz, BoxT + BoxSz),
      0, 0, [], 1.0);
    Canvas.Fill.Color := TAlphaColorRec.Black;
    Canvas.FillText(TRectF.Create(BoxL + BoxSz + 6, BoxT - 3,
      PanelX + PanelW - Pad, BoxT + 13), AItems[i].Text, False, 1.0, [],
      TTextAlign.Leading, TTextAlign.Center);
  end;
end;

procedure DrawLegend(Canvas: TCanvas; ACanvasWidth: Single;
  ALayers: TStrings; const AEnabled: TArray<Boolean>; ALengthColorOn: Boolean);
var
  PanelX, PanelY, PanelH: Single;
  i, x: Integer;
  BoxLeft, BoxTop: Single;
  Enabled: Boolean;
begin
  PanelH := LegendPad * 2 + (ALayers.Count + 1) * RowH;
  PanelX := ACanvasWidth - PanelW - LegendPad;
  PanelY := LegendPad;
  // Panel background (semi-transparent) so the grid underneath stays readable.
  Canvas.Fill.Color := PalPanelFrost;
  Canvas.FillRect(TRectF.Create(PanelX, PanelY, PanelX + PanelW, PanelY + PanelH),
    0, 0, [], 1.0);
  Canvas.Fill.Color := PalGreyDark;
  Canvas.FillRect(TRectF.Create(PanelX, PanelY, PanelX + PanelW, PanelY + 1), 0, 0, [], 1.0);
  Canvas.FillRect(TRectF.Create(PanelX, PanelY + PanelH - 1, PanelX + PanelW, PanelY + PanelH), 0, 0, [], 1.0);
  Canvas.FillRect(TRectF.Create(PanelX, PanelY, PanelX + 1, PanelY + PanelH), 0, 0, [], 1.0);
  Canvas.FillRect(TRectF.Create(PanelX + PanelW - 1, PanelY, PanelX + PanelW, PanelY + PanelH), 0, 0, [], 1.0);

  Canvas.Font.Size := 10;
  for i := 0 to ALayers.Count - 1 do
  begin
    BoxLeft := PanelX + LegendPad;
    BoxTop := PanelY + LegendPad + i * RowH + (RowH - BoxSize) / 2;
    if i <= High(AEnabled) then
      Enabled := AEnabled[i]
    else
      Enabled := True;
    if Enabled then
    begin
      Canvas.Fill.Color := UColors.RoutingLayerColor(i, 1.0);
      Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + BoxSize, BoxTop + BoxSize),
        0, 0, [], 1.0);
    end
    else
    begin
      Canvas.Fill.Color := TAlphaColorRec.White;
      Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + BoxSize, BoxTop + BoxSize),
        0, 0, [], 1.0);
      Canvas.Fill.Color := PalGreyMid;
      Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + BoxSize, BoxTop + 1), 0, 0, [], 1.0);
      Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop + BoxSize - 1, BoxLeft + BoxSize, BoxTop + BoxSize), 0, 0, [], 1.0);
      Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + 1, BoxTop + BoxSize), 0, 0, [], 1.0);
      Canvas.FillRect(TRectF.Create(BoxLeft + BoxSize - 1, BoxTop, BoxLeft + BoxSize, BoxTop + BoxSize), 0, 0, [], 1.0);
    end;
    Canvas.Fill.Color := TAlphaColorRec.Black;
    Canvas.FillText(TRectF.Create(PanelX + TextX, BoxTop - 4,
      PanelX + PanelW - LegendPad, BoxTop + 14),
      ALayers[i], False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);
  end;

  // Separator above the length-colour toggle.
  BoxTop := PanelY + LegendPad + ALayers.Count * RowH;
  Canvas.Fill.Color := PalGrey;
  Canvas.FillRect(TRectF.Create(PanelX + LegendPad, BoxTop,
    PanelX + PanelW - LegendPad, BoxTop + 1), 0, 0, [], 1.0);

  // Length/Debug toggle row: gradient box (blue->red) filled when active.
  BoxLeft := PanelX + LegendPad;
  BoxTop := PanelY + LegendPad + ALayers.Count * RowH + (RowH - BoxSize) / 2;
  if ALengthColorOn then
  begin
    for x := 0 to BoxSize - 1 do
    begin
      Canvas.Fill.Color := UColors.LengthColor(x / (BoxSize - 1));
      Canvas.FillRect(TRectF.Create(BoxLeft + x, BoxTop,
        BoxLeft + x + 1, BoxTop + BoxSize), 0, 0, [], 1.0);
    end;
  end
  else
  begin
    Canvas.Fill.Color := TAlphaColorRec.White;
    Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + BoxSize, BoxTop + BoxSize),
      0, 0, [], 1.0);
    Canvas.Fill.Color := PalGreyMid;
    Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + BoxSize, BoxTop + 1), 0, 0, [], 1.0);
    Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop + BoxSize - 1, BoxLeft + BoxSize, BoxTop + BoxSize), 0, 0, [], 1.0);
    Canvas.FillRect(TRectF.Create(BoxLeft, BoxTop, BoxLeft + 1, BoxTop + BoxSize), 0, 0, [], 1.0);
    Canvas.FillRect(TRectF.Create(BoxLeft + BoxSize - 1, BoxTop, BoxLeft + BoxSize, BoxTop + BoxSize), 0, 0, [], 1.0);
  end;
  Canvas.Fill.Color := TAlphaColorRec.Black;
  Canvas.FillText(TRectF.Create(PanelX + TextX, BoxTop - 4,
    PanelX + PanelW - LegendPad, BoxTop + 14),
    'Debug', False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);
end;

function HitTestLegend(X, Y, ACanvasWidth: Single; ALayerCount: Integer;
  out ALayerIndex: Integer): TLegendHit;
var
  PanelX, PanelY, BoxLeft, BoxTop: Single;
  i: Integer;
begin
  Result := lhNone;
  ALayerIndex := -1;
  PanelX := ACanvasWidth - PanelW - LegendPad;
  PanelY := LegendPad;
  for i := 0 to ALayerCount - 1 do
  begin
    BoxLeft := PanelX + LegendPad;
    BoxTop := PanelY + LegendPad + i * RowH + (RowH - BoxSize) / 2;
    if (X >= BoxLeft) and (X <= BoxLeft + BoxSize) and
       (Y >= BoxTop) and (Y <= BoxTop + BoxSize) then
    begin
      ALayerIndex := i;
      Result := lhLayer;
      Exit;
    end;
  end;
  BoxLeft := PanelX + LegendPad;
  BoxTop := PanelY + LegendPad + ALayerCount * RowH + (RowH - BoxSize) / 2;
  if (X >= BoxLeft) and (X <= BoxLeft + BoxSize) and
     (Y >= BoxTop) and (Y <= BoxTop + BoxSize) then
    Result := lhLengthToggle;
end;

end.
