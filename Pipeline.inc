// Pipeline: cached layout, the (culled, batched) pipeline painter, the pipeline
// model and the mode/limit/slider UI. Included from MainWindow's implementation
// via {$I Pipeline.inc}.
procedure TForm1.FreePipelineRows;
var
  i: Integer;
begin
  for i := 0 to High(FPipelineRows) do
    FPipelineRows[i].Free;
  FPipelineRows := nil;
  FPipeGridPos.Free;
  FPipeGridPos := nil;
  FPipeInputCol.Free;
  FPipeInputCol := nil;
  FPipeOutGrid.Free;
  FPipeOutGrid := nil;
  FPipeLevelDepth := nil;
  FPipeLevelYOff := nil;
  FPipeHasGateRow := nil;
  FPipeArea := 0;
  FPipeWorstPath := 0;
  FPipeRowsModel := nil;
end;

// Builds everything the pipeline page draws that does NOT depend on zoom or pan:
// the rows per clock level, each gate's tree position, the input columns and
// output grid positions, the per-level extents and the aggregate area / worst
// path. The painter re-projects this, so panning and the slider never rebuild
// or re-walk the whole circuit.
procedure TForm1.BuildPipelineRows(const AModel: TBlifModel);
var
  Gate: TGateInstance;
  i, j, k: Integer;
  MaxLevel, MaxRows, MaxOutputLevel: Integer;
  MaxCol, GridCol, MaxDepth, YOff, OutLevel: Integer;
  OutName: string;
  InputNets, OutputNets: TStringList;
  OutputLevels: TList<Integer>;
  LevelMaxDepth, LevelCols: TList<Integer>;
  Placed: TDictionary<TGateInstance, Boolean>;
  OutColCount: TDictionary<Integer, Integer>;
  GatePair: TPair<TGateInstance, TPoint>;
  PtTmp: TPoint;
  Conn: TPinConnection;
  NNet: TNet;
  NC: TNetConnection;
  HasParent: Boolean;
  DelayMemo: TDictionary<TGateInstance, Double>;
  Dly: Double;

  // True if G has a non-clock data input on the given net.
  function GateUsesNet(G: TGateInstance; const ANetName: string): Boolean;
  var
    kk: Integer;
    CC: TPinConnection;
  begin
    Result := False;
    for kk := 0 to G.Connections.Count - 1 do
    begin
      CC := G.Connections[kk];
      if CC.Port.Direction <> pdInput then
        Continue;
      if IsClockPinName(CC.Port.Name) then
        Continue;
      if SameText(CC.NetName, ANetName) then
        Exit(True);
    end;
  end;

  // Depth-first tree layout within one clock level.
  procedure DFSLayout(AGate: TGateInstance; Depth, BaseCol: Integer);
  var
    C: TPinConnection;
    N: TNet;
    NCC: TNetConnection;
    ParentCol: Integer;
  begin
    if Placed.ContainsKey(AGate) then
      Exit;
    while LevelCols.Count <= Depth do
      LevelCols.Add(0);
    if LevelCols[Depth] < BaseCol then
      LevelCols[Depth] := BaseCol;
    ParentCol := LevelCols[Depth];
    FPipeGridPos.Add(AGate, TPoint.Create(ParentCol, Depth));
    Placed.Add(AGate, True);
    LevelCols[Depth] := ParentCol + 1;
    for C in AGate.Connections do
    begin
      if C.Port.Direction <> pdOutput then
        Continue;
      if not AModel.Nets.TryGetValue(C.NetName, N) then
        Continue;
      for NCC in N.Connections do
        if (not NCC.IsDriver) and (NCC.Gate.ClockLevel = AGate.ClockLevel) then
          DFSLayout(NCC.Gate, Depth + 1, ParentCol);
    end;
    if Depth + 1 < LevelCols.Count then
      if LevelCols[Depth] < LevelCols[Depth + 1] then
        LevelCols[Depth] := LevelCols[Depth + 1];
  end;

  // Length of the worst combinational path from a clocked boundary to G.
  function DelayToOutput(G: TGateInstance): Double;
  var
    MaxIn, Dly2: Double;
    m: Integer;
    C: TPinConnection;
    N: TNet;
    NC2: TNetConnection;
  begin
    if DelayMemo.TryGetValue(G, Result) then
      Exit;
    if CellHasClock(G.Cell) then
    begin
      Dly2 := CellDelayPs(G.Cell);
      if Dly2 < 0 then
        Dly2 := 0;
      Result := Dly2;
      DelayMemo.Add(G, Result);
      Exit;
    end;
    MaxIn := 0;
    for m := 0 to G.Connections.Count - 1 do
    begin
      C := G.Connections[m];
      if C.Port.Direction <> pdInput then
        Continue;
      if IsClockPinName(C.Port.Name) then
        Continue;
      if AModel.Nets.TryGetValue(C.NetName, N) then
        for NC2 in N.Connections do
          if NC2.IsDriver then
          begin
            Dly2 := DelayToOutput(NC2.Gate);
            if Dly2 > MaxIn then
              MaxIn := Dly2;
          end;
    end;
    Dly2 := CellDelayPs(G.Cell);
    if Dly2 < 0 then
      Dly2 := 0;
    Result := MaxIn + Dly2;
    DelayMemo.Add(G, Result);
  end;

begin
  FreePipelineRows;
  FPipeRowsModel := AModel;
  if (AModel = nil) or (AModel.Gates.Count = 0) then
    Exit;
  MaxLevel := -1;
  for Gate in AModel.Gates do
    if (Gate.ClockLevel >= 0) and (Gate.ClockLevel > MaxLevel) then
      MaxLevel := Gate.ClockLevel;
  if MaxLevel < 0 then
    Exit;
  SetLength(FPipelineRows, MaxLevel + 1);
  for i := 0 to MaxLevel do
    FPipelineRows[i] := TList<TGateInstance>.Create;
  for Gate in AModel.Gates do
    if Gate.ClockLevel >= 0 then
      FPipelineRows[Gate.ClockLevel].Add(Gate);

  InputNets := TStringList.Create;
  OutputNets := TStringList.Create;
  OutputLevels := TList<Integer>.Create;
  LevelMaxDepth := TList<Integer>.Create;
  LevelCols := TList<Integer>.Create;
  Placed := TDictionary<TGateInstance, Boolean>.Create;
  FPipeGridPos := TDictionary<TGateInstance, TPoint>.Create;
  FPipeInputCol := TDictionary<string, Integer>.Create;
  FPipeOutGrid := TDictionary<string, TPoint>.Create;
  try
    // Primary inputs (level 0), skipping the clock net.
    for i := 0 to AModel.Inputs.Count - 1 do
      if not SameText(AModel.Inputs[i], UNetNaming.ClockRootName) then
        InputNets.Add(AModel.Inputs[i]);

    // Primary outputs with their clock level (driver level + 1).
    MaxOutputLevel := 0;
    for i := 0 to AModel.Outputs.Count - 1 do
    begin
      OutName := AModel.Outputs[i];
      if AModel.Nets.TryGetValue(OutName, NNet) then
      begin
        OutLevel := 0;
        for NC in NNet.Connections do
          if NC.IsDriver then
          begin
            OutLevel := NC.Gate.ClockLevel + 1;
            Break;
          end;
        OutputNets.Add(OutName);
        OutputLevels.Add(OutLevel);
        if OutLevel > MaxOutputLevel then
          MaxOutputLevel := OutLevel;
      end;
    end;

    MaxRows := Length(FPipelineRows);
    if MaxOutputLevel >= MaxRows then
      MaxRows := MaxOutputLevel + 1;
    if MaxRows = 0 then
      MaxRows := 1;

    // Tree layout within each clock level.
    for i := 0 to High(FPipelineRows) do
    begin
      LevelCols.Clear;
      LevelCols.Add(0);
      Placed.Clear;

      if (i = 0) and (InputNets.Count > 0) then
      begin
        // Level 0: primary inputs are the roots; each claims a row-0 column and
        // pushes the next input right, like the general tree layout.
        for j := 0 to InputNets.Count - 1 do
        begin
          GridCol := LevelCols[0];
          FPipeInputCol.AddOrSetValue(InputNets[j], GridCol);
          LevelCols[0] := LevelCols[0] + 1;
          for k := 0 to FPipelineRows[i].Count - 1 do
          begin
            Gate := FPipelineRows[i][k];
            if Placed.ContainsKey(Gate) then
              Continue;
            if not GateUsesNet(Gate, InputNets[j]) then
              Continue;
            HasParent := False;
            for Conn in Gate.Connections do
            begin
              if Conn.Port.Direction <> pdInput then
                Continue;
              if IsClockPinName(Conn.Port.Name) then
                Continue;
              if not AModel.Nets.TryGetValue(Conn.NetName, NNet) then
                Continue;
              for NC in NNet.Connections do
                if NC.IsDriver and (NC.Gate.ClockLevel = i) then
                begin
                  HasParent := True;
                  Break;
                end;
              if HasParent then
                Break;
            end;
            if HasParent then
              Continue;
            DFSLayout(Gate, 1, GridCol);
          end;
          // Push the input row right to cover the subtree just placed.
          if LevelCols.Count > 1 then
            if LevelCols[0] < LevelCols[1] then
              LevelCols[0] := LevelCols[1];
        end;
        // Remaining level-0 gates (cycles or disconnected).
        for k := 0 to FPipelineRows[i].Count - 1 do
        begin
          Gate := FPipelineRows[i][k];
          if not Placed.ContainsKey(Gate) then
            DFSLayout(Gate, 1, LevelCols[0]);
        end;
      end
      else
      begin
        // Other levels: ordinary roots at the level's top row.
        for j := 0 to FPipelineRows[i].Count - 1 do
        begin
          Gate := FPipelineRows[i][j];
          if Placed.ContainsKey(Gate) then
            Continue;
          HasParent := False;
          for Conn in Gate.Connections do
          begin
            if Conn.Port.Direction <> pdInput then
              Continue;
            if IsClockPinName(Conn.Port.Name) then
              Continue;
            if not AModel.Nets.TryGetValue(Conn.NetName, NNet) then
              Continue;
            for NC in NNet.Connections do
              if NC.IsDriver and (NC.Gate.ClockLevel = i) then
              begin
                HasParent := True;
                Break;
              end;
            if HasParent then
              Break;
          end;
          if not HasParent then
            DFSLayout(Gate, 0, 0);
        end;
        // Remaining gates (cycles or disconnected).
        for j := 0 to FPipelineRows[i].Count - 1 do
        begin
          Gate := FPipelineRows[i][j];
          if not Placed.ContainsKey(Gate) then
            DFSLayout(Gate, 0, 0);
        end;
      end;

      // Rows used by this level.
      MaxDepth := 0;
      for j := 0 to FPipelineRows[i].Count - 1 do
      begin
        Gate := FPipelineRows[i][j];
        if FPipeGridPos.TryGetValue(Gate, PtTmp) then
          if PtTmp.Y > MaxDepth then
            MaxDepth := PtTmp.Y;
      end;
      LevelMaxDepth.Add(MaxDepth + 1);
    end;

    // Cumulative first-row offset per level, with a gap between levels.
    while LevelMaxDepth.Count < MaxRows do
      LevelMaxDepth.Add(1);
    SetLength(FPipeLevelDepth, LevelMaxDepth.Count);
    SetLength(FPipeLevelYOff, LevelMaxDepth.Count);
    SetLength(FPipeHasGateRow, LevelMaxDepth.Count);
    YOff := 0;
    for i := 0 to LevelMaxDepth.Count - 1 do
    begin
      FPipeLevelDepth[i] := LevelMaxDepth[i];
      FPipeLevelYOff[i] := YOff;
      FPipeHasGateRow[i] := False;
      Inc(YOff, LevelMaxDepth[i] + 1);
    end;
    for i := 0 to AModel.Gates.Count - 1 do
      if (AModel.Gates[i].ClockLevel >= 0) and
         (AModel.Gates[i].ClockLevel < Length(FPipeHasGateRow)) then
        FPipeHasGateRow[AModel.Gates[i].ClockLevel] := True;

    // Output grid positions: one column past the widest gate column of the
    // level, stacked right for several outputs on the same level.
    OutColCount := TDictionary<Integer, Integer>.Create;
    try
      for j := 0 to OutputLevels.Count - 1 do
      begin
        OutLevel := OutputLevels[j];
        MaxCol := 0;
        for GatePair in FPipeGridPos do
          if GatePair.Key.ClockLevel = OutLevel then
          begin
            GridCol := GatePair.Value.X;
            if GridCol + 1 > MaxCol then
              MaxCol := GridCol + 1;
          end;
        if OutColCount.TryGetValue(OutLevel, i) then
          GridCol := MaxCol + i
        else
          GridCol := MaxCol;
        OutColCount.AddOrSetValue(OutLevel, GridCol - MaxCol + 1);
        FPipeOutGrid.AddOrSetValue(OutputNets[j], TPoint.Create(GridCol, OutLevel));
      end;
    finally
      OutColCount.Free;
    end;

    // Stats: total area and the worst per-level combinational path.
    DelayMemo := TDictionary<TGateInstance, Double>.Create;
    try
      FPipeArea := 0;
      for i := 0 to High(FPipelineRows) do
        for j := 0 to FPipelineRows[i].Count - 1 do
          FPipeArea := FPipeArea +
            FPipelineRows[i][j].Cell.Width * FPipelineRows[i][j].Cell.Height;
      FPipeWorstPath := 0;
      for i := 0 to High(FPipelineRows) do
        for j := 0 to FPipelineRows[i].Count - 1 do
        begin
          Dly := DelayToOutput(FPipelineRows[i][j]);
          if Dly > FPipeWorstPath then
            FPipeWorstPath := Dly;
        end;
    finally
      DelayMemo.Free;
    end;
  finally
    InputNets.Free;
    OutputNets.Free;
    OutputLevels.Free;
    LevelMaxDepth.Free;
    LevelCols.Free;
    Placed.Free;
  end;
end;

procedure TForm1.PaintPipeline(Sender: TObject; Canvas: TCanvas);
var
  R, NoteR, StatsR: TRectF;
  i, j: Integer;
  ClipState: TCanvasSaveState;
  Gate, Src: TGateInstance;
  Square, HGap, VGap, Left, X, Y: Single;
  Color: TAlphaColor;
  ActiveModel: TBlifModel;
  Note, StatsText: string;
  GateCenters: TDictionary<TGateInstance, TPointF>;
  InputPositions, OutputPositions: TDictionary<string, TPointF>;
  SrcPt, DstPt: TPointF;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  Pt: TPoint;
  InCol: Integer;
  WirePath: TPathData;
  WireCount: Integer;
  DrawCells: Boolean;

  // True when the square whose top-left is (AX, AY) touches the canvas.
  function OnScreen(const AX, AY: Single): Boolean;
  begin
    Result := (AX + Square >= 0) and (AX <= PaintBox1.Width) and
              (AY + Square >= 0) and (AY <= PaintBox1.Height);
  end;

  procedure AddWire(const AFrom, ATo: TPointF);
  begin
    WirePath.MoveTo(AFrom);
    WirePath.LineTo(ATo);
    Inc(WireCount);
  end;

begin
  R := TRectF.Create(0, 0, PaintBox1.Width, PaintBox1.Height);
  Canvas.Fill.Color := TAlphaColorRec.White;
  Canvas.FillRect(R, 0, 0, [], 1.0);

  ActiveModel := FModel;
  if FPipelineModel <> nil then
    ActiveModel := FPipelineModel;

  Note := '';
  if (ActiveModel <> nil) and (FFlipFlopNames.Count = 0) then
    Note := 'No flip-flop cells selected on the Flip-flops page.';

  ClipState := Canvas.SaveState;
  try
    Canvas.IntersectClipRect(R);
    if ActiveModel = nil then
    begin
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(R, 'No netlist loaded.', False, 1.0, [],
        TTextAlign.Center, TTextAlign.Center);
      Exit;
    end;

    // The layout does not depend on zoom or pan: rebuild only when the model
    // changes, so panning never re-walks the circuit.
    if FPipeRowsModel <> ActiveModel then
      BuildPipelineRows(ActiveModel);

    if Note <> '' then
    begin
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      NoteR := TRectF.Create(4, 4, PaintBox1.Width - 4, 24);
      Canvas.FillText(NoteR, Note, False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);
    end;

    HGap := 4 * FZoom;
    VGap := 4 * FZoom;
    Left := 40 * FZoom;
    Square := 18 * FZoom;
    // Zoomed far out the cells are sub-pixel noise: skip them and the wires
    // entirely (the level labels and the stats line still describe the design).
    DrawCells := (FZoom > 0) and (Square >= MinBlockPx);

    // Level labels, culled vertically.
    for i := 0 to High(FPipeLevelDepth) do
    begin
      if (i > 0) and (not FPipeHasGateRow[i]) then
        Continue; // output-pad row: not a clock level
      Y := FPanY + 4 * FZoom + FPipeLevelYOff[i] * (Square + VGap);
      if (Y > PaintBox1.Height) or (Y + Square < 0) then
        Continue;
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(TRectF.Create(FPanX, Y, FPanX + Left - 6 * FZoom, Y + Square),
        IntToStr(i), False, 1.0, [], TTextAlign.Trailing, TTextAlign.Center);
    end;

    GateCenters := TDictionary<TGateInstance, TPointF>.Create;
    InputPositions := TDictionary<string, TPointF>.Create;
    OutputPositions := TDictionary<string, TPointF>.Create;
    WirePath := TPathData.Create;
    try
      WireCount := 0;
      if DrawCells then
      begin
        // Primary inputs at level 0, at their layout columns.
        Y := FPanY + 4 * FZoom;
        for j := 0 to ActiveModel.Inputs.Count - 1 do
        begin
          if SameText(ActiveModel.Inputs[j], UNetNaming.ClockRootName) then
            Continue;
          if not FPipeInputCol.TryGetValue(ActiveModel.Inputs[j], InCol) then
            Continue;
          X := FPanX + Left + InCol * (Square + HGap);
          if not OnScreen(X, Y) then
            Continue;
          Canvas.Fill.Color := PalYellow;
          Canvas.FillRect(TRectF.Create(X, Y, X + Square, Y + Square), 0, 0, [], 1.0);
          InputPositions.AddOrSetValue(ActiveModel.Inputs[j],
            TPointF.Create(X + Square * 0.5, Y + Square * 0.5));
        end;

        // Gates at their tree positions, culled to the canvas.
        for i := 0 to ActiveModel.Gates.Count - 1 do
        begin
          Gate := ActiveModel.Gates[i];
          if not FPipeGridPos.TryGetValue(Gate, Pt) then
            Continue;
          X := FPanX + Left + Pt.X * (Square + HGap);
          if Gate.ClockLevel < Length(FPipeLevelYOff) then
            Y := FPanY + 4 * FZoom +
              (FPipeLevelYOff[Gate.ClockLevel] + Pt.Y) * (Square + VGap)
          else
            Y := FPanY + 4 * FZoom + Gate.ClockLevel * (Square + VGap);
          if not OnScreen(X, Y) then
            Continue;
          if FSplitterNames.IndexOf(Gate.Cell.Name) >= 0 then
            Color := PalGreen
          else if FFlipFlopNames.IndexOf(Gate.Cell.Name) >= 0 then
            Color := PalRedDeep
          else if CellHasClock(Gate.Cell) then
            Color := PalBlueDark
          else
            Color := PalBlueLight;
          Canvas.Fill.Color := Color;
          Canvas.FillRect(TRectF.Create(X, Y, X + Square, Y + Square), 0, 0, [], 1.0);
          GateCenters.AddOrSetValue(Gate,
            TPointF.Create(X + Square * 0.5, Y + Square * 0.5));
        end;

        // Primary outputs at their driver's level + 1.
        for j := 0 to ActiveModel.Outputs.Count - 1 do
        begin
          if not FPipeOutGrid.TryGetValue(ActiveModel.Outputs[j], Pt) then
            Continue;
          if Pt.Y > High(FPipeLevelYOff) then
            Continue;
          X := FPanX + Left + Pt.X * (Square + HGap);
          Y := FPanY + 4 * FZoom + FPipeLevelYOff[Pt.Y] * (Square + VGap);
          if not OnScreen(X, Y) then
            Continue;
          Canvas.Fill.Color := PalPurple;
          Canvas.FillRect(TRectF.Create(X, Y, X + Square, Y + Square), 0, 0, [], 1.0);
          OutputPositions.AddOrSetValue(ActiveModel.Outputs[j],
            TPointF.Create(X + Square * 0.5, Y + Square * 0.5));
        end;

        // Wires, batched into one path: one DrawLine per connection builds a
        // path geometry per wire, which is what exhausted memory on large
        // circuits. Only wires between drawn endpoints are added (culling).
        for i := 0 to ActiveModel.Gates.Count - 1 do
        begin
          Src := ActiveModel.Gates[i];
          if not GateCenters.TryGetValue(Src, SrcPt) then
            Continue;
          for j := 0 to Src.Connections.Count - 1 do
          begin
            Conn := Src.Connections[j];
            if Conn.Port.Direction <> pdOutput then
              Continue;
            if not ActiveModel.Nets.TryGetValue(Conn.NetName, Net) then
              Continue;
            for NC in Net.Connections do
              if (not NC.IsDriver) and GateCenters.TryGetValue(NC.Gate, DstPt) then
                AddWire(SrcPt, DstPt);
          end;
        end;
        for j := 0 to ActiveModel.Inputs.Count - 1 do
        begin
          if not InputPositions.TryGetValue(ActiveModel.Inputs[j], SrcPt) then
            Continue;
          if not ActiveModel.Nets.TryGetValue(ActiveModel.Inputs[j], Net) then
            Continue;
          for NC in Net.Connections do
            if (not NC.IsDriver) and GateCenters.TryGetValue(NC.Gate, DstPt) then
              AddWire(SrcPt, DstPt);
        end;
        for j := 0 to ActiveModel.Outputs.Count - 1 do
        begin
          if not OutputPositions.TryGetValue(ActiveModel.Outputs[j], DstPt) then
            Continue;
          if not ActiveModel.Nets.TryGetValue(ActiveModel.Outputs[j], Net) then
            Continue;
          for NC in Net.Connections do
            if NC.IsDriver and GateCenters.TryGetValue(NC.Gate, SrcPt) then
              AddWire(SrcPt, DstPt);
        end;
        if WireCount > 0 then
        begin
          Canvas.Stroke.Kind := TBrushKind.Solid;
          Canvas.Stroke.Color := PalWireDim;
          Canvas.Stroke.Thickness := 1;
          Canvas.DrawPath(WirePath, 1.0);
        end;
      end;

      // --- Heuristics panel ---
      if FPipeWorstPath > 0 then
        StatsText := Format(
          'Pipeline Levels: %d  |  Worst path/level: %.1f ps  |  Area: %.1f um2',
          [Length(FPipelineRows), FPipeWorstPath, FPipeArea])
      else
        StatsText := Format(
          'Pipeline Levels: %d  |  Worst path/level: (no timing)  |  Area: %.1f um2',
          [Length(FPipelineRows), FPipeArea]);
    finally
      GateCenters.Free;
      InputPositions.Free;
      OutputPositions.Free;
      WirePath.Free;
    end;

    StatsR := TRectF.Create(4, PaintBox1.Height - 22, PaintBox1.Width - 4, PaintBox1.Height - 2);
    // White shelf along the bottom so the text stays readable over gate squares.
    Canvas.Fill.Color := TAlphaColorRec.White;
    Canvas.FillRect(TRectF.Create(0, PaintBox1.Height - 26, PaintBox1.Width,
      PaintBox1.Height), 0, 0, [], 0.8);
    Canvas.Fill.Color := TAlphaColorRec.Dimgray;
    Canvas.FillText(StatsR, StatsText, False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);

    // Colour key: cell types only.
    DrawInfoLegend(Canvas, PaintBox1.Width, [
      LegendItem(PalBlueLight, 'Logic cell'),
      LegendItem(PalBlueDark, 'Clocked logic cell'),
      LegendItem(PalRedDeep, 'Flip-flop'),
      LegendItem(PalGreen, 'Splitter'),
      LegendItem(PalYellow, 'Input pad'),
      LegendItem(PalPurple, 'Output pad')]);

  finally
    Canvas.RestoreState(ClipState);
  end;
end;

procedure TForm1.FreePipelineModel;
begin
  // The painter's cached layout keys on gate pointers into this model; a new
  // model can be allocated at the same address, so drop the cache first.
  FreePipelineRows;
  if FPlacementModel = FPipelineModel then
    FPlacementModel := nil; // drop the non-owning alias before its target dies
  FPipelineModel.Free;
  FPipelineModel := nil;
end;

procedure TForm1.BuildPipelineModel;
var
  PM: TBlifModel;
  Dummy: TStringList;
  FFDelay: Double;
  Delay: Double;
  Gate: TGateInstance;
  i, k: Integer;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  DelayMemo: TDictionary<TGateInstance, Double>;
  MinMemo: TDictionary<TGateInstance, Double>;
  FFCell: TCell;
  LevelDelay, GateArea: Double;
  Cmp: TBlifModel;
  CDummy: TStringList;

  function DelayToOutput(G: TGateInstance): Double;
  var
    MaxIn, Dly: Double;
    m: Integer;
    C: TPinConnection;
    N: TNet;
    NC2: TNetConnection;
  begin
    if DelayMemo.TryGetValue(G, Result) then
      Exit;
    if CellHasClock(G.Cell) then
    begin
      // Starting clocked component: its clock-to-output delay is
      // counted. It ends the path, so we do not recurse into it.
      Dly := CellDelayPs(G.Cell);
      if Dly < 0 then Dly := 0;
      Result := Dly;
      DelayMemo.Add(G, Result);
      Exit;
    end;
    MaxIn := 0;
    for m := 0 to G.Connections.Count - 1 do
    begin
      C := G.Connections[m];
      if C.Port.Direction <> pdInput then Continue;
      if IsClockPinName(C.Port.Name) then Continue;
      if PM.Nets.TryGetValue(C.NetName, N) then
        for NC2 in N.Connections do
          if NC2.IsDriver then
          begin
            Dly := DelayToOutput(NC2.Gate);
            if Dly > MaxIn then
              MaxIn := Dly;
          end;
    end;
    Dly := CellDelayPs(G.Cell);
    if Dly < 0 then Dly := 0;
    Result := MaxIn + Dly;
    DelayMemo.Add(G, Result);
  end;

  // Minimum achievable arrival at G: the best worst-case stage prefix delay
  // that DFF insertion can arrange at G. Clocked gates reset the arrival to
  // their own clock-to-output delay; unclocked gates add their own delay to
  // the maximum over data drivers of min(driver arrival, FFDelay), where the
  // FFDelay option is a DFF cut on that driver edge. The worst value over
  // all gates is the minimum achievable worst-case stage delay (a special
  // case of Leiserson-Saxe minimum-period retiming).
  function MinArrival(G: TGateInstance): Double;
  var
    MaxIn, Dly, A: Double;
    m: Integer;
    C: TPinConnection;
    N: TNet;
    NC2: TNetConnection;
  begin
    if MinMemo.TryGetValue(G, Result) then
      Exit;
    Dly := CellDelayPs(G.Cell);
    if Dly < 0 then Dly := 0;
    if CellHasClock(G.Cell) then
    begin
      Result := Dly;
      MinMemo.Add(G, Result);
      Exit;
    end;
    MaxIn := 0;
    for m := 0 to G.Connections.Count - 1 do
    begin
      C := G.Connections[m];
      if C.Port.Direction <> pdInput then Continue;
      if IsClockPinName(C.Port.Name) then Continue;
      if PM.Nets.TryGetValue(C.NetName, N) then
        for NC2 in N.Connections do
          if NC2.IsDriver then
          begin
            A := MinArrival(NC2.Gate);
            if A > FFDelay then
              A := FFDelay;
            if A > MaxIn then
              MaxIn := A;
          end;
    end;
    Result := Dly + MaxIn;
    MinMemo.Add(G, Result);
  end;

  // Same measure the stats bar shows: worst DelayToOutput over all gates
  // of an already-built model (clocked gates count their clk-to-q only).
  function WorstLevelDelayOf(AModel: TBlifModel): Double;
  var
    Memo: TDictionary<TGateInstance, Double>;
    AG: TGateInstance;

    function DlyToOut(G: TGateInstance): Double;
    var
      MaxIn, Dly: Double;
      m: Integer;
      C: TPinConnection;
      N: TNet;
      NC2: TNetConnection;
    begin
      if Memo.TryGetValue(G, Result) then
        Exit;
      if CellHasClock(G.Cell) then
        Dly := CellDelayPs(G.Cell)
      else
      begin
        MaxIn := 0;
        for m := 0 to G.Connections.Count - 1 do
        begin
          C := G.Connections[m];
          if C.Port.Direction <> pdInput then Continue;
          if IsClockPinName(C.Port.Name) then Continue;
          if AModel.Nets.TryGetValue(C.NetName, N) then
            for NC2 in N.Connections do
              if NC2.IsDriver then
              begin
                Dly := DlyToOut(NC2.Gate);
                if Dly > MaxIn then MaxIn := Dly;
              end;
        end;
        Dly := MaxIn + CellDelayPs(G.Cell);
      end;
      if Dly < 0 then Dly := 0;
      Result := Dly;
      Memo.Add(G, Result);
    end;

  begin
    Memo := TDictionary<TGateInstance, Double>.Create;
    try
      Result := 0;
      for AG in AModel.Gates do
      begin
        GateArea := DlyToOut(AG);
        if GateArea > Result then
          Result := GateArea;
      end;
    finally
      Memo.Free;
    end;
  end;

begin
  // A pipeline change invalidates the derived validation state; scrap it before
  // the old pipeline model (whose gates the clone references) is freed.
  ScrapValidationModel;
  FreePipelineModel;
  FThreshold := 0;
  if FModel = nil then
    Exit;
  PM := FModel.Clone;
  try
    if (FLib <> nil) and (FFlipFlopNames.Count > 0) then
    begin
      // Worst combinational path between clocked boundaries on the pristine
      // clone (before any insertion).
      DelayMemo := TDictionary<TGateInstance, Double>.Create;
      try
        FMaxWorstPath := 1;
        for i := 0 to PM.Gates.Count - 1 do
        begin
          Gate := PM.Gates[i];
          LevelDelay := 0;
          for k := 0 to Gate.Connections.Count - 1 do
          begin
            Conn := Gate.Connections[k];
            if Conn.Port.Direction <> pdInput then Continue;
            if IsClockPinName(Conn.Port.Name) then Continue;
            if PM.Nets.TryGetValue(Conn.NetName, Net) then
              for NC in Net.Connections do
                if NC.IsDriver then
                begin
                  GateArea := DelayToOutput(NC.Gate);
                  if GateArea > LevelDelay then
                    LevelDelay := GateArea;
                end;
          end;
          if LevelDelay > FMaxWorstPath then
            FMaxWorstPath := LevelDelay;
        end;
      finally
        DelayMemo.Free;
      end;

      // Fastest possible circuit: exact minimum achievable worst-case stage
      // delay over all DFF insertions (see MinArrival above).
      FMaxWorstPath := Max(1, FMaxWorstPath);
      FFCell := FLib.FindCell(FFlipFlopNames[0]);
      FFDelay := 0;
      if FFCell <> nil then
      begin
        FFDelay := CellDelayPs(FFCell);
        if FFDelay < 0 then
          FFDelay := 0;
      end;
      MinMemo := TDictionary<TGateInstance, Double>.Create;
      try
        FMinDelay := 0;
        for Gate in PM.Gates do
        begin
          Delay := MinArrival(Gate);
          if Delay > FMinDelay then
            FMinDelay := Delay;
        end;
      finally
        MinMemo.Free;
      end;
      if FMinDelay < 1 then
        FMinDelay := 1;

      // The theoretical minimum can be unreachable in practice: forced
      // balancing chains (gap-fill, output padding) and nets the levelizer
      // cannot cut add stages that M* does not account for. Build the
      // fastest pipeline the tool actually produces and clamp the right
      // slider endpoint to its measured worst stage, so the predicted
      // limit is always deliverable.
      Cmp := PM.Clone;
      try
        CDummy := TStringList.Create;
        try
          InsertDelayLevelizedFFs(Cmp, FLib, FFlipFlopNames[0], FMinDelay);
          PadOutputFFs(Cmp, FLib, FFlipFlopNames[0]);
          ComputeClockLevels(Cmp, CDummy);
        finally
          CDummy.Free;
        end;
        Delay := WorstLevelDelayOf(Cmp);
      finally
        Cmp.Free;
      end;
      if Delay > FMinDelay then
        FMinDelay := Delay;

      Dummy := TStringList.Create;
      try
        if FSliderPos = 0 then
        begin
          // Compact mode at the far-left slider position. The merge runs again
          // after padding: the padding flip-flops sit at the ends of the
          // splitter trees and fold back into one shared flip-flop per splitter,
          // then cascade up the tree.
          InsertCompactFlipFlops(PM, FLib, FFlipFlopNames[0]);
          ComputeClockLevels(PM, Dummy);
          PadOutputFFs(PM, FLib, FFlipFlopNames[0]);
          MergeCompactSplitters(PM, FLib, FFlipFlopNames[0]);
          ComputeClockLevels(PM, Dummy);
        end
        else
        begin
          // Delay-levelized: the threshold interpolates from the worst path
          // down to the fastest possible single level as the slider moves
          // right.
          if FMaxWorstPath > FMinDelay then
            FThreshold := FMaxWorstPath - (FMaxWorstPath - FMinDelay) * (FSliderPos / 100)
          else
            FThreshold := FMinDelay;
          InsertDelayLevelizedFFs(PM, FLib, FFlipFlopNames[0], FThreshold);
          PadOutputFFs(PM, FLib, FFlipFlopNames[0]);
          ComputeClockLevels(PM, Dummy);
        end;

        // Left slider endpoint: measure compact mode's worst path/level so
        // the label matches what the stats bar shows in compact mode.
        if FSliderPos = 0 then
          FCompactWorstDelay := WorstLevelDelayOf(PM)
        else
        begin
          Cmp := FModel.Clone;
          try
            CDummy := TStringList.Create;
            try
              InsertCompactFlipFlops(Cmp, FLib, FFlipFlopNames[0]);
              ComputeClockLevels(Cmp, CDummy);
              PadOutputFFs(Cmp, FLib, FFlipFlopNames[0]);
              MergeCompactSplitters(Cmp, FLib, FFlipFlopNames[0]);
              ComputeClockLevels(Cmp, CDummy);
            finally
              CDummy.Free;
            end;
            FCompactWorstDelay := WorstLevelDelayOf(Cmp);
          finally
            Cmp.Free;
          end;
        end;
      finally
        Dummy.Free;
      end;
    end
    else
    begin
      // No flip-flop selected: keep the plain clone, just label the levels.
      FMaxWorstPath := 1;
      FMinDelay := 1;
      Dummy := TStringList.Create;
      try
        ComputeClockLevels(PM, Dummy);
      finally
        Dummy.Free;
      end;
    end;
    FPipelineModel := PM;
    PM := nil;
  finally
    PM.Free;
  end;
end;

procedure TForm1.TrackBar1Change(Sender: TObject);
begin
  if FSliderUpdating then
    Exit;
  FSliderUpdating := True;
  try
    FSliderPos := Round(TrackBar1.Value);
    if FSliderPos < 0 then FSliderPos := 0;
    if FSliderPos > 100 then FSliderPos := 100;
  finally
    FSliderUpdating := False;
  end;
  // Update the constraint shown live in the heuristics label without
  // rebuilding the circuit; the build happens once the slider is released.
  if FMaxWorstPath > FMinDelay then
    FThreshold := FMaxWorstPath - (FMaxWorstPath - FMinDelay) * (FSliderPos / 100)
  else
    FThreshold := FMinDelay;
  UpdateModeLabel;
  RepaintPipelinePage;
  FSliderTimer.Enabled := False;
  FSliderTimer.Enabled := True;
end;

procedure TForm1.SliderTimerTimer(Sender: TObject);
begin
  FSliderTimer.Enabled := False;
  if TabControl1.TabIndex <> TabPipeline then
    Exit;
  BuildPipelineModel;
  UpdateModeLabel;
  RepaintPipelinePage;
end;

procedure TForm1.UpdateModeLabel;
begin
  if FSliderPos = 0 then
    LabelMode.Text := 'Mode: compact'
  else
    LabelMode.Text := Format('Mode: max delay <=%.1f ps', [FThreshold]);
end;

procedure TForm1.UpdateLimitLabels;
begin
  // Slider end delays: the compact mode worst path/level (left) and the fastest
  // possible level delay (right). These are the raw numbers a clock frequency
  // would be inferred from - the frequency itself is not a meaningful figure.
  if (FModel <> nil) and (FFlipFlopNames.Count > 0) then
  begin
    // Left end: compact mode's real worst path/level, matching the stats
    // bar; falls back to the pristine worst path before the first build.
    if FCompactWorstDelay > 0 then
      LabelFreqLeft.Text := Format('%.1f ps', [FCompactWorstDelay])
    else
      LabelFreqLeft.Text := Format('%.1f ps', [FMaxWorstPath]);
    LabelFreqRight.Text := Format('%.1f ps', [FMinDelay]);
  end
  else
  begin
    LabelFreqLeft.Text := '-';
    LabelFreqRight.Text := '-';
  end;
end;

procedure TForm1.RepaintPipelinePage;
begin
  // Only the canvas holds circuit-dependent content; repainting every child
  // turned one pan step into a storm of full-canvas paints.
  if TabControl1.TabIndex <> TabPipeline then
    Exit;
  PaintBox1.Repaint;
end;
