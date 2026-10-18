// Pipeline: row building, the pipeline painter, the pipeline model and the
// mode/limit/slider UI. Included from MainWindow's implementation via
// {$I Pipeline.inc}.
procedure TForm1.FreePipelineRows;
var
  i: Integer;
begin
  for i := 0 to High(FPipelineRows) do
    FPipelineRows[i].Free;
  FPipelineRows := nil;
end;

procedure TForm1.BuildPipelineRows(const AModel: TBlifModel);
var
  Gate: TGateInstance;
  i, MaxLevel: Integer;
begin
  FreePipelineRows;
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
end;

procedure TForm1.PaintPipeline(Sender: TObject; Canvas: TCanvas);
var
  R, NoteR: TRectF;
  i, j, k: Integer;
  ClipState: TCanvasSaveState;
  Gate, Src: TGateInstance;
  MaxRows, MaxOutputLevel: Integer;
  Square, HGap, VGap, Left, X, Y: Single;
  Color: TAlphaColor;
  ActiveModel: TBlifModel;
  Note: string;
  GateCenters: TDictionary<TGateInstance, TPointF>;
  InputPositions: TDictionary<string, TPointF>;
  OutputPositions: TDictionary<string, TPointF>;
  SrcPt, DstPt: TPointF;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  InputNets: TStringList;
  OutputNets: TStringList;
  OutputLevels: TList<Integer>;
  OutColCount: TDictionary<Integer, Integer>;
  OutName: string;
  OutLevel: Integer;
  LevelDelay, MaxLevelDelay, TotalArea, GateArea: Double;
  LevelIdx, TotalLevels: Integer;
  StatsText: string;
  StatsR: TRectF;
  DelayMemo: TDictionary<TGateInstance, Double>;
  GateGridPos: TDictionary<TGateInstance, TPoint>;
  InputCol: TDictionary<string, Integer>;
  LevelMaxDepth, LevelYOffset: TList<Integer>;
  Placed: TDictionary<TGateInstance, Boolean>;
  LevelCols: TList<Integer>;
  MaxDepth, MaxCol, GridCol, GridRow, YOff: Integer;
  HasParent: Boolean;
  GatePair: TPair<TGateInstance, TPoint>;

  function DelayToOutput(G: TGateInstance): Double;
  var
    MaxIn, Dly: Double;
    m: Integer;
    C: TPinConnection;
    N: TNet;
    NC: TNetConnection;
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
      if ActiveModel.Nets.TryGetValue(C.NetName, N) then
        for NC in N.Connections do
          if NC.IsDriver then
          begin
            Dly := DelayToOutput(NC.Gate);
            if Dly > MaxIn then
              MaxIn := Dly;
          end;
    end;
    Dly := CellDelayPs(G.Cell);
    if Dly < 0 then Dly := 0;
    Result := MaxIn + Dly;
    DelayMemo.Add(G, Result);
  end;

  procedure DFSLayout(Gate: TGateInstance; Depth, BaseCol: Integer);
  var
    C: TPinConnection;
    N: TNet;
    NCC: TNetConnection;
    ParentCol: Integer;
  begin
    if Placed.ContainsKey(Gate) then
      Exit;
    while LevelCols.Count <= Depth do
      LevelCols.Add(0);
    if LevelCols[Depth] < BaseCol then
      LevelCols[Depth] := BaseCol;
    ParentCol := LevelCols[Depth];
    GateGridPos.Add(Gate, TPoint.Create(ParentCol, Depth));
    Placed.Add(Gate, True);
    LevelCols[Depth] := ParentCol + 1;
    for C in Gate.Connections do
    begin
      if C.Port.Direction <> pdOutput then
        Continue;
      if not ActiveModel.Nets.TryGetValue(C.NetName, N) then
        Continue;
      for NCC in N.Connections do
        if (not NCC.IsDriver) and (NCC.Gate.ClockLevel = Gate.ClockLevel) then
          DFSLayout(NCC.Gate, Depth + 1, ParentCol);
    end;
    if Depth + 1 < LevelCols.Count then
      if LevelCols[Depth] < LevelCols[Depth + 1] then
        LevelCols[Depth] := LevelCols[Depth + 1];
  end;

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

  // Mask to the paint box so drawing doesn't bleed over the slider/tab edges;
  // D2D honours IntersectClipRect only inside SaveState/RestoreState.
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

    BuildPipelineRows(ActiveModel);

    if Note <> '' then
    begin
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      NoteR := TRectF.Create(4, 4, PaintBox1.Width - 4, 24);
      Canvas.FillText(NoteR, Note, False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);
    end;

  InputNets := TStringList.Create;
  OutputNets := TStringList.Create;
  OutputLevels := TList<Integer>.Create;
  InputPositions := TDictionary<string, TPointF>.Create;
  OutputPositions := TDictionary<string, TPointF>.Create;
  GateCenters := TDictionary<TGateInstance, TPointF>.Create;
  try
    // Collect primary inputs (level 0), skipping the clock net.
    for i := 0 to ActiveModel.Inputs.Count - 1 do
      if not SameText(ActiveModel.Inputs[i], UNetNaming.ClockRootName) then
        InputNets.Add(ActiveModel.Inputs[i]);

    // Collect primary outputs with their clock level (driver level + 1).
    MaxOutputLevel := 0;
    for i := 0 to ActiveModel.Outputs.Count - 1 do
    begin
      OutName := ActiveModel.Outputs[i];
      if ActiveModel.Nets.TryGetValue(OutName, Net) then
      begin
        OutLevel := 0;
        for NC in Net.Connections do
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

    HGap := 4 * FZoom;
    VGap := 4 * FZoom;
    Left := 40 * FZoom;
    Square := 18 * FZoom;

    MaxRows := Length(FPipelineRows);
    if MaxOutputLevel >= MaxRows then
      MaxRows := MaxOutputLevel + 1;
    if MaxRows = 0 then
      MaxRows := 1;

    GateGridPos := TDictionary<TGateInstance, TPoint>.Create;
    InputCol := TDictionary<string, Integer>.Create;
    LevelMaxDepth := TList<Integer>.Create;
    LevelYOffset := TList<Integer>.Create;
    Placed := TDictionary<TGateInstance, Boolean>.Create;
    try
      LevelCols := TList<Integer>.Create;
      try
        // Compute tree layout within each clock level.
        for i := 0 to High(FPipelineRows) do
        begin
          LevelCols.Clear;
          LevelCols.Add(0);
          Placed.Clear;

          // Level 0: primary inputs are the roots; each claims a row-0 column and
          // pushes the next input right, like the general tree layout.
          if (i = 0) and (InputNets.Count > 0) then
          begin
            for j := 0 to InputNets.Count - 1 do
            begin
              GridCol := LevelCols[0];
              InputCol.AddOrSetValue(InputNets[j], GridCol);
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
                  if not ActiveModel.Nets.TryGetValue(Conn.NetName, Net) then
                    Continue;
                  for NC in Net.Connections do
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
              // Push the input row right to cover the subtree just placed,
              // mirroring the push-up the tree layout applies to its roots.
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
                if not ActiveModel.Nets.TryGetValue(Conn.NetName, Net) then
                  Continue;
                for NC in Net.Connections do
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

          // Find max depth for this level.
          MaxDepth := 0;
          for j := 0 to FPipelineRows[i].Count - 1 do
          begin
            Gate := FPipelineRows[i][j];
            if GateGridPos.ContainsKey(Gate) then
            begin
              GridRow := GateGridPos[Gate].Y;
              if GridRow > MaxDepth then
                MaxDepth := GridRow;
            end;
          end;
          LevelMaxDepth.Add(MaxDepth + 1);
        end;

        // Compute cumulative Y offsets per level with a gap between levels.
        while LevelMaxDepth.Count < MaxRows do
          LevelMaxDepth.Add(1);
        YOff := 0;
        for i := 0 to LevelMaxDepth.Count - 1 do
        begin
          LevelYOffset.Add(YOff);
          Inc(YOff, LevelMaxDepth[i] + 1);
        end;

        // Draw level labels to the left of each level's first row.
        for i := 0 to LevelMaxDepth.Count - 1 do
        begin
          Y := FPanY + 4 * FZoom + LevelYOffset[i] * (Square + VGap);
          Canvas.Fill.Color := TAlphaColorRec.Dimgray;
          Canvas.FillText(TRectF.Create(FPanX, Y, FPanX + Left - 6 * FZoom, Y + Square),
            IntToStr(i), False, 1.0, [], TTextAlign.Trailing, TTextAlign.Center);
        end;

        // Draw primary inputs at level 0, at the columns the layout assigned
        // them (pushed right by their subtrees, like the other roots).
        Y := FPanY + 4 * FZoom;
        for j := 0 to InputNets.Count - 1 do
        begin
          GridCol := 0;
          if not InputCol.TryGetValue(InputNets[j], GridCol) then
            GridCol := j;
          X := FPanX + Left + GridCol * (Square + HGap);
          Canvas.Fill.Color := PalYellow;
          Canvas.FillRect(TRectF.Create(X, Y, X + Square, Y + Square), 0, 0, [], 1.0);
          InputPositions.AddOrSetValue(InputNets[j],
            TPointF.Create(X + Square * 0.5, Y + Square * 0.5));
        end;

        // Draw gates at their tree positions.
        for i := 0 to ActiveModel.Gates.Count - 1 do
        begin
          Gate := ActiveModel.Gates[i];
          if Gate.ClockLevel < 0 then
            Continue;
          if not GateGridPos.ContainsKey(Gate) then
            Continue;
          GridCol := GateGridPos[Gate].X;
          GridRow := GateGridPos[Gate].Y;
          X := FPanX + Left + GridCol * (Square + HGap);
          if Gate.ClockLevel < LevelYOffset.Count then
            Y := FPanY + 4 * FZoom + (LevelYOffset[Gate.ClockLevel] + GridRow) * (Square + VGap)
          else
            Y := FPanY + 4 * FZoom + Gate.ClockLevel * (Square + VGap);
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

        // Draw primary outputs at their driver's level + 1, each in its own
        // column to the right of that level's gates.
        OutColCount := TDictionary<Integer, Integer>.Create;
        try
          for j := 0 to OutputLevels.Count - 1 do
          begin
            OutLevel := OutputLevels[j];
            MaxCol := 0;
            for GatePair in GateGridPos do
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
            X := FPanX + Left + GridCol * (Square + HGap);
            Y := FPanY + 4 * FZoom + LevelYOffset[OutLevel] * (Square + VGap);
            Canvas.Fill.Color := PalPurple;
            Canvas.FillRect(TRectF.Create(X, Y, X + Square, Y + Square), 0, 0, [], 1.0);
            OutputPositions.AddOrSetValue(OutputNets[j],
              TPointF.Create(X + Square * 0.5, Y + Square * 0.5));
          end;
        finally
          OutColCount.Free;
        end;

      finally
        LevelCols.Free;
      end;

    finally
      GateGridPos.Free;
      InputCol.Free;
      LevelMaxDepth.Free;
      LevelYOffset.Free;
      Placed.Free;
    end;

    // Draw connection lines.
    Canvas.Stroke.Kind := TBrushKind.Solid;
    Canvas.Stroke.Color := PalWireDim;
    Canvas.Stroke.Thickness := 1;

    // Gate-to-gate.
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
            Canvas.DrawLine(SrcPt, DstPt, 1.0);
      end;
    end;

    // Input-to-gate.
    for i := 0 to InputNets.Count - 1 do
    begin
      if not InputPositions.TryGetValue(InputNets[i], SrcPt) then
        Continue;
      if not ActiveModel.Nets.TryGetValue(InputNets[i], Net) then
        Continue;
      for NC in Net.Connections do
        if (not NC.IsDriver) and GateCenters.TryGetValue(NC.Gate, DstPt) then
          Canvas.DrawLine(SrcPt, DstPt, 1.0);
    end;

    // Gate-to-output.
    for i := 0 to OutputNets.Count - 1 do
    begin
      if not OutputPositions.TryGetValue(OutputNets[i], DstPt) then
        Continue;
      if not ActiveModel.Nets.TryGetValue(OutputNets[i], Net) then
        Continue;
      for NC in Net.Connections do
        if NC.IsDriver and GateCenters.TryGetValue(NC.Gate, SrcPt) then
          Canvas.DrawLine(SrcPt, DstPt, 1.0);
    end;

    // --- Heuristics panel ---
    MaxLevelDelay := 0;
    TotalArea := 0;
    TotalLevels := MaxRows;

    DelayMemo := TDictionary<TGateInstance, Double>.Create;
    try
      // Accumulate area from all gates.
      for LevelIdx := 0 to MaxRows - 1 do
        if LevelIdx <= High(FPipelineRows) then
          for j := 0 to FPipelineRows[LevelIdx].Count - 1 do
            TotalArea := TotalArea +
              FPipelineRows[LevelIdx][j].Cell.Width *
              FPipelineRows[LevelIdx][j].Cell.Height;

      // Per-level worst path: longest combinational path from a source register
      // (clk-to-q counted) to the next receiver register (its delay not counted).
      for LevelIdx := 0 to MaxRows - 1 do
      begin
        LevelDelay := 0;
        if LevelIdx <= High(FPipelineRows) then
          for j := 0 to FPipelineRows[LevelIdx].Count - 1 do
          begin
            Gate := FPipelineRows[LevelIdx][j];
            GateArea := DelayToOutput(Gate);
            if GateArea > LevelDelay then
              LevelDelay := GateArea;
          end;
        if LevelDelay > MaxLevelDelay then
          MaxLevelDelay := LevelDelay;
      end;
    finally
      DelayMemo.Free;
    end;

    if MaxLevelDelay > 0 then
    begin
      StatsText := Format(
        'Levels: %d  |  Worst path/level: %.1f ps  |  Fmax: %.1f GHz  |  Area: %.1f um2',
        [TotalLevels, MaxLevelDelay,
         1000.0 / MaxLevelDelay,
         TotalArea]);
    end
    else
      StatsText := Format(
        'Levels: %d  |  Worst path/level: (no timing)  |  Area: %.1f um2',
        [TotalLevels, TotalArea]);

    StatsR := TRectF.Create(4, PaintBox1.Height - 22, PaintBox1.Width - 4, PaintBox1.Height - 2);
    // White shelf along the bottom so the text stays readable over gate
    // squares.
    Canvas.Fill.Color := TAlphaColorRec.White;
    Canvas.FillRect(TRectF.Create(0, PaintBox1.Height - 26, PaintBox1.Width,
      PaintBox1.Height), 0, 0, [], 0.8);
    Canvas.Fill.Color := TAlphaColorRec.Dimgray;
    Canvas.FillText(StatsR, StatsText, False, 1.0, [], TTextAlign.Leading, TTextAlign.Center);

  finally
    InputNets.Free;
    OutputNets.Free;
    OutputLevels.Free;
    InputPositions.Free;
    OutputPositions.Free;
    GateCenters.Free;
  end;
  finally
    Canvas.RestoreState(ClipState);
  end;
end;

procedure TForm1.FreePipelineModel;
begin
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
          // Compact mode at the far-left slider position.
          InsertCompactFlipFlops(PM, FLib, FFlipFlopNames[0]);
          ComputeClockLevels(PM, Dummy);
          PadOutputFFs(PM, FLib, FFlipFlopNames[0]);
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
  // Slider end frequencies: the compact mode worst path (left) and the
  // fastest possible level (right). Delays are in ps, so invert for GHz.
  if (FModel <> nil) and (FFlipFlopNames.Count > 0) then
  begin
    // Left end: compact mode's real worst path/level, matching the stats
    // bar; falls back to the pristine worst path before the first build.
    if FCompactWorstDelay > 0 then
      LabelFreqLeft.Text := Format('%.2f GHz', [1000.0 / FCompactWorstDelay])
    else
      LabelFreqLeft.Text := Format('%.2f GHz', [1000.0 / FMaxWorstPath]);
    LabelFreqRight.Text := Format('%.2f GHz', [1000.0 / FMinDelay]);
  end
  else
  begin
    LabelFreqLeft.Text := '-';
    LabelFreqRight.Text := '-';
  end;
end;

procedure TForm1.RepaintPipelinePage;
var
  i: Integer;
begin
  // Partial redraws around the clipped canvas corrupt neighbouring controls, so
  // repaint every direct child (the form itself is not a TControl).
  if TabControl1.TabIndex <> TabPipeline then
    Exit;
  for i := 0 to Children.Count - 1 do
    if Children[i] is TControl then
      TControl(Children[i]).Repaint;
end;
