// Placement geometry, ordering, bias expansion and pad handling. Included
// from MainWindow's implementation via {\$I Placement.inc} (see FloorPlan.inc).

function TForm1.BandIndexOfY(Y: Integer): Integer;
var
  b: Integer;
begin
  Result := -1;
  for b := 0 to High(FPlanBandStarts) do
    if (b < Length(FPlanBandHeight)) and
       (Y >= FPlanBandStarts[b]) and
       (Y < FPlanBandStarts[b] + FPlanBandHeight[b]) then
    begin
      Result := b;
      Exit;
    end;
end;

// Height of a band's top bias row: base 1 plus any extra current-capacity rows.
function TForm1.BandTopBiasH(Band: Integer): Integer;
begin
  Result := 1;
  if (Band >= 0) and (Band < Length(FBiasRowH)) and
     (Length(FBiasRowH[Band]) > 0) then
    Inc(Result, FBiasRowH[Band][0]);
end;

// Height of a band's middle bias row (the one above the clock row).
function TForm1.BandMidBiasH(Band: Integer): Integer;
begin
  Result := 1;
  if (Band >= 0) and (Band < Length(FBiasRowH)) and
     (Length(FBiasRowH[Band]) > 1) then
    Inc(Result, FBiasRowH[Band][1]);
end;

// Top Y of a band's logic row (below the band's top bias row).
function TForm1.BandLogicRowY(Band: Integer): Integer;
begin
  Result := FPlanBandStarts[Band] + BandTopBiasH(Band);
end;

// Top Y of a band's clock row (below the logic row, its extras, and the
// middle bias row).
function TForm1.BandClockRowY(Band: Integer): Integer;
begin
  Result := BandLogicRowY(Band) + FPlanRowHBlocks + BandMidBiasH(Band);
  if (Band >= 0) and (Band < Length(FLogicRowExtra)) then
    Inc(Result, FLogicRowExtra[Band]);
end;

procedure TForm1.OrderLayer(L: Integer; CrossOnly: Boolean);
var
  Items, Order, CellBand, PlacedX, BandUsed: TArray<Integer>;
  BaryX, BaryY, NbrX: TArray<Double>;
  i, j, k, Idx, TmpIdx, BandStartIdx, BandEndIdx, BandIdx, X, RowY: Integer;
  Pref, d, cand: Integer;
  W, DL, NextLeft: Integer;
  SumX, SumY, TmpX, Dist, BestDist: Double;
  Count, Wb, Hb: Integer;
  Conn: TPinConnection;
  Net: TNet;
  NC: TNetConnection;
  Pt, PadPt: TPoint;
  Changed: Boolean;
begin
  // Collect this layer's placed component indices.
  SetLength(Items, 0);
  for Idx := 0 to High(FPlacedComponents) do
    if FPlacedComponents[Idx].ClockLevel = FPlanLevels[L] then
    begin
      SetLength(Items, Length(Items) + 1);
      Items[High(Items)] := Idx;
    end;
  if Length(Items) = 0 then
    Exit;

  // (X,Y) barycentres from placed neighbours (clock pins excluded).
  SetLength(BaryX, Length(Items));
  SetLength(BaryY, Length(Items));
  for i := 0 to High(Items) do
  begin
    SumX := 0;
    SumY := 0;
    Count := 0;
    if CrossOnly then
      SetLength(NbrX, 0);
    if FPlacedComponents[Items[i]].Gate <> nil then
      for Conn in FPlacedComponents[Items[i]].Gate.Connections do
      begin
        if IsClockPinName(Conn.PinName) then
          Continue;
        if (FPlacementModel = nil) or
           (not FPlacementModel.Nets.TryGetValue(Conn.NetName, Net)) then
          Continue;
        // Immobile I/O anchor: a primary input/output net on this pin is pinned
        // to its pad at the die edge, so it counts as a fixed neighbour in the
        // barycentre (anchors the layout so it cannot float freely).
        if GetPad(Conn.NetName, PadPt) then
        begin
          if CrossOnly then
          begin
            SetLength(NbrX, Length(NbrX) + 1);
            NbrX[High(NbrX)] := PadPt.X + 0.5;
          end;
          SumX := SumX + (PadPt.X + 0.5);
          SumY := SumY + (PadPt.Y + 0.5);
          Inc(Count);
        end;
        for NC in Net.Connections do
        begin
          if NC.Gate = FPlacedComponents[Items[i]].Gate then
            Continue;
          if not FGatePlacement.TryGetValue(NC.Gate, Pt) then
            Continue;
          // CrossOnly orders cells by their neighbours on OTHER layers only, so
          // layer-to-layer wires align and stop crossing; same-layer neighbours
          // are ignored during this phase.
          if CrossOnly and
             (NC.Gate.ClockLevel = FPlacedComponents[Items[i]].ClockLevel) then
            Continue;
          Wb := 1;
          Hb := 1;
          if NC.Gate.Cell <> nil then
          begin
            Wb := Round(NC.Gate.Cell.Width / FPlanCore);
            Hb := Round(NC.Gate.Cell.Height / FPlanCore);
            if Wb < 1 then
              Wb := 1;
            if Hb < 1 then
              Hb := 1;
          end;
          if CrossOnly then
          begin
            SetLength(NbrX, Length(NbrX) + 1);
            NbrX[High(NbrX)] := Pt.X + Wb / 2;
          end;
          SumX := SumX + (Pt.X + Wb / 2);
          SumY := SumY + (Pt.Y + Hb / 2);
          Inc(Count);
        end;
      end;
    if Count > 0 then
    begin
      if CrossOnly then
      begin
        // Median of the cross-layer neighbour X-centres - the classic robust
        // ordering key for crossing minimisation (outliers don't dominate).
        for k := 1 to High(NbrX) do
        begin
          TmpX := NbrX[k];
          j := k - 1;
          while (j >= 0) and (NbrX[j] > TmpX) do
          begin
            NbrX[j + 1] := NbrX[j];
            Dec(j);
          end;
          NbrX[j + 1] := TmpX;
        end;
        BaryX[i] := NbrX[Length(NbrX) div 2];
      end
      else
        BaryX[i] := SumX / Count;
      BaryY[i] := SumY / Count;
    end
    else
    begin
      // No neighbours: keep the current centre so isolated cells stay put.
      BaryX[i] := FPlacedComponents[Items[i]].X +
        FPlacedComponents[Items[i]].W / 2;
      BaryY[i] := FPlacedComponents[Items[i]].Y +
        FPlacedComponents[Items[i]].H / 2;
    end;
  end;

  // Sort cell indices by X barycentre (stable insertion sort).
  SetLength(Order, Length(Items));
  for i := 0 to High(Order) do
    Order[i] := i;
  for i := 1 to High(Order) do
  begin
    TmpIdx := Order[i];
    j := i - 1;
    while (j >= 0) and (BaryX[Order[j]] > BaryX[TmpIdx]) do
    begin
      Order[j + 1] := Order[j];
      Dec(j);
    end;
    Order[j + 1] := TmpIdx;
  end;

  // Band assignment: each cell prefers the closest row centre, spilling to the
  // nearest band with room - a deterministic one-shot decision (no drift).
  BandStartIdx := FPlanLevelFirstBand[L];
  BandEndIdx := BandStartIdx + FPlanLevelBandCount[L];
  SetLength(CellBand, Length(Order));
  SetLength(PlacedX, Length(Order));
  SetLength(BandUsed, BandEndIdx - BandStartIdx);
  for BandIdx := 0 to High(BandUsed) do
    BandUsed[BandIdx] := 0;

  for i := 0 to High(Order) do
  begin
    Idx := Items[Order[i]];
    // Preferred band: the row centre closest to the Y barycentre, so cells are
    // free to migrate between rows in both phases (only the X-ordering key
    // differs) - moving a cell toward its connections' rows shortens wires.
    Pref := BandStartIdx;
    BestDist := MaxSingle;
    for BandIdx := BandStartIdx to BandEndIdx - 1 do
    begin
      Dist := Abs((FPlanBandStarts[BandIdx] + FPlanRowHBlocks / 2) -
        BaryY[Order[i]]);
      if Dist < BestDist then
      begin
        BestDist := Dist;
        Pref := BandIdx;
      end;
    end;
    // Nearest band (from Pref outward) that can still fit this cell.
    CellBand[i] := -1;
    for d := 0 to BandEndIdx - BandStartIdx - 1 do
    begin
      cand := Pref + d;
      if (cand >= BandStartIdx) and (cand < BandEndIdx) and
         (BandUsed[cand - BandStartIdx] +
          FPlacedComponents[Idx].W <= FPlanXRight - FPlanXLeft) then
      begin
        CellBand[i] := cand;
        Break;
      end;
      cand := Pref - d;
      if (d > 0) and (cand >= BandStartIdx) and (cand < BandEndIdx) and
         (BandUsed[cand - BandStartIdx] +
          FPlacedComponents[Idx].W <= FPlanXRight - FPlanXLeft) then
      begin
        CellBand[i] := cand;
        Break;
      end;
    end;
    if CellBand[i] < 0 then
      Break; // no band has room left for this layer
    BandUsed[CellBand[i] - BandStartIdx] :=
      BandUsed[CellBand[i] - BandStartIdx] +
      FPlacedComponents[Idx].W + 1; // width + one-cell gap
  end;

  // Spread each band's cells to their barycentre targets (order preserved) to
  // shorten wires; a forward push + backward release resolves overlaps.
  Changed := False;
  for BandIdx := BandStartIdx to BandEndIdx - 1 do
  begin
    // Forward pass: place each cell at its target left, but not before the
    // previous cell's right edge + gap.
    X := FPlanXLeft;
    for i := 0 to High(Order) do
    begin
      if CellBand[i] <> BandIdx then
        Continue;
      Idx := Items[Order[i]];
      W := FPlacedComponents[Idx].W;
      DL := Round(BaryX[Order[i]] - W / 2);
      if DL < FPlanXLeft then
        DL := FPlanXLeft;
      if DL > FPlanXRight - W then
        DL := FPlanXRight - W;
      if DL < X then
        DL := X;
      PlacedX[i] := DL;
      X := DL + W + 1; // width + one-cell gap
    end;
    // Backward pass: clamp to the row's right edge and release any forward
    // push where there is room to the left (prevents accumulation/drift).
    NextLeft := FPlanXRight;
    for i := High(Order) downto 0 do
    begin
      if CellBand[i] <> BandIdx then
        Continue;
      Idx := Items[Order[i]];
      W := FPlacedComponents[Idx].W;
      if PlacedX[i] + W > FPlanXRight then
        PlacedX[i] := FPlanXRight - W;
      if PlacedX[i] + W + 1 > NextLeft then
        PlacedX[i] := NextLeft - W - 1;
      if PlacedX[i] < FPlanXLeft then
        PlacedX[i] := FPlanXLeft;
      NextLeft := PlacedX[i];
    end;
  end;

  // Write the final positions.
  for i := 0 to High(Order) do
  begin
    if (CellBand[i] < BandStartIdx) or (CellBand[i] >= BandEndIdx) then
      Continue;
    Idx := Items[Order[i]];
    RowY := BandLogicRowY(CellBand[i]) +
      ((FPlanRowHBlocks - FPlacedComponents[Idx].H) div 2);
    if (FPlacedComponents[Idx].X <> PlacedX[i]) or
       (FPlacedComponents[Idx].Y <> RowY) then
      Changed := True;
    FPlacedComponents[Idx].X := PlacedX[i];
    FPlacedComponents[Idx].Y := RowY;
    FGatePlacement.AddOrSetValue(FPlacedComponents[Idx].Gate,
      TPoint.Create(PlacedX[i], RowY));
  end;

  if Changed then
    FOrderChanged := True;
end;

procedure TForm1.ButtonOptimizeClick(Sender: TObject);
begin
  // Latching behavior: if the bias expansion has already run, this re-optimizes
  // from a clean slate - reset the bias expansion state so the floorplan is
  // built with base-width bias lines again, then optimise.
  if FFlowStage >= fsBias then
  begin
    FBiasRowH := nil;
    FBottomBiasH := 0;
    FBiasLaneW := nil;
    FPlanMaxRowW := 0;
    FPlanBiasTrunkW := 1;
    FFlowStage := fsPlacement;
    BuildFloorplan;
  end;
  OptimizePlacement;
  // The user must have successfully optimised the placement before the bias
  // expansion (and hence the routing page) becomes available.
  if (FFloorplanErrorCount = 0) and (FPlacementErrorCount = 0) then
    if FFlowStage < fsPlacement then FFlowStage := fsPlacement;
  UpdateUI;
end;

// True if the configured max bias current exceeds every netlist port's current,
// guarding the expansion against a per-line limit that can never be satisfied.
function TForm1.MaxUaGreaterThanLargestPort: Boolean;
var
  MaxUa, Largest: Double;
  Gate: TGateInstance;
  Port: TPort;
  Shape: TPortShape;
begin
  RefreshDesignConfig;
  Result := False;
  if FLib = nil then
    Exit;
  MaxUa := FDesignConfig.MaxBiasCurrentUa;
  if MaxUa <= 0 then
    Exit;
  Largest := 0;
  // Scan the gates actually in the netlist (the placement model's gates), not
  // the whole library, so unused cells with large ports don't block expansion.
  if FPlacementModel <> nil then
    for Gate in FPlacementModel.Gates do
      if (Gate <> nil) and (Gate.Cell <> nil) then
        for Port in Gate.Cell.PowerPorts do
          for Shape in Port.Shapes do
            if Shape.CurrentUa > Largest then
              Largest := Shape.CurrentUa;
  Result := MaxUa > Largest;
end;

// Grows each horizontal bias channel and the two vertical trunk lanes to hold the
// parallel tracks their summed current needs (EditBiasCurrent per track). One-shot latch.
procedure TForm1.ButtonExpandBiasClick(Sender: TObject);
var
  MaxUa: Double;
  NumBands, Band, GLeft, GRight: Integer;
  b, Upper: Integer;
  Extra: Integer;
  TrunkCount, i, j: Integer;
  TrunkLimit: Double;
  BRows: TArray<TBiasRow>;
  BranchCur: TArray<Double>;
  TrunkOf: TArray<Integer>;
  TmpRow: TBiasRow;
  LogicTop, LogicBot, ClockTop, ClockBot: TArray<Integer>; // tracks per band
  LogicTopP, LogicBotP, ClockTopP, ClockBotP: TArray<TArray<TBiasPort>>;
  Above, Below, TrunkPorts: TArray<TBiasPort>;

  // Which band's row a cell's TOP row sits on; AOnClockRow says whether that is
  // the band's clock row (False = logic row). -1 when not on a logic/clock row.
  function RowBandOf(Y: Integer; var AOnClockRow: Boolean): Integer;
  var
    bb: Integer;
  begin
    AOnClockRow := False;
    for bb := 0 to NumBands - 1 do
    begin
      if (Y >= BandLogicRowY(bb)) and (Y < BandLogicRowY(bb) + FPlanRowHBlocks) then
      begin
        Result := bb;
        Exit;
      end;
      if (Y >= BandClockRowY(bb)) and (Y < BandClockRowY(bb) + FPlanRowHBlocks) then
      begin
        Result := bb;
        AOnClockRow := True;
        Exit;
      end;
    end;
    Result := -1;
  end;

  // Collects the AEdge ports of every placed cell on Band's logic row or clock
  // row, scanning BOTH arrays, so an inserted buffer that landed on the "other"
  // row still connects to the bias row next to it (not a band away).
  procedure CollectRowPorts(Band: Integer; AOnClockRow: Boolean; AEdge: TPortEdge;
    var APorts: TArray<TBiasPort>);
  var
    k, lv, c2, bb: Integer;
    OnClk: Boolean;
    Pt: TPoint;
  begin
    SetLength(APorts, 0);
    for k := 0 to High(FPlacedComponents) do
    begin
      bb := RowBandOf(FPlacedComponents[k].Y, OnClk);
      if (bb = Band) and (OnClk = AOnClockRow) then
        CollectCellPorts(FPlacedComponents[k].Gate, FPlacedComponents[k].X,
          FPlacedComponents[k].Y, AEdge, APorts);
    end;
    for lv := 0 to High(FClockSubtree) do
      for c2 := 0 to High(FClockSubtree[lv]) do
        if not FClockSubtree[lv][c2].IsLeaf then
        begin
          bb := RowBandOf(FClockSubtree[lv][c2].Y, OnClk);
          if (bb = Band) and (OnClk = AOnClockRow) then
            CollectCellPorts(FClockSubtree[lv][c2].Gate, FClockSubtree[lv][c2].X,
              FClockSubtree[lv][c2].Y, AEdge, APorts);
        end;
    // Length mask buffers on this row also consume bias tracks.
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

  // Number of tracks a channel needs: partition the above and below sides into
  // current groups; each group is one track. The final-group merge edge case
  // (the rightmost groups' combined current <= MaxUa) saves one track.
  function SharedTracks(const AAbove, ABelow: TArray<TBiasPort>): Integer;
  var
    GA, GB: TArray<TBiasGroup>;
  begin
    GA := PartitionBiasPorts(AAbove, MaxUa);
    GB := PartitionBiasPorts(ABelow, MaxUa);
    Result := Length(GA) + Length(GB);
    if (Length(GA) > 0) and (Length(GB) > 0) then
      if GA[High(GA)].TotalUa + GB[High(GB)].TotalUa <= MaxUa then
        Dec(Result);
  end;

begin
  RefreshDesignConfig;
  FBiasExpansionFailed := False;
  if not FFloorplanValid then
    Exit;
  MaxUa := FDesignConfig.MaxBiasCurrentUa;
  if MaxUa <= 0 then
  begin
    ReportBiasError('Bias expansion: the max bias current must be positive.');
    Exit;
  end;
  // Guard: the per-line limit must be able to carry the largest single port
  // current in the netlist, otherwise even one channel is under-sized.
  if not MaxUaGreaterThanLargestPort then
  begin
    ReportBiasError('Bias expansion: the max bias current is below the largest cell port current.');
    Exit;
  end;
  NumBands := Length(FPlanBandStarts);
  if NumBands < 1 then
    Exit;
  if Length(FBiasRowH) < NumBands then
  begin
    SetLength(FBiasRowH, NumBands);
    for b := 0 to NumBands - 1 do
    begin
      SetLength(FBiasRowH[b], 2);
      FBiasRowH[b][0] := 0;
      FBiasRowH[b][1] := 0;
    end;
  end;
  if Length(FBiasLaneW) <> 2 then
  begin
    SetLength(FBiasLaneW, 2);
    FBiasLaneW[0] := 1;
    FBiasLaneW[1] := 1;
  end;

  // Clock bias groups: the trunk's left ("top") ports top-to-bottom and right
  // ("bottom") ports bottom-to-top. Each group needs one vertical lane track and
  // one horizontal turn row in the topmost/bottommost full-width bias row.
  CollectTrunkPorts(True, TrunkPorts);
  GLeft := Length(PartitionTrunkPorts(TrunkPorts, MaxUa, False));
  CollectTrunkPorts(False, TrunkPorts);
  GRight := Length(PartitionTrunkPorts(TrunkPorts, MaxUa, True));

  // Partition each row side's ports into current groups. The number of groups
  // IS the number of horizontal tracks the channel needs (a partition
  // guideline, not a ceil of the summed current).
  SetLength(LogicTopP, NumBands);
  SetLength(LogicBotP, NumBands);
  SetLength(ClockTopP, NumBands);
  SetLength(ClockBotP, NumBands);
  SetLength(LogicTop, NumBands);
  SetLength(LogicBot, NumBands);
  SetLength(ClockTop, NumBands);
  SetLength(ClockBot, NumBands);
  for b := 0 to NumBands - 1 do
  begin
    CollectLogic(b, peTop, LogicTopP[b]);
    CollectLogic(b, peBottom, LogicBotP[b]);
    CollectClock(b, peTop, ClockTopP[b]);
    CollectClock(b, peBottom, ClockBotP[b]);
    LogicTop[b] := Length(PartitionBiasPorts(LogicTopP[b], MaxUa));
    LogicBot[b] := Length(PartitionBiasPorts(LogicBotP[b], MaxUa));
    ClockTop[b] := Length(PartitionBiasPorts(ClockTopP[b], MaxUa));
    ClockBot[b] := Length(PartitionBiasPorts(ClockBotP[b], MaxUa));
  end;

  // KNOWN QUIRK: bias rows/columns grown below persist. BuildFloorplan remaps
  // and keeps FBiasRowH / FBiasLaneW / FBottomBiasH / FPlanBiasTrunkW across
  // rebuilds and there is no teardown, so a validation pass can leave the
  // floorplan wider than strictly needed. That is harmless (every geometry
  // accessor reads the current heights, so wider rows are just unused area),
  // and the sizing checks below compare against the current allocation so
  // nothing grows unboundedly.
  // --- Horizontal channels (bias rows) ---
  // Topmost full-width row must hold both the top logic tracks and the trunk's left turn rows.
  Extra := (LogicTop[0] + GLeft) - BandTopBiasH(0);
  if Extra < 0 then
    Extra := 0;
  if Extra > 0 then
    IncreaseTopBottomBiasRow(True, Extra);
  // Bottommost full-width row: the last band's clock-row bottom ports
  // (ClockBot[last] tracks) plus the clock trunk's right turn rows (GRight).
  Extra := (ClockBot[NumBands - 1] + GRight) - (1 + FBottomBiasH);
  if Extra < 0 then
    Extra := 0;
  if Extra > 0 then
    IncreaseTopBottomBiasRow(False, Extra);
  // Interior channels: each band's MIDDLE row spans logic (above) to clock (below),
  // its TOP row (band > 0) the previous band's clock to this band's logic.
  for Band := 0 to NumBands - 1 do
  begin
    // Middle bias row: logic (above) + clock (below).
    Above := LogicBotP[Band];
    Below := ClockTopP[Band];
    // Only add what the current row cannot already hold.
    Extra := SharedTracks(Above, Below) - BandMidBiasH(Band);
    if Extra < 0 then
      Extra := 0;
    if Extra > 0 then
      IncreaseBiasRowHeight(Band, 1, Extra);
    // Top bias row (skip band 0: it is the topmost full-width row).
    if Band > 0 then
    begin
      Upper := Band - 1;
      Above := ClockBotP[Upper];
      Below := LogicTopP[Band];
      Extra := SharedTracks(Above, Below) - BandTopBiasH(Band);
      if Extra < 0 then
        Extra := 0;
      if Extra > 0 then
        IncreaseBiasRowHeight(Band, 0, Extra);
    end;
  end;

  // --- Clock bias lanes (flanking the clock trunk) ---
  // Lane width = the number of clock groups, not ceil(total/max).
  Extra := GLeft - FPlanLane0W;
  if Extra < 0 then
    Extra := 0;
  if Extra > 0 then
    IncreaseClockTrunkColumn(0, Extra);
  Extra := GRight - FPlanLane1W;
  if Extra < 0 then
    Extra := 0;
  if Extra > 0 then
    IncreaseClockTrunkColumn(1, Extra);

  // --- Bias trunk (far left): pack branches onto shared trunks ---
  // The current limit applies to every wire in the bias network, but the trunk
  // limit lets several branches share one trunk wire, so the trunk needs one
  // column per TRUNK (not per branch). Rows are packed top-to-bottom greedily.
  BuildBiasRows(MaxUa, BRows);
  for i := 1 to High(BRows) do
  begin
    TmpRow := BRows[i];
    j := i - 1;
    while (j >= 0) and (BRows[j].Y > TmpRow.Y) do
    begin
      BRows[j + 1] := BRows[j];
      Dec(j);
    end;
    BRows[j + 1] := TmpRow;
  end;
  SetLength(BranchCur, Length(BRows));
  for i := 0 to High(BRows) do
    BranchCur[i] := BRows[i].CurrentUa;
  TrunkLimit := FDesignConfig.MaxBiasTrunkCurrentUa;
  if TrunkLimit < MaxUa then
    TrunkLimit := MaxUa; // a trunk must at least carry one branch
  TrunkOf := PackBiasTrunks(BranchCur, TrunkLimit);
  TrunkCount := 1;
  for i := 0 to High(TrunkOf) do
    if TrunkOf[i] + 1 > TrunkCount then
      TrunkCount := TrunkOf[i] + 1;
  Extra := TrunkCount - FPlanBiasTrunkW;
  if Extra > 0 then
    IncreaseBiasTrunkColumn(Extra);

  if FBiasExpansionFailed then
  begin
    // Some rows grew and the floorplan is still valid, but the bias network
    // cannot be completed. Stop before routing overlaps the neighbouring rows.
    ReportBiasError('Bias expansion stopped: the die cannot hold the bias lines. ' +
      'Increase the die height/width (or reduce the bias current) and rebuild.');
    UpdateUI;
    RepaintFloorplanPage;
    Exit;
  end;
  if FFlowStage < fsBias then FFlowStage := fsBias;
  UpdateUI;
  RepaintFloorplanPage;
end;

// Runs the barycentre relaxation (cross-only ordering first to untangle
// layer-to-layer wires, then the full optimisation alternating the sweep
// direction), then guarantees no overlaps and rebuilds the clock placements.
procedure TForm1.OptimizePlacement;
var
  Pass, L: Integer;
begin
  if not FFloorplanValid then
    Exit;
  if Length(FPlacedComponents) = 0 then
    Exit;
  // Clear the previous diagnostics so the listbox shows only the CURRENT
  // (post-optimize) overlaps/coverage, not the ones from the initial build.
  ListBoxFloorplanErrors.Clear;
  FFloorplanErrorCount := 0;
  FManhattanItem := nil;
  // Phase 1 - untangle: order cells only by their neighbours on other layers,
  // alternating the sweep direction, so layer-to-layer wires align and stop
  // crossing before the full optimisation runs.
  for Pass := 0 to MaxCrossPasses - 1 do
  begin
    FOrderChanged := False;
    if Pass mod 2 = 0 then
      for L := 0 to FPlanNumLayers - 1 do
        OrderLayer(L, True)
    else
      for L := FPlanNumLayers - 1 downto 0 do
        OrderLayer(L, True);
    if not FOrderChanged then
      Break; // converged
  end;
  // Phase 2 - full barycentre optimisation (all neighbours, X and Y),
  // alternating the sweep direction so the Gauss-Seidel bias cancels.
  for Pass := 0 to MaxOrderPasses - 1 do
  begin
    FOrderChanged := False;
    if Pass mod 2 = 0 then
      for L := 0 to FPlanNumLayers - 1 do
        OrderLayer(L, False)
    else
      for L := FPlanNumLayers - 1 downto 0 do
        OrderLayer(L, False);
    if not FOrderChanged then
      Break; // converged
  end;
  ResolvePlacementOverlaps; // guarantee cells never overlap
  BuildClockSubtreePlacements; // rebuild the balanced clock subtrees
  BuildSpinePlacement;
  ValidateFloorplanLayout;
  UpdateManhattanDiagnostic;
  RepaintFloorplanPage;
end;

// Rebuilds the bias geometry without reshuffling cells: snapshots each cell's X,
// rebuilds, restores the optimized X, shifting rows left that no longer fit.
procedure TForm1.RebuildFloorplanPreserve;
var
  LogicSnap, ClockSnap: TDictionary<TGateInstance, TPlaceSnapshot>;
  CloneToPlace: TDictionary<TGateInstance, TGateInstance>;
  S: TPlaceSnapshot;
  i, L, ci, band: Integer;
  RowCells: TArray<Integer>;
  j, MaxRight, Shift: Integer;
  Pt: TPoint;
  PGate: TGateInstance;
begin
  if not FFloorplanValid then
  begin
    BuildFloorplan;
    Exit;
  end;
  LogicSnap := TDictionary<TGateInstance, TPlaceSnapshot>.Create;
  ClockSnap := TDictionary<TGateInstance, TPlaceSnapshot>.Create;
  CloneToPlace := TDictionary<TGateInstance, TGateInstance>.Create;
  try
    // Logic cells: snapshot the horizontal offset from the row's left edge.
    // (The vertical position is recomputed by BuildFloorplan for the new band
    // geometry, so only the optimized X arrangement is preserved.)
    for i := 0 to High(FPlacedComponents) do
    begin
      S.Gate := FPlacedComponents[i].Gate;
      S.X := FPlacedComponents[i].X - FPlanXLeft;
      LogicSnap.AddOrSetValue(S.Gate, S);
    end;
    // Clock tree interior nodes: same - keep the horizontal offset, let the
    // rebuilt clock placement set the row Y.
    for L := 0 to High(FClockSubtree) do
      for ci := 0 to High(FClockSubtree[L]) do
        if not FClockSubtree[L][ci].IsLeaf then
        begin
          S.Gate := FClockSubtree[L][ci].Gate;
          S.X := FClockSubtree[L][ci].X - FPlanXLeft;
          ClockSnap.AddOrSetValue(S.Gate, S);
        end;

    BuildFloorplan;

    // Restore logic cells' X (keeps the optimized horizontal row layout). The
    // Y is left as BuildFloorplan computed it for the current band geometry.
    for i := 0 to High(FPlacedComponents) do
      if LogicSnap.TryGetValue(FPlacedComponents[i].Gate, S) then
      begin
        FPlacedComponents[i].X := FPlanXLeft + S.X;
        FGatePlacement.AddOrSetValue(FPlacedComponents[i].Gate,
          TPoint.Create(FPlacedComponents[i].X, FPlacedComponents[i].Y));
      end;
    // Restore clock tree interior nodes' X.
    for L := 0 to High(FClockSubtree) do
      for ci := 0 to High(FClockSubtree[L]) do
        if (not FClockSubtree[L][ci].IsLeaf) and
           ClockSnap.TryGetValue(FClockSubtree[L][ci].Gate, S) then
          FClockSubtree[L][ci].X := FPlanXLeft + S.X;

    // A grown bias lane narrows the rows: shift each band's cells left uniformly
    // so they fit, moving logic cells and clock-row nodes together.
    for band := 0 to High(FPlanBandStarts) do
    begin
      SetLength(RowCells, 0);
      for i := 0 to High(FPlacedComponents) do
        if BandIndexOfY(FPlacedComponents[i].Y) = band then
        begin
          SetLength(RowCells, Length(RowCells) + 1);
          RowCells[High(RowCells)] := i;
        end;
      MaxRight := FPlanXLeft - 1;
      for j := 0 to High(RowCells) do
        if FPlacedComponents[RowCells[j]].X +
           FPlacedComponents[RowCells[j]].W > MaxRight then
          MaxRight := FPlacedComponents[RowCells[j]].X +
            FPlacedComponents[RowCells[j]].W;
      // Include the clock-row interior nodes of the same band: they sit in the
      // same row region and must move with it.
      for L := 0 to High(FClockSubtree) do
        for ci := 0 to High(FClockSubtree[L]) do
          if (not FClockSubtree[L][ci].IsLeaf) and
             (BandIndexOfY(FClockSubtree[L][ci].Y) = band) then
            if FClockSubtree[L][ci].X + FClockSubtree[L][ci].W > MaxRight then
              MaxRight := FClockSubtree[L][ci].X + FClockSubtree[L][ci].W;
      if MaxRight > FPlanXRight then
      begin
        Shift := MaxRight - FPlanXRight;
        // Whole-row shift only. If the row is physically wider than the die,
        // do not squash it - report and leave the layout alone.
        if Shift > FPlanXRight - FPlanXLeft then
          AddFloorplanError(Format(
            'Placement: band %d is wider than the die; not shifting.', [band]))
        else
        begin
          for j := 0 to High(RowCells) do
          begin
            FPlacedComponents[RowCells[j]].X :=
              FPlacedComponents[RowCells[j]].X - Shift;
            FGatePlacement.AddOrSetValue(FPlacedComponents[RowCells[j]].Gate,
              TPoint.Create(FPlacedComponents[RowCells[j]].X,
                FPlacedComponents[RowCells[j]].Y));
          end;
          // Shift the clock-row interior nodes by the same amount.
          for L := 0 to High(FClockSubtree) do
            for ci := 0 to High(FClockSubtree[L]) do
              if (not FClockSubtree[L][ci].IsLeaf) and
                 (BandIndexOfY(FClockSubtree[L][ci].Y) = band) then
                FClockSubtree[L][ci].X := FClockSubtree[L][ci].X - Shift;
        end;
      end;
    end;

    // Re-sync clocked leaves to their (possibly shifted) logic cells: the subtree
    // gates are clock-model clones, mapped back by index before the lookup.
    if (FPlacementModel <> nil) and (FClockBufferedModel <> nil) and
       (FClockBufferedModel.Gates.Count > 0) then
      for i := 0 to FPlacementModel.Gates.Count - 1 do
        if (i < FClockBufferedModel.Gates.Count) and
           (not CloneToPlace.ContainsKey(FClockBufferedModel.Gates[i])) then
          CloneToPlace.Add(FClockBufferedModel.Gates[i], FPlacementModel.Gates[i]);
    if (FPlacementModel <> nil) and (FClockModel <> nil) and
       (FClockModel.Gates.Count > 0) then
      for i := 0 to FPlacementModel.Gates.Count - 1 do
        if (i < FClockModel.Gates.Count) and
           (not CloneToPlace.ContainsKey(FClockModel.Gates[i])) then
          CloneToPlace.Add(FClockModel.Gates[i], FPlacementModel.Gates[i]);
    for L := 0 to High(FClockSubtree) do
      for ci := 0 to High(FClockSubtree[L]) do
        if FClockSubtree[L][ci].IsLeaf and
           CloneToPlace.TryGetValue(FClockSubtree[L][ci].Gate, PGate) and
           FGatePlacement.TryGetValue(PGate, Pt) then
        begin
          FClockSubtree[L][ci].X := Pt.X;
          FClockSubtree[L][ci].Y := Pt.Y;
        end;

    ValidateFloorplanLayout;
    UpdateManhattanDiagnostic;
  finally
    LogicSnap.Free;
    ClockSnap.Free;
    CloneToPlace.Free;
  end;
  RepaintFloorplanPage;
end;

procedure TForm1.CheckBoxToggleChange(Sender: TObject);
begin
  if TabControl1.TabIndex = TabFloorplan then
    RepaintFloorplanPage;
end;

procedure TForm1.ResolvePlacementOverlaps;
var
  MaxBand, BandIdx, i, j, Idx, Tmp, MinX: Integer;
  Items: TArray<Integer>;
begin
  if Length(FPlacedComponents) = 0 then
    Exit;
  MaxBand := 0;
  for i := 0 to High(FPlacedComponents) do
  begin
    BandIdx := BandIndexOfY(FPlacedComponents[i].Y);
    if BandIdx > MaxBand then
      MaxBand := BandIdx;
  end;
  for BandIdx := 0 to MaxBand do
  begin
    // Collect the band's cells, then order them by X.
    SetLength(Items, 0);
    for i := 0 to High(FPlacedComponents) do
      if BandIndexOfY(FPlacedComponents[i].Y) = BandIdx then
      begin
        SetLength(Items, Length(Items) + 1);
        Items[High(Items)] := i;
      end;
    if Length(Items) < 2 then
      Continue;
    for i := 1 to High(Items) do
    begin
      Tmp := Items[i];
      j := i - 1;
      while (j >= 0) and (FPlacedComponents[Items[j]].X > FPlacedComponents[Tmp].X) do
      begin
        Items[j + 1] := Items[j];
        Dec(j);
      end;
      Items[j + 1] := Tmp;
    end;
    // Enforce the 1-cell gap so cells can never overlap, and clamp within the
    // row so nothing runs off the die. Safe for the length mask: this runs in
    // OptimizePlacement, before the mask is built; during validation rows only
    // move as units (RebuildFloorplanPreserve).
    for i := 1 to High(Items) do
    begin
      MinX := FPlacedComponents[Items[i - 1]].X +
        FPlacedComponents[Items[i - 1]].W + 1;
      Idx := Items[i];
      if FPlacedComponents[Idx].X < MinX then
        FPlacedComponents[Idx].X := MinX;
      if FPlacedComponents[Idx].X + FPlacedComponents[Idx].W > FPlanXRight then
        FPlacedComponents[Idx].X := FPlanXRight - FPlacedComponents[Idx].W;
      if FPlacedComponents[Idx].X < FPlanXLeft then
        FPlacedComponents[Idx].X := FPlanXLeft;
      FGatePlacement.AddOrSetValue(FPlacedComponents[Idx].Gate,
        TPoint.Create(FPlacedComponents[Idx].X, FPlacedComponents[Idx].Y));
    end;
  end;
end;

procedure TForm1.AddFloorplanError(const Text: string);
var
  Item: TListBoxItem;
begin
  Item := TListBoxItem.Create(ListBoxFloorplanErrors);
  Item.Parent := ListBoxFloorplanErrors;
  Item.Text := '[ERROR] ' + Text;
  Item.StyledSettings := Item.StyledSettings - [TStyledSetting.FontColor];
  Item.TextSettings.FontColor := PalRed;
  Inc(FFloorplanErrorCount);
end;

// Bias expansion can be triggered from the placement page (Expand Bias Lines)
// and from validation. Both surfaces need the message, so report to the
// floorplan error list and to the routing log, and latch the failure so the
// caller does not route a layout whose bias rows are under-sized.
procedure TForm1.ReportBiasError(const Text: string);
begin
  FBiasExpansionFailed := True;
  AddFloorplanError(Text);
  MemoRouting.Lines.Add('[bias] ' + Text);
end;

// World-space (um) centre of a placed gate. Mirrors PlacedCenter but in the
// placement's real coordinate system instead of screen pixels.
function TForm1.CellCenterUm(G: TGateInstance; Core: Double;
  var UX, UY: Double): Boolean;
var
  Pt: TPoint;
  Wb, Hb: Double;
begin
  Result := (G <> nil) and FGatePlacement.TryGetValue(G, Pt);
  if not Result then
    Exit;
  Wb := 1;
  Hb := 1;
  if G.Cell <> nil then
  begin
    Wb := G.Cell.Width / Core;
    Hb := G.Cell.Height / Core;
    if Wb < 1 then
      Wb := 1;
    if Hb < 1 then
      Hb := 1;
  end;
  UX := (Pt.X + Wb / 2) * Core;
  UY := (Pt.Y + Hb / 2) * Core;
end;

// Manhattan wire length (um) of one net: its placed, non-clock driver to each
// of its placed, non-clock loads. Clock pins and unplaced gates are ignored,
// exactly like the debug wire rendering.
function TForm1.NetManhattan(Net: TNet): Double;
var
  NC: TNetConnection;
  Driver, Load: TGateInstance;
  Core, SX1, SY1, SX2, SY2: Double;
begin
  RefreshDesignConfig;
  Result := 0;
  Core := FDesignConfig.CoreUm;
  if Core <= 0 then
    Core := FPlanCore;
  Driver := nil;
  for NC in Net.Connections do
    if NC.IsDriver and (not IsClockPinName(NC.PinName)) and
       FGatePlacement.ContainsKey(NC.Gate) then
    begin
      Driver := NC.Gate;
      Break;
    end;
  if Driver = nil then
    Exit;
  if not CellCenterUm(Driver, Core, SX1, SY1) then
    Exit;
  for NC in Net.Connections do
  begin
    if NC.IsDriver then
      Continue;
    if IsClockPinName(NC.PinName) then
      Continue;
    Load := NC.Gate;
    if not CellCenterUm(Load, Core, SX2, SY2) then
      Continue;
    Result := Result + Abs(SX1 - SX2) + Abs(SY1 - SY2);
  end;
end;

// Sum of Manhattan distances (in um) of every data connection the debug wires
// draw - the total of all nets' driver->load lengths.
function TForm1.TotalManhattanDistance: Double;
var
  Pair: TPair<string, TNet>;
begin
  Result := 0;
  if (FPlacementModel = nil) or (FPlacementModel.Nets = nil) then
    Exit;
  for Pair in FPlacementModel.Nets do
    Result := Result + NetManhattan(Pair.Value);
end;

procedure TForm1.UpdateManhattanDiagnostic;
var
  Total: Double;
begin
  if ListBoxFloorplanErrors = nil then
    Exit;
  Total := TotalManhattanDistance;
  if FManhattanItem = nil then
  begin
    FManhattanItem := TListBoxItem.Create(ListBoxFloorplanErrors);
    FManhattanItem.Parent := ListBoxFloorplanErrors;
  end;
  FManhattanItem.Text := Format('Total wire length (Manhattan): %.0f um', [Total]);
end;

// Returns the immobile pad position for a primary input/output net, if any.
function TForm1.GetPad(const ANetName: string; var P: TPoint): Boolean;
begin
  Result := (FPadMap <> nil) and FPadMap.TryGetValue(ANetName, P);
end;

// X (grid blocks) of display slot k in a row of N pads, evenly spaced from
// the left edge to Right (Right = row right for inputs, clock trunk right for
// outputs).
function TForm1.PadSlotX(k, N, Right: Integer): Single;
begin
  Result := FPlanXLeft + (k + 0.5) * (Right - FPlanXLeft - 1) / Max(1, N);
end;

// The slot (0..N-1) whose X is closest to DragX within [FPlanXLeft, Right).
function TForm1.NearestPadSlot(DragX: Single; N, Right: Integer): Integer;
var
  k: Integer;
  BestD, D: Single;
begin
  Result := 0;
  BestD := Abs(PadSlotX(0, N, Right) - DragX);
  for k := 1 to N - 1 do
  begin
    D := Abs(PadSlotX(k, N, Right) - DragX);
    if D < BestD then
    begin
      BestD := D;
      Result := k;
    end;
  end;
end;

// Copy of the order array with DragIdx moved to display Slot (others shift).
function TForm1.PreviewPadOrder(const Ord: TArray<Integer>;
  DragIdx, Slot: Integer): TArray<Integer>;
var
  i, k: Integer;
begin
  Result := Copy(Ord);
  k := -1;
  for i := 0 to High(Result) do
    if Result[i] = DragIdx then
    begin
      k := i;
      Break;
    end;
  if k < 0 then
    Exit;
  for i := k to High(Result) - 1 do
    Result[i] := Result[i + 1];
  SetLength(Result, Length(Result) - 1);
  SetLength(Result, Length(Result) + 1);
  for i := High(Result) downto Slot + 1 do
    Result[i] := Result[i - 1];
  Result[Slot] := DragIdx;
end;

// Recomputes every pad's X position and FPadMap from the display orders.
procedure TForm1.ReapplyPadOrder;
var
  N, M, k, Idx, X: Integer;
begin
  N := Length(FPadOrderInput);
  M := Length(FPadOrderOutput);
  for k := 0 to N - 1 do
  begin
    Idx := FPadOrderInput[k];
    if (Idx >= 0) and (Idx < Length(FPads)) then
    begin
      X := Round(PadSlotX(k, N, FPlanXRight));
      FPads[Idx].X := X;
      FPadMap.AddOrSetValue(FPads[Idx].NetName, TPoint.Create(X, FPads[Idx].Y));
    end;
  end;
  for k := 0 to M - 1 do
  begin
    Idx := FPadOrderOutput[k];
    if (Idx >= 0) and (Idx < Length(FPads)) then
    begin
      X := Round(PadSlotX(k, M, FPlanXRight + FPlanLane0W + FPlanTrunkW));
      FPads[Idx].X := X;
      FPadMap.AddOrSetValue(FPads[Idx].NetName, TPoint.Create(X, FPads[Idx].Y));
    end;
  end;
end;

procedure TForm1.SetPlanCell(X, Y: Integer; Kind: TFloorplanCell; ALayer: Integer);
begin
  if (X >= 0) and (X < FFloorplanW) and (Y >= 0) and (Y < FFloorplanH) then
  begin
    FFloorplan[Y * FFloorplanW + X] := Kind;
    FFloorplanLayer[Y * FFloorplanW + X] := ALayer;
  end;
end;

function TForm1.GetPlanCell(X, Y: Integer): TFloorplanCell;
begin
  if (X >= 0) and (X < FFloorplanW) and (Y >= 0) and (Y < FFloorplanH) then
    Result := FFloorplan[Y * FFloorplanW + X]
  else
    Result := fcEmpty;
end;

procedure TForm1.FillPlanRect(X0, Y0, X1, Y1: Integer; Kind: TFloorplanCell;
  ALayer: Integer);
var
  x, y: Integer;
begin
  for y := Y0 to Y1 - 1 do
    for x := X0 to X1 - 1 do
      SetPlanCell(x, y, Kind, ALayer);
end;
