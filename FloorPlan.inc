// Floorplan build / clock placement / validation / paint. Included from
// MainWindow's implementation via {\$I FloorPlan.inc} so these TForm1 methods
// keep full access to the form state without growing the god file.

procedure TForm1.BuildFloorplan;

  // Walks a row's clock distribution tree (from its tap net) and returns the
  // total width of all subtree components. Trunk spine elements are excluded;
  // clocked cells are leaves (counted, but their data outputs are not walked).
  function CollectTreeWidth(const ANetName: string;
    Visited: TDictionary<TGateInstance, Boolean>): Double;
  var
    Net: TNet;
    NC: TNetConnection;
    Conn: TPinConnection;
  begin
    Result := 0;
    if FClockModel = nil then
      Exit;
    if not FClockModel.Nets.TryGetValue(ANetName, Net) then
      Exit;
    for NC in Net.Connections do
    begin
      if NC.IsDriver then
        Continue;
      if Visited.ContainsKey(NC.Gate) then
        Continue;
      Visited.Add(NC.Gate, True);
      if NC.Gate.ClockTrunk then
        Continue; // spine element, not part of the subtree
      if NC.Gate.Cell <> nil then
        Result := Result + NC.Gate.Cell.Width;
      if not CellHasClock(NC.Gate.Cell) then
        // Interior node (splitter/buffer): keep walking its output nets.
        for Conn in NC.Gate.Connections do
          if Conn.Port.Direction = pdOutput then
            Result := Result + CollectTreeWidth(Conn.NetName, Visited);
    end;
  end;

var
  Core, DieW, DieH, RowH, Util: Double;
  DieWBlocks, DieHBlocks, RowHBlocks: Integer;
  Levels: TList<Integer>;
  Gate: TGateInstance;
  L, i, NumLayers: Integer;
  WidthSum, AllocBlocks, ClkWidth, ClkBlocks: Double;
  PadRec: TPadConnection;
  ClockNetName: string;
  ClockIsInput: Boolean;
  InputPadIdx, OutputPadIdx: TArray<Integer>;
  RowNetName: string;
  Visited: TDictionary<TGateInstance, Boolean>;
  RowWidths: TArray<Integer>;
  TotalH, TotalW, XRight, BandStart, CursorY: Integer;
  MaxRowW, BodyW, LeftPad, XLeft: Integer;
  TopPad: Integer;
  AvailableWidth, TotalBands, Band, C, ChunkCount, ChunkWidth: Integer;
  LevelBandCount, LevelFirstBand, BandStarts: TArray<Integer>;
  NewExtra: TArray<Integer>;
  NewBias: TArray<TArray<Integer>>;
  NewLane: TArray<Integer>;
  OldFirst, OldCount: Integer;
  TrunkW, Lane0W, Lane1W: Integer;
  CurChunk, CurX: TArray<Integer>;
  Idx: Integer;
  P: TPlacedComponent;
  RowY, BandIndex: Integer;
  RowY0, RowY1: Integer;
  NeedsBuild: Boolean;
begin
  RefreshDesignConfig;
  // Reset the view; the die is fitted to the canvas on the next paint.
  FPlanPanX := 0;
  FPlanPanY := 0;
  FPlanZoom := 1.0;
  FPlanNeedsFit := True;
  ListBoxFloorplanErrors.Clear;
  FManhattanItem := nil; // cleared listbox invalidates the diagnostic item
  FFloorplanErrorCount := 0;
  // Place the post-DFF netlist (pipeline, else splitter-inserted); once validation
  // has cloned a private model, that clone is the base and the shared model is untouched.
  if FOwnedPlacementModel <> nil then
    FPlacementModel := FOwnedPlacementModel
  else
  begin
    FPlacementModel := FPipelineModel;
    if FPlacementModel = nil then
    begin
      // A freshly loaded project has no pipeline model yet; build it (using the
      // restored slider) so the post-DFF netlist is used, as on the Pipeline page.
      if (FModel <> nil) and (FLib <> nil) and (FFlipFlopNames.Count > 0) then
        BuildPipelineModel;
      FPlacementModel := FPipelineModel;
      if FPlacementModel = nil then
        FPlacementModel := FModel;
    end;
  end;
  FFloorplan := nil;
  FFloorplanW := 0;
  FFloorplanH := 0;
  FFloorplanValid := False;

  if (FDesignConfig.CoreUm <= 0) or (FDesignConfig.DieWUm <= 0) or
     (FDesignConfig.DieHUm <= 0) or (FDesignConfig.RowHeightUm <= 0) then
  begin
    AddFloorplanError('Placement configuration is incomplete or invalid; go back and fix it.');
    RepaintFloorplanPage;
    Exit;
  end;
  Core := FDesignConfig.CoreUm;
  DieW := FDesignConfig.DieWUm;
  DieH := FDesignConfig.DieHUm;
  RowH := FDesignConfig.RowHeightUm;
  Util := FDesignConfig.UtilizationPct;
  if Util <= 0 then
    Util := 60;

  DieWBlocks := Round(DieW / Core);
  DieHBlocks := Round(DieH / Core);
  RowHBlocks := Round(RowH / Core);
  if RowHBlocks < 1 then
    RowHBlocks := 1;
  if DieWBlocks < 1 then
    DieWBlocks := 1;
  if DieHBlocks < 1 then
    DieHBlocks := 1;
  // Guard against absurd grid sizes.
  if DieWBlocks > MaxGridBlocks then
  begin
    AddFloorplanError(Format('Die width of %d blocks is too large to visualise (capped at %d).', [DieWBlocks, MaxGridBlocks]));
    DieWBlocks := MaxGridBlocks;
  end;
  if DieHBlocks > MaxGridBlocks then
  begin
    AddFloorplanError(Format('Die height of %d blocks is too large to visualise (capped at %d).', [DieHBlocks, MaxGridBlocks]));
    DieHBlocks := MaxGridBlocks;
  end;

  Levels := TList<Integer>.Create;
  try
    // All distinct clock levels (>= 0) present in the main netlist.
    if FPlacementModel <> nil then
      for Gate in FPlacementModel.Gates do
        if (Gate.ClockLevel >= 0) and (Levels.IndexOf(Gate.ClockLevel) < 0) then
          Levels.Add(Gate.ClockLevel);
    Levels.Sort;
    NumLayers := Levels.Count;

    if NumLayers = 0 then
    begin
      AddFloorplanError('No clock layers found in the netlist; load a BLIF first.');
      RepaintFloorplanPage;
      Exit;
    end;

    // Per-layer row width, calc1: sum of gate widths at that level, buffered by
    // the utilization.
    SetLength(RowWidths, NumLayers);
    for L := 0 to NumLayers - 1 do
    begin
      WidthSum := 0;
      for Gate in FPlacementModel.Gates do
        if Gate.ClockLevel = Levels[L] then
          if Gate.Cell <> nil then
            WidthSum := WidthSum + Gate.Cell.Width;
      AllocBlocks := Ceil(WidthSum / (Util / 100) / Core);
      RowWidths[L] := Round(AllocBlocks);
      if RowWidths[L] < 1 then
        RowWidths[L] := 1;
    end;

    // calc2 needs a usable clock network (model *and* a row per level). It can be
    // left half-built by an earlier BuildClockModel - FClockModel set but
    // FClockNet nil - and then every level silently loses its subtree width and
    // the rows come out too narrow on the first build. Rebuild it here, where the
    // levels to check are known.
    NeedsBuild := (FClockModel = nil) or (FClockNet = nil);
    if not NeedsBuild then
      for L := 0 to NumLayers - 1 do
        if FClockNet.Rows.IndexOf(Levels[L]) < 0 then
          NeedsBuild := True;
    if NeedsBuild then
      BuildClockModel;

    // Per-layer row width, calc2: the clock subtree at that level (trunk
    // components excluded), buffered the same way. The allocated width is
    // the maximum of the two calculations.
    for L := 0 to NumLayers - 1 do
    begin
      ClkWidth := 0;
      if (FClockModel <> nil) and (FClockNet <> nil) and
         (FClockNet.Rows.IndexOf(Levels[L]) >= 0) then
      begin
        RowNetName := UNetNaming.ClockRowNetName(Levels[L]);
        Visited := TDictionary<TGateInstance, Boolean>.Create;
        try
          ClkWidth := CollectTreeWidth(RowNetName, Visited);
        finally
          Visited.Free;
        end;
      end;
      ClkBlocks := Ceil(ClkWidth / (Util / 100) / Core);
      if Round(ClkBlocks) > RowWidths[L] then
        RowWidths[L] := Round(ClkBlocks);
    end;

    // Horizontal stack: far-left bias trunk, rows, left feed lane, clock trunk
    // (RowHBlocks), far-right lane; rows wrap into chunks and the whole is centered.
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
    Lane0W := FBiasLaneW[0];
    Lane1W := FBiasLaneW[1];
    if FPlanBiasTrunkW < 1 then
      FPlanBiasTrunkW := 1;
    TrunkW := RowHBlocks; // the clock trunk is always RowHBlocks wide
    AvailableWidth := DieWBlocks - FPlanBiasTrunkW - Lane0W - TrunkW - Lane1W;
    if AvailableWidth < 1 then
    begin
      AddFloorplanError(Format('Die is too narrow: at least %d blocks are needed for the bias trunk, lanes and clock trunk.',
        [FPlanBiasTrunkW + Lane0W + TrunkW + Lane1W]));
      RepaintFloorplanPage;
      Exit;
    end;
    MaxRowW := 0;
    for L := 0 to NumLayers - 1 do
      if RowWidths[L] > MaxRowW then
        MaxRowW := RowWidths[L];
    if MaxRowW > AvailableWidth then
      MaxRowW := AvailableWidth; // clip to the die's allocatable row width
    // The congestion helpers may have nudged the rows tighter (column
    // expansion recovered space from the utilization slack).
    if FPlanMaxRowW > 0 then
      if FPlanMaxRowW < MaxRowW then
        MaxRowW := FPlanMaxRowW;
    BodyW := MaxRowW + FPlanBiasTrunkW + Lane0W + TrunkW + Lane1W;
    if BodyW > DieWBlocks then
    begin
      AddFloorplanError(Format('Not enough width: floorplan needs %d blocks, die has %d.',
        [BodyW, DieWBlocks]));
      BodyW := DieWBlocks;
    end;
    // Center the floorplan horizontally (rows + trunks) in the die; a floorplan
    // that fills the die gets no padding. The far-left bias lane and far-right
    // bias lane sit at the two edges of the allocated block.
    LeftPad := (DieWBlocks - BodyW) div 2;
    if LeftPad < 0 then
      LeftPad := 0;
    XLeft := LeftPad + FPlanBiasTrunkW;    // left edge of the rows
    XRight := XLeft + MaxRowW;            // common right edge of the rows
    TotalW := LeftPad + BodyW;            // far-right edge of the bias lane
    FPlanXLeft := XLeft;
    FPlanXRight := XRight;

    // Allocate the die-sized grid and its per-cell layer tags.
    FFloorplanW := DieWBlocks;
    FFloorplanH := DieHBlocks;
    SetLength(FFloorplan, FFloorplanW * FFloorplanH);
    SetLength(FFloorplanLayer, FFloorplanW * FFloorplanH);
    for i := 0 to High(FFloorplan) do
    begin
      FFloorplan[i] := fcEmpty;
      FFloorplanLayer[i] := -1;
    end;

    // Lay out the bands, wrapping rows wider than the die into their own bands; the
    // per-layer chunk layout is computed first so extra rows remap by (layer, chunk).
    SetLength(LevelBandCount, NumLayers);
    SetLength(LevelFirstBand, NumLayers);
    TotalBands := 0;
    for L := 0 to NumLayers - 1 do
    begin
      LevelFirstBand[L] := TotalBands;
      LevelBandCount[L] := Max(1, Ceil(RowWidths[L] / AvailableWidth));
      TotalBands := TotalBands + LevelBandCount[L];
    end;
    // Remap the accumulated per-row extra rows by (layer, chunk): the old
    // layout is still in FPlanLevelFirstBand/FPlanLevelBandCount from the last
    // build. Chunks that existed before keep their rows; new chunks start at 0.
    if Length(FLogicRowExtra) > 0 then
    begin
      NewExtra := nil;
      SetLength(NewExtra, TotalBands);
      for L := 0 to NumLayers - 1 do
      begin
        OldFirst := 0;
        OldCount := 0;
        if (L < Length(FPlanLevelFirstBand)) and (L < Length(FPlanLevelBandCount)) then
        begin
          OldFirst := FPlanLevelFirstBand[L];
          OldCount := FPlanLevelBandCount[L];
        end;
        for Band := 0 to Min(OldCount, LevelBandCount[L]) - 1 do
          if (OldFirst + Band >= 0) and (OldFirst + Band < Length(FLogicRowExtra)) then
            NewExtra[LevelFirstBand[L] + Band] := FLogicRowExtra[OldFirst + Band];
      end;
      FLogicRowExtra := NewExtra;
    end
    else
      SetLength(FLogicRowExtra, TotalBands);
    if Length(FClockRowExtra) > 0 then
    begin
      NewExtra := nil;
      SetLength(NewExtra, TotalBands);
      for L := 0 to NumLayers - 1 do
      begin
        OldFirst := 0;
        OldCount := 0;
        if (L < Length(FPlanLevelFirstBand)) and (L < Length(FPlanLevelBandCount)) then
        begin
          OldFirst := FPlanLevelFirstBand[L];
          OldCount := FPlanLevelBandCount[L];
        end;
        for Band := 0 to Min(OldCount, LevelBandCount[L]) - 1 do
          if (OldFirst + Band >= 0) and (OldFirst + Band < Length(FClockRowExtra)) then
            NewExtra[LevelFirstBand[L] + Band] := FClockRowExtra[OldFirst + Band];
      end;
      FClockRowExtra := NewExtra;
    end
    else
      SetLength(FClockRowExtra, TotalBands);
    // Remap the per-band bias-row extras (top/middle) by (layer, chunk).
    if Length(FBiasRowH) > 0 then
    begin
      NewBias := nil;
      SetLength(NewBias, TotalBands);
      for Band := 0 to TotalBands - 1 do
      begin
        SetLength(NewBias[Band], 2);
        NewBias[Band][0] := 0;
        NewBias[Band][1] := 0;
      end;
      for L := 0 to NumLayers - 1 do
      begin
        OldFirst := 0;
        OldCount := 0;
        if (L < Length(FPlanLevelFirstBand)) and (L < Length(FPlanLevelBandCount)) then
        begin
          OldFirst := FPlanLevelFirstBand[L];
          OldCount := FPlanLevelBandCount[L];
        end;
        for Band := 0 to Min(OldCount, LevelBandCount[L]) - 1 do
          if (OldFirst + Band >= 0) and (OldFirst + Band < Length(FBiasRowH)) and
             (Length(FBiasRowH[OldFirst + Band]) >= 2) then
          begin
            NewBias[LevelFirstBand[L] + Band][0] :=
              FBiasRowH[OldFirst + Band][0];
            NewBias[LevelFirstBand[L] + Band][1] :=
              FBiasRowH[OldFirst + Band][1];
          end;
      end;
      FBiasRowH := NewBias;
    end
    else
    begin
      SetLength(FBiasRowH, TotalBands);
      for Band := 0 to TotalBands - 1 do
      begin
        SetLength(FBiasRowH[Band], 2);
        FBiasRowH[Band][0] := 0;
        FBiasRowH[Band][1] := 0;
      end;
    end;
    // Default: the topmost (band 0's top) and the bottommost full-width bias
    // rows start 2 cells thick (base 1 + one default extra cell), which is
    // needed to route the bias lines. The expansion helpers grow them further.
    if Length(FBiasRowH) > 0 then
      if Length(FBiasRowH[0]) > 0 then
        if FBiasRowH[0][0] < 1 then
          FBiasRowH[0][0] := 1;
    if FBottomBiasH < 1 then
      FBottomBiasH := 1;
    // Total height = sum of per-band heights (top bias + logic row + its extras
    // + middle bias + clock row + its extras) + the bottom-most bias line.
    SetLength(FPlanBandHeight, TotalBands);
    TotalH := 0;
    for Band := 0 to TotalBands - 1 do
    begin
      FPlanBandHeight[Band] := BandTopBiasH(Band) + RowHBlocks +
        FLogicRowExtra[Band] + BandMidBiasH(Band) + RowHBlocks +
        FClockRowExtra[Band];
      if FPlanBandHeight[Band] < 1 then
        FPlanBandHeight[Band] := 1;
      TotalH := TotalH + FPlanBandHeight[Band];
    end;
    Inc(TotalH, 1 + FBottomBiasH);

    // Failure checks - report and keep whatever fits. Two extra rows are reserved
    // for the I/O pads (top inputs, bottom outputs); the bias trunk and the
    // far-right bias lane need one column each side of the rows.
    if TotalH + 2 > DieHBlocks then
      AddFloorplanError(Format('Not enough height: floorplan needs %d blocks (plus 2 pad rows), die has %d.',
        [TotalH, DieHBlocks]));
    if TotalW > DieWBlocks then
      AddFloorplanError(Format('Not enough width: floorplan needs %d blocks, die has %d.',
        [TotalW, DieWBlocks]));

    // Vertically center the stack in the die: the same number of reserved rows
    // above (input pads + routing) and below (output pads + routing), instead
    // of hugging the top edge with a single pad row.
    TopPad := (DieHBlocks - TotalH) div 2;
    if TopPad < 1 then
      TopPad := 1;

    // Bias trunk (red) on the far left, and the vertical bias lanes (red)
    // flanking the clock trunk, all spanning the stack height (the reserved
    // rows above and below stay clear for the I/O pads).
    FillPlanRect(LeftPad, TopPad, LeftPad + FPlanBiasTrunkW, TopPad + TotalH, fcBias, -1);
    // Left feed bias lane (width Lane0W), immediately left of the clock trunk.
    FillPlanRect(XRight, TopPad, XRight + Lane0W, TopPad + TotalH, fcBias, -1);
    // Clock trunk (green), spanning the stack height. It is enclosed by bias:
    // the two flanking lanes on its sides, and the full-width topmost and
    // bottom-most bias rows above and below it.
    FillPlanRect(XRight + Lane0W, TopPad,
      XRight + Lane0W + TrunkW, TopPad + TotalH, fcClock, -1);
    // Far-right bias lane (width Lane1W), spanning the stack height; the
    // top-right corner (the input-pin row) stays empty.
    FillPlanRect(XRight + Lane0W + TrunkW, TopPad, TotalW, TopPad + TotalH, fcBias, -1);

    // Bands, top to bottom; a layer may wrap into several bands. The bands are
    // shifted down by one row so the top row is reserved for input pads.
    SetLength(BandStarts, TotalBands);
    Band := 0;
    CursorY := TopPad; // running Y cursor: bands have per-band heights now
    for L := 0 to NumLayers - 1 do
    begin
      ChunkCount := LevelBandCount[L];
      for C := 0 to ChunkCount - 1 do
      begin
        ChunkWidth := RowWidths[L] - C * AvailableWidth;
        if ChunkWidth > AvailableWidth then
          ChunkWidth := AvailableWidth;
        if ChunkWidth < 1 then
          ChunkWidth := 1;
        BandStart := CursorY;
        BandStarts[Band] := BandStart;
        // Bias line spanning from the bias trunk to the common right edge. The
        // topmost one (band 0) runs the full floorplan width, reaching the
        // far-right bias lane so it encloses the top of the clock trunk.
        if Band = 0 then
          FillPlanRect(LeftPad, BandStart, TotalW,
            BandStart + BandTopBiasH(Band), fcBias, Levels[L])
        else
          FillPlanRect(LeftPad, BandStart, XRight,
            BandStart + BandTopBiasH(Band), fcBias, Levels[L]);
        // Logic row (blue), as wide as its chunk; extra logic rows extend it
        // downward (routing space between logic and clock), computed from locals.
        RowY0 := BandStart + BandTopBiasH(Band);
        RowY1 := RowY0 + RowHBlocks + FLogicRowExtra[Band] + BandMidBiasH(Band);
        FillPlanRect(XLeft, RowY0,
          XLeft + ChunkWidth, RowY0 + RowHBlocks, fcLogic, Levels[L]);
        if FLogicRowExtra[Band] > 0 then
          FillPlanRect(XLeft, RowY0 + RowHBlocks,
            XLeft + ChunkWidth, RowY0 + RowHBlocks + FLogicRowExtra[Band],
            fcLogicFill, Levels[L]);
        // Bias line above the clock row.
        FillPlanRect(LeftPad, RowY1 - BandMidBiasH(Band),
          XRight, RowY1, fcBias, Levels[L]);
        // Clock row (green), as wide as its chunk, left-aligned. Extra clock-
        // row rows extend the clock row downward.
        FillPlanRect(XLeft, RowY1,
          XLeft + ChunkWidth, RowY1 + RowHBlocks, fcClock, Levels[L]);
        if FClockRowExtra[Band] > 0 then
          FillPlanRect(XLeft, RowY1 + RowHBlocks,
            XLeft + ChunkWidth, RowY1 + RowHBlocks +
            FClockRowExtra[Band], fcClockFill, Levels[L]);
        Inc(Band);
        CursorY := CursorY + FPlanBandHeight[Band - 1];
      end;
    end;

    // Bias line below the very bottom cell row (the last band's clock row),
    // stretching the full floorplan width left to right, unbroken, so it
    // encloses the bottom of the clock trunk.
    FillPlanRect(LeftPad, TopPad + TotalH - 1 - FBottomBiasH,
      TotalW, TopPad + TotalH, fcBias, -1);

    // Snapshot the layout for the ordering animation.
    FPlanCore := Core;
    FPlanLevels := Levels.ToArray;
    FPlanNumLayers := NumLayers;
    FPlanLevelFirstBand := LevelFirstBand;
    FPlanLevelBandCount := LevelBandCount;
    FPlanBandStarts := BandStarts;
    FPlanRowHBlocks := RowHBlocks;
    FPlanTrunkW := TrunkW;
    FPlanLane0W := Lane0W;
    FPlanLane1W := Lane1W;
    FPlanLastTotalH := TotalH;

    // Build the immobile I/O anchor pads: inputs on the top row, outputs on the
    // bottom, and the clock input alone at the trunk base on the bottom row.
    SetLength(FPads, 0);
    FPadMap.Clear;
    FClockPadIdx := -1;
    if FPlacementModel <> nil then
    begin
      ClockNetName := '';
      if FClockNet <> nil then
        ClockNetName := FClockNet.SourceNet;
      if ClockNetName = '' then
        ClockNetName := ClockNetFor(FPlacementModel);
      ClockIsInput := (ClockNetName <> '') and
        (FPlacementModel.Inputs.IndexOf(ClockNetName) >= 0);

      // Inputs (top row, Y = 0), excluding the clock input.
      SetLength(InputPadIdx, 0);
      for i := 0 to FPlacementModel.Inputs.Count - 1 do
      begin
        if ClockIsInput and
           SameText(FPlacementModel.Inputs[i], ClockNetName) then
          Continue;
        PadRec.NetName := FPlacementModel.Inputs[i];
        PadRec.X := 0;
        PadRec.Y := 0;
        PadRec.IsInput := True;
        SetLength(FPads, Length(FPads) + 1);
        FPads[High(FPads)] := PadRec;
        SetLength(InputPadIdx, Length(InputPadIdx) + 1);
        InputPadIdx[High(InputPadIdx)] := High(FPads);
      end;
      // Outputs (bottom row, Y = last row of the die).
      SetLength(OutputPadIdx, 0);
      for i := 0 to FPlacementModel.Outputs.Count - 1 do
      begin
        PadRec.NetName := FPlacementModel.Outputs[i];
        PadRec.X := 0;
        PadRec.Y := DieHBlocks - 1;
        PadRec.IsInput := False;
        SetLength(FPads, Length(FPads) + 1);
        FPads[High(FPads)] := PadRec;
        SetLength(OutputPadIdx, Length(OutputPadIdx) + 1);
        OutputPadIdx[High(OutputPadIdx)] := High(FPads);
      end;
      // The clock input: bottom of the die, middle of the clock trunk.
      if ClockIsInput then
      begin
        PadRec.NetName := ClockNetName;
        PadRec.X := XRight + FPlanLane0W + FPlanTrunkW div 2;
        PadRec.Y := DieHBlocks - 1;
        PadRec.IsInput := True;
        SetLength(FPads, Length(FPads) + 1);
        FPads[High(FPads)] := PadRec;
        FPadMap.AddOrSetValue(PadRec.NetName,
          TPoint.Create(PadRec.X, PadRec.Y));
        FClockPadIdx := High(FPads);
      end;
      // Initialize/preserve the display orders (FPads indices). A user
      // reordering persists across rebuilds and optimise.
      if Length(FPadOrderInput) <> Length(InputPadIdx) then
      begin
        SetLength(FPadOrderInput, Length(InputPadIdx));
        for i := 0 to High(FPadOrderInput) do
          FPadOrderInput[i] := InputPadIdx[i];
      end;
      if Length(FPadOrderOutput) <> Length(OutputPadIdx) then
      begin
        SetLength(FPadOrderOutput, Length(OutputPadIdx));
        for i := 0 to High(FPadOrderOutput) do
          FPadOrderOutput[i] := OutputPadIdx[i];
      end;
      ReapplyPadOrder;
    end;

    // Place logic gates (netlist order) into their layer's logic rows, one
    // component per cell with a one-cell gap. Clock placement and bias
    // connections are ignored for now.
    FDroppedCells := 0;
    SetLength(FPlacedComponents, 0);
    FGatePlacement.Clear;
    SetLength(CurChunk, NumLayers);
    SetLength(CurX, NumLayers);
    for L := 0 to NumLayers - 1 do
    begin
      CurChunk[L] := 0;
      CurX[L] := XLeft; // fill the row (from the bias trunk rightwards)
    end;
    if FPlacementModel <> nil then
      for Idx := 0 to FPlacementModel.Gates.Count - 1 do
      begin
        Gate := FPlacementModel.Gates[Idx];
        L := Levels.IndexOf(Gate.ClockLevel);
        if L < 0 then
          Continue; // unleveled / not a floorplan layer
        if Gate.Cell = nil then
          Continue;
        // Component footprint in grid cells (widths/heights are multiples of
        // the core block, as guaranteed by the configuration page).
        P.W := Round(Gate.Cell.Width / Core);
        if P.W < 1 then
          P.W := 1;
        P.H := Round(Gate.Cell.Height / Core);
        if P.H < 1 then
          P.H := 1;
        // Advance to the next chunk of this level if the current one cannot
        // fit the component (component + one-cell gap).
        while (CurChunk[L] < LevelBandCount[L]) and
              (CurX[L] + P.W > XRight) do
        begin
          Inc(CurChunk[L]);
          if CurChunk[L] < LevelBandCount[L] then
            CurX[L] := XLeft
          else
            CurX[L] := High(Integer);
        end;
        if CurChunk[L] >= LevelBandCount[L] then
        begin
          Inc(FDroppedCells);
          Continue; // no more room for this layer
        end;
        BandIndex := LevelFirstBand[L] + CurChunk[L];
        RowY := BandLogicRowY(BandIndex) + ((RowHBlocks - P.H) div 2);
        P.Gate := Gate;
        P.InstanceName := Format('%s_%d', [Gate.CellName, Idx + 1]);
        P.CellName := Gate.CellName;
        P.ClockLevel := Gate.ClockLevel;
        P.X := CurX[L];
        P.Y := RowY;
        SetLength(FPlacedComponents, Length(FPlacedComponents) + 1);
        FPlacedComponents[High(FPlacedComponents)] := P;
        FGatePlacement.Add(Gate, TPoint.Create(P.X, P.Y));
        CurX[L] := CurX[L] + P.W + 1; // component + one-cell gap
      end;

    FFloorplanValid := True;
  finally
    Levels.Free;
  end;

  BuildClockSubtreePlacements;
  BuildSpinePlacement;
  ValidateFloorplanLayout;
  UpdateManhattanDiagnostic;
  RepaintFloorplanPage;
end;

// Walks each layer's real clock tree (from its tap net) and places every cell:
// interior nodes sit balanced in the clock row, leaves stay at their positions.
procedure TForm1.BuildClockSubtreePlacements;
var
  L, i: Integer;
  Visited: TDictionary<TGateInstance, Boolean>;
  ClockPlacement: TDictionary<TGateInstance, TPoint>;
  MapPt: TPoint;
  TreeModel: TBlifModel;
  HasClkCell: Boolean;
  Interior: TArray<Integer>;
  Tmp, j, Idx, W, MinX, NextLeft, BandCount, s, e: Integer;
  RootNode: Integer;

  function WalkNet(const ANetName: string; ClkY: Integer): Integer;
  var
    Net: TNet;
    NC: TNetConnection;
    OutConn: TPinConnection;
    Node, SubIdx: Integer;
    SumX: Double;
    Cnt: Integer;
    Pt: TPoint;
  begin
    Result := -1;
    if (TreeModel = nil) or
       (not TreeModel.Nets.TryGetValue(ANetName, Net)) then
      Exit;
    for NC in Net.Connections do
    begin
      if NC.IsDriver then
        Continue;
      if Visited.ContainsKey(NC.Gate) then
        Continue;
      Visited.Add(NC.Gate, True);
      // Length mask buffers are placed by their own layer, so no node is made
      // for them - but the tree continues through them, so walk their outputs.
      if IsLengthMaskGate(NC.Gate) then
      begin
        for OutConn in NC.Gate.Connections do
          if (OutConn.Port <> nil) and (OutConn.Port.Direction = pdOutput) then
            WalkNet(OutConn.NetName, ClkY);
        Continue;
      end;

      SetLength(FClockSubtree[L], Length(FClockSubtree[L]) + 1);
      Node := High(FClockSubtree[L]);
      FClockSubtree[L][Node].Gate := NC.Gate;

      // Real cell footprint.
      FClockSubtree[L][Node].W := 1;
      FClockSubtree[L][Node].H := 1;
      if NC.Gate.Cell <> nil then
      begin
        FClockSubtree[L][Node].W := Round(NC.Gate.Cell.Width / FPlanCore);
        FClockSubtree[L][Node].H := Round(NC.Gate.Cell.Height / FPlanCore);
        if FClockSubtree[L][Node].W < 1 then
          FClockSubtree[L][Node].W := 1;
        if FClockSubtree[L][Node].H < 1 then
          FClockSubtree[L][Node].H := 1;
      end;

      if CellHasClock(NC.Gate.Cell) then
      begin
        // Leaf: keep its placed position.
        FClockSubtree[L][Node].IsLeaf := True;
        if ClockPlacement.TryGetValue(NC.Gate, Pt) then
        begin
          FClockSubtree[L][Node].X := Pt.X;
          FClockSubtree[L][Node].Y := Pt.Y;
        end
        else
        begin
          FClockSubtree[L][Node].X := (FPlanXLeft + FPlanXRight) div 2;
          FClockSubtree[L][Node].Y := ClkY;
        end;
      end
      else
      begin
        // Interior splitter/buffer: balanced between its children.
        FClockSubtree[L][Node].IsLeaf := False;
        SumX := 0;
        Cnt := 0;
        for OutConn in NC.Gate.Connections do
          if OutConn.Port.Direction = pdOutput then
          begin
            SubIdx := WalkNet(OutConn.NetName, ClkY);
            if SubIdx >= 0 then
            begin
              SetLength(FClockSubtree[L][Node].Children,
                Length(FClockSubtree[L][Node].Children) + 1);
              FClockSubtree[L][Node].Children[
                High(FClockSubtree[L][Node].Children)] := SubIdx;
              SumX := SumX + (FClockSubtree[L][SubIdx].X +
                FClockSubtree[L][SubIdx].W / 2);
              Inc(Cnt);
            end;
          end;
        if Cnt > 0 then
        begin
          FClockSubtree[L][Node].X :=
            Round(SumX / Cnt - FClockSubtree[L][Node].W / 2);
          if FClockSubtree[L][Node].X < FPlanXLeft then
            FClockSubtree[L][Node].X := FPlanXLeft;
          if FClockSubtree[L][Node].X + FClockSubtree[L][Node].W > FPlanXRight then
            FClockSubtree[L][Node].X := FPlanXRight - FClockSubtree[L][Node].W;
          FClockSubtree[L][Node].Y := ClkY - FClockSubtree[L][Node].H div 2;
          if FClockSubtree[L][Node].Y < 0 then
            FClockSubtree[L][Node].Y := 0;
        end
        else
        begin
          FClockSubtree[L][Node].X := (FPlanXLeft + FPlanXRight) div 2;
          FClockSubtree[L][Node].Y := ClkY - FClockSubtree[L][Node].H div 2;
        end;
      end;

      if Result < 0 then
        Result := Node;
    end;
  end;

  // Bottom-up: each interior node joins the band holding the majority of its
  // descendant leaves and sits in that band's clock row. Returns per-band counts.
  function AssignBands(NodeIdx: Integer): TArray<Integer>;
  var
    k, Band, Child, BestBand: Integer;
    Counts, ChildCounts: TArray<Integer>;
  begin
    SetLength(Counts, BandCount);
    if FClockSubtree[L][NodeIdx].IsLeaf then
    begin
      Band := BandIndexOfY(FClockSubtree[L][NodeIdx].Y) - FPlanLevelFirstBand[L];
      if Band < 0 then
        Band := 0;
      if Band >= BandCount then
        Band := BandCount - 1;
      FClockSubtree[L][NodeIdx].Band := Band;
      Counts[Band] := 1;
      Result := Counts;
      Exit;
    end;
    for k := 0 to High(FClockSubtree[L][NodeIdx].Children) do
    begin
      Child := FClockSubtree[L][NodeIdx].Children[k];
      ChildCounts := AssignBands(Child);
      for Band := 0 to BandCount - 1 do
        Counts[Band] := Counts[Band] + ChildCounts[Band];
    end;
    BestBand := 0;
    for Band := 1 to BandCount - 1 do
      if Counts[Band] > Counts[BestBand] then
        BestBand := Band;
    FClockSubtree[L][NodeIdx].Band := BestBand;
    FClockSubtree[L][NodeIdx].Y := BandClockRowY(
      FPlanLevelFirstBand[L] + BestBand) +
      FPlanRowHBlocks div 2 - FClockSubtree[L][NodeIdx].H div 2;
    if FClockSubtree[L][NodeIdx].Y < 0 then
      FClockSubtree[L][NodeIdx].Y := 0;
    Result := Counts;
  end;

begin
  // On a freshly loaded project the clock network may not exist yet (it is
  // normally created when visiting the clock tab); build it on demand so the
  // subtrees appear without a manual round-trip.
  if FClockModel = nil then
    BuildClockModel;
  SetLength(FClockSubtree, FPlanNumLayers);
  // Prefer the delay-replaced (buffered) model; fall back to the original
  // clock model so the row trees still show if the buffered copy was dropped
  // by a stale pipeline rebuild.
  TreeModel := FClockBufferedModel;
  if TreeModel = nil then
    TreeModel := FClockModel;
  Visited := TDictionary<TGateInstance, Boolean>.Create;
  ClockPlacement := TDictionary<TGateInstance, TPoint>.Create;
  try
    if TreeModel = nil then
      AddFloorplanError('Clock tree: no clock model available (rebuild the clock network).')
    else if FClockBufferedModel = nil then
      AddFloorplanError('Clock tree: using original model (buffered copy absent).');
    if FPlacementModel = nil then
      AddFloorplanError('Clock tree: placement model is nil.');
    // The clock model is a deep clone (gates differ but order matches), so map
    // gate i of the clone to gate i of the placement model and its placed position.
    if (FPlacementModel <> nil) and (TreeModel <> nil) then
      for i := 0 to FPlacementModel.Gates.Count - 1 do
        if (i < TreeModel.Gates.Count) and
           FGatePlacement.TryGetValue(FPlacementModel.Gates[i], MapPt) then
          ClockPlacement.AddOrSetValue(TreeModel.Gates[i], MapPt);

    for L := 0 to FPlanNumLayers - 1 do
    begin
      SetLength(FClockSubtree[L], 0);
      Visited.Clear;
      // Level 0 (and any level with no clocked cells) legitimately has no
      // clock tree; only flag a missing tap when clocked cells exist there.
      HasClkCell := False;
      for i := 0 to High(FPlacedComponents) do
        if (FPlacedComponents[i].ClockLevel = FPlanLevels[L]) and
           (FPlacedComponents[i].Gate <> nil) and
           CellHasClock(FPlacedComponents[i].Gate.Cell) then
        begin
          HasClkCell := True;
          Break;
        end;
      if HasClkCell and (TreeModel <> nil) and
         (not TreeModel.Nets.ContainsKey(UNetNaming.ClockRowNetName(FPlanLevels[L]))) then
        AddFloorplanError(Format('Clock tree: tap net "clk_row_%d" missing.',
          [FPlanLevels[L]]));
      RootNode := WalkNet(UNetNaming.ClockRowNetName(FPlanLevels[L]),
        BandClockRowY(FPlanLevelFirstBand[L]) + FPlanRowHBlocks div 2);
      // Spread the level across its wrapped bands (majority-leaf rule). WalkNet
      // appends the root first, so RootNode is the tree root, not the last index.
      if RootNode >= 0 then
      begin
        BandCount := FPlanLevelBandCount[L];
        if BandCount < 1 then
          BandCount := 1;
        AssignBands(RootNode);
      end;
    end;

    // Enforce a one-cell gap between interior nodes sharing a clock row (a chain
    // with clustered leaves would otherwise pile splitters up); per same-Y group.
    for L := 0 to High(FClockSubtree) do
    begin
      SetLength(Interior, 0);
      for i := 0 to High(FClockSubtree[L]) do
        if not FClockSubtree[L][i].IsLeaf then
        begin
          SetLength(Interior, Length(Interior) + 1);
          Interior[High(Interior)] := i;
        end;
      if Length(Interior) < 2 then
        Continue;
      // Stable sort by (Y, X) so each band's row is a contiguous run.
      for i := 1 to High(Interior) do
      begin
        Tmp := Interior[i];
        j := i - 1;
        while (j >= 0) and
              ((FClockSubtree[L][Interior[j]].Y > FClockSubtree[L][Tmp].Y) or
               ((FClockSubtree[L][Interior[j]].Y = FClockSubtree[L][Tmp].Y) and
                (FClockSubtree[L][Interior[j]].X > FClockSubtree[L][Tmp].X))) do
        begin
          Interior[j + 1] := Interior[j];
          Dec(j);
        end;
        Interior[j + 1] := Tmp;
      end;
      s := 0;
      while s < Length(Interior) do
      begin
        e := s;
        while (e < Length(Interior)) and
              (FClockSubtree[L][Interior[e]].Y = FClockSubtree[L][Interior[s]].Y) do
          Inc(e);
        if e - s >= 2 then
        begin
          // Forward pass: keep a one-cell gap, clamped within the row.
          MinX := FPlanXLeft;
          for i := s to e - 1 do
          begin
            Idx := Interior[i];
            W := FClockSubtree[L][Idx].W;
            if FClockSubtree[L][Idx].X < MinX then
              FClockSubtree[L][Idx].X := MinX;
            if FClockSubtree[L][Idx].X + W > FPlanXRight then
              FClockSubtree[L][Idx].X := FPlanXRight - W;
            if FClockSubtree[L][Idx].X < FPlanXLeft then
              FClockSubtree[L][Idx].X := FPlanXLeft;
            MinX := FClockSubtree[L][Idx].X + W + 1;
          end;
          // Backward pass: release any forward push where there is room.
          NextLeft := FPlanXRight;
          for i := e - 1 downto s do
          begin
            Idx := Interior[i];
            W := FClockSubtree[L][Idx].W;
            if FClockSubtree[L][Idx].X + W > FPlanXRight then
              FClockSubtree[L][Idx].X := FPlanXRight - W;
            if FClockSubtree[L][Idx].X + W + 1 > NextLeft then
              FClockSubtree[L][Idx].X := NextLeft - W - 1;
            if FClockSubtree[L][Idx].X < FPlanXLeft then
              FClockSubtree[L][Idx].X := FPlanXLeft;
            NextLeft := FClockSubtree[L][Idx].X;
          end;
        end;
        s := e;
      end;
    end;
  finally
    ClockPlacement.Free;
    Visited.Free;
  end;
end;

// Places the clock trunk: junctions at each layer's base, stage buffers stacked
// upward (overflow to the nearest band's clock row). Trunk cells rotate 90 deg CCW.
procedure TForm1.BuildSpinePlacement;
const
  Gap = 1;
var
  TreeModel: TBlifModel;
  CurNet: string;
  i, j, L, Lv, NextJ, Cursor, BufY, TrunkX, LastB: Integer;
  StepGate: TGateInstance;
  Net: TNet;
  NC: TNetConnection;
  Conn: TPinConnection;
  Gate: TGateInstance;
  Comp: TSpineComponent;
  SegBottom: Double;

  function OutCount(G: TGateInstance): Integer;
  var
    C: TPinConnection;
  begin
    Result := 0;
    if G = nil then
      Exit;
    for C in G.Connections do
      if (C.Port <> nil) and (C.Port.Direction = pdOutput) then
        Inc(Result);
  end;

begin
  SetLength(FSpine, 0);
  TreeModel := FClockBufferedModel;
  if TreeModel = nil then
    TreeModel := FClockModel;
  if (TreeModel = nil) or (FClockNet = nil) then
    Exit;

  // ---- Collect the spine in order: junction, stage buffers, next junction ----
  CurNet := FClockNet.SourceNet;
  while True do
  begin
    Gate := nil;
    if TreeModel.Nets.TryGetValue(CurNet, Net) then
      for NC in Net.Connections do
        if (not NC.IsDriver) and NC.Gate.ClockTrunk then
        begin
          Gate := NC.Gate;
          Break;
        end;
    if Gate = nil then
    begin
      // No junction on this net: step over a 1-in/1-out buffer (a length buffer
      // can sit on the root net) and look again on its output. The buffer is
      // owned by the length mask, not the spine, so it is not collected.
      StepGate := nil;
      if TreeModel.Nets.TryGetValue(CurNet, Net) then
        for NC in Net.Connections do
          if (not NC.IsDriver) and (not CellHasClock(NC.Gate.Cell)) and
             (OutCount(NC.Gate) = 1) then
          begin
            StepGate := NC.Gate;
            Break;
          end;
      if StepGate = nil then
        Break;
      CurNet := '';
      for Conn in StepGate.Connections do
        if (Conn.Port <> nil) and (Conn.Port.Direction = pdOutput) then
        begin
          CurNet := Conn.NetName;
          Break;
        end;
      if CurNet = '' then
        Break;
      Continue;
    end;

    Comp.Gate := Gate;
    Comp.IsJunction := True;
    Comp.Rotated := True;
    Comp.Band := -1;
    Comp.W := 1;
    Comp.H := 1;
    if Gate.Cell <> nil then
    begin
      Comp.W := Round(Gate.Cell.Height / FPlanCore); // rotated: W = height
      Comp.H := Round(Gate.Cell.Width / FPlanCore);
      if Comp.W < 1 then Comp.W := 1;
      if Comp.H < 1 then Comp.H := 1;
    end;
    SetLength(FSpine, Length(FSpine) + 1);
    FSpine[High(FSpine)] := Comp;

    // The delay output net: the junction's SECOND output (the first is its row
    // tree). Keyed on port order so a trunk net reusing a row-net name is still
    // recognised as the trunk.
    CurNet := '';
    Lv := 0;
    for Conn in Gate.Connections do
      if (Conn.Port <> nil) and (Conn.Port.Direction = pdOutput) then
      begin
        Inc(Lv);
        if Lv = 2 then
        begin
          CurNet := Conn.NetName;
          Break;
        end;
      end;
    if CurNet = '' then
      Break;

    // Walk the trunk buffer chain. A trunk buffer is a 1-in/1-out gate; the
    // walk stops at the next junction, at the row-tree root (several outputs),
    // or at a clocked leaf. This lets a buffer sit after the final junction,
    // where there is no following junction.
    while True do
    begin
      Gate := nil;
      if TreeModel.Nets.TryGetValue(CurNet, Net) then
        for NC in Net.Connections do
          if (not NC.IsDriver) and (not NC.Gate.ClockTrunk) and
             (not CellHasClock(NC.Gate.Cell)) and (OutCount(NC.Gate) = 1) and
             (not IsLengthMaskGate(NC.Gate)) then
          begin
            Gate := NC.Gate;
            Break;
          end;
      if Gate = nil then
        Break; // no more buffers on this spine net
      Comp.Gate := Gate;
      Comp.IsJunction := False;
      Comp.Rotated := True;
      Comp.Band := -1;
      Comp.W := 1;
      Comp.H := 1;
      if Gate.Cell <> nil then
      begin
        Comp.W := Round(Gate.Cell.Height / FPlanCore);
        Comp.H := Round(Gate.Cell.Width / FPlanCore);
        if Comp.W < 1 then Comp.W := 1;
        if Comp.H < 1 then Comp.H := 1;
      end;
      SetLength(FSpine, Length(FSpine) + 1);
      FSpine[High(FSpine)] := Comp;
      CurNet := '';
      for Conn in Gate.Connections do
        if (Conn.Port <> nil) and (Conn.Port.Direction = pdOutput) then
        begin
          CurNet := Conn.NetName;
          Break;
        end;
      if CurNet = '' then
        Break;
    end;
  end;

  // ---- Place the junctions at the base of their layers. ---------------------
  // The trunk sits after the left feed lane, so it moves right when the lane widens.
  TrunkX := FPlanXRight + FPlanLane0W;
  for i := 0 to High(FSpine) do
    if FSpine[i].IsJunction then
    begin
      Lv := FSpine[i].Gate.ClockLevel;
      L := -1;
      for j := 0 to High(FPlanLevels) do
        if FPlanLevels[j] = Lv then
        begin
          L := j;
          Break;
        end;
      if L < 0 then
        Continue;
      LastB := FPlanLevelFirstBand[L] + FPlanLevelBandCount[L] - 1;
      SegBottom := BandClockRowY(LastB) + FPlanRowHBlocks;
      FSpine[i].Y := Round(SegBottom - FSpine[i].H);
      FSpine[i].X := TrunkX + (FPlanRowHBlocks - FSpine[i].W) div 2;
      if FSpine[i].X < TrunkX then
        FSpine[i].X := TrunkX;
    end;

  // ---- Place the stage buffers, stacked upward; overflow on collision. ------
  i := 0;
  while i <= High(FSpine) do
  begin
    if not FSpine[i].IsJunction then
    begin
      Inc(i);
      Continue;
    end;
    NextJ := -1;
    for j := i + 1 to High(FSpine) do
      if FSpine[j].IsJunction then
      begin
        NextJ := j;
        Break;
      end;
    Cursor := FSpine[i].Y; // buffers go up from the junction's top
    for j := i + 1 to High(FSpine) do
    begin
      if FSpine[j].IsJunction then
        Break;
      BufY := Cursor - FSpine[j].H - Gap;
      // Trunk components always stay in the clock column and stack upward; they
      // never spill onto a band's clock row. Rows are the length-validation
      // buffers' domain (temporarily), so mixing the two placement spaces there
      // would risk overlaps. If a stage is short the buffer simply sits higher
      // in the column.
      if BufY < 0 then
      begin
        BufY := 0;
        if FSpine[j].Gate <> nil then
          MemoRouting.Lines.Add(Format(
            '  clock trunk full: %s clamped to the top edge.',
            [FSpine[j].Gate.CellName]));
      end;
      FSpine[j].Y := BufY;
      FSpine[j].X := TrunkX + (FPlanRowHBlocks - FSpine[j].W) div 2;
      if FSpine[j].X < TrunkX then
        FSpine[j].X := TrunkX;
      Cursor := BufY;
    end;
    if NextJ < 0 then
      Break;
    i := NextJ;
  end;
end;

// Validates the finished placement: reports cross-set overlaps (logic cells,
// clock cells, trunk cells, pads), dropped logic cells, and clock-tree
// coverage gaps (clocked cells the placed tree failed to reach).
procedure TForm1.ValidateFloorplanLayout;
var
  Occ: TDictionary<Int64, string>;
  i, ClkL, ClkIdx, OverlapCount, MaskX, MaskY: Integer;
  Expected, Actual: Integer;
  Label_: string;

  procedure MarkRect(X, Y, W, H: Integer; const ALabel: string);
  var
    dx, dy: Integer;
    Key: Int64;
  begin
    for dy := 0 to H - 1 do
      for dx := 0 to W - 1 do
      begin
        Key := Int64(Y + dy) * FFloorplanW + (X + dx);
        if Occ.ContainsKey(Key) then
        begin
          Inc(OverlapCount);
          if OverlapCount <= 8 then
            AddFloorplanError(Format('Placement overlap: %s vs %s at (%d,%d).',
              [Occ[Key], ALabel, X + dx, Y + dy]));
        end
        else
          Occ.Add(Key, ALabel);
      end;
  end;

begin
  if (not FFloorplanValid) or (FFloorplanW <= 0) then
    Exit;
  Occ := TDictionary<Int64, string>.Create;
  try
    OverlapCount := 0;

    // Logic cells.
    for i := 0 to High(FPlacedComponents) do
      MarkRect(FPlacedComponents[i].X, FPlacedComponents[i].Y,
        FPlacedComponents[i].W, FPlacedComponents[i].H,
        'logic ' + FPlacedComponents[i].InstanceName);
    // Clock subtree cells (interior only; leaves are the logic cells).
    for ClkL := 0 to High(FClockSubtree) do
      for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
        if not FClockSubtree[ClkL][ClkIdx].IsLeaf then
          MarkRect(FClockSubtree[ClkL][ClkIdx].X, FClockSubtree[ClkL][ClkIdx].Y,
            FClockSubtree[ClkL][ClkIdx].W, FClockSubtree[ClkL][ClkIdx].H,
            'clock cell');
    // Trunk (spine) cells.
    for i := 0 to High(FSpine) do
    begin
      if FSpine[i].IsJunction then
        Label_ := 'junction'
      else
        Label_ := 'buffer';
      MarkRect(FSpine[i].X, FSpine[i].Y, FSpine[i].W, FSpine[i].H, Label_);
    end;
    // Length mask buffers (validation overlay). Positioned from their stored
    // row offsets so this also covers the rebuild that runs before the mask is
    // re-applied.
    for i := 0 to High(FLengthBuffers) do
      if FLengthBuffers[i].Gate <> nil then
      begin
        MaskX := FPlanXLeft + FLengthBuffers[i].XOffset;
        if MaskX + FLengthBuffers[i].W > FPlanXRight then
          MaskX := FPlanXRight - FLengthBuffers[i].W;
        if MaskX < FPlanXLeft then
          MaskX := FPlanXLeft;
        if FLengthBuffers[i].OnClockRow then
          MaskY := BandClockRowY(FLengthBuffers[i].Band)
        else
          MaskY := BandLogicRowY(FLengthBuffers[i].Band);
        MaskY := MaskY + ((FPlanRowHBlocks - FLengthBuffers[i].H) div 2);
        MarkRect(MaskX, MaskY, FLengthBuffers[i].W, FLengthBuffers[i].H,
          'length buffer');
      end;
    // Pads.
    for i := 0 to High(FPads) do
      MarkRect(FPads[i].X, FPads[i].Y, 1, 1, 'pad ' + FPads[i].NetName);

    if OverlapCount > 0 then
      AddFloorplanError(Format('Placement: %d overlapping grid cell(s).',
        [OverlapCount]));

    // Clock-tree coverage: every clocked cell in the model must be a leaf of
    // the placed tree.
    for ClkL := 0 to High(FClockSubtree) do
    begin
      Expected := 0;
      if FPlacementModel <> nil then
        for i := 0 to FPlacementModel.Gates.Count - 1 do
          if (FPlacementModel.Gates[i].ClockLevel = FPlanLevels[ClkL]) and
             CellHasClock(FPlacementModel.Gates[i].Cell) then
            Inc(Expected);
      Actual := 0;
      for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
        if FClockSubtree[ClkL][ClkIdx].IsLeaf then
          Inc(Actual);
      if Actual < Expected then
        AddFloorplanError(Format(
          'Clock tree L%d: only %d of %d clocked cells covered by the tree.',
          [FPlanLevels[ClkL], Actual, Expected]));
    end;

    // Dropped logic cells (could not fit their layer's rows).
    if FDroppedCells > 0 then
      AddFloorplanError(Format(
        'Placement: %d logic cell(s) did not fit and were dropped.',
        [FDroppedCells]));
  finally
    Occ.Free;
  end;
end;

procedure TForm1.RepaintFloorplanPage;
var
  i: Integer;
begin
  if TabControl1.TabIndex <> TabFloorplan then
    Exit;
  for i := 0 to Children.Count - 1 do
    if Children[i] is TControl then
      TControl(Children[i]).Repaint;
end;

procedure TForm1.PaintFloorplan(Sender: TObject; Canvas: TCanvas);
const
  DrawDebugNets = True; // temporary: draw data connections between placements
var
  R: TRectF;
  ClipState: TCanvasSaveState;
  DieW, DieH, Core: Double;
  Cols, Rows, i: Integer;
  X, Y: Single;
  BlockPx, WorldX0, WorldX1, WorldY0, WorldY1: Single;
  I0, I1, J0, J1: Integer;
  BX0, BX1, BY0, BY1, RunStart, RowIdx: Integer;
  ClkL, ClkIdx, ClkChild, Ci: Integer;
  ClkNode: TPlacedClockNode;
  SpineComp: TSpineComponent;
  SpineL: Integer;
  Kind: TFloorplanCell;
  P: TPlacedComponent;
  Net: TNet;
  NC2: TNetConnection;
  Pair: TPair<string, TNet>;
  Driver: TGateInstance;
  SX1, SY1, SX2, SY2: Single;

  function WX(AValue: Single): Single;
  begin
    Result := FPlanPanX + AValue * FPlanZoom;
  end;

  function WY(AValue: Single): Single;
  begin
    Result := FPlanPanY + AValue * FPlanZoom;
  end;

  // Screen centre of a placed gate (world centre transformed to screen).
  function PlacedCenter(G: TGateInstance; out SX, SY: Single): Boolean;
  var
    Pt: TPoint;
    Wb, Hb: Integer;
  begin
    Result := (G <> nil) and FGatePlacement.TryGetValue(G, Pt);
    if not Result then
      Exit;
    Wb := 1;
    Hb := 1;
    if G.Cell <> nil then
    begin
      Wb := Round(G.Cell.Width / Core);
      Hb := Round(G.Cell.Height / Core);
      if Wb < 1 then
        Wb := 1;
      if Hb < 1 then
        Hb := 1;
    end;
    SX := WX((Pt.X + Wb / 2) * Core);
    SY := WY((Pt.Y + Hb / 2) * Core);
  end;

begin
  RefreshDesignConfig;
  R := TRectF.Create(0, 0, PaintBox3.Width, PaintBox3.Height);
  Canvas.Fill.Color := TAlphaColorRec.White;
  Canvas.FillRect(R, 0, 0, [], 1.0);

  // Mask everything outside the paint box (D2D needs the clip while a save
  // state is active, otherwise drawing bleeds onto the buttons).
  ClipState := Canvas.SaveState;
  try
    Canvas.IntersectClipRect(R);

    if (FDesignConfig.CoreUm <= 0) or (FDesignConfig.DieWUm <= 0) or
       (FDesignConfig.DieHUm <= 0) then
    begin
      Canvas.Fill.Color := TAlphaColorRec.Dimgray;
      Canvas.FillText(R, 'No valid floorplan - check the Placement Configuration tab.',
        False, 1.0, [], TTextAlign.Center, TTextAlign.Center);
      Exit;
    end;

    Core := FDesignConfig.CoreUm;
    DieW := FDesignConfig.DieWUm;
    DieH := FDesignConfig.DieHUm;

    Cols := Round(DieW / Core);
    Rows := Round(DieH / Core);

    // Fit the whole die into the canvas the first time we paint with a real
    // size; this is also the most zoomed-out the user can go.
    if FPlanNeedsFit and (PaintBox3.Width > 20) and (PaintBox3.Height > 20) then
    begin
      FPlanZoom := (Min(PaintBox3.Width, PaintBox3.Height) - 20) / Max(DieW, DieH);
      FPlanPanX := (PaintBox3.Width - DieW * FPlanZoom) / 2;
      FPlanPanY := (PaintBox3.Height - DieH * FPlanZoom) / 2;
      FPlanNeedsFit := False;
    end;

    // Die body.
    Canvas.Fill.Color := PalCanvasBg;
    Canvas.FillRect(TRectF.Create(WX(0), WY(0), WX(DieW), WY(DieH)), 0, 0, [], 1.0);

    // Floorplan allocation (blue logic, green clock, red bias), run-merged
    // per row so large uniform regions draw as few rectangles. Hidden when the
    // 'Floorplan' toggle is off.
    if FFloorplanValid and (FPlanZoom > 0) then
    begin
      BX0 := Trunc((0 - FPlanPanX) / FPlanZoom / Core);
      if BX0 < 0 then
        BX0 := 0;
      BX1 := Trunc((PaintBox3.Width - FPlanPanX) / FPlanZoom / Core) + 1;
      if BX1 > FFloorplanW then
        BX1 := FFloorplanW;
      BY0 := Trunc((0 - FPlanPanY) / FPlanZoom / Core);
      if BY0 < 0 then
        BY0 := 0;
      BY1 := Trunc((PaintBox3.Height - FPlanPanY) / FPlanZoom / Core) + 1;
      if BY1 > FFloorplanH then
        BY1 := FFloorplanH;

      // Region fills, hidden when the 'Floorplan' toggle is off. The cells,
      // names, and pads below still draw (gated by their own toggles).
      if CheckBoxShowFloorplan.IsChecked then
      begin
        for RowIdx := BY0 to BY1 - 1 do
        begin
          i := BX0;
          while i < BX1 do
          begin
            Kind := GetPlanCell(i, RowIdx);
            if Kind = fcEmpty then
            begin
              Inc(i);
              Continue;
            end;
            RunStart := i;
            while (i < BX1) and (GetPlanCell(i, RowIdx) = Kind) do
              Inc(i);
            case Kind of
              fcLogic: Canvas.Fill.Color := PalLogicInk;
              fcClock: Canvas.Fill.Color := PalClockInk;
              fcBias:  Canvas.Fill.Color := PalBiasInk;
              fcLogicFill: Canvas.Fill.Color := PalLogicPaper;
              fcClockFill: Canvas.Fill.Color := PalClockPaper;
            end;
            Canvas.FillRect(TRectF.Create(WX(RunStart * Core), WY(RowIdx * Core),
              WX(i * Core), WY((RowIdx + 1) * Core)), 0, 0, [], 1.0);
          end;
        end;
      end;

      // Placed logic components (teal), culled to the visible range; hidden when the
      // 'Cells' toggle is off.
      if CheckBoxShowCells.IsChecked then
        for i := 0 to High(FPlacedComponents) do
        begin
          P := FPlacedComponents[i];
          if (P.X + P.W <= BX0) or (P.X >= BX1) or
             (P.Y + P.H <= BY0) or (P.Y >= BY1) then
            Continue;
          Canvas.Fill.Color := PalCellBlue;
          Canvas.FillRect(TRectF.Create(WX(P.X * Core), WY(P.Y * Core),
            WX((P.X + P.W) * Core), WY((P.Y + P.H) * Core)), 0, 0, [], 1.0);
        end;

      // Cell names (when enabled): overlay each component's instance name.
      if CheckBoxShowNames.IsChecked then
      begin
        Canvas.Fill.Color := TAlphaColorRec.Black;
        Canvas.Font.Size := 8;
        for i := 0 to High(FPlacedComponents) do
        begin
          P := FPlacedComponents[i];
          if (P.X + P.W <= BX0) or (P.X >= BX1) or
             (P.Y + P.H <= BY0) or (P.Y >= BY1) then
            Continue;
          Canvas.FillText(TRectF.Create(
            WX(P.X * Core), WY(P.Y * Core),
            WX((P.X + P.W) * Core), WY((P.Y + P.H) * Core)),
            P.InstanceName, False, 1.0, [], TTextAlign.Center, TTextAlign.Center);
        end;
      end;

      // Clock cells (dark green), drawn with the logic cells so the grid
      // overlays them (hidden with the 'Cells' toggle). Their names show when
      // the 'Cell names' toggle is on.
      if CheckBoxShowCells.IsChecked then
      begin
        Canvas.Fill.Color := PalClockCell;
        for ClkL := 0 to High(FClockSubtree) do
          for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
          begin
            ClkNode := FClockSubtree[ClkL][ClkIdx];
            if ClkNode.IsLeaf then
              Continue;
            Canvas.FillRect(TRectF.Create(
              WX(ClkNode.X * Core), WY(ClkNode.Y * Core),
              WX((ClkNode.X + ClkNode.W) * Core),
              WY((ClkNode.Y + ClkNode.H) * Core)), 0, 0, [], 1.0);
          end;
        for i := 0 to High(FSpine) do
        begin
          SpineComp := FSpine[i];
          Canvas.FillRect(TRectF.Create(
            WX(SpineComp.X * Core), WY(SpineComp.Y * Core),
            WX((SpineComp.X + SpineComp.W) * Core),
            WY((SpineComp.Y + SpineComp.H) * Core)), 0, 0, [], 1.0);
        end;
      end;
      if CheckBoxShowNames.IsChecked then
      begin
        Canvas.Fill.Color := TAlphaColorRec.Black;
        Canvas.Font.Size := 8;
        for ClkL := 0 to High(FClockSubtree) do
          for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
          begin
            ClkNode := FClockSubtree[ClkL][ClkIdx];
            if ClkNode.IsLeaf then
              Continue;
            if ClkNode.Gate <> nil then
              Canvas.FillText(TRectF.Create(
                WX(ClkNode.X * Core), WY(ClkNode.Y * Core),
                WX((ClkNode.X + ClkNode.W) * Core),
                WY((ClkNode.Y + ClkNode.H) * Core)),
                ClkNode.Gate.CellName, False, 1.0, [],
                TTextAlign.Center, TTextAlign.Center);
          end;
        for i := 0 to High(FSpine) do
          if FSpine[i].Gate <> nil then
            Canvas.FillText(TRectF.Create(
              WX(FSpine[i].X * Core), WY(FSpine[i].Y * Core),
              WX((FSpine[i].X + FSpine[i].W) * Core),
              WY((FSpine[i].Y + FSpine[i].H) * Core)),
              FSpine[i].Gate.CellName, False, 1.0, [],
              TTextAlign.Center, TTextAlign.Center);
      end;

    end;

    // Grid of core-block squares as thin filled rectangles (stroke is unreliable
    // here); drawn only when large enough, culled to the visible area.
    BlockPx := Core * FPlanZoom;
    if (BlockPx >= MinBlockPx) and (FPlanZoom > 0) then
    begin
      WorldX0 := (0 - FPlanPanX) / FPlanZoom;
      WorldX1 := (PaintBox3.Width - FPlanPanX) / FPlanZoom;
      WorldY0 := (0 - FPlanPanY) / FPlanZoom;
      WorldY1 := (PaintBox3.Height - FPlanPanY) / FPlanZoom;

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

    // Die boundary, drawn as four filled bars (thicker than the grid).
    Canvas.Fill.Color := PalGreyDark;
    Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(0) - BorderHalf,
      WX(DieW) + BorderHalf, WY(0) + BorderHalf), 0, 0, [], 1.0); // top
    Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(DieH) - BorderHalf,
      WX(DieW) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // bottom
    Canvas.FillRect(TRectF.Create(WX(0) - BorderHalf, WY(0) - BorderHalf,
      WX(0) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // left
    Canvas.FillRect(TRectF.Create(WX(DieW) - BorderHalf, WY(0) - BorderHalf,
      WX(DieW) + BorderHalf, WY(DieH) + BorderHalf), 0, 0, [], 1.0); // right

    // DEBUG: temporary net connections between placed components. Clock pins
    // are skipped (the clock network is not placed yet). Remove with the
    // DrawDebugNets flag; hidden when the 'Logic connections' toggle is off.
    if DrawDebugNets and CheckBoxShowLogicWires.IsChecked and (FPlacementModel <> nil) then
    begin
      Canvas.Stroke.Kind := TBrushKind.Solid;
      Canvas.Stroke.Color := PalSelStroke;
      Canvas.Stroke.Thickness := 2;
      for Pair in FPlacementModel.Nets do
      begin
        Net := Pair.Value;
        Driver := nil;
        for NC2 in Net.Connections do
          if NC2.IsDriver and (not IsClockPinName(NC2.PinName)) and
             FGatePlacement.ContainsKey(NC2.Gate) then
          begin
            Driver := NC2.Gate;
            Break;
          end;
        if Driver = nil then
          Continue;
        if not PlacedCenter(Driver, SX1, SY1) then
          Continue;
        for NC2 in Net.Connections do
        begin
          if NC2.IsDriver then
            Continue;
          if IsClockPinName(NC2.PinName) then
            Continue;
          if not FGatePlacement.ContainsKey(NC2.Gate) then
            Continue;
          // Show the real connectivity (incl. short-path arcs) so no cell
          // looks dangling; wave-pipelined adjacency needs the DFF model.
          if PlacedCenter(NC2.Gate, SX2, SY2) then
            Canvas.DrawLine(TPointF.Create(SX1, SY1), TPointF.Create(SX2, SY2), 1.0);
        end;
      end;
      // Pad wires: connect every data input/output pad to its net's gates (the
      // clock input pad is drawn with the clock wires instead).
      for i := 0 to High(FPads) do
      begin
        if i = FClockPadIdx then
          Continue;
        if not FPlacementModel.Nets.TryGetValue(FPads[i].NetName, Net) then
          Continue;
        SX1 := WX((FPads[i].X + 0.5) * Core);
        SY1 := WY((FPads[i].Y + 0.5) * Core);
        if FPads[i].IsInput then
        begin
          for NC2 in Net.Connections do
            if (not NC2.IsDriver) and
               FGatePlacement.ContainsKey(NC2.Gate) and
               PlacedCenter(NC2.Gate, SX2, SY2) then
              Canvas.DrawLine(TPointF.Create(SX1, SY1),
                TPointF.Create(SX2, SY2), 1.0);
        end
        else
        begin
          for NC2 in Net.Connections do
            if NC2.IsDriver and
               FGatePlacement.ContainsKey(NC2.Gate) and
               PlacedCenter(NC2.Gate, SX2, SY2) then
              Canvas.DrawLine(TPointF.Create(SX1, SY1),
                TPointF.Create(SX2, SY2), 1.0);
        end;
      end;
    end;

    // Clock connections (white) drawn on top; hidden by the 'Clock connections'
    // toggle. The clock cells themselves are drawn earlier, under the grid,
    // together with the logic cells.
    if CheckBoxShowClockWires.IsChecked then
    begin
      Canvas.Stroke.Kind := TBrushKind.Solid;
      Canvas.Stroke.Color := PalOkStroke;
      Canvas.Stroke.Thickness := 1.5;
      // Subtree wires.
      for ClkL := 0 to High(FClockSubtree) do
        for ClkIdx := 0 to High(FClockSubtree[ClkL]) do
          for ClkChild := 0 to High(FClockSubtree[ClkL][ClkIdx].Children) do
          begin
            Ci := FClockSubtree[ClkL][ClkIdx].Children[ClkChild];
            Canvas.DrawLine(
              TPointF.Create(WX((FClockSubtree[ClkL][ClkIdx].X +
                FClockSubtree[ClkL][ClkIdx].W div 2) * Core),
                WY((FClockSubtree[ClkL][ClkIdx].Y +
                  FClockSubtree[ClkL][ClkIdx].H div 2) * Core)),
              TPointF.Create(WX((FClockSubtree[ClkL][Ci].X +
                FClockSubtree[ClkL][Ci].W div 2) * Core),
                WY((FClockSubtree[ClkL][Ci].Y +
                  FClockSubtree[ClkL][Ci].H div 2) * Core)), 1.0);
          end;
      // Trunk spine chain: junction -> buffers -> junction.
      for i := 0 to High(FSpine) - 1 do
        Canvas.DrawLine(
          TPointF.Create(WX((FSpine[i].X + FSpine[i].W div 2) * Core),
            WY((FSpine[i].Y + FSpine[i].H div 2) * Core)),
          TPointF.Create(WX((FSpine[i + 1].X + FSpine[i + 1].W div 2) * Core),
            WY((FSpine[i + 1].Y + FSpine[i + 1].H div 2) * Core)), 1.0);
      // Each junction's tap to its layer's subtree root.
      for i := 0 to High(FSpine) do
        if FSpine[i].IsJunction then
        begin
          SpineL := -1;
          for ClkIdx := 0 to High(FPlanLevels) do
            if FPlanLevels[ClkIdx] = FSpine[i].Gate.ClockLevel then
            begin
              SpineL := ClkIdx;
              Break;
            end;
          if (SpineL >= 0) and (Length(FClockSubtree[SpineL]) > 0) then
            Canvas.DrawLine(
              TPointF.Create(WX((FSpine[i].X + FSpine[i].W div 2) * Core),
                WY((FSpine[i].Y + FSpine[i].H div 2) * Core)),
              TPointF.Create(WX((FClockSubtree[SpineL][0].X +
                FClockSubtree[SpineL][0].W div 2) * Core),
                WY((FClockSubtree[SpineL][0].Y +
                  FClockSubtree[SpineL][0].H div 2) * Core)), 1.0);
        end;
      // Final tap: the lowest clock layer (level 1) has no junction - it is fed
      // directly by the end of the spine.
      if High(FSpine) >= 0 then
      begin
        SpineL := -1;
        for ClkIdx := 0 to High(FPlanLevels) do
          if FPlanLevels[ClkIdx] >= 1 then
          begin
            SpineL := ClkIdx;
            Break; // lowest clock layer
          end;
        if (SpineL >= 0) and (Length(FClockSubtree[SpineL]) > 0) then
          Canvas.DrawLine(
            TPointF.Create(WX((FSpine[High(FSpine)].X +
              FSpine[High(FSpine)].W div 2) * Core),
              WY((FSpine[High(FSpine)].Y + FSpine[High(FSpine)].H div 2) * Core)),
            TPointF.Create(WX((FClockSubtree[SpineL][0].X +
              FClockSubtree[SpineL][0].W div 2) * Core),
              WY((FClockSubtree[SpineL][0].Y +
                FClockSubtree[SpineL][0].H div 2) * Core)), 1.0);
      end;
      // Clock input pad: connect it to the base of the clock tree (the first
      // spine cell), where it feeds the counter-flow network.
      if (FClockPadIdx >= 0) and (High(FSpine) >= 0) then
        Canvas.DrawLine(
          TPointF.Create(WX((FPads[FClockPadIdx].X + 0.5) * Core),
            WY((FPads[FClockPadIdx].Y + 0.5) * Core)),
          TPointF.Create(WX((FSpine[0].X + FSpine[0].W div 2) * Core),
            WY((FSpine[0].Y + FSpine[0].H div 2) * Core)), 1.0);
    end;
  finally
    Canvas.RestoreState(ClipState);
  end;
end;
