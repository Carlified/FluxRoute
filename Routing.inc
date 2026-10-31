// Routing: painting, the sequential maze router, bias geometry/routing, the
// validation (length + buffer insertion), resonance overlay and LeeRoute.
// Included from MainWindow's implementation via {$I Routing.inc}.

procedure TForm1.RepaintRoutingPage;
var
  i: Integer;
begin
  if TabControl1.TabIndex <> TabRouting then
    Exit;
  for i := 0 to Children.Count - 1 do
    if Children[i] is TControl then
      TControl(Children[i]).Repaint;
end;

procedure TForm1.PaintRouting(Sender: TObject; Canvas: TCanvas);
const
  CellAlpha = $50;   // placed cells: semi-transparent grey
  PortAlpha = 0.55;   // port shapes: semi-transparent
var
  R: TRectF;
  ClipState: TCanvasSaveState;
  DieW, DieH, Core: Double;
  Cols, Rows, i: Integer;
  X, Y: Single;
  BlockPx, WorldX0, WorldX1, WorldY0, WorldY1: Single;
  I0, I1, J0, J1: Integer;
  P: TPlacedComponent;
  MaskPt: TPoint;
  ClkL, ClkIdx: Integer;
  ClkNode: TPlacedClockNode;
  Sp: TSpineComponent;

  function WX(AValue: Single): Single;
  begin
    Result := FRoutePanX + AValue * FRouteZoom;
  end;

  function WY(AValue: Single): Single;
  begin
    Result := FRoutePanY + AValue * FRouteZoom;
  end;

  // Draws every port shape of one cell, translated to its placed origin (and
  // rotated 90 deg CCW for trunk cells). AWidth/AHeight are the cell's own
  // dimensions in um; AX/AY are the placed top-left grid cell.
  procedure DrawCellPorts(ACell: TCell; AX, AY: Integer;
    AWidth, AHeight: Double; Rotated: Boolean);
  var
    Port: TPort;
    Shape: TPortShape;
    Wx1, Wy1, Wx2, Wy2: Double;
  begin
    if ACell = nil then
      Exit;
    for Port in ACell.Ports do
      for Shape in Port.Shapes do
      begin
        if not RoutingLayerEnabled(Shape.Layer) then
          Continue;
        Canvas.Fill.Color := UColors.RoutingLayerColor(FRoutingLayers.IndexOf(Shape.Layer), PortAlpha);
        if Rotated then
        begin
          Wx1 := AX * Core + (AHeight - Shape.y2);
          Wx2 := AX * Core + (AHeight - Shape.y1);
          Wy1 := AY * Core + Shape.x1;
          Wy2 := AY * Core + Shape.x2;
        end
        else
        begin
          // Canvas Y runs down while LEF Y runs up: flip (AHeight - y).
          Wx1 := AX * Core + Shape.x1;
          Wx2 := AX * Core + Shape.x2;
          Wy1 := AY * Core + (AHeight - Shape.y2);
          Wy2 := AY * Core + (AHeight - Shape.y1);
        end;
        Canvas.FillRect(TRectF.Create(WX(Wx1), WY(Wy1), WX(Wx2), WY(Wy2)),
          0, 0, [], 1.0);
      end;
    for Port in ACell.PowerPorts do
      for Shape in Port.Shapes do
      begin
        if not RoutingLayerEnabled(Shape.Layer) then
          Continue;
        Canvas.Fill.Color := UColors.RoutingLayerColor(FRoutingLayers.IndexOf(Shape.Layer), PortAlpha);
        if Rotated then
        begin
          Wx1 := AX * Core + (AHeight - Shape.y2);
          Wx2 := AX * Core + (AHeight - Shape.y1);
          Wy1 := AY * Core + Shape.x1;
          Wy2 := AY * Core + Shape.x2;
        end
        else
        begin
          // Canvas Y runs down while LEF Y runs up: flip (AHeight - y).
          Wx1 := AX * Core + Shape.x1;
          Wx2 := AX * Core + Shape.x2;
          Wy1 := AY * Core + (AHeight - Shape.y2);
          Wy2 := AY * Core + (AHeight - Shape.y1);
        end;
        Canvas.FillRect(TRectF.Create(WX(Wx1), WY(Wy1), WX(Wx2), WY(Wy2)),
          0, 0, [], 1.0);
      end;
  end;

begin
  RefreshDesignConfig;
  R := TRectF.Create(0, 0, PaintBox4.Width, PaintBox4.Height);
  Canvas.Fill.Color := TAlphaColorRec.White;
  Canvas.FillRect(R, 0, 0, [], 1.0);

  ClipState := Canvas.SaveState;
  try
    Canvas.IntersectClipRect(R);

    if (FDesignConfig.CoreUm <= 0) or (FDesignConfig.DieWUm <= 0) or
       (FDesignConfig.DieHUm <= 0) then
    begin
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(R, 'No valid placement - check the Placement Configuration tab.',
        False, 1.0, [], TTextAlign.Center, TTextAlign.Center);
      Exit;
    end;

    Core := FDesignConfig.CoreUm;
    // The die the layout actually uses: bias expansion widens it at run time, and
    // the routing grid has to cover that or every wire hugs the old edge.
    DieW := EffectiveDieWUm;
    DieH := FDesignConfig.DieHUm;

    Cols := Round(DieW / Core);
    Rows := Round(DieH / Core);

    if FRouteNeedsFit and (PaintBox4.Width > 20) and (PaintBox4.Height > 20) then
    begin
      FRouteZoom := (Min(PaintBox4.Width, PaintBox4.Height) - 20) / Max(DieW, DieH);
      FRoutePanX := (PaintBox4.Width - DieW * FRouteZoom) / 2;
      FRoutePanY := (PaintBox4.Height - DieH * FRouteZoom) / 2;
      FRouteNeedsFit := False;
    end;

    // Die body.
    Canvas.Fill.Color := PalCanvasBg;
    Canvas.FillRect(TRectF.Create(WX(0), WY(0), WX(DieW), WY(DieH)), 0, 0, [], 1.0);

      // Placed logic cells (semi-transparent grey), then their ports.
      Canvas.Fill.Color := UColors.HslToColor(0, 0, 0.6, CellAlpha / 255);
      for i := 0 to High(FPlacedComponents) do
      begin
        P := FPlacedComponents[i];
        Canvas.FillRect(TRectF.Create(WX(P.X * Core), WY(P.Y * Core),
          WX((P.X + P.W) * Core), WY((P.Y + P.H) * Core)), 0, 0, [], 1.0);
      end;
      for i := 0 to High(FPlacedComponents) do
      begin
        P := FPlacedComponents[i];
        if (P.Gate <> nil) and (P.Gate.Cell <> nil) then
          DrawCellPorts(P.Gate.Cell, P.X, P.Y,
            P.Gate.Cell.Width, P.Gate.Cell.Height, False);
      end;

      // Clock tree cells (interior nodes), unrotated.
      Canvas.Fill.Color := UColors.HslToColor(0, 0, 0.6, CellAlpha / 255);
      for ClkL := 0 to High(FClockSubtree) do
        for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
        begin
          ClkNode := FClockSubtree[ClkL][ClkIdx];
          if ClkNode.IsLeaf then
            Continue;
          Canvas.FillRect(TRectF.Create(WX(ClkNode.X * Core), WY(ClkNode.Y * Core),
            WX((ClkNode.X + ClkNode.W) * Core),
            WY((ClkNode.Y + ClkNode.H) * Core)), 0, 0, [], 1.0);
        end;
      for ClkL := 0 to High(FClockSubtree) do
        for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
        begin
          ClkNode := FClockSubtree[ClkL][ClkIdx];
          if ClkNode.IsLeaf or (ClkNode.Gate = nil) or (ClkNode.Gate.Cell = nil) then
            Continue;
          DrawCellPorts(ClkNode.Gate.Cell, ClkNode.X, ClkNode.Y,
            ClkNode.Gate.Cell.Width, ClkNode.Gate.Cell.Height, False);
        end;

      // Trunk spine cells; trunk cells are rotated 90 deg CCW.
      Canvas.Fill.Color := UColors.HslToColor(0, 0, 0.6, CellAlpha / 255);
      for i := 0 to High(FSpine) do
      begin
        Sp := FSpine[i];
        Canvas.FillRect(TRectF.Create(WX(Sp.X * Core), WY(Sp.Y * Core),
          WX((Sp.X + Sp.W) * Core), WY((Sp.Y + Sp.H) * Core)), 0, 0, [], 1.0);
      end;
      for i := 0 to High(FSpine) do
      begin
        Sp := FSpine[i];
        if (Sp.Gate <> nil) and (Sp.Gate.Cell <> nil) then
          DrawCellPorts(Sp.Gate.Cell, Sp.X, Sp.Y,
            Sp.Gate.Cell.Width, Sp.Gate.Cell.Height, Sp.Rotated);
      end;

      // Grid of core-block-sized squares (culled to the visible area).
      BlockPx := Core * FRouteZoom;
      if (BlockPx >= MinBlockPx) and (FRouteZoom > 0) then
      begin
        WorldX0 := (0 - FRoutePanX) / FRouteZoom;
        WorldX1 := (PaintBox4.Width - FRoutePanX) / FRouteZoom;
        WorldY0 := (0 - FRoutePanY) / FRouteZoom;
        WorldY1 := (PaintBox4.Height - FRoutePanY) / FRouteZoom;

        I0 := Trunc(WorldX0 / Core);
        if I0 < 0 then I0 := 0;
        I1 := Trunc(WorldX1 / Core) + 1;
        if I1 > Cols then I1 := Cols;
        J0 := Trunc(WorldY0 / Core);
        if J0 < 0 then J0 := 0;
        J1 := Trunc(WorldY1 / Core) + 1;
        if J1 > Rows then J1 := Rows;

        Canvas.Fill.Color := PalGrey;
        for i := I0 to I1 do
        begin
          X := WX(i * Core);
          Canvas.FillRect(TRectF.Create(X - GridHalf, WY(0), X + GridHalf, WY(DieH)),
            0, 0, [], 1.0);
        end;
        for i := J0 to J1 do
        begin
          Y := WY(i * Core);
          Canvas.FillRect(TRectF.Create(WX(0), Y - GridHalf, WX(DieW), Y + GridHalf),
            0, 0, [], 1.0);
        end;
      end;

      // Die boundary.
      Canvas.Fill.Color := PalGreyDark;
      Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(0) - BorderHalf,
        WX(DieW) + BorderHalf, WY(0) + BorderHalf), 0, 0, [], 1.0); // top
      Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(DieH) - BorderHalf,
        WX(DieW) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // bottom
      Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(0) - BorderHalf,
        WX(0) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // left
      Canvas.FillRect(TRectF.Create(WX(DieW) - BorderHalf, WY(0) - BorderHalf,
        WX(DieW) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // right

      // Routed traces (and the Debug resonance overlay), drawn last so they sit
      // on top of the grid and die boundary.
      // Length-fixing validation buffers (mask layer): drawn like any other placed
  // cell (grey body + port shapes, layer toggles apply) so they read as part of
  // the layout. Their routed halves are ordinary traces in FRouteTraces.
  for i := 0 to High(FLengthBuffers) do
    if (FLengthBuffers[i].Gate <> nil) and
       (FLengthBuffers[i].Gate.Cell <> nil) and
       FGatePlacement.TryGetValue(FLengthBuffers[i].Gate, MaskPt) then
    begin
      Canvas.Fill.Color := $50808080;
      Canvas.FillRect(TRectF.Create(
        WX(MaskPt.X * Core), WY(MaskPt.Y * Core),
        WX((MaskPt.X + FLengthBuffers[i].W) * Core),
        WY((MaskPt.Y + FLengthBuffers[i].H) * Core)), 0, 0, [], 1.0);
      DrawCellPorts(FLengthBuffers[i].Gate.Cell, MaskPt.X, MaskPt.Y,
        FLengthBuffers[i].Gate.Cell.Width, FLengthBuffers[i].Gate.Cell.Height,
        False);
    end;

  DrawRoutedTraces(Canvas);

      // Fixed top-right layer legend (screen space): one row per used layer; a
      // filled box means enabled, outlined means hidden.
      if FRoutingLayers.Count > 0 then
        DrawRoutingLegend(Canvas);
  finally
    Canvas.RestoreState(ClipState);
  end;
end;

procedure TForm1.PaintBox4MouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
var
  Hit: URoutingLegend.TLegendHit;
  LayerIdx: Integer;
begin
  if Button <> TMouseButton.mbLeft then
    Exit;
  // Hit-test the top-right layer legend first; clicking a colour box toggles
  // that layer (or the Debug colouring) instead of starting a pan.
  if FRoutingLayers.Count > 0 then
  begin
    Hit := URoutingLegend.HitTestLegend(X, Y, PaintBox4.Width,
      FRoutingLayers.Count, LayerIdx);
    if Hit = lhLayer then
    begin
      ToggleRoutingLayer(FRoutingLayers[LayerIdx]);
      Exit;
    end
    else if Hit = lhLengthToggle then
    begin
      FRouteLengthColor := not FRouteLengthColor;
      RepaintRoutingPage;
      Exit;
    end;
  end;
  FRouteDragging := True;
  FRouteDragX := X;
  FRouteDragY := Y;
end;

procedure TForm1.PaintBox4MouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Single);
begin
  if FRouteDragging then
  begin
    FRoutePanX := FRoutePanX + (X - FRouteDragX);
    FRoutePanY := FRoutePanY + (Y - FRouteDragY);
    FRouteDragX := X;
    FRouteDragY := Y;
    RepaintRoutingPage;
  end;
end;

procedure TForm1.PaintBox4MouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  FRouteDragging := False;
end;

// Ordered list of layers shown for routing: the library's routing layers plus
// the user-chosen bias layer (FBiasLayer), which is not a signal layer.
procedure TForm1.BuildRoutingLayers;
var
  i: Integer;
begin
  if FRoutingLayers = nil then
    FRoutingLayers := TStringList.Create;
  FRoutingLayers.Clear;
  if FLib <> nil then
    for i := 0 to FLib.Layers.Count - 1 do
      if FLib.Layers[i].LayerType = ltRouting then
        FRoutingLayers.Add(FLib.Layers[i].Name);
  if (FBiasLayer <> '') and (FRoutingLayers.IndexOf(FBiasLayer) < 0) then
    FRoutingLayers.Add(FBiasLayer);
  // Newly-seen layers default to enabled.
  for i := 0 to FRoutingLayers.Count - 1 do
    if not FRoutingLayerEnabled.ContainsKey(FRoutingLayers[i]) then
      FRoutingLayerEnabled.Add(FRoutingLayers[i], True);
end;

function TForm1.RoutingLayerEnabled(const ALayer: string): Boolean;
begin
  Result := True;
  if FRoutingLayerEnabled <> nil then
    FRoutingLayerEnabled.TryGetValue(ALayer, Result);
end;

procedure TForm1.ToggleRoutingLayer(const ALayer: string);
var
  B: Boolean;
begin
  B := RoutingLayerEnabled(ALayer);
  if FRoutingLayerEnabled <> nil then
    FRoutingLayerEnabled.AddOrSetValue(ALayer, not B);
  RepaintRoutingPage;
end;

// Draws the fixed top-right layer legend. Row order = FRoutingLayers order; a
// filled colour box means the layer is enabled, an outlined box means hidden.
// A final 'Length' row toggles length-based (temperature) trace colouring.
procedure TForm1.DrawRoutingLegend(Canvas: TCanvas);
var
  i: Integer;
  Enabled: TArray<Boolean>;
begin
  SetLength(Enabled, FRoutingLayers.Count);
  for i := 0 to FRoutingLayers.Count - 1 do
    Enabled[i] := RoutingLayerEnabled(FRoutingLayers[i]);
  URoutingLegend.DrawLegend(Canvas, PaintBox4.Width, FRoutingLayers, Enabled,
    FRouteLengthColor);
end;

// Maze-routes every signal net and clock link: each net tries the routing layers
// one at a time (no vias), then a via pass; each wire blocks its layer as it routes.
procedure TForm1.RunRouting;
var
  Core: Double;
  Path: TArray<TPoint>;
  PathLayers: TArray<Integer>;
  NC: TNetConnection;
  Net: TNet;
  Pair: TPair<string, TNet>;
  Driver, Load: TGateInstance;
  DriverPin, LoadPin: string;
  Failed: Integer;
  Trace: TRoutedTrace;
  i, j, k, L, ci: Integer;
  Jobs: TRouteJobArray;
  Job: TRouteJob;
  Order: TArray<Integer>;
  TmpIdx: Integer;
  Pt: TPoint;
  SigRouted, ClkRouted: Integer;
  TreeModel: TBlifModel;
  ClkPos: TDictionary<TGateInstance, TPoint>;
  ClkRot: TDictionary<TGateInstance, Boolean>;
  Sp: TSpineComponent;
  Node: TPlacedClockNode;
  GatePos, DriverPos: TPoint;
  UseClkPad: Boolean;
  PassRouted, PassFailed, NoCommon, NoMetal: Integer;

  // Marks a routed path's cells as hard obstacles on the layers they use, so
  // later nets on those layers route around them (classic sequential maze).
  procedure BlockPath(Pth: TArray<TPoint>; PL: TArray<Integer>);
  var
    ii, La, Lb, Lk: Integer;
  begin
    for ii := 0 to High(Pth) do
    begin
      Pt := Pth[ii];
      if (Pt.X < 0) or (Pt.X >= FRouteObstaclesW) or
         (Pt.Y < 0) or (Pt.Y >= FRouteObstaclesH) then
        Continue;
      if (PL[ii] >= 0) and (PL[ii] <= High(FRouteObstacles)) then
        FRouteObstacles[PL[ii]][Pt.Y * FRouteObstaclesW + Pt.X] := True;
      // A via is two consecutive points at the same cell on different layers.
      // Its shaft crosses every layer in between (FRouteLayers is in library
      // stack order), so those blocks are obstructed as well.
      if (ii > 0) and (ii - 1 <= High(PL)) and
         (Pth[ii - 1].X = Pt.X) and (Pth[ii - 1].Y = Pt.Y) then
      begin
        La := PL[ii - 1];
        Lb := PL[ii];
        if La > Lb then
        begin
          Lk := La;
          La := Lb;
          Lb := Lk;
        end;
        for Lk := La to Lb do
          if (Lk >= 0) and (Lk <= High(FRouteObstacles)) then
            FRouteObstacles[Lk][Pt.Y * FRouteObstaclesW + Pt.X] := True;
      end;
    end;
  end;

  // Appends a routed job's path to FRouteTraces and repaints immediately, so
  // each wire appears on screen as soon as it is routed.
  procedure PublishTrace(const AJob: TRouteJob);
  var
    jj: Integer;
  begin
    if not AJob.Routed or (Length(AJob.Path) = 0) then
      Exit;
    Trace.NetName := AJob.NetName;
    Trace.Points := AJob.Path;
    Trace.StartMask := AJob.StartMask;
    Trace.GoalMask := AJob.GoalMask;
    SetLength(Trace.Layers, Length(AJob.PathLayers));
    for jj := 0 to High(AJob.PathLayers) do
      Trace.Layers[jj] := FRouteLayers[AJob.PathLayers[jj]];
    SetLength(FRouteTraces, Length(FRouteTraces) + 1);
    FRouteTraces[High(FRouteTraces)] := Trace;
    // Progressive feedback, throttled: a synchronous repaint and message pump
    // per wire is needlessly heavy. Re-entrancy is already blocked by
    // FRoutingBusy in the button handlers, so the pump only runs safe messages.
    Inc(FPublishSinceRepaint);
    if FPublishSinceRepaint >= RepaintEvery then
    begin
      FPublishSinceRepaint := 0;
      PaintBox4.Repaint;
      Application.ProcessMessages;
    end;
  end;

  // Builds one TRouteJob for a signal net (from the placement model) or for a
  // single clock link (one driver -> load branch of a clock net's fan-out).
  procedure PushJob(ANetName: string; AKind: TRouteJobKind;
    ADriver: TGateInstance; ADriverPin: string;
    ALoad: TGateInstance; ALoadPin: string);
  var
    SJ: TRouteJob;
  begin
    SJ.NetName := ANetName;
    SJ.Kind := AKind;
    SJ.Driver := ADriver;
    SJ.DriverPin := ADriverPin;
    SJ.Load := ALoad;
    SJ.LoadPin := ALoadPin;
    SJ.Routed := False;
    SJ.Path := nil;
    SJ.PathLayers := nil;
    SJ.StartValid := False;
    SJ.GoalValid := False;
    SJ.StartMask := High(UInt64);
    SJ.GoalMask := High(UInt64);
    SJ.Dist := High(Integer) div 2;
    if ADriver = nil then
    begin
      if GetPad(ANetName, SJ.Start) then
        SJ.StartValid := True;
    end
    else
    begin
      SJ.StartMask := PortLayerMask(ADriver, ADriverPin);
      if GatePinBlock(ADriver, ADriverPin, FirstMaskLayer(SJ.StartMask), SJ.Start) then
        SJ.StartValid := True;
    end;
    if ALoad = nil then
    begin
      if GetPad(ANetName, SJ.Goal) then
        SJ.GoalValid := True;
    end
    else
    begin
      SJ.GoalMask := PortLayerMask(ALoad, ALoadPin);
      if GatePinBlock(ALoad, ALoadPin, FirstMaskLayer(SJ.GoalMask), SJ.Goal) then
        SJ.GoalValid := True;
    end;
    if SJ.StartValid and SJ.GoalValid then
      SJ.Dist := Abs(SJ.Start.X - SJ.Goal.X) + Abs(SJ.Start.Y - SJ.Goal.Y);
    SetLength(Jobs, Length(Jobs) + 1);
    Jobs[High(Jobs)] := SJ;
  end;

  // Human-readable layer names for a pin's allowed-layer mask ('none' = the pin
  // has shapes but none on a routing layer).
  function MaskText(Mask: UInt64): string;
  var
    L2: Integer;
  begin
    Result := '';
    for L2 := 0 to High(FRouteLayers) do
      if ((Mask shr L2) and 1) <> 0 then
      begin
        if Result <> '' then
          Result := Result + '/';
        Result := Result + FRouteLayers[L2];
      end;
    if Result = '' then
      Result := 'none';
  end;

begin
  RefreshDesignConfig;
  FPublishSinceRepaint := 0;
  MemoRouting.Lines.Clear;
  if FFlowStage > fsBias then FFlowStage := fsBias;
  if FPlacementModel = nil then
  begin
    MemoRouting.Lines.Add('No placement model to route.');
    Exit;
  end;
  if FDesignConfig.CoreUm <= 0 then
  begin
    MemoRouting.Lines.Add('Core block size is invalid.');
    Exit;
  end;
  Core := FDesignConfig.CoreUm;
  if FLib = nil then
  begin
    MemoRouting.Lines.Add('No library loaded.');
    Exit;
  end;

    // All routing layers, in library order. The first is the primary layer;
    // subsequent layers are used one at a time for the nets the earlier layer
    // could not route.
    SetLength(FRouteLayers, 0);
    for i := 0 to FLib.Layers.Count - 1 do
      if FLib.Layers[i].LayerType = ltRouting then
      begin
        SetLength(FRouteLayers, Length(FRouteLayers) + 1);
        FRouteLayers[High(FRouteLayers)] := FLib.Layers[i].Name;
      end;
    FRouteSignalLayer := '';
    if Length(FRouteLayers) > 0 then
      FRouteSignalLayer := FRouteLayers[0];
    if FRouteSignalLayer = '' then
    begin
      MemoRouting.Lines.Add('No routing layer defined in the library.');
      Exit;
    end;

    BuildRoutingObstacles;

    SetLength(FRouteTraces, 0);
    SetLength(FBiasCells, 0);
    Failed := 0;
    SetLength(Jobs, 0);

    // Collect signal nets (non-clock pins, placed gates only).
    for Pair in FPlacementModel.Nets do
    begin
      Net := Pair.Value;
      // Clock-network nets (root 'clk', 'clk_*', '<Leaf>__clkbuf_<n>') are routed
      // by the clock pass below, not skipped as signals.
      if UNetNaming.IsClockNetName(Net.Name) then
        Continue;
      Driver := nil;
      DriverPin := '';
      Load := nil;
      LoadPin := '';
      for NC in Net.Connections do
      begin
        if IsClockPinName(NC.PinName) then
          Continue;
        if not FGatePlacement.ContainsKey(NC.Gate) then
          Continue;
        if NC.IsDriver then
        begin
          Driver := NC.Gate;
          DriverPin := NC.PinName;
        end
        else
        begin
          Load := NC.Gate;
          LoadPin := NC.PinName;
        end;
      end;
      if (Driver = nil) and (Load = nil) then
        Continue;
      PushJob(Net.Name, rkSignal, Driver, DriverPin, Load, LoadPin);
    end;

    // Collect clock links from the buffered clock tree (driver -> each load).
    TreeModel := FClockBufferedModel;
    if TreeModel = nil then
      TreeModel := FClockModel;
    if (TreeModel <> nil) and (Length(FPlanLevels) > 0) then
    begin
      ClkPos := TDictionary<TGateInstance, TPoint>.Create;
      ClkRot := TDictionary<TGateInstance, Boolean>.Create;
      try
        for i := 0 to High(FSpine) do
        begin
          Sp := FSpine[i];
          if Sp.Gate <> nil then
          begin
            ClkPos.AddOrSetValue(Sp.Gate, TPoint.Create(Sp.X, Sp.Y));
            ClkRot.AddOrSetValue(Sp.Gate, Sp.Rotated);
          end;
        end;
        for L := 0 to High(FClockSubtree) do
          for ci := 0 to High(FClockSubtree[L]) do
          begin
            Node := FClockSubtree[L][ci];
            if Node.Gate <> nil then
            begin
              ClkPos.AddOrSetValue(Node.Gate, TPoint.Create(Node.X, Node.Y));
              ClkRot.AddOrSetValue(Node.Gate, False);
            end;
          end;
        for Pair in TreeModel.Nets do
        begin
          Net := Pair.Value;
          // Clock nets: 'clk' root, 'clk_*', or a buffer output
          // '<Leaf>__clkbuf_<n>' - the '__clkbuf_' marker, not the 'clk' prefix.
          if not UNetNaming.IsClockNetName(Net.Name) then
            Continue;
          Driver := nil;
          DriverPin := '';
          UseClkPad := False;
          for NC in Net.Connections do
            if NC.IsDriver and (ClkPos.ContainsKey(NC.Gate) or
               FGatePlacement.ContainsKey(NC.Gate)) then
            begin
              Driver := NC.Gate;
              DriverPin := NC.PinName;
              Break;
            end;
          if (Driver = nil) and SameText(Net.Name, UNetNaming.ClockRootName) and
             (FClockPadIdx >= 0) then
            UseClkPad := True;
          if (Driver = nil) and (not UseClkPad) then
          begin
            Continue;
          end;
          if UseClkPad then
            DriverPos := TPoint.Create(FPads[FClockPadIdx].X, FPads[FClockPadIdx].Y)
          else if ClkPos.ContainsKey(Driver) then
          begin
            if not GatePinBlockAt(Driver, DriverPin, 0,
              ClkPos[Driver].X, ClkPos[Driver].Y, ClkRot[Driver], DriverPos) then
              Continue;
          end
          else if FGatePlacement.TryGetValue(Driver, GatePos) then
          begin
            // Mask-layer buffer: unrotated, positioned by the length placer.
            if not GatePinBlockAt(Driver, DriverPin, 0,
              GatePos.X, GatePos.Y, False, DriverPos) then
              Continue;
          end
          else
            Continue;
          // Each non-driver connection is a point-to-point link.
          for NC in Net.Connections do
          begin
            if NC.IsDriver then
              Continue;
            if NC.Gate = nil then
            begin
              Continue;
            end;
            if ClkPos.TryGetValue(NC.Gate, GatePos) then
            begin
              if not GatePinBlockAt(NC.Gate, NC.PinName, 0,
                GatePos.X, GatePos.Y, ClkRot[NC.Gate], Pt) then
                Continue;
            end
            else if FGatePlacement.TryGetValue(NC.Gate, GatePos) then
            begin
              // Mask-layer buffer: unrotated.
              if not GatePinBlockAt(NC.Gate, NC.PinName, 0,
                GatePos.X, GatePos.Y, False, Pt) then
                Continue;
            end
            else
              Continue;
            Job.NetName := Net.Name;
            Job.Kind := rkClock;
            Job.Driver := nil; // clock links use the pre-resolved DriverPos
            Job.DriverPin := '';
            Job.Load := NC.Gate;
            Job.LoadPin := NC.PinName;
            Job.Routed := False;
            Job.Path := nil;
            Job.PathLayers := nil;
            Job.Start := DriverPos;
            Job.Goal := Pt;
            Job.StartMask := High(UInt64); // clock pad / synthetic: any layer
            if not UseClkPad then
              Job.StartMask := PortLayerMask(Driver, DriverPin);
            Job.GoalMask := PortLayerMask(NC.Gate, NC.PinName);
            Job.StartValid := True;
            Job.GoalValid := True;
            Job.Dist := Abs(Job.Start.X - Job.Goal.X) +
              Abs(Job.Start.Y - Job.Goal.Y);
            SetLength(Jobs, Length(Jobs) + 1);
            Jobs[High(Jobs)] := Job;
          end;
        end;
      finally
        ClkPos.Free;
        ClkRot.Free;
      end;
    end;

    // Pins that declare no shared routing layer are still connectable (the wire
    // arrives on a trunk layer and the pin via drops onto the pin's own metal),
    // so this is informational: those nets will need a via at each pin.
    NoCommon := 0;
    for i := 0 to High(Jobs) do
      if Jobs[i].StartValid and Jobs[i].GoalValid and
         ((Jobs[i].StartMask and Jobs[i].GoalMask) = 0) then
      begin
        Inc(NoCommon);
        if NoCommon <= 8 then
          MemoRouting.Lines.Add(Format(
            'Net %s: pins share no routing layer (driver on %s, load on %s) - ' +
            'a pin via will be needed.',
            [Jobs[i].NetName, MaskText(Jobs[i].StartMask),
             MaskText(Jobs[i].GoalMask)]));
      end;
    if NoCommon > 0 then
      MemoRouting.Lines.Add(Format(
        '%d net(s) share no pin layer: they need a via along the route.',
        [NoCommon]));
    // A pin whose LEF shapes are all on non-routing layers has no metal to
    // connect to at all, so those nets cannot be routed.
    NoMetal := 0;
    for i := 0 to High(Jobs) do
      if Jobs[i].StartValid and Jobs[i].GoalValid and
         ((Jobs[i].StartMask = 0) or (Jobs[i].GoalMask = 0)) then
      begin
        Inc(NoMetal);
        if NoMetal <= 8 then
          MemoRouting.Lines.Add(Format(
            'Net %s: pin has no metal on a routing layer (driver %s, load %s).',
            [Jobs[i].NetName, MaskText(Jobs[i].StartMask),
             MaskText(Jobs[i].GoalMask)]));
      end;
    if NoMetal > 0 then
      MemoRouting.Lines.Add(Format(
        '%d net(s) cannot be routed: a pin has no routing-layer metal.',
        [NoMetal]));

    // Shortest links first (stable insertion order for ties). A short wire is
    // easy to place first, leaving the longer ones the remaining space.
    SetLength(Order, Length(Jobs));
    for i := 0 to High(Jobs) do
      Order[i] := i;
    for i := 0 to High(Order) - 1 do
      for j := i + 1 to High(Order) do
        if Jobs[Order[j]].Dist < Jobs[Order[i]].Dist then
        begin
          TmpIdx := Order[i];
          Order[i] := Order[j];
          Order[j] := TmpIdx;
        end;

    // ---- Sequential Lee maze routing ----
    // Layer passes first (no vias), then a via pass; each wire blocks its layer as it routes.
    for L := 0 to High(FRouteLayers) do
    begin
      PassRouted := 0;
      PassFailed := 0;
      for k := 0 to High(Order) do
      begin
        Job := Jobs[Order[k]];
        if Job.Routed then
          Continue;
        if Job.StartValid and Job.GoalValid and
           LeeRoute(Job.Start, Job.Goal, L, Job.StartMask, Job.GoalMask,
             Path, PathLayers) then
        begin
          Job.Routed := True;
          Job.Path := Path;
          Job.PathLayers := PathLayers;
          BlockPath(Path, PathLayers);
          Inc(PassRouted);
          PublishTrace(Job);
        end
        else
        begin
          Job.Routed := False;
          Inc(PassFailed);
        end;
        Jobs[Order[k]] := Job;
      end;
      MemoRouting.Lines.Add(Format(
        'Layer %d (%s): %d routed, %d failed.',
        [L, FRouteLayers[L], PassRouted, PassFailed]));
    end;

    // Final pass: vias allowed across all layers, for everything still
    // unrouted. (This is the only pass that may switch layers mid-wire.)
    PassRouted := 0;
    PassFailed := 0;
    for k := 0 to High(Order) do
    begin
      Job := Jobs[Order[k]];
      if Job.Routed then
        Continue;
      if Job.StartValid and Job.GoalValid and
         LeeRoute(Job.Start, Job.Goal, -1, Job.StartMask, Job.GoalMask,
           Path, PathLayers) then
      begin
        Job.Routed := True;
        Job.Path := Path;
        Job.PathLayers := PathLayers;
        BlockPath(Path, PathLayers);
        Inc(PassRouted);
        PublishTrace(Job);
      end
      else
      begin
        Job.Routed := False;
        Inc(PassFailed);
      end;
      Jobs[Order[k]] := Job;
    end;
    MemoRouting.Lines.Add(Format(
      'Via pass: %d routed, %d failed.', [PassRouted, PassFailed]));

    // Final report.
    Failed := 0;
    SigRouted := 0;
    ClkRouted := 0;
    for i := 0 to High(Jobs) do
    begin
      Job := Jobs[i];
      if not Job.Routed or (Length(Job.Path) = 0) then
      begin
        Inc(Failed);
        Continue;
      end;
      if Job.Kind = rkSignal then
        Inc(SigRouted)
      else
        Inc(ClkRouted);
    end;

    MemoRouting.Lines.Add(Format(
      'Routed %d signal net(s) + %d clock link(s) on %d routing layer(s).',
      [SigRouted, ClkRouted, Length(FRouteLayers)]));
    FRouteFailedLinks := Failed;
    if Failed > 0 then
      MemoRouting.Lines.Add(Format('%d link(s) could not be routed.',
        [Failed]));
  if (Failed = 0) and (FFlowStage < fsRouted) then FFlowStage := fsRouted;
  RepaintRoutingPage;
end;

// Per-block obstacle maps per routing layer: blocks covered by pin geometry
// (logic or clock) are hard obstacles; cell footprints on other layers are not.
procedure TForm1.BuildRoutingObstacles;
var
  Core: Double;
  W, H: Integer;
  i, j: Integer;
  P: TPlacedComponent;
  Sp: TSpineComponent;
  Node: TPlacedClockNode;
  MaskPt: TPoint;
  L, ci: Integer;

  // Marks a pin's footprint on EVERY routing layer: pins are obstruction
  // pillars, so nothing may route or via through a pin block on any layer. Only
  // the goal port of the route being searched is exempt (see LeeRoute).
  procedure MarkGatePins(G: TGateInstance; AX, AY: Integer; Rotated: Boolean);
  var
    Port2: TPort;
    Shape2: TPortShape;

    procedure MarkShape(const AShape: TPortShape);
    var
      k, x, y, Lx0, Ly0, Lx1, Ly1, Tmp2: Integer;
      CellH: Double;
    begin
      CellH := G.Cell.Height;
      if CellH <= 0 then
        CellH := Core;
      if Rotated then
      begin
        Lx0 := Trunc((AX * Core + (CellH - AShape.y2)) / Core);
        Ly0 := Trunc((AY * Core + AShape.x1) / Core);
        Lx1 := Trunc((AX * Core + (CellH - AShape.y1)) / Core);
        Ly1 := Trunc((AY * Core + AShape.x2) / Core);
      end
      else
      begin
        // Canvas Y runs down while LEF Y runs up: flip (CellH - y).
        Lx0 := Trunc((AX * Core + AShape.x1) / Core);
        Ly0 := Trunc((AY * Core + (CellH - AShape.y2)) / Core);
        Lx1 := Trunc((AX * Core + AShape.x2) / Core);
        Ly1 := Trunc((AY * Core + (CellH - AShape.y1)) / Core);
      end;
      if Lx1 < Lx0 then begin Tmp2 := Lx0; Lx0 := Lx1; Lx1 := Tmp2; end;
      if Ly1 < Ly0 then begin Tmp2 := Ly0; Ly0 := Ly1; Ly1 := Tmp2; end;
      for k := 0 to High(FRouteLayers) do
        for x := Lx0 to Lx1 do
          for y := Ly0 to Ly1 do
            if (x >= 0) and (x < W) and (y >= 0) and (y < H) then
              FRouteObstacles[k][y * W + x] := True;
    end;

  begin
    if (G = nil) or (G.Cell = nil) then
      Exit;
    for Port2 in G.Cell.Ports do
      for Shape2 in Port2.Shapes do
        MarkShape(Shape2);
    for Port2 in G.Cell.PowerPorts do
      for Shape2 in Port2.Shapes do
        MarkShape(Shape2);
  end;

begin
  Core := FDesignConfig.CoreUm;
  if Core <= 0 then
    Core := FPlanCore;
  W := 0;
  H := 0;
  if FDesignConfig.DieWUm > 0 then
    W := Round(EffectiveDieWUm / Core);
  if FDesignConfig.DieHUm > 0 then
    H := Round(FDesignConfig.DieHUm / Core);
  if (W <= 0) or (H <= 0) then
    Exit;

  FRouteObstaclesW := W;
  FRouteObstaclesH := H;
  // One obstacle map per routing layer.
  SetLength(FRouteObstacles, Length(FRouteLayers));
  for j := 0 to High(FRouteLayers) do
  begin
    SetLength(FRouteObstacles[j], W * H);
    for i := 0 to W * H - 1 do
      FRouteObstacles[j][i] := False;
  end;

  // Logic cells (in FPlacedComponents), unrotated.
  for i := 0 to High(FPlacedComponents) do
  begin
    P := FPlacedComponents[i];
    if (P.Gate <> nil) and (P.Gate.Cell <> nil) then
      MarkGatePins(P.Gate, P.X, P.Y, False);
  end;
  // Clock trunk (spine) cells - trunk cells are rotated 90 deg CCW.
  for i := 0 to High(FSpine) do
  begin
    Sp := FSpine[i];
    if (Sp.Gate <> nil) and (Sp.Gate.Cell <> nil) then
      MarkGatePins(Sp.Gate, Sp.X, Sp.Y, Sp.Rotated);
  end;
  // Clock tree cells (subtree interior + leaves), unrotated.
  for L := 0 to High(FClockSubtree) do
    for ci := 0 to High(FClockSubtree[L]) do
    begin
      Node := FClockSubtree[L][ci];
      if (Node.Gate <> nil) and (Node.Gate.Cell <> nil) then
        MarkGatePins(Node.Gate, Node.X, Node.Y, False);
    end;
  // Length-fixing validation buffers (mask layer), unrotated. This runs before
  // RunRouting (ReapplyLengthBufferMask is called just before it), so their
  // pins are real obstructions and wires route around them.
  for i := 0 to High(FLengthBuffers) do
    if (FLengthBuffers[i].Gate <> nil) and
       (FLengthBuffers[i].Gate.Cell <> nil) and
       FGatePlacement.TryGetValue(FLengthBuffers[i].Gate, MaskPt) then
      MarkGatePins(FLengthBuffers[i].Gate, MaskPt.X, MaskPt.Y, False);
  // Validation-inserted buffers are real placed cells: their pins obstruct too,
  // otherwise a re-route after validation can pass straight through them.
  for i := 0 to High(FValidationBuffers) do
    if (FValidationBuffers[i].Gate <> nil) and
       (FValidationBuffers[i].Gate.Cell <> nil) and
       FGatePlacement.TryGetValue(FValidationBuffers[i].Gate, MaskPt) then
      MarkGatePins(FValidationBuffers[i].Gate, MaskPt.X, MaskPt.Y, False);
  // I/O anchor pads are pillars on the die edge: nothing crosses them on any
  // layer (arriving on one is exempt, since it is a route's goal).
  for i := 0 to High(FPads) do
    for j := 0 to High(FRouteLayers) do
      if (FPads[i].X >= 0) and (FPads[i].X < W) and
         (FPads[i].Y >= 0) and (FPads[i].Y < H) then
        FRouteObstacles[j][FPads[i].Y * W + FPads[i].X] := True;
end;

// Grows a band's TOP (Which=0) or MIDDLE (Which=1) bias row by ByRows cells to
// relieve congestion; reports and aborts (layout unchanged) when the die is full.
function TForm1.IncreaseBiasRowHeight(Band, Which, ByRows: Integer): Boolean;
var
  DieHBlocks: Integer;
  RowName: string;
begin
  Result := False;
  if (Band < 0) or (Band >= Length(FBiasRowH)) or (Which < 0) or (Which > 1) or
     (ByRows < 1) then
    Exit;
  if FFloorplanH > 0 then
    DieHBlocks := FFloorplanH
  else
    Exit;
  if FPlanLastTotalH + ByRows + 2 > DieHBlocks then
  begin
    if Which = 0 then
      RowName := 'top'
    else
      RowName := 'middle';
    ReportBiasError(Format('Bias expansion: band %d needs %d more row(s) for its ' +
      '%s bias row, but the die is full (%d of %d rows used).',
      [Band, ByRows, RowName, FPlanLastTotalH, DieHBlocks]));
    Exit;
  end;
  FBiasRowH[Band][Which] := FBiasRowH[Band][Which] + ByRows;
  RebuildFloorplanPreserve;
  Result := True;
end;

// Increase the height of the topmost (IsTop=True, band 0's top bias row) or the
// bottommost full-width bias row by ByRows cells. Same height error handling.
function TForm1.IncreaseTopBottomBiasRow(IsTop: Boolean;
  ByRows: Integer): Boolean;
var
  DieHBlocks: Integer;
  Side: string;
begin
  Result := False;
  if ByRows < 1 then
    Exit;
  if FFloorplanH > 0 then
    DieHBlocks := FFloorplanH
  else
    Exit;
  if FPlanLastTotalH + ByRows + 2 > DieHBlocks then
  begin
    if IsTop then
      Side := 'top'
    else
      Side := 'bottom';
    ReportBiasError(Format('Bias expansion: the %s bias row needs %d more row(s), ' +
      'but the die is full (%d of %d rows used).',
      [Side, ByRows, FPlanLastTotalH, DieHBlocks]));
    Exit;
  end;
  if IsTop then
  begin
    if (Length(FBiasRowH) > 0) and (Length(FBiasRowH[0]) > 0) then
    begin
      FBiasRowH[0][0] := FBiasRowH[0][0] + ByRows;
      RebuildFloorplanPreserve;
      Result := True;
    end;
  end
  else
  begin
    FBottomBiasH := FBottomBiasH + ByRows;
    RebuildFloorplanPreserve;
    Result := True;
  end;
end;

// Widens a vertical bias lane by ByCols (0 = left feed, 1 = far-right). The die
// takes the extra columns (GrowDieWidth), so the row wrap window is unchanged
// and no cell moves; when the die cannot grow, the reason is reported.
function TForm1.IncreaseClockTrunkColumn(ColIdx, ByCols: Integer): Boolean;
var
  DieWBlocks, MaxRowW, NewLaneW: Integer;
  NewLane: TArray<Integer>;
begin
  Result := False;
  if (ColIdx < 0) or (ColIdx > 1) or (ByCols < 1) then
    Exit;
  if Length(FBiasLaneW) <> 2 then
  begin
    NewLane := nil;
    SetLength(NewLane, 2);
    NewLane[0] := 1;
    NewLane[1] := 1;
    if Length(FBiasLaneW) >= 1 then
    begin
      if FBiasLaneW[0] >= 1 then
        NewLane[0] := FBiasLaneW[0];
      if Length(FBiasLaneW) >= 2 then
        if FBiasLaneW[1] >= 1 then
          NewLane[1] := FBiasLaneW[1];
    end;
    FBiasLaneW := NewLane;
  end;
  if FFloorplanW > 0 then
    DieWBlocks := FFloorplanW
  else
    Exit;
  MaxRowW := FPlanXRight - FPlanXLeft;
  if MaxRowW < 1 then
    MaxRowW := 1;
  NewLaneW := FPlanLane0W + FPlanLane1W + ByCols; // widened lane adds ByCols
  if MaxRowW + FPlanBiasTrunkW + NewLaneW + FPlanTrunkW > DieWBlocks then
    if not GrowDieWidth(ByCols) then
    begin
      ReportBiasError(Format('Bias expansion: clock bias lane %d needs %d more ' +
        'column(s) and the die cannot be widened any further.', [ColIdx, ByCols]));
      Exit;
    end;
  FBiasLaneW[ColIdx] := FBiasLaneW[ColIdx] + ByCols;
  RebuildFloorplanPreserve;
  Result := True;
end;

// Widens the far-left bias trunk by ByCols columns, growing the die by the same
// count so the rows keep their width (and therefore their wrapping). Rows are
// never re-packed: a placement within a row does not change here.
function TForm1.IncreaseBiasTrunkColumn(ByCols: Integer): Boolean;
var
  DieWBlocks, MaxRowW, NewTrunkW: Integer;
begin
  Result := False;
  if ByCols < 1 then
    Exit;
  if FFloorplanW > 0 then
    DieWBlocks := FFloorplanW
  else
    Exit;
  MaxRowW := FPlanXRight - FPlanXLeft;
  if MaxRowW < 1 then
    MaxRowW := 1;
  NewTrunkW := FPlanBiasTrunkW + ByCols;
  if MaxRowW + NewTrunkW + FPlanLane0W + FPlanTrunkW + FPlanLane1W > DieWBlocks then
    if not GrowDieWidth(ByCols) then
    begin
      ReportBiasError(Format('Bias expansion: the bias trunk needs %d more ' +
        'column(s) and the die cannot be widened any further.', [ByCols]));
      Exit;
    end;
  FPlanBiasTrunkW := NewTrunkW;
  RebuildFloorplanPreserve;
  Result := True;
end;

// Collects the power ports of one placed cell on AEdge (top/bottom) as TBiasPort
// records (grid block + current), via the placed origin (AX, AY).
procedure TForm1.CollectCellPorts(G: TGateInstance; AX, AY: Integer;
  AEdge: TPortEdge; var Ports: TArray<TBiasPort>);
var
  Port: TPort;
  Shape: TPortShape;
  BP: TBiasPort;
  Core, CellH: Double;
  BX0, BX1, HBlocks: Integer;
  Swp: Integer;
begin
  if (G = nil) or (G.Cell = nil) then
    Exit;
  Core := FPlanCore;
  if Core <= 0 then
    Exit;
  CellH := G.Cell.Height;
  if CellH <= 0 then
    CellH := Core;
  HBlocks := Max(1, Round(CellH / Core));
  for Port in G.Cell.PowerPorts do
    for Shape in Port.Shapes do
      if Shape.Edge = AEdge then
      begin
        BP.Gate := G;
        BP.Edge := AEdge;
        // Horizontal port block from the parsed shape geometry (X is not
        // affected by the Y-axis flip).
        BX0 := Trunc((AX * Core + Shape.x1) / Core);
        BX1 := Trunc((AX * Core + Shape.x2) / Core);
        if BX1 < BX0 then begin Swp := BX0; BX0 := BX1; BX1 := Swp; end;
        BP.X := (BX0 + BX1) div 2;
        // The bias line must NOT enter the cell: the offshoot ends on the cell's
        // top/bottom edge row so it reads as a T touching the cell.
        if AEdge = peTop then
          BP.Y := AY
        else
          BP.Y := AY + HBlocks - 1;
        BP.CurrentUa := Shape.CurrentUa;
        SetLength(Ports, Length(Ports) + 1);
        Ports[High(Ports)] := BP;
      end;
end;

// Greedy-partitions a side's ports (X order) into groups each under AMaxUa, one
// group per horizontal bias track; a group never splits a single port.
function TForm1.PartitionBiasPorts(const Ports: TArray<TBiasPort>;
  AMaxUa: Double): TArray<TBiasGroup>;
var
  Sorted: TArray<TBiasPort>;
  Order: TArray<Integer>;
  i, j, Tmp: Integer;
  G: TBiasGroup;
  GroupStart: Integer;
begin
  Result := nil;
  if AMaxUa <= 0 then
    Exit;
  // Keep only ports with current, ordered by X (placement order).
  SetLength(Sorted, 0);
  for i := 0 to High(Ports) do
    if Ports[i].CurrentUa > 0 then
    begin
      SetLength(Sorted, Length(Sorted) + 1);
      Sorted[High(Sorted)] := Ports[i];
    end;
  if Length(Sorted) = 0 then
    Exit;
  SetLength(Order, Length(Sorted));
  for i := 0 to High(Order) do
    Order[i] := i;
  for i := 0 to High(Order) - 1 do
    for j := i + 1 to High(Order) do
      if Sorted[Order[j]].X < Sorted[Order[i]].X then
      begin
        Tmp := Order[i];
        Order[i] := Order[j];
        Order[j] := Tmp;
      end;
  // Greedy partition: fill a group until adding the next port would exceed the
  // limit, then start a new group.
  GroupStart := 0;
  G.TotalUa := 0;
  G.Ports := nil;
  for i := 0 to High(Order) do
  begin
    if (i > GroupStart) and
       (G.TotalUa + Sorted[Order[i]].CurrentUa > AMaxUa) then
    begin
      // Close the current group.
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := G;
      G.Ports := nil;
      G.TotalUa := 0;
      GroupStart := i;
    end;
    SetLength(G.Ports, Length(G.Ports) + 1);
    G.Ports[High(G.Ports)] := Sorted[Order[i]];
    G.TotalUa := G.TotalUa + Sorted[Order[i]].CurrentUa;
  end;
  if Length(G.Ports) > 0 then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := G;
  end;
end;

// Collects the clock trunk's power ports on one side. Trunk cells are rotated
// 90 deg CCW, so LEF top ports face left and bottom ports face right.
procedure TForm1.CollectTrunkPorts(IsLeft: Boolean; var Ports: TArray<TBiasPort>);
var
  i, BX0, BX1, BY0, BY1, Swp, W: Integer;
  Port: TPort;
  Shape: TPortShape;
  BP: TBiasPort;
  Core, CellH: Double;
  AEdge: TPortEdge;
begin
  SetLength(Ports, 0);
  Core := FPlanCore;
  if Core <= 0 then
    Exit;
  if IsLeft then
    AEdge := peTop
  else
    AEdge := peBottom;
  for i := 0 to High(FSpine) do
  begin
    if (FSpine[i].Gate = nil) or (FSpine[i].Gate.Cell = nil) then
      Continue;
    CellH := FSpine[i].Gate.Cell.Height;
    if CellH <= 0 then
      CellH := Core;
    W := Max(1, Round(CellH / Core)); // placed width of the rotated cell
    for Port in FSpine[i].Gate.Cell.PowerPorts do
      for Shape in Port.Shapes do
        if Shape.Edge = AEdge then
        begin
          // Rotated 90 deg CCW: local (x, y) -> (CellH - y, x).
          BX0 := FSpine[i].X + Trunc((CellH - Shape.y2) / Core);
          BX1 := FSpine[i].X + Trunc((CellH - Shape.y1) / Core);
          BY0 := FSpine[i].Y + Trunc(Shape.x1 / Core);
          BY1 := FSpine[i].Y + Trunc(Shape.x2 / Core);
          if BX1 < BX0 then begin Swp := BX0; BX0 := BX1; BX1 := Swp; end;
          if BY1 < BY0 then begin Swp := BY0; BY0 := BY1; BY1 := Swp; end;
          BP.Gate := FSpine[i].Gate;
          BP.Edge := AEdge;
          // Left ports hug the trunk's left edge, right ports its right edge.
          // Clamp to the cell's own columns so the tap always reaches the cell
          // edge (an edge-hugging right port maps one block past the cell).
          if IsLeft then
            BP.X := BX0
          else
            BP.X := BX1;
          if BP.X < FSpine[i].X then
            BP.X := FSpine[i].X;
          if BP.X > FSpine[i].X + W - 1 then
            BP.X := FSpine[i].X + W - 1;
          BP.Y := (BY0 + BY1) div 2;
          BP.CurrentUa := Shape.CurrentUa;
          SetLength(Ports, Length(Ports) + 1);
          Ports[High(Ports)] := BP;
        end;
  end;
end;

// Partitions the trunk side's ports into groups each carrying at most AMaxUa,
// ordered by Y (ascending = top-to-bottom for the left side, descending =
// bottom-to-top for the right). Each group becomes one vertical track.
function TForm1.PartitionTrunkPorts(const Ports: TArray<TBiasPort>;
  AMaxUa: Double; Descending: Boolean): TArray<TBiasGroup>;
var
  Sorted: TArray<TBiasPort>;
  Order: TArray<Integer>;
  i, j, Tmp: Integer;
  G: TBiasGroup;
  GroupStart: Integer;
begin
  Result := nil;
  if AMaxUa <= 0 then
    Exit;
  SetLength(Sorted, 0);
  for i := 0 to High(Ports) do
    if Ports[i].CurrentUa > 0 then
    begin
      SetLength(Sorted, Length(Sorted) + 1);
      Sorted[High(Sorted)] := Ports[i];
    end;
  if Length(Sorted) = 0 then
    Exit;
  SetLength(Order, Length(Sorted));
  for i := 0 to High(Order) do
    Order[i] := i;
  for i := 0 to High(Order) - 1 do
    for j := i + 1 to High(Order) do
      if (not Descending and (Sorted[Order[j]].Y < Sorted[Order[i]].Y)) or
         (Descending and (Sorted[Order[j]].Y > Sorted[Order[i]].Y)) then
      begin
        Tmp := Order[i];
        Order[i] := Order[j];
        Order[j] := Tmp;
      end;
  // Greedy partition: fill a group until adding the next port would exceed.
  GroupStart := 0;
  G.TotalUa := 0;
  G.Ports := nil;
  for i := 0 to High(Order) do
  begin
    if (i > GroupStart) and
       (G.TotalUa + Sorted[Order[i]].CurrentUa > AMaxUa) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := G;
      G.Ports := nil;
      G.TotalUa := 0;
      GroupStart := i;
    end;
    SetLength(G.Ports, Length(G.Ports) + 1);
    G.Ports[High(G.Ports)] := Sorted[Order[i]];
    G.TotalUa := G.TotalUa + Sorted[Order[i]].CurrentUa;
  end;
  if Length(G.Ports) > 0 then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := G;
  end;
end;

// Routes the block-based bias tree: every cell of the network is recorded once
// with the directions it connects to on the bias layer (TBiasCell.Dirs), so the
// bias lines are enumerated and placed cell-by-cell like PTL runs - no more long
// single traces that doubled back through every port. The same cells drive the
// routing-page paint and the export enumerator.
// Builds the bias rows (one per horizontal bias track) for the current layout.
// Shared by the floorplan (to size the trunk) and the router (to place the rows);
// each row carries the total current it draws so branches can be packed onto
// shared trunks.
procedure TForm1.BuildBiasRows(MaxUa: Double; out Rows: TArray<TBiasRow>);
var
  NumBands, Band, g: Integer;
  LogicTopP, LogicBotP, ClockTopP, ClockBotP: TArray<TArray<TBiasPort>>;
  GA, GB: TArray<TBiasGroup>;
  Above, Below: TArray<TBiasPort>;
  Merged: Boolean;
  ChanY0, ChanY1, TrackY, TrackX: Integer;
  TrunkPorts: TArray<TBiasPort>;
  TrunkL, TrunkR, TopRow, BotRow: Integer;

  // Which band's row a cell's TOP row sits on; AOnClockRow says whether that is
  // the band's clock row (False = logic row). -1 when not on a logic/clock row.
  function RowBandOf(Y: Integer; var AOnClockRow: Boolean): Integer;
  var
    b: Integer;
  begin
    AOnClockRow := False;
    for b := 0 to NumBands - 1 do
    begin
      if (Y >= BandLogicRowY(b)) and (Y < BandLogicRowY(b) + FPlanRowHBlocks) then
      begin
        Result := b;
        Exit;
      end;
      if (Y >= BandClockRowY(b)) and (Y < BandClockRowY(b) + FPlanRowHBlocks) then
      begin
        Result := b;
        AOnClockRow := True;
        Exit;
      end;
    end;
    Result := -1;
  end;

  // Collects the AEdge power ports of every placed cell on Band's logic row
  // (AOnClockRow=False) or clock row (True), scanning BOTH the logic and clock
  // arrays - so an inserted buffer that landed on the "other" row still connects
  // to the bias row physically next to it, not one a band away.
  procedure CollectRowPorts(Band: Integer; AOnClockRow: Boolean; AEdge: TPortEdge;
    var APorts: TArray<TBiasPort>);
  var
    k, L, ci, b: Integer;
    OnClk: Boolean;
    Pt: TPoint;
  begin
    SetLength(APorts, 0);
    for k := 0 to High(FPlacedComponents) do
    begin
      b := RowBandOf(FPlacedComponents[k].Y, OnClk);
      if (b = Band) and (OnClk = AOnClockRow) then
        CollectCellPorts(FPlacedComponents[k].Gate, FPlacedComponents[k].X,
          FPlacedComponents[k].Y, AEdge, APorts);
    end;
    for L := 0 to High(FClockSubtree) do
      for ci := 0 to High(FClockSubtree[L]) do
        if not FClockSubtree[L][ci].IsLeaf then
        begin
          b := RowBandOf(FClockSubtree[L][ci].Y, OnClk);
          if (b = Band) and (OnClk = AOnClockRow) then
            CollectCellPorts(FClockSubtree[L][ci].Gate, FClockSubtree[L][ci].X,
              FClockSubtree[L][ci].Y, AEdge, APorts);
        end;
    // Length mask buffers on this row are wired to the same bias rail.
    for k := 0 to High(FLengthBuffers) do
      if (FLengthBuffers[k].Band = Band) and
         (FLengthBuffers[k].OnClockRow = AOnClockRow) and
         FGatePlacement.TryGetValue(FLengthBuffers[k].Gate, Pt) then
        CollectCellPorts(FLengthBuffers[k].Gate, Pt.X, Pt.Y, AEdge, APorts);
  end;

  procedure CollectLogic(Band: Integer; AEdge: TPortEdge;
    var APorts: TArray<TBiasPort>);
  begin
    CollectRowPorts(Band, False, AEdge, APorts);
  end;

  procedure CollectClock(Band: Integer; AEdge: TPortEdge;
    var APorts: TArray<TBiasPort>);
  begin
    CollectRowPorts(Band, True, AEdge, APorts);
  end;

  procedure AddRow(AKind: TBiasRowKind; AY: Integer; const AGrpA, AGrpB: TBiasGroup;
    ATrackX: Integer);
  var
    Total: Double;
  begin
    Total := AGrpA.TotalUa;
    if AKind = brMerged then
      Total := Total + AGrpB.TotalUa;
    SetLength(Rows, Length(Rows) + 1);
    Rows[High(Rows)].Y := AY;
    Rows[High(Rows)].Kind := AKind;
    Rows[High(Rows)].GrpA := AGrpA;
    Rows[High(Rows)].GrpB := AGrpB;
    Rows[High(Rows)].TrackX := ATrackX;
    Rows[High(Rows)].CurrentUa := Total;
  end;

begin
  SetLength(Rows, 0);
  NumBands := Length(FPlanBandStarts);
  if NumBands < 1 then
    Exit;
  SetLength(LogicTopP, NumBands);
  SetLength(LogicBotP, NumBands);
  SetLength(ClockTopP, NumBands);
  SetLength(ClockBotP, NumBands);
  for Band := 0 to NumBands - 1 do
  begin
    CollectLogic(Band, peTop, LogicTopP[Band]);
    CollectLogic(Band, peBottom, LogicBotP[Band]);
    CollectClock(Band, peTop, ClockTopP[Band]);
    CollectClock(Band, peBottom, ClockBotP[Band]);
  end;

  // Topmost full-width row: band 0's logic row top ports, tracks stepping UP.
  GA := PartitionBiasPorts(LogicTopP[0], MaxUa);
  ChanY1 := BandLogicRowY(0);
  for g := 0 to High(GA) do
  begin
    TrackY := ChanY1 - 1 - g;
    AddRow(brGroup, TrackY, GA[g], Default(TBiasGroup), 0);
  end;

  // Bottommost full-width row: the last band's clock row bottom ports.
  GA := PartitionBiasPorts(ClockBotP[NumBands - 1], MaxUa);
  ChanY0 := BandClockRowY(NumBands - 1) + FPlanRowHBlocks;
  if NumBands - 1 < Length(FClockRowExtra) then
    ChanY0 := ChanY0 + FClockRowExtra[NumBands - 1];
  for g := 0 to High(GA) do
  begin
    TrackY := ChanY0 + g;
    AddRow(brGroup, TrackY, GA[g], Default(TBiasGroup), 0);
  end;

  // Interior channels.
  for Band := 0 to NumBands - 1 do
  begin
    // MIDDLE bias row: logic bottom (above) meets clock top (below).
    Above := LogicBotP[Band];
    Below := ClockTopP[Band];
    GA := PartitionBiasPorts(Above, MaxUa);
    GB := PartitionBiasPorts(Below, MaxUa);
    Merged := False;
    if (Length(GA) > 0) and (Length(GB) > 0) then
      if GA[High(GA)].TotalUa + GB[High(GB)].TotalUa <= MaxUa then
        Merged := True;
    ChanY0 := BandClockRowY(Band) - BandMidBiasH(Band);
    ChanY1 := BandClockRowY(Band);
    for g := 0 to High(GA) do
    begin
      if Merged and (g = High(GA)) then
        Continue;
      TrackY := ChanY0 + g;
      AddRow(brGroup, TrackY, GA[g], Default(TBiasGroup), 0);
    end;
    for g := 0 to High(GB) do
    begin
      if Merged and (g = High(GB)) then
        Continue;
      TrackY := ChanY1 - 1 - g;
      AddRow(brGroup, TrackY, GB[g], Default(TBiasGroup), 0);
    end;
    if Merged then
      AddRow(brMerged, ChanY0 + High(GA), GA[High(GA)], GB[High(GB)], 0);

    // TOP bias row (band > 0): previous band's clock bottom + this logic top.
    if Band > 0 then
    begin
      Above := ClockBotP[Band - 1];
      Below := LogicTopP[Band];
      GA := PartitionBiasPorts(Above, MaxUa);
      GB := PartitionBiasPorts(Below, MaxUa);
      Merged := False;
      if (Length(GA) > 0) and (Length(GB) > 0) then
        if GA[High(GA)].TotalUa + GB[High(GB)].TotalUa <= MaxUa then
          Merged := True;
      ChanY0 := FPlanBandStarts[Band];
      ChanY1 := BandLogicRowY(Band);
      for g := 0 to High(GA) do
      begin
        if Merged and (g = High(GA)) then
          Continue;
        TrackY := ChanY0 + g;
        AddRow(brGroup, TrackY, GA[g], Default(TBiasGroup), 0);
      end;
      for g := 0 to High(GB) do
      begin
        if Merged and (g = High(GB)) then
          Continue;
        TrackY := ChanY1 - 1 - g;
        AddRow(brGroup, TrackY, GB[g], Default(TBiasGroup), 0);
      end;
      if Merged then
        AddRow(brMerged, ChanY0 + High(GA), GA[High(GA)], GB[High(GB)], 0);
    end;
  end;

  // Clock bias rows: vertical tracks in the flanking lanes that turn into the
  // topmost/bottommost full-width bias rows.
  TrunkL := FPlanXRight + FPlanLane0W;
  TrunkR := FPlanXRight + FPlanLane0W + FPlanTrunkW;
  TopRow := FPlanBandStarts[0];
  BotRow := FPlanBandStarts[NumBands - 1] + FPlanBandHeight[NumBands - 1] + FBottomBiasH;
  CollectTrunkPorts(True, TrunkPorts);
  GA := PartitionTrunkPorts(TrunkPorts, MaxUa, False);
  for g := 0 to High(GA) do
  begin
    TrackX := TrunkL - 1 - g;
    AddRow(brClock, TopRow + g, GA[g], Default(TBiasGroup), TrackX);
  end;
  CollectTrunkPorts(False, TrunkPorts);
  GB := PartitionTrunkPorts(TrunkPorts, MaxUa, False);
  for g := 0 to High(GB) do
  begin
    TrackX := TrunkR + (High(GB) - g);
    AddRow(brClock, BotRow - g, GB[g], Default(TBiasGroup), TrackX);
  end;
end;

// Packs branch currents (in placement order) onto trunks greedily: a branch joins
// the current trunk while the running total stays within Limit. Returns the trunk
// index of each branch (branches sharing an index share a trunk wire).
function TForm1.PackBiasTrunks(const Currents: TArray<Double>;
  Limit: Double): TArray<Integer>;
var
  i, T: Integer;
  Acc: Double;
begin
  SetLength(Result, Length(Currents));
  if Limit <= 0 then
  begin
    for i := 0 to High(Result) do
      Result[i] := i; // no trunk limit: one trunk per branch
    Exit;
  end;
  T := 0;
  Acc := 0;
  for i := 0 to High(Currents) do
  begin
    if (Acc > 0) and (Acc + Currents[i] > Limit) then
    begin
      Inc(T);
      Acc := 0;
    end;
    Result[i] := T;
    Acc := Acc + Currents[i];
  end;
end;

// Routes the block-based bias tree. Each horizontal bias row runs from its trunk
// column to its ports; rows are packed onto shared trunks (greedy, by the trunk
// current limit) so several branches can share a trunk wire. Each trunk then runs
// its own vertical line up to the die top edge, keeping every wire under limit.
procedure TForm1.RouteBiasLines;
var
  MaxUa, TrunkLimit: Double;
  BiasLayer: string;
  Cells: TDictionary<Int64, TBiasCell>;
  GateSeen: TDictionary<TGateInstance, Boolean>;
  B: TBiasCell;
  Rows: TArray<TBiasRow>;
  Currents: TArray<Double>;
  TrunkOf: TArray<Integer>;
  Col, a, b2, t, MaxTrunk, MaxY: Integer;
  TmpRow: TBiasRow;

  // Assembles one cell (merging directions when several lines share it). ATap
  // marks the added directions as skinny taps rather than full-width wire.
  procedure AddCell(AX, AY: Integer; ADir: Byte; ATap: Boolean);
  var
    Key: Int64;
  begin
    Key := (Int64(AX) shl 16) or Int64(AY);
    if not Cells.TryGetValue(Key, B) then
    begin
      B := Default(TBiasCell);
      B.X := AX;
      B.Y := AY;
      B.Layer := BiasLayer;
      B.Dirs := 0;
      B.TapDirs := 0;
      Cells.Add(Key, B);
    end;
    B.Dirs := B.Dirs or ADir;
    if ATap then
      B.TapDirs := B.TapDirs or ADir;
    Cells.AddOrSetValue(Key, B);
  end;

  // Horizontal line cells on row AY from AX0..AX1 inclusive.
  procedure WireH(AY, AX0, AX1: Integer; ATap: Boolean);
  var
    x: Integer;
    d: Byte;
  begin
    for x := AX0 to AX1 do
    begin
      d := 0;
      if x < AX1 then
        d := d or BiasDirE;
      if x > AX0 then
        d := d or BiasDirW;
      AddCell(x, AY, d, ATap);
    end;
  end;

  // Vertical line cells down column AX from AY0..AY1 inclusive.
  procedure WireV(AX, AY0, AY1: Integer; ATap: Boolean);
  var
    y: Integer;
    d: Byte;
  begin
    for y := AY0 to AY1 do
    begin
      d := 0;
      if y < AY1 then
        d := d or BiasDirS;
      if y > AY0 then
        d := d or BiasDirN;
      AddCell(AX, y, d, ATap);
    end;
  end;

  // The offshoot from the track at (PX, ATrackY) to the port (PX, PY): a skinny
  // tap. The junction cell gains the tap direction, intermediate cells pass
  // through, and the port cell is a dead end (a terminal -> cap block).
  procedure AddStub(PX, ATrackY, PY: Integer);
  var
    y: Integer;
  begin
    if PY = ATrackY then
      Exit;
    if PY > ATrackY then
    begin
      AddCell(PX, ATrackY, BiasDirS, True);
      for y := ATrackY + 1 to PY - 1 do
        AddCell(PX, y, BiasDirN or BiasDirS, True);
      AddCell(PX, PY, BiasDirN, True);
    end
    else
    begin
      AddCell(PX, ATrackY, BiasDirN, True);
      for y := PY + 1 to ATrackY - 1 do
        AddCell(PX, y, BiasDirN or BiasDirS, True);
      AddCell(PX, PY, BiasDirS, True);
    end;
  end;

  // Emits one group's track at ATrackY from trunk column ACol to the rightmost
  // port, with a stub to every port.
  procedure EmitGroupRow(const AGrp: TBiasGroup; ATrackY, ACol: Integer);
  var
    k, px: Integer;
  begin
    if Length(AGrp.Ports) = 0 then
      Exit;
    px := AGrp.Ports[0].X;
    for k := 1 to High(AGrp.Ports) do
      if AGrp.Ports[k].X > px then
        px := AGrp.Ports[k].X;
    WireH(ATrackY, ACol, px, False);
    for k := 0 to High(AGrp.Ports) do
      AddStub(AGrp.Ports[k].X, ATrackY, AGrp.Ports[k].Y);
  end;

  // Emits the merged edge case as one bias line at the shared track.
  procedure EmitMergedRow(const ATopGrp, ABottomGrp: TBiasGroup;
    ASharedY, ACol: Integer);
  var
    Combined: TArray<TBiasPort>;
    k, j, px: Integer;
    Tmp: TBiasPort;
  begin
    SetLength(Combined, 0);
    for k := 0 to High(ATopGrp.Ports) do
    begin
      SetLength(Combined, Length(Combined) + 1);
      Combined[High(Combined)] := ATopGrp.Ports[k];
    end;
    for k := 0 to High(ABottomGrp.Ports) do
    begin
      SetLength(Combined, Length(Combined) + 1);
      Combined[High(Combined)] := ABottomGrp.Ports[k];
    end;
    if Length(Combined) = 0 then
      Exit;
    for k := 1 to High(Combined) do
    begin
      Tmp := Combined[k];
      j := k - 1;
      while (j >= 0) and (Combined[j].X > Tmp.X) do
      begin
        Combined[j + 1] := Combined[j];
        Dec(j);
      end;
      Combined[j + 1] := Tmp;
    end;
    px := Combined[0].X;
    for k := 1 to High(Combined) do
      if Combined[k].X > px then
        px := Combined[k].X;
    WireH(ASharedY, ACol, px, False);
    for k := 0 to High(Combined) do
      AddStub(Combined[k].X, ASharedY, Combined[k].Y);
  end;

  // Emits one clock-bias group as a vertical track tapping each port, plus a
  // horizontal run from the trunk column ACol to the track.
  procedure EmitClockRow(const AGrp: TBiasGroup; ATrackX, ATurnY, ACol: Integer);
  var
    k, px, py, Y0, Y1: Integer;
  begin
    if Length(AGrp.Ports) = 0 then
      Exit;
    Y0 := ATurnY;
    Y1 := ATurnY;
    for k := 0 to High(AGrp.Ports) do
    begin
      py := AGrp.Ports[k].Y;
      if py < Y0 then
        Y0 := py;
      if py > Y1 then
        Y1 := py;
    end;
    WireV(ATrackX, Y0, Y1, False);
    if ACol < ATrackX then
      WireH(ATurnY, ACol, ATrackX, False)
    else
      WireH(ATurnY, ATrackX, ACol, False);
    for k := 0 to High(AGrp.Ports) do
    begin
      px := AGrp.Ports[k].X;
      py := AGrp.Ports[k].Y;
      if px < ATrackX then
        WireH(py, px, ATrackX, True)
      else
        WireH(py, ATrackX, px, True);
    end;
  end;

begin
  RefreshDesignConfig;
  if not FFloorplanValid then
    Exit;
  MaxUa := FDesignConfig.MaxBiasCurrentUa;
  if MaxUa <= 0 then
    Exit;
  TrunkLimit := FDesignConfig.MaxBiasTrunkCurrentUa;
  if TrunkLimit < MaxUa then
    TrunkLimit := MaxUa; // a trunk must at least carry one branch
  BuildRoutingLayers;
  BiasLayer := FBiasLayer;
  if BiasLayer = '' then
    BiasLayer := FRouteSignalLayer;
  if BiasLayer = '' then
    Exit;
  if Length(FPlanBandStarts) < 1 then
    Exit;

  BuildBiasRows(MaxUa, Rows);
  // Sort rows top-to-bottom, then pack branches onto trunks by current budget.
  for a := 1 to High(Rows) do
  begin
    TmpRow := Rows[a];
    b2 := a - 1;
    while (b2 >= 0) and (Rows[b2].Y > TmpRow.Y) do
    begin
      Rows[b2 + 1] := Rows[b2];
      Dec(b2);
    end;
    Rows[b2 + 1] := TmpRow;
  end;
  SetLength(Currents, Length(Rows));
  for a := 0 to High(Rows) do
    Currents[a] := Rows[a].CurrentUa;
  TrunkOf := PackBiasTrunks(Currents, TrunkLimit);
  MaxTrunk := 0;
  for a := 0 to High(TrunkOf) do
    if TrunkOf[a] > MaxTrunk then
      MaxTrunk := TrunkOf[a];

  Cells := TDictionary<Int64, TBiasCell>.Create;
  try
    for a := 0 to High(Rows) do
    begin
      Col := FPlanXLeft - 1 - TrunkOf[a];
      case Rows[a].Kind of
        brGroup: EmitGroupRow(Rows[a].GrpA, Rows[a].Y, Col);
        brMerged: EmitMergedRow(Rows[a].GrpA, Rows[a].GrpB, Rows[a].Y, Col);
        brClock: EmitClockRow(Rows[a].GrpA, Rows[a].TrackX, Rows[a].Y, Col);
      end;
    end;
    // One vertical trunk line per trunk, from the die top edge down to the
    // trunk's lowest row.
    for t := 0 to MaxTrunk do
    begin
      Col := FPlanXLeft - 1 - t;
      MaxY := 0;
      for a := 0 to High(Rows) do
        if (TrunkOf[a] = t) and (Rows[a].Y > MaxY) then
          MaxY := Rows[a].Y;
      WireV(Col, 0, MaxY, False);
    end;

    // Materialise the assembled network for the paint and the export scan.
    FBiasCells := nil;
    for B in Cells.Values do
    begin
      SetLength(FBiasCells, Length(FBiasCells) + 1);
      FBiasCells[High(FBiasCells)] := B;
    end;

    // Record how many powered cells this allocation covered: the final audit
    // re-counts them after validation (which may have inserted cells) and fails
    // if the two disagree.
    FBiasGatesSeen := 0;
    GateSeen := TDictionary<TGateInstance, Boolean>.Create;
    try
      for a := 0 to High(FPlacedComponents) do
        if (FPlacedComponents[a].Gate <> nil) and
           (FPlacedComponents[a].Gate.Cell <> nil) and
           (FPlacedComponents[a].Gate.Cell.PowerPorts.Count > 0) then
          GateSeen.AddOrSetValue(FPlacedComponents[a].Gate, True);
      // Clock-tree interiors only: the leaves ARE the clocked cells, already
      // counted from FPlacedComponents - and they are different gate objects
      // (the clock model is a clone), so identity dedupe would not merge them.
      for a := 0 to High(FClockSubtree) do
        for b2 := 0 to High(FClockSubtree[a]) do
          if (not FClockSubtree[a][b2].IsLeaf) and
             (FClockSubtree[a][b2].Gate <> nil) and
             (FClockSubtree[a][b2].Gate.Cell <> nil) and
             (FClockSubtree[a][b2].Gate.Cell.PowerPorts.Count > 0) then
            GateSeen.AddOrSetValue(FClockSubtree[a][b2].Gate, True);
      for a := 0 to High(FSpine) do
        if (FSpine[a].Gate <> nil) and (FSpine[a].Gate.Cell <> nil) and
           (FSpine[a].Gate.Cell.PowerPorts.Count > 0) then
          GateSeen.AddOrSetValue(FSpine[a].Gate, True);
      for a := 0 to High(FLengthBuffers) do
        if (FLengthBuffers[a].Gate <> nil) and
           (FLengthBuffers[a].Gate.Cell <> nil) and
           (FLengthBuffers[a].Gate.Cell.PowerPorts.Count > 0) then
          GateSeen.AddOrSetValue(FLengthBuffers[a].Gate, True);
      FBiasGatesSeen := GateSeen.Count;
      // Keep the gates themselves so the final audit can name any mismatch.
      FBiasGateSet.Free;
      FBiasGateSet := GateSeen;
      GateSeen := nil;
    finally
      GateSeen.Free;
    end;
  finally
    Cells.Free;
  end;

  RepaintRoutingPage;
end;


// Total routed length of one trace, in um: the sum of Manhattan distances
// between consecutive grid blocks, scaled by the core block size. Consecutive
// points are adjacent (or a via hop), so this is the wire's real length.
function TForm1.TraceLengthUm(const ATr: TRoutedTrace; Core: Double): Double;
var
  k: Integer;
begin
  Result := 0;
  for k := 0 to High(ATr.Points) - 1 do
    Result := Result + (Abs(ATr.Points[k + 1].X - ATr.Points[k].X) +
      Abs(ATr.Points[k + 1].Y - ATr.Points[k].Y)) * Core;
end;

// A bias trace is a constant-voltage distribution line (net name *'), not
// a PTL: it has no timing or propagation constraints, so it is excluded from
// the PTL validation (length limit, weighted scale, dashing).
function TForm1.IsBiasTrace(const ATr: TRoutedTrace): Boolean;
begin
  Result := UNetNaming.IsBiasNetName(ATr.NetName);
end;

// True if the traces still contain nets from a prior validation run (name carries
// '__vbuf_'); those belong to a discarded clone and the clean model must be re-routed.
function TForm1.HasValidationBufferTraces: Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FRouteTraces) do
    if Pos(UNetNaming.ValidationBufferMarker, FRouteTraces[i].NetName) > 0 then
      Exit(True);
  Result := False;
end;

// Total length of a raw grid-block polyline, in um (used while re-routing).
function TForm1.PathLengthUm(const Pts: TArray<TPoint>; Core: Double): Double;
var
  k: Integer;
begin
  Result := 0;
  for k := 0 to High(Pts) - 1 do
    Result := Result + (Abs(Pts[k + 1].X - Pts[k].X) +
      Abs(Pts[k + 1].Y - Pts[k].Y)) * Core;
end;

// Marks one trace's cells as obstacles on their layers (like RunRouting's
// BlockPath, but reusable). Layers holds layer NAMES.
// Index of a routing-layer name in FRouteLayers (the list that indexes
// FRouteObstacles). Using the UI list (FRoutingLayers) here is wrong: it also
// holds the bias layer and may be ordered differently, so a trace would block or
// unblock a different layer - which silently cleared pin pillars on re-routes.
function TForm1.RouteLayerIndex(const AName: string): Integer;
var
  k: Integer;
begin
  Result := -1;
  for k := 0 to High(FRouteLayers) do
    if SameText(FRouteLayers[k], AName) then
      Exit(k);
end;

procedure TForm1.BlockTrace(ATraceIdx: Integer);
var
  ii, L: Integer;
  Pt: TPoint;
begin
  for ii := 0 to High(FRouteTraces[ATraceIdx].Points) do
  begin
    Pt := FRouteTraces[ATraceIdx].Points[ii];
    if (Pt.X < 0) or (Pt.X >= FRouteObstaclesW) or
       (Pt.Y < 0) or (Pt.Y >= FRouteObstaclesH) then
      Continue;
    if ii <= High(FRouteTraces[ATraceIdx].Layers) then
    begin
      L := RouteLayerIndex(FRouteTraces[ATraceIdx].Layers[ii]);
      if (L >= 0) and (L <= High(FRouteObstacles)) then
        FRouteObstacles[L][Pt.Y * FRouteObstaclesW + Pt.X] := True;
    end;
  end;
end;

// Removes one trace's cells from the obstacle maps (the inverse of BlockTrace),
// freeing the space so a re-route can use it.
procedure TForm1.UnblockTrace(ATraceIdx: Integer);
var
  ii, L, La, Lb, Lk: Integer;
  Pt: TPoint;
begin
  for ii := 0 to High(FRouteTraces[ATraceIdx].Points) do
  begin
    Pt := FRouteTraces[ATraceIdx].Points[ii];
    if (Pt.X < 0) or (Pt.X >= FRouteObstaclesW) or
       (Pt.Y < 0) or (Pt.Y >= FRouteObstaclesH) then
      Continue;
    L := -1;
    if ii <= High(FRouteTraces[ATraceIdx].Layers) then
      L := RouteLayerIndex(FRouteTraces[ATraceIdx].Layers[ii]);
    if (L >= 0) and (L <= High(FRouteObstacles)) then
      FRouteObstacles[L][Pt.Y * FRouteObstaclesW + Pt.X] := False;
    // Mirror BlockPath: a via also obstructed the layers between its ends.
    if (ii > 0) and (ii - 1 <= High(FRouteTraces[ATraceIdx].Layers)) and
       (FRouteTraces[ATraceIdx].Points[ii - 1].X = Pt.X) and
       (FRouteTraces[ATraceIdx].Points[ii - 1].Y = Pt.Y) then
    begin
      La := RouteLayerIndex(FRouteTraces[ATraceIdx].Layers[ii - 1]);
      Lb := L;
      if La > Lb then
      begin
        Lk := La;
        La := Lb;
        Lb := Lk;
      end;
      for Lk := La to Lb do
        if (Lk >= 0) and (Lk <= High(FRouteObstacles)) then
          FRouteObstacles[Lk][Pt.Y * FRouteObstaclesW + Pt.X] := False;
    end;
  end;
end;

// Rips up one trace and re-routes it (layer passes then vias, shortest kept).
// Returns True if under the PTL limit; restores the original if nothing routes.
function TForm1.RerouteTrace(ATraceIdx: Integer): Boolean;
var
  Core, Limit, Len, BestLen: Double;
  Start, Goal: TPoint;
  L, i: Integer;
  Path, BestPath: TArray<TPoint>;
  Layers, BestLayers: TArray<Integer>;
  FoundAny: Boolean;
  SM, GM: UInt64;
begin
  Result := False;
  if (ATraceIdx < 0) or (ATraceIdx > High(FRouteTraces)) then
    Exit;
  if Length(FRouteTraces[ATraceIdx].Points) < 2 then
    Exit;
  Core := FDesignConfig.CoreUm;
  if Core <= 0 then
    Core := FPlanCore;
  Limit := FDesignConfig.MaxPtlLengthUm;
  if Limit <= 0 then
    Exit;
  Start := FRouteTraces[ATraceIdx].Points[0];
  Goal := FRouteTraces[ATraceIdx].Points[High(FRouteTraces[ATraceIdx].Points)];
  // Same per-pin layer restriction the original route was made under.
  SM := FRouteTraces[ATraceIdx].StartMask;
  GM := FRouteTraces[ATraceIdx].GoalMask;
  if SM = 0 then
    SM := High(UInt64);
  if GM = 0 then
    GM := High(UInt64);
  UnblockTrace(ATraceIdx); // free the current wire's space for the search
  FoundAny := False;
  BestLen := MaxDouble;
  BestPath := nil;
  BestLayers := nil;
  for L := 0 to High(FRouteLayers) do
    if LeeRoute(Start, Goal, L, SM, GM, Path, Layers) then
    begin
      FoundAny := True;
      Len := PathLengthUm(Path, Core);
      if Len < BestLen then
      begin
        BestLen := Len;
        BestPath := Path;
        BestLayers := Layers;
      end;
    end;
  if LeeRoute(Start, Goal, -1, SM, GM, Path, Layers) then
  begin
    FoundAny := True;
    Len := PathLengthUm(Path, Core);
    if Len < BestLen then
    begin
      BestLen := Len;
      BestPath := Path;
      BestLayers := Layers;
    end;
  end;
  if FoundAny then
  begin
    FRouteTraces[ATraceIdx].Points := BestPath;
    SetLength(FRouteTraces[ATraceIdx].Layers, Length(BestLayers));
    for i := 0 to High(BestLayers) do
      FRouteTraces[ATraceIdx].Layers[i] := FRouteLayers[BestLayers[i]];
    BlockTrace(ATraceIdx);
    Result := BestLen <= Limit;
  end
  else
    BlockTrace(ATraceIdx); // nothing routed: put the original wire back
end;

// The buffer type to use for length-breaking: the user's buffer list, choosing
// the cell with the smallest propagation delay.
function TForm1.FindMinDelayBufferCell: TCell;
var
  i: Integer;
  Cell, Best, First: TCell;
  Delay, BestDelay: Double;
begin
  Result := nil;
  Best := nil;
  First := nil;
  BestDelay := MaxDouble;
  if FLib = nil then
    Exit;
  for i := 0 to FBufferNames.Count - 1 do
  begin
    Cell := FLib.FindCell(FBufferNames[i]);
    if Cell = nil then
      Continue;
    if First = nil then
      First := Cell;
    Delay := CellDelayPs(Cell);
    if (Delay >= 0) and (Delay < BestDelay) then
    begin
      BestDelay := Delay;
      Best := Cell;
    end;
  end;
  if Best = nil then
    Best := First;
  Result := Best;
end;

// The buffer type to use for clock-trunk balancing: the user's buffer list,
// choosing the cell with the LARGEST propagation delay, matching the clock
// network's seeded stage-buffer choice.
function TForm1.FindMaxDelayBufferCell: TCell;
var
  i: Integer;
  Cell, Best, First: TCell;
  Delay, BestDelay: Double;
begin
  Result := nil;
  Best := nil;
  First := nil;
  BestDelay := -1;
  if FLib = nil then
    Exit;
  for i := 0 to FBufferNames.Count - 1 do
  begin
    Cell := FLib.FindCell(FBufferNames[i]);
    if Cell = nil then
      Continue;
    if First = nil then
      First := Cell;
    Delay := CellDelayPs(Cell);
    if (Delay >= 0) and (Delay > BestDelay) then
    begin
      BestDelay := Delay;
      Best := Cell;
    end;
  end;
  if Best = nil then
    Best := First;
  Result := Best;
end;

// True when a W x H buffer at (X, Y) would touch a placed cell, a clock-tree
// interior node, a trunk cell or another length buffer. One clear block is
// required on each side (X - 1 .. X + W), which is the gap the row packer and
// the clock-row spreader already leave between cells, so a slot flush against a
// cell is rejected instead of accepted. SkipGate excludes the buffer being
// placed from its own test. Pads sit outside the rows and are not tested.
function TForm1.BufferSlotBlocked(X, Y, W, H: Integer;
  SkipGate: TGateInstance = nil): Boolean;
var
  i, L, ci: Integer;
  MPt: TPoint;
begin
  Result := True;
  if (W < 1) or (H < 1) then
    Exit;
  for i := 0 to High(FPlacedComponents) do
    if (FPlacedComponents[i].Gate <> SkipGate) and
       UGeometry.RectOverlap(X - 1, Y, W + 2, H, FPlacedComponents[i].X,
         FPlacedComponents[i].Y, FPlacedComponents[i].W,
         FPlacedComponents[i].H) then
      Exit;
  for L := 0 to High(FClockSubtree) do
    for ci := 0 to High(FClockSubtree[L]) do
      if (not FClockSubtree[L][ci].IsLeaf) and
         (FClockSubtree[L][ci].Gate <> SkipGate) and
         UGeometry.RectOverlap(X - 1, Y, W + 2, H, FClockSubtree[L][ci].X,
           FClockSubtree[L][ci].Y, FClockSubtree[L][ci].W,
           FClockSubtree[L][ci].H) then
        Exit;
  for i := 0 to High(FSpine) do
    if (FSpine[i].Gate <> SkipGate) and
       UGeometry.RectOverlap(X - 1, Y, W + 2, H, FSpine[i].X, FSpine[i].Y,
         FSpine[i].W, FSpine[i].H) then
      Exit;
  for i := 0 to High(FLengthBuffers) do
    if (FLengthBuffers[i].Gate <> nil) and
       (FLengthBuffers[i].Gate <> SkipGate) and
       FGatePlacement.TryGetValue(FLengthBuffers[i].Gate, MPt) and
       UGeometry.RectOverlap(X - 1, Y, W + 2, H, MPt.X, MPt.Y,
         FLengthBuffers[i].W, FLengthBuffers[i].H) then
      Exit;
  Result := False;
end;

// Nearest free slot for a buffer of footprint W x H: the wanted X first, then
// alternately right/left along the same row, then the band's other row, then the
// nearest bands. Returns False when no row of any band can hold it.
function TForm1.FindBufferSlot(WantBand, WantRowType, WantX, W, H: Integer;
  out ABand, ARowType, AX, AY: Integer): Boolean;
var
  NumBands, band, X, Y: Integer;
  Step, Dir: Integer;

  function RowFits(ABand, ARow: Integer; out FX, FY: Integer): Boolean;
  var
    RowY, StartX, K, Off: Integer;
  begin
    Result := False;
    if ARow = 1 then
      RowY := BandClockRowY(ABand)
    else
      RowY := BandLogicRowY(ABand);
    FY := RowY + ((FPlanRowHBlocks - H) div 2);
    StartX := WantX;
    if StartX > FPlanXRight - W then
      StartX := FPlanXRight - W;
    if StartX < FPlanXLeft then
      StartX := FPlanXLeft;
    for K := 0 to FPlanXRight - FPlanXLeft do
    begin
      if K = 0 then
        Off := 0
      else if Odd(K) then
        Off := (K + 1) div 2
      else
        Off := -(K div 2);
      FX := StartX + Off;
      if (FX < FPlanXLeft) or (FX > FPlanXRight - W) then
        Continue;
      if not BufferSlotBlocked(FX, FY, W, H) then
        Exit(True);
    end;
  end;

begin
  Result := False;
  ABand := -1;
  ARowType := -1;
  AX := -1;
  AY := -1;
  NumBands := Length(FPlanBandStarts);
  if (NumBands = 0) or (W < 1) or (H < 1) or (H > FPlanRowHBlocks) or
     (W > FPlanXRight - FPlanXLeft) then
    Exit;
  if WantBand < 0 then
    WantBand := 0;
  if WantBand > NumBands - 1 then
    WantBand := NumBands - 1;
  if (WantRowType <> 0) and (WantRowType <> 1) then
    WantRowType := 1;
  for Step := 0 to NumBands - 1 do
    for Dir := 0 to 1 do
    begin
      if Step = 0 then
      begin
        if Dir <> 0 then
          Continue;
        band := WantBand;
      end
      else if Dir = 0 then
        band := WantBand - Step
      else
        band := WantBand + Step;
      if (band < 0) or (band > NumBands - 1) then
        Continue;
      // The wanted row type first, then the band's other row.
      if RowFits(band, WantRowType, X, Y) then
      begin
        ABand := band;
        ARowType := WantRowType;
        AX := X;
        AY := Y;
        Exit(True);
      end;
      if RowFits(band, 1 - WantRowType, X, Y) then
      begin
        ABand := band;
        ARowType := 1 - WantRowType;
        AX := X;
        AY := Y;
        Exit(True);
      end;
    end;
end;

// Re-applies each validation buffer's slot after a floorplan rebuild: signal
// buffers rejoin FPlacedComponents, clock buffers move within FClockSubtree.
procedure TForm1.ReapplyValidationBuffers;
var
  i, i2, W, H, Y, X: Integer;
  NB, NR, NX, NY: Integer;
  VB: TValidationBuffer;
  P: TPlacedComponent;
  L, ci: Integer;
  Found: Boolean;
begin
  if Length(FPlanBandStarts) = 0 then
    Exit;
  for i := 0 to High(FValidationBuffers) do
  begin
    VB := FValidationBuffers[i];
    if (VB.Gate = nil) or (VB.Gate.Cell = nil) then
      Continue;
    W := Round(VB.Gate.Cell.Width / FPlanCore);
    if W < 1 then
      W := 1;
    H := Round(VB.Gate.Cell.Height / FPlanCore);
    if H < 1 then
      H := 1;
    if VB.RowType = 0 then
      Y := BandLogicRowY(VB.Band) + ((FPlanRowHBlocks - H) div 2)
    else if VB.RowType = 1 then
      Y := BandClockRowY(VB.Band) + ((FPlanRowHBlocks - H) div 2)
    else
      Y := VB.Y;
    X := VB.X;
    if VB.RowType = 2 then
    begin
      // Clock trunk column: recompute the current trunk position and clamp X/Y
      // to the trunk's column / the full stack.
      if X < FPlanXRight + FPlanLane0W then
        X := FPlanXRight + FPlanLane0W;
      if X + W > FPlanXRight + FPlanLane0W + FPlanRowHBlocks then
        X := FPlanXRight + FPlanLane0W + FPlanRowHBlocks - W;
      if Length(FPlanBandStarts) > 0 then
      begin
        if Y < FPlanBandStarts[0] then
          Y := FPlanBandStarts[0];
        if Y + H > FPlanBandStarts[High(FPlanBandStarts)] +
           FPlanBandHeight[High(FPlanBandStarts)] + FBottomBiasH then
          Y := FPlanBandStarts[High(FPlanBandStarts)] +
            FPlanBandHeight[High(FPlanBandStarts)] + FBottomBiasH - H;
      end;
    end
    else
    begin
      if X < FPlanXLeft then
        X := FPlanXLeft;
      if X + W > FPlanXRight then
        X := FPlanXRight - W;
      if X < FPlanXLeft then
        X := FPlanXLeft;
    end;
    // The stored slot is advisory: bias expansion can grow a lane and narrow the
    // rows after it was chosen. If it is no longer clear (one-block gap), move
    // the buffer to the nearest free slot and keep that new slot from now on.
    if ((VB.RowType = 0) or (VB.RowType = 1)) and
       BufferSlotBlocked(X, Y, W, H, VB.Gate) then
      if FindBufferSlot(VB.Band, VB.RowType, X, W, H, NB, NR, NX, NY) then
      begin
        MemoRouting.Lines.Add(Format(
          '  buffer %s moved to band %d row %d x %d y %d (its slot was occupied).',
          [VB.Gate.CellName, NB, NR, NX, NY]));
        X := NX;
        Y := NY;
        VB.Band := NB;
        VB.RowType := NR;
      end
      else
        MemoRouting.Lines.Add(Format(
          '  buffer %s has no clear slot; left at band %d row %d x %d y %d.',
          [VB.Gate.CellName, VB.Band, VB.RowType, X, Y]));
    VB.X := X;
    VB.Y := Y;
    FValidationBuffers[i] := VB;

    if VB.IsClock then
    begin
      for L := 0 to High(FClockSubtree) do
        for ci := 0 to High(FClockSubtree[L]) do
          if FClockSubtree[L][ci].Gate = VB.Gate then
          begin
            // A slotless clock buffer (RowType < 0) keeps the position the
            // clock-tree builder gave it; only slotted ones are re-applied.
            if VB.RowType >= 0 then
            begin
              FClockSubtree[L][ci].X := X;
              FClockSubtree[L][ci].Y := Y;
            end;
            FGatePlacement.AddOrSetValue(VB.Gate,
              TPoint.Create(FClockSubtree[L][ci].X, FClockSubtree[L][ci].Y));
            Break;
          end;
    end
    else
    begin
      Found := False;
      for i2 := 0 to High(FPlacedComponents) do
        if FPlacedComponents[i2].Gate = VB.Gate then
        begin
          FPlacedComponents[i2].X := X;
          FPlacedComponents[i2].Y := Y;
          Found := True;
          Break;
        end;
      if not Found then
      begin
        P.Gate := VB.Gate;
        P.InstanceName := Format('%s_vb%d', [VB.Gate.CellName, i + 1]);
        P.CellName := VB.Gate.CellName;
        P.ClockLevel := -1;
        P.X := X;
        P.Y := Y;
        P.W := W;
        P.H := H;
        SetLength(FPlacedComponents, Length(FPlacedComponents) + 1);
        FPlacedComponents[High(FPlacedComponents)] := P;
      end;
      FGatePlacement.AddOrSetValue(VB.Gate, TPoint.Create(X, Y));
    end;
  end;
end;

// Re-runs the bias expansion then routing after an insertion, re-applying the
// buffers first and preserving the validation log across RunRouting's memo clear.
// Sanity check after the placements are rebuilt: every validation buffer must
// be owned by exactly one placer - FSpine (trunk), FClockSubtree (clock row
// tree) or FPlacedComponents (logic row). Silent when all is well.
procedure TForm1.CheckValidationBufferOwnership;
var
  i, k, L, ci, Owners: Integer;
  VB: TValidationBuffer;
  Where: string;
begin
  for i := 0 to High(FValidationBuffers) do
  begin
    VB := FValidationBuffers[i];
    if VB.Gate = nil then
      Continue;
    Owners := 0;
    Where := '';
    for k := 0 to High(FSpine) do
      if FSpine[k].Gate = VB.Gate then
      begin
        Inc(Owners);
        Where := Where + ' spine';
        Break;
      end;
    for L := 0 to High(FClockSubtree) do
    begin
      for ci := 0 to High(FClockSubtree[L]) do
        if FClockSubtree[L][ci].Gate = VB.Gate then
        begin
          Inc(Owners);
          Where := Where + ' tree[' + IntToStr(L) + ']';
          Break;
        end;
    end;
    for k := 0 to High(FPlacedComponents) do
      if FPlacedComponents[k].Gate = VB.Gate then
      begin
        Inc(Owners);
        Where := Where + ' row';
        Break;
      end;
    if Owners <> 1 then
      MemoRouting.Lines.Add(Format(
        '  WARNING: validation buffer %s on %s has %d placements:%s',
        [VB.Gate.CellName, VB.NetName, Owners, Where]));
  end;
end;

procedure TForm1.ReapplyLengthBufferMask;
var
  i, X, Y, RowType, NB, NR, NX, NY: Integer;
begin
  if Length(FPlanBandStarts) = 0 then
    Exit;
  for i := 0 to High(FLengthBuffers) do
  begin
    if FLengthBuffers[i].Gate = nil then
      Continue;
    X := FPlanXLeft + FLengthBuffers[i].XOffset;
    if X + FLengthBuffers[i].W > FPlanXRight then
      X := FPlanXRight - FLengthBuffers[i].W;
    if X < FPlanXLeft then
      X := FPlanXLeft;
    if FLengthBuffers[i].OnClockRow then
    begin
      RowType := 1;
      Y := BandClockRowY(FLengthBuffers[i].Band);
    end
    else
    begin
      RowType := 0;
      Y := BandLogicRowY(FLengthBuffers[i].Band);
    end;
    Y := Y + ((FPlanRowHBlocks - FLengthBuffers[i].H) div 2);
    // The band/offset pair is only a hint after a rebuild: bias expansion can
    // grow a lane and narrow the rows, and the buffer mask layer is not part of
    // the rows' own packing. Re-test the stored slot with the same one-block
    // clearance the packer uses, and relocate (persisting the new slot) if the
    // layout moved under it.
    if BufferSlotBlocked(X, Y, FLengthBuffers[i].W, FLengthBuffers[i].H,
      FLengthBuffers[i].Gate) then
      if FindBufferSlot(FLengthBuffers[i].Band, RowType, X,
        FLengthBuffers[i].W, FLengthBuffers[i].H, NB, NR, NX, NY) then
      begin
        MemoRouting.Lines.Add(Format(
          '  length buffer %s moved to band %d row %d x %d y %d (its slot was occupied).',
          [FLengthBuffers[i].Gate.CellName, NB, NR, NX, NY]));
        X := NX;
        Y := NY;
        FLengthBuffers[i].Band := NB;
        FLengthBuffers[i].OnClockRow := NR = 1;
        FLengthBuffers[i].XOffset := X - FPlanXLeft;
      end
      else
        MemoRouting.Lines.Add(Format(
          '  length buffer %s has no clear slot; left at band %d x %d y %d.',
          [FLengthBuffers[i].Gate.CellName, FLengthBuffers[i].Band, X, Y]));
    FGatePlacement.AddOrSetValue(FLengthBuffers[i].Gate, TPoint.Create(X, Y));
  end;
end;

function TForm1.IsLengthMaskGate(G: TGateInstance): Boolean;
var
  i: Integer;
begin
  Result := False;
  if G = nil then
    Exit;
  for i := 0 to High(FLengthBuffers) do
    if FLengthBuffers[i].Gate = G then
      Exit(True);
end;

procedure TForm1.RemoveLengthBuffers;
var
  i, k: Integer;
  Model: TBlifModel;
  Gate: TGateInstance;
  Conn: TPinConnection;
  InNet, OutNet, OldNet, NewNet: string;
  OldTgt, NewSrc: TNet;
  NC: TNetConnection;
begin
  for i := High(FLengthBuffers) downto 0 do
  begin
    Gate := FLengthBuffers[i].Gate;
    if Gate = nil then
      Continue;
    if FLengthBuffers[i].IsClock then
      Model := FClockBufferedModel
    else
      Model := FPlacementModel;
    if (Model = nil) or (Model.Gates.IndexOf(Gate) < 0) then
      Continue;
    InNet := '';
    OutNet := '';
    for Conn in Gate.Connections do
      if (Conn.Port <> nil) and (Conn.Port.Direction = pdOutput) then
        OutNet := Conn.NetName
      else if (Conn.Port <> nil) and (Conn.Port.Direction = pdInput) then
        InNet := Conn.NetName;
    if SameText(InNet, FLengthBuffers[i].NetName) then
    begin
      OldNet := InNet;
      NewNet := OutNet;
    end
    else
    begin
      OldNet := OutNet;
      NewNet := InNet;
    end;
    OldTgt := nil;
    NewSrc := nil;
    Model.Nets.TryGetValue(OldNet, OldTgt);
    Model.Nets.TryGetValue(NewNet, NewSrc);
    if (OldTgt = nil) or (NewSrc = nil) then
      Continue;
    for k := NewSrc.Connections.Count - 1 downto 0 do
    begin
      NC := NewSrc.Connections[k];
      NewSrc.Connections.Delete(k);
      if NC.Gate = Gate then
        Continue;
      for Conn in NC.Gate.Connections do
        if SameText(Conn.PinName, NC.PinName) and
           SameText(Conn.NetName, NewNet) then
        begin
          Conn.NetName := OldNet;
          Break;
        end;
      OldTgt.Connections.Add(NC);
    end;
    for k := OldTgt.Connections.Count - 1 downto 0 do
      if OldTgt.Connections[k].Gate = Gate then
        OldTgt.Connections.Delete(k);
    Model.Nets.Remove(NewNet);
    Model.Gates.Remove(Gate); // owns objects: frees Gate
    FLengthBuffers[i].Gate := nil;
  end;
  FLengthBuffers := nil;
end;

// Removes the clock buffers that validation inserted into the persistent
// buffered clock model, merging each split net back together. Signal buffers
// live on the throwaway placement clone and go with it; the clock model is
// shared with placement/export, so going back must undo them explicitly.
procedure TForm1.RemoveClockValidationBuffers;
var
  i, k: Integer;
  VB: TValidationBuffer;
  Gate: TGateInstance;
  Conn: TPinConnection;
  InNet, OutNet, OldNet, NewNet: string;
  OldTgt, NewSrc: TNet;
  NC: TNetConnection;
begin
  if FClockBufferedModel = nil then
    Exit;
  for i := High(FValidationBuffers) downto 0 do
  begin
    VB := FValidationBuffers[i];
    if (not VB.IsClock) or (VB.Gate = nil) then
      Continue;
    Gate := VB.Gate;
    if FClockBufferedModel.Gates.IndexOf(Gate) < 0 then
      Continue;
    InNet := '';
    OutNet := '';
    for Conn in Gate.Connections do
      if (Conn.Port <> nil) and (Conn.Port.Direction = pdOutput) then
        OutNet := Conn.NetName
      else if (Conn.Port <> nil) and (Conn.Port.Direction = pdInput) then
        InNet := Conn.NetName;
    // The side that is not the recorded original net is the fresh one.
    if SameText(InNet, VB.NetName) then
    begin
      OldNet := InNet;
      NewNet := OutNet;
    end
    else
    begin
      OldNet := OutNet;
      NewNet := InNet;
    end;
    OldTgt := nil;
    NewSrc := nil;
    FClockBufferedModel.Nets.TryGetValue(OldNet, OldTgt);
    FClockBufferedModel.Nets.TryGetValue(NewNet, NewSrc);
    if (OldTgt = nil) or (NewSrc = nil) then
      Continue;
    // Move the fresh net's non-buffer connections back onto the original net.
    for k := NewSrc.Connections.Count - 1 downto 0 do
    begin
      NC := NewSrc.Connections[k];
      NewSrc.Connections.Delete(k);
      if NC.Gate = Gate then
        Continue;
      for Conn in NC.Gate.Connections do
        if SameText(Conn.PinName, NC.PinName) and
           SameText(Conn.NetName, NewNet) then
        begin
          Conn.NetName := OldNet;
          Break;
        end;
      OldTgt.Connections.Add(NC);
    end;
    // Drop the buffer's own connection from the surviving net before freeing.
    for k := OldTgt.Connections.Count - 1 downto 0 do
      if OldTgt.Connections[k].Gate = Gate then
        OldTgt.Connections.Delete(k);
    FClockBufferedModel.Nets.Remove(NewNet);
    FClockBufferedModel.Gates.Remove(Gate); // owns objects: frees Gate
  end;
end;

function TForm1.RunBiasExpansionAndRouting: Boolean;
var
  Saved, Report: TStringList;
begin
  Result := False;
  // The floorplan skips the validation buffers (their ClockLevel is -1), so they
  // are placed only here. Place them BEFORE the expansion so its row/trunk sizing
  // sees them (otherwise the bias rows under-size and the router overflows into
  // neighbouring rows), then again AFTER - the expansion's rebuild drops them.
  ReapplyValidationBuffers;
  ButtonExpandBiasClick(nil);
  if FBiasExpansionFailed then
  begin
    // The detailed reason (which band/trunk/lane ran out of room) is already in
    // the memo from ReportBiasError; make the consequence and the way out clear.
    MemoRouting.Lines.Add('[bias] routing skipped: the bias lines do not fit the ' +
      'die. Raise the die height or width (or lower the bias current) on the ' +
      'Placement page, expand the bias lines again, then re-run routing.');
    Exit;
  end;
  // ButtonExpandBiasClick only rebuilds the floorplan when the bias rows need
  // to grow, so FSpine/FClockSubtree may still predate a just-inserted trunk
  // buffer. Re-derive the clock placements unconditionally: routing only makes
  // a clock link when both endpoints are in FSpine/FClockSubtree, so a stale
  // spine means the buffer is silently not routed.
  BuildClockSubtreePlacements;
  BuildSpinePlacement;
  ReapplyValidationBuffers;
  // Each validation buffer must be owned by exactly one placer; log any that
  // are placed nowhere (unroutable pins) or twice (drawn in two places).
  CheckValidationBufferOwnership;
  ReapplyLengthBufferMask;
  Saved := TStringList.Create;
  Report := TStringList.Create;
  try
    Saved.Assign(MemoRouting.Lines);
    RunRouting;
    Report.Assign(MemoRouting.Lines);
    MemoRouting.Lines.Assign(Saved);
    MemoRouting.Lines.AddStrings(Report);
  finally
    Saved.Free;
    Report.Free;
  end;
  // Bias lines after the main routing (RunRouting clears FRouteTraces, so the
  // bias traces must be appended afterwards, as in ButtonRunRoutingClick).
  RouteBiasLines;
  Result := True;
end;

// Splits NetName at LoadPin with a min-delay buffer at the given slot and re-runs
// the expansion + routing; reverts the netlist and returns False if it won't route.
function TForm1.TryInsertBuffer(IsClock: Boolean; const NetName: string;
  Driver, Load: TGateInstance; const DriverPin, LoadPin: string;
  APadLoad, AIsLengthFix: Boolean;
  BufCell: TCell; const InPin, OutPin: string;
  ABand, ARowType, AX, AY: Integer): Boolean;
var
  Model: TBlifModel;
  Net: TNet;
  OrigConn: TList<TNetConnection>;
  NewNetName: string;
  NewNet: TNet;
  NC: TNetConnection;
  BufGate: TGateInstance;
  Conn: TPinConnection;
  VB: TValidationBuffer;
  InPort, OutPort: TPort;
  InNetName, OutNetName: string;
  BiasFailed: Boolean;

  // Keep the gate-side pin connection in step with the net-side move: the
  // split below creates new TNetConnections, but the gate's own TPinConnection
  // still names the old net until this runs. Callers (BuildSpinePlacement,
  // the CIR export) read the gate side.
  procedure Repoint(AGate: TGateInstance; const APin, AFrom, ATo: string);
  var
    C: TPinConnection;
  begin
    if AGate = nil then
      Exit;
    for C in AGate.Connections do
      if SameText(C.PinName, APin) and SameText(C.NetName, AFrom) then
      begin
        C.NetName := ATo;
        Exit;
      end;
  end;

begin
  Result := False;
  if IsClock then
  begin
    Model := FClockBufferedModel;
    if Model = nil then
      Model := FClockModel;
  end
  else
    Model := FPlacementModel;
  if (Model = nil) or (BufCell = nil) then
    Exit;
  // A pad-terminated (output) net has no gate load; only normal nets need one.
  if (not APadLoad) and (Load = nil) then
    Exit;
  if not Model.Nets.TryGetValue(NetName, Net) then
    Exit;
  OrigConn := TList<TNetConnection>.Create;
  try
    OrigConn.AddRange(Net.Connections);

    // Build the buffer gate and split the net around it (see the pad/normal
    // branches below for which side keeps the original net name).
    BufGate := TGateInstance.Create;
    BufGate.CellName := BufCell.Name;
    BufGate.Cell := BufCell;
    BufGate.ClockLevel := -1;
    InPort := BufCell.FindPort(InPin);
    OutPort := BufCell.FindPort(OutPin);
    // A net name unique in the model (buffers from earlier validation runs may
    // already occupy some suffixes).
    repeat
      NewNetName := UNetNaming.ValidationBufNetName(NetName, FValidationBufIdx);
      Inc(FValidationBufIdx);
    until not Model.Nets.ContainsKey(NewNetName);

    // Which side keeps NetName: the input for a normal net, the output for a pad
    // load (the pad is keyed to the original name); the other moves to a fresh net.
    if APadLoad then
    begin
      InNetName := NewNetName;
      OutNetName := NetName;
    end
    else
    begin
      InNetName := NetName;
      OutNetName := NewNetName;
    end;

    Net.Connections.Clear;
    if APadLoad then
    begin
      // Output net: the buffer's OUTPUT drives the original (pad) net; the
      // original driver gate moves onto the fresh net with the buffer's input.
      for NC in OrigConn do
        if not ((NC.Gate = Driver) and (NC.PinName = DriverPin)) then
          Net.Connections.Add(NC);
      NC.Gate := BufGate;
      NC.PinName := OutPin;
      NC.IsDriver := True;
      Net.Connections.Add(NC);
      NewNet := Model.FindOrCreateNet(NewNetName);
      NC.Gate := Driver;
      NC.PinName := DriverPin;
      NC.IsDriver := True;
      NewNet.Connections.Add(NC);
      NC.Gate := BufGate;
      NC.PinName := InPin;
      NC.IsDriver := False;
      NewNet.Connections.Add(NC);
    end
    else
    begin
      // Normal net: the buffer's input joins the original net, its output
      // drives a fresh net to the original load.
      for NC in OrigConn do
        if not ((NC.Gate = Load) and (NC.PinName = LoadPin)) then
          Net.Connections.Add(NC);
      NC.Gate := BufGate;
      NC.PinName := InPin;
      NC.IsDriver := False;
      Net.Connections.Add(NC);
      NewNet := Model.FindOrCreateNet(NewNetName);
      NC.Gate := BufGate;
      NC.PinName := OutPin;
      NC.IsDriver := True;
      NewNet.Connections.Add(NC);
      NC.Gate := Load;
      NC.PinName := LoadPin;
      NC.IsDriver := False;
      NewNet.Connections.Add(NC);
    end;

    // The endpoint that moved to the fresh net must be repointed on its gate.
    if APadLoad then
      Repoint(Driver, DriverPin, NetName, NewNetName)
    else
      Repoint(Load, LoadPin, NetName, NewNetName);

    Conn := TPinConnection.Create;
    Conn.PinName := InPin;
    Conn.NetName := InNetName;
    Conn.Port := InPort;
    BufGate.Connections.Add(Conn);
    Conn := TPinConnection.Create;
    Conn.PinName := OutPin;
    Conn.NetName := OutNetName;
    Conn.Port := OutPort;
    BufGate.Connections.Add(Conn);
    Model.Gates.Add(BufGate);

    if AIsLengthFix then
    begin
      // Mask layer: its own placement record, never in FValidationBuffers.
      SetLength(FLengthBuffers, Length(FLengthBuffers) + 1);
      FLengthBuffers[High(FLengthBuffers)].Gate := BufGate;
      FLengthBuffers[High(FLengthBuffers)].NetName := NetName;
      FLengthBuffers[High(FLengthBuffers)].IsClock := IsClock;
      FLengthBuffers[High(FLengthBuffers)].Band := ABand;
      FLengthBuffers[High(FLengthBuffers)].OnClockRow := ARowType = 1;
      FLengthBuffers[High(FLengthBuffers)].XOffset := AX - FPlanXLeft;
      FLengthBuffers[High(FLengthBuffers)].W := Round(BufCell.Width / FPlanCore);
      if FLengthBuffers[High(FLengthBuffers)].W < 1 then
        FLengthBuffers[High(FLengthBuffers)].W := 1;
      FLengthBuffers[High(FLengthBuffers)].H := Round(BufCell.Height / FPlanCore);
      if FLengthBuffers[High(FLengthBuffers)].H < 1 then
        FLengthBuffers[High(FLengthBuffers)].H := 1;
    end
    else
    begin
      // Record the slot so ReapplyValidationBuffers keeps it across rebuilds.
      VB.Gate := BufGate;
      VB.NetName := NetName;
      VB.IsClock := IsClock;
      VB.Band := ABand;
      VB.RowType := ARowType;
      VB.X := AX;
      VB.Y := AY;
      SetLength(FValidationBuffers, Length(FValidationBuffers) + 1);
      FValidationBuffers[High(FValidationBuffers)] := VB;
    end;

    if RunBiasExpansionAndRouting and (FFlowStage >= fsRouted) then
    begin
      MemoRouting.Lines.Add(Format(
        '  buffer %s inserted on %s (band %d, row %d, x %d, y %d).',
        [BufCell.Name, NetName, ABand, ARowType, AX, AY]));
      Result := True;
      Exit;
    end;

    // If the expansion itself failed, every other slot will fail the same way
    // (the rows cannot grow), so report once and let the caller stop.
    BiasFailed := FBiasExpansionFailed;
    // The circuit no longer routes with the buffer there: revert the netlist.
    if APadLoad then
      Repoint(Driver, DriverPin, NewNetName, NetName)
    else
      Repoint(Load, LoadPin, NewNetName, NetName);
    Model.Gates.Remove(BufGate); // owns objects: frees BufGate
    Model.Nets.Remove(NewNetName);
    Net.Connections.Clear;
    Net.Connections.AddRange(OrigConn);
    if AIsLengthFix then
      SetLength(FLengthBuffers, Length(FLengthBuffers) - 1)
    else
      SetLength(FValidationBuffers, Length(FValidationBuffers) - 1);
    if BiasFailed then
      // Nothing to restore to: the expansion failed, so re-running it would only
      // fail again. The caller reports and stops; the failure flag stays latched
      // so the next routing click explains what to fix.
      MemoRouting.Lines.Add('  bias expansion failed; the buffer cannot be placed.')
    else
      RunBiasExpansionAndRouting; // restore the clean derived state
  finally
    OrigConn.Free;
  end;
end;

// Inserts a buffer to break the over-limit trace at ATraceIdx: resolves its net,
// driver and load, then tries every free logic/clock/trunk slot in score order.
function TForm1.InsertBufferForTrace(ATraceIdx: Integer): Boolean;
type
  TCand = record
    Band, RowType, X, Y: Integer;
    Score: Double;
  end;
var
  Core, Limit, R1u, R2u, MaxR, MinR, Score, CurLen, Cap: Double;
  UseBalanced: Boolean;
  NetName: string;
  IsClock: Boolean;
  TreeModel: TBlifModel;
  Net: TNet;
  NC: TNetConnection;
  Driver, Load: TGateInstance;
  DriverPin, LoadPin: string;
  IsPadLoad: Boolean;
  BufCell: TCell;
  InPort, OutPort: TPort;
  InPin, OutPin: string;
  Src, Dst, Pt, GatePos: TPoint;
  ClkPos: TDictionary<TGateInstance, TPoint>;
  ClkRot: TDictionary<TGateInstance, Boolean>;
  Sp: TSpineComponent;
  Node: TPlacedClockNode;
  L, ci, k: Integer;
  NumBands, Band, RowType, X, W, H, Bx, By: Integer;
  Cands: TArray<TCand>;
  C, TmpC: TCand;
  a, b: Integer;
  Key: string;

  // Evaluates slot (X, Y) for the current (Band, RowType): rejects a slot that
  // touches a placed cell, clock node, trunk cell or length buffer (routed wires
  // are ignored - all is re-routed), else records it.
  procedure Consider(X, Y: Integer);
  begin
    Bx := X + W div 2;
    By := Y + H div 2;
    R1u := (Abs(Src.X - Bx) + Abs(Src.Y - By)) * Core;
    R2u := (Abs(Bx - Dst.X) + Abs(By - Dst.Y)) * Core;
    if R1u > R2u then
    begin
      MaxR := R1u;
      MinR := R2u;
    end
    else
    begin
      MaxR := R2u;
      MinR := R1u;
    end;
    if MinR <= 0 then
      Exit;
    // Dual-mode scoring: one buffer needed -> balance the two residuals;
    // several -> pack to the max-reach target so the count stays near optimal.
    if UseBalanced then
      Score := -(MaxR * 10.0 + (R1u + R2u))
    else
      Score := Cap - Abs(MinR - Cap);
    Key := Format('%d:%d:%d:%d', [Band, RowType, X, Y]);
    if FValidationBlocked.IndexOf(Key) >= 0 then
      Exit;
    // Cells, clock nodes, trunk cells and other length buffers, with the usual
    // one-block clearance - a slot flush against a cell is not a slot.
    if BufferSlotBlocked(X, Y, W, H) then
      Exit;
    SetLength(Cands, Length(Cands) + 1);
    Cands[High(Cands)].Band := Band;
    Cands[High(Cands)].RowType := RowType;
    Cands[High(Cands)].X := X;
    Cands[High(Cands)].Y := Y;
    Cands[High(Cands)].Score := Score;
  end;

begin
  Result := False;
  if (ATraceIdx < 0) or (ATraceIdx > High(FRouteTraces)) then
    Exit;
  if Length(FRouteTraces[ATraceIdx].Points) < 2 then
    Exit;
  Core := FDesignConfig.CoreUm;
  if Core <= 0 then
    Core := FPlanCore;
  Limit := FDesignConfig.MaxPtlLengthUm;
  if Limit <= 0 then
    Exit;

  // Dual-mode placement: one buffer needed (length <= 2*Limit) -> split evenly
  // for margin; several -> pack to max-reach to keep the count near optimal.
  CurLen := TraceLengthUm(FRouteTraces[ATraceIdx], Core);
  UseBalanced := CurLen <= 2 * Limit;
  Cap := Limit * (1 - MaxReachLeeway);

  BufCell := FindMinDelayBufferCell;
  if BufCell = nil then
  begin
    MemoRouting.Lines.Add('  no usable buffer cell in the library.');
    Exit;
  end;
  InPort := nil;
  OutPort := nil;
  for k := 0 to BufCell.Ports.Count - 1 do
    if BufCell.Ports[k].Direction = pdOutput then
      OutPort := BufCell.Ports[k]
    else if BufCell.Ports[k].Direction = pdInput then
      InPort := BufCell.Ports[k];
  if (InPort = nil) or (OutPort = nil) then
  begin
    MemoRouting.Lines.Add(Format('  buffer %s has no single input/output pin.',
      [BufCell.Name]));
    Exit;
  end;
  InPin := InPort.Name;
  OutPin := OutPort.Name;

  NetName := FRouteTraces[ATraceIdx].NetName;
  IsClock := UNetNaming.IsClockNetName(NetName);
  Src := FRouteTraces[ATraceIdx].Points[0];
  Dst := FRouteTraces[ATraceIdx].Points[High(FRouteTraces[ATraceIdx].Points)];
  Driver := nil;
  Load := nil;
  DriverPin := '';
  LoadPin := '';
  IsPadLoad := False;

  if IsClock then
  begin
    TreeModel := FClockBufferedModel;
    if TreeModel = nil then
      TreeModel := FClockModel;
    if TreeModel = nil then
      Exit;
    if not TreeModel.Nets.TryGetValue(NetName, Net) then
      Exit;
    ClkPos := TDictionary<TGateInstance, TPoint>.Create;
    ClkRot := TDictionary<TGateInstance, Boolean>.Create;
    try
      for k := 0 to High(FSpine) do
      begin
        Sp := FSpine[k];
        if Sp.Gate <> nil then
        begin
          ClkPos.AddOrSetValue(Sp.Gate, TPoint.Create(Sp.X, Sp.Y));
          ClkRot.AddOrSetValue(Sp.Gate, Sp.Rotated);
        end;
      end;
      for L := 0 to High(FClockSubtree) do
        for ci := 0 to High(FClockSubtree[L]) do
        begin
          Node := FClockSubtree[L][ci];
          if Node.Gate <> nil then
          begin
            ClkPos.AddOrSetValue(Node.Gate, TPoint.Create(Node.X, Node.Y));
            ClkRot.AddOrSetValue(Node.Gate, False);
          end;
        end;
      for NC in Net.Connections do
      begin
        if NC.IsDriver then
          Continue;
        // Length mask buffers are placed by their own layer, not ClkPos.
        if ClkPos.ContainsKey(NC.Gate) then
        begin
          if not GatePinBlockAt(NC.Gate, NC.PinName, 0,
            ClkPos[NC.Gate].X, ClkPos[NC.Gate].Y, ClkRot[NC.Gate], Pt) then
            Continue;
        end
        else if FGatePlacement.TryGetValue(NC.Gate, GatePos) then
        begin
          if not GatePinBlockAt(NC.Gate, NC.PinName, 0,
            GatePos.X, GatePos.Y, False, Pt) then
            Continue;
        end
        else
          Continue;
        if (Pt.X = Dst.X) and (Pt.Y = Dst.Y) then
        begin
          Load := NC.Gate;
          LoadPin := NC.PinName;
          Break;
        end;
      end;
    finally
      ClkPos.Free;
      ClkRot.Free;
    end;
  end
  else
  begin
    if (FPlacementModel = nil) or
       (not FPlacementModel.Nets.TryGetValue(NetName, Net)) then
      Exit;
    for NC in Net.Connections do
      if NC.IsDriver and FGatePlacement.ContainsKey(NC.Gate) then
      begin
        Driver := NC.Gate;
        DriverPin := NC.PinName;
        Break;
      end;
    for NC in Net.Connections do
    begin
      if NC.IsDriver then
        Continue;
      if not FGatePlacement.ContainsKey(NC.Gate) then
        Continue;
      if GatePinBlock(NC.Gate, NC.PinName, 0, Pt) and
         (Pt.X = Dst.X) and (Pt.Y = Dst.Y) then
      begin
        Load := NC.Gate;
        LoadPin := NC.PinName;
        Break;
      end;
    end;
  end;
  if Load = nil then
  begin
    // A primary output net has no gate load: keep the name on the buffer->pad
    // side (the pad is keyed to it) and move the driver onto a fresh net.
    if (not IsClock) and FPadMap.ContainsKey(NetName) and (Driver <> nil) then
      IsPadLoad := True
    else
    begin
      MemoRouting.Lines.Add(Format('  cannot resolve %s load pin.', [NetName]));
      Exit;
    end;
  end;

  // A latched bias failure makes every slot unusable; do not walk thousands of
  // them (each attempt re-expands the layout and looks like a freeze).
  if FBiasExpansionFailed then
  begin
    MemoRouting.Lines.Add(Format(
      '  %s: bias expansion has failed, no buffer can be placed.', [NetName]));
    Exit;
  end;

  // Buffer footprint in grid cells.
  W := Round(BufCell.Width / Core);
  if W < 1 then
    W := 1;
  H := Round(BufCell.Height / Core);
  if H < 1 then
    H := 1;

  // Enumerate every free slot and score by residual reach: logic and clock rows
  // only. Buffers are never placed in the clock-trunk column: a validation
  // buffer there is not rotated and its bias ports are not collected, so the
  // trunk is left to the spine placer. Wires are ignored.
  NumBands := Length(FPlanBandStarts);
  SetLength(Cands, 0);
  for Band := 0 to NumBands - 1 do
  begin
    // Logic rows.
    if H <= FPlanRowHBlocks then
    begin
      RowType := 0;
      for X := FPlanXLeft to FPlanXRight - W do
        Consider(X, BandLogicRowY(Band) + ((FPlanRowHBlocks - H) div 2));
    end;
    // Clock rows.
    if H <= FPlanRowHBlocks then
    begin
      RowType := 1;
      for X := FPlanXLeft to FPlanXRight - W do
        Consider(X, BandClockRowY(Band) + ((FPlanRowHBlocks - H) div 2));
    end;
  end;

  if Length(Cands) = 0 then
  begin
    MemoRouting.Lines.Add(Format(
      '  no free buffer slot satisfies the length split for %s.', [NetName]));
    Exit;
  end;

  // Sort by score descending (best split per the current mode: balanced for
  // short wires, max-reach packing for long ones).
  for a := 1 to High(Cands) do
  begin
    TmpC := Cands[a];
    b := a - 1;
    while (b >= 0) and (Cands[b].Score < TmpC.Score) do
    begin
      Cands[b + 1] := Cands[b];
      Dec(b);
    end;
    Cands[b + 1] := TmpC;
  end;

  for a := 0 to High(Cands) do
  begin
    C := Cands[a];
    if TryInsertBuffer(IsClock, NetName, Driver, Load, DriverPin, LoadPin,
      IsPadLoad, True, BufCell, InPin, OutPin, C.Band, C.RowType,
      C.X, C.Y) then
    begin
      Result := True;
      Exit;
    end;
    FValidationBlocked.Add(Format('%d:%d:%d:%d', [C.Band, C.RowType, C.X, C.Y]));
    if FBiasExpansionFailed then
      Break; // layout-wide failure: more slots cannot help
  end;
  MemoRouting.Lines.Add(Format(
    '  every buffer slot for %s made the circuit unroutable.', [NetName]));
end;

// Repeats: rip up / re-route the longest over-limit PTL, else insert a min-delay
// buffer to split it; stops when all PTLs fit or no buffer slot is usable.
procedure TForm1.RunRoutingValidation;
var
  Core, Limit, Len, Man, BestLen: Double;
  i, BestIdx: Integer;
  OldModel: TBlifModel;
  Pt0, Pt1: TPoint;
  ClockInserted, LengthInserted: Boolean;
begin
  RefreshDesignConfig;
  if Length(FRouteTraces) = 0 then
  begin
    MemoRouting.Lines.Add('No routed traces to validate.');
    if FFlowStage < fsValidated then FFlowStage := fsValidated;
    Exit;
  end;
  Core := FDesignConfig.CoreUm;
  if Core <= 0 then
    Core := FPlanCore;
  Limit := FDesignConfig.MaxPtlLengthUm;
  if Limit <= 0 then
  begin
    MemoRouting.Lines.Add('Set a PTL length limit before validating.');
    if FFlowStage < fsValidated then FFlowStage := fsValidated;
    Exit;
  end;
  // Validation runs on a CLEAN model every time: scrap any prior validation
  // clone, then clone the pristine base fresh and mutate only that.
  ScrapValidationModel;
  // Traces left over from a previous validation reference its buffer nets, which
  // the clean model does not have; re-route the pristine model first so the
  // input traces match the netlist being validated.
  if HasValidationBufferTraces then
  begin
    // Re-route the PRISTINE model on the SAME placement, so the input traces
    // match what the routing page shows. Rebuilding + re-optimising here would
    // discard the layout the user optimised and bias-expanded.
    RebuildFloorplanPreserve;
    RunRouting;
  end;
  if FPlacementModel <> nil then
  begin
    OldModel := FPlacementModel;
    FOwnedPlacementModel := FPlacementModel.Clone;
    FPlacementModel := FOwnedPlacementModel;
    // Rebuild the placement maps against the CLONE's gates so resolution and
    // overlap checks see the mutated netlist; the rebuild re-keys the rows by
    // gate index (against the pre-clone model), so the layout stays put.
    RebuildFloorplanPreserve(OldModel);
  end;
  // A fresh validation session: the buffers inserted on a previous run stay in
  // the netlist (they are now part of the circuit) but are re-applied fresh.
  FValidationBuffers := nil;
  FValidationBlocked.Clear;
  MemoRouting.Lines.Add('--- Routing validation ---');
  MemoRouting.Lines.Add(Format('PTL length limit: %s um', [EditPTLLength.Text]));

  repeat
    // Clock first: insert trunk buffers until every clocked cell's clock has
    // arrived by the time its data can. The length check then moves wires
    // again, so alternate until both hold in the same pass.
    ClockInserted := False;
    LengthInserted := False;

    if not RunClockValidation(ClockInserted) then
    begin
      RepaintRoutingPage;
      Exit;
    end;

    repeat
      // The longest over-limit PTL is fixed first (most impactful).
      BestIdx := -1;
      BestLen := 0;
      for i := 0 to High(FRouteTraces) do
      begin
        if IsBiasTrace(FRouteTraces[i]) then
          Continue;
        Len := TraceLengthUm(FRouteTraces[i], Core);
        if (Len > Limit) and (Len > BestLen) then
        begin
          BestLen := Len;
          BestIdx := i;
        end;
      end;
      if BestIdx < 0 then
        Break; // every PTL is within the limit

      Pt0 := FRouteTraces[BestIdx].Points[0];
      Pt1 := FRouteTraces[BestIdx].Points[High(FRouteTraces[BestIdx].Points)];
      Man := (Abs(Pt1.X - Pt0.X) + Abs(Pt1.Y - Pt0.Y)) * Core;
      MemoRouting.Lines.Add(Format('  %s: %.2f um (Manhattan span %.2f um)',
        [FRouteTraces[BestIdx].NetName, BestLen, Man]));

      // The routed length exceeding the Manhattan span means the wire took a
      // detour; rip it up and re-route through the usual passes (a straight line
      // is always at least worth attempting - the router may find a shorter one).
      if (Man > 0) and (BestLen > Man) then
      begin
        MemoRouting.Lines.Add('    detour: ripping up and re-routing...');
        if RerouteTrace(BestIdx) then
        begin
          MemoRouting.Lines.Add('    re-routed under the limit.');
          LengthInserted := True;
          RepaintRoutingPage;
          Continue; // re-scan; other over-limit wires are fixed next
        end
        else
          MemoRouting.Lines.Add('    re-route did not reach the limit; inserting a buffer.');
      end;

      if not InsertBufferForTrace(BestIdx) then
      begin
        if FBiasExpansionFailed then
        begin
          MemoRouting.Lines.Add(
            'VALIDATION STOPPED: the bias lines do not fit the die, so the ' +
            'length-fixing buffer could not be placed.');
          MemoRouting.Lines.Add(
            '  Fix: raise the die height (or widen the die / lower the bias ' +
            'current) on the Placement page, expand the bias lines again, then ' +
            're-run routing.');
          // Not validated: drop back to the routed stage so Export stays locked.
          if FFlowStage > fsRouted then FFlowStage := fsRouted;
          UpdateUI;
          RepaintRoutingPage;
          Application.ProcessMessages;
          Exit;
        end;
        MemoRouting.Lines.Add(Format(
          'VALIDATION FAILED: no usable buffer location on %s.',
          [FRouteTraces[BestIdx].NetName]));
        if FFlowStage < fsValidated then FFlowStage := fsValidated;
        RepaintRoutingPage;
        Exit;
      end;
      LengthInserted := True;
      // InsertBufferForTrace re-ran the bias expansion + routing; re-scan.
      RepaintRoutingPage;
    until False;
  until (not ClockInserted) and (not LengthInserted);

  MemoRouting.Lines.Add('All PTL lengths are within the limit.');
  if FFlowStage < fsValidated then FFlowStage := fsValidated;
  // Requirement audit: printed below the validation output; the stage is only
  // cleared as validated when every requirement holds.
  if not RunFinalChecks then
    FFlowStage := fsRouted;
  RepaintRoutingPage;
end;

// Draws traces as polylines through block centres: layer colour, or a blue-to-red
// length scale capped at the PTL limit (dashed past it). Bias lines stay solid.
procedure TForm1.DrawRoutedTraces(Canvas: TCanvas);
var
  Core: Double;
  Limit: Double;
  ScaleCap: Double;
  i, k: Integer;
  Clr: TAlphaColor;
  X1, Y1, X2, Y2: Single;
  Len, MaxLen, t: Double;
  Found: Boolean;
  IsBias: Boolean;
  L: Integer;
  B: TBiasCell;
begin
  if (Length(FRouteTraces) = 0) and (Length(FBiasCells) = 0) then
    Exit;
  Core := FDesignConfig.CoreUm;
  if Core <= 0 then
    Core := FPlanCore;
  Limit := FDesignConfig.MaxPtlLengthUm;
  if Limit <= 0 then
    Limit := 0;
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Thickness := TraceThick;

  // Fallback scale cap: the longest PTL trace (only used when no limit is set).
  MaxLen := 0;
  Found := False;
  for i := 0 to High(FRouteTraces) do
  begin
    if IsBiasTrace(FRouteTraces[i]) then
      Continue;
    Found := True;
    Len := TraceLengthUm(FRouteTraces[i], Core);
    if Len > MaxLen then MaxLen := Len;
  end;
  if not Found then
    MaxLen := 1;
  if MaxLen <= 0 then
    MaxLen := 1;
  if Limit > 0 then
    ScaleCap := Limit
  else
    ScaleCap := MaxLen;

  for i := 0 to High(FRouteTraces) do
  begin
    if Length(FRouteTraces[i].Layers) <= 1 then
      Continue;
    IsBias := IsBiasTrace(FRouteTraces[i]);
    // The wire length drives both the dash pattern and the length colour:
    // compute it once per trace, not once per segment.
    if IsBias or (not FRouteLengthColor) then
      Len := 0
    else
      Len := TraceLengthUm(FRouteTraces[i], Core);
    if (not IsBias) and FRouteLengthColor and (Limit > 0) and (Len > Limit) then
      // Past the PTL length limit: draw dashed (length mode only).
      Canvas.Stroke.Dash := TStrokeDash.Dash
    else
      Canvas.Stroke.Dash := TStrokeDash.Solid;
    // Draw each segment; via cells are the point where the layer changes
    // (both colours join there).
    for k := 0 to High(FRouteTraces[i].Points) - 1 do
    begin
      if not RoutingLayerEnabled(FRouteTraces[i].Layers[k]) then
        Continue;
      if IsBias or (not FRouteLengthColor) then
        Clr := UColors.RoutingLayerColor(FRoutingLayers.IndexOf(FRouteTraces[i].Layers[k]), 1.0)
      else
      begin
        t := Len / ScaleCap;
        if t < 0 then t := 0;
        if t > 1 then t := 1;
        Clr := UColors.LengthColor(t);
      end;
      // Keep the trace opaque against the pale die body.
      Clr := (Clr and $FFFFFF) or $FF000000;
      Canvas.Stroke.Color := Clr;
      X1 := FRoutePanX + (FRouteTraces[i].Points[k].X + 0.5) * Core * FRouteZoom;
      Y1 := FRoutePanY + (FRouteTraces[i].Points[k].Y + 0.5) * Core * FRouteZoom;
      X2 := FRoutePanX + (FRouteTraces[i].Points[k + 1].X + 0.5) * Core * FRouteZoom;
      Y2 := FRoutePanY + (FRouteTraces[i].Points[k + 1].Y + 0.5) * Core * FRouteZoom;
      Canvas.DrawLine(TPointF.Create(X1, Y1), TPointF.Create(X2, Y2), 1.0);
    end;
  end;
  Canvas.Stroke.Dash := TStrokeDash.Solid;
  // Block-based bias tree: draw centre-to-centre lines per direction bit, in
  // the bias layer's own colour, straight from the assembled bias cells. Hidden
  // with the rest of the layer when its legend entry is toggled off.
  if (Length(FBiasCells) > 0) and RoutingLayerEnabled(FBiasCells[0].Layer) then
  begin
    Canvas.Stroke.Thickness := TraceThick;
    L := FRoutingLayers.IndexOf(FBiasCells[0].Layer);
    if L >= 0 then
      Clr := UColors.RoutingLayerColor(L, 1.0)
    else
      Clr := UColors.PalBiasInk;
    Clr := (Clr and $FFFFFF) or $FF000000;
    Canvas.Stroke.Color := Clr;
    for i := 0 to High(FBiasCells) do
    begin
      B := FBiasCells[i];
      X1 := FRoutePanX + (B.X + 0.5) * Core * FRouteZoom;
      Y1 := FRoutePanY + (B.Y + 0.5) * Core * FRouteZoom;
      if (B.Dirs and BiasDirE) <> 0 then
        Canvas.DrawLine(TPointF.Create(X1, Y1),
          TPointF.Create(FRoutePanX + (B.X + 1.5) * Core * FRouteZoom, Y1), 1.0);
      if (B.Dirs and BiasDirW) <> 0 then
        Canvas.DrawLine(TPointF.Create(X1, Y1),
          TPointF.Create(FRoutePanX + (B.X - 0.5) * Core * FRouteZoom, Y1), 1.0);
      if (B.Dirs and BiasDirS) <> 0 then
        Canvas.DrawLine(TPointF.Create(X1, Y1),
          TPointF.Create(X1, FRoutePanY + (B.Y + 1.5) * Core * FRouteZoom), 1.0);
      if (B.Dirs and BiasDirN) <> 0 then
        Canvas.DrawLine(TPointF.Create(X1, Y1),
          TPointF.Create(X1, FRoutePanY + (B.Y - 0.5) * Core * FRouteZoom), 1.0);
    end;
  end;
  // In Debug mode, overlay the resonant-length problem markers.
  if FRouteLengthColor then
    DrawResonancePulses(Canvas, Core, ScaleCap);
end;

// Debug overlay: marks each straight section (between bends/vias) at every
// multiple of the resonant length Lr = 500/(f*delay) with its danger band.
procedure TForm1.DrawResonancePulses(Canvas: TCanvas;
  Core, ScaleCap: Double);
var
  FreqGHz, Delay, Lr, PulseW, TraceLen, SecLen: Double;
  i, d, Ux, Uy, Px, Py, segD, segLen: Integer;
  Clr: TAlphaColor;
  SecStartX, SecStartY: Double;
  SecDir: Integer;
  a, b: TPoint;
  t: Double;

  // Filled danger-band rectangle centred at along-wire CUm, +/-HalfBaseUm along
  // the wire and +/-DangerHalfWidthBlocks across, clamped to the section.
  procedure FillDangerRect(CUm, HalfBaseUm: Double);
  var
    Lo, Hi, Mid, HalfLenBlocks, Cx, Cy, ExX, ExY: Double;
  begin
    Lo := CUm - HalfBaseUm;
    if Lo < 0 then
      Lo := 0;
    Hi := CUm + HalfBaseUm;
    if Hi > SecLen then
      Hi := SecLen;
    if Hi <= Lo then
      Exit; // marker entirely off the section
    Mid := (Lo + Hi) / 2;                    // along-wire centre, um
    HalfLenBlocks := (Hi - Lo) / 2 / Core;   // along-wire half-length, blocks
    Cx := SecStartX + Ux * (Mid / Core);
    Cy := SecStartY + Uy * (Mid / Core);
    ExX := Abs(Ux) * HalfLenBlocks + Abs(Px) * DangerHalfWidthBlocks;
    ExY := Abs(Uy) * HalfLenBlocks + Abs(Py) * DangerHalfWidthBlocks;
    Canvas.Fill.Color := Clr;
    Canvas.FillRect(TRectF.Create(
      FRoutePanX + (Cx - ExX + 0.5) * Core * FRouteZoom,
      FRoutePanY + (Cy - ExY + 0.5) * Core * FRouteZoom,
      FRoutePanX + (Cx + ExX + 0.5) * Core * FRouteZoom,
      FRoutePanY + (Cy + ExY + 0.5) * Core * FRouteZoom), 0, 0, [], 1.0);
  end;

  // Draws the danger rectangles along the straight section accumulated so far,
  // one per resonant multiple.
  procedure FlushSection;
  var
    n, MaxN: Integer;
  begin
    if (SecLen <= 0) or (SecDir < 0) or (PulseW <= 0) or (Lr <= 0) then
      Exit;
    UGeometry.DirUnit(SecDir, Ux, Uy);
    if (SecDir = 0) or (SecDir = 1) then
    begin
      Px := 0; Py := 1; // wire horizontal
    end
    else
    begin
      Px := 1; Py := 0; // wire vertical
    end;
    if (SecLen + PulseW / 2) / Lr > 100000 then
      MaxN := 100000
    else
      MaxN := Trunc((SecLen + PulseW / 2) / Lr);
    if MaxN < 0 then
      MaxN := 0;
    for n := 1 to MaxN do
      FillDangerRect(n * Lr, PulseW / 2);
  end;

begin
  FreqGHz := FDesignConfig.FreqGHz;
  Delay := FDesignConfig.PtlDelayPsPerUm;
  PulseW := FDesignConfig.PulseWidthUm;
  if (FreqGHz <= 0) or (Delay <= 0) or (PulseW <= 0) then
    Exit;
  Lr := UPhysics.ResonantLengthUm(FreqGHz, Delay); // resonant length, um
  if Lr <= 0 then
    Exit;
  Canvas.Stroke.Kind := TBrushKind.Solid;
  Canvas.Stroke.Thickness := 1.5;
  Canvas.Fill.Kind := TBrushKind.Solid;
  for i := 0 to High(FRouteTraces) do
  begin
    if IsBiasTrace(FRouteTraces[i]) then
      Continue; // constant-voltage lines do not resonate
    if Length(FRouteTraces[i].Points) < 2 then
      Continue;
    // Match the wire colour: the length scale (Debug mode always colours by
    // length).
    TraceLen := TraceLengthUm(FRouteTraces[i], Core);
    if ScaleCap > 0 then
      t := TraceLen / ScaleCap
    else
      t := 0;
    if t < 0 then t := 0;
    if t > 1 then t := 1;
    Clr := (UColors.LengthColor(t) and $FFFFFF) or $FF000000;

    // Walk the trace, grouping collinear same-layer segments into sections. A
    // via (layer change) or a bend (direction change) is a discontinuity.
    SecDir := -1;
    SecLen := 0;
    for d := 0 to High(FRouteTraces[i].Points) - 1 do
    begin
      a := FRouteTraces[i].Points[d];
      b := FRouteTraces[i].Points[d + 1];
      if not SameText(FRouteTraces[i].Layers[d], FRouteTraces[i].Layers[d + 1]) then
      begin
        FlushSection;
        SecDir := -1;
        SecLen := 0;
        Continue; // via
      end;
      segD := UGeometry.SegDir(b.X - a.X, b.Y - a.Y);
      if segD < 0 then
      begin
        FlushSection;
        SecDir := -1;
        SecLen := 0;
        Continue;
      end;
      segLen := Abs(b.X - a.X) + Abs(b.Y - a.Y);
      if SecDir = -1 then
      begin
        SecDir := segD;
        SecStartX := a.X;
        SecStartY := a.Y;
        SecLen := segLen * Core;
      end
      else if segD = SecDir then
        SecLen := SecLen + segLen * Core
      else
      begin
        FlushSection;
        SecDir := segD;
        SecStartX := a.X;
        SecStartY := a.Y;
        SecLen := segLen * Core;
      end;
    end;
    FlushSection;
  end;
  Canvas.Stroke.Dash := TStrokeDash.Solid;
end;

// Grid block of a gate's pin on routing layer ALayer (gate origin from
// FGatePlacement); falls back to the first shape, then the cell centre.
// Routing layers a pin's LEF shapes allow (bit k = FRouteLayers[k]). A port
// with no shapes at all is a synthetic cell (clock delay / trunk buffer), which
// may connect on any layer; a port whose shapes are all on non-routing layers
// yields 0, i.e. no wire can ever reach it.
function TForm1.PortLayerMask(G: TGateInstance; const PinName: string): UInt64;
var
  Port: TPort;
  Shape: TPortShape;
  k: Integer;
begin
  Result := 0;
  if (G = nil) or (G.Cell = nil) then
    Exit(High(UInt64));
  Port := G.Cell.FindPort(PinName);
  if (Port = nil) or (Port.Shapes.Count = 0) then
    Exit(High(UInt64));
  for Shape in Port.Shapes do
    for k := 0 to High(FRouteLayers) do
      if SameText(Shape.Layer, FRouteLayers[k]) then
        Result := Result or (UInt64(1) shl k);
end;

// Lowest allowed route-layer index (0 when the mask allows none).
function TForm1.FirstMaskLayer(Mask: UInt64): Integer;
var
  k: Integer;
begin
  Result := 0;
  for k := 0 to High(FRouteLayers) do
    if ((Mask shr k) and 1) <> 0 then
      Exit(k);
end;

function TForm1.GatePinBlock(G: TGateInstance; const PinName: string;
  ALayer: Integer; var P: TPoint): Boolean;
var
  Pt: TPoint;
begin
  Result := False;
  if (G = nil) or (G.Cell = nil) then
    Exit;
  if not FGatePlacement.TryGetValue(G, Pt) then
    Exit;
  Result := GatePinBlockAt(G, PinName, ALayer, Pt.X, Pt.Y, False, P);
end;

// Like GatePinBlock but with an explicit placed origin (AX, AY) for clock gates;
// rotated cells have their footprint and pin shapes turned 90 deg CCW.
function TForm1.GatePinBlockAt(G: TGateInstance; const PinName: string;
  ALayer, AX, AY: Integer; Rotated: Boolean; var P: TPoint): Boolean;
var
  Core: Double;
  Port: TPort;
  Shape: TPortShape;
  CellW, CellH: Double;
  BX0, BY0, BX1, BY1: Integer;
begin
  Result := False;
  if (G = nil) or (G.Cell = nil) then
    Exit;
  Core := FDesignConfig.CoreUm;
  if Core <= 0 then
    Core := FPlanCore;
  // The pin's own geometry: prefer a shape on the requested layer.
  Port := G.Cell.FindPort(PinName);
  Shape := nil;
  if Port <> nil then
  begin
    for Shape in Port.Shapes do
      if (ALayer >= 0) and (ALayer < Length(FRouteLayers)) and
         SameText(Shape.Layer, FRouteLayers[ALayer]) then
        Break;
    if (Shape = nil) and (Port.Shapes.Count > 0) then
      Shape := Port.Shapes[0];
  end;
  if Shape <> nil then
  begin
    // The occupied cell: the range of blocks covered by the (possibly
    // rotated) shape.
    if Rotated then
    begin
      CellH := G.Cell.Height;
      if CellH <= 0 then
        CellH := Core;
      // 90 deg CCW: local (x, y) -> (cellH - y, x).
      BX0 := Trunc((AX * Core + (CellH - Shape.y2)) / Core);
      BY0 := Trunc((AY * Core + Shape.x1) / Core);
      BX1 := Trunc((AX * Core + (CellH - Shape.y1)) / Core);
      BY1 := Trunc((AY * Core + Shape.x2) / Core);
    end
    else
    begin
      // Canvas Y runs down while LEF Y runs up: flip (CellH - y).
      CellH := G.Cell.Height;
      if CellH <= 0 then
        CellH := Core;
      BX0 := Trunc((AX * Core + Shape.x1) / Core);
      BY0 := Trunc((AY * Core + (CellH - Shape.y2)) / Core);
      BX1 := Trunc((AX * Core + Shape.x2) / Core);
      BY1 := Trunc((AY * Core + (CellH - Shape.y1)) / Core);
    end;
    if BX1 < BX0 then BX0 := BX1;
    if BY1 < BY0 then BY0 := BY1;
    // The cell nearest the shape centre, guaranteed inside the covered range.
    P.X := BX0 + ((BX1 - BX0) div 2);
    P.Y := BY0 + ((BY1 - BY0) div 2);
    // Clamp into the die grid: edge cells can otherwise resolve a pin block one
    // past the boundary and make the Lee router bail on its bounds check.
    if FRouteObstaclesW > 0 then
    begin
      if P.X < 0 then P.X := 0;
      if P.X >= FRouteObstaclesW then P.X := FRouteObstaclesW - 1;
    end;
    if FRouteObstaclesH > 0 then
    begin
      if P.Y < 0 then P.Y := 0;
      if P.Y >= FRouteObstaclesH then P.Y := FRouteObstaclesH - 1;
    end;
    Result := True;
    Exit;
  end;
  // Fallback: the centre of the placed cell footprint.
  CellW := G.Cell.Width;
  CellH := G.Cell.Height;
  if CellW <= 0 then
    CellW := Core;
  if CellH <= 0 then
    CellH := Core;
  if Rotated then
  begin
    // Footprint is swapped: W = cell height, H = cell width.
    P.X := Trunc((AX * Core + CellH / 2) / Core);
    P.Y := Trunc((AY * Core + CellW / 2) / Core);
  end
  else
  begin
    P.X := Trunc((AX * Core + CellW / 2) / Core);
    P.Y := Trunc((AY * Core + CellH / 2) / Core);
  end;
  // Clamp into the die grid (see the shape path above).
  if FRouteObstaclesW > 0 then
  begin
    if P.X < 0 then P.X := 0;
    if P.X >= FRouteObstaclesW then P.X := FRouteObstaclesW - 1;
  end;
  if FRouteObstaclesH > 0 then
  begin
    if P.Y < 0 then P.Y := 0;
    if P.Y >= FRouteObstaclesH then P.Y := FRouteObstaclesH - 1;
  end;
  Result := True;
end;

// Windowed A* maze: straight costs 1, a turn adds TurnPenalty, a via ViaPenalty.
// UseLayer >= 0 pins one layer (no vias); OutPath/OutLayers get the path and layers.
function TForm1.LeeRoute(Start, Goal: TPoint; UseLayer: Integer;
  StartMask, GoalMask: UInt64;
  var OutPath: TArray<TPoint>; var OutLayers: TArray<Integer>): Boolean;
const
  DirDx: array[0..3] of Integer = (1, -1, 0, 0);
  DirDy: array[0..3] of Integer = (0, 0, 1, -1);
  DirCount = 5;    // states per cell-layer: Dir+1 in 0..4 (0 = no direction)
  MinMargin = 16;  // minimum window margin in blocks
  MaxMargin = 128; // maximum window margin in blocks
  MarginDiv = 3;   // margin = max(MinMargin, dist div MarginDiv)
  // Resonance pruning: a straight run that lands within half a pulse width of a
  // multiple of the resonant length is refused, so the path carries on straight.
  ResonanceGuardEnabled = True;
var
  W, H, NumLayers, MaxLayer, TotalStates: Integer;
  WinX0, WinY0, WinX1, WinY1, WinW, WinH: Integer;
  Margin, Dist: Integer;
  gScore: TArray<Integer>;
  Parent: TArray<Integer>;
  Closed: TArray<Boolean>;
  Heap: TArray<Integer>;
  HeapCount: Integer;
  S, NS: Integer;
  CurLayer, EffLayer, CurX, CurY: Integer;
  CurDir, Nx, Ny, d, L, i: Integer;
  NewG, TurnCost: Integer;
  Expanded, ExpansionLimit: Integer;
  lx, ly: Integer;
  Swp: TPoint;
  SwpLayer: Integer;
  LrUm, PulseWUm, CoreUm, FreqGHz, Delay: Double;
  ResonanceOn: Boolean;
  RunLen: TArray<Integer>; // straight-run length (blocks) of the best path to a state

  // State id over the WINDOW-local grid: ((ly*WinW+lx)*MaxLayer+Layer)*DirCount
  // + (Dir+1), Dir in -1..3. lx = X - WinX0, ly = Y - WinY0.
  function StateId(lx, ly, Layer, Dir: Integer): Integer;
  begin
    Result := (((ly * WinW + lx) * MaxLayer + Layer) * DirCount) + (Dir + 1);
  end;

  // Manhattan distance from the state's cell to the goal (global coords).
  function Heuristic(S: Integer): Integer;
  var
    cell, hx, hy: Integer;
  begin
    cell := (S div DirCount) div MaxLayer;
    hy := cell div WinW;
    hx := cell mod WinW;
    Result := Abs((hx + WinX0) - Goal.X) + Abs((hy + WinY0) - Goal.Y);
  end;

  // Resonance guard: a straight run ending here is forbidden if its length is
  // within half a pulse width of an integer multiple of the resonant length.
  // RunBlocks is the straight-run length in grid blocks.
  function InDangerZone(RunBlocks: Integer): Boolean;
  var
    RunUm, Nearest: Double;
    n: Integer;
  begin
    Result := False;
    if (not ResonanceOn) or (RunBlocks <= 0) then
      Exit;
    RunUm := RunBlocks * CoreUm;
    if RunUm / LrUm > 1.0e7 then
      Exit; // absurd configuration (Lr far below a block): nothing sensible to flag
    n := Round(RunUm / LrUm);
    if n < 1 then
      Exit; // shorter than the first harmonic
    Nearest := n * LrUm;
    if Abs(RunUm - Nearest) <= PulseWUm / 2 then
      Result := True;
  end;

  // A is preferred over B when its f (= g+h) is lower; on equal f the one
  // closer to the goal (smaller h) is popped first, pushing the search toward
  // the goal instead of flaring sideways.
  function LessThan(A, B: Integer): Boolean;
  var
    fA, fB, hA, hB: Integer;
  begin
    fA := gScore[A] + Heuristic(A);
    fB := gScore[B] + Heuristic(B);
    hA := Heuristic(A);
    hB := Heuristic(B);
    Result := (fA < fB) or ((fA = fB) and (hA < hB));
  end;

  procedure HeapPush(S: Integer);
  var
    idx, par, Tmp: Integer;
  begin
    idx := HeapCount;
    Inc(HeapCount);
    if idx >= Length(Heap) then
      SetLength(Heap, HeapCount + 64);
    Heap[idx] := S;
    while idx > 0 do
    begin
      par := (idx - 1) div 2;
      if not LessThan(S, Heap[par]) then
        Break;
      Tmp := Heap[idx];
      Heap[idx] := Heap[par];
      Heap[par] := Tmp;
      idx := par;
    end;
  end;

  function HeapPop: Integer;
  var
    idx, child, other, Tmp: Integer;
  begin
    Result := Heap[0];
    Dec(HeapCount);
    if HeapCount > 0 then
    begin
      Heap[0] := Heap[HeapCount];
      idx := 0;
      while True do
      begin
        child := idx * 2 + 1;
        if child >= HeapCount then
          Break;
        other := child + 1;
        if (other < HeapCount) and LessThan(Heap[other], Heap[child]) then
          child := other;
        if not LessThan(Heap[child], Heap[idx]) then
          Break;
        Tmp := Heap[idx];
        Heap[idx] := Heap[child];
        Heap[child] := Tmp;
        idx := child;
      end;
    end;
  end;

begin
  Result := False;
  W := FRouteObstaclesW;
  H := FRouteObstaclesH;
  NumLayers := Length(FRouteLayers);
  if (W <= 0) or (H <= 0) or (NumLayers <= 0) then
    Exit;
  if (Start.X < 0) or (Start.X >= W) or (Start.Y < 0) or (Start.Y >= H) or
     (Goal.X < 0) or (Goal.X >= W) or (Goal.Y < 0) or (Goal.Y >= H) then
    Exit;
  if UseLayer >= NumLayers then
    Exit;
  // A single-layer pass can only connect pins that BOTH have metal on it: with
  // no via allowed at a pin, there is nothing to land on otherwise.
  if UseLayer >= 0 then
    if (((StartMask shr UseLayer) and 1) = 0) or
       (((GoalMask shr UseLayer) and 1) = 0) then
      Exit;
  if (Start.X = Goal.X) and (Start.Y = Goal.Y) then
  begin
    SetLength(OutPath, 1);
    OutPath[0] := Start;
    SetLength(OutLayers, 1);
    OutLayers[0] := 0;
    if UseLayer >= 0 then
      OutLayers[0] := UseLayer;
    Result := True;
    Exit;
  end;

  if UseLayer >= 0 then
    MaxLayer := 1
  else
    MaxLayer := NumLayers;

  // Resonance guard parameters: resonant length Lr = 500/(f*delay) um, with the
  // forbidden band +/- half the pulse width around each multiple of Lr. Off (no
  // pruning) if the configuration is incomplete.
  CoreUm := FDesignConfig.CoreUm;
  if CoreUm <= 0 then
    CoreUm := FPlanCore;
  FreqGHz := FDesignConfig.FreqGHz;
  Delay := FDesignConfig.PtlDelayPsPerUm;
  PulseWUm := FDesignConfig.PulseWidthUm;
  ResonanceOn := ResonanceGuardEnabled and (CoreUm > 0) and (FreqGHz > 0) and
    (Delay > 0) and (PulseWUm > 0);
  if ResonanceOn then
  begin
    LrUm := UPhysics.ResonantLengthUm(FreqGHz, Delay);
    ResonanceOn := LrUm > 0;
  end;

  // Search window: the terminal bounding box plus a margin that scales with the
  // Manhattan distance, clamped to the die. A shortest path never needs to leave
  // a comfortable box around its terminals, so this bounds the state space.
  Dist := Abs(Goal.X - Start.X) + Abs(Goal.Y - Start.Y);
  Margin := Dist div MarginDiv;
  if Margin < MinMargin then
    Margin := MinMargin;
  if Margin > MaxMargin then
    Margin := MaxMargin;
  WinX0 := Start.X;
  if Goal.X < WinX0 then
    WinX0 := Goal.X;
  WinX1 := Start.X;
  if Goal.X > WinX1 then
    WinX1 := Goal.X;
  WinY0 := Start.Y;
  if Goal.Y < WinY0 then
    WinY0 := Goal.Y;
  WinY1 := Start.Y;
  if Goal.Y > WinY1 then
    WinY1 := Goal.Y;
  Dec(WinX0, Margin);
  if WinX0 < 0 then
    WinX0 := 0;
  Inc(WinX1, Margin);
  if WinX1 >= W then
    WinX1 := W - 1;
  Dec(WinY0, Margin);
  if WinY0 < 0 then
    WinY0 := 0;
  Inc(WinY1, Margin);
  if WinY1 >= H then
    WinY1 := H - 1;
  WinW := WinX1 - WinX0 + 1;
  WinH := WinY1 - WinY0 + 1;

  TotalStates := WinW * WinH * MaxLayer * DirCount;
  SetLength(gScore, TotalStates);
  SetLength(Parent, TotalStates);
  SetLength(Closed, TotalStates);
  SetLength(RunLen, TotalStates);
  SetLength(Heap, 128);
  for i := 0 to TotalStates - 1 do
  begin
    gScore[i] := High(Integer) div 4;
    Closed[i] := False;
    RunLen[i] := 0;
  end;
  HeapCount := 0;

  // Expansion budget: a few passes over the window's cells. Since the window
  // already bounds the search, this only aborts genuinely hopeless cases.
  ExpansionLimit := WinW * WinH * MaxLayer * 3;
  if ExpansionLimit < 512 then
    ExpansionLimit := 512;
  Expanded := 0;

  // Seed the start on the layer(s) the search is allowed to use. The start
  // cell is not obstacle-checked (it is a pin block), and it has no incoming
  // direction (Dir = -1), so a turn away from it is not penalised.
  if UseLayer >= 0 then
  begin
    S := StateId(Start.X - WinX0, Start.Y - WinY0, 0, -1);
    gScore[S] := 0;
    Parent[S] := -1;
    HeapPush(S);
  end
  else
    // The wire leaves the driver pin on one of the pin's own layers: pins are
    // pillars, so no via may sit there. Everything else is reached by vias
    // along the way.
    for L := 0 to NumLayers - 1 do
      if ((StartMask shr L) and 1) <> 0 then
      begin
        S := StateId(Start.X - WinX0, Start.Y - WinY0, L, -1);
        gScore[S] := 0;
        Parent[S] := -1;
        HeapPush(S);
      end;

  while HeapCount > 0 do
  begin
    S := HeapPop;
    if Closed[S] then
      Continue;
    Closed[S] := True;
    Inc(Expanded);
    if Expanded > ExpansionLimit then
      Exit; // budget exceeded: give up on this route
    CurLayer := (S div DirCount) mod MaxLayer;
    lx := ((S div DirCount) div MaxLayer) mod WinW;
    ly := ((S div DirCount) div MaxLayer) div WinW;
    CurX := lx + WinX0;
    CurY := ly + WinY0;
    CurDir := (S mod DirCount) - 1;
    // In single-layer mode MaxLayer = 1, so the state's layer is always 0; the
    // obstacles to consult are on UseLayer. In multi-layer mode the state layer
    // is the real layer.
    if UseLayer >= 0 then
      EffLayer := UseLayer
    else
      EffLayer := CurLayer;

    if (CurX = Goal.X) and (CurY = Goal.Y) then
    begin
      // The wire must arrive on a layer the pin actually has: no via is allowed
      // on a pin pillar, so a foreign arrival would connect to nothing.
      if ((GoalMask shr EffLayer) and 1) = 0 then
        Continue;
      // The last straight ends at the goal (a port): if that final run lands in
      // the resonance danger zone, reject this arrival and keep searching.
      if InDangerZone(RunLen[S]) then
        Continue;
      // Reconstruct the path by walking parents back to the start.
      SetLength(OutPath, 0);
      SetLength(OutLayers, 0);
      NS := S;
      while NS >= 0 do
      begin
        CurLayer := (NS div DirCount) mod MaxLayer;
        lx := ((NS div DirCount) div MaxLayer) mod WinW;
        ly := ((NS div DirCount) div MaxLayer) div WinW;
        SetLength(OutPath, Length(OutPath) + 1);
        OutPath[High(OutPath)] :=
          TPoint.Create(lx + WinX0, ly + WinY0);
        SetLength(OutLayers, Length(OutLayers) + 1);
        if UseLayer >= 0 then
          OutLayers[High(OutLayers)] := UseLayer
        else
          OutLayers[High(OutLayers)] := CurLayer;
        NS := Parent[NS];
      end;
      // Reverse both arrays so the path runs start -> goal.
      for i := 0 to (Length(OutPath) div 2) - 1 do
      begin
        Swp := OutPath[i];
        OutPath[i] := OutPath[High(OutPath) - i];
        OutPath[High(OutPath) - i] := Swp;
        SwpLayer := OutLayers[i];
        OutLayers[i] := OutLayers[High(OutLayers) - i];
        OutLayers[High(OutLayers) - i] := SwpLayer;
      end;
      Result := True;
      Exit;
    end;

    // Same-layer 4-directional moves. A move that keeps the current heading
    // costs 1; changing heading adds TurnPenalty. Moves stay inside the window.
    for d := 0 to 3 do
    begin
      Nx := CurX + DirDx[d];
      Ny := CurY + DirDy[d];
      if (Nx < WinX0) or (Nx > WinX1) or (Ny < WinY0) or (Ny > WinY1) then
        Continue;
      if FRouteObstacles[EffLayer][Ny * W + Nx] and
         not ((Nx = Goal.X) and (Ny = Goal.Y)) then
        Continue;
      TurnCost := 0;
      if (CurDir >= 0) and (CurDir <> d) then
      begin
        // A turn ends the current straight run: deny it if that run lands in the
        // resonance danger zone (the path must carry on straight instead).
        if InDangerZone(RunLen[S]) then
          Continue;
        TurnCost := TurnPenalty;
      end;
      NewG := gScore[S] + 1 + TurnCost;
      NS := StateId(Nx - WinX0, Ny - WinY0, CurLayer, d);
      if (not Closed[NS]) and (NewG < gScore[NS]) then
      begin
        gScore[NS] := NewG;
        Parent[NS] := S;
        if TurnCost > 0 then
          RunLen[NS] := 1 // a new run starts on the turn
        else
          RunLen[NS] := RunLen[S] + 1; // continue the run
        HeapPush(NS);
      end;
    end;

    // Via transitions (multi-layer search only): switch layers on the spot.
    // The heading is unchanged, so no turn penalty applies. NOT on the goal
    // cell: the pads/pins are obstruction pillars, so no via geometry may sit
    // where the pin is. The wire has to arrive there on its own layer.
    if (UseLayer < 0) and not ((CurX = Goal.X) and (CurY = Goal.Y)) then
      for L := 0 to NumLayers - 1 do
      begin
        if L = CurLayer then
          Continue;
        if FRouteObstacles[L][CurY * W + CurX] then
          Continue;
        // A via is a discontinuity: it ends the current straight run, so deny it
        // if that run lands in the resonance danger zone.
        if InDangerZone(RunLen[S]) then
          Continue;
        NewG := gScore[S] + ViaPenalty;
        NS := StateId(CurX - WinX0, CurY - WinY0, L, CurDir);
        if (not Closed[NS]) and (NewG < gScore[NS]) then
        begin
          gScore[NS] := NewG;
          Parent[NS] := S;
          RunLen[NS] := 0; // the via starts a fresh run
          HeapPush(NS);
        end;
      end;
  end;
end;
