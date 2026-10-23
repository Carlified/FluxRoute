// Design statistics written next to the exports as <stem>.metrics.json.
//
// The numbers are the ones RSFQ/SFQ place-and-route papers tabulate: junction
// count as the area proxy, clocking overhead (DFFs, clock-tree and trunk cells),
// wirelength (total, per layer, per-net spread), achieved period against the
// requested one, and routing runtime. Area is also reported against the die, the
// floorplan body and the routed bounding box, so packing can be judged.
// Included from MainWindow's implementation via {$I ExportMetrics.inc}.

// Junction count of a cell: the extracted .cir lists one "B<n> ... jjmit ..."
// line per Josephson junction. Memoised per cell name.
var
  GJJCache: TDictionary<string, Integer> = nil;

function CellJJCount(ACell: TCell): Integer;
var
  i, n: Integer;
  Lines: TArray<string>;
  Path, S: string;
begin
  Result := 0;
  if ACell = nil then
    Exit;
  if GJJCache = nil then
    GJJCache := TDictionary<string, Integer>.Create;
  if GJJCache.TryGetValue(ACell.Name, Result) then
    Exit;
  Result := 0;
  Path := '';
  for i := 0 to ACell.SourceFiles.Count - 1 do
    if SameText(ExtractFileExt(ACell.SourceFiles[i]), '.cir') then
    begin
      Path := ACell.SourceFiles[i];
      Break;
    end;
  if (Path <> '') and TFile.Exists(Path) then
  begin
    Lines := TFile.ReadAllLines(Path);
    n := 0;
    for i := 0 to High(Lines) do
    begin
      S := Trim(Lines[i]);
      if (Length(S) >= 2) and (S[1] = 'B') and CharInSet(S[2], ['0'..'9']) then
        Inc(n);
    end;
    Result := n;
  end;
  GJJCache.AddOrSetValue(ACell.Name, Result);
end;

function TForm1.BuildMetricsJson: string;
var
  S: TStringList;
  FS: TFormatSettings;
  Model: TBlifModel;
  D: TExportDesign;
  Core, L, Dy, SigLen, CellArea, DieArea, BodyArea: Double;
  LayLen: TDictionary<string, Double>;
  LayerKeys: TArray<string>;
  Bx0, By0, Bx1, By1: Integer;
  i, k, Junc, GateCount, NetTotal, InTotal, OutTotal: Integer;
  ClockCells, TreeNodes, Levels, WorstLvl: Integer;
  Tr: TRoutedTrace;
  Gate: TGateInstance;
  Ma: TPoint;
  RowsText, SkewText: string;
  BBoxPct, PackPct, RowUtilPct, EffUtilPct, MaxGHz, BBoxArea: Double;
  RowArea: Double;
  RowsH: Integer;
  WorstSkew: Double;

  function Q(const V: string): string;
  var
    ch: Char;
  begin
    Result := '"';
    for ch in V do
      if ch = '"' then
        Result := Result + '\"'
      else if ch = '\' then
        Result := Result + '\\'
      else
        Result := Result + ch;
    Result := Result + '"';
  end;

  function Num(const V: Double): string;
  begin
    Result := FloatToStr(V, FS);
  end;

  procedure Extend(const AX, AY, AW, AH: Integer);
  begin
    if AX < Bx0 then Bx0 := AX;
    if AY < By0 then By0 := AY;
    if AX + AW > Bx1 then Bx1 := AX + AW;
    if AY + AH > By1 then By1 := AY + AH;
  end;

  procedure AddArea(const AW, AH: Integer);
  begin
    CellArea := CellArea + AW * AH * Core * Core;
  end;

  procedure TallyJJ(AGate: TGateInstance);
  begin
    if (AGate <> nil) and (AGate.Cell <> nil) then
      Inc(Junc, CellJJCount(AGate.Cell));
  end;

begin
  FS := TFormatSettings.Invariant;
  S := TStringList.Create;
  LayLen := TDictionary<string, Double>.Create;
  try
    Core := FDesignConfig.CoreUm;
    if Core <= 0 then
      Core := FPlanCore;
    if Core <= 0 then
      Core := 1;

    Model := FClockBufferedModel;
    if Model = nil then
      Model := FClockModel;
    GateCount := 0;
    NetTotal := 0;
    InTotal := 0;
    OutTotal := 0;
    ClockCells := 0;
    if Model <> nil then
    begin
      GateCount := Model.Gates.Count;
      NetTotal := Model.Nets.Count;
      InTotal := Model.Inputs.Count;
      OutTotal := Model.Outputs.Count;
      for Gate in Model.Gates do
        if CellHasClock(Gate.Cell) then
          Inc(ClockCells);
    end;
    Levels := 0;
    if FClockNet <> nil then
      Levels := FClockNet.Rows.Count;
    TreeNodes := 0;
    for i := 0 to High(FClockSubtree) do
      for k := 0 to High(FClockSubtree[i]) do
        if not FClockSubtree[i][k].IsLeaf then
          Inc(TreeNodes);

    // ---- wirelength (equivalent, from the placed geometry) ----
    // The routed trace length is not used. Instead each placed block contributes
    // its pitch: a straight run block or a bend is one pitch, a via is half a
    // pitch on each of the two layers it joins, and a cap is half a pitch on its
    // own layer.
    ExportScanAll(FRouteTraces, FBiasCells, FRouteLayers, D);
    SigLen := 0;
    for i := 0 to High(D.Runs) do
    begin
      L := D.Runs[i].Count * Core;
      if D.Runs[i].Family = xfPtl then
      begin
        SigLen := SigLen + L;
        if LayLen.TryGetValue(D.Runs[i].Layer, Dy) then
          LayLen.AddOrSetValue(D.Runs[i].Layer, Dy + L)
        else
          LayLen.AddOrSetValue(D.Runs[i].Layer, L);
      end;
    end;
    for i := 0 to High(D.Bends) do
      if D.Bends[i].Family = xfPtl then
      begin
        SigLen := SigLen + Core;
        if LayLen.TryGetValue(D.Bends[i].Layer, Dy) then
          LayLen.AddOrSetValue(D.Bends[i].Layer, Dy + Core)
        else
          LayLen.AddOrSetValue(D.Bends[i].Layer, Core);
      end;
    for i := 0 to High(D.ViaBlocks) do
    begin
      // Half a pitch on each layer the via joins (it belongs to neither alone).
      L := Core / 2;
      SigLen := SigLen + L;
      if LayLen.TryGetValue(D.ViaBlocks[i].LoLayer, Dy) then
        LayLen.AddOrSetValue(D.ViaBlocks[i].LoLayer, Dy + L)
      else
        LayLen.AddOrSetValue(D.ViaBlocks[i].LoLayer, L);
      if (D.ViaBlocks[i].HiLayer <> '') and
         (D.ViaBlocks[i].HiLayer <> D.ViaBlocks[i].LoLayer) then
      begin
        SigLen := SigLen + L;
        if LayLen.TryGetValue(D.ViaBlocks[i].HiLayer, Dy) then
          LayLen.AddOrSetValue(D.ViaBlocks[i].HiLayer, Dy + L)
        else
          LayLen.AddOrSetValue(D.ViaBlocks[i].HiLayer, L);
      end;
    end;
    for i := 0 to High(D.Terminals) do
      if D.Terminals[i].Family = xfPtl then
      begin
        L := Core / 2;
        SigLen := SigLen + L;
        if LayLen.TryGetValue(D.Terminals[i].Layer, Dy) then
          LayLen.AddOrSetValue(D.Terminals[i].Layer, Dy + L)
        else
          LayLen.AddOrSetValue(D.Terminals[i].Layer, L);
      end;

    // ---- area and occupancy ----
    CellArea := 0;
    Bx0 := MaxInt;
    By0 := MaxInt;
    Bx1 := -1;
    By1 := -1;
    Junc := 0;
    for i := 0 to High(FPlacedComponents) do
    begin
      AddArea(FPlacedComponents[i].W, FPlacedComponents[i].H);
      Extend(FPlacedComponents[i].X, FPlacedComponents[i].Y,
        FPlacedComponents[i].W, FPlacedComponents[i].H);
      TallyJJ(FPlacedComponents[i].Gate);
    end;
    for i := 0 to High(FClockSubtree) do
      for k := 0 to High(FClockSubtree[i]) do
        if not FClockSubtree[i][k].IsLeaf then
        begin
          AddArea(FClockSubtree[i][k].W, FClockSubtree[i][k].H);
          Extend(FClockSubtree[i][k].X, FClockSubtree[i][k].Y,
            FClockSubtree[i][k].W, FClockSubtree[i][k].H);
          TallyJJ(FClockSubtree[i][k].Gate);
        end;
    for i := 0 to High(FSpine) do
    begin
      AddArea(FSpine[i].W, FSpine[i].H);
      Extend(FSpine[i].X, FSpine[i].Y, FSpine[i].W, FSpine[i].H);
      TallyJJ(FSpine[i].Gate);
    end;
    for i := 0 to High(FLengthBuffers) do
      if (FLengthBuffers[i].Gate <> nil) and
         FGatePlacement.TryGetValue(FLengthBuffers[i].Gate, Ma) then
      begin
        AddArea(FLengthBuffers[i].W, FLengthBuffers[i].H);
        Extend(Ma.X, Ma.Y, FLengthBuffers[i].W, FLengthBuffers[i].H);
        TallyJJ(FLengthBuffers[i].Gate);
      end;
    // Wires and pads count too: PTL runs wide under congestion and the pad
    // connections dominate the extent, so the routed bbox is the union of the
    // placed cells, every trace point (signal and bias), the bias blocks and the
    // I/O pads - each point/pad occupying its own grid block.
    for i := 0 to High(FRouteTraces) do
      for k := 0 to High(FRouteTraces[i].Points) do
        Extend(FRouteTraces[i].Points[k].X, FRouteTraces[i].Points[k].Y, 1, 1);
    for i := 0 to High(FBiasCells) do
      Extend(FBiasCells[i].X, FBiasCells[i].Y, 1, 1);
    for i := 0 to High(FPads) do
      Extend(FPads[i].X, FPads[i].Y, 1, 1);
    if Bx1 < 0 then
    begin
      Bx0 := 0;
      By0 := 0;
      Bx1 := 0;
      By1 := 0;
    end;

    DieArea := FFloorplanW * FFloorplanH * Core * Core;
    // Floorplan body (all rows and channels) - reported for reference.
    BodyArea := (FPlanBiasTrunkW + (FPlanXRight - FPlanXLeft) + FPlanLane0W +
      FPlanTrunkW + FPlanLane1W) * FPlanLastTotalH * Core * Core;
    // Row+trunk allocation: the cell rows plus the clock trunk column. Only the
    // logic rows and clock rows (plus their extra rows) count vertically, and
    // only the row band plus the clock trunk count horizontally - the bias
    // trunk, the bias channels and the bias lanes are not packing space.
    RowsH := 0;
    for i := 0 to High(FPlanBandStarts) do
    begin
      Inc(RowsH, FPlanRowHBlocks * 2);
      if i <= High(FLogicRowExtra) then
        Inc(RowsH, FLogicRowExtra[i]);
      if i <= High(FClockRowExtra) then
        Inc(RowsH, FClockRowExtra[i]);
    end;
    RowArea := ((FPlanXRight - FPlanXLeft) + FPlanTrunkW) * RowsH * Core * Core;

    // Ratios, guarded so an unsized floorplan cannot divide by zero.
    BBoxPct := 0;
    PackPct := 0;
    RowUtilPct := 0;
    EffUtilPct := 0;
    BBoxArea := (Bx1 - Bx0) * (By1 - By0) * Core * Core;
    if DieArea > 0 then
    begin
      BBoxPct := BBoxArea / DieArea * 100;
      PackPct := CellArea / DieArea * 100;
    end;
    // Utilisation if the die were shrunk to exactly the routed extent.
    if BBoxArea > 0 then
      EffUtilPct := CellArea / BBoxArea * 100;
    if RowArea > 0 then
      RowUtilPct := CellArea / RowArea * 100;
    if FMinClockPeriodPs > 0 then
      MaxGHz := 1000.0 / FMinClockPeriodPs
    else
      MaxGHz := 0;

    // ---- skew, in clock-row order ----
    RowsText := '[]';
    SkewText := '[]';
    WorstSkew := 0;
    WorstLvl := -1;
    if (FClockNet <> nil) and (Length(FClockLevelSkew) = FClockNet.Rows.Count) and
       (FClockNet.Rows.Count > 0) then
    begin
      RowsText := '[';
      SkewText := '[';
      for i := 0 to High(FClockLevelSkew) do
      begin
        if i > 0 then
        begin
          RowsText := RowsText + ', ';
          SkewText := SkewText + ', ';
        end;
        RowsText := RowsText + IntToStr(FClockNet.Rows[i]);
        SkewText := SkewText + Num(FClockLevelSkew[i]);
        if FClockLevelSkew[i] > WorstSkew then
        begin
          WorstSkew := FClockLevelSkew[i];
          WorstLvl := FClockNet.Rows[i];
        end;
      end;
      RowsText := RowsText + ']';
      SkewText := SkewText + ']';
    end;

    // ---- JSON ----
    S.Add('{');
    S.Add('  "design": {');
    S.Add(Format('    "gates": %d,', [GateCount]));
    S.Add(Format('    "nets": %d,', [NetTotal]));
    S.Add(Format('    "inputs": %d,', [InTotal]));
    S.Add(Format('    "outputs": %d,', [OutTotal]));
    S.Add(Format('    "junctions": %d,', [Junc]));
    S.Add(Format('    "clockedCells": %d,', [ClockCells]));
    S.Add(Format('    "clockLevels": %d,', [Levels]));
    S.Add(Format('    "clockTreeCells": %d,', [TreeNodes]));
    S.Add(Format('    "trunkCells": %d,', [Length(FSpine)]));
    S.Add(Format('    "lengthBuffers": %d', [Length(FLengthBuffers)]));
    S.Add('  },');
    S.Add('  "area": {');
    S.Add(Format('    "dieUm2": %s,', [Num(DieArea)]));
    S.Add(Format('    "floorplanBodyUm2": %s,', [Num(BodyArea)]));
    S.Add(Format('    "cellUm2": %s,', [Num(CellArea)]));
    S.Add(Format('    "routedBBoxUm2": %s,', [Num(BBoxArea)]));
    S.Add(Format('    "routedBBoxPctOfDie": %s,', [Num(BBoxPct)]));
    S.Add(Format('    "packingDensityPct": %s,', [Num(PackPct)]));
    S.Add(Format('    "rowTrunkAreaUm2": %s,', [Num(RowArea)]));
    S.Add(Format('    "rowTrunkUtilisationPct": %s,', [Num(RowUtilPct)]));
    S.Add(Format('    "effectiveUtilisationPct": %s', [Num(EffUtilPct)]));
    S.Add('  },');
    S.Add('  "wirelength": {');
    S.Add(Format('    "signalUm": %s,', [Num(SigLen)]));
    LayerKeys := LayLen.Keys.ToArray;
    TArray.Sort<string>(LayerKeys);
    if Length(LayerKeys) = 0 then
      S.Add('    "perLayerUm": {}')
    else
    begin
      S.Add('    "perLayerUm": {');
      for i := 0 to High(LayerKeys) do
      begin
        LayLen.TryGetValue(LayerKeys[i], L);
        if i = High(LayerKeys) then
          S.Add(Format('      %s: %s', [Q(LayerKeys[i]), Num(L)]))
        else
          S.Add(Format('      %s: %s,', [Q(LayerKeys[i]), Num(L)]));
      end;
      S.Add('    }');
    end;
    S.Add('  },');
    S.Add('  "timing": {');
    S.Add(Format('    "minClockPeriodPs": %s,', [Num(FMinClockPeriodPs)]));
    S.Add(Format('    "maxClockGHz": %s,', [Num(MaxGHz)]));
    S.Add(Format('    "targetGHz": %s,', [Num(FDesignConfig.FreqGHz)]));
    S.Add(Format('    "pipelineLevels": %d,', [Levels]));
    S.Add(Format('    "clockRows": %s,', [RowsText]));
    S.Add(Format('    "skewPs": %s,', [SkewText]));
    S.Add(Format('    "worstSkewPs": %s,', [Num(WorstSkew)]));
    S.Add(Format('    "worstSkewLevel": %d', [WorstLvl]));
    S.Add('  },');
    S.Add('  "runtime": {');
    S.Add(Format('    "routingMs": %d', [Int64(FRouteRuntimeMs)]));
    S.Add('  }');
    S.Add('}');
    Result := S.Text;
  finally
    LayLen.Free;
    S.Free;
  end;
end;

procedure TForm1.RunMetricsExport(const OutDir, Stem: string);
var
  Path: string;
begin
  TDirectory.CreateDirectory(OutDir);
  Path := TPath.Combine(OutDir, Stem + '.metrics.json');
  TFile.WriteAllText(Path, BuildMetricsJson);
  MemoExportLog.Lines.Add('Stats: -> ' + Path);
end;
