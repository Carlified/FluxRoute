unit ClockValidate;

// Clock-arrival validation. For every clocked cell the clock must not arrive
// later than the data launched by the preceding clocked cell(s):
//
//   clkArr(T) <= clkArr(P) + dataDelay(P -> T)   (worst-case data path)
//
// clkArr is accumulated from the clock pad down the clock tree: the routed PTL
// delay of each link (per block, pin blocks excluded) plus the cell delay of
// every splitter / buffer / junction on the way. dataDelay is a max-relaxation
// of the logic netlist from every clocked cell (its clk->q plus the wire and
// gate delays until the next clocked cell). A violation names the clock-trunk
// net that must be split so the next-lower clock level is delayed.
//
// Form-free: the caller supplies the per-link wire delays (it owns the traces
// and placement) and this unit does only the netlist walks.

interface

uses
  System.SysUtils, System.Generics.Collections,
  BlifLibrary, LefLibrary, VerilogTiming, PipelineConfig;

type
  TClockViolation = record
    CellName: string;
    Level: Integer;
    ClkArrPs: Double;
    DataArrPs: Double;
    TrunkNet: string;     // trunk net to split for this violation
  end;
  TClockViolations = TArray<TClockViolation>;

  // Launch window for the first batch of input data, measured from the moment
  // the clock edge is SENT at the pad (t = 0 there), not from its arrival at the
  // clocked cells. Later batches are spaced by the clock period, so only this
  // first window has to be handed to the simulation.
  TInputWindow = record
    Found: Boolean;        // at least one clocked cell is driven from an input
    StartPs: Double;       // lower bound: earliest safe launch
    EndPs: Double;         // upper bound: latest launch that still meets setup
    ExtraPeriodPs: Double; // > 0 when the bounds conflict (period too short)
  end;

// Key for the wire-delay lookup of the link entering pin APin of gate ALoad.
function WireKey(AIndex: Integer; const APin: string): string;

// Clock arrival (ps from the pad) of every clocked gate in AModel.
procedure ComputeClockArrivals(AModel: TBlifModel; const ASourceNet: string;
  AWireDelays: TDictionary<string, Double>;
  AClockArr: TDictionary<TGateInstance, Double>);

// Worst-case data arrival (ps) at every clocked gate, walking data outputs from
// each clocked cell and stopping at the next clocked cell.
procedure ComputeDataArrivals(AModel: TBlifModel;
  AWireDelays: TDictionary<string, Double>;
  AClockArr, ADataArr: TDictionary<TGateInstance, Double>);

// Violations for clock levels that have a following junction. The first clock
// level (the last row) is excluded: there is no junction after it to insert a
// buffer at. ARows is the clock row list, highest level first.
function FindClockViolations(AModel: TBlifModel; const ARows: TArray<Integer>;
  AClockArr, ADataArr: TDictionary<TGateInstance, Double>): TClockViolations;

// Minimum clock period implied by the data path and setup: max over clocked
// cells of (dataArr(T) - clkArr(T) + setup(T)). Cells without a data arrival
// (the first clock level) are skipped.
function MinPeriodFromTiming(AModel: TBlifModel;
  AClockArr, ADataArr: TDictionary<TGateInstance, Double>): Double;

// Largest input-to-input spacing constraint in the circuit (ps).
function MaxInputSpacingPs(AModel: TBlifModel): Double;

// Timing window for the first batch of input data. Walks data from every
// primary input (arrival 0) through the combinational logic up to the first
// clocked cells and reports the launch range that satisfies both bounds. Values
// are relative to the clock edge as sent at the pad, so a negative bound simply
// means the simulation would have to launch the data before the first edge (or
// delay the clock instead):
//
//   StartPs = max over T of (clkArr(T) + hold(T) - period - earliestData(T))
//   EndPs   = min over T of (clkArr(T) - setup(T) - latestData(T))
//
// The first keeps the *next* batch (one period later) from arriving before the
// current one has been held; the second keeps the first batch from arriving
// after the setup point. If EndPs ends up below StartPs the two are
// inconsistent and ExtraPeriodPs is the period that has to be added.
function InputTimingWindow(AModel: TBlifModel;
  AClockArr: TDictionary<TGateInstance, Double>;
  AWireDelays: TDictionary<string, Double>; APeriodPs: Double): TInputWindow;

// Earliest travel time (ps) from the clock edge being SENT at the pad to any
// primary output pad: down the clock tree to a clocked cell, its clk->q, then
// the final combinational logic and interconnect out to the output. This is the
// period-independent part of the output window; the testbench adds its clock
// offset and levels * period. Returns -1 when no output is reachable.
function MinOutputTravelPs(AModel: TBlifModel;
  AClockArr: TDictionary<TGateInstance, Double>;
  AWireDelays: TDictionary<string, Double>): Double;

implementation

var
  GCellDelays: TDictionary<string, Double> = nil;
  GCellTimings: TDictionary<string, TCellTiming> = nil;

// Parsed timing for a cell (memoised), or nil when it has no .v file.
function CellTimingOf(ACell: TCell): TCellTiming;
var
  i: Integer;
  Timing: TCellTiming;
begin
  Result := nil;
  if ACell = nil then
    Exit;
  if GCellTimings = nil then
    GCellTimings := TDictionary<string, TCellTiming>.Create;
  if GCellTimings.TryGetValue(ACell.Name, Result) then
    Exit;
  Result := nil;
  for i := 0 to ACell.SourceFiles.Count - 1 do
    if SameText(ExtractFileExt(ACell.SourceFiles[i]), '.v') then
    begin
      Timing := ParseVerilogTiming(ACell.SourceFiles[i]);
      if Timing <> nil then
      begin
        Result := Timing;
        Break;
      end;
    end;
  GCellTimings.AddOrSetValue(ACell.Name, Result);
end;

// Worst-case output delay of a cell in ps, memoised; 0 when the cell has no
// .v timing arc.
function CellDelayPs(ACell: TCell): Double;
var
  i: Integer;
  Timing: TCellTiming;
begin
  if ACell = nil then
    Exit(0);
  if GCellDelays = nil then
    GCellDelays := TDictionary<string, Double>.Create;
  if GCellDelays.TryGetValue(ACell.Name, Result) then
    Exit;
  Result := 0;
  for i := 0 to ACell.SourceFiles.Count - 1 do
    if SameText(ExtractFileExt(ACell.SourceFiles[i]), '.v') then
    begin
      Timing := ParseVerilogTiming(ACell.SourceFiles[i]);
      if Timing <> nil then
      begin
        Result := Timing.OutputDelayPs;
        if Result < 0 then
          Result := 0;
        Timing.Free;
        Break;
      end;
    end;
  GCellDelays.AddOrSetValue(ACell.Name, Result);
end;

function WireKey(AIndex: Integer; const APin: string): string;
begin
  Result := IntToStr(AIndex) + '|' + LowerCase(APin);
end;

// Builds a gate -> index map (the model's own order).
function BuildIndexMap(AModel: TBlifModel): TDictionary<TGateInstance, Integer>;
var
  i: Integer;
begin
  Result := TDictionary<TGateInstance, Integer>.Create;
  for i := 0 to AModel.Gates.Count - 1 do
    Result.AddOrSetValue(AModel.Gates[i], i);
end;

procedure ComputeClockArrivals(AModel: TBlifModel; const ASourceNet: string;
  AWireDelays: TDictionary<string, Double>;
  AClockArr: TDictionary<TGateInstance, Double>);
var
  IndexMap: TDictionary<TGateInstance, Integer>;

  function LinkPs(ALoad: TGateInstance; const APin: string): Double;
  begin
    Result := 0;
    if (ALoad <> nil) and IndexMap.ContainsKey(ALoad) then
      AWireDelays.TryGetValue(WireKey(IndexMap[ALoad], APin), Result);
  end;

  procedure Walk(const ANetName: string; AArrived: Double);
  var
    Net: TNet;
    NC: TNetConnection;
    OutConn: TPinConnection;
    D: Double;
  begin
    if not AModel.Nets.TryGetValue(ANetName, Net) then
      Exit;
    for NC in Net.Connections do
    begin
      if NC.IsDriver then
        Continue;
      D := AArrived + LinkPs(NC.Gate, NC.PinName);
      if CellHasClock(NC.Gate.Cell) then
      begin
        if (not AClockArr.ContainsKey(NC.Gate)) or (D < AClockArr[NC.Gate]) then
          AClockArr.AddOrSetValue(NC.Gate, D);
        Continue;
      end;
      D := D + CellDelayPs(NC.Gate.Cell);
      for OutConn in NC.Gate.Connections do
        if (OutConn.Port <> nil) and (OutConn.Port.Direction = pdOutput) then
          Walk(OutConn.NetName, D);
    end;
  end;

begin
  AClockArr.Clear;
  IndexMap := BuildIndexMap(AModel);
  try
    Walk(ASourceNet, 0);
  finally
    IndexMap.Free;
  end;
end;

procedure ComputeDataArrivals(AModel: TBlifModel;
  AWireDelays: TDictionary<string, Double>;
  AClockArr, ADataArr: TDictionary<TGateInstance, Double>);
var
  IndexMap: TDictionary<TGateInstance, Integer>;
  OutArr: TDictionary<TGateInstance, Double>;
  Gate: TGateInstance;
  Net: TNet;
  NC: TNetConnection;
  OutConn: TPinConnection;
  Base, A, W: Double;
  Changed: Boolean;
  Guard, MaxPasses: Integer;

  function LinkPs(ALoad: TGateInstance; const APin: string): Double;
  begin
    Result := 0;
    if (ALoad <> nil) and IndexMap.ContainsKey(ALoad) then
      AWireDelays.TryGetValue(WireKey(IndexMap[ALoad], APin), Result);
  end;

begin
  ADataArr.Clear;
  OutArr := TDictionary<TGateInstance, Double>.Create;
  IndexMap := BuildIndexMap(AModel);
  try
    // Each clocked cell launches its data one clk->q after its clock arrives.
    for Gate in AModel.Gates do
      if CellHasClock(Gate.Cell) and AClockArr.ContainsKey(Gate) then
        OutArr.AddOrSetValue(Gate, AClockArr[Gate] + CellDelayPs(Gate.Cell));

    // Max-relaxation along data nets; clocked cells are boundaries.
    MaxPasses := AModel.Gates.Count + 8;
    Guard := 0;
    repeat
      Changed := False;
      Inc(Guard);
      for Gate in AModel.Gates do
      begin
        if not OutArr.TryGetValue(Gate, Base) then
          Continue;
        for OutConn in Gate.Connections do
        begin
          if (OutConn.Port = nil) or (OutConn.Port.Direction <> pdOutput) then
            Continue;
          if not AModel.Nets.TryGetValue(OutConn.NetName, Net) then
            Continue;
          for NC in Net.Connections do
          begin
            if NC.IsDriver then
              Continue;
            W := LinkPs(NC.Gate, NC.PinName);
            A := Base + W;
            if CellHasClock(NC.Gate.Cell) then
            begin
              if (not ADataArr.ContainsKey(NC.Gate)) or (A > ADataArr[NC.Gate]) then
              begin
                ADataArr.AddOrSetValue(NC.Gate, A);
                Changed := True;
              end;
            end
            else
            begin
              A := A + CellDelayPs(NC.Gate.Cell);
              if (not OutArr.ContainsKey(NC.Gate)) or (A > OutArr[NC.Gate]) then
              begin
                OutArr.AddOrSetValue(NC.Gate, A);
                Changed := True;
              end;
            end;
          end;
        end;
      end;
    until (not Changed) or (Guard >= MaxPasses);
  finally
    IndexMap.Free;
    OutArr.Free;
  end;
end;

function FindClockViolations(AModel: TBlifModel; const ARows: TArray<Integer>;
  AClockArr, ADataArr: TDictionary<TGateInstance, Double>): TClockViolations;
var
  i, k, RowIdx, n: Integer;
  Gate: TGateInstance;
  C, CEff, D: Double;
  V: TClockViolation;

  // The trunk net immediately after the junction that serves ALevel: the
  // junction's SECOND output (the first drives its row tree). Keyed on port
  // order, so a trunk net that reuses a row-net name is still recognised.
  function TrunkAfterJunction(ALevel: Integer): string;
  var
    JG: TGateInstance;
    Conn: TPinConnection;
    OutSeen: Integer;
  begin
    Result := '';
    for JG in AModel.Gates do
      if JG.ClockTrunk and (JG.ClockLevel = ALevel) then
      begin
        OutSeen := 0;
        for Conn in JG.Connections do
          if (Conn.Port <> nil) and (Conn.Port.Direction = pdOutput) then
          begin
            Inc(OutSeen);
            if OutSeen = 2 then
            begin
              Result := Conn.NetName;
              Exit;
            end;
          end;
        Exit;
      end;
  end;

begin
  Result := nil;
  n := Length(ARows);
  for i := 0 to AModel.Gates.Count - 1 do
  begin
    Gate := AModel.Gates[i];
    if not CellHasClock(Gate.Cell) then
      Continue;
    if not AClockArr.TryGetValue(Gate, C) then
      Continue;
    if not ADataArr.TryGetValue(Gate, D) then
      Continue;
    RowIdx := -1;
    for k := 0 to n - 1 do
      if ARows[k] = Gate.ClockLevel then
      begin
        RowIdx := k;
        Break;
      end;
    if RowIdx < 0 then
      Continue;
    // The first clock level (last row) has no junction after it.
    if RowIdx >= n - 1 then
      Continue;
    // The clock must be safe against both the data arrival and the cell's hold.
    CEff := C;
    if CellTimingOf(Gate.Cell) <> nil then
      CEff := C + CellTimingOf(Gate.Cell).HoldPs;
    if CEff <= D + 1e-9 then
      Continue;
    V.CellName := Gate.CellName;
    V.Level := Gate.ClockLevel;
    V.ClkArrPs := C;
    V.DataArrPs := D;
    V.TrunkNet := TrunkAfterJunction(ARows[RowIdx]);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := V;
  end;
end;

// Relaxes input data arrivals (ps from the pad) through the combinational logic,
// stopping at clocked cells. ATakeMin keeps the earliest path (needed for the
// second-batch bound); otherwise the latest path is kept.
procedure RelaxInputArrivals(AModel: TBlifModel;
  AWireDelays: TDictionary<string, Double>; ATakeMin: Boolean;
  AClockedArr: TDictionary<TGateInstance, Double>);
var
  IndexMap: TDictionary<TGateInstance, Integer>;
  NetArr: TDictionary<string, Double>;
  Keys: TArray<string>;
  Net: TNet;
  NC: TNetConnection;
  OutConn: TPinConnection;
  Base, A, Old: Double;
  Changed: Boolean;
  Guard, i: Integer;

  function LinkPs(ALoad: TGateInstance; const APin: string): Double;
  begin
    Result := 0;
    if (ALoad <> nil) and IndexMap.ContainsKey(ALoad) then
      AWireDelays.TryGetValue(WireKey(IndexMap[ALoad], APin), Result);
  end;

  function Better(const ANew, AOld: Double): Boolean;
  begin
    if ATakeMin then
      Result := ANew < AOld - 1e-9
    else
      Result := ANew > AOld + 1e-9;
  end;

  procedure Offer(AGate: TGateInstance; AValue: Double);
  begin
    if (not AClockedArr.TryGetValue(AGate, Old)) or Better(AValue, Old) then
    begin
      AClockedArr.AddOrSetValue(AGate, AValue);
      Changed := True;
    end;
  end;

  procedure OfferNet(const AName: string; AValue: Double);
  begin
    if (not NetArr.TryGetValue(AName, Old)) or Better(AValue, Old) then
    begin
      NetArr.AddOrSetValue(AName, AValue);
      Changed := True;
    end;
  end;

begin
  AClockedArr.Clear;
  IndexMap := BuildIndexMap(AModel);
  NetArr := TDictionary<string, Double>.Create;
  try
    Keys := AModel.Nets.Keys.ToArray;
    for i := 0 to High(Keys) do
      if AModel.Inputs.IndexOf(Keys[i]) >= 0 then
        NetArr.AddOrSetValue(Keys[i], 0);

    Guard := 0;
    repeat
      Changed := False;
      for i := 0 to High(Keys) do
        if NetArr.TryGetValue(Keys[i], Base) then
        begin
          Net := AModel.Nets[Keys[i]];
          for NC in Net.Connections do
          begin
            if NC.IsDriver then
              Continue;
            A := Base + LinkPs(NC.Gate, NC.PinName);
            if CellHasClock(NC.Gate.Cell) then
              Offer(NC.Gate, A)
            else
              for OutConn in NC.Gate.Connections do
                if (OutConn.Port <> nil) and
                   (OutConn.Port.Direction = pdOutput) then
                  OfferNet(OutConn.NetName, A + CellDelayPs(NC.Gate.Cell));
          end;
        end;
      Inc(Guard);
    until (not Changed) or (Guard >= AModel.Gates.Count + 8);
  finally
    NetArr.Free;
    IndexMap.Free;
  end;
end;

function InputTimingWindow(AModel: TBlifModel;
  AClockArr: TDictionary<TGateInstance, Double>;
  AWireDelays: TDictionary<string, Double>; APeriodPs: Double): TInputWindow;
var
  MinArr, MaxArr: TDictionary<TGateInstance, Double>;
  Gate: TGateInstance;
  Timing: TCellTiming;
  C, DMin, DMax, Lo, Hi: Double;
  i: Integer;
begin
  Result.Found := False;
  Result.StartPs := 0;
  Result.EndPs := 0;
  Result.ExtraPeriodPs := 0;
  MinArr := TDictionary<TGateInstance, Double>.Create;
  MaxArr := TDictionary<TGateInstance, Double>.Create;
  try
    RelaxInputArrivals(AModel, AWireDelays, True, MinArr);
    RelaxInputArrivals(AModel, AWireDelays, False, MaxArr);
    for i := 0 to AModel.Gates.Count - 1 do
    begin
      Gate := AModel.Gates[i];
      if not CellHasClock(Gate.Cell) then
        Continue;
      if not AClockArr.TryGetValue(Gate, C) then
        Continue;
      if not MinArr.TryGetValue(Gate, DMin) then
        Continue;
      if not MaxArr.TryGetValue(Gate, DMax) then
        Continue;
      Timing := CellTimingOf(Gate.Cell);
      Lo := C - APeriodPs - DMin;
      Hi := C - DMax;
      if Timing <> nil then
      begin
        Lo := Lo + Timing.HoldPs;
        Hi := Hi - Timing.SetupPs;
      end;
      if not Result.Found then
      begin
        Result.Found := True;
        Result.StartPs := Lo;
        Result.EndPs := Hi;
      end
      else
      begin
        if Lo > Result.StartPs then
          Result.StartPs := Lo;
        if Hi < Result.EndPs then
          Result.EndPs := Hi;
      end;
    end;
  finally
    MaxArr.Free;
    MinArr.Free;
  end;
  if Result.Found and (Result.EndPs < Result.StartPs) then
    Result.ExtraPeriodPs := Result.StartPs - Result.EndPs;
end;

function MinOutputTravelPs(AModel: TBlifModel;
  AClockArr: TDictionary<TGateInstance, Double>;
  AWireDelays: TDictionary<string, Double>): Double;
var
  IndexMap: TDictionary<TGateInstance, Integer>;
  NetArr: TDictionary<string, Double>;
  Keys: TArray<string>;
  Net: TNet;
  NC: TNetConnection;
  OutConn: TPinConnection;
  Gate: TGateInstance;
  Base, A, Old, Best: Double;
  Changed, Found: Boolean;
  Guard, i: Integer;

  function LinkPs(ALoad: TGateInstance; const APin: string): Double;
  begin
    Result := 0;
    if (ALoad <> nil) and IndexMap.ContainsKey(ALoad) then
      AWireDelays.TryGetValue(WireKey(IndexMap[ALoad], APin), Result);
  end;

  procedure OfferNet(const AName: string; AValue: Double);
  begin
    if (not NetArr.TryGetValue(AName, Old)) or (AValue < Old - 1e-9) then
    begin
      NetArr.AddOrSetValue(AName, AValue);
      Changed := True;
    end;
  end;

begin
  Result := -1;
  IndexMap := BuildIndexMap(AModel);
  NetArr := TDictionary<string, Double>.Create;
  try
    Keys := AModel.Nets.Keys.ToArray;

    // Seed: every clocked cell launches its data one clk->q after its clock.
    for Gate in AModel.Gates do
      if CellHasClock(Gate.Cell) and AClockArr.ContainsKey(Gate) then
        for OutConn in Gate.Connections do
          if (OutConn.Port <> nil) and (OutConn.Port.Direction = pdOutput) then
            OfferNet(OutConn.NetName, AClockArr[Gate] + CellDelayPs(Gate.Cell));

    // Earliest arrival per net through the combinational logic; clocked cells
    // are boundaries because they relaunch on their own clock.
    Guard := 0;
    repeat
      Changed := False;
      for i := 0 to High(Keys) do
        if NetArr.TryGetValue(Keys[i], Base) then
        begin
          Net := AModel.Nets[Keys[i]];
          for NC in Net.Connections do
          begin
            if NC.IsDriver or CellHasClock(NC.Gate.Cell) then
              Continue;
            A := Base + LinkPs(NC.Gate, NC.PinName) + CellDelayPs(NC.Gate.Cell);
            for OutConn in NC.Gate.Connections do
              if (OutConn.Port <> nil) and
                 (OutConn.Port.Direction = pdOutput) then
                OfferNet(OutConn.NetName, A);
          end;
        end;
      Inc(Guard);
    until (not Changed) or (Guard >= AModel.Gates.Count + 8);

    Best := 0;
    Found := False;
    for i := 0 to AModel.Outputs.Count - 1 do
      if NetArr.TryGetValue(AModel.Outputs[i], Old) then
        if (not Found) or (Old < Best) then
        begin
          Best := Old;
          Found := True;
        end;
    if Found then
      Result := Best;
  finally
    NetArr.Free;
    IndexMap.Free;
  end;
end;

function MinPeriodFromTiming(AModel: TBlifModel;
  AClockArr, ADataArr: TDictionary<TGateInstance, Double>): Double;
var
  i: Integer;
  Gate: TGateInstance;
  C, D, V: Double;
begin
  Result := 0;
  for i := 0 to AModel.Gates.Count - 1 do
  begin
    Gate := AModel.Gates[i];
    if not CellHasClock(Gate.Cell) then
      Continue;
    if not AClockArr.TryGetValue(Gate, C) then
      Continue;
    if not ADataArr.TryGetValue(Gate, D) then
      Continue;
    V := D - C;
    if CellTimingOf(Gate.Cell) <> nil then
      V := V + CellTimingOf(Gate.Cell).SetupPs;
    if V > Result then
      Result := V;
  end;
end;

function MaxInputSpacingPs(AModel: TBlifModel): Double;
var
  i: Integer;
  T: TCellTiming;
begin
  Result := 0;
  for i := 0 to AModel.Gates.Count - 1 do
  begin
    T := CellTimingOf(AModel.Gates[i].Cell);
    if (T <> nil) and (T.InputSpacingPs > Result) then
      Result := T.InputSpacingPs;
  end;
end;

initialization

finalization
  GCellDelays.Free;
  // The memoised TCellTiming objects live for the process; only the map is
  // released here (per-process teardown makes the objects moot).
  GCellTimings.Free;

end.
