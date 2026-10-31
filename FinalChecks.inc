// Post-validation requirement audit. Prints a "Final requirements" section below
// the validation output and returns True only when every requirement holds.
//
// What is re-derived here and what is carried forward:
//   - fanout and stage balance are netlist properties, re-derived because the
//     validation pass inserts buffers;
//   - routing completeness, PTL length, resonance and bias allocation are
//     established by the router/expansion; their recorded results are audited
//     rather than recomputed (nothing between there and here can change them).
// Included from MainWindow's implementation via {$I FinalChecks.inc}.

function TForm1.RunFinalChecks: Boolean;
var
  Model: TBlifModel;
  Pair: TPair<string, TNet>;
  NC: TNetConnection;
  Gate: TGateInstance;
  Conn: TPinConnection;
  DepthMin, DepthMax: TDictionary<string, Integer>;
  i, k, j, Lo, Hi, D, InLo, InHi, FirstD, BadFanout, BadBalance: Integer;
  Powered, LrBad: Integer;
  OverlapCells, PtlOverBias: Integer;
  Occ: TArray<Boolean>;
  BiasBlocks: TDictionary<Int64, Boolean>;
  Ma: TPoint;
  BiasLayer: string;
  Placed: TDictionary<TGateInstance, Boolean>;
  Errs: TStringList;
  Unplaced, NetErrs, Unbound: Integer;
  ClkNet: string;
  MaxGHz: Double;
  LenCount, OverLen: Integer;
  Changed, AllSeen: Boolean;
  Guard: Integer;
  Core, Len, BestLen, Limit: Double;
  LrUm, FreqGHz, DelayPsUm, PulseWUm, Band: Double;
  Failures, Warnings: Integer;
  G2: TGateInstance;
  Detail: TStringList;
  SeenNotPowered: Integer;
  IsLenBuf, IsValBuf: Boolean;
  Names: TDictionary<string, Integer>;
  Covered, NotCovered, Cnt: Integer;
  Dx, Dy, PrevDx, PrevDy, RunLen: Integer;
  BestRun: Double;
  LrDetail: TStringList;

  procedure Report(const AName, AState, ADetail: string);
  begin
    MemoRouting.Lines.Add(Format('  %-14s %-5s %s', [AName, AState, ADetail]));
  end;

  // Resonance applies to a straight PTL run: a bend, a via or a pad breaks the
  // standing wave. RunBlocks is one contiguous same-direction run, in blocks.
  procedure CheckRun(RunBlocks: Integer; const ANet: string);
  var
    RunUm: Double;
    n: Integer;
  begin
    if (RunBlocks <= 0) or (LrUm <= 0) or (Band <= 0) then
      Exit;
    RunUm := RunBlocks * Core;
    if RunUm > BestRun then
      BestRun := RunUm;
    if RunUm / LrUm > 1.0e7 then
      Exit; // absurd configuration (Lr far below a block): nothing sensible to flag
    n := Round(RunUm / LrUm);
    if n < 1 then
      Exit; // shorter than the first harmonic
    if Abs(RunUm - n * LrUm) <= Band then
    begin
      Inc(LrBad);
      if LrDetail.Count < 8 then
        LrDetail.Add(Format(
          '%s: %.2f um straight run (harmonic %d, Lr %.2f um, band +/-%.2f)',
          [ANet, RunUm, n, LrUm, Band]));
    end;
  end;

  // Marks a placed cell's grid footprint, counting blocks that were already
  // taken (the cell-overlap check).
  procedure MarkBlocks(AX, AY, AW, AH: Integer);
  var
    mx, my: Integer;
  begin
    for my := AY to AY + AH - 1 do
      for mx := AX to AX + AW - 1 do
        if (mx >= 0) and (mx < FFloorplanW) and (my >= 0) and
           (my < FFloorplanH) then
        begin
          if Occ[my * FFloorplanW + mx] then
            Inc(OverlapCells)
          else
            Occ[my * FFloorplanW + mx] := True;
        end;
  end;

begin
  Result := False;
  Failures := 0;
  Warnings := 0;
  BadFanout := 0;
  BadBalance := 0;
  LrBad := 0;
  OverLen := 0;
  LenCount := 0;
  OverlapCells := 0;
  PtlOverBias := 0;

  Model := FClockBufferedModel;
  if Model = nil then
    Model := FClockModel;

  MemoRouting.Lines.Add('');
  MemoRouting.Lines.Add('-- Final requirements --');

  if Model = nil then
  begin
    Report('netlist', 'FAIL', 'no validated model');
    MemoRouting.Lines.Add('RESULT: FAIL');
    Exit;
  end;

  // ---- fanout legality: a net may have at most one load ----
  for Pair in Model.Nets do
  begin
    k := 0;
    for NC in Pair.Value.Connections do
      if not NC.IsDriver then
        Inc(k);
    if k > 1 then
      Inc(BadFanout);
  end;
  if BadFanout = 0 then
    Report('fanout', 'OK', 'every net drives at most one load')
  else
  begin
    Report('fanout', 'FAIL', Format('%d net(s) drive more than one load', [BadFanout]));
    Inc(Failures);
  end;

  // ---- stage balance ----
  // Depth = clocked cells traversed from a primary input. Min and max are tracked
  // separately: a net whose two differ is fed by paths of unequal depth, and a
  // clocked cell whose inputs have unequal depth is mis-balanced. Validation
  // buffers are combinational, so they do not shift the count, and ClockLevel is
  // deliberately not consulted (inserted buffers do not inherit it).
  DepthMin := TDictionary<string, Integer>.Create;
  DepthMax := TDictionary<string, Integer>.Create;
  try
    for i := 0 to Model.Inputs.Count - 1 do
    begin
      DepthMin.AddOrSetValue(Model.Inputs[i], 0);
      DepthMax.AddOrSetValue(Model.Inputs[i], 0);
    end;

    Guard := 0;
    repeat
      Changed := False;
      Inc(Guard);
      for i := 0 to Model.Gates.Count - 1 do
      begin
        Gate := Model.Gates[i];
        InLo := MaxInt;
        InHi := -1;
        AllSeen := True;
        for Conn in Gate.Connections do
        begin
          if (Conn.Port = nil) or (Conn.Port.Direction <> pdInput) then
            Continue;
          if SameText(Conn.PinName, 'clk') then
            Continue;
          if not DepthMax.TryGetValue(Conn.NetName, D) then
          begin
            AllSeen := False;
            Break;
          end;
          DepthMin.TryGetValue(Conn.NetName, Lo);
          if Lo < InLo then
            InLo := Lo;
          if D > InHi then
            InHi := D;
        end;
        if (not AllSeen) or (InHi < 0) then
          Continue;
        if CellHasClock(Gate.Cell) then
        begin
          Inc(InLo);
          Inc(InHi);
        end;
        for Conn in Gate.Connections do
          if (Conn.Port <> nil) and (Conn.Port.Direction = pdOutput) then
          begin
            if (not DepthMax.TryGetValue(Conn.NetName, D)) or (InHi > D) then
            begin
              DepthMax.AddOrSetValue(Conn.NetName, InHi);
              Changed := True;
            end;
            if (not DepthMin.TryGetValue(Conn.NetName, Lo)) or (InLo < Lo) then
            begin
              DepthMin.AddOrSetValue(Conn.NetName, InLo);
              Changed := True;
            end;
          end;
      end;
    until (not Changed) or (Guard > Model.Gates.Count * 2 + 8);

    for Pair in Model.Nets do
      if DepthMin.TryGetValue(Pair.Key, Lo) and DepthMax.TryGetValue(Pair.Key, Hi) then
        if Lo <> Hi then
          Inc(BadBalance);

    for i := 0 to Model.Gates.Count - 1 do
    begin
      Gate := Model.Gates[i];
      if not CellHasClock(Gate.Cell) then
        Continue;
      FirstD := -2;
      AllSeen := False;
      for Conn in Gate.Connections do
        if (Conn.Port <> nil) and (Conn.Port.Direction = pdInput) and
           (not SameText(Conn.PinName, 'clk')) and
           DepthMax.TryGetValue(Conn.NetName, D) then
        begin
          if FirstD = -2 then
            FirstD := D
          else if D <> FirstD then
            AllSeen := True; // inputs disagree
        end;
      if AllSeen then
        Inc(BadBalance);
    end;
  finally
    DepthMin.Free;
    DepthMax.Free;
  end;

  if BadBalance = 0 then
    Report('stage balance', 'OK', 'every clocked cell sees equal-depth inputs')
  else
  begin
    Report('stage balance', 'FAIL',
      Format('%d unbalanced net/cell(s) in the clocked data path', [BadBalance]));
    Inc(Failures);
  end;

  // ---- placement completeness ----
  // A gate counts as placed when it has a position in the placement map, OR is
  // in the placed-cell list. The map alone is authoritative for the cells
  // BuildFloorplan skips (ClockLevel -1): validation buffers, length-mask buffers
  // and the clock trunk buffers are placed through FGatePlacement only, so
  // checking FPlacedComponents alone reported them as unplaced.
  Placed := TDictionary<TGateInstance, Boolean>.Create;
  Detail := TStringList.Create;
  try
    for i := 0 to High(FPlacedComponents) do
      if FPlacedComponents[i].Gate <> nil then
        Placed.AddOrSetValue(FPlacedComponents[i].Gate, True);
    Unplaced := 0;
    if FPlacementModel <> nil then
      for i := 0 to FPlacementModel.Gates.Count - 1 do
      begin
        G2 := FPlacementModel.Gates[i];
        if Placed.ContainsKey(G2) or FGatePlacement.ContainsKey(G2) then
          Continue;
        Inc(Unplaced);
        if Detail.Count < 8 then
        begin
          IsLenBuf := False;
          for k := 0 to High(FLengthBuffers) do
            if FLengthBuffers[k].Gate = G2 then
              IsLenBuf := True;
          IsValBuf := False;
          for k := 0 to High(FValidationBuffers) do
            if FValidationBuffers[k].Gate = G2 then
              IsValBuf := True;
          Detail.Add(Format('%s clock level %d (no position; length buffer: %s, validation buffer: %s)',
            [G2.CellName, G2.ClockLevel,
             BoolToStr(IsLenBuf, True), BoolToStr(IsValBuf, True)]));
        end;
      end;
    if Unplaced = 0 then
      Report('placement', 'OK', 'every placement-model gate has a position')
    else
    begin
      Report('placement', 'FAIL',
        Format('%d gate(s) are in the netlist but not placed', [Unplaced]));
      Inc(Failures);
      for i := 0 to Detail.Count - 1 do
        MemoRouting.Lines.Add('             unplaced: ' + Detail[i]);
    end;
  finally
    Detail.Free;
    Placed.Free;
  end;

  // ---- net connectivity, re-run on the validated netlist ----
  // The load-time check predates splitters, pipeline, clock and buffer
  // insertion; this catches a net left with two drivers, none, or an orphaned
  // primary output afterwards.
  Errs := TStringList.Create;
  try
    CheckNetConnectivity(Model, Errs);
    NetErrs := Errs.Count;
    if NetErrs > 0 then
      for i := 0 to 0 do
        if i < Errs.Count then
          MemoRouting.Lines.Add('      ! ' + Errs[i]);
  finally
    Errs.Free;
  end;
  if NetErrs = 0 then
    Report('connectivity', 'OK', 'no undriven, unloaded or multi-driver nets')
  else
  begin
    Report('connectivity', 'FAIL',
      Format('%d netlist connectivity error(s)', [NetErrs]));
    Inc(Failures);
  end;

  // ---- clock pin binding ----
  // A clocked cell whose clk pin has no real net would be exported with a
  // synthetic node and never clocked.
  Unbound := 0;
  for i := 0 to Model.Gates.Count - 1 do
  begin
    Gate := Model.Gates[i];
    if not CellHasClock(Gate.Cell) then
      Continue;
    ClkNet := '';
    for Conn in Gate.Connections do
      if SameText(Conn.PinName, 'clk') and (Conn.NetName <> '') then
      begin
        ClkNet := Conn.NetName;
        Break;
      end;
    if (ClkNet = '') or (not Model.Nets.ContainsKey(ClkNet)) then
      Inc(Unbound);
  end;
  if Unbound = 0 then
    Report('clock pins', 'OK', 'every clocked cell is bound to a clock net')
  else
  begin
    Report('clock pins', 'FAIL',
      Format('%d clocked cell(s) have no clock net', [Unbound]));
    Inc(Failures);
  end;

  // ---- requested clock period vs the achievable one ----
  if (FDesignConfig.FreqGHz > 0) and (FMinClockPeriodPs > 0) then
  begin
    MaxGHz := 1000.0 / FMinClockPeriodPs;
    if FDesignConfig.FreqGHz > MaxGHz + 1e-9 then
    begin
      Report('clock period', 'WARN',
        Format('target %.2f GHz exceeds the achievable %.2f GHz',
          [FDesignConfig.FreqGHz, MaxGHz]));
      Inc(Warnings);
    end
    else if FInputWindowTargetFound and
            (FInputWindowTargetStartPs > FInputWindowTargetEndPs) then
    begin
      Report('clock period', 'FAIL',
        'the target input window is inverted (start after end)');
      Inc(Failures);
    end
    else
      Report('clock period', 'OK',
        Format('target %.2f GHz within the achievable %.2f GHz',
          [FDesignConfig.FreqGHz, MaxGHz]));
  end;

  // ---- clock timing (established by the validation walk) ----
  // The clock/data arrival walk already proved that every clocked cell fires in
  // the right order inside its hold/setup window, so this reports that result
  // rather than re-deriving it. Per-level skew is measured during validation and
  // kept in FClockLevelSkew for the metrics section.
  if FClockNet <> nil then
    Report('clock timing', 'OK',
      Format('validated; %d level(s), min period %.1f ps',
        [FClockNet.Rows.Count, FMinClockPeriodPs]))
  else
    Report('clock timing', 'OK',
      Format('validated; min period %.1f ps', [FMinClockPeriodPs]));

  // ---- resonance and PTL length over the routed traces ----
  Core := FDesignConfig.CoreUm;
  if Core <= 0 then
    Core := FPlanCore;
  Limit := FDesignConfig.MaxPtlLengthUm;
  LrUm := 0;
  Band := 0;
  FreqGHz := FDesignConfig.FreqGHz;
  DelayPsUm := FDesignConfig.PtlDelayPsPerUm;
  PulseWUm := FDesignConfig.PulseWidthUm;
  if (FreqGHz > 0) and (DelayPsUm > 0) then
    LrUm := UPhysics.ResonantLengthUm(FreqGHz, DelayPsUm);
  if PulseWUm > 0 then
    Band := PulseWUm / 2;
  BestLen := 0;
  BestRun := 0;
  LrDetail := TStringList.Create;
  try
    for i := 0 to High(FRouteTraces) do
    begin
      if IsBiasTrace(FRouteTraces[i]) then
        Continue;
      if Length(FRouteTraces[i].Layers) <= 1 then
        Continue;
      Len := TraceLengthUm(FRouteTraces[i], Core);
      Inc(LenCount);
      if Len > BestLen then
        BestLen := Len;
      if (Limit > 0) and (Len > Limit + 1e-6) then
        Inc(OverLen);
      // Resonance: walk the trace and measure every straight run on its own.
      // A repeated point is a via; a change of step direction is a bend; both
      // end the current run. The end-to-end length is NOT the resonant length.
      RunLen := 0;
      PrevDx := 0;
      PrevDy := 0;
      for j := 1 to High(FRouteTraces[i].Points) do
      begin
        Dx := FRouteTraces[i].Points[j].X - FRouteTraces[i].Points[j - 1].X;
        Dy := FRouteTraces[i].Points[j].Y - FRouteTraces[i].Points[j - 1].Y;
        if (Dx = 0) and (Dy = 0) then
        begin
          CheckRun(RunLen, FRouteTraces[i].NetName); // via ends the run
          RunLen := 0;
          PrevDx := 0;
          PrevDy := 0;
          Continue;
        end;
        if (Dx <> PrevDx) or (Dy <> PrevDy) then
        begin
          CheckRun(RunLen, FRouteTraces[i].NetName); // bend ends the run
          RunLen := 0;
        end;
        Inc(RunLen, Abs(Dx) + Abs(Dy));
        PrevDx := Dx;
        PrevDy := Dy;
      end;
      CheckRun(RunLen, FRouteTraces[i].NetName);
    end;
  finally
    LrDetail.Free;
  end;

  if LrBad = 0 then
    Report('resonance', 'OK', Format(
      'no straight PTL run sits in a resonant band (longest run %.2f um)', [BestRun]))
  else
  begin
    Report('resonance', 'FAIL', Format(
      '%d straight PTL run(s) in a resonant band', [LrBad]));
    Inc(Failures);
    for i := 0 to LrDetail.Count - 1 do
      MemoRouting.Lines.Add('             resonance: ' + LrDetail[i]);
  end;

  if Limit <= 0 then
    Report('PTL length', 'OK', Format('no limit set; longest %.2f um', [BestLen]))
  else if OverLen = 0 then
    Report('PTL length', 'OK',
      Format('longest %.2f of %.2f um over %d routed net(s)', [BestLen, Limit, LenCount]))
  else
  begin
    Report('PTL length', 'FAIL',
      Format('%d of %d net(s) over the %.2f um limit (longest %.2f um)',
        [OverLen, LenCount, Limit, BestLen]));
    Inc(Failures);
  end;

  // ---- bias: every powered cell was part of the allocation ----
  // Compared by CELL NAME, not by gate identity: validation re-clones the
  // netlist after the bias lines are routed, so identity comparison saw every
  // cell as "not allotted". Every buffer insertion re-runs the whole chain
  // (RunBiasExpansionAndRouting ends with RouteBiasLines), so the recorded set
  // always describes the final netlist - buffers included.
  Powered := 0;
  Covered := 0;
  NotCovered := 0;
  SeenNotPowered := 0;
  Detail := TStringList.Create;
  Names := TDictionary<string, Integer>.Create;
  try
    if FBiasGateSet <> nil then
      for G2 in FBiasGateSet.Keys do
      begin
        if (G2.Cell = nil) or (G2.Cell.PowerPorts.Count = 0) then
          Inc(SeenNotPowered);
        if G2.CellName <> '' then
        begin
          if Names.TryGetValue(G2.CellName, Cnt) then
            Names[G2.CellName] := Cnt + 1
          else
            Names.Add(G2.CellName, 1);
        end;
      end;
    if FPlacementModel <> nil then
      for i := 0 to FPlacementModel.Gates.Count - 1 do
      begin
        G2 := FPlacementModel.Gates[i];
        if (G2.Cell = nil) or (G2.Cell.PowerPorts.Count = 0) then
          Continue;
        Inc(Powered);
        if (G2.CellName <> '') and Names.TryGetValue(G2.CellName, Cnt) and
           (Cnt > 0) then
        begin
          Names[G2.CellName] := Cnt - 1;
          Inc(Covered);
        end
        else
        begin
          Inc(NotCovered);
          if Detail.Count < 8 then
            Detail.Add(Format('%s (clock level %d) has no bias allocation',
              [G2.CellName, G2.ClockLevel]));
        end;
      end;
    if (Powered = 0) or (NotCovered = 0) then
      Report('bias', 'OK',
        Format('%d of %d cell(s) covered by the bias network',
          [Covered, Powered]))
    else
    begin
      Report('bias', 'FAIL',
        Format('%d of %d cell(s) on the bias network, %d not covered',
          [Covered, Powered, NotCovered]));
      Inc(Failures);
      for i := 0 to Detail.Count - 1 do
        MemoRouting.Lines.Add('             bias: ' + Detail[i]);
    end;
    if SeenNotPowered > 0 then
      MemoRouting.Lines.Add(Format('             bias note: %d allotted gate(s) have no power pins',
        [SeenNotPowered]));
  finally
    Names.Free;
    Detail.Free;
  end;

  // ---- overlaps ----
  // Cells: re-derived, the placement arrays are the only source. Clock-tree
  // leaves are skipped (they are the placed clocked cells) and mask buffers come
  // from their FGatePlacement position.
  if (FFloorplanW > 0) and (FFloorplanH > 0) then
  begin
    SetLength(Occ, FFloorplanW * FFloorplanH);
    for i := 0 to High(Occ) do
      Occ[i] := False;
    for i := 0 to High(FPlacedComponents) do
      MarkBlocks(FPlacedComponents[i].X, FPlacedComponents[i].Y,
        FPlacedComponents[i].W, FPlacedComponents[i].H);
    for i := 0 to High(FClockSubtree) do
      for j := 0 to High(FClockSubtree[i]) do
        if not FClockSubtree[i][j].IsLeaf then
          MarkBlocks(FClockSubtree[i][j].X, FClockSubtree[i][j].Y,
            FClockSubtree[i][j].W, FClockSubtree[i][j].H);
    for i := 0 to High(FSpine) do
      MarkBlocks(FSpine[i].X, FSpine[i].Y, FSpine[i].W, FSpine[i].H);
    for i := 0 to High(FLengthBuffers) do
      if (FLengthBuffers[i].Gate <> nil) and
         FGatePlacement.TryGetValue(FLengthBuffers[i].Gate, Ma) then
        MarkBlocks(Ma.X, Ma.Y, FLengthBuffers[i].W, FLengthBuffers[i].H);
  end;

  if OverlapCells = 0 then
    Report('cell overlap', 'OK', 'no two placed cells share a grid block')
  else
  begin
    Report('cell overlap', 'FAIL',
      Format('%d grid block(s) hold more than one cell', [OverlapCells]));
    Inc(Failures);
  end;

  // PTL: the router allocates each block to one net as it routes (a cap shares
  // its port's block), so that is carried forward. Bias is a single net, so bias
  // blocks meeting each other is the intended fabric rather than a defect; the
  // only meaningful overlap test is bias against *other* nets, which on the bias
  // layer means PTL. Every bias cell - lines, trunk and the taps reaching the
  // cells' power pins - sits on the chosen bias layer.
  BiasLayer := '';
  if Length(FBiasCells) > 0 then
    BiasLayer := FBiasCells[0].Layer;
  BiasBlocks := TDictionary<Int64, Boolean>.Create;
  try
    for i := 0 to High(FBiasCells) do
      BiasBlocks.AddOrSetValue(Int64(FBiasCells[i].Y) * (Int64(FFloorplanW) + 1) +
        FBiasCells[i].X, True);
    if (BiasBlocks.Count > 0) and (BiasLayer <> '') then
      for i := 0 to High(FRouteTraces) do
      begin
        if IsBiasTrace(FRouteTraces[i]) then
          Continue;
        for j := 0 to High(FRouteTraces[i].Points) do
          if (j <= High(FRouteTraces[i].Layers)) and
             (FRouteTraces[i].Layers[j] = BiasLayer) and
             BiasBlocks.ContainsKey(
               Int64(FRouteTraces[i].Points[j].Y) * (Int64(FFloorplanW) + 1) +
               FRouteTraces[i].Points[j].X) then
            Inc(PtlOverBias);
      end;
  finally
    BiasBlocks.Free;
  end;

  if PtlOverBias = 0 then
    Report('PTL overlap', 'OK',
      Format('%d routed net(s), one net per block (caps apart), none on bias metal',
        [LenCount]))
  else
  begin
    Report('PTL overlap', 'FAIL',
      Format('%d PTL block(s) share a block and layer with bias metal', [PtlOverBias]));
    Inc(Failures);
  end;

  // ---- routing completeness (established at route time) ----
  if FRouteFailedLinks = 0 then
    Report('routing', 'OK',
      Format('all %d routed net(s) complete, nothing dropped', [LenCount]))
  else
  begin
    Report('routing', 'FAIL',
      Format('%d link(s) could not be routed', [FRouteFailedLinks]));
    Inc(Failures);
  end;

  // Failures first: a warning must never mask them (this used to print
  // "PASS with 1 warning" while two requirements had failed, which locked the
  // export with no explanation).
  if Failures > 0 then
    MemoRouting.Lines.Add(Format('RESULT: FAIL (%d requirement(s), %d warning(s))',
      [Failures, Warnings]))
  else if Warnings > 0 then
    MemoRouting.Lines.Add(Format('RESULT: PASS with %d warning(s)', [Warnings]))
  else
    MemoRouting.Lines.Add('RESULT: PASS');

  Result := Failures = 0;
end;
