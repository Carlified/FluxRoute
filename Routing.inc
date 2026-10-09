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
    DieW := FDesignConfig.DieWUm;
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
  PassRouted, PassFailed: Integer;

  // Marks a routed path's cells as hard obstacles on the layers they use, so
  // later nets on those layers route around them (classic sequential maze).
  procedure BlockPath(Pth: TArray<TPoint>; PL: TArray<Integer>);
  var
    ii: Integer;
  begin
    for ii := 0 to High(Pth) do
    begin
      Pt := Pth[ii];
      if (Pt.X < 0) or (Pt.X >= FRouteObstaclesW) or
         (Pt.Y < 0) or (Pt.Y >= FRouteObstaclesH) then
        Continue;
      if (PL[ii] >= 0) and (PL[ii] <= High(FRouteObstacles)) then
        FRouteObstacles[PL[ii]][Pt.Y * FRouteObstaclesW + Pt.X] := True;
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
    SJ.Dist := High(Integer) div 2;
    if ADriver = nil then
    begin
      if GetPad(ANetName, SJ.Start) then
        SJ.StartValid := True;
    end
    else if GatePinBlock(ADriver, ADriverPin, 0, SJ.Start) then
      SJ.StartValid := True;
    if ALoad = nil then
    begin
      if GetPad(ANetName, SJ.Goal) then
        SJ.GoalValid := True;
    end
    else if GatePinBlock(ALoad, ALoadPin, 0, SJ.Goal) then
      SJ.GoalValid := True;
    if SJ.StartValid and SJ.GoalValid then
      SJ.Dist := Abs(SJ.Start.X - SJ.Goal.X) + Abs(SJ.Start.Y - SJ.Goal.Y);
    SetLength(Jobs, Length(Jobs) + 1);
    Jobs[High(Jobs)] := SJ;
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
            if NC.IsDriver and ClkPos.ContainsKey(NC.Gate) then
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
          else if not GatePinBlockAt(Driver, DriverPin, 0,
            ClkPos[Driver].X, ClkPos[Driver].Y, ClkRot[Driver], DriverPos) then
          begin
            Continue;
          end;
          // Each non-driver connection is a point-to-point link.
          for NC in Net.Connections do
          begin
            if NC.IsDriver then
              Continue;
            if NC.Gate = nil then
            begin
              Continue;
            end;
            if not ClkPos.TryGetValue(NC.Gate, GatePos) then
            begin
              Continue;
            end;
            if not GatePinBlockAt(NC.Gate, NC.PinName, 0,
              GatePos.X, GatePos.Y, ClkRot[NC.Gate], Pt) then
            begin
              Continue;
            end;
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
           LeeRoute(Job.Start, Job.Goal, L, Path, PathLayers) then
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
         LeeRoute(Job.Start, Job.Goal, -1, Path, PathLayers) then
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
  BX0, BY0, BX1, BY1: Integer;
  Swp: Integer;
  Sp: TSpineComponent;
  Node: TPlacedClockNode;
  L, ci: Integer;

  // Marks every pin shape of one gate, placed at (AX, AY) (grid cells, with
  // optional 90 deg CCW rotation), on the routing layer it belongs to.
  procedure MarkGatePins(G: TGateInstance; AX, AY: Integer; Rotated: Boolean);
  var
    k, x, y: Integer;
    Port2: TPort;
    Shape2: TPortShape;
    CellH: Double;
  begin
    if (G = nil) or (G.Cell = nil) then
      Exit;
    for k := 0 to High(FRouteLayers) do
    begin
      for Port2 in G.Cell.Ports do
        for Shape2 in Port2.Shapes do
          if SameText(Shape2.Layer, FRouteLayers[k]) then
          begin
            if Rotated then
            begin
              CellH := G.Cell.Height;
              if CellH <= 0 then CellH := Core;
              BX0 := Trunc((AX * Core + (CellH - Shape2.y2)) / Core);
              BY0 := Trunc((AY * Core + Shape2.x1) / Core);
              BX1 := Trunc((AX * Core + (CellH - Shape2.y1)) / Core);
              BY1 := Trunc((AY * Core + Shape2.x2) / Core);
            end
            else
            begin
              // Canvas Y runs down while LEF Y runs up: flip (CellH - y).
              CellH := G.Cell.Height;
              if CellH <= 0 then CellH := Core;
              BX0 := Trunc((AX * Core + Shape2.x1) / Core);
              BY0 := Trunc((AY * Core + (CellH - Shape2.y2)) / Core);
              BX1 := Trunc((AX * Core + Shape2.x2) / Core);
              BY1 := Trunc((AY * Core + (CellH - Shape2.y1)) / Core);
            end;
            if BX1 < BX0 then begin Swp := BX0; BX0 := BX1; BX1 := Swp; end;
            if BY1 < BY0 then begin Swp := BY0; BY0 := BY1; BY1 := Swp; end;
            for x := BX0 to BX1 do
              for y := BY0 to BY1 do
                if (x >= 0) and (x < W) and (y >= 0) and (y < H) then
                  FRouteObstacles[k][y * W + x] := True;
          end;
      for Port2 in G.Cell.PowerPorts do
        for Shape2 in Port2.Shapes do
          if SameText(Shape2.Layer, FRouteLayers[k]) then
          begin
            if Rotated then
            begin
              CellH := G.Cell.Height;
              if CellH <= 0 then CellH := Core;
              BX0 := Trunc((AX * Core + (CellH - Shape2.y2)) / Core);
              BY0 := Trunc((AY * Core + Shape2.x1) / Core);
              BX1 := Trunc((AX * Core + (CellH - Shape2.y1)) / Core);
              BY1 := Trunc((AY * Core + Shape2.x2) / Core);
            end
            else
            begin
              // Canvas Y runs down while LEF Y runs up: flip (CellH - y).
              CellH := G.Cell.Height;
              if CellH <= 0 then CellH := Core;
              BX0 := Trunc((AX * Core + Shape2.x1) / Core);
              BY0 := Trunc((AY * Core + (CellH - Shape2.y2)) / Core);
              BX1 := Trunc((AX * Core + Shape2.x2) / Core);
              BY1 := Trunc((AY * Core + (CellH - Shape2.y1)) / Core);
            end;
            if BX1 < BX0 then begin Swp := BX0; BX0 := BX1; BX1 := Swp; end;
            if BY1 < BY0 then begin Swp := BY0; BY0 := BY1; BY1 := Swp; end;
            for x := BX0 to BX1 do
              for y := BY0 to BY1 do
                if (x >= 0) and (x < W) and (y >= 0) and (y < H) then
                  FRouteObstacles[k][y * W + x] := True;
          end;
    end;
  end;

begin
  Core := FDesignConfig.CoreUm;
  if Core <= 0 then
    Core := FPlanCore;
  W := 0;
  H := 0;
  if FDesignConfig.DieWUm > 0 then
    W := Round(FDesignConfig.DieWUm / Core);
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
end;

// Grows a band's TOP (Which=0) or MIDDLE (Which=1) bias row by ByRows cells to
// relieve congestion; reports and aborts (layout unchanged) when the die is full.
function TForm1.IncreaseBiasRowHeight(Band, Which, ByRows: Integer): Boolean;
var
  DieHBlocks: Integer;
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
    AddFloorplanError('not enough space for the bias lines');
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
    AddFloorplanError('not enough space for the bias lines');
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

// Widens a vertical bias lane by ByCols (0 = left feed, 1 = far-right); if the
// die is full, packs rows left to recover columns, else reports failure.
function TForm1.IncreaseClockTrunkColumn(ColIdx, ByCols: Integer): Boolean;
var
  DieWBlocks, MaxRowW, NewLaneW, Need: Integer;
  TightMax, PrevRight, X: Integer;
  b, i, Ci, n: Integer;
  RowCells: TArray<Integer>;
  Tmp: Integer;
  NewLane: TArray<Integer>;

  // Sorts the band's logic-row cell indices by X (insertion sort, stable).
  procedure SortRowByX;
  var
    a, b2: Integer;
  begin
    for a := 1 to n - 1 do
    begin
      Tmp := RowCells[a];
      b2 := a - 1;
      while (b2 >= 0) and
            (FPlacedComponents[RowCells[b2]].X > FPlacedComponents[Tmp].X) do
      begin
        RowCells[b2 + 1] := RowCells[b2];
        Dec(b2);
      end;
      RowCells[b2 + 1] := Tmp;
    end;
  end;

begin
  Result := False;
  // ColIdx: 0 = left feed bias lane, 1 = far-right bias lane.
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
  // Fits outright (far-left trunk 1 + rows + lane0 + trunk + lane1)?
  if MaxRowW + 1 + NewLaneW + FPlanTrunkW <= DieWBlocks then
  begin
    FBiasLaneW[ColIdx] := FBiasLaneW[ColIdx] + ByCols;
    RebuildFloorplanPreserve;
    Result := True;
    Exit;
  end;
  // Need to recover columns from the rows: pack each logic row's cells to the
  // left (knock-on nudge) and compute the tightest row width.
  Need := (MaxRowW + 1 + NewLaneW + FPlanTrunkW) - DieWBlocks;
  if Need < 1 then
    Need := 1;
  TightMax := 0;
  for b := 0 to High(FPlanBandStarts) do
  begin
    SetLength(RowCells, 0);
    for i := 0 to High(FPlacedComponents) do
      if (BandIndexOfY(FPlacedComponents[i].Y) = b) and
         (FPlacedComponents[i].Y >= BandLogicRowY(b)) and
         (FPlacedComponents[i].Y < BandLogicRowY(b) + FPlanRowHBlocks) then
      begin
        SetLength(RowCells, Length(RowCells) + 1);
        RowCells[High(RowCells)] := i;
      end;
    n := Length(RowCells);
    if n = 0 then
      Continue;
    SortRowByX;
    // Knock-on: pack left from XLeft with one-cell gaps.
    PrevRight := FPlanXLeft - 1;
    for Ci := 0 to n - 1 do
    begin
      X := FPlanXLeft;
      if PrevRight + 1 > X then
        X := PrevRight + 1;
      if FPlacedComponents[RowCells[Ci]].X > X then
        FPlacedComponents[RowCells[Ci]].X := X;
      FGatePlacement.AddOrSetValue(FPlacedComponents[RowCells[Ci]].Gate,
        TPoint.Create(FPlacedComponents[RowCells[Ci]].X,
          FPlacedComponents[RowCells[Ci]].Y));
      PrevRight := FPlacedComponents[RowCells[Ci]].X +
        FPlacedComponents[RowCells[Ci]].W;
    end;
    if PrevRight - FPlanXLeft + 1 > TightMax then
      TightMax := PrevRight - FPlanXLeft + 1;
  end;
  if MaxRowW - TightMax >= Need then
  begin
    // Recovered enough: shrink the row allocation, widen the lane, rebuild.
    FPlanMaxRowW := MaxRowW - Need;
    FBiasLaneW[ColIdx] := FBiasLaneW[ColIdx] + ByCols;
    RebuildFloorplanPreserve;
    Result := True;
  end
  else
  begin
    // Could not recover enough width. Rebuild so the (nudged) cell positions
    // match the floorplan grid, then report the failure.
    RebuildFloorplanPreserve;
    AddFloorplanError('no space for clock bias lines');
  end;
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

// Routes the horizontal bias lines: each partition group becomes one track at its
// own Y running left to the far-left trunk, tracks from both sides meeting in the middle.
procedure TForm1.RouteBiasLines;
var
  MaxUa: Double;
  NumBands, Band, g: Integer;
  LogicTopP, LogicBotP, ClockTopP, ClockBotP: TArray<TArray<TBiasPort>>;
  GA, GB: TArray<TBiasGroup>;
  Above, Below: TArray<TBiasPort>;
  Merged: Boolean;
  ChanY0, ChanY1: Integer; // channel row extent (top row .. bottom row+1)
  TrackY: Integer;
  Tr: TRoutedTrace;
  BiasLayer: string;
  TrunkPorts: TArray<TBiasPort>;
  TrackX, TurnY, ToX, TrunkL, TrunkR, TopRow, BotRow: Integer;

  procedure CollectLogic(Band: Integer; AEdge: TPortEdge;
    var APorts: TArray<TBiasPort>);
  var
    k: Integer;
  begin
    SetLength(APorts, 0);
    for k := 0 to High(FPlacedComponents) do
      if BandIndexOfY(FPlacedComponents[k].Y) = Band then
        CollectCellPorts(FPlacedComponents[k].Gate, FPlacedComponents[k].X,
          FPlacedComponents[k].Y, AEdge, APorts);
  end;

  procedure CollectClock(Band: Integer; AEdge: TPortEdge;
    var APorts: TArray<TBiasPort>);
  var
    L, ci: Integer;
  begin
    SetLength(APorts, 0);
    for L := 0 to High(FClockSubtree) do
      for ci := 0 to High(FClockSubtree[L]) do
        if (not FClockSubtree[L][ci].IsLeaf) and
           (BandIndexOfY(FClockSubtree[L][ci].Y) = Band) then
          CollectCellPorts(FClockSubtree[L][ci].Gate, FClockSubtree[L][ci].X,
            FClockSubtree[L][ci].Y, AEdge, APorts);
  end;

  // Emits one group's track at ATrackY: a horizontal run from the far-left trunk
  // to the rightmost port, with a vertical offshoot to each port.
  procedure EmitGroup(const AGrp: TBiasGroup; ATrackY: Integer;
    const ANetName: string);
  var
    k, px, py: Integer;
  begin
    if Length(AGrp.Ports) = 0 then
      Exit;
    Tr.NetName := ANetName;
    SetLength(Tr.Points, 0);
    // Start at the far-left bias trunk column (FPlanXLeft-1), on the track.
    SetLength(Tr.Points, 1);
    Tr.Points[0] := TPoint.Create(FPlanXLeft - 1, ATrackY);
    for k := 0 to High(AGrp.Ports) do
    begin
      px := AGrp.Ports[k].X;
      py := AGrp.Ports[k].Y;
      // Horizontal to the port's X, then the vertical offshoot to the port, then
      // back up onto the track (so the polyline stays on the track between ports).
      SetLength(Tr.Points, Length(Tr.Points) + 3);
      Tr.Points[High(Tr.Points) - 2] := TPoint.Create(px, ATrackY);
      Tr.Points[High(Tr.Points) - 1] := TPoint.Create(px, py);
      Tr.Points[High(Tr.Points)] := TPoint.Create(px, ATrackY);
    end;
    SetLength(Tr.Layers, Length(Tr.Points));
    for k := 0 to High(Tr.Layers) do
      Tr.Layers[k] := BiasLayer;
    SetLength(FRouteTraces, Length(FRouteTraces) + 1);
    FRouteTraces[High(FRouteTraces)] := Tr;
  end;

  // Emits the merged edge case as one bias line at the top group's track, with
  // every port (top and bottom) branching off a short stub.
  procedure EmitMergedT(const ATopGrp, ABottomGrp: TBiasGroup;
    ASharedY: Integer; const ANetName: string);
  var
    Combined: TArray<TBiasPort>;
    k, j, px, py: Integer;
    Tmp: TBiasPort;
  begin
    // Combine both groups' ports into one list, ordered left to right so the
    // line never doubles back.
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
    Tr.NetName := ANetName;
    SetLength(Tr.Points, 0);
    // One line from the far-left trunk to the farthest-right port.
    SetLength(Tr.Points, 1);
    Tr.Points[0] := TPoint.Create(FPlanXLeft - 1, ASharedY);
    for k := 0 to High(Combined) do
    begin
      px := Combined[k].X;
      py := Combined[k].Y;
      // Branch to each port (down for top ports, up for bottom ports) and back.
      SetLength(Tr.Points, Length(Tr.Points) + 3);
      Tr.Points[High(Tr.Points) - 2] := TPoint.Create(px, ASharedY);
      Tr.Points[High(Tr.Points) - 1] := TPoint.Create(px, py);
      Tr.Points[High(Tr.Points)] := TPoint.Create(px, ASharedY);
    end;
    SetLength(Tr.Layers, Length(Tr.Points));
    for k := 0 to High(Tr.Layers) do
      Tr.Layers[k] := BiasLayer;
    SetLength(FRouteTraces, Length(FRouteTraces) + 1);
    FRouteTraces[High(FRouteTraces)] := Tr;
  end;

  // Emits one clock-bias group as a vertical track at ATrackX tapping each port,
  // plus a horizontal run left to AToX (the far-left trunk), which it joins.
  procedure EmitClockGroup(const AGrp: TBiasGroup; ATrackX, ATurnY, AToX: Integer;
    const ANetName: string);
  var
    k, px, py: Integer;
  begin
    if Length(AGrp.Ports) = 0 then
      Exit;
    Tr.NetName := ANetName;
    SetLength(Tr.Points, 0);
    // Start at the merge point on the full-width bias row, run to the track.
    SetLength(Tr.Points, 1);
    Tr.Points[0] := TPoint.Create(AToX, ATurnY);
    SetLength(Tr.Points, Length(Tr.Points) + 1);
    Tr.Points[High(Tr.Points)] := TPoint.Create(ATrackX, ATurnY);
    // Walk the vertical track, tapping into each port.
    for k := 0 to High(AGrp.Ports) do
    begin
      px := AGrp.Ports[k].X;
      py := AGrp.Ports[k].Y;
      SetLength(Tr.Points, Length(Tr.Points) + 3);
      Tr.Points[High(Tr.Points) - 2] := TPoint.Create(ATrackX, py);
      Tr.Points[High(Tr.Points) - 1] := TPoint.Create(px, py);
      Tr.Points[High(Tr.Points)] := TPoint.Create(ATrackX, py);
    end;
    SetLength(Tr.Layers, Length(Tr.Points));
    for k := 0 to High(Tr.Layers) do
      Tr.Layers[k] := BiasLayer;
    SetLength(FRouteTraces, Length(FRouteTraces) + 1);
    FRouteTraces[High(FRouteTraces)] := Tr;
  end;

begin
  RefreshDesignConfig;
  if not FFloorplanValid then
    Exit;
  MaxUa := FDesignConfig.MaxBiasCurrentUa;
  if MaxUa <= 0 then
    Exit;
  // Bias lines are drawn on the user-chosen bias layer (added to FRoutingLayers
  // for its colour/toggle); fall back to the primary signal layer.
  BuildRoutingLayers;
  BiasLayer := FBiasLayer;
  if BiasLayer = '' then
    BiasLayer := FRouteSignalLayer;
  if BiasLayer = '' then
    Exit;
  NumBands := Length(FPlanBandStarts);
  if NumBands < 1 then
    Exit;
  // Collect each side's ports once.
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

  // Topmost full-width row: band 0's logic row top ports, tracks stepping UP
  // from the cells. Channel rows: [FPlanBandStarts[0], BandLogicRowY(0)).
  GA := PartitionBiasPorts(LogicTopP[0], MaxUa);
  ChanY1 := BandLogicRowY(0);
  for g := 0 to High(GA) do
  begin
    TrackY := ChanY1 - 1 - g; // group 1 hugs the cells, then steps up
    EmitGroup(GA[g], TrackY, Format(BiasPrefix + 'topmost_g%d', [g + 1]));
  end;

  // Bottommost full-width row: the last band's clock row bottom ports, tracks
  // stepping DOWN from the cells. Channel rows: [end of last clock row, +1+FBottomBiasH).
  GA := PartitionBiasPorts(ClockBotP[NumBands - 1], MaxUa);
  ChanY0 := BandClockRowY(NumBands - 1) + FPlanRowHBlocks;
  if NumBands - 1 < Length(FClockRowExtra) then
    ChanY0 := ChanY0 + FClockRowExtra[NumBands - 1];
  for g := 0 to High(GA) do
  begin
    TrackY := ChanY0 + g; // group 1 hugs the cells, then steps down
    EmitGroup(GA[g], TrackY, Format(BiasPrefix + 'bottom_g%d', [g + 1]));
  end;

  // Interior channels.
  for Band := 0 to NumBands - 1 do
  begin
    // MIDDLE bias row: logic bottom (above) meets clock top (below) in the
    // channel [BandLogicRowY+RowH, BandClockRowY); tracks meet in the middle.
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
    // Logic side: group g is g-1 rows below the logic cells. The last group is
    // the shared line when the edge case merges it with the clock side's last.
    for g := 0 to High(GA) do
    begin
      if Merged and (g = High(GA)) then
        Continue; // emitted with the T below
      TrackY := ChanY0 + g;
      EmitGroup(GA[g], TrackY, Format(BiasPrefix + 'b%d_mid_lg%d', [Band, g + 1]));
    end;
    // Clock side: group g is g-1 rows above the clock cells.
    for g := 0 to High(GB) do
    begin
      if Merged and (g = High(GB)) then
        Continue; // emitted with the T below
      TrackY := ChanY1 - 1 - g;
      EmitGroup(GB[g], TrackY, Format(BiasPrefix + 'b%d_mid_cl%d', [Band, g + 1]));
    end;
    // Merged edge case: one bias line at the top (logic) group's last track,
    // with both groups' ports branching off it.
    if Merged then
      EmitMergedT(GA[High(GA)], GB[High(GB)], ChanY0 + High(GA),
        Format(BiasPrefix + 'b%d_mid_merged', [Band]));

    // TOP bias row (band > 0): previous band's clock bottom (above) + this
    // band's logic top (below). Channel rows: [FPlanBandStarts[Band], BandLogicRowY(Band)).
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
      // Clock side above: group g is g-1 rows below the previous clock row.
      for g := 0 to High(GA) do
      begin
        if Merged and (g = High(GA)) then
          Continue; // emitted with the T below
        TrackY := ChanY0 + g;
        EmitGroup(GA[g], TrackY, Format(BiasPrefix + 'b%d_top_cl%d', [Band, g + 1]));
      end;
      // Logic side below: group g is g-1 rows above this logic row.
      for g := 0 to High(GB) do
      begin
        if Merged and (g = High(GB)) then
          Continue; // emitted with the T below
        TrackY := ChanY1 - 1 - g;
        EmitGroup(GB[g], TrackY, Format(BiasPrefix + 'b%d_top_lg%d', [Band, g + 1]));
      end;
      // Merged edge case: one bias line at the top (clock) group's last track,
      // with both groups' ports branching off it.
      if Merged then
        EmitMergedT(GA[High(GA)], GB[High(GB)], ChanY0 + High(GA),
          Format(BiasPrefix + 'b%d_top_merged', [Band]));
    end;
  end;

  // --- Clock bias lines (vertical) ---
  // Trunk ports become vertical tracks in the flanking lane (group 1 hugging the
  // trunk), each turning into the topmost/bottommost full-width bias row.
  TrunkL := FPlanXRight + FPlanLane0W;                 // green trunk left edge
  TrunkR := FPlanXRight + FPlanLane0W + FPlanTrunkW;   // green trunk right edge
  TopRow := FPlanBandStarts[0];                        // very top of the stack
  BotRow := FPlanBandStarts[NumBands - 1] +
    FPlanBandHeight[NumBands - 1] + FBottomBiasH;      // bottom of bottom bias row
  // Left side: top-to-bottom groups, tracks step left, turn rows step down.
  CollectTrunkPorts(True, TrunkPorts);
  GA := PartitionTrunkPorts(TrunkPorts, MaxUa, False);
  for g := 0 to High(GA) do
  begin
    TrackX := TrunkL - 1 - g;   // group 1 hugs the trunk, then steps left
    TurnY := TopRow + g;        // group 1 at the very top, then one lower
    ToX := FPlanXLeft - 1;      // run left to the far-left bias trunk
    EmitClockGroup(GA[g], TrackX, TurnY, ToX, Format(BiasPrefix + 'clkL_g%d', [g + 1]));
  end;
  // Right side: topmost group turns at BotRow (lowest), later groups one higher,
  // and tracks step left so a later high run never crosses an earlier track.
  CollectTrunkPorts(False, TrunkPorts);
  GB := PartitionTrunkPorts(TrunkPorts, MaxUa, False);
  for g := 0 to High(GB) do
  begin
    TrackX := TrunkR + (High(GB) - g); // topmost group farthest right, stepping left
    TurnY := BotRow - g;               // group 1 (topmost) at the very bottom, then one higher
    ToX := FPlanXLeft - 1;             // run left to the far-left bias trunk
    EmitClockGroup(GB[g], TrackX, TurnY, ToX, Format(BiasPrefix + 'clkR_g%d', [g + 1]));
  end;

  // The far-left bias trunk itself: a single vertical wire on the trunk column
  // (FPlanXLeft-1) that every bias line branches from. It spans the full stack,
  // from the topmost bias row to the bottom of the bottom-most bias row.
  SetLength(Tr.Points, 2);
  Tr.Points[0] := TPoint.Create(FPlanXLeft - 1, FPlanBandStarts[0]);
  Tr.Points[1] := TPoint.Create(FPlanXLeft - 1,
    FPlanBandStarts[NumBands - 1] + FPlanBandHeight[NumBands - 1] +
    1 + FBottomBiasH);
  SetLength(Tr.Layers, 2);
  Tr.Layers[0] := BiasLayer;
  Tr.Layers[1] := BiasLayer;
  Tr.NetName := UNetNaming.BiasTrunkName;
  SetLength(FRouteTraces, Length(FRouteTraces) + 1);
  FRouteTraces[High(FRouteTraces)] := Tr;

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
      L := FRoutingLayers.IndexOf(FRouteTraces[ATraceIdx].Layers[ii]);
      if (L >= 0) and (L <= High(FRouteObstacles)) then
        FRouteObstacles[L][Pt.Y * FRouteObstaclesW + Pt.X] := True;
    end;
  end;
end;

// Removes one trace's cells from the obstacle maps (the inverse of BlockTrace),
// freeing the space so a re-route can use it.
procedure TForm1.UnblockTrace(ATraceIdx: Integer);
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
      L := FRoutingLayers.IndexOf(FRouteTraces[ATraceIdx].Layers[ii]);
      if (L >= 0) and (L <= High(FRouteObstacles)) then
        FRouteObstacles[L][Pt.Y * FRouteObstaclesW + Pt.X] := False;
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
  UnblockTrace(ATraceIdx); // free the current wire's space for the search
  FoundAny := False;
  BestLen := MaxDouble;
  BestPath := nil;
  BestLayers := nil;
  for L := 0 to High(FRouteLayers) do
    if LeeRoute(Start, Goal, L, Path, Layers) then
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
  if LeeRoute(Start, Goal, -1, Path, Layers) then
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

// Re-applies each validation buffer's slot after a floorplan rebuild: signal
// buffers rejoin FPlacedComponents, clock buffers move within FClockSubtree.
procedure TForm1.ReapplyValidationBuffers;
var
  i, i2, W, H, Y, X: Integer;
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
    VB.X := X;
    VB.Y := Y;
    FValidationBuffers[i] := VB;

    if VB.IsClock then
    begin
      Found := False;
      for L := 0 to High(FClockSubtree) do
        for ci := 0 to High(FClockSubtree[L]) do
          if FClockSubtree[L][ci].Gate = VB.Gate then
          begin
            FClockSubtree[L][ci].X := X;
            FClockSubtree[L][ci].Y := Y;
            Found := True;
            Break;
          end;
      if Found then
        FGatePlacement.AddOrSetValue(VB.Gate, TPoint.Create(X, Y));
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
        P.InstanceName := Format('%s_vb', [VB.Gate.CellName]);
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
procedure TForm1.RunBiasExpansionAndRouting;
var
  Saved, Report: TStringList;
begin
  ButtonExpandBiasClick(nil);
  ReapplyValidationBuffers;
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
end;

// Splits NetName at LoadPin with a min-delay buffer at the given slot and re-runs
// the expansion + routing; reverts the netlist and returns False if it won't route.
function TForm1.TryInsertBuffer(IsClock: Boolean; const NetName: string;
  Driver, Load: TGateInstance; const DriverPin, LoadPin: string;
  APadLoad: Boolean;
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

    RunBiasExpansionAndRouting;
    if FFlowStage >= fsRouted then
    begin
      MemoRouting.Lines.Add(Format(
        '  buffer %s inserted on %s (band %d, row %d, x %d, y %d).',
        [BufCell.Name, NetName, ABand, ARowType, AX, AY]));
      Result := True;
      Exit;
    end;

    // The circuit no longer routes with the buffer there: revert the netlist.
    Model.Gates.Remove(BufGate);
    BufGate.Free;
    Model.Nets.Remove(NewNetName);
    Net.Connections.Clear;
    Net.Connections.AddRange(OrigConn);
    SetLength(FValidationBuffers, Length(FValidationBuffers) - 1);
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
  Src, Dst, Pt: TPoint;
  ClkPos: TDictionary<TGateInstance, TPoint>;
  ClkRot: TDictionary<TGateInstance, Boolean>;
  Sp: TSpineComponent;
  Node: TPlacedClockNode;
  L, ci, k: Integer;
  NumBands, Band, RowType, X, Y, W, H, Bx, By: Integer;
  TrunkX0, StackTop, StackBottom: Integer;
  Cands: TArray<TCand>;
  C, TmpC: TCand;
  a, b: Integer;
  Key: string;
  Overlap: Boolean;

  // Evaluates slot (X, Y) for the current (Band, RowType): rejects overlap with a
  // placed cell or endpoint pin (routed wires ignored - all is re-routed), else records it.
  procedure Consider(X, Y: Integer);
  var
    i2, L, ci, k: Integer;
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
    Overlap := False;
    for i2 := 0 to High(FPlacedComponents) do
      if UGeometry.RectOverlap(X, Y, W, H, FPlacedComponents[i2].X,
        FPlacedComponents[i2].Y, FPlacedComponents[i2].W,
        FPlacedComponents[i2].H) then
      begin
        Overlap := True;
        Break;
      end;
    if not Overlap then
      for L := 0 to High(FClockSubtree) do
        for ci := 0 to High(FClockSubtree[L]) do
          if (not FClockSubtree[L][ci].IsLeaf) and
             UGeometry.RectOverlap(X, Y, W, H, FClockSubtree[L][ci].X,
               FClockSubtree[L][ci].Y, FClockSubtree[L][ci].W,
               FClockSubtree[L][ci].H) then
          begin
            Overlap := True;
            Break;
          end;
    if not Overlap then
      for k := 0 to High(FSpine) do
        if UGeometry.RectOverlap(X, Y, W, H, FSpine[k].X, FSpine[k].Y,
          FSpine[k].W, FSpine[k].H) then
        begin
          Overlap := True;
          Break;
        end;
    if Overlap then
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
        if not ClkPos.ContainsKey(NC.Gate) then
          Continue;
        if GatePinBlockAt(NC.Gate, NC.PinName, 0,
          ClkPos[NC.Gate].X, ClkPos[NC.Gate].Y, ClkRot[NC.Gate], Pt) and
           (Pt.X = Dst.X) and (Pt.Y = Dst.Y) then
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

  // Buffer footprint in grid cells.
  W := Round(BufCell.Width / Core);
  if W < 1 then
    W := 1;
  H := Round(BufCell.Height / Core);
  if H < 1 then
    H := 1;

  // Enumerate every free slot and score by residual reach: logic rows, clock rows
  // and the trunk column (the last space when rows are packed). Wires are ignored.
  NumBands := Length(FPlanBandStarts);
  TrunkX0 := FPlanXRight + FPlanLane0W;
  StackTop := 0;
  StackBottom := 0;
  if NumBands > 0 then
  begin
    StackTop := FPlanBandStarts[0];
    StackBottom := FPlanBandStarts[NumBands - 1] +
      FPlanBandHeight[NumBands - 1] + FBottomBiasH;
  end;
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
  // Clock trunk column: the trunk cells are rotated and centred in a column of
  // width FPlanRowHBlocks, so free space remains beside them; the buffer's
  // width (unrotated) must fit the column and its height the stack.
  if (W <= FPlanRowHBlocks) and (H <= StackBottom - StackTop) then
  begin
    Band := -1;
    RowType := 2;
    for X := TrunkX0 to TrunkX0 + FPlanRowHBlocks - W do
      for Y := StackTop to StackBottom - H do
        Consider(X, Y);
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
      IsPadLoad, BufCell, InPin, OutPin, C.Band, C.RowType, C.X, C.Y) then
    begin
      Result := True;
      Exit;
    end;
    FValidationBlocked.Add(Format('%d:%d:%d:%d', [C.Band, C.RowType, C.X, C.Y]));
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
  Pt0, Pt1: TPoint;
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
    BuildFloorplan;
    RunRouting;
  end;
  if FPlacementModel <> nil then
  begin
    FOwnedPlacementModel := FPlacementModel.Clone;
    FPlacementModel := FOwnedPlacementModel;
    // Rebuild the placement maps against the CLONE's gates so resolution and
    // overlap checks see the mutated netlist (content-equal, layout still lines up).
    BuildFloorplan;
    if FFloorplanErrorCount = 0 then
      OptimizePlacement;
  end;
  // A fresh validation session: the buffers inserted on a previous run stay in
  // the netlist (they are now part of the circuit) but are re-applied fresh.
  FValidationBuffers := nil;
  FValidationBlocked.Clear;
  MemoRouting.Lines.Add('--- Routing validation ---');
  MemoRouting.Lines.Add(Format('PTL length limit: %s um', [EditPTLLength.Text]));

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
        RepaintRoutingPage;
        Continue; // re-scan; other over-limit wires are fixed next
      end
      else
        MemoRouting.Lines.Add('    re-route did not reach the limit; inserting a buffer.');
    end;

    if not InsertBufferForTrace(BestIdx) then
    begin
      MemoRouting.Lines.Add(Format(
        'VALIDATION FAILED: no usable buffer location on %s.',
        [FRouteTraces[BestIdx].NetName]));
      if FFlowStage < fsValidated then FFlowStage := fsValidated;
      RepaintRoutingPage;
      Exit;
    end;
    // InsertBufferForTrace re-ran the bias expansion + routing; re-scan.
    RepaintRoutingPage;
  until False;

  MemoRouting.Lines.Add('All PTL lengths are within the limit.');
  if FFlowStage < fsValidated then FFlowStage := fsValidated;
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
begin
  if Length(FRouteTraces) = 0 then
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
  var OutPath: TArray<TPoint>; var OutLayers: TArray<Integer>): Boolean;
const
  DirDx: array[0..3] of Integer = (1, -1, 0, 0);
  DirDy: array[0..3] of Integer = (0, 0, 1, -1);
  DirCount = 5;    // states per cell-layer: Dir+1 in 0..4 (0 = no direction)
  MinMargin = 16;  // minimum window margin in blocks
  MaxMargin = 128; // maximum window margin in blocks
  MarginDiv = 3;   // margin = max(MinMargin, dist div MarginDiv)
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
  ResonanceOn := (CoreUm > 0) and (FreqGHz > 0) and (Delay > 0) and (PulseWUm > 0);
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
    for L := 0 to NumLayers - 1 do
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
    // The heading is unchanged, so no turn penalty applies.
    if UseLayer < 0 then
      for L := 0 to NumLayers - 1 do
      begin
        if L = CurLayer then
          Continue;
        if FRouteObstacles[L][CurY * W + CurX] and
           not ((CurX = Goal.X) and (CurY = Goal.Y)) then
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
