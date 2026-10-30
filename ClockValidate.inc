// Clock-arrival validation: checks that no clocked cell's clock arrives later
// than the worst-case data launched by a preceding clocked cell, and inserts
// trunk buffers (the next-lower clock level is delayed) until it holds. The
// netlist walks live in ClockValidate.pas; this file supplies the routed PTL
// delays and performs the insertion. Included by MainWindow.pas.

function TForm1.RunClockValidation(out AInserted: Boolean): Boolean;
const
  MaxBuffersPerRun = 64;
var
  Model: TBlifModel;
  IndexMap: TDictionary<TGateInstance, Integer>;
  ClkPos: TDictionary<TGateInstance, TPoint>;
  ClkRot: TDictionary<TGateInstance, Boolean>;
  WireDelays: TDictionary<string, Double>;
  ClockArr, DataArr: TDictionary<TGateInstance, Double>;
  Rows: TArray<Integer>;
  Violations: TClockViolations;
  Core, PerBlock, DataPer, SpacingPer, TargetPer: Double;
  Window, Tw: TInputWindow;
  i, k, Worst, Guard, Idx: Integer;
  SkLo, SkHi, SkD: Double;
  SkFound: Boolean;
  Net: TNet;
  Tr: TRoutedTrace;
  V: TClockViolation;

  // Pin block of a clock-tree (or, as a fallback, logic) gate.
  function PinBlock(G: TGateInstance; const PinName: string;
    out P: TPoint): Boolean;
  var
    P0: TPoint;
    Rot: Boolean;
  begin
    Result := False;
    if G = nil then
      Exit;
    if ClkPos.TryGetValue(G, P0) then
    begin
      Rot := False;
      ClkRot.TryGetValue(G, Rot);
      Result := GatePinBlockAt(G, PinName, 0, P0.X, P0.Y, Rot, P);
      Exit;
    end;
    if FGatePlacement.TryGetValue(G, P0) then
      Result := GatePinBlock(G, PinName, 0, P);
  end;

  // PTL blocks in the routed trace. The trace runs centre-to-centre between the
  // two endpoint pin blocks, so each end contributes half a block: exclude one
  // block in total, not one per end.
  function LineBlocks(const ATr: TRoutedTrace): Integer;
  var
    k, N: Integer;
  begin
    N := 0;
    for k := 0 to High(ATr.Points) do
      if (k = 0) or (ATr.Points[k].X <> ATr.Points[k - 1].X) or
         (ATr.Points[k].Y <> ATr.Points[k - 1].Y) then
        Inc(N);
    Result := N - 1;
    if Result < 0 then
      Result := 0;
  end;

  // The routed trace of ANetName that terminates at Load's pin block.
  function TraceForLoad(const NetName: string; Load: TGateInstance;
    const LoadPin: string; out ATr: TRoutedTrace): Boolean;
  var
    k: Integer;
    P, EndPt: TPoint;
  begin
    Result := False;
    if not PinBlock(Load, LoadPin, P) then
      Exit;
    for k := 0 to High(FRouteTraces) do
    begin
      if not SameText(FRouteTraces[k].NetName, NetName) then
        Continue;
      if Length(FRouteTraces[k].Points) = 0 then
        Continue;
      EndPt := FRouteTraces[k].Points[High(FRouteTraces[k].Points)];
      if (EndPt.X = P.X) and (EndPt.Y = P.Y) then
      begin
        ATr := FRouteTraces[k];
        Exit(True);
      end;
    end;
  end;

  procedure BuildMaps;
  var
    Sp: TSpineComponent;
    Node: TPlacedClockNode;
    si, sl, sk: Integer;
  begin
    ClkPos.Clear;
    ClkRot.Clear;
    for si := 0 to High(FSpine) do
    begin
      Sp := FSpine[si];
      if Sp.Gate <> nil then
      begin
        ClkPos.AddOrSetValue(Sp.Gate, TPoint.Create(Sp.X, Sp.Y));
        ClkRot.AddOrSetValue(Sp.Gate, Sp.Rotated);
      end;
    end;
    for sl := 0 to High(FClockSubtree) do
      for sk := 0 to High(FClockSubtree[sl]) do
      begin
        Node := FClockSubtree[sl][sk];
        if Node.Gate <> nil then
        begin
          ClkPos.AddOrSetValue(Node.Gate, TPoint.Create(Node.X, Node.Y));
          ClkRot.AddOrSetValue(Node.Gate, False);
        end;
      end;
  end;

  procedure BuildWireDelays;
  var
    WNet: TNet;
    WNC: TNetConnection;
  begin
    WireDelays.Clear;
    for WNet in Model.Nets.Values do
      for WNC in WNet.Connections do
      begin
        if WNC.IsDriver then
          Continue;
        if not IndexMap.TryGetValue(WNC.Gate, Idx) then
          Continue;
        if TraceForLoad(WNet.Name, WNC.Gate, WNC.PinName, Tr) then
          WireDelays.AddOrSetValue(WireKey(Idx, WNC.PinName),
            LineBlocks(Tr) * PerBlock)
        else
          WireDelays.AddOrSetValue(WireKey(Idx, WNC.PinName), 0);
      end;
  end;

  // True for an exact per-row tap net (clk_row_<n>), false for a net merely
  // derived from one (clk_row_1__vbuf_3).
  function IsRowNet(const S: string): Boolean;
  var
    LV: Integer;
  begin
    Result := SameText(Copy(S, 1, Length(UNetNaming.ClockRowPrefix)),
      UNetNaming.ClockRowPrefix) and
      TryStrToInt(Copy(S, Length(UNetNaming.ClockRowPrefix) + 1, MaxInt), LV);
  end;

  // Splits the trunk segment net with one buffer. Only the netlist changes: the
  // next floorplan rebuild places the buffer as a spine component (rotated,
  // stacked, overflow-aware, with its bias ports collected) via
  // BuildSpinePlacement, and routing re-runs. No placement slot is chosen here.
  function InsertTrunkBuffer(const NetName: string): Boolean;
  var
    Driver, Load: TGateInstance;
    DriverPin, LoadPin: string;
    BufCell: TCell;
    InPort, OutPort: TPort;
    InPin, OutPin: string;
    NC: TNetConnection;
    k: Integer;
  begin
    Result := False;
    if (NetName = '') or (not Model.Nets.TryGetValue(NetName, Net)) then
      Exit;
    Driver := nil;
    DriverPin := '';
    for NC in Net.Connections do
      if NC.IsDriver then
      begin
        Driver := NC.Gate;
        DriverPin := NC.PinName;
        Break;
      end;
    Load := nil;
    LoadPin := '';
    for NC in Net.Connections do
      if not NC.IsDriver then
      begin
        Load := NC.Gate;
        LoadPin := NC.PinName;
        Break;
      end;
    if Load = nil then
      Exit;
    BufCell := FindMaxDelayBufferCell;
    if BufCell = nil then
      Exit;
    InPort := nil;
    OutPort := nil;
    for k := 0 to BufCell.Ports.Count - 1 do
      if BufCell.Ports[k].Direction = pdOutput then
        OutPort := BufCell.Ports[k]
      else if BufCell.Ports[k].Direction = pdInput then
        InPort := BufCell.Ports[k];
    if (InPort = nil) or (OutPort = nil) then
      Exit;
    InPin := InPort.Name;
    OutPin := OutPort.Name;
    // When the target is a row tap net (the merged final junction output),
    // keep that name on the load side so the row tree stays rooted there; the
    // junction moves to a fresh net and the buffer becomes a spine component
    // placed by BuildSpinePlacement, not a row-tree node.
    Result := TryInsertBuffer(True, NetName, Driver, Load, DriverPin, LoadPin,
      IsRowNet(NetName), False, BufCell, InPin, OutPin, -1, -1, 0, 0);
  end;

begin
  AInserted := False;
  Result := True;
  FInputWindowFound := False;
  FInputWindowStartPs := 0;
  FInputWindowEndPs := 0;
  FInputWindowTargetFound := False;
  FInputWindowTargetStartPs := 0;
  FInputWindowTargetEndPs := 0;
  FOutputTravelFound := False;
  FOutputTravelPs := 0;
  FClockLevelSkew := nil;
  Model := FClockBufferedModel;
  if Model = nil then
    Model := FClockModel;
  if (Model = nil) or (FClockNet = nil) then
    Exit;
  SetLength(Rows, FClockNet.Rows.Count);
  for i := 0 to FClockNet.Rows.Count - 1 do
    Rows[i] := FClockNet.Rows[i];
  if Length(Rows) < 2 then
    Exit;

  Core := FDesignConfig.CoreUm;
  if Core <= 0 then
    Core := FPlanCore;
  if Core <= 0 then
    Core := 1;
  PerBlock := Core * FDesignConfig.PtlDelayPsPerUm;
  if PerBlock < 0 then
    PerBlock := 0;

  IndexMap := TDictionary<TGateInstance, Integer>.Create;
  ClkPos := TDictionary<TGateInstance, TPoint>.Create;
  ClkRot := TDictionary<TGateInstance, Boolean>.Create;
  WireDelays := TDictionary<string, Double>.Create;
  ClockArr := TDictionary<TGateInstance, Double>.Create;
  DataArr := TDictionary<TGateInstance, Double>.Create;
  try
    for i := 0 to Model.Gates.Count - 1 do
      IndexMap.AddOrSetValue(Model.Gates[i], i);

    Guard := 0;
    repeat
      BuildMaps;
      BuildWireDelays;
      ComputeClockArrivals(Model, FClockNet.SourceNet, WireDelays, ClockArr);
      ComputeDataArrivals(Model, WireDelays, ClockArr, DataArr);
      Violations := FindClockViolations(Model, Rows, ClockArr, DataArr);
      if Length(Violations) = 0 then
      begin
        DataPer := MinPeriodFromTiming(Model, ClockArr, DataArr);
        SpacingPer := MaxInputSpacingPs(Model);
        FMinPeriodTimingPs := DataPer;
        FMinPeriodSpacingPs := SpacingPer;
        FMinPeriodWindowExtraPs := 0;
        FMinClockPeriodPs := DataPer;
        if SpacingPer > FMinClockPeriodPs then
          FMinClockPeriodPs := SpacingPer;
        // Third constraint: the first input batch has to be launchable. When the
        // window bounds conflict the period is too short, so grow it until the
        // lower bound falls to meet the upper one.
        if FMinClockPeriodPs > 0 then
        begin
          // Tightest window: the one the minimum period allows.
          Window := InputTimingWindow(Model, ClockArr, WireDelays,
            FMinClockPeriodPs);
          FInputWindowFound := Window.Found;
          if Window.Found then
          begin
            if Window.ExtraPeriodPs > 0 then
            begin
              FMinPeriodWindowExtraPs := Window.ExtraPeriodPs;
              FMinClockPeriodPs := FMinClockPeriodPs + Window.ExtraPeriodPs;
              Window.StartPs := Window.EndPs; // the added period lowers it to meet
              MemoRouting.Lines.Add(Format(
                'Input window needs %.1f ps more period; min clock period is now %.1f ps.',
                [Window.ExtraPeriodPs, FMinClockPeriodPs]));
            end;
            // The library testbenches send an initial clock edge before any
            // data (NOTT/DFFT/AND2T/XORT clock at 20 ps, first data at 150 ps),
            // so the first usable data launch is one clock period after the raw
            // setup/hold window. Add the min clock period to both bounds: this
            // keeps the window width unchanged while moving it to the first
            // data edge a hand-written testbench can actually use.
            FInputWindowStartPs := Window.StartPs + FMinClockPeriodPs;
            FInputWindowEndPs := Window.EndPs + FMinClockPeriodPs;
          end;

          // Same walk at the frequency the user asked for, which is normally
          // slower and therefore allows an earlier launch.
          TargetPer := 0;
          if FDesignConfig.FreqGHz > 0 then
            TargetPer := 1000.0 / FDesignConfig.FreqGHz;
          if TargetPer > 0 then
          begin
            Tw := InputTimingWindow(Model, ClockArr, WireDelays, TargetPer);
            FInputWindowTargetFound := Tw.Found;
            if Tw.Found then
            begin
              // Same one-period shift at the requested frequency: both bounds
              // move together by one target clock period for the initial clock
              // edge, so the exported values are directly usable without any
              // period math in a hand-written testbench.
              FInputWindowTargetStartPs := Tw.StartPs + TargetPer;
              FInputWindowTargetEndPs := Tw.EndPs + TargetPer;
            end;
          end;
        end;
        // Clock skew inside each level (max - min arrival), for the final audit.
        SetLength(FClockLevelSkew, Length(Rows));
        for i := 0 to High(Rows) do
        begin
          SkLo := 0;
          SkHi := 0;
          SkFound := False;
          for k := 0 to Model.Gates.Count - 1 do
            if CellHasClock(Model.Gates[k].Cell) and
               (Model.Gates[k].ClockLevel = Rows[i]) and
               ClockArr.TryGetValue(Model.Gates[k], SkD) then
            begin
              if (not SkFound) or (SkD < SkLo) then
                SkLo := SkD;
              if (not SkFound) or (SkD > SkHi) then
                SkHi := SkD;
              SkFound := True;
            end;
          if SkFound then
            FClockLevelSkew[i] := SkHi - SkLo
          else
            FClockLevelSkew[i] := 0;
        end;

        // Period-independent part of the output window: how long data takes to
        // get from the clock being sent to the first output pad.
        FOutputTravelPs := MinOutputTravelPs(Model, ClockArr, WireDelays);
        FOutputTravelFound := FOutputTravelPs >= 0;
        MemoRouting.Lines.Add(Format(
          'Clock arrivals are within the data-arrival limit (%d cell(s) timed).',
          [ClockArr.Count]));
        Exit;
      end;

      Worst := 0;
      for i := 1 to High(Violations) do
        if (Violations[i].ClkArrPs - Violations[i].DataArrPs) >
           (Violations[Worst].ClkArrPs - Violations[Worst].DataArrPs) then
          Worst := i;
      V := Violations[Worst];
      MemoRouting.Lines.Add(Format(
        '  clock %s (level %d): clock %.1f ps > data %.1f ps; buffering %s.',
        [V.CellName, V.Level, V.ClkArrPs, V.DataArrPs, V.TrunkNet]));

      if V.TrunkNet = '' then
      begin
        MemoRouting.Lines.Add(Format(
          'CLOCK VALIDATION FAILED: no trunk segment to buffer for cell %s ' +
          '(level %d, clock %.1f ps, data %.1f ps).',
          [V.CellName, V.Level, V.ClkArrPs, V.DataArrPs]));
        Result := False;
        Exit;
      end;
      if not InsertTrunkBuffer(V.TrunkNet) then
      begin
        MemoRouting.Lines.Add(Format(
          'CLOCK VALIDATION FAILED: could not insert a buffer on %s (cell %s, ' +
          'level %d, clock %.1f ps, data %.1f ps).',
          [V.TrunkNet, V.CellName, V.Level, V.ClkArrPs, V.DataArrPs]));
        if FBiasExpansionFailed then
          MemoRouting.Lines.Add(
            '  The bias expansion failed: raise the die height (or widen the ' +
            'die / lower the bias current) on the Placement page, expand the ' +
            'bias lines again, then re-run routing.');
        Result := False;
        Exit;
      end;
      AInserted := True;
      Inc(Guard);
      RepaintRoutingPage;
    until Guard >= MaxBuffersPerRun;

    MemoRouting.Lines.Add(Format(
      'CLOCK VALIDATION FAILED: still unbalanced after %d buffers.',
      [MaxBuffersPerRun]));
    Result := False;
  finally
    DataArr.Free;
    ClockArr.Free;
    WireDelays.Free;
    ClkRot.Free;
    ClkPos.Free;
    IndexMap.Free;
  end;
end;

// Which of the three period limits is binding, for the export page and the
// metrics file. The input window counts as binding whenever it had to add
// period at all - without it the period would be shorter.
function TForm1.ClockLimiterName: string;
begin
  Result := 'none';
  if FMinClockPeriodPs <= 0 then
    Exit;
  if FMinPeriodWindowExtraPs > 0 then
    Result := 'input window'
  else if FMinPeriodSpacingPs >= FMinPeriodTimingPs then
    Result := 'input spacing'
  else
    Result := 'data path';
end;
